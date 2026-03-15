#!/usr/bin/env bash
# =============================================================================
# docker/deploy.sh
#
# Smart deployment script that handles BOTH first-time setup AND updates:
#
#   First run:
#     1. Validates .env
#     2. Generates secrets
#     3. Renders config templates → ./data/
#     4. Starts all services (HTTP only – no SSL yet)
#     5. Waits for the user to confirm the server is working
#     6. Asks whether to request SSL certs via Let's Encrypt
#
#   Subsequent runs:
#     1. Pulls latest Docker images
#     2. Restarts services (existing config and data in ./data/ are preserved)
#
# Run from the docker/ directory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="${SCRIPT_DIR}/data"
ENV_FILE="${SCRIPT_DIR}/.env"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[deploy]${NC} $*"; }
success() { echo -e "${GREEN}[deploy]${NC} $*"; }
warn()    { echo -e "${YELLOW}[deploy]${NC} $*"; }
die()     { echo -e "${RED}[deploy]${NC} $*" >&2; exit 1; }

# ── Helpers ───────────────────────────────────────────────────────────────────
require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1. Please install it."; }
gen_secret()  { openssl rand -hex 32; }
gen_short()   { openssl rand -hex 16; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
require_cmd docker
require_cmd openssl
# Support both 'docker compose' (v2 plugin) and 'docker-compose' (standalone)
if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    die "docker compose / docker-compose not found. Install Docker with the Compose plugin."
fi

cd "${SCRIPT_DIR}"

# ── Load / validate .env ──────────────────────────────────────────────────────
[[ -f "${ENV_FILE}" ]] || {
    warn ".env not found."
    die "Run ./init-env.sh first to create your .env with all required secrets, then re-run deploy.sh"
}
# Export all variables so child processes (envsubst, docker, etc.) can see them.
# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

[[ -z "${DOMAIN:-}" ]]            && die "DOMAIN is not set in .env"
[[ "${DOMAIN}" == *"example.com"* ]] && die "DOMAIN still contains 'example.com'. Set a real domain in .env"
[[ -z "${LETSENCRYPT_EMAIL:-}" ]] && die "LETSENCRYPT_EMAIL is not set in .env"
[[ -z "${POSTGRES_PASSWORD:-}" || "${POSTGRES_PASSWORD}" == "CHANGE_ME"* ]] \
    && die "POSTGRES_PASSWORD is not set (or still the placeholder) in .env"

# ── Determine if this is a first-time deploy ──────────────────────────────────
FIRST_DEPLOY=false
[[ ! -f "${DATA_DIR}/synapse/homeserver.yaml" ]] && FIRST_DEPLOY=true

# ── Auto-fill secret placeholders in .env ────────────────────────────────────
if [[ "${FIRST_DEPLOY}" == true ]]; then
    info "First-time deployment detected – generating secrets…"
    # Replace placeholder secrets with real random values
    sed -i "s|^REGISTRATION_SHARED_SECRET=.*CHANGE_ME.*|REGISTRATION_SHARED_SECRET=$(gen_secret)|" "${ENV_FILE}"
    sed -i "s|^MACAROON_SECRET_KEY=.*CHANGE_ME.*|MACAROON_SECRET_KEY=$(gen_secret)|"               "${ENV_FILE}"
    sed -i "s|^FORM_SECRET=.*CHANGE_ME.*|FORM_SECRET=$(gen_secret)|"                               "${ENV_FILE}"
    sed -i "s|^COTURN_SECRET=.*CHANGE_ME.*|COTURN_SECRET=$(gen_secret)|"                           "${ENV_FILE}"
    sed -i "s|^LIVEKIT_API_KEY=.*CHANGE_ME.*|LIVEKIT_API_KEY=$(gen_short)|"                       "${ENV_FILE}"
    sed -i "s|^LIVEKIT_API_SECRET=.*CHANGE_ME.*|LIVEKIT_API_SECRET=$(gen_secret)|"                "${ENV_FILE}"
    # Reload after edits (keep export so envsubst sees the new values)
    # shellcheck disable=SC1090
    set -a; source "${ENV_FILE}"; set +a
    success "Secrets generated and saved to .env"
fi

# ── Create data directories ────────────────────────────────────────────────────
mkdir -p \
    "${DATA_DIR}/synapse" \
    "${DATA_DIR}/element" \
    "${DATA_DIR}/coturn" \
    "${DATA_DIR}/livekit" \
    "${DATA_DIR}/lk-jwt" \
    "${DATA_DIR}/certbot/www"

# ── Render config templates (only if not already present) ─────────────────────
render_template() {
    local src="$1" dst="$2"
    if [[ -f "${dst}" ]]; then
        warn "Skipping $(basename "${dst}") – already exists (preserving existing config)."
        return
    fi
    info "Rendering $(basename "${dst}") from template…"
    envsubst < "${src}" > "${dst}"
    success "  → ${dst}"
}

if [[ "${FIRST_DEPLOY}" == true ]]; then
    render_template "${SCRIPT_DIR}/config/synapse/homeserver.yaml.template"  "${DATA_DIR}/synapse/homeserver.yaml"
    render_template "${SCRIPT_DIR}/config/synapse/log.config.template"       "${DATA_DIR}/synapse/log.config"
    render_template "${SCRIPT_DIR}/config/element/config.json.template"      "${DATA_DIR}/element/config.json"
    render_template "${SCRIPT_DIR}/config/coturn/turnserver.conf.template"   "${DATA_DIR}/coturn/turnserver.conf"
    render_template "${SCRIPT_DIR}/config/livekit/livekit.yaml.template"     "${DATA_DIR}/livekit/livekit.yaml"
    render_template "${SCRIPT_DIR}/config/lk-jwt/config.yaml.template"       "${DATA_DIR}/lk-jwt/config.yaml"
fi

# ── Generate Synapse signing key (only on first deploy) ───────────────────────
if [[ "${FIRST_DEPLOY}" == true && ! -f "${DATA_DIR}/synapse/${DOMAIN}.signing.key" ]]; then
    info "Generating Synapse signing key…"
    docker run --rm \
        -v "${DATA_DIR}/synapse:/data" \
        -e "SYNAPSE_SERVER_NAME=${DOMAIN}" \
        -e "SYNAPSE_REPORT_STATS=no" \
        matrixdotorg/synapse:latest generate 2>/dev/null | tail -5
    success "Signing key generated."
fi

# ── Pull / build images ───────────────────────────────────────────────────────
info "Pulling latest images (this may take a few minutes)…"
${DC} pull --quiet 2>/dev/null || true
info "Building custom nginx image…"
${DC} build nginx --quiet

# ── Start services ────────────────────────────────────────────────────────────
info "Starting services (SSL_ENABLED=${SSL_ENABLED:-false})…"
${DC} up -d --remove-orphans

# ── First-deploy: human confirmation gate ─────────────────────────────────────
if [[ "${FIRST_DEPLOY}" == true ]]; then
    echo
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║            ⚠  First Deployment – Action Required  ⚠         ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo "  Your Matrix server is starting up in HTTP-only mode."
    echo
    echo "  Before requesting SSL certificates from Let's Encrypt, please verify:"
    echo
    echo "  1. Your domain '${DOMAIN}' has a DNS A record pointing to this machine's"
    echo "     public IP address (see docs/domain-setup.md)."
    echo "  2. Ports 80 and 443 are forwarded from your router to this machine"
    echo "     (see docs/router-setup.md)."
    echo "  3. The Matrix server responds correctly:"
    echo "       curl http://${DOMAIN}/_matrix/client/versions"
    echo
    echo "  When you are satisfied with the above, run:"
    echo
    echo -e "    ${YELLOW}./init-letsencrypt.sh${NC}"
    echo
    echo "  to obtain SSL certificates. This only needs to be done ONCE."
    echo "  ⚠  Let's Encrypt rate-limits certificate requests (5 per domain per week)."
    echo "     Do NOT run init-letsencrypt.sh repeatedly."
    echo

    # Register a first admin user
    echo "─────────────────────────────────────────────────────────────────"
    read -rp "Create an admin user now? [Y/n] " CREATE_USER
    if [[ "${CREATE_USER,,}" != "n" ]]; then
        read -rp "  Admin username [admin]: " ADMIN_USER
        ADMIN_USER="${ADMIN_USER:-admin}"
        read -rsp "  Admin password: " ADMIN_PASS
        echo
        # Wait for Synapse to become healthy before registering a user.
        info "Waiting for Synapse to be ready…"
        SYNAPSE_CONTAINER="$(${DC} ps -q synapse)"
        for _i in $(seq 1 24); do
            if docker exec "${SYNAPSE_CONTAINER}" curl -sf http://localhost:8008/health >/dev/null 2>&1; then
                break
            fi
            [[ "${_i}" -eq 24 ]] && { warn "Synapse did not become healthy in time. Try user creation manually."; break; }
            sleep 5
        done
        # Use -i only (not -t) so this works in both interactive and piped contexts
        docker exec -i "${SYNAPSE_CONTAINER}" \
            register_new_matrix_user \
                -c /data/homeserver.yaml \
                -u "${ADMIN_USER}" \
                -p "${ADMIN_PASS}" \
                -a \
                http://localhost:8008 \
            && success "Admin user '@${ADMIN_USER}:${DOMAIN}' created." \
            || warn "Could not create user automatically. See README for manual steps."
    fi
else
    success "Update complete. Existing config and data were preserved."
    echo
    echo "  Services running:"
    ${DC} ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || ${DC} ps
fi

echo
success "Deployment finished."
[[ "${SSL_ENABLED:-false}" == "true" ]] && _proto="https" || _proto="http"
echo "  Matrix API   →  ${_proto}://${DOMAIN}/_matrix/"
echo "  Element Web  →  ${_proto}://${DOMAIN}/"
echo
