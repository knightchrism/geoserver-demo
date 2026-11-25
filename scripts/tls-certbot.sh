#!/bin/sh
# Request a Let's Encrypt certificate on the Ubuntu VM, then copy it where Nginx looks.
# The site must already be reachable on port 80 at LETSENCRYPT_DOMAIN.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

domain="${LETSENCRYPT_DOMAIN:-}"
email="${LETSENCRYPT_EMAIL:-}"
if [ -z "$domain" ] || [ "$domain" = "localhost" ]; then
    die "Set LETSENCRYPT_DOMAIN in .env to the public DNS name of this VM."
fi
if [ -z "$email" ] || [ "$email" = "you@example.com" ]; then
    die "Set LETSENCRYPT_EMAIL in .env to a real address Let's Encrypt can use."
fi

echo "[geoknight] requesting a certificate for ${domain}"
dc --profile letsencrypt run --rm --entrypoint certbot certbot certonly \
    --webroot -w /var/www/certbot \
    --agree-tos --no-eff-email \
    --email "$email" \
    -d "$domain"

dc --profile letsencrypt run --rm --entrypoint sh certbot -c \
    "cp /etc/letsencrypt/live/${domain}/fullchain.pem /etc/letsencrypt/fullchain.pem && cp /etc/letsencrypt/live/${domain}/privkey.pem /etc/letsencrypt/privkey.pem"

cid="$(dc --profile letsencrypt ps -q certbot || true)"
# The certs live in the certbot_certs volume. Copy them out with a one-off container.
dc --profile letsencrypt run --rm --no-deps --entrypoint sh certbot -c \
    "cp /etc/letsencrypt/live/${domain}/fullchain.pem /tmp/fullchain.pem && cp /etc/letsencrypt/live/${domain}/privkey.pem /tmp/privkey.pem && cat /tmp/fullchain.pem" \
    > "$ROOT/certs/server.crt"
dc --profile letsencrypt run --rm --no-deps --entrypoint sh certbot -c \
    "cat /etc/letsencrypt/live/${domain}/privkey.pem" \
    > "$ROOT/certs/server.key"
chmod 644 "$ROOT/certs/server.crt"
chmod 600 "$ROOT/certs/server.key"
dc exec nginx nginx -s reload
echo "[geoknight] Nginx is using the Let's Encrypt certificate for ${domain}"
echo "[geoknight] Renew on a schedule with: docker compose --profile letsencrypt up -d certbot"
unset cid
