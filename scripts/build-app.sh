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
    echo "==> Signing with your certificate \"$SIGN_IDENTITY_NAME\""
    # The first time, macOS asks whether codesign may use the certificate:
    # type your Mac password and click "Always Allow". That question can only
    # appear when the build runs in Terminal; elsewhere it fails, so fall back.
    if ! codesign --force --sign "$SIGN_IDENTITY_NAME" --identifier "$BUNDLE_ID" "$APP" 2>/dev/null; then
        echo "==> macOS didn't let codesign use \"$SIGN_IDENTITY_NAME\" yet."
        echo "    Run 'make install' in Terminal once and click \"Always Allow\"."
        echo "    Signing to run locally (ad-hoc) for now."
        codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
    fi
else
    echo "==> Signing to run locally (ad-hoc). See README to keep permissions across rebuilds."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --strict "$APP"

echo "==> Done: $APP"
