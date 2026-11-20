#!/bin/bash
# Renders background.svg into background.tiff (640 × 420 and its 2x in one file, as Finder wants for Retina).
# Needs rsvg-convert (brew install librsvg). Run after changing the SVG; the .tiff is committed.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
rsvg-convert -w 640 -h 420 background.svg -o "$tmp/background.png"
rsvg-convert -w 1280 -h 840 background.svg -o "$tmp/background@2x.png"
tiffutil -cathidpicheck "$tmp/background.png" "$tmp/background@2x.png" -out background.tiff
echo "background.tiff: $(du -h background.tiff | cut -f1)"
