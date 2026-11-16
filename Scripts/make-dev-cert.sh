#!/usr/bin/env bash
# Creates a self-signed code-signing identity "MacScreen Dev" in the login keychain.
set -euo pipefail

NAME="MacScreen Dev"

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "Code-signing identity \"$NAME\" already exists. Nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
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
CNF

PASS="$(/usr/bin/openssl rand -hex 16)"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/openssl.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem"

/usr/bin/openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout "pass:$PASS" -out "$TMP/dev.p12"

LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$TMP/dev.p12" -k "$LOGIN_KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

cat <<MSG

Created and imported the self-signed identity "$NAME" (valid 10 years).

Next steps:
  1. Run Scripts/make-app.sh. It will pick up "$NAME" automatically.
  2. The first codesign use may show a keychain prompt. Choose "Always Allow".
  3. If codesign reports the identity as not trusted or not found, open
     Keychain Access, double-click "$NAME", expand Trust and set
     Code Signing to "Always Trust".
  4. Grant Screen Recording to build/MacScreen.app once; it will persist across
     rebuilds because the signing identity is stable.
MSG
