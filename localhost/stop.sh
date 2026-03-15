#!/usr/bin/env bash
# =============================================================================
# localhost/stop.sh  –  Stop the local dev services (data is preserved)
# =============================================================================
set -euo pipefail

YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "\033[0;32m[stop]${NC}  $*"; }
die()   { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Please run as root: sudo $0"

info "Stopping Matrix Synapse…"
systemctl stop matrix-synapse && info "Synapse stopped." || true

info "Stopping nginx…"
systemctl stop nginx && info "nginx stopped." || true

echo
echo -e "${YELLOW}Services stopped. Your data is preserved.${NC}"
echo "Run 'sudo ./start.sh' to start them again."
