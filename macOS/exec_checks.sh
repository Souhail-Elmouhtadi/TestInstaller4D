#!/bin/bash
# Installation and execution checks of the checklist (sourced by qa_mac.sh and by the tests).
# Needs: results.sh, network.sh, launch_check.sh, version.sh and, from the engine: newproj, fresh_pristine,
# clt, ask, SRCAPP, PAPP, APPNAME, DMG, DMG_SHA, PRODUCT, VERSION, BUILD, BASE, ABOUT_CHECK.
# Three separate rows: launch WITH Internet (notarisation checked online), stapled ticket (static check), and
# the actual launch WITHOUT Internet of the installed application. A spctl or stapler success never makes the
# offline row green: only a proof of start written by 4D while the absence of Internet is verified does.
A_INSTALL="Installation of 4D"
A_EXEC_OFF="Execution of application (without Internet)"
A_STAPLE="Notarization ticket (stapling)"
A_EXEC_ON="Execution of application (with Internet)"
OFF_TIMEOUT="${OFF_TIMEOUT:-180}"
ON_TIMEOUT="${ON_TIMEOUT:-180}"
XC_BLOCK_RE="can.t be opened|cannot be opened|damaged|malicious|not opened|endommag|impossible d.ouvrir|ne peut pas .tre ouvert|pas pu .tre ouvert|logiciel malveillant|kann nicht ge.ffnet|besch.digt|nelze otev|poškozen|開けません|開くことができません|壊れている"

xc_state() { awk -F'\t' -v k="$2" '$1==k{print $2; exit}' "$1" 2>/dev/null; }
xc_cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1; }
xc_ax() { [ -n "${ABOUT_CHECK:-}" ] && [ -x "$ABOUT_CHECK" ] && grep -q '^AX	1' <<< "$("$ABOUT_CHECK" --permissions 2>/dev/null)"; }

# ---------- installation done by install_4d.sh for this disk image and this selection ----------
xc_install() { # state file -> INST_APP (empty when not usable)
  local f="$1" app sv iv ib cd
  INST_APP=""
  begin
  if [ ! -s "$f" ]; then
    notrun "Installation not done by the tool (no installation record): install 4D first, the offline test launches the installed application"
    res "$A_INSTALL" "$ST" "$D"; return 0
  fi
  app="$(xc_state "$f" APP)"
  add "Last installation: $(xc_state "$f" DATE) ($(xc_state "$f" MODE))"
  if [ "$(xc_state "$f" STATUS)" != ok ]; then
    if [ "$(xc_state "$f" ERROR_CODE)" = EXISTS ]; then need_action "An installation already exists in $(xc_state "$f" TARGET_DIR): choose Replace or Use the existing one"
    else notrun "The last installation failed ($(xc_state "$f" ERROR_CODE)): $(xc_state "$f" ERROR)"; fi
    res "$A_INSTALL" "$ST" "$D" "$app"; return 0
  fi
  if [ -n "${DMG_SHA:-}" ] && [ "$(xc_state "$f" DMG_SHA256)" != "$DMG_SHA" ]; then
    notrun "The installed application comes from another disk image ($(xc_state "$f" DMG), SHA-256 $(xc_state "$f" DMG_SHA256)), not from the tested one ($DMG): install it again"
    res "$A_INSTALL" "$ST" "$D" "$app"; return 0
  fi
  if [ "$(xc_state "$f" PRODUCT)" != "$PRODUCT" ] || ! version_equal "$(xc_state "$f" VERSION)" "$VERSION" || [ "$(xc_state "$f" BUILD)" != "$BUILD" ]; then
    notrun "The installed application is $(xc_state "$f" PRODUCT) $(xc_state "$f" VERSION) build $(xc_state "$f" BUILD), the selection is $PRODUCT $VERSION build $BUILD: install it again"
    res "$A_INSTALL" "$ST" "$D" "$app"; return 0
  fi
  add "Disk image: $(xc_state "$f" DMG) ($(xc_state "$f" DMG_SIZE) bytes, SHA-256 $(xc_state "$f" DMG_SHA256)), origin: $(xc_state "$f" ORIGIN)"
  add "Installed items: $(xc_state "$f" ITEMS) -> $(xc_state "$f" TARGET_DIR)"
  add "Disk image: $(xc_state "$f" MOUNT)"
  [ -n "$(xc_state "$f" PREVIOUS)" ] && add "$(xc_state "$f" PREVIOUS)"
  if [ ! -d "$app" ]; then
    ko "Installed application missing now: $app (moved or deleted after the installation)"
    res "$A_INSTALL" "$ST" "$D" "$app"; return 0
  fi
  sv="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null)"
  iv="$(version_normalize "$sv")"; ib="$(version_build "$sv")"
  if version_equal "$iv" "$VERSION" && [ "$ib" = "$BUILD" ]; then add "Installed version checked now: $sv"
  else ko "Installed application is now $sv, expected $VERSION build $BUILD"; fi
  if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then add "codesign --verify --deep --strict: OK"
  else ko "codesign --verify --deep --strict failed: the installed application was modified after the installation"; fi
  cd="$(xc_cdhash "$app")"
  [ "$cd" = "$(xc_state "$f" INSTALLED_CDHASH)" ] || ko "CDHash $cd differs from the one recorded at installation ($(xc_state "$f" INSTALLED_CDHASH))"
  add "Quarantine attribute at installation: $(xc_state "$f" QUARANTINE_AT_INSTALL), now: $(xattr -p com.apple.quarantine "$app" 2>/dev/null || echo none)"
  [ "$ST" = ok ] && INST_APP="$app"
  res "$A_INSTALL" "$ST" "$D" "$app"
}

# ---------- what may let macOS skip an online check (reported, never hidden) ----------
xc_cache_notes() { # app
  local app="$1" q fl cd
  q="$(xattr -p com.apple.quarantine "$app" 2>/dev/null)"
  if [ -z "$q" ]; then
    echo "the application has no quarantine attribute: Gatekeeper does not evaluate it at launch, so this launch proves that 4D starts offline, not that the stapled ticket is used"
  else
    fl="${q%%;*}"
    if printf '%s' "$fl" | grep -qE '^[0-9a-fA-F]+$' && [ $(( 0x$fl & 0x40 )) -ne 0 ]; then
      echo "quarantine flags $fl: macOS already recorded a user approval of this application (earlier first launch), Gatekeeper may not check its notarisation again"
    fi
  fi
  cd="$(xc_cdhash "$app")"
  if [ -n "$cd" ] && [ -f "$BASE/assessed_$cd" ]; then
    echo "the same code (CDHash $cd) was launched with Internet by this tool on $(cat "$BASE/assessed_$cd"): macOS may reuse a cached notarisation result"
  fi
  echo "the disk image was opened on this Mac before the test (installation): if it carries a stapled ticket, macOS may have registered it"
}

xc_launch_result() { # label
  local l="$1"
  case "$LC_STATE" in
    READY) add "$l: 4D started - $LC_REASON";;
    CRASH) ko "$l: crash - $LC_REASON";;
    EXIT) ko "$l: 4D ended without starting - $LC_REASON";;
    HANG) ko "$l: blocked, no proof of start within the time limit - $LC_REASON";;
    BLOCKED) ko "$l: refused by macOS - $LC_REASON";;
    DIALOG)
      if printf '%s' "$LC_REASON $LC_GK" | grep -qiE "$XC_BLOCK_RE"; then ko "$l: a macOS dialog prevented the start - $LC_REASON"
      elif [ "${XC_AX:-0}" != 1 ]; then need_action "$l: a dialog prevents the start and cannot be read or answered automatically (Accessibility not granted to Test Installer 4D): answer it or grant Accessibility, then run the test again - $LC_REASON"
      else ko "$l: a dialog prevented the start - $LC_REASON"; fi;;
    BENCH) undetermined "$l: test bench error, 4D not evaluated - $LC_REASON";;
    *) undetermined "$l: no usable proof of start (${LC_STATE:-no state}) - $LC_REASON";;
  esac
  [ -n "$LC_GK" ] && add "  $LC_GK"
  [ -n "$LC_CRASH_AFTER" ] && warn "  crash report written after the proof of start, check it: $LC_CRASH_AFTER"
  return 0
}

NET_BACK_WAIT="${NET_BACK_WAIT:-90}"
xc_restore_network() {
  local rel i=0
  case "$OFF" in
    auto)
      if guard_open; then rel="$GUARD_DETAIL"
      elif ! guard_running && ! guard_stale; then rel="network guard stopped: $GUARD_DETAIL"
      else ko "Network possibly still blocked after the offline test ($GUARD_DETAIL): quit Test Installer 4D (its guard then removes the rules) or restart the Mac"; return 0; fi
      until online || [ "$i" -ge "$NET_BACK_WAIT" ]; do sleep 1; i=$((i+1)); done
      if online; then add "Network restored automatically ($rel); Internet reachable again"
      else add "Network restored automatically ($rel) but Internet not reachable yet after ${NET_BACK_WAIT}s: check the connection"; fi;;
    manual) ask "Turn the network back ON then press Enter:" >/dev/null; add "User asked to turn the network back on";;
  esac
  return 0
}
# automatic cut: the pf guard started for this run (app, .command) or, for a direct run of qa_mac.sh, now
xc_guard_ready() {
  local rc=0
  XC_GUARD_NOTE=""
  guard_running && return 0
  if [ "${NET_SESSION:-0}" = 1 ]; then
    XC_GUARD_NOTE="${NET_GUARD_NOTE:-the network guard started for this run is no longer running (${GUARD_DETAIL:-no state})}"; return 1
  fi
  guard_start "$$" || rc=$?
  if [ "$rc" = 0 ]; then QA_GUARD_OWNED=1; return 0; fi
  XC_GUARD_NOTE="automatic cut unavailable: $GUARD_DETAIL"; return 1
}

# ---------- launch WITHOUT Internet of the installed application ----------
xc_offline() { # installed app
  local app="$1" E notes rc1 how="" a i ok_off l fail=""
  begin
  OFF=""; OFF_DECLINED=0; OFF_FAILED=0
  if [ -z "$app" ] || [ ! -d "$app" ]; then
    notrun "WITHOUT Internet: not executed - no verified installation of the selected 4D (see '$A_INSTALL'): the offline test launches the installed application only"
    res "$A_EXEC_OFF" "$ST" "$D" "$app"; return 0
  fi
  add "Tested application: $app"
  # everything needed is prepared before the network is cut
  E="$(newproj QA_Exec QA_Exec_offline)"
  if [ ! -f "$E/Project/QA_Exec_offline.4DProject" ]; then
    undetermined "test bench: test project not prepared ($E)"; res "$A_EXEC_OFF" "$ST" "$D" "$app"; return 0
  fi
  notes="$(xc_cache_notes "$app")"
  XC_AX=0; xc_ax && XC_AX=1
  if offline_proof; then OFF=already; how="Mac already without Internet"
  elif [ "${NET_AUTO:-0}" = 1 ] && xc_guard_ready; then
    echo "   offline test: network blocked by the pf firewall (authorized at the start of the run)"
    if guard_block "$((OFF_TIMEOUT + 120))"; then OFF=auto; how="$GUARD_DETAIL; authorized explicitly at the start of the run"
    else
      fail="$GUARD_DETAIL"; OFF=auto; xc_restore_network; OFF=""; OFF_FAILED=1
    fi
  else
    [ "${NET_AUTO:-0}" = 1 ] && add "Automatic cut not used: $XC_GUARD_NOTE; manual cut requested"
    if confirm_offline; then
      a="$(ask "OFFLINE test: turn Wi-Fi/network OFF then press Enter (or type s to skip):")"
      case "$a" in s|S) OFF_DECLINED=1;; *) OFF=manual; how="network cut manually by the user";; esac
    else OFF_DECLINED=1; fi
  fi
  if [ "$OFF_DECLINED" = 1 ]; then
    notrun "WITHOUT Internet: not executed (permission declined, unanswered or skipped); the network was not modified, no offline success is claimed"
    res "$A_EXEC_OFF" "$ST" "$D" "$app"; return 0
  fi
  if [ "$OFF_FAILED" = 1 ]; then
    need_action "WITHOUT Internet: not executed - the automatic cut (pf firewall) failed: $fail. Cut the network manually (Wi-Fi off, cable unplugged, VPN disconnected) or run the test again"
    res "$A_EXEC_OFF" "$ST" "$D" "$app"; return 0
  fi
  # absence of Internet: several independent probes (HTTPS by name, TCP by IP address, DNS, default route)
  if [ "$OFF" != already ]; then
    ok_off=0; i=0
    while [ $i -lt 4 ]; do offline_proof && { ok_off=1; break; }; i=$((i+1)); [ $i -lt 4 ] && sleep "${OFF_SETTLE:-5}"; done
    if [ $ok_off = 0 ] && [ "$OFF" = manual ]; then
      a="$(ask "Internet is still reachable. Turn Wi-Fi OFF, unplug the network cable, disconnect any VPN, then press Enter (or type s to skip):")"
      case "$a" in s|S) ;; *) offline_proof && ok_off=1;; esac
    fi
    if [ $ok_off = 0 ]; then
      need_action "WITHOUT Internet: not executed - Internet is still reachable after the cut ($how): $NET_PROOF"
      xc_restore_network; res "$A_EXEC_OFF" "$ST" "$D" "$app"; return 0
    fi
  fi
  add "Absence of Internet verified before the launch ($how): $NET_PROOF"
  # launch of exactly the installed application, proof = result file written by the QA_Exec project
  lc_launch "$app" "$E" "$OFF_TIMEOUT" open "$app"
  rc1=0; offline_proof || rc1=$?
  if [ "$rc1" = 0 ]; then add "Absence of Internet verified after the launch: $NET_PROOF"
  else undetermined "Internet became reachable during the test, the launch cannot be attributed to an offline start: $NET_PROOF"; fi
  xc_launch_result "WITHOUT Internet"
  xc_restore_network
  while IFS= read -r l; do [ -n "$l" ] && add "Possible cache effect: $l"; done <<< "$notes"
  res "$A_EXEC_OFF" "$ST" "$D" "$app"
}

# ---------- notarisation ticket stapled (static check, never a proof of an offline launch) ----------
xc_staple() {
  local how a d ra rd ia ri
  begin
  if clt stapler; then
    how="xcrun stapler validate"
    a="$(xcrun stapler validate "$SRCAPP" 2>&1)"; ra=$?
    d="$(xcrun stapler validate "$DMG" 2>&1)"; rd=$?
    if [ -n "${INST_APP:-}" ]; then ia="$(xcrun stapler validate "$INST_APP" 2>&1)"; ri=$?; fi
  else
    how="codesign -dvvv (Notarization Ticket=stapled; no Command Line Tools for stapler)"
    a="$(codesign -dvvv "$SRCAPP" 2>&1)"; grep -q '^Notarization Ticket=stapled' <<< "$a"; ra=$?
    d="$(codesign -dvvv "$DMG" 2>&1)"; grep -q '^Notarization Ticket=stapled' <<< "$d"; rd=$?
    if [ -n "${INST_APP:-}" ]; then ia="$(codesign -dvvv "$INST_APP" 2>&1)"; grep -q '^Notarization Ticket=stapled' <<< "$ia"; ri=$?; fi
  fi
  [ "$ra" = 0 ] && add "$how $APPNAME (disk image): ticket stapled to the application"
  [ "$rd" = 0 ] && add "$how $(basename "$DMG"): ticket stapled to the disk image"
  if [ "$ra" != 0 ] && [ "$rd" != 0 ]; then
    ko "No valid stapled notarisation ticket on the application nor on the disk image ($how): $(printf '%s' "$a" | tail -1) / $(printf '%s' "$d" | tail -1)"
  elif [ "$ra" != 0 ]; then
    add "The application itself is not stapled: without Internet macOS relies on the ticket of the disk image ($(printf '%s' "$a" | tail -1))"
  fi
  if [ -n "${INST_APP:-}" ]; then
    if [ "$ri" = 0 ]; then add "$how installed application: ticket present ($INST_APP)"
    elif [ "$ra" = 0 ]; then ko "Installed application: stapled ticket missing although present in the disk image ($INST_APP)"; fi
  fi
  add "A stapled ticket does not prove that 4D starts without Internet: see '$A_EXEC_OFF'"
  res "$A_STAPLE" "$ST" "$D" "${INST_APP:-$SRCAPP}"
}

# ---------- launch WITH Internet of a fresh quarantined copy (Gatekeeper first launch, notarisation online) ----------
xc_online() {
  local S E cd
  begin
  # Internet first: without it spctl cannot check the notarisation online (a refusal would not be meaningful)
  if ! online; then
    notrun "WITH Internet: not executed - no Internet access now (HTTPS www.apple.com and TCP 1.1.1.1:443 unreachable); Gatekeeper assessment and launch skipped"
    res "$A_EXEC_ON" "$ST" "$D" "$PAPP"; return 0
  fi
  S="$(spctl -a -vv -t exec "$SRCAPP" 2>&1 | tr '\n' ' ')"
  case "$S" in *accepted*Notarized*) add "spctl (Gatekeeper assessment of $APPNAME in the disk image): $S";; *) ko "spctl: $S";; esac
  fresh_pristine
  E="$(newproj QA_Exec QA_Exec_online)"
  add "Tested application: fresh copy of $APPNAME from the disk image with a quarantine attribute (as downloaded): $PAPP"
  XC_AX=0; xc_ax && XC_AX=1
  lc_launch "$PAPP" "$E" "$ON_TIMEOUT" open "$PAPP"
  xc_launch_result "WITH Internet"
  if [ "$LC_STATE" = READY ] && cd="$(xc_cdhash "$PAPP")" && [ -n "$cd" ]; then date '+%Y-%m-%d %H:%M:%S' > "$BASE/assessed_$cd"; fi
  res "$A_EXEC_ON" "$ST" "$D" "$PAPP"
}
