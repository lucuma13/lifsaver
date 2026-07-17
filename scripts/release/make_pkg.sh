#!/bin/bash
# Produce the release artifacts from an assembled dist/Lifsaver.app:
#   dist/lifsaver_installer_macos.pkg            — unsigned installer
#   dist/lifsaver-<version>-macos-universal.zip  — app zip for the Homebrew cask
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

VERSION="$("$ROOT/scripts/version.sh")"
APP="$ROOT/dist/Lifsaver.app"
[ -d "$APP" ] || {
  echo "ERROR: run scripts/release/bundle_app.sh first" >&2
  exit 1
}

PKGROOT="$ROOT/dist/pkgroot"
rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Applications"
cp -R "$APP" "$PKGROOT/Applications/"

chmod 755 scripts/release/installer-scripts/postinstall

pkgbuild \
  --root "$PKGROOT" \
  --scripts scripts/release/installer-scripts \
  --identifier com.lucuma13.lifsaver \
  --version "$VERSION" \
  --install-location / \
  "dist/lifsaver-component.pkg"

# productbuild wraps the component so Installer.app titles the window from
# distribution.xml rather than the filename.
sed "s/__VERSION__/$VERSION/g" scripts/release/templates/template_distribution.xml >dist/distribution.xml
productbuild \
  --distribution dist/distribution.xml \
  --package-path dist \
  --resources scripts/release/installer-resources \
  "dist/lifsaver_installer_macos.pkg"
rm -rf "$PKGROOT" "dist/lifsaver-component.pkg" "dist/distribution.xml"

ditto -c -k --keepParent "$APP" "dist/lifsaver-$VERSION-macos-universal.zip"

echo "Artifacts:"
ls -la dist/*.pkg dist/*.zip
shasum -a 256 dist/*.pkg dist/*.zip
