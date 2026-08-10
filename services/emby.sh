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

        port_in_use() {
            local _port="$1" _proto="${2:-tcp}"
            local _flag="-tlnH"
            [ "$_proto" = "udp" ] && _flag="-ulnH"
            ss "$_flag" "sport = :${_port}" 2>/dev/null | grep -q .
        }

        find_free_port() {
            local _varname="$1" _port="$2" _proto="${3:-tcp}"
            while port_in_use "$_port" "$_proto"; do
                _port=$((_port + 1))
            done
            eval "$_varname='$_port'"
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

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "emby" name/paths/ports exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces suffixed naming — same pattern as
    # services/mattermost.sh and services/wordpress.sh.
    local EMBY_DIR="$DOCKER_DIR/emby"
    local INSTANCE_SUFFIX="" CONTAINER="emby"
    local WEB_PORT="8096" HTTPS_PORT="8920"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Emby would:"
        echo "  - Offer to add a new, separate instance if one already exists"
        echo "  - Ask whether this is a music-only setup (changes the default folder/guidance only —"
        echo "    which library types you add still happens in Emby's own web setup wizard)"
        echo "  - Create \$DOCKER_DIR/emby(-<name>) with docker-compose.yml + .env (config/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) at /media"
        echo "  - Run as UID/GID $(id -u "$ACTUAL_USER")/$(id -g "$ACTUAL_USER")"
        echo "  - Auto-scan for free host ports if this is an additional instance"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    if [ -d "$EMBY_DIR" ]; then
        echo ""
        echo "  Emby is already installed at $EMBY_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Emby instance alongside it (its own server,"
        echo "       library, and ports — full isolation, not another Emby library)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'music'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/emby-$_suffix" ]; then
                    log_warning "emby-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            EMBY_DIR="$DOCKER_DIR/emby-$_suffix"
            CONTAINER="emby-$_suffix"
            DEFAULT_MEDIA="$ACTUAL_HOME/media-$_suffix"
            log_info "New instance: $EMBY_DIR"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$EMBY_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the Emby image only — existing config, port, and Caddy setup are left as-is."
                        ( cd "$EMBY_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "Emby image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $EMBY_DIR/docker-compose.yml logs"
                        return 0
                        ;;
                    cancel)
                        log_info "Leaving the existing install as-is."
                        return 0
                        ;;
                    fresh) ;;  # fall through to the full install flow below
                esac
            fi
        fi
    fi

    # Scan for free ports unconditionally — not just when adding an explicit
    # additional instance. A plain first install can just as easily collide
    # with an unrelated service that already claimed these default ports
    # (e.g. jellyfin also defaults to 8096) — see CLAUDE.md's "Port collision
    # avoidance" section.
    find_free_port WEB_PORT "$WEB_PORT"
    find_free_port HTTPS_PORT "$HTTPS_PORT"

    local MUSIC_ONLY=""
    prompt_yn "Set this up as a music-only server (skip movies/TV)? (y/n):" "n" MUSIC_ONLY

    local DEFAULT_FOLDER="$DEFAULT_MEDIA" FOLDER_PROMPT="Path to media folder"
    if [[ "$MUSIC_ONLY" =~ ^[Yy]$ ]]; then
        DEFAULT_FOLDER="$ACTUAL_HOME/music"
        FOLDER_PROMPT="Path to music folder"
    fi

    # Reset before the chain call, not after — VDM_LAST_MOUNT_POINT is a
    # plain global set by services/vpn-data-mount.sh, so without this an
    # unrelated earlier vpn-data-mount run in the same setup.sh session
    # would silently leak its mount point in here as the default even if
    # the user declines below or this chain never runs at all.
    unset VDM_LAST_MOUNT_POINT
    if declare -F install_vpn-data-mount >/dev/null 2>&1; then
        local USE_VPN_DATA=""
        prompt_yn "Is your media on a VPN-connected home box that isn't mounted yet? (y/n):" "n" USE_VPN_DATA
        [[ "$USE_VPN_DATA" =~ ^[Yy]$ ]] && install_vpn-data-mount
    fi
    [ -n "${VDM_LAST_MOUNT_POINT:-}" ] && DEFAULT_FOLDER="$VDM_LAST_MOUNT_POINT"

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
name: $CONTAINER

services:
  emby:
    image: emby/embyserver:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    environment:
      - UID=$UID_VAL
      - GID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config
      - \${MEDIA_PATH}:/media
    ports:
      - "${WEB_PORT}:8096"
      - "${HTTPS_PORT}:8920"
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
    log_success "Emby${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $EMBY_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Emby${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:8096" "emby${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    write_readme "$EMBY_DIR" << MD
# Emby${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Media server for movies, TV, and music.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own library, own
ports) — not another library within another Emby instance.")

- Web UI: http://localhost:${WEB_PORT}  (HTTPS on ${HTTPS_PORT})
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

1. Open http://localhost:${WEB_PORT} and complete the setup wizard.
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
    prompt_yn "Start Emby${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_EMBY
    if [ "$START_EMBY" = "y" ] || [ "$START_EMBY" = "Y" ]; then
        docker compose up -d && log_success "Emby${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_emby
