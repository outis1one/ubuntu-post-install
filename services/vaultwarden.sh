#!/bin/bash
# services/vaultwarden.sh — Vaultwarden (self-hosted Bitwarden server).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash vaultwarden.sh
# (Docker must already be installed when run standalone)
#
# Vaultwarden is an unofficial, lightweight Bitwarden-compatible server.
# All official Bitwarden clients (browser extension, desktop, mobile) work with it.
# Requires HTTPS in production — set DOMAIN to your public URL.

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

register_service vaultwarden utilities "Bitwarden-compatible password manager (Vaultwarden)" 80

install_vaultwarden() {
    require_docker || return 1
    log_info "Installing Vaultwarden..."
    local VW_DIR="$DOCKER_DIR/vaultwarden"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $VW_DIR (vaultwarden_data/)"
        echo "[DRY-RUN] Would deploy vaultwarden/server:latest"
        echo "[DRY-RUN] Would generate admin token and prompt for domain"
        echo "[DRY-RUN] Signups disabled by default (enable via admin panel)"
        return 0
    fi

    mkdir -p "$VW_DIR/vaultwarden_data"
    ensure_docker_dir_ownership "$VW_DIR"
    cd "$VW_DIR" || return 1

    local ADMIN_TOKEN TZ_VAL
    ADMIN_TOKEN=$(generate_password 48)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    echo ""
    echo "  Vaultwarden needs to know its public HTTPS URL so Bitwarden clients"
    echo "  can connect and password-reset emails link correctly."
    echo ""
    local VW_DOMAIN=""
    local DEFAULT_DOMAIN="https://vault.${SITE_DOMAIN:-example.com}"
    prompt_text "Vaultwarden public URL (e.g. https://vault.example.com):" "$DEFAULT_DOMAIN" VW_DOMAIN
    [ -z "$VW_DOMAIN" ] && VW_DOMAIN="$DEFAULT_DOMAIN"

    echo ""
    echo "  SMTP (optional) — for password-reset and invite emails."
    echo "  Press Enter to skip each field and configure SMTP later in .env."
    echo ""
    local SMTP_HOST="" SMTP_FROM="" SMTP_USER="" SMTP_PASS="" SMTP_PORT="587"
    prompt_text "SMTP host (e.g. smtp.gmail.com) [skip]:" "" SMTP_HOST
    if [ -n "$SMTP_HOST" ]; then
        prompt_text "SMTP port [587]:" "587" SMTP_PORT
        prompt_text "SMTP from address:" "" SMTP_FROM
        prompt_text "SMTP username:" "" SMTP_USER
        prompt_text "SMTP password:" "" SMTP_PASS
    fi

    cat > docker-compose.yml << 'VW_COMPOSE'
name: vaultwarden

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: vaultwarden
    hostname: vaultwarden
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./vaultwarden_data:/data
    expose:
      - "80"
    ports:
      - "3012:3012"    # WebSocket (legacy — not needed for Vaultwarden v1.29+)
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
VW_COMPOSE

    cat > .env << VW_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── Vaultwarden ───────────────────────────────────────────────────────────────
# Public URL — MUST match the URL clients use (affects TOTP, push, reset emails)
DOMAIN=$VW_DOMAIN

# Admin panel: https://<domain>/admin  — keep this token secret
# To disable admin panel: delete ADMIN_TOKEN from this file
ADMIN_TOKEN=$ADMIN_TOKEN

# Signups: false = only the first admin can invite users via admin panel
SIGNUPS_ALLOWED=false
SIGNUPS_VERIFY=false

# WebSocket notifications (v1.29+: built into port 80, no separate port needed)
WEBSOCKET_ENABLED=true

# ── SMTP (optional — for password-reset and invite emails) ────────────────────
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SECURITY=starttls
SMTP_FROM=$SMTP_FROM
SMTP_USERNAME=$SMTP_USER
SMTP_PASSWORD=$SMTP_PASS
VW_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$VW_DIR"
    log_success "Vaultwarden configured at $VW_DIR"

    configure_caddy_for_service "Vaultwarden" "vaultwarden:80" "vault"

    write_readme "$VW_DIR" << MD
# Vaultwarden — Bitwarden-compatible password manager

Lightweight, self-hosted Bitwarden server. Works with all official
Bitwarden clients: browser extension, desktop app, and mobile app.

## Setup
1. Point your Bitwarden client to: $VW_DOMAIN
2. Create the first account (signups are off after the first user — use admin panel)
3. Admin panel: **$VW_DOMAIN/admin** (use ADMIN_TOKEN from .env)

## Admin panel
The admin panel lets you manage users, send invites, and configure settings.
URL: \`$VW_DOMAIN/admin\`
Token: see \`ADMIN_TOKEN\` in .env

**Security:** remove or rotate ADMIN_TOKEN after initial setup if you don't
need ongoing admin access.

## Inviting users (signups disabled)
Admin panel → Users → Invite User → enter email.
Requires SMTP to be configured for the invite email to arrive.

## Credentials
- Admin token: stored in .env (chmod 600)
- User vaults: encrypted in vaultwarden_data/

## Manage
\`\`\`bash
cd $VW_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_VW=""
    prompt_yn "Start Vaultwarden now? (y/n):" "y" START_VW
    if [ "$START_VW" = "y" ] || [ "$START_VW" = "Y" ]; then
        docker compose up -d \
            && log_success "Vaultwarden started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Domain:      $VW_DOMAIN"
    echo "  Admin panel: $VW_DOMAIN/admin"
    echo "  Admin token: $ADMIN_TOKEN"
    echo "  (Token also saved to $VW_DIR/.env)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_vaultwarden
