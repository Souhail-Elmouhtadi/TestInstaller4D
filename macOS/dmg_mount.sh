#!/bin/bash
# Disk image helpers shared by the kit (sourced).
# An image already attached by the user is reused as is and never detached; an image attached here is
# detached by dmg_detach (only its own device), including on failure (call it from an EXIT trap).
# dmg_attach <file.dmg> <mount point> sets DMG_MNT, DMG_DEV, DMG_OWN (1 = attached here, 0 = user's mount)
# and DMG_ERR (message when it fails).
# DMG_NOVERIFY=1: no checksum verification at attach (quick reading of the version; the test verifies the image).
# DMG_BROWSE=1: attached as a double-click would (visible in Finder, mounted under /Volumes) for the window check.

dmg_realpath() {
  local d
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$d" "$(basename "$1")"
}

# Prints "<whole disk dev>\t<mount point>" for an attached image whose image-path is the given file.
dmg_find_attached() {
  local want p i=0 j dev mp first plist
  want="$(dmg_realpath "$1")" || return 1
  plist="$(mktemp /tmp/ti4d_info.XXXXXX)" || return 1
  hdiutil info -plist > "$plist" 2>/dev/null || { rm -f "$plist"; return 1; }
  while p="$(plutil -extract "images.$i.image-path" raw -o - "$plist" 2>/dev/null)"; do
    if [ "$(dmg_realpath "$p" 2>/dev/null)" = "$want" ]; then
      j=0; first=""; mp=""
      while dev="$(plutil -extract "images.$i.system-entities.$j.dev-entry" raw -o - "$plist" 2>/dev/null)"; do
        [ -n "$first" ] || first="$dev"
        [ -n "$mp" ] || mp="$(plutil -extract "images.$i.system-entities.$j.mount-point" raw -o - "$plist" 2>/dev/null)"
        j=$((j+1))
      done
      rm -f "$plist"
      printf '%s\t%s\n' "${first%s[0-9]*}" "$mp"
      return 0
    fi
    i=$((i+1))
  done
  rm -f "$plist"
  return 1
}

dmg_attach() {
  local dmg="$1" mp="$2" found out err j dev m
  DMG_MNT=""; DMG_DEV=""; DMG_OWN=0; DMG_ERR=""
  if found="$(dmg_find_attached "$dmg")"; then
    DMG_DEV="${found%%$'\t'*}"; DMG_MNT="${found#*$'\t'}"
    if [ -n "$DMG_MNT" ] && [ -d "$DMG_MNT" ]; then return 0; fi
    DMG_ERR="image already attached by the user ($DMG_DEV) but without a mounted volume"
    return 1
  fi
  local where=(-nobrowse -mountpoint "$mp")
  if [ "${DMG_BROWSE:-0}" = 1 ]; then where=()
  else
    mkdir -p "$mp" || { DMG_ERR="cannot create the mount point $mp"; return 1; }
    # A leftover of an interrupted run of the kit on its own mount point.
    if grep -qF " on $(cd "$mp" && pwd -P) (" <<< "$(mount)"; then hdiutil detach "$mp" -force >/dev/null 2>&1; fi
  fi
  out="$(mktemp /tmp/ti4d_attach.XXXXXX)"; err="$(mktemp /tmp/ti4d_attach_err.XXXXXX)"
  # "yes" accepts a licence agreement, if the image has one (same as a double-click in Finder).
  if ! yes 2>/dev/null | hdiutil attach ${where[@]+"${where[@]}"} -readonly -noautoopen ${DMG_NOVERIFY:+-noverify} -plist "$dmg" > "$out" 2> "$err"; then
    DMG_ERR="$(grep -v 'deprecated' "$err" | tr '\n' ' ' | sed 's/ *$//')"
    [ -n "$DMG_ERR" ] || DMG_ERR="hdiutil attach failed"
    rm -f "$out" "$err"
    return 1
  fi
  j=0
  while dev="$(plutil -extract "system-entities.$j.dev-entry" raw -o - "$out" 2>/dev/null)"; do
    [ -n "$DMG_DEV" ] || DMG_DEV="${dev%s[0-9]*}"
    m="$(plutil -extract "system-entities.$j.mount-point" raw -o - "$out" 2>/dev/null)"
    [ -n "$m" ] && [ -z "$DMG_MNT" ] && DMG_MNT="$m"
    j=$((j+1))
  done
  rm -f "$out" "$err"
  DMG_OWN=1
  [ -n "$DMG_MNT" ] || [ "${DMG_BROWSE:-0}" = 1 ] || DMG_MNT="$mp"
  [ -d "$DMG_MNT" ] || { DMG_ERR="no volume mounted from the image"; dmg_detach; return 1; }
  return 0
}

# Detaches only an image attached by dmg_attach. Returns 1 if it is still attached.
dmg_detach() {
  local i=0
  [ "${DMG_OWN:-0}" = 1 ] && [ -n "$DMG_DEV" ] || return 0
  while [ $i -lt 3 ]; do
    diskutil eject "$DMG_DEV" >/dev/null 2>&1 || hdiutil detach "$DMG_DEV" >/dev/null 2>&1 || hdiutil detach "$DMG_DEV" -force >/dev/null 2>&1
    if ! grep -qE "^${DMG_DEV}([[:space:]]|s[0-9])" <<< "$(hdiutil info 2>/dev/null)"; then
      [ -n "$DMG_MNT" ] && [ "${DMG_BROWSE:-0}" != 1 ] && rmdir "$DMG_MNT" 2>/dev/null
      DMG_OWN=0; DMG_DEV=""
      return 0
    fi
    sleep 2; i=$((i+1))
  done
  return 1
}
