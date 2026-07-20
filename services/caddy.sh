#!/bin/bash
# services/caddy.sh — Caddy reverse proxy + automatic HTTPS.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash caddy.sh
# (Docker must already be installed when run standalone)
#
# Caddy is the front door for the homelab: it terminates TLS (automatic
# Let's Encrypt certificates), reverse-proxies to your other services, and
# writes JSON access logs that CrowdSec reads for intrusion prevention.
#
# Each web service adds its own site block to $CADDY_DIR/Caddyfile (the shared
# configure_caddy_for_service helper does this automatically), then Caddy is
# reloaded without downtime.

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

register_service caddy homelab "Reverse proxy + automatic HTTPS (Caddy)" 443

install_caddy() {
    require_docker || return 1
    log_info "Installing Caddy reverse proxy..."

    local CADDY_DIR="$DOCKER_DIR/caddy"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ CADDY - Modern Web Server & Reverse Proxy                       │"
    echo "│ Automatic HTTPS, reverse proxy for all your services            │"
    echo "│ Port: 80 (HTTP), 443 (HTTPS)                                    │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    # ── DRY-RUN: describe the plan and bail before touching anything real ────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $CADDY_DIR (data/, config/)"
        echo "[DRY-RUN] Would write $CADDY_DIR/docker-compose.yml (ports 80/443 + HTTP/3)"
        echo "[DRY-RUN] Would write a starter $CADDY_DIR/Caddyfile (if none exists)"
        echo "[DRY-RUN] Would write $CADDY_DIR/README.md"
        echo "[DRY-RUN] Would optionally start Caddy (docker compose up -d)"
        return 0
    fi

    # Reconfigure guard: warn if Caddy already looks installed.
    if [ -f "$CADDY_DIR/Caddyfile" ] || [ -f "$CADDY_DIR/docker-compose.yml" ]; then
        echo ""
        echo "⚠  Caddy appears to be already installed at $CADDY_DIR"
        local RECONFIGURE_CADDY=""
        prompt_yn "Do you want to reconfigure it? (y/n):" "n" RECONFIGURE_CADDY
        if [ "$RECONFIGURE_CADDY" != "y" ] && [ "$RECONFIGURE_CADDY" != "Y" ]; then
            echo "  Skipping Caddy installation"
            return 0
        fi
    fi

    mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config"
    ensure_docker_dir_ownership "$CADDY_DIR"

    # Backup existing Caddyfile if it exists
    if [ -f "$CADDY_DIR/Caddyfile" ]; then
        mkdir -p "$CADDY_DIR/backups"
        local BACKUP_FILE="$CADDY_DIR/backups/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CADDY_DIR/Caddyfile" "$BACKUP_FILE"
        echo "  ✓ Backed up existing Caddyfile to: $BACKUP_FILE"
    fi

    cd "$CADDY_DIR" || return 1

    cat > docker-compose.yml << 'CADDY_COMPOSE'
name: caddy

services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./data:/data
      - ./config:/config
      - /var/log/caddy:/var/log/caddy
    environment:
      - ACME_AGREE=true
    labels:
      - "io.podman.annotations.label/crowdsec.enable=true"
    # Lets Caddyfile blocks reach services that use network_mode: host
    # (e.g. asterisk/asterisk-do) via "host.docker.internal:PORT" — Caddy
    # itself is on the caddy_net bridge network below, so plain "localhost"
    # in a site block resolves to Caddy's own container, not the host.
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - caddy_net

networks:
  caddy_net:
    driver: bridge
    name: caddy_net
CADDY_COMPOSE

    # Create Caddyfile if it doesn't exist
    if [ ! -f "Caddyfile" ]; then
        cat > Caddyfile << 'CADDYFILE'
{
    # Global options
    admin off
    # Email for Let's Encrypt notifications
    # email admin@yourdomain.com
}

# Example configuration - edit this for your services
# Uncomment and modify these examples:

# ── Port reference ────────────────────────────────────────────────────────────
# Services on caddy_net → use the container name and INTERNAL port:
#   reverse_proxy myservice:80       (what the container listens on inside Docker)
#
# Accessing a service directly from another machine → use the HOST port:
#   http://server-ip:8085            (the left side of ports: "8085:80" in compose)
#
# The ports: mapping is only for direct host access.
# Caddy bypasses it entirely and talks container-to-container.
# ─────────────────────────────────────────────────────────────────────────────

# ── Authelia SSO snippet (auto-added by installer if Authelia is installed) ───
# (authelia) {
#     forward_auth authelia:9091 {
#         uri /api/authz/forward-auth
#         copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
#     }
# }
#
# Authelia login portal
# auth.yourdomain.com {
#     reverse_proxy authelia:9091
# }
#
# To protect any service with Authelia, add:  import authelia
# Example:
# myservice.yourdomain.com {
#     import authelia
#     reverse_proxy container_name:port
# }

# ActualBudget
# budget.yourdomain.com {
#     log {
#         output file /var/log/caddy/actualbudget-access.log
#         format json
#         level INFO
#     }
#     reverse_proxy actualbudget:5006
#     header {
#         Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
#         X-Frame-Options "SAMEORIGIN"
#         X-Content-Type-Options "nosniff"
#         X-XSS-Protection "1; mode=block"
#         Referrer-Policy "strict-origin-when-cross-origin"
#     }
# }

# Add more services here...
CADDYFILE
        echo "  ✓ Created example Caddyfile"
    else
        echo "  ℹ Using existing Caddyfile"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$CADDY_DIR"
    echo "  ✓ Caddy configured at $CADDY_DIR"

    write_readme "$CADDY_DIR" << 'CADDY_README'
# Caddy — reverse proxy + automatic HTTPS

Caddy is the front door for this box. It:

- Reverse-proxies incoming requests to your other services.
- Obtains and renews TLS certificates automatically (Let's Encrypt / ZeroSSL),
  so every site is HTTPS with no manual cert wrangling.
- Listens on **80** (HTTP, redirects to HTTPS) and **443** (HTTPS, incl. HTTP/3
  on 443/udp).
- Writes JSON access logs to `/var/log/caddy/` — these are what CrowdSec reads
  to detect and ban malicious traffic.

## Adding services

Other services add their own **site blocks** to `./Caddyfile` (the installer's
`configure_caddy_for_service` helper appends them automatically when you install
a web service). You can also edit it by hand:

```
myservice.example.com {
    reverse_proxy container_name:1234
    log {
        output file /var/log/caddy/myservice.example.com.log
        format json
    }
}
```

**Port rule:** use the container's *internal* port, not the host-mapped port.
If a service has `ports: "8085:80"` in its compose file, Caddy uses `:80`
(container-to-container on `caddy_net`). The `8085` is only for direct
host access from another machine.

## Reloading after edits

Apply Caddyfile changes without downtime:

```
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Start / stop

From this folder (`~/docker/caddy`):

```
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # follow logs
```

## Where things live

- Caddyfile:  `~/docker/caddy/Caddyfile`  (mounted at `/etc/caddy/Caddyfile`)
- Access logs: `/var/log/caddy/*.log`  (JSON; consumed by CrowdSec)
- Certs/state: `~/docker/caddy/data` and `~/docker/caddy/config`
- Backups of the Caddyfile: `~/docker/caddy/backups/`
CADDY_README

    local START_CADDY=""
    prompt_yn "Start Caddy now? (y/n):" "y" START_CADDY
    if [ "$START_CADDY" = "y" ] || [ "$START_CADDY" = "Y" ]; then
        docker compose up -d 2>/dev/null && echo "  ✓ Caddy started" || echo "  ⚠ Failed to start Caddy"
    fi

    echo ""
    echo "  Configuration file: $CADDY_DIR/Caddyfile"
    echo "  Edit Caddyfile to add your domains and services"
    echo "  Reload config:      docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
    echo ""
    echo "  ⚠  IMPORTANT: Edit the Caddyfile to configure your domains!"
    echo "     - Uncomment and modify the example configurations"
    echo "     - Add your domain names"
    echo "     - Configure services you want to expose"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_caddy
