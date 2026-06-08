#!/bin/bash
# services/watchtower.sh — Watchtower automatic container update monitoring.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash watchtower.sh
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

register_service watchtower utilities "Automatic container updates (Watchtower)"

install_watchtower() {
    require_docker || return 1
    log_info "Installing Watchtower..."
    local WT_DIR="$DOCKER_DIR/watchtower"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $WT_DIR"
        return 0
    fi

    mkdir -p "$WT_DIR" 2>/dev/null || true
    ensure_docker_dir_ownership "$WT_DIR"
    cd "$WT_DIR" 2>/dev/null || cd "$DOCKER_DIR" || return 1

    # Ask about mode
    echo ""
    echo "Watchtower Mode:"
    echo "  [M] Monitor only - Get notifications about available updates (SAFE)"
    echo "  [A] Auto-update - Automatically pull and restart containers (RISKY)"
    echo ""
    echo "  ⚠️  Auto-update can break apps like Immich that need DB migrations!"
    echo "  Recommendation: Use monitor mode, update manually when ready."
    echo ""
    local WT_MODE="M"
    prompt_text "Mode [M/A]:" "M" WT_MODE
    WT_MODE=$(echo "$WT_MODE" | tr '[:lower:]' '[:upper:]')

    local MONITOR_ONLY
    if [ "$WT_MODE" = "A" ]; then
        MONITOR_ONLY="false"
        echo "  Mode: Auto-update (containers will be updated automatically)"
    else
        MONITOR_ONLY="true"
        echo "  Mode: Monitor only (you'll be notified of updates)"
    fi

    # Check for ntfy
    local NTFY_URL=""
    if [ -d "$DOCKER_DIR/ntfy" ]; then
        echo "  ✓ ntfy detected - configuring notifications"
        NTFY_URL="http://ntfy/watchtower"
    fi

    cat > docker-compose.yml << WT_COMPOSE
name: watchtower

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    hostname: watchtower
    restart: unless-stopped
    environment:
      # Check for updates daily at 4 AM
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      # Monitor only - don't auto-update (change to false for auto-update)
      - WATCHTOWER_MONITOR_ONLY=${MONITOR_ONLY}
      # Cleanup old images after update
      - WATCHTOWER_CLEANUP=true
      # Include stopped containers
      - WATCHTOWER_INCLUDE_STOPPED=true
      # Notification URL (ntfy, Discord, Slack, etc.)
      - WATCHTOWER_NOTIFICATION_URL=\${NOTIFICATION_URL:-}
      # Show debug info
      - WATCHTOWER_DEBUG=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
WT_COMPOSE

    # Create .env
    cat > .env << WT_ENV
# Watchtower Configuration
# =========================
#
# Monitor-only mode: Watchtower checks for updates but doesn't apply them.
# This is SAFER because some apps (Immich, Mealie) have database migrations
# that can break if you update without proper procedures.
#
# To update manually:
#   cd ~/docker/{app}
#   docker compose pull
#   docker compose up -d

# Set to "false" to enable auto-updates (RISKY!)
MONITOR_ONLY=$MONITOR_ONLY

# Notification URL (optional)
# Examples:
#   ntfy:    ntfy://ntfy.example.com/watchtower
#   Discord: discord://token@id
#   Slack:   slack://hook-url
#   Gotify:  gotify://hostname/token
#
# Full list: https://containrrr.dev/shoutrrr/services/overview/
NOTIFICATION_URL=$NTFY_URL
CADDY_NET=$SITE_CADDY_NET
WT_ENV

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WT_DIR" 2>/dev/null || true

    echo ""
    log_success "Watchtower installed at $WT_DIR"

    write_readme "$WT_DIR" << MD
# Watchtower

Monitors running containers for image updates. Defaults to NOTIFY-ONLY mode,
because apps like Immich can have breaking DB migrations on auto-update.

## No web interface
Watchtower has no web UI/port. It runs in the background and checks for updates
daily at 4 AM.

## Configuration
- Mode: $([ "$MONITOR_ONLY" = "true" ] && echo "Monitor only" || echo "Auto-update") (set MONITOR_ONLY in .env; "false" = auto-update)
- Notifications: set NOTIFICATION_URL in .env (ntfy, Discord, Slack, Gotify, ...)
  See https://containrrr.dev/shoutrrr/services/overview/

## Exclude a container
Add this label to any container you want Watchtower to ignore:
\`com.centurylinklabs.watchtower.enable=false\`

## Update an app manually
\`\`\`
cd ~/docker/<app>
docker compose pull
docker compose up -d
\`\`\`

## Manage
\`\`\`
cd $WT_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_WATCHTOWER=""
    prompt_yn "Start Watchtower now? (y/n):" "y" START_WATCHTOWER
    if [ "$START_WATCHTOWER" = "y" ] || [ "$START_WATCHTOWER" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Watchtower started" || log_warning "Failed to start"
    fi

    echo "  Mode: $([ "$MONITOR_ONLY" = "true" ] && echo "Monitor only" || echo "Auto-update")"
    echo ""
    echo "  Checks for updates daily at 4 AM."
    if [ -n "$NTFY_URL" ]; then
        echo "  Notifications: $NTFY_URL"
    else
        echo "  Configure NOTIFICATION_URL in .env for alerts."
    fi
    echo ""
    echo "  To exclude a container from Watchtower:"
    echo "    Add label: com.centurylinklabs.watchtower.enable=false"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_watchtower
