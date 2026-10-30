#!/bin/bash
# Create once, on this Mac, the local code-signing identity "TestInstaller4D Local Signing" (self-signed
# certificate, 10 years) used by build_dmg.sh when no Apple certificate is available.
# Why: with an ad-hoc signature macOS identifies the app by its code hash, so every rebuild is a new app for
# Accessibility / Screen Recording. Signed with this certificate, the designated requirement becomes
# identifier "com.4d.qa.testinstaller4d" and certificate leaf = H"…": the permissions stay valid after a rebuild.
# It is only known by this Mac: it does not replace a Developer ID for Gatekeeper on other Macs.
# Usage: bash make_signing_identity.sh [keychain]   (default: login keychain)
# macOS may ask, in its own dialog, to allow codesign to use the key: answer "Always Allow". No password is stored.
set -euo pipefail
NAME="TestInstaller4D Local Signing"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"
if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -qF "\"$NAME\""; then
  echo "Identity already present: $NAME"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/req.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/req.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12_PASS="$(/usr/bin/openssl rand -hex 16)" # only protects the temporary .p12 file, deleted on exit
/usr/bin/openssl pkcs12 -export -name "$NAME" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$P12_PASS"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -f pkcs12 -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
security find-identity -p codesigning "$KEYCHAIN" | grep -F "\"$NAME\""
echo "Created: $NAME. Rebuild: bash \"$(cd "$(dirname "$0")" && pwd)/build_dmg.sh\""
