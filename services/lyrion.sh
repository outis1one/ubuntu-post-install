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

register_service lyrion media "Music streaming server — Squeezebox, Chromecast (Lyrion)" 9000

install_lyrion() {
    require_docker || return 1

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "lyrion" name/paths/ports and
    # network_mode: host exactly as before (zero behavior change for anyone
    # with a single instance) — host networking is what makes Chromecast and
    # Squeezebox UDP broadcast/multicast discovery work without manual setup.
    #
    # A second instance CANNOT also use network_mode: host — both would bind
    # the same fixed host ports (9000/9090/3483) and collide outright, and
    # Docker only allows one container on host networking to own a given port.
    # So additional instances switch to bridge networking with auto-scanned,
    # per-instance ports instead. The tradeoff: bridge mode means this
    # instance loses the zero-config broadcast/multicast auto-discovery that
    # host networking provides — Chromecasts and Squeezebox hardware won't
    # find it automatically. Players still work, just not auto-discovered:
    # point the Squeezer app / Squeezebox firmware at this server's address
    # and port manually instead of relying on discovery.
    local LYRION_DIR="$DOCKER_DIR/lyrion"
    local INSTANCE_SUFFIX="" CONTAINER="lyrion"
    local USE_HOST_NETWORK=true
    local WEB_PORT="9000" CLI_PORT="9090" PLAYER_PORT="3483"
    local DEFAULT_MUSIC="$ACTUAL_HOME/music"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Lyrion Music Server would:"
        echo "  - Offer to add a new, separate instance if one already exists"
        echo "  - Create \$DOCKER_DIR/lyrion(-<name>) with docker-compose.yml + .env (config/ playlists/)"
        echo "  - Mount a music folder (default $DEFAULT_MUSIC) read-only at /music"
        echo "  - First instance: network_mode: host (Chromecast/Squeezebox UDP discovery)"
        echo "    ports 9000 (web), 9090 (CLI), 3483 (players)"
        echo "  - Additional instances: bridge networking with auto-scanned ports —"
        echo "    loses zero-config discovery; players need the server address entered manually"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    if [ -d "$LYRION_DIR" ]; then
        echo ""
        echo "  Lyrion is already installed at $LYRION_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Lyrion instance alongside it (its own"
        echo "       server, library, and ports — full isolation)"
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
                if [ -d "$DOCKER_DIR/lyrion-$_suffix" ]; then
                    log_warning "lyrion-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            LYRION_DIR="$DOCKER_DIR/lyrion-$_suffix"
            CONTAINER="lyrion-$_suffix"
            DEFAULT_MUSIC="$ACTUAL_HOME/music-$_suffix"
            USE_HOST_NETWORK=false

            log_warning "Additional Lyrion instances use bridge networking (not host) so they"
            log_warning "don't collide with the first instance's fixed ports. This instance"
            log_warning "loses zero-config Chromecast/Squeezebox discovery — enter its address"
            log_warning "manually in the Squeezer app / Squeezebox firmware instead."
            log_info "New instance: $LYRION_DIR"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$LYRION_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the Lyrion image only — existing config, port, and Caddy setup are left as-is."
                        ( cd "$LYRION_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "Lyrion image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $LYRION_DIR/docker-compose.yml logs"
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

    # Port collision avoidance — see CLAUDE.md's "Port collision avoidance"
    # section. Bridge-mode instances can fully auto-scan (all 3 ports move
    # together). Host-mode (the first instance) can only auto-adjust
    # WEB_PORT — HTTP_PORT is a real env var the image honors even under
    # host networking — CLI_PORT/PLAYER_PORT are hardcoded inside the image
    # with no override, so a collision there can only be warned about, not
    # silently fixed.
    if [ "$USE_HOST_NETWORK" = true ]; then
        find_free_port WEB_PORT "$WEB_PORT"
        port_in_use "$CLI_PORT" && log_warning "CLI port $CLI_PORT is already in use by another process — Lyrion's CLI interface won't be reachable until that's resolved (this port isn't configurable in the image)."
        port_in_use "$PLAYER_PORT" && log_warning "Player port $PLAYER_PORT is already in use by another process — Squeezebox/app connections won't work until that's resolved (this port isn't configurable in the image)."
    else
        while port_in_use "$WEB_PORT" || port_in_use "$CLI_PORT" || port_in_use "$PLAYER_PORT"; do
            WEB_PORT=$((WEB_PORT + 1))
            CLI_PORT=$((CLI_PORT + 1))
            PLAYER_PORT=$((PLAYER_PORT + 1))
        done
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

    # Host mode has no ports: remapping — HTTP_PORT is the only thing that
    # actually controls the bind port, so it must track the scanned WEB_PORT.
    # Bridge mode keeps the container's internal port fixed at 9000 and lets
    # the ports: line do the remapping instead.
    local _NETWORK_BLOCK="    network_mode: host
"
    local _PORTS_BLOCK=""
    local _HTTP_PORT_INTERNAL="$WEB_PORT"
    if [ "$USE_HOST_NETWORK" != true ]; then
        _NETWORK_BLOCK=""
        _PORTS_BLOCK="    ports:
      - \"${WEB_PORT}:9000\"
      - \"${CLI_PORT}:9090\"
      - \"${PLAYER_PORT}:3483\"
"
        _HTTP_PORT_INTERNAL="9000"
    fi

    cat > docker-compose.yml << LYRION_COMPOSE
name: $CONTAINER

services:
  lyrion:
    image: lmscommunity/lyrionmusicserver:stable
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
${_NETWORK_BLOCK}${_PORTS_BLOCK}    environment:
      - HTTP_PORT=$_HTTP_PORT_INTERNAL
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config:rw
      - \${MUSIC_PATH}:/music:ro
      - ./playlists:/playlists:rw
      - /etc/localtime:/etc/localtime:ro

LYRION_COMPOSE

    cat > .env << LYRION_ENV
MUSIC_PATH=$MUSIC_PATH
CADDY_NET=$SITE_CADDY_NET
LYRION_ENV

    mkdir -p config playlists
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LYRION_DIR"
    log_success "Lyrion Music Server${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $LYRION_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Lyrion${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${WEB_PORT}" "lyrion${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    write_readme "$LYRION_DIR" << MD
# Lyrion Music Server${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Stream music to Squeezebox devices, the Squeezer Android/iOS app, and Chromecast.
Formerly known as Logitech Media Server (LMS).
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own library, own
ports) — not a shared library with another Lyrion instance. It runs on
**bridge networking**, not host networking, so it does NOT get zero-config
Chromecast/Squeezebox discovery — enter this server's address and port
manually in the Squeezer app or Squeezebox firmware instead of relying on
auto-discovery.")

- Web UI: http://localhost:${WEB_PORT}
- Player port: ${PLAYER_PORT} (Squeezeboxes / apps)
- CLI port: ${CLI_PORT}
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
$( [ "$USE_HOST_NETWORK" = true ] && echo "- Uses \`network_mode: host\` so UDP discovery for Chromecast and Squeezebox devices
  works without manual port mapping." || echo "- Uses bridge networking (auto-scanned ports) since the first instance already
  owns the fixed host-networking ports. Discovery is manual for this instance." )
- Change the music path in \`.env\` (\`MUSIC_PATH=\`), then \`docker compose up -d\`.
- Add music libraries in the web UI under Settings → Music Library.
MD

    local START_LMS=""
    prompt_yn "Start Lyrion Music Server${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_LMS
    if [ "$START_LMS" = "y" ] || [ "$START_LMS" = "Y" ]; then
        docker compose up -d && log_success "Lyrion${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:${WEB_PORT}"
    if [ "$USE_HOST_NETWORK" = true ]; then
        echo "  Note: uses host networking for Chromecast/Squeezebox UDP discovery"
    else
        echo "  Note: uses bridge networking — no auto-discovery, configure players manually"
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_lyrion
