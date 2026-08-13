#!/bin/bash
# attic/coturn.sh — RETIRED. Formerly services/coturn.sh.
#
# The shared-coturn model this file implements is no longer offered by this
# repo at all: services/asterisk.sh and services/mattermost.sh each now run
# their own dedicated coturn unconditionally, with lib/common.sh's
# find_free_coturn_range() making that safe (it scans every coturn-owning
# service's own .env on the box for already-claimed relay ranges and picks
# a block that can't collide with any of them, dedicated or shared). Sharing
# one instance only ever saved ~40MB RAM per additional consumer beyond the
# first — real, but small — and it was a single point of failure every
# consumer depended on. Parked here, not deleted, since the code is still
# correct and someone could resurrect it if a future need for it shows up;
# living in attic/ (outside services/*.sh's glob) means it never
# self-registers, never appears in the menu, and `sudo ./setup.sh coturn`
# now correctly fails with "unknown service" instead of silently offering
# a coturn shape nothing else in this repo will register a user against.
#
# ── Everything below this point is the file exactly as it ran before
#    retirement, kept for reference/rollback, not actively maintained. ────────
#
# Can still be run standalone on any machine, same as before:
#   sudo bash attic/coturn.sh
# (Docker must already be installed when run standalone) — but nothing in
# this repo will call ensure_coturn_user() to register with it anymore, so
# doing this only makes sense if you're deliberately reintroducing the
# shared-coturn pattern yourself.
#
# One coturn instance, shared by every service that needs TURN (Asterisk,
# Mattermost, and anything added later) instead of each service running its
# own — which used to mean N containers all on network_mode: host fighting
# over relay port ranges (confirmed live: Asterisk's default range and
# Mattermost's default range overlapped by ~100 ports before this existed).
#
# Runs in long-term-credential mode (--lt-cred-mech) with a SQLite user
# database instead of a single static user — every consumer registers its
# own dedicated username/password via ensure_coturn_user() (lib/common.sh),
# so credentials are per-service and one consumer being compromised or
# reconfigured doesn't affect any other's TURN access.
#
# Deliberately NOT --use-auth-secret (the HMAC/REST-API mode Mattermost's
# Calls plugin also supports): coturn does not support both auth mechanisms
# on one running instance at once — turning on --use-auth-secret silently
# overrides --lt-cred-mech server-wide, which would break every
# static-credential consumer (Asterisk's PJSIP TURN client wants a fixed
# long-lived username/password, not a periodically-regenerated HMAC one).
# lt-cred-mech supports any number of named users out of the box, which is
# exactly the shared-multi-consumer shape this needs — no tradeoff either
# way. Mattermost's Calls plugin is configured with a static username/
# credential pair too (its "ICE Servers Configurations" field), not its
# "TURN Static Auth Secret" field, so both consumers use the same mechanism.

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

        prompt_reinstall_mode() {
            local _var="$1" _r
            if [[ "${UNATTENDED:-false}" == "true" ]]; then eval "$_var='cancel'"; return; fi
            echo "  Existing install detected. Choose:"
            echo "    u) Update — refresh vendor files, keep existing settings"
            echo "    f) Full reinstall — re-run every prompt from scratch"
            echo "    c) Cancel — leave everything as-is [default]"
            read -r -p "  Choice [u/f/c, Enter=cancel]: " _r
            case "${_r,,}" in
                u) eval "$_var='update'" ;;
                f) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$_dir/README.md" 2>/dev/null || true
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
        }

        ensure_ufw_enabled() {
            command -v ufw &>/dev/null || return 0
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            ufw status 2>/dev/null | grep -q "Status: active" && return 0
            local _ssh_port
            _ssh_port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')"
            ufw allow "${_ssh_port:-22}/tcp" comment 'SSH' >/dev/null 2>&1
            ufw --force enable >/dev/null 2>&1
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service coturn homelab "Shared TURN/STUN relay (coturn) for Asterisk, Mattermost, and other WebRTC-capable services" 3478

install_coturn() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/coturn"
    local ENV_FILE="$DIR/.env"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Shared coturn (TURN/STUN relay)                     ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "  One TURN server, shared by every service that needs one (Asterisk,"
    echo "  Mattermost Calls, anything added later) — each gets its own"
    echo "  dedicated username/password, registered automatically the first"
    echo "  time that service is installed. You normally don't run this"
    echo "  directly; another service's installer chains into it."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml + .env"
        echo "[DRY-RUN] Would run coturn in --lt-cred-mech mode with a SQLite user database"
        echo "[DRY-RUN] Would open UFW: 3478/udp+tcp, and the relay port range udp"
        return 0
    fi

    # ── Update vs. fresh reinstall ─────────────────────────────────────────────
    # "update" only refreshes the image/compose shape — realm, host, port
    # range, and every registered consumer's credentials are left exactly as
    # they are. Rotating any of those here would silently break TURN for
    # every service already relying on this instance (Asterisk phones,
    # Mattermost Calls) without those services knowing to reconfigure.
    local MODE="fresh"
    if [[ -f "$DIR/docker-compose.yml" && -f "$ENV_FILE" ]]; then
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing the coturn image/compose only — realm, host, port range, and"
                log_info "every registered consumer's credentials are left exactly as they are."
                ;;
            cancel)
                log_info "Leaving the existing coturn install as-is."
                return 0
                ;;
            fresh)
                echo ""
                log_warning "A full reinstall regenerates nothing destructive by itself, but if you"
                log_warning "change the host/port/realm below, every already-registered consumer"
                log_warning "(Asterisk, Mattermost, ...) keeps pointing at the OLD values in its own"
                log_warning ".env until you re-run that service's installer too."

                local _consumers=""
                [ -d "$DIR/users" ] && _consumers="$(find "$DIR/users" -maxdepth 1 -name '*.env' -printf '%f\n' 2>/dev/null | sed 's/\.env$//' | tr '\n' ' ')"
                if [ -n "$_consumers" ]; then
                    echo ""
                    log_info "Registered consumers: $_consumers"
                    local _WIPE_USERS=""
                    prompt_yn "  Also delete all TURN user credentials and the user database (forces every consumer above to re-register)? (y/n):" "n" _WIPE_USERS
                    if [[ "$_WIPE_USERS" =~ ^[Yy]$ ]]; then
                        rm -rf "$DIR/users" "$DIR/db"
                        mkdir -p "$DIR/db" "$DIR/users"
                        # The running container (if any) still holds the old,
                        # now-deleted turndb file open — new turnadmin writes
                        # to the fresh file at that path go unseen until the
                        # server process restarts and reopens it.
                        docker restart coturn >/dev/null 2>&1
                        log_warning "Deleted TURN credentials and the user database."
                        log_warning "Re-run each consumer's installer in Update mode afterward —"
                        log_warning "ensure_coturn_user() auto-recovers a fresh credential for it."
                    fi
                fi
                ;;
        esac
    fi

    mkdir -p "$DIR/db" "$DIR/users"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local COTURN_REALM="" COTURN_HOST="" COTURN_PORT="3478"
    local COTURN_MIN_PORT="49152" COTURN_MAX_PORT="49452"

    if [ "$MODE" = "update" ]; then
        # shellcheck source=/dev/null
        source "$ENV_FILE"
    else
        local _default_realm="${SITE_DOMAIN:-localhost}"
        prompt_text "  Realm (usually your domain, or 'localhost' for LAN-only):" "$_default_realm" COTURN_REALM

        local _detected_ip
        _detected_ip="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
        prompt_text "  Public hostname/IP TURN clients should connect to:" "$_detected_ip" COTURN_HOST

        prompt_text "  Listening port:" "3478" COTURN_PORT
        prompt_text "  Relay port range — min:" "49152" COTURN_MIN_PORT
        prompt_text "  Relay port range — max (each concurrent relayed call needs ~1 port; 300 ports is generous for a homelab):" "49452" COTURN_MAX_PORT
    fi

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'EOF'
name: coturn

services:
  coturn:
    image: coturn/coturn:latest
    container_name: coturn
    network_mode: host
    user: root
    env_file: .env
    volumes:
      - ./db:/var/lib/coturn
    command:
      - -n
      - --listening-port=${COTURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --userdb=/var/lib/coturn/turndb
      - --realm=${COTURN_REALM:-localhost}
      - --min-port=${COTURN_MIN_PORT:-49152}
      - --max-port=${COTURN_MAX_PORT:-49452}
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped
EOF

    cat > "$ENV_FILE" << ENVEOF
TZ=$TZ_VAL

# ── Identity — read by lib/common.sh's ensure_coturn_user() ────────────────
# Changing these after consumers already registered breaks TURN for them
# until each one is reconfigured — see the warning above before editing.
COTURN_REALM=$COTURN_REALM
COTURN_HOST=$COTURN_HOST
COTURN_PORT=$COTURN_PORT
COTURN_MIN_PORT=$COTURN_MIN_PORT
COTURN_MAX_PORT=$COTURN_MAX_PORT
ENVEOF
    chmod 600 "$ENV_FILE"
    chown "$ACTUAL_USER:$ACTUAL_USER" docker-compose.yml "$ENV_FILE"

    log_success "coturn configured at $DIR"

    # ── Firewall ──────────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow "${COTURN_PORT}/udp" comment 'coturn TURN/STUN' >/dev/null 2>&1
        ufw allow "${COTURN_PORT}/tcp" comment 'coturn TURN/STUN' >/dev/null 2>&1
        ufw allow "${COTURN_MIN_PORT}:${COTURN_MAX_PORT}/udp" comment 'coturn relay' >/dev/null 2>&1
        log_success "UFW: opened ${COTURN_PORT}/udp+tcp and ${COTURN_MIN_PORT}-${COTURN_MAX_PORT}/udp"
        ensure_ufw_enabled
    fi

    # ── Admin helper: list/add/remove consumers without touching compose ───────
    cat > coturn_user.sh << 'USEREOF'
#!/bin/bash
# ~/docker/coturn/coturn_user.sh — manage TURN users in the shared coturn's
# SQLite user database. Most services register themselves automatically via
# ensure_coturn_user() (lib/common.sh) at install time — this is for manual
# inspection/cleanup.
#
#   sudo ./coturn_user.sh list
#   sudo ./coturn_user.sh add <name> <password>
#   sudo ./coturn_user.sh remove <name>
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$HERE/.env"

case "${1:-}" in
    list)
        docker exec coturn turnadmin -l -b /var/lib/coturn/turndb
        ;;
    add)
        [ -n "${2:-}" ] && [ -n "${3:-}" ] || { echo "Usage: $0 add <name> <password>"; exit 1; }
        docker exec coturn turnadmin -a -u "$2" -p "$3" -r "$COTURN_REALM" -b /var/lib/coturn/turndb \
            && echo "Added: $2" \
            || echo "Failed to add $2 — is the coturn container running?"
        ;;
    remove)
        [ -n "${2:-}" ] || { echo "Usage: $0 remove <name>"; exit 1; }
        docker exec coturn turnadmin -d -u "$2" -r "$COTURN_REALM" -b /var/lib/coturn/turndb \
            && { echo "Removed: $2"; rm -f "$HERE/users/$2.env"; } \
            || echo "Failed to remove $2"
        ;;
    *)
        echo "Usage: $0 {list|add <name> <password>|remove <name>}"
        exit 1
        ;;
esac
USEREOF
    chmod +x coturn_user.sh
    chown "$ACTUAL_USER:$ACTUAL_USER" coturn_user.sh

    write_readme "$DIR" << MD
# coturn — shared TURN/STUN relay

One coturn instance shared by every service on this box that needs TURN
(Asterisk, Mattermost Calls, anything added later) — instead of each running
its own and fighting over host ports for the relay range.

Runs in long-term-credential mode with a SQLite user database. Each
consumer gets its own dedicated username/password, registered automatically
by that service's installer via \`ensure_coturn_user()\` — you don't
normally need to touch this directly.

## Identity
- Realm: \`$COTURN_REALM\`
- Host clients connect to: \`$COTURN_HOST\`
- Listening port: \`$COTURN_PORT\`
- Relay port range: \`$COTURN_MIN_PORT-$COTURN_MAX_PORT\` (udp)

**Changing any of the above breaks TURN for every already-registered
consumer until that service's installer is re-run** — they cache the host/
port/credentials in their own \`.env\` at registration time, not read live.

## Manage users
\`\`\`bash
sudo ./coturn_user.sh list
sudo ./coturn_user.sh add <name> <password>
sudo ./coturn_user.sh remove <name>
\`\`\`
Per-consumer credentials are also cached in \`users/<name>.env\` (chmod 600)
so a service re-running its own installer reuses the same credential
instead of silently minting a new one and orphaning the old.

## Manage the container
\`\`\`bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
\`\`\`

## Adding a new service that needs TURN
In that service's \`install_<name>()\`, after \`require_docker\`:
\`\`\`bash
ensure_coturn_user "my-service"
if [ -n "\$COTURN_HOST" ]; then
    # COTURN_HOST / COTURN_PORT / COTURN_USERNAME / COTURN_PASSWORD are set
    # (not local — read them after the call returns, same convention as
    # configure_caddy_for_service's CADDY_SERVICE_* out-params)
else
    # coturn unavailable — degrade gracefully (no TURN, or prompt to run
    # \`sudo ./setup.sh coturn\` first)
fi
\`\`\`
MD

    local START=""
    prompt_yn "Start coturn now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "coturn started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  Realm: $COTURN_REALM   Host: $COTURN_HOST   Port: $COTURN_PORT"
    echo "  Relay range: $COTURN_MIN_PORT-$COTURN_MAX_PORT/udp"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_coturn
