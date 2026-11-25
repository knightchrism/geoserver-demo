#!/bin/sh
# Headless Locust run. Default length is two minutes (SIM_DURATION in .env).
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_env
if [ ! -f "$ROOT/certs/ca.crt" ]; then
    die "Missing certs/ca.crt. Run: make up"
fi
echo "[geoknight] simulating visitors for ${SIM_DURATION:-2m}"
dc --profile sim up --no-deps --force-recreate locust
echo "[geoknight] simulation finished"
