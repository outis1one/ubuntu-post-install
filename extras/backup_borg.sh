#!/bin/bash
# extras/backup_borg.sh — Borg backup worker for all Docker services.
# Installed to ~/docker/borg-backup/backup_borg.sh by the borg-backup installer.
#
#   sudo ./backup_borg.sh          run a full backup cycle
#   sudo ./backup_borg.sh list     list all archives in all repos
#   sudo ./backup_borg.sh info     show repo info for all destinations
#
# Minecraft instances: flush to disk (save-all) then archive — no downtime.
# All other services:  stop → archive → restart for consistency.
# Reads backup.conf from the same directory.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run: sudo setup.sh borg-backup)"; exit 1; }
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

repo_for() { local var="DEST_${1}_REPO"; echo "${!var:-}"; }
pass_for() { local var="DEST_${1}_PASSPHRASE"; echo "${!var:-}"; }
dest_for_svc() { local var="SVC_${1//-/_}"; echo "${!var:-${DEST_DEFAULT:-default}}"; }

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

# Pre-flight: warn if any local repo destination is low on space
for _pf_dest in ${DEST_NAMES:-default}; do
    _pf_repo="$(repo_for "$_pf_dest")"
    if [ -n "$_pf_repo" ] && [[ "$_pf_repo" != *@*:* ]] && [[ "$_pf_repo" != ssh://* ]]; then
        _pf_dir="$([ -d "$_pf_repo" ] && echo "$_pf_repo" || dirname "$_pf_repo")"
        _pf_avail="$(df -m "$_pf_dir" 2>/dev/null | awk 'NR==2{print $4}')"
        if [ -n "$_pf_avail" ] && [ "$_pf_avail" -lt 512 ]; then
            log "WARNING: Low disk for '$_pf_dest' — ${_pf_avail}MB free at $_pf_repo"
            FAIL_REASONS+=("Low disk at '${_pf_dest}' (${_pf_avail}MB free)")
        fi
    fi
done

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
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
            log "Flushing Minecraft world '$svc' (save-all, no downtime)..."
            docker exec "$svc" mc-send-to-console save-all flush 2>/dev/null \
                || docker exec "$svc" rcon-cli save-all 2>/dev/null || true
            sleep 5
        fi
        log "Archiving $svc → $dest::$ARCHIVE ..."
        if b_for "$dest" create \
            --compression=zstd,6 --exclude-caches --stats \
            "::$ARCHIVE" "$svc_dir" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc (Minecraft, no downtime)"; BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            log "WARNING: archive failed for $svc"; rc=1
            FAIL_REASONS+=("$svc: archive failed")
        fi
    else
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
            --compression=zstd,6 --exclude-caches --stats \
            "::$ARCHIVE" "$svc_dir" 2>&1 | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc"; BACKUP_COUNT=$((BACKUP_COUNT+1))
        else
            log "WARNING: archive failed for $svc"; rc=1
            FAIL_REASONS+=("$svc: archive failed")
        fi

        if [ "$STOPPED" = true ]; then
            log "Starting $svc..."
            docker compose -f "${svc_dir}docker-compose.yml" up -d 2>/dev/null \
                || log "WARNING: could not restart $svc — run: docker compose -f ${svc_dir}docker-compose.yml up -d"
        fi
    fi

    log "Pruning old archives for $svc in '$dest'..."
    b_for "$dest" prune \
        --keep-daily="${KEEP_DAILY:-7}" \
        --keep-weekly="${KEEP_WEEKLY:-4}" \
        --keep-monthly="${KEEP_MONTHLY:-3}" \
        --glob-archives="${svc}-*" \
        --list 2>/dev/null \
        || log "WARNING: prune failed for $svc (non-fatal)"
done

for dest in ${DEST_NAMES:-default}; do
    repo="$(repo_for "$dest")"
    [ -n "$repo" ] || continue
    log "Compacting repo '$dest'..."
    b_for "$dest" compact 2>/dev/null || true
done

DURATION=$(( $(date +%s) - START_TS ))
MINS=$(( DURATION / 60 )); SECS=$(( DURATION % 60 ))
if [ "$rc" -eq 0 ]; then
    log "===== Borg backup complete (${BACKUP_COUNT} services, ${MINS}m${SECS}s) ====="
    ntfy_send "Borg backup complete" \
        "$(date '+%F %T') — ${BACKUP_COUNT} service(s) archived. Duration: ${MINS}m${SECS}s." \
        "low" "white_check_mark"
else
    if [ "${#FAIL_REASONS[@]}" -gt 0 ]; then
        fail_msg="$(printf '%s; ' "${FAIL_REASONS[@]}" | sed 's/; $//')"
    else
        fail_msg="Script error at line ${TRAP_LINE}: ${TRAP_CMD}"
    fi
    log "===== Borg backup finished WITH WARNINGS (see above) ====="
    ntfy_send "Borg backup FAILED" \
        "$(date '+%F %T') — ${fail_msg}. Check: journalctl -u post-install-borg-backup" \
        "high" "rotating_light"
fi
exit "$rc"
