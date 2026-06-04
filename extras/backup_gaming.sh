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
HOST="$(hostname -s 2>/dev/null || hostname)"
log() { echo "[$(date '+%F %T')] $*"; }
k()   { "$KOPIA" --config-file="$KOPIA_CONFIG" "$@"; }

ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    [ -z "${NTFY_URL:-}" ] && return 0
    local -a _args=(-fsS -o /dev/null)
    _args+=(-H "Title: $title" -H "Priority: $priority")
    [ -n "$tags" ]           && _args+=(-H "Tags: $tags")
    [ -n "${NTFY_TOKEN:-}" ] && _args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl "${_args[@]}" -d "$msg" "$NTFY_URL" 2>/dev/null || true
}

categorize_error() {
    local txt="$1"
    if   echo "$txt" | grep -qi "no space left\|disk quota exceeded"; then
        echo "disk full — backup destination is out of space"
    elif echo "$txt" | grep -qi "connection refused\|network unreachable\|no route to host\|ssh.*connect\|timed out\|host unreachable"; then
        echo "remote unreachable — check network / destination host"
    elif echo "$txt" | grep -qi "repository.*not.*exist\|not a valid kopia\|not connected"; then
        echo "repository not found — re-run the gaming-backup installer"
    elif echo "$txt" | grep -qi "passphrase\|wrong key\|cannot decrypt"; then
        echo "wrong passphrase — check backup.conf"
    elif echo "$txt" | grep -qi "permission denied\|access denied"; then
        echo "permission denied — check file permissions"
    else
        echo "error — see system logs on $HOST"
    fi
}

if ! k repository status >/dev/null 2>&1; then
    log "ERROR: not connected to a repository — re-run the gaming-backup service"
    ntfy_send "✗ Gaming backup FAILED" \
        "$HOST: cannot connect to Kopia repository — re-run gaming-backup installer" \
        "urgent" "rotating_light"
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
declare -a FAILED_LABELS=()
_ERR="$(mktemp)"
trap 'rm -f "$_ERR"' EXIT
START_TS="$(date +%s)"
BACKUP_COUNT=0

if [ -n "${KOPIA_REPO:-}" ] && [[ "${KOPIA_REPO:-}" != *@*:* ]] && [[ "${KOPIA_REPO:-}" != ssh://* ]]; then
    _pf_dir="$([ -d "$KOPIA_REPO" ] && echo "$KOPIA_REPO" || dirname "$KOPIA_REPO")"
    _pf_avail="$(df -m "$_pf_dir" 2>/dev/null | awk 'NR==2{print $4}')"
    if [ -n "$_pf_avail" ] && [ "$_pf_avail" -lt 512 ]; then
        log "WARNING: Low disk space — ${_pf_avail}MB free at $KOPIA_REPO"
        FAILED_LABELS+=("repo: low disk (${_pf_avail}MB free)")
        rc=1
    fi
fi

snap() {
    local label="$1" path="$2"
    if [ -z "$path" ] || [ ! -e "$path" ]; then
        log "skip $label — not found: ${path:-<unset>}"; return
    fi
    log "Snapshotting $label: $path"
    if k snapshot create --description="gaming: $label" "$path" 2>"$_ERR"; then
        BACKUP_COUNT=$((BACKUP_COUNT+1))
    else
        _reason="$(categorize_error "$(cat "$_ERR")")"
        log "WARNING: snapshot failed for $label — $_reason"
        FAILED_LABELS+=("$label: $_reason")
        rc=1
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
    if ! k repository sync-to "$REMOTE_TYPE" $REMOTE_ARGS 2>"$_ERR"; then
        _reason="$(categorize_error "$(cat "$_ERR")")"
        log "WARNING: remote mirror failed — $_reason"
        FAILED_LABELS+=("mirror: $_reason")
        rc=1
    fi
fi

DURATION=$(( $(date +%s) - START_TS ))
DURATION_STR="$((DURATION/60))m $((DURATION%60))s"

if [ "$rc" -eq 0 ]; then
    log "===== Gaming backup complete — $BACKUP_COUNT snapshot(s) in $DURATION_STR ====="
    ntfy_send "✓ Gaming backup complete" \
        "$HOST: $BACKUP_COUNT snapshot(s) saved in $DURATION_STR" \
        "low" "white_check_mark"
else
    log "===== Gaming backup finished WITH WARNINGS — $BACKUP_COUNT/$((BACKUP_COUNT+${#FAILED_LABELS[@]})) succeeded in $DURATION_STR ====="
    _ntfy_msg="$HOST: gaming backup failures (${#FAILED_LABELS[@]}):"
    for _s in "${FAILED_LABELS[@]}"; do _ntfy_msg+=$'\n'"• $_s"; done
    ntfy_send "✗ Gaming backup FAILED" "$_ntfy_msg" "urgent" "rotating_light"
fi
exit "$rc"
