#!/usr/bin/env bash
# Makes a private certificate authority (CA) and a server certificate, so the
# phone can talk to this Mac over HTTPS during development.
#
# Nothing is installed into the Mac's keychain. The app trusts this CA only
# when a debug run passes it in (see backend/README.md), so release builds
# never trust it.
#
# Usage: scripts/make-dev-cert.sh [LAN-IP]
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p certs

LAN_IP="${1:-$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)}"

# The CA is made once and kept, so phones that already trust it keep working
# when the server certificate is renewed (e.g. after the LAN IP changes).
if [ ! -f certs/dev-ca.pem ]; then
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -days 3650 -subj "/CN=TrustPunch Dev CA" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout certs/dev-ca-key.pem -out certs/dev-ca.pem 2>/dev/null
fi

# Names the server answers to: this Mac, the Android emulator's alias for
# this Mac (10.0.2.2), and the Mac's address on the Wi-Fi for real phones.
SAN="DNS:localhost,IP:127.0.0.1,IP:10.0.2.2"
if [ -n "$LAN_IP" ]; then SAN="$SAN,IP:$LAN_IP"; fi

openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj "/CN=trustpunch-dev" \
  -keyout certs/server-key.pem -out certs/server.csr 2>/dev/null

# 397 days: the longest a server certificate may live and still be accepted
# by Apple's rules.
openssl x509 -req -in certs/server.csr \
  -CA certs/dev-ca.pem -CAkey certs/dev-ca-key.pem -CAcreateserial \
  -days 397 -out certs/server.pem \
  -extfile <(printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n' "$SAN") \
  2>/dev/null

rm -f certs/server.csr
chmod 600 certs/*-key.pem

echo "Certificate valid for: $SAN"
echo "CA for the app:        $(pwd)/certs/dev-ca.pem"
