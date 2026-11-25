#!/bin/sh
set -eu
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
dc --profile sim --profile test --profile letsencrypt --profile oidc down
echo "[geoknight] stopped. Data volumes were kept. Use 'make reset' to delete them."
