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
            echo ""
            echo "Options:"
            echo "  --check       Test reachability of each domain"
            echo "  --sipnetic    Show Sipnetic-specific domains"
            echo "  --linphone    Show Linphone-specific domains"
            echo "  --help        Show this help"
            exit 0
            ;;
        *) shift ;;
    esac
done

print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

check_dns() {
    local domain="$1"
    local port="$2"
    local proto="${3:-tcp}"

    if $CHECK_MODE; then
        # DNS resolution test
        if nslookup "$domain" >/dev/null 2>&1; then
            echo -e "    ${GREEN}✓ DNS resolves${NC}"
        else
            echo -e "    ${RED}✗ DNS BLOCKED - add to whitelist${NC}"
            return 1
        fi

        # Connectivity test
        if [[ "$proto" == "udp" ]]; then
            # UDP - just check DNS resolution (can't reliably test UDP connectivity)
            echo -e "    ${CYAN}→ UDP port ${port} (cannot test remotely)${NC}"
        else
            if curl -s --connect-timeout 5 "https://${domain}" >/dev/null 2>&1 || \
               curl -s --connect-timeout 5 "http://${domain}" >/dev/null 2>&1; then
                echo -e "    ${GREEN}✓ Reachable${NC}"
            else
                echo -e "    ${YELLOW}! Connection failed (may be expected)${NC}"
            fi
        fi
    fi
}

# Load config if available
source "$CONFIG_FILE" 2>/dev/null || true

print_header "DNS Whitelist for Easy Asterisk"

echo -e "${BOLD}Your Setup:${NC}"
if [[ -n "$DOMAIN_NAME" ]]; then
    echo -e "  Mode: FQDN/Internet (${DOMAIN_NAME})"
else
    echo -e "  Mode: LAN/VPN (no domain configured)"
fi
echo ""

# ══════════════════════════════════════════════════════════════
# SECTION 1: ASTERISK SERVER DOMAINS
# ══════════════════════════════════════════════════════════════
if $SHOW_ALL; then
    echo -e "${BOLD}━━━ 1. ASTERISK SERVER (whitelist on server's DNS filter) ━━━${NC}"
    echo ""

    echo -e "${BOLD}Required for LAN/VPN mode:${NC}"
    echo -e "  ${GREEN}None${NC} - Asterisk needs no internet after installation"
    echo -e "  SIP operates over direct IP connections, no DNS involved"
    echo ""

    echo -e "${BOLD}Required for FQDN/Internet mode only:${NC}"
    echo ""

    echo -e "  ${CYAN}ifconfig.me${NC} (HTTPS 443)"
    echo -e "    Purpose: Auto-detect public IP for NAT settings"
    echo -e "    When: Only during config regeneration"
    check_dns "ifconfig.me" "443"
    echo ""

    echo -e "  ${CYAN}icanhazip.com${NC} (HTTPS 443)"
    echo -e "    Purpose: Fallback public IP detection"
    check_dns "icanhazip.com" "443"
    echo ""

    echo -e "${BOLD}Required if ICE/STUN enabled:${NC}"
    echo ""

    # Check what STUN server is configured
    stun_server=""
    if [[ -f /etc/asterisk/rtp.conf ]]; then
        stun_server=$(grep "^stunaddr=" /etc/asterisk/rtp.conf 2>/dev/null | cut -d= -f2)
    fi

    if [[ -n "$stun_server" ]]; then
        stun_host=$(echo "$stun_server" | cut -d: -f1)
        stun_port=$(echo "$stun_server" | cut -d: -f2)
        stun_port="${stun_port:-3478}"
        echo -e "  ${CYAN}${stun_host}${NC} (UDP ${stun_port})"
        echo -e "    Purpose: STUN NAT discovery"
        echo -e "    ${YELLOW}Tip: Use self-hosted coturn to avoid this dependency${NC}"
        check_dns "$stun_host" "$stun_port" "udp"
    else
        echo -e "  ${GREEN}No external STUN server configured${NC}"
        echo -e "  To use self-hosted: docker compose --profile stun up -d"
    fi
    echo ""

    echo -e "${BOLD}Required for package updates only:${NC}"
    echo ""
    echo -e "  ${CYAN}archive.ubuntu.com${NC} / ${CYAN}security.ubuntu.com${NC} (HTTPS 443)"
    echo -e "    Purpose: apt package updates"
    echo -e "    When: Only during install/update (not runtime)"
    echo ""

    echo -e "${BOLD}Required for TLS certificates:${NC}"
    echo ""
    echo -e "  ${CYAN}acme-v02.api.letsencrypt.org${NC} (HTTPS 443)"
    echo -e "    Purpose: Let's Encrypt certificate issuance"
    echo -e "    When: Only if using Let's Encrypt / Certbot / Caddy"
    if $CHECK_MODE; then
        check_dns "acme-v02.api.letsencrypt.org" "443"
    fi
    echo ""
fi

# ══════════════════════════════════════════════════════════════
# SECTION 2: SIPNETIC (Mobile Client) DOMAINS
# ══════════════════════════════════════════════════════════════
if $SHOW_ALL || $SHOW_SIPNETIC; then
    echo -e "${BOLD}━━━ 2. SIPNETIC CLIENT (whitelist on caller/receiver DNS) ━━━${NC}"
    echo ""

    echo -e "${BOLD}Required for SIP calls:${NC}"
    echo -e "  ${GREEN}None${NC} - Configure Sipnetic with the server's IP address directly"
    echo -e "  SIP registration and calls use IP:port, not DNS"
    echo ""

    echo -e "${BOLD}Sipnetic app domains (for app functionality):${NC}"
    echo ""
    echo -e "  ${CYAN}onesip.io${NC} / ${CYAN}api.onesip.io${NC}"
    echo -e "    Purpose: Sipnetic account/licensing (free tier works offline)"
    echo -e "    Required: Only for initial setup or account sync"
    if $CHECK_MODE; then
        check_dns "onesip.io" "443"
    fi
    echo ""

    echo -e "  ${CYAN}play.google.com${NC} / ${CYAN}apps.apple.com${NC}"
    echo -e "    Purpose: App updates"
    echo -e "    Required: Only for installing/updating the app"
    echo ""

    echo -e "${BOLD}If STUN configured in Sipnetic:${NC}"
    echo ""
    echo -e "  The STUN server domain configured in Sipnetic's settings"
    echo -e "  needs to resolve on the mobile device's network."
    echo ""
    echo -e "  ${YELLOW}Recommendation: Use the Asterisk server's VPN IP as STUN${NC}"
    echo -e "  ${YELLOW}server (if running self-hosted coturn), avoiding DNS entirely.${NC}"
    echo ""

    echo -e "${BOLD}Sipnetic Configuration for DNS-Filtered Networks:${NC}"
    echo ""
    echo -e "  Server:     ${CYAN}<server-vpn-ip>${NC} (not a hostname)"
    echo -e "  Port:       ${CYAN}5060${NC} (UDP, LAN/VPN mode)"
    echo -e "  Transport:  ${CYAN}UDP${NC}"
    echo -e "  STUN:       ${CYAN}<server-vpn-ip>:3478${NC} (if self-hosted coturn)"
    echo -e "              or leave blank if VPN provides direct routing"
    echo ""
fi

# ══════════════════════════════════════════════════════════════
# SECTION 3: LINPHONE (Mobile Client) DOMAINS
# ══════════════════════════════════════════════════════════════
if $SHOW_ALL || $SHOW_LINPHONE; then
    echo -e "${BOLD}━━━ 3. LINPHONE CLIENT (whitelist on caller/receiver DNS) ━━━${NC}"
    echo ""

    echo -e "${BOLD}Required for SIP calls:${NC}"
    echo -e "  ${GREEN}None${NC} - Same as Sipnetic, configure with server IP directly"
    echo ""

    echo -e "${BOLD}Linphone app domains:${NC}"
    echo ""
    echo -e "  ${CYAN}linphone.org${NC} / ${CYAN}sip.linphone.org${NC}"
    echo -e "    Purpose: Default Linphone SIP proxy (NOT needed for Easy Asterisk)"
    echo -e "    Required: ${GREEN}No${NC} - We use our own Asterisk server"
    echo ""
    echo -e "  ${CYAN}subscribe.linphone.org${NC}"
    echo -e "    Purpose: Push notifications (may be needed for background calls)"
    echo -e "    Required: Only if you need calls to ring when app is backgrounded"
    echo ""

    echo -e "${BOLD}For remote provisioning:${NC}"
    echo ""
    echo -e "  If using Easy Asterisk's HTTP provisioning:"
    echo -e "  The phone must reach ${CYAN}http://<server-ip>:8088/static/linphone.xml${NC}"
    echo -e "  This is an IP address, so no DNS whitelist needed."
    echo ""
fi

# ══════════════════════════════════════════════════════════════
# SECTION 4: SUMMARY
# ══════════════════════════════════════════════════════════════
if $SHOW_ALL; then
    print_header "Quick Reference - Minimum DNS Whitelist"

    echo -e "${BOLD}For LAN/VPN mode (no internet calling):${NC}"
    echo ""
    echo -e "  Server DNS filter:  ${GREEN}No domains needed${NC}"
    echo -e "  Client DNS filter:  ${GREEN}No domains needed${NC}"
    echo -e "  (Configure everything by IP address)"
    echo ""

    echo -e "${BOLD}For LAN/VPN + self-hosted STUN (coturn):${NC}"
    echo ""
    echo -e "  Server DNS filter:  ${GREEN}No domains needed${NC}"
    echo -e "  Client DNS filter:  ${GREEN}No domains needed${NC}"
    echo -e "  (STUN server reached by VPN IP, not hostname)"
    echo ""

    echo -e "${BOLD}For LAN/VPN + Google STUN:${NC}"
    echo ""
    echo -e "  Server DNS filter:  ${YELLOW}stun.l.google.com${NC}"
    echo -e "  Client DNS filter:  ${YELLOW}stun.l.google.com${NC} (if also set in Sipnetic)"
    echo ""

    echo -e "${BOLD}For FQDN/Internet mode:${NC}"
    echo ""
    echo -e "  Server DNS filter:  ${YELLOW}ifconfig.me, icanhazip.com, stun.l.google.com${NC}"
    echo -e "                      ${YELLOW}acme-v02.api.letsencrypt.org${NC} (if using LE certs)"
    echo -e "  Client DNS filter:  ${YELLOW}Your domain name (${DOMAIN_NAME:-yourdomain.com})${NC}"
    echo ""

    print_header "Recommendation for DNS-Filtered Environments"

    echo -e "  ${GREEN}Use LAN/VPN mode + self-hosted coturn (STUN-only)${NC}"
    echo -e "  ${GREEN}= Zero external DNS dependencies${NC}"
    echo ""
    echo -e "  Setup: docker compose --profile stun up -d"
    echo -e "  Then configure STUN as your server's VPN IP:3478"
    echo -e "  No hostnames, no DNS, everything by IP."
    echo ""
fi
