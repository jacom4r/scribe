#!/usr/bin/env bash
# Creates a self-signed code signing identity named "Scribe Dev" in the login
# keychain, once. A stable identity keeps macOS's audio permission grant valid
# across rebuilds; ad-hoc signatures change every build and re-prompt.
set -euo pipefail

NAME="Scribe Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "'$NAME' already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem"

# OpenSSL 3 needs -legacy for a PKCS#12 that `security import` accepts;
# LibreSSL (macOS default) has no -legacy flag and produces a compatible file.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/scribe-dev.p12" -passout pass:scribe 2>/dev/null \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/scribe-dev.p12" -passout pass:scribe

security import "$TMP/scribe-dev.p12" -k "$KEYCHAIN" -P scribe \
  -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (may prompt for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo "Created '$NAME'. The first codesign may show a keychain prompt; choose 'Always Allow'."
security find-identity -v -p codesigning | grep "$NAME"
