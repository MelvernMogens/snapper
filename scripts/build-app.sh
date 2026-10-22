#!/bin/bash
# Build Snapper.app: release build -> .app bundle -> ad-hoc codesign.
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications and launches)
#
# Signing note: ad-hoc signatures change every build, so macOS may ask for Screen Recording again
# after a rebuild. If it does: System Settings -> Privacy & Security -> Screen & System Audio Recording,
# remove Snapper with "-", relaunch, grant once.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Snapper"
APP="build/Snapper.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier com.melvern.snapper "$APP"
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Snapper || true
  rm -rf /Applications/Snapper.app
  cp -R "$APP" /Applications/
  open /Applications/Snapper.app
  echo "installed /Applications/Snapper.app"
fi
