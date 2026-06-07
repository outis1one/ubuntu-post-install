#!/bin/bash
# services/vaultwarden.sh — Vaultwarden (self-hosted Bitwarden server).
# Part of the modular post-install system (sourced by setup.sh).
#
# Vaultwarden is an unofficial, lightweight Bitwarden-compatible server.
# All official Bitwarden clients (browser extension, desktop, mobile) work with it.
# Requires HTTPS in production — set DOMAIN to your public URL.

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
