#!/bin/bash
# Version and build of the 4D applications inside a DMG, read from their Info.plist
# (CFBundleShortVersionString "21.2 build 21.100624" -> 21.2 / 100624): the build is not in the DMG name.
# An image already mounted by the user is read in place and left mounted; an image mounted here is detached (dmg_mount.sh).
# Usage : bash dmg_info.sh <file.dmg>
# Output: one line per application: <name>\t<version>\t<build>\t<bundle id>\t<path in the image>
DMG="$1"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/version.sh" || exit 1
. "$HERE/dmg_mount.sh" || exit 1
[ -f "$DMG" ] || { echo "DMG not found: $DMG" >&2; exit 1; }
M="$(mktemp -d /tmp/ti4d_dmg.XXXXXX)"
trap 'dmg_detach; rmdir "$M" 2>/dev/null' EXIT
DMG_NOVERIFY=1 dmg_attach "$DMG" "$M" || { echo "Cannot mount $DMG: $DMG_ERR" >&2; exit 1; }
find "$DMG_MNT" -maxdepth 2 -name '*.app' -type d | sort | while IFS= read -r a; do
  p="$a/Contents/Info.plist"
  sv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$p" 2>/dev/null)"
  bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$p" 2>/dev/null)"
  b="$(version_build "$sv")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$a" .app)" "$(version_normalize "$sv")" "$b" "$bid" "${a#"$DMG_MNT"/}"
done
