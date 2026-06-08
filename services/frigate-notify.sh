#!/bin/bash
# services/frigate-notify.sh — Push notification sidecar for Frigate events.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash frigate-notify.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FRIGATE-NOTIFY ----).
# Own ~/docker/frigate-notify/ with a standalone docker-compose.yml + config.yml.
# Supports ntfy, Pushover, Discord, Gotify, Telegram, and more. No web UI.
# Auto-detects local Frigate and ntfy installs to pre-fill config defaults.

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

register_service frigate-notify cameras "Push alerts for Frigate detection events (Frigate-Notify)"

install_frigate-notify() {
    require_docker || return 1

    local FN_DIR="$DOCKER_DIR/frigate-notify"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Frigate-Notify would:"
        echo "  - Create $FN_DIR with docker-compose.yml + config.yml"
        echo "  - Auto-detect local Frigate and ntfy installs"
        echo "  - No web UI — configure via config.yml"
        return 0
    fi

    mkdir -p "$FN_DIR"
    ensure_docker_dir_ownership "$FN_DIR"
    cd "$FN_DIR" || return 1

    cat > docker-compose.yml << 'FN_COMPOSE'
name: frigate-notify

services:
  frigate-notify:
    image: ghcr.io/0x2142/frigate-notify:latest
    container_name: frigate-notify
    hostname: frigate-notify
    restart: unless-stopped
    volumes:
      - ./config.yml:/app/config.yml:ro
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
FN_COMPOSE

    # Smart defaults based on what's installed
    local FRIGATE_URL="http://frigate:5000"
    local NTFY_URL="https://ntfy.sh"
    local NTFY_TOPIC="frigate-alerts"

    if [ -d "$DOCKER_DIR/frigate" ]; then
        log_success "Local Frigate detected — using http://frigate:5000"
    else
        log_warning "Frigate not found locally — using default URL (update config.yml if needed)"
    fi

    if [ -d "$DOCKER_DIR/ntfy" ]; then
        NTFY_URL="http://ntfy:80"
        log_success "Local ntfy detected — using http://ntfy:80"
    else
        log_warning "Local ntfy not found — using ntfy.sh (update config.yml for self-hosted)"
    fi

    echo ""
    prompt_text "Frigate URL [$FRIGATE_URL]:" "$FRIGATE_URL" FRIGATE_URL
    prompt_text "ntfy server URL [$NTFY_URL]:" "$NTFY_URL" NTFY_URL
    prompt_text "ntfy topic [frigate-alerts]:" "frigate-alerts" NTFY_TOPIC

    cat > config.yml << FN_CONFIG
# Frigate-Notify Configuration
# Docs: https://frigate-notify.0x2142.com
#
# Edit this file if notifications don't arrive — check Frigate URL,
# ntfy server, and that containers share a Docker network.

frigate:
  server: $FRIGATE_URL
  webapi:
    enabled: true
    interval: 30

alerts:
  general:
    send_startup_message: true
  labels:
    - person
    - car
    # - dog
    # - package

notifiers:
  - name: ntfy
    enabled: true
    provider: ntfy
    config:
      server: $NTFY_URL
      topic: $NTFY_TOPIC
FN_CONFIG

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FN_DIR"
    log_success "Frigate-Notify configured at $FN_DIR"

    write_readme "$FN_DIR" << MD
# Frigate-Notify

Push notification sidecar for Frigate — sends alerts when Frigate detects
people, cars, animals, or custom objects. Supports ntfy, Pushover, Discord,
Gotify, Telegram, and more. No web UI.

- Config: \`config.yml\` — edit notification targets here
- Frigate events polled every 30 seconds by default
- Docs: https://frigate-notify.0x2142.com

## Manage
\`\`\`bash
cd $FN_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # check for delivery errors
docker compose pull && docker compose up -d   # update
\`\`\`

## Adding more notifiers
Edit \`config.yml\` and add entries under \`notifiers:\`. Supported providers:
ntfy, Pushover, Discord (webhook), Gotify, Telegram, SMTP, and more.
See: https://frigate-notify.0x2142.com/configuration/alerts/
MD

    local START_FN=""
    prompt_yn "Start Frigate-Notify now? (y/n):" "y" START_FN
    if [ "$START_FN" = "y" ] || [ "$START_FN" = "Y" ]; then
        docker compose up -d && log_success "Frigate-Notify started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Config:  $FN_DIR/config.yml"
    echo "  Docs:    https://frigate-notify.0x2142.com"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_frigate-notify
