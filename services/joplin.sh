#!/bin/bash
# services/joplin.sh — Self-hosted Joplin sync server for notes.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash joplin.sh
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service joplin utilities "Self-hosted Joplin sync server for notes" 22300

install_joplin() {
    require_docker || return 1
    log_info "Installing Joplin Server..."

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "joplin"/"joplin-db" names/paths/port
    # exactly as before (zero behavior change for anyone with a single
    # instance). Only asking to add a second one introduces suffixed naming —
    # same pattern as services/mattermost.sh and services/wordpress.sh.
    # Each instance gets its own dedicated Postgres container (not shared) —
    # see CLAUDE.md's "Multi-instance services" section for why: Kopia's
    # generic backup stops the container to snapshot it, so a shared DB would
    # back up/restore every instance's notes as one unit instead of per-instance.
    local JOPLIN_DIR="$DOCKER_DIR/joplin"
    local INSTANCE_SUFFIX="" CONTAINER="joplin" DB_CONTAINER="joplin-db"
    local WEB_PORT="22300"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would offer to add a new, separate instance if one already exists"
        echo "[DRY-RUN] Would create \$DOCKER_DIR/joplin(-<name>)"
        echo "[DRY-RUN] Would write docker-compose.yml and .env (dedicated Postgres per instance)"
        echo "[DRY-RUN] Would auto-scan for a free host port if this is an additional instance"
        return 0
    fi

    if [ -d "$JOPLIN_DIR" ]; then
        echo ""
        echo "  Joplin Server is already installed at $JOPLIN_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Joplin Server instance alongside it (its own"
        echo "       server, database, and port — full isolation)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'work'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/joplin-$_suffix" ]; then
                    log_warning "joplin-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            JOPLIN_DIR="$DOCKER_DIR/joplin-$_suffix"
            CONTAINER="joplin-$_suffix"
            DB_CONTAINER="joplin-db-$_suffix"
            log_info "New instance: $JOPLIN_DIR"
        fi
    fi

    # Scan for a free port unconditionally — not just when adding an explicit
    # additional instance. A plain first install can just as easily collide
    # with an unrelated service that already claimed this default port — see
    # CLAUDE.md's "Port collision avoidance" section.
    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$JOPLIN_DIR"
    ensure_docker_dir_ownership "$JOPLIN_DIR"
    cd "$JOPLIN_DIR" || return 1

    # Reused across reruns if already set — the Postgres volume keeps the
    # password from its first init, so a fresh random one on every rerun
    # would lock Joplin out of its own database.
    local DB_PASS=""
    [ -f ".env" ] && DB_PASS="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
    [ -n "$DB_PASS" ] || DB_PASS="$(generate_password 32)"
    local BASE_URL="https://joplin${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}.${SITE_DOMAIN}"

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_BLOCK=""
    local _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    cat > docker-compose.yml << JOPLIN_COMPOSE
name: $CONTAINER

services:
  joplin:
    image: joplin/server:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    depends_on:
      - joplin-db
    env_file: .env
    ports:
      - "${WEB_PORT}:22300"
${_CADDY_NET_BLOCK}
  joplin-db:
    image: postgres:15-alpine
    container_name: $DB_CONTAINER
    hostname: $DB_CONTAINER
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db-data:/var/lib/postgresql/data
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
JOPLIN_COMPOSE

    cat > .env << JOPLIN_ENV
# Joplin Server configuration
APP_PORT=22300
# Must match the public URL — update if your domain changes
APP_BASE_URL=${BASE_URL}

# Database connection (Joplin Server)
DB_CLIENT=pg
POSTGRES_HOST=joplin-db
POSTGRES_DATABASE=joplin
POSTGRES_USER=joplin
POSTGRES_PASSWORD=${DB_PASS}

# PostgreSQL sidecar
POSTGRES_DB=joplin

# Caddy network
CADDY_NET=${SITE_CADDY_NET}
JOPLIN_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JOPLIN_DIR"

    echo ""
    log_success "Joplin Server${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $JOPLIN_DIR (port $WEB_PORT)"
    log_info "APP_BASE_URL set to: $BASE_URL"
    log_warning "APP_BASE_URL in .env must match the public URL used by Joplin clients."

    configure_caddy_for_service "Joplin${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:22300" "joplin${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    write_readme "$JOPLIN_DIR" << MD
# Joplin Server${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Self-hosted sync server for the Joplin note-taking app.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own dedicated
database, own port) — not shared notes with another Joplin instance.")

## Access
- URL: http://localhost:${WEB_PORT}
- Default admin: admin@localhost / admin (change immediately after first login!)

## Important
\`APP_BASE_URL\` in \`.env\` must exactly match the public URL your Joplin
clients connect to (e.g. https://joplin.example.com). If this URL changes,
update .env and restart the stack.

## Client setup
In the Joplin desktop or mobile app:
  Tools → Options → Synchronisation → Synchronisation target: Joplin Server
  Enter your server URL, email, and password.

## Manage
\`\`\`bash
cd $JOPLIN_DIR
docker compose up -d                                        # start
docker compose down                                         # stop
docker compose logs -f                                      # logs
docker compose pull && docker compose down && docker compose up -d  # update
\`\`\`

## Files
- docker-compose.yml — stack definition
- .env             — secrets and config (chmod 600)
- db-data/         — PostgreSQL data volume
MD

    local START_JOPLIN=""
    prompt_yn "Start Joplin Server${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_JOPLIN
    if [ "$START_JOPLIN" = "y" ] || [ "$START_JOPLIN" = "Y" ]; then
        docker compose up -d 2>/dev/null \
            && log_success "Joplin Server${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo "  Default login: admin@localhost / admin (change immediately!)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_joplin
