#!/bin/bash
# No saved configuration or timeout can authorize a network interruption (manual cut, see also confirm_guard).
confirm_offline() {
  if [ "${GUI:-0}" = 1 ]; then
    local answer
    answer="$(osascript -e 'button returned of (display dialog "Faire maintenant le test hors ligne ? Il vous sera demandé de couper le réseau de tout le Mac (Wi-Fi, câble, VPN), puis de le rétablir. Vos appels et téléchargements seront interrompus. Passer laisse le réseau intact et signale le test non exécuté." buttons {"Passer","Autoriser la coupure"} default button "Passer" cancel button "Passer" with title "Test Installer 4D — Réseau" giving up after 120)' 2>/dev/null)" || return 1
    [ "$answer" = "Autoriser la coupure" ]
  else
    local answer
    printf '%s' "OFFLINE: authorize disconnecting this Mac NOW? Network will be restored afterwards. [y/N] " > /dev/tty 2>/dev/null || return 1
    IFS= read -r answer < /dev/tty 2>/dev/null || return 1
    case "$answer" in y|Y|yes|YES|o|O|oui|OUI) return 0;; *) return 1;; esac
  fi
}
online() { curl -s -o /dev/null --max-time 5 https://www.apple.com || nc -z -G 3 -w 3 1.1.1.1 443 >/dev/null 2>&1; }

# Offline proof: several independent paths to the Internet are probed in parallel. One failed HTTP request
# is not a proof. Any HTTP answer (even an error status) or any TCP connection by IP address means online.
# Sets NET_PROOF (method + results, kept in the results). Returns 0 = offline (every HTTPS and TCP probe
# failed), 1 = online (at least one succeeded).
NET_HTTPS_URLS="${NET_HTTPS_URLS:-https://www.apple.com https://captive.apple.com https://api.apple-cloudkit.com}"
NET_TCP_TARGETS="${NET_TCP_TARGETS:-17.253.144.10:443 1.1.1.1:443 8.8.8.8:443}"
NET_DNS_NAME="${NET_DNS_NAME:-apple.com}"
net_probe_https() { curl -s -o /dev/null --max-time 6 "$1" >/dev/null 2>&1; }
net_probe_tcp() { nc -z -G 4 -w 4 "${1%:*}" "${1##*:}" >/dev/null 2>&1; }
net_probe_dns() { dig +time=2 +tries=1 +short "$1" A 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; }
net_default_route() { route -n get default >/dev/null 2>&1; }
offline_proof() {
  local d u t n=0 ok_https=0 ok_tcp=0 nh=0 nt=0 route dns hl="" tl="" pids=""
  d="$(mktemp -d /tmp/ti4d_net.XXXXXX)" || { NET_PROOF="probe error: no temporary folder"; return 1; }
  for u in $NET_HTTPS_URLS; do n=$((n+1)); ( net_probe_https "$u" && : > "$d/h$n" ) & pids="$pids $!"; done
  n=0
  for t in $NET_TCP_TARGETS; do n=$((n+1)); ( net_probe_tcp "$t" && : > "$d/t$n" ) & pids="$pids $!"; done
  ( net_probe_dns "$NET_DNS_NAME" && : > "$d/dns" ) & pids="$pids $!"
  if net_default_route; then route=present; else route=absent; fi
  wait $pids # only the probes (never other background jobs of the caller, e.g. a 4D kept open)
  n=0
  for u in $NET_HTTPS_URLS; do n=$((n+1)); nh=$((nh+1)); u="${u#https://}"; u="${u%%/*}"
    if [ -e "$d/h$n" ]; then ok_https=$((ok_https+1)); hl="$hl $u=reached,"; else hl="$hl $u=no answer,"; fi; done
  n=0
  for t in $NET_TCP_TARGETS; do n=$((n+1)); nt=$((nt+1))
    if [ -e "$d/t$n" ]; then ok_tcp=$((ok_tcp+1)); tl="$tl $t=connected,"; else tl="$tl $t=refused/timeout,"; fi; done
  if [ -e "$d/dns" ]; then dns=resolved; else dns="no answer"; fi
  rm -rf "$d"
  hl="${hl# }"; hl="${hl%,}"; tl="${tl# }"; tl="${tl%,}"
  NET_PROOF="$(date '+%Y-%m-%d %H:%M:%S') default route: $route; DNS $NET_DNS_NAME: $dns; HTTPS $ok_https/$nh reachable ($hl); TCP by IP $ok_tcp/$nt ($tl)"
  [ "$ok_https" -eq 0 ] && [ "$ok_tcp" -eq 0 ]
}
# ---------- automatic cut (opt-in): pf firewall guard, see net_guard.sh ----------
# Started once per run after explicit permission (confirmation, then the macOS administrator dialog). The
# network settings are never modified: the guard only loads block rules into its own pf anchor during each
# offline test and removes them afterwards (automatically at the latest after the requested duration).
NG_DIR="${NG_DIR:-/var/run/com.4d.ti4d.netguard}"
NG_REQ="${NG_REQ:-$HOME/4DQA_mac/netguard_request}"
NG_SRC="${NG_SRC:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/net_guard.sh}"
NG_WAIT="${NG_WAIT:-25}"
NG_ADMIN_SCRIPT='on run argv
	set src to quoted form of (item 1 of argv)
	set owner to quoted form of (item 2 of argv)
	set req to quoted form of (item 3 of argv)
	do shell script "umask 022; D=/var/run/com.4d.ti4d.netguard; [ ! -L \"$D\" ] && /bin/mkdir -p \"$D\" && /usr/sbin/chown root:wheel \"$D\" && /bin/chmod 755 \"$D\" && /usr/bin/install -m 700 -o root -g wheel " & src & " \"$D/net_guard.sh\" && { /bin/bash \"$D/net_guard.sh\" daemon " & owner & " " & req & " \"$D\" </dev/null >\"$D/daemon.log\" 2>&1 & }" with prompt "Test Installer 4D veut bloquer temporairement le trafic réseau (pare-feu macOS pf) pendant les tests sans Internet de cette exécution. Le réseau est rétabli automatiquement." with administrator privileges
end run'
NG_RECOVER_SCRIPT='do shell script "D=/var/run/com.4d.ti4d.netguard; /sbin/pfctl -a com.apple/000.TestInstaller4D -F rules >/dev/null 2>&1; t=$(/usr/bin/tr -cd 0-9 < \"$D/token\" 2>/dev/null); [ -n \"$t\" ] && /sbin/pfctl -X \"$t\" >/dev/null 2>&1; /bin/rm -f \"$D/token\"; echo \"0 0 stopped $(/bin/date +%s) network restored by the recovery of an interrupted guard\" > \"$D/state\"" with prompt "Test Installer 4D doit retirer ses règles de pare-feu (pf) laissées par une exécution interrompue, pour rétablir le réseau." with administrator privileges'
confirm_guard() {
  local answer msg="Autoriser le test sans Internet automatique pour cette exécution ?

Pendant chaque test sans Internet (5 minutes au plus par langue), Test Installer 4D bloque tout le trafic réseau de ce Mac avec le pare-feu de macOS (pf), puis le rétablit automatiquement. Wi-Fi, câble et réglages réseau ne sont pas modifiés.

Pendant ces minutes, les sessions à distance (TeamViewer, partage d’écran), appels et téléchargements sont coupés. macOS va demander le mot de passe d’un administrateur ; l’outil ne le voit pas et ne l’enregistre pas.

Passer : le test sans Internet vous demandera de couper le réseau vous-même."
  if [ "${GUI:-0}" = 1 ]; then
    answer="$(osascript -e 'on run argv' -e 'button returned of (display dialog (item 1 of argv) buttons {"Passer","Autoriser"} default button "Passer" cancel button "Passer" with title "Test Installer 4D — Test sans Internet automatique" with icon caution giving up after 180)' -e 'end run' "$msg" 2>/dev/null)" || return 1
    [ "$answer" = "Autoriser" ]
  else
    printf '%s\n%s' "$msg" "Autoriser ? [o/N] " > /dev/tty 2>/dev/null || return 1
    IFS= read -r answer < /dev/tty 2>/dev/null || return 1
    case "$answer" in o|O|oui|OUI|y|Y|yes|YES) return 0;; *) return 1;; esac
  fi
}
guard_read() {
  GUARD_PID=""; GUARD_SEQ=""; GUARD_STATUS=""; GUARD_TIME=""; GUARD_DETAIL=""
  [ -f "$NG_DIR/state" ] || return 1
  read -r GUARD_PID GUARD_SEQ GUARD_STATUS GUARD_TIME GUARD_DETAIL < "$NG_DIR/state" 2>/dev/null
  [ -n "$GUARD_STATUS" ]
}
guard_alive() {
  case "$GUARD_PID" in ''|*[!0-9]*) return 1;; esac
  ps -p "$GUARD_PID" -o command= 2>/dev/null | grep -q 'net_guard\.sh daemon'
}
guard_running() { guard_read && [ "$GUARD_STATUS" != stopped ] && guard_alive; }
# block rules possibly left by a guard that could not clean up (killed); pf rules never survive a restart
guard_stale() {
  local boot
  guard_read || return 1
  guard_alive && return 1
  case "$GUARD_STATUS" in blocked|error) ;; *) return 1;; esac
  boot="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')"
  [ -n "$boot" ] && [ "${GUARD_TIME:-0}" -lt "$boot" ] && return 1
  return 0
}
guard_send() { # request [argument] -> 0 once the guard answered this request (GUARD_STATUS, GUARD_DETAIL)
  local seq last="" i=0
  guard_running || { GUARD_DETAIL="the network guard is not running${GUARD_DETAIL:+ ($GUARD_DETAIL)}"; return 1; }
  seq=$(( ${GUARD_SEQ:-0} + 1 ))
  [ -f "$NG_REQ" ] && read -r last _ < "$NG_REQ"
  case "$last" in ''|*[!0-9]*) ;; *) [ "$last" -ge "$seq" ] && seq=$((last + 1));; esac
  { printf '%s %s %s\n' "$seq" "$1" "${2:-}" > "$NG_REQ.tmp" && mv -f "$NG_REQ.tmp" "$NG_REQ"; } 2>/dev/null \
    || { GUARD_DETAIL="request file not writable: $NG_REQ"; return 1; }
  while [ $i -lt $((NG_WAIT * 2)) ]; do
    sleep 0.5; i=$((i+1))
    guard_read && [ "$GUARD_SEQ" = "$seq" ] && return 0
    guard_alive || { GUARD_DETAIL="the network guard stopped: ${GUARD_DETAIL:-no state}"; return 1; }
  done
  GUARD_DETAIL="no answer from the network guard within ${NG_WAIT}s"; return 1
}
guard_block() { guard_send block "$1" && [ "$GUARD_STATUS" = blocked ]; }
guard_open() { guard_send open && [ "$GUARD_STATUS" = open ]; }
guard_quit() {
  guard_running || { GUARD_DETAIL="not running"; return 0; }
  guard_send quit && [ "$GUARD_STATUS" = stopped ] && return 0
  guard_read; ! guard_alive && [ "$GUARD_STATUS" = stopped ]
}
guard_start() { # owner_pid -> 0 ready, 2 declined or cancelled, 1 error; GUARD_DETAIL = reason
  local owner="$1" t0 out rc=0 i=0
  if guard_running; then GUARD_DETAIL="network guard already running (pid $GUARD_PID): $GUARD_DETAIL"; return 0; fi
  [ -f "$NG_SRC" ] || { GUARD_DETAIL="net_guard.sh missing: $NG_SRC"; return 1; }
  confirm_guard || { GUARD_DETAIL="automatic cut declined, unanswered or skipped"; return 2; }
  mkdir -p "$(dirname "$NG_REQ")"; rm -f "$NG_REQ" "$NG_REQ.tmp"
  t0="$(date +%s)"
  if [ -n "${NG_LAUNCH:-}" ]; then out="$("$NG_LAUNCH" "$NG_SRC" "$owner" "$NG_REQ" "$NG_DIR" 2>&1)" || rc=$? # tests: no root
  else out="$(osascript -e "$NG_ADMIN_SCRIPT" "$NG_SRC" "$owner" "$NG_REQ" 2>&1)" || rc=$?; fi
  if [ "$rc" != 0 ]; then
    case "$out" in *-128*|*anceled*|*nnulé*) GUARD_DETAIL="administrator dialog cancelled"; return 2;; esac
    GUARD_DETAIL="the network guard could not be started: $(printf '%s' "$out" | head -3 | tr '\n' ' ')"; return 1
  fi
  while [ $i -lt $((NG_WAIT * 2)) ]; do
    if guard_read && [ "${GUARD_TIME:-0}" -ge "$t0" ]; then
      [ "$GUARD_STATUS" = ready ] && guard_alive && return 0
      [ "$GUARD_STATUS" = stopped ] && { GUARD_DETAIL="the network guard stopped: $GUARD_DETAIL"; return 1; }
    fi
    sleep 0.5; i=$((i+1))
  done
  GUARD_DETAIL="the network guard did not answer within ${NG_WAIT}s"; return 1
}
guard_recover() {
  guard_stale || return 0
  echo "The network guard of an interrupted run did not restore the network (state: $GUARD_STATUS)."
  if osascript -e "$NG_RECOVER_SCRIPT" >/dev/null 2>&1; then echo "pf rules of the tool removed: network restored"; return 0; fi
  echo "WARNING: the network may still be blocked: restart the Mac, or run in Terminal: sudo pfctl -a com.apple/000.TestInstaller4D -F rules"
  return 1
}
# Legacy recovery only: earlier versions disabled network services listed in NETF.
net_on() {
  local s i=0 failed=0
  [ -f "$NETF" ] || return 0
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    networksetup -setnetworkserviceenabled "$s" on >/dev/null 2>&1
    if [ "$(networksetup -getnetworkserviceenabled "$s" 2>/dev/null)" != Enabled ]; then
      echo "Could not restore network service: $s" >&2
      failed=1
    fi
  done < "$NETF"
  [ "$failed" = 0 ] || return 1
  rm -f "$NETF"
  until online || [ "$i" -ge 90 ]; do sleep 1; i=$((i+1)); done
  online
}
