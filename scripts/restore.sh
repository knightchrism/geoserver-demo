#!/bin/sh
# Restore a backup made by scripts/backup.sh.
#
#   sh scripts/restore.sh --yes backups/geoknight-<stamp>.dump backups/geoserver-data-<stamp>.tar.gz
#
# GeoServer is stopped while the database and its data directory are replaced,
# then started again. Grants are reapplied from .env so the dump does not have
# to carry passwords or the database owner.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

yes_flag=""
dump=""
archive=""
for arg in "$@"; do
    case "$arg" in
        --yes) yes_flag=1 ;;
        *)
            if [ -z "$dump" ]; then
                dump="$arg"
            elif [ -z "$archive" ]; then
                archive="$arg"
            else
                die "Unexpected argument: $arg"
            fi
            ;;
    esac
done

if [ -z "$yes_flag" ] || [ -z "$dump" ] || [ -z "$archive" ]; then
    die "Usage: sh scripts/restore.sh --yes <geoknight-stamp.dump> <geoserver-data-stamp.tar.gz>"
fi
if [ ! -f "$dump" ] || [ ! -f "$archive" ]; then
    die "Both the dump and the GeoServer archive have to exist."
fi

project="${COMPOSE_PROJECT_NAME:-geoknight}"
volume="${project}_geoserver_data"
if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    die "Docker volume ${volume} was not found. Run: make up"
fi
if ! dc exec -T postgis pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    die "PostGIS is not ready. Run: make up"
fi

dump="$(CDPATH= cd -- "$(dirname "$dump")" && pwd)/$(basename "$dump")"
archive="$(CDPATH= cd -- "$(dirname "$archive")" && pwd)/$(basename "$archive")"
restart=0

cleanup() {
    status=$?
    if [ "$restart" -eq 1 ]; then
        dc start geoserver >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

if dc ps --status running -q geoserver | grep -q .; then
    echo "[geoknight] stopping GeoServer"
    restart=1
    dc stop geoserver >/dev/null
fi

echo "[geoknight] restoring the database"
dc exec -T postgis pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    --clean --if-exists --no-owner --no-acl < "$dump"

echo "[geoknight] restoring the GeoServer data directory"
docker run --rm \
    -v "${volume}:/opt/geoserver_data" \
    -v "$(dirname "$archive"):/backup:ro" \
    alpine:3.20 \
    sh -c 'find /opt/geoserver_data -mindepth 1 -delete && tar -C /opt/geoserver_data -xzf "/backup/'"$(basename "$archive")"'"'

sh "$ROOT/scripts/grant-app-role.sh"

if [ "$restart" -eq 1 ]; then
    echo "[geoknight] starting GeoServer"
    dc start geoserver >/dev/null
    restart=0
fi
echo "[geoknight] restore finished"
