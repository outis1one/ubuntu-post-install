#!/bin/bash
# extras/test_backup_kopia.sh — Restore-verify test for Kopia-backed services.
# Installed to ~/docker/backup/ by the backup service installer.
#
#   sudo ./test_backup_kopia.sh                  test all services
#   sudo ./test_backup_kopia.sh --service <name> test one service
#   sudo ./test_backup_kopia.sh --list           list services and snapshot counts
#
# For each service:
#   1. Verifies the latest snapshot (kopia snapshot verify — catches corruption)
#   2. Stops the container
#   3. Moves live data aside   → <dir>.test-aside-TIMESTAMP
#   4. Restores latest snapshot → <dir>
#   5. Compares file inventory: restored vs original (informational)
#   6. Rolls back: original data returns, container restarts
#   7. Reports PASS / FAIL
#
# PASS criteria:
#   • snapshot verify exits 0 (no data corruption)
#   • kopia restore exits 0
#   • Restored directory is non-empty and contains docker-compose.yml
#
# The file comparison (step 5) is informational: any delta between restored and
# current data represents normal writes since the last backup — not a failure.
#
# Sends ntfy notification on completion if NTFY_URL / NTFY_TOPIC are set in backup.conf.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run: sudo setup.sh backup)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root: sudo $0"; exit 1; }
command -v jq >/dev/null 2>&1  || { echo "jq required: sudo apt install jq"; exit 1; }

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="$ACTUAL_HOME/docker"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/post-install-backup-test.log"

log()  { printf "[%s] %s\n"        "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
info() { printf "[%s] [INFO] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
pass() { printf "[%s] [PASS] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
fail() { printf "[%s] [FAIL] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
warn() { printf "[%s] [WARN] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

kp_for() {
    local dest="$1"; shift
    local cfg_var="DEST_${dest}_CONFIG" pw_var="DEST_${dest}_PASSWORD"
    local cfg="${!cfg_var:-}" pw="${!pw_var:-}"
    [ -n "$cfg" ] || { log "Unknown destination: $dest"; return 1; }
    env KOPIA_PASSWORD="$pw" "$KOPIA" --config-file="$cfg" "$@"
}

dest_for_svc() { local v="SVC_${1//-/_}"; echo "${!v:-${DEST_DEFAULT:-default}}"; }

ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    [ -z "${NTFY_URL:-}" ] && return 0
    local -a args=(-fsSL -o /dev/null)
    args+=(-H "Title: ${title}" -H "Priority: ${priority}")
    [ -n "${tags}" ] && args+=(-H "Tags: ${tags}")
    [ -n "${NTFY_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    args+=(-d "${msg}")
    curl "${args[@]}" "$NTFY_URL" 2>/dev/null || true
}

# ── Args ──────────────────────────────────────────────────────────────────────
FILTER_SVC=""; LIST_ONLY=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --service|-s) FILTER_SVC="${2:-}"; shift 2 ;;
        --list|-l)    LIST_ONLY=true;      shift ;;
        *)            shift ;;
    esac
done

# ── File inventory comparison (informational only) ────────────────────────────
compare_dirs() {
    local restored="${1%/}" original="${2%/}"
    local tmp_r tmp_o
    tmp_r="$(mktemp /tmp/bktest-XXXXXX)"; tmp_o="$(mktemp /tmp/bktest-XXXXXX)"
    find "$restored" -type f -printf "%P\n" 2>/dev/null | sort > "$tmp_r"
    find "$original" -type f -printf "%P\n" 2>/dev/null | sort > "$tmp_o"
    local r_files o_files added deleted
    r_files="$(wc -l < "$tmp_r")"; o_files="$(wc -l < "$tmp_o")"
    added="$(comm -23 "$tmp_o" "$tmp_r" | wc -l)"    # in original, not in restored
    deleted="$(comm -13 "$tmp_o" "$tmp_r" | wc -l)"  # in restored, not in original (deleted since backup)
    rm -f "$tmp_r" "$tmp_o"
    printf "restored=%d original=%d added_since_backup=%d deleted_since_backup=%d" \
        "$r_files" "$o_files" "$added" "$deleted"
}

# ── Collect services ──────────────────────────────────────────────────────────
declare -a SVCS_TO_TEST=()
for _sd in "$DOCKER_DIR"/*/; do
    [ -f "${_sd}docker-compose.yml" ] || continue
    _sv="$(basename "$_sd")"
    [[ "$_sv" == "backup" || "$_sv" == "borg-backup" || "$_sv" == "gaming-backup" ]] && continue
    [ -n "$FILTER_SVC" ] && [ "$_sv" != "$FILTER_SVC" ] && continue
    SVCS_TO_TEST+=("$_sv")
done

[ "${#SVCS_TO_TEST[@]}" -gt 0 ] || {
    echo "No services found$([ -n "$FILTER_SVC" ] && echo " matching: $FILTER_SVC" || echo " under $DOCKER_DIR")"
    exit 1
}

# ── List mode ─────────────────────────────────────────────────────────────────
if [ "$LIST_ONLY" = true ]; then
    echo ""
    printf "  %-20s  %-14s  %s\n" "SERVICE" "DESTINATION" "SNAPSHOTS"
    echo "  ──────────────────────────────────────────────────"
    # Cache snapshot JSON per destination
    declare -A _DEST_SNAPS=()
    for _sv in "${SVCS_TO_TEST[@]}"; do
        dest="$(dest_for_svc "$_sv")"
        if [ -z "${_DEST_SNAPS[$dest]+x}" ]; then
            _DEST_SNAPS["$dest"]="$(kp_for "$dest" snapshot list --all --json 2>/dev/null || echo '[]')"
        fi
        n="$(echo "${_DEST_SNAPS[$dest]}" | jq -r --arg p "${DOCKER_DIR}/${_sv}/" \
            '[.[] | select(.source.path == $p)] | length' 2>/dev/null || echo '?')"
        printf "  %-20s  %-14s  %s\n" "$_sv" "$dest" "$n"
    done
    echo ""; exit 0
fi

# ── Pre-cache snapshot JSON per destination ───────────────────────────────────
declare -A DEST_SNAP_CACHE=()
for _sv in "${SVCS_TO_TEST[@]}"; do
    dest="$(dest_for_svc "$_sv")"
    if [ -z "${DEST_SNAP_CACHE[$dest]+x}" ]; then
        _repo_var="DEST_${dest}_REPO"
        if [ -n "${!_repo_var:-}" ]; then
            DEST_SNAP_CACHE["$dest"]="$(kp_for "$dest" snapshot list --all --json 2>/dev/null || echo '[]')"
        else
            DEST_SNAP_CACHE["$dest"]="[]"
        fi
    fi
done

# ── Test run ──────────────────────────────────────────────────────────────────
log "===== Backup restore test starting (${#SVCS_TO_TEST[@]} service(s)) ====="
PASS_N=0; FAIL_N=0; SKIP_N=0
declare -a FAIL_LIST=()

for svc in "${SVCS_TO_TEST[@]}"; do
    svc_dir="${DOCKER_DIR}/${svc}"
    compose_file="${svc_dir}/docker-compose.yml"
    dest="$(dest_for_svc "$svc")"

    # Destination must be configured
    _repo_var="DEST_${dest}_REPO"
    if [ -z "${!_repo_var:-}" ]; then
        info "SKIP $svc — destination '$dest' not configured"; SKIP_N=$((SKIP_N+1)); continue
    fi

    log "── Testing: $svc (dest: $dest)"

    # ── Find latest snapshot ─────────────────────────────────────────────────
    svc_path="${svc_dir}/"
    all_snaps="${DEST_SNAP_CACHE[$dest]:-[]}"
    latest_id="$(echo "$all_snaps" | jq -r --arg p "$svc_path" \
        '[.[] | select(.source.path == $p)] | sort_by(.startTime) | reverse | .[0].id // empty' \
        2>/dev/null || true)"
    latest_time="$(echo "$all_snaps" | jq -r --arg p "$svc_path" \
        '[.[] | select(.source.path == $p)] | sort_by(.startTime) | reverse |
         .[0].startTime | split("T") | "\(.[0]) \(.[1][:8]) UTC"' 2>/dev/null || true)"

    if [ -z "${latest_id:-}" ]; then
        warn "SKIP $svc — no snapshots found in destination '$dest'"; SKIP_N=$((SKIP_N+1)); continue
    fi
    info "$svc: latest snapshot $latest_time  (id ${latest_id:0:12}...)"

    # ── Step 1: Verify snapshot integrity ───────────────────────────────────
    info "$svc: verifying snapshot..."
    if ! kp_for "$dest" snapshot verify "$latest_id" >/dev/null 2>&1; then
        fail "$svc: FAIL — snapshot verify failed (data may be corrupted in backup)"
        FAIL_N=$((FAIL_N+1)); FAIL_LIST+=("$svc (snapshot corruption)"); continue
    fi
    info "$svc: snapshot verified OK"

    # ── Step 2: Stop container ───────────────────────────────────────────────
    STOPPED=false
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$svc"; then
        info "$svc: stopping container..."
        if docker compose -f "$compose_file" down 2>/dev/null \
                || docker stop "$svc" 2>/dev/null; then
            STOPPED=true
        else
            warn "$svc: could not stop container — testing live (consistency not guaranteed)"
        fi
    fi

    # ── Step 3: Move live data aside ─────────────────────────────────────────
    ASIDE="${svc_dir}.test-aside-${TS}"
    if ! mv "$svc_dir" "$ASIDE" 2>/dev/null; then
        fail "$svc: FAIL — could not move data aside from $svc_dir"
        [ "$STOPPED" = true ] && \
            docker compose -f "${ASIDE}/docker-compose.yml" up -d 2>/dev/null || true
        FAIL_N=$((FAIL_N+1)); FAIL_LIST+=("$svc (move failed)"); continue
    fi

    # ── Step 4: Restore snapshot ─────────────────────────────────────────────
    mkdir -p "$svc_dir"
    TEST_PASS=true; FAIL_REASON=""; RESTORED_FILES=0
    if kp_for "$dest" restore "$latest_id" "$svc_dir" >/dev/null 2>&1; then
        RESTORED_FILES="$(find "$svc_dir" -type f 2>/dev/null | wc -l)"
    else
        TEST_PASS=false; FAIL_REASON="kopia restore failed"
    fi

    # ── Step 5: Sanity checks ────────────────────────────────────────────────
    if [ "$TEST_PASS" = true ] && [ "$RESTORED_FILES" -eq 0 ]; then
        TEST_PASS=false; FAIL_REASON="restored directory is empty"
    fi
    if [ "$TEST_PASS" = true ] && [ ! -f "${svc_dir}/docker-compose.yml" ]; then
        TEST_PASS=false; FAIL_REASON="docker-compose.yml missing from restore"
    fi

    # ── Step 6: File inventory comparison (informational) ────────────────────
    if [ "$TEST_PASS" = true ]; then
        info "$svc: comparing file inventory..."
        cmp_out="$(compare_dirs "$svc_dir" "$ASIDE" 2>/dev/null || echo "comparison error")"
        info "$svc: $cmp_out"
    fi

    # ── Step 7: Roll back to original data ───────────────────────────────────
    info "$svc: rolling back to live data..."
    rm -rf "$svc_dir" 2>/dev/null || true
    if mv "$ASIDE" "$svc_dir" 2>/dev/null; then
        info "$svc: live data restored"
    else
        warn "$svc: could not restore original — manual action needed:"
        warn "$svc:   mv \"$ASIDE\" \"$svc_dir\""
    fi
    if [ "$STOPPED" = true ]; then
        docker compose -f "$compose_file" up -d 2>/dev/null \
            || warn "$svc: restart failed — run: docker compose -f $compose_file up -d"
    fi

    # ── Result ────────────────────────────────────────────────────────────────
    if [ "$TEST_PASS" = true ]; then
        pass "$svc: PASS  (snapshot: $latest_time, restored $RESTORED_FILES file(s))"
        PASS_N=$((PASS_N+1))
    else
        fail "$svc: FAIL — $FAIL_REASON"
        FAIL_N=$((FAIL_N+1)); FAIL_LIST+=("$svc ($FAIL_REASON)")
    fi
done

# ── Summary & notification ────────────────────────────────────────────────────
TOTAL=$((PASS_N + FAIL_N))
log "===== Test complete: ${PASS_N}/${TOTAL} passed, ${SKIP_N} skipped ====="
[ -n "${NTFY_URL:-}" ] && log "Log: $LOG"

if [ "$FAIL_N" -eq 0 ]; then
    ntfy_send "Backup test passed (${PASS_N}/${TOTAL})" \
        "$(date '+%F %T') — All ${PASS_N} service(s) restore-tested OK. Log: $LOG" \
        "low" "white_check_mark,microscope"
    exit 0
else
    fail_str="$(IFS=', '; echo "${FAIL_LIST[*]}")"
    ntfy_send "Backup test FAILED (${FAIL_N}/${TOTAL} failed)" \
        "$(date '+%F %T') — FAILED: ${fail_str}. Log: $LOG" \
        "high" "rotating_light,microscope"
    exit 1
fi
