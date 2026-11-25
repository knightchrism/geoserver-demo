#!/bin/sh
# Request a Let's Encrypt certificate on the Ubuntu VM, copy it where Nginx
# looks, and reload Nginx. The site must already answer on port 80 at
# LETSENCRYPT_DOMAIN. Renewal is scripts/tls-renew.sh, on a timer or cron.
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

dc --profile letsencrypt run --rm --no-deps --entrypoint sh certbot -c \
    "/bin/sh /opt/geoknight/tls-deploy-hook.sh /etc/letsencrypt/live/${domain}"

if ! dc exec nginx nginx -s reload; then
    die "The certificate was copied, but Nginx did not reload."
fi
echo "[geoknight] Nginx is using the Let's Encrypt certificate for ${domain}"
echo "[geoknight] Set TLS_MODE=letsencrypt in .env so make up does not replace it."
echo "[geoknight] Renew on a schedule with: sudo sh scripts/bootstrap-vm.sh --enable-cert-renew"
