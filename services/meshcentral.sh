#!/bin/bash
# services/meshcentral.sh — Self-hosted remote device management server (MeshCentral).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash meshcentral.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MESHCENTRAL SERVER ----).
# Own ~/docker/meshcentral/ with a standalone docker-compose.yml + .env.
# HTTPS on port 4430, agent listener on 4433. First visit: create admin account.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
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

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
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

            # Back up before touching
            if [[ -f "$_caddyfile" ]]; then
                local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                cp "$_caddyfile" "$_bk"
                log_info "Backed up Caddyfile to $(basename "$_bk")"
            else
                touch "$_caddyfile"
            fi

            # Remove existing block for this domain if present
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

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service meshcentral utilities "Self-hosted remote device management server (MeshCentral)" 4430

install_meshcentral() {
    require_docker || return 1

    local MC_DIR="$DOCKER_DIR/meshcentral"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] MeshCentral would:"
        echo "  - Create $MC_DIR with docker-compose.yml + .env (data/ files/ backups/)"
        echo "  - Prompt for hostname (domain or IP for agent connections)"
        echo "  - Expose port 4430 (HTTPS web) and 4433 (agent)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MC_HOSTNAME=""
    prompt_text "MeshCentral hostname (domain or IP) [localhost]:" "localhost" MC_HOSTNAME
    MC_HOSTNAME="${MC_HOSTNAME:-localhost}"

    mkdir -p "$MC_DIR"
    ensure_docker_dir_ownership "$MC_DIR"
    cd "$MC_DIR" || return 1

    cat > docker-compose.yml << 'MC_COMPOSE'
name: meshcentral

services:
  meshcentral:
    image: ghcr.io/ylianst/meshcentral:latest
    container_name: meshcentral
    hostname: meshcentral
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - HOSTNAME=${MC_HOSTNAME:-localhost}
      - REVERSE_PROXY=${MC_REVERSE_PROXY:-false}
      - REVERSE_PROXY_TLS_PORT=${MC_TLS_PORT:-443}
      - IFRAME=false
      - ALLOW_NEW_ACCOUNTS=true
      - WEBRTC=true
    volumes:
      - ./data:/opt/meshcentral/meshcentral-data
      - ./files:/opt/meshcentral/meshcentral-files
      - ./backups:/opt/meshcentral/meshcentral-backups
    ports:
      - "4430:443"
      - "4433:4433"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
MC_COMPOSE

    cat > .env << MC_ENV
MC_HOSTNAME=$MC_HOSTNAME
MC_REVERSE_PROXY=false
MC_TLS_PORT=443
CADDY_NET=$SITE_CADDY_NET
MC_ENV

    mkdir -p data files backups
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR"
    log_success "MeshCentral configured at $MC_DIR"

    configure_caddy_for_service "MeshCentral" "meshcentral:443" "mesh"

    write_readme "$MC_DIR" << MD
# MeshCentral

Self-hosted remote device management — remotely access, manage, and monitor
all your computers from a single web interface. Install agents on each device.

- Web UI: https://localhost:4430  (self-signed cert on first launch)
- Agent listener: port 4433 (devices connect here — forward this port if remote)
- Hostname: \`$MC_HOSTNAME\` (update \`MC_HOSTNAME\` in .env if it changes)
- App data: \`data/\`, \`files/\`, \`backups/\`

## Manage
\`\`\`bash
cd $MC_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## First launch
1. Open https://localhost:4430 (accept the self-signed cert warning)
2. Create your admin account
3. Go to "My Devices" → "+ Add Device" → download the agent for each OS
4. Install the agent on every computer you want to manage

## Remote access
For devices outside your LAN to connect:
- Forward **TCP port 4433** on your router to this server
- Set \`MC_HOSTNAME\` in \`.env\` to your public domain/IP, then restart

## Docs
https://meshcentral.com/docs/
MD

    local START_MC=""
    prompt_yn "Start MeshCentral now? (y/n):" "y" START_MC
    if [ "$START_MC" = "y" ] || [ "$START_MC" = "Y" ]; then
        docker compose up -d && log_success "MeshCentral started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  https://localhost:4430  (accept self-signed cert)"
    echo "  First visit: create your admin account"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_meshcentral
