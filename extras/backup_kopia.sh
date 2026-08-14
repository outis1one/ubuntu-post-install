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

# Logs the raw stderr text a failure produced, truncated to a sane length.
# categorize_error()'s bucket alone ("error — see system logs") used to be
# the end of the trail for anything that didn't match one of its known
# patterns — the actual message was in a mktemp'd file this script deletes
# on exit (trap ... EXIT), so nothing was ever really "in system logs" to
# go look at. This makes that claim true: the raw text now lands in the
# same log stream (journal, when run via the systemd timer) as everything
# else, surviving past the run that produced it.
#
# Takes the already-read error TEXT, not the file path. A live run showed
# categorize_error() correctly matching a specific pattern (so $_ERR had
# real content at that point) while a second, later read of the same file
# for this function came back completely empty — every failure that night
# logged its categorized reason but zero "Raw error:" lines. Whatever causes
# that (the file is reused across the whole script run and read twice per
# failure), reading it once and passing the string to both this function and
# categorize_error() removes the second read entirely, so there's nothing
# left to race.
log_raw_error() {
    local raw
    raw="$(printf '%s' "$1" | tr '\n' ' ' | head -c 500)"
    [ -n "$raw" ] && log "  Raw error: $raw"
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
            _err_text="$(cat "$_ERR" 2>/dev/null)"
            _reason="$(categorize_error "$_err_text")"
            log "WARNING: snapshot failed for $svc — $_reason"
            log_raw_error "$_err_text"
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
            _err_text="$(cat "$_ERR" 2>/dev/null)"
            _reason="$(categorize_error "$_err_text")"
            log "WARNING: snapshot failed for $svc — $_reason"
            log_raw_error "$_err_text"
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
            _err_text="$(cat "$_ERR" 2>/dev/null)"
            _reason="$(categorize_error "$_err_text")"
            log "WARNING: mirror failed for '$dest' — $_reason"
            log_raw_error "$_err_text"
            FAILED_SVCS+=("mirror[$dest]: $_reason")
            rc=1
        fi
    done
fi

# Additional mirrors (EXTRA_MIRROR_NAMES) — run alongside REMOTE_TYPE above,
# not instead of it, so a box can mirror to e.g. Backblaze B2 AND directly
# to a spare over SSH/SFTP at the same time.
for mirror_name in ${EXTRA_MIRROR_NAMES:-}; do
    _mtype_var="MIRROR_${mirror_name}_TYPE"
    _margs_var="MIRROR_${mirror_name}_ARGS"
    _mtype="${!_mtype_var:-}"
    _margs="${!_margs_var:-}"
    [ -n "$_mtype" ] || continue
    for dest in ${DEST_NAMES:-default}; do
        log "Mirroring '$dest' to '$mirror_name' ($_mtype)..."
        # shellcheck disable=SC2086
        if ! kp_for "$dest" repository sync-to "$_mtype" $_margs 2>"$_ERR"; then
            _err_text="$(cat "$_ERR" 2>/dev/null)"
            _reason="$(categorize_error "$_err_text")"
            log "WARNING: mirror '$mirror_name' failed for '$dest' — $_reason"
            log_raw_error "$_err_text"
            FAILED_SVCS+=("mirror[$mirror_name/$dest]: $_reason")
            rc=1
        fi
    done
done

# ── Keep a spare box's copy of backup.conf + README current ─────────────────
# Runs after the data itself is backed up (and mirrored, if configured) so a
# sync never ships config pointing at a repo state that isn't actually there
# yet. dr_bringup.sh on the spare only needs these two small files — the
# repo data itself already lives wherever REMOTE_TYPE mirrored it (or is
# local, if the spare IS that target).
# Wraps a remote path for use inside a `ssh host "command '...'"` string so
# it's still safely quoted (spaces etc.) while a leading ~/ stays OUTSIDE
# the quotes — single-quoting a leading tilde stops the remote shell from
# expanding it at all, so it goes looking for a literal directory named
# "~" instead of the actual home directory. Confirmed live: this is exactly
# what broke `mkdir -p '~/docker/backup'` / `chmod 600 '~/docker/backup/...'`
# — the DEFAULT DR_SYNC_PATH — while rsync's own transfer step (which has
# its own tilde-aware remote-path handling, unrelated to shell quoting)
# succeeded against the exact same path.
_dr_remote_quote() {
    local p="$1"
    if [[ "$p" == "~/"* ]]; then
        printf "~/'%s'" "${p#\~/}"
    elif [[ "$p" == "~" ]]; then
        printf '~'
    else
        printf "'%s'" "$p"
    fi
}

if [ -n "${DR_SYNC_HOST:-}" ]; then
    _dr_path="${DR_SYNC_PATH:-~/docker/backup}"
    log "Syncing backup.conf + README to spare ($DR_SYNC_HOST:$_dr_path)..."
    _dr_files=("$CONF")
    [ -f "$HERE/README.md" ] && _dr_files+=("$HERE/README.md")
    # rsync instead of scp: modern OpenSSH (9.0+) defaults scp to an
    # SFTP-based transfer, and some remote-side setups (restricted shells,
    # forced commands, older sshd) reject that with an immediate "Connection
    # closed" while plain ssh exec and rsync's own protocol both still work
    # fine over the same connection. Confirmed live: scp failing this way
    # while `ssh "$DR_SYNC_HOST" true` succeeded, rsync doesn't hit it.
    if ssh -o BatchMode=yes -o ConnectTimeout=10 "$DR_SYNC_HOST" "mkdir -p $(_dr_remote_quote "$_dr_path")" 2>"$_ERR" \
        && rsync -a -e 'ssh -o BatchMode=yes -o ConnectTimeout=10' "${_dr_files[@]}" "$DR_SYNC_HOST:$_dr_path/" 2>>"$_ERR" \
        && ssh -o BatchMode=yes -o ConnectTimeout=10 "$DR_SYNC_HOST" "chmod 600 $(_dr_remote_quote "$_dr_path/backup.conf")" 2>>"$_ERR"; then
        log "OK spare sync ($DR_SYNC_HOST)"
    else
        _err_text="$(cat "$_ERR" 2>/dev/null)"
        _reason="$(categorize_error "$_err_text")"
        log "WARNING: spare sync failed — $_reason"
        log_raw_error "$_err_text"
        FAILED_SVCS+=("spare-sync: $_reason")
        rc=1
    fi
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
