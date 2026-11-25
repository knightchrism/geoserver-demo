#!/bin/sh
# Replaces the stock GeoServer docker credential script.
#
# The stock script rewrites users.xml and roles.xml from the image template on
# every start. That would erase the viewer, analyst, and editor accounts.
# This copy still sets the admin login from the environment on first start.
# After scripts/configure.sh drops a marker file, later starts only refresh the
# admin password and leave every other account in place.
set -eu

if [ "${DEBUG:-}" != "" ]; then
    set -x
fi

GEOSERVER_DATA_DIR="${GEOSERVER_DATA_DIR:-/opt/geoserver_data}"
# The image default sometimes includes a trailing slash.
GEOSERVER_DATA_DIR=$(printf '%s' "$GEOSERVER_DATA_DIR" | sed 's:/*$::')

if [ ! -d "${GEOSERVER_DATA_DIR}/security" ]; then
    cp -a "${CATALINA_HOME}/webapps/geoserver/data/security" "${GEOSERVER_DATA_DIR}/"
fi

if [ "$#" -eq 2 ]; then
    GEOSERVER_ADMIN_USER="$1"
    GEOSERVER_ADMIN_PASSWORD="$2"
fi

GEOSERVER_ADMIN_USER="${GEOSERVER_ADMIN_USER:-admin}"
GEOSERVER_ADMIN_PASSWORD="${GEOSERVER_ADMIN_PASSWORD:-geoserver}"

if [ "$GEOSERVER_ADMIN_USER" = "admin" ] && [ "$GEOSERVER_ADMIN_PASSWORD" = "geoserver" ]; then
    echo "Refusing to start with the default GeoServer admin/geoserver login." >&2
    exit 1
fi

USERS_XML_ORIG="${CATALINA_HOME}/webapps/geoserver/data/security/usergroup/default/users.xml"
ROLES_XML_ORIG="${CATALINA_HOME}/webapps/geoserver/data/security/role/default/roles.xml"
USERS_XML="${GEOSERVER_DATA_DIR}/security/usergroup/default/users.xml"
ROLES_XML="${GEOSERVER_DATA_DIR}/security/role/default/roles.xml"
MARKER="${GEOSERVER_DATA_DIR}/security/geoknight-managed.txt"

make_hash() {
    new_password="$1"
    # jasypt-springsecurity*.jar does not contain the digest tool. Use the core jar.
    jar=$(find "${CATALINA_HOME}/webapps/geoserver/WEB-INF/lib" -name 'jasypt-[0-9]*.jar' | head -n 1)
    if [ -z "$jar" ]; then
        echo "Could not find the jasypt jar in GeoServer." >&2
        exit 1
    fi
    hash=$(java -classpath "$jar" org.jasypt.intf.cli.JasyptStringDigestCLI \
        digest.sh algorithm=SHA-256 saltSizeBytes=16 iterations=100000 \
        input="$new_password" verbose=0)
    if [ -z "$hash" ]; then
        echo "GeoServer password hash failed." >&2
        exit 1
    fi
    printf 'digest1:%s' "$hash"
}

PWD_HASH=$(make_hash "$GEOSERVER_ADMIN_PASSWORD")

if [ -f "$MARKER" ] && [ -f "$USERS_XML" ]; then
    echo "GeoKnight accounts already exist. Refreshing only the admin password."
    if ! grep -q "name=\"${GEOSERVER_ADMIN_USER}\"" "$USERS_XML"; then
        echo "Admin user ${GEOSERVER_ADMIN_USER} is not in users.xml." >&2
        echo "Delete ${MARKER} only if you intend to rebuild the security files from scratch." >&2
        exit 1
    fi
    # Base64 hashes contain "/" so the sed delimiter is "|".
    sed -i "s|\\(name=\"${GEOSERVER_ADMIN_USER}\" password=\"\\)[^\"]*|\\1${PWD_HASH}|" "$USERS_XML"
    echo "Admin password refreshed."
    exit 0
fi

echo "First start: writing the admin account from the image template."
sed -e "s/ name=\".*\" / name=\"${GEOSERVER_ADMIN_USER}\" /" \
    -e "s|password=\".*\"/|password=\"${PWD_HASH}\"/|" \
    "$USERS_XML_ORIG" > /tmp/users.xml
mv /tmp/users.xml "$USERS_XML"

sed -e "s/ username=\".*\"/ username=\"${GEOSERVER_ADMIN_USER}\"/" \
    "$ROLES_XML_ORIG" > /tmp/roles.xml
mv /tmp/roles.xml "$ROLES_XML"

echo "Admin account is ${GEOSERVER_ADMIN_USER}. Other accounts are added by scripts/configure.sh."
