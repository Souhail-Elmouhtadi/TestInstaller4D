#!/bin/bash
# Download of a 4D disk image, official 4D addresses only (*.4d.com, HTTPS).
# No credential is ever asked for, read or stored: when the server requires a sign-in (4D account), the user
# signs in and downloads in the browser; the tool then only detects the finished download (--scan).
# Usage:
#   download_4d.sh --url <https://...4d.com/...> --dir <folder>   direct link: the address is checked at every
#                                                                 redirect (no automatic redirect is followed)
#   download_4d.sh --scan <folder> [--since <epoch>]              disk images present in the folder
# Output (TAB separated):
#   STEP <text> | PROGRESS <pct> <bytes> <total> | INFO <key> <value> | ERROR <CODE> <text> | RESULT ok <path>
#   CANDIDATE <path> <size> <complete|partial|empty|invalid> <official|other|unknown> <origin hosts> <mtime>
#     complete: finished UDIF image ("koly" trailer) | partial: download in progress (browser temporary file,
#     .crdownload / .part / Safari .download bundle, or modified less than DL_STABLE_SECONDS ago) | empty: 0 byte |
#     invalid: no UDIF trailer (truncated file or unsupported format)
# Error codes: ARGS ACCESS DOMAIN AUTH NOTFOUND HTTP NETWORK INCOMPLETE EMPTY FORMAT SPACE WRITE
# Exit: 0 ok, 1 error
set -uo pipefail
LC_ALL=C; export LC_ALL
MAX_HOPS="${DL_MAX_HOPS:-8}"
CURL="${DL_CURL:-curl}"

ev() { local IFS=$'\t'; printf '%s\n' "$*"; }
host_of() { printf '%s' "$1" | sed -nE 's#^[A-Za-z]+://([^/:?@]*@)?([^/:?#]+).*#\2#p' | tr 'A-Z' 'a-z'; }
official_host() { case "$1" in 4d.com|*.4d.com) [[ "$1" =~ ^[a-z0-9.-]+$ ]] && [[ "$1" != *..* ]];; *) return 1;; esac; }
# https only, no user name/password in the address, default port, host *.4d.com
official_url() {
  local u="$1" auth
  [[ "$u" =~ ^https://[^/?#]+ ]] || return 1
  auth="${BASH_REMATCH[0]#https://}"
  case "$auth" in *@*) return 1;; *:443) auth="${auth%:443}";; *:*) return 1;; esac
  official_host "$(printf '%s' "$auth" | tr 'A-Z' 'a-z')"
}
wherefroms_hosts() { # file -> origin hosts recorded by the browser (kMDItemWhereFroms)
  xattr -px com.apple.metadata:kMDItemWhereFroms "$1" 2>/dev/null | xxd -r -p 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null \
    | sed -n 's:.*<string>\(.*\)</string>.*:\1:p' | while IFS= read -r u; do host_of "$u"; echo; done | grep . | sort -u | tr '\n' ' ' | sed 's/ $//'
}
origin_class() { # hosts -> official | other | unknown
  local h
  [ -z "$1" ] && { echo unknown; return; }
  for h in $1; do official_host "$h" || { echo other; return; }; done
  echo official
}

# UDIF disk image: "koly" trailer in the last 512 bytes, written last (a truncated or HTML file does not have it)
udif_trailer() { [ "$(tail -c 512 "$1" 2>/dev/null | head -c 4)" = koly ]; }

# ---------- disk images already downloaded (browser) ----------
scan() {
  local dir="$1" since="${2:-0}" f size state m now hosts inner
  now=$(date +%s)
  [ -d "$dir" ] || { ev ERROR ARGS "folder not found: $dir"; return 1; }
  # an unreadable folder (permissions, or macOS privacy protection) must not look like an empty one
  ls -A "$dir" >/dev/null 2>&1 || { ev ERROR ACCESS "folder not readable: $dir"; return 1; }
  find "$dir" -maxdepth 1 -type f -iname '*.dmg' -print 2>/dev/null | sort | while IFS= read -r f; do
    m=$(stat -f%m "$f" 2>/dev/null) || continue
    [ "$m" -ge "$since" ] || continue
    size=$(stat -f%z "$f")
    state=complete
    for x in download crdownload part partial; do [ -e "$f.$x" ] && state=partial; done
    [ $((now - m)) -lt "${DL_STABLE_SECONDS:-3}" ] && state=partial # still being written
    if [ "$state" = complete ]; then
      if [ "$size" = 0 ]; then state=empty; elif ! udif_trailer "$f"; then state=invalid; fi
    fi
    hosts="$(wherefroms_hosts "$f")"
    ev CANDIDATE "$f" "$size" "$state" "$(origin_class "$hosts")" "$hosts" "$m"
  done
  # downloads in progress not yet renamed: Chrome (.crdownload), Firefox (.part), Safari (.download bundle)
  find "$dir" -maxdepth 1 \( -iname '*.dmg.crdownload' -o -iname '*.dmg.part' -o -iname '*.dmg.partial' -o -iname '*.dmg.download' \) \
      -print 2>/dev/null | sort | while IFS= read -r f; do
    [ -e "${f%.*}" ] && continue # already listed (partial) under its final name
    m=$(stat -f%m "$f" 2>/dev/null) || continue
    size=0
    if [ -d "$f" ]; then
      inner="$(find "$f" -maxdepth 1 -type f -iname '*.dmg' -print 2>/dev/null | head -1)"
      [ -n "$inner" ] && { size=$(stat -f%z "$inner"); m=$(stat -f%m "$inner"); }
    else
      size=$(stat -f%z "$f")
    fi
    [ "$m" -ge "$since" ] || continue
    hosts="$(wherefroms_hosts "$f")"
    ev CANDIDATE "$f" "$size" partial "$(origin_class "$hosts")" "$hosts" "$m"
  done
}

# ---------- direct link ----------
TMPD=""; PART=""; CPID=""
cleanup() {
  [ -n "$CPID" ] && kill "$CPID" 2>/dev/null
  [ -n "$PART" ] && rm -f "$PART"
  [ -n "$TMPD" ] && rm -rf "$TMPD"
}
fail() { ev ERROR "$1" "$2"; cleanup; trap - EXIT; exit 1; }

header_value() { # header file, name -> value of the last response (case insensitive)
  awk -v n="$(printf '%s' "$2" | tr 'A-Z' 'a-z')" '/^HTTP\//{v=""} { l=tolower($0); if (index(l, n ":")==1) { v=substr($0, length(n)+2); sub(/^[ \t]+/, "", v); sub(/\r$/, "", v) } } END{print v}' "$1"
}
file_name() { # content-disposition, url -> safe file name
  local cd="$1" u="$2" n=""
  if [[ "$cd" =~ filename\*=[Uu][Tt][Ff]-8\'\'([^\;]+) ]]; then n="${BASH_REMATCH[1]}"
  elif [[ "$cd" =~ filename=\"([^\"]+)\" ]]; then n="${BASH_REMATCH[1]}"
  elif [[ "$cd" =~ filename=([^\;]+) ]]; then n="${BASH_REMATCH[1]}"; fi
  [ -z "$n" ] && { n="${u%%[?#]*}"; n="${n##*/}"; }
  n="$(printf '%b' "${n//%/\\x}")"   # percent-decoding
  n="${n##*/}"; n="$(printf '%s' "$n" | tr -d '\000-\037' | sed 's/^[. ]*//')"
  printf '%s' "$n"
}
unique_path() { # dir name -> path that does not exist yet ("name 2.dmg" like the Finder)
  local d="$1" n="$2" b e i=2
  [ -e "$d/$n" ] || { echo "$d/$n"; return; }
  b="${n%.*}"; e="${n##*.}"
  while [ -e "$d/$b $i.$e" ]; do i=$((i+1)); done
  echo "$d/$b $i.$e"
}

download() {
  local url="$1" dir="$2" u hop=0 code loc ctype cd len size rc name dest avail last=-1 pct sha qflags hdr w
  official_url "$url" || fail DOMAIN "refused: $url is not an HTTPS address of an official 4D server (*.4d.com)"
  [ -d "$dir" ] && [ -w "$dir" ] || fail WRITE "destination folder missing or not writable: $dir"
  TMPD="$(mktemp -d /tmp/ti4d_dl.XXXXXX)" || fail WRITE "no temporary folder"
  PART="$dir/.ti4d-download-$$.part"
  u="$url"
  while :; do
    official_url "$u" || fail DOMAIN "redirection to $u refused: not an HTTPS address of an official 4D server (*.4d.com)"
    ev STEP "Téléchargement depuis $(host_of "$u")"
    hdr="$TMPD/h$hop"; w="$TMPD/w$hop"; : > "$hdr"
    "$CURL" --proto =https --tlsv1.2 -sS --max-redirs 0 --connect-timeout 20 --speed-limit 1 --speed-time 120 \
      -A "Test Installer 4D" -D "$hdr" -o "$PART" -w '%{http_code}\n%{content_type}\n%{redirect_url}\n' "$u" > "$w" 2> "$TMPD/err" &
    CPID=$!
    while kill -0 "$CPID" 2>/dev/null; do
      sleep 1
      len="$(header_value "$hdr" content-length)"; size=$(stat -f%z "$PART" 2>/dev/null || echo 0)
      if [[ "$len" =~ ^[0-9]+$ ]] && [ "$len" -gt 0 ]; then
        if [ "$last" = -1 ]; then
          avail=$(( $(df -Pk "$dir" | awk 'NR==2{print $4}') * 1024 ))
          [ "$len" -gt "$avail" ] && { kill "$CPID" 2>/dev/null; fail SPACE "not enough space in $dir: $len bytes needed, $avail available"; }
        fi
        pct=$(( size * 100 / len )); [ "$pct" != "$last" ] && { ev PROGRESS "$pct" "$size" "$len"; last=$pct; }
      fi
    done
    wait "$CPID"; rc=$?; CPID=""
    { read -r code; read -r ctype; read -r loc; } < "$w" # one value per line: empty values kept
    case "$rc" in
      0) ;;
      1) fail DOMAIN "protocol refused (HTTPS only): $u";;
      18) fail INCOMPLETE "connection closed before the end of the file: $(head -c 200 "$TMPD/err")";;
      23) avail=$(( $(df -Pk "$dir" | awk 'NR==2{print $4}') * 1024 ))
          [ "$avail" -lt 1048576 ] && fail SPACE "disk full while writing in $dir"
          fail WRITE "cannot write in $dir: $(head -c 200 "$TMPD/err")";;
      28) fail NETWORK "download stalled or timed out: $(head -c 200 "$TMPD/err")";;
      47) ;; # too many redirects: handled below (max-redirs 0)
      *) fail NETWORK "network error (curl $rc): $(head -c 200 "$TMPD/err")";;
    esac
    case "$code" in
      301|302|303|307|308)
        [ -n "$loc" ] || fail HTTP "redirection without address (HTTP $code)"
        hop=$((hop+1)); [ $hop -le "$MAX_HOPS" ] || fail HTTP "too many redirections"
        u="$loc"; continue;;
      200) break;;
      401|403) fail AUTH "the server requires a sign-in (HTTP $code): sign in to product-download.4d.com in the browser and download the file there; the tool detects the finished download";;
      404|410) fail NOTFOUND "file not found on the server (HTTP $code): $u";;
      *) fail HTTP "unexpected answer of the server: HTTP ${code:-none}";;
    esac
  done
  case "$(printf '%s' "$ctype" | tr 'A-Z' 'a-z')" in
    text/html*) fail AUTH "the server returned a web page instead of the file (sign-in page?): sign in and download in the browser; the tool detects the finished download";;
  esac
  size=$(stat -f%z "$PART" 2>/dev/null || echo 0)
  [ "$size" -gt 0 ] || fail EMPTY "empty file received (0 byte)"
  len="$(header_value "$hdr" content-length)"
  if [[ "$len" =~ ^[0-9]+$ ]]; then [ "$size" = "$len" ] || fail INCOMPLETE "incomplete file: $size bytes received, $len announced"
  else ev INFO NOTE "no announced size (Content-Length): completeness checked by the disk image format only"; fi
  name="$(file_name "$(header_value "$hdr" content-disposition)" "$u")"
  case "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" in *.dmg) ;; *) fail FORMAT "the file received ('$name') is not a disk image (.dmg)";; esac
  udif_trailer "$PART" || fail FORMAT "the file received is not a complete disk image (no UDIF trailer)"
  dest="$(unique_path "$dir" "$name")"
  mv -n "$PART" "$dest" && [ -f "$dest" ] && [ ! -e "$PART" ] || fail WRITE "cannot rename the downloaded file to $dest"
  PART=""
  # same metadata as a browser download: origin (checked by install_4d.sh) and quarantine (checked by Gatekeeper)
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><string>%s</string><string>%s</string></array></plist>' \
    "$(printf '%s' "$u" | sed 's/&/\&amp;/g; s/</\&lt;/g')" "$(printf '%s' "$url" | sed 's/&/\&amp;/g; s/</\&lt;/g')" > "$TMPD/wf.plist"
  plutil -convert binary1 "$TMPD/wf.plist" && xattr -wx com.apple.metadata:kMDItemWhereFroms "$(xxd -p "$TMPD/wf.plist" | tr -d '\n')" "$dest"
  qflags="0081;$(printf '%x' "$(date +%s)");Test Installer 4D;$(uuidgen)"
  xattr -w com.apple.quarantine "$qflags" "$dest"
  sha="$(shasum -a 256 "$dest" | awk '{print $1}')"
  ev INFO PATH "$dest"; ev INFO SIZE "$size"; ev INFO SHA256 "$sha"; ev INFO ORIGIN "$(host_of "$u")"
  rm -rf "$TMPD"; TMPD=""
  ev RESULT ok "$dest"
}

MODE=""; URL=""; DIR=""; SINCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --url) MODE=url; URL="${2:-}"; shift;;
    --dir) DIR="${2:-}"; shift;;
    --scan) MODE=scan; DIR="${2:-}"; shift;;
    --since) SINCE="${2:-0}"; shift;;
    *) ev ERROR ARGS "unknown argument: $1"; exit 1;;
  esac
  shift
done
case "$MODE" in
  scan) scan "$DIR" "$SINCE";;
  url) trap cleanup EXIT; trap 'fail NETWORK "download cancelled"' TERM INT HUP
       [ -n "$URL" ] && [ -n "$DIR" ] || { ev ERROR ARGS "usage: --url <address> --dir <folder>"; exit 1; }
       download "$URL" "$DIR";;
  *) ev ERROR ARGS "usage: --url <address> --dir <folder> | --scan <folder> [--since <epoch>]"; exit 1;;
esac
