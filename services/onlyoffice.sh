#!/bin/bash
# services/onlyoffice.sh — Self-hosted OnlyOffice Document Server (Nextcloud/FileBrowser).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash onlyoffice.sh
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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
        }

        write_readme() {
            local _dir="$1"; shift
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
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

            # Support remote Caddy host via CADDY_REMOTE_HOST
            if [[ -n "${CADDY_REMOTE_HOST:-}" ]]; then
                log_info "Remote Caddy detected at $CADDY_REMOTE_HOST — printing block to add manually."
                echo ""
                echo "  Add the following to your Caddyfile on $CADDY_REMOTE_HOST:"
                echo "  ──────────────────────────────────────────────────────────"
                echo "  # $_name"
                echo "  ${_subdomain}.${SITE_DOMAIN:-example.com} {"
                echo "      reverse_proxy $_upstream"
                [[ -n "$_extra" ]] && echo "$_extra"
                echo "  }"
                echo "  ──────────────────────────────────────────────────────────"
                return 0
            fi

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

register_service onlyoffice utilities "Self-hosted OnlyOffice Document Server (Nextcloud/FileBrowser)" 8082

# ── Helper: install yq v4 if absent ──────────────────────────────────────────
_ensure_yq() {
    command -v yq &>/dev/null && return 0
    log_info "Installing yq (required for FileBrowser config patching)..."
    local _arch; _arch=$(uname -m)
    local _binary="yq_linux_amd64"
    [[ "$_arch" == "aarch64" || "$_arch" == "arm64" ]] && _binary="yq_linux_arm64"
    curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/${_binary}" \
        -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq \
        && log_success "yq installed" || log_warning "yq install failed — FileBrowser wiring skipped"
}

# ── Helper: wire OnlyOffice into Nextcloud (idempotent) ───────────────────────
_wire_nextcloud() {
    local _jwt="$1"
    local _nc_container="nextcloud"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${_nc_container}$" || {
        log_info "Nextcloud container not running — skipping Nextcloud wiring"
        return 0
    }
    log_info "Wiring OnlyOffice into Nextcloud..."
    docker exec "$_nc_container" php occ app:enable onlyoffice 2>/dev/null || true
    docker exec "$_nc_container" php occ config:system:set onlyoffice DocumentServerUrl \
        --value="https://office.${SITE_DOMAIN:-example.com}/" 2>/dev/null \
        && log_success "DocumentServerUrl set" || log_warning "Could not set DocumentServerUrl"
    docker exec "$_nc_container" php occ config:system:set onlyoffice jwt_secret \
        --value="$_jwt" 2>/dev/null \
        && log_success "jwt_secret set" || log_warning "Could not set jwt_secret"
    docker exec "$_nc_container" php occ config:system:set onlyoffice jwt_header \
        --value="AuthorizationJwt" 2>/dev/null \
        && log_success "jwt_header set" || log_warning "Could not set jwt_header"
}

# ── Helper: patch FileBrowser Quantum config.yaml with OnlyOffice endpoint ───
_wire_filebrowser() {
    local _fbq_config="$DOCKER_DIR/filebrowser/config.yaml"
    [[ -f "$_fbq_config" ]] || { log_info "FileBrowser config not found — skipping"; return 0; }
    command -v yq &>/dev/null || { log_info "yq not found — skipping FileBrowser wiring"; return 0; }
    log_info "Wiring OnlyOffice into FileBrowser Quantum..."
    yq e '.officeServer = "http://onlyoffice:80/"' -i "$_fbq_config" \
        && log_success "FileBrowser officeServer set" || log_warning "Could not patch FileBrowser config"
    docker restart filebrowser 2>/dev/null && log_success "FileBrowser restarted" || true
}

install_onlyoffice() {
    require_docker || return 1
    _ensure_yq

    log_info "Installing OnlyOffice Document Server..."
    local DIR="$DOCKER_DIR/onlyoffice"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml, .env"
        return 0
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # ── Preserve JWT secret across re-runs ──────────────────────────────────
    local JWT_SECRET=""
    if [[ -f "$DIR/.env" ]]; then
        JWT_SECRET=$(grep "^JWT_SECRET=" "$DIR/.env" 2>/dev/null | cut -d= -f2-)
    fi
    [[ -z "$JWT_SECRET" ]] && JWT_SECRET="$(generate_password 32)"

    # ── docker-compose.yml ──────────────────────────────────────────────────
    cat > docker-compose.yml << 'OOCOMPOSE'
name: onlyoffice
services:
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    hostname: onlyoffice
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./logs:/var/log/onlyoffice
      - ./data:/var/www/onlyoffice/Data
      - ./fonts:/usr/share/fonts/truetype/custom
    ports:
      - "8082:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
OOCOMPOSE

    # ── .env ────────────────────────────────────────────────────────────────
    cat > .env << OOENV
CADDY_NET=$SITE_CADDY_NET
# JWT authentication — keep JWT_SECRET private
JWT_ENABLED=true
JWT_SECRET=$JWT_SECRET
JWT_HEADER=AuthorizationJwt
OOENV
    chmod 600 .env

    # ── Subdirectories ──────────────────────────────────────────────────────
    mkdir -p logs data fonts
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    echo ""
    log_success "OnlyOffice configured at $DIR"

    # OnlyOffice must be embeddable as an iframe (Nextcloud / FileBrowser open
    # documents in a frame). Override the default X-Frame-Options header that
    # Caddy would otherwise set to SAMEORIGIN.
    local OO_EXTRA_BLOCK='    header {
        -X-Frame-Options
        Content-Security-Policy "frame-ancestors '\''self'\'' *"
    }'
    configure_caddy_for_service "OnlyOffice" "onlyoffice:80" "office" "$OO_EXTRA_BLOCK"

    # ── Prompt to start ─────────────────────────────────────────────────────
    local START_OO=""
    prompt_yn "Start OnlyOffice now? (y/n):" "y" START_OO
    if [ "$START_OO" = "y" ] || [ "$START_OO" = "Y" ]; then
        docker compose up -d \
            && log_success "OnlyOffice started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Wire integrations (runs every install/re-install) ───────────────────
    echo ""
    _wire_nextcloud "$JWT_SECRET"
    _wire_filebrowser

    # ── README ───────────────────────────────────────────────────────────────
    write_readme "$DIR" << OOREAD
# OnlyOffice Document Server

Self-hosted document editing server, integrated with Nextcloud and FileBrowser Quantum.

## Access

- URL: https://office.${SITE_DOMAIN:-example.com}  (or http://localhost:8082)
- The document server itself has no user-facing login page — it is accessed
  through Nextcloud or FileBrowser Quantum.

## Manage

\`\`\`bash
docker compose up -d    # start
docker compose down     # stop
docker compose logs -f  # follow logs
docker compose pull && docker compose up -d   # update
\`\`\`

## JWT secret rotation

1. Generate a new secret:
   \`\`\`bash
   openssl rand -hex 24
   \`\`\`
2. Update \`JWT_SECRET\` in \`$DIR/.env\`
3. Restart OnlyOffice:
   \`\`\`bash
   docker compose restart
   \`\`\`
4. Update Nextcloud's stored secret:
   \`\`\`bash
   docker exec nextcloud php occ config:system:set onlyoffice jwt_secret --value="<new-secret>"
   \`\`\`

## Verify Nextcloud integration

\`\`\`bash
docker exec nextcloud php occ config:system:get onlyoffice
\`\`\`

## Verify FileBrowser integration

\`\`\`bash
grep officeServer $DOCKER_DIR/filebrowser/config.yaml
\`\`\`

## Add custom fonts

Copy \`.ttf\` / \`.otf\` font files into \`$DIR/fonts/\`, then restart the container.
OOREAD

    echo ""
    echo "  OnlyOffice Document Server"
    echo "  Access URL:   http://localhost:8082"
    echo "  JWT secret:   $JWT_SECRET"
    echo "  Config dir:   $DIR"
    echo ""
    echo "  Integration status:"
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^nextcloud$" \
        && echo "    Nextcloud:     wired (onlyoffice app + JWT configured)" \
        || echo "    Nextcloud:     not running — wire manually after starting Nextcloud"
    [[ -f "$DOCKER_DIR/filebrowser/config.yaml" ]] \
        && echo "    FileBrowser:   config.yaml patched" \
        || echo "    FileBrowser:   config not found — will wire on next onlyoffice install"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_onlyoffice
