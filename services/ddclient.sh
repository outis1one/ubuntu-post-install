#!/bin/bash
# services/ddclient.sh — Dynamic DNS updater (ddclient).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash ddclient.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- DDCLIENT ----).
# Own ~/docker/ddclient/ with a standalone docker-compose.yml + config.
# Supports Cloudflare, DuckDNS, No-IP, and many other providers.
# Edit config/ddclient.conf before starting — no web UI.

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

register_service ddclient utilities "Dynamic DNS updater — keep your domain pointing at your home IP (ddclient)"

install_ddclient() {
    require_docker || return 1

    local DDCLIENT_DIR="$DOCKER_DIR/ddclient"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] ddclient would:"
        echo "  - Create $DDCLIENT_DIR with docker-compose.yml + config/ddclient.conf template"
        echo "  - No web UI — edit config/ddclient.conf for your DNS provider before starting"
        return 0
    fi

    mkdir -p "$DDCLIENT_DIR"
    ensure_docker_dir_ownership "$DDCLIENT_DIR"
    cd "$DDCLIENT_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'DDCLIENT_COMPOSE'
name: ddclient

services:
  ddclient:
    image: lscr.io/linuxserver/ddclient:latest
    container_name: ddclient
    hostname: ddclient
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}
    volumes:
      - ./config:/config
DDCLIENT_COMPOSE

    cat > .env << DDCLIENT_ENV
TZ=$TZ_VAL
DDCLIENT_ENV

    mkdir -p config

    cat > config/ddclient.conf << 'DDCLIENT_CONF'
# ddclient configuration
# Docs: https://ddclient.net/
#
# ⚠️  YOU MUST EDIT THIS FILE before starting ddclient.
# Uncomment and fill in the block for your DNS provider.

daemon=300
syslog=yes
pid=/var/run/ddclient/ddclient.pid
ssl=yes

# Cloudflare example:
# use=web, web=cloudflare
# protocol=cloudflare
# zone=example.com
# login=token
# password=your-api-token
# example.com

# DuckDNS example:
# use=web
# protocol=duckdns
# password=your-duckdns-token
# yourdomain.duckdns.org

# No-IP example:
# use=web
# protocol=noip
# login=your@email.com
# password=your-password
# yourhostname.ddns.net
DDCLIENT_CONF

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DDCLIENT_DIR"
    log_success "ddclient configured at $DDCLIENT_DIR"

    write_readme "$DDCLIENT_DIR" << MD
# ddclient

Dynamic DNS client — keeps your domain pointing at your home IP address
even when your ISP changes it. No web UI; runs as a background daemon.

- Config: \`config/ddclient.conf\` — **edit before starting**
- Supported providers: Cloudflare, DuckDNS, No-IP, FreeDNS, and more

## Setup
1. Edit \`config/ddclient.conf\` for your DNS provider.
2. Start: \`docker compose up -d\`
3. Check logs: \`docker compose logs -f\`

## Manage
\`\`\`bash
cd $DDCLIENT_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Docs
- https://ddclient.net/
- Cloudflare setup: https://ddclient.net/protocols/cloudflare.html
MD

    echo ""
    log_warning "Edit config/ddclient.conf for your DNS provider before starting."
    echo ""
    local START_DDC=""
    prompt_yn "Start ddclient now? (y/n):" "n" START_DDC
    if [ "$START_DDC" = "y" ] || [ "$START_DDC" = "Y" ]; then
        docker compose up -d && log_success "ddclient started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Config:  $DDCLIENT_DIR/config/ddclient.conf"
    echo "  Docs:    https://ddclient.net/"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_ddclient
