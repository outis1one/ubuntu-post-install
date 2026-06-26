#!/bin/bash
# services/stirling-pdf.sh — PDF toolkit — merge, split, compress, OCR (Stirling PDF).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash stirling-pdf.sh
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service stirling-pdf utilities "PDF toolkit — merge, split, compress, OCR (Stirling PDF)" 8070

install_stirling-pdf() {
    require_docker || return 1
    log_info "Installing Stirling PDF..."

    local PDF_DIR="$DOCKER_DIR/stirling-pdf"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $PDF_DIR"
        echo "[DRY-RUN] Would write docker-compose.yml and .env"
        return 0
    fi

    mkdir -p "$PDF_DIR"
    ensure_docker_dir_ownership "$PDF_DIR"
    cd "$PDF_DIR" || return 1

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

    cat > docker-compose.yml << PDF_COMPOSE
name: stirling-pdf

services:
  stirling-pdf:
    image: frooodle/s-pdf:latest
    container_name: stirling-pdf
    hostname: stirling-pdf
    restart: unless-stopped
    env_file: .env
    ports:
      - "8070:8080"
    volumes:
      - ./training-data:/usr/share/tessdata
      - ./extraConfigs:/configs
      - ./logs:/logs
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
PDF_COMPOSE

    cat > .env << PDF_ENV
# Stirling PDF configuration

# Set to true to enable login/user management (requires restart)
DOCKER_ENABLE_SECURITY=false

# Set to true to install LibreOffice for advanced HTML/book conversion ops
INSTALL_BOOK_AND_ADVANCED_HTML_OPS=false

# Caddy network
CADDY_NET=${SITE_CADDY_NET}
PDF_ENV

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$PDF_DIR"

    echo ""
    log_success "Stirling PDF configured at $PDF_DIR"
    log_info "Security/login is disabled by default (DOCKER_ENABLE_SECURITY=false)."
    log_info "To enable built-in auth, set DOCKER_ENABLE_SECURITY=true in .env and restart."

    # No built-in auth by default — offer Authelia SSO protection
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Stirling PDF with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
    fi

    configure_caddy_for_service "Stirling PDF" "stirling-pdf:8080" "pdf" "$EXTRA_BLOCK"

    write_readme "$PDF_DIR" << MD
# Stirling PDF

Feature-rich PDF toolkit: merge, split, compress, rotate, OCR, convert, and more.

## Access
- URL: http://localhost:8070
- No login required by default (security disabled)

## Enabling built-in auth
Set \`DOCKER_ENABLE_SECURITY=true\` in \`.env\`, then restart:
\`\`\`bash
cd $PDF_DIR
docker compose down && docker compose up -d
\`\`\`

## OCR / Tesseract
Additional Tesseract language packs can be placed in \`./training-data/\`.
See: https://github.com/Frooodle/Stirling-PDF#ocr

## Manage
\`\`\`bash
cd $PDF_DIR
docker compose up -d                                        # start
docker compose down                                         # stop
docker compose logs -f                                      # logs
docker compose pull && docker compose down && docker compose up -d  # update
\`\`\`

## Files
- docker-compose.yml  — stack definition
- .env                — configuration flags
- training-data/      — Tesseract OCR language data
- extraConfigs/       — optional extra config files
- logs/               — application logs
MD

    local START_PDF=""
    prompt_yn "Start Stirling PDF now? (y/n):" "y" START_PDF
    if [ "$START_PDF" = "y" ] || [ "$START_PDF" = "Y" ]; then
        docker compose up -d 2>/dev/null \
            && log_success "Stirling PDF started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:8070"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_stirling-pdf
