#!/bin/sh
# Prove HTTPS, the access rules, WFS-T on editor notes, and that the dashboard can see traffic.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/tls-client.sh"
need_env
tls_client_init

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
base="$VERIFY_BASE"
http_port="${HTTP_PORT:-80}"

https_get() {
    # shellcheck disable=SC2086
    curl -sS $CURL_CA_OPT $CURL_RESOLVE --max-time 90 "$@"
}

png_ok() {
    file="$1"
    magic="$(od -An -t x1 -N 4 "$file" 2>/dev/null | tr -d ' \n' || true)"
    [ "$magic" = "89504e47" ]
}

wfst_success() {
    file="$1"
    label="$2"
    code="$3"
    if [ "$code" = "200" ] && grep -Eq '<[^>]*totalInserted>1<|>[^>]*totalUpdated>1<|>[^>]*totalDeleted>1<|SUCCESS' "$file"; then
        ok "$label"
        return 0
    fi
    bad "$label (HTTP ${code})"
    return 1
}

wfst_denied() {
    file="$1"
    label="$2"
    code="$3"
    if grep -Eq '<[^>]*totalInserted>[1-9]|<[^>]*totalUpdated>[1-9]|<[^>]*totalDeleted>[1-9]|<wfs:SUCCESS>' "$file" 2>/dev/null; then
        bad "$label (transaction succeeded, HTTP ${code})"
        return 1
    fi
    if [ "$code" = "401" ] || [ "$code" = "403" ] || grep -qiE 'AccessDenied|not authorized|Unauthorized|permission denied|read-only|read only' "$file"; then
        ok "$label ($code)"
        return 0
    fi
    bad "$label (HTTP ${code})"
    return 1
}

echo "GeoKnight GIS smoke test"
echo "Host: ${PUBLIC_HOST:-localhost}"
echo "TLS_MODE: ${TLS_MODE}"
if [ -n "${VERIFY_CA:-}" ]; then
    echo "CA file: ${VERIFY_CA}"
elif [ "$TLS_MODE" = "letsencrypt" ]; then
    echo "CA: system trust store"
else
    echo "CA file: certs/ca.crt"
fi
echo

# HTTPS and redirect
# shellcheck disable=SC2086
if echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -servername "$VERIFY_NAME" $OPENSSL_CA_OPT -brief >/tmp/gk-tls.txt 2>&1; then
    if grep -q "Verification: OK" /tmp/gk-tls.txt || grep -q "Verify return code: 0" /tmp/gk-tls.txt; then
        ok "HTTPS handshake trusts the certificate"
    else
        bad "HTTPS handshake failed verification (see /tmp/gk-tls.txt)"
    fi
else
    bad "HTTPS handshake failed (see /tmp/gk-tls.txt)"
fi

if echo | openssl s_client -connect "127.0.0.1:${HTTPS_PORT}" -tls1 >/tmp/gk-tls1.txt 2>&1; then
    bad "TLS 1.0 was accepted"
else
    ok "TLS 1.0 is rejected"
fi

redirect="$(curl -s -o /dev/null -D - --max-time 20 "http://127.0.0.1:${http_port}/" || true)"
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
if https_get -o /tmp/gk-roads.png "$map_url" && png_ok /tmp/gk-roads.png; then
    ok "Anonymous GetMap of public:roads returned a PNG"
else
    bad "Anonymous GetMap of public:roads was not a PNG"
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
if [ "$analyst_code" = "200" ] && grep -q "restricted:parcels\|<[^>]*re>" /tmp/gk-analyst.xml; then
    ok "Analyst can read restricted:parcels"
else
    bad "Analyst could not read restricted:parcels (HTTP ${analyst_code})"
fi

mirta_url="$base/geoserver/restricted/wms?service=WMS&version=1.1.1&request=GetMap&layers=restricted:mirta&styles=&srs=EPSG:26917&bbox=${bbox}&width=256&height=256&format=image/png"
if https_get -u "${ANALYST_USER}:${ANALYST_PASSWORD}" -o /tmp/gk-mirta.png "$mirta_url" && png_ok /tmp/gk-mirta.png; then
    ok "Analyst GetMap of restricted:mirta returned a PNG"
else
    bad "Analyst GetMap of restricted:mirta was not a PNG"
fi

note_tag="verify-$(date +%s)"
wfs_url="$base/geoserver/restricted/wfs"
cat > /tmp/gk-wfst-insert.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:gml="http://www.opengis.net/gml"
  xmlns:restricted="https://geoknight.gis/restricted">
  <wfs:Insert>
    <restricted:editor_notes>
      <restricted:note>${note_tag}</restricted:note>
      <restricted:created_by>verify</restricted:created_by>
      <restricted:geom>
        <gml:Point srsName="http://www.opengis.net/gml/srs/epsg.xml#26917">
          <gml:pos>430000 3350000</gml:pos>
        </gml:Point>
      </restricted:geom>
    </restricted:editor_notes>
  </wfs:Insert>
</wfs:Transaction>
EOF

insert_code="$(https_get -u "${EDITOR_USER}:${EDITOR_PASSWORD}" -o /tmp/gk-wfst-insert-out.xml -w "%{http_code}" \
    -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-insert.xml "$wfs_url" || true)"
fid=""
if wfst_success /tmp/gk-wfst-insert-out.xml "Editor can insert restricted:editor_notes" "$insert_code"; then
    fid="$(sed -n 's/.*fid="\([^"]*\)".*/\1/p' /tmp/gk-wfst-insert-out.xml | head -n 1)"
fi
if [ -z "$fid" ]; then
    bad "Editor insert did not return a feature id"
else
    cat > /tmp/gk-wfst-update.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:ogc="http://www.opengis.net/ogc">
  <wfs:Update typeName="restricted:editor_notes">
    <wfs:Property>
      <wfs:Name>note</wfs:Name>
      <wfs:Value>${note_tag}-updated</wfs:Value>
    </wfs:Property>
    <ogc:Filter>
      <ogc:FeatureId fid="${fid}"/>
    </ogc:Filter>
  </wfs:Update>
</wfs:Transaction>
EOF
    update_code="$(https_get -u "${EDITOR_USER}:${EDITOR_PASSWORD}" -o /tmp/gk-wfst-update-out.xml -w "%{http_code}" \
        -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-update.xml "$wfs_url" || true)"
    wfst_success /tmp/gk-wfst-update-out.xml "Editor can update restricted:editor_notes" "$update_code" || true

    cat > /tmp/gk-wfst-delete.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:ogc="http://www.opengis.net/ogc">
  <wfs:Delete typeName="restricted:editor_notes">
    <ogc:Filter>
      <ogc:FeatureId fid="${fid}"/>
    </ogc:Filter>
  </wfs:Delete>
</wfs:Transaction>
EOF
    delete_code="$(https_get -u "${EDITOR_USER}:${EDITOR_PASSWORD}" -o /tmp/gk-wfst-delete-out.xml -w "%{http_code}" \
        -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-delete.xml "$wfs_url" || true)"
    wfst_success /tmp/gk-wfst-delete-out.xml "Editor can delete restricted:editor_notes" "$delete_code" || true
fi

cat > /tmp/gk-wfst-denied.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:gml="http://www.opengis.net/gml"
  xmlns:restricted="https://geoknight.gis/restricted">
  <wfs:Insert>
    <restricted:editor_notes>
      <restricted:note>denied</restricted:note>
      <restricted:geom>
        <gml:Point srsName="http://www.opengis.net/gml/srs/epsg.xml#26917">
          <gml:pos>430100 3350100</gml:pos>
        </gml:Point>
      </restricted:geom>
    </restricted:editor_notes>
  </wfs:Insert>
</wfs:Transaction>
EOF

analyst_tx="$(https_get -u "${ANALYST_USER}:${ANALYST_PASSWORD}" -o /tmp/gk-wfst-analyst.xml -w "%{http_code}" \
    -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-denied.xml "$wfs_url" || true)"
wfst_denied /tmp/gk-wfst-analyst.xml "Analyst cannot write restricted:editor_notes" "$analyst_tx" || true

viewer_tx="$(https_get -u "${VIEWER_USER}:${VIEWER_PASSWORD}" -o /tmp/gk-wfst-viewer.xml -w "%{http_code}" \
    -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-denied.xml "$wfs_url" || true)"
wfst_denied /tmp/gk-wfst-viewer.xml "Viewer cannot write restricted:editor_notes" "$viewer_tx" || true

cat > /tmp/gk-wfst-parcel.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<wfs:Transaction service="WFS" version="1.1.0"
  xmlns:wfs="http://www.opengis.net/wfs"
  xmlns:gml="http://www.opengis.net/gml"
  xmlns:restricted="https://geoknight.gis/restricted">
  <wfs:Insert>
    <restricted:parcels>
      <restricted:re>should-fail</restricted:re>
      <restricted:geom>
        <gml:Polygon srsName="http://www.opengis.net/gml/srs/epsg.xml#26917">
          <gml:exterior>
            <gml:LinearRing>
              <gml:posList>430000 3350000 430010 3350000 430010 3350010 430000 3350000</gml:posList>
            </gml:LinearRing>
          </gml:exterior>
        </gml:Polygon>
      </restricted:geom>
    </restricted:parcels>
  </wfs:Insert>
</wfs:Transaction>
EOF
parcel_tx="$(https_get -u "${EDITOR_USER}:${EDITOR_PASSWORD}" -o /tmp/gk-wfst-parcel-out.xml -w "%{http_code}" \
    -H "Content-Type: text/xml" --data-binary @/tmp/gk-wfst-parcel.xml "$wfs_url" || true)"
wfst_denied /tmp/gk-wfst-parcel-out.xml "Editor cannot write restricted:parcels" "$parcel_tx" || true

db_login="$(dc exec -T -e PGPASSWORD="$GEOSERVER_DB_PASSWORD" postgis \
    psql -h 127.0.0.1 -q -tA -U "$GEOSERVER_DB_USER" -d "$POSTGRES_DB" -c "SELECT current_user" 2>/dev/null || true)"
db_login="$(printf '%s' "$db_login" | tr -d '[:space:]')"
if [ "$db_login" = "$GEOSERVER_DB_USER" ]; then
    ok "GeoServer database role can sign in"
else
    bad "GeoServer database role could not sign in"
fi

db_denied="$(dc exec -T -e PGPASSWORD="$GEOSERVER_DB_PASSWORD" postgis \
    psql -h 127.0.0.1 -q -U "$GEOSERVER_DB_USER" -d "$POSTGRES_DB" \
    -c "INSERT INTO public.parcels DEFAULT VALUES" 2>&1 || true)"
if printf '%s' "$db_denied" | grep -qi "permission denied"; then
    ok "Database role cannot write public.parcels"
else
    bad "Database role was not denied a write to public.parcels"
fi

db_note="$(dc exec -T -e PGPASSWORD="$GEOSERVER_DB_PASSWORD" postgis \
    psql -h 127.0.0.1 -q -tA -U "$GEOSERVER_DB_USER" -d "$POSTGRES_DB" \
    -c "INSERT INTO restricted.editor_notes (note, created_by, geom) VALUES ('db-check', 'verify', ST_GeomFromText('POINT(430000 3350000)', 26917)) RETURNING id" 2>/tmp/gk-db-note.err || true)"
db_note="$(printf '%s' "$db_note" | tr -d '[:space:]')"
if printf '%s' "$db_note" | grep -Eq '^[0-9]+$'; then
    dc exec -T -e PGPASSWORD="$GEOSERVER_DB_PASSWORD" postgis \
        psql -h 127.0.0.1 -q -U "$GEOSERVER_DB_USER" -d "$POSTGRES_DB" \
        -c "DELETE FROM restricted.editor_notes WHERE id = ${db_note}" >/dev/null
    ok "Database role can insert and delete editor notes"
else
    bad "Database role could not write restricted.editor_notes"
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

outsider_ca=""
if [ -n "${VERIFY_CA:-}" ]; then
    cp "$VERIFY_CA" "$ROOT/certs/verify-override.crt"
    chmod 644 "$ROOT/certs/verify-override.crt"
    outsider_ca="--cacert /certs/verify-override.crt"
elif [ "$TLS_MODE" = "local" ]; then
    outsider_ca="--cacert /certs/ca.crt"
fi
if [ "$TLS_MODE" = "letsencrypt" ]; then
    outsider_url="https://${VERIFY_NAME}/geoserver/web/"
    outsider_resolve="--resolve ${VERIFY_NAME}:443:${NGINX_EDGE_IP}"
else
    outsider_url="https://nginx/geoserver/web/"
    outsider_resolve=""
fi
# shellcheck disable=SC2086
outsider_code="$(dc --profile test run --rm --no-deps outsider \
    $outsider_ca $outsider_resolve -s -o /dev/null -w "%{http_code}" \
    "$outsider_url" || true)"
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
