#!/usr/bin/env bash
# 编译 Release 版（arm64 + x86_64 通用包）并打包成 DMG
# 用法：scripts/package-dmg.sh   → dist/Immerse-<版本号>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  [[ -n "$XCODE_APP" ]] || { echo "❌ 没找到 Xcode，请先安装 Xcode 16.2" >&2; exit 1; }
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi
export PATH="$HOME/.local/bin:$PATH"
command -v xcodegen >/dev/null || { echo "❌ 没找到 xcodegen" >&2; exit 1; }

DERIVED="build/DerivedData"
xcodegen generate --quiet
# generic destination + ONLY_ACTIVE_ARCH=NO 才会同时编出 Apple 芯片和 Intel 两种架构
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

# 没有 Developer ID 证书，只能 ad-hoc 签名；--deep 保证内嵌资源一起签上
codesign --force --deep --options runtime --sign - "$APP"
codesign --verify --deep --strict "$APP"

# DMG 内放 App + 指向 /Applications 的快捷方式，打开后拖进去即可安装
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
