#!/bin/bash
# Release DMG of the app: xcodegen, Release build, Developer ID signature (hardened runtime, secure timestamp) of the
# frameworks (Sparkle's nested code first), the helper and the app, a DMG laid out by dmgbuild (background with an
# arrow, the app and an /Applications link; dmg-settings.py), its signature, notarization, stapling and the
# Gatekeeper checks. dmgbuild is installed once into build/release/dmgbuild-venv (requirements.txt).
#
#   MW_SIGN_IDENTITY="Developer ID Application: <name> (<team>)" Scripts/release/build-dmg.sh [--skip-notarize]
#
#   MW_SIGN_IDENTITY   codesign identity: its name or SHA-1 (`security find-identity -v -p codesigning`); the
#                      certificate must belong to the team in DEVELOPMENT_TEAM of project.yml (MW_TEAM overrides it),
#                      and the helper's requirements (HelperConstants in HelperProtocol.swift) must name the same team,
#                      or the app and the helper refuse each other
#   Notarization signs in either with an App Store Connect API key — MW_NOTARY_KEY (the .p8 file), MW_NOTARY_KEY_ID,
#   MW_NOTARY_ISSUER — or with MW_NOTARY_PROFILE=<profile>, a `notarytool store-credentials` keychain profile.
#   --skip-notarize    no notarization and stapling; the Gatekeeper (spctl) checks only warn. Allows an identity that
#                      is not Developer ID (e.g. Apple Development) to test the build; such a DMG is not for release.
#
# Output: build/release/MacWashing-<CFBundleShortVersionString>.dmg; work files (DerivedData, xcodebuild.log, the DMG
# staging folder, notarization results) stay in build/release/. Publish it with publish-release.sh.
set -euo pipefail

app_dir=$(cd "$(dirname "$0")/../.." && pwd)
out=$app_dir/build/release
team=${MW_TEAM:-$(sed -n 's/^ *DEVELOPMENT_TEAM: *\([A-Z0-9]*\)$/\1/p' "$app_dir/project.yml" | head -n 1)}
helper_name=com.ovvi.MacWashing.Helper

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

skip_notarize=0
for arg in "$@"; do
    case $arg in
        --skip-notarize) skip_notarize=1 ;;
        -h | --help)
            sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option $arg (see --help)" ;;
    esac
done

[[ -n $team ]] || die "no DEVELOPMENT_TEAM in project.yml (or set MW_TEAM)"
identity=${MW_SIGN_IDENTITY:-}
[[ -n $identity ]] || die "set MW_SIGN_IDENTITY to a Developer ID Application identity (see --help)"
for tool in xcodegen xcodebuild codesign hdiutil xcrun spctl python3; do
    command -v "$tool" >/dev/null || die "$tool is not installed"
done
ident_line=$(security find-identity -v -p codesigning | grep -F "$identity" | head -n 1 || true)
[[ -n $ident_line ]] || die "no valid code signing identity '$identity' in the keychain (security find-identity -v -p codesigning)"
info "identity: $(printf '%s' "$ident_line" | sed 's/^ *[0-9]*) //')"
if [[ $skip_notarize -eq 0 ]]; then
    [[ $ident_line == *"Developer ID Application"* ]] ||
        die "notarization needs a Developer ID Application identity (or --skip-notarize for a test build)"
    if [[ -n ${MW_NOTARY_PROFILE:-} ]]; then
        notary_auth=(--keychain-profile "$MW_NOTARY_PROFILE")
        notary_what="keychain profile $MW_NOTARY_PROFILE"
    else
        key=${MW_NOTARY_KEY:-}
        key_id=${MW_NOTARY_KEY_ID:-}
        [[ -r $key && -n $key_id && -n ${MW_NOTARY_ISSUER:-} ]] ||
            die "set MW_NOTARY_KEY, MW_NOTARY_KEY_ID and MW_NOTARY_ISSUER (or MW_NOTARY_PROFILE; see --help)"
        notary_auth=(--key "$key" --key-id "$key_id" --issuer "$MW_NOTARY_ISSUER")
        notary_what="API key $key_id"
    fi
elif [[ $ident_line != *"Developer ID Application"* ]]; then
    warn "not a Developer ID identity: a test build, Gatekeeper will reject it"
fi

# The designated requirements the app and the helper check on each other (HelperConstants in HelperProtocol.swift).
# A Release helper accepts only `releaseClientRequirement` (Developer ID, no get-task-allow): the line after it.
swift_reqs=$app_dir/Packages/MacWashingKit/Sources/MacWashingXPC/HelperProtocol.swift
client_req=$(sed -n '/releaseClientRequirement =$/{n;s/^.*#"\(identifier "com\.ovvi\.MacWashing" [^#]*\)"#.*$/\1/p;}' "$swift_reqs")
helper_req=$(sed -n 's/^.*#"\(identifier "com\.ovvi\.MacWashing\.Helper" [^#]*\)"#.*$/\1/p' "$swift_reqs")
[[ -n $client_req && -n $helper_req ]] || die "cannot read clientRequirement/helperRequirement from $swift_reqs"

mnt=""
cleanup() {
    [[ -z $mnt ]] || hdiutil detach -quiet "$mnt" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$out"

step "xcodegen"
(cd "$app_dir" && xcodegen generate --quiet)

# `xcodebuild build`, not `archive`: the DMG is laid out from the build products. DEPLOYMENT_POSTPROCESSING=YES strips
# the binaries as an archive would. Universal (arm64, x86_64) through the generic destination. No secure
# timestamp here (`--timestamp=none`: a Developer ID signature asks for one by default): xcodebuild signs in parallel and Apple's timestamp server refuses concurrent requests («The timestamp
# transaction is not permitted»); the signing step below signs everything again, one at a time, with the timestamp.
step "Release build (log: build/release/xcodebuild.log)"
products=$out/DerivedData/Build/Products/Release
rm -rf "$products/MacWashing.app"
if ! xcodebuild build -project "$app_dir/MacWashing.xcodeproj" -scheme MacWashing -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$out/DerivedData" DEPLOYMENT_POSTPROCESSING=YES \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" DEVELOPMENT_TEAM="$team" PROVISIONING_PROFILE_SPECIFIER= \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO OTHER_CODE_SIGN_FLAGS=--timestamp=none >"$out/xcodebuild.log" 2>&1; then
    grep -E 'error:|BUILD FAILED' "$out/xcodebuild.log" | tail -n 30 >&2 || tail -n 30 "$out/xcodebuild.log" >&2
    die "xcodebuild failed (full log: $out/xcodebuild.log)"
fi

stage=$out/dmg-stage
app=$stage/MacWashing.app
rm -rf "$stage"
mkdir -p "$stage"
ditto "$products/MacWashing.app" "$app"
plist=$app/Contents/Info.plist
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")
[[ $version =~ ^[0-9][0-9A-Za-z.+-]{0,39}$ ]] || die "version '$version' is not a valid version"
info "MacWashing $version ($build)"

step "Checking the bundle"
[[ -s $app/Contents/Resources/database.sqlite ]] || die "Contents/Resources/database.sqlite (the rules database) is missing"
[[ -x $app/Contents/MacOS/$helper_name ]] || die "the helper Contents/MacOS/$helper_name is missing"
[[ -f $app/Contents/Library/LaunchDaemons/$helper_name.plist ]] || die "Contents/Library/LaunchDaemons/$helper_name.plist is missing"
# Updates can only be switched on by an update: a release without its keys would never get one (app or rules).
for key in SUPublicEDKey MWRulesKeys; do
    value=$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true)
    if [[ -z $value ]]; then
        [[ $skip_notarize -eq 1 ]] || die "$key is empty in Info.plist: this release could never be updated"
        warn "$key is empty: updates are off in this test build"
    else
        info "$key $value"
    fi
done
archs=$(lipo -archs "$app/Contents/MacOS/MacWashing")
[[ $archs == *arm64* && $archs == *x86_64* ]] || die "the app is not universal (architectures: $archs)"
info "architectures: $archs"

step "Signing (hardened runtime, secure timestamp): frameworks, helper, app"
sign() {
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$identity" "$@"
}
# Sparkle's helpers inside its framework, inside out (Sparkle's documented order for signing outside an Xcode archive);
# --deep is never used. The Downloader keeps its entitlements (--preserve-metadata).
sparkle=$app/Contents/Frameworks/Sparkle.framework
if [[ -d $sparkle ]]; then
    for code in "$sparkle"/Versions/B/XPCServices/Installer.xpc "$sparkle"/Versions/B/XPCServices/Downloader.xpc \
        "$sparkle"/Versions/B/Autoupdate "$sparkle"/Versions/B/Updater.app; do
        [[ -e $code ]] || continue
        info "${code#"$app"/}"
        sign "$code"
    done
else
    die "Sparkle.framework is missing from Contents/Frameworks"
fi
if [[ -d $app/Contents/Frameworks ]]; then
    find "$app/Contents/Frameworks" -mindepth 1 -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) -print0 |
        while IFS= read -r -d '' code; do
            info "${code#"$app"/}"
            sign "$code"
        done
fi
info "Contents/MacOS/$helper_name"
sign --identifier "$helper_name" "$app/Contents/MacOS/$helper_name"
info "MacWashing.app"
sign "$app"

step "Verifying the signatures"
codesign --verify --deep --strict --verbose=2 "$app"
if [[ $ident_line == *"Developer ID Application"* ]]; then
    codesign --verify --strict -R="$client_req" "$app" || die "the app does not satisfy the helper's clientRequirement"
elif ! codesign --verify --strict -R="$client_req" "$app" 2>/dev/null; then
    warn "not Developer ID: the Release helper of this test build will refuse the app (releaseClientRequirement)"
fi
codesign --verify --strict -R="$helper_req" "$app/Contents/MacOS/$helper_name" ||
    die "the helper does not satisfy the app's helperRequirement"
for code in "$app" "$app/Contents/MacOS/$helper_name" "$sparkle" "$sparkle/Versions/B/Autoupdate" "$sparkle/Versions/B/Updater.app"; do
    details=$(codesign -dvv "$code" 2>&1)
    [[ $details == *"TeamIdentifier=$team"* ]] || die "${code#"$stage"/} is not signed by team $team"
    [[ $details =~ flags=0x[0-9a-f]+\([^\)]*runtime ]] || die "${code#"$stage"/} has no hardened runtime"
    [[ $details == *"Timestamp="* ]] || die "${code#"$stage"/} has no secure timestamp"
    if codesign -d --entitlements - --xml "$code" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then
        die "${code#"$stage"/} has the get-task-allow entitlement (notarization rejects it)"
    fi
done
info "team $team, hardened runtime, timestamp (app, helper, Sparkle); app and helper satisfy each other's requirements"

step "DMG (dmgbuild)"
venv=$out/dmgbuild-venv
if ! "$venv/bin/python" -c 'import dmgbuild' 2>/dev/null; then
    info "installing dmgbuild into build/release/dmgbuild-venv"
    rm -rf "$venv"
    python3 -m venv "$venv"
    "$venv/bin/pip" install --quiet --disable-pip-version-check -r "$app_dir/Scripts/release/requirements.txt"
fi
volume_icon=$app/Contents/Resources/AppIcon.icns
[[ -f $volume_icon ]] || die "Contents/Resources/AppIcon.icns is missing (the volume icon)"
dmg=$out/MacWashing-$version.dmg
rm -f "$dmg"
"$venv/bin/dmgbuild" -s "$app_dir/Scripts/release/dmg-settings.py" -D app="$app" \
    -D background="$app_dir/Scripts/release/dmg/background.tiff" -D icon="$volume_icon" MacWashing "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"

if [[ $skip_notarize -eq 0 ]]; then
    step "Notarization (xcrun notarytool, $notary_what; usually a few minutes)"
    xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait --output-format json \
        >"$out/notarization.json" || true
    status=$(plutil -extract status raw -o - "$out/notarization.json" 2>/dev/null || echo unknown)
    id=$(plutil -extract id raw -o - "$out/notarization.json" 2>/dev/null || true)
    if [[ $status != Accepted ]]; then
        [[ -z $id ]] || xcrun notarytool log "$id" "${notary_auth[@]}" "$out/notarization-log.json" || true
        die "notarization status '$status' (submission ${id:-unknown}; $out/notarization.json, $out/notarization-log.json)"
    fi
    info "accepted (submission $id)"
    step "Stapling"
    xcrun stapler staple "$dmg"
    xcrun stapler validate "$dmg"
else
    warn "--skip-notarize: not notarized, not stapled"
fi

step "Gatekeeper"
gatekeeper() { # gatekeeper <description> <command...>
    local what=$1
    shift
    if "$@"; then
        info "$what: accepted"
    elif [[ $skip_notarize -eq 1 ]]; then
        warn "$what: rejected (expected without notarization)"
    else
        die "$what: rejected"
    fi
}
gatekeeper "DMG (spctl -t open)" spctl -a -t open --context context:primary-signature -vv "$dmg"
mnt=$(mktemp -d "$out/mnt.XXXXXX")
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg"
codesign --verify --deep --strict --verbose=2 "$mnt/MacWashing.app"
[[ -L $mnt/Applications ]] || die "the DMG has no Applications link"
[[ -f $mnt/.DS_Store && -f $mnt/.background.tiff ]] || die "the DMG has no window layout (.DS_Store, .background.tiff)"
gatekeeper "app in the DMG (spctl -t exec)" spctl -a -t exec -vv "$mnt/MacWashing.app"
hdiutil detach -quiet "$mnt"
rmdir "$mnt"
mnt=""

step "Done"
info "$dmg ($(du -h "$dmg" | cut -f1 | tr -d ' '), sha256 $(shasum -a 256 "$dmg" | cut -d' ' -f1))"
[[ $skip_notarize -eq 0 ]] || warn "a test DMG (not notarized): do not upload it as a release"
