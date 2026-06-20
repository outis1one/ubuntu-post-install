#!/bin/bash
# services/homeassistant.sh — Home Assistant home-automation hub.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash homeassistant.sh
# (Docker must already be installed when run standalone)

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
            local _display_port="${_upstream##*:}"

            # Determine mode: local Caddy, remote Caddy, or none
            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            # Domain prompt — pre-fill from SITE_DOMAIN when available
            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Build upstream — remote Caddy uses host IP:port, not container name
            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

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
)"

            if [[ "$_mode" == "local" ]]; then
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

                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
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

register_service homeassistant homelab "Home automation hub (Home Assistant)" 8123

install_homeassistant() {
    require_docker || return 1
    log_info "Installing Home Assistant..."
    local HOMEASSISTANT_DIR="$DOCKER_DIR/homeassistant"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $HOMEASSISTANT_DIR"
        return 0
    fi

    mkdir -p "$HOMEASSISTANT_DIR"
    ensure_docker_dir_ownership "$HOMEASSISTANT_DIR"
    cd "$HOMEASSISTANT_DIR" || return 1

    # Networking mode: bridge (published port) vs host networking.
    echo ""
    echo "  Home Assistant networking mode:"
    echo "    1) Bridge  - container gets its own network; port 8123 is published"
    echo "                 to the host. Works behind the Caddy reverse proxy and"
    echo "                 keeps HA isolated. Recommended for most setups."
    echo "    2) Host    - HA shares the host's network directly. Needed for"
    echo "                 auto-discovery of devices on your LAN (Chromecast/Cast,"
    echo "                 HomeKit, mDNS/Zeroconf, some Zigbee/Z-Wave & Bluetooth)."
    local HA_NETMODE=""
    prompt_text "  Choose networking mode [1]:" "1" HA_NETMODE
    local HA_NET_LINES HA_CADDY_NET_LINES
    if [ "$HA_NETMODE" = "2" ]; then
        HA_NET_LINES="    network_mode: host"
        HA_CADDY_NET_LINES=""
        echo "  → Host networking selected (best device discovery)."
    else
        HA_NET_LINES="    ports:
      - \"8123:8123\""
        if [ -d "$DOCKER_DIR/caddy" ]; then
            HA_CADDY_NET_LINES="    networks:
      - caddy_net"
        else
            HA_CADDY_NET_LINES=""
        fi
        echo "  → Bridge networking selected (port 8123 published)."
    fi

    local _CADDY_NET_SECTION=""
    if [ "$HA_NETMODE" != "2" ] && [ -d "$DOCKER_DIR/caddy" ]; then
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    cat > docker-compose.yml << HOMEASSISTANT_COMPOSE
name: homeassistant

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    hostname: homeassistant
    restart: unless-stopped
    privileged: true
    environment:
      - TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
    volumes:
      - ./config:/config
      - /run/dbus:/run/dbus:ro
${HA_NET_LINES}
${HA_CADDY_NET_LINES}
${_CADDY_NET_SECTION}
HOMEASSISTANT_COMPOSE

    mkdir -p config

    # Pre-seed trusted_proxies so HA works behind the Caddy reverse proxy.
    # Only written on a fresh install (never clobber an existing config).
    if [ ! -f config/configuration.yaml ]; then
        cat > config/configuration.yaml << 'HA_CONFIG'
# Loads default set of integrations. Do not remove.
default_config:

# Allow access through a reverse proxy (e.g. Caddy)
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 10.0.0.0/8
    - 127.0.0.1
    - ::1
HA_CONFIG
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$HOMEASSISTANT_DIR"
    echo ""
    log_success "Home Assistant configured at $HOMEASSISTANT_DIR"

    if [ "$HA_NETMODE" = "2" ]; then
        configure_caddy_for_service "Home Assistant" "8123" "home"
    else
        configure_caddy_for_service "Home Assistant" "homeassistant:8123" "home"
    fi

    write_readme "$HOMEASSISTANT_DIR" << MD
# Home Assistant

Home automation hub. Built-in auth — no Authelia needed.

## Access
- URL: http://localhost:8123
- First run: create your admin account through the onboarding wizard

## Manage
\`\`\`bash
cd $HOMEASSISTANT_DIR
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f                        # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_HA=""
    prompt_yn "Start Home Assistant now? (y/n):" "y" START_HA
    if [ "$START_HA" = "y" ] || [ "$START_HA" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Home Assistant started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:8123"
    echo "  First run:  open the URL and create your admin account (onboarding)."
    echo "  Note:       first startup can take a minute while HA initializes."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_homeassistant
