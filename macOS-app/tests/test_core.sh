#!/bin/bash
# Core.swift unit tests (tests/test_core.swift) plus the Swift version rules checked against version.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_core.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
swiftc -parse-as-library -o "$TMP/core_tests" "$ROOT/macOS-app/Core.swift" "$ROOT/macOS-app/tests/test_core.swift" 2>"$TMP/build.log" \
  || { cat "$TMP/build.log" >&2; echo "core: build FAILED" >&2; exit 1; }
"$TMP/core_tests"; rc=$?
# the Swift normalisation must give the same result as version.sh (the engine and the app compare the same values)
. "$ROOT/macOS/version.sh"
cat > "$TMP/v.swift" <<'SW'
import Foundation
@main struct V { static func main() { for a in CommandLine.arguments.dropFirst() { print(Version.normalize(a)) } } }
SW
swiftc -parse-as-library -o "$TMP/v" "$ROOT/macOS-app/Core.swift" "$TMP/v.swift" 2>"$TMP/v.log" || { cat "$TMP/v.log" >&2; exit 1; }
n=0; f=0
for v in "21.2" " 21.2 " "21.0.2" "21.0.2 HF1" "21 R2" "21 R2 build 100629" "20.0.10.1" "20.0.10" "19.0.5 build 1"; do
  s="$("$TMP/v" "$v")"; b="$(version_normalize "$v")"
  n=$((n+1)); [ "$s" = "$b" ] || { f=$((f+1)); echo "FAILED (core): normalize '$v' swift='$s' bash='$b'" >&2; }
done
echo "core/version.sh: $((n-f)) checks passed, $f failed"
[ $rc = 0 ] && [ $f = 0 ]
