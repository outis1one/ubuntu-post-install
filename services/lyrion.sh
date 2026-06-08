#!/bin/bash
# services/lyrion.sh — Lyrion Music Server for Squeezebox devices, apps, Chromecast.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash lyrion.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- LYRION MUSIC SERVER ----).
# Uses network_mode: host so UDP discovery (Chromecast, Squeezebox) works without
# manual port-forwarding. Own ~/docker/lyrion/ with compose + .env.

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

register_service lyrion media "Music streaming server — Squeezebox, Chromecast (Lyrion)" 9000

install_lyrion() {
    require_docker || return 1

    local LYRION_DIR="$DOCKER_DIR/lyrion"
    local DEFAULT_MUSIC="$ACTUAL_HOME/music"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Lyrion Music Server would:"
        echo "  - Create $LYRION_DIR with docker-compose.yml + .env (config/ playlists/)"
        echo "  - Mount a music folder (default $DEFAULT_MUSIC) read-only at /music"
        echo "  - Run with network_mode: host (required for Chromecast/Squeezebox UDP discovery)"
        echo "  - Expose port 9000 (web), 9090 (CLI), 3483 (players)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MUSIC_PATH=""
    prompt_text "Path to music folder [$DEFAULT_MUSIC]:" "$DEFAULT_MUSIC" MUSIC_PATH
    MUSIC_PATH="${MUSIC_PATH/#\~/$ACTUAL_HOME}"; MUSIC_PATH="${MUSIC_PATH%/}"

    mkdir -p "$LYRION_DIR"
    ensure_docker_dir_ownership "$LYRION_DIR"
    cd "$LYRION_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << LYRION_COMPOSE
name: lyrion

services:
  lyrion:
    image: lmscommunity/lyrionmusicserver:stable
    container_name: lyrion
    hostname: lyrion
    restart: unless-stopped
    network_mode: host
    environment:
      - HTTP_PORT=9000
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config:rw
      - \${MUSIC_PATH}:/music:ro
      - ./playlists:/playlists:rw
      - /etc/localtime:/etc/localtime:ro

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
LYRION_COMPOSE

    cat > .env << LYRION_ENV
MUSIC_PATH=$MUSIC_PATH
CADDY_NET=$SITE_CADDY_NET
LYRION_ENV

    mkdir -p config playlists
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LYRION_DIR"
    log_success "Lyrion Music Server configured at $LYRION_DIR"

    configure_caddy_for_service "Lyrion" "9000" "lyrion"

    write_readme "$LYRION_DIR" << MD
# Lyrion Music Server

Stream music to Squeezebox devices, the Squeezer Android/iOS app, and Chromecast.
Formerly known as Logitech Media Server (LMS).

- Web UI: http://localhost:9000
- Player port: 3483 (Squeezeboxes / apps)
- CLI port: 9090
- Music folder (read-only): \`$MUSIC_PATH\` → mounted at /music
- App data: \`config/\` and \`playlists/\`

## Manage
\`\`\`bash
cd $LYRION_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- Uses \`network_mode: host\` so UDP discovery for Chromecast and Squeezebox devices
  works without manual port mapping.
- Change the music path in \`.env\` (\`MUSIC_PATH=\`), then \`docker compose up -d\`.
- Add music libraries in the web UI under Settings → Music Library.
MD

    local START_LMS=""
    prompt_yn "Start Lyrion Music Server now? (y/n):" "y" START_LMS
    if [ "$START_LMS" = "y" ] || [ "$START_LMS" = "Y" ]; then
        docker compose up -d && log_success "Lyrion started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:9000"
    echo "  Note: uses host networking for Chromecast/Squeezebox UDP discovery"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_lyrion
