#!/bin/bash
# services/onlyoffice.sh — Self-hosted OnlyOffice Document Server.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash onlyoffice.sh
# (Docker must already be installed when run standalone)

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
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

        generate_password() {
            local len="${1:-32}"
            tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
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

register_service onlyoffice utilities "Self-hosted OnlyOffice Document Server (Nextcloud/FileBrowser)" 8082

# ── Ensure yq v4 is installed ─────────────────────────────────────────────────
_ensure_yq() {
    if command -v yq &>/dev/null; then
        local major
        major=$(yq --version 2>&1 | grep -oP '(?<=v)\d+' | head -1 || echo 0)
        [[ "$major" -ge 4 ]] && return 0
        log_info "yq found but version < 4 — reinstalling..."
    else
        log_info "yq not found — installing..."
    fi
    local arch
    arch=$(uname -m)
    local yq_bin="yq_linux_amd64"
    [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && yq_bin="yq_linux_arm64"
    if wget -qO /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/latest/download/${yq_bin}" \
        && chmod +x /usr/local/bin/yq; then
        log_success "yq installed ($(yq --version 2>&1 | head -1))"
    else
        log_warning "Could not install yq — FileBrowser config.yaml will need manual update"
        return 1
    fi
}

# ── Wire OnlyOffice into Nextcloud ────────────────────────────────────────────
_wire_nextcloud() {
    local jwt_secret="$1"
    local nc_dir="$DOCKER_DIR/nextcloud"

    [[ -d "$nc_dir" ]] || return 0

    log_info "Nextcloud detected — wiring OnlyOffice integration..."

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^nextcloud$"; then
        log_warning "Nextcloud container not running — skipping occ wiring."
        log_info "  Start Nextcloud and re-run: sudo bash $0"
        return 0
    fi

    docker exec --user www-data nextcloud php occ app:enable onlyoffice \
        && log_success "OnlyOffice app enabled in Nextcloud" \
        || log_warning "app:enable failed — may already be enabled"
    docker exec --user www-data nextcloud php occ \
        config:app:set onlyoffice DocumentServerUrl \
        --value "http://onlyoffice:80/" \
        && log_success "DocumentServerUrl → http://onlyoffice:80/" \
        || log_warning "Could not set DocumentServerUrl"
    docker exec --user www-data nextcloud php occ \
        config:app:set onlyoffice jwt_secret \
        --value "$jwt_secret" \
        && log_success "jwt_secret set" \
        || log_warning "Could not set jwt_secret"
    docker exec --user www-data nextcloud php occ \
        config:app:set onlyoffice jwt_header \
        --value "AuthorizationJwt" \
        && log_success "jwt_header set" \
        || log_warning "Could not set jwt_header"
}

# ── Wire OnlyOffice into FileBrowser Quantum ──────────────────────────────────
_wire_filebrowser() {
    local fb_config="$DOCKER_DIR/filebrowser/data/config.yaml"

    [[ -f "$fb_config" ]] || return 0

    log_info "FileBrowser Quantum detected — updating config.yaml..."

    if ! _ensure_yq; then
        log_info "Set officeServer manually in $fb_config:"
        log_info "  officeServer: \"http://onlyoffice:80/\""
        return 0
    fi

    yq e -i '.officeServer = "http://onlyoffice:80/"' "$fb_config" \
        && log_success "FileBrowser config.yaml: officeServer → http://onlyoffice:80/" \
        || log_warning "yq failed — set officeServer manually in $fb_config"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^filebrowser$"; then
        docker restart filebrowser >/dev/null 2>&1 \
            && log_info "FileBrowser restarted to pick up config change" \
            || log_warning "Could not restart FileBrowser container"
    fi
}

install_onlyoffice() {
    require_docker || return 1
    log_info "Installing OnlyOffice Document Server..."

    local DIR="$DOCKER_DIR/onlyoffice"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml and .env"
        echo "[DRY-RUN] Would deploy onlyoffice/documentserver:latest on port 8082"
        echo "[DRY-RUN] Would install yq if missing"
        echo "[DRY-RUN] Would wire OnlyOffice into Nextcloud (if running)"
        echo "[DRY-RUN] Would wire OnlyOffice into FileBrowser Quantum (if present)"
        return 0
    fi

    # Always install yq — needed for FBQ config patching
    _ensure_yq || true

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # Generate JWT secret (or read existing one so re-runs don't rotate it)
    local JWT_SECRET=""
    if [[ -f "$DIR/.env" ]]; then
        JWT_SECRET=$(grep "^JWT_SECRET=" "$DIR/.env" 2>/dev/null | cut -d= -f2-)
    fi
    [[ -z "$JWT_SECRET" ]] && JWT_SECRET="$(generate_password 32)"

    cat > docker-compose.yml << 'OO_COMPOSE'
name: onlyoffice

services:
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    hostname: onlyoffice
    restart: unless-stopped
    env_file: .env
    ports:
      - "8082:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
OO_COMPOSE

    cat > .env << OO_ENV
# OnlyOffice Document Server — environment
CADDY_NET=$SITE_CADDY_NET

# JWT authentication — keep JWT_SECRET private
# If you rotate it, update Nextcloud (occ config:app:set onlyoffice jwt_secret)
# and any other integration that uses this server
JWT_ENABLED=true
JWT_SECRET=$JWT_SECRET
JWT_HEADER=AuthorizationJwt
OO_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    configure_caddy_for_service "OnlyOffice" "onlyoffice:80" "office"

    local START=""
    prompt_yn "Start OnlyOffice now? (y/n):" "y" START
    if [[ "$START" =~ ^[Yy]$ ]]; then
        docker compose up -d \
            && log_success "OnlyOffice started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # Wire into integrations every run (idempotent)
    echo ""
    _wire_nextcloud "$JWT_SECRET"
    _wire_filebrowser

    write_readme "$DIR" << MD
# OnlyOffice Document Server

Self-hosted collaborative editing for DOCX, XLSX, PPTX, and ODT files.
Integrates with Nextcloud and FileBrowser Quantum.
Port: 8082 (internal 80)

## JWT Secret
Stored in \`.env\` (chmod 600). If you rotate it:
1. Update \`JWT_SECRET\` in \`.env\`
2. Re-run the installer to re-wire all integrations:  \`sudo bash services/onlyoffice.sh\`

## Verify integrations
\`\`\`bash
# Nextcloud
docker exec --user www-data nextcloud php occ config:app:get onlyoffice DocumentServerUrl
docker exec --user www-data nextcloud php occ config:app:get onlyoffice jwt_secret

# FileBrowser Quantum
grep officeServer ~/docker/filebrowser/data/config.yaml
\`\`\`

## Manage
\`\`\`bash
cd $DIR
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f                        # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    log_success "OnlyOffice installed at $DIR"
    echo ""
    echo "  Port:       http://localhost:8082"
    echo "  JWT Secret: $JWT_SECRET"
    echo "  (Secret also saved to $DIR/.env)"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_onlyoffice
