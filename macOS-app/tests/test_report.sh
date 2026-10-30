#!/bin/bash
# rapport_mac.sh tests: one run only (no green result of an older run), every status labelled, no false success,
# date + tested path + proof present, HTML escaped.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REP="$ROOT/macOS/rapport_mac.sh"
TMP="$(mktemp -d /tmp/ti4d_test_rep.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (report): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
T=$'\t'
mk() { # file run lang rows... (row = action|status|detail|date|path)
  local f="$1" run="$2" l="$3" r; shift 3
  { printf '#RUN\t%s\n#DATE\t2026-10-22 10:00:00\n#PRODUCT\t4D\n#OS\tmacOS 27.0.1\n#LANG\t%s\n#PLATFORM\tmacOS ARM\n#DMG\t/Users/x/4D 21.2.dmg\n#HASH\t4D 21.2.dmg\tABCDEF\n#VERSION\t21.2\n#BUILD\t100629\n#INSTALLED\t/Applications/4D 21.2/4D.app\n#LOCALE\tAppleLanguages=(%s)\n' "$run" "$l" "$l"
    for r in "$@"; do printf '%s\n' "$r" | tr '|' '\t'; done; } > "$f"
}
D="$TMP/results"; mkdir "$D"
mk "$D/21.2_100629_FR.tsv" R1 FR "The download|ok|old ok|2026-10-01 09:00:00|/old.dmg" "Execution of application (without Internet)|ok|old green|2026-10-01 09:00:00|/old/4D.app"
touch "$D/21.2_100629_FR_about.png"
sleep 1
mk "$D/21.2_100629_EN.tsv" R2 EN \
  "The download|ok|hdiutil verify OK|2026-10-22 10:00:01|/Users/x/4D 21.2.dmg" \
  "Installation of 4D|ok|copied, version 21.2 build 100629|2026-10-22 10:00:02|/Applications/4D 21.2/4D.app" \
  "Execution of application (with Internet)|undetermined|no proof of start in 120 s|2026-10-22 10:01:00|/Applications/4D 21.2/4D.app" \
  "Notarization ticket (stapling)|ko|stapler: no ticket\\nsecond line|2026-10-22 10:01:30|/Applications/4D 21.2/4D.app" \
  "Execution of application (without Internet)|notrun|Internet still reachable (3 probes)|2026-10-22 10:02:00|/Applications/4D 21.2/4D.app" \
  "Version number|action|close the dialog <script>alert(1)</script> & retry|2026-10-22 10:03:00|/Applications/4D 21.2/4D.app" \
  "ReadMe|weird|?|2026-10-22 10:04:00|" \
  "Execution of application|ok|row of an older engine|2026-10-22 10:05:00|/x"
out="$(bash "$REP" "$D" 21.2_100629 4D 21.2 100629 "macOS ARM" R2)"; rc=$?
H="$D/rapport_21.2_100629.html"; M="$D/rapport_21.2_100629.md"
check test "$rc" = 0; check test "$out" = "$H"; check test -s "$M"
hdr="$(grep '^| Actions' "$M")"
check test "$hdr" = "| Actions | EN |"                  # FR of run R1 not merged
check grep -q 'Ignorés.*FR' "$M"
check not grep -q 'old green' "$M" "$H"
check not grep -q '_FR_about.png' "$M" "$H"
row() { grep -F "| $1 |" "$M" | head -1; }
check grep -q '✅ OK' <<< "$(row 'The download')"
check grep -q '❔ Indéterminé' <<< "$(row 'Execution of application (with Internet)')"
check grep -q '❌ Échec — stapler: no ticket |' <<< "$(row 'Notarization ticket (stapling)')"
check grep -q '⏭️ Non exécuté' <<< "$(row 'Execution of application (without Internet)')"
check grep -q '✋ Action requise' <<< "$(row 'Version number')"
check grep -q '❔ weird' <<< "$(row 'ReadMe')"
check grep -q '| — |' <<< "$(row '"Components" folder')"    # no result: never blank, never green
check grep -q '✅ OK' <<< "$(row 'Execution of application')" # legacy row kept, not dropped
# exactly 3 green cells in the table (download, installation, legacy row)
check test "$(grep '^| ' "$M" | grep -o '✅' | wc -l | tr -d ' ')" = 3
check test "$(grep -o 'class="st ok"' "$H" | wc -l | tr -d ' ')" -ge 3
check not grep -q '<script>' "$H"; check grep -q '&lt;script&gt;alert(1)&lt;/script&gt; &amp; retry' "$H"
check grep -q 'Internet still reachable (3 probes)' "$M"
check grep -q '2026-10-22 10:02:00 — `/Applications/4D 21.2/4D.app`' "$M"
check grep -q 'Image disque : /Users/x/4D 21.2.dmg' "$M"
check grep -q 'Application testée : /Applications/4D 21.2/4D.app' "$M"
check grep -q 'Exécution.*R2' "$M"
check grep -q 'SHA-256 `ABCDEF`' "$M"
check grep -q 'Synthèse.*✅ OK : 3.*❌ Échec : 1' "$M"
check grep -q 'prefers-color-scheme:dark' "$H"
check grep -qF '<details open><summary><span class="st notrun">' "$H"
check grep -qF '<details open><summary><span class="st undetermined">' "$H"
check grep -qF '<details><summary><span class="st ok">' "$H"
# without run id: run of the most recent file (R2), never the older green run
bash "$REP" "$D" 21.2_100629 4D 21.2 100629 "macOS ARM" > /dev/null
check test "$(grep '^| Actions' "$M")" = "| Actions | EN |"
RUN_ID=R1 bash "$REP" "$D" 21.2_100629 4D 21.2 100629 "macOS ARM" > /dev/null
check test "$(grep '^| Actions' "$M")" = "| Actions | FR |"
# same run, two languages: both columns
mk "$D/21.2_100629_DE.tsv" R2 DE "The download|ko|hdiutil verify FAILED|2026-10-22 10:00:01|/x.dmg"
bash "$REP" "$D" 21.2_100629 4D 21.2 100629 "macOS ARM" R2 > /dev/null
check test "$(grep '^| Actions' "$M")" = "| Actions | EN | DE |"
check grep -q '| ✅ OK | ❌ Échec — hdiutil verify FAILED |' <<< "$(row 'The download')"
# unknown run: no report produced
cp "$H" "$TMP/before.html"
bash "$REP" "$D" 21.2_100629 4D 21.2 100629 "macOS ARM" R9 > "$TMP/o" 2>&1; check test $? = 1
check test ! -s "$TMP/o" -o -z "$(grep -F "$H" "$TMP/o")"
# window of the disk image: row placed right after the download, screenshot shown as proof, "À vérifier" until confirmed
E="$TMP/dw"; mkdir "$E"
mk "$E/21.2_100629_EN.tsv" R3 EN "Installation of 4D|ok|copied|2026-10-22 10:00:02|/A/4D.app" \
  "DMG window (before installation)|manual|[ok] window displayed|2026-10-22 10:00:01|/w/dmg_window.png" \
  "The download|ok|verified|2026-10-22 10:00:00|/x.dmg"
bash "$REP" "$E" 21.2_100629 4D 21.2 100629 "macOS ARM" R3 > /dev/null
EM="$E/rapport_21.2_100629.md"; EH="$E/rapport_21.2_100629.html"
order="$(grep -E '^\| (The download|DMG window|Installation of 4D)' "$EM" | cut -d'|' -f2 | tr -d ' ' | tr '\n' ,)"
check test "$order" = "Thedownload,DMGwindow(beforeinstallation),Installationof4D,"
check grep -q '⚠️ À vérifier' <<< "$(grep '^| DMG window' "$EM")"
check not grep -q 'dmg_window.png"' "$EH"                 # no screenshot file: no image shown
printf 'PNG' > "$E/21.2_100629_dmg_window.png"
bash "$REP" "$E" 21.2_100629 4D 21.2 100629 "macOS ARM" R3 > /dev/null
check grep -q '<img src="21.2_100629_dmg_window.png"' "$EH"
check grep -q '](21.2_100629_dmg_window.png)' "$EM"

echo "report: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
