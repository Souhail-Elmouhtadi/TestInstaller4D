#!/bin/bash
# Installation tests (install_4d.sh) on synthetic disk images: success and the main failures.
# Never writes outside a temporary folder: df, ditto, osascript and codesign --verify can be replaced by mocks;
# no administrator prompt is ever shown (osascript is always a mock here).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/macOS/install_4d.sh"
TMP="$(mktemp -d /tmp/ti4d_test_install.XXXXXX)"
pass=0; failn=0
finish() {
  chmod -R u+w "$TMP" 2>/dev/null
  # images of this test still attached (should not happen): detach them
  hdiutil info 2>/dev/null | awk -v t="$TMP" '$1=="image-path" && index($0,t){f=1} f && /^\/dev\/disk[0-9]+[[:space:]]/{print $1; f=0}' | while read -r d; do hdiutil detach "$d" -force >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap finish EXIT
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (install): $* [line ${BASH_LINENO[1]}]" >&2; [ -f "${OUT:-}" ] && tail -3 "$OUT" | sed "s/^/    /" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }

# ---------- mocks ----------
mkdir -p "$TMP/bin"
cat > "$TMP/bin/df" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_DF_AVAIL:-}" ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity iused ifree %%iused Mounted on\n/dev/fake 999999 1 %s 1%% 1 1 1%% /fake\n' "$FAKE_DF_AVAIL"
else exec /bin/df "$@"; fi
EOF
cat > "$TMP/bin/ditto" <<'EOF'
#!/bin/bash
if [ -n "${FAKE_DITTO_ERR:-}" ]; then echo "$FAKE_DITTO_ERR" >&2; exit 1; fi
exec /usr/bin/ditto "$@"
EOF
cat > "$TMP/bin/osascript" <<'EOF'
#!/bin/bash
echo "$*" >> "${OSA_LOG:-/dev/null}"
echo "${FAKE_OSA_ERR:-execution error: User canceled. (-128)}" >&2
exit "${FAKE_OSA_RC:-1}"
EOF
cat > "$TMP/bin/codesign" <<'EOF'
#!/bin/bash
if [ "${FAKE_CODESIGN_VERIFY_FAIL:-0}" = 1 ] && [ "$1" = --verify ]; then echo "a sealed resource is missing or invalid" >&2; exit 1; fi
exec /usr/bin/codesign "$@"
EOF
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" OSA_LOG="$TMP/osascript.log" INSTALL_SETTLE=0 EXPECTED_TEAM=none

# ---------- synthetic 4D disk images ----------
# fake_dmg <out.dmg> <version string> [arch: universal|x86_64] [product]
fake_dmg() {
  local out="$1" vs="$2" arch="${3:-universal}" prod="${4:-4D}" w root
  w="$(mktemp -d "$TMP/fx.XXXXXX")"; root="$w/root/4D 21.2"
  mkdir -p "$root/$prod.app/Contents/MacOS" "$root/Components/QA.4dbase/Contents" "$root/Components/Private.4dbase" "$root/.hidden"
  if [ "$arch" = universal ]; then cp /usr/bin/true "$root/$prod.app/Contents/MacOS/$prod"
  else lipo -thin "$arch" /usr/bin/true -output "$root/$prod.app/Contents/MacOS/$prod"; fi
  cat > "$root/$prod.app/Contents/Info.plist" <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$prod</string><key>CFBundleIdentifier</key><string>com.example.fake4d</string>
<key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$vs</string></dict></plist>
P
  echo comp > "$root/Components/QA.4dbase/Contents/a.txt"; echo x > "$root/Components/Private.4dbase/b.txt"
  chmod 750 "$root/Components/Private.4dbase"
  xattr -w com.example.meta keep "$root/Components/QA.4dbase/Contents/a.txt"
  /usr/bin/codesign -s - --force "$root/$prod.app" 2>/dev/null
  ln -s /Applications "$w/root/Applications"; echo readme > "$w/root/ReadMe.pdf"
  hdiutil create -quiet -srcfolder "$w/root" -volname "4D fake" -format UDZO "$out" 2>/dev/null
  rm -rf "$w"
}
fake_dmg "$TMP/good.dmg" "21.2 build 21.100629"
fake_dmg "$TMP/intel.dmg" "21.2 build 21.100629" x86_64
[ -s "$TMP/good.dmg" ] && [ -s "$TMP/intel.dmg" ] || { echo "FAILED (install): cannot build the synthetic disk images" >&2; exit 1; }

OUT="$TMP/out.txt"; RC=0
inst() { # dest state args...
  local dest="$1" state="$2"; shift 2
  RC=0; bash "$INSTALL" --product 4D --version 21.2 --build 100629 --platform "macOS ARM" --dest "$dest" --state "$state" "$@" > "$OUT" 2>&1 || RC=$?
}
inst_dmg() { local dmg="$1"; shift; inst "$@" --dmg "$dmg"; }
has() { grep -q "$1" "$OUT"; }
error_is() { grep -q "^ERROR	$1	" "$OUT"; }
state() { awk -F'\t' -v k="$2" '$1==k{print $2}' "$1"; }
attached() { hdiutil info > "$TMP/hinfo" 2>/dev/null; grep -qF "$1" "$TMP/hinfo"; }
not() { ! "$@"; }
no_leftover() { [ -z "$(find "$1" -name '.ti4d-*' 2>/dev/null)" ]; }

# 1. success: version/build/permissions/metadata/state, image detached
D1="$TMP/dest1"; mkdir "$D1"; S1="$TMP/state1.tsv"
inst_dmg "$TMP/good.dmg" "$D1" "$S1"
check test "$RC" = 0
check has "^RESULT	ok	$D1/4D 21.2/4D.app"
check test "$(state "$S1" STATUS)" = ok
check test "$(state "$S1" DMG_SHA256)" = "$(shasum -a 256 "$TMP/good.dmg" | awk '{print toupper($1)}')"
check test "$(state "$S1" DMG_SIZE)" = "$(stat -f%z "$TMP/good.dmg")"
check test "$(state "$S1" DMG)" = "$TMP/good.dmg"
check test "$(state "$S1" APP)" = "$D1/4D 21.2/4D.app"
check test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$D1/4D 21.2/4D.app/Contents/Info.plist")" = "21.2 build 21.100629"
check /usr/bin/codesign --verify --strict "$D1/4D 21.2/4D.app"
check test -f "$D1/4D 21.2/Components/QA.4dbase/Contents/a.txt"
check test "$(stat -f%Lp "$D1/4D 21.2/Components/Private.4dbase")" = 750
check test "$(xattr -p com.example.meta "$D1/4D 21.2/Components/QA.4dbase/Contents/a.txt")" = keep
check test ! -e "$D1/4D 21.2/.hidden"
check test ! -e "$D1/4D 21.2/Applications"
check not attached "$TMP/good.dmg"
check no_leftover "$D1"
check grep -q '^PROGRESS	100	' "$OUT"

# 2. existing installation: never overwritten without confirmation (exit 3)
touch -t 202001010000 "$D1/4D 21.2/4D.app/Contents/Info.plist"
inst_dmg "$TMP/good.dmg" "$D1" "$S1"
check test "$RC" = 3
check has "^EXISTS	$D1/4D 21.2	21.2	100629	same"
check test "$(state "$S1" ERROR_CODE)" = EXISTS
check test "$(stat -f%Sm -t %Y "$D1/4D 21.2/4D.app/Contents/Info.plist")" = 2020
check not attached "$TMP/good.dmg"

# 3. --adopt: the identical existing installation is verified and recorded, nothing copied
inst_dmg "$TMP/good.dmg" "$D1" "$S1" --adopt
check test "$RC" = 0
check test "$(state "$S1" STATUS)" = ok
check grep -q '^SOURCE	existing installation' "$S1"
check test "$(stat -f%Sm -t %Y "$D1/4D 21.2/4D.app/Contents/Info.plist")" = 2020

# 4. --replace (confirmed): the previous copy is kept aside (Trash disabled in tests)
echo old > "$D1/4D 21.2/Components/old_marker"
INSTALL_TRASH=0 inst_dmg "$TMP/good.dmg" "$D1" "$S1" --replace
check test "$RC" = 0
check test ! -e "$D1/4D 21.2/Components/old_marker"
check test -f "$D1/4D 21.2/"previous\ installation*/Components/old_marker
check grep -q '^PREVIOUS	previous installation kept' "$S1"
check no_leftover "$D1"
rm -rf "$D1/4D 21.2/"previous\ installation*

# 5. --replace but the new copy fails verification: previous installation restored
echo old > "$D1/4D 21.2/Components/old_marker"
FAKE_CODESIGN_VERIFY_FAIL=1 INSTALL_TRASH=0 inst_dmg "$TMP/good.dmg" "$D1" "$S1" --replace
check test "$RC" = 1
check error_is VERIFY
check test -f "$D1/4D 21.2/Components/old_marker"
check test -d "$D1/4D 21.2/4D.app"
check no_leftover "$D1"
check test "$(state "$S1" STATUS)" = ko
check not attached "$TMP/good.dmg"

# 6. wrong build / version: never another version, image detached, nothing created
D6="$TMP/dest6"; mkdir "$D6"
inst "$D6" "$TMP/s6" --dmg "$TMP/good.dmg" --build 100630
check test "$RC" = 1; check error_is VERSION; check test ! -e "$D6/4D 21.2"; check not attached "$TMP/good.dmg"
RC=0; bash "$INSTALL" --dmg "$TMP/good.dmg" --product 4D --version 21.3 --build 100629 --platform "macOS ARM" --dest "$D6" --state "$TMP/s6" > "$OUT" 2>&1 || RC=$?
check test "$RC" = 1; check error_is VERSION; check test ! -e "$D6/4D 21.2"
RC=0; bash "$INSTALL" --dmg "$TMP/good.dmg" --product 4D --version "" --build "" --dest "$D6" --state "$TMP/s6" > "$OUT" 2>&1 || RC=$?
check test "$RC" = 1; check error_is ARGS

# 7. incomplete downloads
: > "$TMP/empty.dmg"
inst_dmg "$TMP/empty.dmg" "$D6" "$TMP/s7"; check test "$RC" = 1; check error_is INCOMPLETE; check grep -q 'empty file' "$OUT"
check test "$(state "$TMP/s7" ERROR_CODE)" = INCOMPLETE
cp "$TMP/good.dmg" "$TMP/partial.dmg"; : > "$TMP/partial.dmg.download"
inst_dmg "$TMP/partial.dmg" "$D6" "$TMP/s7"; check test "$RC" = 1; check error_is INCOMPLETE; check grep -q 'still in progress' "$OUT"
cp "$TMP/good.dmg" "$TMP/x.dmg.crdownload"
inst_dmg "$TMP/x.dmg.crdownload" "$D6" "$TMP/s7"; check test "$RC" = 1; check error_is INCOMPLETE
inst_dmg "$TMP/missing.dmg" "$D6" "$TMP/s7"; check test "$RC" = 1; check error_is INCOMPLETE
# truncated image: integrity check fails before mounting
head -c $(( $(stat -f%z "$TMP/good.dmg") / 2 )) "$TMP/good.dmg" > "$TMP/truncated.dmg"
inst_dmg "$TMP/truncated.dmg" "$D6" "$TMP/s7"; check test "$RC" = 1; check error_is CORRUPT; check not attached "$TMP/truncated.dmg"
# not a disk image
head -c 100000 /dev/urandom > "$TMP/random.dmg"
inst_dmg "$TMP/random.dmg" "$D6" "$TMP/s7"; check test "$RC" = 1
check grep -qE '^ERROR	(CORRUPT|MOUNT)	' "$OUT"
check test ! -e "$D6/4D 21.2"

# 8. product / architecture / signature
RC=0; bash "$INSTALL" --dmg "$TMP/good.dmg" --product "4D Server" --version 21.2 --build 100629 --platform "macOS ARM" --dest "$D6" --state "$TMP/s8" > "$OUT" 2>&1 || RC=$?
check test "$RC" = 1; check error_is PRODUCT; check grep -q 'contains: 4D.app' "$OUT"; check not attached "$TMP/good.dmg"
inst_dmg "$TMP/intel.dmg" "$D6" "$TMP/s8"; check test "$RC" = 1; check error_is ARCH; check grep -q "contains \[x86_64\]" "$OUT"; check not attached "$TMP/intel.dmg"
RC=0; bash "$INSTALL" --dmg "$TMP/intel.dmg" --product 4D --version 21.2 --build 100629 --platform "macOS Intel" --dest "$TMP/dest8" --state "$TMP/s8" > "$OUT" 2>&1 || RC=$?
check test "$RC" = 0
EXPECTED_TEAM=37UG5W39Z2 inst_dmg "$TMP/good.dmg" "$D6" "$TMP/s8"; check test "$RC" = 1; check error_is SIGNATURE

# 9. origin of the download (browser metadata): only *.4d.com
wherefroms() { # file url...
  local f="$1" x; shift
  x="$TMP/wf.plist"; printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array>' > "$x"
  for u in "$@"; do printf '<string>%s</string>' "$u" >> "$x"; done; printf '</array></plist>' >> "$x"
  plutil -convert binary1 "$x" && xattr -wx com.apple.metadata:kMDItemWhereFroms "$(xxd -p "$x" | tr -d '\n')" "$f"
}
cp "$TMP/good.dmg" "$TMP/evil.dmg"; wherefroms "$TMP/evil.dmg" "https://download.example.com/4D.dmg" "https://product-download.4d.com/"
inst_dmg "$TMP/evil.dmg" "$D6" "$TMP/s9"; check test "$RC" = 1; check error_is ORIGIN
cp "$TMP/good.dmg" "$TMP/evil2.dmg"; wherefroms "$TMP/evil2.dmg" "https://builds2.4d.com.evil.net/4D.dmg"
inst_dmg "$TMP/evil2.dmg" "$D6" "$TMP/s9"; check test "$RC" = 1; check error_is ORIGIN
cp "$TMP/good.dmg" "$TMP/official.dmg"; wherefroms "$TMP/official.dmg" "https://builds2.4d.com/x/4D.dmg?sig=1" "https://product-download.4d.com/"
inst_dmg "$TMP/official.dmg" "$TMP/dest9" "$TMP/s9"; check test "$RC" = 0
check test "$(state "$TMP/s9" ORIGIN)" = "builds2.4d.com product-download.4d.com"

# 10. space, copy refused, copy failure
FAKE_DF_AVAIL=1000 inst_dmg "$TMP/good.dmg" "$D6" "$TMP/s10"; check test "$RC" = 1; check error_is SPACE; check test ! -e "$D6/4D 21.2"
FAKE_DITTO_ERR="ditto: /x: Operation not permitted" inst_dmg "$TMP/good.dmg" "$D6" "$TMP/s10"
check test "$RC" = 1; check error_is DENIED; check no_leftover "$D6"; check test ! -e "$D6/4D 21.2"; check not attached "$TMP/good.dmg"
FAKE_DITTO_ERR="ditto: /x: No space left on device" inst_dmg "$TMP/good.dmg" "$D6" "$TMP/s10"; check test "$RC" = 1; check error_is SPACE
FAKE_DITTO_ERR="ditto: /x: Input/output error" inst_dmg "$TMP/good.dmg" "$D6" "$TMP/s10"; check test "$RC" = 1; check error_is COPY; check no_leftover "$D6"

# 11. destination not writable: administrator rights requested from macOS (mock); cancel = nothing installed
D11="$TMP/dest11"; mkdir "$D11"; chmod 555 "$D11"; : > "$OSA_LOG"
inst_dmg "$TMP/good.dmg" "$D11" "$TMP/s11"
check test "$RC" = 1; check error_is ADMIN; check grep -q 'with administrator privileges' "$OSA_LOG"
check test ! -e "$D11/4D 21.2"; check not attached "$TMP/good.dmg"; check test -z "$(ls /tmp/ti4d_priv.* 2>/dev/null)"
chmod 755 "$D11"

# 12. image already mounted by the user: used as is and left mounted
UM="$(hdiutil attach -nobrowse -readonly -noautoopen "$TMP/good.dmg" 2>/dev/null | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
if [ -n "$UM" ]; then
  inst_dmg "$TMP/good.dmg" "$TMP/dest12" "$TMP/s12"
  check test "$RC" = 0
  check grep -q '^MOUNT	already mounted by the user' "$TMP/s12"
  check attached "$TMP/good.dmg"
  check test -d "$UM/4D 21.2/4D.app"
  hdiutil detach "$UM" >/dev/null 2>&1
else bad "could not mount the image as a user for case 12"; fi

check test -z "$(ls -d /tmp/ti4d_install.* 2>/dev/null)"
check test -z "$(ls /tmp/ti4d_ditto.* 2>/dev/null)"
echo "install: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
