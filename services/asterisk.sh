#!/bin/bash
# services/asterisk.sh — Easy Asterisk PBX + coturn TURN server (home intercom/VoIP).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash asterisk.sh
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

register_service asterisk homelab "Easy Asterisk PBX + coturn TURN server (home intercom/VoIP)" 5061

install_asterisk() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn..."

    local EA_DIR="$DOCKER_DIR/asterisk"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, 8080, 8088, 8089, 3478, 10000-20000, 49152-49252"
        return 0
    fi

    mkdir -p "$EA_DIR"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    mkdir -p docker

    # ── Vendor files ──────────────────────────────────────────────────────────
    local _SELF_DIR_LOCAL
    _SELF_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local VENDOR_DIR="$_SELF_DIR_LOCAL/../vendor/easy-asterisk"

    if [[ -d "$VENDOR_DIR" ]]; then
        log_info "Copying vendor files from $VENDOR_DIR ..."
        cp "$VENDOR_DIR/Dockerfile"                    ./Dockerfile
        cp "$VENDOR_DIR/docker/entrypoint.sh"          ./docker/entrypoint.sh
        cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"   ./docker/coturn-entrypoint.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk-v0.10.0.sh
    else
        log_info "Vendor directory not found — downloading from GitHub ..."
        local GH_RAW="https://raw.githubusercontent.com/DeadDork/easy-asterisk/main"
        curl -fsSL "$GH_RAW/Dockerfile"                        -o ./Dockerfile
        curl -fsSL "$GH_RAW/docker/entrypoint.sh"              -o ./docker/entrypoint.sh
        curl -fsSL "$GH_RAW/docker/coturn-entrypoint.sh"       -o ./docker/coturn-entrypoint.sh
        curl -fsSL "$GH_RAW/easy-asterisk-v0.10.0.sh"          -o ./easy-asterisk.sh
        cp ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh
    fi

    chmod 755 ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh \
              ./docker/entrypoint.sh ./docker/coturn-entrypoint.sh

    # ── Networking mode ───────────────────────────────────────────────────────
    echo ""
    echo "  Networking mode:"
    echo "    1) LAN-only  — no domain, self-signed cert, works on local network/VPN only"
    echo "    2) FQDN      — TLS + TURN relay, works from anywhere (requires public domain)"
    local HA_NETMODE=""
    prompt_text "Choose [1]:" "1" HA_NETMODE

    local DOMAIN_NAME=""
    if [[ "$HA_NETMODE" == "2" ]]; then
        prompt_text "FQDN (e.g. asterisk.${SITE_DOMAIN:-example.com}) [blank=skip]:" "" DOMAIN_NAME
    fi

    # ── Secrets ───────────────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(generate_password 24)"

    local TURN_SERVER_VAL=""
    [[ -n "$DOMAIN_NAME" ]] && TURN_SERVER_VAL="${DOMAIN_NAME}:3478"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > docker-compose.yml << 'EOF'
name: asterisk

services:
  asterisk:
    build: .
    container_name: easy-asterisk
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - asterisk-config:/etc/asterisk
      - easy-asterisk-config:/etc/easy-asterisk
      - asterisk-logs:/var/log/asterisk
      - asterisk-spool:/var/spool/asterisk
      - asterisk-lib:/var/lib/asterisk
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    env_file: .env
    command:
      - -n
      - --listening-port=${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=${TURN_USERNAME:-easyasterisk}:${TURN_PASSWORD}
      - --realm=${DOMAIN_NAME:-localhost}
      - --min-port=49152
      - --max-port=49252
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

volumes:
  asterisk-config:
  easy-asterisk-config:
  asterisk-logs:
  asterisk-spool:
  asterisk-lib:
EOF

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# Set to your FQDN for remote access. Leave empty for LAN-only.
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
TURN_USERNAME=easyasterisk
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=3478
# For LAN-only: TURN_SERVER is empty. For FQDN: set to domain:3478
TURN_SERVER=${TURN_SERVER_VAL}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── Web admin ─────────────────────────────────────────────────
WEB_ADMIN_PORT=8080
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── UFW firewall rules ────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        ufw allow 8080/tcp
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow 10000:20000/udp
        ufw allow 49152:49252/udp
        log_success "UFW rules added."
    fi

    # ── Caddy reverse proxy for web admin ─────────────────────────────────────
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
        if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
            EXTRA_BLOCK="    import authelia"
            # Disable built-in auth since Authelia handles it
            sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
        fi
    fi
    configure_caddy_for_service "Asterisk Web Admin" "8080" "asterisk" "$EXTRA_BLOCK"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << 'MD'
# Easy Asterisk PBX + coturn

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal. Suitable for home intercom, VoIP handsets, and softphones.

## Manage

```bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
```

## Management script

```bash
docker exec -it easy-asterisk easy-asterisk --help
```

## SIP client setup

| Setting         | Value                                |
|-----------------|--------------------------------------|
| SIP server      | <host-ip> (LAN) or your FQDN (FQDN) |
| SIP port        | 5061 (TLS) / 5060 (UDP)             |
| TURN server     | <DOMAIN_NAME>:3478 (FQDN mode only) |
| TURN username   | easyasterisk                         |
| TURN password   | see .env → TURN_PASSWORD             |

Recommended softphones: Linphone, Zoiper, Bria, Grandstream Wave.

## Web admin

Access the Easy Asterisk web interface at http://<host-ip>:8080
or via your configured reverse-proxy domain.

## Volumes

| Volume               | Contents                       |
|----------------------|-------------------------------|
| asterisk-config      | /etc/asterisk — dialplan, SIP  |
| easy-asterisk-config | /etc/easy-asterisk — web config|
| asterisk-logs        | /var/log/asterisk              |
| asterisk-spool       | /var/spool/asterisk            |
| asterisk-lib         | /var/lib/asterisk              |

## Ports

| Port          | Protocol | Purpose                          |
|---------------|----------|----------------------------------|
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| 8080          | TCP      | Easy Asterisk web admin          |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| 49152–49252   | UDP      | TURN relay media ports           |
MD

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Easy Asterisk installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    else
        echo "  Mode:        LAN-only"
        echo "  TURN server: (none — LAN/VPN only)"
    fi
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):8080"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it easy-asterisk easy-asterisk --help"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk
