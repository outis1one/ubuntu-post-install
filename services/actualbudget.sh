#!/bin/bash
# services/actualbudget.sh — Open-source personal finance / budgeting (Actual Budget).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash actualbudget.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- ACTUALBUDGET ----).
# Own ~/docker/actualbudget/ with a standalone docker-compose.yml.

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

register_service actualbudget utilities "Open-source personal finance & budgeting (Actual Budget)" 5006

install_actualbudget() {
    require_docker || return 1

    local AB_DIR="$DOCKER_DIR/actualbudget"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Actual Budget would:"
        echo "  - Create $AB_DIR with docker-compose.yml (data/)"
        echo "  - Expose port 5006"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$AB_DIR/data"
    ensure_docker_dir_ownership "$AB_DIR"
    cd "$AB_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'AB_COMPOSE'
name: actualbudget

services:
  actualbudget:
    image: actualbudget/actual-server:latest
    container_name: actualbudget
    restart: unless-stopped
    ports:
      - "5006:5006"
    volumes:
      - ./data:/data
    env_file:
      - .env
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
AB_COMPOSE

    cat > .env << AB_ENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET
AB_ENV

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$AB_DIR"
    log_success "Actual Budget configured at $AB_DIR"

    configure_caddy_for_service "ActualBudget" "actualbudget:5006" "budget"

    write_readme "$AB_DIR" << MD
# Actual Budget

Open-source personal finance and budgeting tool. Supports bank sync via
SimpleFIN (requires a SimpleFIN account at simplefin.org).

- Web UI: http://localhost:5006
- App data: \`data/\`

## Manage
\`\`\`bash
cd $AB_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- First launch: create a budget file or import an existing one.
- Bank sync requires a SimpleFIN bridge subscription (simplefin.org).
MD

    local START_AB=""
    prompt_yn "Start Actual Budget now? (y/n):" "y" START_AB
    if [ "$START_AB" = "y" ] || [ "$START_AB" = "Y" ]; then
        docker compose up -d && log_success "Actual Budget started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:5006"
    echo "  Bank sync:  simplefin.org (optional, paid)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_actualbudget
