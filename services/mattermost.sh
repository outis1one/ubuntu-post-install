#!/bin/bash
# services/mattermost.sh — Team messaging with voice/video calls (Mattermost + coturn).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash mattermost.sh
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

            # Remote Caddy support: if CADDY_REMOTE_HOST is set, operate on the
            # remote machine via SSH instead of the local filesystem.
            if [[ -n "${CADDY_REMOTE_HOST:-}" ]]; then
                echo ""
                local _do_caddy=""
                read -r -p "  Configure Caddy reverse proxy for $_name on $CADDY_REMOTE_HOST? [y/N]: " _do_caddy
                [[ "${_do_caddy,,}" == "y" ]] || {
                    log_info "Skipping — access at: http://$(hostname -I | awk '{print $1}'):${_upstream##*:}"
                    return 0
                }

                local _domain=""
                read -r -p "  Domain (e.g. ${_subdomain}.${SITE_DOMAIN:-example.com}): " _domain
                [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

                local _block
                _block="$(cat << CBLOCK

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
)"
                echo "$_block" | ssh "$CADDY_REMOTE_HOST" "cat >> $_caddyfile"
                ssh "$CADDY_REMOTE_HOST" "docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true"
                if ssh "$CADDY_REMOTE_HOST" "docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null"; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: ssh $CADDY_REMOTE_HOST docker logs caddy"
                fi
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

        write_readme() {
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service mattermost utilities "Team messaging with voice/video calls (Mattermost + coturn)" 8065

install_mattermost() {
    require_docker || return 1
    log_info "Installing Mattermost + coturn..."

    local DIR="$DOCKER_DIR/mattermost"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml"
        echo "[DRY-RUN] Would write .env with DB and Mattermost secrets"
        echo "[DRY-RUN] Would create data/ logs/ config/ plugins/ db/ subdirectories"
        echo "[DRY-RUN] Would open UFW ports 8443/udp, 3479, 49153:49352/udp"
        return 0
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local DB_PASS
    local MM_SECRET
    DB_PASS=$(generate_password 32)
    MM_SECRET=$(generate_password 48)

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    local UID_VAL GID_VAL
    UID_VAL=$(id -u "$ACTUAL_USER")
    GID_VAL=$(id -g "$ACTUAL_USER")

    # Compute SITE_URL
    local SITE_URL="http://localhost:8065"
    if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        SITE_URL="https://mattermost.${SITE_DOMAIN}"
    fi
    local CONFIGURED_SITEURL=""
    prompt_text "Mattermost site URL [$SITE_URL]:" "$SITE_URL" CONFIGURED_SITEURL
    [[ -n "$CONFIGURED_SITEURL" ]] && SITE_URL="$CONFIGURED_SITEURL"

    cat > docker-compose.yml << 'EOF'
name: mattermost

services:
  db:
    image: postgres:15-alpine
    container_name: mattermost-db
    hostname: mattermost-db
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db:/var/lib/postgresql/data
    networks:
      - caddy_net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost
    hostname: mattermost
    restart: unless-stopped
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    volumes:
      - ./data:/mattermost/data
      - ./logs:/mattermost/logs
      - ./config:/mattermost/config
      - ./plugins:/mattermost/plugins
    ports:
      - "8065:8065"
      - "8443:8443/udp"
    networks:
      - caddy_net

  coturn:
    image: coturn/coturn:latest
    container_name: mattermost-coturn
    network_mode: host
    user: root
    command:
      - -n
      - --listening-port=3479
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --use-auth-secret
      - --static-auth-secret=${COTURN_SECRET}
      - --realm=${MM_REALM:-localhost}
      - --min-port=49153
      - --max-port=49352
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
EOF

    cat > .env << EOF
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# PostgreSQL
POSTGRES_DB=mattermost
POSTGRES_USER=mattermost
POSTGRES_PASSWORD=$DB_PASS

# Mattermost
MM_SQLSETTINGS_DRIVERNAME=postgres
MM_SQLSETTINGS_DATASOURCE=postgres://mattermost:${DB_PASS}@mattermost-db:5432/mattermost?sslmode=disable&connect_timeout=10
MM_SERVICESETTINGS_SITEURL=$SITE_URL
MM_SERVICESETTINGS_ENABLELOCALMODE=true
MM_FILESETTINGS_DRIVERNAME=local
MM_PLUGINSETTINGS_ENABLE=true

# coturn HMAC secret for Mattermost Calls plugin
COTURN_SECRET=$MM_SECRET
MM_REALM=${SITE_DOMAIN:-localhost}

# PUID/PGID for file ownership
PUID=$UID_VAL
PGID=$GID_VAL
EOF
    chmod 600 .env

    mkdir -p data logs config plugins db
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    # Open required firewall ports
    if command -v ufw &>/dev/null; then
        ufw allow 8443/udp comment "Mattermost Calls RTC"
        ufw allow 3479/udp; ufw allow 3479/tcp
        ufw allow 49153:49352/udp comment "Mattermost coturn relay"
    fi

    echo ""
    log_success "Mattermost configured at $DIR"

    configure_caddy_for_service "Mattermost" "mattermost:8065" "mattermost"

    write_readme "$DIR" << MD
# Mattermost

Team messaging with voice/video calls. PostgreSQL backend + coturn TURN relay.

## Access
- URL: $SITE_URL (or http://localhost:8065)
- First run: create admin account at the URL above

## Voice/Video Calls (Calls plugin)
Port 8443/udp must be open on your router/firewall.
coturn relay runs on port 3479 (HMAC secret in .env).

Configure in Mattermost: System Console → Plugins → Calls:
- TURN Server URI: turn:YOUR_DOMAIN_OR_IP:3479?transport=udp
- TURN Credentials: use static-auth-secret (see .env COTURN_SECRET)

## Manage
\`\`\`bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
\`\`\`
MD

    if [[ "$SITE_URL" == http://* ]]; then
        log_warning "WebRTC (voice/video calls) requires HTTPS. Configure Caddy and update SITE_URL."
    fi

    local START=""
    prompt_yn "Start Mattermost now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "Mattermost started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  $SITE_URL"
    echo "  First run:  open the URL above and create your admin account."
    echo "  Calls plugin: System Console → Plugins → Calls to configure coturn."
    echo "    TURN URI:    turn:${SITE_DOMAIN:-YOUR_IP}:3479?transport=udp"
    echo "    Auth secret: see COTURN_SECRET in $DIR/.env"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mattermost
