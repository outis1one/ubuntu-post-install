#!/bin/bash
# services/watchyourlan.sh — WatchYourLAN network device tracker.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash watchyourlan.sh
# (Docker must already be installed when run standalone)
#
# Continuously scans the network for connected devices, tracks history,
# and can alert on new/unknown devices. Uses network_mode: host so it
# can see the physical network directly (required for ARP scanning).

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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service watchyourlan utilities "Network device tracker (WatchYourLAN)" 8840

install_watchyourlan() {
    require_docker || return 1
    log_info "Installing WatchYourLAN..."
    local WYL_DIR="$DOCKER_DIR/watchyourlan"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $WYL_DIR (watchyourlan_data/)"
        echo "[DRY-RUN] Would deploy aceberg/watchyourlan:latest (network_mode: host)"
        echo "[DRY-RUN] Port 8840 on host, needs network interface name"
        return 0
    fi

    mkdir -p "$WYL_DIR/watchyourlan_data"
    ensure_docker_dir_ownership "$WYL_DIR"
    cd "$WYL_DIR" || return 1

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # Auto-detect primary network interface
    local DEFAULT_IFACE
    DEFAULT_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [ -z "$DEFAULT_IFACE" ] && DEFAULT_IFACE="eth0"

    echo ""
    echo "  WatchYourLAN needs to know which network interface to scan."
    echo "  Your detected primary interface: $DEFAULT_IFACE"
    echo ""
    ip link show 2>/dev/null | awk -F: '/^[0-9]+: / && !/lo/ {gsub(/ /,"",$2); print "  •", $2}' || true
    echo ""
    local SCAN_IFACE=""
    prompt_text "Network interface to scan:" "$DEFAULT_IFACE" SCAN_IFACE
    [ -z "$SCAN_IFACE" ] && SCAN_IFACE="$DEFAULT_IFACE"

    local GUI_PORT="8840"
    prompt_text "GUI port [8840]:" "8840" GUI_PORT
    [ -z "$GUI_PORT" ] && GUI_PORT="8840"

    cat > docker-compose.yml << 'WYL_COMPOSE'
name: watchyourlan

services:
  watchyourlan:
    image: aceberg/watchyourlan:latest
    container_name: watchyourlan
    hostname: watchyourlan
    restart: unless-stopped
    network_mode: host
    env_file: .env
    volumes:
      - ./watchyourlan_data:/data
WYL_COMPOSE

    cat > .env << WYL_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL

# ── WatchYourLAN ──────────────────────────────────────────────────────────────
# Network interface to scan (ARP scanning requires the physical interface)
IFACE=$SCAN_IFACE

# GUI bind address and port (network_mode: host — binds directly to the host)
GUIIP=0.0.0.0
GUIPORT=$GUI_PORT

# Web UI theme (darkly, cosmo, lumen, sandstone, etc.)
THEME=darkly
WYL_ENV

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WYL_DIR"
    log_success "WatchYourLAN configured at $WYL_DIR"

    # WatchYourLAN uses network_mode: host, so Caddy container-name routing
    # can't reach it via caddy_net. Access is directly on host port $GUI_PORT.
    # If behind Caddy on the same host, configure manually with host IP:PORT.
    if [ -d "$DOCKER_DIR/caddy" ]; then
        echo ""
        log_info "Note: WatchYourLAN uses host networking (needed for ARP scanning)."
        log_info "It cannot join caddy_net. To put it behind Caddy, add this block manually:"
        echo ""
        echo "  yourdomain.com {"
        echo "      reverse_proxy <HOST_IP>:$GUI_PORT"
        echo "  }"
        echo ""
        echo "  where HOST_IP is this server's IP on the Docker bridge (usually 172.17.0.1)."
    fi

    write_readme "$WYL_DIR" << MD
# WatchYourLAN — network device tracker

Scans the network continuously for connected devices, tracks history,
and alerts on new or unknown devices joining the network.

## Access
- URL: http://localhost:$GUI_PORT  (or http://<server-ip>:$GUI_PORT from LAN)

## Scanning interface
Configured to scan: **$SCAN_IFACE**
Change \`IFACE\` in .env and restart if you need to scan a different interface.

## Network mode note
WatchYourLAN uses \`network_mode: host\` to see real ARP traffic.
This means it cannot be added to caddy_net for reverse proxy via container name.
To put it behind Caddy, use the host's IP directly in the Caddyfile:
\`reverse_proxy 172.17.0.1:$GUI_PORT\` (adjust IP to your Docker bridge gateway).

## Manage
\`\`\`bash
cd $WYL_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_WYL=""
    prompt_yn "Start WatchYourLAN now? (y/n):" "y" START_WYL
    if [ "$START_WYL" = "y" ] || [ "$START_WYL" = "Y" ]; then
        docker compose up -d \
            && log_success "WatchYourLAN started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:$GUI_PORT"
    echo "  Scanning:   interface $SCAN_IFACE"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_watchyourlan
