#!/bin/bash
# 4D's bundle spelling M.0.N and marketing spelling M.N are equivalent.
# Preserve all other components, release/hotfix suffixes and build checks.
version_normalize() {
  printf '%s\n' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/ [Bb]uild.*$//; s/^([0-9]+)\.0\.([0-9]+)([[:space:]].*|$)/\1.\2\3/'
}
version_equal() {
  [ -n "$1" ] && [ -n "$2" ] &&
    [ "$(version_normalize "$1")" = "$(version_normalize "$2")" ]
}
version_in_text() {
  local candidate
  while IFS= read -r candidate; do
    version_equal "$candidate" "$1" && return 0
  done < <(printf '%s\n' "$2" | grep -Eo '[0-9]+(\.[0-9]+)*([[:blank:]]*R[0-9]+)?([[:blank:]]*HF[0-9]+)?')
  return 1
}
# Build number of a CFBundleShortVersionString: "21.2 build 21.100624" -> 100624,
# "21 R5 build 21R5.100123" -> 100123, "21.2 build 100624" -> 100624.
version_build() {
  printf '%s' "$1" | sed -nE 's/.*[Bb]uild ([0-9]+[[:alnum:]]*\.)?([0-9]+).*/\2/p'
}
# Info.plist coherence: CFBundleShortVersionString (without its build) vs CFBundleVersion.
# Besides the M.0.N = M.N rule, an R release "M RN" is intentionally numbered exactly M.N.0 in
# CFBundleVersion ("21 R5" / "21.5.0"). Any other major, R number, third component, M.N alone
# or the LTS spelling M.0.N (21.0.5 is 21.5, not 21 R5) stays a mismatch.
bundle_version_matches() {
  local sv bv major r
  version_equal "$1" "$2" && return 0
  sv="$(version_normalize "$1")"; bv="$(printf '%s' "$2" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ "$sv" =~ ^([0-9]+)[[:blank:]]*R([0-9]+)$ ]] || return 1
  major=$((10#${BASH_REMATCH[1]})); r=$((10#${BASH_REMATCH[2]}))
  [[ "$bv" =~ ^([0-9]+)\.([0-9]+)\.0$ ]] || return 1
  [ $((10#${BASH_REMATCH[1]})) = "$major" ] && [ $((10#${BASH_REMATCH[2]})) = "$r" ]
}
