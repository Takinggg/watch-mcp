#!/usr/bin/env bash
# Creates a self-signed code-signing identity for local builds of WatchRecorder, stored in a
# keychain file inside this folder (companion/.signing/, git-ignored). build-app.sh uses it
# automatically, so every rebuild has the same identity and macOS keeps the Screen Recording,
# Microphone and Accessibility permissions. Your login keychain and the system trust settings
# are left as they were. Not suitable for distribution (see README: Developer ID + notarization).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DIR="$HERE/.signing"
KEYCHAIN="$DIR/watchrecorder.keychain-db"
NAME="WatchRecorder Local Signing"
if [ -f "$KEYCHAIN" ] && [ -f "$DIR/keychain-password" ]; then
  echo "Signing identity already exists: $KEYCHAIN"
  exit 0
fi
mkdir -p "$DIR"
chmod 700 "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASSWORD="$(/usr/bin/openssl rand -hex 16)"
printf '%s' "$PASSWORD" > "$DIR/keychain-password"
chmod 600 "$DIR/keychain-password"

cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
# The system LibreSSL writes a PKCS#12 file that the macOS keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/openssl.cnf" -extensions codesign \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/identity.p12" -passout "pass:$PASSWORD"

# create-keychain also adds the new keychain to the user's search list: put the list back as it was.
ORIGINAL_LIST=()
while IFS= read -r line; do ORIGINAL_LIST+=("$(echo "$line" | sed -E 's/^ *"(.*)"$/\1/')"); done < <(security list-keychains -d user)
security create-keychain -p "$PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "${ORIGINAL_LIST[@]}"
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
echo "Created \"$NAME\" in $KEYCHAIN"
