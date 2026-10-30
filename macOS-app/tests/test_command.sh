#!/bin/bash
# "Test Installer 4D.command" tests, driven by expect: the DMG is chosen by the user from complete downloads only,
# a product / version / build not in the DMG is refused (never replaced by another one), the installation is
# confirmed (existing installation: replace only on request), one RUN_ID for all the languages of a run, and the
# quarantine of downloaded files is kept. The engine, the installer and the report are stubs.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_cmd.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (command): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }

K="$TMP/kit"; H="$TMP/home"; mkdir -p "$K" "$H/Downloads" "$TMP/src/4D 21.2/4D.app/Contents" "$TMP/apps"
for f in "Test Installer 4D.command" version.sh dmg_info.sh dmg_mount.sh download_4d.sh; do cp "$ROOT/macOS/$f" "$K/"; done
cat > "$TMP/src/4D 21.2/4D.app/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>21.2 build 21.100629</string><key>CFBundleIdentifier</key><string>com.4D.4D</string></dict></plist>
P
hdiutil create -quiet -srcfolder "$TMP/src" -format UDZO -volname "4D 21.2" "$H/Downloads/4D_21.2.dmg" || exit 1
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>https://builds2.4d.com/x.dmg</string></array></plist>' > "$TMP/wf.plist"
plutil -convert binary1 "$TMP/wf.plist"; xattr -wx com.apple.metadata:kMDItemWhereFroms "$(xxd -p "$TMP/wf.plist" | tr -d '\n')" "$H/Downloads/4D_21.2.dmg"
Q="0081;6512abcd;Safari;11111111-2222-3333-4444-555555555555"
xattr -w com.apple.quarantine "$Q" "$H/Downloads/4D_21.2.dmg"
cp "$H/Downloads/4D_21.2.dmg" "$K/kit_copy.dmg"; xattr -w com.apple.quarantine "$Q" "$K/kit_copy.dmg"
cp "$H/Downloads/4D_21.2.dmg" "$H/Downloads/partial.dmg"; echo x > "$H/Downloads/partial.dmg.crdownload"
head -c 2000 "$H/Downloads/4D_21.2.dmg" > "$H/Downloads/trunc.dmg"   # no UDIF trailer: not usable
touch -t 202001010000 "$K/kit_copy.dmg" "$H/Downloads/"*
# stubs
cat > "$K/install_4d.sh" <<'S'
#!/bin/bash
echo "$*" >> "$TI4D_TMP/install_calls"
printf 'STEP\tMontage du DMG\nPROGRESS\t50\tCopie\n'
if [ ! -f "$TI4D_TMP/installed" ] && [[ " $* " != *" --replace "* ]] && [[ " $* " != *" --adopt "* ]] && [ -f "$TI4D_TMP/exists" ]; then
  printf 'EXISTS\t/x/4D 21.2/4D.app\t21.2\t100624\tdifferent\nERROR\tEXISTS\tan installation exists\nRESULT\tko\t\n'; exit 3; fi
touch "$TI4D_TMP/installed"; printf 'RESULT\tok\t/x/4D 21.2/4D.app\n'
S
cat > "$K/qa_mac.sh" <<'S'
#!/bin/bash
. "$(dirname "$0")/kit.conf"
echo "$1|$RUN_ID|$DMG|$PRODUCT|$VERSION|$BUILD" >> "$TI4D_TMP/qa_calls"
echo "${NET_SESSION:-}|${NET_GUARD_NOTE:-}|$NET_AUTO" >> "$TI4D_TMP/net_env"
printf '#RUN\t%s\n#LANG\t%s\nThe download\tok\tx\t2026\t%s\n' "$RUN_ID" "$1" "$DMG" > "$(dirname "$0")/qa_mac_results.tsv"
S
cat > "$K/net_guard.sh" <<'S'
#!/bin/bash
echo "$*" >> "$TI4D_TMP/ng_calls"
case "$1" in
  start) rc="$(cat "$TI4D_TMP/ng_rc" 2>/dev/null || echo 0)"
         case "$rc" in 0) echo READY;; 2) echo DECLINED;; *) echo "ERROR pf.conf does not evaluate com.apple/*";; esac; exit "$rc";;
esac
S
cat > "$K/rapport_mac.sh" <<'S'
#!/bin/bash
echo "$7" >> "$TI4D_TMP/rep_calls"; echo "$1/rapport.html"
S
mkdir -p "$TMP/bin"; printf '#!/bin/bash\necho "$*" >> "$TI4D_TMP/open_calls"\n' > "$TMP/bin/open"; chmod +x "$TMP/bin/open"
export TI4D_TMP="$TMP" HOME="$H" PATH="$TMP/bin:$PATH"

drive() { # expect script body
  cat > "$TMP/s.exp" <<X
set timeout 30
log_file -noappend "$TMP/session.log"
spawn bash "$K/Test Installer 4D.command"
proc step {pat ans} {
  expect {
    -ex \$pat { send -- "\$ans\r" }
    timeout { puts "\nTIMEOUT waiting for: \$pat"; exit 2 }
    eof { puts "\nEOF waiting for: \$pat"; exit 3 }
  }
}
$1
expect eof
X
  expect "$TMP/s.exp" > /dev/null 2>&1; echo $? > "$TMP/exp_rc"
}

# 1. full run: wrong product, wrong build, existing installation replaced on request, two languages
touch "$TMP/exists"
drive '
step "Votre choix" "1"
step "Produit" "4D Server"
step "Produit" "4D"
step "Version attendue" ""
step "Build attendu" "100628"
step "quitter" "r"
step "Version attendue" ""
step "Build attendu" ""
step "Plateforme" "macOS ARM"
step "Langue" "FR EN"
step "moin" "n"
step "GitHub" "n"
step "sans Internet automatique" "n"
step "Installer 4D 21.2 build 100629" "o"
step "destination" "'"$TMP/apps"'"
step "r = la remplacer" "r"
step "Entrée pour fermer" ""'
L="$TMP/session.log"
check test "$(cat "$TMP/exp_rc")" = 0
check grep -q '1) 4D_21.2.dmg' "$L"; check grep -q 'kit_copy.dmg' "$L"
check grep -q 'partial.dmg  (téléchargement en cours : non utilisable)' "$L"
check not grep -qE '[0-9]\) partial.dmg' "$L"
check grep -q "trunc.dmg  (fin d'image disque absente : non utilisable)" "$L"; check not grep -qE '[0-9]\) trunc.dmg' "$L"
check grep -q "« 4D Server » n'est pas dans ce DMG (produits présents : 4D)" "$L"
check grep -q 'Le DMG contient 4D 21.2 build 100629, pas 21.2 build 100628' "$L"
check test "$(wc -l < "$TMP/install_calls" | tr -d ' ')" = 2
check grep -q -- "--dmg $H/Downloads/4D_21.2.dmg --product 4D --version 21.2 --build 100629 --platform macOS ARM --dest $TMP/apps\$" "$TMP/install_calls"
check test "$(sed -n 2p "$TMP/install_calls" | grep -c -- '--replace$')" = 1
check grep -q 'Installation existante : /x/4D 21.2/4D.app (21.2 build 100624)' "$L"
check grep -q 'Installé et vérifié : /x/4D 21.2/4D.app' "$L"
check test "$(cut -d'|' -f1 "$TMP/qa_calls" | paste -sd' ' -)" = "FR EN"
check test "$(cut -d'|' -f2 "$TMP/qa_calls" | sort -u | wc -l | tr -d ' ')" = 1   # one RUN_ID for the run
check test -n "$(cut -d'|' -f2 "$TMP/qa_calls" | head -1)"
check test "$(cut -d'|' -f3-6 "$TMP/qa_calls" | sort -u)" = "$H/Downloads/4D_21.2.dmg|4D|21.2|100629"
check test "$(sort -u "$TMP/rep_calls")" = "$(cut -d'|' -f2 "$TMP/qa_calls" | head -1)"
check test "$(xattr -p com.apple.quarantine "$H/Downloads/4D_21.2.dmg")" = "$Q"
check test "$(xattr -p com.apple.quarantine "$K/kit_copy.dmg")" = "$Q"   # versions < 3.4 cleared it on the kit
check test -z "$(hdiutil info | grep -F "$H/Downloads/4D_21.2.dmg")"      # dmg_info detached its own mount

# 2. existing installation kept (no replacement without confirmation), no installation asked
rm -f "$TMP/install_calls" "$TMP/qa_calls" "$TMP/installed"
drive '
step "Votre choix" "1"
step "Produit" ""
step "Version attendue" ""
step "Build attendu" ""
step "Plateforme" ""
step "Langue" "FR"
step "moin" "n"
step "GitHub" "n"
step "sans Internet automatique" "n"
step "Installer" "o"
step "destination" ""
step "r = la remplacer" "a"
step "Entrée pour fermer" ""'
check test "$(wc -l < "$TMP/install_calls" | tr -d ' ')" = 1
check not grep -q -- '--replace\|--adopt' "$TMP/install_calls"
check grep -q -- "--dest $TMP/apps\$" "$TMP/install_calls"  # destination remembered from the previous run
check grep -q 'Installation non effectuée : les tests d.exécution seront « Non exécuté »' "$TMP/session.log"
rm -f "$TMP/install_calls"
drive '
step "Votre choix" "1"
step "Produit" ""
step "Version attendue" ""
step "Build attendu" ""
step "Plateforme" ""
step "Langue" "FR"
step "moin" "n"
step "GitHub" "n"
step "sans Internet automatique" "n"
step "Installer" "n"
step "Entrée pour fermer" ""'
check test ! -e "$TMP/install_calls"
check grep -q 'Installation non demandée' "$TMP/session.log"
check test ! -e "$TMP/ng_calls"                                    # no automatic cut asked: the guard is never started
check test "$(tail -1 "$TMP/net_env")" = "1||0"

# 2b. automatic offline test: the guard is started once for the run (owner = the .command), stopped at the end
drive_net() { rm -f "$TMP/ng_calls" "$TMP/net_env"; drive '
step "Votre choix" "1"
step "Produit" ""
step "Version attendue" ""
step "Build attendu" ""
step "Plateforme" ""
step "Langue" "FR EN"
step "moin" "n"
step "GitHub" "n"
step "sans Internet automatique" "'"$1"'"
step "Installer" "n"
step "Entrée pour fermer" ""'; }
echo 0 > "$TMP/ng_rc"; drive_net o
check test "$(cat "$TMP/exp_rc")" = 0
check test "$(grep -c '^start ' "$TMP/ng_calls")" = 1                # one permission for both languages
check grep -qE '^start [0-9]+$' "$TMP/ng_calls"
check test "$(tail -1 "$TMP/ng_calls")" = quit                      # lifted when the script ends
check test "$(sort -u "$TMP/net_env")" = "1||1"
check grep -q 'Garde réseau prêt' "$TMP/session.log"
check grep -q '^NET_AUTO=1$' "$K/kit.conf"
echo 2 > "$TMP/ng_rc"; drive_net ""                                 # default remembered from kit.conf: o
check test "$(grep -c '^start ' "$TMP/ng_calls")" = 1
check not grep -q '^quit' "$TMP/ng_calls"
check test "$(sort -u "$TMP/net_env")" = "1|automatic cut declined at the start of the run|1"
check grep -q 'Coupure automatique refusée' "$TMP/session.log"
echo 1 > "$TMP/ng_rc"; drive_net o
check test "$(sort -u "$TMP/net_env")" = "1|automatic cut unavailable: pf.conf does not evaluate com.apple/*|1"
check grep -q 'Coupure automatique indisponible' "$TMP/session.log"
drive_net n
check test ! -e "$TMP/ng_calls"
check grep -q '^NET_AUTO=0$' "$K/kit.conf"

# 3. the download page is opened in the browser on request (sign-in there), then the list is refreshed
drive '
step "Votre choix" "t"
step "Votre choix" "q"'
check grep -q '^https://product-download.4d.com/$' "$TMP/open_calls"
echo "command: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
