#!/bin/bash
# Publishes the rules database between app releases: only on the maintainer's command, after reviewing the changes.
#
#   Scripts/release/publish-rules.sh [--dry-run] [--yes]
#
# From HEAD of main (clean, pushed): App/Resources/database.sqlite is copied as updates/rules/<level>/rules-<version>.sqlite
# (<level> is Database.level of the code), with its manifest signed by the rules key from the login keychain
# (setup-keys.sh) and checked against MWRulesKeys of App/Info.plist; updates/rules/index.json gets the version; an older
# file of the same level is removed (git history keeps it); info.json holds the counts; the project page (site/) is
# rebuilt with the new numbers. One commit on main, tag
# rules-v<version>, pushed. Apps fetch it within a day and use it from their next launch.
#
#   --dry-run   every check and the signature, the files written to a temporary folder (printed); no commit, no push
#   --yes       no confirmation after the summary of what changed
#
# Before publishing: raise info.version in database.sqlite
# (`sqlite3 App/Resources/database.sqlite "UPDATE info SET value='<next version>' WHERE key='version'"`), commit, push.
set -euo pipefail
# shellcheck source=SCRIPTDIR/lib-releases.sh
. "$(dirname "$0")/lib-releases.sh"

dry_run=0
for arg in "$@"; do
    case $arg in
        --dry-run) dry_run=1 ;;
        --yes) export MW_YES=1 ;;
        -h | --help)
            sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown option $arg (see --help)" ;;
    esac
done
for tool in sqlite3 python3 xcrun security shasum; do command -v "$tool" >/dev/null || die "$tool is not installed"; done

database=$repo/App/Resources/database.sqlite
commit=$(source_commit)

level=$(sed -n 's/^ *public static let level = \([0-9]*\)$/\1/p' "$repo/Packages/MacWashingKit/Sources/MacWashingKit/Database/Database.swift")
[[ $level =~ ^[1-9][0-9]*$ ]] || die "cannot read Database.level"
version=$(sqlite3 "$database" "SELECT value FROM info WHERE key = 'version'")
[[ $version =~ ^[0-9]{1,6}(\.[0-9]{1,6}){0,5}$ ]] || die "info.version '$version' is not 1-6 dot-separated numbers"
file_level=$(sqlite3 "$database" "SELECT value FROM info WHERE key = 'level'")
[[ -z $file_level || $file_level == "$level" ]] || die "database.sqlite says level $file_level, the code reads level $level"
keys=$(plist_value MWRulesKeys)
[[ -n $keys ]] || die "MWRulesKeys is empty in App/Info.plist: run setup-keys.sh first"

tag_is_free "rules-v$version"
dir=$updates/rules/$level
published=""
if [[ -f $dir/manifest.json ]]; then
    published=$(json "$dir/manifest.json" 'd["version"]')
    newest=$(printf '%s\n%s\n' "$published" "$version" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n -k5,5n -k6,6n | tail -n 1)
    [[ $version != "$published" && $newest == "$version" ]] ||
        die "level $level: $version is not newer than the published $published (raise info.version in database.sqlite)"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/mw-publish-rules.XXXXXX")
[[ $dry_run -eq 1 ]] || trap 'rm -rf "$work"' EXIT

step "What changes (level $level: ${published:-nothing} → $version)"
counts() { sqlite3 "$1" "SELECT (SELECT count(*) FROM rules) || ' rules, ' || (SELECT count(*) FROM apps) || ' apps'"; }
if [[ -n $published && -f $dir/rules-$published.sqlite ]]; then
    before=$dir/rules-$published.sqlite
    info "published ($published): $(counts "$before")"
    sqlite3 "$database" "ATTACH '$before' AS b;
        SELECT '    + app ' || name || ' (' || bundle_id || ')' FROM apps WHERE bundle_id NOT IN (SELECT bundle_id FROM b.apps) LIMIT 40;
        SELECT '    - app ' || name || ' (' || bundle_id || ')' FROM b.apps WHERE bundle_id NOT IN (SELECT bundle_id FROM main.apps) LIMIT 40;"
fi
info "now ($version, ${commit:0:12}): $(counts "$database")"
confirm "Publish rules $version for level $level?" || die "cancelled"

step "Signing"
file=rules-$version.sqlite
# The published copy says its level, so an app of another level never takes it for its own.
cp "$database" "$work/$file"
sqlite3 "$work/$file" "INSERT OR REPLACE INTO info (key, value) VALUES ('level', '$level'); VACUUM;"
size=$(stat -f %z "$work/$file")
sha=$(shasum -a 256 "$work/$file" | cut -d' ' -f1)
printf 'mw-rules-v1\n%s\n%s\n%s\n%s' "$level" "$version" "$size" "$sha" >"$work/signed.txt"
signrules=(xcrun swift "$repo/Tools/SignRules/main.swift")
private=$(security find-generic-password -s "$rules_service" -a "$rules_account" -w 2>/dev/null) ||
    die "no rules key in the login keychain: run setup-keys.sh (or restore it from your backup)"
signature=$(printf '%s' "$private" | "${signrules[@]}" sign "$work/signed.txt")
unset private
"${signrules[@]}" verify "$work/signed.txt" "$signature" "$keys" ||
    die "the keychain key does not match MWRulesKeys in App/Info.plist: apps would refuse this database"
info "$file: $size bytes, sha256 $sha"

out=$updates
[[ $dry_run -eq 0 ]] || { out=$work/updates; mkdir -p "$out/rules"; [[ ! -f $updates/rules/index.json ]] || cp "$updates/rules/index.json" "$out/rules/"; }
step "Files ($out/rules)"
target=$out/rules/$level
rm -rf "$target"
mkdir -p "$target"
cp "$work/$file" "$target/$file"
n_rules=$(sqlite3 "$database" "SELECT count(*) FROM rules")
n_apps=$(sqlite3 "$database" "SELECT count(*) FROM apps")
python3 - "$target/manifest.json" "$out/rules/index.json" "$level" "$version" "$size" "$sha" "$file" "$commit" "$signature" "$target/info.json" "$n_rules" "$n_apps" <<'EOF'
import json, os, sys
manifest, index, level, version, size, sha, file, commit, signature, info, n_rules, n_apps = sys.argv[1:13]
json.dump({"level": int(level), "version": version, "size": int(size), "sha256": sha, "file": file,
           "source_commit": commit, "signature": signature}, open(manifest, "w"), indent=2)
# For people and pages only (not signed, the app never reads it): the counts.
json.dump({"version": version, "rules": int(n_rules), "apps": int(n_apps)}, open(info, "w"), indent=2)
levels = json.load(open(index))["levels"] if os.path.exists(index) else {}
levels[level] = version
json.dump({"levels": dict(sorted(levels.items(), key=lambda kv: int(kv[0])))}, open(index, "w"), indent=2)
EOF
info "rules/index.json: $(json "$out/rules/index.json" 'd["levels"]')"

if [[ $dry_run -eq 1 ]]; then
    warn "--dry-run: nothing committed or pushed; files in $out"
    exit 0
fi
python3 "$repo/Scripts/site/build.py" >/dev/null
step "Push"
commit_and_tag "Rules database $version (level $level)" "rules-v$version" updates/rules site
git_ push --quiet origin main "refs/tags/rules-v$version"
info "tag rules-v$version; apps fetch it at their next daily check"
