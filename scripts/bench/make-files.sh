#!/bin/bash
# Makes all of the bench's hard files, fresh, in one folder.
# Usage: scripts/bench/make-files.sh [folder]   (default: ~/Library/Developer/Pinwheel/bench/files)
set -euo pipefail
source "$(dirname "$0")/../common.sh"

OUT="${1:-$BUILD_ROOT/bench/files}"
rm -rf "$OUT"
mkdir -p "$OUT"
"$ROOT/scripts/bench/make-media.sh" "$OUT" 2>&1 | grep -v "^Svt"
swift "$ROOT/scripts/bench/make-pictures.swift" "$OUT"
I="$OUT/images"
cwebp -quiet -lossless "$I/soft-for-webp.png.tmp" -o "$I/lossless alpha.webp"
cwebp -quiet -q 75 "$I/soft-for-webp.png.tmp" -o "$I/lossy.webp"
img2webp -loop 0 -lossy -q 80 -d 100 "$I"/webp-frames.tmp/*.png -o "$I/animated.webp" >/dev/null
ffmpeg -hide_banner -loglevel error -y -i "$I/Ελληνικό όνομα 😀.png" -pix_fmt monob "$I/black and white 1bit.bmp"
ffmpeg -hide_banner -loglevel error -y -i "$I/soft-for-webp.png.tmp" -c:v png -pix_fmt pal8 "$I/indexed palette.png"
rm -rf "$I/soft-for-webp.png.tmp" "$I/webp-frames.tmp"
swift "$ROOT/scripts/bench/make-pdfs.swift" "$OUT"
swift "$ROOT/scripts/bench/make-office.swift" "$OUT"
echo "==> $(find "$OUT" -type f | wc -l | tr -d ' ') files in $OUT"
