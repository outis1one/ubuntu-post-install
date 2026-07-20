#!/bin/bash
# ================================================================
# Easy Asterisk Docker Entrypoint
#
# Fully automated:
#   - Detects public IP
#   - Generates TURN credentials if not provided
#   - Configures Asterisk with FQDN, TLS, ICE, STUN, TURN
#   - Starts web admin + Asterisk
# ================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[entrypoint]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[entrypoint]${NC} $1"; }
log_error() { echo -e "${RED}[entrypoint]${NC} $1"; }

CONFIG_DIR="/etc/easy-asterisk"
CONFIG_FILE="${CONFIG_DIR}/config"
WEB_ADMIN_SCRIPT="/usr/local/bin/easy-asterisk-webadmin"

# ── Helper: generate random password ─────────────────────────
gen_password() {
    openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24
}

# ── 1. Ensure asterisk user exists ───────────────────────────
if ! id asterisk >/dev/null 2>&1; then
    useradd -r -s /bin/false -d /var/lib/asterisk asterisk 2>/dev/null || true
fi

# ── 2. Detect public IP ──────────────────────────────────────
PUBLIC_IP="${PUBLIC_IP:-}"
if [[ -z "$PUBLIC_IP" ]]; then
    log_info "Auto-detecting public IP..."
    PUBLIC_IP=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || true)
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null || true)
    fi
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP=$(curl -s -4 --connect-timeout 5 api.ipify.org 2>/dev/null || true)
    fi
fi

if [[ -n "$PUBLIC_IP" ]]; then
    log_info "Public IP: ${PUBLIC_IP}"
else
    log_warn "Could not detect public IP. Set PUBLIC_IP in .env"
fi

# ── 3. TURN credentials ─────────────────────────────────────────
# The password MUST match what coturn was started with. In Docker, both
# read from the same env-var / .env file, so we use the value as-is.
# Auto-generating a different password here would create a mismatch
# (coturn is already running with ITS copy of the env-var).
TURN_USERNAME="${TURN_USERNAME:-easyasterisk}"
TURN_PASSWORD="${TURN_PASSWORD:-changeme}"
if [[ "${TURN_PASSWORD}" == "changeme" ]]; then
    log_warn "TURN password is the default 'changeme' — set TURN_PASSWORD in .env for better security"
fi

# ── 4. Detect local network ──────────────────────────────────
local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
raw_cidr=$(ip -o -f inet addr show 2>/dev/null | awk '/scope global/ {print $4}' | head -1)
default_cidr="$raw_cidr"
if [[ "$raw_cidr" =~ \.([0-9]+)/([0-9]+)$ ]]; then
    default_cidr="${raw_cidr%.*}.0/${BASH_REMATCH[2]}"
fi

# ── 4b. Sync Caddy-issued TLS cert (if the compose file shared it) ───────
# If services/asterisk.sh mounted Caddy's data dir read-only at /caddy-data,
# and Caddy already holds a real Let's Encrypt cert for our own DOMAIN_NAME
# (e.g. because a matching site block exists in the Caddyfile), prefer that
# over a self-signed cert — phones then get a CA-trusted TLS connection.
CADDY_CERT_DIR="/caddy-data/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
sync_caddy_cert() {
    [[ -n "${DOMAIN_NAME:-}" ]] || return 1
    local src_crt="${CADDY_CERT_DIR}/${DOMAIN_NAME}/${DOMAIN_NAME}.crt"
    local src_key="${CADDY_CERT_DIR}/${DOMAIN_NAME}/${DOMAIN_NAME}.key"
    [[ -f "$src_crt" && -f "$src_key" ]] || return 1

    if [[ -f /etc/asterisk/certs/server.crt ]] && cmp -s "$src_crt" /etc/asterisk/certs/server.crt; then
        return 1   # already in sync
    fi

    mkdir -p /etc/asterisk/certs
    cp "$src_crt" /etc/asterisk/certs/server.crt
    cp "$src_key" /etc/asterisk/certs/server.key
    chown asterisk:asterisk /etc/asterisk/certs/server.crt /etc/asterisk/certs/server.key
    chmod 644 /etc/asterisk/certs/server.crt
    chmod 600 /etc/asterisk/certs/server.key
    return 0
}

if [[ -d "$CADDY_CERT_DIR" ]] && sync_caddy_cert; then
    log_info "Synced Caddy-issued Let's Encrypt cert for ${DOMAIN_NAME} (CA-trusted, no self-signed warning)"
fi

# ── 5. Generate self-signed certs ──────────────────────────────
# Regenerate if missing OR if existing cert lacks SANs (modern TLS clients require them)
# Skipped entirely if the Caddy sync above just installed a real cert.
regen_cert=false
if [[ ! -f /etc/asterisk/certs/server.crt ]]; then
    regen_cert=true
elif ! openssl x509 -in /etc/asterisk/certs/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:"; then
    log_info "Existing TLS cert lacks SANs — regenerating for mobile phone compatibility"
    regen_cert=true
fi

if $regen_cert; then
    log_info "Generating self-signed TLS certificate..."
    mkdir -p /etc/asterisk/certs
    cn="${DOMAIN_NAME:-asterisk-local}"
    # Include Subject Alternative Names — required by modern TLS clients (iOS/Android SIP apps)
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/asterisk/certs/server.key \
        -out /etc/asterisk/certs/server.crt \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=DNS:${cn}${PUBLIC_IP:+,IP:${PUBLIC_IP}}" \
        2>/dev/null
    chown asterisk:asterisk /etc/asterisk/certs/server.*
    chmod 644 /etc/asterisk/certs/server.crt
    chmod 600 /etc/asterisk/certs/server.key
fi

# ── 6. Write config file ─────────────────────────────────────
mkdir -p "$CONFIG_DIR"

# Determine TURN/STUN server address
turn_server="${TURN_SERVER:-${DOMAIN_NAME:-$local_ip}:${TURN_PORT:-3478}}"

cat > "$CONFIG_FILE" << EOF
# Easy Asterisk Configuration (Docker) - $(date)
KIOSK_USER=""
KIOSK_UID=""
KIOSK_EXTENSION=""
KIOSK_NAME=""
SIP_PASSWORD=""
ASTERISK_HOST="${DOMAIN_NAME:-$local_ip}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
ENABLE_TLS="${ENABLE_TLS:-y}"
HAS_VLANS="${HAS_VLANS:-n}"
VLAN_SUBNETS="${VLAN_SUBNETS:-}"
CERT_PATH=""
KEY_PATH=""
INSTALLED_SERVER="y"
INSTALLED_CLIENT="n"
CURRENT_PUBLIC_IP="${PUBLIC_IP}"
PTT_DEVICE=""
PTT_KEYCODE=""
LOCAL_CIDR="${LOCAL_CIDR:-$default_cidr}"
WEB_ADMIN_PORT="${WEB_ADMIN_PORT:-8080}"
WEB_ADMIN_AUTH_DISABLED="${WEB_ADMIN_AUTH_DISABLED:-false}"
VPN_ICE_ENABLED="y"
CUSTOM_STUN_SERVER="${turn_server}"
TURN_ENABLED="y"
TURN_SERVER="${turn_server}"
TURN_USERNAME="${TURN_USERNAME}"
TURN_PASSWORD="${TURN_PASSWORD}"
EOF
chmod 644 "$CONFIG_FILE"

# ── 7. Initialize categories & rooms if missing ──────────────
CATEGORIES_FILE="${CONFIG_DIR}/categories.conf"
if [[ ! -f "$CATEGORIES_FILE" ]]; then
    log_info "Creating default device categories..."
    cat > "$CATEGORIES_FILE" << 'EOF'
kiosks|Kiosks|yes|Fixed wall-mount tablets & intercoms
mobile|Mobile|no|Phones & tablets (ring normally)
custom|Custom|no|Custom configuration
EOF
fi

ROOMS_FILE="${CONFIG_DIR}/rooms.conf"
if [[ ! -f "$ROOMS_FILE" ]]; then
    cat > "$ROOMS_FILE" << 'EOF'
# ext|name|members|timeout|type
EOF
fi

# ── 8. Generate Asterisk configs ─────────────────────────────

# Build local_net entries
all_local_nets="local_net=${LOCAL_CIDR:-$default_cidr}"
if [[ "${HAS_VLANS:-n}" == "y" && -n "${VLAN_SUBNETS:-}" ]]; then
    for subnet in $VLAN_SUBNETS; do
        all_local_nets="${all_local_nets}
local_net=${subnet}"
    done
fi

# NAT settings - always include external addresses for FQDN mode
nat_settings=""
if [[ -n "$PUBLIC_IP" ]]; then
    nat_settings="external_media_address=${PUBLIC_IP}
external_signaling_address=${PUBLIC_IP}
${all_local_nets}"
else
    nat_settings="${all_local_nets}"
fi

# ── pjsip.conf (only if empty/missing - preserves existing devices) ──
if [[ ! -f /etc/asterisk/pjsip.conf ]] || [[ ! -s /etc/asterisk/pjsip.conf ]]; then
    log_info "Generating PJSIP configuration..."
    cat > /etc/asterisk/pjsip.conf << EOF
; Easy Asterisk (Docker) - FQDN: ${DOMAIN_NAME:-none}
[global]
type=global
user_agent=EasyAsterisk

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
; Server IP: ${local_ip} | Public IP: ${PUBLIC_IP:-unknown}
${nat_settings}

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
; Server IP: ${local_ip} | Public IP: ${PUBLIC_IP:-unknown}
${nat_settings}

[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:5061
; Server IP: ${local_ip} | Public IP: ${PUBLIC_IP:-unknown}
cert_file=/etc/asterisk/certs/server.crt
priv_key_file=/etc/asterisk/certs/server.key
; ca_list_file not set — only needed for verify_client=yes (client cert auth)
method=tlsv1_2
${nat_settings}

EOF
    chown asterisk:asterisk /etc/asterisk/pjsip.conf
else
    # Update NAT settings in existing pjsip.conf transports if public IP changed
    if [[ -n "$PUBLIC_IP" ]]; then
        current_ext=$(grep "^external_media_address=" /etc/asterisk/pjsip.conf 2>/dev/null | head -1 | cut -d= -f2)
        if [[ "$current_ext" != "$PUBLIC_IP" && -n "$current_ext" ]]; then
            log_info "Updating public IP in pjsip.conf: ${current_ext} -> ${PUBLIC_IP}"
            sed -i "s|external_media_address=.*|external_media_address=${PUBLIC_IP}|g" /etc/asterisk/pjsip.conf
            sed -i "s|external_signaling_address=.*|external_signaling_address=${PUBLIC_IP}|g" /etc/asterisk/pjsip.conf
        fi
    fi
fi

# ── Sanitize pjsip.conf: remove endpoint-only options from aor sections ──
if [[ -f /etc/asterisk/pjsip.conf ]]; then
    # Options that are only valid in [endpoint] sections, not in [aor] sections
    endpoint_only_opts="direct_media|rtp_symmetric|force_rport|rewrite_contact|rtp_keepalive|rtp_timeout|rtp_timeout_hold|ice_support|context|disallow|allow|auth|aors|callerid|media_encryption|transport"
    current_type=""
    needs_fix=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^type=(.*) ]]; then
            current_type="${BASH_REMATCH[1]}"
        fi
        if [[ "$current_type" == "aor" ]] && echo "$line" | grep -qE "^(${endpoint_only_opts})="; then
            needs_fix=true
            break
        fi
    done < /etc/asterisk/pjsip.conf

    if $needs_fix; then
        log_info "Sanitizing pjsip.conf (removing misplaced options from aor sections)..."
        awk -v opts="$endpoint_only_opts" '
        BEGIN { split(opts, arr, "|"); for (i in arr) bad[arr[i]]=1 }
        /^type=/ { current_type = substr($0, 6) }
        {
            if (current_type == "aor") {
                split($0, kv, "=")
                if (kv[1] in bad) next
            }
            print
        }
        ' /etc/asterisk/pjsip.conf > /tmp/pjsip_sanitized.conf
        mv /tmp/pjsip_sanitized.conf /etc/asterisk/pjsip.conf
        chown asterisk:asterisk /etc/asterisk/pjsip.conf
    fi
fi

# ── Ensure transport-tls exists in pjsip.conf (upgrade / migration path) ──
# If pjsip.conf was preserved from a pre-TLS config or a non-Docker install it
# will have no [transport-tls] section.  Asterisk starts without TLS silently,
# and mobile devices cannot register.  Inject the section when it is absent.
if [[ -f /etc/asterisk/pjsip.conf ]] && ! grep -q "^\[transport-tls\]" /etc/asterisk/pjsip.conf; then
    log_info "transport-tls missing from pjsip.conf — adding TLS transport (required for mobile registration)..."
    cat >> /etc/asterisk/pjsip.conf << EOF

[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:5061
cert_file=/etc/asterisk/certs/server.crt
priv_key_file=/etc/asterisk/certs/server.key
; ca_list_file not set — only needed for verify_client=yes (client cert auth)
method=tlsv1_2
${nat_settings}

EOF
    chown asterisk:asterisk /etc/asterisk/pjsip.conf
fi

# ── Ensure transport-udp/transport-tcp exist (same migration path as TLS) ──
# Same scenario as above: a preserved/migrated pjsip.conf can be missing the
# plain SIP transports entirely, silently, with no bind error — LAN/VLAN
# devices registering without TLS then can never connect. Inject if absent.
if [[ -f /etc/asterisk/pjsip.conf ]] && ! grep -q "^\[transport-udp\]" /etc/asterisk/pjsip.conf; then
    log_info "transport-udp missing from pjsip.conf — adding UDP transport..."
    cat >> /etc/asterisk/pjsip.conf << EOF

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
${nat_settings}

EOF
    chown asterisk:asterisk /etc/asterisk/pjsip.conf
fi

if [[ -f /etc/asterisk/pjsip.conf ]] && ! grep -q "^\[transport-tcp\]" /etc/asterisk/pjsip.conf; then
    log_info "transport-tcp missing from pjsip.conf — adding TCP transport..."
    cat >> /etc/asterisk/pjsip.conf << EOF

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:5060
${nat_settings}

EOF
    chown asterisk:asterisk /etc/asterisk/pjsip.conf
fi

# ── rtp.conf (always regenerated) ──
# ICE is enabled so Asterisk participates in ICE negotiation with clients.
# stunaddr/turnaddr are NOT set here because:
#   - Asterisk already knows its public IP via external_media_address in pjsip.conf
#   - Its RTP ports are port-forwarded, so host candidates are sufficient
#   - Setting stunaddr/turnaddr causes STUN/TURN gather timeouts (~27s per call)
#     when the STUN/TURN server is unreachable or misconfigured
# coturn is for SIP CLIENTS behind strict NAT — they configure TURN in their
# own app settings, independently of Asterisk's rtp.conf.
log_info "Configuring RTP with ICE support..."
cat > /etc/asterisk/rtp.conf << EOF
[general]
rtpstart=${RTP_START:-10000}
rtpend=${RTP_END:-20000}
strictrtp=yes
icesupport=yes
EOF
chown asterisk:asterisk /etc/asterisk/rtp.conf

# ── extensions.conf (only if missing) ──
if [[ ! -f /etc/asterisk/extensions.conf ]] || [[ ! -s /etc/asterisk/extensions.conf ]]; then
    log_info "Generating dialplan..."
    cat > /etc/asterisk/extensions.conf << 'EOF'
[general]
static=yes
writeprotect=no
[default]
exten => _X.,1,Hangup()
[intercom]
EOF
    chown asterisk:asterisk /etc/asterisk/extensions.conf
fi

# ── Other core configs (only if missing) ──
if [[ ! -f /etc/asterisk/asterisk.conf ]]; then
    cat > /etc/asterisk/asterisk.conf << 'EOF'
[directories]
[options]
runuser = asterisk
rungroup = asterisk
EOF
fi

# ── logger.conf (always regenerated - ensures security logging is on) ──
cat > /etc/asterisk/logger.conf << 'EOF'
[general]
[logfiles]
; security level captures TLS handshake failures and auth issues
console => notice,warning,error,security
EOF

# ── modules.conf (always regenerated - ensures chan_sip stays disabled) ──
cat > /etc/asterisk/modules.conf << 'EOF'
[modules]
autoload=yes
noload => chan_sip.so
noload => chan_iax2.so
; Opus transcoding unavailable on Ubuntu 24.04 (bug #2044135)
; Opus pass-through still works via res_format_attr_opus.so
noload => codec_opus.so
noload => format_ogg_opus.so
load => res_pjsip.so
load => res_pjsip_session.so
load => res_pjsip_logger.so
load => chan_pjsip.so
load => codec_ulaw.so
load => codec_alaw.so
load => codec_g722.so
load => res_rtp_asterisk.so
load => app_dial.so
load => app_page.so
load => pbx_config.so
EOF

# ── Remove incompatible Digium codec_opus if present on volume ──
# The Digium binary is ABI-incompatible with Ubuntu 24.04's Asterisk and crashes it
MODULES_DIR=$(find /usr/lib -type d -name modules -path "*/asterisk/*" 2>/dev/null | head -1)
if [[ -n "$MODULES_DIR" ]]; then
    for bad_module in codec_opus.so format_ogg_opus.so; do
        if [[ -f "$MODULES_DIR/$bad_module" ]] && ! dpkg -S "$MODULES_DIR/$bad_module" >/dev/null 2>&1; then
            log_warn "Removing incompatible $bad_module (not from Ubuntu package)"
            rm -f "$MODULES_DIR/$bad_module"
        fi
    done
fi

# ── 9. Fix permissions ───────────────────────────────────────
chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk 2>/dev/null || true

# ── 10. Start Web Admin in background ─────────────────────────
# The web admin script is generated by the 'easy-asterisk' management tool,
# but it only lives in the container's writable layer (not baked into the
# image or bind-mounted), so it's gone every time the container is
# recreated. Regenerate it unconditionally instead of only starting it if
# it happens to already exist — otherwise the web admin never comes back
# on its own after a restart, requiring a manual CLI trip every time.
if [[ -x /usr/local/bin/easy-asterisk ]]; then
    /usr/local/bin/easy-asterisk --write-web-admin-script >/dev/null 2>&1 || true
fi
if [[ -f "$WEB_ADMIN_SCRIPT" ]]; then
    log_info "Starting Web Admin on port ${WEB_ADMIN_PORT:-8080}..."
    WEBADMIN_PORT="${WEB_ADMIN_PORT:-8080}" \
    WEBADMIN_AUTH_DISABLED="${WEB_ADMIN_AUTH_DISABLED:-false}" \
    python3 "$WEB_ADMIN_SCRIPT" &
fi

# ── 10b. Keep the Caddy-issued cert fresh across renewals ────────────────
# Let's Encrypt certs renew every ~60-90 days without the container restarting.
# Re-check periodically and hot-reload Asterisk when Caddy's copy changes.
if [[ -d "$CADDY_CERT_DIR" ]]; then
    (
        while sleep 43200; do   # every 12h
            if sync_caddy_cert; then
                log_info "Caddy cert renewed for ${DOMAIN_NAME} — reloading Asterisk"
                asterisk -rx "core reload" >/dev/null 2>&1 || true
            fi
        done
    ) &
fi

# ── 11. Signal handling for clean shutdown ────────────────────
cleanup() {
    log_info "Shutting down..."
    # pkill only sends the signal and returns immediately — it doesn't wait
    # for the process to actually exit and release its listening socket.
    # Under network_mode: host there's no Docker-managed port mapping to
    # tear down, so the next container's bind attempt races however long
    # this process actually takes to die. Wait for it (briefly) instead of
    # racing the next container's startup — it retries too now, but a
    # clean handoff here means it usually shouldn't need to.
    if pkill -f "easy-asterisk-webadmin" 2>/dev/null; then
        for i in $(seq 1 20); do
            pgrep -f "easy-asterisk-webadmin" >/dev/null 2>&1 || break
            sleep 0.1
        done
        pkill -9 -f "easy-asterisk-webadmin" 2>/dev/null || true
    fi
    asterisk -rx "core stop now" 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

# ── 12. Start Asterisk ───────────────────────────────────────
log_info "Starting Asterisk PBX..."
echo ""

# Start Asterisk in the background, then print management info once ready
asterisk -f -U asterisk -G asterisk &
ASTERISK_PID=$!

# Wait for Asterisk to be ready (up to 60 seconds)
for i in $(seq 1 60); do
    if asterisk -rx "core show version" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Rebuild the dialplan from the current pjsip.conf/rooms.conf on every start.
# Devices/rooms are meant to trigger this themselves when added via the web
# admin, but this is a cheap safety net against any path that misses it
# (or config restored/edited outside the web admin) — without it, endpoints
# can register fine yet be uncallable ("extension not found in context
# 'intercom'") with no obvious cause.
if [[ -x /usr/local/bin/easy-asterisk ]]; then
    /usr/local/bin/easy-asterisk --rebuild-dialplan >/dev/null 2>&1 || true
fi

# Verify PJSIP transports are listening. res_pjsip finishes binding its
# transports a beat after "core show version" first responds, so a single
# immediate check can catch it mid-startup and misreport TLS as down even
# though it comes up a second later — poll for a few seconds before giving up.
tls_ok=false
udp_ok=false
for i in $(seq 1 10); do
    transports_output=$(asterisk -rx "pjsip show transports" 2>/dev/null)
    echo "$transports_output" | grep -q "transport-tls" && tls_ok=true
    echo "$transports_output" | grep -q "transport-udp" && udp_ok=true
    $tls_ok && $udp_ok && break
    sleep 1
done

# Check if port 5061 is actually bound
tls_listen=""
if command -v ss &>/dev/null; then
    tls_listen=$(ss -tlnp 2>/dev/null | grep ":5061 " || true)
elif command -v netstat &>/dev/null; then
    tls_listen=$(netstat -tlnp 2>/dev/null | grep ":5061 " || true)
fi

echo ""
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Easy Asterisk (Docker)${NC}"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo -e "  FQDN:         ${GREEN}${DOMAIN_NAME:-not set}${NC}"
echo -e "  Public IP:    ${GREEN}${PUBLIC_IP:-unknown}${NC}"
echo -e "  TURN/STUN:    ${GREEN}${turn_server}${NC}"
if $tls_ok && [[ -n "$tls_listen" ]]; then
    echo -e "  TLS:          ${GREEN}Enabled (port 5061)${NC}"
elif $tls_ok; then
    echo -e "  TLS:          ${YELLOW}Transport loaded but port 5061 not bound — check certs${NC}"
else
    echo -e "  TLS:          ${RED}NOT LOADED — check Asterisk logs${NC}"
fi
echo -e "  ICE:          ${GREEN}Enabled${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo -e "  SIP clients connect to: ${GREEN}${DOMAIN_NAME:-$local_ip}:5061${NC} (TLS)"
echo -e "  Web Admin:    ${GREEN}http://${local_ip}:${WEB_ADMIN_PORT:-8080}/clients${NC}"
echo -e "${CYAN}──────────────────────────────────────────────────────────────${NC}"
echo -e "  Management:   ${YELLOW}docker exec -it easy-asterisk easy-asterisk${NC}"
echo -e "  Diagnostics:  docker exec -it easy-asterisk vpn-diagnostics"
echo -e "${CYAN}══════════════════════════════════════════════════════════════${NC}"
echo ""

# Wait for Asterisk process (keeps container running)
wait $ASTERISK_PID
