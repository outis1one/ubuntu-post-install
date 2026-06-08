#!/bin/bash
# services/mattermost.sh — Team messaging with voice/video calls (Mattermost + coturn).
# Part of the modular post-install system (sourced by setup.sh).
#
# Mattermost Team Edition with PostgreSQL and a dedicated coturn TURN server
# (port 3479 — distinct from Easy Asterisk's coturn on 3478).
#
# Can also be run standalone on any machine:
#   sudo bash mattermost.sh
# (Docker must already be installed when run standalone)

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$_len"
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

register_service mattermost utilities "Team messaging with voice/video calls (Mattermost + coturn)" 8065

install_mattermost() {
    require_docker || return 1
    log_info "Installing Mattermost Team Edition..."

    local DIR="$DOCKER_DIR/mattermost"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with subdirectories: data logs config plugins db"
        echo "[DRY-RUN] Would generate DB password, MM secret key, and TURN secret"
        echo "[DRY-RUN] Would write docker-compose.yml and .env"
        echo "[DRY-RUN] Would open UFW ports: 3479/udp+tcp, 49153-49352/udp"
        echo "[DRY-RUN] Would configure Caddy reverse proxy for Mattermost"
        return 0
    fi

    # ── Create directory structure ────────────────────────────────────────────
    mkdir -p "$DIR"/{data,logs,config,plugins,db}
    # Mattermost runs as UID 2000 inside the container
    chown -R 2000:2000 "$DIR/data" "$DIR/logs" "$DIR/config" "$DIR/plugins"
    ensure_docker_dir_ownership "$DIR/db"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # ── Generate secrets ──────────────────────────────────────────────────────
    local DB_PASS MM_SECRET TURN_SECRET
    DB_PASS="$(generate_password 32)"
    MM_SECRET="$(generate_password 48)"
    TURN_SECRET="$(openssl rand -hex 32 2>/dev/null || generate_password 32)"

    # ── Site URL ──────────────────────────────────────────────────────────────
    local SITE_URL="http://localhost:8065"
    if [[ -n "$SITE_DOMAIN" && "$SITE_DOMAIN" != "example.com" ]]; then
        SITE_URL="https://chat.${SITE_DOMAIN}"
    fi
    local CONFIGURED_SITEURL=""
    prompt_text "Mattermost site URL [${SITE_URL}]:" "$SITE_URL" CONFIGURED_SITEURL
    [[ -n "$CONFIGURED_SITEURL" ]] && SITE_URL="$CONFIGURED_SITEURL"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > docker-compose.yml << COMPOSE
# Mattermost Team Edition — generated by ubuntu-post-install
# Manage: docker compose up -d / down / logs -f
# Admin setup: \${MATTERMOST_SITE_URL}/signup_user_complete

name: mattermost

services:

  db:
    image: postgres:15-alpine
    container_name: mattermost-db
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 100
    volumes:
      - ./db:/var/lib/postgresql/data
    environment:
      - POSTGRES_USER=mattermost
      - POSTGRES_PASSWORD=\${DB_PASS}
      - POSTGRES_DB=mattermost
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mattermost"]
      interval: 10s
      timeout: 5s
      retries: 5

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: mattermost
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    pids_limit: 200
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8065:8065"
      - "8443:8443/udp"   # Calls plugin RTC server (WebRTC direct path)
    volumes:
      - ./data:/mattermost/data
      - ./logs:/mattermost/logs
      - ./config:/mattermost/config
      - ./plugins:/mattermost/plugins
    environment:
      - MM_SQLSETTINGS_DRIVERNAME=postgres
      - MM_SQLSETTINGS_DATASOURCE=postgres://mattermost:\${DB_PASS}@db:5432/mattermost?sslmode=disable
      - MM_SERVICESETTINGS_SITEURL=\${MATTERMOST_SITE_URL}
      - MM_PLUGINSETTINGS_ENABLEUPLOADS=true
      - MM_SERVICESETTINGS_ENABLELOCALMODE=true
      - TZ=\${TZ}
    networks:
      - default
      - caddy_net

  coturn:
    image: coturn/coturn:latest
    container_name: mattermost-coturn
    restart: unless-stopped
    network_mode: host
    command:
      - -n
      - --listening-port=3479
      - --tls-listening-port=5350
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --use-auth-secret
      - --static-auth-secret=\${TURN_SECRET}
      - --realm=\${TURN_REALM}
      - --min-port=49153
      - --max-port=49352
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout

networks:
  default:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
COMPOSE

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# Mattermost — environment configuration
# Edit and restart: docker compose down && docker compose up -d

# PostgreSQL password (do not change after first start without migrating data)
DB_PASS=$DB_PASS

# Mattermost secret key (used for signing session tokens)
MM_SECRET=$MM_SECRET

# Site URL — must match the public URL clients use to access Mattermost
MATTERMOST_SITE_URL=$SITE_URL

# Timezone
TZ=$SITE_TZ

# TURN server shared secret for Mattermost Calls plugin
# Generate a new one: openssl rand -hex 32
TURN_SECRET=$TURN_SECRET

# TURN realm (typically your domain)
TURN_REALM=${SITE_DOMAIN:-localhost}

# Caddy network name
CADDY_NET=$SITE_CADDY_NET
ENV

    chmod 600 .env
    chown "$ACTUAL_USER:$ACTUAL_USER" .env

    # ── UFW firewall rules ─────────────────────────────────────────────────────
    echo ""
    log_info "Firewall — Mattermost coturn uses port 3479 (avoiding conflict with Easy Asterisk on 3478)."
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Opening UFW ports for Mattermost..."
        ufw allow 8443/udp  comment "Mattermost Calls RTC server"  >/dev/null
        ufw allow 3479/udp  comment "Mattermost coturn STUN/TURN"  >/dev/null
        ufw allow 3479/tcp  comment "Mattermost coturn STUN/TURN"  >/dev/null
        ufw allow 49153:49352/udp comment "Mattermost coturn relay" >/dev/null
        log_success "UFW rules added"
    else
        log_info "UFW not active — add these rules manually if needed:"
        echo "    ufw allow 8443/udp  # Mattermost Calls RTC"
        echo "    ufw allow 3479/udp && ufw allow 3479/tcp  # coturn STUN/TURN"
        echo "    ufw allow 49153:49352/udp  # coturn relay"
    fi

    # ── Router port-forward instructions ──────────────────────────────────────
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  Router port-forwards needed for Mattermost Calls (external)   │"
    echo "  ├──────────────────┬──────────┬──────────────────────────────────┤"
    echo "  │  Port(s)         │ Protocol │ Service                          │"
    echo "  ├──────────────────┼──────────┼──────────────────────────────────┤"
    echo "  │  8443            │ UDP      │ Calls plugin RTC (direct WebRTC) │"
    echo "  │  3479            │ UDP+TCP  │ coturn STUN/TURN                 │"
    echo "  │  49153–49352     │ UDP      │ coturn relay range               │"
    echo "  └──────────────────┴──────────┴──────────────────────────────────┘"
    echo ""
    echo "  ⚠  WebRTC (Calls) requires HTTPS. Calls will not work if Mattermost"
    echo "     is accessed over plain HTTP. Configure Caddy with a domain below."
    echo ""

    ensure_docker_dir_ownership "$DIR"

    # ── Caddy reverse proxy ───────────────────────────────────────────────────
    # Mattermost's SITEURL must match the public URL for WebRTC (Calls) to work.
    # If the user configures a Caddy domain here, update SITEURL in .env to match.
    if [ -d "$DOCKER_DIR/caddy" ]; then
        local _mm_domain=""
        prompt_text "Caddy domain for Mattermost (e.g. chat.${SITE_DOMAIN:-example.com}) [skip]:" "" _mm_domain
        if [[ -n "$_mm_domain" ]]; then
            # Update SITEURL before wiring Caddy so the running container gets the right value
            sed -i "s|^MATTERMOST_SITE_URL=.*|MATTERMOST_SITE_URL=https://$_mm_domain|" "$DIR/.env"
            log_info "SITEURL updated → https://$_mm_domain (WebRTC requires HTTPS)"
            # Write Caddyfile block directly (configure_caddy_for_service would prompt again)
            local _caddyfile="$DOCKER_DIR/caddy/Caddyfile"
            local _bk="$DOCKER_DIR/caddy/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
            [[ -f "$_caddyfile" ]] && cp "$_caddyfile" "$_bk" && log_info "Backed up Caddyfile"
            if grep -q "^${_mm_domain}" "$_caddyfile" 2>/dev/null; then
                log_warning "$_mm_domain already in Caddyfile — skipping block write"
            else
                cat >> "$_caddyfile" << MMCADDY

# Mattermost
$_mm_domain {
    reverse_proxy mattermost:8065

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_mm_domain}.log
        format json
    }
}
MMCADDY
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "Mattermost accessible at: https://$_mm_domain"
                else
                    log_warning "Caddy reload failed — check: docker logs caddy"
                fi
            fi
        fi
    fi

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$DIR" << MD
# Mattermost

Team messaging platform with voice/video calls via the Calls plugin and self-hosted coturn TURN server.

## Access
- Direct:  http://localhost:8065
- Via Caddy: see your configured domain (e.g. https://chat.${SITE_DOMAIN:-example.com})

## Initial admin setup
Visit: \`${SITE_URL}/signup_user_complete\`

The first user to sign up becomes the System Admin.

## Calls plugin (voice/video)
The Mattermost Calls plugin provides voice/video channels.
**WebRTC requires HTTPS** — calls will not work over plain HTTP.

### Enable the plugin
1. Go to **System Console → Plugins → Plugin Management**
2. Enable the **Calls** plugin (pre-installed in Team Edition)

### Configure ICE / TURN server
1. Go to **System Console → Plugins → Calls**
2. Set **RTC Server Address**: your server's public IP or domain
3. Set **TURN server URL**: \`turn:<your-server-or-ip>:3479\`
4. Set **TURN credentials type**: Static credentials (auth secret)
5. Set **TURN static auth secret**: (see \`TURN_SECRET\` in \`$DIR/.env\`)
6. Save and test a call in a channel

Direct WebRTC (port 8443/UDP) is tried first; coturn relay is the fallback
for clients behind strict NAT (cellular, hotel WiFi, Proton VPN, etc.).

## Router port-forwards (for external calls)
| Port(s)      | Protocol | Service                         |
|--------------|-----------|---------------------------------|
| 8443         | UDP       | Calls plugin RTC (direct path)  |
| 3479         | UDP+TCP   | coturn STUN/TURN                |
| 49153–49352  | UDP       | coturn relay range              |

## Manage
\`\`\`bash
cd $DIR
docker compose up -d                         # start
docker compose down                          # stop
docker compose logs -f                       # all logs
docker compose logs -f mattermost            # app logs only
docker compose logs -f coturn                # TURN server logs
docker compose pull && docker compose up -d  # update images
\`\`\`

## Backup
Important paths to back up:
- \`$DIR/data/\`    — uploaded files and attachments
- \`$DIR/config/\`  — server configuration
- \`$DIR/plugins/\` — installed plugins
- \`$DIR/db/\`      — PostgreSQL data directory
- \`$DIR/.env\`     — secrets and configuration

## Configuration
Main config file: \`$DIR/config/config.json\` (created on first start).
Environment variables in \`.env\` override config.json values.
After editing .env: \`docker compose down && docker compose up -d\`
MD

    # ── Start ──────────────────────────────────────────────────────────────────
    echo ""
    local START=""
    prompt_yn "Start Mattermost now? (y/n):" "y" START
    if [[ "$START" =~ ^[Yy]$ ]]; then
        log_info "Pulling images and starting Mattermost (first start may take a minute)..."
        if docker compose pull 2>&1 | tail -3 && docker compose up -d; then
            log_success "Mattermost started"
            echo ""
            echo "  App:         http://localhost:8065"
            echo "  Admin setup: ${SITE_URL}/signup_user_complete"
            echo ""
            log_info "Enable the Calls plugin and configure TURN at:"
            log_info "  System Console → Plugins → Calls"
            log_info "  TURN URL:    turn:<your-public-ip>:3479"
            log_info "  TURN secret: (see $DIR/.env → TURN_SECRET)"
        else
            log_warning "Start failed — check: docker compose logs"
        fi
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mattermost
