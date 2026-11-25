#!/bin/sh
# Create the login GeoServer uses. It is not the database owner.
# It can read every map table and write only restricted.editor_notes.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

user="${GEOSERVER_DB_USER:-}"
password="${GEOSERVER_DB_PASSWORD:-}"
if [ -z "$user" ] || [ -z "$password" ]; then
    die "Set GEOSERVER_DB_USER and GEOSERVER_DB_PASSWORD in .env."
fi
case "$user" in
    [A-Za-z_]*)
        case "$user" in
            *[!A-Za-z0-9_]*) die "GEOSERVER_DB_USER must be letters, digits, and underscores." ;;
        esac
        ;;
    *) die "GEOSERVER_DB_USER must start with a letter or underscore." ;;
esac
if [ "$user" = "${POSTGRES_USER:-}" ] || [ "$user" = "postgres" ]; then
    die "GEOSERVER_DB_USER must be a separate role, not the database owner."
fi

echo "[geoknight] ensuring PostGIS tables and the GeoServer database role"
dc exec -T postgis psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    < "$ROOT/sql/001_schema.sql" >/dev/null

dc exec -T postgis psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
    -v app_user="$user" \
    -v app_password="$password" \
    -v app_db="$POSTGRES_DB" <<'SQL'
SELECT format(
    CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'app_user')
         THEN 'ALTER ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE'
         ELSE 'CREATE ROLE %I WITH LOGIN PASSWORD %L NOSUPERUSER NOCREATEDB NOCREATEROLE'
    END,
    :'app_user', :'app_password')
\gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', :'app_db', :'app_user') \gexec
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE CREATE ON SCHEMA restricted FROM PUBLIC;
SELECT format('GRANT USAGE ON SCHEMA public, restricted TO %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', :'app_user') \gexec
SELECT format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA public FROM %I', :'app_user') \gexec
SELECT format('GRANT SELECT ON ALL TABLES IN SCHEMA restricted TO %I', :'app_user') \gexec
SELECT format('REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA restricted FROM %I', :'app_user') \gexec
SELECT format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE restricted.editor_notes TO %I', :'app_user') \gexec
SELECT format('GRANT USAGE, SELECT, UPDATE ON SEQUENCE restricted.editor_notes_id_seq TO %I', :'app_user') \gexec
SELECT format('ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO %I', :'app_user') \gexec
SQL

echo "[geoknight] GeoServer will connect as ${user} (read-only, except editor notes)"
