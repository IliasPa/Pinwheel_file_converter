#!/bin/bash
# Runs the automated tests (format rules, file naming, wheel math, conversions).
set -euo pipefail
source "$(dirname "$0")/common.sh"

cd "$ROOT"
swift test --scratch-path "$SCRATCH" "$@" 2>&1 | filter_toolchain_noise
