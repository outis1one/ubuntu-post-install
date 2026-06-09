#!/bin/bash
# services/magicmirror.sh — Modular smart mirror / info dashboard (MagicMirror²).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash magicmirror.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MAGIC MIRROR ----).
# Supports 1-3 instances (ports 8081-8083) each in ~/docker/magicmirror/<N>/.
# If you provide an existing config.js, third-party MMM-* modules are detected
# and cloned from GitHub automatically.

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

register_service magicmirror utilities "Modular smart mirror / info dashboard (MagicMirror²)" 8081

install_magicmirror() {
    require_docker || return 1

    local MM_BASE="$DOCKER_DIR/magicmirror"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] MagicMirror would:"
        echo "  - Ask how many instances (1-3, ports 8081-8083)"
        echo "  - Create $MM_BASE/<N>/ for each instance"
        echo "  - Optionally copy your existing config.js + clone MMM-* modules"
        echo "  - Offer a Caddy reverse proxy (first instance) and to start"
        return 0
    fi

    # Number of instances
    local MM_COUNT=""
    prompt_text "How many MagicMirror instances? [1-3, default: 1]:" "1" MM_COUNT
    MM_COUNT="${MM_COUNT:-1}"
    [ "$MM_COUNT" -gt 3 ] 2>/dev/null && MM_COUNT=3
    [ "$MM_COUNT" -lt 1 ] 2>/dev/null && MM_COUNT=1

    mkdir -p "$MM_BASE"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$MM_BASE"

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    local i MM_PORT MM_DIR

    for i in $(seq 1 "$MM_COUNT"); do
        MM_PORT=$((8080 + i))
        MM_DIR="$MM_BASE/$i"

        echo ""
        echo "── Instance $i (port $MM_PORT) ──"
        mkdir -p "$MM_DIR"
        ensure_docker_dir_ownership "$MM_DIR"
        cd "$MM_DIR" || continue

        cat > docker-compose.yml << MM_COMPOSE
name: mm-$MM_PORT

services:
  magicmirror:
    image: karsten13/magicmirror:latest
    container_name: magicmirror-$MM_PORT
    hostname: magicmirror-$MM_PORT
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
    volumes:
      - ./config:/opt/magic_mirror/config
      - ./modules:/opt/magic_mirror/modules
      - ./css:/opt/magic_mirror/css
    ports:
      - "$MM_PORT:8080"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
MM_COMPOSE

        mkdir -p config modules css

        # Offer to copy an existing config.js
        local MM_CONFIG_CHOICE=""
        echo ""
        echo "  Config options:"
        echo "    [1] Use default config (basic built-in modules)"
        echo "    [2] Copy existing config.js from a path"
        if [ "$UNATTENDED" = true ]; then
            MM_CONFIG_CHOICE="1"
        else
            read -r -p "  Choose [1]: " MM_CONFIG_CHOICE
            MM_CONFIG_CHOICE="${MM_CONFIG_CHOICE:-1}"
        fi

        if [ "$MM_CONFIG_CHOICE" = "2" ]; then
            local MM_CONFIG_PATH=""
            read -r -p "  Path to config.js: " MM_CONFIG_PATH
            if [ -f "$MM_CONFIG_PATH" ]; then
                cp "$MM_CONFIG_PATH" config/config.js
                log_success "Copied config from $MM_CONFIG_PATH"

                # Copy custom.css if it exists next to config.js
                local MM_CSS_DIR="${MM_CONFIG_PATH%/*}"
                [ -f "$MM_CSS_DIR/custom.css" ] && cp "$MM_CSS_DIR/custom.css" css/custom.css && log_success "Copied custom.css"

                # Detect MMM-* third-party modules referenced in config
                local THIRD_PARTY_MODS
                THIRD_PARTY_MODS=$(grep -oP "module:\s*[\"']MMM-[^\"']+[\"']" config/config.js 2>/dev/null \
                    | sed "s/module:\s*[\"']//g" | sed "s/[\"']//g" | sort -u)

                if [ -n "$THIRD_PARTY_MODS" ]; then
                    echo ""
                    echo "  Third-party modules found in config:"
                    echo "$THIRD_PARTY_MODS" | while read -r mod; do echo "    - $mod"; done
                    echo ""
                    local MM_DL_MODS=""
                    prompt_yn "  Download these modules from GitHub? (y/n):" "y" MM_DL_MODS
                    if [ "$MM_DL_MODS" = "y" ] || [ "$MM_DL_MODS" = "Y" ]; then
                        cd modules || true
                        echo "$THIRD_PARTY_MODS" | while read -r mod; do
                            [ -z "$mod" ] || [ -d "$mod" ] && continue
                            echo "  Downloading $mod..."
                            git clone --depth 1 "https://github.com/MichMich/${mod}.git" 2>/dev/null || \
                            git clone --depth 1 "https://github.com/bugsounet/${mod}.git" 2>/dev/null || \
                            git clone --depth 1 "https://github.com/MagicMirrorOrg/${mod}.git" 2>/dev/null || \
                            log_warning "Could not find $mod — search at https://github.com/topics/magicmirror"
                        done
                        cd "$MM_DIR" || true
                    fi
                fi
            else
                log_warning "File not found: $MM_CONFIG_PATH — using default config"
            fi
        fi

        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MM_DIR"
        log_success "MagicMirror instance $i configured at $MM_DIR (port $MM_PORT)"

        # Offer Caddy only for first instance
        if [ "$i" -eq 1 ]; then
            local MM_EXTRA_BLOCK=""
            if [ -d "$DOCKER_DIR/authelia" ]; then
                local _use_auth=""
                prompt_yn "Protect MagicMirror with Authelia SSO? (y/n):" "y" _use_auth
                [[ "$_use_auth" =~ ^[Yy]$ ]] && MM_EXTRA_BLOCK="    import authelia"
            fi
            configure_caddy_for_service "MagicMirror" "magicmirror-${MM_PORT}:8080" "mirror" "$MM_EXTRA_BLOCK"
        fi

        local START_MM=""
        prompt_yn "Start instance $i now? (y/n):" "y" START_MM
        if [ "$START_MM" = "y" ] || [ "$START_MM" = "Y" ]; then
            docker compose up -d && log_success "MagicMirror instance $i started" || log_warning "Failed to start — check: docker compose logs"
        fi

        echo "  Access at:  http://localhost:$MM_PORT"
    done

    write_readme "$MM_BASE" << MD
# MagicMirror²

Modular smart mirror / info dashboard. Each instance has its own port and
independent config, modules, and CSS.

| Instance | Port | Directory |
|----------|------|-----------|
$(for j in $(seq 1 "$MM_COUNT"); do echo "| $j | $((8080 + j)) | \`$MM_BASE/$j/\` |"; done)

## Manage
\`\`\`bash
cd $MM_BASE/1
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Config
- Edit \`<instance>/config/config.js\` for layout and module settings.
- Add CSS overrides in \`<instance>/css/custom.css\`.
- Third-party modules go in \`<instance>/modules/<module-name>/\`.
  Then run \`docker exec magicmirror-PORT sh -c 'cd /opt/magic_mirror/modules/<name> && npm install --production'\`

## Finding modules
Browse: https://github.com/topics/magicmirror
MD

    echo ""
    echo "  MagicMirror config: $MM_BASE/<instance>/config/config.js"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_magicmirror
