#!/bin/bash
# Tests of the automatic offline cut (net_guard.sh + guard_* in network.sh). pfctl is a mock (state in files),
# the guard runs as the current user (no root), dialogs are mocked: the real firewall and network are untouched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_netguard.XXXXXX)"
PIDS=""
cleanup() { local p; for p in $PIDS; do kill "$p" 2>/dev/null; done; sleep 0.6; rm -rf "$TMP"; }
trap cleanup EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (netguard): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
has() { grep -qF -- "$2" <<< "$1"; }

M="$TMP/pf"; mkdir -p "$M"
# ---- pfctl mock: main ruleset, anchor rules, enable references (tokens), calls ----
cat > "$TMP/pfctl" <<'EOF'
#!/bin/bash
M="$(dirname "$0")/pf"
echo "$*" >> "$M/calls"
anchor=""
if [ "$1" = -a ]; then anchor="$2"; shift 2; fi
enabled() { [ -s "$M/tokens" ] || [ -f "$M/preenabled" ]; }
case "$1" in
  -s)
    case "$2" in
      info) if enabled; then echo "Status: Enabled for 0 days"; else echo "Status: Disabled"; fi;;
      rules) if [ -n "$anchor" ]; then cat "$M/anchor" 2>/dev/null; else cat "$M/main"; fi;;
    esac;;
  -f)
    [ -f "$M/fail_load" ] && { echo "stdin:3: syntax error" >&2; exit 1; }
    cat > "$M/anchor"; echo "$anchor" > "$M/anchor_name";;
  -F)
    if [ "$2" = rules ]; then [ -f "$M/fail_flush" ] || : > "$M/anchor"; echo "rules cleared" >&2
    elif [ "$2" = states ]; then echo "states flushed" >> "$M/flushed"; fi;;
  -E)
    [ -f "$M/fail_enable" ] && { echo "pfctl: DIOCSTARTREF: Operation not permitted" >&2; exit 1; }
    n=$(( $(cat "$M/next" 2>/dev/null || echo 1000) + 1 )); echo "$n" > "$M/next"; echo "$n" >> "$M/tokens"
    printf 'No ALTQ support in kernel\nALTQ related functions disabled\npf enabled\nToken : %s\n' "$n" >&2;;
  -X)
    grep -qx "$2" "$M/tokens" 2>/dev/null || { echo "pfctl: DIOCSTOPREF: Invalid argument" >&2; exit 1; }
    grep -vx "$2" "$M/tokens" > "$M/t2"; mv "$M/t2" "$M/tokens"; echo "pf disabled" >&2;;
esac
exit 0
EOF
chmod +x "$TMP/pfctl"
reset_pf() { rm -rf "$M"; mkdir -p "$M"; printf 'scrub-anchor "com.apple/*" all fragment reassemble\nanchor "com.apple/*" all\n' > "$M/main"; : > "$M/tokens"; : > "$M/calls"; }
anchor_rules() { cat "$M/anchor" 2>/dev/null; }
tokens() { grep -c . "$M/tokens" 2>/dev/null; }

# ---- client environment: guard started without administrator rights through NG_LAUNCH ----
export NG_PFCTL="$TMP/pfctl" NG_MAX_LIFE=600 NG_MIN_BLOCK=1
NG_DIR="$TMP/state"; NG_REQ="$TMP/user/netguard_request"; NG_WAIT=10
mkdir -p "$NG_DIR"
cat > "$TMP/launch" <<'EOF'
#!/bin/bash
# src owner request dir: the same command line as the administrator dialog, without root
echo "$*" >> "$(dirname "$0")/launches"
/bin/bash "$1" daemon "$2" "$3" "$4" </dev/null >"$4/daemon.log" 2>&1 &
EOF
chmod +x "$TMP/launch"
NG_LAUNCH="$TMP/launch"
. "$ROOT/macOS/network.sh"
NG_SRC="$ROOT/macOS/net_guard.sh"
CONFIRM=0; confirm_guard() { echo confirm >> "$TMP/confirms"; return "$CONFIRM"; }
OSA_OUT=""; OSA_RC=0; osascript() { printf '%s\n' "$*" >> "$TMP/osascript"; printf '%s' "$OSA_OUT"; return "$OSA_RC"; }
owner() { sleep 300 & OWNER=$!; disown "$OWNER"; PIDS="$PIDS $OWNER"; }
wait_state() { # status [seconds]
  local i=0; while [ $i -lt $(( ${2:-5} * 10 )) ]; do guard_read && [ "$GUARD_STATUS" = "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1
}
stop_guard() { guard_read; [ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null; wait_state stopped 3 >/dev/null; rm -f "$NG_DIR/state"; }

# ---- start: declined, cancelled, ready ----
reset_pf; owner
CONFIRM=1; rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 2; check not test -e "$TMP/launches"; check not test -e "$TMP/osascript"; check has "$GUARD_DETAIL" "declined"
# administrator dialog cancelled: no guard, declined (2); osascript received the script and no password
CONFIRM=0; SAVED_LAUNCH="$NG_LAUNCH"; unset NG_LAUNCH
OSA_OUT="execution error: User canceled. (-128)"; OSA_RC=1; rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 2; check has "$GUARD_DETAIL" "cancelled"
check grep -q "with administrator privileges" "$TMP/osascript"
check grep -qF "$NG_SRC $OWNER $NG_REQ" "$TMP/osascript"
check grep -qF "/var/run/com.4d.ti4d.netguard" "$TMP/osascript"
check grep -qF "/usr/bin/install -m 700 -o root -g wheel" "$TMP/osascript"
check not grep -qiE "password|-S |sudo" "$TMP/osascript"
OSA_OUT="execution error: some failure (1)"; rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 1; check has "$GUARD_DETAIL" "could not be started"
NG_LAUNCH="$SAVED_LAUNCH"; OSA_OUT=""; OSA_RC=0; : > "$TMP/osascript"
# a request left by an earlier session is never executed
mkdir -p "$(dirname "$NG_REQ")"; echo "999 quit" > "$NG_REQ"
"$NG_LAUNCH" "$NG_SRC" "$OWNER" "$NG_REQ" "$NG_DIR"; check wait_state ready 5
sleep 1.2; check guard_running; check test "$GUARD_SEQ" = 999
stop_guard
# normal start
rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 0; check guard_running; check test "$GUARD_STATUS" = ready
check not test -e "$NG_REQ" # old requests removed before the start
check test "$(stat -f %Lp "$NG_DIR/state")" = 644
# already running: no second dialog, no second guard
: > "$TMP/confirms"; n="$(grep -c . "$TMP/launches")"; rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 0; check not test -s "$TMP/confirms"; check test "$(grep -c . "$TMP/launches")" = "$n"

# ---- block: rules in the tool's own anchor only, pf enable reference, states flushed ----
check guard_block 60
check test "$GUARD_STATUS" = blocked
check test "$(cat "$M/anchor_name")" = "com.apple/000.TestInstaller4D"
check grep -qx "block return out quick all" "$M/anchor"
check grep -qx "block drop in quick all" "$M/anchor"
check grep -qx "pass out quick on lo0 all" "$M/anchor"
check test "$(tokens)" = 1
check test -s "$M/flushed"
check has "$GUARD_DETAIL" "anchor com.apple/000.TestInstaller4D"
check has "$GUARD_DETAIL" "pf disabled before"
check has "$GUARD_DETAIL" "automatic restore after 60s"
check not grep -qE '^-f|^-F rules$|^-F all|^-a com.apple/[^0]' "$M/calls" # never the main ruleset, never another anchor
check not grep -q -- '-F all' "$M/calls"
# a second block keeps one single reference
check guard_block 60; check test "$(tokens)" = 1
# ---- open: anchor empty, reference released ----
check guard_open; check test "$GUARD_STATUS" = open
check test -z "$(anchor_rules)"; check test "$(tokens)" = 0
check has "$GUARD_DETAIL" "pf rules removed"
# ---- quit while blocked: rules removed, guard gone ----
check guard_block 60
GP="$GUARD_PID"; check guard_quit
check test "$GUARD_STATUS" = stopped; check test -z "$(anchor_rules)"; check test "$(tokens)" = 0
check has "$GUARD_DETAIL" "network restored"
sleep 0.3; check not kill -0 "$GP" 2>/dev/null; check not guard_running
# quit when not running: nothing to do
check guard_quit
# requests without guard fail at once (no wait)
check not guard_block 60; check has "$GUARD_DETAIL" "not running"

# ---- maximum block duration: automatic restore ----
reset_pf; rm -f "$NG_DIR/state"; check guard_start "$OWNER"
check guard_block 2
check wait_state open 6; check has "$GUARD_DETAIL" "maximum block duration"
check test -z "$(anchor_rules)"; check test "$(tokens)" = 0
check guard_running # the guard stays available for the next language
stop_guard

# ---- owner process ends: automatic restore ----
reset_pf; owner; check guard_start "$OWNER"; check guard_block 60
kill "$OWNER"; check wait_state stopped 5
check has "$GUARD_DETAIL" "owner process $OWNER ended"; check has "$GUARD_DETAIL" "network restored"
check test -z "$(anchor_rules)"; check test "$(tokens)" = 0

# ---- guard stopped by a signal: automatic restore ----
reset_pf; owner; rm -f "$NG_DIR/state"; check guard_start "$OWNER"; check guard_block 60
kill -TERM "$GUARD_PID"; check wait_state stopped 5
check has "$GUARD_DETAIL" "signal"; check test -z "$(anchor_rules)"; check test "$(tokens)" = 0

# ---- SIGHUP (launched without nohup, which macOS refuses without a console) never stops a block ----
reset_pf; owner; rm -f "$NG_DIR/state"; check guard_start "$OWNER"; check guard_block 60
kill -HUP "$GUARD_PID"; sleep 1.2
check guard_running; check test "$GUARD_STATUS" = blocked; check test -n "$(anchor_rules)"
check guard_open; check guard_quit
check not has "$NG_ADMIN_SCRIPT" "nohup"
check has "$NG_ADMIN_SCRIPT" '</dev/null >\"$D/daemon.log\" 2>&1 &'

# ---- maximum lifetime of the guard ----
reset_pf; rm -f "$NG_DIR/state"; NG_MAX_LIFE=2 guard_start "$OWNER" >/dev/null; check wait_state stopped 6
check has "$GUARD_DETAIL" "maximum lifetime"

# ---- pf already enabled by something else: its reference is kept, existing states flushed ----
reset_pf; touch "$M/preenabled"; rm -f "$NG_DIR/state"; check guard_start "$OWNER"
check guard_block 60; check has "$GUARD_DETAIL" "pf enabled before"; check test -s "$M/flushed"
check guard_open; check grep -q "Status: Enabled" <<< "$("$TMP/pfctl" -s info)"
stop_guard

# ---- failures: no block left behind, precise reasons ----
reset_pf; touch "$M/fail_load"; rm -f "$NG_DIR/state"; check guard_start "$OWNER"
check not guard_block 60; check test "$GUARD_STATUS" = error; check has "$GUARD_DETAIL" "could not load the rules"
check test "$(tokens)" = 0
rm -f "$M/fail_load"; touch "$M/fail_enable"
check not guard_block 60; check has "$GUARD_DETAIL" "pf could not be enabled"; check test -z "$(anchor_rules)"
rm -f "$M/fail_enable"; check guard_block 60; check guard_open # the guard recovers from an error
touch "$M/fail_flush"; check guard_block 60
check not guard_open; check test "$GUARD_STATUS" = error; check has "$GUARD_DETAIL" "still present"
rm -f "$M/fail_flush"; check guard_open
stop_guard
# main ruleset without the com.apple/* anchors (modified pf.conf): refused, nothing loaded
reset_pf; echo 'pass all' > "$M/main"; rm -f "$NG_DIR/state"; rc=0; guard_start "$OWNER" || rc=$?
check test "$rc" = 1; check has "$GUARD_DETAIL" "does not evaluate the com.apple/* anchors"
check not grep -q -- '-E' "$M/calls"; check test -z "$(anchor_rules)"
# leftovers of a killed guard (rules + reference) are removed by the next start
reset_pf; echo 1500 >> "$M/tokens"; echo "block return out quick all" > "$M/anchor"; echo 1500 > "$NG_DIR/token"
rm -f "$NG_DIR/state"; check guard_start "$OWNER"
check test -z "$(anchor_rules)"; check test "$(tokens)" = 0; check not test -e "$NG_DIR/token"
stop_guard
# the daemon refuses to run without root (or the test mock), and with a relative path
out="$(env -u NG_PFCTL bash "$NG_SRC" daemon "$OWNER" "$NG_REQ" "$NG_DIR" 2>&1)"; check has "$out" "must run as root"
out="$(bash "$NG_SRC" daemon "$OWNER" relative "$NG_DIR" 2>&1)"; check has "$out" "absolute paths"
# a symbolic link as request file is ignored
reset_pf; rm -f "$NG_DIR/state"; check guard_start "$OWNER"
echo "77 block 60" > "$TMP/other"; rm -f "$NG_REQ"; ln -s "$TMP/other" "$NG_REQ"; sleep 1.2
guard_read; check test "$GUARD_STATUS" = ready; check test -z "$(anchor_rules)"
rm -f "$NG_REQ"; stop_guard

# ---- stale state: guard gone while blocked -> recovery through the administrator dialog only ----
printf '99999 4 blocked %s pf firewall\n' "$(date +%s)" > "$NG_DIR/state"
check guard_stale
: > "$TMP/osascript"; out="$(guard_recover)"; check has "$out" "network restored"
check grep -q "with administrator privileges" "$TMP/osascript"; check grep -qF -- "-F rules" "$TMP/osascript"
OSA_RC=1; out="$(guard_recover)"; check has "$out" "restart the Mac"; OSA_RC=0
printf '99999 4 blocked 1000 pf firewall\n' > "$NG_DIR/state"; check not guard_stale # before the last restart
printf '99999 4 stopped %s done\n' "$(date +%s)" > "$NG_DIR/state"; check not guard_stale
printf '99999 4 open %s done\n' "$(date +%s)" > "$NG_DIR/state"; check not guard_stale
: > "$TMP/osascript"; check guard_recover; check not test -s "$TMP/osascript"
rm -f "$NG_DIR/state"

# ---- CLI used by the app and the .command ----
reset_pf; owner
out="$(NG_DIR="$NG_DIR" NG_REQ="$NG_REQ" bash -c '. "$0"; confirm_guard() { return 0; }; NG_SRC="$1"; NG_LAUNCH="$2"; guard_start "$3" && echo "READY $GUARD_DETAIL"' "$ROOT/macOS/network.sh" "$NG_SRC" "$NG_LAUNCH" "$OWNER")"
check has "$out" "READY"
out="$(NG_DIR="$NG_DIR" NG_REQ="$NG_REQ" bash "$NG_SRC" status)"; check has "$out" "RUNNING ready"
out="$(NG_DIR="$NG_DIR" NG_REQ="$NG_REQ" bash "$NG_SRC" quit)"; check has "$out" "STOPPED"
out="$(NG_DIR="$NG_DIR" NG_REQ="$NG_REQ" bash "$NG_SRC" status)"; check has "$out" "STOPPED"
out="$(GUI=0 NG_DIR="$NG_DIR" NG_REQ="$NG_REQ" bash "$NG_SRC" start "$OWNER" < /dev/null 2>/dev/null)"; rc=$?
check test "$rc" = 2; check has "$out" "DECLINED" # no terminal answer = declined
out="$(bash "$NG_SRC" bogus 2>&1)"; check has "$out" "usage"

# ---- the real guard script: pfctl fixed for root, no change of interfaces or settings ----
check grep -q 'PFCTL=/sbin/pfctl; NG_MAX_LIFE=28800; NG_MIN_BLOCK=30' "$NG_SRC"
check not grep -qE '^[^#]*(networksetup|ifconfig|route (add|delete|change)|socketfilterfw|(>|-f|cp|mv|tee) */etc/pf)' "$NG_SRC"
# network.sh: networksetup only to re-enable services left disabled by versions < 3.2 (never to disable one)
check not grep -qE '^[^#]*(ifconfig|socketfilterfw|setnetworkserviceenabled[^;]*off)' "$ROOT/macOS/network.sh"
check not grep -qE '^[^#]*pfctl[^|]*-f /etc' "$NG_SRC" "$ROOT/macOS/network.sh"

echo "netguard: $pass checks, $failn failed"
[ "$failn" = 0 ]
