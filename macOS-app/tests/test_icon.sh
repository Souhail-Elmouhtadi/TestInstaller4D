#!/bin/bash
# Tests of the application icon: AppIcon.icns is up to date with its vector source (AppIconArt.swift), has the 10
# sizes of a macOS iconset, uses the brand gradient, and the header draws the same source (still with Reduce Motion).
# Dock icon set once at launch from the bundle (behaviour: tests/test_runner.swift), Desktop alias made by install.sh
# (in a temporary home: the real Desktop is untouched), temporary build unregistered from LaunchServices.
set -uo pipefail
APP="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/ti4d_test_icon.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
pass=0; failn=0
ok() { pass=$((pass+1)); }
bad() { echo "FAILED (icon): $* [line ${BASH_LINENO[1]}]" >&2; failn=$((failn+1)); }
check() { if "$@"; then ok; else bad "$*"; fi; }
not() { ! "$@"; }
has() { grep -qF -- "$2" <<< "$1"; }

# ---- the committed icon is the output of make_icon.sh (rendering and iconutil are deterministic) ----
check bash "$APP/icon/make_icon.sh" "$TMP/AppIcon.icns" > /dev/null
check cmp -s "$TMP/AppIcon.icns" "$APP/AppIcon.icns"
check test -s "$APP/icon/AppIcon_1024.png"

# ---- 10 sizes, exact pixel dimensions ----
iconutil -c iconset -o "$TMP/set.iconset" "$APP/AppIcon.icns"
for pt in 16 32 128 256 512; do
  for sc in 1 2; do
    f="$TMP/set.iconset/icon_${pt}x${pt}.png"; [ "$sc" = 2 ] && f="$TMP/set.iconset/icon_${pt}x${pt}@2x.png"
    px=$((pt * sc))
    dims="$(sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')"
    check test "$dims" = "$px $px "
  done
done
check test "$(ls "$TMP/set.iconset" | wc -l | tr -d ' ')" = 10

# ---- pixels: transparent corners, opaque body, gradient from indigo (top left) to orange (bottom right) ----
cat > "$TMP/main.swift" <<'EOF'
import AppKit
func rgba(_ img: CGImage, _ x: Int, _ y: Int) -> [Int] {
    let c = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    let p = c.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<4).map { Int(p[$0]) }
}
let a = CommandLine.arguments
if a[1] == "pose" { // launch(0) = empty box, launch(1) = rest pose (same drawing as AppIcon.icns)
    let s = AppIconArt.Pose.launch(0), e = AppIconArt.Pose.launch(1), m = AppIconArt.Pose.launch(0.2)
    print(s.badge == 0 && s.sparkle == 0 && s.arrow > 0.5 ? "start-ok" : "start-bad")
    print(e == AppIconArt.Pose.rest ? "end-ok" : "end-bad")
    print(m.arrow < s.arrow && m.arrow > 0 && m.badge == 0 ? "mid-ok" : "mid-bad") // falling, check not shown yet
    exit(0)
}
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
for pt in a.dropFirst(2) {
    let xy = pt.split(separator: ",").map { Int($0)! }
    print(rgba(img, xy[0], xy[1]).map(String.init).joined(separator: " "))
}
EOF
if swiftc -o "$TMP/probe" "$APP/Core.swift" "$APP/AppIconArt.swift" "$TMP/main.swift" 2> "$TMP/probe.err"; then
  ok
  big="$TMP/set.iconset/icon_512x512@2x.png"; small="$TMP/set.iconset/icon_16x16.png"
  out="$("$TMP/probe" "$big" 4,4 1019,1019 512,512 200,240 880,600)"
  corner="$(sed -n 1p <<< "$out")"; corner2="$(sed -n 2p <<< "$out")"; center="$(sed -n 3p <<< "$out")"
  check test "$(awk '{print $4}' <<< "$corner")" = 0
  check test "$(awk '{print $4}' <<< "$corner2")" = 0
  check test "$(awk '{print $4}' <<< "$center")" = 255
  tl="$(sed -n 4p <<< "$out")"; br="$(sed -n 5p <<< "$out")"
  check awk '{ exit !($3 > $1 && $4 == 255) }' <<< "$tl"   # indigo/violet: blue > red
  check awk '{ exit !($1 > $3 + 60 && $4 == 255) }' <<< "$br" # pink/orange: red well above blue
  out="$("$TMP/probe" "$small" 0,0 15,15 8,8)"
  check test "$(sed -n 1p <<< "$out" | awk '{print $4}')" = 0
  check test "$(sed -n 2p <<< "$out" | awk '{print $4}')" = 0
  check test "$(sed -n 3p <<< "$out" | awk '{print $4}')" = 255
  out="$("$TMP/probe" pose)"
  check has "$out" "start-ok"; check has "$out" "end-ok"; check has "$out" "mid-ok"
else
  bad "probe build: $(head -3 "$TMP/probe.err")"
fi

# ---- launch animation frames (make_icon --frames): the first differs from the last ----
swiftc -O -parse-as-library -o "$TMP/make_icon" "$APP/Core.swift" "$APP/AppIconArt.swift" "$APP/icon/make_icon.swift" 2> /dev/null
check "$TMP/make_icon" --frames "$TMP/frames" 64 5
check test "$(ls "$TMP/frames" | wc -l | tr -d ' ')" = 5
check not cmp -s "$TMP/frames/frame_000.png" "$TMP/frames/frame_004.png"
check not cmp -s "$TMP/frames/frame_002.png" "$TMP/frames/frame_004.png"

# ---- one vector source: brand palette, compiled into the app, drawn in the header ----
check grep -q 'Palette.gradient' "$APP/AppIconArt.swift"
check grep -q '"\$HERE/AppIconArt.swift"' "$APP/build_dmg.sh"
check grep -q 'CFBundleIconFile' "$APP/build_dmg.sh"
banner="$(sed -n '/^struct HeaderBanner/,/^}/p' "$APP/Theme.swift")"
check has "$banner" 'AppIconMark(busy: busy)'
check not has "$banner" 'Image(systemName: "shippingbox'
mark="$(sed -n '/^struct AppIconMark/,/^}/p' "$APP/Theme.swift")"
check has "$mark" 'if busy && !reduceMotion'                  # no floating arrow with Reduce Motion
check has "$mark" 'LaunchIcon(progress: reduceMotion ? 1 : launch.progress)' # final pose at once
check has "$mark" 'if reduceMotion { launch.progress = 1 }'   # no animated appearance
check has "$mark" '.accessibilityHidden(true)'                # decorative: the texts carry the state
check grep -q 'AppIconArt.draw(\$0, in: CGRect(origin: .zero, size: size), pose: pose)' "$APP/Theme.swift"

# ---- Dock: the running app shows its own AppIcon.icns, set once at launch (never animated) ----
delegate="$(sed -n '/^final class AppDelegate/,/^}/p' "$APP/TestInstaller4D.swift")"
check has "$delegate" 'func applicationDidFinishLaunching'
check has "$delegate" 'BundleIcon.applyToDock()'
check grep -q '@NSApplicationDelegateAdaptor(AppDelegate.self)' "$APP/TestInstaller4D.swift"
srcs=("$APP/Core.swift" "$APP/AppIconArt.swift" "$APP/Theme.swift" "$APP/Runner.swift" "$APP/TestInstaller4D.swift")
check test "$(cat "${srcs[@]}" | grep -c 'applicationIconImage *=')" = 1
check grep -q 'NSApp.applicationIconImage = img' "$APP/Runner.swift"
check grep -q 'trap .*"\$LSREGISTER" -u "\$APP" >/dev/null 2>&1 || true; rm -rf' "$APP/build_dmg.sh"

# ---- Desktop alias made by install.sh (temporary home, fake application) ----
INST="$APP/install.sh"
H2="$TMP/home"; mkdir -p "$H2/Desktop" "$TMP/Fake 4D.app/Contents"
LINK="$H2/Desktop/Test Installer 4D"
resolve() { osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(a) {
  const u = $.NSURL.URLByResolvingAliasFileAtURLOptionsError($.NSURL.fileURLWithPath(a[0]), 0, $());
  return (u && !u.isNil()) ? u.path.js : "UNRESOLVED"; }' "$1" 2>/dev/null; }
is_alias() { [ "$(osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(a) { const v = Ref();
  $.NSURL.fileURLWithPath(a[0]).getResourceValueForKeyError(v, $.NSURLIsAliasFileKey, $()); return (v[0] && v[0].boolValue) ? "1" : "0"; }' "$1" 2>/dev/null)" = 1 ]; }
out="$(HOME="$H2" bash "$INST" --desktop-alias "$TMP/Fake 4D.app")"; rc=$?
check test "$rc" = 0; check has "$out" "Alias sur le Bureau"
check test -f "$LINK"; check is_alias "$LINK"
REAL="$(cd "$TMP" && pwd -P)" # /tmp -> /private/tmp
check test "$(resolve "$LINK")" = "$REAL/Fake 4D.app"
mkdir -p "$TMP/Other.app/Contents"   # an existing alias is refreshed (new target), never duplicated
out="$(HOME="$H2" bash "$INST" --desktop-alias "$TMP/Other.app")"; rc=$?
check test "$rc" = 0; check test "$(resolve "$LINK")" = "$REAL/Other.app"
check test "$(ls "$H2/Desktop" | wc -l | tr -d ' ')" = 1
rm -f "$LINK"; echo "notes" > "$LINK"     # another item with that name is never replaced
out="$(HOME="$H2" bash "$INST" --desktop-alias "$TMP/Other.app")"; rc=$?
check test "$rc" = 2; check test "$(cat "$LINK")" = notes; check has "$out" "laissé tel quel"
rm -f "$LINK"; mkdir "$LINK"
out="$(HOME="$H2" bash "$INST" --desktop-alias "$TMP/Other.app")"; rc=$?
check test "$rc" = 2; check test -d "$LINK"
rmdir "$LINK"
out="$(HOME="$H2" bash "$INST" --desktop-alias "$TMP/Missing.app")"; rc=$?
check test "$rc" = 1; check not test -e "$LINK"
H3="$TMP/nodesk"; mkdir -p "$H3"
out="$(HOME="$H3" bash "$INST" --desktop-alias "$TMP/Other.app")"; rc=$?
check test "$rc" = 1; check not test -e "$H3/Desktop"
# a normal installation refreshes the alias of /Applications/Test Installer 4D.app, before opening the app
check grep -qx 'desktop_alias "\$DST"' "$INST"
check test "$(grep -n '^desktop_alias "\$DST"' "$INST" | cut -d: -f1)" -lt "$(grep -n '^open "\$DST"' "$INST" | cut -d: -f1)"
check not grep -qiE 'tell application "Finder"' "$INST"   # no Apple Event: no Automation permission needed

echo "icon: $pass checks, $failn failed"
[ "$failn" = 0 ]
