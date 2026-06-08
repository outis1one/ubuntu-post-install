#!/bin/bash
# services/jellyfin.sh — Free media server for movies, TV, and music (Jellyfin).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash jellyfin.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- JELLYFIN ----).
# Lives in its own ~/docker/jellyfin/ with a standalone docker-compose.yml + .env.
# Hardware transcoding (Intel/AMD VAAPI) is auto-enabled when a render node
# (/dev/dri/renderD128) is present on the host.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
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

register_service jellyfin media "Free media server — movies, TV, music (Jellyfin)" 8096

install_jellyfin() {
    require_docker || return 1

    local JELLYFIN_DIR="$DOCKER_DIR/jellyfin"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Jellyfin would:"
        echo "  - Create $JELLYFIN_DIR with docker-compose.yml + .env (config/ cache/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) read-only at /media"
        echo "  - Auto-enable VAAPI hw transcoding if /dev/dri/renderD128 exists"
        echo "  - Expose port 8096 (+ DLNA 1900/udp, discovery 7359/udp)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MEDIA_PATH=""
    prompt_text "Path to media folder [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH/#\~/$ACTUAL_HOME}"; MEDIA_PATH="${MEDIA_PATH%/}"

    mkdir -p "$JELLYFIN_DIR"
    ensure_docker_dir_ownership "$JELLYFIN_DIR"
    cd "$JELLYFIN_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # Hardware acceleration: only wire /dev/dri through if a render node exists,
    # otherwise the container would fail to start on a GPU-less host.
    local HWACCEL_BLOCK="" RENDER_GID
    if [ -e /dev/dri/renderD128 ]; then
        RENDER_GID=$(getent group render | cut -d: -f3 2>/dev/null || echo "989")
        HWACCEL_BLOCK="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
    group_add:
      - \"$RENDER_GID\""
        log_success "Render node found — enabling VAAPI hardware transcoding (render gid $RENDER_GID)"
    else
        log_warning "No /dev/dri/renderD128 — Jellyfin will use CPU transcoding."
    fi

    cat > docker-compose.yml << JELLYFIN_COMPOSE
name: jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
$HWACCEL_BLOCK
    volumes:
      - ./config:/config
      - ./cache:/cache
      - \${MEDIA_PATH}:/media:ro
    ports:
      - "8096:8096"
      - "1900:1900/udp"
      - "7359:7359/udp"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
JELLYFIN_COMPOSE

    cat > .env << JELLYFIN_ENV
MEDIA_PATH=$MEDIA_PATH
CADDY_NET=$SITE_CADDY_NET
JELLYFIN_ENV

    mkdir -p config cache
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JELLYFIN_DIR"
    log_success "Jellyfin configured at $JELLYFIN_DIR"

    configure_caddy_for_service "Jellyfin" "jellyfin:8096" "jellyfin"

    write_readme "$JELLYFIN_DIR" << MD
# Jellyfin

Free media server (movies, TV, music) — a no-paywall alternative to Emby.

- Web UI: http://localhost:8096
- Media folder (read-only): \`$MEDIA_PATH\` → mounted at /media
- App data: \`config/\` and \`cache/\` in this folder
- Edit the media path in \`.env\` (\`MEDIA_PATH=\`), then \`docker compose up -d\`.

## Manage
\`\`\`bash
cd $JELLYFIN_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- Hardware transcoding (Intel/AMD VAAPI) is enabled automatically when
  \`/dev/dri/renderD128\` exists on the host; otherwise transcoding is CPU-only.
- First launch: open the web UI and complete the setup wizard, then add your
  media libraries pointing at /media.
MD

    local START_JF=""
    prompt_yn "Start Jellyfin now? (y/n):" "y" START_JF
    if [ "$START_JF" = "y" ] || [ "$START_JF" = "Y" ]; then
        docker compose up -d && log_success "Jellyfin started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8096"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_jellyfin
