#!/usr/bin/env bash
# One-time: create a self-signed code-signing certificate in your login keychain
# and point the build at it, so macOS permission grants (Accessibility, Screen
# Recording, Microphone) survive rebuilds. macOS will show ONE password dialog
# when the certificate is marked trusted for code signing.
#
# Usage: scripts/make-dev-cert.sh            (identity name: "HeyClickyClone Dev")
set -euo pipefail

NAME="${1:-HeyClickyClone Dev}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "certificate \"$NAME\" already exists in the login keychain"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
  # Import key and certificate as PEM (a PKCS#12 made by modern OpenSSL uses
  # ciphers the macOS importer rejects, and it writes PKCS#8 keys the importer
  # does not parse, so convert to the traditional RSA form first).
  # -T lets codesign use the key silently.
  openssl rsa -in "$TMP/key.pem" -traditional -out "$TMP/key_rsa.pem" 2>/dev/null
  security import "$TMP/key_rsa.pem" -k "$KEYCHAIN" -t priv -f openssl -A -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security import "$TMP/cert.pem" -k "$KEYCHAIN" -t cert -f openssl >/dev/null
  # Mark it trusted for code signing (user trust domain -> one password dialog).
  security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
  echo "created and trusted certificate \"$NAME\""
fi

security find-identity -v -p codesigning | grep -F "$NAME" || {
  echo "warning: the identity is not listed as valid for code signing yet; open Keychain Access and set Trust -> Code Signing: Always Trust" >&2
}

ENV_FILE="$ROOT/.env"
touch "$ENV_FILE"
if grep -q '^CODESIGN_IDENTITY=' "$ENV_FILE"; then
  sed -i '' "s|^CODESIGN_IDENTITY=.*|CODESIGN_IDENTITY=\"$NAME\"|" "$ENV_FILE"
else
  echo "CODESIGN_IDENTITY=\"$NAME\"" >> "$ENV_FILE"
fi
echo "CODESIGN_IDENTITY set in .env; rebuild with scripts/build-app.sh, then grant permissions once more (they now persist)."
