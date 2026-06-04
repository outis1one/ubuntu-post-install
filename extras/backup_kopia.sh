#!/bin/bash
# extras/backup_kopia.sh — Kopia backup worker for all Docker services.
# Installed to ~/docker/backup/backup_kopia.sh by the backup service installer.
#
#   sudo ./backup_kopia.sh             run a full backup cycle
#   sudo ./backup_kopia.sh snapshots   list all snapshots (all repos)
#   sudo ./backup_kopia.sh policy      show retention policies
#
# Minecraft instances: flush to disk (save-all) then snapshot — no downtime.
# All other services:  stop → snapshot → restart for consistency.
# Reads backup.conf from the same directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run: sudo setup.sh backup)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="$ACTUAL_HOME/docker"
HOST="$(hostname -s 2>/dev/null || hostname)"

log() { echo "[$(date '+%F %T')] $*"; }

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
        echo "repository not found — re-run the backup installer"
    elif echo "$txt" | grep -qi "passphrase\|wrong key\|cannot decrypt"; then
        echo "wrong passphrase — check backup.conf"
    elif echo "$txt" | grep -qi "permission denied\|access denied"; then
        echo "permission denied — check file permissions"
    else
        echo "error — see system logs on $HOST"
    fi
}

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

log "===== Backup starting ====="
rc=0
declare -a FAILED_SVCS=()
_ERR="$(mktemp)"
trap 'rm -f "$_ERR"' EXIT
START_TS="$(date +%s)"
BACKUP_COUNT=0

for _pf_dest in ${DEST_NAMES:-default}; do
    _pf_var="DEST_${_pf_dest}_REPO"; _pf_repo="${!_pf_var:-}"
    if [ -n "$_pf_repo" ] && [[ "$_pf_repo" != *@*:* ]] && [[ "$_pf_repo" != ssh://* ]]; then
        _pf_dir="$([ -d "$_pf_repo" ] && echo "$_pf_repo" || dirname "$_pf_repo")"
        _pf_avail="$(df -m "$_pf_dir" 2>/dev/null | awk 'NR==2{print $4}')"
        if [ -n "$_pf_avail" ] && [ "$_pf_avail" -lt 512 ]; then
            log "WARNING: Low disk for '$_pf_dest' — ${_pf_avail}MB free at $_pf_repo"
            FAILED_SVCS+=("$_pf_dest: low disk (${_pf_avail}MB free)")
            rc=1
        fi
    fi
done

for svc_dir in "$DOCKER_DIR"/*/; do
    [ -f "${svc_dir}docker-compose.yml" ] || continue
    svc="$(basename "$svc_dir")"
    [[ "$svc" == "backup" || "$svc" == "borg-backup" || "$svc" == "gaming-backup" ]] && continue

    dest="$(dest_for_svc "$svc")"
    _repo_var="DEST_${dest}_REPO"
    [ -n "${!_repo_var:-}" ] || { log "SKIP $svc — dest '$dest' not configured in conf"; continue; }

    if is_minecraft "$svc_dir"; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Flushing Minecraft world '$svc' (save-all, no downtime)..."
            docker exec "$svc" mc-send-to-console save-all flush 2>/dev/null \
                || docker exec "$svc" rcon-cli save-all 2>/dev/null || true
            sleep 5
        fi
        log "Snapshotting $svc (dest: $dest)..."
        if kp_for "$dest" snapshot create --description="backup: $svc" "$svc_dir" 2>"$_ERR"; then
            log "OK $svc (Minecraft, no downtime)"
            BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            _reason="$(categorize_error "$(cat "$_ERR")")"
            log "WARNING: snapshot failed for $svc — $_reason"
            FAILED_SVCS+=("$svc: $_reason")
            rc=1
        fi
    else
        STOPPED=false
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Stopping $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" down 2>/dev/null \
                || docker stop "$svc" 2>/dev/null \
                || log "WARNING: could not stop $svc — snapshotting live (consistency not guaranteed)"
            STOPPED=true
        fi

        log "Snapshotting $svc (dest: $dest)..."
        if kp_for "$dest" snapshot create --description="backup: $svc" "$svc_dir" 2>"$_ERR"; then
            log "OK $svc"
            BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            _reason="$(categorize_error "$(cat "$_ERR")")"
            log "WARNING: snapshot failed for $svc — $_reason"
            FAILED_SVCS+=("$svc: $_reason")
            rc=1
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
        if ! kp_for "$dest" repository sync-to "$REMOTE_TYPE" $REMOTE_ARGS 2>"$_ERR"; then
            _reason="$(categorize_error "$(cat "$_ERR")")"
            log "WARNING: mirror failed for '$dest' — $_reason"
            FAILED_SVCS+=("mirror[$dest]: $_reason")
            rc=1
        fi
    done
fi

DURATION=$(( $(date +%s) - START_TS ))
DURATION_STR="$((DURATION/60))m $((DURATION%60))s"

if [ "$rc" -eq 0 ]; then
    log "===== Backup complete — $BACKUP_COUNT service(s) in $DURATION_STR ====="
    ntfy_send "✓ Backup complete" \
        "$HOST: $BACKUP_COUNT service(s) backed up in $DURATION_STR" \
        "low" "white_check_mark"
else
    log "===== Backup finished WITH WARNINGS — $BACKUP_COUNT/$((BACKUP_COUNT+${#FAILED_SVCS[@]})) succeeded in $DURATION_STR ====="
    _ntfy_msg="$HOST: backup failures (${#FAILED_SVCS[@]}):"
    for _s in "${FAILED_SVCS[@]}"; do _ntfy_msg+=$'\n'"• $_s"; done
    ntfy_send "✗ Backup FAILED" "$_ntfy_msg" "urgent" "rotating_light"
fi
exit "$rc"
