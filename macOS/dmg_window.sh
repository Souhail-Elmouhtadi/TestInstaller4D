#!/bin/bash
# Presentation of the 4D disk image (the window the user sees after a double-click), checked BEFORE installing.
# Usage: bash dmg_window.sh --dmg <file.dmg> --product <4D|4D Server|4D Volume Desktop> --version <21.2> --build <n>
#                           [--state <file.tsv>] [--shot <file.png>]
#        bash dmg_window.sh --confirm <yes|no> --dmg <file.dmg> [--state <file.tsv>]   (user's verdict on the screenshot)
# Two separate parts:
#   files : volume name, product folder (with <product>.app), Applications link to /Applications, ReadMe, layout
#           (.DS_Store) and background (.background) - their existence alone never proves what the window shows;
#   window: the volume is opened in Finder and the window really displayed is read (title, icon view, bounds, position
#           of each icon: inside the window, no overlap, product folder left of Applications), then captured.
# Even when every automatic check passes, readability (labels, background arrow) can only be judged on the screenshot:
# the result stays "pending" until the user confirms it (--confirm yes|no). Never a success without that proof.
# An image already mounted by the user is used as is and left mounted (its Finder window is left open if it was open);
# an image attached here (visible in Finder, as a double-click) is detached, also on failure.
# Output: STEP <text> | CHECK <ok|ko|info> <text> | ERROR <CODE> <text> | RESULT <pending|ok|ko|action|error> <screenshot>
#   CODE: ARGS MOUNT FINDER AUTOMATION SHOT STATE
# Exit: 0 pending/ok, 2 ko, 4 action required (permission), 1 error.
# Test hooks: FINDER_PROBE (command: <open|close> <mount point> [had]) and SCREENCAPTURE.
KIT="$(cd "$(dirname "$0")" && pwd)"
. "$KIT/dmg_mount.sh" || exit 1
DMG=""; PRODUCT=""; VERSION=""; BUILD=""; CONFIRM=""
STATE="$HOME/4DQA_mac/dmg_window.tsv"; SHOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dmg) DMG="$2"; shift;; --product) PRODUCT="$2"; shift;; --version) VERSION="$2"; shift;;
    --build) BUILD="$2"; shift;; --state) STATE="$2"; shift;; --shot) SHOT="$2"; shift;;
    --confirm) CONFIRM="$2"; shift;;
    *) printf 'ERROR\tARGS\tunknown argument %s\n' "$1"; exit 1;;
  esac
  shift
done
ev() { local IFS=$'\t'; printf '%s\n' "$*"; }
[ -n "$DMG" ] && [ -f "$DMG" ] || { ev ERROR ARGS "disk image not found: $DMG"; ev RESULT error ""; exit 1; }
mkdir -p "$(dirname "$STATE")" || { ev ERROR STATE "cannot create $(dirname "$STATE")"; exit 1; }
stamp() { stat -f '%z %m' "$1" 2>/dev/null; }
get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$STATE" 2>/dev/null; }

# ---------- user's verdict on the screenshot of the last check ----------
if [ -n "$CONFIRM" ]; then
  case "$CONFIRM" in yes|no) ;; *) ev ERROR ARGS "--confirm yes|no"; exit 1;; esac
  if [ "$(get STATUS)" != pending ] || [ "$(get DMG)" != "$DMG" ] || [ "$(get STAMP)" != "$(stamp "$DMG")" ]; then
    ev ERROR STATE "no pending check for this disk image: run the check again"; ev RESULT error ""; exit 1
  fi
  new=ok; why="confirmed by the user on the screenshot"
  [ "$CONFIRM" = yes ] || { new=ko; why="rejected by the user on the screenshot"; }
  tmp="$(mktemp "$STATE.XXXXXX")" || exit 1
  awk -F'\t' -v OFS='\t' -v s="$new" -v w="$why" -v d="$(date '+%Y-%m-%d %H:%M:%S')" '
    $1=="STATUS"{$2=s} $1=="VERDICT"{next} {print} END{print "VERDICT", w; print "CONFIRMED", d}' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  ev RESULT "$new" "$(get SHOT)"
  [ "$new" = ok ] && exit 0 || exit 2
fi

[ -n "$PRODUCT" ] && [ -n "$VERSION" ] || { ev ERROR ARGS "--product and --version are required"; ev RESULT error ""; exit 1; }
[ -n "$SHOT" ] || SHOT="$(dirname "$STATE")/dmg_window.png"
rm -f "$STATE" "$SHOT" # a previous result never survives a new check
STATUS=pending; DETAIL=""; VOL=""; HAD=0; OPENED=0
check() { ev CHECK "$1" "$2"; DETAIL="$DETAIL${DETAIL:+\\n}[$1] $2"; [ "$1" != ko ] || STATUS=ko; }
save() {
  { printf 'STATUS\t%s\nDATE\t%s\nPRODUCT\t%s\nVERSION\t%s\nBUILD\t%s\nDMG\t%s\nSTAMP\t%s\nVOLUME\t%s\nSHOT\t%s\nDETAIL\t%s\n' \
      "$STATUS" "$(date '+%Y-%m-%d %H:%M:%S')" "$PRODUCT" "$VERSION" "$BUILD" "$DMG" "$(stamp "$DMG")" "$VOL" \
      "$([ -s "$SHOT" ] && echo "$SHOT")" "$DETAIL"
    [ "$STATUS" = pending ] && printf 'VERDICT\twaiting for the user: compare the screenshot with the expected window\n'
  } > "$STATE"
}
probe() {
  if [ -n "${FINDER_PROBE:-}" ]; then $FINDER_PROBE "$@"; return; fi
  if [ "$1" = close ]; then
    osascript - "$2" <<'EOF'
on run a
  set p to item 1 of a
  tell application "Finder"
    repeat with k from (count Finder windows) to 1 by -1
      try
        if POSIX path of ((get target of Finder window k) as alias) is p then close Finder window k
      end try
    end repeat
  end tell
end run
EOF
    return
  fi
  osascript - "$2" <<'EOF'
on run a
  set p to item 1 of a
  set o to ""
  tell application "Finder"
    set had to 0
    repeat with k from 1 to (count Finder windows)
      try
        if POSIX path of ((get target of Finder window k) as alias) is p then set had to 1
      end try
    end repeat
    set o to o & "had=" & had & linefeed
    open (POSIX file p as alias)
    delay 1.5
    set w to missing value
    repeat with k from 1 to (count Finder windows)
      try
        if POSIX path of ((get target of Finder window k) as alias) is p then
          set w to Finder window k
          exit repeat
        end if
      end try
    end repeat
    if w is missing value then return o & "window=none" & linefeed
    set index of w to 1
    activate
    delay 0.8
    set AppleScript's text item delimiters to ","
    set o to o & "name=" & (name of w) & linefeed & "view=" & (current view of w as string) & linefeed
    set o to o & "bounds=" & ((get bounds of w) as string) & linefeed
    set o to o & "toolbar=" & (toolbar visible of w) & linefeed
    if (current view of w as string) is "icon view" then set o to o & "iconsize=" & (icon size of icon view options of w) & linefeed
    set tg to (get target of w)
    set nms to (get name of every item of tg)
    set ps to (get position of every item of tg)
  end tell
  repeat with k from 1 to (count nms)
    set o to o & "item=" & (item k of nms) & tab & ((item k of ps) as string) & linefeed
  end repeat
  return o
end run
EOF
}
cleanup() {
  [ "$OPENED" = 1 ] && [ "$HAD" = 0 ] && [ -n "$VOL" ] && probe close "$VOL/" >/dev/null 2>&1
  dmg_detach >/dev/null 2>&1
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---------- 1. mount as a double-click would (the user's own mount is reused) ----------
ev STEP "Mounting $(basename "$DMG") as Finder does"
DMG_NOVERIFY=1 DMG_BROWSE=1 dmg_attach "$DMG" "" || { ev ERROR MOUNT "cannot mount the disk image: $DMG_ERR"; STATUS=error; DETAIL="mount: $DMG_ERR"; save; ev RESULT error ""; exit 1; }
VOL="${DMG_MNT%/}"
[ "$DMG_OWN" = 1 ] && check info "image mounted for this check at $VOL, detached afterwards" || check info "image already mounted by the user at $VOL: used as is, left mounted"
NAME="$(basename "$VOL")"

# ---------- 2. files of the package (necessary, never sufficient) ----------
ev STEP "Files of the package"
vword() { case " $1 " in *[!0-9.]"$VERSION"[!0-9.]*) return 0;; *) return 1;; esac; }
if vword "$NAME"; then check ok "volume name \"$NAME\" matches $PRODUCT $VERSION"; else check ko "volume name \"$NAME\" does not contain the selected version $VERSION"; fi
FOLDER=""
for d in "$VOL"/*/; do
  d="${d%/}"; case "$d" in *.app) continue;; esac
  [ -d "$d/$PRODUCT.app" ] && { FOLDER="$(basename "$d")"; break; }
done
if [ -n "$FOLDER" ]; then
  check ok "product folder \"$FOLDER\" contains $PRODUCT.app"
  vword "$FOLDER" || check ko "product folder \"$FOLDER\" does not contain the version $VERSION"
else check ko "no folder containing $PRODUCT.app at the root of the image"; fi
if [ -L "$VOL/Applications" ] && [ "$(readlink "$VOL/Applications")" = /Applications ]; then check ok "\"Applications\" is a link to /Applications"
elif [ "$(head -c 4 "$VOL/Applications" 2>/dev/null)" = book ] && [ "${ALIAS_TARGET:-$(osascript -e "tell application \"Finder\" to POSIX path of (original item of (POSIX file \"$VOL/Applications\" as alias) as alias)" 2>/dev/null)}" = /Applications/ ]; then check ok "\"Applications\" is a Finder alias to /Applications"
else check ko "no \"Applications\" link to /Applications at the root of the image"; fi
README="$(cd "$VOL" && ls -1 2>/dev/null | grep -i '^readme.*\.pdf$' | head -1)"
if [ -n "$README" ] && [ -s "$VOL/$README" ]; then check ok "\"$README\" present ($(stat -f%z "$VOL/$README") bytes)"
else check ko "no ReadMe (PDF) at the root of the image"; fi
[ -s "$VOL/.DS_Store" ] && check ok "window layout stored in the image (.DS_Store)" || check ko "no window layout in the image (.DS_Store missing): Finder shows a default window"
bg="$(ls -1 "$VOL/.background" 2>/dev/null | head -1)"
[ -n "$bg" ] && check ok "background image .background/$bg" || check info "no background image (.background)"
BGSHA="$([ -n "$bg" ] && shasum -a 256 "$VOL/.background/$bg" | cut -d' ' -f1)"

# ---------- 3. window really displayed by Finder ----------
ev STEP "Opening the window in Finder"
out="$(probe open "$VOL/" 2>&1)"; rc=$?
OPENED=1
HAD="$(printf '%s\n' "$out" | sed -n 's/^had=//p' | head -1)"; HAD="${HAD:-0}"
if [ $rc != 0 ]; then
  OPENED=0
  case "$out" in
    *-1743*|*"Not authorized"*|*"not allowed"*)
      check ko "Finder could not be controlled: allow Test Installer 4D in System Settings > Privacy & Security > Automation > Finder, then check again"
      STATUS=action; save; ev ERROR AUTOMATION "Automation > Finder not allowed"; ev RESULT action ""; exit 4;;
    *) check ko "Finder window could not be read: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)"
       STATUS=error; save; ev ERROR FINDER "Finder window could not be read"; ev RESULT error ""; exit 1;;
  esac
fi
kv() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }
if [ "$(kv window)" = none ]; then check ko "no Finder window opened for $VOL"
else
  WNAME="$(kv name)"; VIEW="$(kv view)"; B="$(kv bounds)"; IS="$(kv iconsize)"; TB="$(kv toolbar)"
  [ "$WNAME" = "$NAME" ] && check ok "window displayed, title \"$WNAME\"" || check ko "window title \"$WNAME\" instead of \"$NAME\""
  [ "$VIEW" = "icon view" ] && check ok "icon view, icons ${IS:-?} pt" || check ko "window in $VIEW instead of the icon view of the layout"
  IFS=, read -r L T R BO <<< "$B"
  W=$((R-L)); H=$((BO-T)); CH=$((H-28)); [ "$TB" = true ] && CH=$((CH-50))
  check info "window ${W}x${H} at ($L,$T), toolbar ${TB:-?}"
  IS="${IS:-64}"; HALF=$((IS/2))
  ITEMS="$(printf '%s\n' "$out" | sed -n 's/^item=//p')"
  pos() { printf '%s\n' "$ITEMS" | awk -F'\t' -v n="$1" '$1==n{print $2; exit}'; }
  place() { # name label
    local p x y; p="$(pos "$1")"
    [ -n "$p" ] || { check ko "$2 \"$1\" not shown in the window"; return 1; }
    x="${p%,*}"; y="${p#*,}"
    if [ $((x-HALF)) -ge 0 ] && [ $((x+HALF)) -le $W ] && [ $((y-HALF)) -ge 0 ] && [ $((y+HALF+18)) -le $CH ]; then
      check ok "$2 \"$1\" visible at ($x,$y), icon and label inside the window"
    else check ko "$2 \"$1\" at ($x,$y) is cut or outside the visible area (${W}x${CH})"; fi
  }
  [ -n "$FOLDER" ] && place "$FOLDER" "product folder"
  place Applications "shortcut"
  [ -n "$README" ] && place "$README" "ReadMe"
  ov="$(printf '%s\n' "$ITEMS" | awk -F'\t' -v s="$IS" '{split($2,p,","); n[NR]=$1; x[NR]=p[1]; y[NR]=p[2]}
    END{for(i=1;i<=NR;i++)for(j=i+1;j<=NR;j++){dx=x[i]-x[j];dy=y[i]-y[j];if(dx<0)dx=-dx;if(dy<0)dy=-dy;if(dx<s&&dy<s)print n[i] " / " n[j]}}')"
  [ -z "$ov" ] && check ok "no overlapping icons" || check ko "overlapping icons: $(printf '%s' "$ov" | tr '\n' ';')"
  if [ -n "$FOLDER" ] && fp="$(pos "$FOLDER")" && ap="$(pos Applications)" && [ -n "$fp" ] && [ -n "$ap" ]; then
    dy=$(( ${fp#*,} - ${ap#*,} )); [ $dy -lt 0 ] && dy=$((-dy))
    if [ "${fp%,*}" -lt "${ap%,*}" ] && [ $dy -lt $HALF ]; then check ok "\"$FOLDER\" left of \"Applications\" on the same row (drag to install)"
    else check ko "\"$FOLDER\" is not left of \"Applications\" on the same row: drag to install is not shown"; fi
  fi
  extra="$(printf '%s\n' "$ITEMS" | awk -F'\t' -v a="$FOLDER" -v r="$README" 'NF && $1!=a && $1!="Applications" && $1!=r {print $1}')"
  [ -z "$extra" ] || check info "other items shown: $(printf '%s' "$extra" | tr '\n' ',' | sed 's/,$//')"
  # ---------- 4. proof: screenshot of the window ----------
  if ${SCREENCAPTURE:-screencapture} -x -R"$L,$T,$W,$H" "$SHOT" >/dev/null 2>&1 && [ -s "$SHOT" ]; then
    check info "screenshot of the window: $SHOT"
  else
    rm -f "$SHOT"; prev="$STATUS"
    check ko "the window could not be captured: allow Test Installer 4D in Privacy & Security > Screen Recording, then check again"
    [ "$prev" = ko ] || STATUS=action
    [ "$STATUS" = action ] && { save; ev ERROR SHOT "screenshot impossible"; ev RESULT action ""; exit 4; }
  fi
fi
# ---------- 5. automatic verdict: comparison with the reference window (4D 21.2, see dmg_window_reference.tsv) ----------
REF="${DMG_WINDOW_REF:-$(dirname "$0")/dmg_window_reference.tsv}"
if [ "$STATUS" = pending ]; then
  ref() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$REF" 2>/dev/null; }
  if [ ! -s "$REF" ]; then check ko "reference window missing ($REF): no automatic verdict"; STATUS=error
  else
    TOL="$(ref TOLERANCE)"; TOL="${TOL:-4}"; diffs=""
    near() { local a="$1" b="$2" d; d=$(( ${a%,*} - ${b%,*} )); [ ${d#-} -le $TOL ] || return 1; d=$(( ${a#*,} - ${b#*,} )); [ ${d#-} -le $TOL ]; }
    [ "${W}x${H}" = "$(ref WINDOW)" ] || diffs="$diffs; window ${W}x${H} instead of $(ref WINDOW)"
    [ "$VIEW" = "$(ref VIEW)" ] || diffs="$diffs; $VIEW instead of $(ref VIEW)"
    [ "$IS" = "$(ref ICONSIZE)" ] || diffs="$diffs; icons $IS pt instead of $(ref ICONSIZE)"
    [ "${TB:-false}" = "$(ref TOOLBAR)" ] || diffs="$diffs; toolbar $TB instead of $(ref TOOLBAR)"
    for k in FOLDER:"$FOLDER" APPLICATIONS:Applications README:"$README"; do
      n="${k#*:}"; p="$(pos "$n")"; e="$(ref "POS_${k%%:*}")"
      [ -n "$p" ] && near "$p" "$e" || diffs="$diffs; \"$n\" at (${p:-absent}) instead of ($e)"
    done
    [ "$BGSHA" = "$(ref BACKGROUND_SHA256)" ] || diffs="$diffs; background image differs from the reference"
    if [ -z "$diffs" ]; then
      STATUS=ok; check ok "window identical to the reference ($(ref SOURCE)): size, view, icons, positions within ${TOL} pt, background"
      VERDICT="automatic: identical to the reference window ($(ref SOURCE))"
    else
      check ko "window differs from the reference ($(ref SOURCE)):${diffs#;}"; STATUS=ko
      VERDICT="automatic: differs from the reference window"
    fi
  fi
fi
save
[ -n "${VERDICT:-}" ] && printf 'VERDICT\t%s\n' "$VERDICT" >> "$STATE"
ev RESULT "$STATUS" "$([ -s "$SHOT" ] && echo "$SHOT")"
[ "$STATUS" = ko ] && exit 2
exit 0
