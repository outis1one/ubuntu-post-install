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
        echo "  ⚠ Authelia already exists at $AUTHELIA_DIR."
        echo ""
        echo "    1) Add another protected domain to this instance (non-destructive —"
        echo "       one Authelia+Redis, multiple independent apex domains/logins)"
        echo "    2) Add a new user (creates a users.yml entry + password hash)"
        echo "    3) Edit an existing user (email, password reset, 2FA reset/exempt,"
        echo "       promote/demote admin)"
        echo "    4) Register an app to log in VIA Authelia (OIDC/SSO — e.g. ActualBudget,"
        echo "       Vaultwarden, or any other app with its own \"Enable OpenID\" setting)"
        echo "    5) Reconfigure from scratch (regenerates secrets/users — breaks"
        echo "       existing sessions for every domain already on this instance)"
        echo "    6) Leave as-is"
        echo ""
        local EXISTING_CHOICE=""
        prompt_text "  Choice [1/2/3/4/5/6]:" "6" EXISTING_CHOICE
        case "$EXISTING_CHOICE" in
            1)
                add_authelia_domain
                return 0
                ;;
            2)
                add_authelia_user
                return 0
                ;;
            3)
                edit_authelia_user
                return 0
                ;;
            4)
                _authelia_add_oidc_client
                return 0
                ;;
            5)
                : # fall through to the full reinstall flow below
                ;;
            *)
                echo "  Keeping existing Authelia. (Edit config/users.yml then: cd $AUTHELIA_DIR && docker compose restart authelia)"
                return 0
                ;;
        esac
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
        # Anchored to an actual, uncommented snippet definition — a bare
        # `grep -q "(authelia)"` also matches the commented-out example
        # block caddy.sh's starter Caddyfile ships ("# (authelia) {" as
        # documentation). Confirmed live: that false match made this skip
        # writing the real snippet entirely, leaving any later `import
        # authelia` reference elsewhere in the file dangling — Caddy then
        # refuses to start at all ("File to import not found: authelia"),
        # taking down every site it fronts, not just the Authelia-protected
        # one.
        if ! grep -qE '^\(authelia\)[[:space:]]*\{' "$CADDY_FILE"; then
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
    # header_up pins X-Forwarded-Host to whatever the client actually sent.
    # Without it, Caddy's reverse_proxy recomputes X-Forwarded-Host from its
    # own incoming request (always auth.${AUTHELIA_DOMAIN} itself) and
    # overwrites the value a forward_auth caller (e.g. a remote site's
    # "forward_auth https://auth.${AUTHELIA_DOMAIN}" block, see
    # services/asterisk.sh's droplet-mode Caddy block) set for its own domain. Confirmed
    # live: every forward-auth check evaluated as if it were for
    # auth.${AUTHELIA_DOMAIN} itself (which has policy: bypass in
    # access_control.rules so its own login portal isn't gated behind
    # itself), so every domain behind it silently passed through with no
    # 2FA prompt regardless of that domain's own policy.
    reverse_proxy authelia:9091 {
        header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}
    }
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

## Protecting a second (or third) apex domain
Re-run this installer (\`sudo ./setup.sh authelia\` or \`sudo bash authelia.sh\`)
and choose **"Add another protected domain to this instance"** when it detects
the existing install. That domain gets its own \`session.cookies\` entry and its
own \`auth.<domain>\` portal — a separate login/session from ${AUTHELIA_DOMAIN},
so no accidental cross-domain SSO — but it's still one shared Authelia + Redis
container and one shared user database, not a second full stack. Cheaper than
standing up an entirely separate instance, and the right way to protect
multiple unrelated domains from the same box.

## Letting other apps log in via Authelia (OIDC/SSO)
Different from \`import authelia\` above: that gates a whole site behind a
login page before the request reaches it. This is for an app with its OWN
"Enable OpenID"/SSO setting (ActualBudget, Vaultwarden, etc.) that should
delegate ITS login to Authelia instead of a separate app-specific password.

Re-run this installer and choose **"Register an app to log in VIA
Authelia"** when it detects the existing install. Presets exist for
ActualBudget and Vaultwarden (their exact redirect URI is filled in
automatically); anything else works too via "Other/custom" — check that
app's own OIDC/SSO docs for its redirect URI path first.

First time this runs it also enables Authelia's OIDC provider itself
(generates a signing key + HMAC secret, one-time, automatic). Each
registered app gets its own Client ID/Secret under
\`identity_providers.oidc.clients\` in \`config/configuration.yml\` — the
secret is shown once at registration time and only the hash is kept.

Endpoints (needed if an app asks for them instead of a discovery URL):
- Discovery: \`https://auth.${AUTHELIA_DOMAIN}/.well-known/openid-configuration\`
- Authorization: \`https://auth.${AUTHELIA_DOMAIN}/api/oidc/authorization\`
- Token: \`https://auth.${AUTHELIA_DOMAIN}/api/oidc/token\`
- UserInfo: \`https://auth.${AUTHELIA_DOMAIN}/api/oidc/userinfo\`

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
- Both self-service paths need working SMTP: **Forgot Password** on the login
  screen emails a reset link, and even the in-portal **Settings → Change
  Password** page (for an already-logged-in user) sends a one-time code to
  their email to confirm the change — confirmed live, it is not a
  no-email path despite Authelia describing it as an in-session action.
  If SMTP isn't working yet, use the admin-side reset instead (next line),
  which never touches email.
- **Add a user:** re-run this installer (\`sudo ./setup.sh authelia\` or
  \`sudo bash authelia.sh\`) and choose **"Add a new user"** from the menu —
  it prompts for username/email/display name, generates the password hash,
  writes the \`users.yml\` block, and restarts Authelia for you.
- To add one by hand instead: copy a block in \`config/users.yml\`, change
  username/email/displayname, generate a hash, then
  \`docker compose restart authelia\`:
\`\`\`
docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'thepassword'
\`\`\`
- Any user added this way can log into every OIDC app already registered on
  this instance (see "Letting other apps log in via Authelia" above) — access
  isn't scoped per-app by default, it's shared across the whole instance.

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

# Adds a second (or third, etc.) independent apex domain to an EXISTING Authelia
# instance instead of standing up a whole separate Authelia+Redis stack for it.
# Authelia natively supports this: session.cookies and access_control.rules are
# both lists, so one instance can hold a distinct cookie scope + login portal per
# domain, each with its own session (no cross-domain SSO, but also no collision —
# see the "Running more than one Authelia instance" note in CLAUDE.md for why two
# domains can't just share one session.cookies entry). Far cheaper on RAM than a
# second full instance, which matters most on a small droplet.
add_authelia_domain() {
    local AUTHELIA_DIR="$DOCKER_DIR/authelia"
    local CONFIG_FILE="$AUTHELIA_DIR/config/configuration.yml"
    local CADDY_FILE="$DOCKER_DIR/caddy/Caddyfile"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "No configuration.yml found at $CONFIG_FILE — install Authelia first."
        return 1
    fi

    echo ""
    echo "  Add another apex domain to this Authelia instance."
    echo "  It gets its own session-cookie scope and its own auth.<domain> portal —"
    echo "  a separate login/session from your other domain(s) — but shares this"
    echo "  same Authelia + Redis container, not a second full stack."
    echo ""
    local NEW_DOMAIN=""
    prompt_text "  New domain (e.g., example.com):" "" NEW_DOMAIN
    if [ -z "$NEW_DOMAIN" ]; then
        log_warning "No domain entered — nothing to do."
        return 0
    fi

    if grep -qF "\"*.${NEW_DOMAIN}\"" "$CONFIG_FILE" 2>/dev/null; then
        log_warning "$NEW_DOMAIN is already configured in $CONFIG_FILE — nothing to do."
        return 0
    fi

    # ── access_control.rules: insert right after "rules:" ────────────────────
    awk -v domain="$NEW_DOMAIN" '
        { print }
        /^  rules:$/ && !done {
            print "    - domain: \"*." domain "\""
            print "      policy: two_factor"
            done=1
        }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    # ── session.cookies: insert right after "cookies:" ────────────────────────
    awk -v domain="$NEW_DOMAIN" '
        { print }
        /^  cookies:$/ && !done {
            print "    - domain: " domain
            print "      authelia_url: https://auth." domain
            print "      default_redirection_url: https://" domain
            done=1
        }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    chown 1000:1000 "$CONFIG_FILE" 2>/dev/null || true
    log_success "Added $NEW_DOMAIN to $CONFIG_FILE (access_control rule + session cookie scope)"

    # ── Caddy portal block for the new domain ─────────────────────────────────
    if [ -f "$CADDY_FILE" ]; then
        if ! grep -q "^auth.${NEW_DOMAIN} {" "$CADDY_FILE"; then
            cat >> "$CADDY_FILE" << CADDY_AUTH_BLOCK2

# ── Authelia login portal (${NEW_DOMAIN}) ─────────────────────────────────────
auth.${NEW_DOMAIN} {
    # See auth.${AUTHELIA_DOMAIN:-<original domain>}'s block above for why
    # header_up X-Forwarded-Host is required here, not optional.
    reverse_proxy authelia:9091 {
        header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}
    }
    log {
        output file /var/log/caddy/auth.${NEW_DOMAIN}.log
    }
}
CADDY_AUTH_BLOCK2
            echo "  ✓ Authelia portal block added for auth.${NEW_DOMAIN}"
            docker ps --format '{{.Names}}' | grep -q "^caddy$" && \
                { docker exec -w /etc/caddy caddy caddy reload 2>/dev/null && echo "  ✓ Caddy reloaded" || echo "  ⚠ Reload manually: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"; }
        else
            echo "  ✓ auth.${NEW_DOMAIN} portal block already exists in the Caddyfile"
        fi
    else
        echo "  ℹ Caddy not installed — add an auth.${NEW_DOMAIN} portal block manually later (see README)."
    fi

    # ── Restart Authelia to pick up the new config ────────────────────────────
    local RESTART_AUTH=""
    prompt_yn "  Restart Authelia to apply the new domain? (y/n):" "y" RESTART_AUTH
    if [ "$RESTART_AUTH" = "y" ] || [ "$RESTART_AUTH" = "Y" ]; then
        (cd "$AUTHELIA_DIR" && docker compose restart authelia 2>/dev/null) \
            && log_success "Authelia restarted" \
            || log_warning "Restart failed — check: docker compose logs authelia"
    fi

    echo ""
    echo "  Auth portal for $NEW_DOMAIN: https://auth.${NEW_DOMAIN}"
    echo "  Protect a service under this domain the same way as any other:"
    echo "    myservice.${NEW_DOMAIN} {"
    echo "        import authelia"
    echo "        reverse_proxy localhost:PORT"
    echo "    }"
    echo "  Same users/passwords work across every domain on this instance —"
    echo "  it's one shared user database, just separate sessions per domain."
    echo ""
}

# Picks "count" random characters from "charset" using an unbiased-enough
# per-byte modulo draw from /dev/urandom. Not part of lib/common.sh's shared
# generate_password (that one is deliberately alphanumeric-only — see its
# paired validate_password, which rejects special characters outright, since
# plenty of other services embed its output directly into .env/YAML/URLs
# without escaping). This one is scoped to add_authelia_user()'s temp
# password only, which is never written to disk in plaintext, so the wider
# character set is safe here without becoming a repo-wide convention change.
_authelia_rand_chars() {
    local charset="$1" count="$2" out="" idx byte clen
    clen=${#charset}
    while [ "${#out}" -lt "$count" ]; do
        byte=$(od -An -N1 -tu1 /dev/urandom | tr -d ' ')
        idx=$(( byte % clen ))
        out+="${charset:idx:1}"
    done
    printf '%s' "$out"
}

# 30 chars, at least 5 each of uppercase/digit/special, rest a random mix —
# then shuffled so the guaranteed characters aren't clustered at the front.
_authelia_gen_temp_password() {
    local length=30 min_upper=5 min_digit=5 min_special=5
    local upper_set="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    local digit_set="0123456789"
    local special_set='!@#%^&*()_+=-[]{}:,.?~'
    local mixed_set="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789${special_set}"

    local part_upper part_digit part_special part_rest
    part_upper="$(_authelia_rand_chars "$upper_set" "$min_upper")"
    part_digit="$(_authelia_rand_chars "$digit_set" "$min_digit")"
    part_special="$(_authelia_rand_chars "$special_set" "$min_special")"
    local rest_len=$(( length - min_upper - min_digit - min_special ))
    part_rest="$(_authelia_rand_chars "$mixed_set" "$rest_len")"

    printf '%s%s%s%s' "$part_upper" "$part_digit" "$part_special" "$part_rest" \
        | fold -w1 | shuf | tr -d '\n'
}

# Adds a new user to an EXISTING Authelia instance's users.yml — the scripted
# version of the manual "generate a hash, paste a users.yml block, restart"
# steps this file's own generated README already documents. Non-destructive:
# only inserts a new block under the existing "users:" key, never touches any
# other user already there. Any user added here can authenticate against
# every OIDC client already registered on this instance (see
# _authelia_add_oidc_client below) — Authelia's authorization_policy controls
# required auth strength (1FA/2FA), not which users may use a given client,
# so there's no separate "grant access to this app" step needed.
add_authelia_user() {
    local AUTHELIA_DIR="$DOCKER_DIR/authelia"
    local USERS_FILE="$AUTHELIA_DIR/config/users.yml"

    if [ ! -f "$USERS_FILE" ]; then
        log_warning "No users.yml found at $USERS_FILE — install Authelia first."
        return 1
    fi

    echo ""
    echo "  Add a new user to this Authelia instance."
    echo "  They log in with their username (not email). A temporary password"
    echo "  is generated below — hand it to them directly. \"Forgot Password\""
    echo "  and Authelia's own Settings → Change Password both require working"
    echo "  SMTP (both email a one-time code), so until that's fixed, use this"
    echo "  menu's \"Edit an existing user\" → \"Reset password\" for future resets."
    echo ""
    local NEW_USERNAME="" NEW_DISPLAY="" NEW_EMAIL="" NEW_ADMIN=""
    prompt_text "  Username (lowercase, no spaces):" "" NEW_USERNAME
    NEW_USERNAME="$(echo "$NEW_USERNAME" | tr -cs 'a-z0-9_-' '-' | sed 's/^-*//;s/-*$//')"
    if [ -z "$NEW_USERNAME" ]; then
        log_warning "No username entered — nothing to do."
        return 0
    fi
    if grep -qE "^  ${NEW_USERNAME}:$" "$USERS_FILE" 2>/dev/null; then
        log_warning "A user named '$NEW_USERNAME' already exists in $USERS_FILE — pick another username, or edit that entry by hand."
        return 0
    fi

    prompt_text "  Display name:" "$NEW_USERNAME" NEW_DISPLAY
    prompt_text "  Email:" "${NEW_USERNAME}@${SITE_DOMAIN:-example.com}" NEW_EMAIL
    local NEW_ADMIN_YN=""
    prompt_yn "  Grant admin group membership too? (y/n):" "n" NEW_ADMIN_YN

    log_info "Generating temporary password + hash..."
    local TEMP_PASS NEW_HASH
    TEMP_PASS="$(_authelia_gen_temp_password)"
    NEW_HASH=$(docker run --rm authelia/authelia:4.39.20 \
        authelia crypto hash generate argon2 --password "$TEMP_PASS" 2>/dev/null \
        | grep -oP '(?<=Digest: ).*')
    if [ -z "$NEW_HASH" ]; then
        log_warning "Couldn't generate the password hash automatically. Run manually, then add the"
        log_warning "user to $USERS_FILE by hand:"
        echo "    docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate argon2 --password 'temporary-password'"
        return 1
    fi

    local GROUPS_BLOCK="      - users"
    [[ "$NEW_ADMIN_YN" =~ ^[Yy]$ ]] && GROUPS_BLOCK="      - admins
      - users"

    local USER_BLOCK="  ${NEW_USERNAME}:
    displayname: \"${NEW_DISPLAY}\"
    email: ${NEW_EMAIL}
    password: \"${NEW_HASH}\"
    groups:
${GROUPS_BLOCK}"

    awk -v block="$USER_BLOCK" '
        { print }
        /^users:$/ && !done { print block; done=1 }
    ' "$USERS_FILE" > "$USERS_FILE.tmp" && mv "$USERS_FILE.tmp" "$USERS_FILE"
    chown 1000:1000 "$USERS_FILE" 2>/dev/null || true
    log_success "Added user '$NEW_USERNAME' to $USERS_FILE"

    local RESTART_AUTH=""
    prompt_yn "  Restart Authelia to apply the new user? (y/n):" "y" RESTART_AUTH
    if [ "$RESTART_AUTH" = "y" ] || [ "$RESTART_AUTH" = "Y" ]; then
        (cd "$AUTHELIA_DIR" && docker compose restart authelia 2>/dev/null) \
            && log_success "Authelia restarted" \
            || log_warning "Restart failed — check: docker compose logs authelia"
    fi

    echo ""
    echo "  New user:      ${NEW_USERNAME}"
    echo "  Temp password: ${TEMP_PASS}"
    echo "  Give this to them directly (it's shown once, nothing stores it in"
    echo "  plaintext). They can log in with it as-is and keep using it, or"
    echo "  change it themselves from Authelia's Settings page — but that page"
    echo "  emails a one-time code to confirm the change, so it needs working"
    echo "  SMTP. Without SMTP, use this menu's \"Edit an existing user\" →"
    echo "  \"Reset password\" instead — that one never touches email."
    echo ""
}

# ── edit_authelia_user() helpers ──────────────────────────────────────────────
# All of these operate on a caller-supplied line range or file, never scan the
# whole file themselves, so an edit to one user's block can't bleed into a
# neighboring user (or, for the 2FA-exempt helpers, one user's exemption rule
# can't be mistaken for another's — verified against multi-user/multi-domain
# fixtures before this shipped, since a bad access_control edit here would
# break every protected domain on the instance, not just this one user).

_authelia_list_usernames() {
    local users_file="$1"
    awk '/^users:$/{f=1; next} f && /^  [A-Za-z0-9_-]+:$/{gsub(/^  /,""); gsub(/:$/,""); print}' "$users_file"
}

# Prints "<start_line> <end_line>" (1-indexed, inclusive) spanning just the
# given user's block in users.yml.
_authelia_user_line_range() {
    local users_file="$1" username="$2"
    awk -v user="$username" '
        BEGIN{start=0; end=0}
        /^  [A-Za-z0-9_-]+:$/ {
            if (start>0 && end==0) { end=NR-1 }
            if ($0 ~ "^  "user":$") { start=NR }
        }
        END {
            if (start>0 && end==0) { end=NR }
            print start, end
        }
    ' "$users_file"
}

# Replaces the first "    <field>: ..." line found within [start,end] with
# "newline" verbatim (caller supplies correct quoting for that field).
_authelia_set_user_field() {
    local users_file="$1" start="$2" end="$3" field="$4" newline="$5"
    awk -v s="$start" -v e="$end" -v field="$field" -v newline="$newline" '
        NR>=s && NR<=e && $0 ~ "^    "field":" { print newline; next }
        { print }
    ' "$users_file" > "$users_file.tmp" && mv "$users_file.tmp" "$users_file"
}

# enable=true adds "- admins" under this user's groups: (no-op if already
# present); enable=false removes it. Scoped to [start,end] so it can't touch
# another user's groups list.
_authelia_toggle_admin() {
    local users_file="$1" start="$2" end="$3" enable="$4"
    if [ "$enable" = "true" ]; then
        if ! sed -n "${start},${end}p" "$users_file" | grep -q '^      - admins$'; then
            awk -v s="$start" -v e="$end" '
                { print }
                NR>=s && NR<=e && /^    groups:$/ { print "      - admins" }
            ' "$users_file" > "$users_file.tmp" && mv "$users_file.tmp" "$users_file"
        fi
    else
        awk -v s="$start" -v e="$end" '
            NR>=s && NR<=e && /^      - admins$/ { next }
            { print }
        ' "$users_file" > "$users_file.tmp" && mv "$users_file.tmp" "$users_file"
    fi
}

# action="exempt": inserts a "policy: one_factor / subject: user:<name>" rule
# immediately before EVERY plain "policy: two_factor" catch-all domain rule in
# configuration.yml (handles multi-domain instances from add_authelia_domain
# automatically). action="restore": removes only this user's own such rules,
# leaving any other user's exemptions and the catch-all rules untouched.
# Caller is responsible for the idempotency check (only offer "exempt" in the
# menu when not already exempt, and vice versa) — this helper doesn't dedupe.
_authelia_set_2fa_exempt() {
    local config_file="$1" username="$2" action="$3"
    if [ "$action" = "exempt" ]; then
        awk -v user="$username" '
            { lines[NR]=$0 }
            END {
                for (i=1; i<=NR; i++) {
                    if (lines[i] ~ /^    - domain:/ && lines[i+1] ~ /policy: two_factor/) {
                        domain = lines[i]
                        sub(/^    - domain: /, "", domain)
                        print "    - domain: " domain
                        print "      policy: one_factor"
                        print "      subject: \"user:" user "\""
                    }
                    print lines[i]
                }
            }
        ' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
    else
        awk -v user="$username" '
            { lines[NR]=$0 }
            END {
                for (i=1; i<=NR; i++) {
                    if (lines[i] ~ /^    - domain:/ && lines[i+1] ~ /policy: one_factor/ && lines[i+2] ~ ("subject: \"user:" user "\"")) {
                        i += 2
                        continue
                    }
                    print lines[i]
                }
            }
        ' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
    fi
    chown 1000:1000 "$config_file" 2>/dev/null || true
}

# Interactive: pick an existing user from users.yml, then act on them —
# edit email/display name, force a password reset, reset their 2FA device,
# toggle whether they need 2FA at all, or toggle admin group membership.
# Loops so multiple actions can be applied to the same user in one pass.
edit_authelia_user() {
    local AUTHELIA_DIR="$DOCKER_DIR/authelia"
    local USERS_FILE="$AUTHELIA_DIR/config/users.yml"
    local CONFIG_FILE="$AUTHELIA_DIR/config/configuration.yml"

    if [ ! -f "$USERS_FILE" ]; then
        log_warning "No users.yml found at $USERS_FILE — install Authelia first."
        return 1
    fi

    local -a USERNAMES
    mapfile -t USERNAMES < <(_authelia_list_usernames "$USERS_FILE")
    if [ "${#USERNAMES[@]}" -eq 0 ]; then
        log_warning "No users found in $USERS_FILE."
        return 0
    fi

    echo ""
    echo "  Existing users:"
    local i=1 u
    for u in "${USERNAMES[@]}"; do
        echo "    $i) $u"
        i=$((i + 1))
    done
    echo ""
    local SEL=""
    prompt_text "  Select a user by number (blank to cancel):" "" SEL
    if [ -z "$SEL" ] || ! [[ "$SEL" =~ ^[0-9]+$ ]] || [ "$SEL" -lt 1 ] || [ "$SEL" -gt "${#USERNAMES[@]}" ]; then
        log_info "Cancelled."
        return 0
    fi
    local TARGET="${USERNAMES[$((SEL - 1))]}"

    local CONTINUE="y"
    while [[ "$CONTINUE" =~ ^[Yy]$ ]]; do
        local RANGE START END
        RANGE="$(_authelia_user_line_range "$USERS_FILE" "$TARGET")"
        START="${RANGE% *}"; END="${RANGE#* }"

        local IS_ADMIN="no"
        sed -n "${START},${END}p" "$USERS_FILE" | grep -q '^      - admins$' && IS_ADMIN="yes"
        local IS_EXEMPT="no"
        [ -f "$CONFIG_FILE" ] && grep -qF "subject: \"user:${TARGET}\"" "$CONFIG_FILE" && IS_EXEMPT="yes"

        echo ""
        echo "  Editing user: $TARGET   (admin: $IS_ADMIN, 2FA-exempt: $IS_EXEMPT)"
        echo "    1) Edit email / display name"
        echo "    2) Reset password"
        echo "    3) Reset 2FA device (they register a new one on next login)"
        if [ "$IS_EXEMPT" = "yes" ]; then
            echo "    4) Restore the 2FA requirement for this user"
        else
            echo "    4) Exempt this user from 2FA (one_factor only — weakens their account)"
        fi
        if [ "$IS_ADMIN" = "yes" ]; then
            echo "    5) Demote from admin"
        else
            echo "    5) Promote to admin"
        fi
        echo "    6) Done with this user"
        echo ""
        local ACTION=""
        prompt_text "  Choice [1-6]:" "6" ACTION

        case "$ACTION" in
            1)
                local CUR_EMAIL CUR_DISPLAY NEW_EMAIL NEW_DISPLAY
                CUR_EMAIL="$(sed -n "${START},${END}p" "$USERS_FILE" | grep '^    email:' | sed 's/^    email: *//')"
                CUR_DISPLAY="$(sed -n "${START},${END}p" "$USERS_FILE" | grep '^    displayname:' | sed 's/^    displayname: *//; s/^"//; s/"$//')"
                prompt_text "  New email [$CUR_EMAIL]:" "$CUR_EMAIL" NEW_EMAIL
                prompt_text "  New display name [$CUR_DISPLAY]:" "$CUR_DISPLAY" NEW_DISPLAY
                _authelia_set_user_field "$USERS_FILE" "$START" "$END" "email" "    email: ${NEW_EMAIL}"
                _authelia_set_user_field "$USERS_FILE" "$START" "$END" "displayname" "    displayname: \"${NEW_DISPLAY}\""
                chown 1000:1000 "$USERS_FILE" 2>/dev/null || true
                log_success "Updated $TARGET's email/display name."
                ;;
            2)
                log_info "Generating a new temporary password + hash..."
                local NEW_TEMP_PASS NEW_HASH
                NEW_TEMP_PASS="$(_authelia_gen_temp_password)"
                NEW_HASH=$(docker run --rm authelia/authelia:4.39.20 \
                    authelia crypto hash generate argon2 --password "$NEW_TEMP_PASS" 2>/dev/null \
                    | grep -oP '(?<=Digest: ).*')
                if [ -z "$NEW_HASH" ]; then
                    log_warning "Couldn't generate the password hash automatically — nothing changed. Try again."
                else
                    _authelia_set_user_field "$USERS_FILE" "$START" "$END" "password" "    password: \"${NEW_HASH}\""
                    chown 1000:1000 "$USERS_FILE" 2>/dev/null || true
                    log_success "Password reset for $TARGET."
                    echo "    New password: ${NEW_TEMP_PASS}"
                    echo "    Give this to them directly — shown once, not stored in plaintext anywhere."
                fi
                ;;
            3)
                if docker ps --format '{{.Names}}' | grep -q '^authelia$'; then
                    if docker exec authelia authelia storage user totp delete "$TARGET" --config /config/configuration.yml 2>/dev/null; then
                        log_success "TOTP device reset for $TARGET — they'll register a new one on next login."
                    else
                        log_warning "No TOTP device found for $TARGET (or the delete failed) — check: docker compose logs authelia"
                    fi
                    echo "  WebAuthn devices (if any) aren't covered by this option — reset those manually with:"
                    echo "    docker exec authelia authelia storage user webauthn delete --username $TARGET --config /config/configuration.yml"
                else
                    log_warning "Authelia isn't running — start it first: cd $AUTHELIA_DIR && docker compose up -d"
                fi
                ;;
            4)
                if [ "$IS_EXEMPT" = "yes" ]; then
                    _authelia_set_2fa_exempt "$CONFIG_FILE" "$TARGET" "restore"
                    log_success "Restored the two_factor requirement for $TARGET."
                else
                    local CONFIRM_EXEMPT=""
                    prompt_yn "  $TARGET will be able to log in with just a password (no 2FA) on every domain this instance protects. Continue? (y/n):" "n" CONFIRM_EXEMPT
                    if [[ "$CONFIRM_EXEMPT" =~ ^[Yy]$ ]]; then
                        _authelia_set_2fa_exempt "$CONFIG_FILE" "$TARGET" "exempt"
                        log_success "$TARGET no longer needs 2FA (one_factor only)."
                    else
                        log_info "Left as-is."
                    fi
                fi
                ;;
            5)
                if [ "$IS_ADMIN" = "yes" ]; then
                    _authelia_toggle_admin "$USERS_FILE" "$START" "$END" "false"
                    chown 1000:1000 "$USERS_FILE" 2>/dev/null || true
                    log_success "$TARGET demoted from admin."
                else
                    _authelia_toggle_admin "$USERS_FILE" "$START" "$END" "true"
                    chown 1000:1000 "$USERS_FILE" 2>/dev/null || true
                    log_success "$TARGET promoted to admin."
                fi
                ;;
            *)
                ACTION="6"
                ;;
        esac

        if [[ "$ACTION" =~ ^[1245]$ ]]; then
            local RESTART_AUTH=""
            prompt_yn "  Restart Authelia to apply this change? (y/n):" "y" RESTART_AUTH
            if [ "$RESTART_AUTH" = "y" ] || [ "$RESTART_AUTH" = "Y" ]; then
                (cd "$AUTHELIA_DIR" && docker compose restart authelia 2>/dev/null) \
                    && log_success "Authelia restarted" \
                    || log_warning "Restart failed — check: docker compose logs authelia"
            fi
            echo ""
            prompt_yn "  Do something else with $TARGET? (y/n):" "n" CONTINUE
        else
            CONTINUE="n"
        fi
    done
}

# Enables Authelia's OIDC PROVIDER feature — a distinct thing from the
# forward_auth (proxy-auth) setup install_authelia() already does. forward_auth
# gates a whole Caddy site behind an Authelia login page before the request
# ever reaches the app; OIDC provider mode is the opposite direction — an app
# with its OWN "Enable OpenID"/SSO setting (ActualBudget, Vaultwarden, etc.)
# delegates ITS login to Authelia instead of asking a user for a
# service-specific password. Neither replaces the other; a service can use
# either, both, or neither.
#
# One-time, idempotent (checked via the identity_providers: key already being
# present) — every _authelia_add_oidc_client() call runs this first so OIDC
# just works the first time an app is registered, no separate "enable OIDC"
# step to remember.
_authelia_ensure_oidc_provider() {
    local AUTHELIA_DIR="$1"
    local CONFIG_FILE="$AUTHELIA_DIR/config/configuration.yml"
    local SECRETS_DIR="$AUTHELIA_DIR/config/secrets"

    grep -q '^identity_providers:' "$CONFIG_FILE" 2>/dev/null && return 0

    log_info "Enabling Authelia's OIDC provider (one-time — lets other apps log in via Authelia)..."

    # hmac_secret: injected via a _FILE env var in docker-compose.yml, same
    # convention as jwt/session/storage secrets above — configuration.yml
    # itself never holds this one as a raw string. "Random Value: <value>"
    # is the exact (and only) line this subcommand prints — confirmed
    # against Authelia's own CLI source, not assumed.
    local _rand_out
    _rand_out="$(docker run --rm authelia/authelia:4.39.20 \
        authelia crypto rand --length 64 --charset alphanumeric 2>/dev/null)"
    echo "${_rand_out#Random Value: }" > "$SECRETS_DIR/oidc_hmac_secret"
    if [ ! -s "$SECRETS_DIR/oidc_hmac_secret" ]; then
        log_warning "Couldn't generate the OIDC HMAC secret — skipping OIDC provider setup. Re-run to try again."
        return 1
    fi
    chmod 600 "$SECRETS_DIR/oidc_hmac_secret"

    # RSA keypair for signing OIDC tokens (jwks). Authelia's schema requires
    # the private key inlined as PEM directly in configuration.yml — no
    # file-path or _FILE-env-var option for this specific nested field
    # (confirmed against the current identity_providers.oidc.jwks schema) —
    # so this generates into config/secrets/ for safe permissions, then reads
    # it back in below. "private.pem"/"public.pem" are the CLI's own default
    # output filenames (confirmed against Authelia's CLI reference), not
    # guessed.
    docker run --rm -u "$(id -u):$(id -g)" -v "$SECRETS_DIR":/keys \
        authelia/authelia:4.39.20 authelia crypto pair rsa generate --directory /keys >/dev/null 2>&1
    if [ ! -f "$SECRETS_DIR/private.pem" ]; then
        log_warning "Couldn't generate the OIDC signing key — skipping OIDC provider setup. Re-run to try again."
        return 1
    fi
    chmod 600 "$SECRETS_DIR/private.pem" "$SECRETS_DIR/public.pem" 2>/dev/null

    {
        echo ""
        echo "identity_providers:"
        echo "  oidc:"
        echo "    jwks:"
        echo "      - key_id: 'main'"
        echo "        algorithm: 'RS256'"
        echo "        use: 'sig'"
        echo "        key: |"
        sed 's/^/          /' "$SECRETS_DIR/private.pem"
        echo "    clients: []"
    } >> "$CONFIG_FILE"

    if ! grep -q 'AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE' "$AUTHELIA_DIR/docker-compose.yml"; then
        sed -i '/AUTHELIA_NOTIFIER_SMTP_SENDER/a\      - AUTHELIA_IDENTITY_PROVIDERS_OIDC_HMAC_SECRET_FILE=/config/secrets/oidc_hmac_secret' \
            "$AUTHELIA_DIR/docker-compose.yml"
    fi

    chown -R 1000:1000 "$AUTHELIA_DIR/config"
    chmod 600 "$CONFIG_FILE"
    log_success "OIDC provider enabled (signing key + HMAC secret generated)"
}

# Registers an OIDC client for another app to log in via Authelia — the
# "Other" provider option in an app's own "Enable OpenID"/SSO dialog. Presets
# below hand back the app's own known redirect URI path and the exact fields
# to paste where; "Other/custom" covers anything not listed (the app's own
# OIDC/SSO docs will say what redirect URI it expects).
_authelia_add_oidc_client() {
    local AUTHELIA_DIR="$DOCKER_DIR/authelia"
    local CONFIG_FILE="$AUTHELIA_DIR/config/configuration.yml"

    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "No configuration.yml found at $CONFIG_FILE — install Authelia first."
        return 1
    fi

    _authelia_ensure_oidc_provider "$AUTHELIA_DIR" || return 1

    # The apex domain this Authelia instance already serves — read back from
    # its own session.cookies (same structure install_authelia()/
    # add_authelia_domain() write), rather than asking again or assuming a
    # variable set earlier in this run is still in scope (this flow can be
    # reached standalone from the "already exists" menu with none of
    # install_authelia()'s own locals ever having run this session).
    local AUTHELIA_DOMAIN
    AUTHELIA_DOMAIN="$(awk '/^  cookies:$/{f=1; next} f && /domain:/{print $3; exit}' "$CONFIG_FILE")"
    if [ -z "$AUTHELIA_DOMAIN" ]; then
        log_warning "Couldn't determine this Authelia instance's domain from $CONFIG_FILE — aborting."
        return 1
    fi

    echo ""
    echo "  Register another app to log in via Authelia (OIDC/SSO)."
    echo ""
    echo "    1) ActualBudget"
    echo "    2) Vaultwarden"
    echo "    3) Other / custom app"
    echo ""
    local APP_CHOICE=""
    prompt_text "  Choice [1/2/3]:" "3" APP_CHOICE

    local APP_NAME="" CLIENT_ID="" REDIRECT_PATH=""
    case "$APP_CHOICE" in
        1) APP_NAME="ActualBudget"; CLIENT_ID="actualbudget"; REDIRECT_PATH="/openid/callback" ;;
        2) APP_NAME="Vaultwarden";  CLIENT_ID="vaultwarden";  REDIRECT_PATH="/identity/connect/oidc-signin" ;;
        *)
            prompt_text "  App name (for your reference):" "" APP_NAME
            [ -z "$APP_NAME" ] && { log_warning "No app name entered — nothing to do."; return 0; }
            CLIENT_ID="$(echo "$APP_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')"
            prompt_text "  Client ID [${CLIENT_ID}]:" "$CLIENT_ID" CLIENT_ID
            echo "  Check ${APP_NAME}'s own OIDC/SSO docs for its exact redirect URI path"
            echo "  (often something like /oauth/callback, /auth/callback, /sso/callback)."
            prompt_text "  Redirect URI path (starting with /):" "" REDIRECT_PATH
            ;;
    esac
    if [ -z "$CLIENT_ID" ] || [ -z "$REDIRECT_PATH" ]; then
        log_warning "Missing client ID or redirect path — nothing to do."
        return 0
    fi

    if grep -qF "client_id: '${CLIENT_ID}'" "$CONFIG_FILE" 2>/dev/null; then
        log_warning "A client with ID '$CLIENT_ID' is already registered in $CONFIG_FILE."
        log_warning "Pick a different app, or edit that entry by hand."
        return 0
    fi

    local APP_DOMAIN_DEFAULT="" APP_DOMAIN=""
    [ -n "${SITE_DOMAIN:-}" ] && [ "$SITE_DOMAIN" != "example.com" ] && APP_DOMAIN_DEFAULT="${CLIENT_ID}.${SITE_DOMAIN}"
    prompt_text "  Domain ${APP_NAME} is reachable at [${APP_DOMAIN_DEFAULT:-required}]:" "$APP_DOMAIN_DEFAULT" APP_DOMAIN
    if [ -z "$APP_DOMAIN" ]; then
        log_warning "No domain entered — nothing to do."
        return 0
    fi
    local REDIRECT_URI="https://${APP_DOMAIN}${REDIRECT_PATH}"

    local _2fa="" AUTH_POLICY="two_factor"
    prompt_yn "  Require two-factor for ${APP_NAME} logins too? (y/n):" "y" _2fa
    [[ "$_2fa" =~ ^[Yy]$ ]] || AUTH_POLICY="one_factor"

    log_info "Generating client secret..."
    local _hash_out CLIENT_SECRET_PLAIN CLIENT_SECRET_HASH
    _hash_out="$(docker run --rm authelia/authelia:4.39.20 \
        authelia crypto hash generate pbkdf2 --variant sha512 --random \
        --random.length 72 --random.charset rfc3986 2>/dev/null)"
    CLIENT_SECRET_PLAIN="$(echo "$_hash_out" | sed -n 's/^Random Password: //p')"
    CLIENT_SECRET_HASH="$(echo "$_hash_out" | sed -n 's/^Digest: //p')"
    if [ -z "$CLIENT_SECRET_PLAIN" ] || [ -z "$CLIENT_SECRET_HASH" ]; then
        log_warning "Couldn't generate the client secret automatically. Run manually, then add the"
        log_warning "client to $CONFIG_FILE's identity_providers.oidc.clients by hand:"
        echo "    docker run --rm authelia/authelia:4.39.20 authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986"
        return 1
    fi

    grep -q '^    clients: \[\]$' "$CONFIG_FILE" && sed -i 's/^    clients: \[\]$/    clients:/' "$CONFIG_FILE"

    local CLIENT_BLOCK="      - client_id: '${CLIENT_ID}'
        client_name: '${APP_NAME}'
        client_secret: '${CLIENT_SECRET_HASH}'
        public: false
        authorization_policy: '${AUTH_POLICY}'
        redirect_uris:
          - '${REDIRECT_URI}'
        scopes:
          - 'openid'
          - 'profile'
          - 'email'
        grant_types:
          - 'authorization_code'
        response_types:
          - 'code'
        response_modes:
          - 'query'
        userinfo_signed_response_alg: 'none'"

    awk -v block="$CLIENT_BLOCK" '
        { print }
        /^    clients:$/ && !done { print block; done=1 }
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    chown 1000:1000 "$CONFIG_FILE" 2>/dev/null || true

    local RESTART_AUTH=""
    prompt_yn "  Restart Authelia to apply? (y/n):" "y" RESTART_AUTH
    if [ "$RESTART_AUTH" = "y" ] || [ "$RESTART_AUTH" = "Y" ]; then
        (cd "$AUTHELIA_DIR" && docker compose restart authelia 2>/dev/null) \
            && log_success "Authelia restarted" \
            || log_warning "Restart failed — check: docker compose logs authelia"
    fi

    echo ""
    echo "  ${APP_NAME} is registered. Paste these into its OpenID/SSO settings"
    echo "  (choose \"Other\" as the provider if it's not listed by name):"
    echo ""
    echo "    Client ID:      ${CLIENT_ID}"
    echo "    Client Secret:  ${CLIENT_SECRET_PLAIN}"
    echo "    Discovery URL:  https://auth.${AUTHELIA_DOMAIN}/.well-known/openid-configuration"
    echo ""
    echo "  If it asks for individual endpoints instead of a discovery URL:"
    echo "    Authorization:  https://auth.${AUTHELIA_DOMAIN}/api/oidc/authorization"
    echo "    Token:          https://auth.${AUTHELIA_DOMAIN}/api/oidc/token"
    echo "    UserInfo:       https://auth.${AUTHELIA_DOMAIN}/api/oidc/userinfo"
    echo "    Scopes:         openid profile email"
    echo ""
    case "$APP_CHOICE" in
        1)
            echo "  ActualBudget's \"Enable OpenID\" dialog → provider \"Other\": paste the"
            echo "  Discovery URL, Client ID, and Client Secret above."
            echo "  First OIDC login becomes the ActualBudget server owner."
            echo ""
            ;;
        2)
            echo "  Add these to Vaultwarden's .env, then: cd \$VAULTWARDEN_DIR && docker compose up -d"
            echo "    SSO_ENABLED=true"
            echo "    SSO_AUTHORITY=https://auth.${AUTHELIA_DOMAIN}"
            echo "    SSO_CLIENT_ID=${CLIENT_ID}"
            echo "    SSO_CLIENT_SECRET=${CLIENT_SECRET_PLAIN}"
            echo "    SSO_SCOPES=profile email"
            echo "  Enabling SSO changes Vaultwarden's login flow for everyone on this"
            echo "  instance — see Vaultwarden's own SSO docs before turning this on for"
            echo "  a vault other people already use."
            echo ""
            ;;
    esac
    log_warning "The Client Secret above is shown once — it isn't stored in plaintext anywhere. Save it now."
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_authelia
