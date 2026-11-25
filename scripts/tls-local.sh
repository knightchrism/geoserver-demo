#!/bin/sh
# Create a local certificate authority and a server certificate.
# The server name list covers localhost, the Nginx container, and PUBLIC_HOST.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"

mkdir -p "$ROOT/certs"
force="${1:-}"

if [ -f "$ROOT/certs/server.crt" ] && [ "$force" != "--force" ]; then
    if openssl x509 -in "$ROOT/certs/server.crt" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:nginx"; then
        echo "[geoknight] local certificate already exists"
        exit 0
    fi
fi

host_name="${PUBLIC_HOST:-localhost}"
san="DNS:localhost,DNS:nginx,DNS:geoknight.local,DNS:host.docker.internal,IP:127.0.0.1"
case "$host_name" in
    localhost|127.0.0.1) ;;
    *[0-9].[0-9]*) san="$san,IP:$host_name" ;;
    *) san="$san,DNS:$host_name" ;;
esac

openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
    -keyout "$ROOT/certs/ca.key" \
    -out "$ROOT/certs/ca.crt" \
    -subj "/CN=GeoKnight Local CA/O=GeoKnight GIS" >/dev/null 2>&1

openssl req -newkey rsa:2048 -nodes \
    -keyout "$ROOT/certs/server.key" \
    -out "$ROOT/certs/server.csr" \
    -subj "/CN=${host_name}/O=GeoKnight GIS" >/dev/null 2>&1

cat > "$ROOT/certs/server.ext" <<EOF
subjectAltName=${san}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF

openssl x509 -req \
    -in "$ROOT/certs/server.csr" \
    -CA "$ROOT/certs/ca.crt" \
    -CAkey "$ROOT/certs/ca.key" \
    -CAcreateserial \
    -out "$ROOT/certs/server.crt" \
    -days 825 -sha256 \
    -extfile "$ROOT/certs/server.ext" >/dev/null 2>&1

rm -f "$ROOT/certs/server.csr"
chmod 600 "$ROOT/certs/ca.key" "$ROOT/certs/server.key"
chmod 644 "$ROOT/certs/ca.crt" "$ROOT/certs/server.crt"
echo "[geoknight] wrote a local certificate for ${host_name}"
echo "[geoknight] trust certs/ca.crt in your browser if you want to skip the warning"
