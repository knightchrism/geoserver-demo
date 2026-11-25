#!/bin/sh
# Prove HTTPS, the access rules, and that the dashboard can see traffic.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

pass=0
fail=0
ok() {
    pass=$((pass + 1))
    printf '[PASS] %s\n' "$1"
}
bad() {
    fail=$((fail + 1))
    printf '[FAIL] %s\n' "$1"
}

extent_file="$ROOT/config/extent.env"
if [ -f "$ROOT/data/extent.env" ]; then
    extent_file="$ROOT/data/extent.env"
fi
# shellcheck disable=SC1090
. "$extent_file"
bbox="${MIN_X},${MIN_Y},${MAX_X},${MAX_Y}"
ca="$ROOT/certs/ca.crt"
base="https://127.0.0.1"

https_get() {
    curl -sS --cacert "$ca" --max-time 60 "$@"
}

echo "GeoKnight GIS smoke test"
echo "Host: ${PUBLIC_HOST:-localhost}"
echo

# HTTPS and redirect
if echo | openssl s_client -connect 127.0.0.1:443 -servername localhost -CAfile "$ca" -brief >/tmp/gk-tls.txt 2>&1; then
    ok "HTTPS handshake trusts the local certificate"
else
    bad "HTTPS handshake failed (see /tmp/gk-tls.txt)"
fi

if echo | openssl s_client -connect 127.0.0.1:443 -tls1 >/tmp/gk-tls1.txt 2>&1; then
    bad "TLS 1.0 was accepted"
else
    ok "TLS 1.0 is rejected"
fi

redirect="$(curl -s -o /dev/null -D - --max-time 20 "http://127.0.0.1/" || true)"
if printf '%s' "$redirect" | head -n 1 | grep -q "301" && printf '%s' "$redirect" | grep -qi "location: https://"; then
    ok "HTTP redirects to HTTPS"
else
    bad "HTTP did not redirect to HTTPS"
fi

caps="$(https_get "$base/geoserver/ows?service=WMS&version=1.3.0&request=GetCapabilities" || true)"
if printf '%s' "$caps" | grep -q "public:roads"; then
    ok "WMS capabilities list public:roads"
else
    bad "WMS capabilities did not list public:roads"
fi
if printf '%s' "$caps" | grep -q "public:naip" && printf '%s' "$caps" | grep -q "public:dem"; then
    ok "WMS capabilities list imagery and elevation"
else
    bad "WMS capabilities are missing imagery or elevation"
fi

wfs_caps="$(https_get "$base/geoserver/ows?service=WFS&version=2.0.0&request=GetCapabilities" || true)"
if printf '%s' "$wfs_caps" | grep -q "restricted:parcels"; then
    ok "WFS capabilities list restricted:parcels"
else
    bad "WFS capabilities did not list parcels"
fi

wcs_caps="$(https_get "$base/geoserver/ows?service=WCS&version=2.0.1&request=GetCapabilities" || true)"
if printf '%s' "$wcs_caps" | grep -qi "dem"; then
    ok "WCS capabilities mention the elevation coverage"
else
    bad "WCS capabilities did not mention elevation"
fi

wmts_caps="$(https_get "$base/geoserver/gwc/service/wmts?SERVICE=WMTS&REQUEST=GetCapabilities" || true)"
if printf '%s' "$wmts_caps" | grep -q "public:roads"; then
    ok "WMTS capabilities list public:roads"
else
    bad "WMTS capabilities did not list public:roads"
fi

map_url="$base/geoserver/public/wms?service=WMS&version=1.1.1&request=GetMap&layers=public:roads&styles=&srs=EPSG:26917&bbox=${bbox}&width=256&height=256&format=image/png"
if https_get -o /tmp/gk-roads.png "$map_url" && printf '\211PNG' | cmp -s -n 4 - /tmp/gk-roads.png; then
    ok "Anonymous GetMap of public:roads returned a PNG"
else
    # cmp with a pipe can be picky. Check the magic bytes directly.
    magic="$(od -An -t x1 -N 4 /tmp/gk-roads.png 2>/dev/null | tr -d ' \n' || true)"
    if [ "$magic" = "89504e47" ]; then
        ok "Anonymous GetMap of public:roads returned a PNG"
    else
        bad "Anonymous GetMap of public:roads was not a PNG"
    fi
fi

parcel_code="$(https_get -o /tmp/gk-anon-parcels.xml -w "%{http_code}" \
    "$base/geoserver/restricted/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=restricted:parcels&count=1" || true)"
if [ "$parcel_code" = "401" ] || [ "$parcel_code" = "403" ]; then
    ok "Anonymous user is denied restricted:parcels ($parcel_code)"
elif grep -qiE "AccessDenied|not authorized|Unauthorized" /tmp/gk-anon-parcels.xml 2>/dev/null; then
    ok "Anonymous user is denied restricted:parcels (exception report)"
else
    bad "Anonymous user was not denied restricted:parcels (HTTP ${parcel_code})"
fi

viewer_code="$(https_get -u "${VIEWER_USER}:${VIEWER_PASSWORD}" -o /tmp/gk-viewer.xml -w "%{http_code}" \
    "$base/geoserver/restricted/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=restricted:parcels&count=1" || true)"
if [ "$viewer_code" = "401" ] || [ "$viewer_code" = "403" ] || grep -qiE "AccessDenied|not authorized" /tmp/gk-viewer.xml 2>/dev/null; then
    ok "Signed-in public viewer is denied restricted:parcels ($viewer_code)"
else
    bad "Signed-in public viewer was not denied restricted:parcels (HTTP ${viewer_code})"
fi

analyst_code="$(https_get -u "${ANALYST_USER}:${ANALYST_PASSWORD}" -o /tmp/gk-analyst.xml -w "%{http_code}" \
    "$base/geoserver/restricted/wfs?service=WFS&version=2.0.0&request=GetFeature&typeNames=restricted:parcels&count=2" || true)"
if [ "$analyst_code" = "200" ] && grep -q "restricted:parcels\|RE-" /tmp/gk-analyst.xml; then
    ok "Analyst can read restricted:parcels"
else
    bad "Analyst could not read restricted:parcels (HTTP ${analyst_code})"
fi

default_code="$(https_get -u "${GEOSERVER_ADMIN_USER}:geoserver" -o /dev/null -w "%{http_code}" \
    "$base/geoserver/rest/about/version.json" || true)"
if [ "$default_code" = "401" ] || [ "$default_code" = "403" ]; then
    ok "The old admin password geoserver is rejected"
else
    bad "The old admin password was accepted (HTTP ${default_code})"
fi

admin_code="$(https_get -o /dev/null -w "%{http_code}" "$base/geoserver/web/" || true)"
if [ "$admin_code" = "200" ] || [ "$admin_code" = "302" ]; then
    ok "Operator can open the GeoServer admin page ($admin_code)"
else
    bad "Operator was blocked from the admin page (HTTP ${admin_code})"
fi

outsider_code="$(dc --profile test run --rm --no-deps outsider \
    --cacert /certs/ca.crt -s -o /dev/null -w "%{http_code}" \
    https://nginx/geoserver/web/ || true)"
if [ "$outsider_code" = "403" ]; then
    ok "A container outside the allowlist is refused the admin page"
else
    bad "Outsider admin check returned HTTP ${outsider_code}"
fi

dash_code="$(https_get -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" -o /tmp/gk-dash.json -w "%{http_code}" \
    "$base/grafana/api/dashboards/uid/geoknight-gis" || true)"
if [ "$dash_code" = "200" ] && grep -q "GeoKnight GIS" /tmp/gk-dash.json; then
    ok "Grafana is serving the GeoKnight dashboard"
else
    bad "Grafana dashboard was not found (HTTP ${dash_code})"
fi

query='sum(count_over_time({job="nginx"}[30m]))'
encoded="$(printf '%s' "$query" | jq -sRr @uri)"
metrics="$(https_get -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
    "$base/grafana/api/datasources/proxy/uid/loki/loki/api/v1/query?query=${encoded}" || true)"
if ! printf '%s' "$metrics" | grep -q '"status":"success"'; then
    metrics="$(https_get -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASSWORD}" \
        "$base/grafana/api/datasources/proxy/uid/loki/loki/api/v1/query_range?query=${encoded}&start=$(date -u +%s -d '-30 minutes')&end=$(date -u +%s)&step=60" || true)"
fi
count="$(printf '%s' "$metrics" | jq -r '.. | .value? // empty | if type=="array" then .[1] else empty end' 2>/dev/null | head -n 1 || true)"
if [ -n "$count" ] && [ "$count" != "null" ] && awk "BEGIN { exit !($count > 0) }"; then
    ok "Dashboard data source has ${count} Nginx log lines in the last 30 minutes"
else
    bad "Dashboard data source did not return Nginx log lines yet. Run make simulate, then make verify."
fi

echo
echo "Passed: $pass  Failed: $fail"
if [ "$fail" -ne 0 ]; then
    exit 1
fi
echo "Smoke test passed."
