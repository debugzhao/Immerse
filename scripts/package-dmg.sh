#!/usr/bin/env bash
# Build the Release version (universal arm64 + x86_64) and package it into a DMG
# Usage: scripts/package-dmg.sh   → dist/Immerse-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  [[ -n "$XCODE_APP" ]] || { echo "❌ Xcode not found. Please install Xcode 16.2" >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
export PATH="$HOME/.local/bin:$PATH"
command -v xcodegen >/dev/null || { echo "❌ xcodegen not found" >&2; exit 1; }

DERIVED="build/DerivedData"
xcodegen generate --quiet
# A generic destination + ONLY_ACTIVE_ARCH=NO is required to build both Apple silicon and Intel architectures
xcodebuild \
  -project Immerse.xcodeproj \
  -scheme Immerse \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  ONLY_ACTIVE_ARCH=NO \
  -quiet \
  build

APP="$DERIVED/Build/Products/Release/Immerse.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")

# No Developer ID certificate, so ad-hoc signing only; --deep signs embedded resources too
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

# The DMG holds the app + a shortcut to /Applications; just drag it in after opening to install
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Immerse-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Immerse $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "✅ $DMG"
lipo -archs "$APP/Contents/MacOS/Immerse"
