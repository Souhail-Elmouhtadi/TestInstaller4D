#!/bin/bash
# Tests of the installation / execution rows (exec_checks.sh + results.sh): no false positive, the offline row
# is only green with a proof of start while the absence of Internet is verified before and after the launch.
# Network, launch, codesign, stapler and spctl are mocked: nothing is cut, nothing is launched.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_exec.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (exec): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
has() { grep -qF -- "$2" <<< "$1"; }

KIT="$ROOT/macOS"
. "$KIT/version.sh"; . "$KIT/results.sh"; . "$KIT/network.sh"; . "$KIT/exec_checks.sh"
BASE="$TMP/base"; mkdir -p "$BASE"; OUT="$TMP/out.tsv"; : > "$OUT"
PRODUCT=4D; VERSION=21.2; BUILD=100629; APPNAME=4D.app; DMG="$TMP/4D.dmg"; DMG_SHA=aaaa; : > "$DMG"
SRCAPP="$TMP/mnt/4D 21.2/4D.app"; PAPP="$TMP/work/pristine/4D.app"; mkdir -p "$SRCAPP"
OFF_SETTLE=0; GUI=0

mkapp() { # path version-string
  mkdir -p "$1/Contents/MacOS"
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $2" -c "Add :CFBundleExecutable string 4D" "$1/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $2" "$1/Contents/Info.plist" >/dev/null
}
APP="$TMP/Apps/4D 21.2/4D.app"; mkapp "$APP" "21.2 build 21.100629"

# ---- mocks ----
LOG="$TMP/calls.log"
call() { echo "$*" >> "$LOG"; }
called() { grep -q "^$1" "$LOG" 2>/dev/null; }
ncalls() { grep -c "^$1" "$LOG" 2>/dev/null || true; }
FAKE_VERIFY=0; FAKE_CDHASH=cd01; FAKE_TICKET=""; FAKE_CLT=0; FAKE_STAPLED=""
codesign() {
  case "$1" in
    --verify) return "$FAKE_VERIFY";;
    -dvvv) echo "CDHash=$FAKE_CDHASH"; case " $FAKE_TICKET " in *" $2 "*) echo "Notarization Ticket=stapled";; esac;;
  esac
}
clt() { return "$FAKE_CLT"; }
xcrun() { # stapler validate <path>
  call "stapler $3"
  case "|$FAKE_STAPLED|" in *"|$3|"*) echo "The validate action worked!"; return 0;; esac
  echo "$3 does not have a ticket stapled to it."; return 65
}
FAKE_SPCTL="$SRCAPP: accepted source=Notarized Developer ID"
spctl() { call spctl; echo "$FAKE_SPCTL"; }
FAKE_ONLINE=0; online() { call online; return "$FAKE_ONLINE"; }
PROBES=""
offline_proof() { # pops the next answer: 0 = no Internet (all probes failed), 1 = Internet reachable
  local r="${PROBES%% *}"; [ -z "$r" ] && r=1
  PROBES="${PROBES#"$r"}"; PROBES="${PROBES# }"
  call "probe $r"; NET_PROOF="mock probes ($r)"; return "$r"
}
FAKE_CONFIRM=0; confirm_offline() { call confirm; return "$FAKE_CONFIRM"; }
FAKE_ASK=""; ask() { call "ask $1"; echo "$FAKE_ASK"; }
FAKE_NETON=0; net_on() { call net_on; return "$FAKE_NETON"; }
# pf guard (net_guard.sh is tested in test_netguard.sh): 0 = running / success
FAKE_GRUN=1; FAKE_GSTART=0; FAKE_BLOCK=0; FAKE_GOPEN=0; FAKE_GSTALE=1; FAKE_GONE=0
guard_running() { call guard_running; if [ "$FAKE_GRUN" = 0 ]; then GUARD_STATUS=ready; return 0; fi; GUARD_DETAIL="mock: no guard"; return 1; }
guard_start() { call "guard_start $1"; GUARD_DETAIL="mock start ($FAKE_GSTART)"; [ "$FAKE_GSTART" = 0 ] && FAKE_GRUN=0; return "$FAKE_GSTART"; }
guard_block() { call "guard_block $1"; if [ "$FAKE_BLOCK" = 0 ]; then GUARD_DETAIL="pf firewall: mock block"; else GUARD_DETAIL="mock block failure"; fi; return "$FAKE_BLOCK"; }
guard_open() { call guard_open; GUARD_DETAIL="pf rules removed (mock)"; [ "$FAKE_GONE" = 1 ] && FAKE_GRUN=1; return "$FAKE_GOPEN"; }
guard_stale() { return "$FAKE_GSTALE"; }
FAKE_NEWPROJ=0
newproj() { local p="$TMP/projects/$2"; rm -rf "$p"; mkdir -p "$p/Project"; [ "$FAKE_NEWPROJ" = 0 ] && : > "$p/Project/$2.4DProject"; call "newproj $2"; echo "$p"; }
fresh_pristine() { call pristine; mkdir -p "$PAPP"; }
FAKE_LC=READY; FAKE_LC_REASON="result file written (token t)"; FAKE_LC_GK=""; FAKE_CRASH_AFTER=""
lc_launch() { call "launch $1|$5|$4"; LC_STATE="$FAKE_LC"; LC_REASON="$FAKE_LC_REASON"; LC_GK="$FAKE_LC_GK"; LC_CRASH_AFTER="$FAKE_CRASH_AFTER"; [ "$LC_STATE" = READY ]; }
FAKE_AX=1
ABOUT_CHECK="$TMP/about_check"
printf '#!/bin/bash\n[ "$1" = --permissions ] && printf "AX\\t%%s\\n" "$(cat "%s/ax")"\n' "$TMP" > "$ABOUT_CHECK"; chmod +x "$ABOUT_CHECK"
setax() { echo "$1" > "$TMP/ax"; }; setax 1

reset() { : > "$LOG"; : > "$OUT"; PROBES=""; FAKE_CONFIRM=0; FAKE_ASK=""; FAKE_NETON=0; FAKE_LC=READY
  FAKE_GRUN=1; FAKE_GSTART=0; FAKE_BLOCK=0; FAKE_GOPEN=0; FAKE_GSTALE=1; FAKE_GONE=0; QA_GUARD_OWNED=0; NET_BACK_WAIT=1
  unset NET_SESSION NET_GUARD_NOTE
  FAKE_LC_REASON="result file written (token t)"; FAKE_LC_GK=""; FAKE_CRASH_AFTER=""; NET_AUTO=0; FAKE_NEWPROJ=0; setax 1
  FAKE_ONLINE=0; FAKE_SPCTL="$SRCAPP: accepted source=Notarized Developer ID"; FAKE_CLT=0; FAKE_STAPLED=""; FAKE_TICKET=""
  FAKE_VERIFY=0; FAKE_CDHASH=cd01; rm -rf "$APP"; mkapp "$APP" "21.2 build 21.100629"; rm -f "$BASE"/assessed_*; }
field() { awk -F'\t' -v a="$1" -v n="$2" '$1==a{v=$n} END{print v}' "$OUT"; }
status() { field "$1" 2; }
detail() { field "$1" 3; }

# ---- results.sh ----
reset
begin; warn w; ko k; notrun n; check test "$ST" = ko
begin; notrun n; need_action a; undetermined u; check test "$ST" = action
begin; undetermined u; warn w; check test "$ST" = undetermined
begin; add "line1"; add "a	tab"; res "Row" "$ST" "$D" "/x/4D.app" >/dev/null
check test "$(awk -F'\t' '{print NF}' "$OUT")" = 5
check test "$(status Row)" = ok
check test "$(detail Row)" = 'line1\na tab'
check test "$(field Row 5)" = "/x/4D.app"
grep -qE '^Row	ok	.*	20[0-9]{2}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}	' "$OUT"; check test $? = 0
RES_PATH=/default; begin; res "Row2" ok "x" >/dev/null; check test "$(field Row2 5)" = /default; unset RES_PATH

# ---- xc_install ----
STATE="$TMP/install_state.tsv"
mkstate() { : > "$STATE"; local kv; for kv in "$@" STATUS=ok DATE=2026-01-01 MODE=new PRODUCT=4D VERSION=21.2 BUILD=100629 "DMG=$DMG" DMG_SHA256=aaaa DMG_SIZE=10 \
  ORIGIN=https://product-download.4d.com/ "APP=$APP" "TARGET_DIR=$TMP/Apps/4D 21.2" ITEMS=4D.app MOUNT=detached INSTALLED_CDHASH=cd01 QUARANTINE_AT_INSTALL=none; do
  printf '%s\t%s\n' "${kv%%=*}" "${kv#*=}" >> "$STATE"; done; }
reset; rm -f "$STATE"; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = notrun; check test -z "$INST_APP"
reset; mkstate; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = ok; check test "$INST_APP" = "$APP"; check test "$(field "$A_INSTALL" 5)" = "$APP"
reset; mkstate STATUS=ko ERROR_CODE=EXISTS; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = action; check test -z "$INST_APP"
reset; mkstate STATUS=ko ERROR_CODE=SPACE "ERROR=not enough space"; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = notrun; check has "$(detail "$A_INSTALL")" "not enough space"
reset; mkstate DMG_SHA256=bbbb; xc_install "$STATE" >/dev/null # installed from another disk image: stale
check test "$(status "$A_INSTALL")" = notrun; check test -z "$INST_APP"
reset; mkstate BUILD=100624; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = notrun; check test -z "$INST_APP"
reset; mkstate PRODUCT="4D Server"; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = notrun
reset; mkstate "APP=$TMP/Apps/gone/4D.app"; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = ko; check test -z "$INST_APP"
reset; mkstate; mkapp "$APP" "21.2 build 21.100624"; xc_install "$STATE" >/dev/null # replaced by another build since
check test "$(status "$A_INSTALL")" = ko; check test -z "$INST_APP"; mkapp "$APP" "21.2 build 21.100629"
reset; mkstate; FAKE_VERIFY=1; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = ko; check test -z "$INST_APP"
reset; mkstate; FAKE_CDHASH=ffff; xc_install "$STATE" >/dev/null
check test "$(status "$A_INSTALL")" = ko

# ---- xc_offline ----
off() { xc_offline "$1" > "$TMP/stdout" 2>&1; }
# not installed: not executed, network untouched, nothing launched
reset; off ""; check test "$(status "$A_EXEC_OFF")" = notrun; check not called launch; check not called confirm; check not called probe
# success, manual cut: probes online -> offline -> offline after the launch
reset; PROBES="1 0 0"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ok
check called "launch $APP|$APP|open"
check has "$(detail "$A_EXEC_OFF")" "Absence of Internet verified before the launch (network cut manually by the user)"
check has "$(detail "$A_EXEC_OFF")" "Absence of Internet verified after the launch"
check test "$(field "$A_EXEC_OFF" 5)" = "$APP"
check not called guard_block; check called "ask Turn the network back ON"
# the test project is prepared before any network change
check test "$(grep -n '^newproj' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^confirm' "$LOG" | cut -d: -f1)"
# crash / exit / hang / refused
for s in CRASH EXIT HANG BLOCKED; do reset; PROBES="1 0 0"; FAKE_LC=$s; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ko; done
reset; PROBES="1 0 0"; FAKE_LC=HANG; FAKE_LC_REASON="pid 12 still running after 180s"; off "$APP"
check has "$(detail "$A_EXEC_OFF")" "blocked, no proof of start within the time limit"
# network still active after the cut (and after the second request): action required, no launch
reset; PROBES="1 1 1 1 1 1"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = action; check not called launch
check test "$(ncalls 'ask ')" = 3 # cut, still reachable, network back
# declined / skipped / unanswered: not executed, network not touched, no launch
reset; PROBES="1"; FAKE_CONFIRM=1; off "$APP"
check test "$(status "$A_EXEC_OFF")" = notrun; check not called launch; check not called ask; check not called guard_block
reset; PROBES="1"; FAKE_ASK=s; off "$APP"
check test "$(status "$A_EXEC_OFF")" = notrun; check not called launch
# Internet back during the launch: undetermined even with a proof of start
reset; PROBES="1 0 1"; off "$APP"; check test "$(status "$A_EXEC_OFF")" = undetermined
# Mac already offline: no request, launch
reset; PROBES="0 0"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ok; check not called confirm; check has "$(detail "$A_EXEC_OFF")" "Mac already without Internet"
# automatic cut (opt-in, pf guard authorized once at the start of the run)
auto() { reset; NET_AUTO=1; NET_SESSION=1; FAKE_GRUN=0; }
auto; PROBES="1 0 0"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ok; check called "guard_block 300"; check called guard_open
check not called confirm; check not called "ask "; check not called guard_start; check not called net_on
check has "$(detail "$A_EXEC_OFF")" "Absence of Internet verified before the launch (pf firewall: mock block; authorized explicitly at the start of the run)"
check has "$(detail "$A_EXEC_OFF")" "Network restored automatically (pf rules removed (mock)); Internet reachable again"
# the test project is prepared and the probes run before the block; the launch happens while blocked, then open
check test "$(grep -n '^newproj' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^guard_block' "$LOG" | cut -d: -f1)"
check test "$(grep -n '^guard_block' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^launch' "$LOG" | cut -d: -f1)"
check test "$(grep -n '^launch' "$LOG" | cut -d: -f1)" -lt "$(grep -n '^guard_open' "$LOG" | cut -d: -f1)"
# crash / hang while blocked: ko, network restored
for s in CRASH HANG; do auto; PROBES="1 0 0"; FAKE_LC=$s; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ko; check called guard_open; done
# the block fails: action required, network restored, never launched
auto; PROBES="1"; FAKE_BLOCK=1; off "$APP"
check test "$(status "$A_EXEC_OFF")" = action; check called guard_open; check not called launch
check has "$(detail "$A_EXEC_OFF")" "the automatic cut (pf firewall) failed: mock block failure"
# Internet still reachable despite the block (4 probe rounds): action required, no launch, no manual prompt
auto; PROBES="1 1 1 1 1"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = action; check not called launch; check called guard_open; check not called "ask "
check test "$(ncalls 'probe ')" = 5
# Internet back during the launch: undetermined
auto; PROBES="1 0 1"; off "$APP"; check test "$(status "$A_EXEC_OFF")" = undetermined
# the block cannot be lifted (guard still running or stale): ko, never green
auto; PROBES="1 0 0"; FAKE_GOPEN=1; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ko
check has "$(detail "$A_EXEC_OFF")" "Network possibly still blocked"
auto; PROBES="1 0 0"; FAKE_GOPEN=1; FAKE_GRUN=0; FAKE_GSTALE=0; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ko
# the guard stopped by itself (it removed its rules): no failure
auto; PROBES="1 0 0"; FAKE_GOPEN=1; FAKE_GONE=1; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ok
check has "$(detail "$A_EXEC_OFF")" "network guard stopped"
# rules removed but Internet not back yet: reported, the launch result is kept
auto; PROBES="1 0 0"; FAKE_ONLINE=1; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ok
check has "$(detail "$A_EXEC_OFF")" "Internet not reachable yet"
# declined at the start of the run: manual cut requested (or not executed), the guard is never started here
auto; FAKE_GRUN=1; NET_GUARD_NOTE="automatic cut declined at the start of the run"; PROBES="1 0 0"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ok; check called confirm; check not called guard_start; check not called guard_block
check has "$(detail "$A_EXEC_OFF")" "Automatic cut not used: automatic cut declined at the start of the run; manual cut requested"
check has "$(detail "$A_EXEC_OFF")" "network cut manually by the user"
auto; FAKE_GRUN=1; NET_GUARD_NOTE="automatic cut declined at the start of the run"; PROBES="1"; FAKE_CONFIRM=1; off "$APP"
check test "$(status "$A_EXEC_OFF")" = notrun; check not called launch; check not called guard_block
# the guard of the run is gone (e.g. lifetime): manual, with the reason
auto; FAKE_GRUN=1; PROBES="1 0 0"; off "$APP"; check has "$(detail "$A_EXEC_OFF")" "no longer running"
# direct run of qa_mac.sh (no session): the guard is started for this process and stopped by its cleanup
reset; NET_AUTO=1; PROBES="1 0 0"; off "$APP"
check called "guard_start $$"; check test "$QA_GUARD_OWNED" = 1; check test "$(status "$A_EXEC_OFF")" = ok
reset; NET_AUTO=1; FAKE_GSTART=2; PROBES="1"; FAKE_CONFIRM=1; off "$APP"
check test "$(status "$A_EXEC_OFF")" = notrun; check has "$(detail "$A_EXEC_OFF")" "automatic cut unavailable: mock start (2)"
check not called guard_block; check not called launch
# Mac already offline: nothing is blocked
auto; PROBES="0 0"; off "$APP"; check test "$(status "$A_EXEC_OFF")" = ok; check not called guard_block
# default without NET_AUTO: manual (the kit never disables the network services by itself)
reset; unset NET_AUTO; PROBES="1 0 0"; off "$APP"; check not called guard_block; check not called guard_start; check called confirm
# dialogs
reset; PROBES="1 0 0"; FAKE_LC=DIALOG; FAKE_LC_REASON="window: 4D Activation"; setax 0; off "$APP"
check test "$(status "$A_EXEC_OFF")" = action
reset; PROBES="1 0 0"; FAKE_LC=DIALOG; FAKE_LC_REASON="window: 4D Activation"; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ko
reset; PROBES="1 0 0"; FAKE_LC=DIALOG; FAKE_LC_REASON="“4D” can’t be opened because Apple cannot check it"; setax 0; off "$APP"
check test "$(status "$A_EXEC_OFF")" = ko
# no usable proof / bench error
for s in NOPROOF NOPROCESS BENCH; do reset; PROBES="1 0 0"; FAKE_LC=$s; off "$APP"; check test "$(status "$A_EXEC_OFF")" = undetermined; done
reset; FAKE_NEWPROJ=1; off "$APP"; check test "$(status "$A_EXEC_OFF")" = undetermined; check not called confirm
# crash report after the proof: to check by hand, not green
reset; PROBES="1 0 0"; FAKE_CRASH_AFTER=/x/4D.ips; off "$APP"; check test "$(status "$A_EXEC_OFF")" = manual
# cache effects are reported
reset; PROBES="1 0 0"; xattr -w com.apple.quarantine "0041;00000000;Safari;" "$APP"; echo 2026-01-01 > "$BASE/assessed_cd01"; off "$APP"
check has "$(detail "$A_EXEC_OFF")" "already recorded a user approval"
check has "$(detail "$A_EXEC_OFF")" "cached notarisation result"
reset; PROBES="1 0 0"; off "$APP"; check has "$(detail "$A_EXEC_OFF")" "no quarantine attribute"

# ---- xc_staple: static, never a proof of an offline launch ----
INST_APP="$APP"
reset; FAKE_STAPLED="$SRCAPP|$DMG|$APP"; xc_staple >/dev/null
check test "$(status "$A_STAPLE")" = ok; check has "$(detail "$A_STAPLE")" "does not prove that 4D starts without Internet"
check called "stapler $APP"
reset; FAKE_STAPLED=""; xc_staple >/dev/null; check test "$(status "$A_STAPLE")" = ko
reset; FAKE_STAPLED="$DMG"; xc_staple >/dev/null; check test "$(status "$A_STAPLE")" = ok
check has "$(detail "$A_STAPLE")" "relies on the ticket of the disk image"
reset; FAKE_STAPLED="$SRCAPP|$DMG"; xc_staple >/dev/null; check test "$(status "$A_STAPLE")" = ko
reset; FAKE_CLT=1; FAKE_TICKET="$SRCAPP $APP"; xc_staple >/dev/null; check test "$(status "$A_STAPLE")" = ok; check not called stapler
# stapler OK + offline not executed: the offline row stays not executed (separate rows, no inheritance)
reset; FAKE_STAPLED="$SRCAPP|$DMG|$APP"; PROBES="1"; FAKE_CONFIRM=1; off "$APP"; xc_staple >/dev/null
check test "$(status "$A_EXEC_OFF")" = notrun; check test "$(status "$A_STAPLE")" = ok
INST_APP=""

# ---- xc_online ----
reset; FAKE_ONLINE=1; xc_online >/dev/null
check test "$(status "$A_EXEC_ON")" = notrun; check not called spctl; check not called launch
reset; xc_online >/dev/null
check test "$(status "$A_EXEC_ON")" = ok; check called "launch $PAPP|$PAPP|open"; check test -f "$BASE/assessed_cd01"
check test "$(field "$A_EXEC_ON" 5)" = "$PAPP"
reset; FAKE_SPCTL="$SRCAPP: rejected"; xc_online >/dev/null; check test "$(status "$A_EXEC_ON")" = ko
reset; FAKE_LC=CRASH; xc_online >/dev/null; check test "$(status "$A_EXEC_ON")" = ko; check test ! -f "$BASE/assessed_cd01"

# no row is ever green without a proof: every non-READY launch state gives a non-ok status
for s in CRASH EXIT HANG DIALOG BLOCKED NOPROCESS NOPROOF BENCH ""; do
  reset; PROBES="1 0 0"; FAKE_LC="$s"; off "$APP"; check test "$(status "$A_EXEC_OFF")" != ok
done
echo "exec: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
