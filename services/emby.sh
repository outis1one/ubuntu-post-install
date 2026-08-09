#!/bin/bash
# services/emby.sh — Media server for movies, TV, and music (Emby).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash emby.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- EMBY ----).
# Own ~/docker/emby/ with a standalone docker-compose.yml + .env. Hardware
# transcoding is left commented in the compose (uncomment the /dev/dri block
# once you've confirmed your GPU) to match the original behavior.

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

register_service emby media "Media server — movies, TV, music (Emby); supports a music-only setup with per-user library access" 8096

install_emby() {
    require_docker || return 1

    local EMBY_DIR="$DOCKER_DIR/emby"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Emby would:"
        echo "  - Ask whether this is a music-only setup (changes the default folder/guidance only —"
        echo "    which library types you add still happens in Emby's own web setup wizard)"
        echo "  - Create $EMBY_DIR with docker-compose.yml + .env (config/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) at /media"
        echo "  - Run as UID/GID $(id -u "$ACTUAL_USER")/$(id -g "$ACTUAL_USER")"
        echo "  - Expose ports 8096 (web) and 8920 (https)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MUSIC_ONLY=""
    prompt_yn "Set this up as a music-only server (skip movies/TV)? (y/n):" "n" MUSIC_ONLY

    local DEFAULT_FOLDER="$DEFAULT_MEDIA" FOLDER_PROMPT="Path to media folder"
    if [[ "$MUSIC_ONLY" =~ ^[Yy]$ ]]; then
        DEFAULT_FOLDER="$ACTUAL_HOME/music"
        FOLDER_PROMPT="Path to music folder"
    fi

    local MEDIA_PATH=""
    prompt_text "$FOLDER_PROMPT [$DEFAULT_FOLDER]:" "$DEFAULT_FOLDER" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH/#\~/$ACTUAL_HOME}"; MEDIA_PATH="${MEDIA_PATH%/}"

    mkdir -p "$EMBY_DIR"
    ensure_docker_dir_ownership "$EMBY_DIR"
    cd "$EMBY_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

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

    cat > docker-compose.yml << EMBY_COMPOSE
name: emby

services:
  emby:
    image: emby/embyserver:latest
    container_name: emby
    hostname: emby
    restart: unless-stopped
    environment:
      - UID=$UID_VAL
      - GID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config
      - \${MEDIA_PATH}:/media
    ports:
      - "8096:8096"
      - "8920:8920"
    # Uncomment for hardware transcoding (Intel/AMD):
    # devices:
    #   - /dev/dri:/dev/dri
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
EMBY_COMPOSE

    cat > .env << EMBY_ENV
MEDIA_PATH=$MEDIA_PATH
CADDY_NET=$SITE_CADDY_NET
EMBY_ENV

    mkdir -p config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EMBY_DIR"
    log_success "Emby configured at $EMBY_DIR"

    configure_caddy_for_service "Emby" "emby:8096" "emby"

    write_readme "$EMBY_DIR" << MD
# Emby

Media server for movies, TV, and music.

- Web UI: http://localhost:8096  (HTTPS on 8920)
- Media folder: \`$MEDIA_PATH\` → mounted at /media
- App data: \`config/\` in this folder
- Edit the media path in \`.env\` (\`MEDIA_PATH=\`), then \`docker compose up -d\`.

## Manage
\`\`\`bash
cd $EMBY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Hardware transcoding
Uncomment the \`devices: [/dev/dri:/dev/dri]\` block in \`docker-compose.yml\`
once you've confirmed your Intel/AMD GPU exposes a render node, then restart.
$( [[ "$MUSIC_ONLY" =~ ^[Yy]$ ]] && cat << MUSICMD

## Music-only setup (per-user library access)
This mount is meant to hold only your music library — which library types
you actually add still happens in Emby's own first-run setup wizard, not
this script (Emby has no compose/env flag for "music-only"; it's a web-UI
step):

1. Open http://localhost:8096 and complete the setup wizard.
2. When adding a library, choose type **Music**, point it at \`/media\`,
   and don't add any Movies/TV/other library types.
3. **Per-user library access** (the reason to pick Emby over a Squeezebox
   setup for this role): Dashboard → Users → select a user → **Access** tab
   → under "Library Access", uncheck "Enable access to all libraries" and
   pick only the libraries that user should see. Repeat per user. New users
   default to full access, so revisit this each time you add one.
4. Casting to Chromecast/other cast targets works out of the box from
   Emby's own apps — nothing to configure here for that.

Emby is a generalist media server, not a purpose-built music server — for
an always-on background/kiosk audio zone, a dedicated Squeezebox setup
(\`lyrion\`, with \`squeezelite\` as the player) is the more solid choice;
use this Emby instance for browser-based, per-user-restricted access
instead of as the primary always-on player.
MUSICMD
)
MD

    local START_EMBY=""
    prompt_yn "Start Emby now? (y/n):" "y" START_EMBY
    if [ "$START_EMBY" = "y" ] || [ "$START_EMBY" = "Y" ]; then
        docker compose up -d && log_success "Emby started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8096"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_emby
