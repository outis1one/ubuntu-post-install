#!/bin/bash
# services/mail-archiver.sh — Mail Archiver (IMAP email archive & search).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash mail-archiver.sh
# (Docker must already be installed when run standalone)
#
# Self-hosted email archive — connects to IMAP accounts, indexes messages,
# and provides full-text search. No big-tech email required.
# Image: s1t5/mailarchiver  DB: postgres:17-alpine

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

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
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

register_service mail-archiver utilities "IMAP email archive & search (Mail Archiver)" 5000

install_mail-archiver() {
    require_docker || return 1
    log_info "Installing Mail Archiver..."
    local MA_DIR="$DOCKER_DIR/mail-archiver"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $MA_DIR (mailarchiver_database/)"
        echo "[DRY-RUN] Would deploy s1t5/mailarchiver:latest + postgres:17-alpine"
        echo "[DRY-RUN] Accessed via Caddy reverse proxy (no direct host port)"
        echo "[DRY-RUN] Would generate DB and admin passwords"
        return 0
    fi

    mkdir -p "$MA_DIR/mailarchiver_database"
    ensure_docker_dir_ownership "$MA_DIR"
    cd "$MA_DIR" || return 1

    local DB_PASS ADMIN_PASS TZ_VAL
    DB_PASS=$(generate_password 32)
    ADMIN_PASS=$(generate_password 24)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'MA_COMPOSE'
name: mail-archiver

services:
  mailarchiver-app:
    image: s1t5/mailarchiver:latest
    container_name: mailarchiver-app
    hostname: mailarchiver-app
    restart: unless-stopped
    env_file: .env
    expose:
      - "5000"
    depends_on:
      mailarchiver-db:
        condition: service_healthy
    networks:
      - caddy_net

  mailarchiver-db:
    image: postgres:17-alpine
    container_name: mailarchiver-db
    hostname: mailarchiver-db
    restart: unless-stopped
    env_file: .env
    expose:
      - "5432"
    volumes:
      - ./mailarchiver_database:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mailuser -d MailArchiver"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
MA_COMPOSE

    cat > .env << MA_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── Database connection (app → postgres) ──────────────────────────────────────
ConnectionStrings__DefaultConnection=Host=mailarchiver-db;Database=MailArchiver;Username=mailuser;Password=$DB_PASS;

# ── Web authentication ────────────────────────────────────────────────────────
Authentication__Enabled=true
Authentication__Username=admin
Authentication__Password=$ADMIN_PASS
Authentication__SessionTimeoutMinutes=60
Authentication__CookieName=MailArchiverAuth

# ── Mail sync schedule ────────────────────────────────────────────────────────
MailSync__IntervalMinutes=15
MailSync__TimeoutMinutes=60
MailSync__ConnectionTimeoutSeconds=180
MailSync__CommandTimeoutSeconds=300

# ── Batch restore limits ──────────────────────────────────────────────────────
BatchRestore__AsyncThreshold=50
BatchRestore__MaxSyncEmails=150
BatchRestore__MaxAsyncEmails=50000
BatchRestore__SessionTimeoutMinutes=30
BatchRestore__DefaultBatchSize=50

# ── Postgres tuning ───────────────────────────────────────────────────────────
Npgsql__CommandTimeout=600

# ── Postgres container ────────────────────────────────────────────────────────
POSTGRES_DB=MailArchiver
POSTGRES_USER=mailuser
POSTGRES_PASSWORD=$DB_PASS
MA_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MA_DIR"
    log_success "Mail Archiver configured at $MA_DIR"

    configure_caddy_for_service "Mail Archiver" "mailarchiver-app:5000" "mail"

    write_readme "$MA_DIR" << MD
# Mail Archiver

Self-hosted IMAP email archive and full-text search.
Add your IMAP mail accounts through the web UI — Mail Archiver will pull
and index all messages, then let you search the full archive.

## Access
- URL: via Caddy reverse proxy (no direct host port)
- Login: admin / (see .env Authentication__Password)

## Adding mail accounts
1. Open the web UI → Settings → Mail Accounts
2. Add IMAP server, username, and password
3. Mail Archiver syncs every \`MailSync__IntervalMinutes\` minutes (default: 15)

## Credentials
Stored in \`.env\` (chmod 600):
- Web admin password: \`Authentication__Password\`
- DB password:        \`POSTGRES_PASSWORD\`

## Manage
\`\`\`bash
cd $MA_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_MA=""
    prompt_yn "Start Mail Archiver now? (y/n):" "y" START_MA
    if [ "$START_MA" = "y" ] || [ "$START_MA" = "Y" ]; then
        docker compose up -d \
            && log_success "Mail Archiver started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Admin login:  admin / $(grep Authentication__Password .env | cut -d= -f2)"
    echo "  Add IMAP accounts via the web UI after starting."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mail-archiver
