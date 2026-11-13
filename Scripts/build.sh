#!/bin/zsh
# Builds the app into ./build. Usage: Scripts/build.sh [debug|release] [--install] [--run]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
INSTALL=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    debug|release) CONFIG="$arg" ;;
    --install) INSTALL=1 ;;
    --run) RUN=1 ;;
  esac
done

source "$ROOT/Scripts/identity.sh"
echo "▸ swift build ($CONFIG)"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN_DIR="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)"
APP="$ROOT/build/$APP_NAME.app"

rm -rf "$APP"
# The app's program, and the uninstall helper beside it with the description launchd reads to start it on request.
assemble_bundle "$APP" "$BIN_DIR"

# Prefer a stable Apple Development identity so Keychain access survives rebuilds.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Apple Development' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
if [ -n "$IDENTITY" ]; then
  echo "▸ codesign with: $IDENTITY"
  # The helper first, under its own identifier: the app and the helper each check the other's signature.
  codesign --force --sign "$IDENTITY" --timestamp=none --identifier "$HELPER_ID" "$APP/Contents/MacOS/$HELPER_EXECUTABLE"
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
  echo "▸ codesign ad-hoc"
  codesign --force --sign - --identifier "$HELPER_ID" "$APP/Contents/MacOS/$HELPER_EXECUTABLE"
  codesign --force --sign - "$APP"
fi
echo "✓ Built $APP"

if [ "$INSTALL" = "1" ]; then
  echo "▸ Installing to /Applications"
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" "/Applications/$APP_NAME.app"
  APP="/Applications/$APP_NAME.app"
fi

if [ "$RUN" = "1" ]; then
  pkill -x "$EXECUTABLE" 2>/dev/null || true
  sleep 0.3
  open "$APP"
  echo "✓ Launched"
fi
