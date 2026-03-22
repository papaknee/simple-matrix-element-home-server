#!/usr/bin/env bash
# =============================================================================
# docker/update.sh
#
# Pull the latest Docker images and restart services.
# All configuration and data in ./data/ are PRESERVED.
# Run from the docker/ directory.
#
# Usage:
#   ./update.sh                 # update images only
#   ./update.sh --sync-configs  # update images + restart config-driven services
#                               # so they reload any changes you made in ./data/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[update]${NC} $*"; }
success() { echo -e "${GREEN}[update]${NC} $*"; }
warn()    { echo -e "${YELLOW}[update]${NC} $*"; }
die()     { echo -e "${RED}[update]${NC} $*" >&2; exit 1; }

SYNC_CONFIGS=false
for arg in "$@"; do [[ "$arg" == "--sync-configs" ]] && SYNC_CONFIGS=true; done

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
if ! ${DC} pull; then
    warn "One or more images could not be pulled (network issue?). Continuing with locally cached images."
fi

info "Rebuilding custom nginx image…"
${DC} build nginx

info "Restarting services with new images (data volumes preserved)…"
${DC} up -d --remove-orphans

if [[ "${SYNC_CONFIGS}" == true ]]; then
    echo
    info "Restarting config-driven services to reload changes from ./data/…"
    for svc in synapse element coturn livekit lk-jwt nginx; do
        info "  Restarting ${svc}…"
        ${DC} restart "${svc}"
    done
    success "Config reload complete."
fi

echo
success "Update complete."
echo
echo "  All configuration files and data in ./data/ were preserved."
if [[ "${SYNC_CONFIGS}" == false ]]; then
    echo
    echo "  Tip: if you edited files in ./data/, run with --sync-configs to"
    echo "  restart services and apply those changes."
fi
echo
${DC} ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || ${DC} ps
