#!/bin/sh
# =============================================================================
# docker/nginx/entrypoint.sh
# Generates the nginx config at container start based on SSL_ENABLED.
# =============================================================================
set -e

DOMAIN="${DOMAIN:-localhost}"
SSL_ENABLED="${SSL_ENABLED:-false}"
CONF_DIR="/etc/nginx/conf.d"
TMPL_DIR="/etc/nginx/templates"

mkdir -p "${CONF_DIR}"
rm -f "${CONF_DIR}"/*.conf

if [ "${SSL_ENABLED}" = "true" ]; then
    # Check that the certificate actually exists before switching to SSL mode
    CERT="/etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
    if [ -f "${CERT}" ]; then
        echo "[nginx] SSL_ENABLED=true and certificate found – using HTTPS config"
        envsubst '${DOMAIN}' < "${TMPL_DIR}/matrix-ssl.conf.template"  > "${CONF_DIR}/matrix.conf"
        envsubst '${DOMAIN}' < "${TMPL_DIR}/element-ssl.conf.template" > "${CONF_DIR}/element.conf"
        envsubst '${DOMAIN}' < "${TMPL_DIR}/livekit-ssl.conf.template" > "${CONF_DIR}/livekit.conf"
    else
        echo "[nginx] WARNING: SSL_ENABLED=true but certificate not found at ${CERT}"
        echo "[nginx] Falling back to HTTP-only config. Run init-letsencrypt.sh to get certs."
        envsubst '${DOMAIN}' < "${TMPL_DIR}/matrix-http.conf.template"  > "${CONF_DIR}/matrix.conf"
        envsubst '${DOMAIN}' < "${TMPL_DIR}/element-http.conf.template" > "${CONF_DIR}/element.conf"
        envsubst '${DOMAIN}' < "${TMPL_DIR}/livekit-http.conf.template" > "${CONF_DIR}/livekit.conf"
    fi
else
    echo "[nginx] SSL_ENABLED=false – using HTTP-only config"
    envsubst '${DOMAIN}' < "${TMPL_DIR}/matrix-http.conf.template"  > "${CONF_DIR}/matrix.conf"
    envsubst '${DOMAIN}' < "${TMPL_DIR}/element-http.conf.template" > "${CONF_DIR}/element.conf"
    envsubst '${DOMAIN}' < "${TMPL_DIR}/livekit-http.conf.template" > "${CONF_DIR}/livekit.conf"
fi

echo "[nginx] Starting nginx…"
exec nginx -g "daemon off;"
