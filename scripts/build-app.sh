#!/bin/bash
# Build Snapper.app: release build -> .app bundle -> ad-hoc codesign.
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications and launches)
#
# Signing: uses the local self-signed identity in ~/.snapper-signing (scripts/make-signing-identity.sh) so the
# code signature's designated requirement stays the same across rebuilds and macOS keeps the Screen Recording
# grant. Falls back to ad-hoc (grant resets on every rebuild) when the identity is missing.
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

KC="$HOME/.snapper-signing/snapper.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HOME/.snapper-signing/pass")" "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Snapper Local Signing/ {print $2; exit}')
  codesign --force --sign "$ID" --keychain "$KC" --identifier com.melvern.snapper "$APP"
else
  echo "warning: no local signing identity, using ad-hoc (Screen Recording grant will reset)"
  codesign --force --sign - --identifier com.melvern.snapper "$APP"
fi
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Snapper || true
  rm -rf /Applications/Snapper.app
  cp -R "$APP" /Applications/
  open /Applications/Snapper.app
  echo "installed /Applications/Snapper.app"
fi
