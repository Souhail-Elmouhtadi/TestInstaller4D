#!/bin/bash
# Result rows of the checklist (sourced by qa_mac.sh and by the tests).
# One row: <action> TAB <status> TAB <detail, \n escaped> TAB <date> TAB <tested path>
# Status: ok | ko | manual (to check by hand) | na (not applicable) | notrun (not executed) |
#         action (user action required) | undetermined (no usable proof). Only ok is a success.
NL=$'\n'
D=""; ST=ok
st_rank() { case "$1" in ko) echo 6;; action) echo 5;; undetermined) echo 4;; notrun) echo 3;; manual) echo 2;; *) echo 1;; esac; }
raise() { [ "$(st_rank "$1")" -gt "$(st_rank "$ST")" ] && ST="$1"; return 0; }
add() { if [ -n "$D" ]; then D="$D$NL$1"; else D="$1"; fi; }
begin() { D=""; ST=ok; }
ko() { raise ko; add "$1"; }
warn() { raise manual; add "$1"; }
notrun() { raise notrun; add "$1"; }
need_action() { raise action; add "$1"; }
undetermined() { raise undetermined; add "$1"; }
item_lines() { printf '%s\n' "$1" | tr -d '\r' | awk 'NF' | LC_ALL=C sort; }
item_names() { awk 'BEGIN{s=""} {printf "%s%s",s,$0; s=", "} END{if(s=="") printf "(none)"; printf "\n"}'; }
check_items() { # label, expected lines, observed lines, corrective action, [required: allow additional items]
  local label="$1" expected observed missing extra ne no LC_ALL=C
  export LC_ALL
  expected="$(item_lines "$2")"; observed="$(item_lines "$3")"
  ne="$(printf '%s\n' "$expected" | awk 'NF{n++} END{print n+0}')"
  no="$(printf '%s\n' "$observed" | awk 'NF{n++} END{print n+0}')"
  missing="$(comm -23 <(printf '%s\n' "$expected" | awk 'NF') <(printf '%s\n' "$observed" | awk 'NF'))"
  extra="$(comm -13 <(printf '%s\n' "$expected" | awk 'NF') <(printf '%s\n' "$observed" | awk 'NF'))"
  add "$label: expected $ne$([ "${5:-}" = required ] && printf ' required'), observed $no"
  if [ -n "$missing" ] || { [ "${5:-}" != required ] && [ -n "$extra" ]; }; then
    ko "Missing: $(printf '%s\n' "$missing" | awk 'NF' | item_names)"
    if [ "${5:-}" = required ]; then
      add "Additional (allowed): $(printf '%s\n' "$extra" | awk 'NF' | item_names)"
    else
      add "Unexpected: $(printf '%s\n' "$extra" | awk 'NF' | item_names)"
    fi
    add "Expected: $(printf '%s\n' "$expected" | awk 'NF' | item_names)"
    add "Observed: $(printf '%s\n' "$observed" | awk 'NF' | item_names)"
    add "Action: $4"
  else
    add "Observed: $(printf '%s\n' "$observed" | awk 'NF' | item_names)"
    [ "${5:-}" != required ] || [ -z "$extra" ] || add "Additional (allowed): $(printf '%s\n' "$extra" | awk 'NF' | item_names)"
  fi
  return 0
}
hdr() { printf '#%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" >> "$OUT"; }
res() { # action status detail [path]
  local d; d="$(printf '%s' "$3" | tr '\t' ' ' | awk 'BEGIN{ORS="\\n"}1' | sed 's/\\n$//')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$d" "$(date '+%Y-%m-%d %H:%M:%S')" "$(printf '%s' "${4:-${RES_PATH:-}}" | tr '\t\n' '  ')" >> "$OUT"
  echo "[$2] $1"; printf '%s\n' "$3" | sed 's/^/      /'
}
