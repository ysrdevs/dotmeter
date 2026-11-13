#!/bin/zsh
# Builds dist/Dotmeter-<version>.dmg for other Macs: a universal app signed with Developer ID and the hardened
# runtime, in a laid-out install image, notarized by Apple and stapled.
#
# Usage: Scripts/package.sh [--skip-notarize]
#
# Needs, once per Mac that packages:
#   - a "Developer ID Application" certificate in the keychain
#   - notarization credentials saved in the keychain as a notarytool profile. The default name is
#     "dotmeter-notary"; NOTARY_PROFILE=<name>, in the environment or in Scripts/local.env, picks another.
#     To save one on a new Mac:
#       xcrun notarytool store-credentials <name> --apple-id <your Apple ID> --team-id <team id>
#     (it asks for an app-specific password from account.apple.com and keeps it in the keychain)
# Without the profile the image is still built and signed, just not notarized, and the script says so.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/Scripts/identity.sh"
VOLUME="$APP_NAME"
# A profile name that belongs to one Mac goes in Scripts/local.env (not kept in the repository), as
# NOTARY_PROFILE=<name>; the environment can set it too.
[ ! -f "$ROOT/Scripts/local.env" ] || source "$ROOT/Scripts/local.env"
PROFILE="${NOTARY_PROFILE:-dotmeter-notary}"
NOTARIZE=1
for arg in "$@"; do
  case "$arg" in
    --skip-notarize) NOTARIZE=0 ;;
  esac
done

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
DIST="$ROOT/dist"
WORK="$DIST/work"
APP="$WORK/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"
MOUNT="/Volumes/$VOLUME"

die() { echo "✗ $1" >&2; exit 1; }

IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 'Developer ID Application' | sed -E 's/.*"(.*)"/\1/' || true)"
fi
[ -n "$IDENTITY" ] || die "No Developer ID Application certificate in the keychain. Create one in Xcode: Settings, Accounts, Manage Certificates."

# Ask Apple something small first. Saved credentials can be fine and the request still refused, for instance
# when the developer account has an agreement waiting to be accepted, so the reason is printed as Apple gave it.
# The service has been seen to refuse one request and take the next while such a change settles, so every step
# that talks to it is tried several times before giving up.
if [ "$NOTARIZE" = "1" ]; then
  READY=0
  CHECK=""
  for attempt in 1 2 3 4 5 6 7 8; do
    if CHECK="$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1)"; then READY=1; break; fi
    sleep 15
  done
  if [ "$READY" = "0" ]; then
    echo "! Apple would not take a notarization request with the profile \"$PROFILE\". Building a signed image without notarizing it."
    echo "  Apple's answer: $(echo "$CHECK" | grep -m1 -iE 'error|status' | cut -c1-220)"
    NOTARIZE=0
    MISSING_PROFILE=1
  fi
fi

# Sends one file to Apple and waits for the verdict. Prints the log when it is refused.
notarize() {
  local file="$1" out="" id="" verdict="" attempt
  echo "▸ notarizing $(basename "$file") (usually a few minutes)"
  for attempt in 1 2 3 4 5 6 7 8; do
    if out="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" 2>&1)"; then
      id="$(echo "$out" | grep -m1 '  id:' | awk '{print $2}')"
    fi
    [ -n "$id" ] && break
    echo "  the submission was refused, trying again ($attempt of 8)"
    sleep 20
  done
  [ -n "$id" ] || { echo "$out"; die "Apple did not take $(basename "$file")"; }
  # Up to half an hour, asking every fifteen seconds; a refused question is simply asked again.
  for attempt in $(seq 1 120); do
    if out="$(xcrun notarytool info "$id" --keychain-profile "$PROFILE" 2>&1)"; then
      verdict="$(echo "$out" | grep -m1 'status:' | sed -E 's/.*status: //')"
      case "$verdict" in Accepted|Invalid|Rejected) break ;; esac
    fi
    sleep 15
  done
  if [ "$verdict" != "Accepted" ]; then
    echo "$out"
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" || true
    die "Apple did not accept $(basename "$file") (status: ${verdict:-no answer})"
  fi
  echo "✓ accepted"
}

rm -rf "$WORK"
mkdir -p "$WORK"

echo "▸ swift build (release, Apple silicon + Intel)"
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" 2>&1 | grep -E "error|warning: unre|Build complete" || true
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT" --show-bin-path)"
[ -x "$BIN_DIR/$PRODUCT" ] || die "build failed"
[ -x "$BIN_DIR/$HELPER_PRODUCT" ] || die "helper was not built"

# The app's program, and the uninstall helper beside it with the description launchd reads to start it on request.
assemble_bundle "$APP" "$BIN_DIR"

echo "▸ codesign with: $IDENTITY"
# Hardened runtime and a secure timestamp are what notarization requires. One entitlement: sending Apple events,
# for asking the Finder to move an app to the Trash.
# The helper is signed first, under its own identifier, with no entitlements: the app and the helper each check
# the other's signature before saying a word.
codesign --force --options runtime --timestamp --identifier "$HELPER_ID" --sign "$IDENTITY" "$APP/Contents/MacOS/$HELPER_EXECUTABLE"
codesign --force --options runtime --timestamp --entitlements "$ROOT/Resources/App.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP" 2>&1 | tail -2

if [ "$NOTARIZE" = "1" ]; then
  # The app first, so the copy people drag out of the image carries its own ticket and opens offline.
  ditto -c -k --keepParent "$APP" "$WORK/$APP_NAME.zip"
  notarize "$WORK/$APP_NAME.zip"
  xcrun stapler staple "$APP" | tail -1
fi

echo "▸ building the install image"
[ ! -e "$MOUNT" ] || die "$MOUNT is already mounted. Eject it and run this again."
RW="$WORK/rw.dmg"
hdiutil create -size 64m -fs HFS+ -volname "$VOLUME" -type UDIF -layout SPUD -ov -quiet "$RW"
hdiutil attach "$RW" -nobrowse -noautoopen -quiet
[ -d "$MOUNT" ] || die "the image did not mount at $MOUNT"
trap 'hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true' EXIT

ditto "$APP" "$MOUNT/$APP_NAME.app"
ln -s /Applications "$MOUNT/Applications"

swift "$ROOT/Scripts/make-dmg-background.swift" "$WORK/background" --name "$APP_NAME" --version "$VERSION" >/dev/null
tiffutil -cathidpicheck "$WORK/background/background.png" "$WORK/background/background@2x.png" -out "$MOUNT/.background.tiff" >/dev/null 2>&1

cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
xcrun SetFile -a C "$MOUNT" 2>/dev/null || true

# Window 640 x 460 plus the title bar; positions are icon centres. Keep in step with make-dmg-background.swift.
swift "$ROOT/Scripts/make-dmg-layout.swift" "$MOUNT" .background.tiff 640 488 112 "$APP_NAME.app=178,264" "Applications=462,264"

rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes" 2>/dev/null || true
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" -quiet
trap - EXIT

rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = "1" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG" | tail -1
  echo "▸ Gatekeeper check"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG" 2>&1 | tail -2
fi

rm -rf "$WORK"
echo "✓ $DMG ($(du -h "$DMG" | awk '{print $1}'))"
if [ "${MISSING_PROFILE:-0}" = "1" ]; then
  echo "! Not notarized: other Macs will refuse to open it until it is. Save credentials once, then run this again:"
  echo "    xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id $(echo "$IDENTITY" | sed -E 's/.*\((.*)\)/\1/')"
fi
