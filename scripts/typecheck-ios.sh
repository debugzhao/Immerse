#!/usr/bin/env bash
# Type-check the iOS app and extension sources against the iOS 17 simulator SDK, without an installed simulator runtime.
# Builds ImmerseCore for iOS first, then runs `swiftc -typecheck` per target folder.
# Usage: scripts/typecheck-ios.sh [folder ...]   (default: ImmerseiOS ImmerseWidgets)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
TRIPLE=arm64-apple-ios17.0-simulator
SCRATCH=build/ImmerseKit-ios
swift build --package-path ImmerseKit --triple "$TRIPLE" --sdk "$SDK" --scratch-path "$SCRATCH" >/dev/null
MODULES="$SCRATCH/arm64-apple-ios-simulator/debug/Modules"

FOLDERS=("$@")
[[ ${#FOLDERS[@]} -gt 0 ]] || FOLDERS=(ImmerseiOS ImmerseWidgets)
for folder in "${FOLDERS[@]}"; do
  [[ -d "$folder" ]] || continue
  echo "▶ typecheck $folder"
  find "$folder" -name "*.swift" -print0 | xargs -0 xcrun swiftc -typecheck -parse-as-library \
    -target "$TRIPLE" -sdk "$SDK" -I "$MODULES" -module-name "$(basename "$folder")" \
    -swift-version 5 -strict-concurrency=complete -enable-upcoming-feature InferSendableFromCaptures
done
echo "✅ iOS sources type-check"
