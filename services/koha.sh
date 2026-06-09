#!/bin/bash
# services/koha.sh — Koha Integrated Library System (physical book catalog + loans).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash koha.sh
# (Docker must already be installed when run standalone)
#
# Uses teogramm/koha (single bundled container: Apache, Plack, Zebra indexer,
# background jobs worker) + MariaDB + Memcached + RabbitMQ sidecars.
# OPAC (patron UI): port 8097  |  Staff/admin: port 8098
# RAM: needs ~2.5 GB free.

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service koha utilities "Physical book library — catalog, shelf locations, loans/checkout (Koha ILS)" 8097

install_koha() {
    require_docker || return 1

    local KOHA_DIR="$DOCKER_DIR/koha"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] koha would:"
        echo "  - Create $KOHA_DIR with docker-compose.yml + config-main.env"
        echo "  - Deploy teogramm/koha + MariaDB + Memcached + RabbitMQ"
        echo "  - OPAC (patron UI):   port 8097"
        echo "  - Staff/admin:        port 8098"
        echo "  - Requires ~2.5 GB free RAM"
        return 0
    fi

    echo ""
    echo "  Koha is a full Integrated Library System (ILS):"
    echo "  • ISBN barcode scanning → auto-fetch cover art, author, summary"
    echo "  • Shelf / location tracking (define your own locations)"
    echo "  • Loan / checkout system with due dates and history"
    echo "  • OPAC (patron browsing UI) + staff admin interface"
    echo "  • Requires ~2.5 GB free RAM (4 containers: Koha, MariaDB, Memcached, RabbitMQ)"
    echo ""

    local DB_PASS RABBIT_PASS
    DB_PASS=$(generate_password 24)
    RABBIT_PASS=$(generate_password 24)

    mkdir -p "$KOHA_DIR"
    ensure_docker_dir_ownership "$KOHA_DIR"
    cd "$KOHA_DIR" || return 1

    cat > docker-compose.yml << 'KOHA_COMPOSE'
name: koha

services:
  koha:
    image: teogramm/koha:24.11
    container_name: koha
    hostname: koha
    restart: unless-stopped
    cap_add:
      - DAC_READ_SEARCH
      - SYS_NICE
    env_file:
      - config-main.env
    ports:
      - "8097:8080"
      - "8098:8081"
    depends_on:
      - koha-db
      - koha-memcached
      - koha-rabbitmq
    networks:
      - koha_internal
      - caddy_net

  koha-db:
    image: mariadb:11
    container_name: koha-db
    hostname: koha-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASS}
      MYSQL_DATABASE: koha_default
      MYSQL_USER: koha_default
      MYSQL_PASSWORD: ${DB_PASS}
    volumes:
      - koha_db_data:/var/lib/mysql
    networks:
      - koha_internal

  koha-memcached:
    image: memcached:latest
    container_name: koha-memcached
    hostname: koha-memcached
    restart: unless-stopped
    networks:
      - koha_internal

  koha-rabbitmq:
    image: rabbitmq:3
    container_name: koha-rabbitmq
    hostname: koha-rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: koha
      RABBITMQ_DEFAULT_PASS: ${RABBIT_PASS}
    networks:
      - koha_internal

volumes:
  koha_db_data:

networks:
  koha_internal:
    internal: true
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
KOHA_COMPOSE

    cat > config-main.env << KOHA_ENV
# Koha ILS configuration — generated at install time
MYSQL_SERVER=koha-db
DB_NAME=koha_default
MYSQL_USER=koha_default
MYSQL_PASSWORD=$DB_PASS
DB_ROOT_PASS=$(generate_password 24)
MEMCACHED_SERVERS=koha-memcached:11211
MB_HOST=koha-rabbitmq
MB_PORT=61613
MB_USER=koha
MB_PASS=$RABBIT_PASS
RABBIT_PASS=$RABBIT_PASS
DB_PASS=$DB_PASS
CADDY_NET=$SITE_CADDY_NET
KOHA_LANGS=en
ZEBRA_MARC_FORMAT=marc21
USE_Z3950=1
KOHA_ENV

    chmod 600 config-main.env
    ensure_docker_dir_ownership "$KOHA_DIR"
    log_success "Koha configured at $KOHA_DIR"

    # Koha has its own staff login — no Authelia for staff interface
    # OPAC is public-facing, Caddy proxies to OPAC port
    configure_caddy_for_service "Koha OPAC" "koha:8080" "library"

    write_readme "$KOHA_DIR" << MD
# Koha ILS — Home Library

Full Integrated Library System for managing a physical book collection.

## Access
- **OPAC** (patron browsing): http://localhost:8097
- **Staff / admin**:          http://localhost:8098

## First-time setup (important — takes ~5 minutes)
1. Open the **staff interface**: http://localhost:8098
2. Wait for the setup wizard (Koha takes 2–3 minutes to initialize on first start)
3. Follow the web installer — it asks for library name, MARC flavour (choose MARC21),
   and creates your admin account
4. Go to Administration → Basic parameters → Libraries to add your library
5. Go to Administration → Basic parameters → Item types to define your book categories
6. Go to Administration → Basic parameters → Authorized values → LOC to define
   shelf locations (e.g. "LR1" = Living Room Shelf 1)

## Adding books
- **By ISBN** (recommended): Cataloguing → Z39.50/SRU search → enter ISBN →
  imports full metadata, cover art, summary from WorldCat/OpenLibrary
- **Barcode scanning**: use any USB barcode scanner or phone camera app;
  scan ISBN on the back of the book

## Loans / checkout
- Patron management: Patrons → New patron (add family members)
- Checkout: Circulation → Check out → scan patron card, scan book barcode
- Return: Circulation → Check in

## Manage
\`\`\`bash
cd $KOHA_DIR
docker compose up -d      # start (allow 3 min for first-time init)
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Shelf locations
Define custom locations in Staff → Administration → Authorized values → LOST
(or create a new category). Common home library codes:
- LR1, LR2 — Living Room shelves
- BR — Bedroom
- OF — Office
- BS — Basement
MD

    local START_KOHA=""
    prompt_yn "Start Koha now? (y/n):" "y" START_KOHA
    if [ "$START_KOHA" = "y" ] || [ "$START_KOHA" = "Y" ]; then
        docker compose up -d \
            && log_success "Koha starting (takes 2–3 min on first run)" \
            || log_warning "Start failed — check: docker compose logs koha"
    fi

    echo ""
    echo "  OPAC (patron UI): http://localhost:8097"
    echo "  Staff / admin:    http://localhost:8098"
    echo "  First run: open staff interface and complete the setup wizard (~5 min)"
    echo "  Credentials saved in: $KOHA_DIR/config-main.env"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_koha
