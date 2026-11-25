# Shared TLS client settings for smoke tests and the visitor simulation.
# Source this after scripts/lib/common.sh. Then call tls_client_init.
#
# TLS_MODE=local trusts certs/ca.crt and talks to 127.0.0.1.
# TLS_MODE=letsencrypt trusts the system certificate store and uses PUBLIC_HOST
# (or LETSENCRYPT_DOMAIN) so the name matches the public certificate.
# VERIFY_CA, when set, is the CA file for either mode.

tls_client_init() {
    TLS_MODE="${TLS_MODE:-local}"
    HTTPS_PORT="${HTTPS_PORT:-443}"
    case "$TLS_MODE" in
        local|letsencrypt) ;;
        *) die "TLS_MODE must be local or letsencrypt (got ${TLS_MODE})." ;;
    esac

    CURL_CA_OPT=""
    OPENSSL_CA_OPT=""
    if [ -n "${VERIFY_CA:-}" ]; then
        if [ ! -f "$VERIFY_CA" ]; then
            die "VERIFY_CA does not point at a file: ${VERIFY_CA}"
        fi
        CURL_CA_OPT="--cacert ${VERIFY_CA}"
        OPENSSL_CA_OPT="-CAfile ${VERIFY_CA}"
    elif [ "$TLS_MODE" = "local" ]; then
        if [ ! -f "$ROOT/certs/ca.crt" ]; then
            die "Missing certs/ca.crt. Run: make up"
        fi
        CURL_CA_OPT="--cacert ${ROOT}/certs/ca.crt"
        OPENSSL_CA_OPT="-CAfile ${ROOT}/certs/ca.crt"
    fi

    if [ "$TLS_MODE" = "letsencrypt" ]; then
        VERIFY_NAME="${PUBLIC_HOST:-}"
        if [ -z "$VERIFY_NAME" ] || [ "$VERIFY_NAME" = "localhost" ]; then
            VERIFY_NAME="${LETSENCRYPT_DOMAIN:-}"
        fi
        if [ -z "$VERIFY_NAME" ] || [ "$VERIFY_NAME" = "localhost" ]; then
            die "TLS_MODE=letsencrypt needs PUBLIC_HOST or LETSENCRYPT_DOMAIN set to the name on the certificate."
        fi
        if [ "$HTTPS_PORT" = "443" ]; then
            VERIFY_BASE="https://${VERIFY_NAME}"
        else
            VERIFY_BASE="https://${VERIFY_NAME}:${HTTPS_PORT}"
        fi
        CURL_RESOLVE="--resolve ${VERIFY_NAME}:${HTTPS_PORT}:127.0.0.1"
    else
        VERIFY_NAME="localhost"
        if [ "$HTTPS_PORT" = "443" ]; then
            VERIFY_BASE="https://127.0.0.1"
        else
            VERIFY_BASE="https://127.0.0.1:${HTTPS_PORT}"
        fi
        CURL_RESOLVE=""
    fi

    # These match the addresses in docker-compose.yml.
    NGINX_FRONTEND_IP="172.28.10.10"
    NGINX_EDGE_IP="172.28.12.10"
}
