#!/bin/bash
# services/nextcloud.sh — Self-hosted cloud storage with SMB/local file access (Nextcloud).
# Part of the modular post-install system (sourced by setup.sh).
#
# Uses a custom Dockerfile (nextcloud:apache + smbclient) so SMB external storage
# works without AIO.  All data uses bind mounts under ~/docker/nextcloud/ so that
# Kopia/Borg backup scripts cover everything automatically.
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
        # One-off copy — inline minimal stubs
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
                log_info "Access $_name directly on port 8080."
                return 0
            fi

            echo ""
            local _do_caddy=""
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:8080"
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

register_service nextcloud utilities "Self-hosted cloud storage with SMB/local file access (Nextcloud)" 8080

install_nextcloud() {
    require_docker || return 1
    log_info "Installing Nextcloud..."
    local DIR="$DOCKER_DIR/nextcloud"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with:"
        echo "[DRY-RUN]   Dockerfile (nextcloud:apache + smbclient)"
        echo "[DRY-RUN]   docker-compose.yml (nextcloud + mariadb:10.11)"
        echo "[DRY-RUN]   .env with generated DB and admin passwords"
        echo "[DRY-RUN]   Bind-mount directories: html/ db/ config/ custom_apps/"
        echo "[DRY-RUN] Would expose Nextcloud on port 8080"
        echo "[DRY-RUN] Would enable files_external app via occ after deploy"
        return 0
    fi

    mkdir -p "$DIR/html" "$DIR/db" "$DIR/config" "$DIR/custom_apps"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local DB_PASS NC_ADMIN_PASS TZ_VAL
    DB_PASS=$(generate_password 32)
    NC_ADMIN_PASS=$(generate_password 24)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # ── Dockerfile — adds SMB support to the official apache image ────────────
    cat > Dockerfile << 'DOCKERFILE'
FROM nextcloud:apache

RUN apt-get update \
 && apt-get install -y --no-install-recommends procps smbclient \
 && rm -rf /var/lib/apt/lists/*
DOCKERFILE

    # ── docker-compose.yml — single-quoted EOF prevents variable expansion ────
    cat > docker-compose.yml << 'EOF'
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
EOF

    # ── .env — actual variable values (NOT inside the compose heredoc) ────────
    cat > .env << NC_ENV
# ── Timezone & network ────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── MariaDB ───────────────────────────────────────────────────────────────────
MYSQL_ROOT_PASSWORD=$DB_PASS
MYSQL_DATABASE=nextcloud
MYSQL_USER=nextcloud
MYSQL_PASSWORD=$DB_PASS
MARIADB_AUTO_UPGRADE=1

# ── Nextcloud bootstrap ───────────────────────────────────────────────────────
# These are used only on the very first startup to create the admin account
# and wire up the database.  They are ignored on subsequent startups.
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=$NC_ADMIN_PASS
NEXTCLOUD_DB_TYPE=mysql
MYSQL_HOST=db
NC_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"
    log_success "Nextcloud configured at $DIR"

    configure_caddy_for_service "Nextcloud" "nextcloud:80" "cloud"

    write_readme "$DIR" << MD
# Nextcloud

Self-hosted cloud storage — files, contacts, calendar, notes, and more.
SMB/local external storage is enabled via a custom Docker image (nextcloud:apache + smbclient).

## Access
- URL: http://localhost:8080
- Admin user: \`admin\`
- Admin password: see \`NEXTCLOUD_ADMIN_PASSWORD\` in \`.env\`

## Directory layout (all bind-mounted — covered by Kopia/Borg backups)
\`\`\`
$DIR/
  html/         # Nextcloud web root (PHP app + uploaded files)
  config/       # config.php and other Nextcloud config files
  custom_apps/  # manually installed apps not shipped with Nextcloud
  db/           # MariaDB data directory
  Dockerfile    # custom image definition (adds smbclient)
  docker-compose.yml
  .env          # secrets — chmod 600
\`\`\`

## External Storage (SMB / local paths)
The \`files_external\` app is enabled automatically during setup.
Add mounts in the Nextcloud web UI:
**Admin → Administration → External Storage**

Supported backends: Local, SMB/CIFS, FTP, S3, WebDAV, and more.

## Manage
\`\`\`bash
cd $DIR
docker compose up -d                                      # start
docker compose down                                       # stop
docker compose logs -f                                    # logs
docker compose build --pull && docker compose up -d      # rebuild image + update
docker exec --user www-data nextcloud php occ list        # occ CLI
\`\`\`

## Backup note
All data lives under \`$DIR/\` as bind mounts.
Include this directory in your Kopia/Borg backup policy.
Run \`docker compose down\` before a cold backup of \`db/\` for consistency,
or use \`mysqldump\` for a hot backup:
\`\`\`bash
docker exec nextcloud-db mysqldump -u nextcloud -p\$MYSQL_PASSWORD nextcloud > nextcloud_db.sql
\`\`\`
MD

    local START_NC=""
    prompt_yn "Start Nextcloud now? (y/n):" "y" START_NC
    if [ "$START_NC" = "y" ] || [ "$START_NC" = "Y" ]; then
        docker compose up -d \
            && log_success "Nextcloud started — first boot may take 1-2 minutes" \
            || { log_warning "Start failed — check: docker compose logs"; return 1; }

        # Wait for Nextcloud to finish first-boot initialisation before running occ
        log_info "Waiting for Nextcloud to finish initialising (up to 90 s)..."
        local _waited=0
        until docker exec --user www-data nextcloud php occ status --output=json 2>/dev/null \
              | grep -q '"installed":true'; do
            sleep 5
            _waited=$(( _waited + 5 ))
            if (( _waited >= 90 )); then
                log_warning "Nextcloud did not finish initialising within 90 s."
                log_warning "Run the occ command manually once the container is ready:"
                log_warning "  docker exec --user www-data nextcloud php occ app:enable files_external"
                break
            fi
        done

        if (( _waited < 90 )); then
            if docker exec --user www-data nextcloud php occ app:enable files_external; then
                log_success "External Storage app enabled"
            else
                log_warning "Could not enable files_external — run manually:"
                log_warning "  docker exec --user www-data nextcloud php occ app:enable files_external"
            fi
        fi
    fi

    echo ""
    echo "  URL:            http://localhost:8080"
    echo "  Admin user:     admin"
    echo "  Admin password: $NC_ADMIN_PASS"
    echo "  (Credentials also saved to $DIR/.env)"
    echo ""
    echo "  To add SMB or local external storage:"
    echo "    Nextcloud → Admin → Administration → External Storage"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_nextcloud
