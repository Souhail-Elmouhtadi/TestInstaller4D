#!/bin/bash
# Runner.swift tests (tests/test_runner.swift) with a fake engine (dmg_info.sh, install_4d.sh, download_4d.sh) and a
# fake permission helper (about_check) in a temporary home: nothing real is installed, downloaded or asked to macOS.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_runner.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; KIT="$H/TestInstaller4D"; HP="$H/helpers"
mkdir -p "$KIT" "$HP" "$H/Downloads" "$H/4DQA_mac" "$H/Applications"

head -c 4096 /dev/urandom > "$H/Downloads/4D good.dmg"
head -c 100 /dev/urandom > "$H/Downloads/4D bad.dmg"
head -c 100 /dev/urandom > "$H/Downloads/4D other.dmg"
head -c 100 /dev/urandom > "$H/Downloads/4D 21.3 LTS Mac.dmg.download"
shasum -a 256 "$H/Downloads/4D good.dmg" | cut -d' ' -f1 | tr -d '\n' > "$H/good.sha"

cat > "$HP/about_check" <<'EOF'
#!/bin/bash
D="$(dirname "$0")"
echo "$*" >> "$D/started.log"
case "${1:-}" in --request-accessibility|--request-screen) echo "$1" >> "$D/requests.log";; esac
[ -f "$D/fail" ] && exit 4
P="$(cat "$D/perm")"
[ -f "$D/slow" ] && sleep 1
printf 'EXE\t%s\nPID\t%s\n%s\n' "$0" "$$" "$P"
EOF

cat > "$KIT/dmg_info.sh" <<'EOF'
#!/bin/bash
[ -f "$1" ] || exit 1
case "$(basename "$1")" in *bad*) echo "hdiutil: attach failed - image not recognized" >&2; exit 1;; esac
printf '4D\t21.2\t100629\tcom.4d.4d\t4D 21.2/4D.app\n'
printf '4D Server\t21.2\t100629\tcom.4d.4dserver\t4D 21.2/4D Server.app\n'
EOF

cat > "$KIT/install_4d.sh" <<'EOF'
#!/bin/bash
H="$(cd "$(dirname "$0")/.." && pwd)"
(IFS='|'; echo "$*") >> "$H/install_args.log"
MODE="$(cat "$H/install_mode" 2>/dev/null)"
CONFIRM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --replace|--adopt) CONFIRM="$1";;
    --dmg) DMG="$2"; shift;; --product) PRODUCT="$2"; shift;; --version) VERSION="$2"; shift;;
    --build) BUILD="$2"; shift;; --platform) PLATFORM="$2"; shift;; --dest) DEST="$2"; shift;; --state) STATE="$2"; shift;;
  esac; shift
done
echo "STEP	Vérification de l'image"
case "$MODE" in
  space) printf 'ERROR\tSPACE\t3 Go nécessaires, 1 Go libres\nRESULT\tko\t\n'; exit 1;;
  exists) if [ -z "$CONFIRM" ]; then
            printf 'EXISTS\t%s/4D 21.2/4D.app\t21.2\t100629\tsame\nERROR\tEXISTS\tconfirmation requise\n' "$DEST"; exit 3
          fi;;
  slow) trap 'printf "ERROR\tINTERRUPTED\tinterrompu\n"; exit 143' TERM
        printf 'PROGRESS\t10\tCopie\n'; for i in $(seq 1 200); do sleep 0.1; done; exit 0;;
esac
printf 'PROGRESS\t50\tCopie\nPROGRESS\t100\tVérification\n'
APP="$DEST/4D 21.2/4D.app"
printf 'STATUS\tok\nDATE\t%s\nPRODUCT\t%s\nVERSION\t%s\nBUILD\t%s\nPLATFORM\t%s\nDMG\t%s\nDEST\t%s\nAPP\t%s\n' \
  "$(date '+%F %T')" "$PRODUCT" "$VERSION" "$BUILD" "$PLATFORM" "$DMG" "$DEST" "$APP" > "$STATE"
printf 'RESULT\tok\t%s\n' "$APP"
EOF

cat > "$KIT/dmg_window.sh" <<'EOF'
#!/bin/bash
# fake presentation check: window_mode = ok (default) | pending | ko | action | nostate | stale
H="$(cd "$(dirname "$0")/.." && pwd)"
MODE="$(cat "$H/window_mode" 2>/dev/null || echo ok)"
echo "$*" >> "$H/window_args.log"
CONF=""
while [ $# -gt 0 ]; do
  case "$1" in --confirm) CONF="$2"; shift;; --dmg) DMG="$2"; shift;; --product) PRODUCT="$2"; shift;;
    --version) VERSION="$2"; shift;; --build) BUILD="$2"; shift;; --state) STATE="$2"; shift;; esac; shift
done
if [ -n "$CONF" ]; then
  grep -q $'^STATUS\tpending' "$STATE" || exit 1
  if [ "$CONF" = yes ]; then st=ok; v="confirmed by the user on the screenshot"; else st=ko; v="rejected by the user on the screenshot"; fi
  sed -i '' -e "s/^STATUS	pending/STATUS	$st/" "$STATE"; printf 'VERDICT\t%s\n' "$v" >> "$STATE"; exit 0
fi
rm -f "$STATE"; echo "STEP Ouverture de la fenêtre"
[ "$MODE" = nostate ] && exit 1
STAMP="$(stat -f '%z %m' "$DMG")"; ST="$MODE"
[ "$MODE" = stale ] && { STAMP="0 0"; ST=pending; }
case "$MODE" in ok|pending) D='[ok] title 4D 21.2 Release\n[ok] Applications shortcut';; ko) D='[ok] title\n[ko] Applications shortcut missing';;
  action) D='[ko] Finder automation not allowed (Automation > Finder)';; *) D='';; esac
printf 'STATUS\t%s\nDATE\tnow\nPRODUCT\t%s\nVERSION\t%s\nBUILD\t%s\nDMG\t%s\nSTAMP\t%s\nVOLUME\t4D 21.2 Release\nSHOT\t\nDETAIL\t%s\n' \
  "$ST" "$PRODUCT" "$VERSION" "$BUILD" "$DMG" "$STAMP" "$D" > "$STATE"
echo "RESULT $ST"
EOF

cat > "$KIT/download_4d.sh" <<'EOF'
#!/bin/bash
if [ "$1" = --scan ]; then
  H="$(cd "$(dirname "$0")/.." && pwd)"
  echo x >> "$H/scan_calls"
  [ -f "$H/scan_fail" ] && { printf 'ERROR\tACCESS\tfolder not readable: %s\n' "$2"; exit 1; }
  for f in "$2"/*.dmg "$2"/*.download "$2"/*.crdownload; do
    [ -e "$f" ] || continue
    case "$f" in *.download|*.crdownload) st=partial;; *trunc*) st=invalid;; *) st=complete;; esac
    [ "$st" = complete ] && [ ! -s "$f" ] && st=empty
    case "$f" in *mirror*) org=other; hosts=mirror.example.com;; *) org=official; hosts=product-download.4d.com;; esac
    printf 'CANDIDATE\t%s\t%s\t%s\t%s\t%s\t%s\n' "$f" "$(stat -f %z "$f")" "$st" "$org" "$hosts" "$(stat -f %m "$f")"
  done
  exit 0
fi
URL="$2"; DIR="$4"
echo "STEP	Téléchargement"
case "$URL" in
  */auth/*) printf 'ERROR\tAUTH\tle serveur demande une connexion (HTTP 401)\n'; exit 1;;
  */slow/*) trap 'printf "ERROR\tNETWORK\tcancelled\n"; exit 143' TERM
            printf 'PROGRESS\t5\t1000\t20000\n'; for i in $(seq 1 200); do sleep 0.1; done; exit 0;;
esac
printf 'PROGRESS\t100\t4096\t4096\nINFO\tPATH\t%s\nINFO\tSIZE\t4096\nINFO\tSHA256\tABC123\nRESULT\tok\t%s\n' "$DIR/4D good.dmg" "$DIR/4D good.dmg"
EOF
chmod +x "$HP/about_check" "$KIT"/*.sh
printf 'AX\t1\nSCREEN\t0\n' > "$HP/perm"

swiftc -parse-as-library -o "$TMP/runner_tests" "$ROOT/macOS-app/Core.swift" "$ROOT/macOS-app/Runner.swift" \
  "$ROOT/macOS-app/tests/test_runner.swift" 2>"$TMP/build.log" \
  || { cat "$TMP/build.log" >&2; echo "runner: build FAILED" >&2; exit 1; }
cp "$ROOT/macOS-app/AppIcon.icns" "$H/AppIcon.icns" # real application icon (Dock icon test)
"$TMP/runner_tests" "$H"
