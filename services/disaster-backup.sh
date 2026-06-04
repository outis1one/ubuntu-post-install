#!/bin/bash
# services/disaster-backup.sh — Complete disaster-recovery backup via Kopia.
# Part of the modular post-install system (sourced by setup.sh).
#
# Backs up each entire ~/docker/<service>/ directory (compose file, config, data,
# databases — everything needed to restore from nothing). Per-service behaviour:
#   Minecraft instances — flush world to disk (save-all), snapshot, no downtime
#   All other services  — stop, snapshot, restart (seconds of downtime each)
#
# Different services can be routed to different Kopia repos / drives.
# New services are auto-discovered on every run — no reconfiguration needed.
#
# Creates: ~/docker/disaster-backup/
#   disaster-backup.conf   settings + per-service destination map
#   disaster-backup.sh     worker (run directly or via systemd timer)
#   restore/<dest>/        restore_kopia_backup.sh + backup.conf per destination

register_service disaster-backup backup "Disaster-recovery backup (full ~/docker service dirs, stop/start)"

install_disaster_backup() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/disaster-backup"
    local CONF_FILE="$DIR/disaster-backup.conf"
    local WORKER="$DIR/disaster-backup.sh"
    local RESTORE_DIR="$DIR/restore"
    local RESTORE_SRC="${HERE:-}/extras/restore_kopia_backup.sh"
    local SVC_NAME="post-install-disaster-backup"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Disaster-Recovery Backup Setup                      ║"
    echo "║   Full ~/docker/<service>/ snapshots via Kopia        ║"
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
        [[ "$svc" == "backup" || "$svc" == "disaster-backup" ]] && continue
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

    local DEFAULT_DEST="$ACTUAL_HOME/backups/disaster-kopia"
    local _repo=""
    prompt_text "  Default repository path [${DEFAULT_DEST}]:" "$DEFAULT_DEST" _repo
    _repo="${_repo/#\~/$ACTUAL_HOME}"; _repo="${_repo%/}"

    local -a DEST_NAMES_ARR=("default")
    local -A DEST_REPOS=() DEST_PASSWORDS=() DEST_CONFIGS=()
    DEST_REPOS["default"]="$_repo"
    DEST_CONFIGS["default"]="/etc/disaster-backup/default.config"

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
            DEST_CONFIGS["$_dn"]="/etc/disaster-backup/${_dn}.config"
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
    log_info "Setting repository passwords (stored in disaster-backup.conf, chmod 600)..."
    for dn in "${DEST_NAMES_ARR[@]}"; do
        local pw=""
        if [ "$UNATTENDED" = true ]; then
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

    # ── 7. Create dirs + init Kopia repos ────────────────────────────────────
    mkdir -p "$DIR" "$RESTORE_DIR"
    ensure_docker_dir_ownership "$DIR"

    local repo pw cfg
    for dn in "${DEST_NAMES_ARR[@]}"; do
        repo="${DEST_REPOS[$dn]}"
        pw="${DEST_PASSWORDS[$dn]}"
        cfg="${DEST_CONFIGS[$dn]}"
        mkdir -p "$repo" "$(dirname "$cfg")" /var/cache/disaster-backup

        kp_d() { env KOPIA_PASSWORD="$pw" "$KOPIA_BIN" --config-file="$cfg" "$@"; }

        if kp_d repository status >/dev/null 2>&1; then
            log_success "Connected to existing repo '$dn'."
        elif test -e "$repo/kopia.repository.f"; then
            log_info "Connecting to existing repo '$dn' at $repo ..."
            kp_d repository connect filesystem --path="$repo" \
                --cache-directory=/var/cache/disaster-backup \
                || { log_error "Failed to connect to '$dn' repo."; return 1; }
        else
            log_info "Creating repo '$dn' at $repo ..."
            kp_d repository create filesystem --path="$repo" \
                --cache-directory=/var/cache/disaster-backup \
                || { log_error "Failed to create '$dn' repo."; return 1; }
        fi

        kp_d policy set --global --compression=zstd \
            --keep-latest="$KEEP_LATEST" \
            --keep-daily=7 --keep-weekly=4 --keep-monthly=3 \
            --keep-annual=0 --keep-hourly=0 >/dev/null
        log_success "Repo '$dn' ready at $repo"
    done
    unset -f kp_d

    # ── 8. Write disaster-backup.conf ────────────────────────────────────────
    log_info "Writing $CONF_FILE ..."
    {
        echo "# ── disaster-backup.conf ───────────────────────────────────────────────────"
        echo "# Generated $(date '+%F %T'). Safe to hand-edit."
        echo "# Worker : sudo $WORKER"
        echo "# Restore: sudo $RESTORE_DIR/<dest>/restore_kopia_backup.sh"
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
        echo "# Example SFTP: REMOTE_TYPE=sftp  REMOTE_ARGS=\"--host H --username U --path /srv/...\""
        echo "REMOTE_TYPE=\"none\""
        echo "REMOTE_ARGS=\"\""
    } > "$CONF_FILE"
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE"
    log_success "disaster-backup.conf written (chmod 600)"

    # ── 9. Generate worker script ─────────────────────────────────────────────
    log_info "Writing worker $WORKER ..."
    cat > "$WORKER" << 'WORKEREOF'
#!/bin/bash
# Generated by the disaster-backup installer.
# Backs up full ~/docker/<service>/ directories via Kopia.
#   Minecraft instances: flush to disk (save-all) then snapshot — no downtime.
#   All other services:  stop → snapshot → restart for consistency.
#
#   sudo ./disaster-backup.sh             run a full backup cycle
#   sudo ./disaster-backup.sh snapshots   list all snapshots (all repos)
#   sudo ./disaster-backup.sh policy      show retention policies
#
# Reads disaster-backup.conf from the same directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${DISASTER_BACKUP_CONF:-$HERE/disaster-backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run the disaster-backup service)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="$ACTUAL_HOME/docker"

log() { echo "[$(date '+%F %T')] $*"; }

kp_for() {
    local dest="$1"; shift
    local cfg_var="DEST_${dest}_CONFIG" pw_var="DEST_${dest}_PASSWORD"
    local cfg="${!cfg_var:-}" pw="${!pw_var:-}"
    [ -n "$cfg" ] || { log "Unknown destination: $dest"; return 1; }
    env KOPIA_PASSWORD="$pw" "$KOPIA" --config-file="$cfg" "$@"
}

dest_for_svc() {
    local var="SVC_${1//-/_}"
    echo "${!var:-${DEST_DEFAULT:-default}}"
}

# Detect itzg Minecraft instances by their Dockerfile signature.
is_minecraft() { [ -f "${1}Dockerfile" ] && grep -qs itzg "${1}Dockerfile"; }

case "${1:-run}" in
    snapshots)
        for dest in ${DEST_NAMES:-default}; do
            echo ""; echo "── dest: $dest ──"
            kp_for "$dest" snapshot list 2>/dev/null || true
        done
        exit 0 ;;
    policy)
        for dest in ${DEST_NAMES:-default}; do
            echo ""; echo "── dest: $dest ──"
            kp_for "$dest" policy show --global 2>/dev/null || true
        done
        exit 0 ;;
esac

log "===== Disaster backup starting ====="
rc=0

for svc_dir in "$DOCKER_DIR"/*/; do
    [ -f "${svc_dir}docker-compose.yml" ] || continue
    svc="$(basename "$svc_dir")"
    [[ "$svc" == "backup" || "$svc" == "disaster-backup" ]] && continue

    dest="$(dest_for_svc "$svc")"
    _repo_var="DEST_${dest}_REPO"
    [ -n "${!_repo_var:-}" ] || { log "SKIP $svc — dest '$dest' not configured in conf"; continue; }

    if is_minecraft "$svc_dir"; then
        # ── Minecraft: flush world to disk, snapshot without stopping ────────
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Flushing Minecraft world '$svc' (save-all, no downtime)..."
            docker exec "$svc" mc-send-to-console save-all flush 2>/dev/null \
                || docker exec "$svc" rcon-cli save-all 2>/dev/null || true
            sleep 5
        fi
        log "Snapshotting $svc (dest: $dest)..."
        if kp_for "$dest" snapshot create --description="disaster: $svc" "$svc_dir"; then
            log "OK $svc (Minecraft, no downtime)"
        else
            log "WARNING: snapshot failed for $svc"; rc=1
        fi
    else
        # ── All other services: stop → snapshot → restart ─────────────────
        STOPPED=false
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Stopping $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" down 2>/dev/null \
                || docker stop "$svc" 2>/dev/null \
                || log "WARNING: could not stop $svc — snapshotting live (consistency not guaranteed)"
            STOPPED=true
        fi

        log "Snapshotting $svc (dest: $dest)..."
        if kp_for "$dest" snapshot create --description="disaster: $svc" "$svc_dir"; then
            log "OK $svc"
        else
            log "WARNING: snapshot failed for $svc"; rc=1
        fi

        if [ "$STOPPED" = true ]; then
            log "Starting $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" up -d 2>/dev/null \
                || log "WARNING: could not restart $svc — run: docker compose -f ${svc_dir}docker-compose.yml up -d"
        fi
    fi
done

if [ "${REMOTE_TYPE:-none}" != "none" ] && [ -n "${REMOTE_TYPE:-}" ]; then
    for dest in ${DEST_NAMES:-default}; do
        log "Mirroring '$dest' offsite ($REMOTE_TYPE)..."
        # shellcheck disable=SC2086
        kp_for "$dest" repository sync-to "$REMOTE_TYPE" $REMOTE_ARGS \
            || { log "WARNING: mirror failed for '$dest'"; rc=1; }
    done
fi

if [ "$rc" -eq 0 ]; then
    log "===== Disaster backup complete ====="
else
    log "===== Disaster backup finished WITH WARNINGS (see above) ====="
fi
exit "$rc"
WORKEREOF
    chmod +x "$WORKER"
    chown root:root "$WORKER" 2>/dev/null || true
    log_success "disaster-backup.sh written"

    # ── 10. Restore scripts (one per destination) ────────────────────────────
    if [ -f "$RESTORE_SRC" ]; then
        for dn in "${DEST_NAMES_ARR[@]}"; do
            local dest_rdir="$RESTORE_DIR/$dn"
            mkdir -p "$dest_rdir"
            cp "$RESTORE_SRC" "$dest_rdir/restore_kopia_backup.sh"
            chmod +x "$dest_rdir/restore_kopia_backup.sh"
            {
                echo "# backup.conf for disaster-backup destination '$dn'"
                echo "# Read by restore_kopia_backup.sh in this directory."
                echo "KOPIA=\"$KOPIA_BIN\""
                echo "KOPIA_CONFIG=\"${DEST_CONFIGS[$dn]}\""
                printf "KOPIA_PASSWORD='%s'\n" "${DEST_PASSWORDS[$dn]}"
            } > "$dest_rdir/backup.conf"
            chown root:root "$dest_rdir/backup.conf" 2>/dev/null || true
            chmod 600 "$dest_rdir/backup.conf"
            log_success "restore/$dn/ ready"
        done
    else
        log_warning "extras/restore_kopia_backup.sh not found — restore scripts not installed"
        log_warning "Copy it manually: cp extras/restore_kopia_backup.sh $RESTORE_DIR/<dest>/"
    fi

    # ── 11. Systemd timer ────────────────────────────────────────────────────
    log_info "Installing systemd timer ($SCHED_LABEL)..."
    local AUTORUN=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Post-install disaster-recovery backup (full Docker service directories)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKER run
SVCEOF

        tee "/etc/systemd/system/${SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Schedule disaster-recovery backup ($SCHED_LABEL)

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

    # ── 12. Optional first run ────────────────────────────────────────────────
    echo ""
    local _now=""
    prompt_yn "  Run the first disaster backup now? (y/N):" "n" _now
    if [[ "$_now" =~ ^[Yy]$ ]]; then
        /bin/bash "$WORKER" run || log_warning "First disaster backup reported warnings — check output above."
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  DISASTER BACKUP CONFIGURED"
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
    echo "  Restore (per destination):"
    for dn in "${DEST_NAMES_ARR[@]}"; do
        echo "    sudo $RESTORE_DIR/$dn/restore_kopia_backup.sh"
        echo "    sudo $RESTORE_DIR/$dn/restore_kopia_backup.sh --list"
    done
    echo ""
    [ -n "$AUTORUN" ] && echo "  $AUTORUN" && echo ""
    log_warning "Save your passwords (in disaster-backup.conf) somewhere safe —"
    log_warning "without them encrypted repos cannot be restored."
    echo ""
    log_success "Disaster-recovery backup configured."
}
