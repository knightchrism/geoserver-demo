#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env
sh "$ROOT/scripts/check-env.sh"
sh "$ROOT/scripts/tls-local.sh"
mkdir -p "$ROOT/logs/nginx" \
    "$ROOT/data/vector/gpkg" "$ROOT/data/vector/sql" \
    "$ROOT/data/imagery" "$ROOT/data/elevation" "$ROOT/data/styles"
echo "[geoknight] starting the stack"
dc up -d
wait_for_url "http://127.0.0.1:${GEOSERVER_PORT:-8080}/geoserver/web/" "GeoServer" 80
echo "[geoknight] stack is up. Next: make load-data && make configure"
