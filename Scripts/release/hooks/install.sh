#!/bin/bash
# Installs the optional pre-push reminder (unpublished rules database) into this clone's .git/hooks. An existing
# pre-push hook is left alone.
set -euo pipefail
hooks=$(git rev-parse --git-path hooks)
target=$hooks/pre-push
if [[ -e $target && ! -L $target ]]; then
    echo "a pre-push hook already exists ($target): add a call to Scripts/release/hooks/pre-push to it by hand" >&2
    exit 1
fi
mkdir -p "$hooks"
ln -sfn "$(cd "$(dirname "$0")" && pwd)/pre-push" "$target"
echo "installed: $target"
