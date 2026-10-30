#!/bin/bash
# download_4d.sh tests: official HTTPS addresses only (checked at every redirect), sign-in left to the browser,
# complete and non-empty files only, browser-like metadata, detection of finished browser downloads.
# curl and df are mocks: no network access.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DL="$ROOT/macOS/download_4d.sh"
TMP="$(mktemp -d /tmp/ti4d_test_dl.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (download): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }

mkdir -p "$TMP/bin" "$TMP/src" "$TMP/out"
echo hello > "$TMP/src/f.txt"
hdiutil create -quiet -srcfolder "$TMP/src" -format UDZO -volname T "$TMP/real.dmg" || { echo "cannot create test image" >&2; exit 1; }
head -c 4000 /dev/urandom > "$TMP/random.bin"; : > "$TMP/empty.bin"
printf '<html><body>Sign in</body></html>' > "$TMP/login.html"
# curl mock: answers from $TMP/routes: url|code|location|content-type|body|curl rc|content-length|content-disposition|delay
cat > "$TMP/bin/curl" <<'M'
#!/bin/bash
hdr=""; out=""; w=""; url=""
while [ $# -gt 0 ]; do case "$1" in -D) hdr="$2"; shift;; -o) out="$2"; shift;; -w) w="$2"; shift;;
  --proto|--connect-timeout|--speed-limit|--speed-time|-A|--max-redirs) shift;; -*) ;; *) url="$1";; esac; shift; done
echo "$url" >> "$TI4D_TMP/curl_calls"
line="$(awk -F'|' -v u="$url" '$1==u' "$TI4D_TMP/routes" | head -1)"
[ -n "$line" ] || { echo "curl: (6) Could not resolve host" >&2; exit 6; }
IFS='|' read -r _ code loc ctype body rc len cd delay <<< "$line"
{ printf 'HTTP/1.1 %s X\r\n' "$code"; [ -n "$loc" ] && printf 'Location: %s\r\n' "$loc"; [ -n "$ctype" ] && printf 'Content-Type: %s\r\n' "$ctype"
  [ -n "$len" ] && printf 'Content-Length: %s\r\n' "$len"; [ -n "$cd" ] && printf 'Content-Disposition: %s\r\n' "$cd"; printf '\r\n'; } > "$hdr"
[ -n "$delay" ] && sleep "$delay"
if [ -n "$body" ]; then cat "$body" > "$out"; else : > "$out"; fi
w="${w//'%{http_code}'/$code}"; w="${w//'%{redirect_url}'/$loc}"; w="${w//'%{content_type}'/$ctype}"; printf '%b' "$w"
exit "${rc:-0}"
M
cat > "$TMP/bin/df" <<'M'
#!/bin/bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 100000000 1 %s 1%% /\n' "${FAKE_DF_AVAIL:-50000000}"
M
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH" TI4D_TMP="$TMP"
SZ=$(stat -f%z "$TMP/real.dmg")
route() { echo "$*" >> "$TMP/routes"; }
run() { : > "$TMP/curl_calls"; rm -f "$TMP/out/"* "$TMP/out/".ti4d* 2>/dev/null; bash "$DL" --url "$1" --dir "$TMP/out" > "$TMP/o.txt" 2>&1; echo $? > "$TMP/rc"; }
err() { awk -F'\t' '$1=="ERROR"{print $2}' "$TMP/o.txt"; }
result() { awk -F'\t' '$1=="RESULT"{print $3}' "$TMP/o.txt"; }
info() { awk -F'\t' -v k="$1" '$1=="INFO" && $2==k{print $3}' "$TMP/o.txt"; }
nothing_left() { [ -z "$(ls -A "$TMP/out")" ]; }
rc() { cat "$TMP/rc"; }

# 1. direct link, official, complete
route "https://builds2.4d.com/a/4D.dmg|200||application/x-apple-diskimage|$TMP/real.dmg|0|$SZ|attachment; filename=\"4D 21.2 LTS Mac.dmg\"|"
run "https://builds2.4d.com/a/4D.dmg"
check test "$(rc)" = 0
check test "$(result)" = "$TMP/out/4D 21.2 LTS Mac.dmg"
check test -f "$TMP/out/4D 21.2 LTS Mac.dmg"
check test "$(info SHA256)" = "$(shasum -a 256 "$TMP/real.dmg" | awk '{print $1}')"
check test "$(info SIZE)" = "$SZ"
check test -n "$(xattr -p com.apple.quarantine "$TMP/out/4D 21.2 LTS Mac.dmg" 2>/dev/null)"
check test "$(ls -A "$TMP/out" | wc -l | tr -d ' ')" = 1 # no temporary file left
bash "$DL" --scan "$TMP/out" > "$TMP/scan.txt"; DL_STABLE_SECONDS=0
check grep -q "	official	builds2.4d.com	" "$TMP/scan.txt"
# a second download never overwrites the first file
cp "$TMP/out/4D 21.2 LTS Mac.dmg" "$TMP/keep.dmg"; : > "$TMP/curl_calls"
bash "$DL" --url "https://builds2.4d.com/a/4D.dmg" --dir "$TMP/out" > "$TMP/o.txt" 2>&1
check test "$(result)" = "$TMP/out/4D 21.2 LTS Mac 2.dmg"
check cmp -s "$TMP/out/4D 21.2 LTS Mac.dmg" "$TMP/keep.dmg"

# 2. redirects between official servers: every address checked, origin recorded
route "https://product-download.4d.com/dl?id=1|302|https://builds2.4d.com/b/4D_21.2.dmg?sig=x|text/html||0|||"
route "https://builds2.4d.com/b/4D_21.2.dmg?sig=x|200||application/octet-stream|$TMP/real.dmg|0|$SZ||"
run "https://product-download.4d.com/dl?id=1"
check test "$(rc)" = 0; check test "$(result)" = "$TMP/out/4D_21.2.dmg"
check test "$(info ORIGIN)" = builds2.4d.com
check test "$(grep -c . "$TMP/curl_calls")" = 2
bash "$DL" --scan "$TMP/out" > "$TMP/scan.txt"
check grep -q "	official	builds2.4d.com product-download.4d.com	" "$TMP/scan.txt"

# 3. redirect to another domain: refused before any request to it
route "https://product-download.4d.com/dl?id=2|302|https://cdn.example.net/4D.dmg|text/html||0|||"
route "https://cdn.example.net/4D.dmg|200||application/octet-stream|$TMP/real.dmg|0|$SZ||"
run "https://product-download.4d.com/dl?id=2"
check test "$(err)" = DOMAIN; check test "$(rc)" = 1; check nothing_left
check not grep -q example.net "$TMP/curl_calls"
route "https://product-download.4d.com/dl?id=3|302|http://builds2.4d.com/4D.dmg|text/html||0|||"
run "https://product-download.4d.com/dl?id=3"; check test "$(err)" = DOMAIN

# 4. addresses refused without any request
for u in "http://builds2.4d.com/4D.dmg" "https://builds2.4d.com.evil.net/4D.dmg" "https://evil4d.com/4D.dmg" \
         "https://user:pw@builds2.4d.com/4D.dmg" "https://builds2.4d.com:8443/4D.dmg" "ftp://builds2.4d.com/4D.dmg" \
         "https://4d.com@evil.net/4D.dmg" "https://builds2.4d.com..evil/4D.dmg"; do
  run "$u"; check test "$(err)" = DOMAIN; check test ! -s "$TMP/curl_calls"
done
route "https://4d.com:443/x.dmg|200||application/octet-stream|$TMP/real.dmg|0|$SZ||"
run "https://4d.com:443/x.dmg"; check test "$(rc)" = 0

# 5. sign-in required: left to the browser, nothing stored
route "https://product-download.4d.com/p1|401||text/html|$TMP/login.html|0|||"
run "https://product-download.4d.com/p1"; check test "$(err)" = AUTH; check nothing_left
check grep -q 'browser' "$TMP/o.txt"
route "https://product-download.4d.com/p2|200||text/html; charset=utf-8|$TMP/login.html|0|||"
run "https://product-download.4d.com/p2"; check test "$(err)" = AUTH; check nothing_left
route "https://product-download.4d.com/p3|403||text/html|$TMP/login.html|0|||"
run "https://product-download.4d.com/p3"; check test "$(err)" = AUTH
check not grep -qiE -- '(--user|--netrc|-u [^ ]*:|passw)' <(grep -v '^#' "$DL")

# 6. not found, server error, network
route "https://builds2.4d.com/missing.dmg|404||text/html|$TMP/login.html|0|||"
run "https://builds2.4d.com/missing.dmg"; check test "$(err)" = NOTFOUND
route "https://builds2.4d.com/err.dmg|500||text/plain||0|||"
run "https://builds2.4d.com/err.dmg"; check test "$(err)" = HTTP
run "https://unknown.4d.com/x.dmg"; check test "$(err)" = NETWORK; check nothing_left
route "https://builds2.4d.com/slow.dmg|200||application/octet-stream|$TMP/real.dmg|28|$SZ||"
run "https://builds2.4d.com/slow.dmg"; check test "$(err)" = NETWORK; check nothing_left

# 7. incomplete / empty / not a disk image
route "https://builds2.4d.com/cut.dmg|200||application/octet-stream|$TMP/real.dmg|18|$SZ||"
run "https://builds2.4d.com/cut.dmg"; check test "$(err)" = INCOMPLETE; check nothing_left
route "https://builds2.4d.com/short.dmg|200||application/octet-stream|$TMP/real.dmg|0|$((SZ+10))||"
run "https://builds2.4d.com/short.dmg"; check test "$(err)" = INCOMPLETE; check nothing_left
route "https://builds2.4d.com/empty.dmg|200||application/octet-stream|$TMP/empty.bin|0|0||"
run "https://builds2.4d.com/empty.dmg"; check test "$(err)" = EMPTY; check nothing_left
route "https://builds2.4d.com/rand.dmg|200||application/octet-stream|$TMP/random.bin|0|4000||"
run "https://builds2.4d.com/rand.dmg"; check test "$(err)" = FORMAT; check nothing_left
route "https://builds2.4d.com/file.zip|200||application/zip|$TMP/real.dmg|0|$SZ||"
run "https://builds2.4d.com/file.zip"; check test "$(err)" = FORMAT; check nothing_left
route "https://builds2.4d.com/nolen.dmg|200||application/octet-stream|$TMP/real.dmg|0|||"
run "https://builds2.4d.com/nolen.dmg"; check test "$(rc)" = 0; check grep -q 'no announced size' "$TMP/o.txt"

# 8. not enough space announced: stopped, nothing left
route "https://builds2.4d.com/big.dmg|200||application/octet-stream|$TMP/real.dmg|0|99999999999||3"
FAKE_DF_AVAIL=1000 run "https://builds2.4d.com/big.dmg"; check test "$(err)" = SPACE; check nothing_left
export FAKE_DF_AVAIL=1000; run "https://builds2.4d.com/big.dmg"; unset FAKE_DF_AVAIL
check test "$(err)" = SPACE
route "https://builds2.4d.com/p.dmg|200||application/octet-stream|$TMP/real.dmg|0|$SZ||3"
run "https://builds2.4d.com/p.dmg"; check grep -q '^PROGRESS	100	' "$TMP/o.txt"

# 9. destination not writable
mkdir "$TMP/ro"; chmod 555 "$TMP/ro"
bash "$DL" --url "https://builds2.4d.com/a/4D.dmg" --dir "$TMP/ro" > "$TMP/o.txt"; check test "$(err)" = WRITE; chmod 755 "$TMP/ro"

# 10. detection of browser downloads: complete, in progress (Safari, Chrome, Firefox), empty, origin
S="$TMP/dl"; mkdir "$S"
wf() { local f="$1" x; shift; x="$TMP/wf.plist"; printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array>' > "$x"
  for u in "$@"; do printf '<string>%s</string>' "$u" >> "$x"; done; printf '</array></plist>' >> "$x"
  plutil -convert binary1 "$x" && xattr -wx com.apple.metadata:kMDItemWhereFroms "$(xxd -p "$x" | tr -d '\n')" "$f"; }
cp "$TMP/real.dmg" "$S/4D 21.2.dmg"; wf "$S/4D 21.2.dmg" "https://builds2.4d.com/x.dmg?s=1" "https://product-download.4d.com/"
cp "$TMP/real.dmg" "$S/other.dmg"; wf "$S/other.dmg" "https://mirror.example.com/4D.dmg"
cp "$TMP/real.dmg" "$S/nometa.DMG"
: > "$S/firefox.dmg"; echo x > "$S/firefox.dmg.part"
cp "$TMP/real.dmg" "$S/chrome.dmg"; echo x > "$S/chrome.dmg.crdownload"
mkdir "$S/safari.dmg.download"; : > "$S/empty.dmg"; echo x > "$S/notes.txt"
touch -t 202001010000 "$S/"*
line() { awk -F'\t' -v f="$S/$1" '$2==f' "$TMP/scan.txt"; }
bash "$DL" --scan "$S" > "$TMP/scan.txt"
check grep -q "	complete	official	builds2.4d.com product-download.4d.com	" <<< "$(line "4D 21.2.dmg")"
check grep -q "	complete	other	mirror.example.com	" <<< "$(line other.dmg)"
check grep -q "	complete	unknown		" <<< "$(line nometa.DMG)"
check grep -q "	partial	" <<< "$(line firefox.dmg)"
check grep -q "	partial	" <<< "$(line chrome.dmg)"
check grep -q "	empty	" <<< "$(line empty.dmg)"
check test "$(grep -c '^CANDIDATE' "$TMP/scan.txt")" = 7 # no .txt; .part / .crdownload not listed twice
check grep -q "	partial	" <<< "$(line safari.dmg.download)"   # Safari bundle in progress, final file not there yet
check test -z "$(line firefox.dmg.part)"; check test -z "$(line chrome.dmg.crdownload)"
# in progress, not renamed yet: Chrome .crdownload, Safari bundle with its data inside (size of the data)
cp "$TMP/real.dmg" "$S/4D 21.3.dmg.crdownload"; mkdir "$S/4D 21.4.dmg.download"; head -c 5000 /dev/urandom > "$S/4D 21.4.dmg.download/4D 21.4.dmg"
# finished but not a complete UDIF image: truncated real image, random bytes
head -c $(( SZ / 2 )) "$TMP/real.dmg" > "$S/trunc.dmg"; head -c 4000 /dev/urandom > "$S/random.dmg"
touch -t 202001010000 "$S/4D 21.3.dmg.crdownload" "$S/4D 21.4.dmg.download/4D 21.4.dmg" "$S/trunc.dmg" "$S/random.dmg"
bash "$DL" --scan "$S" > "$TMP/scan.txt"
check grep -q "	$SZ	partial	" <<< "$(line "4D 21.3.dmg.crdownload")"
check grep -q "	5000	partial	" <<< "$(line "4D 21.4.dmg.download")"
check grep -q "	invalid	" <<< "$(line trunc.dmg)"
check grep -q "	invalid	" <<< "$(line random.dmg)"
check grep -q "	complete	" <<< "$(line "4D 21.2.dmg")"                  # real UDZO image: "koly" trailer present
check test "$(grep -c '	complete	' "$TMP/scan.txt")" = 3
mv "$S/4D 21.3.dmg.crdownload" "$S/4D 21.3.dmg"; touch -t 202001010000 "$S/4D 21.3.dmg" # renamed when finished
bash "$DL" --scan "$S" > "$TMP/scan.txt"
check grep -q "	complete	" <<< "$(line "4D 21.3.dmg")"; check test -z "$(line "4D 21.3.dmg.crdownload")"
rm -rf "$S/4D 21.3.dmg" "$S/4D 21.4.dmg.download" "$S/trunc.dmg" "$S/random.dmg"
touch "$S/4D 21.2.dmg"; bash "$DL" --scan "$S" > "$TMP/scan.txt" # still being written (modified just now)
check grep -q "	partial	" <<< "$(line "4D 21.2.dmg")"
bash "$DL" --scan "$S" --since "$(( $(date +%s) - 60 ))" > "$TMP/scan.txt"
check test "$(grep -c '^CANDIDATE' "$TMP/scan.txt")" = 1
bash "$DL" --scan "$TMP/none" > "$TMP/scan.txt"; check grep -q '^ERROR	ARGS' "$TMP/scan.txt"
# unreadable folder: an error, not an empty list
mkdir "$TMP/locked"; cp "$TMP/real.dmg" "$TMP/locked/x.dmg"; chmod 000 "$TMP/locked"
bash "$DL" --scan "$TMP/locked" > "$TMP/scan.txt"; check test $? = 1
check grep -q '^ERROR	ACCESS	' "$TMP/scan.txt"; check not grep -q '^CANDIDATE' "$TMP/scan.txt"
chmod 755 "$TMP/locked"
echo "download: $pass checks passed, $failn failed"
[ "$failn" = 0 ]
