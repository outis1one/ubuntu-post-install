#!/bin/bash
# services/immich.sh — Self-hosted photo & video backup (like Google Photos).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash immich.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- IMMICH ----).
# Multi-container stack: immich-server + machine-learning + valkey + postgres.
# Two library strategies:
#   1) Unified  — Immich manages all photos in one place (import-photos.sh helps)
#   2) External — Immich indexes your existing folder read-only; new uploads separate

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

register_service immich media "Self-hosted photo & video backup — like Google Photos (Immich)" 2283

install_immich() {
    require_docker || return 1

    local IMMICH_DIR="$DOCKER_DIR/immich"
    local DEFAULT_PHOTOS="$ACTUAL_HOME/photos"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Immich would:"
        echo "  - Create $IMMICH_DIR with docker-compose.yml + .env"
        echo "  - Deploy: immich-server, immich-machine-learning, valkey, postgres"
        echo "  - Strategy 1 (unified): all photos in one folder, import-photos.sh helper"
        echo "  - Strategy 2 (external): existing photos indexed read-only, new uploads separate"
        echo "  - Expose port 2283"
        echo "  - Offer a Caddy reverse proxy and to start the stack"
        return 0
    fi

    # ── Photo library setup ─────────────────────────────────────────────────
    echo ""
    echo "  PHOTO LIBRARY SETUP"
    echo ""

    local IMMICH_STRATEGY="1" UPLOAD_LOCATION="" EXTERNAL_LIBRARY="" EXISTING_PHOTOS_SOURCE=""
    local HAS_EXISTING_PHOTOS=""
    prompt_yn "Do you have existing photos to include? (y/n):" "n" HAS_EXISTING_PHOTOS

    if [ "$HAS_EXISTING_PHOTOS" = "y" ] || [ "$HAS_EXISTING_PHOTOS" = "Y" ]; then
        echo ""
        echo "  How should Immich handle your existing photos?"
        echo ""
        echo "    [1] Import into Immich (recommended)"
        echo "        Immich manages all photos in one unified library."
        echo "        Dates preserved via EXIF. Organized by date automatically."
        echo "        Your original folder names are NOT kept on disk"
        echo "        (use Immich albums to organize instead)."
        echo ""
        echo "    [2] Keep existing photos in place (read-only external library)"
        echo "        Immich indexes your existing photos without moving them."
        echo "        New uploads go to a separate folder."
        echo "        Your folder structure stays intact."
        echo ""

        if [ "$UNATTENDED" = true ]; then
            IMMICH_STRATEGY="1"
            echo "  Strategy: [auto: 1]"
        else
            read -r -p "  Choose [1/2]: " IMMICH_STRATEGY
            IMMICH_STRATEGY="${IMMICH_STRATEGY:-1}"
        fi

        if [ "$IMMICH_STRATEGY" = "2" ]; then
            local EXISTING_PHOTOS_PATH=""
            prompt_text "Existing photos path [$DEFAULT_PHOTOS]:" "$DEFAULT_PHOTOS" EXISTING_PHOTOS_PATH
            EXISTING_PHOTOS_SOURCE="${EXISTING_PHOTOS_PATH/#\~/$ACTUAL_HOME}"; EXISTING_PHOTOS_SOURCE="${EXISTING_PHOTOS_SOURCE%/}"
            UPLOAD_LOCATION="$ACTUAL_HOME/immich-uploads"
            EXTERNAL_LIBRARY="$EXISTING_PHOTOS_SOURCE"
            echo ""
            echo "  Setup:"
            echo "    Existing photos: $EXISTING_PHOTOS_SOURCE  (read-only)"
            echo "    New uploads:     $UPLOAD_LOCATION"
        else
            local PHOTOS_DIR_INPUT=""
            prompt_text "Photo library path [$DEFAULT_PHOTOS]:" "$DEFAULT_PHOTOS" PHOTOS_DIR_INPUT
            PHOTOS_DIR_INPUT="${PHOTOS_DIR_INPUT/#\~/$ACTUAL_HOME}"; PHOTOS_DIR_INPUT="${PHOTOS_DIR_INPUT%/}"

            local EXISTING_INPUT=""
            prompt_text "Existing photos path [$PHOTOS_DIR_INPUT]:" "$PHOTOS_DIR_INPUT" EXISTING_INPUT
            EXISTING_PHOTOS_SOURCE="${EXISTING_INPUT/#\~/$ACTUAL_HOME}"; EXISTING_PHOTOS_SOURCE="${EXISTING_PHOTOS_SOURCE%/}"

            UPLOAD_LOCATION="$PHOTOS_DIR_INPUT"
            echo ""
            echo "  All photos (existing + new) will live in: $PHOTOS_DIR_INPUT"
        fi
    else
        local PHOTOS_DIR_INPUT=""
        prompt_text "Photo library path [$DEFAULT_PHOTOS]:" "$DEFAULT_PHOTOS" PHOTOS_DIR_INPUT
        PHOTOS_DIR_INPUT="${PHOTOS_DIR_INPUT/#\~/$ACTUAL_HOME}"; PHOTOS_DIR_INPUT="${PHOTOS_DIR_INPUT%/}"
        UPLOAD_LOCATION="$PHOTOS_DIR_INPUT"
        echo ""
        echo "  Photos will be stored in: $PHOTOS_DIR_INPUT"
    fi

    echo ""

    # ── Create directories ──────────────────────────────────────────────────
    mkdir -p "$IMMICH_DIR"
    ensure_docker_dir_ownership "$IMMICH_DIR"
    mkdir -p "$UPLOAD_LOCATION"
    [ -n "$EXTERNAL_LIBRARY" ] && mkdir -p "$EXTERNAL_LIBRARY"

    # Immich checks for these subdirs + .immich marker files on startup
    local subdir
    for subdir in thumbs upload backups library profile encoded-video; do
        mkdir -p "$UPLOAD_LOCATION/$subdir"
        touch "$UPLOAD_LOCATION/$subdir/.immich"
    done

    cd "$IMMICH_DIR" || return 1

    # ── Generate DB password ────────────────────────────────────────────────
    local DB_PASS TZ_VAL
    DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # ── Write docker-compose.yml ────────────────────────────────────────────
    local _CADDY_NET_BLOCK=""
    if [ -d "$DOCKER_DIR/caddy" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
    fi

    local _CADDY_NET_SECTION=""
    if [ -d "$DOCKER_DIR/caddy" ]; then
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    if [ -n "$EXTERNAL_LIBRARY" ]; then
        cat > docker-compose.yml << IMMICH_COMPOSE
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:\${IMMICH_VERSION:-release}
    volumes:
      - \${UPLOAD_LOCATION}:/usr/src/app/upload
      - \${EXTERNAL_LIBRARY}:/usr/src/app/external:ro
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - 2283:2283
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false
${_CADDY_NET_BLOCK}
  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:\${IMMICH_VERSION:-release}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9-bookworm
    healthcheck:
      test: valkey-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_USER: \${DB_USERNAME}
      POSTGRES_DB: \${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - \${DB_DATA_LOCATION}:/var/lib/postgresql/data
    restart: always

volumes:
  model-cache:
${_CADDY_NET_SECTION}
IMMICH_COMPOSE
    else
        cat > docker-compose.yml << IMMICH_COMPOSE
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:\${IMMICH_VERSION:-release}
    volumes:
      - \${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - 2283:2283
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false
${_CADDY_NET_BLOCK}
  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:\${IMMICH_VERSION:-release}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:9-bookworm
    healthcheck:
      test: valkey-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: \${DB_PASSWORD}
      POSTGRES_USER: \${DB_USERNAME}
      POSTGRES_DB: \${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - \${DB_DATA_LOCATION}:/var/lib/postgresql/data
    restart: always

volumes:
  model-cache:
${_CADDY_NET_SECTION}
IMMICH_COMPOSE
    fi

    # ── Write .env ──────────────────────────────────────────────────────────
    if [ "$IMMICH_STRATEGY" = "2" ]; then
        cat > .env << IMMICH_ENV
# IMMICH CONFIGURATION — External Library Mode
#
# STORAGE TEMPLATE (set in Immich web UI):
#   Admin → Settings → Storage Template → Enable
#   Template: {{y}}/{{MM}}/{{filename}}
#
# EXTERNAL LIBRARY SETUP:
#   Admin → External Libraries → Create Library
#   Import path: /usr/src/app/external
#   Click "Scan" to index your existing photos.

# New uploads from phone/web
UPLOAD_LOCATION=$UPLOAD_LOCATION

# Existing photos (read-only, indexed by Immich)
EXTERNAL_LIBRARY=$EXTERNAL_LIBRARY

DB_DATA_LOCATION=./postgres
IMMICH_VERSION=release
DB_PASSWORD=$DB_PASS
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET
IMMICH_ENV
    else
        cat > .env << IMMICH_ENV
# IMMICH CONFIGURATION — Unified Library
#
# All photos (imported + new uploads) are stored in one location.
# Storage template organizes files by date automatically.
#
# To import existing photos run: $IMMICH_DIR/import-photos.sh

UPLOAD_LOCATION=$UPLOAD_LOCATION
DB_DATA_LOCATION=./postgres
IMMICH_VERSION=release
DB_PASSWORD=$DB_PASS
DB_USERNAME=postgres
DB_DATABASE_NAME=immich
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET
IMMICH_ENV
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$IMMICH_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$UPLOAD_LOCATION"
    [ -n "$EXTERNAL_LIBRARY" ] && chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EXTERNAL_LIBRARY" 2>/dev/null || true

    # ── import-photos.sh (strategy 1 + existing photos only) ───────────────
    if [ "$IMMICH_STRATEGY" != "2" ] && [ -n "$EXISTING_PHOTOS_SOURCE" ]; then
        cat > "$IMMICH_DIR/import-photos.sh" << 'IMPORT_HEAD'
#!/bin/bash
################################################################################
# Immich Photo Import Script — generated by ubuntu-post-install
#
# Imports your existing photo collection into Immich with EXIF date preservation.
# Photos are uploaded through the API so Immich extracts metadata (dates, GPS,
# camera info) from the originals.
#
# What this script does:
#   1. Creates admin account (if first run) or logs in
#   2. Generates an API key automatically
#   3. Configures the storage template (date-based organization)
#   4. Installs the Immich CLI (if needed)
#   5. Uploads all photos with EXIF metadata preserved
#
# Usage:
#   ./import-photos.sh              # interactive (prompts for everything)
#   ./import-photos.sh <api-key>    # skip account setup, use existing key
################################################################################

IMPORT_HEAD

        cat >> "$IMMICH_DIR/import-photos.sh" << IMPORT_VARS
IMMICH_URL="http://localhost:2283"
SOURCE_DIR="$EXISTING_PHOTOS_SOURCE"
IMMICH_DIR="$IMMICH_DIR"
IMPORT_VARS

        cat >> "$IMMICH_DIR/import-photos.sh" << 'IMPORT_BODY'

echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ IMMICH PHOTO IMPORT                                            │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""

# ── Preflight checks ────────────────────────────────────────────────────────
echo "Checking Immich server..."
if ! curl -s "$IMMICH_URL/api/server/ping" > /dev/null 2>&1; then
    echo ""
    echo "  ✗ Immich is not running at $IMMICH_URL"
    echo "    Start it with: cd $IMMICH_DIR && docker compose up -d"
    echo ""
    exit 1
fi
echo "  ✓ Immich is running"

if [ ! -d "$SOURCE_DIR" ]; then
    echo ""
    echo "  ✗ Source directory not found: $SOURCE_DIR"
    echo "    Update SOURCE_DIR in this script if your photos moved."
    echo ""
    exit 1
fi
echo "  ✓ Source directory: $SOURCE_DIR"

echo -n "  Scanning for photos/videos..."
PHOTO_COUNT=$(find "$SOURCE_DIR" -type f \( \
    -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.heic" -o \
    -iname "*.heif" -o -iname "*.webp" -o -iname "*.gif" -o -iname "*.tiff" -o \
    -iname "*.bmp" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" -o \
    -iname "*.mkv" -o -iname "*.webm" \) 2>/dev/null | wc -l)
echo " done"
echo "  ✓ Found ~$PHOTO_COUNT photos/videos"

# ── Get or create API key ────────────────────────────────────────────────────
API_KEY="${1:-}"

if [ -z "$API_KEY" ]; then
    echo ""
    SERVER_CONFIG=$(curl -s "$IMMICH_URL/api/server/config" 2>/dev/null)
    IS_INITIALIZED=$(echo "$SERVER_CONFIG" | python3 -c \
        "import sys,json; print(json.load(sys.stdin).get('isInitialized', True))" 2>/dev/null)

    if [ "$IS_INITIALIZED" = "False" ]; then
        echo "┌─────────────────────────────────────────────────────────────────┐"
        echo "│ FIRST-TIME SETUP — Creating admin account                      │"
        echo "└─────────────────────────────────────────────────────────────────┘"
        echo ""
        read -r -p "  Admin email: " ADMIN_EMAIL
        while [ -z "$ADMIN_EMAIL" ]; do
            read -r -p "  Admin email (required): " ADMIN_EMAIL
        done
        read -r -sp "  Admin password: " ADMIN_PASS; echo ""
        while [ "${#ADMIN_PASS}" -lt 8 ]; do
            echo "  Password must be at least 8 characters."
            read -r -sp "  Admin password: " ADMIN_PASS; echo ""
        done
        read -r -p "  Your name [Admin]: " ADMIN_NAME
        ADMIN_NAME="${ADMIN_NAME:-Admin}"

        echo ""
        echo "  Creating admin account..."
        SIGNUP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
            -H "Content-Type: application/json" \
            "$IMMICH_URL/api/auth/admin-sign-up" \
            -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\",\"name\":\"$ADMIN_NAME\"}" 2>/dev/null)
        SIGNUP_CODE=$(echo "$SIGNUP_RESPONSE" | tail -1)
        SIGNUP_BODY=$(echo "$SIGNUP_RESPONSE" | sed '$d')

        if [ "$SIGNUP_CODE" = "201" ]; then
            echo "  ✓ Admin account created"
        else
            echo "  ✗ Failed to create admin account (HTTP $SIGNUP_CODE)"
            echo "  Response: $SIGNUP_BODY"
            echo "  Create your account at $IMMICH_URL then re-run: $0 <api-key>"
            exit 1
        fi
    else
        echo "  Immich is already set up. Log in to generate an API key."
        echo ""
        read -r -p "  Admin email: " ADMIN_EMAIL
        while [ -z "$ADMIN_EMAIL" ]; do
            read -r -p "  Admin email (required): " ADMIN_EMAIL
        done
        read -r -sp "  Admin password: " ADMIN_PASS; echo ""
    fi

    echo "  Logging in..."
    LOGIN_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        "$IMMICH_URL/api/auth/login" \
        -d "{\"email\":\"$ADMIN_EMAIL\",\"password\":\"$ADMIN_PASS\"}" 2>/dev/null)
    LOGIN_CODE=$(echo "$LOGIN_RESPONSE" | tail -1)
    LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | sed '$d')

    if [ "$LOGIN_CODE" != "201" ]; then
        echo "  ✗ Login failed (HTTP $LOGIN_CODE)"
        echo "  Check your email/password, or pass an API key: $0 <api-key>"
        exit 1
    fi

    ACCESS_TOKEN=$(echo "$LOGIN_BODY" | python3 -c \
        "import sys,json; print(json.load(sys.stdin)['accessToken'])" 2>/dev/null)
    [ -z "$ACCESS_TOKEN" ] && { echo "  ✗ Could not extract access token"; exit 1; }
    echo "  ✓ Logged in"

    echo "  Creating API key..."
    APIKEY_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        "$IMMICH_URL/api/api-keys" \
        -d '{"name":"import-photos-script"}' 2>/dev/null)
    APIKEY_CODE=$(echo "$APIKEY_RESPONSE" | tail -1)
    APIKEY_BODY=$(echo "$APIKEY_RESPONSE" | sed '$d')

    if [ "$APIKEY_CODE" = "201" ]; then
        API_KEY=$(echo "$APIKEY_BODY" | python3 -c \
            "import sys,json; print(json.load(sys.stdin)['secret'])" 2>/dev/null)
        if [ -n "$API_KEY" ]; then
            echo "  ✓ API key created"
        else
            echo "  ✗ Could not extract API key"
            echo "  Create one at $IMMICH_URL → Account Settings → API Keys"
            echo "  Then re-run: $0 <api-key>"
            exit 1
        fi
    else
        echo "  ✗ Failed to create API key (HTTP $APIKEY_CODE)"
        echo "  Create one at $IMMICH_URL → Account Settings → API Keys"
        echo "  Then re-run: $0 <api-key>"
        exit 1
    fi
else
    echo ""
    echo "  Verifying API key..."
    VERIFY_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "x-api-key: $API_KEY" "$IMMICH_URL/api/users/me" 2>/dev/null)
    [ "$VERIFY_CODE" != "200" ] && { echo "  ✗ Invalid API key (HTTP $VERIFY_CODE)"; exit 1; }
    echo "  ✓ API key valid"
fi

# ── Configure storage template ───────────────────────────────────────────────
echo ""
echo "  Configuring storage template ({{y}}/{{MM}}/{{filename}})..."
CURRENT_CONFIG=$(curl -s -H "x-api-key: $API_KEY" "$IMMICH_URL/api/system-config" 2>/dev/null)
if [ -n "$CURRENT_CONFIG" ] && command -v python3 &>/dev/null; then
    UPDATED_CONFIG=$(echo "$CURRENT_CONFIG" | python3 -c "
import sys, json
config = json.load(sys.stdin)
config['storageTemplate']['enabled'] = True
config['storageTemplate']['template'] = '{{y}}/{{MM}}/{{filename}}'
json.dump(config, sys.stdout)
" 2>/dev/null)
    if [ -n "$UPDATED_CONFIG" ]; then
        RESULT=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
            -H "x-api-key: $API_KEY" \
            -H "Content-Type: application/json" \
            "$IMMICH_URL/api/system-config" \
            -d "$UPDATED_CONFIG" 2>/dev/null)
        [ "$RESULT" = "200" ] \
            && echo "  ✓ Storage template configured" \
            || echo "  ⚠ Could not set template (HTTP $RESULT) — set manually in Admin → Settings"
    else
        echo "  ⚠ Could not parse config — set storage template manually in Admin → Settings"
    fi
else
    echo "  ⚠ python3 not found — set storage template manually in Admin → Settings"
fi

# ── Install immich-cli if needed ─────────────────────────────────────────────
echo ""
IMMICH_CMD=""
NODE_OK=false
if command -v node &>/dev/null; then
    NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    [ "$NODE_MAJOR" -ge 20 ] 2>/dev/null && NODE_OK=true
fi

if [ "$NODE_OK" = false ]; then
    echo "  Immich CLI requires Node.js >= 20 (found: $(node -v 2>/dev/null || echo 'none'))."
    read -r -p "  Install Node.js 24 LTS now? (y/n): " INSTALL_NODE_YN
    if [ "$INSTALL_NODE_YN" = "y" ] || [ "$INSTALL_NODE_YN" = "Y" ]; then
        curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - 2>/dev/null
        sudo apt-get install -y -qq nodejs 2>/dev/null
        NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        if [ "$NODE_MAJOR" -ge 20 ] 2>/dev/null; then
            NODE_OK=true
            echo "  ✓ Node.js $(node -v) installed"
        else
            echo "  ✗ Installation failed — install Node.js 20+ manually then re-run: $0 $API_KEY"
            exit 1
        fi
    else
        echo "  Install Node.js 20+ and re-run: $0 $API_KEY"
        exit 0
    fi
fi

if command -v immich &>/dev/null; then
    IMMICH_CMD="immich"
    echo "  ✓ Immich CLI found"
elif command -v npx &>/dev/null; then
    echo "  Immich CLI not installed — will use npx."
    IMMICH_CMD="npx --yes @immich/cli"
elif command -v npm &>/dev/null; then
    echo "  Installing Immich CLI globally..."
    if npm install -g @immich/cli 2>/dev/null; then
        IMMICH_CMD="immich"
        echo "  ✓ Immich CLI installed"
    else
        IMMICH_CMD="npx --yes @immich/cli"
    fi
fi

[ -z "$IMMICH_CMD" ] && { echo "  ✗ No npm/npx found — install manually: npm install -g @immich/cli"; exit 1; }

# ── Run the import ───────────────────────────────────────────────────────────
echo ""
echo "  Authenticating CLI..."
$IMMICH_CMD login "$IMMICH_URL/api" "$API_KEY" || { echo "  ✗ CLI login failed"; exit 1; }

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Starting import from: $SOURCE_DIR"
echo "  Importing ~$PHOTO_COUNT files. This may take a while."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

$IMMICH_CMD upload --recursive "$SOURCE_DIR"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Import complete! View your photos at: $IMMICH_URL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
IMPORT_BODY

        chmod +x "$IMMICH_DIR/import-photos.sh"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$IMMICH_DIR/import-photos.sh"
        log_success "Import helper written: $IMMICH_DIR/import-photos.sh"
    fi

    log_success "Immich configured at $IMMICH_DIR"

    configure_caddy_for_service "Immich" "immich-server:2283" "immich"

    write_readme "$IMMICH_DIR" << MD
# Immich

Self-hosted photo and video backup — like Google Photos but private.
Mobile apps (iOS/Android) auto-upload in the background.

- Web UI: http://localhost:2283
- Photo storage: \`$UPLOAD_LOCATION\`
- App data (postgres, model cache): inside this folder
- Edit paths in \`.env\`, then \`docker compose up -d\` to apply.

## Manage
\`\`\`bash
cd $IMMICH_DIR
docker compose up -d      # start all containers
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## First launch
1. Open http://localhost:2283 and create your admin account.
2. Install the Immich mobile app and point it at \`http://<server-ip>:2283\`.
3. (External library mode) Go to Admin → External Libraries → Create Library,
   set import path to \`/usr/src/app/external\`, and click Scan.

## Import existing photos (unified mode)
\`\`\`bash
./import-photos.sh          # interactive
./import-photos.sh <key>    # skip login, use existing API key
\`\`\`

## Notes
- Machine learning features (face recognition, CLIP search) require the
  \`immich-machine-learning\` container — it pulls a large model on first run.
- The \`.immich\` marker files in the upload subdirs are required by Immich;
  do not delete them.
MD

    local START_IMMICH=""
    prompt_yn "Start Immich now? (y/n):" "y" START_IMMICH
    if [ "$START_IMMICH" = "y" ] || [ "$START_IMMICH" = "Y" ]; then
        docker compose up -d && log_success "Immich started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:2283"
    echo "  First launch: create your admin account in the web UI."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_immich
