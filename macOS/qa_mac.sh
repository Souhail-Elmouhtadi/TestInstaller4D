#!/bin/bash
# Test Installer 4D - macOS part of the release checklist (generated kit).
# Usage : bash qa_mac.sh [EN|FR|DE|CS|JA]   run the checklist (default = current macOS language)
#         bash qa_mac.sh --recover          after an interrupted run: network back on (pf rules of the tool removed),
#                                           4D language restored
#         bash qa_mac.sh --restore-locale   same, plus the macOS language changed by kit versions < 3
# Unattended: 4D is started in the tested language with a per-application language (macOS language
# unchanged, no log out), version/build are read in the DMG when not given, the About box is opened and
# read (Accessibility + OCR), the Gatekeeper alert is confirmed, Rosetta is tested with
# open --arch x86_64, GitHub is retried before concluding. Xcode Command Line Tools are optional.
# Offline test: the installed application (install_4d.sh, record INSTALL_STATE) is launched once the absence
# of Internet is verified by several probes; the user cuts the network (default), or with NET_AUTO=1 the pf
# firewall guard (net_guard.sh, authorized once per run: confirmation + macOS administrator dialog) blocks the
# traffic during the test only and lifts the block afterwards; network settings are never modified.
# 4D processes are identified and terminated by PID only (launch_check.sh).
# Results: qa_mac_results.tsv (next to this script), one row per check with status, detail, date and tested
# path (results.sh); report built by rapport_mac.sh.

KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/version.sh" || exit 1
. "$KIT/network.sh" || exit 1
. "$KIT/results.sh" || exit 1
. "$KIT/dmg_mount.sh" || exit 1
. "$KIT/launch_check.sh" || exit 1
. "$KIT/exec_checks.sh" || exit 1
# helpers: only the signed ones of the app (Contents/Helpers), never a copy. The app passes them; a run from
# Terminal uses the installed app (TI4D_APP, /Applications or ~/Applications).
ti4d_helper() {
  local a
  for a in "${TI4D_APP:-}" "/Applications/Test Installer 4D.app" "$HOME/Applications/Test Installer 4D.app"; do
    [ -n "$a" ] && [ -x "$a/Contents/Helpers/$1" ] && { echo "$a/Contents/Helpers/$1"; return 0; }
  done
  echo "/Applications/Test Installer 4D.app/Contents/Helpers/$1"
}
ABOUT_CHECK="${ABOUT_CHECK:-$(ti4d_helper about_check)}"
README_CHECK="${README_CHECK:-$(ti4d_helper readme_check)}"
BASE="$HOME/4DQA_mac"
OUT="$KIT/qa_mac_results.tsv"
ORIG="$BASE/original_locale.txt"
NETF="$BASE/net_disabled.txt"
PB=/usr/libexec/PlistBuddy
mkdir -p "$BASE"
LC_PIDS="$BASE/launched_pids.txt"
INSTALL_STATE="${INSTALL_STATE:-$BASE/install_state.tsv}"

A_OS="Operating system version used"; A_DL="The download"; A_DMGWIN="DMG window (before installation)"; A_EDITOR="The installer Editor"; A_VERSION="Version number"
A_COMPS='"Components" folder'; A_PLUGINS="No more plugins provided"; A_IC="Download last 4D I.C."; A_LOAD="Load of components"
A_FAT="Check if FAT application"; A_ROSETTA="Execution in 'Rosetta' mode"; A_README="ReadMe"

lang_tag() { case "$1" in EN) echo en-US;; FR) echo fr-FR;; DE) echo de-DE;; CS) echo cs-CZ;; JA) echo ja-JP;; esac; }
loc_of()   { case "$1" in EN) echo en_US;; FR) echo fr_FR;; DE) echo de_DE;; CS) echo cs_CZ;; JA) echo ja_JP;; esac; }
langs_list() { defaults read "${1:--g}" AppleLanguages 2>/dev/null | sed '1d;$d' | tr -d ' ",' | tr '\n' ' ' | sed 's/ $//'; }
ask() {
  if [ "$GUI" = 1 ]; then # graphical app: macOS dialogs (default answer after 5 min, so that an unattended run goes on)
    local m="${1//\\/\\\\}"; m="${m//\"/\\\"}" b
    case "$1" in
      *"[y/N]"*) b="$(osascript -e "button returned of (display dialog \"$m\" buttons {\"Non\",\"Oui\"} default button \"Non\" with title \"Test Installer 4D\" giving up after 300)" 2>/dev/null)"
                 [ "$b" = "Oui" ] && echo y || echo n ;;
      *skip*)    b="$(osascript -e "button returned of (display dialog \"$m\" buttons {\"Passer\",\"Continuer\"} default button \"Continuer\" with title \"Test Installer 4D\" giving up after 300)" 2>/dev/null)"
                 [ "$b" = "Continuer" ] && echo "" || echo s ;;
      *)         osascript -e "display dialog \"$m\" buttons {\"OK\"} default button \"OK\" with title \"Test Installer 4D\" giving up after 300" >/dev/null 2>&1; echo "" ;;
    esac
    return
  fi
  local a; printf '%s ' "$1" > /dev/tty; read a < /dev/tty; echo "$a"; }

# ---------- 4D language: per-application language (System Settings > Language & Region > Applications) ----------
app_lang_set() { # bundle-id LANG
  local f="$BASE/applang_$1.txt" v
  if [ ! -f "$f" ]; then # keep the first backup: an interrupted run leaves the test language in place
    { printf 'BID=%q\n' "$1"
      if defaults read "$1" AppleLanguages >/dev/null 2>&1; then printf 'OLD_LANGS=%q\n' "$(langs_list "$1")"; else echo 'OLD_LANGS=-'; fi
      if v="$(defaults read "$1" AppleLocale 2>/dev/null)"; then printf 'OLD_LOCALE=%q\n' "$v"; else echo 'OLD_LOCALE=-'; fi
    } > "$f"
  fi
  defaults write "$1" AppleLanguages -array "$(lang_tag "$2")"
  defaults write "$1" AppleLocale "$(loc_of "$2")"
  APPLANG="$f"
}
app_lang_restore() { # backup file
  local BID OLD_LANGS OLD_LOCALE
  . "$1" || return 1
  if [ "$OLD_LANGS" = "-" ]; then defaults delete "$BID" AppleLanguages 2>/dev/null; else defaults write "$BID" AppleLanguages -array $OLD_LANGS; fi
  if [ "$OLD_LOCALE" = "-" ]; then defaults delete "$BID" AppleLocale 2>/dev/null; else defaults write "$BID" AppleLocale "$OLD_LOCALE"; fi
  rm -f "$1"
  echo "4D language restored ($BID)"
}
recover() {
  local f
  lc_cleanup # 4D processes started by an interrupted run (by PID, never by name)
  if [ -f "$NETF" ]; then echo "Re-enabling the network services: $(tr '\n' ',' < "$NETF" | sed 's/,$//')"; net_on >/dev/null; fi
  guard_recover # pf rules left by a network guard that could not clean up
  for f in "$BASE"/applang_*.txt; do [ -f "$f" ] && app_lang_restore "$f"; done
  return 0
}

case "$1" in
  --recover) recover; exit 0;;
  --restore-locale)
    recover
    if [ -f "$ORIG" ]; then
      . "$ORIG"
      defaults write -g AppleLanguages -array $ORIG_LANGS
      defaults write -g AppleLocale "$ORIG_LOCALE"
      rm -f "$ORIG"
      echo "Restored: AppleLanguages=($ORIG_LANGS) AppleLocale=$ORIG_LOCALE -> log out / log in to apply."
    else echo "macOS language: nothing to restore (the kit no longer changes it)."; fi
    exit 0;;
esac
[ -f "$KIT/kit.conf" ] || { echo "kit.conf missing: run the app or 'Test Installer 4D.command' first."; exit 1; }
. "$KIT/kit.conf"
recover # leftovers of an interrupted run
caffeinate -dimsu -w $$ >/dev/null 2>&1 & # display and Mac awake during the run (the About box is read on screen)

# ---------- language ----------
CUR="$(langs_list | cut -d' ' -f1)"
CUR2="$(echo "${CUR%%-*}" | tr 'a-z' 'A-Z')"
case "$CUR2" in EN|FR|DE|CS|JA) ;; *) CUR2=EN;; esac
LANG_CODE="$(echo "${1:-$CUR2}" | tr 'a-z' 'A-Z')"
case "$LANG_CODE" in EN|FR|DE|CS|JA) ;; *) echo "Unknown language '$LANG_CODE' (EN FR DE CS JA)"; exit 1;; esac
LC="$(echo "$LANG_CODE" | tr 'A-Z' 'a-z')"

# ---------- result helpers ----------
# row helpers (res, begin, add, ko, warn, notrun, need_action, undetermined): results.sh
: > "$OUT"
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"

OSV="macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"
# hardware of the Mac, not of this process: uname -m says x86_64 when the kit itself runs under Rosetta
case "$(sysctl -n hw.optional.arm64 2>/dev/null)" in 1) ARCH=arm64;; *) [ "$(sysctl -n hw.optional.x86_64 2>/dev/null)" = 1 ] && ARCH=x86_64 || ARCH=unknown;; esac
[ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ] && OSV="$OSV (kit translated by Rosetta, hardware $ARCH)"
hdr RUN "$RUN_ID"
hdr DATE "$(date '+%Y-%m-%d %H:%M:%S')"
hdr PRODUCT "$PRODUCT"
hdr OS "$OSV"
hdr LANG "$LANG_CODE"
hdr PLATFORM "$PLATFORM"

# 2. download
begin
# never a silent choice: the disk image is the one selected by the user (DMG=<path>)
[ -n "${DMG:-}" ] || { res "$A_DL" notrun "No disk image selected: set DMG=<path of the .dmg> (the tool never picks one by itself)" ""; exit 1; }
[ -f "$DMG" ] || { res "$A_DL" ko "Disk image not found: $DMG" "$DMG"; exit 1; }
hdr DMG "$DMG"
DMG_SHA=""
RES_PATH="$DMG" # default tested path of a row
for f in "$DMG" "$KIT"/*.zip; do
  [ -f "$f" ] || continue
  n="$(basename "$f")"; sz=$(stat -f%z "$f")
  h="$(shasum -a 256 "$f" | awk '{print toupper($1)}')"
  printf '#HASH\t%s\t%s\n' "$n" "$h" >> "$OUT"
  [ "$f" = "$DMG" ] && DMG_SHA="$h"
  v=""
  case "$f" in
    *.dmg) if hdiutil verify -quiet "$f" >/dev/null 2>&1; then v="hdiutil verify OK"; else v="hdiutil verify FAILED"; ST=ko; fi;;
    *.zip) if unzip -tq "$f" >/dev/null 2>&1; then v="zip OK"; else v="zip CORRUPTED"; ST=ko; fi;;
  esac
  [ "$sz" -gt 0 ] || ST=ko
  add "$n : $((sz/1048576)) MB, SHA-256 $h, $v"
done
res "$A_DL" "$ST" "$D" "$DMG"

# DMG window: checked by dmg_window.sh before every installation (files + window really shown + screenshot + user's
# verdict). Only a result for this very image, product and version counts; otherwise "not run", never a success.
begin
DW="${DMG_WINDOW_STATE:-$BASE/dmg_window.tsv}"
dwget() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$DW" 2>/dev/null; }
DWST="$(dwget STATUS)"; DWSHOT="$(dwget SHOT)"
if [ -z "$DWST" ] || [ "$(dwget DMG)" != "$DMG" ] || [ "$(dwget STAMP)" != "$(stat -f '%z %m' "$DMG")" ] \
   || [ "$(dwget PRODUCT)" != "$PRODUCT" ] || [ "$(dwget VERSION)" != "$VERSION" ] || [ "$(dwget BUILD)" != "$BUILD" ]; then
  res "$A_DMGWIN" notrun "Not checked for this disk image, product and version: the check runs in the app before every installation (Installer et vérifier)." "$DMG"
else
  D="$(dwget DETAIL)"; add "Checked $(dwget DATE) on volume $(dwget VOLUME); verdict: $(dwget VERDICT)"
  DWSAFE="$(printf '%s_%s' "$VERSION" "$BUILD" | tr ' /' '__')"
  if [ -n "$DWSHOT" ] && [ -s "$DWSHOT" ]; then DWCOPY="$DWSHOT"; add "Screenshot : results/${DWSAFE}_dmg_window.png (copy of $DWSHOT)"; fi
  case "$DWST" in
    ok) ST=ok;; ko) ST=ko;; action) ST=action;;
    pending) ST=manual; add "Result of an older kit without reference window: to be checked by the user.";;
    *) ST=undetermined;;
  esac
  res "$A_DMGWIN" "$ST" "$D" "${DWSHOT:-$DMG}"
fi

# mount
# an image already mounted by the user is reused and left mounted; an image attached here is always detached
if ! dmg_attach "$DMG" "$BASE/mnt"; then res "$A_EDITOR" ko "Cannot mount $DMG: $DMG_ERR" "$DMG"; exit 1; fi
MNT="$DMG_MNT"
[ "$DMG_OWN" = 1 ] || echo "Disk image already mounted by the user at $MNT: used as is, left mounted"
SRCAPP="$MNT/$PRODUCT.app"
[ -d "$SRCAPP" ] || SRCAPP="$(find "$MNT" -maxdepth 2 -name "$PRODUCT.app" -type d | head -1)"
[ -d "$SRCAPP" ] || SRCAPP="$(find "$MNT" -maxdepth 2 -name '*.app' -type d | head -1)"
[ -d "$SRCAPP" ] || { res "$A_EDITOR" ko "No .app in the DMG" "$DMG"; dmg_detach; exit 1; }
APPNAME="$(basename "$SRCAPP")"
exe_of() { echo "$1/Contents/MacOS/$($PB -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist")"; }
echo "App: $SRCAPP"

# version and build of the DMG (Info.plist "21.2 build 21.100624"): the build is not in the DMG name
INFO="$SRCAPP/Contents/Info.plist"
SV="$($PB -c 'Print :CFBundleShortVersionString' "$INFO" 2>/dev/null)"
BV="$($PB -c 'Print :CFBundleVersion' "$INFO" 2>/dev/null)"
BID="$($PB -c 'Print :CFBundleIdentifier' "$INFO" 2>/dev/null)"
PL_VERSION="${SV%% [Bb]uild*}"
PL_BUILD="$(version_build "$SV")"
AUTO=""
[ -n "$VERSION" ] || { VERSION="$PL_VERSION"; AUTO="version"; }
VERSION="$(version_normalize "$VERSION")"
[ -n "$BUILD" ] || { BUILD="$PL_BUILD"; AUTO="${AUTO:+$AUTO + }build"; }
[ -n "$AUTO" ] && echo "Read in the DMG (Info.plist): $AUTO -> $VERSION build $BUILD"
hdr VERSION "$VERSION"
hdr BUILD "$BUILD"
SAFE="$(printf '%s_%s' "$VERSION" "$BUILD" | tr ' /' '__')"
rm -f "$KIT/results/${SAFE}_${LANG_CODE}_about.png" "$KIT/results/${SAFE}_dmg_window.png" # no screenshot of a previous run in this report
[ -n "${DWCOPY:-}" ] && mkdir -p "$KIT/results" && cp "$DWCOPY" "$KIT/results/${SAFE}_dmg_window.png"
WORK="$BASE/$SAFE"
mkdir -p "$WORK"
VMAJ="$(printf '%s' "$VERSION" | sed -E 's/^[^0-9]*([0-9]+).*/\1/')"; [ -n "$VMAJ" ] || VMAJ=21
# 4D 20: no 4D AIKit, components inside 4D.app, plugins (I.C.) still delivered, no GitHub "Follow 4D version"
COMPS="$KIT/comps.txt"; [ "$VMAJ" -lt 21 ] && COMPS="$KIT/comps_20.txt"

APPLANG=""
cleanup() {
  lc_cleanup # only the 4D processes started by this run, by PID
  # interrupted during the offline test: the pf block is lifted at once (the guard would do it at its deadline)
  if guard_running && [ "$GUARD_STATUS" = blocked ]; then guard_open >/dev/null 2>&1; fi
  [ "${QA_GUARD_OWNED:-0}" = 1 ] && guard_quit >/dev/null 2>&1
  [ -f "$NETF" ] && net_on >/dev/null
  [ -n "$APPLANG" ] && [ -f "$APPLANG" ] && app_lang_restore "$APPLANG" >/dev/null
  dmg_detach || echo "WARNING: the disk image $DMG_DEV could not be detached: eject it in Finder"
}
trap cleanup EXIT
trap 'exit 143' TERM INT HUP

if ! EXPECTED_COMPS="$(cat "$COMPS")" || [ -z "$(item_lines "$EXPECTED_COMPS")" ]; then
  res "$A_COMPS" ko "Cannot read a non-empty component reference: $COMPS. Action: restore this reference from the Test Installer 4D kit and re-run the checklist." "$COMPS"
  exit 1
fi
NCOMPS="$(item_lines "$EXPECTED_COMPS" | awk 'END{print NR}')"

# 4D in the tested language without changing macOS (no log out)
[ -n "$BID" ] && app_lang_set "$BID" "$LANG_CODE"
hdr LOCALE "$APPNAME ($BID) : AppleLanguages=$(langs_list "$BID") AppleLocale=$(defaults read "$BID" AppleLocale 2>/dev/null) (per-application language) ; macOS : AppleLanguages=$(langs_list) AppleLocale=$(defaults read -g AppleLocale 2>/dev/null)"
echo "== $PRODUCT $VERSION build $BUILD - $PLATFORM - $LANG_CODE - $OSV =="

# installation (install_4d.sh, run before the checklist): the offline test launches the installed application
xc_install "$INSTALL_STATE"
hdr INSTALLED "${INST_APP:-none}"

# 1. OS
begin; add "$OSV"
HOSTPF="$([ "$ARCH" = arm64 ] && echo "macOS ARM" || { [ "$ARCH" = x86_64 ] && echo "macOS Intel"; })"
if [ -z "$HOSTPF" ]; then ko "Platform of this Mac could not be detected (hw.optional.arm64 / x86_64)"
elif [ "$PLATFORM" != "$HOSTPF" ]; then ko "Platform $PLATFORM given, but this Mac is $HOSTPF: results would not match the tested Mac"
else add "Platform detected on the hardware: $HOSTPF"; fi
add "macOS language : $(langs_list), region $(defaults read -g AppleLocale 2>/dev/null) (unchanged)"
if [ -n "$BID" ]; then add "$APPNAME started in $(lang_tag "$LANG_CODE") / $(loc_of "$LANG_CODE") : per-application language ($BID), no log out"
else ko "No CFBundleIdentifier in $APPNAME: the 4D language cannot be set"; fi
res "$A_OS" "$ST" "$D" "$(sw_vers -productName) $(sw_vers -productVersion)"

# 3. signature (installer editor)
begin
SIG="$(codesign -dv --verbose=4 "$SRCAPP" 2>&1)"
AUTH="$(printf '%s\n' "$SIG" | grep '^Authority=' | head -1 | cut -d= -f2-)"
TEAM="$(printf '%s\n' "$SIG" | grep '^TeamIdentifier=' | cut -d= -f2)"
case "$AUTH|$TEAM" in *"4D SAS"*|"Developer ID Application: 4D (37UG5W39Z2)|37UG5W39Z2") add "$APPNAME : $AUTH (Team $TEAM = 4D SAS Apple team)";; *) ko "$APPNAME : signer '$AUTH' (Team $TEAM) is not 4D SAS (37UG5W39Z2)";; esac
if codesign --verify --deep --strict "$SRCAPP" >/dev/null 2>&1; then add "codesign --verify --deep --strict : OK"
else ko "codesign --verify --deep --strict FAILED: $(codesign --verify --deep --strict "$SRCAPP" 2>&1 | head -3 | tr '\n' ' ')"; fi
DS="$(codesign -dv --verbose=4 "$DMG" 2>&1 | grep '^Authority=' | head -1 | cut -d= -f2-)"
add "DMG : ${DS:-not signed}"
res "$A_EDITOR" "$ST" "$D"

# 5. Components folder
begin
CMP="$MNT/Components"
[ -d "$CMP" ] || CMP="$(find "$MNT" -maxdepth 3 -type d -name Components ! -path '*.app/*' | head -1)"
[ -d "$CMP" ] || CMP="$SRCAPP/Contents/Components"
if [ -d "$CMP" ]; then
  if got="$(ls -1 "$CMP" 2>&1)"; then
    got="$(printf '%s\n' "$got" | awk '!/^\./')"
    check_items "Components folder ($CMP; reference $(basename "$COMPS"))" "$EXPECTED_COMPS" "$got" \
      "Check the DMG for $PRODUCT $VERSION against $(basename "$COMPS"); restore missing components and review unexpected entries in the release package, then re-run."
  else ko "Cannot list Components folder $CMP: $got. Action: check folder permissions and re-run."; fi
else
  ko "No Components folder in the DMG."
  check_items "Components folder (reference $(basename "$COMPS"))" "$EXPECTED_COMPS" "" \
    "Check that the selected DMG is the complete $PRODUCT $VERSION package and includes its Components folder, then re-run."
fi
res "$A_COMPS" "$ST" "$D" "$CMP"

# 6. plugins (static)
PLG="$( { find "$MNT" -maxdepth 3 -type d -name Plugins ! -path '*.app/*'; find "$SRCAPP/Contents" -maxdepth 2 -type d -name Plugins; } 2>/dev/null)"
PLB=""; [ -n "$PLG" ] && PLB="$(printf '%s\n' "$PLG" | while IFS= read -r d; do find "$d" -mindepth 1 -maxdepth 1 -iname '*.bundle'; done)"

# Xcode Command Line Tools are optional: lipo / stapler when installed, otherwise file / codesign (part of macOS)
clt() { xcode-select -p >/dev/null 2>&1 && xcrun --find "$1" >/dev/null 2>&1; }

# 9. FAT
begin
BIN="$(exe_of "$SRCAPP")"
if clt lipo; then LA="$(lipo -archs "$BIN" 2>&1)"; HOW="lipo -archs"
else LA="$(file -b "$BIN" | grep -oE '\[(x86_64|arm64e?)' | tr -d '[' | tr '\n' ' ' | sed 's/ $//')"; HOW="file (no Command Line Tools)"; fi
case "$LA" in *x86_64*arm64*|*arm64*x86_64*) add "$HOW $(basename "$BIN") : $LA";;
  *) ko "$HOW $(basename "$BIN") : $LA (not universal)"
     add "Expected architectures: x86_64 and arm64. Observed: ${LA:-none detected}."
     add "Action: inspect $BIN with lipo -archs (or file); verify that the selected release package contains both Intel and Apple Silicon slices.";;
esac
res "$A_FAT" "$ST" "$D" "$BIN"

# copies: pristine (quarantined, Gatekeeper test) + test copy (Components inside)
rm -rf "$WORK/app"; mkdir -p "$WORK/app/pristine" "$WORK/app/test"
PAPP="$WORK/app/pristine/$APPNAME"; TAPP="$WORK/app/test/$APPNAME"
# The test copy is made from the mounted image without quarantine (ditto --noqtn, user decision): the Components
# added inside it break its seal, so Gatekeeper would refuse it. Gatekeeper is tested on the pristine copy and on
# the installed application, which keep their quarantine. No quarantine attribute is ever removed.
ditto --noqtn "$SRCAPP" "$TAPP"
quarantine() { xattr -w com.apple.quarantine "0081;$(printf %x "$(date +%s)");Safari;" "$1"; }
fresh_pristine() { rm -rf "$PAPP"; ditto "$SRCAPP" "$PAPP"; quarantine "$PAPP"; }
[ -d "$CMP" ] && [ "$CMP" != "$SRCAPP/Contents/Components" ] && ditto --noqtn "$CMP" "$TAPP/Contents/Components"

# projects
# quarantine kept: 4D opens quarantined projects and loads the quarantined I.C. plugin (checked with 4D 21.2)
PRJ="$WORK/projects"; rm -rf "$PRJ"; ditto "$KIT/projects" "$PRJ"
[ "$VMAJ" -lt 21 ] && sed -i '' 's/; "OB Is defined(cs.AIKit.OpenAI)"//' "$PRJ/QA_Local/Project/Sources/Methods/qaTest.4dm"
newproj() { # template newname
  rm -rf "$PRJ/$2"; ditto "$PRJ/$1" "$PRJ/$2"; mv "$PRJ/$2/Project/$1.4DProject" "$PRJ/$2/Project/$2.4DProject"; echo "$PRJ/$2"; }

# run4d app projdir timeout [open|rosetta|x86_64|arm64|direct]: proof of start = fresh qa_result.txt (launch_check.sh)
run4d() {
  local app="$1" p="$2" to="$3" mode="${4:-direct}"
  echo "   launch $APPNAME $mode : $(basename "$p")"
  lc_launch "$app" "$p" "$to" "$mode"
  RUNFLAGS="$LC_FLAGS"; GKMSG="$LC_GK"; RUNSTATE="$LC_STATE"; RUNREASON="$LC_REASON"
  echo "   -> $LC_STATE: $LC_REASON"
  [ "$LC_STATE" = READY ]
}
# start4d app projdir timeout: 4D stays open (pid P4D, tracked) until stop4d projdir
start4d() {
  local p="$2" name i=0
  name="$(basename "$p")"; rm -f "$p/qa_result.txt" "$p/about_done.txt"
  echo "   launch $APPNAME (kept open) : $name"
  "$(exe_of "$1")" --project "$p/Project/$name.4DProject" --opening-mode interpreted --dataless >/dev/null 2>&1 &
  P4D=$!; lc_track "$P4D" "$p/Project/$name.4DProject"
  while [ $i -lt "$3" ] && [ ! -s "$p/qa_result.txt" ] && ps -p "$P4D" >/dev/null 2>&1; do sleep 1; i=$((i+1)); done
  [ -s "$p/qa_result.txt" ]
}
stop4d() {
  local i=0
  touch "$1/about_done.txt"
  while ps -p "$P4D" >/dev/null 2>&1 && [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done
  lc_kill "$P4D" "$1/Project/"
  return 0
}
comps_of()   { tr '\r' '\n' < "$1" | awk '/^Components \(/{f=1;next} /^Plugins \(/{f=0} f&&/^  /{sub(/^  /,"");print}'; }
plugins_of() { tr '\r' '\n' < "$1" | awk '/^Plugins \(/{f=1;next} /^TEST /{f=0} f&&/^  /{sub(/^  /,"");print}'; }
failed_of()  { tr '\r' '\n' < "$1" | grep '^TEST ' | grep -v '(err 0)$' ; tr '\r' '\n' < "$1" | grep '^TEST .*=> UNDEFINED (err 0)$'; }
build_of()   { tr '\r' '\n' < "$1" | sed -n 's/^Build: //p'; }
lang_of()    { tr '\r' '\n' < "$1" | sed -n 's/^Language: //p'; }
ntests()     { tr '\r' '\n' < "$1" | grep -c '^TEST '; }
joinl()      { tr '\n' ',' | sed 's/,$//; s/,/, /g'; }
# GitHub API: "ok <requests left>" | "ratelimit <reset epoch>" | "unreachable"
gh_status() {
  local j r
  j="$(curl -s --max-time 10 https://api.github.com/rate_limit)"
  r="$(printf '%s' "$j" | plutil -extract resources.core.remaining raw -o - - 2>/dev/null)"
  if [ -z "$r" ]; then echo unreachable
  elif [ "$r" -gt 0 ]; then echo "ok $r"
  else echo "ratelimit $(printf '%s' "$j" | plutil -extract resources.core.reset raw -o - - 2>/dev/null)"; fi
}

# 8. load of components
begin; LOCALOK=0
P="$PRJ/QA_Local"
if run4d "$TAPP" "$P" 240; then
  LOCALOK=1; R="$P/qa_result.txt"; cat "$R"
  got="$(comps_of "$R")"
  check_items "Loaded components ($TAPP/Contents/Components)" \
    "$(printf '%s\n' "$EXPECTED_COMPS" | sed 's/\.4dbase$//')" "$got" \
    "Compare the loaded names with $COMPS and the test copy at $TAPP/Contents/Components; inspect the 4D loading errors, then re-run." required
  F="$(failed_of "$R")"
  if [ -n "$F" ]; then
    ko "Tests KO: $(printf '%s\n' "$F" | joinl)"
    add "Action: inspect the named test formulas and their error codes in $R; check the corresponding component versions and loading errors, then re-run."
  else add "$(ntests "$R") tests OK"; fi
else ko "Local project: no result ($RUNSTATE: $RUNREASON). Action: inspect the launch diagnostic and any blocking 4D dialog, then re-run."; fi
if [ "$TEST_CONTROL" = 1 ] && [ -d "$TAPP/Contents/Components" ]; then
  mv "$TAPP/Contents/Components" "$TAPP/Contents/Components_off"
  C="$(newproj QA_Exec QA_Control)"
  if run4d "$TAPP" "$C" 180; then
    ex="$(comps_of "$C/qa_result.txt" | grep -vx '4D Labels' | grep -vx '4D Report')"
    check_items "Control without Contents/Components (excluding built-in 4D Labels and 4D Report)" "" "$ex" \
      "These components still load without the test Components folder. Check other component sources and dependency settings, then re-run."
  else ko "Control project: no result ($RUNSTATE: $RUNREASON). Action: inspect the launch diagnostic and any blocking 4D dialog, then re-run."; fi
  mv "$TAPP/Contents/Components_off" "$TAPP/Contents/Components"
fi
if [ "$TEST_GITHUB" = 1 ] && [ "$VMAJ" -lt 21 ]; then
  add "GitHub : N/A (loading components from GitHub with 'Follow 4D version' is available from 4D 21, tested version $VERSION)"
elif [ "$TEST_GITHUB" = 1 ]; then
  # transient GitHub errors (network, API quota of 60 requests/hour per IP address) are retried before concluding
  CLOG="$HOME/Library/Caches/${APPNAME%.app}/Dependencies/cache.log"
  gerr="x"; try=1; gnote=""
  while [ -n "$gerr" ] && [ $try -le 3 ]; do
    if [ $try -gt 1 ]; then
      gs="$(gh_status)"
      case "$gs" in
        ratelimit*) rs="${gs#ratelimit }"; w=$(( ${rs:-0} - $(date +%s) + 5 ))
                    if [ $w -le 900 ]; then echo "   GitHub API quota used up: waiting ${w}s"; sleep $(( w > 0 ? w : 1 ))
                    else gnote="GitHub API quota used up until $(date -r "$rs" +%H:%M)"; break; fi;;
        unreachable) sleep 30; [ "$(gh_status)" = unreachable ] && { gnote="api.github.com unreachable"; break; };;
        *) sleep $(( try * 20 ));;
      esac
    fi
    echo "   GitHub test, attempt $try/3"; gerr=""; tags=""
    nlog=0; [ -f "$CLOG" ] && nlog="$(wc -l < "$CLOG" | tr -d ' ')"
    G="$(newproj QA_GitHub QA_GitHub_run)"
    if run4d "$TAPP" "$G" 300; then
      LK="$(find "$G" -name dependencies-lock.json | head -1)"
      if [ -z "$LK" ]; then gerr="dependencies-lock.json missing"
      else
        while read c; do c="${c%.4dbase}"
          l="$(plutil -extract "dependencies.$c.loaded" raw -o - "$LK" 2>/dev/null)"
          pth="$(plutil -extract "dependencies.$c.path" raw -o - "$LK" 2>/dev/null)"
          tg="$(plutil -extract "dependencies.$c.tag" raw -o - "$LK" 2>/dev/null)"
          tags="$tags ${c#4D } $tg,"
          case "$l|$pth" in true\|*.github*) ;; *) gerr="$gerr $c not loaded from GitHub;";; esac
        done < <(tr -d '\r' < "$COMPS")
        F="$(failed_of "$G/qa_result.txt")"; [ -z "$F" ] || gerr="$gerr tests KO $(printf '%s\n' "$F" | joinl)"
      fi
    else gerr="no result (timeout)"; fi
    if [ -n "$gerr" ] && [ -f "$CLOG" ]; then
      glog="$(tail -n +"$((nlog+1))" "$CLOG" | grep -iE 'error|fail|limit|denied|timeout' | tail -3 | tr '\n' ' ')"
      [ -n "$glog" ] && gerr="$gerr [4D cache.log: $glog]"
    fi
    try=$((try+1))
  done
  ntry=$((try-1))
  if [ -z "$gerr" ]; then add "GitHub : $NCOMPS components loaded from GitHub, tests OK (tags:${tags%,})$([ $ntry -gt 1 ] && echo " - attempt $ntry/3: previous failure was transient")"
  else
    gs="$(gh_status)"
    if [ -n "$gnote" ] || [ "${gs%% *}" != ok ]; then warn "GitHub : not concluded, transient GitHub problem (${gnote:-$gs}) after $ntry attempt(s) - re-run later. Last error:$gerr"
    else ko "GitHub KO after $ntry attempts (GitHub reachable, API quota ${gs#ok } left) :$gerr"; fi
  fi
fi
res "$A_LOAD" "$ST" "$D" "$TAPP"

# About box: opened through the 4D menu (Accessibility), captured and read (OCR), compared with the expected
# version/build and with the texts of the tested language (About<LANG>.xlf of the app)
about_test() {
  local A AB png e txt menu title lst lmsg k
  if [ ! -x "$ABOUT_CHECK" ]; then warn "About box : about_check helper not found ($ABOUT_CHECK: install the Test Installer 4D app) - check it manually"; return; fi
  A="$(newproj QA_About QA_About_run)"
  png="$WORK/about_$LANG_CODE.png"; AB="$WORK/about_$LANG_CODE.txt"; rm -f "$png"
  if ! start4d "$TAPP" "$A" 180; then stop4d "$A"; warn "About box : 4D did not start - check it manually"; return; fi
  "$ABOUT_CHECK" "$P4D" "$png" "$LANG_CODE" "$TAPP" 90 > "$AB" 2>&1
  stop4d "$A"
  cat "$AB"
  menu="$(awk -F'\t' '$1=="MENU"{print $2}' "$AB")"; title="$(awk -F'\t' '$1=="TITLE"{print $2}' "$AB")"
  txt="$(awk -F'\t' '$1=="OCR"{print $2}' "$AB")"
  e="$(awk -F'\t' '$1=="ERR"{print $3}' "$AB")"
  [ -n "$title" ] && add "About box : menu '$menu' -> window '$title'"
  if printf '%s\n' "$txt" | grep -qE '[0-9]+\.[0-9]{3,}'; then # content displayed (version line read)
    add "About box (OCR) : $(printf '%s\n' "$txt" | grep -E '[0-9]+\.[0-9]' | head -2 | joinl)"
    version_in_text "$VERSION" "$txt" || ko "About box : version $VERSION not displayed"
    printf '%s\n' "$txt" | grep -qE "(^|[^0-9])$BUILD([^0-9]|\$)" || ko "About box : build $BUILD not displayed"
  fi
  lst="$(awk -F'\t' '$1=="LANG"{print $2}' "$AB")"; lmsg="$(awk -F'\t' '$1=="LANG"{print $3}' "$AB")"
  case "$lst" in OK) add "About box language : $lmsg";; KO) ko "About box language : $lmsg"
    for k in $(awk -F'\t' '$1=="LOC" && $2=="KO"{print NR}' "$AB"); do add "  missing : $(awk -F'\t' -v n="$k" 'NR==n{print $3" = \""$4"\""}' "$AB")"; done;; esac
  if [ -s "$png" ]; then mkdir -p "$KIT/results"; cp "$png" "$KIT/results/${SAFE}_${LANG_CODE}_about.png"; add "About screenshot : results/${SAFE}_${LANG_CODE}_about.png"; fi
  [ -n "$e" ] && warn "About box not read automatically : $e"
  [ -z "$txt" ] && [ -z "$e" ] && warn "About box : no text read - check it manually"
}

# 4. version
begin
add "Info.plist : CFBundleShortVersionString=$SV, CFBundleVersion=$BV"
# 4D convention: CFBundleVersion 21.0.2 = 21.2 (a 0 is always inserted after the major version)
BVN="$(version_normalize "$BV")"
[ "$BVN" != "$BV" ] && add "CFBundleVersion $BV = $BVN (4D convention, not a bug)"
SVV="$PL_VERSION"
! version_equal "$SVV" "$BV" && bundle_version_matches "$SVV" "$BV" &&
  add "CFBundleVersion $BV = $SVV (4D R release numbering, not a bug)"
bundle_version_matches "$SVV" "$BV" || ko "Info.plist incoherent : CFBundleShortVersionString $SVV <> CFBundleVersion $BV (= $BVN)"
version_equal "$SVV" "$VERSION" || ko "Version $SVV in Info.plist <> expected $VERSION"
[ "$PL_BUILD" = "$BUILD" ] || ko "Build $PL_BUILD in Info.plist <> expected $BUILD"
[ -n "$AUTO" ] && add "Expected $AUTO read automatically in the DMG (Info.plist), the DMG name does not contain it"
if [ $LOCALOK = 1 ]; then
  B4="$(build_of "$PRJ/QA_Local/qa_result.txt")"
  add "Application version : $(tr '\r' '\n' < "$PRJ/QA_Local/qa_result.txt" | sed -n 's/^Version: //p'), build $B4"
  [ "$B4" = "$BUILD" ] || ko "Build $B4 <> expected $BUILD"
  L4="$(lang_of "$PRJ/QA_Local/qa_result.txt")"
  if [ -n "$L4" ]; then
    if [ "${L4%%[-_]*}" = "$LC" ]; then add "4D language : $L4 (Get database localization(User system localization))"
    else ko "4D ran in '$L4' instead of $LANG_CODE (per-application language not applied)"; fi
  fi
fi
about_test
[ "$ST" != ko ] || add "Action: compare the expected version $VERSION and build $BUILD with Info.plist, the application result and the About box above; verify the selected DMG and test language $LANG_CODE, then re-run."
res "$A_VERSION" "$ST" "$D" "$TAPP"

# 6. plugins
begin
if [ "$VMAJ" -lt 21 ]; then res "$A_PLUGINS" na "4D $VERSION : plugins still delivered before 4D 21 (${PLB:-none found})"
else
check_items "Bundled plugins (4D $VERSION)" "" "$PLB" \
  "Review the named plugin bundles at the paths above; 4D $VERSION must not provide plugins. Correct the release package and re-run."
if [ $LOCALOK = 1 ]; then
  pl="$(plugins_of "$PRJ/QA_Local/qa_result.txt")"
  check_items "Loaded plugins" "" "$pl" \
    "Inspect the named plugins and their sources in the test copy at $TAPP; 4D $VERSION must not provide plugins. Correct the release package and re-run."
fi
res "$A_PLUGINS" "$ST" "$D" "$TAPP"
fi

# 10. execution (Gatekeeper / notarisation), three separate rows (exec_checks.sh):
# the installed application WITHOUT Internet first (no online launch of this run before it), then the
# stapled ticket (static), then a fresh quarantined copy WITH Internet.
xc_offline "$INST_APP"
xc_staple
xc_online

# 11. Rosetta
translated() { [ -n "$RUNFLAGS" ] && [ $(( 0x$RUNFLAGS & 0x20000 )) -ne 0 ]; }
rosetta_ok() { arch -x86_64 /usr/bin/true 2>/dev/null; }
begin
if [ "$ARCH" != arm64 ]; then res "$A_ROSETTA" na "Intel Mac: Rosetta not applicable"
else
  if ! rosetta_ok; then
    a="$(ask "Rosetta is not installed: 4D cannot run in Intel mode. Install Rosetta now (administrator password)? [y/N]")"
    if [ "$a" = y ] || [ "$a" = Y ]; then
      osascript -e 'do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges' >/dev/null 2>&1
    fi
  fi
  if ! rosetta_ok; then
    res "$A_ROSETTA" ko "Rosetta not installed: 4D cannot start in Intel mode. Install it: softwareupdate --install-rosetta --agree-to-license (or the Prerequisites panel of the app)" "$TAPP"
  else
    E="$(newproj QA_Exec QA_Rosetta)"
    if run4d "$TAPP" "$E" 300 rosetta && translated; then
      res "$A_ROSETTA" ok "open --arch x86_64 (LaunchServices launch in Intel mode, same as Get Info > 'Open using Rosetta') : 4D ran under Rosetta (process translated, flags 0x$RUNFLAGS) without crash, build $(build_of "$E/qa_result.txt")" "$TAPP"
    else
      F1="open --arch x86_64 : no result or not translated (flags 0x$RUNFLAGS)"
      E="$(newproj QA_Exec QA_Rosetta2)"
      if run4d "$TAPP" "$E" 240 x86_64 && translated; then res "$A_ROSETTA" ok "arch -x86_64 : 4D ran under Rosetta (process translated) without crash, build $(build_of "$E/qa_result.txt") ($F1)" "$TAPP"
      else res "$A_ROSETTA" ko "$F1 ; arch -x86_64 : no result or not translated (flags 0x$RUNFLAGS) - see ~/Library/Logs/DiagnosticReports"; fi
    fi
  fi
fi

# 7. I.C. : fixed reference plugin (ic_fixed, last I.C. = 20.9, no longer updated) + optional zips in ic/
begin
ICSRC=()
FIXED="$KIT/ic_fixed/4D InternetCommands.bundle"
[ -d "$FIXED" ] && ICSRC+=("$FIXED")
if [ "$TEST_IC" = 1 ]; then for z in "$KIT"/ic/*.zip; do [ -f "$z" ] && ICSRC+=("$z"); done; fi
if [ ${#ICSRC[@]} -gt 0 ]; then
  n=0
  for src in "${ICSRC[@]}"; do
    n=$((n+1)); x="$WORK/ic/$n"; rm -rf "$x"; mkdir -p "$x"
    if [ -d "$src" ]; then
      b="$src"; lbl="ic_fixed ($($PB -c 'Print :CFBundleShortVersionString' "$src/Contents/Info.plist" 2>/dev/null))"
    else
      lbl="$(basename "$src" .zip)"
      ditto -x -k "$src" "$x" 2>/dev/null || unzip -q "$src" -d "$x"
      b="$(find "$x" -type d -name '4D InternetCommands.bundle' | head -1)"
      if [ -z "$b" ]; then ko "$lbl : no 4D InternetCommands.bundle in the zip"; continue; fi
    fi
    I="$(newproj QA_IC "QA_IC$n")"; mkdir -p "$I/Plugins"; ditto "$b" "$I/Plugins/4D InternetCommands.bundle"
    if run4d "$TAPP" "$I" 180; then
      pl="$(plugins_of "$I/qa_result.txt")"; F="$(failed_of "$I/qa_result.txt")"
      if printf '%s\n' "$pl" | grep -qi internet && [ -z "$F" ]; then add "$lbl : plugin loaded in $PRODUCT $VERSION, IT_SetTimeOut(30) OK"
      else ko "$lbl : plugins [$(printf '%s\n' "$pl" | joinl)] tests KO [$(printf '%s\n' "$F" | joinl)]"; fi
    else ko "$lbl : no result"; fi
  done
  res "$A_IC" "$ST" "$D" "$TAPP"
else res "$A_IC" manual "I.C. test not run (no ic_fixed plugin and no zip in kit/ic)"; fi

# 12. ReadMe
link_code() { curl -s -o /dev/null -L --max-time 15 -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" -w '%{http_code}' "$1"; }
begin
RM="$(find "$MNT" -maxdepth 2 \( -iname '*read*me*' -o -iname '*lisez*' -o -iname '*liesmich*' \) ! -path '*.app/*' 2>/dev/null)"
if [ -z "$RM" ]; then add "No ReadMe in the DMG"; else
  printf '%s\n' "$RM" | while read f; do echo "$f"; done > "$WORK/readme.txt"
  while read f; do
    add "File : ${f#$MNT/}"
    [ -f "$f" ] || continue
    urls=""
    if [ -x "$README_CHECK" ]; then
      while IFS=$'\t' read -r k m; do
        case "$k" in OK) add "  ✓ $m";; KO) ko "  ✗ $m";; WARN) add "  ⚠ (other language) $m";; URL) urls="$urls$m$NL";; *) add "  $m";; esac
      done < <("$README_CHECK" "$f" "$VMAJ" "$LANG_CODE" "$([ -n "$PLB" ] && echo 1 || echo 0)" "$KIT/readme_words.txt" 2>/dev/null)
    else ko "  readme_check helper not found ($README_CHECK: install the Test Installer 4D app)"; fi
    for u in $(printf '%s' "$urls" | sort -u | head -40); do
      c="$(link_code "$u")"
      case "$c" in 2*|3*) ;; *) sleep 3; c="$(link_code "$u")";; esac # transient error: retried once before concluding
      case "$c" in 2*|3*) add "  $c $u";; *) ko "  BROKEN $c $u";; esac
    done
  done < "$WORK/readme.txt"
fi
res "$A_README" "$ST" "$D"

echo
echo "Results: $OUT"
[ -f "$ORIG" ] && echo "Restore the macOS language changed by an older kit: bash \"$0\" --restore-locale"
