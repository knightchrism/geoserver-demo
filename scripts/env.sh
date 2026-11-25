#!/bin/sh
# Write .env with random passwords. Does not overwrite an existing file.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -f .env ]; then
    echo "[geoknight] .env already exists. Leaving it alone."
    exit 0
fi

secret() {
    openssl rand -hex 18
}

sed \
    -e "s/^GEOSERVER_ADMIN_PASSWORD=.*/GEOSERVER_ADMIN_PASSWORD=$(secret)/" \
    -e "s/^GEOSERVER_MASTER_PASSWORD=.*/GEOSERVER_MASTER_PASSWORD=$(secret)/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(secret)/" \
    -e "s/^GEOSERVER_DB_PASSWORD=.*/GEOSERVER_DB_PASSWORD=$(secret)/" \
    -e "s/^VIEWER_PASSWORD=.*/VIEWER_PASSWORD=$(secret)/" \
    -e "s/^ANALYST_PASSWORD=.*/ANALYST_PASSWORD=$(secret)/" \
    -e "s/^EDITOR_PASSWORD=.*/EDITOR_PASSWORD=$(secret)/" \
    -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$(secret)/" \
    -e "s/^KEYCLOAK_ADMIN_PASSWORD=.*/KEYCLOAK_ADMIN_PASSWORD=$(secret)/" \
    .env.example > .env
chmod 600 .env
echo "[geoknight] Wrote .env with generated passwords. It stays on this computer."
