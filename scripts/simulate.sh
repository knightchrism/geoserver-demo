#!/bin/sh
# Headless Locust run. Default length is two minutes (SIM_DURATION in .env).
# TLS_MODE=local trusts certs/ca.crt and calls https://nginx.
# TLS_MODE=letsencrypt trusts the system CA inside the Locust image and calls
# https://PUBLIC_HOST, which is pinned to the Nginx container. VERIFY_CA, when
# set, overrides either mode.
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/tls-client.sh"
need_env
tls_client_init

export SIM_TLS_NAME="sim.invalid"
export SIM_HOST="https://nginx"
export LOCUST_CA_FILE="/certs/ca.crt"
if [ "$TLS_MODE" = "letsencrypt" ]; then
    export SIM_TLS_NAME="$VERIFY_NAME"
    export SIM_HOST="https://${VERIFY_NAME}"
    export LOCUST_CA_FILE=""
fi
if [ -n "${VERIFY_CA:-}" ]; then
    cp "$VERIFY_CA" "$ROOT/certs/verify-override.crt"
    chmod 644 "$ROOT/certs/verify-override.crt"
    export LOCUST_CA_FILE="/certs/verify-override.crt"
fi

echo "[geoknight] simulating visitors for ${SIM_DURATION:-2m} (${TLS_MODE})"
dc --profile sim up --no-deps --force-recreate locust
echo "[geoknight] simulation finished"
