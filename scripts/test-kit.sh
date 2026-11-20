#!/usr/bin/env bash
# Test the shared ImmerseKit package: run its tests on macOS, then compile it (and its tests) for the iOS 17 simulator.
# The iOS step uses `swift build` against the iPhoneSimulator SDK bundled with Xcode, so it works even when no
# iOS simulator runtime is installed (xcodebuild refuses iOS destinations until the platform is downloaded).
# Usage: scripts/test-kit.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  [[ -n "$XCODE_APP" ]] || { echo "❌ Xcode not found" >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
DEV_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"

echo "▶ ImmerseKit tests (macOS)"
# Through xcodebuild, not `swift test`: SwiftData traps with "Unable to determine Bundle Name" under the SwiftPM test runner
(cd ImmerseKit && xcodebuild -scheme ImmerseKit -destination 'platform=macOS' \
  -derivedDataPath ../build/ImmerseKit-mac -quiet test)

echo "▶ ImmerseKit build for iOS 17 simulator"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
FRAMEWORKS="$DEV_DIR/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks"
swift build --package-path ImmerseKit --build-tests \
  --triple arm64-apple-ios17.0-simulator --sdk "$SDK" \
  --scratch-path build/ImmerseKit-ios \
  -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS"

echo "✅ ImmerseKit passes on macOS and compiles for iOS"
