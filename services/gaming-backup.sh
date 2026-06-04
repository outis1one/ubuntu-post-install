#!/bin/bash
# services/gaming-backup.sh — Frequent gaming-saves backup (no service downtime).
# Part of the modular post-install system (sourced by setup.sh).
#
# Backs up the things you can't re-download — progress, saved games, user data:
#   • Minecraft worlds / player data  (every <id>/data instance under $DOCKER_DIR)
#   • Emulator saves & save states    ($GAME_STORAGE_DIR/saves)      [gaming box]
#   • ES-DE scraped artwork           ($GAME_STORAGE_DIR/media)      [gaming box]
#   • Steam user data & game saves    ($GAME_STORAGE_DIR/steam)      [gaming box]
#   • Wolf state                      (/etc/wolf — config + profile_data) [gaming box]
#
# Unlike the 'backup' service, nothing is stopped — Minecraft worlds are flushed
# to disk (save-all) and snapshotted live. Run this hourly or every few hours for
# frequent save protection; use 'backup' nightly for full service recovery.
#
# It does NOT back up ROMs or Steam game installs — those are re-downloadable.
#
# Safe to re-run: it reconnects to an existing repository and refreshes the
# config, policies, worker script and timer.

register_service gaming-backup backup "Gaming saves backup (Minecraft worlds, emulator saves, Steam)"

install_gaming_backup() {
    log_info "Setting up gaming saves backup (Kopia)..."

    # ── Repo-conventional paths ──────────────────────────────────────────────
    local BACKUP_DIR="$DOCKER_DIR/gaming-backup"
    local CONF_FILE="$BACKUP_DIR/backup.conf"        # editable settings
    local WORKER="$BACKUP_DIR/gaming-backup.sh"      # generated worker
    local KOPIA_CONFIG="/etc/gaming-backup/repository.config"
    local CACHE_DIR="/var/cache/gaming-backup"
    local SVC_NAME="post-install-gaming-backup"
    local DEFAULT_REPO="$ACTUAL_HOME/backups/gaming-kopia"

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Gaming Backup Setup  ·  Kopia                       ║"
    echo "║   Minecraft worlds · game saves · user data           ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    echo "  Backs up progress / saves / user data — NOT ROMs or game installs."
    echo "  Nothing is stopped: Minecraft worlds are flushed to disk then snapshotted."
    echo "  Run frequently (hourly or every few hours) without disrupting gameplay."
    echo "  Use the 'backup' service for full service recovery (nightly)."
    echo ""

    # ── DRY-RUN ──────────────────────────────────────────────────────────────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install Kopia from the official apt repository"
        echo "[DRY-RUN] Would create $BACKUP_DIR (owned by $ACTUAL_USER)"
        echo "[DRY-RUN] Would create/connect a Kopia repository at $DEFAULT_REPO"
        echo "[DRY-RUN] Would write config $CONF_FILE and worker $WORKER"
        echo "[DRY-RUN] Would install systemd service+timer $SVC_NAME (cron fallback)"
        echo "[DRY-RUN] Would optionally run the first backup"
        return 0
    fi

    # ── 1. Ensure Kopia is installed ─────────────────────────────────────────
    if ! command -v kopia >/dev/null 2>&1; then
        log_info "Kopia not found — installing from the official apt repository..."
        if command -v apt-get >/dev/null 2>&1; then
            install -d -m 0755 /etc/apt/keyrings
            if curl -fsSL https://kopia.io/signing-key \
                | gpg --dearmor --yes -o /etc/apt/keyrings/kopia-keyring.gpg; then
                echo "deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main" \
                    > /etc/apt/sources.list.d/kopia.list
                apt-get update -y && apt-get install -y kopia
            fi
        fi
    fi
    if ! command -v kopia >/dev/null 2>&1; then
        log_error "Kopia is still not installed."
        echo "  Install it manually, then re-run this service:"
        echo "    https://kopia.io/docs/installation/"
        return 1
    fi
    local KOPIA_BIN; KOPIA_BIN="$(command -v kopia)"
    log_success "Kopia: $("$KOPIA_BIN" --version 2>/dev/null | head -1)"

    mkdir -p "$BACKUP_DIR" || return 1
    ensure_docker_dir_ownership "$BACKUP_DIR"

    # ── 2. What to back up ───────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  WHAT TO BACK UP"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    local DEFAULT_MCBASE="$DOCKER_DIR"
    echo "  Each Minecraft instance's world is backed up from its <id>/data folder;"
    echo "  all instances under this folder are detected automatically."
    echo "  (type 'none' to exclude Minecraft)"
    local MC_BASE_DIR=""
    prompt_text "  Folder containing Minecraft instance(s) [${DEFAULT_MCBASE}]:" "$DEFAULT_MCBASE" MC_BASE_DIR
    if [ "$MC_BASE_DIR" = none ]; then
        MC_BASE_DIR=""
    else
        MC_BASE_DIR="${MC_BASE_DIR/#\~/$ACTUAL_HOME}"; MC_BASE_DIR="${MC_BASE_DIR%/}"
        local _found=() d
        for d in "$MC_BASE_DIR"/*/; do
            [ -f "${d}Dockerfile" ] && grep -qs itzg "${d}Dockerfile" && [ -d "${d}data" ] \
                && _found+=("$(basename "$d")")
        done
        if [ "${#_found[@]}" -gt 0 ]; then
            log_success "  Detected Minecraft instance(s): ${_found[*]}"
        else
            log_warning "  No instances detected yet under $MC_BASE_DIR — picked up once created."
        fi
    fi

    # ── Optional gaming-box sources ──────────────────────────────────────────
    echo ""
    echo "  The following are only relevant on a gaming box (Wolf + emulators +"
    echo "  Steam). On a plain homelab server you can leave them disabled."
    local DEFAULT_STORAGE="$ACTUAL_HOME/drives/games"
    local GAME_STORAGE_DIR=""
    prompt_text "  Game storage dir (ROMs/Steam/saves live here) [${DEFAULT_STORAGE}]:" "$DEFAULT_STORAGE" GAME_STORAGE_DIR
    GAME_STORAGE_DIR="${GAME_STORAGE_DIR/#\~/$ACTUAL_HOME}"
    GAME_STORAGE_DIR="${GAME_STORAGE_DIR%/}"

    echo ""
    local _a=""
    prompt_yn "  Back up emulator saves ($GAME_STORAGE_DIR/saves)? (y/N):" "n" _a
    local BACKUP_SAVES; BACKUP_SAVES=$([[ "$_a" =~ ^[Yy]$ ]] && echo yes || echo no)
    prompt_yn "  Back up Steam user data/saves (game installs excluded)? (y/N):" "n" _a
    local BACKUP_STEAM; BACKUP_STEAM=$([[ "$_a" =~ ^[Yy]$ ]] && echo yes || echo no)
    prompt_yn "  Back up ES-DE scraped artwork ($GAME_STORAGE_DIR/media)? (y/N):" "n" _a
    local BACKUP_MEDIA; BACKUP_MEDIA=$([[ "$_a" =~ ^[Yy]$ ]] && echo yes || echo no)
    echo ""
    echo "  /etc/wolf includes pairing/config AND profile_data — where Wolf stores"
    echo "  every app's home dir (ES-DE settings, controller mappings, RetroArch"
    echo "  saves & save states, standalone-emulator saves)."
    prompt_yn "  Back up Wolf state (/etc/wolf)? (y/N):" "n" _a
    local BACKUP_WOLF; BACKUP_WOLF=$([[ "$_a" =~ ^[Yy]$ ]] && echo yes || echo no)
    local WOLF_STATE_DIR="/etc/wolf"

    # ── 3. Repository location ────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  BACKUP REPOSITORY (local)"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Backups are stored in a local Kopia repository. You can mirror it to"
    echo "  another computer or the cloud later (see backup.conf, REMOTE_* lines)."
    echo "  Put it on a DIFFERENT drive from your data if you can."
    echo ""
    local REPO_DIR=""
    prompt_text "  Repository path [${DEFAULT_REPO}]:" "$DEFAULT_REPO" REPO_DIR
    REPO_DIR="${REPO_DIR/#\~/$ACTUAL_HOME}"
    REPO_DIR="${REPO_DIR%/}"

    echo ""
    echo "  The repository is encrypted. A strong password is generated and stored"
    echo "  in backup.conf (root-only). KEEP A COPY — without it backups cannot be"
    echo "  restored, even by you."
    echo ""
    local KOPIA_PASSWORD=""
    if [ "$UNATTENDED" = true ]; then
        echo "  [auto] Generating a random repository password."
    else
        read -rsp "  Repository password [Enter = auto-generate]: " KOPIA_PASSWORD; echo
    fi
    if [ -z "$KOPIA_PASSWORD" ]; then
        KOPIA_PASSWORD="$(generate_password 32)"
        log_info "  Generated a random repository password (saved in backup.conf)."
    fi

    # ── 4. Retention + schedule ───────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  SCHEDULE & RETENTION"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "    1) Daily at 03:00"
    echo "    2) Every 6 hours"
    echo "    3) Hourly              (recommended for active gaming)"
    echo "    4) Custom (systemd OnCalendar)"
    echo ""
    local _sch=""
    prompt_text "  How often? [3]:" "3" _sch
    local ONCALENDAR SCHED_LABEL
    case "${_sch:-3}" in
        1) ONCALENDAR="*-*-* 03:00:00";          SCHED_LABEL="daily at 03:00" ;;
        2) ONCALENDAR="*-*-* 00,06,12,18:00:00"; SCHED_LABEL="every 6 hours" ;;
        4) prompt_text "  OnCalendar expression:" "hourly" ONCALENDAR; SCHED_LABEL="$ONCALENDAR" ;;
        *) ONCALENDAR="hourly";                  SCHED_LABEL="hourly" ;;
    esac

    echo ""
    local KEEP_LATEST=""
    prompt_text "  How many recent snapshots to keep (latest)? [24]:" "24" KEEP_LATEST
    local KEEP_DAILY=7 KEEP_WEEKLY=4 KEEP_MONTHLY=6

    # ── 5. Write backup.conf ──────────────────────────────────────────────────
    log_info "Writing $CONF_FILE ..."
    tee "$CONF_FILE" >/dev/null << CONFEOF
# ── gaming-backup config (read by gaming-backup.sh) ──────────────────────────
# Generated on $(date '+%F %T'). Safe to hand-edit.

KOPIA="$KOPIA_BIN"
KOPIA_CONFIG="$KOPIA_CONFIG"
KOPIA_CACHE_DIR="$CACHE_DIR"
# Repository encryption password — KEEP A COPY somewhere safe.
KOPIA_PASSWORD='$KOPIA_PASSWORD'

# ── Sources (progress / saves / user data only) ──────────────────────────────
# MC_BASE_DIR holds Minecraft instances; every <id>/data with an itzg Dockerfile
# is snapshotted automatically (covers multi-server setups).
MC_BASE_DIR="$MC_BASE_DIR"
GAME_STORAGE_DIR="$GAME_STORAGE_DIR"
WOLF_STATE_DIR="$WOLF_STATE_DIR"
BACKUP_SAVES="$BACKUP_SAVES"   # \$GAME_STORAGE_DIR/saves
BACKUP_STEAM="$BACKUP_STEAM"   # \$GAME_STORAGE_DIR/steam (game installs excluded by policy)
BACKUP_MEDIA="$BACKUP_MEDIA"   # \$GAME_STORAGE_DIR/media (ES-DE scraped artwork)
BACKUP_WOLF="$BACKUP_WOLF"     # /etc/wolf — config + profile_data

# ── Optional offsite mirror ──────────────────────────────────────────────────
# Mirror the WHOLE repository to another computer or the cloud after each run.
# Leave REMOTE_TYPE=none to stay local-only.
#
#   SFTP:    REMOTE_TYPE="sftp"  REMOTE_ARGS="--host H --username U --path /srv/..."
#   B2:      REMOTE_TYPE="b2"   REMOTE_ARGS="--bucket B --key-id K --key A"
#   S3:      REMOTE_TYPE="s3"   REMOTE_ARGS="--bucket B --endpoint E --access-key K --secret-access-key S"
#   rclone:  REMOTE_TYPE="rclone"  REMOTE_ARGS="--remote-path myremote:gaming-kopia"
#
REMOTE_TYPE="none"
REMOTE_ARGS=""
CONFEOF
    chown root:root "$CONF_FILE" 2>/dev/null || true
    chmod 600 "$CONF_FILE"
    log_success "backup.conf written (chmod 600 — contains the repo password)"

    # ── 6. Create / connect the repository, set policies ─────────────────────
    log_info "Preparing repository at $REPO_DIR ..."
    mkdir -p "$REPO_DIR" "$CACHE_DIR" "$(dirname "$KOPIA_CONFIG")"

    kp() { env KOPIA_PASSWORD="$KOPIA_PASSWORD" "$KOPIA_BIN" --config-file="$KOPIA_CONFIG" "$@"; }

    if kp repository status >/dev/null 2>&1; then
        log_success "Already connected to a repository."
    elif test -e "$REPO_DIR/kopia.repository.f"; then
        log_info "Existing repository found — connecting..."
        kp repository connect filesystem --path="$REPO_DIR" --cache-directory="$CACHE_DIR" \
            || { log_error "Failed to connect to existing repository."; return 1; }
        log_success "Connected to existing repository."
    else
        log_info "Creating new repository..."
        kp repository create filesystem --path="$REPO_DIR" --cache-directory="$CACHE_DIR" \
            || { log_error "Failed to create repository."; return 1; }
        log_success "Repository created."
    fi

    log_info "Applying global policy (zstd compression + retention)..."
    kp policy set --global --compression=zstd >/dev/null
    kp policy set --global \
        --keep-latest="$KEEP_LATEST" \
        --keep-daily="$KEEP_DAILY" \
        --keep-weekly="$KEEP_WEEKLY" \
        --keep-monthly="$KEEP_MONTHLY" \
        --keep-annual=0 --keep-hourly=0 >/dev/null
    log_success "Retention: keep latest $KEEP_LATEST, $KEEP_DAILY daily, $KEEP_WEEKLY weekly, $KEEP_MONTHLY monthly"

    if [ "$BACKUP_STEAM" = yes ]; then
        log_info "Setting Steam ignore rules (excluding game installs, keeping saves)..."
        kp policy set "$GAME_STORAGE_DIR/steam" \
            --add-ignore='**/steamapps/common' \
            --add-ignore='**/steamapps/downloading' \
            --add-ignore='**/steamapps/shadercache' \
            --add-ignore='**/steamapps/temp' \
            --add-ignore='**/steamapps/workshop' \
            --add-ignore='**/depotcache' >/dev/null 2>&1 \
            || log_warning "Could not pre-set Steam ignore policy (applies on first snapshot)."
    fi

    # ── 7. Generate the worker script ────────────────────────────────────────
    log_info "Writing worker $WORKER ..."
    cat > "$WORKER" << 'WORKEREOF'
#!/bin/bash
# Generated by the gaming-backup service — frequent game-save snapshots via Kopia.
# Nothing is stopped: Minecraft worlds are flushed to disk (save-all) first.
#
#   sudo ./gaming-backup.sh            run a backup now
#   sudo ./gaming-backup.sh snapshots  list snapshots
#   sudo ./gaming-backup.sh policy     show retention/ignore policy
#
# Reads settings from backup.conf next to this script.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF (re-run the gaming-backup service)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

export KOPIA_PASSWORD
log() { echo "[$(date '+%F %T')] $*"; }
k()   { "$KOPIA" --config-file="$KOPIA_CONFIG" "$@"; }

if ! k repository status >/dev/null 2>&1; then
    log "ERROR: not connected to a repository — re-run the gaming-backup service"
    exit 1
fi

case "${1:-run}" in
    snapshots) k snapshot list; exit 0 ;;
    policy)    k policy show --global; exit 0 ;;
esac

log "===== Gaming backup starting ====="

# Flush each running Minecraft world to disk first so snapshots are consistent.
if [ -n "${MC_BASE_DIR:-}" ] && command -v docker >/dev/null 2>&1; then
    _flushed=0
    for d in "$MC_BASE_DIR"/*/; do
        [ -f "${d}Dockerfile" ] && grep -qs itzg "${d}Dockerfile" || continue
        name="$(basename "$d")"
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
            log "Flushing Minecraft world '$name' (save-all)..."
            docker exec "$name" mc-send-to-console save-all flush 2>/dev/null \
                || docker exec "$name" rcon-cli save-all 2>/dev/null || true
            _flushed=1
        fi
    done
    [ "$_flushed" = 1 ] && sleep 5
fi

rc=0
snap() {
    local label="$1" path="$2"
    if [ -z "$path" ] || [ ! -e "$path" ]; then
        log "skip $label — not found: ${path:-<unset>}"; return
    fi
    log "Snapshotting $label: $path"
    if ! k snapshot create --description="gaming: $label" "$path"; then
        log "WARNING: snapshot failed for $label"; rc=1
    fi
}

if [ -n "${MC_BASE_DIR:-}" ]; then
    for d in "$MC_BASE_DIR"/*/; do
        [ -f "${d}Dockerfile" ] && grep -qs itzg "${d}Dockerfile" && [ -d "${d}data" ] || continue
        nm="$(basename "$d")"
        case "$nm" in minecraft*) lbl="$nm" ;; *) lbl="minecraft-$nm" ;; esac
        snap "$lbl" "${d}data"
    done
fi
[ "${BACKUP_SAVES:-no}" = yes ]    && snap "emulator-saves"  "$GAME_STORAGE_DIR/saves"
[ "${BACKUP_STEAM:-no}" = yes ]    && snap "steam-userdata"  "$GAME_STORAGE_DIR/steam"
[ "${BACKUP_MEDIA:-no}" = yes ]    && snap "es-de-media"     "$GAME_STORAGE_DIR/media"
[ "${BACKUP_WOLF:-no}"  = yes ]    && snap "wolf-state"      "$WOLF_STATE_DIR"

if [ "${REMOTE_TYPE:-none}" != "none" ] && [ -n "${REMOTE_TYPE:-}" ]; then
    log "Mirroring repository to remote ($REMOTE_TYPE)..."
    # shellcheck disable=SC2086
    if ! k repository sync-to "$REMOTE_TYPE" $REMOTE_ARGS; then
        log "WARNING: remote mirror failed"; rc=1
    fi
fi

if [ "$rc" -eq 0 ]; then log "===== Gaming backup complete ====="; else log "===== Gaming backup finished WITH WARNINGS ====="; fi
exit "$rc"
WORKEREOF
    chmod +x "$WORKER"
    chown root:root "$WORKER" 2>/dev/null || true
    log_success "gaming-backup.sh written"

    # ── Copy the interactive restore script ───────────────────────────────────
    local RESTORE_SRC="${HERE:-}/extras/restore_kopia_backup.sh"
    local RESTORE_DEST="$BACKUP_DIR/restore_kopia_backup.sh"
    if [ -f "$RESTORE_SRC" ]; then
        cp "$RESTORE_SRC" "$RESTORE_DEST"
        chmod +x "$RESTORE_DEST"
        chown root:root "$RESTORE_DEST" 2>/dev/null || true
        log_success "restore_kopia_backup.sh installed"
    else
        log_warning "extras/restore_kopia_backup.sh not found — restore script not installed"
    fi

    # ── 8. Install systemd timer (fallback: cron) ────────────────────────────
    local AUTORUN=""
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        log_info "Installing systemd service + timer ($SCHED_LABEL)..."
        tee "/etc/systemd/system/${SVC_NAME}.service" >/dev/null << UNITEOF
[Unit]
Description=Post-install gaming backup (Minecraft world + game saves via Kopia)
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash $WORKER run
UNITEOF

        tee "/etc/systemd/system/${SVC_NAME}.timer" >/dev/null << UNITEOF
[Unit]
Description=Schedule gaming backup ($SCHED_LABEL)

[Timer]
OnCalendar=$ONCALENDAR
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
UNITEOF

        systemctl daemon-reload
        systemctl enable --now "${SVC_NAME}.timer"
        log_success "Timer enabled: $SCHED_LABEL"
        AUTORUN="systemctl list-timers ${SVC_NAME}.timer"
    else
        log_warning "systemd not detected — installing a cron job instead."
        local CRON
        case "${_sch:-3}" in
            1) CRON="0 3 * * *"          ;;
            2) CRON="0 0,6,12,18 * * *"  ;;
            *) CRON="0 * * * *"          ;;
        esac
        echo "$CRON root /bin/bash $WORKER run >> /var/log/${SVC_NAME}.log 2>&1" \
            > "/etc/cron.d/${SVC_NAME}"
        log_success "Cron job installed: $CRON"
        AUTORUN="cat /etc/cron.d/${SVC_NAME}"
    fi

    # ── 9. First backup now? ─────────────────────────────────────────────────
    echo ""
    local _now=""
    prompt_yn "  Run the first gaming backup now? (Y/n):" "y" _now
    if [[ ! "$_now" =~ ^[Nn]$ ]]; then
        /bin/bash "$WORKER" run || log_warning "First backup reported warnings — check the output above."
    fi

    # ── Summary ──────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  GAMING BACKUP CONFIGURED"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Repository : $REPO_DIR  (encrypted, dedup + zstd)"
    echo "  Schedule   : $SCHED_LABEL"
    echo "  Config     : $CONF_FILE"
    echo "  Worker     : $WORKER"
    echo "  Backing up :"
    [ -n "$MC_BASE_DIR" ]        && echo "    • Minecraft worlds     $MC_BASE_DIR/*/data  (all instances)"
    [ "$BACKUP_SAVES" = yes ]    && echo "    • Emulator saves       $GAME_STORAGE_DIR/saves"
    [ "$BACKUP_STEAM" = yes ]    && echo "    • Steam user data      $GAME_STORAGE_DIR/steam  (game installs excluded)"
    [ "$BACKUP_MEDIA" = yes ]    && echo "    • ES-DE scraped art    $GAME_STORAGE_DIR/media"
    [ "$BACKUP_WOLF"  = yes ]    && echo "    • Wolf state           $WOLF_STATE_DIR  (config + profile_data)"
    echo "  NOT backed up: ROMs, Steam game installs (re-downloadable)."
    echo ""
    echo "  Commands:"
    echo "    sudo $WORKER                         back up now"
    echo "    sudo $WORKER snapshots               list snapshots"
    echo "    sudo $RESTORE_DEST                   interactive restore"
    echo "    sudo $RESTORE_DEST --list            list all snapshot sources"
    echo "    $AUTORUN"
    echo ""
    echo "  Tip: also install the 'backup' service for nightly full-service recovery."
    echo ""
    log_warning "Save your repository password (in backup.conf) somewhere safe —"
    log_warning "without it the encrypted backups cannot be restored."
    echo ""
    log_success "Gaming backup configured."
}
