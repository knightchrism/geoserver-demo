#!/bin/sh
# Stop startup when passwords are still the published placeholders.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env

fail=0
check_password() {
    name="$1"
    value="$(eval "printf '%s' \"\${$name:-}\"")"
    if [ -z "$value" ]; then
        echo "Missing $name in .env" >&2
        fail=1
        return
    fi
    if printf '%s' "$value" | grep -q "change-me"; then
        echo "$name still contains a change-me placeholder." >&2
        fail=1
    fi
    if [ "$value" = "geoserver" ] || [ "$value" = "admin" ] || [ "$value" = "postgres" ]; then
        echo "$name is a well-known default. Choose a different password." >&2
        fail=1
    fi
    if [ "${#value}" -lt 12 ]; then
        echo "$name must be at least 12 characters." >&2
        fail=1
    fi
}

check_password GEOSERVER_ADMIN_PASSWORD
check_password GEOSERVER_MASTER_PASSWORD
check_password POSTGRES_PASSWORD
check_password VIEWER_PASSWORD
check_password ANALYST_PASSWORD
check_password EDITOR_PASSWORD
check_password GRAFANA_ADMIN_PASSWORD
check_password GEOSERVER_DB_PASSWORD

if [ -z "${GEOSERVER_DB_USER:-}" ]; then
    echo "Missing GEOSERVER_DB_USER in .env" >&2
    fail=1
elif [ "$GEOSERVER_DB_USER" = "${POSTGRES_USER:-}" ] || [ "$GEOSERVER_DB_USER" = "postgres" ]; then
    echo "GEOSERVER_DB_USER must be a separate role, not the database owner." >&2
    fail=1
fi

if [ "${GEOSERVER_ADMIN_USER:-admin}" = "admin" ]; then
    echo "GEOSERVER_ADMIN_USER is still admin. Use a different username, for example gkadmin." >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "Refusing to start. Edit .env, or run: make env" >&2
    exit 1
fi

echo "[geoknight] .env looks ready"
