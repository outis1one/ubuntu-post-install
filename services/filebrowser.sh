#!/bin/bash
# services/filebrowser.sh — FileBrowser web-based file manager.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash filebrowser.sh
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
        # One-off copy — inline minimal stubs
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
            if [[ -d "$DOCKER_DIR/caddy" ]]; then
                log_info "Caddy detected — configure reverse proxy manually (standalone mode)."
                log_info "  Add to Caddyfile:  reverse_proxy filebrowser:80"
            else
                log_info "Access FileBrowser directly on port 8085."
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

register_service filebrowser utilities "Web file manager (FileBrowser)" 8085

install_filebrowser() {
    require_docker || return 1
    log_info "Installing Filebrowser..."
    local FB_DIR="$DOCKER_DIR/filebrowser"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $FB_DIR"
        return 0
    fi

    mkdir -p "$FB_DIR"
    ensure_docker_dir_ownership "$FB_DIR"
    cd "$FB_DIR" || return 1

    local FB_PATH=""
    prompt_text "Path to browse [default: $ACTUAL_HOME]:" "$ACTUAL_HOME" FB_PATH

    cat > docker-compose.yml << FB_COMPOSE
name: filebrowser

services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    hostname: filebrowser
    restart: unless-stopped
    environment:
      - TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
    volumes:
      - ${FB_PATH}:/srv
      - ./database/filebrowser.db:/database/filebrowser.db
      - ./config/settings.json:/config/settings.json
    ports:
      - "8085:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
FB_COMPOSE

    cat > .env << FB_ENV
FB_PATH=$FB_PATH
CADDY_NET=$SITE_CADDY_NET
FB_ENV

    mkdir -p database config
    touch database/filebrowser.db
    cat > config/settings.json << 'FB_SETTINGS'
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
FB_SETTINGS

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR"

    # Deploy user-management helper script
    local _TOOLS_DIR
    _TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" 2>/dev/null && pwd)" || true
    if [ -f "$_TOOLS_DIR/manage_users.sh" ]; then
        cp "$_TOOLS_DIR/manage_users.sh" "$FB_DIR/manage_users.sh"
        chmod 750 "$FB_DIR/manage_users.sh"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR/manage_users.sh"
        log_success "manage_users.sh installed at $FB_DIR/manage_users.sh"
    fi

    echo ""
    log_success "Filebrowser configured at $FB_DIR"

    configure_caddy_for_service "FileBrowser" "filebrowser:80" "files"

    write_readme "$FB_DIR" << MD
# FileBrowser

Web-based file manager. Browse, upload, and download files through a browser.

## Access
- URL: http://localhost:8085
- Default login: admin / admin (change immediately!)

## Data
- Browsed path: $FB_PATH (mounted to /srv)
- Database: ./database/filebrowser.db
- Settings: ./config/settings.json

## Manage
\`\`\`
cd $FB_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_FB=""
    prompt_yn "Start Filebrowser now? (y/n):" "y" START_FB
    if [ "$START_FB" = "y" ] || [ "$START_FB" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Filebrowser started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:8085"
    echo "  Default login: admin / admin (change immediately!)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_filebrowser
