# Shared settings for the build scripts. Sourced, not run directly.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Build output goes outside the project folder: OneDrive adds hidden file
# attributes that make code signing fail, and there is no reason to sync it.
BUILD_ROOT="${PINWHEEL_BUILD_ROOT:-$HOME/Library/Developer/Pinwheel}"
SCRATCH="$BUILD_ROOT/.build"
APP="$BUILD_ROOT/Pinwheel.app"
BUNDLE_ID="com.iliasmac.Pinwheel"

# Name of the optional self-signed certificate (see README). With it, macOS
# remembers the Accessibility permission across rebuilds.
SIGN_IDENTITY_NAME="${PINWHEEL_SIGN_IDENTITY:-Pinwheel Local Signing}"

# Without Xcode, SwiftPM still adds Xcode-only XCTest folders to the linker
# search path and ld warns that they don't exist. It's harmless and not from
# our code, so hide exactly that line and nothing else.
filter_toolchain_noise() {
    grep --line-buffered -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/"
}
