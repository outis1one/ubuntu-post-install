#!/bin/bash
# services/syncthing.sh — Continuous file sync between devices (Syncthing).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash syncthing.sh
# (Docker must already be installed when run standalone)

# ── Standalone bootstrap ──────────────────────────────────────────────────────
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

            if [[ ! -d "$_caddy_dir" ]]; then
                log_info "Access $_name directly on port ${_upstream##*:}."
                return 0
            fi

            echo ""
            local _do_caddy=""
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:${_upstream##*:}"
                return 0
            }

            local _domain=""
            read -r -p "  Domain (e.g. ${_subdomain}.${SITE_DOMAIN:-example.com}): " _domain
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Back up before touching
            if [[ -f "$_caddyfile" ]]; then
                local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                cp "$_caddyfile" "$_bk"
                log_info "Backed up Caddyfile to $(basename "$_bk")"
            else
                touch "$_caddyfile"
            fi

            # Remove existing block for this domain if present
            if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                log_warning "$_domain already in Caddyfile"
                local _ow=""
                read -r -p "  Overwrite? [y/N]: " _ow
                [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
            fi

            cat >> "$_caddyfile" << CBLOCK

# $_name
$_domain {
    reverse_proxy $_upstream

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

            log_success "Added $_domain to Caddyfile"
            docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
            if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                log_success "$_name accessible at: https://$_domain"
            else
                log_warning "Reload failed — check: docker logs caddy"
                log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
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

register_service syncthing utilities "Continuous file sync between devices (Syncthing)" 8384

install_syncthing() {
    require_docker || return 1
    log_info "Installing Syncthing..."

    local DIR="$DOCKER_DIR/syncthing"
    local WEB_PORT="8384" SYNC_PORT="22000" DISCOVERY_PORT="21027"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml and .env"
        echo "[DRY-RUN] Would expose web UI on 8384, sync protocol on 22000 (tcp+udp), discovery on 21027/udp"
        echo "[DRY-RUN] All 3 auto-scanned/shifted together if occupied"
        return 0
    fi

    # Scan for free host ports, moving all 3 together — a plain install
    # shouldn't silently claim a port another already-running service holds.
    # Note: DISCOVERY_PORT (LAN broadcast) only works for zero-config local
    # discovery at its standard number — shifting it away from 21027 means
    # peers must be added manually by device ID instead of relying on
    # auto-discovery. See CLAUDE.md's "Port collision avoidance" section.
    while port_in_use "$WEB_PORT" || port_in_use "$SYNC_PORT" \
       || port_in_use "$SYNC_PORT" udp || port_in_use "$DISCOVERY_PORT" udp; do
        WEB_PORT=$((WEB_PORT + 1))
        SYNC_PORT=$((SYNC_PORT + 1))
        DISCOVERY_PORT=$((DISCOVERY_PORT + 1))
    done

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local PUID PGID
    PUID="$(id -u "$ACTUAL_USER")"
    PGID="$(id -g "$ACTUAL_USER")"

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

    cat > docker-compose.yml << EOF
name: syncthing

services:
  syncthing:
    image: syncthing/syncthing:latest
    container_name: syncthing
    hostname: syncthing
    restart: unless-stopped
    environment:
      - PUID=\${PUID:-$PUID}
      - PGID=\${PGID:-$PGID}
      - TZ=\${SITE_TZ:-UTC}
    ports:
      - "${WEB_PORT}:8384"
      - "${SYNC_PORT}:22000/tcp"
      - "${SYNC_PORT}:22000/udp"
      - "${DISCOVERY_PORT}:21027/udp"
    volumes:
      - ./config:/var/syncthing/config
      - ./data:/var/syncthing
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
EOF

    cat > .env << ENV
CADDY_NET=$SITE_CADDY_NET
PUID=$PUID
PGID=$PGID
SITE_TZ=$SITE_TZ
ENV

    chmod 600 .env
    chown "$ACTUAL_USER:$ACTUAL_USER" .env

    configure_caddy_for_service "Syncthing" "syncthing:8384" "sync"

    write_readme "$DIR" << MD
# Syncthing

Continuous, decentralised file synchronisation between devices.

## Access
- Web UI: http://localhost:${WEB_PORT}
- First run: go to **Settings → GUI** and set a username and password.
$( [ "$DISCOVERY_PORT" != "21027" ] && echo "
**Note:** the default ports were already in use, so this instance's ports
were shifted — see below. Local LAN auto-discovery only works at the
standard 21027/udp; with a shifted discovery port, add other devices
manually by device ID instead of relying on auto-discovery." )

## Firewall ports (for LAN sync)
Open these on the host firewall so other Syncthing devices can reach this node:
\`\`\`
sudo ufw allow ${SYNC_PORT}/tcp comment "Syncthing sync protocol"
sudo ufw allow ${SYNC_PORT}/udp comment "Syncthing sync protocol (QUIC)"
sudo ufw allow ${DISCOVERY_PORT}/udp comment "Syncthing local discovery"
\`\`\`

## Manage
\`\`\`
cd $DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d  # update
\`\`\`
MD

    local START=""
    prompt_yn "Start Syncthing now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "Syncthing started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo "  First run:  set a username and password in Settings → GUI"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_syncthing
