#!/bin/bash
# ================================================================
# VPN Diagnostics for Easy Asterisk
# Validates PJSIP, TLS, ICE, RTP, and device configuration.
# Usage: vpn-diagnostics [--auto] [--client-ip <ip>]
# ================================================================

set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; RED='\033[0;31m'; NC='\033[0m'

echo -e "${CYAN}━━━ Easy Asterisk VPN Diagnostics ━━━${NC}"
echo ""

# Check Asterisk is running
if ! asterisk -rx "core show version" &>/dev/null; then
    echo -e "${RED}✗ Asterisk is not running${NC}"; exit 1
fi
echo -e "${GREEN}✓ Asterisk running:${NC} $(asterisk -rx "core show version" 2>/dev/null)"

# Check transports
echo ""
echo -e "${CYAN}Transports:${NC}"
asterisk -rx "pjsip show transports" 2>/dev/null || true

# Check registered endpoints
echo ""
echo -e "${CYAN}Endpoints:${NC}"
asterisk -rx "pjsip show endpoints" 2>/dev/null || true

# Check TLS cert
if [[ -f /etc/asterisk/certs/server.crt ]]; then
    exp=$(openssl x509 -in /etc/asterisk/certs/server.crt -noout -enddate 2>/dev/null | cut -d= -f2)
    echo -e "${GREEN}✓ TLS cert:${NC} expires $exp"
    openssl x509 -in /etc/asterisk/certs/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:" \
        && echo -e "${GREEN}✓ SANs present (mobile-compatible)${NC}" \
        || echo -e "${YELLOW}! No SANs — mobile clients may reject cert${NC}"
fi

echo ""
