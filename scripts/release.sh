#!/bin/bash
# Builds Pinwheel.app and packs it for a GitHub release:
# ~/Library/Developer/Pinwheel/release/<version>/Pinwheel.zip
set -euo pipefail
source "$(dirname "$0")/common.sh"

"$ROOT/scripts/build-app.sh"

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")"
OUT="$BUILD_ROOT/release/$VERSION"
mkdir -p "$OUT"
ZIP="$OUT/Pinwheel.zip"
rm -f "$ZIP"
# ditto keeps the app's signature and attributes intact (zip doesn't).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "==> Pinwheel $VERSION: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"
echo "    The app: $(du -sh "$APP" | cut -f1 | tr -d ' ')"
echo "    SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
