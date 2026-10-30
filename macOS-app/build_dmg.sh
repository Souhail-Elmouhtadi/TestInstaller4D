#!/bin/bash
# Build "Test Installer 4D.app" (universal arm64 + x86_64) and TestInstaller4D.dmg.
# Usage: bash build_dmg.sh [output.dmg]   (default: ~/Downloads/TestInstaller4D.dmg)
#        APP_OUT=<folder> also keeps a copy of the built app there; SIGN_KEYCHAIN=<keychain> searches the
#        identity in that keychain.
# Signing identity (macOS ties the Accessibility / Screen Recording permissions to it):
#   SIGN_IDENTITY, else "Developer ID Application", else "Apple Development", else the local certificate
#   "TestInstaller4D Local Signing" (created once with make_signing_identity.sh), else ad hoc.
#   Ad hoc: the designated requirement is the code hash, so each build is a new app for System Settings
#   (permissions to grant again, duplicate entries): the script warns about it.
# Gatekeeper (first launch on another Mac):
# - with a "Developer ID Application" certificate, the app and the DMG are signed with it (hardened runtime, secure
#   timestamp); with a notarytool profile (NOTARY_PROFILE, default TestInstaller4D, created once:
#   xcrun notarytool store-credentials TestInstaller4D --apple-id <id> --team-id <team>) the DMG is notarized and
#   stapled: the app opens with a double-click, no right click > Open;
# - otherwise the DMG contains install.sh (installation without the Gatekeeper alert).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUT="${1:-$HOME/Downloads/TestInstaller4D.dmg}"
BUNDLE_ID="com.4d.qa.testinstaller4d"
NOTARY_PROFILE="${NOTARY_PROFILE:-TestInstaller4D}"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TMP="$(mktemp -d)"
STAGE="$TMP/stage"; APP="$STAGE/Test Installer 4D.app"
# the temporary copy must not stay registered in LaunchServices (same bundle identifier: the Dock or the Finder could
# show its icon instead of the installed app's)
trap '"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

SOURCES=("$HERE/Core.swift" "$HERE/AppIconArt.swift" "$HERE/Theme.swift" "$HERE/Runner.swift" "$HERE/TestInstaller4D.swift")
for a in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$a-apple-macos13.0" -o "$TMP/bin_$a" "${SOURCES[@]}"
  swiftc -O -target "$a-apple-macos13.0" -o "$TMP/rc_$a" "$HERE/readme_check.swift"
  swiftc -O -target "$a-apple-macos13.0" -o "$TMP/ac_$a" "$HERE/about_check.swift"
done
lipo -create "$TMP/bin_arm64" "$TMP/bin_x86_64" -output "$APP/Contents/MacOS/TestInstaller4D"
# helpers in Contents/Helpers (nested code signed with the app): the app starts them, so macOS checks the app's
# permissions for them; the app copies them into ~/TestInstaller4D for a run from Terminal
lipo -create "$TMP/rc_arm64" "$TMP/rc_x86_64" -output "$APP/Contents/Helpers/readme_check"
lipo -create "$TMP/ac_arm64" "$TMP/ac_x86_64" -output "$APP/Contents/Helpers/about_check"

ditto --norsrc "$ROOT/macOS" "$APP/Contents/Resources/kit"
rm -rf "$APP/Contents/Resources/kit/results" "$APP/Contents/Resources/kit/kit.conf" "$APP/Contents/Resources/kit/ic/"*.zip \
       "$APP/Contents/Resources/kit/readme_check" "$APP/Contents/Resources/kit/about_check"
find "$APP" -name .DS_Store -delete

# AppIcon.icns is generated from AppIconArt.swift by icon/make_icon.sh (the header draws the same source)
ICON=""
if [ -f "$HERE/AppIcon.icns" ] && cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"; then
  ICON="<key>CFBundleIconFile</key><string>AppIcon</string>"
fi
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>TestInstaller4D</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>Test Installer 4D</string>
<key>CFBundleDisplayName</key><string>Test Installer 4D</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>3.5.2</string>
<key>CFBundleVersion</key><string>14</string>
<key>CFBundleDevelopmentRegion</key><string>fr</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSAppleEventsUsageDescription</key><string>Afficher les questions de la checklist et contrôler, dans le Finder, la fenêtre de l’image disque de 4D avant installation.</string>
$ICON
</dict></plist>
EOF
plutil -lint -s "$APP/Contents/Info.plist"

# ---------- signing identity ----------
LOCAL_NAME="TestInstaller4D Local Signing"
KC=(); [ -n "${SIGN_KEYCHAIN:-}" ] && KC=(--keychain "$SIGN_KEYCHAIN")
identities() { security find-identity "$@" -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null; }
trusted_identity() { # $1 = name prefix; -v lists only the identities trusted for code signing
  identities -v | awk -F'"' -v p="$1" 'index($2, p) == 1 { print $2; exit }'
}
IDENTITY="${SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="$(trusted_identity "Developer ID Application:")"
[ -n "$IDENTITY" ] || IDENTITY="$(trusted_identity "Apple Development:")"
# self-signed, so not listed by -v: codesign accepts it and macOS ties the permissions to its certificate
[ -n "$IDENTITY" ] || ! identities | grep -qF "\"$LOCAL_NAME\"" || IDENTITY="$LOCAL_NAME"
case "$IDENTITY" in
  "Developer ID Application:"*) KIND=developer-id; TS=(--timestamp);;
  "") KIND=adhoc; TS=(); IDENTITY="-";;
  *) KIND=local; TS=(--timestamp=none);;
esac
echo "Signature : $KIND ($IDENTITY)"
# helpers first, then the app; no --deep: the 4D plugin of the kit keeps its own 4D signature
codesign --force --options runtime ${TS[@]+"${TS[@]}"} ${KC[@]+"${KC[@]}"} -s "$IDENTITY" \
  --identifier "$BUNDLE_ID.readme-check" "$APP/Contents/Helpers/readme_check"
codesign --force --options runtime ${TS[@]+"${TS[@]}"} ${KC[@]+"${KC[@]}"} -s "$IDENTITY" \
  --identifier "$BUNDLE_ID.about-check" "$APP/Contents/Helpers/about_check"
codesign --force --options runtime ${TS[@]+"${TS[@]}"} ${KC[@]+"${KC[@]}"} -s "$IDENTITY" \
  --entitlements "$HERE/TestInstaller4D.entitlements" "$APP"
codesign --verify --strict --deep "$APP"
REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^[# ]*designated => //p')"
echo "Designated requirement: $REQ"
if [ "$KIND" = adhoc ]; then
  echo "WARNING: ad-hoc signature: macOS identifies this build by its code hash." >&2
  echo "  Every rebuild is a new app for Accessibility / Screen Recording (grant again, remove the old entry)." >&2
  echo "  Stable identity on this Mac: bash \"$HERE/make_signing_identity.sh\", then rebuild." >&2
else
  case "$REQ" in
    *"identifier \"$BUNDLE_ID\""*certificate*) ;;
    *) echo "ERROR: unexpected designated requirement (identifier $BUNDLE_ID + certificate expected)" >&2; exit 1;;
  esac
fi
if [ -n "${APP_OUT:-}" ]; then
  mkdir -p "$APP_OUT"; rm -rf "$APP_OUT/Test Installer 4D.app"; ditto "$APP" "$APP_OUT/Test Installer 4D.app"
fi

cp "$ROOT/LISEZMOI.txt" "$STAGE/"
[ "$KIND" = developer-id ] || cp "$HERE/install.sh" "$STAGE/install.sh"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "Test Installer 4D" -srcfolder "$STAGE" -ov -format UDZO "$OUT" -quiet
hdiutil verify "$OUT" -quiet
if [ "$KIND" = developer-id ]; then
  codesign --force --timestamp -s "$IDENTITY" "$OUT"
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    R="$(xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"; echo "$R"
    printf '%s' "$R" | grep -q 'status: Accepted' || { echo "Notarization refused: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2; exit 1; }
    xcrun stapler staple "$OUT"
    spctl -a -vv -t open --context context:primary-signature "$OUT" || true
  else
    echo "WARNING: DMG not notarized (no notarytool profile '$NOTARY_PROFILE'). Create it once:" >&2
    echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <Apple ID> --team-id <team ID>" >&2
  fi
else
  echo "WARNING: no 'Developer ID Application' certificate: Gatekeeper blocks the first launch on another Mac" >&2
  echo "  -> bash \"/Volumes/Test Installer 4D/install.sh\" (or Open Anyway in System Settings)." >&2
fi
echo "$OUT"
