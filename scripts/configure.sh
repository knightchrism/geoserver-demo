#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env
sh "$ROOT/scripts/check-env.sh"

base="http://127.0.0.1:${GEOSERVER_PORT:-8080}/geoserver"
echo "[geoknight] waiting for the GeoServer REST API"
n=0
while [ "$n" -lt 40 ]; do
    code="$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 \
        -u "${GEOSERVER_ADMIN_USER}:${GEOSERVER_ADMIN_PASSWORD}" \
        "$base/rest/about/version.json" || true)"
    if [ "$code" = "200" ]; then
        break
    fi
    n=$((n + 1))
    sleep 3
done
if [ "$code" != "200" ]; then
    die "GeoServer did not accept the admin login from .env (last HTTP status: ${code:-none})."
fi

export GEOSERVER_INTERNAL_URL="$base"
sh "$ROOT/scripts/grant-app-role.sh"
python3 "$ROOT/scripts/configure_geoserver.py"

# The resource API is convenient, and a direct copy makes the files certain.
dc exec -T geoserver bash -c 'cat > /opt/geoserver_data/security/layers.properties' \
    < "$ROOT/geoserver/security/layers.properties"
dc exec -T geoserver bash -c 'cat > /opt/geoserver_data/security/services.properties' \
    < "$ROOT/geoserver/security/services.properties"
dc exec -T geoserver touch /opt/geoserver_data/security/geoknight-managed.txt

curl -fsS -o /dev/null -u "${GEOSERVER_ADMIN_USER}:${GEOSERVER_ADMIN_PASSWORD}" \
    -X POST "$base/rest/reload"
echo "[geoknight] GeoServer is configured. Accounts survive a GeoServer restart."
