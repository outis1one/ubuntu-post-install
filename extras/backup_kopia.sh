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

log() { echo "[$(date '+%F %T')] $*"; }

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

# Pre-flight: warn if any local repo destination is low on space
for _pf_dest in ${DEST_NAMES:-default}; do
    _pf_repo_var="DEST_${_pf_dest}_REPO"; _pf_repo="${!_pf_repo_var:-}"
    if [ -n "$_pf_repo" ] && [[ "$_pf_repo" != *@*:* ]] && [[ "$_pf_repo" != ssh://* ]]; then
        _pf_dir="$([ -d "$_pf_repo" ] && echo "$_pf_repo" || dirname "$_pf_repo")"
        _pf_avail="$(df -m "$_pf_dir" 2>/dev/null | awk 'NR==2{print $4}')"
        if [ -n "$_pf_avail" ] && [ "$_pf_avail" -lt 512 ]; then
            log "WARNING: Low disk for '$_pf_dest' — ${_pf_avail}MB free at $_pf_repo"
            FAIL_REASONS+=("Low disk at '${_pf_dest}' (${_pf_avail}MB free)")
        fi
    fi
done

log "===== Backup starting ====="
rc=0

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
        if kp_for "$dest" snapshot create --description="backup: $svc" "$svc_dir"; then
            log "OK $svc (Minecraft, no downtime)"; BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            log "WARNING: snapshot failed for $svc"; rc=1
            FAIL_REASONS+=("$svc: snapshot failed")
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
        if kp_for "$dest" snapshot create --description="backup: $svc" "$svc_dir"; then
            log "OK $svc"; BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            log "WARNING: snapshot failed for $svc"; rc=1
            FAIL_REASONS+=("$svc: snapshot failed")
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
            || { log "WARNING: mirror failed for '$dest'"; rc=1; FAIL_REASONS+=("mirror failed for '${dest}'"); }
    done
fi

DURATION=$(( $(date +%s) - START_TS ))
MINS=$(( DURATION / 60 )); SECS=$(( DURATION % 60 ))
if [ "$rc" -eq 0 ]; then
    log "===== Backup complete (${BACKUP_COUNT} services, ${MINS}m${SECS}s) ====="
    ntfy_send "Backup complete" \
        "$(date '+%F %T') — ${BACKUP_COUNT} service(s) backed up. Duration: ${MINS}m${SECS}s." \
        "low" "white_check_mark"
else
    if [ "${#FAIL_REASONS[@]}" -gt 0 ]; then
        fail_msg="$(printf '%s; ' "${FAIL_REASONS[@]}" | sed 's/; $//')"
    else
        fail_msg="Script error at line ${TRAP_LINE}: ${TRAP_CMD}"
    fi
    log "===== Backup finished WITH WARNINGS (see above) ====="
    ntfy_send "Backup FAILED" \
        "$(date '+%F %T') — ${fail_msg}. Check: journalctl -u post-install-backup" \
        "high" "rotating_light"
fi
exit "$rc"
