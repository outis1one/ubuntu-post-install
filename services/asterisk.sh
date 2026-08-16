#!/bin/bash
# services/asterisk.sh — Easy Asterisk PBX + coturn TURN server (home intercom/VoIP).
# Part of the modular post-install system (sourced by setup.sh).
#
# One installer for both deployment shapes. It detects a DigitalOcean droplet
# (via the link-local metadata service, with a y/n fallback if that's blocked)
# and, in droplet mode, swaps in the public-cloud specifics: a public-FQDN-only
# flow with no LAN/VLAN prompts, a Caddy site block pinned to that one FQDN,
# an optional remote Authelia, and a DigitalOcean Cloud Firewall via doctl.
# The swapfile (lib/common.sh's ensure_swapfile) is NOT droplet-gated — every
# box gets that same low-RAM safety net regardless of provider or deployment
# shape. Everything else — vendor files, compose, messaging dialplan,
# presence alerts, UFW, log rotation — is identical either way.
#
# This used to be two services (services/asterisk-digital-ocean.sh held a
# near-duplicate copy of the whole file). An existing droplet install at
# ~/docker/asterisk-digital-ocean is detected and kept in place, container
# names included, so the merge doesn't strand it.
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
            echo "    u) Update — refresh vendor files/config, keep existing settings"
            echo "    f) Full reinstall — re-run every prompt from scratch"
            echo "    c) Cancel — leave everything as-is [default]"
            read -r -p "  Choice [u/f/c, Enter=cancel]: " _r
            case "${_r,,}" in
                u) eval "$_var='update'" ;;
                f) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        # Standalone-mode copy of lib/common.sh's ensure_swapfile() — kept in
        # sync by hand, same as every other helper stubbed in this block.
        ensure_swapfile() {
            local TOTAL_RAM_MB
            TOTAL_RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
            [[ "$TOTAL_RAM_MB" -gt 0 && "$TOTAL_RAM_MB" -le 4096 ]] || return 0
            swapon --show | grep -q . && return 0
            [ "${DRY_RUN:-false}" = true ] && { echo "[DRY-RUN] Would add a swapfile (${TOTAL_RAM_MB}MB RAM, no swap detected)"; return 0; }

            local FREE_DISK_MB SWAP_MB=2048
            FREE_DISK_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
            if [[ "$FREE_DISK_MB" -le $((SWAP_MB + 2048)) ]]; then
                log_warning "Not enough free disk for a safe swapfile (${FREE_DISK_MB}MB free) — skipping."
                return 0
            fi

            local ADD_SWAP=""
            prompt_yn "No swap detected on this ${TOTAL_RAM_MB}MB-RAM box — add a ${SWAP_MB}MB swapfile? (recommended) (y/n):" "y" ADD_SWAP
            [[ "$ADD_SWAP" =~ ^[Yy]$ ]] || return 0

            fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile
            grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
            sysctl -w vm.swappiness=10 >/dev/null 2>&1
            log_success "Swapfile enabled (${SWAP_MB}MB, swappiness=10, persists across reboots)."
        }

        # Standalone-mode copy of lib/common.sh's find_free_coturn_range() —
        # kept in sync by hand, same as every other helper stubbed in this block.
        find_free_coturn_range() {
            local _min_varname="$1" _max_varname="$2" _range_size="${3:-200}" _start="${4:-49152}"
            local _highest_max=$((_start - 1)) _f _found
            for _f in "$DOCKER_DIR"/*/.env; do
                [ -f "$_f" ] || continue
                _found="$(grep -E '^(COTURN|TURN)_MAX_PORT=' "$_f" 2>/dev/null | tail -1 | cut -d= -f2-)"
                [[ "$_found" =~ ^[0-9]+$ ]] || continue
                [ "$_found" -gt "$_highest_max" ] && _highest_max=$_found
            done
            local _min=$_start
            [ "$_highest_max" -ge "$_start" ] && _min=$((_highest_max + 50))
            eval "$_min_varname='$_min'"
            eval "$_max_varname='$((_min + _range_size))'"
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

register_service asterisk homelab "Easy Asterisk PBX (intercom/VoIP; auto-tunes for a DigitalOcean droplet); own dedicated coturn for TURN" 5061

# ── Install layout: directory + container names ────────────────────────────
# Sets ASTERISK_DIR / ASTERISK_CONTAINER / ASTERISK_COTURN / ASTERISK_PROJECT.
#
# New installs always land in ~/docker/asterisk with the plain container
# names, droplet or not — the DigitalOcean specifics are behaviour, not a
# separate install. But boxes provisioned by the old, separate
# services/asterisk-digital-ocean.sh have a live install at
# ~/docker/asterisk-digital-ocean running containers named easy-asterisk-do /
# easy-asterisk-do-coturn, with a Caddyfile block, UFW rules, a Cloud
# Firewall, CrowdSec acquisition and a PSTN trunk all pointing at those exact
# paths and names. Renaming any of that from under a running deployment would
# break every one of those references at once, so an existing legacy install
# is detected and kept exactly as it is; only new installs get the unified
# naming. Every sibling service in this repo (pstn-trunk, security-dashboard,
# crowdsec) already probes for both directories, so both layouts stay fully
# supported without further special-casing.
_asterisk_resolve_layout() {
    if [[ -f "$DOCKER_DIR/asterisk-digital-ocean/docker-compose.yml" ]]; then
        ASTERISK_DIR="$DOCKER_DIR/asterisk-digital-ocean"
        ASTERISK_CONTAINER="easy-asterisk-do"
        ASTERISK_COTURN="easy-asterisk-do-coturn"
        ASTERISK_PROJECT="asterisk-do"
    else
        ASTERISK_DIR="$DOCKER_DIR/asterisk"
        ASTERISK_CONTAINER="easy-asterisk"
        ASTERISK_COTURN="easy-asterisk-coturn"
        ASTERISK_PROJECT="asterisk"
    fi
}

# ── DigitalOcean droplet detection ─────────────────────────────────────────
# Sets IS_DO (true/false), DROPLET_ID and PUBLIC_IP.
#
# A droplet's own id/public IP are readable, unauthenticated, from the
# link-local metadata service — no API token needed for this part. The
# metadata service isn't always reachable (a container, a firewalled
# 169.254.0.0/16, a non-DO cloud that still wants the same public-IP
# treatment), so a miss falls back to asking rather than silently deciding
# for the user. Droplet mode is what gates the public-FQDN-only flow and the
# Cloud Firewall step further down (the swapfile is NOT droplet-gated — see
# ensure_swapfile in lib/common.sh, called unconditionally further down).
_asterisk_detect_digitalocean() {
    local _meta="http://169.254.169.254/metadata/v1"
    DROPLET_ID="$(curl -fsS --max-time 2 "$_meta/id" 2>/dev/null || true)"
    PUBLIC_IP="$(curl -fsS --max-time 2 "$_meta/interfaces/public/0/ipv4/address" 2>/dev/null || true)"

    echo ""
    local _answer=""
    if [[ -n "$DROPLET_ID" ]]; then
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
        log_success "DigitalOcean droplet detected (id $DROPLET_ID, public IP ${PUBLIC_IP:-unknown})."
        log_info "Droplet mode adds: public-FQDN-only setup (no LAN/VLAN prompts), a Cloud"
        log_info "Firewall via doctl, and a remote-Authelia option."
        prompt_yn "Set this up as a public droplet? (n = treat it as a home/LAN box) (y/n):" "y" _answer
    else
        log_info "No DigitalOcean metadata service reachable — assuming a home/LAN box."
        log_info "Answer y here anyway if this is a public cloud VM (droplet with metadata"
        log_info "blocked, or another provider) that should get the public-IP treatment."
        prompt_yn "Set this up as a public cloud box? (y/n):" "n" _answer
    fi

    if [[ "$_answer" =~ ^[Yy]$ ]]; then
        IS_DO=true
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
        [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
        [[ -z "$DROPLET_ID" ]] && log_warning "No droplet id — the Cloud Firewall step will print manual rules instead of using doctl."
    else
        IS_DO=false
        DROPLET_ID=""
    fi
}

# ── Shared: vendor file refresh ────────────────────────────────────────────
# Called from both a fresh install and an "update in place" run, so a single
# copy of this logic stays current for both instead of drifting apart. Must
# be called with $PWD already at $ASTERISK_DIR.
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

    # Persist security-level logging to a file — vendor's logger.conf only
    # sends the "security" level (auth failures, SIP brute-force attempts) to
    # the console (Docker stdout), not a file CrowdSec/fail2ban can tail.
    # Applies on every box, not just droplets: the Security Dashboard's
    # Security Log tab and services/crowdsec.sh's Asterisk acquisition both
    # read logs/full, and neither has anything to read without this patch.
    if grep -q '^console => notice,warning,error,security$' ./docker/entrypoint.sh; then
        sed -i '/^console => notice,warning,error,security$/a full => notice,warning,error,security' \
            ./docker/entrypoint.sh
    else
        log_warning "entrypoint.sh logger.conf template changed upstream — security events won't be logged to a file. Update the sed patch in this installer."
    fi

    # Regenerate the self-signed TLS cert when it doesn't match the current
    # DOMAIN_NAME. Vendor's own check only asks "does the file exist" and
    # "does it have a SAN extension" -- never "does the SAN match the domain
    # actually configured now" -- so a domain entered once (even a
    # placeholder, or one later changed) sticks in the cert FOREVER: it
    # survives every subsequent update *and* full reinstall, because
    # /etc/asterisk/certs is a bind-mounted host directory neither install
    # mode ever wipes (the same reason pjsip.conf/devices survive reinstalls
    # too). Confirmed live: a box's TLS transport kept presenting a cert for
    # a stale, originally-entered domain long after DOMAIN_NAME had changed
    # and a full reinstall had been run in between -- most SIP/TLS clients
    # refuse a cert like that outright with no clear error, and this was the
    # actual cause of a "port's open but registration still fails" case that
    # every other check (firewall, coturn, DNS) had already come back clean.
    if grep -q '^if \$regen_cert; then$' ./docker/entrypoint.sh; then
        sed -i '/^if \$regen_cert; then$/i\
if [[ "$regen_cert" != true && -n "${DOMAIN_NAME:-}" ]] && ! openssl x509 -in /etc/asterisk/certs/server.crt -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:${DOMAIN_NAME}"; then\
    log_info "Existing TLS cert does not match current DOMAIN_NAME (${DOMAIN_NAME}) -- regenerating"\
    regen_cert=true\
fi' ./docker/entrypoint.sh
    else
        log_warning "entrypoint.sh cert-regen check changed upstream — a stale-domain cert won't auto-regenerate. Update the sed patch in this installer."
    fi
}

# ── Shared: log rotation for logs/full (unbounded otherwise) ──────────────
# Confirmed live: with no rotation, this file grew to 1.4GB in about 3 days
# on a busy box (SIP scanning noise is constant on the public internet) —
# a real disk-exhaustion risk on a small droplet, and separately made the
# Security Dashboard balloon to 600+MB RAM/GBs of swap reading it every 30s
# before that was fixed to only read a bounded tail (see
# services/security-dashboard.sh). copytruncate avoids needing to signal
# Asterisk to reopen its log file — it has a long-held file descriptor on
# this path and no reload mechanism this installer can reach from the host.
#
# Not droplet-only: a LAN box reachable from the internet (port-forwarded
# SIP) collects the same scanning noise, and the file is unbounded either
# way now that the security-level logging patch above applies everywhere.
_asterisk_write_logrotate() {
    local _ea_dir="$1"
    cat > /etc/logrotate.d/asterisk << LOGROTATE
$_ea_dir/logs/full {
    size 100M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
    # Supersedes the config the old separate droplet installer wrote. Left in
    # place it would rotate the very same path a second time (both files can
    # name the same log), so it goes when this one lands.
    rm -f /etc/logrotate.d/asterisk-digital-ocean
}

# ── Shared: standalone backup/restore, independent of the Kopia backup
# service ─────────────────────────────────────────────────────────────────
# Unlike Mattermost (a database export that needed real work to get right —
# see migrate-from-pikapods.sh), Asterisk's entire state is already plain
# files under one directory: dialplan, pjsip devices, voicemail, recordings,
# .env (including its coturn credential), docker-compose.yml. So this is
# just a tar of the whole directory, with the stop/restart safety a live
# PBX needs around it — no export format to get wrong.
#
# Output defaults to a path OUTSIDE $DOCKER_DIR (~/asterisk-backups/) so a
# Kopia-based backup of this same box doesn't also end up backing up a
# backup-of-itself on every run — the same lesson as not leaving Mattermost
# migration scratch files inside ~/docker/mattermost.
_asterisk_write_standalone_backup_script() {
    local _ea_dir="$1" _container="$2"
    cat > "$_ea_dir/asterisk-standalone-backup.sh" << 'BACKUPSCRIPT'
#!/bin/bash
# __EA_DIR__/asterisk-standalone-backup.sh — independent backup/restore for
# this Asterisk install. No Kopia/backup-service dependency — everything
# this PBX needs to come back already lives under this one directory, so
# this is a tar of the whole thing plus the stop/restart safety a live PBX
# needs around it.
#
#   sudo ./asterisk-standalone-backup.sh backup [output-dir]
#   sudo ./asterisk-standalone-backup.sh restore <archive.tar.gz>
#
# Output defaults to ~/asterisk-backups/ — deliberately OUTSIDE ~/docker/,
# so a Kopia-based backup of this same box doesn't also end up backing up
# a backup-of-itself on every run.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER="__CONTAINER_NAME__"
ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root: sudo $0 ..."; exit 1; }

usage() {
    echo "Usage:"
    echo "  sudo $0 backup [output-dir]      (default: $ACTUAL_HOME/asterisk-backups)"
    echo "  sudo $0 restore <archive.tar.gz>"
    exit 1
}

container_running() {
    docker compose ps --status running -q 2>/dev/null | grep -q .
}

cmd="${1:-}"
case "$cmd" in
    backup)
        OUT_DIR="${2:-$ACTUAL_HOME/asterisk-backups}"
        mkdir -p "$OUT_DIR"
        TS="$(date +%Y%m%d-%H%M%S)"
        ARCHIVE="$OUT_DIR/asterisk-backup-$TS.tar.gz"

        echo "This stops Asterisk briefly (voicemail/spool are written to"
        echo "continuously — a live tar could capture a half-written file"
        echo "otherwise) and restarts it after."
        echo "Target: $ARCHIVE"
        read -r -p "Type YES to proceed: " CONFIRM
        [ "$CONFIRM" = "YES" ] || { echo "Aborted — no changes made."; exit 0; }

        cd "$HERE" || exit 1
        WAS_RUNNING=false
        if container_running; then
            echo "Stopping Asterisk..."
            docker compose stop
            WAS_RUNNING=true
        fi

        echo "Archiving $HERE -> $ARCHIVE ..."
        if tar -czf "$ARCHIVE" -C "$(dirname "$HERE")" "$(basename "$HERE")"; then
            chown "$ACTUAL_USER:$ACTUAL_USER" "$ARCHIVE"
            echo "Done: $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1))"
        else
            echo "tar failed — restarting Asterisk regardless; check disk space."
        fi

        if [ "$WAS_RUNNING" = true ]; then
            echo "Starting Asterisk..."
            (cd "$HERE" && docker compose up -d)
        fi
        ;;

    restore)
        ARCHIVE="${2:-}"
        [ -n "$ARCHIVE" ] || usage
        [ -f "$ARCHIVE" ] || { echo "Archive not found: $ARCHIVE"; exit 1; }

        echo "┌─────────────────────────────────────────────────────────────────┐"
        echo "│ ASTERISK RESTORE — THIS REPLACES $HERE"
        echo "└─────────────────────────────────────────────────────────────────┘"
        echo ""
        echo "  Archive: $ARCHIVE"
        echo "  Target:  $HERE"
        echo ""
        read -r -p "Type YES to proceed: " CONFIRM
        [ "$CONFIRM" = "YES" ] || { echo "Aborted — no changes made."; exit 0; }

        cd "$HERE" || exit 1
        WAS_RUNNING=false
        if container_running; then
            echo "Stopping Asterisk..."
            docker compose stop
            WAS_RUNNING=true
        fi

        PARENT_DIR="$(dirname "$HERE")"
        BASE_NAME="$(basename "$HERE")"
        ASIDE="${HERE}.restore-aside-$(date +%Y%m%d-%H%M%S)"

        # Leave the directory being renamed before renaming it, rather than
        # relying on renaming-your-own-cwd being safe (it generally is on
        # Linux, but there's no reason to lean on that when cd'ing out first
        # costs nothing).
        cd "$PARENT_DIR" || exit 1

        echo "Moving current install aside: $ASIDE"
        mv "$HERE" "$ASIDE"

        echo "Extracting $ARCHIVE -> $PARENT_DIR ..."
        # Extract into a scratch staging dir first rather than straight into
        # $PARENT_DIR — an archive's own top-level directory name reflects
        # whichever layout produced it (see _asterisk_resolve_layout: plain
        # "asterisk"/"easy-asterisk" vs droplet "asterisk-digital-ocean"/
        # "easy-asterisk-do"), which can differ from THIS box's layout (e.g.
        # restoring a droplet backup onto a fresh non-droplet IONOS install).
        # Landing it under the archive's own name instead of $HERE would
        # leave two Asterisk directories on disk and confuse every service
        # that resolves the layout by directory/container name (security-
        # dashboard, pstn-trunk, CrowdSec's Asterisk acquisition, Caddy).
        STAGING="$(mktemp -d)"
        if tar -xzf "$ARCHIVE" -C "$STAGING"; then
            EXTRACTED_DIR="$(find "$STAGING" -mindepth 1 -maxdepth 1 -type d | head -1)"
            if [ -z "$EXTRACTED_DIR" ]; then
                echo "Archive didn't contain a top-level directory — rolling back."
                rm -rf "$STAGING"
                mv "$ASIDE" "$HERE"
                exit 1
            fi

            # If the archive came from the other layout, its docker-
            # compose.yml still names the OLD project/container(s) — fix
            # those to match THIS box's own layout before it lands at $HERE.
            # $CONTAINER is this run's own correct value (baked in at
            # generation time); everything else derives from it the same
            # way _asterisk_resolve_layout's two known layouts do.
            ARCHIVED_COMPOSE="$EXTRACTED_DIR/docker-compose.yml"
            if [ -f "$ARCHIVED_COMPOSE" ]; then
                ARCHIVED_CONTAINER="$(grep -m1 'container_name:' "$ARCHIVED_COMPOSE" | awk '{print $2}')"
                if [ -n "$ARCHIVED_CONTAINER" ] && [ "$ARCHIVED_CONTAINER" != "$CONTAINER" ]; then
                    echo "Archive is from a different Asterisk layout ($ARCHIVED_CONTAINER) than"
                    echo "this box ($CONTAINER) — updating docker-compose.yml to match this box."
                    ARCHIVED_COTURN="${ARCHIVED_CONTAINER}-coturn"
                    NEW_COTURN="${CONTAINER}-coturn"
                    sed -i "s/name: ${ARCHIVED_CONTAINER#easy-}\$/name: ${CONTAINER#easy-}/; \
                            s/container_name: ${ARCHIVED_CONTAINER}\$/container_name: ${CONTAINER}/; \
                            s/container_name: ${ARCHIVED_COTURN}\$/container_name: ${NEW_COTURN}/" \
                        "$ARCHIVED_COMPOSE"
                fi
            fi

            rm -rf "${HERE:?}"
            mv "$EXTRACTED_DIR" "$HERE"
            rm -rf "$STAGING"
            echo "Extracted."
        else
            echo "Extraction failed — rolling back to the pre-restore install."
            rm -rf "$STAGING"
            mv "$ASIDE" "$HERE"
            exit 1
        fi

        # pjsip.conf bakes external_media_address/external_signaling_address
        # in as literal IPs (easy-asterisk writes them at first container
        # start, not this repo) — restoring an archive from a DIFFERENT box
        # verbatim leaves the OLD box's IP in place, breaking RTP media (and
        # likely SIP signaling) on THIS box even though the dialplan itself
        # comes back fine. Detect the mismatch and patch it automatically —
        # this is the whole reason "restore" onto a new host exists, so a
        # stale IP left behind would defeat the point every single time.
        PJSIP_CONF="$HERE/config/asterisk/pjsip.conf"
        if [ -f "$PJSIP_CONF" ]; then
            OLD_EXT_IP="$(grep -m1 '^external_signaling_address=' "$PJSIP_CONF" | cut -d= -f2)"
            NEW_EXT_IP="$(curl -fsS --max-time 2 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address 2>/dev/null || true)"
            [ -z "$NEW_EXT_IP" ] && NEW_EXT_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
            [ -z "$NEW_EXT_IP" ] && NEW_EXT_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

            if [ -n "$OLD_EXT_IP" ] && [ -n "$NEW_EXT_IP" ] && [ "$OLD_EXT_IP" != "$NEW_EXT_IP" ]; then
                echo "This archive's SIP config was for a different box's public IP"
                echo "($OLD_EXT_IP) — this box's is $NEW_EXT_IP. Updating"
                echo "external_media_address/external_signaling_address so RTP/SIP work here."
                # Fixed-string match/replace, restricted to config + .env —
                # never spool/logs/lib, which hold voicemail/recording audio
                # that a text substitution would corrupt.
                ESC_OLD_IP="${OLD_EXT_IP//./\\.}"
                grep -rlF "$OLD_EXT_IP" "$HERE/config" "$HERE/.env" 2>/dev/null | while read -r _f; do
                    sed -i "s/$ESC_OLD_IP/$NEW_EXT_IP/g" "$_f"
                done
                echo "Updated. If this PBX uses VLANs/extra subnets, re-check them:"
                echo "  docker exec -it $CONTAINER easy-asterisk   # Server Settings -> Configure VLAN/VPN Subnets"
            fi
        fi

        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$HERE"

        if [ "$WAS_RUNNING" = true ]; then
            echo "Starting Asterisk..."
            (cd "$HERE" && docker compose up -d)
        fi

        echo ""
        echo "Done. Previous install kept at: $ASIDE"
        echo "Delete it once you've verified this restore is good — it's not"
        echo "cleaned up automatically."
        echo ""
        echo "If you ran this from inside $HERE, your current shell may still show"
        echo "the old directory's contents (a normal Linux quirk — your shell's"
        echo "working directory followed the OLD directory when it got renamed"
        echo "aside). Run 'cd $HERE' again (or open a new shell) to see the"
        echo "restored files."
        ;;

    *)
        usage
        ;;
esac
BACKUPSCRIPT
    sed -i "s/__CONTAINER_NAME__/${_container}/g" "$_ea_dir/asterisk-standalone-backup.sh"
    chmod +x "$_ea_dir/asterisk-standalone-backup.sh"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$_ea_dir/asterisk-standalone-backup.sh" 2>/dev/null || true
}

# ── Shared: extension presence (online/offline) ntfy alerts ────────────────
# Polls PJSIP registration state and alerts only on a CHANGE from the last
# check (never on every poll) — same periodic-check shape as pstn-trunk.sh's
# usage-alert script, but purely informational, so a looser 2-minute
# interval is fine here (nothing enforces/blocks anything off the back of
# this one). UNVERIFIED: the `pjsip show contacts` column layout below is
# parsed defensively (grep for the Avail/Unavail keyword rather than a fixed
# column position) specifically because it hasn't been confirmed against a
# live install's actual output yet — run
# `docker exec <container> asterisk -rx "pjsip show contacts"` yourself
# after enabling this to confirm extensions/status actually show up as
# expected, same as any other not-yet-live-tested piece in this project.
_asterisk_write_presence_alert_script() {
    local FILE="$1" CONTAINER_NAME="$2" NTFY_URL="$3" STATE_FILE="$4"
    cat > "$FILE" << 'SCRIPT'
#!/bin/bash
# Auto-generated by services/asterisk.sh — rerun the installer's
# presence-alert step to change settings instead of editing this directly.
CONTAINER_NAME="__PRESENCE_CONTAINER__"
NTFY_URL="__PRESENCE_NTFY_URL__"
STATE_FILE="__PRESENCE_STATE_FILE__"

[[ -z "$NTFY_URL" ]] && exit 0

send_ntfy() {
    curl -m 5 -s -d "$1" "$NTFY_URL" >/dev/null 2>&1
}

CURRENT="$(docker exec "$CONTAINER_NAME" asterisk -rx "pjsip show contacts" 2>/dev/null | grep '^ Contact:' | while read -r _ aor rest; do
    ext="${aor%%/*}"
    status="Unknown"
    case "$rest" in
        *Unavail*) status="Unavail" ;;
        *Avail*) status="Avail" ;;
    esac
    echo "${ext}:${status}"
done)"

[[ -z "$CURRENT" ]] && exit 0

touch "$STATE_FILE"
declare -A OLD_STATE
while IFS=: read -r ext status; do
    [[ -n "$ext" ]] && OLD_STATE["$ext"]="$status"
done < "$STATE_FILE"

: > "${STATE_FILE}.new"
while IFS=: read -r ext status; do
    [[ -z "$ext" ]] && continue
    echo "${ext}:${status}" >> "${STATE_FILE}.new"
    old="${OLD_STATE[$ext]:-}"
    if [[ -n "$old" && "$old" != "$status" && "$status" != "Unknown" ]]; then
        if [[ "$status" == "Avail" ]]; then
            send_ntfy "Extension $ext is back online."
        elif [[ "$old" == "Avail" ]]; then
            send_ntfy "Extension $ext went offline."
        fi
    fi
done <<< "$CURRENT"
mv "${STATE_FILE}.new" "$STATE_FILE"
SCRIPT
    sed -i "s#__PRESENCE_CONTAINER__#${CONTAINER_NAME}#g; s#__PRESENCE_NTFY_URL__#${NTFY_URL}#g; s#__PRESENCE_STATE_FILE__#${STATE_FILE}#g" "$FILE"
    chmod 755 "$FILE"
}

_asterisk_install_presence_timer() {
    local EA_DIR="$1"
    mkdir -p "$EA_DIR/logs"

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/asterisk-presence-alert.service << SVCEOF
[Unit]
Description=Asterisk extension presence (online/offline) check

[Service]
Type=oneshot
ExecStart=/bin/bash $EA_DIR/asterisk-presence-alert.sh
StandardOutput=append:$EA_DIR/logs/asterisk-presence-alert.log
StandardError=append:$EA_DIR/logs/asterisk-presence-alert.log
SVCEOF

        cat > /etc/systemd/system/asterisk-presence-alert.timer << SVCEOF
[Unit]
Description=Run the Asterisk presence check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
SVCEOF

        systemctl daemon-reload
        systemctl enable --now asterisk-presence-alert.timer
        log_success "Presence check installed (systemd timer, every 2 minutes)."
    elif command -v cron >/dev/null 2>&1 || [[ -d /etc/cron.d ]]; then
        cat > /etc/cron.d/asterisk-presence-alert << CRON
*/2 * * * * root /bin/bash $EA_DIR/asterisk-presence-alert.sh >> $EA_DIR/logs/asterisk-presence-alert.log 2>&1
CRON
        log_success "Presence check installed (cron.d fallback — systemd not detected)."
    else
        log_warning "Neither systemd nor cron available — run $EA_DIR/asterisk-presence-alert.sh manually/periodically."
    fi
}

# ── Shared: internal SIP MESSAGE routing/enforcement ────────────────────────
# Confirmed live against a real install's pjsip.conf/extensions.conf
# (2026-07-23): every endpoint sets context=intercom and leaves
# message_context blank, so PJSIP messaging falls back to context=intercom —
# and [intercom] already owns an exact-match `exten => <ext>,1,...` per
# device, freshly regenerated by the vendor's own rebuild_dialplan() on
# every dialplan rebuild. A competing priority-1 declaration for the same
# extension number in a #include'd file would race that (Asterisk doesn't
# merge two independent priority-1 declarations for the same context+exten —
# one silently wins) and risks breaking normal internal calling entirely.
# So this uses its own dedicated [sip-messaging] context instead, reached by
# explicitly setting message_context=sip-messaging on every endpoint, so
# there is never any overlap with [intercom]'s own per-device call routing.
#
# The vendor's device-creation code has exactly two independent code paths
# that write a fresh endpoint block (confirmed via grep — both contain the
# literal line "context=intercom" exactly once): the CLI menu's bash heredoc,
# and the web admin's Python add_device(). Patching the vendor's own
# generator source (same technique as _pstn_patch_vendor_files) makes every
# device added FROM NOW ON pick this up automatically, in either path.
# Devices that already existed before this was installed need one one-time
# migration pass over the live pjsip.conf (below) since they were written
# before the patch existed.
_asterisk_patch_messaging_vendor_files() {
    local EA_DIR="$1"
    local ENTRYPOINT="$EA_DIR/docker/entrypoint.sh"
    local EASY1="$EA_DIR/easy-asterisk.sh"
    local EASY2
    EASY2="$(find "$EA_DIR" -maxdepth 1 -name 'easy-asterisk-v*.sh' | head -1)"
    [[ -z "$EASY2" ]] && EASY2="$EA_DIR/easy-asterisk-v0.10.0.sh"
    local f

    for f in "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || { log_error "$f not found — is the base Asterisk install fully set up?"; return 1; }
    done

    # Device-creation templates: both occurrences of "context=intercom" in
    # these two files (identical vendor source, copied twice) are the CLI
    # and web-admin device-creation code paths — a single anchor on the bare
    # line patches both in one pass.
    for f in "$EASY1" "$EASY2"; do
        if ! grep -q '^message_context=sip-messaging$' "$f"; then
            if grep -q '^context=intercom$' "$f"; then
                sed -i '/^context=intercom$/a message_context=sip-messaging' "$f"
            else
                log_warning "$(basename "$f"): 'context=intercom' anchor not found — vendor template changed upstream."
                log_warning "  Add 'message_context=sip-messaging' manually after every 'context=intercom' line in this file's device-creation code."
            fi
        fi
    done

    # extensions.conf: same [intercom] anchor _pstn_patch_vendor_files uses,
    # a SEPARATE #include so this coexists whether or not pstn-trunk is
    # installed — messaging is independent of the PSTN trunk entirely.
    #
    # Anchor AFTER [intercom]$, not before — confirmed live (see
    # _pstn_write_inbound_dialplan_include's comment in pstn-trunk.sh,
    # 2026-07-24): a #include'd file whose first real line is its own
    # [context] header, inserted right after [intercom]$ via this same
    # mechanism, loads fine and does NOT swallow the per-device "exten =>"
    # lines the runtime loop appends after it — messaging-dialplan.conf has
    # done exactly this since it was written. (The failure mode that
    # comment documents is different: mixing "continues the ambient
    # context" content with a later context header IN THE SAME FILE broke
    # everything in that file, which is why pstn-trunk-dialplan.conf and
    # pstn-trunk-inbound-dialplan.conf are two separate files. That doesn't
    # apply here — this file is nothing but [sip-messaging] from its first
    # line.) Asterisk's exact internal handling isn't fully understood, but
    # this position is the one this repo has actually verified working.
    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || continue
        if ! grep -q 'messaging-dialplan.conf' "$f"; then
            if grep -q '^\[intercom\]$' "$f"; then
                sed -i '/^\[intercom\]$/a #include messaging-dialplan.conf' "$f"
            else
                log_warning "$(basename "$f"): '[intercom]' anchor not found — vendor template changed upstream."
                log_warning "  Add '#include messaging-dialplan.conf' manually after [intercom] in this file's extensions.conf heredoc."
            fi
        fi
    done

    log_success "Vendor generator functions patched for internal SIP messaging."
}

# Confirmed live (2026-07-23, via a real pstn-trunk.sh failure that hit this
# same mechanism): the vendor-generator patch above only takes effect on a
# FUTURE regeneration, and Easy Asterisk's own entrypoint only regenerates
# extensions.conf if it doesn't already exist (docker/entrypoint.sh guards
# it behind `[[ ! -f ... ]]`) — a box that already has devices configured,
# which is the normal case here, never regenerates it on a plain restart.
# Patches the LIVE file directly instead, so it takes effect immediately
# regardless of whether Easy Asterisk ever regenerates it on its own.
_asterisk_ensure_live_messaging_include() {
    local EA_DIR="$1" CONTAINER_NAME="$2"
    local EXT_LIVE="$EA_DIR/config/asterisk/extensions.conf"
    [[ -f "$EXT_LIVE" ]] || return 0
    if ! grep -q 'messaging-dialplan.conf' "$EXT_LIVE"; then
        if grep -q '^\[intercom\]$' "$EXT_LIVE"; then
            sed -i '/^\[intercom\]$/a #include messaging-dialplan.conf' "$EXT_LIVE"
            log_success "Patched the messaging #include directly into the live extensions.conf."
        else
            log_warning "Couldn't find '[intercom]' in the live extensions.conf — add"
            log_warning "'#include messaging-dialplan.conf' manually after [intercom], then: docker exec ${CONTAINER_NAME} asterisk -rx \"dialplan reload\""
        fi
    fi
    docker exec "$CONTAINER_NAME" asterisk -rx "dialplan reload" &>/dev/null || true
}

# One-time migration for devices that already existed before the patch above
# — new devices pick up message_context=sip-messaging automatically from now
# on, but anything already in pjsip.conf was written before that existed.
# Idempotent: buffers the file and only inserts where the very next line
# isn't already the exact value, so reruns (every "update") never duplicate it.
_asterisk_migrate_existing_devices_message_context() {
    local PJSIP_FILE="$1"
    [[ -f "$PJSIP_FILE" ]] || return 0
    grep -q '^context=intercom$' "$PJSIP_FILE" || return 0

    local TMP_FILE
    TMP_FILE="$(mktemp)"
    awk '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (lines[i] == "context=intercom" && lines[i+1] != "message_context=sip-messaging") {
                    print "message_context=sip-messaging"
                }
            }
        }
    ' "$PJSIP_FILE" > "$TMP_FILE"

    if ! diff -q "$PJSIP_FILE" "$TMP_FILE" >/dev/null 2>&1; then
        cp "$PJSIP_FILE" "$PJSIP_FILE.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$TMP_FILE" "$PJSIP_FILE"
        chown asterisk:asterisk "$PJSIP_FILE" 2>/dev/null || true
        log_success "Existing devices migrated to message_context=sip-messaging (backup saved alongside pjsip.conf)."
    else
        rm -f "$TMP_FILE"
    fi
}

# The actual enforcement — gated on the SENDER's own "messaging" flag in
# pstn-permissions.conf (the exact file/flag the Security Dashboard's
# Messaging column writes, independent of whether the PSTN trunk is
# installed), read live via AST_CONFIG() on every message, same
# mechanism pstn-trunk.sh's own dialplan already relies on for permission
# tiers — no restart needed to take effect. Off by default: an extension
# with no entry, or messaging=no, is denied. UNVERIFIED: MESSAGE(from)'s
# exact format hasn't been confirmed on a live install — the CUT()-based
# extraction below is written to tolerate a display name (e.g. this
# project's "name0" <999> callerid format) but if it ever fails to parse,
# FROM_EXT ends up empty/wrong and the AST_CONFIG() lookup simply finds no
# match, which denies by default (same fail-closed behavior as an
# unlisted extension) rather than silently allowing anything through.
#
# Every attempt (delivered or denied) is appended to sip-messages.log
# (epoch|status|from_ext|to_ext) — same pipe-delimited, no-embedded-delimiter
# convention pstn-trunk.sh's own pstn-trunk-calls.log uses, for the same
# reason (no dependency on Asterisk's own CDR modules). Message bodies are
# never written. The Security Dashboard's Texts table reads this file.
_asterisk_write_messaging_dialplan() {
    local FILE="$1"
    cat > "$FILE" << 'EOF'
; Internal SIP MESSAGE routing/enforcement — services/asterisk.sh.
; Regenerated on every install/update; edit there, not here directly.
;
; Reached via each endpoint's message_context=sip-messaging (patched into
; Easy Asterisk's own device-creation code — see
; _asterisk_patch_messaging_vendor_files) instead of falling back to
; [intercom], which already owns an exact-match "exten => <ext>,1,..." per
; device for CALLS, regenerated fresh on every dialplan rebuild — a
; competing priority-1 declaration for the same extension number here would
; race that and risk breaking normal internal calling. This context ONLY
; ever receives MESSAGE requests, never calls.
[sip-messaging]
exten => _X.,1,NoOp(SIP MESSAGE to ${EXTEN})
 same => n,Set(FROM_URI=${MESSAGE(from)})
 same => n,Set(FROM_PART=${CUT(FROM_URI,@,1)})
 same => n,Set(FROM_EXT=${CUT(FROM_PART,:,2)})
 same => n,Set(SENDER_OK=${AST_CONFIG(pstn-permissions.conf,${FROM_EXT},messaging)})
 same => n,GotoIf($["${SENDER_OK}" = "yes"]?deliver:deny)
 same => n(deliver),MessageSend(pjsip:${EXTEN},${FROM_URI})
 same => n,System(printf '%s|deliver|%s|%s\n' "${EPOCH}" "${FROM_EXT}" "${EXTEN}" >> /var/log/asterisk/sip-messages.log)
 same => n,Hangup()
 same => n(deny),NoOp(Denied — extension ${FROM_EXT} is not messaging-enabled)
 same => n,System(printf '%s|deny|%s|%s\n' "${EPOCH}" "${FROM_EXT}" "${EXTEN}" >> /var/log/asterisk/sip-messages.log)
 same => n,Hangup()
EOF
}

# Voicemail access codes — reached via [intercom]'s "include => voicemail-
# access" fallback (patched into Easy Asterisk's own device-creation code —
# see _asterisk_patch_voicemail_vendor_files): if a dialed pattern isn't one
# of [intercom]'s own per-device "exten =>" declarations, Asterisk checks
# this context next. *97/*98 are reserved codes here — Easy Asterisk only
# ever assigns numeric-only device extensions, so they can't collide.
#
# Gated live on the TARGET's own "voicemail" flag in pstn-permissions.conf
# (same AST_CONFIG() mechanism messaging-dialplan.conf uses for its
# "messaging" flag, and the exact flag the Security Dashboard's Extensions
# tab writes) — no restart needed to take effect. Off by default: an
# extension with no entry, or voicemail=no, is denied. The mailbox itself
# (password/greeting) lives in voicemail.conf, generated/kept in sync by the
# dashboard's write_voicemail() whenever the flag is toggled — always
# regenerated here is safe since this file has no per-extension state of its
# own, unlike voicemail.conf.
_asterisk_write_voicemail_dialplan() {
    local FILE="$1"
    cat > "$FILE" << 'EOF'
; Voicemail access codes — services/asterisk.sh.
; Regenerated on every install/update; edit there, not here directly.
[voicemail-access]
; Dial *97 to check your OWN mailbox (matched by caller ID).
exten => *97,1,NoOp(Voicemail check from ${CALLERID(num)})
 same => n,VoiceMailMain(${CALLERID(num)}@default)
 same => n,Hangup()

; Dial *98<extension> to leave a message directly in that extension's
; mailbox without ringing it first.
exten => _*98X.,1,NoOp(Direct voicemail drop for ${EXTEN:4})
 same => n,Set(TARGET=${EXTEN:4})
 same => n,Set(VM_OK=${AST_CONFIG(pstn-permissions.conf,${TARGET},voicemail)})
 same => n,GotoIf($["${VM_OK}" = "yes"]?leave:deny)
 same => n(leave),VoiceMail(${TARGET}@default,u)
 same => n,Hangup()
 same => n(deny),Playback(privacy-incorrect)
 same => n,Hangup()
EOF
}

# Mailbox skeleton only — [general] settings plus an empty [default]
# section. Deliberately NOT regenerated on every install/update once it
# exists: past this point, the Security Dashboard's write_voicemail() owns
# the [default] section's actual mailbox lines (added/removed as extensions
# toggle their voicemail flag, with a PIN generated once and persisted in
# pstn-permissions.conf's voicemail_pin= so it survives every future
# regeneration). Regenerating wholesale here on every "update" would fight
# that — same non-destructive-update rule as every other install-time-vs-
# dashboard-owned file split in this repo (.env, firewall rules, etc.).
_asterisk_write_voicemail_conf() {
    local FILE="$1"
    [[ -f "$FILE" ]] && return 0
    cat > "$FILE" << 'EOF'
; Voicemail mailboxes — services/asterisk.sh (initial skeleton).
; Mailbox lines below [default] are added/removed by the Security
; Dashboard's Extensions tab (write_voicemail() in app.py) when voicemail is
; toggled for an extension, and this file is never regenerated wholesale
; after this first creation — hand edits below [default] survive.
[general]
format=wav
attach=no
maxmsg=100
maxsecs=180
minsecs=3
review=yes
operator=no

[default]
EOF
}

# Same anchor-position reasoning as _asterisk_patch_messaging_vendor_files:
# Same anchor as messaging's own patch (see the comment above
# _asterisk_patch_messaging_vendor_files for the live-confirmed reasoning):
# #include voicemail-dialplan.conf goes right AFTER [intercom]$, same
# position that's actually been verified not to disturb the per-device
# "exten =>" lines that follow it. Unlike messaging, though, voicemail
# access codes (*97/*98<ext>) need to actually be DIALABLE from [intercom]
# — messaging is reached via message_context and never through call
# dialplan at all — so this also adds a plain "include => voicemail-access"
# line INSIDE [intercom]'s own body (a dialplan include, not a config
# #include — doesn't open a new context, just tells Asterisk to check
# voicemail-access next if nothing in [intercom] itself matches the dialed
# digits). Both anchor on the same [intercom]$ line; order between them
# doesn't matter to Asterisk (neither is a context header), only that both
# land inside [intercom]'s body.
_asterisk_patch_voicemail_vendor_files() {
    local EA_DIR="$1"
    local ENTRYPOINT="$EA_DIR/docker/entrypoint.sh"
    local EASY1="$EA_DIR/easy-asterisk.sh"
    local EASY2
    EASY2="$(find "$EA_DIR" -maxdepth 1 -name 'easy-asterisk-v*.sh' | head -1)"
    [[ -z "$EASY2" ]] && EASY2="$EA_DIR/easy-asterisk-v0.10.0.sh"
    local f

    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || continue
        if ! grep -q '^\[intercom\]$' "$f"; then
            log_warning "$(basename "$f"): '[intercom]' anchor not found — vendor template changed upstream."
            log_warning "  Add '#include voicemail-dialplan.conf' and 'include => voicemail-access' manually after [intercom] in this file's extensions.conf heredoc."
            continue
        fi
        grep -q '^include => voicemail-access$' "$f" || sed -i '/^\[intercom\]$/a include => voicemail-access' "$f"
        grep -q 'voicemail-dialplan.conf' "$f" || sed -i '/^\[intercom\]$/a #include voicemail-dialplan.conf' "$f"
    done

    log_success "Vendor generator functions patched for voicemail access codes."
}

# Live-file counterpart to the vendor-template patch above, same reasoning
# as _asterisk_ensure_live_messaging_include (Easy Asterisk's entrypoint
# only regenerates extensions.conf if it's missing, so a box with existing
# devices never picks up the vendor patch on a plain restart).
_asterisk_ensure_live_voicemail_include() {
    local EA_DIR="$1" CONTAINER_NAME="$2"
    local EXT_LIVE="$EA_DIR/config/asterisk/extensions.conf"
    [[ -f "$EXT_LIVE" ]] || return 0
    if ! grep -q '^\[intercom\]$' "$EXT_LIVE"; then
        log_warning "Couldn't find '[intercom]' in the live extensions.conf — add"
        log_warning "'#include voicemail-dialplan.conf' and 'include => voicemail-access' manually after [intercom], then: docker exec ${CONTAINER_NAME} asterisk -rx \"dialplan reload\""
        return 0
    fi
    if ! grep -q '^include => voicemail-access$' "$EXT_LIVE"; then
        sed -i '/^\[intercom\]$/a include => voicemail-access' "$EXT_LIVE"
    fi
    if ! grep -q 'voicemail-dialplan.conf' "$EXT_LIVE"; then
        sed -i '/^\[intercom\]$/a #include voicemail-dialplan.conf' "$EXT_LIVE"
    fi
    log_success "Patched voicemail access codes directly into the live extensions.conf."
    docker exec "$CONTAINER_NAME" asterisk -rx "dialplan reload" &>/dev/null || true
}

_asterisk_remove_presence_timer() {
    systemctl disable --now asterisk-presence-alert.timer 2>/dev/null || true
    rm -f /etc/systemd/system/asterisk-presence-alert.timer /etc/systemd/system/asterisk-presence-alert.service
    rm -f /etc/cron.d/asterisk-presence-alert
    systemctl daemon-reload 2>/dev/null || true
}

# Interactive step — called from both the fresh-install flow and "update in
# place" (always asked either way, same reasoning as pstn-trunk.sh's
# international-calling step: this is a live-editable extra, not a
# structural setting, so it doesn't belong exclusively to one path).
_asterisk_run_presence_step() {
    local EA_DIR="$1" CONTAINER_NAME="$2"
    local SETTINGS_FILE="$EA_DIR/.presence-alert.env"
    local STATE_FILE="$EA_DIR/.presence-alert.state"

    echo ""
    local _CUR_ENABLED="n" _CUR_NTFY=""
    if [[ -f "$SETTINGS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SETTINGS_FILE"
        _CUR_ENABLED="${PRESENCE_ENABLED:-n}"
        _CUR_NTFY="${PRESENCE_NTFY_URL:-}"
    fi

    if [[ "$_CUR_ENABLED" == "y" ]]; then
        echo "  Extension online/offline ntfy alerts are ON (topic: $_CUR_NTFY)."
        local _CHANGE=""
        prompt_yn "  Change or disable this? (y/n):" "n" _CHANGE
        [[ "$_CHANGE" =~ ^[Yy]$ ]] || return 0
        local _DISABLE=""
        prompt_yn "  Disable presence alerts entirely? (y/n):" "n" _DISABLE
        if [[ "$_DISABLE" =~ ^[Yy]$ ]]; then
            _asterisk_remove_presence_timer
            rm -f "$EA_DIR/asterisk-presence-alert.sh" "$STATE_FILE"
            cat > "$SETTINGS_FILE" << ENV
PRESENCE_ENABLED="n"
PRESENCE_NTFY_URL=""
ENV
            log_success "Presence alerts disabled."
            return 0
        fi
    else
        local _WANT=""
        prompt_yn "Send an ntfy alert when an extension's SIP registration goes offline / comes back online? (y/n):" "n" _WANT
        [[ "$_WANT" =~ ^[Yy]$ ]] || return 0
    fi

    local _ntfy_default="${_CUR_NTFY:-https://ntfy.sh/asterisk-presence}"
    if [[ -z "$_CUR_NTFY" ]] && [[ -f "$DOCKER_DIR/ntfy/config/server.yml" ]]; then
        local _local_base_url
        _local_base_url="$(grep -oP '(?<=base-url: ")[^"]+' "$DOCKER_DIR/ntfy/config/server.yml" 2>/dev/null || true)"
        if [[ -n "$_local_base_url" ]] && [[ "$_local_base_url" != "https://ntfy.example.com" ]]; then
            _ntfy_default="${_local_base_url}/asterisk-presence"
            log_info "Detected a configured local ntfy instance at $_local_base_url — using it as the default."
        fi
    fi
    local PRESENCE_NTFY_URL=""
    prompt_text "  ntfy topic URL:" "$_ntfy_default" PRESENCE_NTFY_URL
    if [[ -z "$PRESENCE_NTFY_URL" ]]; then
        log_warning "No topic entered — presence alerts not enabled."
        return 0
    fi

    _asterisk_write_presence_alert_script "$EA_DIR/asterisk-presence-alert.sh" "$CONTAINER_NAME" "$PRESENCE_NTFY_URL" "$STATE_FILE"
    _asterisk_install_presence_timer "$EA_DIR"

    cat > "$SETTINGS_FILE" << ENV
PRESENCE_ENABLED="y"
PRESENCE_NTFY_URL="${PRESENCE_NTFY_URL}"
ENV
    chown "$ACTUAL_USER:$ACTUAL_USER" "$SETTINGS_FILE" 2>/dev/null || true
    log_success "Presence alerts enabled (checked every 2 minutes) — topic: $PRESENCE_NTFY_URL"
    log_info "Fires only on a state CHANGE, never every check — the first check after enabling"
    log_info "never alerts by itself, since there's no prior state to compare against yet."
}

# Offers to add/refresh the Security Dashboard and a PSTN trunk as part of
# this SAME run, instead of needing to separately remember and run
# `sudo ./setup.sh security-dashboard` / `sudo ./setup.sh pstn-trunk`
# afterward. Neither loses its own independent registration/invocability —
# this is purely a convenience layer on top, called from both the fresh-
# install and update-mode paths below. An already-installed piece is just
# silently refreshed (install_security-dashboard/install_pstn-trunk each
# have their own update/fresh/cancel reinstall-mode gate, so calling them
# again here does the right thing automatically); a not-yet-installed piece
# gets a one-line y/n instead of every detailed prompt firing unconditionally.
_asterisk_offer_dashboard_and_trunk() {
    local EA_DIR="$1"

    # Only available when run through the full repo's setup.sh (which
    # sources every services/*.sh file, including these two) — a standalone
    # `sudo bash asterisk.sh` copy has neither function defined at all.
    if ! declare -F install_security-dashboard >/dev/null 2>&1 && ! declare -F install_pstn-trunk >/dev/null 2>&1; then
        log_info "Run this from the full ubuntu-post-install repo (not a standalone copy) to also"
        log_info "get prompts here for the Security Dashboard and a PSTN trunk — skipping both."
        return 0
    fi

    if declare -F install_security-dashboard >/dev/null 2>&1; then
        echo ""
        if [[ -f "$DOCKER_DIR/security-dashboard/app.py" ]]; then
            log_info "Security Dashboard already installed — refreshing it too..."
            install_security-dashboard
        else
            local _WANT_DASH=""
            prompt_yn "Set up the Security Dashboard (Security Log, Extensions, CrowdSec — one page)? (y/n):" "y" _WANT_DASH
            [[ "$_WANT_DASH" =~ ^[Yy]$ ]] && install_security-dashboard
        fi
    fi

    if declare -F install_pstn-trunk >/dev/null 2>&1; then
        echo ""
        if [[ -f "$EA_DIR/config/asterisk/pstn-trunk-dialplan.conf" ]]; then
            log_info "PSTN trunk already configured — refreshing it too..."
            install_pstn-trunk
        else
            local _WANT_TRUNK=""
            prompt_yn "Configure a real SIP/PSTN trunk (actual outside phone numbers, e.g. Anveo Direct/VoIP.ms)? (y/n):" "n" _WANT_TRUNK
            [[ "$_WANT_TRUNK" =~ ^[Yy]$ ]] && install_pstn-trunk
        fi
    fi
}

# ── Shared: docker-compose.yml ─────────────────────────────────────────────
# Same reasoning as above — one copy of the template used by both fresh
# installs and updates. Must be called with $PWD already at the install dir.
# HAS_VLANS_VAL/VLAN_SUBNETS_VAL aren't referenced here — they live only in
# .env, which the entrypoint reads at container start.
#
# The heredoc stays quoted so ${TURN_PORT} and friends reach docker compose
# literally (it interpolates them from .env, this script must not). Project
# and container names are therefore substituted afterwards, same placeholder
# trick the Caddy volume line already uses below.
#
# Every install now runs its own dedicated coturn — there's no shared coturn
# service left in this repo to opt into (see attic/coturn.sh for why it was
# retired). USE_EMBEDDED_COTURN still exists as a parameter purely for
# backward compatibility with pre-retirement installs that were pointed at
# the old shared coturn service instead: an "update" on one of those must
# keep NOT writing a coturn: block (there's no .env TURN_PASSWORD for it to
# use), so it stays exactly as it was rather than silently gaining or losing
# a container. See the two call sites below for how each decides.
_asterisk_write_compose() {
    local PROJECT="$1" CONTAINER="$2" COTURN_CONTAINER="$3" USE_EMBEDDED_COTURN="${4:-true}"
    local COTURN_MIN_PORT_VAL="${5:-49152}" COTURN_MAX_PORT_VAL="${6:-49252}"

    local _COTURN_DEPENDS="    depends_on:
      coturn:
        condition: service_started
"
    local _COTURN_SERVICE="
  coturn:
    image: coturn/coturn:latest
    container_name: COTURN_CONTAINER_PLACEHOLDER
    network_mode: host
    user: root
    entrypoint: [\"/coturn-entrypoint.sh\"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    env_file: .env
    command:
      - -n
      - --listening-port=\${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=\${TURN_USERNAME:-easyasterisk}:\${TURN_PASSWORD}
      - --realm=\${DOMAIN_NAME:-localhost}
      - --min-port=${COTURN_MIN_PORT_VAL}
      - --max-port=${COTURN_MAX_PORT_VAL}
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped
"
    [[ "$USE_EMBEDDED_COTURN" != true ]] && _COTURN_DEPENDS="" && _COTURN_SERVICE=""

    cat > docker-compose.yml << EOF
name: PROJECT_NAME_PLACEHOLDER

services:
  asterisk:
    build: .
    container_name: ASTERISK_CONTAINER_PLACEHOLDER
    network_mode: host
${_COTURN_DEPENDS}    volumes:
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
${_COTURN_SERVICE}
EOF

    sed -i "s#PROJECT_NAME_PLACEHOLDER#${PROJECT}#; \
            s#ASTERISK_CONTAINER_PLACEHOLDER#${CONTAINER}#; \
            s#COTURN_CONTAINER_PLACEHOLDER#${COTURN_CONTAINER}#" docker-compose.yml

    # Share Caddy's cert store (read-only) so the entrypoint can auto-sync a
    # real Let's Encrypt cert for DOMAIN_NAME instead of falling back to
    # self-signed. No-op if Caddy isn't installed on this box.
    #
    # This is entirely about Asterisk's OWN SIP transport-tls cert (port
    # 5061) -- it has nothing to do with coturn's separate, unrelated TURNS
    # (TLS-wrapped TURN) capability, which the (since-retired) shared coturn
    # service indeed didn't support (see attic/coturn.sh's README). A
    # previous version of this check gated the mount on USE_EMBEDDED_COTURN == true, conflating
    # the two. Confirmed live: on a shared-coturn install with a real Caddy
    # cert already sitting on disk for DOMAIN_NAME, Asterisk silently kept
    # generating (and re-generating) a self-signed cert forever, because
    # /caddy-data was never mounted into the container at all -- sync_caddy_
    # cert() couldn't see a cert store that, from its own vantage point,
    # simply didn't exist. Most SIP/TLS clients refuse a self-signed cert
    # outright with no clear error, which was the actual cause of a
    # "port's open, cert domain matches, registration still silently fails"
    # case that every other layer (firewall, coturn reachability, DNS, cert
    # CN/SAN) had already checked out clean on.
    if [[ -d "$DOCKER_DIR/caddy/data" ]]; then
        sed -i "s#CADDY_VOLUME_PLACEHOLDER#      - ${DOCKER_DIR}/caddy/data:/caddy-data:ro#" docker-compose.yml
    else
        sed -i "/CADDY_VOLUME_PLACEHOLDER/d" docker-compose.yml
    fi
}

# ── Droplet-mode Caddy: web admin on the SAME FQDN used for SIP ────────────
# Deliberately NOT using configure_caddy_for_service in this mode. Caddy only
# holds a cert for domains it's actively serving, and Asterisk never does ACME
# itself — it mounts Caddy's cert store and copies the cert matching
# DOMAIN_NAME. Proxy the admin on a separate "admin" subdomain and Caddy
# obtains a cert for THAT name instead, the sync finds nothing matching
# DOMAIN_NAME, and SIP TLS silently stays self-signed. The helper would also
# prompt for its own domain, defaulting to "<subdomain>.${SITE_DOMAIN}" —
# which is blank or wrong whenever SITE_DOMAIN isn't set, i.e. every time
# this service is run by name (`sudo ./setup.sh asterisk` skips setup.sh's
# site-defaults wizard). There is exactly one correct domain here, so the
# site block is written directly with no domain prompt to get wrong.
#
# Sets WEB_ADMIN_PUBLIC_ACCESS_NEEDED (out-param) so the firewall steps below
# know whether the bare IP:port still has to be reachable.
_asterisk_configure_caddy_public() {
    local DOMAIN_NAME="$1" WEB_ADMIN_PORT_VAL="$2" PUBLIC_IP="$3"

    WEB_ADMIN_PUBLIC_ACCESS_NEEDED=true

    if [[ -z "$DOMAIN_NAME" ]]; then
        log_info "No FQDN set — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL} (nothing for Caddy to do)."
        return 0
    fi
    if [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -z "${CADDY_REMOTE_HOST:-}" ]]; then
        log_info "Caddy not installed — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL}, SIP TLS stays self-signed."
        return 0
    fi

    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
        if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
            EXTRA_BLOCK="    import authelia"
            # Disable built-in auth since Authelia handles it
            sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
        fi
    else
        # No local Authelia — offer one running elsewhere (e.g. a homelab).
        # There's no shared "(authelia)" Caddy snippet to import in that
        # case (authelia.sh only writes one when installing locally), so
        # this builds the same forward_auth block inline, targeting the
        # remote instance directly instead of the local "authelia:9091"
        # container reference.
        local _use_remote_auth=""
        prompt_yn "Protect the web admin with a remote Authelia instance (e.g. on a homelab)? (y/n):" "n" _use_remote_auth
        if [[ "$_use_remote_auth" =~ ^[Yy]$ ]]; then
            local _remote_authelia=""
            prompt_text "  Remote Authelia address — a bare host:port over a private network (e.g. a NetBird mesh IP:9091), or a full https:// URL if it's on its own public domain+TLS:" "" _remote_authelia
            if [[ -n "$_remote_authelia" ]]; then
                # header_up lines are required here (unlike the local
                # "authelia:9091" snippet in services/authelia.sh) because
                # this upstream is reached over a second Caddy hop when
                # given as a scheme-qualified URL (https://auth.example.com).
                # Caddy rewrites the outgoing request's Host header to that
                # upstream host so the remote Caddy can route/SNI-match it —
                # and without an explicit override, X-Forwarded-Host picks up
                # that rewritten value instead of the original site's host.
                # Confirmed live: Authelia was evaluating every request as
                # if it were for auth.example.com itself (which has
                # policy: bypass in access_control.rules), so every domain
                # silently passed through with no 2FA prompt regardless of
                # its own policy. Pinning these to the original request's
                # values fixes it regardless of hop count.
                #
                # X-Forwarded-Host uses a literal domain, NOT the {host}
                # placeholder. Confirmed live: {host} still evaluated to
                # the upstream's own hostname (auth.example.com) rather
                # than the original site's — Caddy appears to rewrite the
                # outgoing request's Host to the upstream target before
                # header_up placeholders are resolved for a scheme-
                # qualified upstream, so {host} echoes back the already-
                # rewritten value instead of the original client-facing
                # host. Since this site block only ever serves one domain
                # (DOMAIN_NAME), hardcoding it sidesteps the ambiguity
                # entirely instead of depending on Caddy's internal
                # header-mutation ordering.
                EXTRA_BLOCK="    forward_auth ${_remote_authelia} {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        header_up X-Forwarded-Method {method}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host ${DOMAIN_NAME}
        header_up X-Forwarded-Uri {uri}
    }"
                sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
                log_info "Using remote Authelia at ${_remote_authelia}."
                log_info "Verify it's reachable from this box before relying on it — e.g.:"
                log_info "  curl -I ${_remote_authelia}"
            else
                log_info "No address entered — skipping Authelia protection."
            fi
        fi
    fi

    echo ""
    local WANT_CADDY_PROXY=""
    prompt_yn "Reverse-proxy the web admin at https://${DOMAIN_NAME}/ via Caddy? (also gets Asterisk a trusted TLS cert for SIP instead of self-signed) (y/n):" "y" WANT_CADDY_PROXY
    [[ "$WANT_CADDY_PROXY" =~ ^[Yy]$ ]] || return 0

    local _CADDY_MODE="local"
    [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -n "${CADDY_REMOTE_HOST:-}" ]] && _CADDY_MODE="remote"

    # Asterisk runs with network_mode: host, so whatever proxies to it
    # needs a way to reach the host, not "localhost" (which resolves
    # to the proxying container's own netns). A local Caddy container
    # reaches the host via host.docker.internal (wired up in
    # services/caddy.sh's compose file); a remote Caddy machine needs
    # this box's actual public IP instead.
    local _PROXY_TARGET="host.docker.internal:${WEB_ADMIN_PORT_VAL}"
    [[ "$_CADDY_MODE" == "remote" ]] && _PROXY_TARGET="${PUBLIC_IP}:${WEB_ADMIN_PORT_VAL}"

    local _SITE_BLOCK
    _SITE_BLOCK="$(cat << CADDY_BLOCK

# Asterisk Web Admin
${DOMAIN_NAME} {
    # Auth (if any) must come before reverse_proxy — forward_auth is the
    # same directive family as reverse_proxy internally, and Caddy doesn't
    # reorder repeats of the same directive within a block; it runs them in
    # the order they're written. With reverse_proxy first, it would handle
    # and terminate every request immediately, so an auth check written
    # after it would be dead code that never runs — full bypass regardless
    # of what the auth server's own rules say.
${EXTRA_BLOCK}
    reverse_proxy ${_PROXY_TARGET}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${DOMAIN_NAME}.log
        format json
    }
}
CADDY_BLOCK
)"

    if [[ "$_CADDY_MODE" == "local" ]]; then
        # Caddy reaches this over the host's internal network — no
        # need to keep the port open to the public internet.
        WEB_ADMIN_PUBLIC_ACCESS_NEEDED=false
        local _CADDYFILE="$DOCKER_DIR/caddy/Caddyfile"
        local _CADDY_BACKUP="$_CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)"
        if [[ -f "$_CADDYFILE" ]]; then
            cp "$_CADDYFILE" "$_CADDY_BACKUP"
        else
            touch "$_CADDYFILE"
        fi
        if grep -q "^${DOMAIN_NAME}" "$_CADDYFILE" 2>/dev/null; then
            log_warning "${DOMAIN_NAME} already in Caddyfile — leaving the existing entry alone."
        else
            printf '%s\n' "$_SITE_BLOCK" >> "$_CADDYFILE"
            log_success "Added ${DOMAIN_NAME} to Caddyfile (backup: $(basename "$_CADDY_BACKUP"))"
            docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
            # The template Caddyfile ships with "admin off", so
            # `caddy reload` (which needs that same admin API) never
            # actually works here. Try it anyway, fall back to a
            # restart — confirmed necessary on a real deployment.
            if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                log_success "Web admin accessible at: https://${DOMAIN_NAME}"
            elif docker restart caddy &>/dev/null; then
                log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                log_success "Web admin should be accessible at: https://${DOMAIN_NAME}"
            else
                log_warning "Reload/restart failed — check: docker logs caddy"
                log_info "Manual fix: docker restart caddy"
            fi
        fi
    else
        local _SNIPPET_DIR="$DOCKER_DIR/caddy-snippets"
        mkdir -p "$_SNIPPET_DIR"
        printf '%s\n' "$_SITE_BLOCK" > "$_SNIPPET_DIR/asterisk.caddy"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$_SNIPPET_DIR/asterisk.caddy" 2>/dev/null || true
        log_success "Snippet saved: $_SNIPPET_DIR/asterisk.caddy"
        log_info "Copy to your Caddy machine: scp $_SNIPPET_DIR/asterisk.caddy caddy-host:~/caddy-snippets/"
        log_info "Remote Caddy reaches this box over its public IP, so the web admin port stays open below."
    fi
}

# ── DigitalOcean Cloud Firewall (network edge, in front of the droplet) ────
_asterisk_configure_do_cloud_firewall() {
    local DROPLET_ID="$1" WEB_ADMIN_PORT_VAL="$2" WEB_ADMIN_PUBLIC="$3"
    local COTURN_MIN_PORT_VAL="${4:-49152}" COTURN_MAX_PORT_VAL="${5:-49252}"

    local DO_FW_RULES=(
        "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5061,address:0.0.0.0/0,address:::/0"
    )
    if [[ "$WEB_ADMIN_PUBLIC" == true ]]; then
        DO_FW_RULES+=("protocol:tcp,ports:${WEB_ADMIN_PORT_VAL},address:0.0.0.0/0,address:::/0")
    fi
    DO_FW_RULES+=(
        "protocol:tcp,ports:8088-8089,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:10000-20000,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:${COTURN_MIN_PORT_VAL}-${COTURN_MAX_PORT_VAL},address:0.0.0.0/0,address:::/0"
    )

    echo ""
    if [[ -n "$DROPLET_ID" ]] && command -v doctl &>/dev/null && doctl account get &>/dev/null; then
        local EXISTING_FW
        EXISTING_FW="$(doctl compute firewall list --format ID,DropletIDs --no-header 2>/dev/null \
            | grep -E "(^|[, ])${DROPLET_ID}([, ]|\$)" | awk '{print $1}' | head -1)"

        if [[ -n "$EXISTING_FW" ]]; then
            log_warning "A Cloud Firewall (id $EXISTING_FW) is already attached to this droplet — not touching it."
            log_warning "Add these inbound rules to it yourself (Networking → Firewalls in the DO console):"
            printf '    %s\n' "${DO_FW_RULES[@]}"
        else
            local DO_FW=""
            prompt_yn "Create a DigitalOcean Cloud Firewall for this droplet via doctl now? (y/n):" "y" DO_FW
            if [[ "$DO_FW" =~ ^[Yy]$ ]]; then
                if doctl compute firewall create \
                    --name "asterisk" \
                    --droplet-ids "$DROPLET_ID" \
                    --inbound-rules "$(IFS=' '; echo "${DO_FW_RULES[*]}")" \
                    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,ports:0,address:0.0.0.0/0,address:::/0" \
                    &>/dev/null; then
                    log_success "Cloud Firewall 'asterisk' created and attached (SSH/22 included so you don't get locked out)."
                    log_info "Verify it in the DO console — adjust the SSH rule if you use a non-default SSH port."
                else
                    log_warning "doctl firewall create failed — add the rules manually (see README)."
                fi
            fi
        fi
    else
        log_info "doctl not installed/authenticated — configure a DigitalOcean Cloud Firewall manually:"
        log_info "Control Panel → Networking → Firewalls → create, attach to this droplet, allow:"
        printf '    %s\n' "${DO_FW_RULES[@]}"
    fi
}

# ── Non-DO public VPS: no automated network-edge firewall step exists for
# arbitrary providers the way _asterisk_configure_do_cloud_firewall automates
# DigitalOcean via doctl -- there's no universal API to drive. But a box set
# up with a public FQDN is, in practice, almost always sitting behind some
# provider-managed firewall anyway, and skipping this reminder left it
# entirely unmentioned. Confirmed live on an IONOS VPS: UFW showed every SIP/
# TURN/RTP port as ALLOW, Asterisk's own PJSIP logger showed zero incoming
# packets of any kind, and nothing in this installer's own output pointed at
# the actual cause -- IONOS's separate network-level firewall (Cloud Panel ->
# Networking -> Firewall Policies) only allowed 22/80/443/8443/8447 and
# silently dropped everything else before it ever reached the box. UFW being
# wide open proves nothing about a layer in front of it that UFW can't see.
_asterisk_remind_non_do_firewall() {
    local WEB_ADMIN_PORT_VAL="$1" WEB_ADMIN_PUBLIC_ACCESS_NEEDED="$2"
    local COTURN_MIN_PORT_VAL="${3:-49152}" COTURN_MAX_PORT_VAL="${4:-49252}"
    echo ""
    log_warning "This box is reachable via FQDN but wasn't set up as a DigitalOcean droplet,"
    log_warning "so no automatic network-edge firewall was configured (that step only exists"
    log_warning "for DO, via doctl). Most VPS/cloud providers run their OWN network-level"
    log_warning "firewall in front of the box, separate from UFW and invisible to it — UFW can"
    log_warning "show every port as ALLOW while traffic still gets silently dropped before it"
    log_warning "ever reaches this box. Check your provider's console for it (e.g. IONOS: Cloud"
    log_warning "Panel -> Networking -> Firewall Policies) and allow inbound, matching what UFW"
    log_warning "just opened on this box:"
    echo "    TCP      22              (SSH)"
    echo "    UDP/TCP  5060            (SIP)"
    echo "    TCP      5061            (SIP TLS)"
    [[ "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" == true ]] && echo "    TCP      ${WEB_ADMIN_PORT_VAL}              (web admin)"
    echo "    TCP      8088, 8089      (Asterisk HTTP/HTTPS)"
    echo "    UDP      10000-20000     (RTP media)"
    echo "    UDP/TCP  3478             (TURN/STUN)"
    echo "    UDP      ${COTURN_MIN_PORT_VAL}-${COTURN_MAX_PORT_VAL}     (TURN relay)"
}

# ── Shared: README ─────────────────────────────────────────────────────────
# One document with a droplet-only section appended in public-cloud mode, so
# the two deployment shapes can't document themselves differently by accident.
_asterisk_write_readme() {
    local EA_DIR="$1" CONTAINER="$2" IS_DO="$3" DOMAIN_NAME="$4" PUBLIC_IP="$5" WEB_ADMIN_PORT_VAL="$6"
    local USE_EMBEDDED_COTURN="${7:-true}" TURN_USERNAME_VAL="${8:-easyasterisk}" TURN_SERVER_DISPLAY="${9:-}"
    local COTURN_MIN_PORT_VAL="${10:-49152}" COTURN_MAX_PORT_VAL="${11:-49252}"
    local _host="${DOMAIN_NAME:-${PUBLIC_IP:-<host-ip>}}"
    [ -z "$TURN_SERVER_DISPLAY" ] && TURN_SERVER_DISPLAY="${_host}:3478"

    {
        cat << MD
# Easy Asterisk PBX + coturn

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal. Suitable for home intercom, VoIP handsets, and softphones.

One installer covers both a home/LAN box and a public cloud VM — it detects a
DigitalOcean droplet at install time and adjusts. This install is in
**$( [[ "$IS_DO" == true ]] && echo "public cloud / droplet" || echo "home / LAN" )** mode; re-run
\`sudo ./setup.sh asterisk\` and pick a full reinstall to change that.

## Manage

\`\`\`bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
\`\`\`

## Management script

\`\`\`bash
docker exec -it ${CONTAINER} easy-asterisk --help
\`\`\`

Use it to create SIP extensions (Server Settings → Extensions) before
connecting a phone. The Security Dashboard's Extensions tab
(\`services/security-dashboard.sh\`) does the same thing from a browser.

## SIP client setup

| Setting         | Value                                |
|-----------------|--------------------------------------|
| SIP server      | \`${_host}\`                          |
| SIP port        | 5061 (TLS) / 5060 (UDP)              |
| TURN server     | \`${TURN_SERVER_DISPLAY}\`            |
| TURN username   | ${TURN_USERNAME_VAL}                 |
| TURN password   | see \`.env\` → \`TURN_PASSWORD\`         |

This install runs its own dedicated coturn container (the \`coturn:\` service in docker-compose.yml).

Recommended softphones: Linphone, Zoiper, Bria, Grandstream Wave, and
[Sipnetic](https://www.sipnetic.com/) on Android (free, TLS/SRTP +
STUN/TURN/ICE). For a phone to work the same way regardless of network (LAN,
VLAN, remote, no VPN), register it against \`${_host}:5061\` over TLS. Plain
UDP/TCP on 5060 still works for LAN-only devices, but only the FQDN+TLS path
is location-independent.

If it registers but calls connect with no audio, the RTP/TURN port ranges
below are almost always the cause — check them on every firewall layer.

## TLS certificate

Caddy is what actually talks to Let's Encrypt — Asterisk never does ACME
itself. If Caddy is installed and holds a cert for \`DOMAIN_NAME\` (i.e.
there's a Caddyfile site block for that exact hostname), the container mounts
Caddy's cert store read-only and the entrypoint syncs it in automatically on
every start — and re-checks every 12h so renewals get picked up without a
restart. No Caddyfile block for the domain, or no Caddy at all, falls back to
a self-signed cert (phones must be configured to accept it).

## Web admin

Access the Easy Asterisk web interface at
\`http://${PUBLIC_IP:-<host-ip>}:${WEB_ADMIN_PORT_VAL}\` or via your configured
reverse-proxy domain. (8081 is the default; if that port was already taken by
something else on this box, the installer picked the next free one instead —
\`WEB_ADMIN_PORT\` in \`.env\` is the actual value.)

## Internal SIP messaging (no PSTN trunk needed)

Every extension can send/receive Asterisk's native SIP MESSAGE (no carrier
SMS, no PSTN, no cost) once its "messaging" flag is set to yes in
\`pstn-permissions.conf\` — via the Security Dashboard's Extensions tab, or by
hand. This works independent of \`pstn-trunk.sh\` entirely. Under the hood:
every device endpoint gets \`message_context=sip-messaging\`, routing messages
to a dedicated \`config/asterisk/messaging-dialplan.conf\` context instead of
\`[intercom]\` (which already owns per-device call routing) — this
install/update patches both the device-creation code (so new extensions pick
it up automatically) and any devices that already existed. Confirmed against
a live install's \`pjsip.conf\`/\`extensions.conf\` on 2026-07-23 — the MESSAGE
sender-extraction logic itself is still unconfirmed against real traffic; if
messages silently don't arrive, check
\`docker exec ${CONTAINER} asterisk -rx "core set verbose 3"\` while sending one.

## Extension presence (online/offline) alerts

Optional ntfy alert when an extension's SIP registration changes state —
offered on both fresh install and "update in place". Checked every 2
minutes (systemd timer, cron.d fallback); fires only on a change, never on
every check.

## Logs

Asterisk's security-level events (auth failures, SIP brute-force attempts)
are written to \`logs/full\` as well as the container's stdout — that file is
what the Security Dashboard's Security Log tab and CrowdSec's Asterisk
acquisition both read. It's rotated at 100MB (5 generations, compressed) via
\`/etc/logrotate.d/asterisk\`; unrotated it reached 1.4GB in three days on a
publicly reachable box.

## Standalone backup/restore

This directory is self-contained — dialplan, pjsip devices, voicemail
messages, recordings, \`.env\` (including its coturn credential), and
\`docker-compose.yml\` all live under \`${EA_DIR}\`. \`asterisk-standalone-backup.sh\`
(written into this directory at install time) tars the whole thing up
independent of Kopia or any other backup service in this repo — useful for
a one-off snapshot before a risky change, or to move this PBX to a new host
without setting up the full backup stack first.

\`\`\`bash
sudo ${EA_DIR}/asterisk-standalone-backup.sh backup [output-dir]
# writes ~/asterisk-backups/asterisk-backup-<timestamp>.tar.gz by default
# (deliberately outside ~/docker/, so a Kopia backup of this box doesn't
# also end up backing up a backup-of-itself on every run)

sudo ${EA_DIR}/asterisk-standalone-backup.sh restore <archive.tar.gz>
# moves the current install aside (timestamped, not deleted) and extracts
# the archive in its place; rolls back automatically if extraction fails
\`\`\`

Both subcommands stop the container first (voicemail/spool are written to
continuously — a live tar could capture a half-written file) and restart it
after, and both require typing \`YES\` to confirm before touching anything.
To migrate to a new host: run \`backup\` on the old one, copy the archive
over, then run \`restore\` after a fresh \`sudo ./setup.sh asterisk\` install
(or directly into an empty \`${EA_DIR}\`) on the new host.

\`restore\` also detects and fixes the one thing that doesn't travel between
boxes on its own: \`pjsip.conf\`'s \`external_media_address\`/
\`external_signaling_address\` are literal IPs, baked in by easy-asterisk at
first container start — restoring an archive from a different box verbatim
would otherwise leave the OLD box's IP in place, breaking RTP media (and
likely SIP registration) even though the dialplan itself comes back fine.
\`restore\` compares the archive's IP against this host's own (same
DO-metadata → ifconfig.me → \`hostname -I\` detection this script's own
install uses) and, if they differ, rewrites every occurrence across
\`config/\` and \`.env\` — never \`spool/\`/\`logs/\`/\`lib/\`, which hold voicemail
and recording audio a text substitution would corrupt. A same-host restore
(rolling back a config mistake, no IP change) leaves everything untouched.

\`restore\` also handles moving between the two layouts this repo supports
(see \`_asterisk_resolve_layout\` — plain \`asterisk\`/\`easy-asterisk\` vs.
DigitalOcean-droplet \`asterisk-digital-ocean\`/\`easy-asterisk-do\`). An
archive's own directory name and \`docker-compose.yml\` reflect whichever
layout produced it; restoring a droplet backup onto a fresh non-droplet
install (or vice versa) rewrites \`docker-compose.yml\`'s project/container/
coturn-container names to match THIS box's layout and lands the data at
this box's own directory — never leaving a second, wrongly-named directory
behind that would confuse every service that resolves Asterisk's layout
(Security Dashboard, PSTN trunk, CrowdSec's Asterisk acquisition, Caddy).

## VLANs / other subnets

\`.env\` → \`HAS_VLANS\`/\`VLAN_SUBNETS\` lists extra networks (space-separated
CIDRs) this server isn't itself attached to but that phones live on. These
become \`local_net=\` entries in \`pjsip.conf\` so NAT/SDP handling is correct
for those devices (missing entries here is the most common cause of calls
connecting with no audio). To change this after install:

\`\`\`bash
docker exec -it ${CONTAINER} easy-asterisk
# Server Settings → Configure VLAN/VPN Subnets
\`\`\`

## Ports

| Port          | Protocol | Purpose                          |
|---------------|----------|----------------------------------|
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| ${WEB_ADMIN_PORT_VAL}          | TCP      | Easy Asterisk web admin (auto-picked — see \`.env\`) |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| ${COTURN_MIN_PORT_VAL}–${COTURN_MAX_PORT_VAL}   | UDP      | TURN relay media ports (only if this install runs its own dedicated coturn — see below) |

## Data directories (all inside ${EA_DIR}/, included in backup)

| Directory            | Contents                        |
|----------------------|---------------------------------|
| config/asterisk/     | /etc/asterisk — dialplan, SIP   |
| config/easy-asterisk/| /etc/easy-asterisk — web config |
| logs/                | /var/log/asterisk               |
| spool/               | /var/spool/asterisk             |
| lib/                 | /var/lib/asterisk               |
MD

        # Droplet-only appendix. Guarded with an `if`, not an early return —
        # this block runs in the pipeline's subshell, where a bare `return`
        # would only leave the subshell and quietly skip nothing useful.
        [[ "$IS_DO" == true ]] && cat << MD

## DigitalOcean droplet notes

This install is in public-cloud mode: the installer read the droplet's public
IP from the metadata service, offered a Cloud Firewall, and reverse-proxied
the web admin on the same FQDN used for SIP. (The swapfile below isn't
droplet-specific — every install on this box gets the same check.)

### Droplet sizing

Asterisk + coturn is light for a handful of SIP extensions and personal use.

| Plan                          | vCPU | RAM   | Good for                              |
|--------------------------------|------|-------|----------------------------------------|
| Basic (regular), \$4/mo          | 1    | 512 MB | Works — this installer adds a 2GB swapfile automatically to cover it. Fine for a couple of extensions and light personal use. |
| **Basic (regular), \$6/mo — recommended** | 1    | 1 GB  | More headroom, still gets an automatic swapfile |
| Basic (regular), \$12/mo         | 1    | 2 GB  | Comfortable — no swap needed, a handful of concurrent calls |
| Basic (regular), \$24/mo         | 2    | 4 GB  | Several simultaneous calls, conference bridges, transcoding |

10 GB SSD (the \$4/mo plan's disk) is enough — this stack isn't storage-heavy,
and the swapfile only takes 2GB of it. Any DO region close to where the
phones actually are is fine; SIP/RTP care about latency more than raw
bandwidth.

**Swap:** DigitalOcean doesn't provision swap by default, and Docker +
Asterisk + coturn leave little headroom at 512MB–1GB RAM. This isn't
Asterisk- or droplet-specific — \`base.sh\` (and this installer, for the
standalone-run case) checks RAM ≤4GB with no existing swap and offers a 2GB
swapfile (persisted in \`/etc/fstab\`) on every install, since a box running
several Docker services at once needs the same insurance a single-purpose
droplet does. It's what makes the \$4/mo plan viable instead of risking an
OOM kill under load — and it's why nothing above 4GB gets asked at all.

**OS image:** Ubuntu 24.04 LTS (supported through April 2029) is the safe,
battle-tested choice for Docker + coturn. Ubuntu 26.04 LTS is also available
and supported longer (through 2031) if you'd rather track the newer LTS.

### DNS

Point an A record at the droplet's public IP before running the installer:

\`\`\`
sip.yourdomain.com   A   ${PUBLIC_IP:-<droplet public IP>}
\`\`\`

That one FQDN is used for SIP, the web admin, and the TLS cert — there's no
separate domain to plan for the admin panel.

### Security

- **SSH:** key-based auth only, password login disabled — \`services/base.sh\`
  in this repo offers to do this for you on first run. Don't skip it; this
  box is public.
- **Two firewall layers, same rule set:**
  - **DigitalOcean Cloud Firewall** — filters at the network edge, before
    traffic reaches the droplet. The installer offers to create one
    automatically via \`doctl\` (only if none is already attached to this
    droplet — it never overwrites an existing one, to avoid clobbering a
    custom SSH allow-list). If \`doctl\` isn't set up, add the same rules as
    the Ports table above manually in the DO console (Networking →
    Firewalls), plus TCP 22 for SSH.
  - **UFW** — host-level, configured automatically by the installer as a
    second layer. Keep both in sync; don't let them contradict each other.
- The web admin port is only opened publicly when Caddy isn't fronting it
  locally — otherwise it's reachable at \`https://${DOMAIN_NAME:-your-domain}/\`
  only, not the bare IP:port.
- **CrowdSec** — SIP brute-force/enumeration protection
  (\`crowdsecurity/asterisk\` collection). Not installed by this script —
  install it separately (whiptail menu, or \`sudo ./setup.sh crowdsec\`); its
  own installer auto-detects this install and wires up SIP protection
  regardless of install order.
- DO's paid Droplet Backups, or \`services/borg-backup.sh\` installed
  separately, are both options for a rollback path.

### Other services (installed separately, not by this script)

This installer only sets up Asterisk + coturn. Everything else — Caddy,
CrowdSec, Authelia, ntfy, watchtower, wg-easy, NetBird, Borg backup — is a
normal service in this repo: pick it from the whiptail menu, or run
\`sudo ./setup.sh <name>\` directly. A few integrate automatically with this
install if already present, no extra config needed:

- **Caddy** — if installed (locally, or you're on a remote-Caddy setup), the
  installer reverse-proxies the web admin on \`DOMAIN_NAME\` and Asterisk syncs
  the resulting Let's Encrypt cert for SIP-TLS too. Not installed →
  self-signed cert, plain HTTP admin.
- **Authelia** — if installed locally (needs Caddy), or you point the
  installer at a remote instance (e.g. a homelab, via NetBird mesh IP or a
  public \`https://\` URL), the web admin gets SSO/2FA in front of it.
- **CrowdSec** — see Security above; wires up SIP protection automatically
  once installed, regardless of whether it went in before or after this.
MD
    } | write_readme "$EA_DIR"
}

install_asterisk() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn..."

    local ASTERISK_DIR ASTERISK_CONTAINER ASTERISK_COTURN ASTERISK_PROJECT
    _asterisk_resolve_layout
    local EA_DIR="$ASTERISK_DIR"
    local CONTAINER="$ASTERISK_CONTAINER"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk, patching Asterisk to"
        echo "[DRY-RUN]   log security events to logs/full (what CrowdSec + the Security Dashboard read)"
        echo "[DRY-RUN] Would rotate logs/full at 100MB via /etc/logrotate.d/asterisk"
        echo "[DRY-RUN] Would add a swapfile if RAM <= 4096MB and none exists (any deployment shape)"
        echo "[DRY-RUN] Would detect a DigitalOcean droplet via its metadata service (asking either way)"
        echo "[DRY-RUN]   and, in droplet mode, additionally:"
        echo "[DRY-RUN]     - skip the LAN/VLAN prompts and set up one public FQDN for SIP + web admin"
        echo "[DRY-RUN]     - reverse-proxy the web admin on that SAME FQDN (needed for SIP cert sync)"
        echo "[DRY-RUN]     - offer local OR remote Authelia to protect the web admin"
        echo "[DRY-RUN]     - offer to create a DigitalOcean Cloud Firewall via doctl"
        echo "[DRY-RUN] Would scan for a free web admin port starting at 8081 (avoids e.g. CrowdSec's 8080)"
        echo "[DRY-RUN] Would run its own dedicated coturn container for TURN, with a relay port"
        echo "[DRY-RUN]   range picked to avoid colliding with any other coturn already on the box"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, <web admin port>, 8088, 8089, 10000-20000,"
        echo "[DRY-RUN]   plus 3478 + the dedicated coturn's relay port range"
        echo "[DRY-RUN] Would offer 'update in place' instead of a fresh install if $EA_DIR already exists"
        echo "[DRY-RUN] Would patch vendor device-creation code + extensions.conf generator to route"
        echo "[DRY-RUN]   internal SIP MESSAGE through a dedicated [sip-messaging] dialplan context,"
        echo "[DRY-RUN]   gated live on each sender's 'messaging' flag in pstn-permissions.conf — migrates"
        echo "[DRY-RUN]   any already-existing devices too"
        echo "[DRY-RUN] Would offer optional ntfy alerts on extension registration going offline/online"
        echo "[DRY-RUN]   (checked every 2 minutes via systemd timer, cron.d fallback; always asked,"
        echo "[DRY-RUN]   update mode included)"
        echo "[DRY-RUN] Would offer to also set up the Security Dashboard and a PSTN trunk in this"
        echo "[DRY-RUN]   same run (calling services/security-dashboard.sh / services/pstn-trunk.sh"
        echo "[DRY-RUN]   directly — both stay independently invocable via their own service name too)"
        return 0
    fi

    [[ "$EA_DIR" == *asterisk-digital-ocean ]] && \
        log_info "Using the existing droplet install at $EA_DIR (containers ${CONTAINER}/${ASTERISK_COTURN}) — left where it is so Caddy, UFW, CrowdSec and the PSTN trunk keep pointing at it."

    # ── Existing install? Offer update-in-place instead of a full reinstall ───
    # A fresh install re-runs every prompt (droplet detection, networking mode,
    # domain, VLANs, firewalls, Authelia). An update only refreshes vendor
    # files + docker-compose.yml — picking up fixes like this one — and
    # rebuilds, without touching .env, UFW, any Cloud Firewall, or the
    # Caddy/Authelia config already in place.
    if [[ -f "$EA_DIR/docker-compose.yml" && -f "$EA_DIR/.env" ]]; then
        echo ""
        log_info "Existing install found at $EA_DIR."
        local REINSTALL_MODE=""
        prompt_reinstall_mode REINSTALL_MODE
        case "$REINSTALL_MODE" in
            update)
                # Detect BEFORE regenerating docker-compose.yml below: an
                # install that already runs its own dedicated coturn (every
                # install predating the shared coturn service) must keep
                # getting one on every update, or this rebuild silently
                # drops the container its own .env TURN_PASSWORD still
                # points at — every already-configured phone loses TURN with
                # no warning. Only an install with no embedded coturn block
                # (new installs made after shared coturn existed) skips it.
                local _HAD_EMBEDDED_COTURN=false
                grep -q '^  coturn:' "$EA_DIR/docker-compose.yml" 2>/dev/null && _HAD_EMBEDDED_COTURN=true

                mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
                         "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
                ensure_docker_dir_ownership "$EA_DIR"
                cd "$EA_DIR" || return 1

                _asterisk_refresh_vendor_files
                _asterisk_write_compose "$ASTERISK_PROJECT" "$CONTAINER" "$ASTERISK_COTURN" "$_HAD_EMBEDDED_COTURN"
                _asterisk_write_logrotate "$EA_DIR"
                _asterisk_write_standalone_backup_script "$EA_DIR" "$CONTAINER"
                _asterisk_patch_messaging_vendor_files "$EA_DIR"
                _asterisk_write_messaging_dialplan "$EA_DIR/config/asterisk/messaging-dialplan.conf"
                _asterisk_ensure_live_messaging_include "$EA_DIR" "$CONTAINER"
                _asterisk_migrate_existing_devices_message_context "$EA_DIR/config/asterisk/pjsip.conf"
                _asterisk_patch_voicemail_vendor_files "$EA_DIR"
                _asterisk_write_voicemail_dialplan "$EA_DIR/config/asterisk/voicemail-dialplan.conf"
                _asterisk_write_voicemail_conf "$EA_DIR/config/asterisk/voicemail.conf"
                _asterisk_ensure_live_voicemail_include "$EA_DIR" "$CONTAINER"
                ensure_docker_dir_ownership "$EA_DIR/config/asterisk"
                chmod 644 "$EA_DIR/config/asterisk/messaging-dialplan.conf" "$EA_DIR/config/asterisk/voicemail-dialplan.conf"

                log_info "Rebuilding and restarting containers..."
                if docker compose up -d --build --force-recreate; then
                    log_success "Update complete — vendor files and docker-compose.yml refreshed."
                else
                    log_warning "docker compose up failed — check: docker compose -f $EA_DIR/docker-compose.yml logs"
                fi

                # A pre-existing install with no embedded coturn block predates
                # this repo's dedicated-coturn-only model — it's still pointed
                # at a shared coturn container this repo no longer installs or
                # manages (attic/coturn.sh). Leave it running as-is; update
                # never touches .env or firewall rules anyway. Point at a
                # fresh reinstall as the migration path instead of silently
                # trying to heal a registration against a service that no
                # longer exists here.
                if [[ "$_HAD_EMBEDDED_COTURN" != true ]]; then
                    log_info "This install still points at a shared coturn service, which this repo no longer installs or manages. It will keep working as long as that coturn container keeps running. Run a full reinstall (not update) to migrate to a dedicated coturn."
                fi

                _asterisk_run_presence_step "$EA_DIR" "$CONTAINER"
                _asterisk_offer_dashboard_and_trunk "$EA_DIR"

                local _EXISTING_DOMAIN _EXISTING_PORT
                _EXISTING_DOMAIN="$(grep -E '^DOMAIN_NAME=' .env | cut -d= -f2-)"
                _EXISTING_PORT="$(grep -E '^WEB_ADMIN_PORT=' .env | cut -d= -f2-)"
                echo ""
                log_success "Existing .env, firewall rules, and Caddy/Authelia config were left untouched."
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
                echo ""
                log_warning "Full reinstall stops the existing containers and re-runs every"
                log_warning "prompt below from scratch (domain, networking, firewall, Caddy/"
                log_warning "Authelia), including generating a fresh dedicated coturn container"
                log_warning "with new TURN credentials — any already-configured phone's TURN"
                log_warning "settings will need to be updated afterward (re-scan its QR code)."
                local _WIPE_PBX_DATA=""
                prompt_yn "  Also delete stored PBX data (extensions, voicemail, recordings, spool)? (y/n):" "n" _WIPE_PBX_DATA

                log_info "Stopping the existing containers..."
                (cd "$EA_DIR" && docker compose down 2>/dev/null)

                if [[ "$_WIPE_PBX_DATA" =~ ^[Yy]$ ]]; then
                    rm -rf "$EA_DIR/config/asterisk" "$EA_DIR/spool" "$EA_DIR/logs" "$EA_DIR/lib"
                    log_warning "Deleted config/asterisk, spool, logs, and lib — extensions,"
                    log_warning "voicemail, and call recordings are gone."
                    if declare -F install_pstn-trunk >/dev/null 2>&1 || [ -f "$EA_DIR/pstn-trunk-usage-alert.sh" ]; then
                        log_warning "PSTN trunk patches config/asterisk's dialplan — re-run"
                        log_warning "'sudo ./setup.sh pstn-trunk' afterward to restore it."
                    fi
                fi
                ;;
        esac
    fi

    # ── Public cloud (DigitalOcean droplet) or home/LAN box? ──────────────────
    # Everything droplet-specific below hangs off this one answer.
    local IS_DO=false DROPLET_ID="" PUBLIC_IP=""
    _asterisk_detect_digitalocean

    # Not droplet-gated — every box gets the same low-RAM safety net now
    # (see lib/common.sh's ensure_swapfile). Idempotent: a no-op if base.sh
    # already added swap earlier in this run, or if swap already exists.
    ensure_swapfile

    mkdir -p "$EA_DIR"
    mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
             "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    _asterisk_refresh_vendor_files
    _asterisk_write_logrotate "$EA_DIR"
    _asterisk_write_standalone_backup_script "$EA_DIR" "$CONTAINER"
    _asterisk_patch_messaging_vendor_files "$EA_DIR"
    _asterisk_write_messaging_dialplan "$EA_DIR/config/asterisk/messaging-dialplan.conf"
    _asterisk_ensure_live_messaging_include "$EA_DIR" "$CONTAINER"
    _asterisk_patch_voicemail_vendor_files "$EA_DIR"
    _asterisk_write_voicemail_dialplan "$EA_DIR/config/asterisk/voicemail-dialplan.conf"
    _asterisk_write_voicemail_conf "$EA_DIR/config/asterisk/voicemail.conf"
    _asterisk_ensure_live_voicemail_include "$EA_DIR" "$CONTAINER"
    ensure_docker_dir_ownership "$EA_DIR/config/asterisk"
    chmod 644 "$EA_DIR/config/asterisk/messaging-dialplan.conf" "$EA_DIR/config/asterisk/voicemail-dialplan.conf"

    # ── Domain / networking mode ──────────────────────────────────────────────
    # A public cloud box is always reachable from anywhere, so there's no
    # LAN-only option worth offering and no VLAN to bridge — one FQDN covers
    # SIP registration, the web admin, and the TLS cert. A home box gets the
    # full choice, plus the VLAN/subnet questions that only matter there.
    local DOMAIN_NAME="" HAS_VLANS_VAL="n" VLAN_SUBNETS_VAL=""

    if [[ "$IS_DO" == true ]]; then
        echo ""
        echo "  Point a DNS A record at this box before continuing:"
        echo "    <subdomain>.${SITE_DOMAIN:-example.com}  A  ${PUBLIC_IP:-<public IP>}"
        echo ""
        echo "  This one FQDN covers everything below — SIP registration, the web"
        echo "  admin, and (via Caddy) the TLS cert Asterisk needs for SIP. There's"
        echo "  no separate \"admin domain\" to pick later — whatever you enter here"
        echo "  is what your SIP client (e.g. Sipnetic) will register against."
        prompt_text "FQDN for this PBX, e.g. sip.yourdomain.com [blank=self-signed cert, IP-only access]:" "" DOMAIN_NAME
        [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — using a self-signed cert; phones must trust it manually."
    else
        echo ""
        echo "  Networking mode:"
        echo "    1) FQDN (recommended) — TLS + TURN relay, every phone connects the"
        echo "                            same way regardless of LAN/VLAN/remote"
        echo "    2) LAN-only           — no domain, self-signed cert, local network/VPN only"
        local HA_NETMODE=""
        prompt_text "Choose [1]:" "1" HA_NETMODE

        if [[ "$HA_NETMODE" != "2" ]]; then
            prompt_text "FQDN (e.g. asterisk.${SITE_DOMAIN:-example.com}) [blank=fall back to LAN-only]:" "" DOMAIN_NAME
            [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — proceeding in LAN-only mode."
        fi

        # ── Local networks / VLANs ────────────────────────────────────────────
        # Feeds HAS_VLANS/VLAN_SUBNETS into .env, which the entrypoint reads to
        # add extra local_net= entries in pjsip.conf so phones on those subnets
        # get correct NAT/SDP handling (this is what fixes the "no sound"
        # symptom for devices on a VLAN the server isn't itself attached to).
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
        prompt_text "VLAN/VPN subnets, space-separated CIDRs [blank=none]:" "" VLAN_SUBNETS_VAL
        [[ -n "$VLAN_SUBNETS_VAL" ]] && HAS_VLANS_VAL="y"
    fi

    # ── Secrets / TURN ───────────────────────────────────────────────────────
    # Asterisk always runs its own dedicated coturn — there is no shared
    # coturn service in this repo anymore (see attic/coturn.sh for why it
    # was retired). find_free_coturn_range (below) is what makes running a
    # dedicated coturn per service safe: it checks every coturn-owning
    # service's .env on the box and picks a relay range that can't collide
    # with any of them.
    local USE_EMBEDDED_COTURN=true
    local TURN_USERNAME TURN_PASSWORD TURN_PORT_VAL TURN_SERVER_VAL

    TURN_USERNAME="easyasterisk"
    TURN_PASSWORD="$(generate_password 24)"
    TURN_PORT_VAL="3478"
    # A public box always has a usable TURN address (the FQDN if set, else its
    # public IP). A LAN box with no FQDN has none — coturn is only reachable
    # over the local network, so clients use the server's LAN address directly.
    TURN_SERVER_VAL=""
    if [[ "$IS_DO" == true ]]; then
        TURN_SERVER_VAL="${DOMAIN_NAME:-$PUBLIC_IP}:3478"
    elif [[ -n "$DOMAIN_NAME" ]]; then
        TURN_SERVER_VAL="${DOMAIN_NAME}:3478"
    fi

    # A dedicated coturn here running alongside Asterisk's own on a prior
    # install, or any Mattermost instance's own, is exactly the pre-merge
    # collision bug this repo's coturn history warns about if two of them
    # claim overlapping relay ports — confirmed live, two independent
    # coturns' default ranges used to overlap by ~100 UDP ports.
    # find_free_coturn_range (lib/common.sh) checks every coturn-owning
    # service's .env on the box and picks a range starting safely past
    # whatever's already claimed. No other coturn on the box at all leaves
    # it at the historical 49152-49252 default — nothing to collide with yet.
    local EMBEDDED_COTURN_MIN_PORT=49152 EMBEDDED_COTURN_MAX_PORT=49252
    find_free_coturn_range EMBEDDED_COTURN_MIN_PORT EMBEDDED_COTURN_MAX_PORT 100 49152
    [[ "$EMBEDDED_COTURN_MIN_PORT" != 49152 ]] && \
        log_info "Dedicated coturn relay range shifted to ${EMBEDDED_COTURN_MIN_PORT}-${EMBEDDED_COTURN_MAX_PORT} to stay clear of another coturn already on this box."

    _asterisk_write_compose "$ASTERISK_PROJECT" "$CONTAINER" "$ASTERISK_COTURN" "$USE_EMBEDDED_COTURN" \
        "$EMBEDDED_COTURN_MIN_PORT" "$EMBEDDED_COTURN_MAX_PORT"

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
    local _domain_comment="Set to your FQDN for remote access. Leave empty for LAN-only."
    local _vlan_comment="Extra local_net= entries for phones on networks this server isn't
# itself attached to. Space-separated CIDRs."
    if [[ "$IS_DO" == true ]]; then
        _domain_comment="Public FQDN for this box. Leave empty to fall back to a self-signed
# cert reachable at the public IP (${PUBLIC_IP:-unknown})."
        _vlan_comment="A public cloud box has one public NIC, so this is usually irrelevant.
# Only set it if you're bridging phones back in over a VPN (e.g.
# WireGuard/Tailscale) on a subnet this box isn't directly attached to."
    fi

    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# ${_domain_comment}
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
# This install runs its own dedicated coturn (see the coturn: service in docker-compose.yml).
TURN_USERNAME=${TURN_USERNAME}
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=${TURN_PORT_VAL}
# Empty when there's no publicly resolvable address (LAN-only, no FQDN).
TURN_SERVER=${TURN_SERVER_VAL}
# This install's own coturn relay range — other services' find_free_coturn_range
# (lib/common.sh) scans this file to avoid claiming an overlapping range.
TURN_MIN_PORT=${EMBEDDED_COTURN_MIN_PORT}
TURN_MAX_PORT=${EMBEDDED_COTURN_MAX_PORT}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── VLAN/VPN subnets ──────────────────────────────────────────
# ${_vlan_comment}
HAS_VLANS=${HAS_VLANS_VAL}
VLAN_SUBNETS=${VLAN_SUBNETS_VAL}

# ── Web admin ─────────────────────────────────────────────────
# Picked automatically at install time (first free port starting at 8081) —
# see WEB_ADMIN_PORT_VAL in services/asterisk.sh if this ever needs to
# change again; don't hand-edit without also updating Caddy's Caddyfile and
# every firewall layer to match.
WEB_ADMIN_PORT=${WEB_ADMIN_PORT_VAL}
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── Caddy reverse proxy for the web admin ─────────────────────────────────
    # Decided before the firewall rules below so they can be scoped correctly:
    # if a local Caddy ends up fronting the web admin, there's no reason to
    # also expose it directly — Caddy already reaches it over the host's
    # internal network (host.docker.internal), and leaving the bare IP:port
    # open would let anyone bypass Caddy/Authelia entirely.
    local WEB_ADMIN_PUBLIC_ACCESS_NEEDED=true
    if [[ "$IS_DO" == true ]]; then
        _asterisk_configure_caddy_public "$DOMAIN_NAME" "$WEB_ADMIN_PORT_VAL" "$PUBLIC_IP"
    else
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
        if [[ "$CADDY_SERVICE_CONFIGURED" == true && "$CADDY_SERVICE_MODE" == "local" ]]; then
            WEB_ADMIN_PUBLIC_ACCESS_NEEDED=false
        fi
    fi

    # ── UFW firewall rules (host-level) ───────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        if [[ "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" == true ]]; then
            ufw allow "${WEB_ADMIN_PORT_VAL}/tcp"
        else
            # Scoped, not deleted outright: a bare `ufw delete allow` also
            # blocks Caddy's own request arriving over the caddy_net bridge.
            ufw delete allow "${WEB_ADMIN_PORT_VAL}/tcp" 2>/dev/null || true
            ufw_allow_from_caddy_net "${WEB_ADMIN_PORT_VAL}"
        fi
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 10000:20000/udp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow "${EMBEDDED_COTURN_MIN_PORT}:${EMBEDDED_COTURN_MAX_PORT}/udp"
        ensure_ufw_enabled
        log_success "UFW rules added."
    fi

    # ── Network-edge firewall (in front of the box, not UFW) ──────────────────
    if [[ "$IS_DO" == true ]]; then
        _asterisk_configure_do_cloud_firewall "$DROPLET_ID" "$WEB_ADMIN_PORT_VAL" "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" \
            "$EMBEDDED_COTURN_MIN_PORT" "$EMBEDDED_COTURN_MAX_PORT"
    elif [[ -n "$DOMAIN_NAME" ]]; then
        _asterisk_remind_non_do_firewall "$WEB_ADMIN_PORT_VAL" "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" \
            "$EMBEDDED_COTURN_MIN_PORT" "$EMBEDDED_COTURN_MAX_PORT"
    fi

    # ── CrowdSec note ──────────────────────────────────────────────────────────
    # Not installed here — select it separately from the whiptail menu, or
    # `sudo ./setup.sh crowdsec`. Its own installer (services/crowdsec.sh)
    # auto-detects an Asterisk install and wires up SIP brute-force
    # protection on its own, in either install order.
    if command -v cscli &>/dev/null; then
        log_info "CrowdSec is already installed — rerun it to pick up SIP protection for this install:"
        log_info "  sudo ./setup.sh crowdsec"
    elif [[ "$IS_DO" == true ]]; then
        log_info "CrowdSec not installed. Recommended for SSH + SIP intrusion prevention on a"
        log_info "public box — install it separately (whiptail menu, or 'sudo ./setup.sh crowdsec')."
        log_info "It auto-detects this install and wires up SIP protection on its own."
    else
        log_info "CrowdSec not installed. Worth adding if SIP is reachable from the internet"
        log_info "(port-forwarded 5060/5061) — whiptail menu, or 'sudo ./setup.sh crowdsec'."
        log_info "It auto-detects this install and wires up SIP protection on its own."
    fi

    # ── Extension presence (online/offline) ntfy alerts ────────────────────────
    _asterisk_run_presence_step "$EA_DIR" "$CONTAINER"

    # ── README ────────────────────────────────────────────────────────────────
    _asterisk_write_readme "$EA_DIR" "$CONTAINER" "$IS_DO" "$DOMAIN_NAME" "$PUBLIC_IP" "$WEB_ADMIN_PORT_VAL" \
        "$USE_EMBEDDED_COTURN" "$TURN_USERNAME" "$TURN_SERVER_VAL" \
        "$EMBEDDED_COTURN_MIN_PORT" "$EMBEDDED_COTURN_MAX_PORT"

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    _asterisk_offer_dashboard_and_trunk "$EA_DIR"

    # ── Summary ───────────────────────────────────────────────────────────────
    local _LOCAL_IP
    _LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo localhost)"
    echo ""
    log_success "Easy Asterisk installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)$( [[ "$IS_DO" == true ]] && echo ", public cloud" )"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    elif [[ "$IS_DO" == true ]]; then
        echo "  Mode:        IP-only, public cloud (self-signed cert)"
        echo "  TURN server: ${PUBLIC_IP:-unknown}:3478"
    else
        echo "  Mode:        LAN-only"
        echo "  TURN server: (none — LAN/VPN only)"
    fi
    [[ "$IS_DO" == true ]] && echo "  Public IP:   ${PUBLIC_IP:-unknown}"
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://${PUBLIC_IP:-$_LOCAL_IP}:${WEB_ADMIN_PORT_VAL}"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it ${CONTAINER} easy-asterisk --help"
    if [[ -n "$DOMAIN_NAME" ]] && [[ -d "$DOCKER_DIR/caddy" ]]; then
        echo ""
        log_info "If Caddy was just installed in this same run, it may still be obtaining the"
        log_info "Let's Encrypt cert for ${DOMAIN_NAME} — Asterisk only checks for it at startup"
        log_info "and then every 12h. If SIP TLS still shows self-signed after a couple of"
        log_info "minutes, pick it up immediately with:"
        log_info "  docker compose -f $EA_DIR/docker-compose.yml restart asterisk"
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk
