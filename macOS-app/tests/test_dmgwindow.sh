#!/bin/bash
# dmg_window.sh tests: checks of the window of the disk image before installation. A real small image is built
# (folder with the product, Applications link, ReadMe, layout); Finder and screencapture are mocks, so the result
# only depends on what the "window" reports. The verdict is automatic: ok only if identical to the reference window.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DW="$ROOT/macOS/dmg_window.sh"
TMP="$(mktemp -d /tmp/ti4d_test_dw.XXXXXX)"
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (dmgwindow): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
VER=97.3; VOLN="4D $VER Release"
cleanup() { [ -d "/Volumes/$VOLN" ] && hdiutil detach -quiet "/Volumes/$VOLN" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

mk() { # name: image with the expected structure; options remove parts
  local s="$TMP/src_$1"; mkdir -p "$s/4D $VER/4D.app/Contents"
  printf 'x' > "$s/4D $VER/4D.app/Contents/Info.plist"
  case " $* " in *" noapps "*) ;; *) ln -s /Applications "$s/Applications";; esac
  mkdir -p "$s/.background"; printf 'BG-%s' "${BGV:-ref}" > "$s/.background/Background.png"
  case " $* " in *" noreadme "*) ;; *) printf '%%PDF-1.4 readme' > "$s/ReadMe.pdf";; esac
  # hdiutil -srcfolder leaves .DS_Store out: written into a read-write image, then converted
  hdiutil create -quiet -srcfolder "$s" -format UDRW -volname "$VOLN" "$TMP/$1_rw.dmg" || { echo "cannot create test image" >&2; exit 1; }
  local m="$TMP/m_$1"; mkdir -p "$m"
  hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$m" "$TMP/$1_rw.dmg" && printf 'layout' > "$m/.DS_Store" && hdiutil detach -quiet "$m"
  hdiutil convert -quiet "$TMP/$1_rw.dmg" -format UDZO -o "$TMP/$1.dmg" && rm -f "$TMP/$1_rw.dmg"
}
mk good; mk noapps noapps; mk noreadme noreadme; BGV=other mk otherbg
REFF="$TMP/ref.tsv"; sed "s/^BACKGROUND_SHA256.*/BACKGROUND_SHA256\t$(printf 'BG-ref' | shasum -a 256 | cut -d' ' -f1)/" "$ROOT/macOS/dmg_window_reference.tsv" > "$REFF"
export DMG_WINDOW_REF="$REFF"

cat > "$TMP/finder" <<'EOF'
#!/bin/bash
echo "$*" >> "$DWT/probe.log"
[ "$1" = close ] && exit 0
M="$(cat "$DWT/mode" 2>/dev/null)"
case "$M" in denied) echo "execution error: Not authorized to send Apple events to Finder. (-1743)"; exit 1;;
  broken) echo "boom"; exit 1;; none) printf 'had=0\nwindow=none\n'; exit 0;; esac
N="$(basename "$2")"; [ "$M" = title ] && N="Other"
F="4D 97.3"; A=460; FY=145; R=300; RY=325; V="icon view"
case "$M" in shift) A=470;; small) IS=64;; swap) F="4D 97.3"; A=140; FX=460;; overlap) A=180;; out) RY=440;; list) V="list view";; esac
printf 'had=%s\nname=%s\nview=%s\nbounds=100,100,700,550\ntoolbar=false\niconsize=%s\n' "$(cat "$DWT/had" 2>/dev/null || echo 0)" "$N" "$V" "${IS:-128}"
printf 'item=%s\t%s,%s\nitem=Applications\t%s,145\nitem=ReadMe.pdf\t%s,%s\n' "$F" "${FX:-140}" "$FY" "$A" "$R" "$RY"
EOF
cat > "$TMP/shot" <<'EOF'
#!/bin/bash
[ -f "$DWT/noshot" ] && exit 1
for a; do f="$a"; done; printf 'PNG' > "$f"
EOF
chmod +x "$TMP/finder" "$TMP/shot"
export DWT="$TMP" FINDER_PROBE="$TMP/finder" SCREENCAPTURE="$TMP/shot"
ST="$TMP/w/dmg_window.tsv"; mkdir -p "$TMP/w"
run() { # mode image [version]
  printf '%s' "$1" > "$TMP/mode"; : > "$TMP/probe.log"
  OUT="$(bash "$DW" --dmg "$TMP/$2.dmg" --product 4D --version "${3:-$VER}" --build 100629 --state "$ST" 2>&1)"; RC=$?
}
get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$ST"; }
has() { grep -qF -- "$1" <<< "$OUT"; }
mounted() { [ -d "/Volumes/$VOLN" ]; }

run ok good
check [ "$RC" = 0 ]; check [ "$(get STATUS)" = ok ]
check has $'RESULT\tok'; check has 'window identical to the reference'; check grep -q '^VERDICT.automatic: identical' "$ST"
check has 'window displayed, title "4D 97.3 Release"'
check has '"4D 97.3" left of "Applications" on the same row'
check has '"Applications" is a link to /Applications'
check has '"ReadMe.pdf" present'
check [ -s "$(get SHOT)" ]
check [ "$(get STAMP)" = "$(stat -f '%z %m' "$TMP/good.dmg")" ]
check [ "$(get BUILD)" = 100629 ]
check not mounted                               # own mount detached
check grep -q "^close /Volumes/$VOLN/" "$TMP/probe.log"  # window it opened is closed

# automatic comparison with the reference window (21.2): any difference is ko, never pending
run shift good; check [ "$RC" = 2 ]; check [ "$(get STATUS)" = ko ]; check has '"Applications" at (470,145) instead of (460,145)'
run small good; check [ "$(get STATUS)" = ko ]; check has 'icons 64 pt instead of 128'
run ok otherbg; check [ "$(get STATUS)" = ko ]; check has 'background image differs from the reference'
DMG_WINDOW_REF="$TMP/none.tsv" run ok good; check [ "$(get STATUS)" = error ]; check has 'reference window missing'
check not grep -q pending "$ST"
run ok good 21.2; check [ "$RC" = 2 ]; check [ "$(get STATUS)" = ko ]; check has 'does not contain the selected version 21.2'
check [ -s "$(get SHOT)" ]                       # still captured as proof of the failure
run ok noapps; check [ "$RC" = 2 ]; check has 'no "Applications" link'
run ok noreadme; check [ "$RC" = 2 ]; check has 'no ReadMe (PDF)'
run title good; check [ "$(get STATUS)" = ko ]; check has 'window title "Other"'
run swap good; check [ "$(get STATUS)" = ko ]; check has 'drag to install is not shown'
run overlap good; check [ "$(get STATUS)" = ko ]; check has 'overlapping icons'
run out good; check [ "$(get STATUS)" = ko ]; check has 'is cut or outside the visible area'
run list good; check [ "$(get STATUS)" = ko ]; check has 'instead of the icon view'
run none good; check [ "$(get STATUS)" = ko ]; check has 'no Finder window opened'
run denied good; check [ "$RC" = 4 ]; check [ "$(get STATUS)" = action ]; check has 'Automation > Finder'
check not grep -q '^close' "$TMP/probe.log"
run broken good; check [ "$RC" = 1 ]; check [ "$(get STATUS)" = error ]
touch "$TMP/noshot"; run ok good; check [ "$RC" = 4 ]; check [ "$(get STATUS)" = action ]; check has 'Screen Recording'
check [ -z "$(get SHOT)" ]; rm -f "$TMP/noshot"
check not mounted

# image already mounted by the user (window already open): used as is, left mounted, window not closed
hdiutil attach -quiet -nobrowse -noautoopen "$TMP/good.dmg" || bad "attach"
echo 1 > "$TMP/had"; run ok good
check [ "$(get STATUS)" = ok ]; check has 'already mounted by the user'
check mounted; check not grep -q '^close' "$TMP/probe.log"
echo 0 > "$TMP/had"; run ok good; check mounted
hdiutil detach -quiet "/Volumes/$VOLN"

# a previous result never survives a new check
run broken good; check [ -z "$(get SHOT)" ]
bash "$DW" --dmg "$TMP/missing.dmg" --product 4D --version $VER --build 1 --state "$ST" >/dev/null 2>&1; check [ $? != 0 ]
check [ "$(get STATUS)" != pending ]; check [ "$(get STATUS)" != ok ]

echo "dmgwindow: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
