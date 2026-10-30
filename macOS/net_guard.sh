#!/bin/bash
# Automatic test WITHOUT Internet: temporary block of the network traffic with the macOS firewall (pf).
# Started once per run, only after the user's explicit permission (confirmation dialog, then the macOS
# administrator dialog; no password is read or stored by the tool).
# It never changes the network interfaces, the network services, /etc/pf.conf or the main pf ruleset: it only
# loads rules into its own anchor com.apple/000.TestInstaller4D, which the standard /etc/pf.conf evaluates
# ('anchor "com.apple/*"'), and takes a pf enable reference (pfctl -E, released with pfctl -X).
# The block is lifted on request, after its maximum duration, when the owner process (the app or the script
# that started the run) ends, when the guard stops for any reason, after NG_MAX_LIFE and, at the latest, at
# the next restart (pf rules loaded at run time are not persistent).
#
#   net_guard.sh start <owner_pid>   confirmation + administrator dialog, then waits until the guard is ready
#                                    exit 0 ready, 2 declined or cancelled, 1 error (reason on stdout)
#   net_guard.sh status | quit | recover
#   net_guard.sh daemon <owner_pid> <request_file> <state_dir>    (root, started by 'start')
# Protocol: request file "<seq> block <seconds>|open|status|quit" written by the user, state file
# "<guard_pid> <seq> <ready|blocked|open|error|stopped> <epoch> <detail>" written by the guard.

NG_ANCHOR="com.apple/000.TestInstaller4D"
NG_RULES='pass out quick on lo0 all
pass in quick on lo0 all
block return out quick all
block drop in quick all'

ng_state() { # status detail
  local f="$NG_DIRD/state" d
  d="$(printf '%s' "$2" | tr '\n\t' '  ' | cut -c1-900)"
  printf '%s %s %s %s %s\n' "$$" "$NG_SEQ" "$1" "$(date +%s)" "$d" > "$f.tmp" && chmod 644 "$f.tmp" && mv -f "$f.tmp" "$f"
}
ng_pf_info() { "$PFCTL" -s info 2>/dev/null | grep -q 'Status: Enabled'; }
ng_flush() { "$PFCTL" -a "$NG_ANCHOR" -F rules >/dev/null 2>&1; }
ng_check() {
  "$PFCTL" -s rules 2>/dev/null | grep -q '^anchor "com\.apple/\*"' && return 0
  NG_ERR="the main pf ruleset does not evaluate the com.apple/* anchors (modified /etc/pf.conf?): the tool never changes it, cut the network manually"
  return 1
}
ng_block() { # seconds
  local secs="$1" was out tok
  case "$secs" in ''|*[!0-9]*) secs=300;; esac
  [ "$secs" -lt "$NG_MIN_BLOCK" ] && secs="$NG_MIN_BLOCK"
  [ "$secs" -gt 900 ] && secs=900
  ng_check || return 1
  if ng_pf_info; then was=enabled; else was=disabled; fi
  if ! out="$(printf '%s\n' "$NG_RULES" | "$PFCTL" -a "$NG_ANCHOR" -f - 2>&1)"; then
    NG_ERR="pfctl could not load the rules: $(printf '%s' "$out" | grep -v ALTQ | head -3)"; ng_flush; return 1
  fi
  if ! "$PFCTL" -a "$NG_ANCHOR" -s rules 2>/dev/null | grep -q '^block return out quick all'; then
    NG_ERR="rules not found in $NG_ANCHOR after loading"; ng_flush; return 1
  fi
  if [ -z "$NG_TOKEN" ]; then
    out="$("$PFCTL" -E 2>&1)"
    tok="$(printf '%s\n' "$out" | sed -n 's/^Token : *\([0-9][0-9]*\).*/\1/p' | head -1)"
    if [ -z "$tok" ]; then NG_ERR="pf could not be enabled: $(printf '%s' "$out" | grep -v ALTQ | head -3)"; ng_flush; return 1; fi
    NG_TOKEN="$tok"; echo "$tok" > "$NG_DIRD/token"; chmod 644 "$NG_DIRD/token"
  fi
  if ! ng_pf_info; then NG_ERR="pf is not enabled after pfctl -E"; ng_unblock; return 1; fi
  # connections opened before the block must not bypass it
  "$PFCTL" -F states >/dev/null 2>&1
  NG_BLOCKED=1; NG_UNTIL=$(( $(date +%s) + secs ))
  NG_INFO="pf firewall: all traffic except loopback blocked (anchor $NG_ANCHOR; pf $was before; enable reference $NG_TOKEN; connection states flushed; automatic restore after ${secs}s at the latest)"
}
ng_unblock() {
  local rc=0
  ng_flush
  if "$PFCTL" -a "$NG_ANCHOR" -s rules 2>/dev/null | grep -q .; then
    rc=1; NG_ERR="rules still present in $NG_ANCHOR after removal: restart the Mac to restore the network"
  fi
  if [ -n "$NG_TOKEN" ]; then "$PFCTL" -X "$NG_TOKEN" >/dev/null 2>&1; NG_TOKEN=""; rm -f "$NG_DIRD/token"; fi
  NG_BLOCKED=0; NG_UNTIL=0
  return $rc
}
ng_final() {
  if [ "$NG_BLOCKED" = 1 ] || [ -n "$NG_TOKEN" ]; then
    if ng_unblock; then NG_STOP_WHY="$NG_STOP_WHY; pf rules removed, network restored"
    else NG_STOP_WHY="$NG_STOP_WHY; $NG_ERR"; fi
  fi
  ng_state stopped "$NG_STOP_WHY"
}

ng_daemon() { # owner_pid request_file state_dir
  local owner="$1" req="$2" ostart now line seq cmd arg n=0 t
  NG_DIRD="$3"; NG_SEQ=0; NG_BLOCKED=0; NG_UNTIL=0; NG_TOKEN=""; NG_ERR=""
  case "$owner" in ''|*[!0-9]*) echo "invalid owner process: $owner" >&2; return 1;; esac
  case "$req$NG_DIRD" in /*/*) ;; *) echo "absolute paths required" >&2; return 1;; esac
  [ -d "$NG_DIRD" ] && [ ! -L "$NG_DIRD" ] || { echo "state folder missing: $NG_DIRD" >&2; return 1; }
  if [ "$(id -u)" = 0 ]; then
    PFCTL=/sbin/pfctl; NG_MAX_LIFE=28800; NG_MIN_BLOCK=30 # environment overrides are for the tests only
  else
    [ -n "${NG_PFCTL:-}" ] || { echo "the network guard must run as root" >&2; return 1; }
    PFCTL="$NG_PFCTL"; NG_MAX_LIFE="${NG_MAX_LIFE:-28800}"; NG_MIN_BLOCK="${NG_MIN_BLOCK:-30}"
  fi
  umask 022
  ostart="$(ps -o lstart= -p "$owner" 2>/dev/null)"
  [ -n "$ostart" ] || { NG_STOP_WHY="owner process $owner not running"; ng_state stopped "$NG_STOP_WHY"; return 1; }
  # a request left by an earlier session is never executed
  if [ -f "$req" ] && [ ! -L "$req" ]; then read -r t _ < "$req"; case "$t" in ''|*[!0-9]*) ;; *) NG_SEQ="$t";; esac; fi
  # leftovers of a guard that could not clean up (killed): remove them before anything else
  if [ -s "$NG_DIRD/token" ]; then t="$(tr -cd '0-9' < "$NG_DIRD/token")"; [ -n "$t" ] && "$PFCTL" -X "$t" >/dev/null 2>&1; rm -f "$NG_DIRD/token"; fi
  ng_flush
  NG_STOP_WHY="guard ended"
  trap ng_final EXIT
  # started in the background by "do shell script" (no nohup: macOS nohup refuses to run without a console)
  trap '' HUP
  trap 'NG_STOP_WHY="guard interrupted by a signal"; exit 0' TERM INT
  NG_STARTED="$(date +%s)"
  if ng_check; then ng_state ready "pf usable (main ruleset evaluates com.apple/*); owner process $owner"
  else NG_STOP_WHY="$NG_ERR"; exit 1; fi
  set -f
  while :; do
    now="$(date +%s)"
    if ! kill -0 "$owner" 2>/dev/null; then NG_STOP_WHY="owner process $owner ended"; exit 0; fi
    if [ $((n % 4)) = 0 ] && [ "$(ps -o lstart= -p "$owner" 2>/dev/null)" != "$ostart" ]; then NG_STOP_WHY="owner process $owner ended"; exit 0; fi
    if [ $((now - NG_STARTED)) -ge "$NG_MAX_LIFE" ]; then NG_STOP_WHY="maximum lifetime of the guard reached (${NG_MAX_LIFE}s)"; exit 0; fi
    if [ "$NG_BLOCKED" = 1 ] && [ "$now" -ge "$NG_UNTIL" ]; then
      if ng_unblock; then ng_state open "automatic restore: maximum block duration reached, pf rules removed"
      else ng_state error "$NG_ERR"; fi
    fi
    if [ -f "$req" ] && [ ! -L "$req" ]; then
      line=""; IFS= read -r line < "$req"
      seq=""; cmd=""; arg=""
      read -r seq cmd arg _ <<< "$line"
      case "$seq" in ''|*[!0-9]*) seq="";; esac
      if [ -n "$seq" ] && [ "$seq" != "$NG_SEQ" ]; then
        NG_SEQ="$seq"
        case "$cmd" in
          block) if ng_block "$arg"; then ng_state blocked "$NG_INFO"; else ng_state error "$NG_ERR"; fi;;
          open)
            if ng_unblock; then ng_state open "pf rules removed (anchor $NG_ANCHOR empty), enable reference released"
            else ng_state error "$NG_ERR"; fi;;
          status) if [ "$NG_BLOCKED" = 1 ]; then ng_state blocked "$NG_INFO"; else ng_state ready "pf rules not loaded"; fi;;
          quit) NG_STOP_WHY="stopped on request"; exit 0;;
          *) ng_state error "unknown request: $cmd";;
        esac
      fi
    fi
    n=$((n+1))
    sleep 0.5
  done
}

if [ "${1:-}" = daemon ]; then
  shift; ng_daemon "$@"; exit $?
fi

# ---------- user side ----------
. "$(cd "$(dirname "$0")" && pwd)/network.sh" || exit 1
case "${1:-}" in
  start)
    rc=0; guard_start "${2:-$PPID}" || rc=$?
    case "$rc" in
      0) echo "READY $GUARD_DETAIL";;
      2) echo "DECLINED ${GUARD_DETAIL:-permission declined}";;
      *) echo "ERROR $GUARD_DETAIL";;
    esac
    exit "$rc";;
  status)
    if guard_running; then echo "RUNNING $GUARD_STATUS $GUARD_DETAIL"; else echo "STOPPED ${GUARD_DETAIL:-}"; fi;;
  quit)
    if guard_quit; then echo "STOPPED $GUARD_DETAIL"; else echo "ERROR $GUARD_DETAIL"; exit 1; fi;;
  recover)
    guard_recover; exit $?;;
  *) echo "usage: net_guard.sh start <owner_pid> | status | quit | recover" >&2; exit 64;;
esac
