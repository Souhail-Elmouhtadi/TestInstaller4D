#!/bin/bash
# Regenerates the application icon from its vector source macOS-app/AppIconArt.swift (also drawn in the header):
#   bash make_icon.sh            -> ../AppIcon.icns (16 to 1024 px, simplified drawing below 48 px)
#                                   + AppIcon_1024.png (preview)
#   bash make_icon.sh <out.icns> -> only that file (tests)
# build_dmg.sh copies AppIcon.icns into the app: run this script after changing AppIconArt.swift.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APPDIR="$(dirname "$HERE")"
OUT="${1:-$APPDIR/AppIcon.icns}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -parse-as-library -o "$TMP/make_icon" "$APPDIR/Core.swift" "$APPDIR/AppIconArt.swift" "$HERE/make_icon.swift"
"$TMP/make_icon" "$TMP/AppIcon.iconset"
iconutil -c icns -o "$OUT" "$TMP/AppIcon.iconset"
[ $# -eq 0 ] && cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" "$HERE/AppIcon_1024.png"
echo "$OUT"
