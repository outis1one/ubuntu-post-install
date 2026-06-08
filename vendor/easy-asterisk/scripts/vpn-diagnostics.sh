#!/bin/bash
# ================================================================
# VPN Diagnostics for Easy Asterisk
#
# Tests whether your third-party VPN setup needs STUN/TURN
# and validates connectivity between Asterisk and VPN clients.
#
# Usage: vpn-diagnostics [--auto] [--client-ip <ip>]
# ================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

CONFIG_FILE="/etc/easy-asterisk/config"
RESULTS=()
WARNINGS=()
CLIENT_IP=""
AUTO_MODE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --auto) AUTO_MODE=true; shift ;;
        --client-ip) CLIENT_IP="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: vpn-diagnostics [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --auto              Non-interactive mode"
            echo "  --client-ip <ip>    Test connectivity to specific VPN client"
            echo "  --help              Show this help"
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

pass() { echo -e "  ${GREEN}✓${NC} $1"; RESULTS+=("PASS: $1"); }
fail() { echo -e "  ${RED}✗${NC} $1"; RESULTS+=("FAIL: $1"); }
warn() { echo -e "  ${YELLOW}!${NC} $1"; WARNINGS+=("$1"); }
info() { echo -e "  ${CYAN}→${NC} $1"; }

# ── Test 1: Detect network interfaces ────────────────────────
print_header "VPN Diagnostics for Easy Asterisk"

echo -e "${BOLD}1. Network Interface Detection${NC}"
echo ""

# Detect primary LAN interface
primary_ip=$(hostname -I | awk '{print $1}')
info "Primary IP: ${primary_ip}"

# Detect VPN interfaces (tun, tap, wg, tailscale, utun, ppp)
vpn_found=false
vpn_ips=()
vpn_ifaces=()

while IFS= read -r line; do
    iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
    ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)

    # Check for VPN interface patterns
    if [[ "$iface" =~ ^(tun|tap|wg|tailscale|utun|ppp|nordlynx|proton|mullvad) ]] || \
       [[ "$ip_addr" =~ ^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.64\.|100\.96\.|100\.100\.) ]]; then
        vpn_found=true
        vpn_ips+=("$ip_addr")
        vpn_ifaces+=("$iface")
        pass "VPN interface detected: ${iface} (${ip_addr})"
    fi
done < <(ip -o -f inet addr show scope global 2>/dev/null)

if ! $vpn_found; then
    warn "No VPN interface detected on server"
    info "If your VPN runs on the router (not this server), that's expected"
    info "The VPN subnet should be added via VLAN/VPN subnet configuration"
fi

# ── Test 2: Check Asterisk PJSIP transport configuration ─────
echo ""
echo -e "${BOLD}2. Asterisk Transport Configuration${NC}"
echo ""

if [[ -f /etc/asterisk/pjsip.conf ]]; then
    # Check local_net entries
    local_nets=$(grep "^local_net=" /etc/asterisk/pjsip.conf 2>/dev/null | sort -u)
    if [[ -n "$local_nets" ]]; then
        while IFS= read -r net; do
            info "Transport local_net: ${net#local_net=}"
        done <<< "$local_nets"

        # Check if VPN subnets are included
        for vpn_ip in "${vpn_ips[@]}"; do
            vpn_subnet=$(echo "$vpn_ip" | sed 's/\.[0-9]*$/.0\/24/')
            if echo "$local_nets" | grep -q "$vpn_subnet"; then
                pass "VPN subnet ${vpn_subnet} included in transport"
            else
                fail "VPN subnet ${vpn_subnet} NOT in transport local_net"
                warn "Add via: Server Settings → Configure VLAN/VPN Subnets"
            fi
        done
    else
        warn "No local_net entries found in transport (basic LAN mode)"
    fi

    # Check transport types
    if grep -q "transport=transport-udp" /etc/asterisk/pjsip.conf; then
        pass "UDP transport configured for LAN/VPN devices"
    fi
    if grep -q "transport=transport-tls" /etc/asterisk/pjsip.conf; then
        pass "TLS transport configured for FQDN devices"
    fi
else
    fail "pjsip.conf not found"
fi

# ── Test 2b: TLS Certificate & Port Checks ────────────────────
echo ""
echo -e "${BOLD}2b. TLS / Certificate Status${NC}"
echo ""

# Check if port 5061 is actually listening
if command -v ss &>/dev/null; then
    tls_listen=$(ss -tlnp 2>/dev/null | grep ":5061 " || true)
elif command -v netstat &>/dev/null; then
    tls_listen=$(netstat -tlnp 2>/dev/null | grep ":5061 " || true)
else
    tls_listen=""
fi

if [[ -n "$tls_listen" ]]; then
    pass "Port 5061 (TLS) is listening"
else
    fail "Port 5061 (TLS) is NOT listening"
    warn "Asterisk TLS transport failed to start — check certs and logs"
fi

# Check TLS cert
cert_file="/etc/asterisk/certs/server.crt"
if [[ -f "$cert_file" ]]; then
    pass "TLS certificate exists: $cert_file"

    # Check cert CN/SAN
    cert_cn=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null | sed 's/.*CN *= *//')
    cert_san=$(openssl x509 -in "$cert_file" -noout -ext subjectAltName 2>/dev/null | grep -oP 'DNS:\K[^,]+' || true)
    cert_expiry=$(openssl x509 -in "$cert_file" -noout -enddate 2>/dev/null | cut -d= -f2)

    info "Cert CN: ${cert_cn:-unknown}"
    if [[ -n "$cert_san" ]]; then
        pass "Cert has SAN (Subject Alt Name): ${cert_san}"
    else
        fail "Cert has NO SAN — modern phones (iOS/Android) will reject it"
        warn "Delete /etc/asterisk/certs/server.crt and restart to regenerate with SANs"
    fi
    info "Cert expires: ${cert_expiry:-unknown}"

    # Check if cert is self-signed
    issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null | sed 's/.*CN *= *//')
    if [[ "$issuer" == "$cert_cn" ]]; then
        warn "Cert is SELF-SIGNED — phones must be set to accept self-signed certs"
        info "In your SIP app: disable TLS certificate verification / allow self-signed"
    fi

    # Verify PJSIP transport loaded it
    if command -v asterisk &>/dev/null; then
        transport_status=$(asterisk -rx "pjsip show transports" 2>/dev/null || true)
        if echo "$transport_status" | grep -q "transport-tls"; then
            pass "PJSIP TLS transport is loaded"
        else
            fail "PJSIP TLS transport NOT loaded — cert may be invalid"
        fi
    fi
else
    fail "TLS certificate not found at $cert_file"
fi

# ── Test 3: Check RTP and ICE/STUN configuration ─────────────
echo ""
echo -e "${BOLD}3. RTP / ICE / STUN Configuration${NC}"
echo ""

if [[ -f /etc/asterisk/rtp.conf ]]; then
    rtp_start=$(grep "^rtpstart=" /etc/asterisk/rtp.conf | cut -d= -f2)
    rtp_end=$(grep "^rtpend=" /etc/asterisk/rtp.conf | cut -d= -f2)
    info "RTP port range: ${rtp_start:-10000}-${rtp_end:-20000}"

    if grep -q "^icesupport=yes" /etc/asterisk/rtp.conf; then
        pass "ICE support enabled"
        stun_addr=$(grep "^stunaddr=" /etc/asterisk/rtp.conf | cut -d= -f2)
        if [[ -n "$stun_addr" ]]; then
            info "STUN server: ${stun_addr}"

            # Test STUN server reachability
            stun_host=$(echo "$stun_addr" | cut -d: -f1)
            stun_port=$(echo "$stun_addr" | cut -d: -f2)
            stun_port="${stun_port:-3478}"

            if command -v nslookup &>/dev/null && nslookup "$stun_host" >/dev/null 2>&1; then
                pass "STUN server DNS resolves: ${stun_host}"
            else
                fail "Cannot resolve STUN server: ${stun_host}"
                warn "Add ${stun_host} to DNS whitelist"
            fi
        fi
    else
        info "ICE support disabled (standard for LAN/VPN mode)"
        warn "If audio fails over VPN, enable ICE via: Server Settings → VPN STUN/ICE"
    fi
else
    warn "rtp.conf not found"
fi

# ── Test 4: Check endpoint ICE settings ───────────────────────
echo ""
echo -e "${BOLD}4. Per-Device ICE Configuration${NC}"
echo ""

if [[ -f /etc/asterisk/pjsip.conf ]]; then
    device_count=$(grep -c "^; === Device:" /etc/asterisk/pjsip.conf 2>/dev/null || echo 0)
    ice_device_count=$(grep -c "^ice_support=yes" /etc/asterisk/pjsip.conf 2>/dev/null || echo 0)
    info "Total devices: ${device_count}"
    info "Devices with ICE: ${ice_device_count}"

    if [[ "$device_count" -gt 0 && "$ice_device_count" -eq 0 ]]; then
        warn "No devices have ICE enabled"
        info "For third-party VPNs with NAT, enable ICE via VPN STUN/ICE menu"
    fi
fi

# ── Test 5: VPN client connectivity ──────────────────────────
echo ""
echo -e "${BOLD}5. VPN Client Connectivity${NC}"
echo ""

if [[ -z "$CLIENT_IP" ]] && ! $AUTO_MODE; then
    echo "  Enter a VPN client IP to test connectivity (or press Enter to skip):"
    read -p "  Client VPN IP: " CLIENT_IP
fi

if [[ -n "$CLIENT_IP" ]]; then
    # Ping test
    if ping -c 2 -W 3 "$CLIENT_IP" >/dev/null 2>&1; then
        pass "Ping to ${CLIENT_IP} succeeded"
    else
        fail "Ping to ${CLIENT_IP} failed"
        warn "VPN routing issue - client may not be reachable"
    fi

    # SIP port test (UDP 5060)
    if command -v nc &>/dev/null; then
        if nc -z -u -w 3 "$CLIENT_IP" 5060 2>/dev/null; then
            pass "UDP 5060 reachable on ${CLIENT_IP}"
        else
            info "UDP 5060 probe inconclusive (normal for filtered VPNs)"
        fi
    fi
else
    info "Skipping client connectivity test (no IP provided)"
fi

# ── Test 6: NAT type detection ───────────────────────────────
echo ""
echo -e "${BOLD}6. NAT Type Analysis${NC}"
echo ""

# Check if server is behind NAT
if [[ -n "$primary_ip" ]]; then
    public_ip=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    if [[ -n "$public_ip" ]]; then
        if [[ "$primary_ip" == "$public_ip" ]]; then
            pass "Server has public IP (no NAT)"
        else
            info "Server behind NAT: ${primary_ip} → ${public_ip}"
            info "This is normal for VPN setups where traffic stays on VPN"
        fi
    else
        info "Cannot detect public IP (DNS filtering or no internet)"
        info "Not needed for LAN/VPN mode"
    fi
fi

# ── Test 7: Asterisk registration status ─────────────────────
echo ""
echo -e "${BOLD}7. Asterisk Registration Status${NC}"
echo ""

if command -v asterisk &>/dev/null; then
    reg_output=$(asterisk -rx "pjsip show endpoints" 2>/dev/null || echo "")
    if [[ -n "$reg_output" ]]; then
        online_count=$(echo "$reg_output" | grep -c "Avail" 2>/dev/null || echo 0)
        offline_count=$(echo "$reg_output" | grep -c "Unavail" 2>/dev/null || echo 0)
        info "Endpoints online: ${online_count}"
        info "Endpoints offline: ${offline_count}"

        if [[ "$offline_count" -gt 0 ]]; then
            warn "Some endpoints are offline - check VPN connectivity"
            echo "$reg_output" | grep "Unavail" | while IFS= read -r line; do
                info "  Offline: $line"
            done
        fi
    else
        info "Asterisk not running or no endpoints configured"
    fi
else
    info "Asterisk CLI not available"
fi

# ── Summary ──────────────────────────────────────────────────
print_header "Diagnostic Summary"

fail_count=0
pass_count=0
for result in "${RESULTS[@]}"; do
    if [[ "$result" == FAIL* ]]; then
        ((fail_count++))
    elif [[ "$result" == PASS* ]]; then
        ((pass_count++))
    fi
done

echo -e "  Passed: ${GREEN}${pass_count}${NC}"
echo -e "  Failed: ${RED}${fail_count}${NC}"
echo -e "  Warnings: ${YELLOW}${#WARNINGS[@]}${NC}"

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${BOLD}Recommendations:${NC}"
    for w in "${WARNINGS[@]}"; do
        echo -e "  ${YELLOW}→${NC} $w"
    done
fi

# ── STUN Recommendation ─────────────────────────────────────
echo ""
echo -e "${BOLD}Do you need STUN?${NC}"
echo ""

if $vpn_found; then
    echo -e "  VPN detected on this server."
    echo -e "  ${GREEN}If your VPN provides direct routing (both sides get VPN IPs),${NC}"
    echo -e "  ${GREEN}STUN is likely NOT needed.${NC}"
    echo ""
    echo -e "  ${YELLOW}If audio works one-way or not at all, enable STUN:${NC}"
    echo -e "    1. docker compose --profile stun up -d  (self-hosted STUN)"
    echo -e "    2. Or via easy-asterisk: Server Settings → VPN STUN/ICE"
else
    echo -e "  No VPN interface found on server."
    echo -e "  ${YELLOW}If VPN runs on router/firewall:${NC}"
    echo -e "    - Add VPN subnet via: Server Settings → VLAN/VPN Subnets"
    echo -e "    - If audio still fails, enable STUN for NAT traversal"
fi

echo ""
