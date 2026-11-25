#!/bin/sh
# Load the Jacksonville data folder into PostGIS.
#
# Expected layout (these files are not committed):
#   aoi.geojson
#   aoi_26917.geojson
#   vector/gpkg/{parcels,roads,mirta_fl,tracts}.gpkg
#   vector/sql/{parcels,roads,mirta_fl,tracts}.sql
#   imagery/naip_2025_jax_aoi_cog.tif
#   elevation/dem_3dep_aoi_cog.tif
#   elevation/hillshade_aoi_cog.tif
#   styles/dem_colorramp.sld
#   styles/hillshade.sld
#
# The SQL files are pg_dump-style scripts. They create tables in the jax_demo
# schema and already use CREATE TABLE IF NOT EXISTS. Column names are lowercase
# (re, sitename). The loader moves jax_demo to public, does not add a second
# IF NOT EXISTS, and can be run again. A GeoPackage is loaded with ogr2ogr
# when the SQL file is missing. Rasters stay on disk for GeoServer.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

DATA_DIR="$ROOT/data"
mkdir -p "$DATA_DIR/vector/gpkg" "$DATA_DIR/vector/sql" "$DATA_DIR/imagery" \
    "$DATA_DIR/elevation" "$DATA_DIR/styles"

has_layer() {
    name="$1"
    [ -f "$DATA_DIR/vector/sql/${name}.sql" ] || [ -f "$DATA_DIR/vector/gpkg/${name}.gpkg" ]
}

if ! has_layer roads || ! has_layer parcels || ! has_layer mirta_fl || ! has_layer tracts \
    || [ ! -f "$DATA_DIR/imagery/naip_2025_jax_aoi_cog.tif" ] \
    || [ ! -f "$DATA_DIR/elevation/dem_3dep_aoi_cog.tif" ] \
    || [ ! -f "$DATA_DIR/elevation/hillshade_aoi_cog.tif" ]; then
    echo "[geoknight] data folder is incomplete. Building the small offline sample in the same layout."
    python3 "$ROOT/scripts/fetch_data.py" --synthetic
fi

echo "[geoknight] waiting for PostGIS"
n=0
while [ "$n" -lt 40 ]; do
    if dc exec -T postgis pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
        break
    fi
    n=$((n + 1))
    sleep 2
done

echo "[geoknight] applying empty editor-notes table"
dc exec -T postgis psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < "$ROOT/sql/001_schema.sql"

load_sql() {
    name="$1"
    rewritten="$(mktemp)"
    echo "[geoknight] loading vector/sql/${name}.sql"
    python3 "$ROOT/scripts/rewrite_sql.py" "$DATA_DIR/vector/sql/${name}.sql" > "$rewritten"
    dc exec -T postgis psql -v ON_ERROR_STOP=1 -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$rewritten"
    rm -f "$rewritten"
}

load_gpkg() {
    name="$1"
    geometry="$2"
    echo "[geoknight] loading vector/gpkg/${name}.gpkg into public.${name}"
    ogr2ogr -f PostgreSQL \
        "PG:host=127.0.0.1 port=${POSTGIS_PORT:-5432} dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}" \
        "$DATA_DIR/vector/gpkg/${name}.gpkg" \
        -nln "$name" \
        -lco SCHEMA=public \
        -lco GEOMETRY_NAME=geom \
        -lco FID=id \
        -lco SPATIAL_INDEX=GIST \
        -lco LAUNDER=YES \
        -nlt "$geometry" \
        -t_srs EPSG:26917 \
        -overwrite
}

load_layer() {
    name="$1"
    geometry="$2"
    if [ -f "$DATA_DIR/vector/sql/${name}.sql" ]; then
        load_sql "$name"
    elif [ -f "$DATA_DIR/vector/gpkg/${name}.gpkg" ]; then
        if ! command -v ogr2ogr >/dev/null 2>&1; then
            die "ogr2ogr is not installed, and vector/sql/${name}.sql is missing."
        fi
        load_gpkg "$name" "$geometry"
    else
        die "Missing vector/sql/${name}.sql and vector/gpkg/${name}.gpkg"
    fi
}

load_layer roads PROMOTE_TO_MULTI
load_layer tracts PROMOTE_TO_MULTI
load_layer parcels PROMOTE_TO_MULTI
load_layer mirta_fl PROMOTE_TO_MULTI

if [ -f "$DATA_DIR/aoi_26917.geojson" ]; then
    if ! command -v ogr2ogr >/dev/null 2>&1; then
        echo "[geoknight] skipping aoi_26917.geojson because ogr2ogr is not installed"
    else
        echo "[geoknight] loading aoi_26917.geojson"
        ogr2ogr -f PostgreSQL \
            "PG:host=127.0.0.1 port=${POSTGIS_PORT:-5432} dbname=${POSTGRES_DB} user=${POSTGRES_USER} password=${POSTGRES_PASSWORD}" \
            "$DATA_DIR/aoi_26917.geojson" \
            -nln aoi \
            -lco SCHEMA=public \
            -lco GEOMETRY_NAME=geom \
            -lco FID=id \
            -lco SPATIAL_INDEX=GIST \
            -lco LAUNDER=YES \
            -nlt PROMOTE_TO_MULTI \
            -a_srs EPSG:26917 \
            -overwrite
    fi
fi

sh "$ROOT/scripts/grant-app-role.sh"

echo "[geoknight] rasters stay on disk for GeoServer:"
echo "  imagery/naip_2025_jax_aoi_cog.tif"
echo "  elevation/dem_3dep_aoi_cog.tif"
echo "  elevation/hillshade_aoi_cog.tif"
echo "[geoknight] database load finished"
