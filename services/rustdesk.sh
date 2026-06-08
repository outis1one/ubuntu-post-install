#!/bin/bash
# services/rustdesk.sh — RustDesk self-hosted remote desktop relay server.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash rustdesk.sh
# (Docker must already be installed when run standalone)
#
# RustDesk is an open-source TeamViewer alternative. This installs the
# SERVER-SIDE relay/rendezvous daemon — clients still need the RustDesk app.
# For cross-VLAN / cross-internet access, point RELAY at this server's FQDN.
#
# Ports that must reach this host (firewall/router):
#   21115 TCP  — NAT type test
#   21116 TCP  — ID register / heartbeat / relay rendezvous
#   21116 UDP  — UDP hole-punching
#   21117 TCP  — relay traffic (the "HBBR" relay daemon)
#   21118 TCP  — WebSocket (browser client support)
#   21119 TCP  — WebSocket HTTPS (browser client support)

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

register_service rustdesk utilities "Self-hosted remote desktop relay (RustDesk)" 21117

install_rustdesk() {
    require_docker || return 1
    log_info "Installing RustDesk server..."
    local RD_DIR="$DOCKER_DIR/rustdesk"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $RD_DIR (rustdesk_data/)"
        echo "[DRY-RUN] Would deploy rustdesk/rustdesk-server-s6:latest"
        echo "[DRY-RUN] Ports: 21115-21119 TCP, 21116 UDP"
        echo "[DRY-RUN] Would prompt for server FQDN/IP (RELAY env var)"
        return 0
    fi

    mkdir -p "$RD_DIR/rustdesk_data"
    ensure_docker_dir_ownership "$RD_DIR"
    cd "$RD_DIR" || return 1

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    echo ""
    echo "  RustDesk needs to know its own public hostname or IP."
    echo "  Clients will connect to this address for relay traffic."
    echo "  Use a FQDN if you have one (e.g. rustdesk.example.com),"
    echo "  or your server's public IP if not."
    echo ""
    local RELAY_HOST=""
    prompt_text "Public hostname or IP for this server:" "" RELAY_HOST
    if [ -z "$RELAY_HOST" ]; then
        log_warning "No relay host set — you MUST edit RELAY in .env before clients will work."
        RELAY_HOST="your-server-fqdn-or-ip"
    fi

    local ENCRYPTED_ONLY="1"
    local _enc=""
    prompt_yn "Require encrypted connections only? (recommended) (y/n):" "y" _enc
    [ "$_enc" = "n" ] || [ "$_enc" = "N" ] && ENCRYPTED_ONLY="0"

    cat > docker-compose.yml << 'RD_COMPOSE'
name: rustdesk

services:
  rustdesk:
    image: rustdesk/rustdesk-server-s6:latest
    container_name: rustdesk
    hostname: rustdesk
    restart: unless-stopped
    env_file: .env
    ports:
      - "21115:21115"
      - "21116:21116"
      - "21116:21116/udp"
      - "21117:21117"
      - "21118:21118"
      - "21119:21119"
    volumes:
      - ./rustdesk_data:/data
RD_COMPOSE

    cat > .env << RD_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL

# ── RustDesk server ───────────────────────────────────────────────────────────
# RELAY: public FQDN or IP that clients use to reach the relay daemon (HBBR).
# Include the port if it's non-standard: hostname:21117
RELAY=$RELAY_HOST:21117

# ENCRYPTED_ONLY: 1 = only clients with the matching public key can connect.
# After first startup, copy the key from ./rustdesk_data/id_ed25519.pub to
# each client: Settings → Network → Key.
ENCRYPTED_ONLY=$ENCRYPTED_ONLY

# KEY_PRIV and KEY_PUB — optional: paste key file contents here instead of
# relying on the volume-mounted file. Useful for portability.
# KEY_PRIV=<content of ./rustdesk_data/id_ed25519>
# KEY_PUB=<content of ./rustdesk_data/id_ed25519.pub>
RD_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$RD_DIR"
    log_success "RustDesk configured at $RD_DIR"

    write_readme "$RD_DIR" << MD
# RustDesk — self-hosted remote desktop relay

Open-source TeamViewer alternative. This is the server-side relay/rendezvous
daemon. Clients use the RustDesk desktop/mobile app to connect.

## After starting: get the public key

\`\`\`bash
cat $RD_DIR/rustdesk_data/id_ed25519.pub
\`\`\`

Paste this key into each client:
**Settings → Network → ID/Relay Server**
- ID Server:    $RELAY_HOST
- Relay Server: $RELAY_HOST
- Key:          <paste id_ed25519.pub contents>

## Firewall / router rules required

Open these ports to this server's IP:
| Port | Protocol | Purpose |
|------|----------|---------|
| 21115 | TCP | NAT type test |
| 21116 | TCP+UDP | ID register / hole-punching |
| 21117 | TCP | Relay traffic |
| 21118 | TCP | WebSocket |
| 21119 | TCP | WebSocket HTTPS |

## Cross-VLAN setup
Use the server's FQDN (not LAN IP) in RELAY so clients on any VLAN
or on the internet can reach the relay. DNS must resolve the FQDN to
the server's public IP.

## Manage
\`\`\`bash
cd $RD_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_RD=""
    prompt_yn "Start RustDesk server now? (y/n):" "y" START_RD
    if [ "$START_RD" = "y" ] || [ "$START_RD" = "Y" ]; then
        docker compose up -d \
            && log_success "RustDesk started" \
            || log_warning "Failed to start — check: docker compose logs"
        echo ""
        echo "  After startup, get the public key:"
        echo "    cat $RD_DIR/rustdesk_data/id_ed25519.pub"
        echo "  Paste it into client Settings → Network → Key."
    fi

    echo ""
    echo "  Relay host: $RELAY_HOST"
    echo "  Ports 21115-21119 must be open in your firewall/router."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_rustdesk
