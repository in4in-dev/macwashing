#!/bin/bash
# Publishes an app release on GitHub: only on the maintainer's command.
#
#   Scripts/release/publish-release.sh [--dmg <path>] [--dry-run] [--yes]
#
# The DMG (default build/release/MacWashing-<MARKETING_VERSION>.dmg from build-dmg.sh) must be notarized and stapled,
# and its app must carry MARKETING_VERSION / CURRENT_PROJECT_VERSION of project.yml, a build newer than every published
# one, and the update keys (SUPublicEDKey, MWRulesKeys). Release notes: release-notes/<version>.en.md and .ru.md (plain
# text; lines starting with "- " become a list).
#
# Steps: Sparkle's sign_update signs the DMG with the EdDSA key in the login keychain (setup-keys.sh) → a draft GitHub
# release v<version> with the DMG twice, as MacWashing-<version>.dmg (what the appcast names) and MacWashing.dmg (the
# stable link releases/latest/download/MacWashing.dmg in the README) → updates/releases/<version>.json,
# updates/appcast.xml, release-notes/dates.txt, CHANGELOG.md and site/ committed on main and tagged v<version> → the
# tag pushed and the draft published on it → main pushed. Apps see the update once the commit is on GitHub (raw.githubusercontent.com caches for
# up to 5 minutes). Needs `gh` signed in (`gh auth login`).
#
#   --dry-run   every check and the signature; no release, no commit, no push
#   --yes       no confirmation
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib-releases.sh
. "$(dirname "$0")/lib-releases.sh"

dry_run=0
dmg=""
while [[ $# -gt 0 ]]; do
    case $1 in
        --dmg) dmg=${2:?--dmg needs a path}; shift ;;
        --dry-run) dry_run=1 ;;
        --yes) export MW_YES=1 ;;
        -h | --help)
            sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option $1 (see --help)" ;;
    esac
    shift
done
for tool in python3 hdiutil spctl xcrun shasum gh; do command -v "$tool" >/dev/null || die "$tool is not installed"; done
gh auth status >/dev/null 2>&1 || die "gh is not signed in: gh auth login"

project_value() { sed -n "s/^ *$1: \"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$repo/project.yml" | head -n 1; }
version=$(project_value MARKETING_VERSION)
build=$(project_value CURRENT_PROJECT_VERSION)
repository=$(repository)
[[ -n $repository ]] || die "no MW_REPOSITORY in project.yml"
dmg=${dmg:-$repo/build/release/MacWashing-$version.dmg}

commit=$(source_commit)
work=$(mktemp -d "${TMPDIR:-/tmp}/mw-publish-release.XXXXXX")
mnt=""
cleanup() {
    [[ -z $mnt ]] || hdiutil detach -quiet "$mnt" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT

step "MacWashing $version ($build) from ${commit:0:12}"
[[ $version =~ ^[0-9][0-9A-Za-z.+-]{0,39}$ && $version != *..* ]] || die "MARKETING_VERSION '$version' is not a valid version"
[[ $build =~ ^[1-9][0-9]{0,8}$ ]] || die "CURRENT_PROJECT_VERSION '$build' is not a positive number"
mkdir -p "$updates/releases"
[[ ! -f $updates/releases/$version.json ]] || die "version $version is already published (raise MARKETING_VERSION)"
tag_is_free "v$version"
! gh release view "v$version" --repo "$repository" >/dev/null 2>&1 ||
    die "a GitHub release v$version already exists (a draft left by an earlier run? delete it: gh release delete v$version)"
for published in "$updates"/releases/*.json; do
    [[ -f $published ]] || continue
    b=$(json "$published" 'd["build"]')
    [[ $build -gt $b ]] || die "build $build is not newer than $(basename "$published" .json)'s build $b (raise CURRENT_PROJECT_VERSION)"
done
notes_en=$repo/release-notes/$version.en.md
notes_ru=$repo/release-notes/$version.ru.md
[[ -s $notes_en && -s $notes_ru ]] || die "release notes missing: release-notes/$version.en.md and .ru.md"

step "DMG $dmg"
[[ -f $dmg ]] || die "no DMG: run build-dmg.sh first (or --dmg <path>)"
xcrun stapler validate -q "$dmg" || die "the DMG is not stapled (notarize it: build-dmg.sh without --skip-notarize)"
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || die "Gatekeeper rejects the DMG"
mnt=$(mktemp -d "$work/mnt.XXXXXX")
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$mnt" "$dmg"
plist=$mnt/MacWashing.app/Contents/Info.plist
[[ -f $plist ]] || die "no MacWashing.app in the DMG"
pv() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
[[ $(pv CFBundleShortVersionString) == "$version" ]] || die "the app in the DMG is $(pv CFBundleShortVersionString), project.yml says $version"
[[ $(pv CFBundleVersion) == "$build" ]] || die "the app's build is $(pv CFBundleVersion), project.yml says $build"
[[ -n $(pv SUPublicEDKey) && -n $(pv MWRulesKeys) ]] || die "the app has no SUPublicEDKey / MWRulesKeys: it could never be updated"
[[ $(pv MWRepository) == "$repository" ]] || die "the app reads its updates from '$(pv MWRepository)', project.yml says $repository"
min_system=$(pv LSMinimumSystemVersion)
min_system=${min_system:-14.0}
spctl -a -t exec "$mnt/MacWashing.app" 2>/dev/null || die "Gatekeeper rejects the app in the DMG"
hdiutil detach -quiet "$mnt"
mnt=""

step "Sparkle signature"
sign_update=$(find "$repo/build" -path '*/artifacts/sparkle/Sparkle/bin/sign_update' -type f 2>/dev/null | head -n 1)
[[ -n $sign_update ]] || die "Sparkle's sign_update not found under build/ (build the app once)"
ed_signature=$("$sign_update" -p "$dmg") || die "sign_update failed (is the Sparkle key in the keychain? setup-keys.sh)"
"$sign_update" --verify "$dmg" "$ed_signature" >/dev/null 2>&1 || die "the EdDSA signature does not verify"
[[ $("$(dirname "$sign_update")/generate_keys" -p) == "$(plist_value SUPublicEDKey)" ]] ||
    die "the keychain's Sparkle key does not match SUPublicEDKey in App/Info.plist"
size=$(stat -f %z "$dmg")
sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
info "macOS $min_system+, $size bytes, sha256 $sha (for Scripts/release/homebrew/macwashing.rb)"

if [[ $dry_run -eq 1 ]]; then
    warn "--dry-run: every check passed; nothing released, committed or pushed"
    exit 0
fi
confirm "Publish MacWashing $version ($build) on github.com/$repository?" || die "cancelled"

step "GitHub release v$version (draft)"
cp "$dmg" "$work/MacWashing-$version.dmg"
cp "$dmg" "$work/MacWashing.dmg"
python3 - "$notes_en" "$notes_ru" "$work/notes.md" <<'EOF'
import sys
en, ru, out = sys.argv[1:4]
open(out, "w").write(open(en).read().strip() + "\n\n<details><summary>По-русски</summary>\n\n" + open(ru).read().strip()
                     + "\n\n</details>\n")
EOF
# A draft first: its assets are uploaded but not public, and it makes no tag; it goes public right after the push below.
gh release create "v$version" --repo "$repository" --draft --title "MacWashing $version" \
    --notes-file "$work/notes.md" "$work/MacWashing-$version.dmg" "$work/MacWashing.dmg"

step "Feed and changelog"
today=$(date -u +%Y-%m-%d)
python3 - "$updates/releases/$version.json" "$version" "$build" "$size" "$sha" "$ed_signature" "$min_system" \
    "$notes_en" "$notes_ru" "$commit" "$(date -u '+%a, %d %b %Y %H:%M:%S +0000')" <<'EOF'
import json, sys
path, version, build, size, sha, sig, min_system, en, ru, commit, date = sys.argv[1:12]
json.dump({"version": version, "build": int(build), "size": int(size), "sha256": sha, "ed_signature": sig,
           "min_system": min_system, "date": date,
           "notes": {"en": open(en).read().strip(), "ru": open(ru).read().strip()},
           "source_commit": commit, "file": f"MacWashing-{version}.dmg"}, open(path, "w"), indent=2, ensure_ascii=False)
EOF
grep -q "^$version " "$repo/release-notes/dates.txt" || printf '%s %s\n' "$version" "$today" >>"$repo/release-notes/dates.txt"
python3 "$repo/Scripts/release/notes.py" appcast "$repo" "$repository"
python3 "$repo/Scripts/release/notes.py" changelog "$repo" "$repository"
python3 "$repo/Scripts/site/build.py" >/dev/null
info "updates/appcast.xml: $(grep -c '<item>' "$updates/appcast.xml") versions"

step "Push"
commit_and_tag "Release $version ($build)" "v$version" updates release-notes/dates.txt CHANGELOG.md site
# The tag first, then the release goes public on it, and only then main with the appcast: apps never see an update
# whose DMG is not downloadable yet.
git_ push --quiet origin "refs/tags/v$version"
gh release edit "v$version" --repo "$repository" --draft=false --latest --verify-tag
git_ push --quiet origin main
info "github.com/$repository/releases/tag/v$version; apps find it at their next daily check"
