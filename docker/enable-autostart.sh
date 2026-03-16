#!/usr/bin/env bash
# =============================================================================
# docker/enable-autostart.sh
#
# Enables automatic restart of the Matrix server stack on system reboot.
#
# This script:
#   1. Ensures Docker daemon starts on boot (systemctl enable docker)
#   2. Creates a systemd service that starts your docker-compose stack
#   3. Enables the new service to auto-start on boot
#
# Run from the docker/ directory. Requires sudo.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="matrix-docker-compose"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[autostart]${NC} $*"; }
success() { echo -e "${GREEN}[autostart]${NC} $*"; }
warn()    { echo -e "${YELLOW}[autostart]${NC} $*"; }
die()     { echo -e "${RED}[autostart]${NC} $*" >&2; exit 1; }

# ── Root check ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Please run as root: sudo $0"

# ── Verify we're in the docker directory ───────────────────────────────────────
[[ -f "${SCRIPT_DIR}/docker-compose.yml" ]] || die "docker-compose.yml not found in ${SCRIPT_DIR}. Are you in the docker/ directory?"

info "Setting up automatic restart on system reboot…"
echo

# ── Step 1: Enable Docker daemon on boot ──────────────────────────────────────
info "Enabling Docker daemon to start on boot…"
if systemctl is-enabled docker &>/dev/null; then
    warn "Docker daemon already enabled on boot"
else
    systemctl enable docker
    success "Docker daemon enabled on boot"
fi
echo

# ── Step 2: Create systemd service file ───────────────────────────────────────
info "Creating systemd service: ${SERVICE_NAME}"

cat > "${SERVICE_FILE}" << 'EOF'
[Unit]
Description=Matrix + Element Docker Compose Stack
Documentation=file:///home/charles/Documents/code/simple-matrix-element-home-server-1/README.md
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=SCRIPT_DIR_PLACEHOLDER
ExecStart=/usr/bin/docker compose up -d --remove-orphans
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=10s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Replace placeholder with actual script directory
sed -i "s|SCRIPT_DIR_PLACEHOLDER|${SCRIPT_DIR}|g" "${SERVICE_FILE}"

success "Service file created: ${SERVICE_FILE}"
echo

# ── Step 3: Enable the new service ────────────────────────────────────────────
info "Enabling ${SERVICE_NAME} on boot…"
systemctl daemon-reload
systemctl enable "${SERVICE_NAME}"
success "${SERVICE_NAME} enabled"
echo

# ── Step 4: Verification ──────────────────────────────────────────────────────
echo -e "${GREEN}✓ Auto-start setup complete!${NC}"
echo
echo "Your Matrix server will now automatically start on system reboot."
echo
echo "To verify the setup:"
echo "  systemctl status ${SERVICE_NAME}"
echo "  systemctl is-enabled ${SERVICE_NAME}"
echo
echo "To manually start/stop:"
echo "  sudo systemctl start ${SERVICE_NAME}"
echo "  sudo systemctl stop ${SERVICE_NAME}"
echo
echo "To view logs:"
echo "  journalctl -u ${SERVICE_NAME} -f"
echo
