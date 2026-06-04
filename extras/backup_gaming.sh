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

if [ "$rc" -eq 0 ]; then
    log "===== Gaming backup complete ====="
else
    log "===== Gaming backup finished WITH WARNINGS ====="
fi
exit "$rc"
