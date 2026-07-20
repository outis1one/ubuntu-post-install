#!/bin/bash
# services/authelia.sh — Authelia SSO + 2FA portal (forward-auth for Caddy).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash authelia.sh
# (Docker must already be installed when run standalone)
#
# Ported from the authelia-setup repo / the monolith's working block.

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

register_service authelia homelab "SSO + 2FA auth portal (Authelia)" 9091

install_authelia() {
    require_docker || return 1
    local AUTHELIA_DIR="$DOCKER_DIR/authelia"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would set up Authelia:"
        echo "  • Create $AUTHELIA_DIR (config/secrets, data)"
        echo "  • Generate jwt/session/storage secrets + admin password hash"
        echo "  • Write docker-compose.yml, configuration.yml, users.yml, README.md"
        echo "  • Create the caddy_net network and add the forward-auth snippet to the Caddyfile"
        return 0
    fi

    # Don't clobber an existing install (it would regenerate secrets and break sessions).
    if [ -f "$AUTHELIA_DIR/docker-compose.yml" ]; then
        local RECONF=""
        echo "  ⚠ Authelia already exists at $AUTHELIA_DIR (secrets/users would be regenerated)."
        prompt_yn "  Reconfigure from scratch? (y/n):" "n" RECONF
        if [ "$RECONF" != "y" ] && [ "$RECONF" != "Y" ]; then
            echo "  Keeping existing Authelia. (Edit config/users.yml then: cd $AUTHELIA_DIR && docker compose restart authelia)"
            return 0
        fi
    fi

    log_info "Installing Authelia..."
    mkdir -p "$AUTHELIA_DIR/config/secrets" "$AUTHELIA_DIR/data"

    # ── Collect configuration ────────────────────────────────────────────────
    echo ""
    echo "  Authelia needs a few details to configure."
    echo ""
    local CADDY_NET="${SITE_CADDY_NET:-caddy_net}"
    local AUTHELIA_DOMAIN AUTHELIA_ADMIN_USER AUTHELIA_ADMIN_DISPLAY AUTHELIA_ADMIN_EMAIL
    local AUTHELIA_SMTP_HOST AUTHELIA_SMTP_PORT AUTHELIA_SMTP_USER AUTHELIA_SMTP_PASS AUTHELIA_TZ
    prompt_text "  Your domain (e.g., example.com):" "${SITE_DOMAIN:-example.com}" AUTHELIA_DOMAIN
    prompt_text "  Admin username:" "admin" AUTHELIA_ADMIN_USER
    prompt_text "  Admin display name:" "Administrator" AUTHELIA_ADMIN_DISPLAY
    prompt_text "  Admin email:" "admin@${AUTHELIA_DOMAIN}" AUTHELIA_ADMIN_EMAIL
    prompt_text "  SMTP server (e.g., smtp.migadu.com):" "smtp.migadu.com" AUTHELIA_SMTP_HOST
    prompt_text "  SMTP port:" "587" AUTHELIA_SMTP_PORT
    prompt_text "  SMTP username (full email):" "authelia@${AUTHELIA_DOMAIN}" AUTHELIA_SMTP_USER
    prompt_text "  SMTP password:" "" AUTHELIA_SMTP_PASS
    prompt_text "  Timezone (e.g., America/New_York):" "${SITE_TZ:-America/New_York}" AUTHELIA_TZ

    # ── Secrets ──────────────────────────────────────────────────────────────
    echo ""
    echo "  Generating secrets..."
    echo "$(openssl rand -hex 32)" > "$AUTHELIA_DIR/config/secrets/jwt_secret"
    echo "$(openssl rand -hex 32)" > "$AUTHELIA_DIR/config/secrets/session_secret"
    echo "$(openssl rand -hex 32)" > "$AUTHELIA_DIR/config/secrets/storage_secret"
    echo "$AUTHELIA_SMTP_PASS"     > "$AUTHELIA_DIR/config/secrets/smtp_password"
    chmod 600 "$AUTHELIA_DIR/config/secrets/"*
    echo "  ✓ Secrets generated"

    # ── Admin password hash ──────────────────────────────────────────────────
    echo ""
    local AUTHELIA_TEMP_PASS AUTHELIA_HASH
    prompt_text "  Temporary password for admin (users reset via email):" "TempPass2026!" AUTHELIA_TEMP_PASS
    echo "  Generating password hash..."
    AUTHELIA_HASH=$(docker run --rm authelia/authelia:4.39.20 \
        authelia crypto hash generate argon2 --password "$AUTHELIA_TEMP_PASS" 2>/dev/null \
        | grep -oP '(?<=Digest: ).*' || echo "REPLACE_WITH_HASH")
    if [ "$AUTHELIA_HASH" = "REPLACE_WITH_HASH" ]; then
        log_warning "Could not generate hash automatically. After install run:"
        echo "    docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'yourpassword'"
        echo "    then update $AUTHELIA_DIR/config/users.yml"
    else
        echo "  ✓ Password hash generated"
    fi

    ensure_docker_dir_ownership "$AUTHELIA_DIR"
    cd "$AUTHELIA_DIR" || return 1

    # ── .env ─────────────────────────────────────────────────────────────────
    cat > .env << AUTHELIA_ENV
MY_DOMAIN=${AUTHELIA_DOMAIN}
SMTP_USER=${AUTHELIA_SMTP_USER}
DOCKER_MY_NETWORK=${CADDY_NET}
TZ=${AUTHELIA_TZ}
AUTHELIA_ENV

    # ── docker-compose.yml (quoted heredoc: ${SMTP_USER} resolved by compose/.env) ──
    cat > docker-compose.yml << 'AUTHELIA_COMPOSE'
name: authelia

services:
  authelia:
    image: authelia/authelia:4.39.20
    pull_policy: missing
    container_name: authelia
    user: "1000:1000"
    volumes:
      - ./config:/config
      - ./data:/data
    environment:
      - AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET_FILE=/config/secrets/jwt_secret
      - AUTHELIA_SESSION_SECRET_FILE=/config/secrets/session_secret
      - AUTHELIA_STORAGE_ENCRYPTION_KEY_FILE=/config/secrets/storage_secret
      - AUTHELIA_NOTIFIER_SMTP_PASSWORD_FILE=/config/secrets/smtp_password
      - AUTHELIA_NOTIFIER_SMTP_USERNAME=${SMTP_USER}
      - AUTHELIA_NOTIFIER_SMTP_SENDER=Authelia <${SMTP_USER}>
    expose:
      - 9091
    restart: unless-stopped
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
AUTHELIA_COMPOSE
    [ "$CADDY_NET" != "caddy_net" ] && sed -i "s/caddy_net/${CADDY_NET}/g" docker-compose.yml

    # ── configuration.yml ────────────────────────────────────────────────────
    cat > config/configuration.yml << AUTHELIA_CONFIG
---
# Authelia configuration. Secrets injected via AUTHELIA_* env vars in compose.
theme: dark

server:
  address: tcp://0.0.0.0:9091

log:
  level: info
  file_path: /data/authelia.log

totp:
  period: 30
  skew: 1

authentication_backend:
  file:
    path: /config/users.yml
    password:
      algorithm: argon2
      argon2:
        variant: argon2id
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

access_control:
  default_policy: deny
  rules:
    - domain: "*.${AUTHELIA_DOMAIN}"
      policy: two_factor

session:
  name: authelia_session
  expiration: 12h
  inactivity: 2h
  remember_me: 7d
  cookies:
    - domain: ${AUTHELIA_DOMAIN}
      authelia_url: https://auth.${AUTHELIA_DOMAIN}
      default_redirection_url: https://${AUTHELIA_DOMAIN}

storage:
  local:
    path: /data/db.sqlite3

notifier:
  disable_startup_check: false
  smtp:
    address: smtp://${AUTHELIA_SMTP_HOST}:${AUTHELIA_SMTP_PORT}
    timeout: 10s
    identifier: localhost
    subject: "[Authelia] {title}"
    startup_check_address: ${AUTHELIA_SMTP_USER}
    disable_require_tls: false
    disable_starttls: false
AUTHELIA_CONFIG

    # ── users.yml ────────────────────────────────────────────────────────────
    cat > config/users.yml << AUTHELIA_USERS
---
# Authelia users database
# Add users: copy a block, change username/email/displayname, restart authelia.
# Generate a hash: docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'thepassword'
# Login with username (not email). Use "Forgot Password" to set a real password.

users:
  ${AUTHELIA_ADMIN_USER}:
    displayname: "${AUTHELIA_ADMIN_DISPLAY}"
    email: ${AUTHELIA_ADMIN_EMAIL}
    password: "${AUTHELIA_HASH}"
    groups:
      - admins
      - users
AUTHELIA_USERS

    chown -R 1000:1000 "$AUTHELIA_DIR/config" "$AUTHELIA_DIR/data"
    log_success "Authelia configured at $AUTHELIA_DIR"

    # $CADDY_NET already exists at this point — require_docker (called at the
    # top of this function) creates it via ensure_caddy_network in lib/common.sh.

    # ── Caddyfile forward-auth snippet + portal block ────────────────────────
    local CADDY_FILE="$DOCKER_DIR/caddy/Caddyfile"
    if [ -f "$CADDY_FILE" ]; then
        echo "  Configuring Caddy for Authelia..."
        if ! grep -q "(authelia)" "$CADDY_FILE"; then
            cp "$CADDY_FILE" "$CADDY_FILE.backup.$(date +%Y%m%d-%H%M%S)"
            { cat << 'SNIPPET_EOF'
# ── Authelia forward auth snippet ─────────────────────────────────────────────
(authelia) {
    forward_auth authelia:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    }
}

SNIPPET_EOF
              cat "$CADDY_FILE"; } > "$CADDY_FILE.tmp" && mv "$CADDY_FILE.tmp" "$CADDY_FILE"
            echo "  ✓ Authelia snippet added to Caddyfile"
        fi
        if ! grep -q "auth.${AUTHELIA_DOMAIN}" "$CADDY_FILE"; then
            cat >> "$CADDY_FILE" << CADDY_AUTH_BLOCK

# ── Authelia login portal ──────────────────────────────────────────────────────
auth.${AUTHELIA_DOMAIN} {
    reverse_proxy authelia:9091
    log {
        output file /var/log/caddy/auth.log
    }
}
CADDY_AUTH_BLOCK
            echo "  ✓ Authelia portal block added for auth.${AUTHELIA_DOMAIN}"
        fi
        docker ps --format '{{.Names}}' | grep -q "^caddy$" && \
            { docker exec -w /etc/caddy caddy caddy reload 2>/dev/null && echo "  ✓ Caddy reloaded" || echo "  ⚠ Reload manually after checking the Caddyfile"; }
    else
        echo "  ℹ Caddy not installed yet — add the (authelia) snippet + auth.${AUTHELIA_DOMAIN} block to your Caddyfile later (see README)."
    fi

    # ── README for the service folder ────────────────────────────────────────
    write_readme "$AUTHELIA_DIR" << README_MD
# Authelia — SSO + 2FA portal

Single login (with TOTP two-factor) that protects any Caddy subdomain via
forward-auth. Portal: **https://auth.${AUTHELIA_DOMAIN}**

## Layout
\`\`\`
$AUTHELIA_DIR/
├── docker-compose.yml
├── .env
├── config/
│   ├── configuration.yml
│   ├── users.yml
│   └── secrets/        # jwt/session/storage/smtp — never commit
└── data/               # sqlite db + log
\`\`\`

## Protect a service with Authelia
In that service's Caddy site block, add \`import authelia\`:
\`\`\`
myservice.${AUTHELIA_DOMAIN} {
    import authelia
    reverse_proxy localhost:PORT
}
\`\`\`
The \`(authelia)\` snippet and the \`auth.${AUTHELIA_DOMAIN}\` portal block were
added to \`$DOCKER_DIR/caddy/Caddyfile\` automatically.

## Manage
\`\`\`
cd $AUTHELIA_DIR
docker compose up -d        # start
docker compose restart authelia
docker compose logs -f authelia
docker compose down         # stop
\`\`\`

## Users
- Login with the **username** (not email). Admin user: \`${AUTHELIA_ADMIN_USER}\`.
- Tell users to click **Forgot Password** on first login to set their own
  password (Authelia emails a reset link via SMTP).
- Add a user: copy a block in \`config/users.yml\`, change username/email/
  displayname, generate a hash, then \`docker compose restart authelia\`:
\`\`\`
docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'thepassword'
\`\`\`

## Notes
- Authelia listens on 9091 **internally only** (no published port) and is
  reached through Caddy on the shared \`caddy_net\` docker network.
- Two-factor is **required** (\`default_policy: deny\`, rule \`two_factor\` for
  \`*.${AUTHELIA_DOMAIN}\`).
README_MD

    local START_AUTHELIA=""
    prompt_yn "Start Authelia now? (y/n):" "y" START_AUTHELIA
    if [ "$START_AUTHELIA" = "y" ] || [ "$START_AUTHELIA" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Authelia started" || log_warning "Failed to start Authelia"
    fi

    echo ""
    echo "  Auth portal:  https://auth.${AUTHELIA_DOMAIN}"
    echo "  Admin login:  ${AUTHELIA_ADMIN_USER}  (use Forgot Password to set a real password)"
    echo "  README:       $AUTHELIA_DIR/README.md"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_authelia
