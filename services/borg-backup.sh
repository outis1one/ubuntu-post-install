#!/bin/bash
# services/borg-backup.sh — Full Docker-service backup via Borg.
# Part of the modular post-install system (sourced by setup.sh).
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
#   backup.conf       settings + per-dest repo/passphrase (chmod 600)
#   borg-backup.sh    worker (run directly or via systemd timer)
#   restore/<dest>/   restore_borg_backup.sh + backup.conf per destination

register_service borg-backup backup "Encrypted backup of all Docker services via Borg"

install_borg_backup() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/borg-backup"
    local CONF_FILE="$DIR/backup.conf"
    local WORKER="$DIR/borg-backup.sh"
    local RESTORE_DIR="$DIR/restore"
    local RESTORE_SRC="${HERE:-}/extras/restore_borg_backup.sh"
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

    # ── 7. Create dirs + init Borg repos ─────────────────────────────────────
    mkdir -p "$DIR" "$RESTORE_DIR"
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
        echo "# Restore: sudo $RESTORE_DIR/<dest>/restore_borg_backup.sh"
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
    } > "$CONF_FILE"
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE"
    log_success "backup.conf written (chmod 600)"

    # ── 9. Generate worker script ─────────────────────────────────────────────
    log_info "Writing worker $WORKER ..."
    cat > "$WORKER" << 'WORKEREOF'
#!/bin/bash
# Generated by the borg-backup installer.
# Backs up full ~/docker/<service>/ directories via Borg.
#   Minecraft instances: flush to disk (save-all) then archive — no downtime.
#   All other services:  stop → archive → restart for consistency.
#
#   sudo ./borg-backup.sh           run a full backup cycle
#   sudo ./borg-backup.sh list      list all archives in all repos
#   sudo ./borg-backup.sh info      show repo info for all destinations
#
# Reads backup.conf from the same directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run the borg-backup service)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="$ACTUAL_HOME/docker"

log() { echo "[$(date '+%F %T')] $*"; }

repo_for()   {
    local var="DEST_${1}_REPO"; echo "${!var:-}"
}
pass_for()   {
    local var="DEST_${1}_PASSPHRASE"; echo "${!var:-}"
}
dest_for_svc() {
    local var="SVC_${1//-/_}"; echo "${!var:-${DEST_DEFAULT:-default}}"
}

b_for() {
    local dest="$1"; shift
    local repo; repo="$(repo_for "$dest")"
    local pass; pass="$(pass_for "$dest")"
    [ -n "$repo" ] || { log "Unknown destination: $dest"; return 1; }
    BORG_PASSPHRASE="$pass" BORG_REPO="$repo" "$BORG" "$@"
}

is_minecraft() { [ -f "${1}Dockerfile" ] && grep -qs itzg "${1}Dockerfile"; }

case "${1:-run}" in
    list)
        for dest in ${DEST_NAMES:-default}; do
            echo ""; echo "── dest: $dest ($(repo_for "$dest")) ──"
            b_for "$dest" list 2>/dev/null | sort -r | head -30 || true
        done
        exit 0 ;;
    info)
        for dest in ${DEST_NAMES:-default}; do
            echo ""; echo "── dest: $dest ──"
            b_for "$dest" info 2>/dev/null || true
        done
        exit 0 ;;
esac

log "===== Borg backup starting ====="
rc=0
TS="$(date +%Y-%m-%dT%H-%M-%S)"

for svc_dir in "$DOCKER_DIR"/*/; do
    [ -f "${svc_dir}docker-compose.yml" ] || continue
    svc="$(basename "$svc_dir")"
    [[ "$svc" == "borg-backup" || "$svc" == "backup" || "$svc" == "gaming-backup" ]] && continue

    dest="$(dest_for_svc "$svc")"
    repo="$(repo_for "$dest")"
    [ -n "$repo" ] || { log "SKIP $svc — dest '$dest' not configured"; continue; }

    ARCHIVE="${svc}-${TS}"

    if is_minecraft "$svc_dir"; then
        # ── Minecraft: flush world to disk, archive without stopping ─────────
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Flushing Minecraft world '$svc' (save-all, no downtime)..."
            docker exec "$svc" mc-send-to-console save-all flush 2>/dev/null \
                || docker exec "$svc" rcon-cli save-all 2>/dev/null || true
            sleep 5
        fi
        log "Archiving $svc → $dest::$ARCHIVE ..."
        if b_for "$dest" create \
            --compression=zstd,6 \
            --exclude-caches \
            --stats \
            "::$ARCHIVE" "$svc_dir" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc (Minecraft, no downtime)"
        else
            log "WARNING: archive failed for $svc"; rc=1
        fi
    else
        # ── All other services: stop → archive → restart ──────────────────
        STOPPED=false
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Stopping $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" down 2>/dev/null \
                || docker stop "$svc" 2>/dev/null \
                || log "WARNING: could not stop $svc — archiving live (consistency not guaranteed)"
            STOPPED=true
        fi

        log "Archiving $svc → $dest::$ARCHIVE ..."
        if b_for "$dest" create \
            --compression=zstd,6 \
            --exclude-caches \
            --stats \
            "::$ARCHIVE" "$svc_dir" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc"
        else
            log "WARNING: archive failed for $svc"; rc=1
        fi

        if [ "$STOPPED" = true ]; then
            log "Starting $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" up -d 2>/dev/null \
                || log "WARNING: could not restart $svc — run: docker compose -f ${svc_dir}docker-compose.yml up -d"
        fi
    fi

    # Prune old archives for this service in its destination repo
    log "Pruning old archives for $svc in '$dest'..."
    b_for "$dest" prune \
        --keep-daily="${KEEP_DAILY:-7}" \
        --keep-weekly="${KEEP_WEEKLY:-4}" \
        --keep-monthly="${KEEP_MONTHLY:-3}" \
        --glob-archives="${svc}-*" \
        --list 2>/dev/null \
        || log "WARNING: prune failed for $svc (non-fatal)"
done

# Compact each repo to reclaim space freed by pruning
for dest in ${DEST_NAMES:-default}; do
    repo="$(repo_for "$dest")"
    [ -n "$repo" ] || continue
    log "Compacting repo '$dest'..."
    b_for "$dest" compact 2>/dev/null || true
done

if [ "$rc" -eq 0 ]; then
    log "===== Borg backup complete ====="
else
    log "===== Borg backup finished WITH WARNINGS (see above) ====="
fi
exit "$rc"
WORKEREOF
    chmod +x "$WORKER"
    chown root:root "$WORKER" 2>/dev/null || true
    log_success "borg-backup.sh written"

    # ── 10. Restore scripts (one per destination) ─────────────────────────────
    if [ -f "$RESTORE_SRC" ]; then
        for dn in "${DEST_NAMES_ARR[@]}"; do
            local dest_rdir="$RESTORE_DIR/$dn"
            mkdir -p "$dest_rdir"
            cp "$RESTORE_SRC" "$dest_rdir/restore_borg_backup.sh"
            chmod +x "$dest_rdir/restore_borg_backup.sh"
            {
                echo "# backup.conf for borg-backup destination '$dn'"
                echo "# Read by restore_borg_backup.sh in this directory."
                echo "BORG=\"$BORG_BIN\""
                echo "BORG_REPO=\"${DEST_REPOS[$dn]}\""
                printf "BORG_PASSPHRASE='%s'\n" "${DEST_PASSWORDS[$dn]}"
            } > "$dest_rdir/backup.conf"
            chown root:root "$dest_rdir/backup.conf" 2>/dev/null || true
            chmod 600 "$dest_rdir/backup.conf"
            log_success "restore/$dn/ ready"
        done
    else
        log_warning "extras/restore_borg_backup.sh not found — restore scripts not installed"
        log_warning "Copy it manually: cp extras/restore_borg_backup.sh $RESTORE_DIR/<dest>/"
    fi

    # ── 11. Systemd timer ─────────────────────────────────────────────────────
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
    for dn in "${DEST_NAMES_ARR[@]}"; do
        echo "    sudo $RESTORE_DIR/$dn/restore_borg_backup.sh"
        echo "    sudo $RESTORE_DIR/$dn/restore_borg_backup.sh --list"
    done
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
