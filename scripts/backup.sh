#!/bin/sh
# Dump PostGIS and archive the GeoServer data directory.
#
# Writes two files under BACKUP_DIR (default: backups/):
#   geoknight-<utc-stamp>.dump              pg_dump custom format, no owners or grants
#   geoserver-data-<utc-stamp>.tar.gz       the GeoServer data volume
#
# Retention:
#   BACKUP_RETENTION_DAYS   delete archives older than this many days (default 14)
#   BACKUP_KEEP             then keep at most this many of each kind (default 14)
#
# GeoServer is stopped for the archive and started again afterward. PostGIS stays up.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

backup_dir="${BACKUP_DIR:-$ROOT/backups}"
days="${BACKUP_RETENTION_DAYS:-14}"
keep="${BACKUP_KEEP:-14}"
case "$days" in
    ''|*[!0-9]*) die "BACKUP_RETENTION_DAYS must be a number of days." ;;
esac
case "$keep" in
    ''|*[!0-9]*) die "BACKUP_KEEP must be a number." ;;
esac

mkdir -p "$backup_dir"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dump="$backup_dir/geoknight-${stamp}.dump"
archive="$backup_dir/geoserver-data-${stamp}.tar.gz"
project="${COMPOSE_PROJECT_NAME:-geoknight}"
volume="${project}_geoserver_data"
restart=0

cleanup() {
    status=$?
    if [ "$restart" -eq 1 ]; then
        dc start geoserver >/dev/null 2>&1 || true
    fi
    if [ "$status" -ne 0 ]; then
        rm -f "$dump" "$archive"
    fi
    exit "$status"
}
trap cleanup EXIT

if ! dc exec -T postgis pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
    die "PostGIS is not ready. Run: make up"
fi
if ! docker volume inspect "$volume" >/dev/null 2>&1; then
    die "Docker volume ${volume} was not found. Run: make up"
fi

if dc ps --status running -q geoserver | grep -q .; then
    echo "[geoknight] stopping GeoServer for a consistent archive"
    restart=1
    dc stop geoserver >/dev/null
fi

echo "[geoknight] dumping ${POSTGRES_DB}"
dc exec -T postgis pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -Fc --no-owner --no-acl > "$dump"

echo "[geoknight] archiving the GeoServer data directory"
docker run --rm \
    -v "${volume}:/opt/geoserver_data:ro" \
    -v "${backup_dir}:/backup" \
    alpine:3.20 \
    tar -C /opt/geoserver_data -czf "/backup/$(basename "$archive")" .

if [ "$restart" -eq 1 ]; then
    echo "[geoknight] starting GeoServer"
    dc start geoserver >/dev/null
    restart=0
fi

find "$backup_dir" -type f \( -name 'geoknight-*.dump' -o -name 'geoserver-data-*.tar.gz' \) \
    -mtime "+${days}" -delete

prune_kind() {
    pattern="$1"
    n=0
    # Names produced by this script have no spaces.
    # shellcheck disable=SC2086
    for file in $(ls -1t $backup_dir/$pattern 2>/dev/null || true); do
        n=$((n + 1))
        if [ "$n" -gt "$keep" ]; then
            rm -f "$file"
        fi
    done
}
prune_kind 'geoknight-*.dump'
prune_kind 'geoserver-data-*.tar.gz'

echo "[geoknight] wrote ${dump}"
echo "[geoknight] wrote ${archive}"
echo "[geoknight] retention is ${days} days and ${keep} archives of each kind"
