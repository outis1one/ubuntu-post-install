#!/bin/bash
# services/drum-rhythm-game.sh — Browser-based drum rhythm game (outis1one/drum-rhythm-game).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash drum-rhythm-game.sh
# (Docker must already be installed when run standalone)
#
# Serves a single self-contained index.html via nginx. No login — protect
# with Authelia via Caddy if you want access control.
# Source: https://github.com/outis1one/drum-rhythm-game

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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service drum-rhythm-game gaming "Browser-based drum rhythm game (outis1one/drum-rhythm-game)" 8096

install_drum-rhythm-game() {
    require_docker || return 1

    local DRUM_DIR="$DOCKER_DIR/drum-rhythm-game"
    local REPO_URL="https://github.com/outis1one/drum-rhythm-game.git"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] drum-rhythm-game would:"
        echo "  - Clone $REPO_URL to $DRUM_DIR/html"
        echo "  - Serve index.html via nginx on port 8096"
        echo "  - Offer Authelia SSO protection via Caddy (no built-in auth)"
        return 0
    fi

    mkdir -p "$DRUM_DIR"
    ensure_docker_dir_ownership "$DRUM_DIR"
    cd "$DRUM_DIR" || return 1

    # Clone or update the game source
    if [ -d "$DRUM_DIR/html/.git" ]; then
        log_info "Updating drum-rhythm-game source..."
        git -C "$DRUM_DIR/html" pull --ff-only 2>/dev/null \
            && log_success "Updated to latest" \
            || log_warning "Could not pull latest — using existing version"
    else
        log_info "Cloning drum-rhythm-game..."
        git clone --depth 1 "$REPO_URL" "$DRUM_DIR/html" \
            || { log_error "Clone failed — check network and git access"; return 1; }
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DRUM_DIR/html"

    cat > docker-compose.yml << 'DRUM_COMPOSE'
name: drum-rhythm-game

services:
  drum-rhythm-game:
    image: nginx:alpine
    container_name: drum-rhythm-game
    hostname: drum-rhythm-game
    restart: unless-stopped
    volumes:
      - ./html:/usr/share/nginx/html:ro
    ports:
      - "8096:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
DRUM_COMPOSE

    cat > .env << DRUM_ENV
CADDY_NET=${SITE_CADDY_NET}
DRUM_ENV

    ensure_docker_dir_ownership "$DRUM_DIR"
    log_success "drum-rhythm-game configured at $DRUM_DIR"

    # No built-in auth — offer Authelia SSO protection
    local DRUM_EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect drum-rhythm-game with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && DRUM_EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "Drum Rhythm Game" "drum-rhythm-game:80" "drums" "$DRUM_EXTRA_BLOCK"

    write_readme "$DRUM_DIR" << 'MD'
# Drum Rhythm Game

Browser-based drum rhythm game — 124 synthesized orchestra pieces across
18 genres, 120 drum patterns. Supports keyboard and USB drum controllers.
No server required; all audio synthesized in-browser via Web Audio API.

Source: https://github.com/outis1one/drum-rhythm-game

## Access
- URL: http://localhost:8096

## Manage
```bash
cd ~/docker/drum-rhythm-game
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
```

## Update game
```bash
cd ~/docker/drum-rhythm-game
git -C html pull
docker compose restart
```
MD

    local START_DRUM=""
    prompt_yn "Start drum-rhythm-game now? (y/n):" "y" START_DRUM
    if [ "$START_DRUM" = "y" ] || [ "$START_DRUM" = "Y" ]; then
        docker compose up -d \
            && log_success "Drum Rhythm Game started — http://localhost:8096" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  URL:         http://localhost:8096"
    echo "  Controls:    keyboard or USB drum controller"
    echo "  Update:      git -C $DRUM_DIR/html pull && docker compose -f $DRUM_DIR/docker-compose.yml restart"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_drum-rhythm-game
