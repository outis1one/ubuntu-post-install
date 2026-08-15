#!/bin/bash
# services/pihole.sh — Pi-hole network-wide DNS ad/tracker blocking.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash pihole.sh
# (Docker must already be installed when run standalone)
#
# Deliberately standalone — not wired into wg-easy or any other VPN/DNS
# push here. Point a device's DNS settings at this box's IP manually to use
# it. If you want it pushed automatically to VPN clients, that's a
# wg-easy-side change (WG_CONFIG's DNS setting), not something this
# installer does on its own.

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
            tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$_len"
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

        prompt_reinstall_mode() {
            local _var="$1" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='cancel'"; return; }
            echo ""
            echo "  1) Update   — refresh the image only, leave config/data as-is"
            echo "  2) Full reinstall — wipe and reconfigure from scratch"
            echo "  3) Cancel   — leave the existing install untouched"
            read -r -p "  Choice [3]: " _r
            case "$_r" in
                1) eval "$_var='update'" ;;
                2) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
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

register_service pihole utilities "Network-wide DNS ad/tracker blocking (Pi-hole) — standalone, not wired into any VPN" 80

install_pihole() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/pihole"
    local WEB_PORT="8081"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml + .env"
        echo "[DRY-RUN] Would warn (not block) if port 53/tcp or 53/udp is already in use"
        echo "[DRY-RUN] Would auto-scan for a free host port for the web admin UI"
        echo "[DRY-RUN] Would generate a random admin password"
        echo "[DRY-RUN] Would offer a Caddy reverse proxy for the admin UI only (never DNS)"
        return 0
    fi

    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing the Pi-hole image only — existing blocklists, config, and"
                log_info "port are left as-is."
                ( cd "$DIR" && docker compose pull && docker compose up -d ) \
                    && log_success "Pi-hole image refreshed" \
                    || log_warning "Refresh failed — check: docker compose -f $DIR/docker-compose.yml logs"
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) ;;  # fall through to the full install flow below
        esac
    fi

    # DNS itself is never scanned/moved — shifting Pi-hole off port 53 would
    # defeat the point, since every device on the network expects to find DNS
    # there by convention (unlike a web UI port, nothing lets a client be told
    # "try a different port instead"). Warn instead: the common case on Ubuntu
    # is systemd-resolved bound only to 127.0.0.53:53 (loopback), which does
    # NOT collide with Pi-hole's container publishing 53 on the host's real
    # interfaces — but if something else really is bound to 0.0.0.0:53, this
    # says so up front instead of failing silently at `docker compose up`.
    if port_in_use 53 tcp || port_in_use 53 udp; then
        log_warning "Something is already listening on port 53 (DNS) — check with:"
        log_warning "  ss -tulnp | grep ':53 '"
        log_warning "If that's systemd-resolved bound to 127.0.0.53 only, this is fine —"
        log_warning "Pi-hole binds the host's real interfaces, not the loopback stub. If"
        log_warning "it's something else bound to 0.0.0.0:53, Pi-hole's container won't"
        log_warning "be able to start until that's freed or reconfigured."
    fi

    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
    # This only ever applies to the WEB admin UI — DNS itself is never behind
    # Caddy (Caddy only speaks HTTP).
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

    local WEBPASSWORD
    WEBPASSWORD="$(generate_password 24)"

    # v6 image: config lives entirely under /etc/pihole (TOML-based
    # pihole.toml) — the old v5 split with a separate /etc/dnsmasq.d volume
    # and WEBPASSWORD env var are both gone. FTLCONF_webserver_api_password
    # replaces WEBPASSWORD; FTLCONF_dns_listeningMode=ALL is required under
    # Docker's default bridge networking or Pi-hole ignores queries from
    # anything but localhost. cap_add matches Pi-hole's own official compose
    # example — NET_ADMIN specifically is only needed if this instance is
    # ever used as a DHCP server too, which it isn't here, but the other two
    # (SYS_TIME, SYS_NICE) are part of that same documented baseline.
    cat > docker-compose.yml << PIHOLE_COMPOSE
name: pihole

services:
  pihole:
    image: pihole/pihole:latest
    container_name: pihole
    hostname: pihole
    restart: unless-stopped
    environment:
      TZ: \${TZ}
      FTLCONF_webserver_api_password: \${WEBPASSWORD}
      FTLCONF_dns_listeningMode: ALL
    volumes:
      - ./etc-pihole:/etc/pihole
    ports:
      - "53:53/tcp"
      - "53:53/udp"
      - "${WEB_PORT}:80/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_TIME
      - SYS_NICE
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
PIHOLE_COMPOSE

    cat > .env << PIHOLE_ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
# Admin web UI password (System Console / login screen).
WEBPASSWORD='${WEBPASSWORD}'
CADDY_NET=$SITE_CADDY_NET
PIHOLE_ENV
    chmod 600 .env

    mkdir -p etc-pihole
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    echo ""
    log_success "Pi-hole configured at $DIR (DNS on 53, admin UI on port $WEB_PORT)"

    configure_caddy_for_service "Pi-hole" "pihole:80" "pihole"
    local _caddy_configured=false _caddy_mode=""
    if declare -p CADDY_SERVICE_CONFIGURED >/dev/null 2>&1; then
        _caddy_configured="$CADDY_SERVICE_CONFIGURED"
        _caddy_mode="$CADDY_SERVICE_MODE"
    fi

    # ── Firewall ─────────────────────────────────────────────────────────────
    # DNS (53) is opened unconditionally — this is meant to be queried
    # directly by devices on the network, never fronted by Caddy. The web UI
    # port only needs opening if Caddy ISN'T fronting it locally (matches the
    # pattern documented in CLAUDE.md for every other service in this repo).
    if command -v ufw &>/dev/null; then
        ufw allow 53/tcp comment "Pi-hole DNS"
        ufw allow 53/udp comment "Pi-hole DNS"
        if [ "$_caddy_configured" != "true" ] || [ "$_caddy_mode" = "remote" ]; then
            ufw allow "${WEB_PORT}/tcp" comment "Pi-hole admin UI"
        fi
    fi

    write_readme "$DIR" << MD
# Pi-hole

Network-wide DNS-based ad/tracker blocking. Standalone install — **not**
wired into wg-easy, Netbird, or any other VPN here. To actually use it,
point a device's DNS settings at this box's IP on port 53, either by hand
per-device or via your router's DHCP DNS setting.

## Access
- Admin UI: http://localhost:${WEB_PORT} (or via Caddy if configured above)
- Admin password: see \`.env\` → \`WEBPASSWORD\`
- DNS: this box's IP, port 53 (standard DNS port — not configurable per-instance)

## Using it
Nothing points at this automatically. Options, in order of how much you
want blocked by default:
- **Per-device**: change that device's DNS server setting to this box's IP.
- **Whole LAN**: change your router's DHCP-assigned DNS server to this box's IP
  (every device on that network picks it up automatically going forward).
- **Over the VPN too**: this needs a manual edit on the wg-easy side — set
  wg-easy's DNS setting to this box's IP so it's pushed to VPN peers. Not
  done automatically by this installer, on purpose (you said standalone).

## Port 53 already in use?
The installer warns but doesn't block if something's already listening on
53 at install time. The common, harmless case on Ubuntu is systemd-resolved
bound only to \`127.0.0.53:53\` (loopback stub) — Pi-hole's container
publishes on the host's real interfaces, not that loopback address, so the
two normally coexist fine. If something else genuinely holds \`0.0.0.0:53\`,
free it first or Pi-hole's container won't start:
\`\`\`
ss -tulnp | grep ':53 '
\`\`\`

## Manage
\`\`\`bash
cd $DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker exec -it pihole pihole -g   # force a blocklist update (gravity)
\`\`\`
MD

    local START=""
    prompt_yn "Start Pi-hole now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "Pi-hole started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  Admin UI:  http://localhost:${WEB_PORT}"
    echo "  Password:  see $DIR/.env"
    echo "  Nothing points at this DNS server yet — see the README for how to"
    echo "  actually route devices to it."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_pihole
