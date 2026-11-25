#!/bin/sh
# Build the allow/deny block, then hand off to the official Nginx entrypoint
# so it can fill ${ADMIN_ALLOW_DIRECTIVES} into the site template.
set -eu

ALLOW="${ADMIN_ALLOW_CIDRS:-10.0.0.0/8,192.168.0.0/16,172.16.0.0/12}"

# 172.28.10.1 is the gateway. A browser on the computer shows up as that address.
# Every other address on the visitor network and on the test network is refused,
# even when a later rule allows all of 172.16.0.0/12.
directives="    allow 127.0.0.1/32;
    allow 172.28.10.1/32;
    deny 172.28.10.0/24;
    deny 172.28.12.0/24;"

old_ifs=$IFS
IFS=,
for cidr in $ALLOW; do
    c=$(printf '%s' "$cidr" | tr -d '[:space:]')
    [ -n "$c" ] || continue
    case "$c" in
        172.28.10.0/24|172.28.12.0/24) continue ;;
    esac
    directives="$directives
    allow $c;"
done
IFS=$old_ifs

directives="$directives
    deny all;"

export ADMIN_ALLOW_DIRECTIVES="$directives"

mkdir -p /var/log/nginx /var/www/certbot
chmod 755 /var/log/nginx /var/www/certbot

exec /docker-entrypoint.sh "$@"
