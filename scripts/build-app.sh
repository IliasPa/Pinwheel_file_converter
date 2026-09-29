#!/bin/bash
# Builds Pinwheel.app with the Swift Package Manager (no Xcode needed).
set -euo pipefail
source "$(dirname "$0")/common.sh"

CONFIG="${CONFIG:-release}"
cd "$ROOT"

echo "==> Compiling ($CONFIG). The first build takes a minute or two..."
swift build -c "$CONFIG" --scratch-path "$SCRATCH" 2>&1 | filter_toolchain_noise
BIN_DIR="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

echo "==> Assembling Pinwheel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Pinwheel" "$APP/Contents/MacOS/Pinwheel"
cp Support/Info.plist "$APP/Contents/Info.plist"
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY_NAME\""; then
    IDENTITY="$SIGN_IDENTITY_NAME"
    echo "==> Signing with your certificate \"$IDENTITY\""
else
    IDENTITY="-"
    echo "==> Signing to run locally (ad-hoc). See README to keep permissions across rebuilds."
fi
codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

echo "==> Done: $APP"
