#!/bin/sh
# Certbot deploy hook. Copies the renewed full chain and key to the files Nginx mounts.
#
# Certbot sets RENEWED_LINEAGE. A renew script can also pass the live directory
# as the first argument. Inside the certbot container the destination is
# /geoknight-certs (the repo certs/ directory). On the host, set GEOKNIGHT_CERT_DIR.
set -eu

dest="${GEOKNIGHT_CERT_DIR:-/geoknight-certs}"
lineage="${RENEWED_LINEAGE:-${1:-}}"
if [ -z "$lineage" ]; then
    echo "tls-deploy-hook: set RENEWED_LINEAGE or pass the live certificate directory." >&2
    exit 1
fi
if [ ! -f "$lineage/fullchain.pem" ] || [ ! -f "$lineage/privkey.pem" ]; then
    echo "tls-deploy-hook: ${lineage} is missing fullchain.pem or privkey.pem." >&2
    exit 1
fi
mkdir -p "$dest"
cp "$lineage/fullchain.pem" "$dest/server.crt"
cp "$lineage/privkey.pem" "$dest/server.key"
chmod 644 "$dest/server.crt"
chmod 600 "$dest/server.key"
echo "tls-deploy-hook: updated ${dest}/server.crt"
