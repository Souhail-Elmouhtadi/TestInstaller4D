#!/bin/bash
# No quarantine attribute is ever removed (app, kit, installation scripts, tests): Gatekeeper must assess what it
# assesses for a user. Static guard over the whole project, then the real mechanisms with a quarantined image:
#  - a quarantined kit script still runs with bash (bash script.sh is not assessed by Gatekeeper);
#  - the 4D test copy is made without quarantine (ditto --noqtn, user decision) while the pristine copy used by the
#    Gatekeeper test keeps it, and the image keeps its own;
#  - the helpers only run from Contents/Helpers of the signed app, never from a copy in the kit.
# TI4D_ROOT=<copy of the project> runs it on another tree (mutation tests).
set -uo pipefail
ROOT="${TI4D_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SELF="macOS-app/tests/test_quarantine.sh"
TMP="$(mktemp -d /tmp/ti4d_test_qtn.XXXXXX)"
MNT=""
trap '[ -n "$MNT" ] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1; rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (quarantine): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
qtn() { xattr -p com.apple.quarantine "$1" 2>/dev/null; }

# ---- static guard ----
# xattr with a delete or clear option in any form (-d, -dr, -rd, -r -d, -c, -cr), the C call, the Foundation key,
# Gatekeeper switched off
REMOVAL='xattr([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*[dc]|removexattr|QuarantineProperties|spctl[^|;&]*--(master-disable|global-disable|disable)'
for l in 'xattr -d com.apple.quarantine f' 'xattr -dr com.apple.quarantine "$D"' 'xattr -rd com.apple.quarantine d' \
         'xattr -r -d com.apple.quarantine d' 'xattr -c "$APP"' 'xattr -cr d' '/usr/bin/xattr -d com.apple.quarantine x' \
         '[ -e "$f" ] && xattr -d com.apple.quarantine "$f" 2>/dev/null' 'removexattr(p, "com.apple.quarantine", 0)' \
         'spctl --master-disable' 'sudo spctl --global-disable'; do
  check grep -qE "$REMOVAL" <<< "$l"
done
for l in 'xattr -w com.apple.quarantine "$Q" f' 'xattr -p com.apple.quarantine f' 'xattr -l f' \
         'xattr -px com.apple.metadata:kMDItemWhereFroms "$1"' 'xattr -wx com.apple.metadata:kMDItemWhereFroms "$h" "$f"' \
         'spctl -a -vv -t exec "$app"' 'ditto "$SRCAPP" "$PAPP"'; do
  check not grep -qE "$REMOVAL" <<< "$l"
done
R="$(grep -rInE --exclude-dir=Windows --exclude-dir=.git "$REMOVAL" "$ROOT" 2>/dev/null | grep -v "^$ROOT/$SELF:")"
check test -z "$R"
[ -z "$R" ] || printf 'quarantine removal found:\n%s\n' "$R" >&2

# copies without quarantine: only the 4D test copy of qa_mac.sh (application + its Components)
U="$(grep -rnE --include='*.sh' --include='*.command' --include='*.swift' '^[^#]*--noqtn' "$ROOT" 2>/dev/null | grep -v "^$ROOT/$SELF:")"
check test "$(grep -c . <<< "$U")" = 2
check test "$(grep -c "^$ROOT/macOS/qa_mac.sh:" <<< "$U")" = 2
check test "$(grep -cE 'ditto --noqtn "\$(SRCAPP|CMP)" "\$TAPP' <<< "$U")" = 2
Q="$ROOT/macOS/qa_mac.sh"
check grep -qE '^fresh_pristine\(\) \{ rm -rf "\$PAPP"; ditto "\$SRCAPP" "\$PAPP"; quarantine "\$PAPP"; \}$' "$Q"

# helpers: only those of the signed app
check not grep -qE 'KIT/(about_check|readme_check)' "$Q"
check grep -qx 'ABOUT_CHECK="${ABOUT_CHECK:-$(ti4d_helper about_check)}"' "$Q"
check grep -qx 'README_CHECK="${README_CHECK:-$(ti4d_helper readme_check)}"' "$Q"
RS="$ROOT/macOS-app/Runner.swift"
KITF="$(sed -n '/func installKit()/,/func loadPreviousConf()/p' "$RS")"
check test "$(grep -c 'copyItem' <<< "$KITF")" = 1          # the kit itself; no helper copy
check not grep -q 'helper(' <<< "$KITF"
check grep -q 'for name in \["about_check", "readme_check"\]' <<< "$KITF" # stale copies of versions < 3.4 removed
check grep -q 'removeItem' <<< "$KITF"
HF="$(sed -n '/func helper(_ name: String)/,/^    }/p' "$RS")"
check grep -q 'Contents/Helpers' <<< "$HF"
check not grep -q 'kit/' <<< "$HF"
eval "$(sed -n '/^ti4d_helper() {/,/^}/p' "$Q")"
if declare -F ti4d_helper >/dev/null; then
  FA="$TMP/Other place/Test Installer 4D.app"; mkdir -p "$FA/Contents/Helpers"
  printf '#!/bin/sh\n' > "$FA/Contents/Helpers/about_check"; chmod +x "$FA/Contents/Helpers/about_check"
  check test "$(TI4D_APP="$FA" ti4d_helper about_check)" = "$FA/Contents/Helpers/about_check"
  r="$(TI4D_APP="$FA" HOME="$TMP/nohome" ti4d_helper readme_check)" # not in that app: an installed app, never the kit
  case "$r" in "/Applications/Test Installer 4D.app/Contents/Helpers/readme_check"|"$TMP/nohome/Applications/Test Installer 4D.app/Contents/Helpers/readme_check") ok;; *) bad "helper path $r";; esac
else bad "ti4d_helper not found in qa_mac.sh"; fi

# installation of the app: quarantine kept, first-launch steps shown, documented
I="$ROOT/macOS-app/install.sh"
check grep -qE '^rm -rf "\$DST" && ditto "\$SRC" "\$DST" \|\| ' "$I"
check grep -q 'xattr -p com.apple.quarantine "$DST"' "$I"
check grep -q 'Ouvrir quand même' "$I"
for d in "$ROOT/LISEZMOI.txt" "$ROOT/GUIDE_Test_Installer_4D.txt"; do
  check grep -q 'Ouvrir quand même' "$d"
  check grep -q 'Developer ID' "$d"
  check grep -q 'noqtn' "$d"
done

# ---- real mechanisms: quarantined image ----
S="$TMP/src/4D 21.2"; mkdir -p "$S/4D.app/Contents/MacOS" "$S/Components/X.4dbase"
printf '#!/bin/sh\n' > "$S/4D.app/Contents/MacOS/4D"; chmod +x "$S/4D.app/Contents/MacOS/4D"
cat > "$S/4D.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>21.2 build 21.100629</string><key>CFBundleIdentifier</key><string>com.4D.4D</string><key>CFBundleExecutable</key><string>4D</string></dict></plist>
P
QV="0081;6512abcd;Safari;11111111-2222-3333-4444-555555555555"
if hdiutil create -quiet -srcfolder "$TMP/src" -format UDZO -volname "4D 21.2" "$TMP/4D.dmg"; then
  xattr -w com.apple.quarantine "$QV" "$TMP/4D.dmg"
  # a quarantined kit script runs with bash
  K="$TMP/kit"; mkdir -p "$K"
  for f in version.sh dmg_info.sh dmg_mount.sh; do cp "$ROOT/macOS/$f" "$K/"; xattr -w com.apple.quarantine "$QV" "$K/$f"; done
  out="$(/bin/bash "$K/dmg_info.sh" "$TMP/4D.dmg" 2>&1)"
  check test "$(cut -f1-3 <<< "$out")" = "$(printf '4D\t21.2\t100629')"
  check test "$(qtn "$K/dmg_info.sh")" = "$QV"
  # the copies of qa_mac.sh, run as they are written
  MNT="$TMP/mnt"; mkdir -p "$MNT"
  if hdiutil attach -nobrowse -readonly -noverify -noautoopen -mountpoint "$MNT" "$TMP/4D.dmg" >/dev/null 2>&1; then
    BLOCK="$(sed -n '/^# copies: pristine/,/ditto --noqtn "\$CMP"/p' "$Q")"
    WORK="$TMP/work"; SRCAPP="$MNT/4D 21.2/4D.app"; APPNAME=4D.app; CMP="$MNT/4D 21.2/Components"; TAPP=""; PAPP=""
    if [ "$(grep -c . <<< "$BLOCK")" -ge 8 ]; then
      eval "$BLOCK"; fresh_pristine
      ditto "$SRCAPP" "$TMP/control.app" # control: a plain copy from this image carries its quarantine
      check test -n "$(qtn "$TMP/control.app/Contents/MacOS/4D")"
      check test -x "$TAPP/Contents/MacOS/4D"
      check test -z "$(qtn "$TAPP")"
      check test -z "$(qtn "$TAPP/Contents/MacOS/4D")"
      check test -d "$TAPP/Contents/Components/X.4dbase"
      check test -z "$(qtn "$TAPP/Contents/Components/X.4dbase")"
      check test -n "$(qtn "$PAPP")"
      check test -n "$(qtn "$PAPP/Contents/MacOS/4D")"
    else bad "copy block not found in qa_mac.sh"; fi
    hdiutil detach "$MNT" -quiet && MNT=""
  else bad "cannot mount the test image"; fi
  check test "$(qtn "$TMP/4D.dmg")" = "$QV"
else bad "cannot create the test image"; fi

echo "quarantine: $pass passed, $failn failed"
[ "$failn" = 0 ]
