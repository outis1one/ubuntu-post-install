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
            log "OK $svc (Minecraft, no downtime)"
        else
            log "WARNING: snapshot failed for $svc"; rc=1
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
    log "===== Backup complete ====="
else
    log "===== Backup finished WITH WARNINGS (see above) ====="
fi
exit "$rc"
