#!/usr/bin/env bash
# Generate the Xcode project and build Immerse.app
# Usage: scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
DERIVED="build/DerivedData"

# If xcode-select hasn't been switched, find an Xcode automatically (no sudo needed)
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  if [[ -z "$XCODE_APP" ]]; then
    echo "❌ Xcode not found. Please install Xcode 16.2" >&2
    exit 1
  fi
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

# XcodeGen may be installed in ~/.local/bin (built from source)
export PATH="$HOME/.local/bin:$PATH"
command -v xcodegen >/dev/null || { echo "❌ xcodegen not found" >&2; exit 1; }

xcodegen generate --quiet
xcodebuild \
  -project Immerse.xcodeproj \
  -scheme Immerse \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  -quiet \
  build

echo "✅ $DERIVED/Build/Products/$CONFIG/Immerse.app"
