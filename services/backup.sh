#!/bin/bash
# services/backup.sh — Full Docker-service backup via Kopia.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash backup.sh
# (Docker must already be installed when run standalone)
#
# Backs up each entire ~/docker/<service>/ directory (compose file, config, data,
# databases — everything needed to restore from nothing). Per-service behaviour:
#   Minecraft instances — flush world to disk (save-all), snapshot, no downtime
#   All other services  — stop, snapshot, restart (seconds of downtime each)
#
# Different services can be routed to different Kopia repos / drives.
# New services are auto-discovered on every run — no reconfiguration needed.
#
# Creates: ~/docker/backup/
#   backup.conf       settings + per-service destination map (chmod 600)
#   backup_kopia.sh   worker (run directly or via systemd timer)
#   restore_kopia.sh  interactive restore helper

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
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

register_service backup backup "Encrypted backup of all Docker services (full restore)"

install_backup() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/backup"
    local CONF_FILE="$DIR/backup.conf"
    local WORKER="$DIR/backup_kopia.sh"
    local RESTORE="$DIR/restore_kopia.sh"
    local DR_BRINGUP="$DIR/dr_bringup.sh"
    local SVC_NAME="post-install-backup"

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════╗"
    echo "║   BACKUP STRATEGIES — choose the right tool for your data        ║"
    echo "╚═══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  This installer sets up Kopia for full service backup, but here is"
    echo "  a quick reference to all available options."
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │ KOPIA (installed here) — block-level dedup + zstd + encryption  │"
    echo "  │   Use for: files that change constantly — Minecraft worlds,     │"
    echo "  │   databases, configs, entire Docker service directories.        │"
    echo "  │   Changed blocks stored once; unchanged blocks share space.     │"
    echo "  │   Restores via: restore_kopia_backup.sh (interactive)           │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │ BORG (sudo apt install borgbackup) — chunk dedup + encryption   │"
    echo "  │   Use for: same as Kopia. Choose Borg if you prefer Borgmatic   │"
    echo "  │   (YAML config), Vorta (GUI), or multi-machine repos.           │"
    echo "  │   borg init / borg create / borg list / borg extract            │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │ RSYNC plain  rsync -av --delete /src/ /dest/                    │"
    echo "  │   Use for: media, ROMs, files that rarely change and you just   │"
    echo "  │   need a copy. Fast, transparent — no special restore tool.     │"
    echo "  │   Not suitable for files that change often (one bad --delete    │"
    echo "  │   run immediately destroys the only copy in the destination).   │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │ RSYNC --link-dest  versioned snapshots, original folder layout  │"
    echo "  │   Creates dated dirs (2024-01-15/, 2024-01-16/, …).            │"
    echo "  │   Unchanged files are hard-linked — cost no extra disk space.  │"
    echo "  │   Each dated dir is a complete, browsable snapshot.             │"
    echo "  │   Use for: general files where you want versioning + readable   │"
    echo "  │   snapshot dirs without a special restore tool.                 │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │ RSNAPSHOT (sudo apt install rsnapshot) — automated rotation     │"
    echo "  │   Wraps rsync with a retention scheme (daily.0, weekly.0, …).  │"
    echo "  │   Hard-links unchanged files; dirs named by rsnapshot.          │"
    echo "  │   Use for: automated versioning without scripting --link-dest.  │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "  Quick reference:"
    echo "    Full service recovery, databases, configs → Kopia (this installer)"
    echo "    Frequently changing saves without downtime → gaming-backup service"
    echo "    Media / ROMs (rarely changes, just need a copy)   → rsync plain"
    echo "    Versioned snapshots, keep original folder layout  → rsync --link-dest"
    echo "    Versioned snapshots, want auto rotation scripted  → rsnapshot"
    echo ""
    echo "  Continuing with Kopia setup..."
    echo ""

    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Backup Setup  ·  Kopia                              ║"
    echo "║   Full ~/docker/<service>/ snapshots                  ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "  Backs up each entire service directory — compose file, config, data,"
    echo "  databases, everything needed to restore a service from scratch."
    echo ""
    echo "  Minecraft: world flushed to disk (save-all), snapshot, NO downtime."
    echo "  Everything else: stopped briefly, snapshotted, restarted."
    echo ""
    echo "  Different services can go to different drives / Kopia repos."
    echo "  New services are auto-detected on every run — no reconfiguration needed."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would discover services under $DOCKER_DIR"
        echo "[DRY-RUN] Would create $DIR with conf, worker, and restore scripts"
        echo "[DRY-RUN] Would create Kopia repo(s) at user-specified paths"
        echo "[DRY-RUN] Would install systemd timer"
        return 0
    fi

    # ── 1. Kopia ─────────────────────────────────────────────────────────────
    if ! command -v kopia >/dev/null 2>&1; then
        log_info "Installing Kopia..."
        if command -v apt-get >/dev/null 2>&1; then
            install -d -m 0755 /etc/apt/keyrings
            curl -fsSL https://kopia.io/signing-key \
                | gpg --dearmor --yes -o /etc/apt/keyrings/kopia-keyring.gpg \
            && echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" \
                > /etc/apt/sources.list.d/kopia.list \
            && apt-get update -y && apt-get install -y kopia
        fi
    fi
    command -v kopia >/dev/null 2>&1 \
        || { log_error "Kopia not installed. See https://kopia.io/docs/installation/"; return 1; }
    local KOPIA_BIN; KOPIA_BIN="$(command -v kopia)"
    log_success "Kopia: $("$KOPIA_BIN" --version 2>/dev/null | head -1)"

    # ── 2. Discover installed services ───────────────────────────────────────
    local -a ALL_SVCS=()
    local d svc
    for d in "$DOCKER_DIR"/*/; do
        [ -f "${d}docker-compose.yml" ] || continue
        svc="$(basename "$d")"
        [[ "$svc" == "backup" || "$svc" == "gaming-backup" ]] && continue
        ALL_SVCS+=("$svc")
    done

    if [ "${#ALL_SVCS[@]}" -eq 0 ]; then
        log_warning "No services found under $DOCKER_DIR — auto-detected on each backup run."
    else
        log_info "Services found: ${ALL_SVCS[*]}"
    fi

    # ── 3. Destinations ───────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  BACKUP DESTINATIONS"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Each destination is a Kopia repository directory."
    echo "  For best resilience: use a different drive or mount point from your data."
    echo "  Destination names must be letters, numbers, and underscores only."
    echo ""

    local DEFAULT_DEST="$ACTUAL_HOME/backups/kopia-backup"
    local _repo=""
    prompt_text "  Default repository path [${DEFAULT_DEST}]:" "$DEFAULT_DEST" _repo
    _repo="${_repo/#\~/$ACTUAL_HOME}"; _repo="${_repo%/}"

    local -a DEST_NAMES_ARR=("default")
    local -A DEST_REPOS=() DEST_PASSWORDS=() DEST_CONFIGS=()
    DEST_REPOS["default"]="$_repo"
    DEST_CONFIGS["default"]="/etc/kopia-backup/default.config"

    local _extra=""
    prompt_yn "  Add more destinations (for services on different drives)? (y/N):" "n" _extra
    if [[ "$_extra" =~ ^[Yy]$ ]]; then
        echo ""
        local _dn _dr
        while true; do
            prompt_text "    Destination name (blank to finish):" "" _dn
            [ -z "$_dn" ] && break
            _dn="${_dn//[^a-zA-Z0-9_]/_}"
            [ "$_dn" = "default" ] && { log_warning "  'default' is reserved — use another name."; continue; }
            prompt_text "    Path for '$_dn' repository:" "" _dr
            [ -z "$_dr" ] && continue
            _dr="${_dr/#\~/$ACTUAL_HOME}"; _dr="${_dr%/}"
            DEST_REPOS["$_dn"]="$_dr"
            DEST_CONFIGS["$_dn"]="/etc/kopia-backup/${_dn}.config"
            DEST_NAMES_ARR+=("$_dn")
            log_success "    Destination '$_dn' → $_dr"
        done
    fi

    # ── 4. Service → destination assignment ──────────────────────────────────
    local -A SVC_DEST_MAP=()
    if [ "${#ALL_SVCS[@]}" -gt 0 ] && [ "${#DEST_NAMES_ARR[@]}" -gt 1 ]; then
        echo ""
        echo "═══════════════════════════════════════════════════════"
        echo "  ASSIGN SERVICES TO DESTINATIONS"
        echo "═══════════════════════════════════════════════════════"
        echo ""
        echo "  Destinations:"
        local dn
        for dn in "${DEST_NAMES_ARR[@]}"; do
            printf "    %-16s %s\n" "$dn" "${DEST_REPOS[$dn]}"
        done
        echo ""
        echo "  Press Enter to accept the default for each service."
        echo ""
        local _d
        for svc in "${ALL_SVCS[@]}"; do
            prompt_text "    $svc [default]:" "default" _d
            if [ -n "$_d" ] && [ "$_d" != "default" ] && [ -n "${DEST_REPOS[$_d]:-}" ]; then
                SVC_DEST_MAP["$svc"]="$_d"
            fi
        done
    fi

    # ── 5. Passwords ─────────────────────────────────────────────────────────
    # A destination's password is read back from an existing backup.conf
    # (if this destination name was already configured) rather than
    # re-prompted every run — this script has no update/fresh distinction,
    # so re-running it (e.g. to add a destination, or just re-running it
    # by habit) used to always mint a fresh/auto-generated password even
    # for an already-existing repo. Confirmed live: that fresh password
    # then fails to open the real repo at that path with "invalid
    # repository password" — the repo's actual password was whatever got
    # typed/generated the FIRST time, permanently, and nothing here ever
    # read that back.
    echo ""
    log_info "Setting repository passwords (stored in backup.conf, chmod 600)..."
    for dn in "${DEST_NAMES_ARR[@]}"; do
        local pw=""
        if [ -f "$CONF_FILE" ]; then
            pw="$(grep "^DEST_${dn}_PASSWORD=" "$CONF_FILE" 2>/dev/null | sed -E "s/^DEST_${dn}_PASSWORD='(.*)'$/\1/")"
        fi
        if [ -n "$pw" ]; then
            log_info "  Reusing existing password for '$dn' (from $CONF_FILE)."
        elif [ "$UNATTENDED" = true ]; then
            pw="$(generate_password 32)"
        else
            read -rsp "  Password for '$dn' [Enter = auto-generate]: " pw; echo
        fi
        [ -z "$pw" ] && pw="$(generate_password 32)" && log_info "  Auto-generated password for '$dn'."
        DEST_PASSWORDS["$dn"]="$pw"
    done

    # ── 6. Schedule ───────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  SCHEDULE & RETENTION"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Minecraft runs uninterrupted; other services stop briefly (seconds each)."
    echo "  Schedule for off-peak hours."
    echo ""
    echo "    1) Daily at 02:00         (recommended)"
    echo "    2) Every 12 hours"
    echo "    3) Weekly (Sunday 02:00)"
    echo "    4) Custom (systemd OnCalendar)"
    echo ""
    local _sch=""
    prompt_text "  How often? [1]:" "1" _sch
    local ONCALENDAR SCHED_LABEL
    case "${_sch:-1}" in
        2) ONCALENDAR="*-*-* 02,14:00:00"; SCHED_LABEL="every 12 hours"       ;;
        3) ONCALENDAR="Sun *-*-* 02:00:00"; SCHED_LABEL="weekly Sunday 02:00" ;;
        4) prompt_text "  OnCalendar expression:" "*-*-* 02:00:00" ONCALENDAR; SCHED_LABEL="$ONCALENDAR" ;;
        *) ONCALENDAR="*-*-* 02:00:00";     SCHED_LABEL="daily at 02:00"      ;;
    esac
    local KEEP_LATEST=""
    prompt_text "  Snapshots to keep (latest)? [7]:" "7" KEEP_LATEST
    KEEP_LATEST="${KEEP_LATEST:-7}"

    # ── Notifications (ntfy) ─────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  NOTIFICATIONS (optional)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Receive a push notification after every backup (and on failures)."
    echo "  Uses ntfy — free and self-hostable. Create a topic at https://ntfy.sh"
    echo "  Example URL: https://ntfy.sh/my-backup-alerts"
    echo ""
    local NTFY_URL="" NTFY_TOKEN=""
    prompt_text "  ntfy topic URL (blank to skip):" "" NTFY_URL
    if [ -n "$NTFY_URL" ]; then
        prompt_text "  ntfy access token (blank if public/no auth):" "" NTFY_TOKEN
    fi

    # ── Disaster-recovery spare box (optional) ────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  DISASTER-RECOVERY SPARE (optional)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  If you keep a spare box ready to take over on failure (running"
    echo "  dr_bringup.sh), this can push backup.conf + README.md to it after"
    echo "  every successful backup, so it's always ready without a manual copy."
    echo ""
    echo "  Requires passwordless SSH (key-based) from THIS box to the spare,"
    echo "  as the account below. Since the backup timer runs as root, that"
    echo "  usually means a key in /root/.ssh authorized on the spare — set that"
    echo "  up first if you haven't (ssh-keygen, then ssh-copy-id to the spare)."
    echo ""
    local DR_SYNC_HOST="" DR_SYNC_PATH=""
    prompt_text "  Spare box SSH destination, user@host (blank to skip):" "" DR_SYNC_HOST
    if [ -n "$DR_SYNC_HOST" ]; then
        prompt_text "  Path for backup.conf/README on the spare:" "~/docker/backup" DR_SYNC_PATH
        DR_SYNC_PATH="${DR_SYNC_PATH:-~/docker/backup}"

        # Catch a missing/unauthorized key now, not at 2am during the first
        # scheduled backup. Non-fatal either way — the setting is saved
        # regardless, since the key may simply not be set up yet.
        if ssh -o BatchMode=yes -o ConnectTimeout=5 "$DR_SYNC_HOST" true 2>/dev/null; then
            log_success "  SSH to $DR_SYNC_HOST works — spare sync will run after each backup."
        else
            log_warning "  Couldn't SSH to $DR_SYNC_HOST without a password right now."

            # If the spare isn't reachable at all (behind NAT, no port-forward —
            # a home box is the common case), a passwordless key won't help
            # until there's a network path there in the first place. Check
            # for an already-running mesh VPN first — wg-easy (this repo's
            # own), Netbird, or Tailscale are all common, and if the
            # operator already has any ONE of them running, pushing them
            # toward installing a second, redundant mesh would be actively
            # wrong. Only offer a choice when none of the three are present.
            local _VPN_DETECTED=""
            if [ -d "$DOCKER_DIR/wg-easy" ]; then
                _VPN_DETECTED="wg-easy"
            elif command -v netbird >/dev/null 2>&1 && systemctl is-active --quiet netbird 2>/dev/null; then
                _VPN_DETECTED="Netbird"
            elif command -v tailscale >/dev/null 2>&1 && systemctl is-active --quiet tailscaled 2>/dev/null; then
                _VPN_DETECTED="Tailscale"
            fi

            if [ -n "$_VPN_DETECTED" ]; then
                log_info "  Detected $_VPN_DETECTED already running — use its address for the spare box"
                log_info "  destination above instead of the public one, if you haven't already."
            else
                echo ""
                echo "    1) wg-easy — this repo's own guided WireGuard hub (chain-installs now)"
                echo "    2) Netbird — official installer (needs a setup key from your Netbird"
                echo "       account/self-hosted server — https://docs.netbird.io)"
                echo "    3) Tailscale — official installer (opens an auth link to your account —"
                echo "       https://tailscale.com)"
                echo "    4) Skip"
                echo ""
                local _VPN_CHOICE=""
                prompt_text "  Spare box not directly reachable? Set up a VPN mesh now [4]:" "4" _VPN_CHOICE
                case "${_VPN_CHOICE:-4}" in
                    1)
                        if declare -F install_wg-easy >/dev/null 2>&1; then
                            install_wg-easy
                        else
                            log_warning "  services/wg-easy.sh isn't loaded — run: sudo ./setup.sh wg-easy"
                        fi
                        ;;
                    2)
                        curl -fsSL https://pkgs.netbird.io/install.sh | sh \
                            && log_success "  Netbird installed — finish setup with: netbird up --setup-key <YOUR_SETUP_KEY>" \
                            || log_warning "  Netbird install failed — see https://docs.netbird.io/get-started/install/linux"
                        ;;
                    3)
                        curl -fsSL https://tailscale.com/install.sh | sh \
                            && log_success "  Tailscale installed — finish setup with: tailscale up" \
                            || log_warning "  Tailscale install failed — see https://tailscale.com/docs/install/linux"
                        ;;
                    *) : ;;
                esac
            fi

            local _HAVE_KEY=false
            [ -f /root/.ssh/id_ed25519 ] || [ -f /root/.ssh/id_rsa ] && _HAVE_KEY=true
            if [ "$_HAVE_KEY" = false ]; then
                local _GEN_KEY=""
                prompt_yn "  No SSH key found for root — generate one now (ssh-keygen)? (y/n):" "y" _GEN_KEY
                if [[ "$_GEN_KEY" =~ ^[Yy]$ ]]; then
                    ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 -q \
                        && log_success "  Generated /root/.ssh/id_ed25519" \
                        || log_warning "  ssh-keygen failed — generate one manually."
                fi
            fi

            local _COPY_KEY=""
            prompt_yn "  Run ssh-copy-id to $DR_SYNC_HOST now? (asks for its login password interactively) (y/n):" "y" _COPY_KEY
            if [[ "$_COPY_KEY" =~ ^[Yy]$ ]]; then
                if ssh-copy-id "$DR_SYNC_HOST"; then
                    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$DR_SYNC_HOST" true 2>/dev/null; then
                        log_success "  SSH to $DR_SYNC_HOST now works — spare sync will run after each backup."
                    else
                        log_warning "  ssh-copy-id reported success but the passwordless check still failed — check manually."
                    fi
                else
                    log_warning "  ssh-copy-id failed. Spare sync is saved but will fail until this works:"
                    log_warning "    ssh-copy-id $DR_SYNC_HOST"
                fi
            else
                log_warning "  Spare sync is saved but will fail until this works (as root, since"
                log_warning "  the backup timer runs as root): ssh-copy-id $DR_SYNC_HOST"
            fi
        fi
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"

    local repo pw cfg
    for dn in "${DEST_NAMES_ARR[@]}"; do
        repo="${DEST_REPOS[$dn]}"
        pw="${DEST_PASSWORDS[$dn]}"
        cfg="${DEST_CONFIGS[$dn]}"
        mkdir -p "$repo" "$(dirname "$cfg")" /var/cache/kopia-backup

        kp_d() { env KOPIA_PASSWORD="$pw" "$KOPIA_BIN" --config-file="$cfg" "$@"; }

        if kp_d repository status >/dev/null 2>&1; then
            log_success "Connected to existing repo '$dn'."
        elif test -e "$repo/kopia.repository.f"; then
            log_info "Connecting to existing repo '$dn' at $repo ..."
            kp_d repository connect filesystem --path="$repo" \
                --cache-directory=/var/cache/kopia-backup \
                || { log_error "Failed to connect to '$dn' repo."; return 1; }
        else
            log_info "Creating repo '$dn' at $repo ..."
            kp_d repository create filesystem --path="$repo" \
                --cache-directory=/var/cache/kopia-backup \
                || { log_error "Failed to create '$dn' repo."; return 1; }
        fi

        kp_d policy set --global --compression=zstd \
            --keep-latest="$KEEP_LATEST" \
            --keep-daily=7 --keep-weekly=4 --keep-monthly=3 \
            --keep-annual=0 --keep-hourly=0 >/dev/null
        log_success "Repo '$dn' ready at $repo"
    done
    unset -f kp_d

    # ── 7b. Offsite mirror (Backblaze B2) ────────────────────────────────────
    # Kopia's dedicated "b2" sync-to provider is marked [DEPRECATED] in
    # Kopia's own docs (kopia.io/docs/reference/command-line/common/
    # repository-sync-to-b2/) — confirmed before writing this rather than
    # building on a command that's on its way out. B2's S3-compatible
    # endpoint plus the actively-maintained `sync-to s3` provider is the
    # supported path instead: same B2 application key, just pointed at
    # B2's own s3.<region>.backblazeb2.com endpoint instead of AWS.
    #
    # Bucket creation and the application key can't be automated here on
    # purpose — Object Lock in particular is a deliberate, one-time choice
    # B2 only lets you make at bucket creation, not something safe for a
    # script to flip on (or skip) silently on someone's behalf. This walks
    # through both console steps, then handles the mechanical part: taking
    # the resulting bucket/endpoint/key and writing a verified
    # REMOTE_TYPE/REMOTE_ARGS into backup.conf.
    #
    # Encryption is NOT a separate step here — Kopia already encrypts
    # everything client-side (AES-256-GCM) using the repository password
    # set above, before any of it leaves this box. B2's own optional
    # Server-Side Encryption toggle is redundant on top of that; harmless
    # to also enable for defense-in-depth, but nothing here depends on it.
    local REMOTE_TYPE="none" REMOTE_ARGS=""
    if [ -f "$CONF_FILE" ]; then
        # Preserve whatever's already configured if this is a re-run and
        # the operator doesn't re-answer the prompt below — re-running this
        # installer has no update/fresh distinction, so without this an
        # already-working offsite mirror would silently reset to "none".
        REMOTE_TYPE="$(grep '^REMOTE_TYPE=' "$CONF_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
        REMOTE_ARGS="$(grep '^REMOTE_ARGS=' "$CONF_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')"
        [ -z "$REMOTE_TYPE" ] && REMOTE_TYPE="none"
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  OFFSITE MIRROR (optional)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Mirrors every local repo above to Backblaze B2 after each backup run —"
    echo "  the actual '1 copy offsite' piece of a real 3-2-1 backup. Skip this if"
    echo "  you don't have a B2 account yet, or would rather set REMOTE_TYPE/"
    echo "  REMOTE_ARGS in backup.conf by hand later."
    if [ "$REMOTE_TYPE" != "none" ]; then
        echo ""
        echo "  Offsite mirroring is already configured (REMOTE_TYPE=$REMOTE_TYPE)."
        echo "  Answering yes below replaces it; answering no leaves it as-is."
    fi
    echo ""
    local _setup_b2=""
    prompt_yn "  Set up Backblaze B2 offsite mirroring now? (y/N):" "n" _setup_b2
    if [[ "$_setup_b2" =~ ^[Yy]$ ]]; then
        echo ""
        echo "  Two one-time steps in the B2 web console first — this script can't do"
        echo "  these for you:"
        echo ""
        echo "  1) Buckets → Create a Bucket"
        echo "       - Files in Bucket: Private"
        echo "       - Object Lock: your call. ON means backups in this bucket can't be"
        echo "         deleted or overwritten for a retention period you choose, even by"
        echo "         someone holding valid credentials for it — protects the offsite"
        echo "         copy if this box is ever compromised, at the cost of genuinely not"
        echo "         being able to delete early yourself either. Can only be set at"
        echo "         bucket creation, not turned on later."
        echo "       - Note the endpoint shown on the bucket's details page afterward,"
        echo "         e.g. s3.us-west-004.backblazeb2.com — you'll need it below."
        echo ""
        echo "  2) Account → App Keys → Add a New Application Key"
        echo "       - Allow access to: the bucket you just created (not 'All')"
        echo "       - Type: Read and Write"
        echo "       - B2 shows the application key ONLY once — copy both values now,"
        echo "         you can't retrieve the key itself again afterward."
        echo ""
        # Character counts are echoed after each field (never the value
        # itself for the hidden one) so a failed paste is visible
        # immediately instead of only surfacing as a generic "left blank"
        # warning after all four prompts have already gone by — confirmed
        # live: a paste into the hidden Application Key field can silently
        # capture nothing depending on the terminal/SSH client, with no
        # other symptom until this point.
        local B2_BUCKET="" B2_ENDPOINT="" B2_KEY_ID="" B2_APP_KEY=""
        prompt_text "  Bucket name:" "" B2_BUCKET
        echo "    (${#B2_BUCKET} characters entered)"
        prompt_text "  Endpoint (e.g. s3.us-west-004.backblazeb2.com):" "" B2_ENDPOINT
        echo "    (${#B2_ENDPOINT} characters entered)"
        prompt_text "  Application Key ID:" "" B2_KEY_ID
        echo "    (${#B2_KEY_ID} characters entered)"
        read -rsp "  Application Key (input hidden): " B2_APP_KEY; echo
        echo "    (${#B2_APP_KEY} characters entered)"

        local _B2_MISSING=""
        [ -z "$B2_BUCKET" ]   && _B2_MISSING="${_B2_MISSING}Bucket name, "
        [ -z "$B2_ENDPOINT" ] && _B2_MISSING="${_B2_MISSING}Endpoint, "
        [ -z "$B2_KEY_ID" ]   && _B2_MISSING="${_B2_MISSING}Application Key ID, "
        [ -z "$B2_APP_KEY" ]  && _B2_MISSING="${_B2_MISSING}Application Key, "
        if [ -n "$_B2_MISSING" ]; then
            log_warning "Left blank: ${_B2_MISSING%, } — skipping B2 setup this run."
        else
            log_info "Verifying B2 credentials (dry-run sync against the 'default' repo)..."
            local _b2_err
            if _b2_err="$(env KOPIA_PASSWORD="${DEST_PASSWORDS[default]}" "$KOPIA_BIN" \
                    --config-file="${DEST_CONFIGS[default]}" repository sync-to s3 \
                    --bucket="$B2_BUCKET" --access-key="$B2_KEY_ID" \
                    --secret-access-key="$B2_APP_KEY" --endpoint="$B2_ENDPOINT" \
                    --dry-run 2>&1)"; then
                REMOTE_TYPE="s3"
                REMOTE_ARGS="--bucket=$B2_BUCKET --access-key=$B2_KEY_ID --secret-access-key=$B2_APP_KEY --endpoint=$B2_ENDPOINT"
                log_success "B2 credentials verified — offsite mirroring will run after each backup."
            else
                log_warning "B2 dry-run failed — check bucket name, endpoint, and key permissions:"
                log_warning "$_b2_err"
                log_warning "Not enabling offsite mirroring this run. Re-run this installer once"
                log_warning "fixed, or hand-edit REMOTE_TYPE/REMOTE_ARGS in backup.conf directly."
            fi
        fi
    fi

    # ── 8. Write backup.conf ─────────────────────────────────────────────────
    log_info "Writing $CONF_FILE ..."
    {
        echo "# ── backup.conf ────────────────────────────────────────────────────────────"
        echo "# Generated $(date '+%F %T'). Safe to hand-edit."
        echo "# Worker : sudo $WORKER"
        echo "# Restore: sudo $RESTORE"
        echo ""
        echo "KOPIA=\"$KOPIA_BIN\""
        echo ""
        echo "# Space-separated list of destination names (defines iteration order)."
        echo "DEST_NAMES=\"${DEST_NAMES_ARR[*]}\""
        echo "DEST_DEFAULT=\"default\""
        echo ""
        for dn in "${DEST_NAMES_ARR[@]}"; do
            echo "# ── destination: $dn"
            echo "DEST_${dn}_REPO=\"${DEST_REPOS[$dn]}\""
            echo "DEST_${dn}_CONFIG=\"${DEST_CONFIGS[$dn]}\""
            printf "DEST_%s_PASSWORD='%s'\n" "$dn" "${DEST_PASSWORDS[$dn]}"
            echo ""
        done
        echo "# ── Service → destination map ───────────────────────────────────────────────"
        echo "# Format: SVC_<name>=<dest_name>  (hyphens in service names become underscores)"
        echo "# Omit a service (or comment it out) to use DEST_DEFAULT."
        for svc in "${ALL_SVCS[@]}"; do
            local svc_var="${svc//-/_}"
            local dest_val="${SVC_DEST_MAP[$svc]:-}"
            if [ -n "$dest_val" ]; then
                echo "SVC_${svc_var}=\"${dest_val}\""
            else
                echo "# SVC_${svc_var}=\"default\""
            fi
        done
        echo ""
        echo "# ── Optional offsite mirror ─────────────────────────────────────────────────"
        echo "# Mirror ALL repos offsite after each run (see kopia repository sync-to --help)."
        echo "# B2: use the s3 provider against B2's S3-compatible endpoint, not the b2"
        echo "# provider — kopia.io marks repository-sync-to-b2 as deprecated. Example:"
        echo "#   REMOTE_TYPE=s3  REMOTE_ARGS=\"--bucket=NAME --access-key=KEYID --secret-access-key=KEY --endpoint=s3.us-west-004.backblazeb2.com\""
        echo "# Example SFTP: REMOTE_TYPE=sftp  REMOTE_ARGS=\"--host H --username U --path /srv/...\""
        echo "REMOTE_TYPE=\"$REMOTE_TYPE\""
        echo "REMOTE_ARGS=\"$REMOTE_ARGS\""
        echo ""
        echo "# ── Notifications (ntfy) ─────────────────────────────────────────────────────"
        echo "# Set NTFY_URL to receive backup success/failure alerts."
        echo "# Leave blank to disable. NTFY_TOKEN is optional (for private topics)."
        printf "NTFY_URL='%s'\n" "${NTFY_URL:-}"
        printf "NTFY_TOKEN='%s'\n" "${NTFY_TOKEN:-}"
        echo ""
        echo "# ── Disaster-recovery spare sync ───────────────────────────────────────────"
        echo "# If set, backup_kopia.sh scp's this backup.conf + README.md to"
        echo "# DR_SYNC_HOST:DR_SYNC_PATH after every successful backup, so a spare box"
        echo "# running dr_bringup.sh is always ready with no manual copy step. Requires"
        echo "# passwordless SSH from this box to the spare (see README.md)."
        printf "DR_SYNC_HOST='%s'\n" "${DR_SYNC_HOST:-}"
        printf "DR_SYNC_PATH='%s'\n" "${DR_SYNC_PATH:-~/docker/backup}"
    } > "$CONF_FILE"
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE"
    log_success "backup.conf written (chmod 600)"

    # ── 9. Install worker script ──────────────────────────────────────────────
    log_info "Installing worker $WORKER ..."
    cp "${HERE:-}/extras/backup_kopia.sh" "$WORKER"
    chmod +x "$WORKER"
    chown root:root "$WORKER" 2>/dev/null || true
    log_success "backup_kopia.sh installed"

    # ── 10. Install restore script ────────────────────────────────────────────
    local RESTORE_SRC="${HERE:-}/extras/restore_kopia.sh"
    if [ -f "$RESTORE_SRC" ]; then
        cp "$RESTORE_SRC" "$RESTORE"
        chmod +x "$RESTORE"
        chown root:root "$RESTORE" 2>/dev/null || true
        log_success "restore_kopia.sh installed"
    else
        log_warning "extras/restore_kopia.sh not found — restore script not installed"
        log_warning "Copy it manually: cp extras/restore_kopia.sh $RESTORE"
    fi

    # ── 10b. Install disaster-recovery bring-up script ────────────────────────
    # Non-interactive counterpart to restore_kopia.sh: restores every service's
    # latest snapshot and runs `docker compose up -d` with no prompts, meant to
    # run on a cold spare box during a real outage rather than the primary.
    local DR_BRINGUP_SRC="${HERE:-}/extras/dr_bringup_kopia.sh"
    if [ -f "$DR_BRINGUP_SRC" ]; then
        cp "$DR_BRINGUP_SRC" "$DR_BRINGUP"
        chmod +x "$DR_BRINGUP"
        chown root:root "$DR_BRINGUP" 2>/dev/null || true
        log_success "dr_bringup.sh installed"
    else
        log_warning "extras/dr_bringup_kopia.sh not found — DR bring-up script not installed"
        log_warning "Copy it manually: cp extras/dr_bringup_kopia.sh $DR_BRINGUP"
    fi

    # ── 11. Install test scripts ─────────────────────────────────────────────
    local TEST_SCRIPT="$DIR/test_backup_kopia.sh"
    local TEST_SRC="${HERE:-}/extras/test_backup_kopia.sh"
    if [ -f "$TEST_SRC" ]; then
        cp "$TEST_SRC" "$TEST_SCRIPT"
        chmod +x "$TEST_SCRIPT"
        chown root:root "$TEST_SCRIPT" 2>/dev/null || true
        log_success "test_backup_kopia.sh installed"
    else
        log_warning "extras/test_backup_kopia.sh not found — test script not installed"
    fi

    local TEST_UNIFIED="$DIR/test_backup.sh"
    local TEST_UNIFIED_SRC="${HERE:-}/extras/test_backup.sh"
    if [ -f "$TEST_UNIFIED_SRC" ]; then
        cp "$TEST_UNIFIED_SRC" "$TEST_UNIFIED"
        chmod +x "$TEST_UNIFIED"
        chown root:root "$TEST_UNIFIED" 2>/dev/null || true
        log_success "test_backup.sh installed"
    fi

    # ── 11b. Backup test timer ───────────────────────────────────────────────
    # Every service in this test stops briefly (seconds) while its data gets
    # moved aside and restored back — same interruption profile as the main
    # backup job itself. Weekly is the most thorough default, but that's a
    # standing tradeoff against a weekly blip on every service; offer the
    # same Daily/Weekly/Monthly/Custom shape the main backup schedule above
    # already gives, rather than hardcoding one choice.
    local TEST_SVC_NAME="post-install-backup-test"
    local _add_test=""
    prompt_yn "  Schedule an automated backup restore test? (y/N):" "n" _add_test
    if [[ "$_add_test" =~ ^[Yy]$ ]]; then
        echo ""
        echo "    1) Weekly (Saturday 03:00)         (recommended)"
        echo "    2) Monthly (1st of the month, 03:00)"
        echo "    3) Custom (systemd OnCalendar)"
        echo ""
        local _test_sch=""
        prompt_text "  How often? [1]:" "1" _test_sch
        local TEST_ONCALENDAR TEST_SCHED_LABEL TEST_CRON=""
        case "${_test_sch:-1}" in
            2) TEST_ONCALENDAR="*-*-01 03:00:00"; TEST_SCHED_LABEL="monthly (1st, 03:00)"; TEST_CRON="0 3 1 * *" ;;
            3) prompt_text "  OnCalendar expression:" "Sat *-*-* 03:00:00" TEST_ONCALENDAR
               TEST_SCHED_LABEL="$TEST_ONCALENDAR" ;;
            *) TEST_ONCALENDAR="Sat *-*-* 03:00:00"; TEST_SCHED_LABEL="weekly (Saturday 03:00)"; TEST_CRON="0 3 * * 6" ;;
        esac

        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            tee "/etc/systemd/system/${TEST_SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Automated restore test for Kopia backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $TEST_SCRIPT
SVCEOF

            tee "/etc/systemd/system/${TEST_SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Kopia backup restore test ($TEST_SCHED_LABEL)

[Timer]
OnCalendar=$TEST_ONCALENDAR
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
SVCEOF

            systemctl daemon-reload
            systemctl enable --now "${TEST_SVC_NAME}.timer"
            log_success "Backup test timer enabled ($TEST_SCHED_LABEL)"
        else
            if [ -z "$TEST_CRON" ]; then
                log_warning "Custom OnCalendar schedules aren't auto-translated to cron — installing"
                log_warning "a weekly placeholder; edit /etc/cron.d/${TEST_SVC_NAME} to adjust the timing."
                TEST_CRON="0 3 * * 6"
            fi
            echo "$TEST_CRON root /bin/bash $TEST_SCRIPT >> /var/log/${TEST_SVC_NAME}.log 2>&1" \
                > "/etc/cron.d/${TEST_SVC_NAME}"
            log_success "Backup test cron installed ($TEST_SCHED_LABEL)"
        fi

        echo ""
        local _run_now=""
        prompt_yn "  Run the first test now, instead of waiting for the schedule? (y/N):" "n" _run_now
        if [[ "$_run_now" =~ ^[Yy]$ ]]; then
            log_info "Running initial backup restore test..."
            bash "$TEST_SCRIPT" || log_warning "Initial test reported failures — see the output above and /var/log/post-install-backup-test.log."
        fi
    fi

    # ── 12. Systemd timer ────────────────────────────────────────────────────
    log_info "Installing systemd timer ($SCHED_LABEL)..."
    local AUTORUN=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Post-install backup (full Docker service directories via Kopia)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKER run
SVCEOF

        tee "/etc/systemd/system/${SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Schedule post-install backup ($SCHED_LABEL)

[Timer]
OnCalendar=$ONCALENDAR
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
SVCEOF

        systemctl daemon-reload
        systemctl enable --now "${SVC_NAME}.timer"
        log_success "Timer enabled: $SCHED_LABEL"
        AUTORUN="systemctl list-timers ${SVC_NAME}.timer"
    else
        log_warning "systemd not detected — installing cron fallback."
        local CRON
        case "${_sch:-1}" in
            2) CRON="0 2,14 * * *" ;;
            3) CRON="0 2 * * 0"   ;;
            *) CRON="0 2 * * *"   ;;
        esac
        echo "$CRON root /bin/bash $WORKER run >> /var/log/${SVC_NAME}.log 2>&1" \
            > "/etc/cron.d/${SVC_NAME}"
        log_success "Cron job installed: $CRON"
        AUTORUN="cat /etc/cron.d/${SVC_NAME}"
    fi

    # ── Write README ─────────────────────────────────────────────────────────
    # Written before the optional first run below so, if DR sync is enabled,
    # the very first backup already ships an up-to-date README to the spare.
    local DEST_LIST_MD=""
    for dn in "${DEST_NAMES_ARR[@]}"; do
        DEST_LIST_MD+="- **${dn}**: ${DEST_REPOS[$dn]}"$'\n'
    done

    local DR_SYNC_MD OFFSITE_MD
    if [ -n "${DR_SYNC_HOST:-}" ]; then
        DR_SYNC_MD="Configured: after every successful backup, this box copies backup.conf + this README to \`${DR_SYNC_HOST}:${DR_SYNC_PATH:-~/docker/backup}\` over SSH."
    else
        DR_SYNC_MD="Not configured. Re-run this installer to set it up, or copy backup.conf to the spare manually whenever it changes."
    fi
    if [ "${REMOTE_TYPE:-none}" != "none" ]; then
        OFFSITE_MD="Configured: every backup also runs \`kopia repository sync-to ${REMOTE_TYPE}\` to mirror the repo off this box."
    else
        OFFSITE_MD="Not configured. Set REMOTE_TYPE/REMOTE_ARGS in backup.conf (see the comment above them) to mirror the repo off this box."
    fi

    write_readme "$DIR" << MD
# Backup — Kopia

Full recovery for every Docker service under \`$DOCKER_DIR\`: each service's
entire directory (compose file, \`.env\`, config, data, databases) is
snapshotted with Kopia — deduplicated, compressed (zstd), and encrypted.
Databases are captured consistently (container stopped briefly, snapshotted,
restarted); Minecraft instead gets a live save-all flush, no downtime.

## Destinations

$DEST_LIST_MD
## Schedule

$SCHED_LABEL — keeps the latest $KEEP_LATEST snapshots (plus 7 daily / 4
weekly / 3 monthly).

## Commands

\`\`\`bash
sudo $WORKER                     # back up now
sudo $WORKER snapshots           # list all snapshots
sudo $WORKER policy              # show retention policy
\`\`\`

### Restore — interactive, one service at a time

\`\`\`bash
sudo $RESTORE
sudo $RESTORE --list
\`\`\`

### Disaster recovery — unattended, every service, for a cold spare box

\`\`\`bash
sudo $DR_BRINGUP                 # restore + start everything
sudo $DR_BRINGUP --list          # list what's restorable
sudo $DR_BRINGUP --dry-run       # preview, touch nothing
sudo $DR_BRINGUP --service NAME  # just one service
\`\`\`

A single service failing to restore or start does not stop the rest of the
batch — it's logged and skipped so the run maximizes what actually comes
back up. The exit code is only non-zero if nothing came up at all.

**On the spare box**, \`dr_bringup.sh\` needs \`backup.conf\` from this
directory to connect to the repo — see the DR spare sync section below.

## Disaster-recovery spare sync

$DR_SYNC_MD

Requires passwordless SSH (key-based) from this box to the spare — since the
backup timer runs as root, generate/authorize a key for root:
\`ssh-keygen\`, then \`ssh-copy-id\` to the spare.

## Offsite mirror

$OFFSITE_MD

## Backup test — stop / restore / compare / restore-back

\`\`\`bash
sudo $TEST_SCRIPT                # test most recent backup, all services
sudo $TEST_SCRIPT --list         # list testable services
sudo $TEST_SCRIPT --service NAME
\`\`\`

## Files

- \`backup.conf\` — destinations, passwords, retention, DR-sync/offsite settings (chmod 600)
- \`backup_kopia.sh\` — the worker the systemd timer runs
- \`restore_kopia.sh\` — interactive restore
- \`dr_bringup.sh\` — unattended full-stack restore + start
- \`test_backup_kopia.sh\` / \`test_backup.sh\` — automated restore tests

**Save the passwords in \`backup.conf\` somewhere safe** — without them the
encrypted repos cannot be restored.
MD

    # ── 12. Optional first run ────────────────────────────────────────────────
    echo ""
    local _now=""
    prompt_yn "  Run the first backup now? (y/N):" "n" _now
    if [[ "$_now" =~ ^[Yy]$ ]]; then
        /bin/bash "$WORKER" run || log_warning "First backup reported warnings — check output above."
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  BACKUP CONFIGURED"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Config   : $CONF_FILE"
    echo "  Worker   : $WORKER"
    echo "  Schedule : $SCHED_LABEL"
    echo ""
    echo "  Destinations:"
    for dn in "${DEST_NAMES_ARR[@]}"; do
        printf "    %-16s %s\n" "$dn" "${DEST_REPOS[$dn]}"
    done
    echo ""
    if [ "${#ALL_SVCS[@]}" -gt 0 ]; then
        echo "  Services backed up: ${ALL_SVCS[*]}"
    else
        echo "  Services: none yet — auto-discovered on each run"
    fi
    echo ""
    echo "  Commands:"
    echo "    sudo $WORKER                     back up now"
    echo "    sudo $WORKER snapshots           list all snapshots"
    echo ""
    echo "  Restore (interactive, one service at a time):"
    echo "    sudo $RESTORE"
    echo "    sudo $RESTORE --list"
    echo ""
    echo "  Disaster recovery (unattended, every service — for a cold spare box):"
    echo "    sudo $DR_BRINGUP              restore + start everything"
    echo "    sudo $DR_BRINGUP --list       list what's restorable"
    echo "    sudo $DR_BRINGUP --dry-run    preview, touch nothing"
    if [ -n "${DR_SYNC_HOST:-}" ]; then
        echo "    backup.conf + README.md sync to $DR_SYNC_HOST after every backup — the"
        echo "    spare stays ready with no manual copy step."
    else
        echo "    Copy backup.conf to the spare box first — it holds the repo path(s)"
        echo "    and password(s) this needs to connect."
    fi
    echo ""
    echo "  Full docs: $DIR/README.md"
    echo ""
    echo "  Backup test (stop/restore/compare/restore-back):"
    echo "    sudo $TEST_SCRIPT                test most recent backup (all services)"
    echo "    sudo $TEST_SCRIPT --list         list testable services"
    echo "    sudo $TEST_SCRIPT --service <n>  test a specific service"
    [ -n "${NTFY_URL:-}" ] && echo "" && echo "  Notifications: $NTFY_URL"
    echo ""
    [ -n "$AUTORUN" ] && echo "  $AUTORUN" && echo ""
    log_warning "Save your passwords (in backup.conf) somewhere safe —"
    log_warning "without them the encrypted repos cannot be restored."
    echo ""
    log_success "Backup configured."
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_backup
