#!/bin/bash
# Assemble Lifsaver.app from the release build products:
#   Contents/MacOS/Lifsaver     — menu bar app
#   Contents/Helpers/lifsaver   — CLI (also symlinked onto PATH by the pkg)
# Ends with an ad-hoc re-sign: Apple Silicon refuses to execute unsigned
# Mach-O code, and mutating the bundle invalidates any prior seal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="$("$ROOT/scripts/version.sh")"

BIN_PATH="$ROOT/.build/universal-release"
[ -x "$BIN_PATH/LifsaverApp" ] || {
  echo "ERROR: run scripts/release/build.sh first" >&2
  exit 1
}

APP="$ROOT/dist/Lifsaver.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"

cp "$BIN_PATH/LifsaverApp" "$APP/Contents/MacOS/Lifsaver"
cp "$BIN_PATH/lifsaver" "$APP/Contents/Helpers/lifsaver"
chmod 755 "$APP/Contents/MacOS/Lifsaver" "$APP/Contents/Helpers/lifsaver"

# Menu-bar icons (loose @1x/@2x/@3x PNG files; NSImage(named:) resolves them):
# the monochrome template plus the orange alert variant for stalled volumes.
SRC_RESOURCES="scripts/release/app-resources"
cp "$SRC_RESOURCES/MenuBarIcon.png" "$SRC_RESOURCES/MenuBarIcon@2x.png" \
  "$SRC_RESOURCES/MenuBarIcon@3x.png" "$SRC_RESOURCES/MenuBarIconAlert.png" \
  "$SRC_RESOURCES/MenuBarIconAlert@2x.png" "$SRC_RESOURCES/MenuBarIconAlert@3x.png" \
  "$APP/Contents/Resources/"

# Colour app icon (Finder/Dock/About), pre-rendered and committed; regenerate
# with scripts/render/icons.sh when the logo changes.
[ -f "$SRC_RESOURCES/AppIcon.icns" ] || {
  echo "ERROR: $SRC_RESOURCES/AppIcon.icns missing — run scripts/render/icons.sh" >&2
  exit 1
}
cp "$SRC_RESOURCES/AppIcon.icns" "$APP/Contents/Resources/"

sed "s/__VERSION__/$VERSION/g" scripts/release/templates/template_Info.plist >"$APP/Contents/Info.plist"
printf 'APPL????' >"$APP/Contents/PkgInfo"

# Ad-hoc signing: helper first, then the bundle (inside-out).
codesign --force -s - "$APP/Contents/Helpers/lifsaver"
codesign --force -s - "$APP"

echo "Assembled $APP (version $VERSION)"
codesign --verify --strict "$APP" && echo "codesign: OK"
