#!/bin/bash
# services/wg-easy.sh — WireGuard VPN with a web management UI (wg-easy).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash wg-easy.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- WG-EASY ----).
# Own ~/docker/wg-easy/ with a standalone docker-compose.yml + .env.
# Requires cap_add: NET_ADMIN + SYS_MODULE and ip_forward sysctl.
# Forward UDP 51830 on your router to this server for external VPN access
# (default — scanned/moved at install time if already taken; see below).
#
# Default port deliberately isn't WireGuard's conventional 51820: Netbird's
# own WireGuard listener also defaults to exactly 51820, and this is the
# one service in this repo where two completely independent tools (this
# repo's own wg-easy and a separately-installed Netbird) are both likely to
# reach for the same hardcoded upstream default with no scanning of their
# own on Netbird's side. Starting one port family away avoids that
# collision in the common case; the scan below still moves both further if
# even the new default is somehow already taken.

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

register_service wg-easy utilities "WireGuard VPN with web management UI (wg-easy); peers mesh through this hub automatically, with a script to sync SSH aliases" 51831

install_wg-easy() {
    require_docker || return 1

    local WGEASY_DIR="$DOCKER_DIR/wg-easy"
    local WEB_PORT="51831" VPN_PORT="51830"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] wg-easy would:"
        echo "  - Create $WGEASY_DIR with docker-compose.yml + .env (config/)"
        echo "  - Auto-detect public IP for WG_HOST"
        echo "  - Generate a random web UI password"
        echo "  - Pin WG_DEFAULT_ADDRESS=10.8.0.x (subnet 10.8.0.0/24)"
        echo "  - Expose port 51831 (web UI) + 51830/udp (VPN), both auto-scanned if occupied"
        echo "  - Require router port-forward: UDP <VPN port> → this server"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        echo "  - Offer to also allow SSH from the VPN subnet (additive, doesn't remove public SSH)"
        echo "  - Write sync-ssh-aliases.sh — generates ~/.ssh/config aliases for connected peers"
        return 0
    fi

    # Scan for free host ports, moving both together — a plain install
    # shouldn't silently claim a port another already-running service holds.
    # Whatever VPN_PORT ends up as is what needs forwarding on the router
    # (the messaging below reflects the final value, not the 51830 default).
    # See CLAUDE.md's "Port collision avoidance" section.
    while port_in_use "$WEB_PORT" || port_in_use "$VPN_PORT" udp; do
        WEB_PORT=$((WEB_PORT + 1))
        VPN_PORT=$((VPN_PORT + 1))
    done

    mkdir -p "$WGEASY_DIR"
    ensure_docker_dir_ownership "$WGEASY_DIR"
    cd "$WGEASY_DIR" || return 1

    # Auto-detect public IP as default for WG_HOST
    local PUBLIC_IP WG_HOST WG_PASSWORD WG_PASSWORD_HASH
    PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "your-public-ip")
    WG_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    # Pinned explicitly (rather than left to wg-easy's own internal default)
    # so this script and the ufw rule below always agree on the subnet, even
    # if a future wg-easy image changes its own default.
    local WG_DEFAULT_ADDRESS="10.8.0.x"
    local WG_SUBNET_CIDR="10.8.0.0/24"

    prompt_text "Public IP or hostname for VPN [$PUBLIC_IP]:" "$PUBLIC_IP" WG_HOST

    # wg-easy v14+ requires PASSWORD_HASH (bcrypt). Generate via docker.
    log_info "Generating bcrypt password hash (requires Docker)..."
    WG_PASSWORD_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:latest wgpw "$WG_PASSWORD" 2>/dev/null \
        | grep -oP '\$2[ab]\$[^\s]+' | head -1)
    if [[ -z "$WG_PASSWORD_HASH" ]]; then
        log_warning "Could not generate bcrypt hash — falling back to plaintext PASSWORD env var."
        log_warning "If wg-easy fails to start, run: docker run --rm ghcr.io/wg-easy/wg-easy wgpw 'yourpassword'"
        log_warning "Then set PASSWORD_HASH in docker-compose.yml and remove PASSWORD."
    fi

    # Escape $ in hash for docker-compose env (bcrypt hashes contain $$)
    local WG_HASH_ESCAPED="${WG_PASSWORD_HASH//\$/\$\$}"

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_BLOCK=""
    local _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    cat > docker-compose.yml << WGEASY_COMPOSE
name: wg-easy

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    hostname: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - WG_HOST=\${WG_HOST}
      - PASSWORD_HASH=${WG_HASH_ESCAPED:-\${WG_PASSWORD}}
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_DEFAULT_ADDRESS=${WG_DEFAULT_ADDRESS}
      - WG_ALLOWED_IPS=0.0.0.0/0, ::/0
      - WG_PORT=${VPN_PORT}
    volumes:
      - ./config:/etc/wireguard
    ports:
      - "${VPN_PORT}:${VPN_PORT}/udp"
      - "${WEB_PORT}:51821/tcp"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
WGEASY_COMPOSE

    cat > .env << WGEASY_ENV
WG_HOST=$WG_HOST
# Plain-text password — used only if PASSWORD_HASH could not be generated above
WG_PASSWORD=$WG_PASSWORD
CADDY_NET=$SITE_CADDY_NET
WGEASY_ENV

    mkdir -p config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WGEASY_DIR"
    log_success "wg-easy configured at $WGEASY_DIR"

    configure_caddy_for_service "wg-easy" "wg-easy:51821" "vpn"

    # ── Optional: also allow SSH over this VPN's subnet ─────────────────────
    # Additive only — never narrows or removes the existing public SSH rule.
    # WG_ALLOWED_IPS=0.0.0.0/0 above already means every peer routes traffic
    # for every other peer through this hub by default (confirmed against
    # wg-easy's own docs/issue tracker: this is what makes client-to-client
    # routing "just work" with no extra config) — this rule is only about
    # giving SSH itself a path over that tunnel as an alternative to the
    # public one, not about enabling the mesh routing itself.
    if command -v ufw &>/dev/null; then
        local ADD_SSH_VPN=""
        prompt_yn "Also allow SSH from this VPN's subnet ($WG_SUBNET_CIDR)? Adds a rule; does NOT remove public SSH access — narrow that yourself once VPN access is confirmed working. (y/n):" "n" ADD_SSH_VPN
        if [[ "$ADD_SSH_VPN" =~ ^[Yy]$ ]]; then
            local _ssh_port
            _ssh_port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | tail -1 | awk '{print $2}')"
            _ssh_port="${_ssh_port:-22}"
            if ufw allow from "$WG_SUBNET_CIDR" to any port "$_ssh_port" proto tcp comment 'SSH via wg-easy VPN' >/dev/null 2>&1; then
                log_success "SSH reachable from $WG_SUBNET_CIDR (public SSH access is unchanged)"
                log_info "To require the VPN for SSH, narrow the public rule yourself once VPN access is confirmed:"
                log_info "  sudo ufw status numbered   # find the public SSH/OpenSSH rule"
                log_info "  sudo ufw delete <number>   # remove only after confirming VPN SSH works"
            else
                log_warning "Failed to add the UFW rule — add manually: ufw allow from $WG_SUBNET_CIDR to any port $_ssh_port proto tcp"
            fi
        fi
    fi

    # ── SSH alias sync script ────────────────────────────────────────────────
    # Reads connected peers from the live WireGuard interface (`wg show`
    # inside the container) rather than wg-easy's own internal client
    # storage — wg-easy's HTTP API is explicitly undocumented/unstable, and
    # its internal storage format has changed across versions, but `wg show`
    # is core wireguard-tools and stable regardless of wg-easy's version.
    # New peers are prompted for a friendly name once (cached in
    # peer-names.env); reruns only ask about genuinely new peers.
    cat > sync-ssh-aliases.sh << 'SYNCEOF'
#!/bin/bash
# ~/docker/wg-easy/sync-ssh-aliases.sh — generate ~/.ssh/config Host aliases
# for every connected wg-easy peer, so "ssh <name>" works without memorizing
# VPN IPs. Safe to re-run any time after adding a client in the web UI.
#
#   sudo ./sync-ssh-aliases.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMES_FILE="$HERE/peer-names.env"
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "$HOME")"
SSH_CFG="$ACTUAL_HOME/.ssh/config"

touch "$NAMES_FILE"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx wg-easy; then
    echo "wg-easy container isn't running — start it first: docker compose up -d"
    exit 1
fi

echo "Reading connected peers from the live WireGuard interface..."
DUMP="$(docker exec wg-easy wg show wg0 dump 2>/dev/null | tail -n +2)"
if [ -z "$DUMP" ]; then
    echo "No peers found — add a client in the wg-easy web UI first, then re-run this."
    exit 0
fi

ADDED=0
while IFS=$'\t' read -r PUBKEY _PSK _ENDPOINT ALLOWED_IPS _REST; do
    [ -n "$PUBKEY" ] || continue
    IP="${ALLOWED_IPS%%/*}"
    [ -n "$IP" ] || continue

    NAME="$(grep "^${PUBKEY}=" "$NAMES_FILE" 2>/dev/null | cut -d= -f2)"
    if [ -z "$NAME" ]; then
        echo ""
        echo "New peer: $IP (public key ${PUBKEY:0:12}...)"
        read -r -p "  Name for an SSH alias (blank to skip this peer): " NAME
        [ -n "$NAME" ] || continue
        echo "${PUBKEY}=${NAME}" >> "$NAMES_FILE"
    fi

    if [ -f "$SSH_CFG" ] && grep -qiE "^Host[[:space:]]+${NAME}([[:space:]]|\$)" "$SSH_CFG"; then
        echo "  '$NAME' already in $SSH_CFG (if its IP changed to $IP, edit the entry manually)."
        continue
    fi

    mkdir -p "$(dirname "$SSH_CFG")"; touch "$SSH_CFG"
    chmod 700 "$(dirname "$SSH_CFG")"; chmod 600 "$SSH_CFG"
    {
        echo ""
        echo "Host $NAME"
        echo "    HostName $IP"
        echo "    User $ACTUAL_USER"
    } >> "$SSH_CFG"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$(dirname "$SSH_CFG")" 2>/dev/null || true
    echo "  Added: ssh $NAME  ->  $ACTUAL_USER@$IP"
    ADDED=$((ADDED+1))
done <<< "$DUMP"

chown "$ACTUAL_USER:$ACTUAL_USER" "$NAMES_FILE" 2>/dev/null || true
echo ""
echo "Done — $ADDED new alias(es) added. Re-run any time after adding a peer in the wg-easy web UI."
SYNCEOF
    chmod +x sync-ssh-aliases.sh
    chown "$ACTUAL_USER:$ACTUAL_USER" sync-ssh-aliases.sh

    write_readme "$WGEASY_DIR" << MD
# wg-easy

WireGuard VPN with a web UI for managing clients, generating QR codes,
and monitoring connections.

- Web UI: http://localhost:${WEB_PORT}
- VPN:    UDP port ${VPN_PORT} (forward this on your router)
- Password: stored in \`.env\` (\`WG_PASSWORD\`)
- VPN host: \`$WG_HOST\` (update \`WG_HOST\` in .env if your IP changes)
- VPN subnet: \`$WG_SUBNET_CIDR\`
- Config: \`config/\`

## Manage
\`\`\`bash
cd $WGEASY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Router setup
Forward **UDP port ${VPN_PORT}** to this server's LAN IP for external VPN access.

## Adding clients
Open http://localhost:${WEB_PORT}, log in with your password, click "+ New Client",
download or scan the QR code with the WireGuard app.

## Mesh — peers reach each other automatically
Every client is created with \`WG_ALLOWED_IPS=0.0.0.0/0, ::/0\`, so each peer
routes traffic for every other peer through this VPS by default — no manual
per-pair setup needed, any enrolled device can already reach any other
enrolled device once both are connected. Traffic between two peers takes one
hop through this VPS (not a direct connection between them); for SSH-sized
traffic that's irrelevant.

If you later enable wg-easy's **Per-Client Firewall** feature (Admin Panel →
Interface) or manually narrow a specific client's Allowed IPs, that client
loses this automatic mesh reachability — add the VPN subnet (\`$WG_SUBNET_CIDR\`)
back to its Allowed IPs / Firewall Allowed IPs to restore it.

## SSH aliases for connected peers
Run \`./sync-ssh-aliases.sh\` any time after adding a client in the web UI —
it reads currently-connected peers straight off the WireGuard interface,
asks for a friendly name the first time it sees each one, and adds a
matching \`Host\` entry to \`~/.ssh/config\` so \`ssh <name>\` works without
memorizing IPs. Name choices are cached in \`peer-names.env\` so reruns only
ask about genuinely new peers.

## SSH over the VPN
$( [[ "${ADD_SSH_VPN:-}" =~ ^[Yy]$ ]] && echo "SSH (port 22) is also reachable from \`$WG_SUBNET_CIDR\` in addition to the public internet — that's additive, your existing public SSH access is untouched. To require the VPN for SSH: verify VPN access works, then find and remove the public SSH rule yourself (\`sudo ufw status numbered\`, then \`sudo ufw delete <number>\`) — this is deliberately a manual last step so a misconfigured VPN can't lock you out." || echo "Not enabled for this install. Re-run this installer and answer yes to the SSH-over-VPN prompt, or add it manually: \`sudo ufw allow from $WG_SUBNET_CIDR to any port 22 proto tcp\`." )
MD

    local START_WGEASY=""
    prompt_yn "Start wg-easy now? (y/n):" "y" START_WGEASY
    if [ "$START_WGEASY" = "y" ] || [ "$START_WGEASY" = "Y" ]; then
        docker compose up -d && log_success "wg-easy started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Web UI:   http://localhost:${WEB_PORT}"
    echo "  Password: $WG_PASSWORD  (saved in .env)"
    [[ -n "$WG_PASSWORD_HASH" ]] && echo "  Auth:     bcrypt hash configured (v14+ compatible)" \
        || echo "  Auth:     WARNING — bcrypt hash generation failed; see README"
    echo "  Router:   forward UDP ${VPN_PORT} → this server for external VPN access"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wg-easy
