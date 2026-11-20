# shellcheck shell=bash
# Shared by publish-release.sh, publish-rules.sh, setup-keys.sh and virustotal.sh. Publications go to the repository itself: the update
# files live in `updates/` of `main` (the app reads them from raw.githubusercontent.com), the DMGs are GitHub release
# assets. Every publication is one commit on `main` and a tag, pushed to `origin`.

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
updates=$repo/updates
rules_service=com.ovvi.MacWashing.rules-signing
rules_account=ed25519

step() { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() {
    printf '\033[31merror:\033[0m %s\n' "$*" >&2
    exit 1
}

git_() { git -C "$repo" "$@"; }

# `owner/name` of the public repository (MW_REPOSITORY in project.yml).
repository() {
    sed -n -E 's/^ *MW_REPOSITORY: *"?([^" #]+)"? *(#.*)?$/\1/p' "$repo/project.yml" | head -n 1
}

# The tag must be new here and on origin: a rerun after a half-finished publication stops before any side effect.
tag_is_free() {
    local tag=$1
    ! git_ rev-parse -q --verify "refs/tags/$tag" >/dev/null || die "tag $tag already exists here (git tag -d $tag if it is a leftover)"
    [[ -z $(git_ ls-remote --tags origin "refs/tags/$tag") ]] || die "tag $tag already exists on origin"
}

# The commit a publication starts from: HEAD of `main`, clean and already on origin.
source_commit() {
    local head branch
    branch=$(git_ rev-parse --abbrev-ref HEAD)
    [[ $branch == main ]] || die "publish from main (now on $branch)"
    [[ -z $(git_ status --porcelain) ]] || die "the working tree has uncommitted changes: commit or stash them first"
    git_ fetch --quiet origin main
    head=$(git_ rev-parse HEAD)
    [[ $head == $(git_ rev-parse origin/main) ]] || die "HEAD ${head:0:12} is not origin/main: pull or push first"
    printf '%s' "$head"
}

# commit_and_tag <message> <tag> <paths...>: commits the given paths on main and tags the commit, locally.
commit_and_tag() {
    local message=$1 tag=$2
    shift 2
    git_ add -A -- "$@"
    git_ commit --quiet -m "$message" -- "$@"
    git_ tag "$tag"
}

# Info.plist value of the source app (one <string> after the key).
plist_value() {
    sed -n "/<key>$1<\/key>/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}" "$repo/App/Info.plist"
}

json() { # json <file> <python expression on `d`>
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

confirm() {
    [[ ${MW_YES:-0} == 1 ]] && return 0
    local answer
    read -r -p "$1 [y/N] " answer
    [[ $answer == y || $answer == Y ]]
}
