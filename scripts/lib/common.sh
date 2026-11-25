#!/bin/sh
# Shared helpers. Shell scripts in this folder source this file.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ -f "$ROOT/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$ROOT/.env"
    set +a
fi

dc() {
    docker compose "$@"
}

die() {
    echo "[geoknight] $*" >&2
    exit 1
}

need_env() {
    if [ ! -f "$ROOT/.env" ]; then
        die "Missing .env. Run: make env"
    fi
}

wait_for_url() {
    url="$1"
    label="$2"
    attempts="${3:-60}"
    n=0
    while [ "$n" -lt "$attempts" ]; do
        if curl -fsS -o /dev/null --max-time 5 "$url"; then
            echo "[geoknight] $label is up"
            return 0
        fi
        n=$((n + 1))
        sleep 3
    done
    die "Timed out waiting for $label ($url)"
}
