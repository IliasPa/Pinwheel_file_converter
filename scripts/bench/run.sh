#!/bin/bash
# The bench: every format and tool on every hard file, each result looked
# at. Makes the files first if they aren't there, and uses the built app's
# own converter (make build). Takes a while; Pages, Keynote and Numbers open
# and close by themselves near the end.
#
#   scripts/bench/run.sh                         everything
#   PINWHEEL_BENCH_ONLY=images,pdf scripts/bench/run.sh    some folders (or file names)
#   PINWHEEL_BENCH_IWORK=0 scripts/bench/run.sh  without Pages, Keynote and Numbers
#
# The report: ~/Library/Developer/Pinwheel/bench/results/results.md
set -euo pipefail
source "$(dirname "$0")/../common.sh"

FILES="$BUILD_ROOT/bench/files"
[ -d "$FILES" ] || "$ROOT/scripts/bench/make-files.sh" "$FILES"
[ -x "$APP/Contents/MacOS/PinwheelWorker" ] || "$ROOT/scripts/build-app.sh"

# Like an app opened from the Dock: no locale settings from Terminal.
env -u LANG -u LC_ALL -u LC_CTYPE \
    PINWHEEL_BENCH="$FILES" \
    PINWHEEL_BENCH_OUT="$BUILD_ROOT/bench/results" \
    PINWHEEL_BENCH_WORKER="$APP/Contents/MacOS/PinwheelWorker" \
    "$ROOT/scripts/test.sh" --filter "Bench" "$@"
