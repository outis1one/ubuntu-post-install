#!/bin/bash
# services/asterisk.sh — Easy Asterisk PBX with self-hosted coturn TURN server.
# Part of the modular post-install system (sourced by setup.sh).
#
# Based on https://github.com/outis1one/easy-asterisk
# Source files vendored in vendor/easy-asterisk/
# Personal/home-lab use only. Not for commercial or emergency services.
#
# Can also be run standalone on any machine:
#   sudo bash asterisk.sh
# (Docker must already be installed when run standalone)

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() {
            command -v docker &>/dev/null || {
                log_error "Docker not found. Install it first:"
                log_error "  curl -fsSL https://get.docker.com | sudo sh"
                return 1
            }
            docker compose version &>/dev/null || {
                log_error "Docker Compose plugin missing:"
                log_error "  sudo apt-get install -y docker-compose-plugin"
                return 1
            }
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"

            if [[ ! -d "$_caddy_dir" ]]; then
                log_info "Access $_name directly on port ${_upstream##*:}."
                return 0
            fi

            echo ""
            local _do_caddy=""
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:${_upstream##*:}"
                return 0
            }

            local _domain=""
            read -r -p "  Domain (e.g. ${_subdomain}.${SITE_DOMAIN:-example.com}): " _domain
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            if [[ -f "$_caddyfile" ]]; then
                local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                cp "$_caddyfile" "$_bk"
                log_info "Backed up Caddyfile to $(basename "$_bk")"
            else
                touch "$_caddyfile"
            fi

            if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                log_warning "$_domain already in Caddyfile"
                local _ow=""
                read -r -p "  Overwrite? [y/N]: " _ow
                [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
            fi

            cat >> "$_caddyfile" << CBLOCK

# $_name
$_domain {
    reverse_proxy $_upstream

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK

            log_success "Added $_domain to Caddyfile"
            docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
            if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                log_success "$_name accessible at: https://$_domain"
            else
                log_warning "Reload failed — check: docker logs caddy"
                log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
            fi
        }

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service asterisk homelab "Easy Asterisk PBX + coturn TURN server (home intercom/VoIP)" 5061

install_asterisk() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX..."

    local EA_DIR="$DOCKER_DIR/asterisk"

    # Locate vendored source files (works when sourced by setup.sh or run standalone)
    local _script_dir
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" \
        || _script_dir="$(dirname "$(realpath "$0" 2>/dev/null || echo "$0")")"
    local VENDOR_DIR="$_script_dir/../vendor/easy-asterisk"
    VENDOR_DIR="$(cd "$VENDOR_DIR" 2>/dev/null && pwd)" || VENDOR_DIR=""

    if [[ -z "$VENDOR_DIR" || ! -f "$VENDOR_DIR/easy-asterisk-v0.10.0.sh" ]]; then
        log_warning "Vendored easy-asterisk files not found at $VENDOR_DIR"
        log_warning "Expected: vendor/easy-asterisk/ alongside services/ directory"
        log_error "Cannot install — run from the ubuntu-post-install repo root."
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR"
        echo "[DRY-RUN] Would copy vendored easy-asterisk files (Dockerfile, scripts, entrypoints)"
        echo "[DRY-RUN] Would write docker-compose.yml, .env"
        echo "[DRY-RUN] Would open UFW ports for SIP/RTP/TURN"
        return 0
    fi

    mkdir -p "$EA_DIR/docker" "$EA_DIR/scripts"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    # ── Copy vendored source files ────────────────────────────────────────────
    log_info "Copying Easy Asterisk source files from vendor/..."

    cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"        "$EA_DIR/easy-asterisk.sh"
    cp "$VENDOR_DIR/Dockerfile"                        "$EA_DIR/Dockerfile"
    cp "$VENDOR_DIR/docker/entrypoint.sh"              "$EA_DIR/docker/entrypoint.sh"
    cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"       "$EA_DIR/docker/coturn-entrypoint.sh"
    cp "$VENDOR_DIR/scripts/vpn-diagnostics.sh"        "$EA_DIR/scripts/vpn-diagnostics.sh"
    cp "$VENDOR_DIR/scripts/dns-whitelist.sh"          "$EA_DIR/scripts/dns-whitelist.sh"

    chmod 750 "$EA_DIR/easy-asterisk.sh"
    chmod 755 "$EA_DIR/docker/entrypoint.sh" "$EA_DIR/docker/coturn-entrypoint.sh"
    chmod 755 "$EA_DIR/scripts/vpn-diagnostics.sh" "$EA_DIR/scripts/dns-whitelist.sh"

    log_success "Source files copied"

    # The Dockerfile COPYs easy-asterisk-v0.10.0.sh (the versioned name).
    # We keep easy-asterisk.sh as the canonical name and make a real copy
    # with the versioned filename so Docker COPY works reliably (no symlinks).
    cp "$EA_DIR/easy-asterisk.sh" "$EA_DIR/easy-asterisk-v0.10.0.sh"

    # ── FQDN setup ────────────────────────────────────────────────────────────
    echo ""
    echo "  Easy Asterisk can run in two modes:"
    echo ""
    echo "  LAN/VPN — UDP transport, no TLS, no TURN."
    echo "            Simple setup for devices on your local network or WireGuard/Tailscale."
    echo ""
    echo "  FQDN    — TLS + SRTP + coturn TURN relay."
    echo "            Works from anywhere: LAN, cellular, hotel WiFi, Proton VPN."
    echo "            Requires a domain name pointing to this server's public IP."
    echo ""

    local DOMAIN_NAME=""
    prompt_text "FQDN for this server (e.g. asterisk.${SITE_DOMAIN:-example.com}) [blank for LAN-only]:" "" DOMAIN_NAME

    local LAN_ONLY=false
    if [[ -z "$DOMAIN_NAME" ]]; then
        LAN_ONLY=true
        log_info "LAN/VPN-only mode — TLS and TURN disabled."
    else
        log_info "FQDN mode: $DOMAIN_NAME"
        echo ""
        echo "  Required router port forwards:"
        printf "    %-22s %s\n" "5061/tcp"        "SIP TLS signaling"
        printf "    %-22s %s\n" "3478/udp+tcp"    "STUN/TURN (NAT traversal)"
        printf "    %-22s %s\n" "10000-20000/udp" "RTP media (Asterisk)"
        printf "    %-22s %s\n" "49152-49252/udp" "TURN relay range (coturn)"
        echo ""
    fi

    # ── Generate TURN password ────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(openssl rand -base64 18 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 24 \
        || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    # Uses the real upstream Dockerfile (FROM ubuntu:24.04 + full Asterisk install)
    # with host networking for RTP/NAT, and the custom coturn entrypoint.
    cat > docker-compose.yml << 'COMPOSE_EOF'
# Easy Asterisk — managed by ubuntu-post-install
# Manage: docker exec -it easy-asterisk easy-asterisk
# Source: https://github.com/outis1one/easy-asterisk

services:

  asterisk:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: easy-asterisk
    # Host networking: required for RTP (10000-20000/udp) and proper NAT detection.
    # SIP clients connect directly to the host IP; Caddy is only used for the web admin.
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - asterisk-config:/etc/asterisk
      - easy-asterisk-config:/etc/easy-asterisk
      - asterisk-logs:/var/log/asterisk
      - asterisk-spool:/var/spool/asterisk
      - asterisk-lib:/var/lib/asterisk
      # Bind-mount the management script so updates don't require a rebuild
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
    environment:
      - DOMAIN_NAME=${DOMAIN_NAME}
      - ENABLE_TLS=${ENABLE_TLS:-y}
      - PUBLIC_IP=${PUBLIC_IP:-}
      - LOCAL_CIDR=${LOCAL_CIDR:-}
      - HAS_VLANS=${HAS_VLANS:-n}
      - VLAN_SUBNETS=${VLAN_SUBNETS:-}
      - TURN_ENABLED=${TURN_ENABLED:-y}
      - TURN_SERVER=${TURN_SERVER}
      - TURN_USERNAME=${TURN_USERNAME:-easyasterisk}
      - TURN_PASSWORD=${TURN_PASSWORD}
      - RTP_START=${RTP_START:-10000}
      - RTP_END=${RTP_END:-20000}
      - WEB_ADMIN_PORT=${WEB_ADMIN_PORT:-8080}
      - WEB_ADMIN_AUTH_DISABLED=${WEB_ADMIN_AUTH_DISABLED:-false}
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    environment:
      - PUBLIC_IP=${PUBLIC_IP:-}
    command:
      - -n
      - --listening-port=${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=${TURN_USERNAME:-easyasterisk}:${TURN_PASSWORD}
      - --realm=${DOMAIN_NAME:-localhost}
      - --min-port=${TURN_RELAY_MIN:-49152}
      - --max-port=${TURN_RELAY_MAX:-49252}
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

volumes:
  asterisk-config:
  easy-asterisk-config:
  asterisk-logs:
  asterisk-spool:
  asterisk-lib:
COMPOSE_EOF

    # ── .env ─────────────────────────────────────────────────────────────────
    cat > .env << ENV
# Easy Asterisk — environment configuration
# Edit and restart: docker compose down && docker compose up -d

# FQDN pointing to this server's public IP (required for remote/TLS mode)
DOMAIN_NAME=$DOMAIN_NAME

# Public IP — leave empty to auto-detect
PUBLIC_IP=

# TLS — always 'y' for remote access, 'n' for LAN-only
ENABLE_TLS=$( [[ "$LAN_ONLY" == "true" ]] && echo "n" || echo "y" )

# Local network CIDR — auto-detected if empty
LOCAL_CIDR=

# Additional subnets for site-to-site VPNs (WireGuard/Tailscale mesh, NOT client-side)
HAS_VLANS=n
VLAN_SUBNETS=

# TURN/STUN credentials — must match in both Asterisk and coturn
# Regenerate: openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c 24
TURN_USERNAME=easyasterisk
TURN_PASSWORD=$TURN_PASSWORD

# TURN server address — auto-set based on FQDN or LAN mode above
# LAN-only: leave empty (coturn not used). FQDN mode: domain:port
TURN_SERVER=$( [[ "$LAN_ONLY" == "true" ]] && echo "" || echo "${DOMAIN_NAME}:3478" )

# TURN port (change to 3479 if 3478 conflicts with UniFi controller or Mattermost)
TURN_PORT=3478

# TURN relay port range — forward this range on your router
TURN_RELAY_MIN=49152
TURN_RELAY_MAX=49252

# RTP media port range — forward this range on your router
RTP_START=10000
RTP_END=20000

# Web admin interface
WEB_ADMIN_PORT=8080
WEB_ADMIN_AUTH_DISABLED=false
ENV

    chmod 600 .env
    chown "$ACTUAL_USER:$ACTUAL_USER" .env

    # ── UFW firewall rules ────────────────────────────────────────────────────
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Opening UFW ports for Asterisk..."
        ufw allow 5060/udp  comment "Asterisk SIP UDP"         >/dev/null
        ufw allow 5060/tcp  comment "Asterisk SIP TCP"         >/dev/null
        ufw allow 5061/tcp  comment "Asterisk SIP TLS"         >/dev/null
        ufw allow 8080/tcp  comment "Asterisk web admin"       >/dev/null
        ufw allow 8088/tcp  comment "Asterisk HTTP provision"  >/dev/null
        ufw allow 8089/tcp  comment "Asterisk HTTPS provision" >/dev/null
        ufw allow 3478/udp  comment "coturn STUN/TURN UDP"     >/dev/null
        ufw allow 3478/tcp  comment "coturn STUN/TURN TCP"     >/dev/null
        ufw allow 10000:20000/udp comment "Asterisk RTP media"  >/dev/null
        ufw allow 49152:49252/udp comment "coturn TURN relay"   >/dev/null
        log_success "UFW rules added"
    else
        log_info "UFW not active — open these ports manually if needed:"
        log_info "  5060/udp+tcp, 5061/tcp"
        log_info "  8080/tcp (web admin), 8088/tcp, 8089/tcp (provisioning)"
        log_info "  3478/udp+tcp (STUN/TURN)"
        log_info "  10000-20000/udp (RTP), 49152-49252/udp (TURN relay)"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EA_DIR"

    # ── Caddy for web admin (with optional Authelia SSO) ──────────────────────
    # The web admin has no built-in auth; let Authelia gate it if available.
    local EA_EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
        if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
            EA_EXTRA_BLOCK="    import authelia"
            # Tell Asterisk's web admin to skip its own auth — Authelia handles it
            sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" "$EA_DIR/.env"
            log_info "WEB_ADMIN_AUTH_DISABLED=true set (Authelia will handle authentication)"
        fi
    fi
    configure_caddy_for_service "Asterisk Web Admin" "localhost:8080" "asterisk" "$EA_EXTRA_BLOCK"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << MD
# Easy Asterisk PBX

Home intercom / VoIP system built on Asterisk with self-hosted coturn TURN server.
Personal/home-lab use only. Source: https://github.com/outis1one/easy-asterisk

## Access
- Web admin:  http://localhost:8080/clients
- FQDN:       $( [[ -n "$DOMAIN_NAME" ]] && echo "$DOMAIN_NAME" || echo "(LAN-only — no domain)" )

## Management
\`\`\`bash
# Interactive management menu (add devices, provisioning, diagnostics)
docker exec -it easy-asterisk easy-asterisk

# VPN diagnostics
docker exec -it easy-asterisk vpn-diagnostics

# DNS whitelist check
docker exec -it easy-asterisk dns-whitelist
\`\`\`

## Adding devices
Run the management menu → Device Management → Add device.
Each device gets a SIP extension, password, and setup instructions
for Linphone (remote provisioning) or Baresip (manual).

## Connection modes
- **LAN/VPN**: UDP, no encryption — local network or WireGuard/Tailscale
- **FQDN**: TLS + SRTP + coturn TURN relay — works from anywhere

## Caddy and phone calls
Asterisk uses **host networking** — SIP signaling and RTP media connect
directly to the server, completely bypassing Caddy. Do NOT put SIP ports
behind a reverse proxy (Contact header rewriting will break registration).

Caddy only handles the **web admin** (port 8080) for HTTPS browser access.

The **provisioning server** (ports 8088/8089) is Asterisk's built-in HTTP
server for Linphone XML config delivery. Access it directly by IP/domain,
not through Caddy — SIP clients fetch it at startup before registering.

## Router port forwards (FQDN mode)
| Port | Protocol | Service |
|------|----------|---------|
| 5061 | TCP | SIP TLS signaling |
| 3478 | UDP+TCP | STUN/TURN |
| 10000-20000 | UDP | RTP media |
| 49152-49252 | UDP | TURN relay |
| 8088 | TCP | Provisioning (Linphone XML) — optional |

## TURN credentials (for SIP clients behind strict NAT)
- Server:   \${DOMAIN_NAME}:3478
- Username: easyasterisk
- Password: (see .env → TURN_PASSWORD)

## Manage
\`\`\`bash
cd $EA_DIR
docker compose up -d                                      # start
docker compose down                                       # stop
docker compose logs -f                                    # logs
docker compose pull                                       # update coturn image
docker compose build --pull && docker compose up -d      # rebuild Asterisk image
\`\`\`
MD

    # ── Build and start ───────────────────────────────────────────────────────
    echo ""
    local START_EA=""
    prompt_yn "Build and start Easy Asterisk now? (y/n):" "y" START_EA
    if [[ "$START_EA" =~ ^[Yy]$ ]]; then
        log_info "Building Asterisk image (first build takes a few minutes)..."
        if docker compose build --pull 2>&1 | tail -5; then
            if docker compose up -d; then
                log_success "Easy Asterisk started"
                echo ""
                echo "  Web admin:   http://localhost:8080/clients"
                echo "  Management:  docker exec -it easy-asterisk easy-asterisk"
                echo ""
                log_info "Next: add your first device via the management menu."
            else
                log_warning "Start failed — check: docker compose logs"
            fi
        else
            log_warning "Build failed — check output above"
        fi
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk
