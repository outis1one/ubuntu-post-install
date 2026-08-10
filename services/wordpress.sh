#!/bin/bash
# services/wordpress.sh — Self-hosted WordPress sites, multi-site, dedicated MariaDB per site.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash wordpress.sh
# (Docker must already be installed when run standalone)
#
# Every WordPress site gets its own directory, its own WordPress container,
# and its own dedicated MariaDB container (same pattern as services/
# nextcloud.sh) — deliberately NOT a shared MariaDB instance across sites.
# A shared instance would mean one site's database backup/restore is
# entangled with every other site's: Kopia's generic backup (services/
# backup.sh) stops a service's container to get a consistent snapshot, so a
# shared instance backs up (and would have to be restored) as one unit
# covering every site at once, not one site independently. Costs more RAM
# per site (a full MariaDB container each, ~100-150MB, instead of one
# instance split across sites) in exchange for real backup/restore
# isolation — each site's database can be restored to any point in time
# without touching any other site's current data.
#
# E-commerce (WooCommerce) is just a normal WordPress plugin — no separate
# infrastructure needed. PHP upload/memory limits are tuned upfront so it
# works well the first time instead of hitting default-image limits on the
# first product-image import.

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

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_reinstall_mode() {
            local _var="$1" _r
            if [[ "${UNATTENDED:-false}" == "true" ]]; then eval "$_var='cancel'"; return; fi
            echo "  Existing install detected. Choose:"
            echo "    r) Reinstall in place — refresh image/compose, keep database and settings"
            echo "    f) Full install — re-run every prompt from scratch"
            echo "    c) Cancel — leave everything as-is [default]"
            read -r -p "  Choice [r/f/c, Enter=cancel]: " _r
            case "${_r,,}" in
                r) eval "$_var='update'" ;;
                f) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
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
            [[ "$_mode" == "remote" ]] && _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"

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
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
            fi
        }

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$_dir/README.md" 2>/dev/null || true
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

register_service wordpress utilities "Self-hosted WordPress sites (multi-site, dedicated MariaDB per site) — blogs, business sites, e-commerce via WooCommerce" 8090

install_wordpress() {
    require_docker || return 1

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ WORDPRESS                                                        │"
    echo "│ Self-hosted WordPress site — blog, business site, or store       │"
    echo "│ (WooCommerce is just a plugin — install it from the WP admin     │"
    echo "│  after setup, no extra infrastructure needed for e-commerce)     │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would prompt for a site name (directory/container naming)"
        echo "[DRY-RUN] Would create \$DOCKER_DIR/wordpress-<site> with docker-compose.yml + .env"
        echo "[DRY-RUN]   including a dedicated MariaDB container for this site alone (not shared"
        echo "[DRY-RUN]   with other sites — independent backup/restore per site)"
        echo "[DRY-RUN] Would tune PHP memory_limit/upload_max_filesize for WooCommerce-readiness"
        echo "[DRY-RUN] Would auto-scan for a free host port for this site"
        echo "[DRY-RUN] Would run wp-cli to install WordPress core non-interactively (site title,"
        echo "[DRY-RUN]   admin account) instead of leaving a setup wizard for a browser to finish"
        echo "[DRY-RUN] Would offer a Caddy reverse proxy and to start the site"
        return 0
    fi

    # ── Site name (used for directory/container naming) ─────────────────────
    local SITE_NAME=""
    while [ -z "$SITE_NAME" ]; do
        prompt_text "Site name (letters/numbers/hyphens, e.g. 'myblog' or 'client-store'):" "" SITE_NAME
        SITE_NAME="$(echo "$SITE_NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
        SITE_NAME="${SITE_NAME#-}"; SITE_NAME="${SITE_NAME%-}"
        if [ -z "$SITE_NAME" ]; then
            if [ "$UNATTENDED" = true ]; then
                SITE_NAME="site1"
            else
                log_warning "Site name required."
            fi
        fi
    done

    local DIR="$DOCKER_DIR/wordpress-$SITE_NAME"
    local CONTAINER="wordpress-$SITE_NAME"

    # ── Existing install (this exact site)? Offer update-in-place ───────────
    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing '$SITE_NAME''s image/compose only — database, domain, and"
                log_info "credentials are left exactly as they are."
                ( cd "$DIR" && docker compose pull && docker compose up -d )
                log_success "'$SITE_NAME' refreshed"
                return 0
                ;;
            cancel)
                log_info "Leaving '$SITE_NAME' as-is."
                return 0
                ;;
            fresh) ;;
        esac
    fi

    # ── This site's dedicated database credentials ───────────────────────────
    # The mariadb image creates MYSQL_DATABASE/MYSQL_USER itself from these
    # env vars on first boot — no imperative CREATE DATABASE step needed,
    # same as services/nextcloud.sh. Reused across reruns (read from the
    # existing .env if present) so a rerun never locks the site out of its
    # own already-initialized database.
    local DB_CONTAINER="${CONTAINER}-db"
    local WP_NET="${CONTAINER}_net"
    local WP_DB_NAME="wp_${SITE_NAME//-/_}"
    local WP_DB_USER="wp_${SITE_NAME//-/_}"
    local WP_DB_PASS="" WP_DB_ROOT_PASS=""
    if [ -f "$DIR/.env" ]; then
        WP_DB_PASS="$(grep '^WORDPRESS_DB_PASSWORD=' "$DIR/.env" | cut -d= -f2-)"
        WP_DB_ROOT_PASS="$(grep '^MYSQL_ROOT_PASSWORD=' "$DIR/.env" | cut -d= -f2-)"
    fi
    [ -n "$WP_DB_PASS" ] || WP_DB_PASS="$(generate_password 24)"
    [ -n "$WP_DB_ROOT_PASS" ] || WP_DB_ROOT_PASS="$(generate_password 32)"

    echo ""
    local WP_SITE_TITLE="" WP_ADMIN_USER="" WP_ADMIN_EMAIL=""
    prompt_text "Site title:" "$SITE_NAME" WP_SITE_TITLE
    prompt_text "Admin username:" "admin" WP_ADMIN_USER
    prompt_text "Admin email:" "" WP_ADMIN_EMAIL
    local WP_ADMIN_PASS=""
    [ -f "$DIR/.env" ] && WP_ADMIN_PASS="$(grep '^WP_ADMIN_PASSWORD=' "$DIR/.env" | cut -d= -f2-)"
    [ -n "$WP_ADMIN_PASS" ] || WP_ADMIN_PASS="$(generate_password 16)"

    # ── Free host port (multiple sites can't all bind the same one) ─────────
    # Was checking `docker ps -a` port lists — only catches ports Docker
    # itself currently has bound, not ports held by non-Docker processes or
    # anything else on the host. Confirmed live: this let a fresh site pick
    # an already-occupied port ("address already in use" at container
    # start). find_free_port checks actual OS-level listening sockets via
    # ss, the same convention every other service here follows — see
    # CLAUDE.md's "Port collision avoidance" section.
    local WEB_PORT=8090
    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$DIR/html" "$DIR/db" "$DIR/uploads-ini.d"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local TZ_VAL="${SITE_TZ:-UTC}"

    # PHP tuning for WooCommerce/media-heavy sites out of the box — default
    # image limits (2M uploads, 128M memory) are a common first-run surprise
    # otherwise, especially importing a product catalog.
    cat > uploads-ini.d/uploads.ini << 'PHPINI'
file_uploads = On
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 300
PHPINI

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_LINE="" _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_LINE="      - caddy_net
"
        _CADDY_NET_SECTION="
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    cat > docker-compose.yml << WPCOMPOSE
name: $CONTAINER

services:
  wordpress:
    image: wordpress:php8.3-apache
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    env_file: .env
    depends_on:
      - db
    volumes:
      - ./html:/var/www/html
      - ./uploads-ini.d/uploads.ini:/usr/local/etc/php/conf.d/uploads.ini:ro
    ports:
      - "${WEB_PORT}:80"
    networks:
      - default
${_CADDY_NET_LINE}
  db:
    image: mariadb:11
    container_name: $DB_CONTAINER
    hostname: $DB_CONTAINER
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db:/var/lib/mysql
    networks:
      - default

networks:
  default:
    name: $WP_NET
${_CADDY_NET_SECTION}
WPCOMPOSE

    cat > .env << WPENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# Dedicated MariaDB for this site alone (not shared with other WordPress
# sites) — independent backup/restore, at the cost of a full MariaDB
# container per site instead of one instance split across several.
MYSQL_ROOT_PASSWORD=$WP_DB_ROOT_PASS
MYSQL_DATABASE=$WP_DB_NAME
MYSQL_USER=$WP_DB_USER
MYSQL_PASSWORD=$WP_DB_PASS

WORDPRESS_DB_HOST=$DB_CONTAINER
WORDPRESS_DB_NAME=$WP_DB_NAME
WORDPRESS_DB_USER=$WP_DB_USER
WORDPRESS_DB_PASSWORD=$WP_DB_PASS

# Only consulted by wp-cli during initial setup below, not read by the
# wordpress:apache image itself (unlike Nextcloud's image, WordPress's
# official image has no built-in "create admin from env vars" feature).
WP_SITE_TITLE=$WP_SITE_TITLE
WP_ADMIN_USER=$WP_ADMIN_USER
WP_ADMIN_PASSWORD=$WP_ADMIN_PASS
WP_ADMIN_EMAIL=$WP_ADMIN_EMAIL
WPENV
    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    log_success "'$SITE_NAME' configured at $DIR (port $WEB_PORT)"

    configure_caddy_for_service "WordPress - $SITE_NAME" "${CONTAINER}:80" "$SITE_NAME"

    write_readme "$DIR" << MD
# WordPress — $SITE_NAME

Self-hosted WordPress site with its own **dedicated** MariaDB container
(\`$DB_CONTAINER\`, in \`db/\` below) — not shared with any other WordPress
site on this box. Costs more RAM per site than a shared database would, in
exchange for independent backup/restore: this site's database can be
restored to any point in time without touching any other site's data, since
each one is backed up (and would be restored) as its own separate Kopia
snapshot rather than being entangled with other sites in one shared
snapshot.

- Web UI: http://localhost:${WEB_PORT}
- Admin user: \`$WP_ADMIN_USER\`
- Admin password: see \`WP_ADMIN_PASSWORD\` in \`.env\`
- Site files: \`html/\`
- Database files: \`db/\`
- PHP limits: \`uploads-ini.d/uploads.ini\` (256M memory, 64M uploads —
  raise further here if a specific import still hits a limit)

## Manage
\`\`\`bash
cd $DIR
docker compose up -d      # start (both wordpress and its db)
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## wp-cli
Run any wp-cli command against this site without installing wp-cli on the
host:
\`\`\`bash
docker run --rm --network $WP_NET -v $DIR/html:/var/www/html \\
    --env-file $DIR/.env wordpress:cli wp <command>
\`\`\`

## E-commerce (WooCommerce)
No separate infrastructure needed — WooCommerce is a normal WordPress
plugin. Install it from Plugins → Add New in the WP admin, or via wp-cli:
\`\`\`bash
docker run --rm --network $WP_NET -v $DIR/html:/var/www/html \\
    --env-file $DIR/.env wordpress:cli wp plugin install woocommerce --activate
\`\`\`
The PHP limits above (256M memory, 64M uploads) were already sized with
WooCommerce's own recommendations in mind, so product/image imports work
without hitting default-image limits on the first try.

## Backup
\`services/backup.sh\` (Kopia) already covers this directory automatically —
it stops \`docker compose down\`, snapshots \`$DIR\`, and restarts, generically
for every \`~/docker/*\` directory with a \`docker-compose.yml\`, so both
\`html/\` and \`db/\` are captured together on every run with no per-site setup
needed. For an ad hoc logical dump instead:
\`\`\`bash
docker exec $DB_CONTAINER mysqldump -uroot -p"\$(grep MYSQL_ROOT_PASSWORD .env | cut -d= -f2-)" $WP_DB_NAME > backup.sql
\`\`\`
MD

    local START_WP=""
    prompt_yn "Start '$SITE_NAME' now? (y/n):" "y" START_WP
    if [[ "$START_WP" =~ ^[Yy]$ ]]; then
        if docker compose up -d; then
            log_success "'$SITE_NAME' started"

            log_info "Waiting for WordPress to come up, then running wp-cli core install..."
            local _tries=0
            until docker exec "$CONTAINER" curl -fs -o /dev/null http://localhost/ 2>/dev/null || [ "$_tries" -ge 30 ]; do
                sleep 1; _tries=$((_tries + 1))
            done

            if docker run --rm --network "$WP_NET" \
                -v "$DIR/html:/var/www/html" \
                -e WORDPRESS_DB_HOST="$DB_CONTAINER" \
                -e WORDPRESS_DB_NAME="$WP_DB_NAME" \
                -e WORDPRESS_DB_USER="$WP_DB_USER" \
                -e WORDPRESS_DB_PASSWORD="$WP_DB_PASS" \
                wordpress:cli \
                core install \
                    --url="http://localhost:${WEB_PORT}" \
                    --title="$WP_SITE_TITLE" \
                    --admin_user="$WP_ADMIN_USER" \
                    --admin_password="$WP_ADMIN_PASS" \
                    --admin_email="$WP_ADMIN_EMAIL" \
                    --skip-email &>/dev/null; then
                log_success "WordPress installed — no browser setup wizard needed"
            else
                log_warning "wp-cli install didn't complete (WordPress may not have been ready yet, or was"
                log_warning "already installed). Finish setup in the browser, or retry manually:"
                log_warning "  docker run --rm --network $WP_NET -v $DIR/html:/var/www/html \\"
                log_warning "    -e WORDPRESS_DB_HOST=$DB_CONTAINER -e WORDPRESS_DB_NAME=$WP_DB_NAME \\"
                log_warning "    -e WORDPRESS_DB_USER=$WP_DB_USER -e WORDPRESS_DB_PASSWORD=$WP_DB_PASS \\"
                log_warning "    wordpress:cli core install --url=http://localhost:${WEB_PORT} \\"
                log_warning "    --title=\"$WP_SITE_TITLE\" --admin_user=$WP_ADMIN_USER \\"
                log_warning "    --admin_password=<password> --admin_email=$WP_ADMIN_EMAIL"
            fi
        else
            log_warning "Failed to start — check: docker compose logs"
        fi
    fi

    echo ""
    echo "  Access at:    http://localhost:${WEB_PORT}"
    echo "  Admin user:   $WP_ADMIN_USER"
    echo "  Admin pass:   $WP_ADMIN_PASS"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wordpress
