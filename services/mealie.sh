#!/bin/bash
# services/mealie.sh — Recipe manager & meal planner (Mealie).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash mealie.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MEALIE ----).
# Own ~/docker/mealie/ with a standalone docker-compose.yml.

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

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service mealie utilities "Recipe manager & meal planner (Mealie)" 9925

# Offers to add "Sign in with Authelia" (OpenID Connect) to Mealie's own
# login page — same additive pattern as services/gitea.sh's
# _gitea_offer_authelia_sso (local login keeps working unchanged), but
# Mealie's OIDC support is entirely environment-variable driven — no CLI
# equivalent to Gitea's `admin auth add-oauth` needed. Confirmed against
# Mealie's own OIDC docs: OIDC_AUTH_ENABLED, OIDC_CLIENT_ID,
# OIDC_CLIENT_SECRET, OIDC_CONFIGURATION_URL, OIDC_SIGNUP_ENABLED, appended
# straight into the .env file this installer already writes and reads via
# `env_file: .env` — no docker-compose.yml regeneration needed for that part.
#
# Reads BASE_URL back from the existing .env rather than taking it as an
# arg, so this works identically whether called right after a fresh
# install (where the URL was just computed) or from an Update rerun
# (where it wasn't recomputed this run, but is already on disk).
#
# Args: DIR CONTAINER
_mealie_offer_authelia_oidc() {
    local DIR="$1" CONTAINER="$2"

    [ -d "$DOCKER_DIR/authelia" ] || return 0
    declare -F _authelia_provision_oidc_client >/dev/null 2>&1 || return 0
    grep -q '^OIDC_AUTH_ENABLED=' "$DIR/.env" 2>/dev/null && return 0

    local BASE_URL
    BASE_URL="$(grep '^BASE_URL=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
    if [ -z "$BASE_URL" ]; then
        log_warning "Couldn't find BASE_URL in $DIR/.env — skipping Authelia SSO offer for Mealie."
        return 0
    fi

    echo ""
    local USE_SSO=""
    prompt_yn "  Add \"Sign in with Authelia\" (OpenID Connect) to Mealie's login page? (y/n):" "n" USE_SSO
    [[ "$USE_SSO" =~ ^[Yy]$ ]] || return 0

    local _2fa="" AUTH_POLICY="two_factor"
    prompt_yn "  Require two-factor for Mealie logins via Authelia too? (y/n):" "y" _2fa
    [[ "$_2fa" =~ ^[Yy]$ ]] || AUTH_POLICY="one_factor"

    if ! _authelia_provision_oidc_client "Mealie" "mealie" "$AUTH_POLICY" "y" "${BASE_URL}/login"; then
        log_warning "Couldn't register Mealie as an OIDC client in Authelia — skipping SSO setup."
        return 0
    fi

    local _discovery_url="https://auth.${OIDC_AUTHELIA_DOMAIN}/.well-known/openid-configuration"
    cat >> "$DIR/.env" << ENV

# Written by services/mealie.sh's Authelia SSO step — adds "Sign in with
# Authelia" alongside local login; local accounts keep working unchanged.
OIDC_AUTH_ENABLED=true
OIDC_SIGNUP_ENABLED=true
OIDC_CLIENT_ID=mealie
OIDC_CLIENT_SECRET=$OIDC_CLIENT_SECRET_PLAIN
OIDC_CONFIGURATION_URL=$_discovery_url
OIDC_PROVIDER_NAME=Authelia
ENV
    chown "$ACTUAL_USER:$ACTUAL_USER" "$DIR/.env" 2>/dev/null || true

    # Mealie's OIDC redirect URI generation trusts X-Forwarded-* only from
    # explicitly allowed IPs — without this, a Caddy-fronted instance
    # generates an http:// redirect URI even when actually served over
    # https://, which Authelia/any OIDC provider rejects as a scheme
    # mismatch. Confirmed against Mealie's own reverse-proxy docs/issue
    # tracker. Only needed (and only added) when Caddy is actually
    # fronting this instance — BASE_URL itself tells us that (it's only
    # ever https:// when a real domain + Caddy were configured).
    if [[ "$BASE_URL" == https://* ]] && ! grep -q '^    entrypoint:' "$DIR/docker-compose.yml"; then
        sed -i "/container_name: ${CONTAINER}\$/a\\    entrypoint: [\"uvicorn\", \"mealie.app:app\", \"--host\", \"0.0.0.0\", \"--port\", \"9000\", \"--forwarded-allow-ips=*\"]" "$DIR/docker-compose.yml"
    fi

    (cd "$DIR" && docker compose up -d) \
        && log_success "\"Sign in with Authelia\" added to Mealie — local login still works too." \
        || log_warning "Restart failed — check: docker compose -f $DIR/docker-compose.yml logs"

    declare -F _authelia_scope_access >/dev/null 2>&1 && _authelia_scope_access "mealie" "${BASE_URL#*://}"
}

install_mealie() {
    require_docker || return 1

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "mealie" name/paths/port exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces suffixed naming — same pattern as
    # services/mattermost.sh and services/wordpress.sh.
    local MEALIE_DIR="$DOCKER_DIR/mealie"
    local INSTANCE_SUFFIX="" CONTAINER="mealie"
    local WEB_PORT="9925"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Mealie would:"
        echo "  - Offer to add a new, separate instance if one already exists"
        echo "  - Create \$DOCKER_DIR/mealie(-<name>) with docker-compose.yml (data/)"
        echo "  - Auto-scan for a free host port if this is an additional instance"
        echo "  - Default login: changeme@email.com / MyPassword (change immediately)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        echo "  - Offer \"Sign in with Authelia\" (OIDC) if Authelia is installed"
        return 0
    fi

    if [ -d "$MEALIE_DIR" ]; then
        echo ""
        echo "  Mealie is already installed at $MEALIE_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Mealie instance alongside it (its own"
        echo "       server, recipes, and port — full isolation)"
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
                if [ -d "$DOCKER_DIR/mealie-$_suffix" ]; then
                    log_warning "mealie-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            MEALIE_DIR="$DOCKER_DIR/mealie-$_suffix"
            CONTAINER="mealie-$_suffix"
            log_info "New instance: $MEALIE_DIR"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$MEALIE_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the Mealie image only — existing config, port, and Caddy setup are left as-is."
                        ( cd "$MEALIE_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "Mealie image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $MEALIE_DIR/docker-compose.yml logs"
                        declare -F _mealie_offer_authelia_oidc >/dev/null 2>&1 && _mealie_offer_authelia_oidc "$MEALIE_DIR" "$CONTAINER"
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

    mkdir -p "$MEALIE_DIR"
    ensure_docker_dir_ownership "$MEALIE_DIR"
    cd "$MEALIE_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    # BASE_URL must match the public URL Mealie is served on (used for email links,
    # OAuth redirects, and the web app manifest). Default to SITE_DOMAIN if set.
    local MEALIE_BASE_URL="http://localhost:${WEB_PORT}"
    if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        MEALIE_BASE_URL="https://recipes${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}.${SITE_DOMAIN}"
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

    cat > docker-compose.yml << MEALIE_COMPOSE
name: $CONTAINER

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    env_file: .env
    environment:
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
      - ALLOW_SIGNUP=true
      - MAX_WORKERS=1
      - WEB_CONCURRENCY=1
    volumes:
      - ./data:/app/data
    ports:
      - "${WEB_PORT}:9000"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
MEALIE_COMPOSE

    cat > .env << MEALIE_ENV
# Public URL Mealie is served on — used for email links and OAuth redirects.
# Update if you change your domain or switch from HTTP to HTTPS.
BASE_URL=$MEALIE_BASE_URL
CADDY_NET=$SITE_CADDY_NET
MEALIE_ENV

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MEALIE_DIR"
    log_success "Mealie${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $MEALIE_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Mealie${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:9000" "recipes${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    declare -F _mealie_offer_authelia_oidc >/dev/null 2>&1 && _mealie_offer_authelia_oidc "$MEALIE_DIR" "$CONTAINER"

    write_readme "$MEALIE_DIR" << MD
# Mealie${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Recipe manager and meal planner — import recipes from any URL, plan meals,
and generate shopping lists. Optional AI-powered recipe parsing.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own recipes, own
port) — not shared recipes with another Mealie instance.")

- Web UI: http://localhost:${WEB_PORT}
- Default login: changeme@email.com / MyPassword (change immediately!)
- App data: \`data/\`

## Manage
\`\`\`bash
cd $MEALIE_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- If using Caddy, update \`BASE_URL\` in \`docker-compose.yml\` to your domain.
MD

    local START_MEALIE=""
    prompt_yn "Start Mealie${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_MEALIE
    if [ "$START_MEALIE" = "y" ] || [ "$START_MEALIE" = "Y" ]; then
        docker compose up -d && log_success "Mealie${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo "  Default:    changeme@email.com / MyPassword  (change immediately!)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mealie
