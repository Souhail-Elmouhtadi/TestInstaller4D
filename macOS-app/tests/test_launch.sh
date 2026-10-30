#!/bin/bash
# launch_check.sh tests: proof of start, crash, exit, hang, dialog, refused, bench errors, PID-only termination.
# A fake "4D" (shell script bundle) reads its behaviour in <project>/fake_mode. macOS dialogs are mocked
# (ABOUT_CHECK mock); `open` is a mock for the cases without process.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_launch.XXXXXX)"
pass=0; failn=0
LC_PIDS="$TMP/pids.txt"; LC_CRASH_DIR="$TMP/crash"; LC_QUIT_WAIT=3
mkdir -p "$LC_CRASH_DIR"
. "$ROOT/macOS/launch_check.sh"
finish() { lc_cleanup; [ -n "${STRAY:-}" ] && kill "$STRAY" 2>/dev/null; rm -rf "$TMP"; }
trap finish EXIT
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (launch): $* [line ${BASH_LINENO[1]}] state=$LC_STATE reason=$LC_REASON" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }

APP="$TMP/Apps/4D.app"
mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>4D</string><key>CFBundleIdentifier</key><string>com.example.fake4d.launch</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
P
cat > "$APP/Contents/MacOS/4D" <<'EOF'
#!/bin/bash
proj=""; tok=""
while [ $# -gt 0 ]; do case "$1" in --project) proj="$2"; shift;; --user-param) tok="$2"; shift;; esac; shift; done
dir="$(dirname "$(dirname "$proj")")"; app="$(cd "$(dirname "$0")/../.." && pwd)"
mode="$(cat "$dir/fake_mode" 2>/dev/null)"
result() { printf 'Version: 21.2\r\nBuild: 100629\r\nApp: %s/\r\nParam: %s\r\n' "$1" "$2" > "$dir/qa_result.txt"; }
case "$mode" in
  ready) sleep 1; result "$app" "$tok";;
  noquit) result "$app" "$tok"; while :; do sleep 1; done;;
  noparam) printf 'Version: 21.2\r\nBuild: 100629\r\n' > "$dir/qa_result.txt";;
  wrongapp) result "/Applications/Other/4D.app" "$tok";;
  transloc) result "/private/var/folders/xx/T/AppTranslocation/1234-ABCD/d/4D.app" "$tok";;
  crash) sleep 1; printf '{"app_name":"4D","pid" : %s}\n{"exception" : {"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"}}\n' "$$" > "$(cat "$dir/crash_dir")/4D-2026-01-01-000000.ips"; exit 139;;
  exit) sleep 1; exit 1;;
  hang|dialog) while :; do sleep 1; done;;
esac
exit 0
EOF
chmod +x "$APP/Contents/MacOS/4D"

proj() { # mode -> project dir
  local p="$TMP/projects/QA_Exec_$1_$RANDOM"
  mkdir -p "$p/Project"; : > "$p/Project/$(basename "$p").4DProject"; echo "$1" > "$p/fake_mode"; echo "$LC_CRASH_DIR" > "$p/crash_dir"
  echo "$p"
}
running_fakes() { ps -axo command= | grep -F "$APP/Contents/MacOS/4D" | grep -v grep | grep -c . ; }

# ABOUT_CHECK mock: windows / Gatekeeper alerts
ABOUT_CHECK="$TMP/about_check"
cat > "$ABOUT_CHECK" <<'EOF'
#!/bin/bash
case "$1" in
  --windows) [ "$2" = uiagent ] && f="$(dirname "$0")/agent_windows" || f="$(dirname "$0")/pid_windows"
             [ -s "$f" ] && { cat "$f"; exit 0; }; exit 1;;
  --gatekeeper) [ -s "$(dirname "$0")/gk_out" ] && cat "$(dirname "$0")/gk_out"; exit 0;;
esac
EOF
chmod +x "$ABOUT_CHECK"

# 1. proof of start with the launch token, process quits by itself
P="$(proj ready)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = READY
check grep -q "started from $APP" <<< "$LC_REASON"
check test -n "$LC_PID"
check test "$(lc_real "$LC_APP_RUN")" = "$(lc_real "$APP")"
check grep -q '^ti4d\.' <<< "$LC_PARAM"
check test ! -s "$LC_PIDS"

# 2. result written but 4D does not quit: terminated by PID only
P="$(proj noquit)"
sleep 600 & STRAY=$! # unrelated process with a similar name pattern must survive
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = READY
check grep -q 'terminated by pid' <<< "$LC_REASON"
check not lc_alive "$LC_PID"
check lc_alive "$STRAY"
kill "$STRAY"; wait "$STRAY" 2>/dev/null; STRAY=""

# 3. crash: crash report of this pid written after the launch
P="$(proj crash)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = CRASH
check grep -q 'EXC_BAD_ACCESS' <<< "$LC_REASON"
rm -f "$LC_CRASH_DIR"/*
# an old crash report of the same pid is not attributed to this launch
P="$(proj exit)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = EXIT
check grep -q 'no crash report' <<< "$LC_REASON"

# 4. hang: still running at the time limit, no window -> HANG, process terminated
P="$(proj hang)"
lc_launch "$APP" "$P" 4 direct "$APP"
check test "$LC_STATE" = HANG
check not lc_alive "$LC_PID"
check test "$(running_fakes)" = 0

# 5. dialog: still running with a window displayed
printf 'WIN\t1\t0\t420x180\t4D\tActivation\n' > "$TMP/pid_windows"
P="$(proj dialog)"
lc_launch "$APP" "$P" 4 direct "$APP"
check test "$LC_STATE" = DIALOG
check grep -q 'Activation' <<< "$LC_REASON"
check not lc_alive "$LC_PID"
rm -f "$TMP/pid_windows"

# 6. no usable proof: result without the token, result from another application
P="$(proj noparam)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = NOPROOF
P="$(proj wrongapp)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = NOPROOF
check grep -q '/Applications/Other/4D.app' <<< "$LC_REASON"
P="$(proj transloc)"
lc_launch "$APP" "$P" 20 direct "$APP"
check test "$LC_STATE" = READY
check grep -q 'App Translocation' <<< "$LC_REASON"
# without an expected path (other test projects), a fresh result without token is accepted
P="$(proj noparam)"
lc_launch "$APP" "$P" 20 direct
check test "$LC_STATE" = READY
# a result file older than the launch is never a proof
P="$(proj hang)"; echo "Param: x" > "$P/qa_result.txt"; touch -t 202001010000 "$P/qa_result.txt"
lc_launch "$APP" "$P" 3 direct "$APP"
check test "$LC_STATE" != READY
check test ! -f "$P/qa_result.txt"

# 7. bench errors
P="$(proj ready)"; rm "$P/Project/"*.4DProject
lc_launch "$APP" "$P" 5 direct "$APP"; check test "$LC_STATE" = BENCH
lc_launch "$TMP/Missing.app" "$(proj ready)" 5 direct; check test "$LC_STATE" = BENCH

# 8. open mode without any process: refused by macOS, unanswered alert, nothing
open() { return 0; }
LC_NOPROC_GRACE=2
printf 'GK\tOK\t“4D” can’t be opened because Apple cannot check it for malicious software.\n' > "$TMP/gk_out"
lc_launch "$APP" "$(proj ready)" 5 open "$APP"; check test "$LC_STATE" = BLOCKED
rm -f "$TMP/gk_out"; printf 'WIN\t99\t0\t500x200\tCoreServicesUIAgent\t\n' > "$TMP/agent_windows"
lc_launch "$APP" "$(proj ready)" 5 open "$APP"; check test "$LC_STATE" = DIALOG
rm -f "$TMP/agent_windows"
lc_launch "$APP" "$(proj ready)" 5 open "$APP"; check test "$LC_STATE" = NOPROCESS
open() { echo "LSOpenURLsWithRole() failed with error -10810" >&2; return 1; }
lc_launch "$APP" "$(proj ready)" 5 open "$APP"; check test "$LC_STATE" = BENCH
unset -f open; LC_NOPROC_GRACE=0

# 9. real LaunchServices launch (open -n): the process is found through the launch token
P="$(proj ready)"
lc_launch "$APP" "$P" 30 open "$APP"
check test "$LC_STATE" = READY
check test -n "$LC_PID"

# 10. lc_cleanup terminates only tracked processes still running the recorded command
sleep 600 & S1=$!
lc_track "$S1" "this-marker-is-not-in-the-command"
lc_cleanup
check lc_alive "$S1"
kill "$S1"; wait "$S1" 2>/dev/null
check test "$(running_fakes)" = 0
echo "launch: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
