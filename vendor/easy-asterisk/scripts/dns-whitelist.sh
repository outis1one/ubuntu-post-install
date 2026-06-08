#!/bin/bash
# ================================================================
# DNS Whitelist Checker for Easy Asterisk
#
# Checks which domains need to be whitelisted when DNS filtering
# is active on the server, caller, or receiver networks.
#
# Usage: dns-whitelist [--check] [--sipnetic] [--linphone]
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/easy-asterisk/config"
CHECK_MODE=false
SHOW_SIPNETIC=false
SHOW_LINPHONE=false
SHOW_ALL=true

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_MODE=true; shift ;;
        --sipnetic) SHOW_SIPNETIC=true; SHOW_ALL=false; shift ;;
        --linphone) SHOW_LINPHONE=true; SHOW_ALL=false; shift ;;
        --help|-h)
            echo "Usage: dns-whitelist [OPTIONS]"
            echo "  --check       Test reachability of each domain"
            echo "  --sipnetic    Show Sipnetic-specific domains"
            echo "  --linphone    Show Linphone-specific domains"
            exit 0 ;;
        *) shift ;;
    esac
done

source "$CONFIG_FILE" 2>/dev/null || true

echo ""
echo -e "${CYAN}━━━ DNS Whitelist for Easy Asterisk ━━━${NC}"
echo ""
echo -e "${BOLD}Mode: ${NC}$( [[ -n "$DOMAIN_NAME" ]] && echo "FQDN ($DOMAIN_NAME)" || echo "LAN/VPN (no domain)" )"
echo ""
echo -e "${BOLD}Server DNS filter:${NC}"
echo -e "  ifconfig.me, icanhazip.com (public IP detection, FQDN mode only)"
echo -e "  acme-v02.api.letsencrypt.org (Let's Encrypt, if used)"
echo ""
echo -e "${BOLD}Client DNS filter (Sipnetic/Linphone):${NC}"
echo -e "  LAN/VPN mode: none (configure by IP)"
echo -e "  FQDN mode: your domain ($DOMAIN_NAME)"
echo ""
