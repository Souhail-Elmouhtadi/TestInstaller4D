#!/bin/bash
# Actual checklist sections with temporary inventories; no application, network or system changes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_diag.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
. "$ROOT/macOS/results.sh"
pass=0; failn=0
check() {
  if "$@"; then pass=$((pass+1)); else
    echo "FAILED (diagnostics): $* [line ${BASH_LINENO[0]}]" >&2; failn=$((failn+1))
  fi
}
contains() { grep -qF -- "$1" <<< "$D"; }
EXPECTED_COMPS="$(cat "$ROOT/macOS/comps_20.txt")"
COMPS="$ROOT/macOS/comps_20.txt"; NCOMPS=6
MNT="$TMP/image"; SRCAPP="$MNT/4D.app"; WORK="$TMP/work"
PRODUCT=4D; VERSION=20.9; BUILD=100123; LANG_CODE=EN
A_COMPS='"Components" folder'; OUT="$TMP/results.tsv"
mkdir -p "$MNT/Components" "$SRCAPP/Contents" "$WORK"
sed -n '/^# 5\. Components folder/,/^# 6\. plugins (static)/{ /^# 6\. plugins (static)/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/folder.sh"
while IFS= read -r name; do mkdir "$MNT/Components/$name"; done <<< "$EXPECTED_COMPS"
touch "$MNT/Components/.DS_Store"
. "$TMP/folder.sh" > /dev/null
check test "$ST" = ok
check contains "expected 6, observed 6"
check contains "4D NetKit.4dbase"
# Concrete request: 8 instead of 6, two explicitly named unexpected entries.
mkdir "$MNT/Components/Extra A.4dbase" "$MNT/Components/Extra B.4dbase"
. "$TMP/folder.sh" > /dev/null
check test "$ST" = ko
check contains "expected 6, observed 8"
check contains "Missing: (none)"
check contains "Unexpected: Extra A.4dbase, Extra B.4dbase"
check contains "Action: Check the DMG"
check test "$(awk -F'\t' 'END{print $5}' "$OUT")" = "$MNT/Components"
# Equal counts do not hide substitutions; names are compared literally, not as regexes.
rmdir "$MNT/Components/Extra B.4dbase" "$MNT/Components/4D NetKit.4dbase"
. "$TMP/folder.sh" > /dev/null
check test "$ST" = ko
check contains "expected 6, observed 6"
check contains "Missing: 4D NetKit.4dbase"
check contains "Unexpected: Extra A.4dbase"
begin
check_items Literal $'4D A[kit]\r\n\n4D B\r\n' $'4D B\n4D A[kit]' "Review package"
check test "$ST" = ok
check contains "expected 2, observed 2"
begin
check_items Empty "4D A" "" "Restore folder"
check test "$ST" = ko
check contains "expected 1, observed 0"
check contains "Missing: 4D A"
begin
check_items Duplicate $'A\nB' $'A\nA\nB' "Review package"
check test "$ST" = ko
check contains "expected 2, observed 3"
check contains "Unexpected: A"
begin
need_action "Existing user action"
check_items Existing A A "Review package"
check test "$ST" = action
check_items Existing A B "Review package"
check test "$ST" = ko
# Missing folder and enumeration errors never look like a successful empty inventory.
mv "$MNT/Components" "$MNT/Components_saved"
. "$TMP/folder.sh" > /dev/null
check test "$ST" = ko
check contains "No Components folder"
check contains "expected 6, observed 0"
check contains "Missing: 4D NetKit.4dbase"
mv "$MNT/Components_saved" "$MNT/Components"
ls() { echo "Permission denied" >&2; return 1; }
. "$TMP/folder.sh" > /dev/null
unset -f ls
check test "$ST" = ko
check contains "Cannot list Components folder"
check contains "Permission denied"

# Both release references and an empty folder: count, names, and severity remain consistent.
begin
check_items "4D 21 components" "$(cat "$ROOT/macOS/comps.txt")" "$(cat "$ROOT/macOS/comps.txt")" "Review package"
check test "$ST" = ok
check contains "expected 7, observed 7"
check contains "4D AIKit.4dbase"
mv "$MNT/Components" "$MNT/Components_saved"
mkdir "$MNT/Components"
. "$TMP/folder.sh" > /dev/null
check test "$ST" = ko
check contains "expected 6, observed 0"
rmdir "$MNT/Components"
mv "$MNT/Components_saved" "$MNT/Components"
sed -n '/^if ! EXPECTED_COMPS=/,/^NCOMPS=/{p;}' "$ROOT/macOS/qa_mac.sh" > "$TMP/reference.sh"
for ref in "$TMP/missing-reference" "$TMP/empty-reference"; do
  : > "$TMP/empty-reference"
  rc=0
  ( COMPS="$ref"; . "$TMP/reference.sh" ) > "$TMP/reference.log" 2>&1 || rc=$?
  check test "$rc" = 1
  check grep -qF "Cannot read a non-empty component reference: $ref" "$TMP/reference.log"
  check grep -qF "Action: restore this reference" "$TMP/reference.log"
done

# Run the real loading section with a mocked 4D project result.
sed -n '/^comps_of()/,/^# GitHub API:/{ /^# GitHub API:/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/parsers.sh"
. "$TMP/parsers.sh"
sed -n '/^# 8\. load of components/,/^# About box:/{ /^# About box:/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/load.sh"
PRJ="$TMP/projects"; TAPP="$TMP/test/4D.app"; APPNAME=4D.app
A_LOAD="Load of components"; TEST_CONTROL=0; TEST_GITHUB=0
RUNSTATE=TIMEOUT; RUNREASON="no proof after 240 s"
mkdir -p "$PRJ/QA_Local"
run4d() { [ "${LAUNCH_FAIL:-0}" = 0 ]; }
{
  printf 'Components (6):\n'
  printf '%s\n' "$EXPECTED_COMPS" | sed 's/\.4dbase$//; s/^/  /'
  printf 'Plugins (0):\nTEST formula => true (err 0)\n'
} > "$PRJ/QA_Local/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ok
check contains "expected 6 required, observed 6"
sed -i '' 's/  4D NetKit/  Extra [Kit]/' "$PRJ/QA_Local/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ko
check contains "Missing: 4D NetKit"
check contains "Additional (allowed): Extra [Kit]"
check contains "Action: Compare the loaded names"
# Existing loading policy allows extra/built-in components; diagnostics must not turn this into a failure.
sed -i '' 's/  Extra \[Kit\]/  4D NetKit\n  4D Labels\n  4D Report/' "$PRJ/QA_Local/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ok
check contains "expected 6 required, observed 8"
check contains "Additional (allowed): 4D Labels, 4D Report"
LAUNCH_FAIL=1
. "$TMP/load.sh" > /dev/null
check test "$ST" = ko
check contains "TIMEOUT: no proof after 240 s"
check contains "Action: inspect the launch diagnostic"
LAUNCH_FAIL=0
printf 'TEST cs.NetKit => UNDEFINED (err -9767)\n' >> "$PRJ/QA_Local/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ko
check contains "cs.NetKit => UNDEFINED (err -9767)"
check contains "Action: inspect the named test formulas"

# Control test accepts built-ins, but identifies anything still loaded from other sources.
TEST_CONTROL=1
sed -i '' '/^TEST cs.NetKit/d' "$PRJ/QA_Local/qa_result.txt"
mkdir -p "$TAPP/Contents/Components" "$TMP/control"
newproj() { echo "$TMP/control"; }
printf 'Components (2):\n  4D Labels\n  4D Report\nPlugins (0):\n' > "$TMP/control/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ok
check contains "Control without Contents/Components"
check contains "expected 0, observed 0"
printf 'Components (3):\n  4D Labels\n  4D Report\n  OtherComponent\nPlugins (0):\n' > "$TMP/control/qa_result.txt"
. "$TMP/load.sh" > /dev/null
check test "$ST" = ko
check contains "expected 0, observed 1"
check contains "Unexpected: OtherComponent"
check contains "Action: These components still load"
check test -d "$TAPP/Contents/Components"

# Plugins: counts and exact names/paths, without changing the pre-21 N/A rule.
sed -n '/^# 6\. plugins$/,/^# 10\. execution/{ /^# 10\. execution/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/plugins.sh"
A_PLUGINS="No more plugins provided"; VMAJ=21; LOCALOK=1
PLB=$'/image/Plugins/Unexpected.bundle\n/image/Plugins/Extra.bundle'
. "$TMP/plugins.sh" > /dev/null
check test "$ST" = ko
check contains "expected 0, observed 2"
check contains "Unexpected: /image/Plugins/Extra.bundle, /image/Plugins/Unexpected.bundle"
check contains "Action: Review the named plugin bundles"
PLB=""
printf 'Components (0):\nPlugins (1):\n  OldPlugin\nTEST ok (err 0)\n' > "$PRJ/QA_Local/qa_result.txt"
. "$TMP/plugins.sh" > /dev/null
check test "$ST" = ko
check contains "Loaded plugins: expected 0, observed 1"
check contains "Unexpected: OldPlugin"
VMAJ=20
. "$TMP/plugins.sh" > /dev/null
check test "$(awk -F'\t' 'END{print $2}' "$OUT")" = na

# Non-universal binaries identify the missing architecture and a concrete inspection command.
sed -n '/^# 9\. FAT/,/^# copies:/{ /^# copies:/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/fat.sh"
A_FAT="Check if FAT application"
exe_of() { printf '%s/Contents/MacOS/4D\n' "$1"; }
clt() { return 0; }
lipo() { printf '%s\n' "$FAKE_ARCHS"; }
FAKE_ARCHS=arm64
. "$TMP/fat.sh" > /dev/null
check test "$ST" = ko
check contains "Expected architectures: x86_64 and arm64. Observed: arm64."
check contains "Action: inspect"
check contains "lipo -archs (or file)"
FAKE_ARCHS="x86_64 arm64"
. "$TMP/fat.sh" > /dev/null
check test "$ST" = ok

# Actual diagnostics survive TSV transport and both report formats, including escaped names.
begin
check_items "Components folder" "$EXPECTED_COMPS" "$EXPECTED_COMPS"$'\nExtra <A>.4dbase\nExtra &B.4dbase' "Review package"
OUT="$TMP/20.9_100123_EN.tsv"
hdr RUN diagnostics; hdr LANG EN
res "$A_COMPS" "$ST" "$D" "$CMP" > /dev/null
bash "$ROOT/macOS/rapport_mac.sh" "$TMP" 20.9_100123 4D 20.9 100123 "macOS Intel" diagnostics > /dev/null
H="$TMP/rapport_20.9_100123.html"; M="$TMP/rapport_20.9_100123.md"
check grep -qF '❌ Échec — Components folder: expected 6, observed 8' "$M"
check grep -qF 'Unexpected: Extra &amp;B.4dbase, Extra &lt;A&gt;.4dbase' "$H"
check grep -qF '<details open><summary><span class="st ko">❌ Échec</span>' "$H"
check grep -qF 'Action: Review package' "$M"
check grep -qF 'Missing: (none)' "$H"
echo "diagnostics: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
