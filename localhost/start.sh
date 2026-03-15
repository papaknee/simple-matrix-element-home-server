#!/usr/bin/env bash
# =============================================================================
# localhost/start.sh  –  Start the local dev services
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[start]${NC} $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
die()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Please run as root: sudo $0"

info "Starting Matrix Synapse…"
systemctl start matrix-synapse
sleep 2
systemctl is-active --quiet matrix-synapse \
    && info "Synapse is running." \
    || die "Synapse failed to start. Check: sudo journalctl -u matrix-synapse -n 50"

info "Starting nginx (Element Web)…"
systemctl start nginx
systemctl is-active --quiet nginx \
    && info "nginx is running." \
    || die "nginx failed to start. Check: sudo journalctl -u nginx -n 20"

echo
echo -e "${GREEN}Services started.${NC}"
echo "  Element Web  →  http://localhost:8080"
echo "  Synapse API  →  http://localhost:8008"
