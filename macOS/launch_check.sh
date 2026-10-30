#!/bin/bash
# 4D launch with a proof of start (sourced by qa_mac.sh).
# lc_launch <app> <project dir> <timeout s> <mode> [expected app path]
#   mode: open (LaunchServices, Gatekeeper evaluates a quarantined app), rosetta (open --arch x86_64),
#         x86_64 | arm64 (arch -<mode> <executable>), direct (executable).
#   A unique token is passed with --user-param: the process is identified by its PID, found through this
#   token, and only processes started here are ever terminated (by PID, never by name).
#   Proof of start: <project>/qa_result.txt written after the launch by the test project (QA_Exec writes
#   "App:" = Application file and "Param:" = the token). The launch command succeeding proves nothing.
# Results:
#   LC_STATE   READY | CRASH | EXIT | HANG | DIALOG | BLOCKED | NOPROCESS | NOPROOF | BENCH
#   LC_REASON  human readable explanation (proof, crash report, window, ...)
#   LC_PID LC_SECONDS LC_FLAGS (ps flags sampled while running: 0x20000 = translated by Rosetta) LC_GK LC_APP_RUN
LC_PIDS="${LC_PIDS:-${BASE:-/tmp}/launched_pids.txt}"
LC_CRASH_DIR="${LC_CRASH_DIR:-$HOME/Library/Logs/DiagnosticReports}"
LC_QUIT_WAIT="${LC_QUIT_WAIT:-30}"
LC_NOPROC_GRACE="${LC_NOPROC_GRACE:-0}"

lc_exe_of() { echo "$1/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null)"; }
lc_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
# path with symbolic links resolved (/tmp -> /private/tmp): LaunchServices and 4D report resolved paths
lc_real() { local d; d="$(cd "${1%/}" 2>/dev/null && pwd -P)" && echo "$d" || echo "${1%/}"; }
lc_cmd() { ps -p "$1" -o command= 2>/dev/null; }
lc_track() { printf '%s\t%s\n' "$1" "$2" >> "$LC_PIDS"; }
lc_untrack() { [ -f "$LC_PIDS" ] && awk -F'\t' -v p="$1" '$1!=p' "$LC_PIDS" > "$LC_PIDS.tmp" && mv "$LC_PIDS.tmp" "$LC_PIDS"; }

# Terminates a process started by the kit: the PID must still run the recorded command (no PID reuse).
lc_kill() { # pid marker
  local pid="$1" mark="$2" i=0
  lc_alive "$pid" || { lc_untrack "$pid"; return 0; }
  case "$(lc_cmd "$pid")" in *"$mark"*) ;; *) lc_untrack "$pid"; return 0;; esac
  kill -TERM "$pid" 2>/dev/null
  while lc_alive "$pid" && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
  lc_alive "$pid" && kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null # reaps a child of this shell (no job notice); no effect on other processes
  lc_untrack "$pid"
  return 0
}
lc_cleanup() {
  local pid mark
  [ -f "$LC_PIDS" ] || return 0
  while IFS=$'\t' read -r pid mark; do [ -n "$pid" ] && lc_kill "$pid" "$mark"; done < "$LC_PIDS"
  rm -f "$LC_PIDS" "$LC_PIDS.tmp"
}

lc_crash_report() { # exe name, pid, marker file -> path of a crash report of this pid written after the marker
  local f
  for f in $(find "$LC_CRASH_DIR" -maxdepth 1 \( -name "$1-*.ips" -o -name "$1_*.crash" -o -name "$1-*.crash" \) -newer "$3" 2>/dev/null); do
    if grep -qE "\"pid\" *: *$2([^0-9]|\$)|^PID: +$2|\[$2\]" "$f" 2>/dev/null; then echo "$f"; return 0; fi
  done
  return 1
}

lc_launch() {
  local app="$1" p="$2" to="$3" mode="${4:-direct}" expect="${5:-}" name exe token t0 i=0 res mark out rc gk="" f
  local w agent
  name="$(basename "$p")"; exe="$(lc_exe_of "$app")"; res="$p/qa_result.txt"
  LC_PID=""; LC_STATE=""; LC_REASON=""; LC_SECONDS=""; LC_FLAGS=""; LC_GK=""; LC_APP_RUN=""; LC_PARAM=""; LC_CRASH_AFTER=""
  token="ti4d.$$.$RANDOM$RANDOM.$(date +%s)"
  if [ ! -x "$exe" ]; then LC_STATE=BENCH; LC_REASON="executable not found: $exe"; return 1; fi
  if [ ! -f "$p/Project/$name.4DProject" ]; then LC_STATE=BENCH; LC_REASON="test project not found: $p/Project/$name.4DProject"; return 1; fi
  rm -f "$res"
  [ -f "$res" ] && { LC_STATE=BENCH; LC_REASON="cannot remove the previous result file $res"; return 1; }
  mark="$(mktemp /tmp/ti4d_launch.XXXXXX)"; out="$(mktemp /tmp/ti4d_launch_out.XXXXXX)"
  sleep 1 # crash reports must be strictly newer than the marker
  t0=$(date +%s)
  local args=(--project "$p/Project/$name.4DProject" --opening-mode interpreted --dataless --user-param "$token")
  case "$mode" in
    open|rosetta)
      if [ "$mode" = open ] && [ -n "${ABOUT_CHECK:-}" ] && [ -x "$ABOUT_CHECK" ]; then
        # first-launch alert of a quarantined app: answered with its default button when Accessibility is granted
        "$ABOUT_CHECK" --gatekeeper "$(basename "$app" .app)" "$to" > "$out.gk" 2>&1 & gk=$!
      fi
      if [ "$mode" = rosetta ]; then open -n --arch x86_64 "$app" --args "${args[@]}" > "$out" 2>&1; rc=$?
      else open -n "$app" --args "${args[@]}" > "$out" 2>&1; rc=$?; fi
      if [ $rc -ne 0 ]; then
        LC_STATE=BENCH; LC_REASON="open failed (exit $rc): $(tr '\n' ' ' < "$out")"
        [ -n "$gk" ] && { kill "$gk" 2>/dev/null; wait "$gk" 2>/dev/null; }
        rm -f "$mark" "$out" "$out.gk"; return 1
      fi;;
    # started from a subshell: the process is not a job of this shell (reaped by launchd, never a zombie
    # answering kill -0, no job notice) and is still identified by its PID
    x86_64|arm64) LC_PID="$(arch -"$mode" "$exe" "${args[@]}" < /dev/null > /dev/null 2>&1 & echo $!)";;
    *) LC_PID="$("$exe" "${args[@]}" < /dev/null > /dev/null 2>&1 & echo $!)";;
  esac
  [ -n "$LC_PID" ] && lc_track "$LC_PID" "$token"
  while [ $i -lt "$to" ]; do
    if [ -z "$LC_PID" ]; then
      LC_PID="$(pgrep -f -- "$token" 2>/dev/null | head -1)"
      if [ -n "$LC_PID" ]; then
        case "$(lc_cmd "$LC_PID")" in *"$token"*) lc_track "$LC_PID" "$token";; *) LC_PID="";; esac
      fi
    fi
    if [ -n "$LC_PID" ]; then f="$(ps -o flags= -p "$LC_PID" 2>/dev/null | tr -d ' ')"; [ -n "$f" ] && LC_FLAGS="$f"; fi
    [ -s "$res" ] && break
    if [ -n "$LC_PID" ] && ! lc_alive "$LC_PID"; then sleep 2; break; fi
    if [ -z "$LC_PID" ] && [ "$LC_NOPROC_GRACE" -gt 0 ] && [ $i -ge "$LC_NOPROC_GRACE" ]; then break; fi
    sleep 1; i=$((i+1))
  done
  LC_SECONDS=$(( $(date +%s) - t0 ))
  if [ -s "$res" ]; then
    sleep 1 # the file is written in one call, then 4D quits
    LC_APP_RUN="$(tr '\r' '\n' < "$res" | sed -n 's/^App: //p' | head -1)"; LC_APP_RUN="${LC_APP_RUN%/}"
    LC_PARAM="$(tr '\r' '\n' < "$res" | sed -n 's/^Param: //p' | head -1)"
  fi
  if [ -n "$gk" ]; then
    kill "$gk" 2>/dev/null; wait "$gk" 2>/dev/null
    LC_GK="$(awk -F'\t' '$1=="GK" && $2!="NONE" {print "macOS alert \"" $3 "\" -> " $2 " (answered automatically)"} $1=="ERR" {print "macOS alerts not handled automatically: " $3}' "$out.gk" 2>/dev/null)"
  fi
  if [ -s "$res" ] && [ ! "$res" -nt "$mark" ]; then
    LC_STATE=NOPROOF; LC_REASON="result file older than the launch: not a proof"
  elif [ -s "$res" ] && [ "$LC_PARAM" = "$token" ]; then
    LC_STATE=READY; LC_REASON="result file written by the launched process after ${LC_SECONDS}s (token $token)"
  elif [ -s "$res" ] && [ -z "$expect" ]; then
    LC_STATE=READY; LC_REASON="result file written after ${LC_SECONDS}s"
  elif [ -s "$res" ]; then
    LC_STATE=NOPROOF; LC_REASON="result file without the launch token (Param: '${LC_PARAM}'): cannot be attributed to this launch"
  elif [ -z "$LC_PID" ]; then
    w=""; agent=""
    if [ -n "${ABOUT_CHECK:-}" ] && [ -x "$ABOUT_CHECK" ]; then agent="$("$ABOUT_CHECK" --windows uiagent 2>/dev/null)"; fi
    if printf '%s' "$LC_GK" | grep -qiE "can.t be opened|cannot be opened|damaged|malicious|endommag|impossible d.ouvrir|ne peut pas .tre ouvert|kann nicht ge.ffnet|nelze otev|開けません|開くことができません"; then
      LC_STATE=BLOCKED; LC_REASON="refused by macOS before start: $LC_GK"
    elif [ -n "$agent" ]; then
      LC_STATE=DIALOG; LC_REASON="no 4D process, a macOS alert (CoreServicesUIAgent) is displayed and was not answered: $(printf '%s' "$agent" | cut -f6 | tr '\n' ' ')"
    else
      LC_STATE=NOPROCESS; LC_REASON="open succeeded but no process carrying the launch token appeared within ${to}s"
    fi
  elif ! lc_alive "$LC_PID"; then
    sleep 3
    if f="$(lc_crash_report "$(basename "$exe")" "$LC_PID" "$mark")"; then
      LC_STATE=CRASH; LC_REASON="pid $LC_PID crashed after ${LC_SECONDS}s, report $f: $(grep -m1 -oE '"exception" *: *\{[^}]*' "$f" | head -c 160)"
    else
      LC_STATE=EXIT; LC_REASON="pid $LC_PID ended after ${LC_SECONDS}s without writing the proof of start (no crash report)"
    fi
  else
    w=""
    if [ -n "${ABOUT_CHECK:-}" ] && [ -x "$ABOUT_CHECK" ]; then w="$("$ABOUT_CHECK" --windows "$LC_PID" 2>/dev/null)"; fi
    if [ -n "$w" ]; then
      LC_STATE=DIALOG; LC_REASON="pid $LC_PID still running after ${to}s with window(s) displayed (dialog preventing the start?): $(printf '%s\n' "$w" | cut -f5,6 | tr '\t\n' ' ;' | head -c 300)"
    else
      LC_STATE=HANG; LC_REASON="pid $LC_PID still running after ${to}s without window nor proof of start (hang)"
    fi
  fi
  if [ "$LC_STATE" = READY ] && [ -n "$expect" ]; then
    case "$(lc_real "$LC_APP_RUN")" in
      "$(lc_real "$expect")") LC_REASON="$LC_REASON; started from $LC_APP_RUN";;
      */AppTranslocation/*/d/"$(basename "$expect")") LC_REASON="$LC_REASON; started by macOS from a translocated read-only copy of $expect (App Translocation: $LC_APP_RUN)";;
      *) LC_STATE=NOPROOF; LC_REASON="the process that answered runs from '${LC_APP_RUN:-?}', not from $expect";;
    esac
  fi
  if [ "$LC_STATE" = READY ] && [ -n "$LC_PID" ]; then
    i=0; while lc_alive "$LC_PID" && [ $i -lt "$LC_QUIT_WAIT" ]; do sleep 1; i=$((i+1)); done
    if lc_alive "$LC_PID"; then LC_REASON="$LC_REASON; did not quit by itself within ${LC_QUIT_WAIT}s (terminated by pid)"
    elif f="$(sleep 2; lc_crash_report "$(basename "$exe")" "$LC_PID" "$mark")"; then LC_REASON="$LC_REASON; WARNING crash report after the proof: $f"; LC_CRASH_AFTER="$f"; fi
  fi
  [ -n "$LC_PID" ] && lc_kill "$LC_PID" "$token"
  rm -f "$mark" "$out" "$out.gk"
  [ "$LC_STATE" = READY ]
}
