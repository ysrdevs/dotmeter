# What the app is called and how macOS knows it, for the build scripts. Sourced, not run.
#
# Resources/Info.plist is where the bundle's name, program and identifier are set, so they are read from there.
# The code keeps the same facts in Sources/DotmeterShared/AppIdentity.swift (the helper's trust is compiled in, not
# read at run time), and a build stops here if the two disagree.
PLIST="$ROOT/Resources/Info.plist"
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST")"
EXECUTABLE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST")"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
HELPER_ID="$BUNDLE_ID.helper"
HELPER_EXECUTABLE="${EXECUTABLE}Helper"
# What Swift Package Manager calls the two programs it builds. Internal; never shown to anyone.
PRODUCT="Dotmeter"
HELPER_PRODUCT="DotmeterHelper"

IDENTITY_SOURCE="$ROOT/Sources/DotmeterShared/AppIdentity.swift"
grep -q "static let name = \"$APP_NAME\"" "$IDENTITY_SOURCE" || { echo "✗ AppIdentity.swift does not name the app \"$APP_NAME\" as Info.plist does" >&2; exit 1; }
grep -q "static let bundleID = \"$BUNDLE_ID\"" "$IDENTITY_SOURCE" || { echo "✗ AppIdentity.swift does not carry the identifier $BUNDLE_ID as Info.plist does" >&2; exit 1; }

# Puts the two programs, the Info.plist and the helper's launchd description into a bundle at $1, from the build
# products in $2. The helper's description is written from a template, under the helper's own identifier.
assemble_bundle() {
  local app="$1" bin="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchDaemons"
  cp "$bin/$PRODUCT" "$app/Contents/MacOS/$EXECUTABLE"
  cp "$bin/$HELPER_PRODUCT" "$app/Contents/MacOS/$HELPER_EXECUTABLE"
  cp "$PLIST" "$app/Contents/Info.plist"
  sed -e "s/__HELPER_ID__/$HELPER_ID/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__HELPER_EXECUTABLE__/$HELPER_EXECUTABLE/g" \
    "$ROOT/Resources/helper.plist.in" > "$app/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
  [ ! -f "$ROOT/Resources/AppIcon.icns" ] || cp "$ROOT/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
  echo -n "APPL????" > "$app/Contents/PkgInfo"
}
