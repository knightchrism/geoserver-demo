#!/bin/sh
# Renew the Let's Encrypt certificate, copy it where Nginx reads it, and reload Nginx.
#
# Run this from cron or the systemd timer after the certificate has been issued
# at least once with scripts/tls-certbot.sh. Certbot does nothing when the
# certificate is not due, and this script still reloads Nginx so a copied file
# is the one in memory.
#
#   systemd: hardening/systemd/geoknight-cert-renew.timer
#   cron:    hardening/cron/geoknight-cert-renew
# Install either one with: sudo sh scripts/bootstrap-vm.sh --enable-cert-renew
# or:                      sudo sh scripts/bootstrap-vm.sh --with-cron
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

domain="${LETSENCRYPT_DOMAIN:-}"
if [ -z "$domain" ] || [ "$domain" = "localhost" ]; then
    die "Set LETSENCRYPT_DOMAIN in .env to the public DNS name of this VM."
fi
if [ "${TLS_MODE:-local}" != "letsencrypt" ]; then
    echo "[geoknight] warning: TLS_MODE is not letsencrypt. Renewing anyway because LETSENCRYPT_DOMAIN is set." >&2
fi

echo "[geoknight] renewing the certificate for ${domain}"
dc --profile letsencrypt run --rm --entrypoint certbot certbot renew \
    --webroot -w /var/www/certbot \
    --deploy-hook "/bin/sh /opt/geoknight/tls-deploy-hook.sh"

dc --profile letsencrypt run --rm --no-deps --entrypoint sh certbot -c \
    "/bin/sh /opt/geoknight/tls-deploy-hook.sh /etc/letsencrypt/live/${domain}"

if ! dc exec nginx nginx -s reload; then
    die "The certificate files were updated, but Nginx did not reload."
fi
echo "[geoknight] Nginx reloaded with the certificate for ${domain}"
