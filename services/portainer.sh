#!/bin/bash
# services/portainer.sh — Portainer Docker management web UI.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash portainer.sh
# (Docker must already be installed when run standalone)

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

register_service portainer utilities "Docker management UI (Portainer)" 9443

install_portainer() {
    require_docker || return 1
    log_info "Installing Portainer..."
    local PORTAINER_DIR="$DOCKER_DIR/portainer"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $PORTAINER_DIR"
        return 0
    fi

    mkdir -p "$PORTAINER_DIR"
    ensure_docker_dir_ownership "$PORTAINER_DIR"
    cd "$PORTAINER_DIR" || return 1

    cat > docker-compose.yml << 'PORTAINER_COMPOSE'
name: portainer

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    hostname: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "9000:9000"
      - "9443:9443"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
PORTAINER_COMPOSE

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$PORTAINER_DIR"

    echo ""
    log_success "Portainer configured at $PORTAINER_DIR"

    configure_caddy_for_service "Portainer" "portainer:9000" "portainer"

    write_readme "$PORTAINER_DIR" << MD
# Portainer

Web UI for managing Docker — containers, images, volumes, and networks.

## Access
- HTTPS: https://localhost:9443
- HTTP:  http://localhost:9000
- Create your admin account on first visit.

## Data
- App data: ./data (mounted to /data)
- Mounts the Docker socket to manage the host's Docker.

## Manage
\`\`\`
cd $PORTAINER_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_PORTAINER=""
    prompt_yn "Start Portainer now? (y/n):" "y" START_PORTAINER
    if [ "$START_PORTAINER" = "y" ] || [ "$START_PORTAINER" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Portainer started" || log_warning "Failed to start"
    fi

    echo "  Access at:  https://localhost:9443"
    echo "  Create admin account on first visit"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_portainer
