#!/bin/bash
# services/borg-backup.sh — Full Docker-service backup via Borg.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash borg-backup.sh
# (Docker must already be installed when run standalone)
#
# Backs up each entire ~/docker/<service>/ directory (compose file, config,
# data, databases — everything needed to restore from nothing).
#   Minecraft instances: flush world (save-all), snapshot, no downtime
#   All other services:  stop → snapshot → restart for consistency
#
# Borg advantages over Kopia: mature tooling, Borgmatic YAML config option,
# Vorta GUI, SSH remote repos out of the box, widely packaged.
#
# Creates: ~/docker/borg-backup/
#   backup.conf      settings + per-dest repo/passphrase (chmod 600)
#   backup_borg.sh   worker (run directly or via systemd timer)
#   restore_borg.sh  interactive restore helper

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

register_service borg-backup backup "Encrypted backup of all Docker services via Borg"

install_borg_backup() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/borg-backup"
    local CONF_FILE="$DIR/backup.conf"
    local WORKER="$DIR/backup_borg.sh"
    local RESTORE="$DIR/restore_borg.sh"
    local SVC_NAME="post-install-borg-backup"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Borg Backup Setup                                   ║"
    echo "║   Full ~/docker/<service>/ snapshots                  ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "  Backs up each entire service directory — compose file, config, data,"
    echo "  databases, everything needed to restore a service from scratch."
    echo ""
    echo "  Minecraft: world flushed to disk (save-all), snapshot, NO downtime."
    echo "  Everything else: stopped briefly, snapshotted, restarted."
    echo ""
    echo "  Borg supports local paths AND remote repos over SSH:"
    echo "    local:   /mnt/backup-drive/borg-repo"
    echo "    remote:  user@hostname:/path/to/repo"
    echo "             ssh://user@hostname:2222/path/to/repo"
    echo "  Remote repos require passwordless SSH key access to the remote host."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would discover services under $DOCKER_DIR"
        echo "[DRY-RUN] Would create $DIR with conf, worker, and restore scripts"
        echo "[DRY-RUN] Would init Borg repo(s) at user-specified paths"
        echo "[DRY-RUN] Would install systemd timer"
        return 0
    fi

    # ── 1. Borg ──────────────────────────────────────────────────────────────
    if ! command -v borg >/dev/null 2>&1; then
        log_info "Installing borgbackup..."
        apt-get install -y borgbackup \
            || { log_error "Failed to install borgbackup. Try: sudo apt install borgbackup"; return 1; }
    fi
    local BORG_BIN; BORG_BIN="$(command -v borg)"
    log_success "Borg: $("$BORG_BIN" --version 2>/dev/null)"

    # ── 2. Discover installed services ───────────────────────────────────────
    local -a ALL_SVCS=()
    local d svc
    for d in "$DOCKER_DIR"/*/; do
        [ -f "${d}docker-compose.yml" ] || continue
        svc="$(basename "$d")"
        [[ "$svc" == "borg-backup" || "$svc" == "backup" || "$svc" == "gaming-backup" ]] && continue
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
    echo "  Each destination is a Borg repository (local path or user@host:/path)."
    echo "  For best resilience: use a different drive or remote host from your data."
    echo "  Destination names must be letters, numbers, and underscores only."
    echo ""

    local DEFAULT_DEST="$ACTUAL_HOME/backups/borg-repo"
    local _repo=""
    prompt_text "  Default repository path [${DEFAULT_DEST}]:" "$DEFAULT_DEST" _repo
    _repo="${_repo/#\~/$ACTUAL_HOME}"; _repo="${_repo%/}"

    local -a DEST_NAMES_ARR=("default")
    local -A DEST_REPOS=() DEST_PASSWORDS=()
    DEST_REPOS["default"]="$_repo"

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
    echo ""
    log_info "Setting repository passphrases (stored in backup.conf, chmod 600)..."
    for dn in "${DEST_NAMES_ARR[@]}"; do
        local pw=""
        if [ "$UNATTENDED" = true ]; then
            pw="$(generate_password 32)"
        else
            read -rsp "  Passphrase for '$dn' [Enter = auto-generate]: " pw; echo
        fi
        [ -z "$pw" ] && pw="$(generate_password 32)" && log_info "  Auto-generated passphrase for '$dn'."
        DEST_PASSWORDS["$dn"]="$pw"
    done

    # ── 6. Schedule & retention ──────────────────────────────────────────────
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

    echo ""
    echo "  Retention policy — Borg prunes per-service archives independently."
    echo ""
    local KEEP_DAILY="" KEEP_WEEKLY="" KEEP_MONTHLY=""
    prompt_text "  Keep last N daily archives per service   [7]:" "7" KEEP_DAILY
    prompt_text "  Keep last N weekly archives per service  [4]:" "4" KEEP_WEEKLY
    prompt_text "  Keep last N monthly archives per service [3]:" "3" KEEP_MONTHLY
    KEEP_DAILY="${KEEP_DAILY:-7}"
    KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
    KEEP_MONTHLY="${KEEP_MONTHLY:-3}"

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

    # ── 7. Create dirs + init Borg repos ─────────────────────────────────────
    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"

    local repo pw
    for dn in "${DEST_NAMES_ARR[@]}"; do
        repo="${DEST_REPOS[$dn]}"
        pw="${DEST_PASSWORDS[$dn]}"

        # Skip init for remote repos — user must set them up manually with SSH access.
        if [[ "$repo" == *@*:* ]] || [[ "$repo" == ssh://* ]]; then
            log_info "Remote repo '$dn' ($repo) — checking connectivity..."
            if BORG_PASSPHRASE="$pw" "$BORG_BIN" info "$repo" >/dev/null 2>&1; then
                log_success "Remote repo '$dn' connected."
            elif BORG_PASSPHRASE="$pw" "$BORG_BIN" init --encryption=repokey-blake2 "$repo" 2>/dev/null; then
                log_success "Remote repo '$dn' initialised at $repo"
            else
                log_warning "Could not init remote repo '$dn' at $repo."
                log_warning "Ensure SSH key access to the remote host is configured, then:"
                log_warning "  BORG_PASSPHRASE='${pw}' borg init --encryption=repokey-blake2 ${repo}"
            fi
        else
            mkdir -p "$repo"
            if BORG_PASSPHRASE="$pw" "$BORG_BIN" info "$repo" >/dev/null 2>&1; then
                log_success "Repo '$dn' already exists at $repo."
            else
                log_info "Initialising repo '$dn' at $repo ..."
                BORG_PASSPHRASE="$pw" "$BORG_BIN" init --encryption=repokey-blake2 "$repo" \
                    || { log_error "Failed to init repo '$dn'."; return 1; }
                log_success "Repo '$dn' initialised at $repo"
            fi
        fi
    done

    # ── 8. Write backup.conf ─────────────────────────────────────────────────
    log_info "Writing $CONF_FILE ..."
    {
        echo "# ── backup.conf ────────────────────────────────────────────────────────────"
        echo "# Generated $(date '+%F %T'). Safe to hand-edit."
        echo "# Worker : sudo $WORKER"
        echo "# Restore: sudo $RESTORE"
        echo ""
        echo "BORG=\"$BORG_BIN\""
        echo ""
        echo "# Space-separated list of destination names."
        echo "DEST_NAMES=\"${DEST_NAMES_ARR[*]}\""
        echo "DEST_DEFAULT=\"default\""
        echo ""
        echo "# Retention (applied per-service archive prefix)."
        echo "KEEP_DAILY=$KEEP_DAILY"
        echo "KEEP_WEEKLY=$KEEP_WEEKLY"
        echo "KEEP_MONTHLY=$KEEP_MONTHLY"
        echo ""
        for dn in "${DEST_NAMES_ARR[@]}"; do
            echo "# ── destination: $dn"
            echo "DEST_${dn}_REPO=\"${DEST_REPOS[$dn]}\""
            printf "DEST_%s_PASSPHRASE='%s'\n" "$dn" "${DEST_PASSWORDS[$dn]}"
            echo ""
        done
        echo "# ── Service → destination map ───────────────────────────────────────────────"
        echo "# Format: SVC_<name>=<dest_name>  (hyphens become underscores)"
        echo "# Omit or comment out to use DEST_DEFAULT."
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
        echo "# ── Notifications (ntfy) ─────────────────────────────────────────────────────"
        echo "# Set NTFY_URL to receive backup success/failure alerts."
        echo "# Leave blank to disable. NTFY_TOKEN is optional (for private topics)."
        printf "NTFY_URL='%s'\n" "${NTFY_URL:-}"
        printf "NTFY_TOKEN='%s'\n" "${NTFY_TOKEN:-}"
    } > "$CONF_FILE"
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE"
    log_success "backup.conf written (chmod 600)"

    # ── 9. Install worker script ──────────────────────────────────────────────
    log_info "Installing worker $WORKER ..."
    cp "${HERE:-}/extras/backup_borg.sh" "$WORKER"
    chmod +x "$WORKER"
    chown root:root "$WORKER" 2>/dev/null || true
    log_success "backup_borg.sh installed"

    # ── 10. Install restore script ────────────────────────────────────────────
    local RESTORE_SRC="${HERE:-}/extras/restore_borg.sh"
    if [ -f "$RESTORE_SRC" ]; then
        cp "$RESTORE_SRC" "$RESTORE"
        chmod +x "$RESTORE"
        chown root:root "$RESTORE" 2>/dev/null || true
        log_success "restore_borg.sh installed"
    else
        log_warning "extras/restore_borg.sh not found — restore script not installed"
        log_warning "Copy it manually: cp extras/restore_borg.sh $RESTORE"
    fi

    # ── 11. Install test scripts ─────────────────────────────────────────────
    local TEST_SCRIPT="$DIR/test_backup_borg.sh"
    local TEST_SRC="${HERE:-}/extras/test_backup_borg.sh"
    if [ -f "$TEST_SRC" ]; then
        cp "$TEST_SRC" "$TEST_SCRIPT"
        chmod +x "$TEST_SCRIPT"
        chown root:root "$TEST_SCRIPT" 2>/dev/null || true
        log_success "test_backup_borg.sh installed"
    else
        log_warning "extras/test_backup_borg.sh not found — test script not installed"
    fi

    local TEST_UNIFIED="$DIR/test_backup.sh"
    local TEST_UNIFIED_SRC="${HERE:-}/extras/test_backup.sh"
    if [ -f "$TEST_UNIFIED_SRC" ]; then
        cp "$TEST_UNIFIED_SRC" "$TEST_UNIFIED"
        chmod +x "$TEST_UNIFIED"
        chown root:root "$TEST_UNIFIED" 2>/dev/null || true
        log_success "test_backup.sh installed"
    fi

    # ── 11b. Weekly backup test timer ────────────────────────────────────────
    local TEST_SVC_NAME="post-install-borg-backup-test"
    local _add_test=""
    prompt_yn "  Schedule a weekly automated backup test? (y/N):" "n" _add_test
    if [[ "$_add_test" =~ ^[Yy]$ ]]; then
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            tee "/etc/systemd/system/${TEST_SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Weekly restore test for Borg backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $TEST_SCRIPT
SVCEOF

            tee "/etc/systemd/system/${TEST_SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Weekly Borg backup restore test (Saturday 03:00)

[Timer]
OnCalendar=Sat *-*-* 03:00:00
Persistent=true
RandomizedDelaySec=600

[Install]
WantedBy=timers.target
SVCEOF

            systemctl daemon-reload
            systemctl enable --now "${TEST_SVC_NAME}.timer"
            log_success "Weekly test timer enabled (Saturday 03:00)"
        else
            echo "0 3 * * 6 root /bin/bash $TEST_SCRIPT >> /var/log/${TEST_SVC_NAME}.log 2>&1" \
                > "/etc/cron.d/${TEST_SVC_NAME}"
            log_success "Weekly test cron installed (Saturday 03:00)"
        fi
    fi

    # ── 12. Systemd timer ─────────────────────────────────────────────────────
    log_info "Installing systemd timer ($SCHED_LABEL)..."
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Post-install Borg backup (full Docker service directories)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKER run
SVCEOF

        tee "/etc/systemd/system/${SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Schedule post-install Borg backup ($SCHED_LABEL)

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
    fi

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
    echo "  BORG BACKUP CONFIGURED"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Config   : $CONF_FILE"
    echo "  Worker   : $WORKER"
    echo "  Schedule : $SCHED_LABEL"
    echo "  Retention: ${KEEP_DAILY}d daily / ${KEEP_WEEKLY}w weekly / ${KEEP_MONTHLY}m monthly (per service)"
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
    echo "    sudo $WORKER                      back up now"
    echo "    sudo $WORKER list                 list all archives"
    echo "    sudo $WORKER info                 repo stats"
    echo ""
    echo "  Restore:"
    echo "    sudo $RESTORE"
    echo "    sudo $RESTORE --list"
    echo ""
    echo "  Backup test (stop/restore/compare/restore-back):"
    echo "    sudo $TEST_SCRIPT                test most recent backup (all services)"
    echo "    sudo $TEST_SCRIPT --list         list testable services"
    echo "    sudo $TEST_SCRIPT --service <n>  test a specific service"
    [ -n "${NTFY_URL:-}" ] && echo "" && echo "  Notifications: $NTFY_URL"
    echo ""
    log_warning "IMPORTANT — back up your Borg key and passphrase now."
    echo "  The key is stored in the repo itself (repokey-blake2 encryption)."
    echo "  Export it to a safe location:"
    for dn in "${DEST_NAMES_ARR[@]}"; do
        local _rp="${DEST_REPOS[$dn]}"
        local _pw="${DEST_PASSWORDS[$dn]}"
        echo "    BORG_PASSPHRASE='${_pw}' borg key export ${_rp} ~/borg-key-${dn}.txt"
    done
    echo "  Store the exported key file and passphrase somewhere that is NOT"
    echo "  on this machine (e.g. USB drive, password manager, offsite)."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_borg_backup
