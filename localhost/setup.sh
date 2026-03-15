#!/usr/bin/env bash
# =============================================================================
# localhost/setup.sh
# Sets up a local (dev) Matrix Synapse + Element Web environment on Debian 13.
# No SSL, no Docker – perfect for testing before promoting to production.
# Run as root or with sudo.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ELEMENT_VERSION="${ELEMENT_VERSION:-1.11.91}"
ELEMENT_INSTALL_DIR="/var/www/element"
SYNAPSE_CONFIG_DIR="/etc/matrix-synapse"
SYNAPSE_DATA_DIR="/var/lib/matrix-synapse"
SYNAPSE_SERVER_NAME="${SYNAPSE_SERVER_NAME:-localhost}"

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Please run as root: sudo $0"

info "=== Simple Matrix Home Server – Localhost Dev Setup ==="
echo
info "This script will install:"
echo "  • Matrix Synapse  (port 8008)"
echo "  • Element Web     (port 8080)"
echo "  • nginx           (reverse proxy for Element)"
echo
warn "This is a DEV environment. No SSL, no Docker."
warn "Server name will be: ${SYNAPSE_SERVER_NAME}"
echo

# ── 1. System packages ────────────────────────────────────────────────────────
info "Updating package lists…"
apt-get update -qq

info "Installing prerequisites…"
apt-get install -y -qq \
    curl wget gnupg apt-transport-https lsb-release \
    nginx python3 python3-pip python3-venv \
    sqlite3 libjpeg-dev libffi-dev libssl-dev \
    libxslt1-dev zlib1g-dev build-essential

# ── 2. Matrix Synapse (from matrix.org Debian repo) ───────────────────────────
DEBIAN_CODENAME="$(lsb_release -sc)"
info "Adding Matrix.org apt repository (codename: ${DEBIAN_CODENAME})…"
wget -qO /usr/share/keyrings/matrix-org-archive-keyring.gpg \
    https://packages.matrix.org/debian/matrix-org-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/matrix-org-archive-keyring.gpg] \
https://packages.matrix.org/debian/ ${DEBIAN_CODENAME} main" \
    > /etc/apt/sources.list.d/matrix-org.list

apt-get update -qq
apt-get install -y -qq matrix-synapse-py3 || {
    warn "matrix-synapse-py3 not available for ${DEBIAN_CODENAME}, falling back to pip install…"
    _install_synapse_pip
}

# ── 2a. Fallback: install Synapse via pip in a virtualenv ─────────────────────
_install_synapse_pip() {
    local venv="/opt/synapse-venv"
    python3 -m venv "${venv}"
    "${venv}/bin/pip" install --quiet --upgrade pip
    "${venv}/bin/pip" install --quiet "matrix-synapse[all]"
    ln -sf "${venv}/bin/synapse_homeserver" /usr/local/bin/synapse_homeserver
    ln -sf "${venv}/bin/register_new_matrix_user" /usr/local/bin/register_new_matrix_user
    mkdir -p "${SYNAPSE_CONFIG_DIR}" "${SYNAPSE_DATA_DIR}"
}

# ── 3. Generate Synapse config ─────────────────────────────────────────────────
info "Generating Synapse configuration for server_name='${SYNAPSE_SERVER_NAME}'…"

if [[ -f "${SYNAPSE_CONFIG_DIR}/homeserver.yaml" ]]; then
    warn "homeserver.yaml already exists – skipping generation (delete it to regenerate)."
else
    # Generate with built-in generator
    python3 -m synapse.app.homeserver \
        --server-name "${SYNAPSE_SERVER_NAME}" \
        --config-path "${SYNAPSE_CONFIG_DIR}/homeserver.yaml" \
        --generate-config \
        --report-stats=no 2>/dev/null || \
    synapse_homeserver \
        --server-name "${SYNAPSE_SERVER_NAME}" \
        --config-path "${SYNAPSE_CONFIG_DIR}/homeserver.yaml" \
        --generate-config \
        --report-stats=no

    # Patch the generated config for local dev
    python3 - "${SYNAPSE_CONFIG_DIR}/homeserver.yaml" <<'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    text = f.read()

# Enable open registration so we can create test accounts easily
text = re.sub(r'^#?\s*enable_registration:.*$',
              'enable_registration: true', text, flags=re.MULTILINE)
text = re.sub(r'^#?\s*enable_registration_without_verification:.*$',
              'enable_registration_without_verification: true', text, flags=re.MULTILINE)

# Bind to localhost only (security for dev)
text = re.sub(r'bind_addresses:.*\n.*- .*\n',
              'bind_addresses: [\'127.0.0.1\']\n', text, flags=re.MULTILINE)

with open(path, 'w') as f:
    f.write(text)
print("Config patched for local dev.")
PYEOF

    success "Synapse config written to ${SYNAPSE_CONFIG_DIR}/homeserver.yaml"
fi

# ── 4. Fix ownership ──────────────────────────────────────────────────────────
chown -R matrix-synapse:matrix-synapse "${SYNAPSE_DATA_DIR}" "${SYNAPSE_CONFIG_DIR}" \
    2>/dev/null || true

# ── 5. Download & install Element Web ────────────────────────────────────────
ELEMENT_ARCHIVE="element-v${ELEMENT_VERSION}.tar.gz"
ELEMENT_URL="https://github.com/element-hq/element-web/releases/download/v${ELEMENT_VERSION}/${ELEMENT_ARCHIVE}"

if [[ -d "${ELEMENT_INSTALL_DIR}" ]]; then
    warn "Element already installed at ${ELEMENT_INSTALL_DIR} – skipping download."
else
    info "Downloading Element Web v${ELEMENT_VERSION}…"
    TMP=$(mktemp -d)
    wget -q --show-progress -O "${TMP}/${ELEMENT_ARCHIVE}" "${ELEMENT_URL}"
    tar -xzf "${TMP}/${ELEMENT_ARCHIVE}" -C "${TMP}"
    mv "${TMP}/element-v${ELEMENT_VERSION}" "${ELEMENT_INSTALL_DIR}"
    rm -rf "${TMP}"
    success "Element Web installed to ${ELEMENT_INSTALL_DIR}"
fi

# ── 6. Write Element config for localhost ─────────────────────────────────────
info "Writing Element config…"
cp "${SCRIPT_DIR}/config/element-config.json" "${ELEMENT_INSTALL_DIR}/config.json"
success "Element config applied."

# ── 7. Configure nginx ────────────────────────────────────────────────────────
info "Configuring nginx to serve Element on port 8080…"
cat > /etc/nginx/sites-available/element-local <<'NGINX'
server {
    listen 8080;
    server_name localhost;

    root /var/www/element;
    index index.html;

    # Security headers (relaxed for dev)
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options SAMEORIGIN;

    location / {
        try_files $uri $uri/ /index.html;
    }

    # Proxy Matrix client API through nginx so the browser doesn't
    # run into CORS issues when testing on port 8080.
    location /_matrix/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }

    location /_synapse/ {
        proxy_pass http://127.0.0.1:8008;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
    }
}
NGINX

ln -sf /etc/nginx/sites-available/element-local \
       /etc/nginx/sites-enabled/element-local
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
success "nginx configured."

# ── 8. Enable & start Synapse ─────────────────────────────────────────────────
info "Enabling and starting Matrix Synapse…"
systemctl enable matrix-synapse
systemctl restart matrix-synapse

# Give Synapse a moment to start
sleep 3
if systemctl is-active --quiet matrix-synapse; then
    success "Synapse is running."
else
    die "Synapse failed to start. Run: sudo journalctl -u matrix-synapse -n 50"
fi

# ── 9. Create a test admin account ───────────────────────────────────────────
echo
info "Creating a test admin user…"
read -rp "  Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"
read -rsp "  Admin password: " ADMIN_PASS
echo

register_new_matrix_user \
    -c "${SYNAPSE_CONFIG_DIR}/homeserver.yaml" \
    -u "${ADMIN_USER}" \
    -p "${ADMIN_PASS}" \
    -a \
    http://127.0.0.1:8008 && success "Admin user '@${ADMIN_USER}:${SYNAPSE_SERVER_NAME}' created." \
    || warn "Could not auto-create user (may already exist). Use the registration form."

# ── Done ──────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}=====================================================${NC}"
echo -e "${GREEN}  Localhost dev environment is ready!               ${NC}"
echo -e "${GREEN}=====================================================${NC}"
echo
echo "  Element Web  →  http://localhost:8080"
echo "  Synapse API  →  http://localhost:8008"
echo
echo "  Login with '@${ADMIN_USER}:${SYNAPSE_SERVER_NAME}' and the password you set."
echo
echo "  When you are happy with the local setup, proceed to the"
echo "  Docker / production deployment:"
echo "    cd ../docker && ./deploy.sh"
echo
