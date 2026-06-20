#!/bin/bash
# services/wg-easy.sh — WireGuard VPN with a web management UI (wg-easy).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash wg-easy.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- WG-EASY ----).
# Own ~/docker/wg-easy/ with a standalone docker-compose.yml + .env.
# Requires cap_add: NET_ADMIN + SYS_MODULE and ip_forward sysctl.
# Forward UDP 51820 on your router to this server for external VPN access.

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

register_service wg-easy utilities "WireGuard VPN with web management UI (wg-easy)" 51821

install_wg-easy() {
    require_docker || return 1

    local WGEASY_DIR="$DOCKER_DIR/wg-easy"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] wg-easy would:"
        echo "  - Create $WGEASY_DIR with docker-compose.yml + .env (config/)"
        echo "  - Auto-detect public IP for WG_HOST"
        echo "  - Generate a random web UI password"
        echo "  - Expose port 51821 (web UI) + 51820/udp (VPN)"
        echo "  - Require router port-forward: UDP 51820 → this server"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$WGEASY_DIR"
    ensure_docker_dir_ownership "$WGEASY_DIR"
    cd "$WGEASY_DIR" || return 1

    # Auto-detect public IP as default for WG_HOST
    local PUBLIC_IP WG_HOST WG_PASSWORD WG_PASSWORD_HASH
    PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "your-public-ip")
    WG_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    prompt_text "Public IP or hostname for VPN [$PUBLIC_IP]:" "$PUBLIC_IP" WG_HOST

    # wg-easy v14+ requires PASSWORD_HASH (bcrypt). Generate via docker.
    log_info "Generating bcrypt password hash (requires Docker)..."
    WG_PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "$WG_PASSWORD" 2>/dev/null \
        | grep -oP '\$2[ab]\$[^\s]+' | head -1)
    if [[ -z "$WG_PASSWORD_HASH" ]]; then
        log_warning "Could not generate bcrypt hash — falling back to plaintext PASSWORD env var."
        log_warning "If wg-easy fails to start, run: docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'yourpassword'"
        log_warning "Then set PASSWORD_HASH in docker-compose.yml and remove PASSWORD."
    fi

    # Escape $ in hash for docker-compose env (bcrypt hashes contain $$)
    local WG_HASH_ESCAPED="${WG_PASSWORD_HASH//\$/\$\$}"

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

    cat > docker-compose.yml << WGEASY_COMPOSE
name: wg-easy

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    hostname: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - WG_HOST=\${WG_HOST}
      - PASSWORD_HASH=${WG_HASH_ESCAPED:-\${WG_PASSWORD}}
      - WG_DEFAULT_DNS=1.1.1.1
    volumes:
      - ./config:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
WGEASY_COMPOSE

    cat > .env << WGEASY_ENV
WG_HOST=$WG_HOST
# Plain-text password — used only if PASSWORD_HASH could not be generated above
WG_PASSWORD=$WG_PASSWORD
CADDY_NET=$SITE_CADDY_NET
WGEASY_ENV

    mkdir -p config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WGEASY_DIR"
    log_success "wg-easy configured at $WGEASY_DIR"

    configure_caddy_for_service "wg-easy" "wg-easy:51821" "vpn"

    write_readme "$WGEASY_DIR" << MD
# wg-easy

WireGuard VPN with a web UI for managing clients, generating QR codes,
and monitoring connections.

- Web UI: http://localhost:51821
- VPN:    UDP port 51820 (forward this on your router)
- Password: stored in \`.env\` (\`WG_PASSWORD\`)
- VPN host: \`$WG_HOST\` (update \`WG_HOST\` in .env if your IP changes)
- Config: \`config/\`

## Manage
\`\`\`bash
cd $WGEASY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Router setup
Forward **UDP port 51820** to this server's LAN IP for external VPN access.

## Adding clients
Open http://localhost:51821, log in with your password, click "+ New Client",
download or scan the QR code with the WireGuard app.
MD

    local START_WGEASY=""
    prompt_yn "Start wg-easy now? (y/n):" "y" START_WGEASY
    if [ "$START_WGEASY" = "y" ] || [ "$START_WGEASY" = "Y" ]; then
        docker compose up -d && log_success "wg-easy started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Web UI:   http://localhost:51821"
    echo "  Password: $WG_PASSWORD  (saved in .env)"
    [[ -n "$WG_PASSWORD_HASH" ]] && echo "  Auth:     bcrypt hash configured (v14+ compatible)" \
        || echo "  Auth:     WARNING — bcrypt hash generation failed; see README"
    echo "  Router:   forward UDP 51820 → this server for external VPN access"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wg-easy
