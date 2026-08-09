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

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "jellyfin" name/paths/ports exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces suffixed naming — same pattern as
    # services/mattermost.sh and services/wordpress.sh (and services/emby.sh,
    # the same idea for a sibling media server).
    local JELLYFIN_DIR="$DOCKER_DIR/jellyfin"
    local INSTANCE_SUFFIX="" CONTAINER="jellyfin"
    local WEB_PORT="8096"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Jellyfin would:"
        echo "  - Offer to add a new, separate instance if one already exists"
        echo "  - Create \$DOCKER_DIR/jellyfin(-<name>) with docker-compose.yml + .env (config/ cache/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) read-only at /media"
        echo "  - Auto-enable VAAPI hw transcoding if /dev/dri/renderD128 exists"
        echo "  - Expose port 8096, auto-scanned for additional instances"
        echo "  - First instance only: DLNA 1900/udp + discovery 7359/udp (host-wide;"
        echo "    additional instances skip these to avoid a fixed-port conflict)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    if [ -d "$JELLYFIN_DIR" ]; then
        echo ""
        echo "  Jellyfin is already installed at $JELLYFIN_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Jellyfin instance alongside it (its own"
        echo "       server, library, and port — full isolation)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'kids'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/jellyfin-$_suffix" ]; then
                    log_warning "jellyfin-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            JELLYFIN_DIR="$DOCKER_DIR/jellyfin-$_suffix"
            CONTAINER="jellyfin-$_suffix"
            DEFAULT_MEDIA="$ACTUAL_HOME/media-$_suffix"

            while ss -tlnH "sport = :${WEB_PORT}" 2>/dev/null | grep -q .; do
                WEB_PORT=$((WEB_PORT + 1))
            done
            log_info "New instance: $JELLYFIN_DIR (port $WEB_PORT)"
            log_warning "DLNA/discovery (1900/udp, 7359/udp) are fixed, host-wide ports already"
            log_warning "claimed by the first instance — this instance skips them (web UI and"
            log_warning "app-based streaming are unaffected; DLNA auto-discovery is not)."
        fi
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

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_BLOCK=""
    local _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    # DLNA (1900/udp) and discovery (7359/udp) are fixed, host-wide UDP ports —
    # only the first instance publishes them to avoid a bind conflict with an
    # existing instance. Additional instances still work for the web UI and
    # every app-based client; only DLNA/network auto-discovery is instance-1-only.
    local _DISCOVERY_PORTS=""
    if [ -z "$INSTANCE_SUFFIX" ]; then
        _DISCOVERY_PORTS='      - "1900:1900/udp"
      - "7359:7359/udp"
'
    fi

    cat > docker-compose.yml << JELLYFIN_COMPOSE
name: $CONTAINER

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
$HWACCEL_BLOCK
    volumes:
      - ./config:/config
      - ./cache:/cache
      - \${MEDIA_PATH}:/media:ro
    ports:
      - "${WEB_PORT}:8096"
${_DISCOVERY_PORTS}${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
JELLYFIN_COMPOSE

    cat > .env << JELLYFIN_ENV
MEDIA_PATH=$MEDIA_PATH
CADDY_NET=$SITE_CADDY_NET
JELLYFIN_ENV

    mkdir -p config cache
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JELLYFIN_DIR"
    log_success "Jellyfin${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $JELLYFIN_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Jellyfin${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:8096" "jellyfin${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    write_readme "$JELLYFIN_DIR" << MD
# Jellyfin${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Free media server (movies, TV, music) — a no-paywall alternative to Emby.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own library, own
port) — not a shared library with another Jellyfin instance. DLNA and
network auto-discovery are only published for the first instance (fixed,
host-wide ports); this instance still works for the web UI and every
app-based client.")

- Web UI: http://localhost:${WEB_PORT}
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
    prompt_yn "Start Jellyfin${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_JF
    if [ "$START_JF" = "y" ] || [ "$START_JF" = "Y" ]; then
        docker compose up -d && log_success "Jellyfin${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_jellyfin
