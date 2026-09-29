#!/bin/bash
# Runs the automated tests (format rules, file naming, wheel math, conversions).
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$ROOT"

# Without Xcode, SwiftPM sometimes forgets to tell the compiler where the
# Swift Testing macros live (the build then fails with "plugin for module
# 'TestingMacros' not found"). Passing the folder explicitly avoids that.
TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swift)")")"
TESTING_PLUGINS="$TOOLCHAIN/lib/swift/host/plugins/testing"
EXTRA=()
if [ -d "$TESTING_PLUGINS" ]; then
    EXTRA=(-Xswiftc -plugin-path -Xswiftc "$TESTING_PLUGINS")
fi

swift test --scratch-path "$SCRATCH" "${EXTRA[@]}" "$@" 2>&1 | filter_toolchain_noise
