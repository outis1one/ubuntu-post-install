#!/bin/bash
# services/garage-webui.sh — Web UI for browsing/managing an existing Garage
# instance's buckets and objects (folders/files view, the same kind of thing
# Backblaze's own web console gives you for a B2 bucket).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash garage-webui.sh
# (Docker must already be installed when run standalone; requires
# services/garage.sh already installed on the SAME machine — this reads
# that install's admin API port/token straight out of its .env)

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
        }

        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_reinstall_mode() {
            local _var="$1" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='cancel'"; return; }
            echo ""
            echo "  1) Update   — refresh the image only, leave config/data as-is"
            echo "  2) Full reinstall — wipe and reconfigure from scratch"
            echo "  3) Cancel   — leave the existing install untouched"
            read -r -p "  Choice [3]: " _r
            case "$_r" in
                1) eval "$_var='update'" ;;
                2) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        configure_caddy_for_service() { CADDY_SERVICE_CONFIGURED=false; }

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

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service garage-webui utilities "Web UI for browsing/managing an existing Garage instance's buckets and objects" 3909

install_garage-webui() {
    require_docker || return 1

    local GARAGE_DIR="$DOCKER_DIR/garage"
    local DIR="$DOCKER_DIR/garage-webui"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would check for an existing services/garage.sh install at $GARAGE_DIR"
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml + .env"
        echo "[DRY-RUN] Would auto-scan for a free web UI port"
        echo "[DRY-RUN] Would generate an admin username/password and bcrypt-hash it (requires Docker)"
        return 0
    fi

    if [[ ! -f "$GARAGE_DIR/.env" ]]; then
        log_error "No Garage install found at $GARAGE_DIR — this is a browser for an"
        log_error "existing Garage instance, not a replacement for it. Install Garage"
        log_error "first: sudo ./setup.sh garage"
        return 1
    fi

    local _garage_env
    _garage_env="$(cat "$GARAGE_DIR/.env")"
    local GARAGE_ADMIN_PORT GARAGE_ADMIN_TOKEN GARAGE_S3_API_PORT
    GARAGE_ADMIN_PORT="$(echo "$_garage_env" | sed -nE "s/^GARAGE_ADMIN_PORT=([0-9]+)\$/\1/p")"
    GARAGE_ADMIN_TOKEN="$(echo "$_garage_env" | sed -nE "s/^GARAGE_ADMIN_TOKEN='?([^']*)'?\$/\1/p")"
    GARAGE_S3_API_PORT="$(echo "$_garage_env" | sed -nE "s/^GARAGE_S3_API_PORT=([0-9]+)\$/\1/p")"

    if [ -z "$GARAGE_ADMIN_PORT" ] || [ -z "$GARAGE_ADMIN_TOKEN" ] || [ -z "$GARAGE_S3_API_PORT" ]; then
        log_error "Garage is installed at $GARAGE_DIR but its .env is missing the admin"
        log_error "API port/token this needs (added in a newer version of services/garage.sh)."
        log_error "Re-run Garage's own installer first to backfill it, then rerun this:"
        log_error "  sudo ./setup.sh garage   (choose \"Update\" when prompted)"
        return 1
    fi

    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing the Garage Web UI image only — existing login is left as-is."
                ( cd "$DIR" && docker compose pull && docker compose up -d ) \
                    && log_success "Garage Web UI refreshed" \
                    || log_warning "Refresh failed — check: docker compose -f $DIR/docker-compose.yml logs"
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) ;;  # fall through to the full install flow below
        esac
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  GARAGE WEB UI — browse/manage Garage's buckets and objects"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Connecting to the Garage instance at $GARAGE_DIR."
    echo ""

    local WEB_PORT="3909"
    find_free_port WEB_PORT "$WEB_PORT"

    local WEBUI_USER=""
    prompt_text "  Admin username:" "admin" WEBUI_USER
    WEBUI_USER="${WEBUI_USER:-admin}"

    local WEBUI_PASSWORD
    WEBUI_PASSWORD="$(generate_password 24)"

    log_info "Generating bcrypt password hash (requires Docker)..."
    local _auth_line
    _auth_line="$(docker run --rm httpd:alpine htpasswd -nbB "$WEBUI_USER" "$WEBUI_PASSWORD" 2>/dev/null)"
    if [ -z "$_auth_line" ]; then
        log_error "Couldn't generate a bcrypt hash (needs to pull httpd:alpine) — aborting."
        return 1
    fi
    # Compose re-parses its own YAML for $VAR/${VAR} interpolation, so a
    # literal $ from the bcrypt hash (embedded directly into
    # docker-compose.yml below) has to be doubled or Compose treats it as
    # the start of a variable reference. Same fix services/wg-easy.sh uses
    # for its own bcrypt PASSWORD_HASH.
    local _auth_escaped="${_auth_line//\$/\$\$}"

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    cat > docker-compose.yml << COMPOSE
name: garage-webui

services:
  garage-webui:
    image: khairul169/garage-webui:1.1.0
    container_name: garage-webui
    restart: unless-stopped
    env_file: .env
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      API_BASE_URL: "http://host.docker.internal:${GARAGE_ADMIN_PORT}"
      S3_ENDPOINT_URL: "http://host.docker.internal:${GARAGE_S3_API_PORT}"
      API_ADMIN_KEY: "${GARAGE_ADMIN_TOKEN}"
      AUTH_USER_PASS: "${_auth_escaped}"
    ports:
      - "${WEB_PORT}:3909"
COMPOSE

    cat > .env << ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}

# Plain-text password — only for your own reference (the container itself
# is only ever given the bcrypt hash, baked into docker-compose.yml).
GARAGE_WEBUI_USER='${WEBUI_USER}'
GARAGE_WEBUI_PASSWORD='${WEBUI_PASSWORD}'
ENV
    chmod 600 .env

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    log_info "Starting Garage Web UI..."
    docker compose up -d || { log_error "Failed to start Garage Web UI — check: docker compose logs"; return 1; }

    configure_caddy_for_service "Garage Web UI" "$WEB_PORT" "garage-admin"

    write_readme "$DIR" << MD
# Garage Web UI

Browser-based admin UI for an existing Garage instance ($GARAGE_DIR) — bucket
and object browser (see folders/files the way Backblaze's own web console
shows a B2 bucket), cluster health, and key management.

## Login
- URL: http://localhost:${WEB_PORT}
- Username: \`$WEBUI_USER\`
- Password: see \`.env\` (\`GARAGE_WEBUI_PASSWORD\`)

## Manage
\`\`\`bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
\`\`\`

This talks to Garage's admin API (\`GARAGE_ADMIN_PORT\`/\`GARAGE_ADMIN_TOKEN\` in
$GARAGE_DIR/.env) and S3 API over \`host.docker.internal\`, both on this same
machine — nothing here is sent over the network to any other box.
MD

    echo ""
    log_success "Garage Web UI ready."
    echo "  URL:      http://localhost:${WEB_PORT}"
    echo "  Username: $WEBUI_USER"
    echo "  Password: $WEBUI_PASSWORD  (saved in $DIR/.env)"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_garage-webui
