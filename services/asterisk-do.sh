#!/bin/bash
# services/asterisk-do.sh — Easy Asterisk PBX + coturn, tuned for a public
# DigitalOcean droplet (public-IP FQDN by default, DO Cloud Firewall setup,
# no LAN/VLAN prompts). For a home/LAN box use services/asterisk.sh instead.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on a fresh droplet:
#   sudo bash asterisk-do.sh
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
                # The template Caddyfile ships with "admin off", so `caddy
                # reload` (which needs that same admin API) never actually
                # works here. Try it anyway, fall back to a restart.
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                elif docker restart caddy &>/dev/null; then
                    log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                    log_success "$_name should be accessible at: https://$_domain"
                else
                    log_warning "Reload/restart failed — check: docker logs caddy"
                    log_info "Manual fix: docker restart caddy"
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

register_service asterisk-do homelab "Easy Asterisk PBX + coturn, tuned for a public DigitalOcean droplet" 5061

install_asterisk-do() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn (DigitalOcean droplet edition)..."

    local EA_DIR="$DOCKER_DIR/asterisk-do"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would add a swapfile if RAM <= 2048MB and none exists"
        echo "[DRY-RUN] Would offer to install Caddy if not already present (full repo only)"
        echo "[DRY-RUN] Would offer optional extras as a numbered, comma-separated menu (1-6)"
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk"
        echo "[DRY-RUN] Would detect droplet public IP via DO metadata service"
        echo "[DRY-RUN] Would scan for a free web admin port starting at 8081 (avoids e.g. CrowdSec's 8080)"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, <web admin port>, 8088, 8089, 3478, 10000-20000, 49152-49252"
        echo "[DRY-RUN] Would open 51820/udp (not 51821) if wg-easy was selected"
        echo "[DRY-RUN] Would offer to create a DigitalOcean Cloud Firewall via doctl"
        echo "[DRY-RUN] Would reverse-proxy the web admin on the SAME FQDN used for SIP (needed for cert sync)"
        echo "[DRY-RUN] Would offer local OR remote Authelia to protect the web admin"
        echo "[DRY-RUN] Would offer to install CrowdSec if not already present (full repo only)"
        echo "[DRY-RUN] Would offer to run base setup first if not already done (full repo only)"
        return 0
    fi

    # ── Bring in base first, if this is a genuinely fresh box ─────────────────
    # Naming a service directly (sudo ./setup.sh asterisk-do) skips setup.sh's
    # own first-run base step — essential packages, SSH key import, disabling
    # password auth. That's a real gap on a fresh droplet: everything below
    # still works without it, but the SSH-hardening part of this setup's
    # security story wouldn't actually have happened. Same marker setup.sh
    # itself uses to detect base (command -v ncdu).
    if ! command -v ncdu &>/dev/null; then
        if declare -F install_base &>/dev/null; then
            local WANT_BASE=""
            prompt_yn "Base setup not detected (essential packages, SSH hardening) — run it first? (y/n):" "y" WANT_BASE
            [[ "$WANT_BASE" =~ ^[Yy]$ ]] && install_base
        else
            log_warning "Base setup not detected, and this looks like a standalone copy of asterisk-do.sh."
            log_warning "Run services/base.sh yourself first, or grab the full repo."
        fi
    fi

    # ── Swap file (insurance for low-RAM droplets, e.g. the $4/mo 512MB plan) ──
    # DigitalOcean doesn't provision swap by default. Docker + Asterisk + coturn
    # fit in 512MB-1GB at idle with little headroom; a swapfile absorbs spikes
    # (apt/image pulls, log bursts, a few concurrent calls) instead of the
    # kernel OOM-killing a container or the box going unresponsive over SSH.
    local TOTAL_RAM_MB
    TOTAL_RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$TOTAL_RAM_MB" -gt 0 && "$TOTAL_RAM_MB" -le 2048 ]] && ! swapon --show | grep -q .; then
        local FREE_DISK_MB SWAP_MB=2048
        FREE_DISK_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
        if [[ "$FREE_DISK_MB" -gt $((SWAP_MB + 2048)) ]]; then
            local ADD_SWAP=""
            prompt_yn "No swap detected on this ${TOTAL_RAM_MB}MB-RAM droplet — add a ${SWAP_MB}MB swapfile? (y/n):" "y" ADD_SWAP
            if [[ "$ADD_SWAP" =~ ^[Yy]$ ]]; then
                fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile
                grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
                sysctl -w vm.swappiness=10 >/dev/null 2>&1
                log_success "Swapfile enabled (${SWAP_MB}MB, swappiness=10, persists across reboots)."
            fi
        else
            log_warning "Not enough free disk for a safe swapfile (${FREE_DISK_MB}MB free) — skipping."
            log_warning "Consider a bigger droplet, or free up disk before installing."
        fi
    fi

    # ── Bring in Caddy automatically, if this is a full repo checkout ─────────
    # Caddy is a separate service (services/caddy.sh); asterisk-do only
    # *integrates* with it (reused certs, reverse-proxied admin) unless
    # offered here. setup.sh sources every services/*.sh file up front, so
    # install_caddy already exists in-process when running through the
    # wizard — a standalone single-file run doesn't have it, so that case
    # gets a manual pointer instead.
    if [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -z "${CADDY_REMOTE_HOST:-}" ]]; then
        if declare -F install_caddy &>/dev/null; then
            local WANT_CADDY=""
            prompt_yn "Caddy not detected — install it now for a trusted TLS cert + reverse proxy? (y/n):" "y" WANT_CADDY
            [[ "$WANT_CADDY" =~ ^[Yy]$ ]] && install_caddy
        else
            log_warning "Caddy not detected, and this looks like a standalone copy of asterisk-do.sh."
            log_warning "Grab the full repo to auto-install it, or run services/caddy.sh yourself."
        fi
    fi

    # ── Optional extras ─────────────────────────────────────────────────────
    # One prompt instead of five separate yes/no interruptions. Each is
    # dispatched at the point later in this function where it actually makes
    # sense (Authelia needs Caddy's state, which we just resolved above;
    # wg-easy needs its own firewall rules alongside the others; backup makes
    # most sense last). Only offered in full-repo mode, same reasoning as Caddy.
    local EXTRAS=""
    local _EXTRA_NAMES=(authelia ntfy watchtower wg-easy netbird backup)
    if declare -F install_authelia &>/dev/null; then
        echo ""
        echo "  Optional extras — enter numbers, comma-separated (blank = skip all):"
        echo "    1) authelia    SSO/2FA in front of the web admin (needs Caddy, above)"
        echo "    2) ntfy        self-hosted push notifications (e.g. CrowdSec ban alerts)"
        echo "    3) watchtower  auto-updates pulled images — only helps coturn here;"
        echo "                   Asterisk itself is built locally, so OS security patches"
        echo "                   still need a manual 'docker compose up -d --build'"
        echo "    4) wg-easy     WireGuard VPN — lets you lock the web admin to VPN-only later"
        echo "    5) netbird     Mesh VPN + optional built-in SSH server, so this droplet and a"
        echo "                   home machine can reach each other without port-forwarding —"
        echo "                   pairs with 'backup' below (skipped automatically if already installed)"
        echo "    6) backup      Borg backup of ~/docker/* to a local machine or remote host —"
        echo "                   config/data backup, NOT a full droplet image, instead of"
        echo "                   DigitalOcean's paid Droplet Backups"
        echo "  Example: 5,6"
        local EXTRAS_NUM=""
        prompt_text "Install:" "" EXTRAS_NUM
        local _IFS_OLD="$IFS" _n
        IFS=','
        for _n in $EXTRAS_NUM; do
            _n="${_n//[[:space:]]/}"
            [[ "$_n" =~ ^[1-6]$ ]] && EXTRAS+=" ${_EXTRA_NAMES[$((_n-1))]}"
        done
        IFS="$_IFS_OLD"
    fi

    if [[ "$EXTRAS" == *authelia* ]] && declare -F install_authelia &>/dev/null; then
        if [[ -d "$DOCKER_DIR/caddy" ]]; then
            install_authelia
        else
            log_warning "Skipping Authelia — it needs Caddy, which isn't installed."
        fi
    fi

    mkdir -p "$EA_DIR"
    mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
             "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    mkdir -p docker

    # ── Vendor files (shared with services/asterisk.sh — no duplication) ──────
    local _SELF_DIR_LOCAL
    _SELF_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local VENDOR_DIR="$_SELF_DIR_LOCAL/../vendor/easy-asterisk"

    mkdir -p scripts

    if [[ -d "$VENDOR_DIR" ]]; then
        log_info "Copying vendor files from $VENDOR_DIR ..."
        cp "$VENDOR_DIR/Dockerfile"                    ./Dockerfile
        cp "$VENDOR_DIR/docker/entrypoint.sh"          ./docker/entrypoint.sh
        cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"   ./docker/coturn-entrypoint.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk-v0.10.0.sh
        cp "$VENDOR_DIR/scripts/vpn-diagnostics.sh"    ./scripts/vpn-diagnostics.sh
        cp "$VENDOR_DIR/scripts/dns-whitelist.sh"      ./scripts/dns-whitelist.sh
    else
        log_info "Vendor directory not found — downloading from GitHub ..."
        local GH_RAW="https://raw.githubusercontent.com/DeadDork/easy-asterisk/main"
        curl -fsSL "$GH_RAW/Dockerfile"                        -o ./Dockerfile
        curl -fsSL "$GH_RAW/docker/entrypoint.sh"              -o ./docker/entrypoint.sh
        curl -fsSL "$GH_RAW/docker/coturn-entrypoint.sh"       -o ./docker/coturn-entrypoint.sh
        curl -fsSL "$GH_RAW/easy-asterisk-v0.10.0.sh"          -o ./easy-asterisk.sh
        curl -fsSL "$GH_RAW/scripts/vpn-diagnostics.sh"        -o ./scripts/vpn-diagnostics.sh
        curl -fsSL "$GH_RAW/scripts/dns-whitelist.sh"          -o ./scripts/dns-whitelist.sh
        cp ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh
    fi

    chmod 755 ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh \
              ./docker/entrypoint.sh ./docker/coturn-entrypoint.sh \
              ./scripts/vpn-diagnostics.sh ./scripts/dns-whitelist.sh

    # ── Persist security-level logging to a file ──────────────────────────────
    # Vendor's logger.conf only sends the "security" level (auth failures, SIP
    # brute-force attempts) to the console — that's Docker's stdout, not a file
    # CrowdSec/fail2ban can tail. Patch our copy of entrypoint.sh (not the
    # shared vendor/ source) so it also writes those events to
    # /var/log/asterisk/full, which is bind-mounted to $EA_DIR/logs/full — a
    # host path services/crowdsec.sh can point its Asterisk acquisition at.
    if grep -q '^console => notice,warning,error,security$' ./docker/entrypoint.sh; then
        sed -i '/^console => notice,warning,error,security$/a full => notice,warning,error,security' \
            ./docker/entrypoint.sh
    else
        log_warning "entrypoint.sh logger.conf template changed upstream — security events won't be logged to a file. Update the sed patch in this installer."
    fi

    # ── DigitalOcean droplet detection ────────────────────────────────────────
    # A droplet's own public IP/ID are readable, unauthenticated, from the
    # link-local metadata service — no API token needed for this part.
    echo ""
    log_info "Reading DigitalOcean droplet metadata..."
    local DO_META="http://169.254.169.254/metadata/v1"
    local DROPLET_ID PUBLIC_IP
    DROPLET_ID="$(curl -fsS --max-time 2 "$DO_META/id" 2>/dev/null || true)"
    PUBLIC_IP="$(curl -fsS --max-time 2 "$DO_META/interfaces/public/0/ipv4/address" 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [[ -n "$DROPLET_ID" ]]; then
        log_success "Detected DigitalOcean droplet id $DROPLET_ID, public IP ${PUBLIC_IP:-unknown}"
    else
        log_warning "DigitalOcean metadata service not reachable (not a droplet, or run in a container)."
        log_warning "Continuing anyway — Cloud Firewall automation will be skipped."
    fi

    # ── Domain (always public — this is a cloud box) ──────────────────────────
    echo ""
    echo "  Point a DNS A record at this droplet before continuing:"
    echo "    <subdomain>.${SITE_DOMAIN:-example.com}  A  ${PUBLIC_IP:-<droplet public IP>}"
    echo ""
    echo "  This one FQDN covers everything below — SIP registration, the web"
    echo "  admin, and (via Caddy) the TLS cert Asterisk needs for SIP. There's"
    echo "  no separate \"admin domain\" to pick later — whatever you enter here"
    echo "  is what your SIP client (e.g. Sipnetic) will register against."
    local DOMAIN_NAME=""
    prompt_text "FQDN for this PBX, e.g. sip.yourdomain.com [blank=self-signed cert, IP-only access]:" "" DOMAIN_NAME
    [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — using a self-signed cert; phones must trust it manually."

    # ── Secrets ───────────────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(generate_password 24)"

    # Unlike the LAN edition, a droplet is always reachable — TURN always has
    # a usable address (the FQDN if set, otherwise the droplet's public IP).
    local TURN_SERVER_VAL="${DOMAIN_NAME:-$PUBLIC_IP}:3478"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > docker-compose.yml << 'EOF'
name: asterisk-do

services:
  asterisk:
    build: .
    container_name: easy-asterisk-do
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - ./config/asterisk:/etc/asterisk
      - ./config/easy-asterisk:/etc/easy-asterisk
      - ./logs:/var/log/asterisk
      - ./spool:/var/spool/asterisk
      - ./lib:/var/lib/asterisk
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
CADDY_VOLUME_PLACEHOLDER
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-do-coturn
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

EOF

    # Share Caddy's cert store (read-only) so the entrypoint can auto-sync a
    # real Let's Encrypt cert for DOMAIN_NAME instead of falling back to
    # self-signed. No-op if Caddy isn't installed on this box.
    if [[ -d "$DOCKER_DIR/caddy/data" ]]; then
        sed -i "s#CADDY_VOLUME_PLACEHOLDER#      - ${DOCKER_DIR}/caddy/data:/caddy-data:ro#" docker-compose.yml
    else
        sed -i "/CADDY_VOLUME_PLACEHOLDER/d" docker-compose.yml
    fi

    # ── Pick a free port for the web admin ─────────────────────────────────────
    # Hardcoding a single number gets fragile fast once several services share
    # a host — CrowdSec's own LAPI already collides with 8080 by default (its
    # own upstream default, confirmed against its real config.yaml). Scan
    # instead: start at 8081 and take the first port nothing is listening on,
    # capped so a pathological box can't spin this forever.
    local WEB_ADMIN_PORT_VAL=8081
    local _port_scan_limit=$((WEB_ADMIN_PORT_VAL + 100))
    while ss -tlnH "sport = :${WEB_ADMIN_PORT_VAL}" 2>/dev/null | grep -q . \
          && [[ "$WEB_ADMIN_PORT_VAL" -lt "$_port_scan_limit" ]]; do
        WEB_ADMIN_PORT_VAL=$((WEB_ADMIN_PORT_VAL + 1))
    done
    if [[ "$WEB_ADMIN_PORT_VAL" -ge "$_port_scan_limit" ]]; then
        log_warning "No free port found in 8081-${_port_scan_limit} — falling back to 8081 anyway."
        WEB_ADMIN_PORT_VAL=8081
    elif [[ "$WEB_ADMIN_PORT_VAL" != 8081 ]]; then
        log_info "Port 8081 was already taken — web admin will use ${WEB_ADMIN_PORT_VAL} instead."
    fi

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# Public FQDN for this droplet. Leave empty to fall back to a self-signed
# cert reachable at the droplet's public IP (${PUBLIC_IP:-unknown}).
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
TURN_USERNAME=easyasterisk
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=3478
TURN_SERVER=${TURN_SERVER_VAL}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── VLAN/VPN subnets ──────────────────────────────────────────
# A droplet has one public NIC, so this is usually irrelevant. Only set it
# if you're bridging phones back in over a VPN (e.g. WireGuard/Tailscale)
# on a subnet the droplet isn't directly attached to.
HAS_VLANS=n
VLAN_SUBNETS=

# ── Web admin ─────────────────────────────────────────────────
# Picked automatically at install time (first free port starting at 8081) —
# see WEB_ADMIN_PORT_VAL in services/asterisk-do.sh if this ever needs to
# change again; don't hand-edit without also updating Caddy's Caddyfile and
# both firewall layers to match.
WEB_ADMIN_PORT=${WEB_ADMIN_PORT_VAL}
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── UFW firewall rules (host-level) ───────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        ufw allow "${WEB_ADMIN_PORT_VAL}/tcp"
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow 10000:20000/udp
        ufw allow 49152:49252/udp
    fi

    # ── wg-easy: install now so its firewall rule lands with the others ───────
    # Only the VPN port (51820/udp) goes on the public firewall — WireGuard's
    # handshake is designed to be internet-facing. The web UI (51821) does
    # NOT get opened publicly: it's a full account-management panel for the
    # VPN, so it's reached via SSH tunnel instead (documented in the README).
    if [[ "$EXTRAS" == *wg-easy* ]] && declare -F install_wg-easy &>/dev/null; then
        install_wg-easy
        cd "$EA_DIR" || return 1   # install_wg-easy cd's into ~/docker/wg-easy
        if command -v ufw &>/dev/null; then
            ufw allow 51820/udp
        fi
    fi

    if command -v ufw &>/dev/null; then
        log_success "UFW rules added."
    fi

    # ── DigitalOcean Cloud Firewall (network edge, in front of the droplet) ───
    local DO_FW_RULES=(
        "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5061,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:${WEB_ADMIN_PORT_VAL},address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:8088-8089,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:10000-20000,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:49152-49252,address:0.0.0.0/0,address:::/0"
    )
    [[ "$EXTRAS" == *wg-easy* ]] && DO_FW_RULES+=("protocol:udp,ports:51820,address:0.0.0.0/0,address:::/0")

    echo ""
    if [[ -n "$DROPLET_ID" ]] && command -v doctl &>/dev/null && doctl account get &>/dev/null; then
        local EXISTING_FW
        EXISTING_FW="$(doctl compute firewall list --format ID,DropletIDs --no-header 2>/dev/null \
            | grep -E "(^|[, ])${DROPLET_ID}([, ]|\$)" | awk '{print $1}' | head -1)"

        if [[ -n "$EXISTING_FW" ]]; then
            log_warning "A Cloud Firewall (id $EXISTING_FW) is already attached to this droplet — not touching it."
            log_warning "Add these inbound rules to it yourself (Networking → Firewalls in the DO console):"
            printf '    %s\n' "${DO_FW_RULES[@]}"
        else
            local DO_FW=""
            prompt_yn "Create a DigitalOcean Cloud Firewall for this droplet via doctl now? (y/n):" "y" DO_FW
            if [[ "$DO_FW" =~ ^[Yy]$ ]]; then
                if doctl compute firewall create \
                    --name "asterisk-do" \
                    --droplet-ids "$DROPLET_ID" \
                    --inbound-rules "$(IFS=' '; echo "${DO_FW_RULES[*]}")" \
                    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,ports:0,address:0.0.0.0/0,address:::/0" \
                    &>/dev/null; then
                    log_success "Cloud Firewall 'asterisk-do' created and attached (SSH/22 included so you don't get locked out)."
                    log_info "Verify it in the DO console — adjust the SSH rule if you use a non-default SSH port."
                else
                    log_warning "doctl firewall create failed — add the rules manually (see README)."
                fi
            fi
        fi
    else
        log_info "doctl not installed/authenticated — configure a DigitalOcean Cloud Firewall manually:"
        log_info "Control Panel → Networking → Firewalls → create, attach to this droplet, allow:"
        printf '    %s\n' "${DO_FW_RULES[@]}"
    fi

    # ── Caddy: reverse-proxy the web admin on the SAME FQDN used for SIP ──────
    # Caddy only holds a cert for domains it's actively serving. If the web
    # admin were proxied on a different "admin" subdomain, Caddy would obtain
    # a cert for THAT domain instead — the sync earlier would never find one
    # matching $DOMAIN_NAME, and SIP TLS would silently stay self-signed. So
    # there's no separate domain prompt: this always targets $DOMAIN_NAME.
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_info "No FQDN set — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL} (nothing for Caddy to do)."
    elif [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -z "${CADDY_REMOTE_HOST:-}" ]]; then
        log_info "Caddy not installed — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL}, SIP TLS stays self-signed."
    else
        local EXTRA_BLOCK=""
        if [ -d "$DOCKER_DIR/authelia" ]; then
            local _use_auth=""
            prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
            if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
                EXTRA_BLOCK="    import authelia"
                # Disable built-in auth since Authelia handles it
                sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
            fi
        else
            # No local Authelia — offer one running elsewhere (e.g. a homelab).
            # There's no shared "(authelia)" Caddy snippet to import in that
            # case (authelia.sh only writes one when installing locally), so
            # this builds the same forward_auth block inline, targeting the
            # remote instance directly instead of the local "authelia:9091"
            # container reference.
            local _use_remote_auth=""
            prompt_yn "Protect the web admin with a remote Authelia instance (e.g. on a homelab)? (y/n):" "n" _use_remote_auth
            if [[ "$_use_remote_auth" =~ ^[Yy]$ ]]; then
                local _remote_authelia=""
                prompt_text "  Remote Authelia address — a bare host:port over a private network (e.g. a NetBird mesh IP:9091), or a full https:// URL if it's on its own public domain+TLS:" "" _remote_authelia
                if [[ -n "$_remote_authelia" ]]; then
                    EXTRA_BLOCK="    forward_auth ${_remote_authelia} {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }"
                    sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
                    log_info "Using remote Authelia at ${_remote_authelia}."
                    log_info "Verify it's reachable from this droplet before relying on it — e.g.:"
                    log_info "  curl -I ${_remote_authelia}"
                else
                    log_info "No address entered — skipping Authelia protection."
                fi
            fi
        fi

        # Deliberately NOT using configure_caddy_for_service here. That helper
        # asks for its own domain, defaulting to "<subdomain>.${SITE_DOMAIN}" —
        # which only lands on $DOMAIN_NAME if SITE_DOMAIN happens to be set to
        # match, and silently shows a useless blank/wrong default otherwise
        # (real-world confirmed: SITE_DOMAIN is never set when this service is
        # run by name, e.g. `sudo ./setup.sh asterisk-do`, since that skips
        # setup.sh's own site-defaults wizard entirely). There is exactly one
        # correct domain for this site block — $DOMAIN_NAME — so it's written
        # directly, with no domain prompt to get wrong.
        echo ""
        local WANT_CADDY_PROXY=""
        prompt_yn "Reverse-proxy the web admin at https://${DOMAIN_NAME}/ via Caddy? (also gets Asterisk a trusted TLS cert for SIP instead of self-signed) (y/n):" "y" WANT_CADDY_PROXY
        if [[ "$WANT_CADDY_PROXY" =~ ^[Yy]$ ]]; then
            local _CADDY_MODE="local"
            [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -n "${CADDY_REMOTE_HOST:-}" ]] && _CADDY_MODE="remote"

            local _SITE_BLOCK
            _SITE_BLOCK="$(cat << CADDY_BLOCK

# Asterisk Web Admin
${DOMAIN_NAME} {
    reverse_proxy localhost:${WEB_ADMIN_PORT_VAL}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${DOMAIN_NAME}.log
        format json
    }
${EXTRA_BLOCK}
}
CADDY_BLOCK
)"

            if [[ "$_CADDY_MODE" == "local" ]]; then
                local _CADDYFILE="$DOCKER_DIR/caddy/Caddyfile"
                local _CADDY_BACKUP="$_CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)"
                if [[ -f "$_CADDYFILE" ]]; then
                    cp "$_CADDYFILE" "$_CADDY_BACKUP"
                else
                    touch "$_CADDYFILE"
                fi
                if grep -q "^${DOMAIN_NAME}" "$_CADDYFILE" 2>/dev/null; then
                    log_warning "${DOMAIN_NAME} already in Caddyfile — leaving the existing entry alone."
                else
                    printf '%s\n' "$_SITE_BLOCK" >> "$_CADDYFILE"
                    log_success "Added ${DOMAIN_NAME} to Caddyfile (backup: $(basename "$_CADDY_BACKUP"))"
                    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                    # The template Caddyfile ships with "admin off", so
                    # `caddy reload` (which needs that same admin API) never
                    # actually works here. Try it anyway, fall back to a
                    # restart — confirmed necessary on a real deployment.
                    if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                        log_success "Web admin accessible at: https://${DOMAIN_NAME}"
                    elif docker restart caddy &>/dev/null; then
                        log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                        log_success "Web admin should be accessible at: https://${DOMAIN_NAME}"
                    else
                        log_warning "Reload/restart failed — check: docker logs caddy"
                        log_info "Manual fix: docker restart caddy"
                    fi
                fi
            else
                local _SNIPPET_DIR="$DOCKER_DIR/caddy-snippets"
                mkdir -p "$_SNIPPET_DIR"
                printf '%s\n' "$_SITE_BLOCK" > "$_SNIPPET_DIR/asterisk-do.caddy"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_SNIPPET_DIR/asterisk-do.caddy" 2>/dev/null || true
                log_success "Snippet saved: $_SNIPPET_DIR/asterisk-do.caddy"
                log_info "Copy to your Caddy machine: scp $_SNIPPET_DIR/asterisk-do.caddy caddy-host:~/caddy-snippets/"
            fi
        fi
    fi

    # ── CrowdSec: SIP brute-force/enumeration protection ──────────────────────
    if command -v cscli &>/dev/null; then
        log_info "CrowdSec is already installed — rerun it to pick up SIP protection for this install:"
        log_info "  sudo ./setup.sh crowdsec"
    elif declare -F install_crowdsec &>/dev/null; then
        local WANT_CS=""
        prompt_yn "CrowdSec not detected — install it now for SSH + SIP intrusion prevention? (y/n):" "y" WANT_CS
        [[ "$WANT_CS" =~ ^[Yy]$ ]] && install_crowdsec
    else
        log_warning "CrowdSec not detected, and this looks like a standalone copy of asterisk-do.sh."
        log_warning "Grab the full repo to auto-install it, or run services/crowdsec.sh yourself."
    fi

    # ── ntfy / watchtower (independent extras, selected earlier) ──────────────
    if [[ "$EXTRAS" == *ntfy* ]] && declare -F install_ntfy &>/dev/null; then
        install_ntfy
        cd "$EA_DIR" || return 1   # install_ntfy cd's into ~/docker/ntfy
    fi
    if [[ "$EXTRAS" == *watchtower* ]] && declare -F install_watchtower &>/dev/null; then
        install_watchtower
        cd "$EA_DIR" || return 1   # install_watchtower cd's into ~/docker/watchtower
    fi

    # ── NetBird: mesh VPN + optional built-in SSH server ───────────────────────
    # _base_setup_netbird lives in services/base.sh (not its own register_service
    # entry — it's a helper base.sh calls on first run), but it's a plain
    # function like any other once sourced, so it's callable here the same way.
    # Doesn't cd anywhere, so no directory restore needed after it. Its own
    # prompt already defaults "enable NetBird's built-in SSH server" to yes —
    # that's the piece that lets 'backup' below reach a home machine without
    # port-forwarding, IF the home machine also joins the same NetBird network
    # (a separate, manual step on that machine — this only sets up this droplet).
    if [[ "$EXTRAS" == *netbird* ]]; then
        if command -v netbird &>/dev/null; then
            log_info "NetBird is already installed on this droplet."
        elif declare -F _base_setup_netbird &>/dev/null; then
            _base_setup_netbird
        else
            log_warning "NetBird setup not found, and this looks like a standalone copy of asterisk-do.sh."
            log_warning "Grab the full repo to auto-install it, or run services/base.sh yourself."
        fi
    fi

    # ── Backup: config/data to a local machine or remote host ─────────────────
    # Not a full droplet image — it's ~/docker/* (this PBX's config, extensions,
    # CDRs, and every other installed service here) via Borg, which supports
    # local paths or user@host:/path SSH remotes. That's the alternative to
    # DigitalOcean's paid Droplet Backups: point it at your own machine instead
    # of paying DO to store snapshots. Disaster recovery then becomes "fresh
    # droplet, rerun this installer, restore from the Borg repo" rather than
    # restoring a multi-GB disk image. Pair with 'netbird' above so the SSH
    # remote target is a private mesh IP instead of needing a port-forward.
    if [[ "$EXTRAS" == *backup* ]] && declare -F install_borg-backup &>/dev/null; then
        install_borg-backup
        cd "$EA_DIR" || return 1   # install_borg-backup cd's into ~/docker/borg-backup
    fi

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << MD
# Easy Asterisk PBX + coturn — DigitalOcean droplet edition

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal, sized and secured for a public DigitalOcean droplet. For a
home/LAN box with VLAN support, use \`~/docker/asterisk\` (services/asterisk.sh)
instead.

## Droplet sizing

Asterisk + coturn is light for a handful of SIP extensions and personal use.

| Plan                          | vCPU | RAM   | Good for                              |
|--------------------------------|------|-------|----------------------------------------|
| Basic (regular), \$4/mo          | 1    | 512 MB | Works — this installer adds a 2GB swapfile automatically to cover it. Fine for a couple of extensions and light personal use. |
| **Basic (regular), \$6/mo — recommended** | 1    | 1 GB  | More headroom, still gets an automatic swapfile |
| Basic (regular), \$12/mo         | 1    | 2 GB  | Comfortable — no swap needed, a handful of concurrent calls |
| Basic (regular), \$24/mo         | 2    | 4 GB  | Several simultaneous calls, conference bridges, transcoding |

10 GB SSD (the \$4/mo plan's disk) is enough — this stack isn't storage-heavy,
and the swapfile only takes 2GB of it. Any DO region close to where the
phones actually are is fine; SIP/RTP care about latency more than raw
bandwidth.

**Swap:** DigitalOcean doesn't provision swap by default, and Docker +
Asterisk + coturn leave little headroom at 512MB–1GB RAM. This installer
detects RAM ≤2GB with no existing swap and offers to add a 2GB swapfile
automatically (persisted in \`/etc/fstab\`) — it's what makes the \$4/mo plan
viable instead of risking an OOM kill under load.

**OS image:** Ubuntu 24.04 LTS (supported through April 2029) is the safe,
battle-tested choice for Docker + coturn. Ubuntu 26.04 LTS is also available
and supported longer (through 2031) if you'd rather track the newer LTS.

## DNS

Before running this installer, point an A record at the droplet's public IP:

\`\`\`
sip.yourdomain.com   A   <droplet public IP>
\`\`\`

The installer reads the droplet's public IP itself (via the DigitalOcean
metadata service) and shows it to you during setup. This one FQDN is used
for SIP, the web admin, and the TLS cert — there's no separate domain to
plan for the admin panel.

## Security

- **SSH:** key-based auth only, password login disabled — \`services/base.sh\`
  in this repo offers to do this for you on first run. Don't skip it; this
  box is public.
- **Two firewall layers, same rule set:**
  - **DigitalOcean Cloud Firewall** — filters at the network edge, before
    traffic reaches the droplet. This installer offers to create one
    automatically via \`doctl\` (only if none is already attached to this
    droplet — it never overwrites an existing one, to avoid clobbering a
    custom SSH allow-list). If \`doctl\` isn't set up, add the rules below
    manually in the DO console (Networking → Firewalls).
  - **UFW** — host-level, configured automatically by this installer as a
    second layer. Keep both in sync; don't let them contradict each other.
- **CrowdSec** — SIP brute-force/enumeration protection (\`crowdsecurity/asterisk\`
  collection). Offered automatically during install if not already present;
  see \`services/crowdsec.sh\`.
- DO's paid Droplet Backups is one option for a rollback path — the
  \`backup\` extra below is the alternative used here.

### Ports (open on both the Cloud Firewall and UFW)

| Port          | Protocol | Purpose                          |
|---------------|----------|-----------------------------------|
| 22            | TCP      | SSH (keep this open or you're locked out) |
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| ${WEB_ADMIN_PORT_VAL}          | TCP      | Easy Asterisk web admin (auto-picked — see \`.env\`) |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| 49152–49252   | UDP      | TURN relay media ports           |
| 51820         | UDP      | WireGuard VPN, only if \`wg-easy\` was selected |

## Optional extras

Offered during install (space-separated at the "Install:" prompt); can also
be added later by running \`sudo ./setup.sh <name>\` from the repo.

- **authelia** — SSO/2FA in front of the web admin. Needs Caddy locally to
  install here. If it's already installed (locally or picked up by
  re-running \`asterisk-do\`), that instance protects the web admin
  automatically. **No local Authelia?** The web-admin step separately offers
  a **remote Authelia** option instead — point it at an instance already
  running elsewhere (e.g. a homelab) via a bare \`host:port\` over a private
  network (a NetBird mesh IP works well here) or a full \`https://\` URL if
  it has its own public domain+TLS. Every web-admin page load then does a
  round trip to that address, so if it's unreachable, the panel fails closed
  — SIP/calling on this droplet is unaffected either way, only the admin UI.
- **ntfy** — self-hosted push notifications. Useful as a destination for
  CrowdSec ban alerts (\`services/crowdsec.sh\` prompts for an ntfy URL —
  point it at this instance instead of the public ntfy.sh if you'd rather
  keep alerts off a third party).
- **watchtower** — auto-updates pulled Docker images daily. Only helps
  \`coturn\` here — Asterisk's image is built locally from a Dockerfile, so
  Watchtower has no registry tag to check against. Keep Asterisk patched
  with an occasional \`docker compose up -d --build\`.
- **wg-easy** — WireGuard VPN. Only its VPN port (51820/udp) is opened on
  the public firewall; the web UI (51821) is deliberately **not** exposed —
  reach it via SSH tunnel: \`ssh -L 51821:localhost:51821 user@<droplet-ip>\`,
  then browse \`http://localhost:51821\`. A natural next step once it's
  installed: restrict the web admin (${WEB_ADMIN_PORT_VAL}) to the VPN subnet only, on both
  firewall layers, so reconfiguring the PBX requires being on the VPN —
  done manually, not automatically, since a firewall mistake there can lock
  you out.
- **netbird** — mesh VPN (via \`services/base.sh\`'s \`_base_setup_netbird\`
  helper). Its own prompt defaults to enabling NetBird's **built-in SSH
  server** (\`--allow-server-ssh\`) on this droplet. Install NetBird on a
  home machine too (separately, outside this installer — same
  \`curl -fsSL https://pkgs.netbird.io/install.sh | sh\`, then
  \`netbird up --setup-key <key> --allow-server-ssh\`) and join it to the
  same network, and the two machines get a private mesh IP to reach each
  other over — no router port-forwarding, no public SSH exposure on either
  end. That mesh IP is what \`backup\` below should target.
- **backup** — Borg backup of \`~/docker/*\` (this PBX's config, extensions,
  CDRs, and every other service on this droplet) to a **local path or a
  remote host over SSH** (\`user@host:/path\`) — see \`services/borg-backup.sh\`.
  This is the alternative to DigitalOcean's paid Droplet Backups: point it
  at your own machine and pay nothing extra to DO. It is **not** a full
  droplet disk image — disaster recovery is "fresh droplet, rerun this
  installer, restore the Borg repo," which is faster and more portable than
  restoring a multi-GB snapshot. If the destination is a home machine
  without a stable public IP, install \`netbird\` (above) first and use its
  mesh IP as the SSH host instead of port-forwarding a home router.

## Manage

\`\`\`bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
\`\`\`

## Management script

\`\`\`bash
docker exec -it easy-asterisk-do easy-asterisk --help
\`\`\`

Use it to create SIP extensions (Server Settings → Extensions) before
connecting a phone.

## Connecting with Sipnetic (Android)

[Sipnetic](https://www.sipnetic.com/) is a free Android SIP client with
TLS/SRTP and STUN/TURN/ICE support — a good fit for this setup. (iPhone
users: Linphone or Zoiper cover the same ground.)

1. In the Easy Asterisk web admin, create an extension — note its
   username/number and password.
2. In Sipnetic, add an account with:

| Setting          | Value                                          |
|-------------------|------------------------------------------------|
| Username          | extension number/username from easy-asterisk   |
| Password          | extension password from easy-asterisk          |
| Domain            | \`${DOMAIN_NAME:-$PUBLIC_IP}\`                        |
| Transport         | TLS                                             |
| Port              | 5061                                            |
| SRTP              | Enabled (optional, for encrypted media)         |
| STUN/TURN server  | \`${DOMAIN_NAME:-$PUBLIC_IP}:3478\`                   |
| TURN username     | \`easyasterisk\` (see \`.env\` → \`TURN_USERNAME\`)    |
| TURN password     | see \`.env\` → \`TURN_PASSWORD\`                      |

3. Save and let it register. If it registers but calls connect with no
   audio, double-check the RTP/TURN port ranges are open on *both* firewall
   layers above.

## TLS certificate

Caddy is what actually talks to Let's Encrypt — Asterisk never does ACME
itself. The installer always reverse-proxies the web admin on the exact
same FQDN used for SIP (never a separate "admin" domain), specifically
because that's what makes Caddy hold a cert matching \`DOMAIN_NAME\`. The
container then mounts Caddy's cert store read-only and the entrypoint syncs
that cert in automatically on every start — and re-checks every 12h so
renewals get picked up without a restart. No Caddy on the box, or no FQDN
set at all, falls back to a self-signed cert (phones must be configured to
accept it manually).

## Web admin

Access the Easy Asterisk web interface at http://<droplet-ip>:${WEB_ADMIN_PORT_VAL}
or via your configured reverse-proxy domain.

## Data directories (all inside ~/docker/asterisk-do/, included in backup)

| Directory            | Contents                        |
|-----------------------|----------------------------------|
| config/asterisk/      | /etc/asterisk — dialplan, SIP   |
| config/easy-asterisk/ | /etc/easy-asterisk — web config |
| logs/                 | /var/log/asterisk               |
| spool/                | /var/spool/asterisk             |
| lib/                  | /var/lib/asterisk               |
MD

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk (DO edition) started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Easy Asterisk (DigitalOcean edition) installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    else
        echo "  Mode:        IP-only (self-signed cert)"
        echo "  TURN server: ${PUBLIC_IP:-unknown}:3478"
    fi
    echo "  Public IP:   ${PUBLIC_IP:-unknown}"
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL}"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it easy-asterisk-do easy-asterisk --help"
    if [[ -n "$DOMAIN_NAME" ]] && [[ -d "$DOCKER_DIR/caddy" ]]; then
        echo ""
        log_info "If Caddy was just installed in this same run, it may still be obtaining the"
        log_info "Let's Encrypt cert for ${DOMAIN_NAME} — Asterisk only checks for it at startup"
        log_info "and then every 12h. If SIP TLS still shows self-signed after a couple of"
        log_info "minutes, pick it up immediately with:"
        log_info "  docker compose -f $EA_DIR/docker-compose.yml restart asterisk"
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk-do
