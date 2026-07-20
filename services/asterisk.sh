#!/bin/bash
# services/asterisk.sh — Easy Asterisk PBX + coturn TURN server (home intercom/VoIP).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash asterisk.sh
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
            if [[ "${UNATTENDED:-false}" == "true" ]]; then
                eval "$_var='cancel'"
                echo "Existing install detected — leaving it as-is [auto: cancel, unattended mode]"
                return
            fi
            echo "  Existing install detected. Choose:"
            echo "    r) Reinstall in place — refresh vendor files/config, keep existing settings"
            echo "    f) Full install — re-run every prompt from scratch"
            echo "    c) Cancel — leave everything as-is [default]"
            read -r -p "  Choice [r/f/c, Enter=cancel]: " _r
            case "${_r,,}" in
                r) eval "$_var='update'" ;;
                f) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

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

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

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
                # The template Caddyfile ships with "admin off", so `caddy
                # reload` (which needs that same admin API) never actually
                # works here. Try it anyway, fall back to a restart.
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                elif docker restart caddy &>/dev/null; then
                    log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                    log_success "$_name should be accessible at: https://$_domain"
                else
                    log_warning "Reload/restart failed — check: docker logs caddy"
                    log_info "Manual fix: docker restart caddy"
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
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service asterisk homelab "Easy Asterisk PBX + coturn TURN server (home intercom/VoIP)" 5061

# ── Shared: vendor file refresh ────────────────────────────────────────────
# Called from both a fresh install and an "update in place" run, so a single
# copy of this logic stays current for both instead of drifting apart. Must
# be called with $PWD already at $EA_DIR.
_asterisk_refresh_vendor_files() {
    mkdir -p docker scripts

    local _SELF_DIR_LOCAL
    _SELF_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local VENDOR_DIR="$_SELF_DIR_LOCAL/../vendor/easy-asterisk"

    if [[ -d "$VENDOR_DIR" ]]; then
        log_info "Copying vendor files from $VENDOR_DIR ..."
        cp "$VENDOR_DIR/Dockerfile"                    ./Dockerfile
        cp "$VENDOR_DIR/docker/entrypoint.sh"          ./docker/entrypoint.sh
        cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"   ./docker/coturn-entrypoint.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk-v0.10.0.sh
        cp "$VENDOR_DIR/scripts/vpn-diagnostics.sh"    ./scripts/vpn-diagnostics.sh
        cp "$VENDOR_DIR/scripts/dns-whitelist.sh"      ./scripts/dns-whitelist.sh
    else
        log_info "Vendor directory not found — downloading from GitHub ..."
        local GH_RAW="https://raw.githubusercontent.com/DeadDork/easy-asterisk/main"
        curl -fsSL "$GH_RAW/Dockerfile"                        -o ./Dockerfile
        curl -fsSL "$GH_RAW/docker/entrypoint.sh"              -o ./docker/entrypoint.sh
        curl -fsSL "$GH_RAW/docker/coturn-entrypoint.sh"       -o ./docker/coturn-entrypoint.sh
        curl -fsSL "$GH_RAW/easy-asterisk-v0.10.0.sh"          -o ./easy-asterisk.sh
        curl -fsSL "$GH_RAW/scripts/vpn-diagnostics.sh"        -o ./scripts/vpn-diagnostics.sh
        curl -fsSL "$GH_RAW/scripts/dns-whitelist.sh"          -o ./scripts/dns-whitelist.sh
        cp ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh
    fi

    chmod 755 ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh \
              ./docker/entrypoint.sh ./docker/coturn-entrypoint.sh \
              ./scripts/vpn-diagnostics.sh ./scripts/dns-whitelist.sh
}

# ── Shared: docker-compose.yml ─────────────────────────────────────────────
# Same reasoning as above — one copy of the template used by both fresh
# installs and updates. Must be called with $PWD already at $EA_DIR.
# HAS_VLANS_VAL/VLAN_SUBNETS_VAL aren't referenced here — they live only in
# .env, which the entrypoint reads at container start.
_asterisk_write_compose() {
    cat > docker-compose.yml << 'EOF'
name: asterisk

services:
  asterisk:
    build: .
    container_name: easy-asterisk
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - ./config/asterisk:/etc/asterisk
      - ./config/easy-asterisk:/etc/easy-asterisk
      - ./logs:/var/log/asterisk
      - ./spool:/var/spool/asterisk
      - ./lib:/var/lib/asterisk
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
      - ./exports:/root
CADDY_VOLUME_PLACEHOLDER
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    env_file: .env
    command:
      - -n
      - --listening-port=${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=${TURN_USERNAME:-easyasterisk}:${TURN_PASSWORD}
      - --realm=${DOMAIN_NAME:-localhost}
      - --min-port=49152
      - --max-port=49252
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

EOF

    # Share Caddy's cert store (read-only) so the entrypoint can auto-sync a
    # real Let's Encrypt cert for DOMAIN_NAME instead of falling back to
    # self-signed. No-op if Caddy isn't installed on this box.
    if [[ -d "$DOCKER_DIR/caddy/data" ]]; then
        sed -i "s#CADDY_VOLUME_PLACEHOLDER#      - ${DOCKER_DIR}/caddy/data:/caddy-data:ro#" docker-compose.yml
    else
        sed -i "/CADDY_VOLUME_PLACEHOLDER/d" docker-compose.yml
    fi
}

install_asterisk() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn..."

    local EA_DIR="$DOCKER_DIR/asterisk"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk"
        echo "[DRY-RUN] Would scan for a free web admin port starting at 8081 (avoids e.g. CrowdSec's 8080)"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, <web admin port>, 8088, 8089, 3478, 10000-20000, 49152-49252"
        echo "[DRY-RUN] Would offer 'update in place' instead of a fresh install if $EA_DIR already exists"
        return 0
    fi

    # ── Existing install? Offer update-in-place instead of a full reinstall ───
    # A fresh install re-runs every prompt (networking mode, domain, VLANs,
    # Authelia). An update only refreshes vendor files + docker-compose.yml —
    # picking up fixes like this one — and rebuilds, without touching .env,
    # UFW, or the Caddy/Authelia config already in place.
    if [[ -f "$EA_DIR/docker-compose.yml" && -f "$EA_DIR/.env" ]]; then
        echo ""
        log_info "Existing install found at $EA_DIR."
        local REINSTALL_MODE=""
        prompt_reinstall_mode REINSTALL_MODE
        case "$REINSTALL_MODE" in
            update)
                mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
                         "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
                ensure_docker_dir_ownership "$EA_DIR"
                cd "$EA_DIR" || return 1

                _asterisk_refresh_vendor_files
                _asterisk_write_compose

                log_info "Rebuilding and restarting containers..."
                if docker compose up -d --build --force-recreate; then
                    log_success "Update complete — vendor files and docker-compose.yml refreshed."
                else
                    log_warning "docker compose up failed — check: docker compose -f $EA_DIR/docker-compose.yml logs"
                fi

                local _EXISTING_DOMAIN _EXISTING_PORT
                _EXISTING_DOMAIN="$(grep -E '^DOMAIN_NAME=' .env | cut -d= -f2-)"
                _EXISTING_PORT="$(grep -E '^WEB_ADMIN_PORT=' .env | cut -d= -f2-)"
                echo ""
                log_success "Existing .env, UFW rules, and Caddy/Authelia config were left untouched."
                if [[ -n "$_EXISTING_DOMAIN" ]]; then
                    echo "  Web admin: https://${_EXISTING_DOMAIN}/"
                else
                    echo "  Web admin: http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):${_EXISTING_PORT:-8081}"
                fi
                echo "  Logs:      docker compose -f $EA_DIR/docker-compose.yml logs -f"
                echo ""
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is — nothing changed."
                return 0
                ;;
            fresh)
                log_info "Proceeding with a full fresh reinstall — every prompt below runs from scratch."
                ;;
        esac
    fi

    mkdir -p "$EA_DIR"
    mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
             "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    _asterisk_refresh_vendor_files

    # ── Networking mode ───────────────────────────────────────────────────────
    echo ""
    echo "  Networking mode:"
    echo "    1) FQDN (recommended) — TLS + TURN relay, every phone connects the"
    echo "                            same way regardless of LAN/VLAN/remote"
    echo "    2) LAN-only           — no domain, self-signed cert, local network/VPN only"
    local HA_NETMODE=""
    prompt_text "Choose [1]:" "1" HA_NETMODE

    local DOMAIN_NAME=""
    if [[ "$HA_NETMODE" != "2" ]]; then
        prompt_text "FQDN (e.g. asterisk.${SITE_DOMAIN:-example.com}) [blank=fall back to LAN-only]:" "" DOMAIN_NAME
        [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — proceeding in LAN-only mode."
    fi

    # ── Local networks / VLANs ────────────────────────────────────────────────
    # Feeds HAS_VLANS/VLAN_SUBNETS into .env, which the entrypoint reads to add
    # extra local_net= entries in pjsip.conf so phones on those subnets get
    # correct NAT/SDP handling (this is what fixes the "no sound" symptom for
    # devices on a VLAN the server isn't itself attached to).
    echo ""
    echo "  Detecting networks this host can see..."
    local DETECTED_NETS=""
    DETECTED_NETS="$(ip -o -f inet addr show scope global 2>/dev/null \
        | awk '{print $2, $4}' \
        | grep -Ev '^(docker|br-|veth|tun|tap|wg)' \
        | awk '{ split($2,a,"/"); split(a[1],o,"."); print o[1]"."o[2]"."o[3]".0/"a[2] }' \
        | sort -u)"
    if [[ -n "$DETECTED_NETS" ]]; then
        echo "  This host is directly attached to:"
        echo "$DETECTED_NETS" | sed 's/^/    /'
    fi
    echo "  Phones on OTHER VLANs (this server usually can't see those directly)"
    echo "  still need to be listed here so their media is treated as local/trusted."
    local VLAN_SUBNETS_VAL=""
    prompt_text "VLAN/VPN subnets, space-separated CIDRs [blank=none]:" "" VLAN_SUBNETS_VAL
    local HAS_VLANS_VAL="n"
    [[ -n "$VLAN_SUBNETS_VAL" ]] && HAS_VLANS_VAL="y"

    # ── Secrets ───────────────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(generate_password 24)"

    local TURN_SERVER_VAL=""
    [[ -n "$DOMAIN_NAME" ]] && TURN_SERVER_VAL="${DOMAIN_NAME}:3478"

    _asterisk_write_compose

    # ── Pick a free port for the web admin ─────────────────────────────────────
    # Hardcoding a single number gets fragile fast once several services share
    # a host — CrowdSec's own LAPI already collides with 8080 by default (its
    # own upstream default, confirmed against its real config.yaml). Scan
    # instead: start at 8081 and take the first port nothing is listening on,
    # capped so a pathological box can't spin this forever.
    local WEB_ADMIN_PORT_VAL=8081
    local _port_scan_limit=$((WEB_ADMIN_PORT_VAL + 100))
    while ss -tlnH "sport = :${WEB_ADMIN_PORT_VAL}" 2>/dev/null | grep -q . \
          && [[ "$WEB_ADMIN_PORT_VAL" -lt "$_port_scan_limit" ]]; do
        WEB_ADMIN_PORT_VAL=$((WEB_ADMIN_PORT_VAL + 1))
    done
    if [[ "$WEB_ADMIN_PORT_VAL" -ge "$_port_scan_limit" ]]; then
        log_warning "No free port found in 8081-${_port_scan_limit} — falling back to 8081 anyway."
        WEB_ADMIN_PORT_VAL=8081
    elif [[ "$WEB_ADMIN_PORT_VAL" != 8081 ]]; then
        log_info "Port 8081 was already taken — web admin will use ${WEB_ADMIN_PORT_VAL} instead."
    fi

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# Set to your FQDN for remote access. Leave empty for LAN-only.
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
TURN_USERNAME=easyasterisk
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=3478
# For LAN-only: TURN_SERVER is empty. For FQDN: set to domain:3478
TURN_SERVER=${TURN_SERVER_VAL}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── VLAN/VPN subnets ──────────────────────────────────────────
# Extra local_net= entries for phones on networks this server isn't
# itself attached to. Space-separated CIDRs.
HAS_VLANS=${HAS_VLANS_VAL}
VLAN_SUBNETS=${VLAN_SUBNETS_VAL}

# ── Web admin ─────────────────────────────────────────────────
# Picked automatically at install time (first free port starting at 8081) —
# see WEB_ADMIN_PORT_VAL in services/asterisk.sh if this ever needs to
# change again; don't hand-edit without also updating Caddy's Caddyfile and
# any firewall rules to match.
WEB_ADMIN_PORT=${WEB_ADMIN_PORT_VAL}
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── UFW firewall rules ────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        ufw allow "${WEB_ADMIN_PORT_VAL}/tcp"
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow 10000:20000/udp
        ufw allow 49152:49252/udp
        log_success "UFW rules added."
    fi

    # ── Caddy reverse proxy for web admin ─────────────────────────────────────
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
        if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
            EXTRA_BLOCK="    import authelia"
            # Disable built-in auth since Authelia handles it
            sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
        fi
    fi
    configure_caddy_for_service "Asterisk Web Admin" "${WEB_ADMIN_PORT_VAL}" "asterisk" "$EXTRA_BLOCK"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << 'MD'
# Easy Asterisk PBX + coturn

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal. Suitable for home intercom, VoIP handsets, and softphones.

## Manage

```bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
```

## Management script

```bash
docker exec -it easy-asterisk easy-asterisk --help
```

## SIP client setup

| Setting         | Value                                |
|-----------------|--------------------------------------|
| SIP server      | <host-ip> (LAN) or your FQDN (FQDN) |
| SIP port        | 5061 (TLS) / 5060 (UDP)             |
| TURN server     | <DOMAIN_NAME>:3478 (FQDN mode only) |
| TURN username   | easyasterisk                         |
| TURN password   | see .env → TURN_PASSWORD             |

Recommended softphones: Linphone, Zoiper, Bria, Grandstream Wave.

For a phone to work the same way regardless of network (LAN, VLAN, remote,
no VPN), register it against `<DOMAIN_NAME>:5061` over TLS — that's what
FQDN mode is for. Plain UDP/TCP on 5060 still works for LAN-only devices,
but only the FQDN+TLS path is location-independent.

## VLANs / other subnets

`.env` → `HAS_VLANS`/`VLAN_SUBNETS` lists extra networks (space-separated
CIDRs) this server isn't itself attached to but that phones live on. These
become `local_net=` entries in `pjsip.conf` so NAT/SDP handling is correct
for those devices (missing entries here is the most common cause of calls
connecting with no audio). To change this after install:

```bash
docker exec -it easy-asterisk easy-asterisk
# Server Settings → Configure VLAN/VPN Subnets
```

## TLS certificate

If Caddy is installed and already holds a Let's Encrypt cert for
`DOMAIN_NAME` (i.e. there's a Caddyfile site block for that exact hostname),
the container mounts Caddy's cert store read-only and the entrypoint syncs
it in automatically on every start — and re-checks every 12h so renewals
get picked up without a restart. No Caddyfile block for the domain, or no
Caddy at all, falls back to a self-signed cert (phones must be configured
to accept it).

## Web admin

Access the Easy Asterisk web interface at http://<host-ip>:8081
or via your configured reverse-proxy domain. (8081 is the default; if that
port was already taken by something else on this box, the installer picked
the next free one instead — check WEB_ADMIN_PORT in .env for the actual
value.)

## Data directories (all inside ~/docker/asterisk/, included in backup)

| Directory            | Contents                        |
|----------------------|---------------------------------|
| config/asterisk/     | /etc/asterisk — dialplan, SIP   |
| config/easy-asterisk/| /etc/easy-asterisk — web config |
| logs/                | /var/log/asterisk               |
| spool/               | /var/spool/asterisk             |
| lib/                 | /var/lib/asterisk               |

## Ports

| Port          | Protocol | Purpose                          |
|---------------|----------|----------------------------------|
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| 8081          | TCP      | Easy Asterisk web admin (default — see .env) |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| 49152–49252   | UDP      | TURN relay media ports           |
MD

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Easy Asterisk installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    else
        echo "  Mode:        LAN-only"
        echo "  TURN server: (none — LAN/VPN only)"
    fi
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost):${WEB_ADMIN_PORT_VAL}"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it easy-asterisk easy-asterisk --help"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk
