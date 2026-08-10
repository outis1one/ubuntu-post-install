#!/bin/bash
# services/unifi.sh — UniFi Network Application (Ubiquiti controller).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash unifi.sh
# (Docker must already be installed when run standalone)
#
# Two containers: mongo:4 (DB) + linuxserver unifi-network-application (app).
# Web UI runs on HTTPS port 8443 — no plain HTTP web interface.
# Caddy reverse-proxy wiring uses TLS passthrough or tls_insecure_skip_verify.

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
            echo
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service unifi utilities "Ubiquiti network controller (UniFi)" 8443

install_unifi() {
    require_docker || return 1
    log_info "Installing UniFi Network Application..."

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "unifi-db"/"unifi-app" names/paths/ports
    # exactly as before (zero behavior change for anyone with a single
    # instance). Only asking to add a second one introduces suffixed naming —
    # same pattern as services/mattermost.sh and services/wordpress.sh.
    # Each instance gets its own dedicated MongoDB container (not shared) —
    # see CLAUDE.md's "Multi-instance services" section for why: Kopia's
    # generic backup stops the container to snapshot it, so a shared DB would
    # back up/restore every instance's site data as one unit instead of
    # per-instance. All 4 published ports move together per instance.
    local UNIFI_DIR="$DOCKER_DIR/unifi"
    local INSTANCE_SUFFIX="" PROJECT="unifi" DB_CONTAINER="unifi-db" APP_CONTAINER="unifi-app"
    local WEB_PORT="8443" INFORM_PORT="8080" STUN_PORT="3478" DISCOVERY_PORT="10001"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would offer to add a new, separate instance if one already exists"
        echo "[DRY-RUN] Would create \$DOCKER_DIR/unifi(-<name>) (mongo_db_data/, unifi_data/)"
        echo "[DRY-RUN] Would deploy mongo:4 + linuxserver/unifi-network-application:latest"
        echo "[DRY-RUN] Ports: 8443 (HTTPS web UI), 8080 (device inform), 3478/udp (STUN), 10001/udp (discovery)"
        echo "[DRY-RUN]   — all 4 auto-scanned/shifted together for additional instances"
        echo "[DRY-RUN] Would generate MongoDB credentials"
        return 0
    fi

    if [ -d "$UNIFI_DIR" ]; then
        echo ""
        echo "  UniFi is already installed at $UNIFI_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate UniFi controller instance alongside it (its own"
        echo "       database, sites, and ports — full isolation)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'guest-site'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/unifi-$_suffix" ]; then
                    log_warning "unifi-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            UNIFI_DIR="$DOCKER_DIR/unifi-$_suffix"
            PROJECT="unifi-$_suffix"
            DB_CONTAINER="unifi-db-$_suffix"
            APP_CONTAINER="unifi-app-$_suffix"
            log_info "New instance: $UNIFI_DIR"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$UNIFI_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the UniFi image only — existing config, port, and Caddy setup are left as-is."
                        ( cd "$UNIFI_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "UniFi image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $UNIFI_DIR/docker-compose.yml logs"
                        return 0
                        ;;
                    cancel)
                        log_info "Leaving the existing install as-is."
                        return 0
                        ;;
                    fresh) ;;  # fall through to the full install flow below
                esac
            fi
        fi
    fi

    # Scan for free ports unconditionally, moving all 4 together — not just
    # when adding an explicit additional instance. A plain first install can
    # just as easily collide with an unrelated service that already claimed
    # one of these default ports — see CLAUDE.md's "Port collision
    # avoidance" section.
    while port_in_use "$WEB_PORT" || port_in_use "$INFORM_PORT" \
       || port_in_use "$STUN_PORT" udp || port_in_use "$DISCOVERY_PORT" udp; do
        WEB_PORT=$((WEB_PORT + 1))
        INFORM_PORT=$((INFORM_PORT + 1))
        STUN_PORT=$((STUN_PORT + 1))
        DISCOVERY_PORT=$((DISCOVERY_PORT + 1))
    done

    mkdir -p "$UNIFI_DIR"
    ensure_docker_dir_ownership "$UNIFI_DIR"
    cd "$UNIFI_DIR" || return 1

    local MONGO_PASS TZ_VAL UID_VAL GID_VAL
    MONGO_PASS=$(generate_password 24)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER")
    GID_VAL=$(id -g "$ACTUAL_USER")

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

    # Unquoted heredoc; ${...} used for caddy_net vars; all Docker Compose vars escaped with \$
    cat > docker-compose.yml << UNIFI_COMPOSE
name: $PROJECT

services:
  unifi-db:
    image: mongo:4
    container_name: $DB_CONTAINER
    hostname: $DB_CONTAINER
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./mongo_db_data:/data/db
    expose:
      - "27017"
    configs:
      - source: init-mongo.js
        target: /docker-entrypoint-initdb.d/init-mongo.js

  unifi-app:
    image: lscr.io/linuxserver/unifi-network-application:latest
    container_name: $APP_CONTAINER
    hostname: $APP_CONTAINER
    restart: unless-stopped
    env_file: .env
    depends_on:
      - unifi-db
    volumes:
      - ./unifi_data:/config
    ports:
      - "${WEB_PORT}:8443"
      - "${INFORM_PORT}:8080"
      - "${STUN_PORT}:3478/udp"
      - "${DISCOVERY_PORT}:10001/udp"
      # Optional — uncomment as needed:
      # - "1900:1900/udp"   # L2 discovery (may conflict with UPnP)
      # - "8843:8843"       # guest portal HTTPS
      # - "8880:8880"       # guest portal HTTP
      # - "6789:6789"       # mobile speed test
      # - "5514:5514/udp"   # remote syslog
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
# Inline MongoDB init — Docker Compose interpolates vars from .env at startup.
configs:
  init-mongo.js:
    content: |
      db.getSiblingDB("\${MONGO_DBNAME}").createUser({user: "\${MONGO_USER}", pwd: "\${MONGO_PASS}", roles: [{role: "\${MONGO_ROLE}", db: "\${MONGO_DBNAME}"}]});
      db.getSiblingDB("\${MONGO_DBNAME}_stat").createUser({user: "\${MONGO_USER}", pwd: "\${MONGO_PASS}", roles: [{role: "\${MONGO_ROLE}", db: "\${MONGO_DBNAME}_stat"}]});
UNIFI_COMPOSE

    cat > .env << UNIFI_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── LinuxServer — UniFi app ───────────────────────────────────────────────────
PUID=$UID_VAL
PGID=$GID_VAL
MEM_LIMIT=1024
MEM_STARTUP=512

# ── MongoDB connection ────────────────────────────────────────────────────────
MONGO_USER=unifi
MONGO_PASS=$MONGO_PASS
MONGO_HOST=unifi-db
MONGO_PORT=27017
MONGO_DBNAME=unifi_db
MONGO_ROLE=dbOwner
# MONGO_TLS=        # optional
# MONGO_AUTHSOURCE= # optional
UNIFI_ENV

    chmod 600 .env
    mkdir -p mongo_db_data unifi_data
    ensure_docker_dir_ownership "$UNIFI_DIR"

    log_success "UniFi${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $UNIFI_DIR (web port $WEB_PORT)"

    # ── Optional Caddy reverse proxy (HTTPS backend requires tls_insecure_skip_verify) ──
    local _caddy_mode="none"
    [ -d "$DOCKER_DIR/caddy" ] && _caddy_mode="local"
    [ -n "${CADDY_REMOTE_HOST:-}" ] && [ "$_caddy_mode" != "local" ] && _caddy_mode="remote"

    if [ "$_caddy_mode" != "none" ]; then
        echo ""
        echo "  UniFi web UI is HTTPS-only (self-signed cert internally)."
        echo "  Caddy proxies it using tls_insecure_skip_verify."
        if [ "$_caddy_mode" = "remote" ]; then
            echo "  Remote Caddy (${CADDY_REMOTE_HOST}) — a snippet file will be saved."
        fi
        echo ""
        local CADDY_UNIFI=""
        prompt_yn "Configure Caddy reverse proxy for UniFi${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}? (y/n):" "n" CADDY_UNIFI
        if [ "$CADDY_UNIFI" = "y" ] || [ "$CADDY_UNIFI" = "Y" ]; then
            local UNIFI_DOMAIN=""
            local _def_domain="unifi${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}.${SITE_DOMAIN:-example.com}"
            prompt_text "UniFi domain [${_def_domain}]:" "$_def_domain" UNIFI_DOMAIN
            if [ -n "$UNIFI_DOMAIN" ]; then
                # UniFi uses HTTPS internally — upstream must use https:// + skip verify.
                # Local mode reaches the container over Docker networking (internal port
                # never changes); remote mode reaches this host's published port, which
                # is WEB_PORT (auto-scanned for additional instances).
                local _upstream="https://${APP_CONTAINER}:8443"
                [ "$_caddy_mode" = "remote" ] && _upstream="https://${CADDY_REMOTE_HOST}:${WEB_PORT}"

                local _site_block
                _site_block="$(cat << CBLOCK

# UniFi Network Application
${UNIFI_DOMAIN} {
    reverse_proxy ${_upstream} {
        transport http {
            tls_insecure_skip_verify
        }
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${UNIFI_DOMAIN}.log
        format json
    }
}
CBLOCK
)"
                if [ "$_caddy_mode" = "local" ]; then
                    local CADDYFILE="$DOCKER_DIR/caddy/Caddyfile"
                    cp "$CADDYFILE" "$CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
                    printf '%s\n' "$_site_block" >> "$CADDYFILE"
                    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                    docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
                        && log_success "Caddy configured for $UNIFI_DOMAIN" \
                        || log_warning "Caddy reload failed — check: docker logs caddy"
                else
                    local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                    local _snippet_file="$_snippet_dir/unifi${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}.caddy"
                    mkdir -p "$_snippet_dir"
                    printf '%s\n' "$_site_block" > "$_snippet_file"
                    chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                    log_success "Snippet saved: $_snippet_file"
                    log_info "Copy to Caddy machine:"
                    log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                fi
            fi
        fi
    fi

    write_readme "$UNIFI_DIR" << MD
# UniFi Network Application${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Ubiquiti network controller. Manages UniFi APs, switches, and gateways.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own dedicated database, own
sites/devices, own ports) — not shared adoption with another UniFi instance.
Devices can only be adopted by one controller at a time.")

## Access
- Web UI: **https://localhost:${WEB_PORT}** (HTTPS, self-signed cert — accept the warning)
- First run: complete the setup wizard and adopt your devices.

## Device adoption
Make sure devices can reach **http://<server-ip>:${INFORM_PORT}/inform** as the inform URL.
In the controller: Settings → System → Application Configuration → Override inform host.

## Ports
| Port | Protocol | Purpose |
|------|----------|---------|
| ${WEB_PORT} | TCP | HTTPS web UI |
| ${INFORM_PORT} | TCP | Device inform / HTTP redirect |
| ${STUN_PORT} | UDP | STUN |
| ${DISCOVERY_PORT} | UDP | AP discovery |

## Manage
\`\`\`bash
cd $UNIFI_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update (wait for DB first)
\`\`\`

## Migration from old UniFi Controller
1. Backup: Settings → System → Backup → Create Backup
2. Down the old container
3. Spin up this stack
4. Restore: Settings → System → Backup → Restore
MD

    local START_UNIFI=""
    prompt_yn "Start UniFi${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_UNIFI
    if [ "$START_UNIFI" = "y" ] || [ "$START_UNIFI" = "Y" ]; then
        docker compose up -d \
            && log_success "UniFi${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started (first startup takes ~60 s while DB initializes)" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Web UI:  https://localhost:${WEB_PORT}  (accept the self-signed cert warning)"
    echo "  MongoDB credentials saved to: $UNIFI_DIR/.env"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_unifi
