#!/bin/bash
# services/backup.sh — Full Docker-service backup via Kopia.
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
# Creates: ~/docker/backup/
#   backup.conf       settings + per-service destination map (chmod 600)
#   backup_kopia.sh   worker (run directly or via systemd timer)
#   restore_kopia.sh  interactive restore helper

register_service backup backup "Encrypted backup of all Docker services (full restore)"

install_backup() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/backup"
    local CONF_FILE="$DIR/backup.conf"
    local WORKER="$DIR/backup_kopia.sh"
    local RESTORE="$DIR/restore_kopia.sh"
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
    echo ""
    log_info "Setting repository passwords (stored in backup.conf, chmod 600)..."
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
        echo "# Example SFTP: REMOTE_TYPE=sftp  REMOTE_ARGS=\"--host H --username U --path /srv/...\""
        echo "REMOTE_TYPE=\"none\""
        echo "REMOTE_ARGS=\"\""
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

    # ── 11b. Weekly backup test timer ────────────────────────────────────────
    local TEST_SVC_NAME="post-install-backup-test"
    local _add_test=""
    prompt_yn "  Schedule a weekly automated backup test? (y/N):" "n" _add_test
    if [[ "$_add_test" =~ ^[Yy]$ ]]; then
        if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
            tee "/etc/systemd/system/${TEST_SVC_NAME}.service" >/dev/null << SVCEOF
[Unit]
Description=Weekly restore test for Kopia backup
After=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $TEST_SCRIPT
SVCEOF

            tee "/etc/systemd/system/${TEST_SVC_NAME}.timer" >/dev/null << SVCEOF
[Unit]
Description=Weekly Kopia backup restore test (Saturday 03:00)

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
    [ -n "$AUTORUN" ] && echo "  $AUTORUN" && echo ""
    log_warning "Save your passwords (in backup.conf) somewhere safe —"
    log_warning "without them the encrypted repos cannot be restored."
    echo ""
    log_success "Backup configured."
}
