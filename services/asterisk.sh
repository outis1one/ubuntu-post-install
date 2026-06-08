#!/bin/bash
# services/asterisk.sh — Easy Asterisk PBX with self-hosted coturn TURN server.
# Part of the modular post-install system (sourced by setup.sh).
#
# Based on https://github.com/outis1one/easy-asterisk
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
    local EA_REPO="https://github.com/outis1one/easy-asterisk"
    local EA_SCRIPT_URL="https://raw.githubusercontent.com/outis1one/easy-asterisk/main/easy-asterisk-v0.10.0.sh"
    local EA_COTURN_URL="https://raw.githubusercontent.com/outis1one/easy-asterisk/main/docker/coturn-entrypoint.sh"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR"
        echo "[DRY-RUN] Would download management script and coturn entrypoint"
        echo "[DRY-RUN] Would write docker-compose.yml, .env, Dockerfile"
        echo "[DRY-RUN] Would open UFW ports for SIP/RTP/TURN"
        return 0
    fi

    mkdir -p "$EA_DIR/docker"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    # ── Download management script ────────────────────────────────────────────
    log_info "Downloading Easy Asterisk management script..."
    if curl -fsSL "$EA_SCRIPT_URL" -o "$EA_DIR/easy-asterisk.sh"; then
        chmod 750 "$EA_DIR/easy-asterisk.sh"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$EA_DIR/easy-asterisk.sh"
        log_success "Management script saved to $EA_DIR/easy-asterisk.sh"
    else
        log_warning "Could not download management script — check network or fetch manually from $EA_REPO"
    fi

    # ── Download coturn custom entrypoint ─────────────────────────────────────
    if curl -fsSL "$EA_COTURN_URL" -o "$EA_DIR/docker/coturn-entrypoint.sh"; then
        chmod 755 "$EA_DIR/docker/coturn-entrypoint.sh"
    else
        log_warning "Could not download coturn-entrypoint.sh — coturn may fail to start"
    fi

    # ── FQDN setup ────────────────────────────────────────────────────────────
    echo ""
    echo "  Easy Asterisk requires a domain name (FQDN) that points to this"
    echo "  server's public IP. SIP clients connect to this domain over TLS."
    echo ""
    echo "  For LAN-only use without a domain, leave this blank."
    echo "  (LAN mode uses UDP — no TLS, no coturn needed.)"
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
        echo "    5061/tcp          → SIP TLS signaling"
        echo "    3478/udp+tcp      → STUN/TURN (NAT traversal)"
        echo "    10000-20000/udp   → RTP media"
        echo "    49152-49252/udp   → TURN relay range"
        echo ""
    fi

    # ── Generate passwords ────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(openssl rand -base64 18 2>/dev/null || tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"

    # ── Dockerfile ────────────────────────────────────────────────────────────
    cat > Dockerfile << 'DOCKERFILE'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    asterisk \
    asterisk-core-sounds-en-gsm \
    asterisk-modules \
    ca-certificates \
    openssl \
    curl \
    wget \
    tcpdump \
    sngrep \
    net-tools \
    iproute2 \
    iputils-ping \
    python3 \
    && rm -rf /var/lib/apt/lists/*

# Management scripts (bind-mounted at runtime from host)
COPY easy-asterisk.sh /usr/local/bin/easy-asterisk
RUN chmod +x /usr/local/bin/easy-asterisk

EXPOSE 5060/udp 5060/tcp 5061/tcp
EXPOSE 8080/tcp 8088/tcp 8089/tcp
EXPOSE 3478/udp
EXPOSE 10000-10100/udp

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD asterisk -rx "core show version" 2>/dev/null | grep -q "Asterisk" || exit 1
DOCKERFILE

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > docker-compose.yml << COMPOSE
# Easy Asterisk — generated by ubuntu-post-install
# Manage: docker exec -it easy-asterisk easy-asterisk
# Source: $EA_REPO

services:

  asterisk:
    build: .
    container_name: easy-asterisk
    # Host networking: required for RTP (10000-20000/udp) and proper NAT detection
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
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
    environment:
      - DOMAIN_NAME=\${DOMAIN_NAME}
      - ENABLE_TLS=\${ENABLE_TLS:-y}
      - PUBLIC_IP=\${PUBLIC_IP:-}
      - LOCAL_CIDR=\${LOCAL_CIDR:-}
      - HAS_VLANS=\${HAS_VLANS:-n}
      - VLAN_SUBNETS=\${VLAN_SUBNETS:-}
      - TURN_ENABLED=\${TURN_ENABLED:-y}
      - TURN_SERVER=\${DOMAIN_NAME}:\${TURN_PORT:-3478}
      - TURN_USERNAME=\${TURN_USERNAME:-easyasterisk}
      - TURN_PASSWORD=\${TURN_PASSWORD}
      - RTP_START=\${RTP_START:-10000}
      - RTP_END=\${RTP_END:-20000}
      - WEB_ADMIN_PORT=\${WEB_ADMIN_PORT:-8080}
      - WEB_ADMIN_AUTH_DISABLED=\${WEB_ADMIN_AUTH_DISABLED:-false}
    restart: unless-stopped

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    environment:
      - PUBLIC_IP=\${PUBLIC_IP:-}
    command:
      - -n
      - --listening-port=\${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=\${TURN_USERNAME:-easyasterisk}:\${TURN_PASSWORD}
      - --realm=\${DOMAIN_NAME:-localhost}
      - --min-port=\${TURN_RELAY_MIN:-49152}
      - --max-port=\${TURN_RELAY_MAX:-49252}
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
COMPOSE

    # ── .env ─────────────────────────────────────────────────────────────────
    cat > .env << ENV
# Easy Asterisk — environment configuration
# Edit and restart: docker compose down && docker compose up -d

# FQDN pointing to this server's public IP (required for remote/TLS mode)
DOMAIN_NAME=$DOMAIN_NAME

# Public IP — leave empty to auto-detect
PUBLIC_IP=

# TLS — set to 'n' for LAN-only mode
ENABLE_TLS=$( [[ "$LAN_ONLY" == "true" ]] && echo "n" || echo "y" )

# Local network CIDR — auto-detected if empty
LOCAL_CIDR=

# Additional subnets for site-to-site VPNs (WireGuard, Tailscale mesh)
# NOT needed for client-side VPNs (Proton, NordVPN) — TURN handles those
HAS_VLANS=n
VLAN_SUBNETS=

# TURN/STUN credentials (coturn)
# Generate new password: openssl rand -base64 18
TURN_USERNAME=easyasterisk
TURN_PASSWORD=$TURN_PASSWORD

# TURN port (default 3478 — change if conflicting with UniFi controller)
TURN_PORT=3478

# TURN relay port range (forward this range on your router)
TURN_RELAY_MIN=49152
TURN_RELAY_MAX=49252

# RTP media port range
RTP_START=10000
RTP_END=20000

# Web admin interface port
WEB_ADMIN_PORT=8080
WEB_ADMIN_AUTH_DISABLED=false
ENV

    chmod 600 .env
    chown "$ACTUAL_USER:$ACTUAL_USER" .env

    # ── UFW firewall rules ────────────────────────────────────────────────────
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Opening UFW ports for Asterisk..."
        ufw allow 5060/udp comment "Asterisk SIP UDP"
        ufw allow 5060/tcp comment "Asterisk SIP TCP"
        ufw allow 5061/tcp comment "Asterisk SIP TLS"
        ufw allow 8080/tcp comment "Asterisk web admin"
        ufw allow 3478/udp comment "coturn STUN/TURN"
        ufw allow 3478/tcp comment "coturn STUN/TURN TCP"
        ufw allow 10000:20000/udp comment "Asterisk RTP media"
        ufw allow 49152:49252/udp comment "coturn TURN relay"
        log_success "UFW rules added"
    else
        log_info "UFW not active — open these ports manually if needed:"
        log_info "  5060/udp+tcp, 5061/tcp, 3478/udp+tcp, 10000-20000/udp, 49152-49252/udp"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EA_DIR"

    # ── Caddy for web admin ───────────────────────────────────────────────────
    configure_caddy_for_service "Asterisk Web Admin" "localhost:8080" "asterisk"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << MD
# Easy Asterisk PBX

Home intercom / VoIP system built on Asterisk with self-hosted coturn TURN server.
Personal/home-lab use only. Source: $EA_REPO

## Access
- Web admin:  http://localhost:8080/clients
- FQDN mode:  $( [[ -n "$DOMAIN_NAME" ]] && echo "$DOMAIN_NAME" || echo "(LAN-only — no domain configured)" )

## Quick start
\`\`\`bash
# Interactive management menu
docker exec -it easy-asterisk easy-asterisk

# Or run the script directly (requires the container to be running)
sudo bash $EA_DIR/easy-asterisk.sh
\`\`\`

## Adding devices
Run the management menu and choose "Device Management → Add device".
Each device gets a SIP extension, password, and setup instructions for Linphone or Baresip.

## Connection types
- **LAN/VPN**: UDP, no encryption — for devices on the local network or WireGuard/Tailscale
- **FQDN**: TLS + SRTP — for devices anywhere on the internet

## Router port forwards (FQDN mode)
| Port | Protocol | Service |
|------|----------|---------|
| 5061 | TCP | SIP TLS signaling |
| 3478 | UDP+TCP | STUN/TURN |
| 10000-20000 | UDP | RTP media |
| 49152-49252 | UDP | TURN relay |

## TURN credentials
Username: easyasterisk
Password: (see .env)

## Manage
\`\`\`bash
cd $EA_DIR
docker compose up -d                           # start
docker compose down                            # stop
docker compose logs -f                         # logs
docker compose pull && docker compose up -d    # update coturn image
docker compose build --pull && docker compose up -d  # rebuild Asterisk image
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
                log_info "Run the management script to add your first device:"
                log_info "  docker exec -it easy-asterisk easy-asterisk"
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
