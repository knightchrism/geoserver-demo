#!/bin/sh
# Checks the TLS client switch without starting the stack.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
die() {
    echo "DIE: $*" >&2
    exit 1
}
# shellcheck disable=SC1091
. "$ROOT/scripts/lib/tls-client.sh"

TLS_MODE=letsencrypt
PUBLIC_HOST=maps.example.com
LETSENCRYPT_DOMAIN=
HTTPS_PORT=443
VERIFY_CA=
tls_client_init
test -z "$CURL_CA_OPT"
test -z "$OPENSSL_CA_OPT"
test "$VERIFY_NAME" = "maps.example.com"
test "$VERIFY_BASE" = "https://maps.example.com"
test "$CURL_RESOLVE" = "--resolve maps.example.com:443:127.0.0.1"

VERIFY_CA="$ROOT/tests/fixtures/jax_demo_sample.sql"
tls_client_init
test "$CURL_CA_OPT" = "--cacert ${VERIFY_CA}"
test "$OPENSSL_CA_OPT" = "-CAfile ${VERIFY_CA}"

if ( TLS_MODE=letsencrypt; PUBLIC_HOST=localhost; LETSENCRYPT_DOMAIN=; VERIFY_CA=; tls_client_init ); then
    echo "letsencrypt without a public name should fail" >&2
    exit 1
fi

tmp="$(mktemp -d)"
mkdir -p "$tmp/certs"
printf 'not a cert\n' > "$tmp/certs/ca.crt"
ROOT="$tmp"
TLS_MODE=local
PUBLIC_HOST=localhost
VERIFY_CA=
HTTPS_PORT=8443
tls_client_init
test "$CURL_CA_OPT" = "--cacert ${tmp}/certs/ca.crt"
test "$VERIFY_BASE" = "https://127.0.0.1:8443"
test "$VERIFY_NAME" = "localhost"
test -z "$CURL_RESOLVE"
rm -rf "$tmp"

echo "tls client checks passed"
