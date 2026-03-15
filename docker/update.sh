#!/usr/bin/env bash
# =============================================================================
# docker/update.sh
#
# Pull the latest Docker images and restart services.
# All configuration and data in ./data/ are PRESERVED.
# Run from the docker/ directory.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[update]${NC} $*"; }
success() { echo -e "${GREEN}[update]${NC} $*"; }
warn()    { echo -e "${YELLOW}[update]${NC} $*"; }
die()     { echo -e "${RED}[update]${NC} $*" >&2; exit 1; }

cd "${SCRIPT_DIR}"

[[ -f .env ]] || die ".env not found. Have you run deploy.sh first?"
# shellcheck disable=SC1091
source .env

if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    die "docker compose not found."
fi

info "Pulling latest images…"
${DC} pull

info "Rebuilding custom nginx image…"
${DC} build nginx

info "Restarting services with new images (data volumes preserved)…"
${DC} up -d --remove-orphans

success "Update complete."
echo
echo "  All configuration files and data in ./data/ were preserved."
echo
${DC} ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || ${DC} ps
