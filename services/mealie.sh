#!/bin/bash
# services/mealie.sh — Recipe manager & meal planner (Mealie).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash mealie.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MEALIE ----).
# Own ~/docker/mealie/ with a standalone docker-compose.yml.

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

register_service mealie utilities "Recipe manager & meal planner (Mealie)" 9925

install_mealie() {
    require_docker || return 1

    local MEALIE_DIR="$DOCKER_DIR/mealie"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Mealie would:"
        echo "  - Create $MEALIE_DIR with docker-compose.yml (data/)"
        echo "  - Expose port 9925"
        echo "  - Default login: changeme@email.com / MyPassword (change immediately)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$MEALIE_DIR"
    ensure_docker_dir_ownership "$MEALIE_DIR"
    cd "$MEALIE_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    # BASE_URL must match the public URL Mealie is served on (used for email links,
    # OAuth redirects, and the web app manifest). Default to SITE_DOMAIN if set.
    local MEALIE_BASE_URL="http://localhost:9925"
    if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        MEALIE_BASE_URL="https://recipes.${SITE_DOMAIN}"
    fi

    cat > docker-compose.yml << MEALIE_COMPOSE
name: mealie

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:latest
    container_name: mealie
    hostname: mealie
    restart: unless-stopped
    env_file: .env
    environment:
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
      - ALLOW_SIGNUP=true
      - MAX_WORKERS=1
      - WEB_CONCURRENCY=1
    volumes:
      - ./data:/app/data
    ports:
      - "9925:9000"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
MEALIE_COMPOSE

    cat > .env << MEALIE_ENV
# Public URL Mealie is served on — used for email links and OAuth redirects.
# Update if you change your domain or switch from HTTP to HTTPS.
BASE_URL=$MEALIE_BASE_URL
CADDY_NET=$SITE_CADDY_NET
MEALIE_ENV

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MEALIE_DIR"
    log_success "Mealie configured at $MEALIE_DIR"

    configure_caddy_for_service "Mealie" "mealie:9000" "recipes"

    write_readme "$MEALIE_DIR" << MD
# Mealie

Recipe manager and meal planner — import recipes from any URL, plan meals,
and generate shopping lists. Optional AI-powered recipe parsing.

- Web UI: http://localhost:9925
- Default login: changeme@email.com / MyPassword (change immediately!)
- App data: \`data/\`

## Manage
\`\`\`bash
cd $MEALIE_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- If using Caddy, update \`BASE_URL\` in \`docker-compose.yml\` to your domain.
MD

    local START_MEALIE=""
    prompt_yn "Start Mealie now? (y/n):" "y" START_MEALIE
    if [ "$START_MEALIE" = "y" ] || [ "$START_MEALIE" = "Y" ]; then
        docker compose up -d && log_success "Mealie started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:9925"
    echo "  Default:    changeme@email.com / MyPassword  (change immediately!)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mealie
