#!/usr/bin/env bash
# =============================================================================
# localhost/teardown.sh  –  Completely remove the local dev environment.
# WARNING: This deletes all Synapse data and config.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
die() { echo -e "${RED}[error]${NC} $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Please run as root: sudo $0"

echo -e "${RED}WARNING:${NC} This will PERMANENTLY delete all Matrix data and configuration."
echo "  • /etc/matrix-synapse/"
echo "  • /var/lib/matrix-synapse/"
echo "  • /var/www/element/"
echo "  • nginx site config"
echo
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "${CONFIRM}" == "yes" ]] || { echo "Aborted."; exit 0; }

echo "Stopping services…"
systemctl stop matrix-synapse 2>/dev/null || true
systemctl disable matrix-synapse 2>/dev/null || true

echo "Removing packages…"
apt-get purge -y matrix-synapse-py3 2>/dev/null || true
apt-get autoremove -y -qq

echo "Removing data directories…"
rm -rf /etc/matrix-synapse /var/lib/matrix-synapse /var/www/element

echo "Removing nginx site…"
rm -f /etc/nginx/sites-enabled/element-local
rm -f /etc/nginx/sites-available/element-local
systemctl reload nginx 2>/dev/null || true

echo -e "${YELLOW}Teardown complete.${NC}"
