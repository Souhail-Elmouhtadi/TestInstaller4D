#!/bin/bash
# Safe regression tests: network commands and dialogs are shell mocks only.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/macOS/version.sh"
. "$ROOT/macOS/network.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
NETF="$TMP/recovery"
GUI=1
pass=0
check() { "$@" || { echo "FAILED: $*" >&2; exit 1; }; pass=$((pass+1)); }
not_equal() { ! version_equal "$1" "$2"; }
not_in_text() { ! version_in_text "$1" "$2"; }
not_in_file() { ! grep -qF -- "$1" "$2"; }
for major in 20 21 22 23; do
  for minor in 0 1 2 9 12; do
    check version_equal "$major.0.$minor" "$major.$minor"
    check version_equal "$major.$minor" "$major.0.$minor"
    check version_in_text "$major.$minor" "4D $major.0.$minor build $major.100579"
    check not_equal "$major.0.$minor" "$major.$((minor+1))"
  done
done
check version_equal "21.0.2 build 21.100579" "21.2"
check version_equal "21.0.2 HF1" "21.2 HF1"
check not_equal "21.0.2 HF1" "21.2 HF2"
check not_equal "21.0.2" "21.2.1"
check not_equal "21.1.2" "21.2"
check not_equal "21 R2" "21.2"
check not_equal "" ""
check not_in_text "21.2" "4D 21.20 build 21.100579"
check not_in_text "21.2" "4D 21.2.1 build 21.100579"
check not_in_text "21.2" "4D 21.0.2 HF1 build 21.100579"
check version_in_text "21 R2" "4D 21 R2 build 21.100579"
check version_in_text "21.2 HF1" "4D 21.0.2 HF1 build 21.100579"
# build number: classic, R release ("21R5.100123") and bare spellings
check test "$(version_build "21.2 build 21.100624")" = 100624
check test "$(version_build "21.0.2 HF1 build 21.100579")" = 100579
check test "$(version_build "21 R5 build 21R5.100123")" = 100123
check test "$(version_build "20 R10 Build 20R10.200001")" = 200001
check test "$(version_build "21.2 build 100624")" = 100624
check test -z "$(version_build "21.2")"
# Info.plist coherence: R release "M RN" is numbered M.N.0 in CFBundleVersion (intentional), for every major
not_bundle() { ! bundle_version_matches "$1" "$2"; }
for major in 19 20 21 22; do
  for r in 1 2 5 10; do
    check bundle_version_matches "$major R$r" "$major.$r.0"
    check bundle_version_matches "$major R$r build ${major}R$r.100123" "$major.$r.0"
    check not_bundle "$major R$r" "$major.$((r+1)).0"
    check not_bundle "$major R$r" "$((major+1)).$r.0"
    check not_bundle "$major R$r" "$major.$r.1"
    check not_bundle "$major R$r" "$major.0.$r"
    check not_bundle "$major R$r" "$major.$r"
  done
done
check bundle_version_matches "21.2" "21.0.2"
check bundle_version_matches "21.0.2 HF1" "21.2 HF1"
check not_bundle "21.2" "21.2.0"
check not_bundle "21.2" "21.0.3"
check not_bundle "21 R5 HF1" "21.5.0"
check not_bundle "21 R5" ""
check not_bundle "" "21.5.0"
check not_equal "21 R5" "21.5.0"

sed -n '/^# 4\. version/,/^# 6\. plugins/{ /^# 6\. plugins/d; p; }' "$ROOT/macOS/qa_mac.sh" > "$TMP/version-check.sh"
begin() { ST=ok; }
add() { :; }
ko() { ST=ko; }
res() { :; }
about_test() { :; }
version_result() {
  local SV="$1" BV="$2" VERSION="$3" BUILD="$4" expected="$5"
  local PL_VERSION="${SV%% [Bb]uild*}" PL_BUILD AUTO="" LOCALOK=0 A_VERSION=Version ST D="" TAPP=/tmp/4D.app LANG_CODE=EN
  PL_BUILD="$(version_build "$SV")"
  . "$TMP/version-check.sh"
  [ "$ST" = "$expected" ]
}
check version_result "21.0.2 build 21.100579" "21.2" "21.2" "100579" ok
check version_result "21.2 build 21.100629" "21.0.2" "21.0.2" "100629" ok
check version_result "21.0.2 build 21.100579" "21.2" "21.2" "100580" ko
check version_result "21.0.2 build 21.100579" "21.2" "21.3" "100579" ko
check version_result "21.0.2 build 21.100579" "21.0.3" "21.2" "100579" ko
check version_result "21.0.2 HF1 build 21.100579" "21.2 HF2" "21.2 HF1" "100579" ko
check version_result "21 R5 build 21R5.100123" "21.5.0" "21 R5" "100123" ok
check version_result "20 R10 build 20R10.100456" "20.10.0" "20 R10" "100456" ok
check version_result "21 R5 build 21R5.100123" "21.5.0" "21 R5" "21" ko
check version_result "21 R5 build 21R5.100123" "21.5.0" "21 R6" "100123" ko
check version_result "21 R5 build 21R5.100123" "21.6.0" "21 R5" "100123" ko
check version_result "21 R5 build 21R5.100123" "21.0.5" "21 R5" "100123" ko
check version_result "21 R5 build 21R5.100123" "21.5.1" "21 R5" "100123" ko
check version_result "21 R5 build 21R5.100123" "21.5.0" "21.5" "100123" ko
check version_result "20.0.10 build 20.100500" "20.10" "20.10" "100500" ok

# No function below invokes real networksetup, pfctl, curl or osascript.
NG_DIR="$TMP/netguard"; NG_REQ="$TMP/netguard_request"; unset NG_LAUNCH
networksetup() {
  printf '%s\n' "$*" >> "$TMP/network_calls"
  case "$1" in
    -getnetworkserviceenabled) cat "$TMP/$2";;
    -setnetworkserviceenabled)
      if [ "${RESTORE_FAIL:-0}" = 1 ] && [ "$3" = on ]; then return 1; fi
      case "$3" in off) echo Disabled;; on) echo Enabled;; esac > "$TMP/$2";;
    *) return 1;;
  esac
}
pfctl() { printf 'pfctl %s\n' "$*" >> "$TMP/network_calls"; }
online() { [ "$(cat "$TMP/Wi-Fi")" = Enabled ]; }
osascript() { printf '%s\n' "$*" >> "$TMP/osascript_calls"; echo x >> "$TMP/osascript_n"; printf '%s' "${DIALOG_ANSWER:-}"; return "${DIALOG_RC:-0}"; }
# the automatic cut needs both answers: any other answer of the confirmation never reaches the administrator dialog
for DIALOG_ANSWER in "" Passer "gave up:true" Oui "Autoriser la coupure"; do
  : > "$TMP/osascript_calls"; : > "$TMP/osascript_n"
  rc=0; guard_start $$ || rc=$?
  check test "$rc" = 2
  check test "$(grep -c . "$TMP/osascript_n")" = 1
  check not_in_file "with administrator privileges" "$TMP/osascript_calls"
done
DIALOG_ANSWER=Autoriser; DIALOG_RC=1; rc=0; guard_start $$ || rc=$?; check test "$rc" = 2; DIALOG_RC=0
check test ! -e "$TMP/network_calls"
# legacy recovery (versions < 3.2 disabled the network services listed in NETF): re-enabled, never disabled
echo Disabled > "$TMP/Wi-Fi"; echo Disabled > "$TMP/Ethernet"; echo Wi-Fi > "$NETF"; : > "$TMP/network_calls"
RESTORE_FAIL=1
rc=0; net_on 2>"$TMP/restore_error" || rc=$?
check test "$rc" = 1
check test -s "$NETF"
check test -s "$TMP/restore_error"
RESTORE_FAIL=0
check net_on
check test ! -e "$NETF"
check test "$(cat "$TMP/Wi-Fi")" = Enabled
check test "$(cat "$TMP/Ethernet")" = Disabled
if grep -qE -- '-setnetworkserviceenabled (Ethernet|.* off)' "$TMP/network_calls"; then
  echo "FAILED: modified a previously disabled service or disabled a service" >&2; exit 1
fi

# The engine runs the three execution rows from exec_checks.sh (no copy of that logic in qa_mac.sh).
check grep -qx 'xc_offline "\$INST_APP"' "$ROOT/macOS/qa_mac.sh"
check grep -qx 'xc_staple' "$ROOT/macOS/qa_mac.sh"
check grep -qx 'xc_online' "$ROOT/macOS/qa_mac.sh"
check grep -qx 'xc_install "\$INSTALL_STATE"' "$ROOT/macOS/qa_mac.sh"
if grep -qE '^[^#]*(pkill|killall)' "$ROOT/macOS/qa_mac.sh" "$ROOT/macOS/launch_check.sh" "$ROOT/macOS/exec_checks.sh"; then
  echo "FAILED: processes terminated by name" >&2; exit 1
fi
# Execute the actual offline row with the same network mocks: a refusal must leave the network untouched,
# never launch 4D and never report a success.
. "$ROOT/macOS/results.sh"
. "$ROOT/macOS/exec_checks.sh"
OUT="$TMP/results.tsv"; BASE="$TMP"; ABOUT_CHECK=""
newproj() { mkdir -p "$TMP/p/$2/Project"; : > "$TMP/p/$2/Project/$2.4DProject"; echo "$TMP/p/$2"; }
offline_proof() { NET_PROOF="mock"; ! online; }
lc_launch() { echo unexpected > "$TMP/launched"; }
ask() { echo unexpected > "$TMP/asked"; echo s; }
mkdir -p "$TMP/4D.app"
offline_status() { awk -F'\t' -v a="$A_EXEC_OFF" '$1==a{s=$2} END{print s}' "$OUT"; }
for NET_AUTO in 1 0; do
  DIALOG_ANSWER=Passer; [ "$NET_AUTO" = 0 ] && DIALOG_ANSWER=""
  : > "$TMP/network_calls"; : > "$OUT"; : > "$TMP/osascript_calls"
  set +e; xc_offline "$TMP/4D.app" > /dev/null; set -e
  check test ! -s "$TMP/network_calls"
  check not_in_file "with administrator privileges" "$TMP/osascript_calls"
  check test ! -e "$TMP/launched"
  check test ! -e "$TMP/asked"
  check test "$(offline_status)" = notrun
  check grep -q "not executed" "$OUT"
done
echo "PASS: $pass checks; real network and permissions unchanged."
# installation, launch, execution rows, results report, application core: tests/ (mocks and temporary files only)
[ "${TI4D_QUICK:-0}" = 1 ] && exit 0 # TI4D_QUICK=1: this file only
for t in "$ROOT"/macOS-app/tests/test_*.sh; do
  echo "== $(basename "$t")"
  bash "$t" || { echo "FAILED: $(basename "$t")" >&2; exit 1; }
done
