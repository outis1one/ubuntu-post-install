#!/bin/bash
# services/nextcloud.sh — Self-hosted cloud storage with SMB/local file access (Nextcloud).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash nextcloud.sh
# (Docker must already be installed when run standalone)

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
        }

        write_readme() {
            local _dir="$1"; shift
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
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

            # Support remote Caddy host via CADDY_REMOTE_HOST
            if [[ -n "${CADDY_REMOTE_HOST:-}" ]]; then
                log_info "Remote Caddy detected at $CADDY_REMOTE_HOST — printing block to add manually."
                echo ""
                echo "  Add the following to your Caddyfile on $CADDY_REMOTE_HOST:"
                echo "  ──────────────────────────────────────────────────────────"
                echo "  # $_name"
                echo "  ${_subdomain}.${SITE_DOMAIN:-example.com} {"
                echo "      reverse_proxy $_upstream"
                [[ -n "$_extra" ]] && echo "$_extra"
                echo "  }"
                echo "  ──────────────────────────────────────────────────────────"
                return 0
            fi

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

register_service nextcloud utilities "Self-hosted cloud storage with SMB/local file access (Nextcloud)" 8080

install_nextcloud() {
    require_docker || return 1
    log_info "Installing Nextcloud..."
    local DIR="$DOCKER_DIR/nextcloud"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with Dockerfile, docker-compose.yml, .env"
        return 0
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local DB_PASS
    DB_PASS=$(generate_password 32)
    local NC_ADMIN_PASS
    NC_ADMIN_PASS=$(generate_password 16)
    local TZ_VAL="${SITE_TZ:-UTC}"

    # ── Dockerfile ──────────────────────────────────────────────────────────
    cat > Dockerfile << 'NCDF'
FROM nextcloud:apache

RUN apt-get update \
 && apt-get install -y --no-install-recommends procps smbclient \
 && rm -rf /var/lib/apt/lists/*
NCDF

    # ── docker-compose.yml ──────────────────────────────────────────────────
    cat > docker-compose.yml << 'NCCOMPOSE'
name: nextcloud
services:
  nextcloud:
    build: .
    container_name: nextcloud
    hostname: nextcloud
    restart: unless-stopped
    env_file: .env
    depends_on:
      - db
    volumes:
      - ./html:/var/www/html
      - ./config:/var/www/html/config
      - ./custom_apps:/var/www/html/custom_apps
    ports:
      - "8080:80"
    networks:
      - caddy_net

  db:
    image: mariadb:10.11
    container_name: nextcloud-db
    hostname: nextcloud-db
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db:/var/lib/mysql
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
NCCOMPOSE

    # ── .env ────────────────────────────────────────────────────────────────
    cat > .env << NCENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# MariaDB
MYSQL_ROOT_PASSWORD=$DB_PASS
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=$DB_PASS
MARIADB_AUTO_UPGRADE=1

# Nextcloud bootstrap (first run only)
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$NC_ADMIN_PASS
NEXTCLOUD_DB_TYPE=mysql
MYSQL_HOST=db

# Reverse proxy (required for correct share links and redirects behind Caddy)
OVERWRITEPROTOCOL=https
OVERWRITECLIURL=https://cloud.${SITE_DOMAIN:-example.com}
TRUSTED_PROXIES=172.16.0.0/12
NCENV
    chmod 600 .env

    # ── Subdirectories ──────────────────────────────────────────────────────
    mkdir -p html config custom_apps db
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    echo ""
    log_success "Nextcloud configured at $DIR"

    configure_caddy_for_service "Nextcloud" "nextcloud:80" "cloud"

    # ── Prompt to start ─────────────────────────────────────────────────────
    local START_NC=""
    prompt_yn "Start Nextcloud now? (y/n):" "y" START_NC
    if [ "$START_NC" = "y" ] || [ "$START_NC" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Nextcloud started" \
            || { log_warning "Start failed — check: docker compose logs"; return 1; }

        # ── Wait for occ and enable files_external ──────────────────────────
        log_info "Waiting for Nextcloud to initialize (up to 90s)..."
        local _wait=0
        until docker exec nextcloud php occ status 2>/dev/null | grep -q "installed: true"; do
            sleep 5; _wait=$((_wait+5))
            [ $_wait -ge 90 ] && { log_warning "Nextcloud not ready after 90s — enable files_external manually"; break; }
        done
        if docker exec nextcloud php occ app:enable files_external 2>/dev/null; then
            log_success "files_external app enabled (SMB/local external storage)"
        fi
    fi

    # ── README ───────────────────────────────────────────────────────────────
    write_readme "$DIR" << NCREADME
# Nextcloud

Self-hosted cloud storage with SMB/local file access.

## Access

- URL:      https://cloud.${SITE_DOMAIN:-example.com}  (or http://localhost:8080)
- Admin:    admin
- Password: see \`NEXTCLOUD_ADMIN_PASSWORD\` in \`$DIR/.env\`

## Manage

\`\`\`bash
docker compose up -d --build   # start / rebuild
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull && docker compose up -d --build   # update
\`\`\`

## Run occ commands

\`\`\`bash
docker exec -u www-data nextcloud php occ <command>
\`\`\`

## Enable external storage (SMB / local)

\`\`\`bash
docker exec -u www-data nextcloud php occ app:enable files_external
\`\`\`

Then configure mounts in Nextcloud → Settings → External Storages.

## Backup

Back up these directories:
- \`$DIR/html\`        — Nextcloud application files
- \`$DIR/config\`      — configuration
- \`$DIR/custom_apps\` — third-party apps
- \`$DIR/db\`          — MariaDB data
- \`$DIR/.env\`        — credentials (permissions 600)
NCREADME

    echo ""
    echo "  Access URL:   http://localhost:8080"
    echo "  Admin user:   admin"
    echo "  Admin pass:   $NC_ADMIN_PASS"
    echo "  Config dir:   $DIR"
    echo ""
    echo "  Note: First startup may take 1-2 minutes while Nextcloud initialises."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_nextcloud
