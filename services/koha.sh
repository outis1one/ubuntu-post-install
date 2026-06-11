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
#
# Database lives in ~/docker/koha/data/ (bind-mount, fully backed up by backup.sh).

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

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   Koha — Integrated Library System                               ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  • ISBN barcode scanning → auto-fetch cover art, author, summary"
    echo "  • Shelf / location tracking (define your own codes)"
    echo "  • Loan / checkout system with due dates and history"
    echo "  • OPAC (patron browsing UI) + staff admin interface"
    echo "  • Requires ~2.5 GB free RAM"
    echo ""
    echo "  SETUP OVERVIEW:"
    echo "    1) Answer the questions below (collects library details + credentials)"
    echo "    2) Koha starts — takes 2–3 min on first boot"
    echo "    3) Open http://localhost:8098 and complete the brief web installer (~2 min)"
    echo "    4) Run  $KOHA_DIR/post-setup.sh  to auto-configure library, items, locations"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $KOHA_DIR with docker-compose.yml + config-main.env"
        echo "[DRY-RUN] Would deploy teogramm/koha + MariaDB (./data/) + Memcached + RabbitMQ"
        echo "[DRY-RUN] Would generate post-setup.sh for REST API configuration"
        echo "[DRY-RUN] OPAC (patron UI):   port 8097"
        echo "[DRY-RUN] Staff/admin:        port 8098"
        return 0
    fi

    # ── Collect library details ───────────────────────────────────────────────
    echo "══════════════════════════════════════════════════════"
    echo "  LIBRARY DETAILS"
    echo "══════════════════════════════════════════════════════"
    echo ""

    local LIB_NAME=""
    prompt_text "Library name (shown in OPAC header) [My Home Library]:" "My Home Library" LIB_NAME

    # Auto-derive a library code from the name
    local _auto_code
    _auto_code="$(echo "$LIB_NAME" | tr '[:lower:]' '[:upper:]' | tr -dc 'A-Z0-9' | head -c 5)"
    [[ -z "$_auto_code" ]] && _auto_code="HOME"
    local LIB_CODE=""
    prompt_text "Library code (3-8 letters/numbers) [${_auto_code}]:" "$_auto_code" LIB_CODE
    LIB_CODE="${LIB_CODE//[^A-Za-z0-9]/}"
    LIB_CODE="${LIB_CODE^^}"
    [[ ${#LIB_CODE} -lt 2 ]] && LIB_CODE="HOME"

    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  ADMIN ACCOUNT"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo "  You will enter this password during the web installer."
    echo "  It is stored in config-main.env (chmod 600) for the post-setup script."
    echo ""

    local KOHA_ADMIN_USER=""
    prompt_text "Admin username [admin]:" "admin" KOHA_ADMIN_USER
    [[ -z "$KOHA_ADMIN_USER" ]] && KOHA_ADMIN_USER="admin"

    local KOHA_ADMIN_PASS=""
    if [ "$UNATTENDED" = true ]; then
        KOHA_ADMIN_PASS="$(generate_password 20)"
    else
        read -rsp "  Admin password [Enter = auto-generate]: " KOHA_ADMIN_PASS; echo
        [[ -z "$KOHA_ADMIN_PASS" ]] && KOHA_ADMIN_PASS="$(generate_password 20)"
    fi

    local KOHA_ADMIN_EMAIL=""
    prompt_text "Admin email [blank to skip]:" "" KOHA_ADMIN_EMAIL

    # ── Item types ────────────────────────────────────────────────────────────
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  ITEM TYPES"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo "  Default set: Book, DVD, Blu-ray, Magazine, Comic, Board Game"
    echo "  (You can add/edit more later in Staff UI → Administration → Item types)"
    echo ""

    # Store as "CODE:Description:loan_days" triplets
    local -a ITEM_TYPES=(
        "BK:Book:21"
        "DVD:DVD:7"
        "BLU:Blu-ray:7"
        "MAG:Magazine:14"
        "COM:Comic:14"
        "BG:Board Game:14"
    )

    local _add_items=""
    prompt_yn "Add custom item types now? (y/N):" "n" _add_items
    if [[ "$_add_items" =~ ^[Yy]$ ]]; then
        echo ""
        echo "  Enter each type (blank code to finish)."
        echo "  Example:  CD : Compact Disc : 14"
        echo ""
        local _ic _id _il
        while true; do
            prompt_text "  Code (3-5 chars, blank to finish):" "" _ic
            [[ -z "$_ic" ]] && break
            _ic="${_ic//[^A-Za-z0-9]/}"
            _ic="${_ic^^}"
            prompt_text "  Description for '$_ic':" "$_ic" _id
            prompt_text "  Loan period in days [14]:" "14" _il
            _il="${_il//[^0-9]/}"; [[ -z "$_il" ]] && _il="14"
            ITEM_TYPES+=("${_ic}:${_id}:${_il}")
            log_success "  Added: $_ic — $_id (${_il}d)"
        done
    fi

    # ── Shelf locations ───────────────────────────────────────────────────────
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  SHELF LOCATIONS"
    echo "══════════════════════════════════════════════════════"
    echo ""
    echo "  Define where books live (e.g. LR1=Living Room Shelf 1, BR=Bedroom)."
    echo "  Used on item records so you can find them again."
    echo "  (You can add/edit more later in Staff UI → Administration → Authorized values → LOC)"
    echo ""

    local -a SHELF_LOCS=()
    local _add_locs=""
    prompt_yn "Add shelf locations now? (y/N):" "n" _add_locs
    if [[ "$_add_locs" =~ ^[Yy]$ ]]; then
        echo ""
        local _lc _ld
        while true; do
            prompt_text "  Location code (blank to finish):" "" _lc
            [[ -z "$_lc" ]] && break
            _lc="${_lc//[^A-Za-z0-9_]/_}"
            prompt_text "  Description for '$_lc':" "$_lc" _ld
            SHELF_LOCS+=("${_lc}:${_ld}")
            log_success "  Added: $_lc — $_ld"
        done
    fi

    # ── Passwords ─────────────────────────────────────────────────────────────
    local DB_PASS DB_ROOT_PASS RABBIT_PASS
    DB_PASS="$(generate_password 24)"
    DB_ROOT_PASS="$(generate_password 24)"
    RABBIT_PASS="$(generate_password 24)"

    # ── Create directories ────────────────────────────────────────────────────
    mkdir -p "$KOHA_DIR/data"
    ensure_docker_dir_ownership "$KOHA_DIR"
    cd "$KOHA_DIR" || return 1

    # ── docker-compose.yml ────────────────────────────────────────────────────
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
      - ./data:/var/lib/mysql
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

networks:
  koha_internal:
    internal: true
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
KOHA_COMPOSE

    # ── config-main.env ───────────────────────────────────────────────────────
    cat > config-main.env << KOHA_ENV
# Koha ILS configuration — generated at install time
MYSQL_SERVER=koha-db
DB_NAME=koha_default
MYSQL_USER=koha_default
MYSQL_PASSWORD=$DB_PASS
DB_ROOT_PASS=$DB_ROOT_PASS
DB_PASS=$DB_PASS
MEMCACHED_SERVERS=koha-memcached:11211
MB_HOST=koha-rabbitmq
MB_PORT=61613
MB_USER=koha
MB_PASS=$RABBIT_PASS
RABBIT_PASS=$RABBIT_PASS
CADDY_NET=$SITE_CADDY_NET
KOHA_LANGS=en
ZEBRA_MARC_FORMAT=marc21
USE_Z3950=1
# Admin credentials (used by post-setup.sh after web installer)
KOHA_ADMIN_USER=$KOHA_ADMIN_USER
KOHA_ADMIN_PASS=$KOHA_ADMIN_PASS
KOHA_ENV

    chmod 600 config-main.env
    ensure_docker_dir_ownership "$KOHA_DIR"

    # ── Generate post-setup.sh ────────────────────────────────────────────────
    log_info "Writing post-setup.sh ..."

    # Serialise item types and shelf locs into env-safe strings
    local _items_str _locs_str
    _items_str="$(IFS='|'; echo "${ITEM_TYPES[*]}")"
    _locs_str="$(IFS='|'; echo "${SHELF_LOCS[*]}")"

    cat > post-setup.sh << POSTSETUP
#!/bin/bash
# post-setup.sh — Run AFTER completing the Koha web installer at http://localhost:8098
# Configures library, item types, and shelf locations via the Koha REST API.
# Generated by ubuntu-post-install on $(date '+%F').

set -uo pipefail

KOHA_STAFF_URL="http://localhost:8098"
KOHA_DIR="${KOHA_DIR}"
CONF="\${KOHA_DIR}/config-main.env"

[ -f "\$CONF" ] || { echo "config-main.env not found at \$CONF"; exit 1; }
source "\$CONF"

ADMIN_USER="\${KOHA_ADMIN_USER:-admin}"
ADMIN_PASS="\${KOHA_ADMIN_PASS:-}"
LIB_NAME="${LIB_NAME}"
LIB_CODE="${LIB_CODE}"
ITEMS_RAW="${_items_str}"
LOCS_RAW="${_locs_str}"

log()  { echo "[\$(date '+%T')] \$*"; }
ok()   { echo "  ✓ \$*"; }
warn() { echo "  ⚠ \$*"; }
fail() { echo "  ✗ \$*" >&2; }

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Koha Post-Setup Configuration                      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "  Library : \$LIB_NAME (\$LIB_CODE)"
echo "  Admin   : \$ADMIN_USER"
echo ""

# ── Wait for Koha API ────────────────────────────────────────────────────────
log "Waiting for Koha REST API..."
_tries=0
until curl -sf "\$KOHA_STAFF_URL/api/v1/auth/session" -o /dev/null 2>/dev/null; do
    _tries=\$((_tries+1))
    [ "\$_tries" -gt 60 ] && { fail "Koha API not available after 5 min — is the stack running?"; exit 1; }
    printf "."
    sleep 5
done
echo ""
ok "Koha API is up"

# ── Authenticate ─────────────────────────────────────────────────────────────
if [ -z "\$ADMIN_PASS" ]; then
    read -rsp "  Admin password (from web installer): " ADMIN_PASS; echo
fi

_COOKIE="\$(mktemp)"
trap 'rm -f "\$_COOKIE"' EXIT

_auth_resp=\$(curl -sf -c "\$_COOKIE" -X POST "\$KOHA_STAFF_URL/api/v1/auth/session" \\
    -H "Content-Type: application/json" \\
    -d "{\"userid\":\"\$ADMIN_USER\",\"password\":\"\$ADMIN_PASS\"}" 2>&1) || true
if ! curl -sf -b "\$_COOKIE" "\$KOHA_STAFF_URL/api/v1/libraries" -o /dev/null 2>/dev/null; then
    fail "Authentication failed — check admin username/password in config-main.env"
    echo "  You can update KOHA_ADMIN_PASS in \$CONF and re-run this script."
    exit 1
fi
ok "Authenticated as \$ADMIN_USER"

# ── Helper: POST with JSON ────────────────────────────────────────────────────
koha_post() {
    local _endpoint="\$1" _body="\$2"
    curl -sf -b "\$_COOKIE" -X POST "\$KOHA_STAFF_URL/api/v1/\$_endpoint" \\
        -H "Content-Type: application/json" \\
        -d "\$_body" -o /dev/null -w "%{http_code}"
}

koha_patch() {
    local _endpoint="\$1" _body="\$2"
    curl -sf -b "\$_COOKIE" -X PATCH "\$KOHA_STAFF_URL/api/v1/\$_endpoint" \\
        -H "Content-Type: application/json" \\
        -d "\$_body" -o /dev/null -w "%{http_code}"
}

# ── Library branch ────────────────────────────────────────────────────────────
echo ""
log "Creating library branch '\$LIB_CODE' (\$LIB_NAME)..."
_code=\$(koha_post "libraries" "{\"library_id\":\"\$LIB_CODE\",\"name\":\"\$LIB_NAME\"}")
case "\$_code" in
    201) ok "Library created" ;;
    409) warn "Library '\$LIB_CODE' already exists — skipping" ;;
    *)   warn "Unexpected response \$_code — may need manual setup in Staff UI" ;;
esac

# ── System preferences ────────────────────────────────────────────────────────
log "Setting system preferences..."
docker exec koha bash -c "\\
    mysql -u root -p\${DB_ROOT_PASS:-\$DB_ROOT_PASS} koha_default -e \\
    \\\"UPDATE systempreferences SET value='\$LIB_NAME' WHERE variable='LibraryName';\\\"
" 2>/dev/null && ok "LibraryName → \$LIB_NAME" || warn "Could not set LibraryName (set manually in Staff UI → Admin → System preferences → OPAC)"

docker exec koha bash -c "\\
    mysql -u root -p\${DB_ROOT_PASS:-\$DB_ROOT_PASS} koha_default -e \\
    \\\"UPDATE systempreferences SET value='\$LIB_NAME' WHERE variable='OPACLibraryName';\\\"
" 2>/dev/null && ok "OPACLibraryName → \$LIB_NAME" || true

# ── Item types ────────────────────────────────────────────────────────────────
echo ""
log "Creating item types..."
IFS='|' read -ra _ITEMS <<< "\$ITEMS_RAW"
for _item in "\${_ITEMS[@]}"; do
    IFS=':' read -r _ic _id _il <<< "\$_item"
    [[ -z "\$_ic" ]] && continue
    _body="{\"item_type_id\":\"\$_ic\",\"description\":\"\$_id\",\"loan_period\":\$_il,\"renewals_allowed\":99}"
    _code=\$(koha_post "item_types" "\$_body")
    case "\$_code" in
        201) ok "\$_ic — \$_id (\${_il}d loan)" ;;
        409) warn "\$_ic already exists — skipping" ;;
        *)   warn "\$_ic: unexpected response \$_code" ;;
    esac
done

# ── Shelf locations (LOC authorized values) ───────────────────────────────────
if [ -n "\$LOCS_RAW" ]; then
    echo ""
    log "Creating shelf locations..."
    IFS='|' read -ra _LOCS <<< "\$LOCS_RAW"
    for _loc in "\${_LOCS[@]}"; do
        IFS=':' read -r _lc _ld <<< "\$_loc"
        [[ -z "\$_lc" ]] && continue
        _body="{\"authorised_value\":\"\$_lc\",\"lib\":\"\$_ld\",\"lib_opac\":\"\$_ld\"}"
        _code=\$(koha_post "authorised_value_categories/LOC/authorised_values" "\$_body")
        case "\$_code" in
            201) ok "\$_lc — \$_ld" ;;
            409) warn "\$_lc already exists — skipping" ;;
            *)   warn "\$_lc: unexpected response \$_code" ;;
        esac
    done
fi

echo ""
echo "══════════════════════════════════════════════════════"
echo "  SETUP COMPLETE"
echo "══════════════════════════════════════════════════════"
echo ""
echo "  Your Koha library is ready to use."
echo ""
echo "  OPAC (patron browsing):  http://localhost:8097"
echo "  Staff / admin:           http://localhost:8098"
echo ""
echo "  Next steps in Staff UI:"
echo "    1. Administration → Patron categories → add patron types"
echo "       (e.g. ADULT, CHILD, FAMILY)"
echo "    2. Administration → Circulation and fines rules → set loan rules"
echo "    3. Cataloguing → Z39.50/SRU — verify WorldCat/OpenLibrary targets work"
echo "       (test by searching an ISBN)"
echo ""
echo "  Adding books:"
echo "    Cataloguing → Z39.50/SRU search → enter ISBN"
echo "    Or use a USB barcode scanner — scan the ISBN barcode on any book"
echo ""
POSTSETUP

    chmod +x post-setup.sh
    chown "$ACTUAL_USER:$ACTUAL_USER" post-setup.sh 2>/dev/null || true
    log_success "post-setup.sh written"

    log_success "Koha configured at $KOHA_DIR"

    # Koha has its own staff login — no Authelia for staff interface
    configure_caddy_for_service "Koha OPAC" "koha:8080" "library"

    write_readme "$KOHA_DIR" << MD
# Koha ILS — Home Library

Full Integrated Library System for managing a physical book collection.

## Access
- **OPAC** (patron browsing): http://localhost:8097
- **Staff / admin**:          http://localhost:8098

## Quick setup (4 steps)

### Step 1 — Start the stack
\`\`\`bash
cd $KOHA_DIR
docker compose up -d
\`\`\`
Takes 2–3 minutes on first boot while Koha initialises.

### Step 2 — Complete the web installer
1. Open **http://localhost:8098**
2. You may see a "Database connection" page first — wait 1–2 min and refresh
3. The installer wizard appears automatically:
   - **Language**: click "Install for language English" → Continue
   - **Koha database**: fields are pre-filled from env → Continue
   - **Select MARC flavour**: choose **MARC21** → Continue
   - **Install basic Koha data**: check all boxes → Continue
   - **Set Koha administrator password**: enter **$KOHA_ADMIN_PASS** exactly
   - **Finish**: click the login link
4. Log in with username **$KOHA_ADMIN_USER** and the password above

### Step 3 — Run post-setup
\`\`\`bash
sudo $KOHA_DIR/post-setup.sh
\`\`\`
Auto-creates your library branch, item types, and shelf locations via the REST API.

### Step 4 — Add patron categories and circulation rules
In Staff UI:
- Administration → Patron categories → New category (e.g. ADULT, CHILD)
- Administration → Circulation and fines rules → add a rule for your library

## Adding books
- **By ISBN** (recommended): Cataloguing → Z39.50/SRU search → enter ISBN
  → imports metadata, cover art, and summary from WorldCat / Open Library
- **Barcode scanner**: any USB scanner works; scan the ISBN barcode on the book cover

## Loans / checkout
- Add patrons: Patrons → New patron
- Checkout: Circulation → Check out → scan/enter patron card, scan book barcode
- Return: Circulation → Check in

## Data location
- **Database**: \`$KOHA_DIR/data/\`  (MariaDB bind-mount, included in backup)
- **Config**:   \`$KOHA_DIR/config-main.env\`  (chmod 600)

## Manage
\`\`\`bash
cd $KOHA_DIR
docker compose up -d            # start (3 min first boot)
docker compose down             # stop
docker compose logs -f          # logs
docker compose logs -f koha     # Koha app logs only
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    # ── Start ──────────────────────────────────────────────────────────────────
    local START_KOHA=""
    prompt_yn "Start Koha now? (y/n):" "y" START_KOHA
    if [ "$START_KOHA" = "y" ] || [ "$START_KOHA" = "Y" ]; then
        docker compose up -d \
            && log_success "Koha starting (takes 2–3 min on first run)" \
            || log_warning "Start failed — check: docker compose logs koha"
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   KOHA SETUP SUMMARY                                             ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Library name : $LIB_NAME  ($LIB_CODE)"
    echo "  Admin user   : $KOHA_ADMIN_USER"
    echo "  Admin pass   : $KOHA_ADMIN_PASS"
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────┐"
    echo "  │  IMPORTANT — Write down or save the admin password above.    │"
    echo "  │  You will type it during the web installer in Step 3.        │"
    echo "  │  Also stored in: $KOHA_DIR/config-main.env                   │"
    echo "  └──────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  NEXT STEPS:"
    echo "    1. Wait ~3 min, then open:  http://localhost:8098"
    echo "    2. Complete the web installer (use password above when asked)"
    echo "    3. Run:  sudo $KOHA_DIR/post-setup.sh"
    echo ""
    echo "  OPAC (patron UI):  http://localhost:8097"
    echo "  Staff / admin:     http://localhost:8098"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_koha
