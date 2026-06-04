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
    elif echo "$txt" | grep -qi "repository.*does not exist\|not a borg\|is not a valid"; then
        echo "repository not found — re-run the backup installer"
    elif echo "$txt" | grep -qi "passphrase\|wrong key\|bad key\|cannot decrypt"; then
        echo "wrong passphrase — check backup.conf"
    elif echo "$txt" | grep -qi "permission denied\|access denied"; then
        echo "permission denied — check file permissions"
    else
        echo "error — see system logs on $HOST"
    fi
}

repo_for()    { local var="DEST_${1}_REPO";       echo "${!var:-}"; }
pass_for()    { local var="DEST_${1}_PASSPHRASE"; echo "${!var:-}"; }
dest_for_svc() { local var="SVC_${1//-/_}";       echo "${!var:-${DEST_DEFAULT:-default}}"; }

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
declare -a FAILED_SVCS=()
_ERR="$(mktemp)"
trap 'rm -f "$_ERR"' EXIT

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
            "::$ARCHIVE" "$svc_dir" 2>"$_ERR" | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc (Minecraft, no downtime)"
        else
            _reason="$(categorize_error "$(cat "$_ERR")")"
            log "WARNING: archive failed for $svc — $_reason"
            FAILED_SVCS+=("$svc: $_reason")
            rc=1
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
            "::$ARCHIVE" "$svc_dir" 2>"$_ERR" | while IFS= read -r line; do log "  $line"; done; then
            log "OK $svc"
        else
            _reason="$(categorize_error "$(cat "$_ERR")")"
            log "WARNING: archive failed for $svc — $_reason"
            FAILED_SVCS+=("$svc: $_reason")
            rc=1
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

if [ "$rc" -eq 0 ]; then
    log "===== Borg backup complete ====="
    ntfy_send "✓ Borg backup complete" "$HOST: all services archived successfully" \
        "low" "white_check_mark"
else
    log "===== Borg backup finished WITH WARNINGS (see above) ====="
    _ntfy_msg="$HOST: Borg backup failures:"
    for _s in "${FAILED_SVCS[@]}"; do _ntfy_msg+=$'\n'"• $_s"; done
    ntfy_send "✗ Borg backup FAILED" "$_ntfy_msg" "urgent" "rotating_light"
fi
exit "$rc"
