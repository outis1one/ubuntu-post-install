#!/bin/bash
# services/filebrowser.sh — FileBrowser Quantum web-based file manager.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash filebrowser.sh
# (Docker must already be installed when run standalone)

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

register_service filebrowser utilities "Web file manager (FileBrowser Quantum)" 8085

install_filebrowser() {
    require_docker || return 1
    log_info "Installing FileBrowser Quantum..."

    local FB_DIR="$DOCKER_DIR/filebrowser"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $FB_DIR"
        echo "[DRY-RUN] Would write docker-compose.yml and data/config.yaml"
        return 0
    fi

    mkdir -p "$FB_DIR/data"
    ensure_docker_dir_ownership "$FB_DIR"
    cd "$FB_DIR" || return 1

    local FB_PATH=""
    prompt_text "Primary files directory to browse [default: $ACTUAL_HOME]:" "$ACTUAL_HOME" FB_PATH

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

    cat > docker-compose.yml << FB_COMPOSE
name: filebrowser

services:
  filebrowser:
    image: gtstef/filebrowser:stable
    container_name: filebrowser
    hostname: filebrowser
    restart: unless-stopped
    environment:
      - TZ=${SITE_TZ:-UTC}
    volumes:
      - ./data:/home/filebrowser/data
      - ${FB_PATH}:/files
    ports:
      - "8085:80"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
FB_COMPOSE

    cat > .env << FB_ENV
CADDY_NET=$SITE_CADDY_NET
FB_ENV

    # Generate config.yaml — Quantum reads this from /home/filebrowser/data/
    cat > data/config.yaml << FB_CONFIG
server:
  sources:
    - path: "/files"
      name: "files"
      config:
        defaultEnabled: true

auth:
  adminUsername: admin
  adminPassword: admin

userDefaults:
  account:
    permissions:
      admin: false
      modify: false
      share: true
      download: true
      create: false
      delete: false
FB_CONFIG

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR"

    # Deploy fbq-add-source.sh helper
    local _TOOLS_DIR
    _TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" 2>/dev/null && pwd)" || true
    if [ -f "$_TOOLS_DIR/fbq-add-source.sh" ]; then
        cp "$_TOOLS_DIR/fbq-add-source.sh" "$FB_DIR/fbq-add-source.sh"
        chmod 750 "$FB_DIR/fbq-add-source.sh"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR/fbq-add-source.sh"
        log_success "fbq-add-source.sh installed at $FB_DIR/fbq-add-source.sh"
    fi

    echo ""
    log_success "FileBrowser Quantum configured at $FB_DIR"

    configure_caddy_for_service "FileBrowser" "filebrowser:80" "files"

    write_readme "$FB_DIR" << MD
# FileBrowser Quantum

Web-based file manager with multi-source support, office preview, and
per-user access control.

## Access
- URL: http://localhost:8085
- Default login: admin / admin (change immediately!)

## Adding sources (extra directories)
Run the included helper to add directories and wire them into both
docker-compose.yml and config.yaml:
\`\`\`
sudo bash $FB_DIR/fbq-add-source.sh
\`\`\`
Then assign the new source to users: Settings → Users → edit user → Add source.

## Data
- Primary path: $FB_PATH (mounted to /files inside container)
- Config + database: ./data/
- Add more mounts via fbq-add-source.sh — no manual YAML editing needed

## Manage
\`\`\`
cd $FB_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose down && docker compose up -d  # update
\`\`\`
MD

    local START_FB=""
    prompt_yn "Start FileBrowser Quantum now? (y/n):" "y" START_FB
    if [ "$START_FB" = "y" ] || [ "$START_FB" = "Y" ]; then
        docker compose up -d 2>/dev/null \
            && log_success "FileBrowser Quantum started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:8085"
    echo "  Default login: admin / admin (change immediately!)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_filebrowser
