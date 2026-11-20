#!/usr/bin/env bash
# Launch the iOS app in the simulator with sample data and save a screenshot of one screen.
# Usage: scripts/ios-screenshot.sh <output.png> [KEY=VALUE ...]   e.g. IMMERSE_TAB=planning IMMERSE_SHEET=capture
# Keys are passed to the app (see AppModel.applyScreenshotScene). Uses the booted simulator.
set -euo pipefail
OUT=$1; shift
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Users/tyson/Downloads/Xcode.app/Contents/Developer}
xcrun simctl terminate booted com.debugzhao.immerse >/dev/null 2>&1 || true
ENVS=(SIMCTL_CHILD_IMMERSE_SNAPSHOT=1)
for pair in "$@"; do ENVS+=("SIMCTL_CHILD_$pair"); done
env "${ENVS[@]}" xcrun simctl launch booted com.debugzhao.immerse >/dev/null
sleep "${WAIT:-3}"
xcrun simctl io booted screenshot "$OUT" >/dev/null
echo "✅ $OUT"
