#!/bin/sh
# Create a local certificate authority and a server certificate.
# The server name list covers localhost, the Nginx container, and PUBLIC_HOST.
#
# TLS_MODE=letsencrypt never replaces a certificate that is already on disk.
# A self-signed certificate is written only when certs/server.crt is missing,
# or when TLS_MODE=local and the current file is still a local certificate
# that does not list DNS:nginx. A Let's Encrypt certificate is left alone
# even if TLS_MODE is still local.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"

mkdir -p "$ROOT/certs"
force="${1:-}"
mode="${TLS_MODE:-local}"
cert="$ROOT/certs/server.crt"
key="$ROOT/certs/server.key"

case "$mode" in
    local|letsencrypt) ;;
    *) die "TLS_MODE must be local or letsencrypt (got ${mode})." ;;
esac

public_cert() {
    issuer="$(openssl x509 -in "$cert" -noout -issuer 2>/dev/null || true)"
    printf '%s' "$issuer" | grep -qiE "Let's Encrypt|Let.s Encrypt|ISRG"
}

keep_existing() {
    echo "[geoknight] keeping the certificate already at certs/server.crt"
}

if [ -f "$cert" ] && [ -f "$key" ] && [ "$mode" = "letsencrypt" ]; then
    keep_existing
    echo "[geoknight] TLS_MODE=letsencrypt, so a self-signed certificate is not written."
    exit 0
fi

if [ -f "$cert" ] && [ -f "$key" ] && public_cert; then
    if [ "$force" = "--force" ]; then
        die "Refusing to overwrite a Let's Encrypt certificate. Move certs/server.crt aside first."
    fi
    keep_existing
    echo "[geoknight] This is a Let's Encrypt certificate. Set TLS_MODE=letsencrypt so it stays in use."
    exit 0
fi

if [ -f "$cert" ] && [ -f "$key" ] && [ "$force" != "--force" ]; then
    if openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:nginx"; then
        echo "[geoknight] local certificate already exists"
        exit 0
    fi
fi

if [ "$mode" = "letsencrypt" ]; then
    echo "[geoknight] TLS_MODE=letsencrypt and no certificate is present yet."
    echo "[geoknight] Writing a temporary self-signed certificate so Nginx can start."
    echo "[geoknight] Replace it with: sh scripts/tls-certbot.sh"
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
