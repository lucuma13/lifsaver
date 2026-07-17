#!/bin/bash
# Render the committed icon artwork from scripts/render/assets/:
#   scripts/release/app-resources/AppIcon.icns          — colour lifebuoy (Finder/Dock/About)
#   scripts/release/app-resources/MenuBarIcon*.png      — monochrome template icons (@1x/@2x/@3x)
#   scripts/release/app-resources/MenuBarIconAlert*.png — orange, turned 45°, for the stalled state
#
# Developer tool, not part of the build: the rendered outputs are committed
# (like the installer background), so this only needs re-running when a logo
# changes — and then both targets want regenerating together, or the menu bar
# and the Dock end up disagreeing.
#
# Usage: icons.sh [appicon|menubar|all]   (default: all)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

TARGET="${1:-all}"
case "$TARGET" in
appicon | menubar | all) ;;
*)
  echo "usage: $0 [appicon|menubar|all]" >&2
  exit 2
  ;;
esac

for tool in rsvg-convert magick; do
  command -v "$tool" >/dev/null || {
    echo "ERROR: $tool not found (brew install librsvg imagemagick)" >&2
    exit 1
  }
done
if [ "$TARGET" != "menubar" ]; then
  command -v iconutil >/dev/null || {
    echo "ERROR: iconutil not found" >&2
    exit 1
  }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_appicon() {
  local svg="$ROOT/scripts/render/assets/lifsaver_logo.svg"
  local out="$ROOT/scripts/release/app-resources/AppIcon.icns"
  local iconset="$TMP/AppIcon.iconset"
  mkdir -p "$iconset"

  # macOS icon grid: the artwork body is 824/1024 of the tile, centred, leaving
  # a transparent margin so the icon "floats" like every other app in the Dock
  # and Finder (the source SVG's rx=230 scales to ~185px at 824, the grid's
  # radius).
  # render <name> <tile-px>
  render() {
    local inner
    inner="$(awk "BEGIN{printf \"%d\", ($2*824/1024)+0.5}")"
    rsvg-convert -w "$inner" -h "$inner" "$svg" |
      magick - -background none -gravity center -extent "${2}x${2}" \
        +set date:create +set date:modify +set date:timestamp \
        -define png:exclude-chunk=tIME \
        "$iconset/$1"
  }
  render icon_16x16.png 16
  render icon_16x16@2x.png 32
  render icon_32x32.png 32
  render icon_32x32@2x.png 64
  render icon_128x128.png 128
  render icon_128x128@2x.png 256
  render icon_256x256.png 256
  render icon_256x256@2x.png 512
  render icon_512x512.png 512
  render icon_512x512@2x.png 1024

  mkdir -p "$(dirname "$out")"
  iconutil -c icns "$iconset" -o "$out"
  echo "Wrote $out"
}

make_menubar() {
  local svg="$ROOT/scripts/render/assets/lifsaver_logo_monochrome_alpha.svg"

  # The source SVG carries ~10% transparent padding on every side; left as-is
  # the buoy renders noticeably smaller than neighbouring menu-bar glyphs. We
  # trim the padding to the artwork's bounding box, then re-inset with a
  # uniform ~1px (@1x) margin so the icon fills the bar like the system's own.
  rsvg-convert -w 1024 -h 1024 "$svg" -o "$TMP/full.png"
  magick "$TMP/full.png" -trim +repage "$TMP/trim.png"

  # Alert artwork: the same buoy turned 45° (cross bands upright rather than
  # diagonal) and painted lifebuoy orange, used when a stalled volume needs
  # attention. Rotating here rather than at runtime is what keeps it crisp —
  # resampling an 18px bitmap through 45° is visibly soft. The buoy is round,
  # so the turn costs no size: 826px across upright, 828px at 45°. -rotate
  # needs -background none or it fills the corners opaque and -trim can no
  # longer find the artwork. -colorize repaints the ink while leaving alpha
  # alone; -alpha shape looks apt here but yields a fully transparent image.
  magick "$TMP/trim.png" -background none -rotate 45 -trim +repage "$TMP/rot.png"
  magick "$TMP/rot.png" -fill "#F15A2B" -colorize 100 "$TMP/alert.png"

  # src  tile-px  margin-px  -> content is (tile - 2*margin), centred on a square tile.
  # Strip the wall clock so identical artwork stays byte-identical and only
  # shows up in a diff when the pixels actually change. Both halves are load
  # bearing: +set drops the date:* properties, which PNG would otherwise write
  # as tEXt, and exclude-chunk drops the binary tIME chunk. Excluding the text
  # chunks instead just pushes ImageMagick to emit the same dates as zTXt.
  emit() {
    local src="$1" out="$2" tile="$3" margin="$4"
    local fit=$((tile - 2 * margin))
    magick "$src" -resize "${fit}x${fit}" \
      -background none -gravity center -extent "${tile}x${tile}" \
      +set date:create +set date:modify +set date:timestamp \
      -define png:exclude-chunk=tIME \
      "scripts/release/app-resources/$out"
    echo "Wrote scripts/release/app-resources/$out"
  }
  emit "$TMP/trim.png" MenuBarIcon.png 18 1
  emit "$TMP/trim.png" MenuBarIcon@2x.png 36 2
  emit "$TMP/trim.png" MenuBarIcon@3x.png 54 3
  emit "$TMP/alert.png" MenuBarIconAlert.png 18 1
  emit "$TMP/alert.png" MenuBarIconAlert@2x.png 36 2
  emit "$TMP/alert.png" MenuBarIconAlert@3x.png 54 3
}

[ "$TARGET" = "menubar" ] || make_appicon
[ "$TARGET" = "appicon" ] || make_menubar
