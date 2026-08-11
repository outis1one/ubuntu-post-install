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

register_service vaultwarden utilities "Bitwarden-compatible password manager (Vaultwarden)" 80

# Vaultwarden refuses to start at all — crash-loops — if exactly one of
# SMTP_HOST/SMTP_FROM is set in .env ("Both SMTP_HOST and SMTP_FROM need to
# be set for email support without USE_SENDMAIL"). The fresh-install prompt
# flow below never writes that half-state, but "update" mode deliberately
# never touches .env (same non-destructive-update rule as everywhere else
# in this repo), so a box whose .env was written before that prompt-side
# fix existed — or hand-edited since — stays stuck crash-looping forever,
# on every future update too, since nothing ever re-checks it. Confirmed
# live. Called right before every `docker compose up` this file does, not
# just at install time, so it self-heals regardless of how the box got into
# this state.
_vaultwarden_fix_smtp_halfstate() {
    local env_file="$1"
    [ -f "$env_file" ] || return 0
    local host from
    host="$(grep '^SMTP_HOST=' "$env_file" 2>/dev/null | cut -d= -f2-)"
    from="$(grep '^SMTP_FROM=' "$env_file" 2>/dev/null | cut -d= -f2-)"
    if { [ -n "$host" ] && [ -z "$from" ]; } || { [ -z "$host" ] && [ -n "$from" ]; }; then
        log_warning "SMTP_HOST/SMTP_FROM in $env_file are half-set (Vaultwarden requires both or neither) — disabling SMTP so the container can actually start. Edit $env_file (or run a fresh reinstall) to set up email properly."
        sed -i -E 's/^SMTP_HOST=.*/SMTP_HOST=/; s/^SMTP_FROM=.*/SMTP_FROM=/; s/^SMTP_PORT=.*/SMTP_PORT=/; s/^SMTP_SECURITY=.*/SMTP_SECURITY=/; s/^SMTP_USERNAME=.*/SMTP_USERNAME=/; s/^SMTP_PASSWORD=.*/SMTP_PASSWORD=/' "$env_file"
    fi
}

install_vaultwarden() {
    require_docker || return 1
    log_info "Installing Vaultwarden..."

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "vaultwarden" name/paths/port exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces suffixed naming — same pattern as
    # services/mattermost.sh and services/wordpress.sh. A real use case:
    # separate personal and family/household vaults with independent admin
    # tokens, domains, and SMTP.
    local VW_DIR="$DOCKER_DIR/vaultwarden"
    local INSTANCE_SUFFIX="" CONTAINER="vaultwarden"
    local WEB_PORT="8888"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would offer to add a new, separate instance if one already exists"
        echo "[DRY-RUN] Would create $VW_DIR(-<name>) (vaultwarden_data/)"
        echo "[DRY-RUN] Would deploy vaultwarden/server:latest"
        echo "[DRY-RUN] Would generate admin token and prompt for domain"
        echo "[DRY-RUN] Would auto-scan for a free host port if this is an additional instance"
        echo "[DRY-RUN] Signups disabled by default (enable via admin panel)"
        return 0
    fi

    if [ -d "$VW_DIR" ]; then
        echo ""
        echo "  Vaultwarden is already installed at $VW_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Vaultwarden instance alongside it (its own"
        echo "       server, vault, and port — full isolation)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'family'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/vaultwarden-$_suffix" ]; then
                    log_warning "vaultwarden-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            VW_DIR="$DOCKER_DIR/vaultwarden-$_suffix"
            CONTAINER="vaultwarden-$_suffix"
            log_info "New instance: $VW_DIR"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$VW_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the Vaultwarden image only — existing config, port, and Caddy setup are left as-is."
                        _vaultwarden_fix_smtp_halfstate "$VW_DIR/.env"
                        ( cd "$VW_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "Vaultwarden image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $VW_DIR/docker-compose.yml logs"
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

    # Scan for a free port unconditionally — not just when adding an explicit
    # additional instance. A plain first install can just as easily collide
    # with an unrelated service that already claimed this default port — see
    # CLAUDE.md's "Port collision avoidance" section.
    find_free_port WEB_PORT "$WEB_PORT"

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
    local DEFAULT_DOMAIN="https://vault${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}.${SITE_DOMAIN:-example.com}"
    prompt_text "Vaultwarden public URL (e.g. https://vault.example.com):" "$DEFAULT_DOMAIN" VW_DOMAIN
    [ -z "$VW_DOMAIN" ] && VW_DOMAIN="$DEFAULT_DOMAIN"

    echo ""
    echo "  SMTP (optional) — for password-reset and invite emails."
    echo "  Press Enter to skip each field and configure SMTP later in .env."
    echo ""
    # Every SMTP_* value (including PORT/SECURITY) stays genuinely empty
    # unless SMTP_HOST is actually provided — confirmed live, this used to
    # default SMTP_PORT to "587" and hardcode SMTP_SECURITY=starttls in the
    # .env template unconditionally, so even a fully-skipped SMTP setup
    # (SMTP_HOST left blank) still wrote real, non-empty values for those
    # two. Vaultwarden reads that as "some SMTP config is present" and
    # refuses to start ("Both SMTP_HOST and SMTP_FROM need to be set"),
    # crash-looping even though the actual host/from fields were blank —
    # the "skip SMTP" path was never actually clean.
    local SMTP_HOST="" SMTP_FROM="" SMTP_USER="" SMTP_PASS="" SMTP_PORT="" SMTP_SECURITY=""
    prompt_text "SMTP host (e.g. smtp.gmail.com) [skip]:" "" SMTP_HOST
    if [ -n "$SMTP_HOST" ]; then
        prompt_text "SMTP port [587]:" "587" SMTP_PORT
        prompt_text "SMTP from address:" "" SMTP_FROM
        prompt_text "SMTP username:" "" SMTP_USER
        prompt_text "SMTP password:" "" SMTP_PASS
        SMTP_SECURITY=starttls
        # Vaultwarden refuses to start at all if SMTP_HOST is set without
        # SMTP_FROM ("Both SMTP_HOST and SMTP_FROM need to be set") —
        # confirmed live, crash-loops on every start, not just a warning at
        # runtime. SMTP_FROM's own prompt has no default, so leaving it
        # blank here writes exactly that broken half-state. Disable SMTP
        # entirely rather than let it reach a config known to crash the
        # container — better than guessing a from-address on your behalf.
        if [ -z "$SMTP_FROM" ]; then
            log_warning "No SMTP from address entered — disabling SMTP entirely (Vaultwarden requires both or neither). Re-run this installer to set it up later."
            SMTP_HOST=""; SMTP_PORT=""; SMTP_SECURITY=""; SMTP_USER=""; SMTP_PASS=""
        fi
    fi

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

    cat > docker-compose.yml << VW_COMPOSE
name: $CONTAINER

services:
  vaultwarden:
    image: vaultwarden/server:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./vaultwarden_data:/data
    ports:
      - "${WEB_PORT}:80"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
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


# ── SMTP (optional — for password-reset and invite emails) ────────────────────
SMTP_HOST=$SMTP_HOST
SMTP_PORT=$SMTP_PORT
SMTP_SECURITY=$SMTP_SECURITY
SMTP_FROM=$SMTP_FROM
SMTP_USERNAME=$SMTP_USER
SMTP_PASSWORD=$SMTP_PASS
VW_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$VW_DIR"
    log_success "Vaultwarden${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $VW_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Vaultwarden${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:80" "vault${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    write_readme "$VW_DIR" << MD
# Vaultwarden${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX} — Bitwarden-compatible password manager

Lightweight, self-hosted Bitwarden server. Works with all official
Bitwarden clients: browser extension, desktop app, and mobile app.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own vault, own
port) — not shared credentials with another Vaultwarden instance.")

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
    prompt_yn "Start Vaultwarden${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_VW
    if [ "$START_VW" = "y" ] || [ "$START_VW" = "Y" ]; then
        _vaultwarden_fix_smtp_halfstate "$VW_DIR/.env"
        docker compose up -d \
            && log_success "Vaultwarden${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" \
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
