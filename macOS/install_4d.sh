#!/bin/bash
# Installs the selected 4D product from a downloaded DMG, then verifies the installed application.
# Usage: bash install_4d.sh --dmg <file.dmg> --product <4D|4D Server|4D Volume Desktop> --version <21.2>
#          --build <100629> --platform <"macOS ARM"|"macOS Intel"> [--dest /Applications] [--state <file>]
#          [--replace | --adopt]
#   --replace  an existing installation is moved to the Trash once the new copy is in place (confirmed by the user)
#   --adopt    an existing installation of exactly the selected version/build is verified and used as is
# Never picks another version: the DMG must contain the selected product, version, build and architecture.
# Never asks for nor stores a password: when the destination is not writable, macOS asks for an administrator
# (osascript "with administrator privileges"). Images attached here are always detached (also on failure);
# an image already mounted by the user is used as is and left mounted.
# Output, one event per line (tab separated):
#   STEP <text> | PROGRESS <0-100> <text> | INFO <key> <value> | EXISTS <path> <version> <build> <same|different>
#   ERROR <CODE> <text> | RESULT <ok|ko> <installed app path>
#   CODE: ARGS INCOMPLETE CORRUPT ORIGIN MOUNT PRODUCT VERSION ARCH SIGNATURE SPACE DENIED ADMIN COPY VERIFY
# Exit: 0 installed and verified, 3 an installation exists (confirmation needed), 1 error.
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/version.sh" || exit 1
. "$KIT/dmg_mount.sh" || exit 1
PB=/usr/libexec/PlistBuddy
EXPECTED_TEAM="${EXPECTED_TEAM:-37UG5W39Z2}" # 4D SAS
DEST=/Applications; STATE="$HOME/4DQA_mac/install_state.tsv"; MODE=install
DMG=""; PRODUCT=""; VERSION=""; BUILD=""; PLATFORM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) DMG="$2"; shift;; --product) PRODUCT="$2"; shift;; --version) VERSION="$2"; shift;;
    --build) BUILD="$2"; shift;; --platform) PLATFORM="$2"; shift;; --dest) DEST="$2"; shift;;
    --state) STATE="$2"; shift;; --replace) MODE=replace;; --adopt) MODE=adopt;;
    *) printf 'ERROR\tARGS\tunknown argument %s\n' "$1"; exit 1;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
step() { printf 'STEP\t%s\n' "$1"; }
progress() { printf 'PROGRESS\t%s\t%s\n' "$1" "$2"; }
info() { printf 'INFO\t%s\t%s\n' "$1" "$2"; }
STATE_ROWS=()
st() { STATE_ROWS+=("$1"$'\t'"$(printf '%s' "$2" | tr '\t\n' '  ')"); }
write_state() { # status [error code] [message]
  local d tmp r
  d="$(dirname "$STATE")"; mkdir -p "$d" || return 1
  tmp="$(mktemp "$d/.install_state.XXXXXX")" || return 1
  {
    printf 'STATUS\t%s\n' "$1"
    printf 'DATE\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    [ -n "$2" ] && printf 'ERROR_CODE\t%s\n' "$2"
    [ -n "$3" ] && printf 'ERROR\t%s\n' "$(printf '%s' "$3" | tr '\t\n' '  ')"
    for r in "${STATE_ROWS[@]}"; do printf '%s\n' "$r"; done
  } > "$tmp" && mv -f "$tmp" "$STATE"
}
FAILED=""
fail() { # CODE message
  FAILED="$1"
  printf 'ERROR\t%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')"
  write_state ko "$1" "$2"
  printf 'RESULT\tko\t%s\n' "${TARGET_APP:-}"
  exit 1
}

# ---------- cleanup: own staging copy and own disk image only ----------
STAGE=""; OLD=""; MOVED=(); PLACED=(); STAMP=""; CREATED_DIR=""; cp_pid=""
cleanup() {
  local i fd
  [ -n "$cp_pid" ] && kill "$cp_pid" 2>/dev/null && wait "$cp_pid" 2>/dev/null
  if [ -n "$FAILED" ] && [ ${#PLACED[@]} -gt 0 ]; then
    # failure after the new copy was put in place: the copy made by this run is removed
    fd="$TARGET_DIR/.ti4d-install-$STAMP-failed"
    mkdir -p "$fd" 2>/dev/null && for i in "${PLACED[@]}"; do [ -e "$TARGET_DIR/$i" ] && mv "$TARGET_DIR/$i" "$fd/" 2>/dev/null; done
    rm -rf "$fd" 2>/dev/null
  fi
  if [ -n "$FAILED" ] && [ ${#MOVED[@]} -gt 0 ]; then
    # the previous installation is put back
    for i in "${MOVED[@]}"; do [ ! -e "$TARGET_DIR/$i" ] && mv "$OLD/$i" "$TARGET_DIR/$i" 2>/dev/null; done
  fi
  [ -n "$OLD" ] && rmdir "$OLD" 2>/dev/null
  # STAGE only contains the copy made by this run
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && case "$STAGE" in */.ti4d-install-*) rm -rf "$STAGE" 2>/dev/null;; esac
  [ -n "$FAILED" ] && [ -n "$CREATED_DIR" ] && rmdir "$CREATED_DIR" 2>/dev/null
  if ! dmg_detach; then printf 'INFO\tWARNING\tthe disk image %s could not be detached: eject it in Finder\n' "$DMG_DEV"; fi
}
trap cleanup EXIT
trap 'FAILED=INTERRUPTED; exit 130' INT TERM HUP

[ -n "$DMG" ] && [ -n "$PRODUCT" ] || { FAILED=ARGS; printf 'ERROR\tARGS\t--dmg and --product are required\n'; exit 1; }
case "$PRODUCT" in "4D"|"4D Server"|"4D Volume Desktop") ;; *) FAILED=ARGS; printf 'ERROR\tARGS\tunknown product %s\n' "$PRODUCT"; exit 1;; esac
[ -n "$VERSION" ] && [ -n "$BUILD" ] || { FAILED=ARGS; printf 'ERROR\tARGS\tversion and build must be selected before installing (no version is chosen automatically)\n'; exit 1; }
VERSION="$(version_normalize "$VERSION")"
case "$PLATFORM" in *Intel*) WANT_ARCH=x86_64;; *ARM*|*arm*) WANT_ARCH=arm64;; *) WANT_ARCH="";; esac
st PRODUCT "$PRODUCT"; st VERSION "$VERSION"; st BUILD "$BUILD"; st PLATFORM "$PLATFORM"; st DMG "$DMG"; st DEST "$DEST"; st MODE "$MODE"

# ---------- 1. downloaded file ----------
step "Vérification du fichier téléchargé"
progress 2 "Vérification du fichier téléchargé"
[ -e "$DMG" ] || fail INCOMPLETE "file not found: $DMG"
[ -f "$DMG" ] || fail INCOMPLETE "not a file: $DMG"
case "$DMG" in *.download|*.crdownload|*.part|*.partial) fail INCOMPLETE "download in progress (temporary file): $DMG";; esac
for x in download crdownload part partial; do [ -e "$DMG.$x" ] && fail INCOMPLETE "download still in progress: $DMG.$x exists"; done
S1=$(stat -f%z "$DMG")
[ "$S1" -gt 0 ] || fail INCOMPLETE "empty file (0 byte): $DMG"
sleep "${INSTALL_SETTLE:-2}"
S2=$(stat -f%z "$DMG")
[ "$S1" = "$S2" ] || fail INCOMPLETE "the file is still growing ($S1 -> $S2 bytes): wait for the end of the download"
st DMG_SIZE "$S2"; info DMG_SIZE "$S2"
# origin recorded by the browser (kMDItemWhereFroms): only *.4d.com is accepted
WF="$(xattr -px com.apple.metadata:kMDItemWhereFroms "$DMG" 2>/dev/null | xxd -r -p 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null | sed -n 's:.*<string>\(.*\)</string>.*:\1:p')"
host_of() { printf '%s' "$1" | sed -nE 's#^[A-Za-z]+://([^/:?@]*@)?([^/:?]+).*#\2#p' | tr 'A-Z' 'a-z'; }
official() { case "$1" in 4d.com|*.4d.com) return 0;; *) return 1;; esac; }
if [ -n "$WF" ]; then
  first="$(printf '%s\n' "$WF" | head -1)"; h="$(host_of "$first")"
  official "$h" || fail ORIGIN "downloaded from $h, not from an official *.4d.com address"
  hosts="$(printf '%s\n' "$WF" | while IFS= read -r u; do host_of "$u"; echo; done | grep . | sort -u | tr '\n' ' ' | sed 's/ $//')"
  for h in $hosts; do official "$h" || fail ORIGIN "download page $h is not an official *.4d.com address"; done
  st ORIGIN "$hosts"; info ORIGIN "$hosts"
else
  st ORIGIN "unknown (no download origin recorded on the file)"; info ORIGIN "unknown (no download origin recorded on the file)"
fi
Q="$(xattr -p com.apple.quarantine "$DMG" 2>/dev/null)"; st DMG_QUARANTINE "${Q:-none}"
progress 5 "Contrôle d'intégrité de l'image (hdiutil verify)"
step "Contrôle d'intégrité de l'image disque"
VERR="$(hdiutil verify "$DMG" 2>&1)" || fail CORRUPT "hdiutil verify failed (incomplete or damaged download): $(printf '%s' "$VERR" | grep -v deprecated | tail -2 | tr '\n' ' ')"
progress 20 "Calcul de l'empreinte SHA-256"
SHA="$(shasum -a 256 "$DMG" | awk '{print toupper($1)}')"
[ ${#SHA} = 64 ] || fail INCOMPLETE "SHA-256 could not be computed"
st DMG_SHA256 "$SHA"; info DMG_SHA256 "$SHA"
[ "$(stat -f%z "$DMG")" = "$S2" ] || fail INCOMPLETE "the file changed during the checks"

# ---------- 2. mount ----------
step "Montage de l'image disque"
progress 28 "Montage de l'image disque"
MP="$(mktemp -d /tmp/ti4d_install.XXXXXX)"
dmg_attach "$DMG" "$MP" || { rmdir "$MP" 2>/dev/null; fail MOUNT "cannot mount the disk image: $DMG_ERR"; }
[ "$DMG_OWN" = 1 ] || rmdir "$MP" 2>/dev/null
MNT="$DMG_MNT"
if [ "$DMG_OWN" = 1 ]; then st MOUNT "attached by the installer, detached afterwards ($DMG_DEV)"; else st MOUNT "already mounted by the user at $MNT: used as is, left mounted"; fi
info MOUNT "$MNT"

# ---------- 3. expected product, version, build, architecture, signature ----------
step "Identification de $PRODUCT dans l'image"
SRCAPP="$(find "$MNT" -maxdepth 3 -type d -name "$PRODUCT.app" ! -path '*.app/*' 2>/dev/null | head -1)"
if [ -z "$SRCAPP" ]; then
  apps="$(find "$MNT" -maxdepth 3 -type d -name '*.app' ! -path '*.app/*' 2>/dev/null | sed 's#.*/##' | tr '\n' ',' | sed 's/,$//')"
  fail PRODUCT "$PRODUCT.app not found in the disk image (contains: ${apps:-no application})"
fi
INFO="$SRCAPP/Contents/Info.plist"
SV="$($PB -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null)"
BID="$($PB -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null)"
DV="$(version_normalize "$SV")"
DB="$(version_build "$SV")"
st SOURCE_VERSION "$SV"; st BUNDLE_ID "$BID"
version_equal "$DV" "$VERSION" && [ "$DB" = "$BUILD" ] ||
  fail VERSION "the disk image contains $PRODUCT $DV build $DB, the selection is $VERSION build $BUILD: nothing installed (no other version is ever installed)"
EXE="$SRCAPP/Contents/MacOS/$($PB -c 'Print :CFBundleExecutable' "$INFO" 2>/dev/null)"
if xcode-select -p >/dev/null 2>&1 && xcrun --find lipo >/dev/null 2>&1; then ARCHS="$(lipo -archs "$EXE" 2>/dev/null)"
else ARCHS="$(file -b "$EXE" | grep -oE '(x86_64|arm64e?)' | sort -u | tr '\n' ' ' | sed 's/ $//')"; fi
[ -n "$ARCHS" ] || fail PRODUCT "cannot read the architectures of $EXE (missing or unreadable executable)"
st ARCHS "$ARCHS"
if [ -n "$WANT_ARCH" ]; then
  case " $ARCHS " in *" $WANT_ARCH "*|*" ${WANT_ARCH}e "*) ;; *) fail ARCH "$PRODUCT.app contains [$ARCHS], the selected platform $PLATFORM needs $WANT_ARCH";; esac
fi
SIG="$(codesign -dvvv "$SRCAPP" 2>&1)"
TEAM="$(printf '%s\n' "$SIG" | sed -n 's/^TeamIdentifier=//p')"
CDH="$(printf '%s\n' "$SIG" | sed -n 's/^CDHash=//p' | head -1)"
st TEAM "${TEAM:-none}"; st CDHASH "$CDH"
if [ "$EXPECTED_TEAM" != none ] && [ "$TEAM" != "$EXPECTED_TEAM" ]; then
  fail SIGNATURE "$PRODUCT.app is signed by team '${TEAM:-none}', not by 4D SAS ($EXPECTED_TEAM)"
fi
info SOURCE "$SRCAPP ($PRODUCT $DV build $DB, $ARCHS, team ${TEAM:-none})"

# ---------- 4. what the package installs: the application + shared resources next to it ----------
PDIR="$(dirname "$SRCAPP")"
if [ "$PDIR" = "$MNT" ]; then FOLDER="$PRODUCT $VERSION"; else FOLDER="$(basename "$PDIR")"; fi
TARGET_DIR="${DEST%/}/$FOLDER"; TARGET_APP="$TARGET_DIR/$PRODUCT.app"
ITEMS=("$PRODUCT.app")
while IFS= read -r d; do
  n="$(basename "$d")"
  case "$n" in .*|*.app|Applications) continue;; esac
  [ -L "$d" ] && continue
  ITEMS+=("$n")
done < <(find "$PDIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
st TARGET_DIR "$TARGET_DIR"; st APP "$TARGET_APP"; st ITEMS "$(printf '%s, ' "${ITEMS[@]}" | sed 's/, $//')"
info ITEMS "$(printf '%s, ' "${ITEMS[@]}" | sed 's/, $//') -> $TARGET_DIR"

# ---------- 5. existing installation: never overwritten without confirmation ----------
EXIST=()
for i in "${ITEMS[@]}"; do [ -e "$TARGET_DIR/$i" ] && EXIST+=("$i"); done
if [ ${#EXIST[@]} -gt 0 ]; then
  ESV=""; EDV=""; EDB=""; SAME=different
  if [ -d "$TARGET_APP" ]; then
    ESV="$($PB -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null)"
    EDV="$(version_normalize "$ESV")"; EDB="$(version_build "$ESV")"
    [ "$(codesign -dvvv "$TARGET_APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)" = "$CDH" ] && SAME=same
  fi
  printf 'EXISTS\t%s\t%s\t%s\t%s\n' "$TARGET_DIR" "${EDV:-?}" "${EDB:-?}" "$SAME"
  case "$MODE" in
    install) FAILED=EXISTS; st EXISTING "$(printf '%s, ' "${EXIST[@]}" | sed 's/, $//')"; write_state ko EXISTS "an installation already exists in $TARGET_DIR: confirmation needed"
             printf 'RESULT\tko\t%s\n' "$TARGET_APP"; exit 3;;
    adopt)
      version_equal "$EDV" "$VERSION" && [ "$EDB" = "$BUILD" ] ||
        fail VERSION "the existing installation is $PRODUCT ${EDV:-?} build ${EDB:-?}, not the selected $VERSION build $BUILD"
      st SOURCE "existing installation, not copied by this run (identical code to the DMG: $SAME)";;
  esac
fi
[ "$MODE" = adopt ] && [ ${#EXIST[@]} -eq 0 ] && fail ARGS "--adopt: no existing installation in $TARGET_DIR"

if [ "$MODE" != adopt ]; then
  # ---------- 6. space ----------
  step "Contrôle de l'espace disque"
  progress 32 "Contrôle de l'espace disque"
  NEED=0; for i in "${ITEMS[@]}"; do k=$(du -sk "$PDIR/$i" 2>/dev/null | awk '{print $1}'); NEED=$((NEED + ${k:-0})); done
  NEED=$(( NEED + NEED / 10 + 102400 ))
  P="$DEST"; while [ ! -d "$P" ] && [ "$P" != / ]; do P="$(dirname "$P")"; done
  AVAIL=$(df -k "$P" | awk 'NR==2{print $4}')
  st SPACE "needed $((NEED/1024)) MB, available $((AVAIL/1024)) MB on $(df "$P" | awk 'NR==2{print $NF}')"
  [ "$AVAIL" -ge "$NEED" ] || fail SPACE "not enough space on $(df "$P" | awk 'NR==2{print $NF}'): $((NEED/1024)) MB needed, $((AVAIL/1024)) MB available"

  # ---------- 7. copy (ditto keeps permissions, extended attributes incl. quarantine, ACLs, signatures) ----------
  STAMP="$(date +%Y%m%d%H%M%S)-$$"
  WDIR="$TARGET_DIR"; [ -d "$WDIR" ] || WDIR="$P"
  PRIV=0; [ -w "$WDIR" ] || PRIV=1
  if [ "$PRIV" = 0 ]; then
    [ -d "$TARGET_DIR" ] || CREATED_DIR="$TARGET_DIR"
    mkdir -p "$TARGET_DIR" 2>/dev/null || fail DENIED "cannot create $TARGET_DIR"
    STAGE="$TARGET_DIR/.ti4d-install-$STAMP"
    mkdir "$STAGE" 2>/dev/null || fail DENIED "cannot write in $TARGET_DIR (permission refused)"
    TOTAL=$NEED; n=0; ERRF="$(mktemp /tmp/ti4d_ditto.XXXXXX)"
    for i in "${ITEMS[@]}"; do
      n=$((n+1)); step "Copie de $i ($n/${#ITEMS[@]})"
      ditto "$PDIR/$i" "$STAGE/$i" 2> "$ERRF" & cp_pid=$!
      while kill -0 $cp_pid 2>/dev/null; do
        done_k=$(du -sk "$STAGE" 2>/dev/null | awk '{print $1}')
        pct=$(( 35 + 45 * ${done_k:-0} / (TOTAL > 0 ? TOTAL : 1) )); [ $pct -gt 80 ] && pct=80; progress $pct "Copie de $i"
        sleep 1
      done
      rc=0; wait $cp_pid || rc=$?; cp_pid=""
      if [ $rc -ne 0 ]; then
        e="$(tr '\n' ' ' < "$ERRF")"; rm -f "$ERRF"
        case "$e" in *"No space"*) fail SPACE "copy of $i stopped: no space left ($e)";; *"ermission"*|*"not permitted"*) fail DENIED "copy of $i refused: $e";; *) fail COPY "copy of $i failed: $e";; esac
      fi
    done
    rm -f "$ERRF"
    sync
    step "Mise en place dans $TARGET_DIR"
    progress 82 "Mise en place"
    if [ ${#EXIST[@]} -gt 0 ]; then
      OLD="$TARGET_DIR/.ti4d-previous-$STAMP"; mkdir "$OLD" || fail DENIED "cannot prepare the replacement in $TARGET_DIR"
      for i in "${EXIST[@]}"; do
        if e="$(mv "$TARGET_DIR/$i" "$OLD/$i" 2>&1)"; then MOVED+=("$i")
        else fail DENIED "the existing $i cannot be replaced: $e. If macOS blocks it, allow this app in System Settings > Privacy & Security > App Management, or delete the old copy in Finder"; fi
      done
    fi
    for i in "${ITEMS[@]}"; do
      if e="$(mv "$STAGE/$i" "$TARGET_DIR/$i" 2>&1)"; then PLACED+=("$i"); else fail DENIED "cannot put $i in place: $e"; fi
    done
    rmdir "$STAGE" 2>/dev/null; STAGE=""
  else
    # destination not writable by this account: macOS asks for an administrator (no password handled here)
    step "Droits administrateur demandés par macOS pour écrire dans $(dirname "$TARGET_DIR")"
    progress 40 "Copie avec les droits administrateur (fenêtre macOS)"
    S="$(mktemp /tmp/ti4d_priv.XXXXXX)"
    {
      echo 'set -e'
      printf 'T=%q; P=%q; OLD=%q\n' "$TARGET_DIR" "$PDIR" "$TARGET_DIR/.ti4d-previous-$STAMP"
      echo 'mkdir -p "$T"'
      if [ ${#EXIST[@]} -gt 0 ]; then echo 'mkdir "$OLD"'; for i in "${EXIST[@]}"; do printf 'mv "$T"/%q "$OLD"/\n' "$i"; done; fi
      for i in "${ITEMS[@]}"; do printf '/usr/bin/ditto "$P"/%q "$T"/%q\n' "$i" "$i"; done
    } > "$S"
    E="$(osascript -e "do shell script \"/bin/bash \" & quoted form of \"$S\" with administrator privileges" 2>&1)"; rc=$?
    rm -f "$S"
    if [ $rc -ne 0 ]; then
      case "$E" in *"-128"*|*"annul"*|*"cancel"*) fail ADMIN "administrator authorisation cancelled: nothing installed";; esac
      fail DENIED "copy with administrator rights failed: $E"
    fi
    [ ${#EXIST[@]} -gt 0 ] && OLD_PRIV="$TARGET_DIR/.ti4d-previous-$STAMP"
  fi
fi

# ---------- 8. verification of the installed application ----------
step "Vérification de l'application installée"
progress 88 "Vérification de la version, du build et de la signature"
[ -d "$TARGET_APP" ] || fail VERIFY "$TARGET_APP is missing after the installation"
ISV="$($PB -c 'Print :CFBundleShortVersionString' "$TARGET_APP/Contents/Info.plist" 2>/dev/null)"
IDV="$(version_normalize "$ISV")"; IDB="$(version_build "$ISV")"
version_equal "$IDV" "$VERSION" && [ "$IDB" = "$BUILD" ] || fail VERIFY "installed $PRODUCT.app is $IDV build $IDB, expected $VERSION build $BUILD"
[ "$($PB -c 'Print :CFBundleIdentifier' "$TARGET_APP/Contents/Info.plist" 2>/dev/null)" = "$BID" ] || fail VERIFY "bundle identifier of the installed app differs from the disk image"
CV="$(codesign --verify --deep --strict "$TARGET_APP" 2>&1)" || fail VERIFY "codesign --verify --deep --strict failed on the installed app (incomplete or altered copy): $(printf '%s' "$CV" | head -2 | tr '\n' ' ')"
ICDH="$(codesign -dvvv "$TARGET_APP" 2>&1 | sed -n 's/^CDHash=//p' | head -1)"
[ "$ICDH" = "$CDH" ] || fail VERIFY "installed code differs from the disk image (CDHash $ICDH <> $CDH)"
for i in "${ITEMS[@]}"; do
  [ "$i" = "$PRODUCT.app" ] && continue
  a="$(cd "$PDIR/$i" && find . | wc -l | tr -d ' ')"; b="$( [ -d "$TARGET_DIR/$i" ] && cd "$TARGET_DIR/$i" && find . | wc -l | tr -d ' ')"
  [ "$a" = "$b" ] || fail VERIFY "$i: $a items in the disk image, ${b:-0} installed"
done
IQ="$(xattr -p com.apple.quarantine "$TARGET_APP" 2>/dev/null)"
st INSTALLED_VERSION "$ISV"; st INSTALLED_CDHASH "$ICDH"; st QUARANTINE_AT_INSTALL "${IQ:-none}"
st CODESIGN "codesign --verify --deep --strict OK, CDHash identical to the disk image"
info INSTALLED "$TARGET_APP ($ISV)"
[ -n "$IQ" ] || info NOTE "the installed app is not quarantined (the DMG has no quarantine): Gatekeeper will not evaluate its first launch"

# ---------- 9. previous copy to the Trash (only after success) ----------
if [ -n "$OLD" ] && [ ${#MOVED[@]} -gt 0 ]; then
  if [ "${INSTALL_TRASH:-1}" = 1 ] && [ -x /usr/bin/trash ] && /usr/bin/trash -s "$OLD" >/dev/null 2>&1; then st PREVIOUS "previous installation moved to the Trash"
  else
    KEEP="$TARGET_DIR/previous installation $(date '+%Y-%m-%d %H.%M.%S')"
    mv "$OLD" "$KEEP" 2>/dev/null && st PREVIOUS "previous installation kept in $KEEP (delete it in Finder)" || st PREVIOUS "previous installation kept in $OLD"
  fi
  OLD=""; MOVED=()
elif [ -n "${OLD_PRIV:-}" ]; then st PREVIOUS "previous installation kept in $OLD_PRIV (administrator rights: delete it in Finder)"
fi
PLACED=()

progress 96 "Démontage de l'image disque"
if [ "$DMG_OWN" = 1 ]; then
  dmg_detach || { st MOUNT "WARNING: could not be detached ($DMG_DEV)"; info WARNING "the disk image could not be detached: eject it in Finder"; }
fi
write_state ok
progress 100 "Installation terminée et vérifiée"
printf 'RESULT\tok\t%s\n' "$TARGET_APP"
exit 0
