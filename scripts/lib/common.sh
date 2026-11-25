#!/bin/sh
# Shared helpers. Shell scripts in this folder source this file.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Load .env without replacing variables the caller already set. That is what
# lets VERIFY_CA or TLS_MODE on the command line override the file.
if [ -f "$ROOT/.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
        esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            *[!A-Za-z0-9_]*|[0-9]*) continue ;;
        esac
        case "$value" in
            \"*\") value=${value#\"}; value=${value%\"} ;;
            \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        isset=$(eval "printf '%s' \"\${$key+set}\"")
        if [ "$isset" = "set" ]; then
            continue
        fi
        export "$key=$value"
    done < "$ROOT/.env"
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
