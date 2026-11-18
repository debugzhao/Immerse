#!/usr/bin/env bash
# 生成 Xcode 工程并编译 Immerse.app
# 用法：scripts/build.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-Debug}"
DERIVED="build/DerivedData"

# 没用 xcode-select 切换时，自动找一份 Xcode（不需要 sudo）
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" | head -1)
  if [[ -z "$XCODE_APP" ]]; then
    echo "❌ 没找到 Xcode，请先安装 Xcode 16.2" >&2
    exit 1
  fi
  export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

# XcodeGen 可能装在 ~/.local/bin（从源码编译安装）
export PATH="$HOME/.local/bin:$PATH"
command -v xcodegen >/dev/null || { echo "❌ 没找到 xcodegen" >&2; exit 1; }

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
