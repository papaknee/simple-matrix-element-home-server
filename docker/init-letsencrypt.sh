#!/usr/bin/env bash
# =============================================================================
# docker/init-letsencrypt.sh
#
# One-time script to obtain SSL certificates from Let's Encrypt.
# Run ONLY ONCE after you have:
#   1. Verified your DNS A record is correct for your domain
#   2. Verified port 80 is reachable from the internet (for the ACME challenge)
#   3. Confirmed the server works in HTTP-only mode (deploy.sh first)
#
# ⚠  Let's Encrypt RATE LIMITS: you can only request 5 certificates per
#    registered domain per week. Do NOT run this script repeatedly.
#    Use the --staging flag to test first (no rate limits but not trusted):
#      STAGING=1 ./init-letsencrypt.sh
#
# After this script succeeds, set SSL_ENABLED=true in .env and run:
#   ./deploy.sh     (or ./update.sh)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[ssl]${NC}    $*"; }
success() { echo -e "${GREEN}[ssl]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[ssl]${NC}    $*"; }
die()     { echo -e "${RED}[ssl]${NC}    $*" >&2; exit 1; }

cd "${SCRIPT_DIR}"

[[ -f .env ]] || die ".env not found. Run deploy.sh first."
# shellcheck disable=SC1091
source .env

[[ -z "${DOMAIN:-}" ]]            && die "DOMAIN is not set in .env"
[[ -z "${LETSENCRYPT_EMAIL:-}" ]] && die "LETSENCRYPT_EMAIL is not set in .env"

if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    die "docker compose not found."
fi

# ── Safety checks ─────────────────────────────────────────────────────────────
CERT_PATH="${DATA_DIR}/letsencrypt/live/${DOMAIN}"
# We actually use the named volume – check via Docker
# Use docker compose to check via the certbot container (uses the named volume correctly)
CERT_EXISTS=$(${DC} --profile certbot run --rm --no-deps certbot \
    sh -c "[ -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ] && echo yes || echo no" 2>/dev/null || echo "no")

if [[ "${CERT_EXISTS}" == "yes" ]]; then
    warn "Certificate for ${DOMAIN} already exists!"
    read -rp "  Renew / replace it? (This counts against rate limits) [y/N] " CONFIRM
    [[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo
echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${YELLOW}║           Let's Encrypt Certificate Request                 ║${NC}"
echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
echo
echo "  Domain : ${DOMAIN}"
echo "  Email  : ${LETSENCRYPT_EMAIL}"
echo
warn "RATE LIMIT: 5 certificates per domain per week."
warn "Use STAGING=1 ./init-letsencrypt.sh to test without consuming your quota."
echo
read -rp "  Proceed with LIVE certificate request? [y/N] " CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || { echo "Aborted."; exit 0; }

# ── Staging flag ──────────────────────────────────────────────────────────────
STAGING_ARG=""
if [[ "${STAGING:-0}" == "1" ]]; then
    warn "Using Let's Encrypt STAGING environment (certificates will NOT be trusted by browsers)."
    STAGING_ARG="--staging"
fi

# ── Ensure nginx is running to serve the ACME challenge ───────────────────────
info "Ensuring nginx is running for the ACME HTTP-01 challenge…"
${DC} up -d nginx

# Give nginx a moment to start
sleep 3

# ── Run certbot ───────────────────────────────────────────────────────────────
info "Requesting certificate for ${DOMAIN} and www.${DOMAIN}…"
${DC} --profile certbot run --rm certbot \
    certonly \
    --webroot \
    --webroot-path=/var/www/certbot \
    --email "${LETSENCRYPT_EMAIL}" \
    --agree-tos \
    --no-eff-email \
    ${STAGING_ARG} \
    -d "${DOMAIN}" \
    -d "www.${DOMAIN}"

success "Certificate obtained!"

# ── Enable SSL in .env ────────────────────────────────────────────────────────
info "Setting SSL_ENABLED=true in .env…"
sed -i "s|^SSL_ENABLED=.*|SSL_ENABLED=true|" .env
# shellcheck disable=SC1091
source .env

# ── Restart nginx with SSL config ─────────────────────────────────────────────
info "Restarting nginx with SSL configuration…"
${DC} up -d nginx

# ── Set up automatic renewal ──────────────────────────────────────────────────
info "Setting up automatic certificate renewal (cron job)…"
CRON_CMD="0 3 * * * cd ${SCRIPT_DIR} && ${DC} --profile certbot run --rm certbot renew --quiet && ${DC} exec nginx nginx -s reload"
(crontab -l 2>/dev/null | grep -v "certbot renew"; echo "${CRON_CMD}") | crontab -
success "Cron job added: certificate will auto-renew at 3 AM daily."

echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}  SSL setup complete!                                ${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
echo "  Matrix API   →  https://${DOMAIN}/_matrix/"
echo "  Element Web  →  https://${DOMAIN}/"
echo
echo "  Next steps:"
echo "   • Update your Matrix client to use 'https://${DOMAIN}'"
echo "   • Federation should now work from other Matrix servers"
echo
