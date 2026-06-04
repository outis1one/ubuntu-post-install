#!/bin/bash
# extras/backup_gaming.sh — Kopia gaming-saves worker (no service downtime).
# Installed to ~/docker/gaming-backup/backup_gaming.sh by the gaming-backup installer.
#
#   sudo ./backup_gaming.sh             run a backup now
#   sudo ./backup_gaming.sh snapshots   list snapshots
#   sudo ./backup_gaming.sh policy      show retention/ignore policy
#
# Nothing is stopped: Minecraft worlds are flushed to disk (save-all) first.
# Reads backup.conf from the same directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF (re-run: sudo setup.sh gaming-backup)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

export KOPIA_PASSWORD
log() { echo "[$(date '+%F %T')] $*"; }
k()   { "$KOPIA" --config-file="$KOPIA_CONFIG" "$@"; }

ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    [ -z "${NTFY_URL:-}" ] || [ -z "${NTFY_TOPIC:-}" ] && return 0
    local -a args=(-fsSL -o /dev/null -X POST "${NTFY_URL}/${NTFY_TOPIC}")
    args+=(-H "Title: ${title}" -H "Priority: ${priority}")
    [ -n "${tags}" ] && args+=(-H "Tags: ${tags}")
    [ -n "${NTFY_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    args+=(-d "${msg}")
    curl "${args[@]}" 2>/dev/null || true
}

FAIL_REASONS=()
START_TS="$(date +%s)"
BACKUP_COUNT=0
TRAP_LINE=0; TRAP_CMD=""
trap 'TRAP_LINE=$LINENO; TRAP_CMD=$BASH_COMMAND' ERR

if ! k repository status >/dev/null 2>&1; then
    log "ERROR: not connected to a repository — re-run the gaming-backup service"
    exit 1
fi

case "${1:-run}" in
    snapshots) k snapshot list; exit 0 ;;
    policy)    k policy show --global; exit 0 ;;
esac

log "===== Gaming backup starting ====="

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
    if k snapshot create --description="gaming: $label" "$path"; then
        BACKUP_COUNT=$((BACKUP_COUNT+1))
    else
        log "WARNING: snapshot failed for $label"; rc=1
        FAIL_REASONS+=("$label: snapshot failed")
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
[ "${BACKUP_SAVES:-no}" = yes ]  && snap "emulator-saves" "$GAME_STORAGE_DIR/saves"
[ "${BACKUP_STEAM:-no}" = yes ]  && snap "steam-userdata" "$GAME_STORAGE_DIR/steam"
[ "${BACKUP_MEDIA:-no}" = yes ]  && snap "es-de-media"    "$GAME_STORAGE_DIR/media"
[ "${BACKUP_WOLF:-no}"  = yes ]  && snap "wolf-state"     "$WOLF_STATE_DIR"

if [ "${REMOTE_TYPE:-none}" != "none" ] && [ -n "${REMOTE_TYPE:-}" ]; then
    log "Mirroring repository to remote ($REMOTE_TYPE)..."
    # shellcheck disable=SC2086
    if ! k repository sync-to "$REMOTE_TYPE" $REMOTE_ARGS; then
        log "WARNING: remote mirror failed"; rc=1
    fi
fi

DURATION=$(( $(date +%s) - START_TS ))
MINS=$(( DURATION / 60 )); SECS=$(( DURATION % 60 ))
if [ "$rc" -eq 0 ]; then
    log "===== Gaming backup complete (${BACKUP_COUNT} snapshots, ${MINS}m${SECS}s) ====="
    ntfy_send "Gaming backup complete" \
        "$(date '+%F %T') — ${BACKUP_COUNT} snapshot(s) saved. Duration: ${MINS}m${SECS}s." \
        "low" "white_check_mark"
else
    if [ "${#FAIL_REASONS[@]}" -gt 0 ]; then
        fail_msg="$(printf '%s; ' "${FAIL_REASONS[@]}" | sed 's/; $//')"
    else
        fail_msg="Script error at line ${TRAP_LINE}: ${TRAP_CMD}"
    fi
    log "===== Gaming backup finished WITH WARNINGS ====="
    ntfy_send "Gaming backup FAILED" \
        "$(date '+%F %T') — ${fail_msg}. Check: journalctl -u post-install-gaming-backup" \
        "high" "rotating_light"
fi
exit "$rc"
