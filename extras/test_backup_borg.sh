#!/bin/bash
# extras/test_backup_borg.sh — Restore-verify test for Borg-backed services.
# Installed to ~/docker/borg-backup/ by the borg-backup service installer.
#
#   sudo ./test_backup_borg.sh                  test all services
#   sudo ./test_backup_borg.sh --service <name> test one service
#   sudo ./test_backup_borg.sh --list           list services and archive counts
#
# For each service:
#   1. Checks the latest archive for integrity (borg check)
#   2. Stops the container
#   3. Moves live data aside   → <dir>.test-aside-TIMESTAMP
#   4. Extracts latest archive → <dir>
#   5. Compares file inventory: restored vs original (informational)
#   6. Rolls back: original data returns, container restarts
#   7. Reports PASS / FAIL
#
# PASS criteria:
#   • borg check exits 0 (no corruption)
#   • borg extract exits 0
#   • Restored directory is non-empty and contains docker-compose.yml
#
# Sends ntfy notification on completion if NTFY_URL / NTFY_TOPIC are set in backup.conf.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"
[ -f "$CONF" ] || { echo "Config not found: $CONF  (re-run: sudo setup.sh borg-backup)"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

[ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root: sudo $0"; exit 1; }
command -v borg >/dev/null 2>&1 || { echo "borg required: sudo apt install borgbackup"; exit 1; }

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="$ACTUAL_HOME/docker"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="/var/log/post-install-borg-test.log"

log()  { printf "[%s] %s\n"        "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
info() { printf "[%s] [INFO] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
pass() { printf "[%s] [PASS] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
fail() { printf "[%s] [FAIL] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }
warn() { printf "[%s] [WARN] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG"; }

repo_for()  { local v="DEST_${1}_REPO";       echo "${!v:-}"; }
pass_for()  { local v="DEST_${1}_PASSPHRASE"; echo "${!v:-}"; }
dest_for_svc() { local v="SVC_${1//-/_}"; echo "${!v:-${DEST_DEFAULT:-default}}"; }

b_for() {
    local dest="$1"; shift
    local repo; repo="$(repo_for "$dest")"
    local pass; pass="$(pass_for "$dest")"
    [ -n "$repo" ] || { log "Unknown destination: $dest"; return 1; }
    BORG_PASSPHRASE="$pass" BORG_REPO="$repo" "$BORG" "$@"
}

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
    added="$(comm -23 "$tmp_o" "$tmp_r" | wc -l)"
    deleted="$(comm -13 "$tmp_o" "$tmp_r" | wc -l)"
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
    printf "  %-20s  %-14s  %s\n" "SERVICE" "DESTINATION" "ARCHIVES"
    echo "  ──────────────────────────────────────────────────"
    declare -A _DEST_LISTS=()
    for _sv in "${SVCS_TO_TEST[@]}"; do
        dest="$(dest_for_svc "$_sv")"
        if [ -z "${_DEST_LISTS[$dest]+x}" ]; then
            _DEST_LISTS["$dest"]="$(b_for "$dest" list --format '{archive}{NL}' 2>/dev/null || echo '')"
        fi
        n="$(echo "${_DEST_LISTS[$dest]}" | grep -c "^${_sv}-" 2>/dev/null || echo '0')"
        printf "  %-20s  %-14s  %s\n" "$_sv" "$dest" "$n"
    done
    echo ""; exit 0
fi

# ── Pre-cache archive lists per destination ───────────────────────────────────
declare -A DEST_ARCHIVE_CACHE=()
for _sv in "${SVCS_TO_TEST[@]}"; do
    dest="$(dest_for_svc "$_sv")"
    if [ -z "${DEST_ARCHIVE_CACHE[$dest]+x}" ]; then
        _repo="$(repo_for "$dest")"
        if [ -n "$_repo" ]; then
            DEST_ARCHIVE_CACHE["$dest"]="$(b_for "$dest" list --format '{archive}{NL}' 2>/dev/null || echo '')"
        else
            DEST_ARCHIVE_CACHE["$dest"]=""
        fi
    fi
done

# ── Test run ──────────────────────────────────────────────────────────────────
log "===== Borg backup restore test starting (${#SVCS_TO_TEST[@]} service(s)) ====="
PASS_N=0; FAIL_N=0; SKIP_N=0
declare -a FAIL_LIST=()

for svc in "${SVCS_TO_TEST[@]}"; do
    svc_dir="${DOCKER_DIR}/${svc}"
    compose_file="${svc_dir}/docker-compose.yml"
    dest="$(dest_for_svc "$svc")"
    repo="$(repo_for "$dest")"

    if [ -z "$repo" ]; then
        info "SKIP $svc — destination '$dest' not configured"; SKIP_N=$((SKIP_N+1)); continue
    fi

    log "── Testing: $svc (dest: $dest)"

    # ── Find latest archive ──────────────────────────────────────────────────
    archive_list="${DEST_ARCHIVE_CACHE[$dest]:-}"
    latest_archive="$(echo "$archive_list" | grep "^${svc}-" | sort -r | head -1 || true)"

    if [ -z "${latest_archive:-}" ]; then
        warn "SKIP $svc — no archives found in destination '$dest'"; SKIP_N=$((SKIP_N+1)); continue
    fi

    archive_ts="${latest_archive#${svc}-}"
    info "$svc: latest archive ${archive_ts}  ($latest_archive)"

    # ── Step 1: Check archive integrity ─────────────────────────────────────
    info "$svc: checking archive integrity..."
    if ! b_for "$dest" check --archives-only "::$latest_archive" >/dev/null 2>&1; then
        fail "$svc: FAIL — borg check failed (archive may be corrupted)"
        FAIL_N=$((FAIL_N+1)); FAIL_LIST+=("$svc (archive corruption)"); continue
    fi
    info "$svc: archive check OK"

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

    # ── Step 4: Extract archive ──────────────────────────────────────────────
    # Borg archives absolute paths; extracting from / restores them in place.
    mkdir -p "$svc_dir"
    TEST_PASS=true; FAIL_REASON=""; RESTORED_FILES=0
    EXTRACT_PATH="${svc_dir#/}"
    if ( cd / && b_for "$dest" extract "::$latest_archive" "$EXTRACT_PATH" ) >/dev/null 2>&1; then
        RESTORED_FILES="$(find "$svc_dir" -type f 2>/dev/null | wc -l)"
    else
        TEST_PASS=false; FAIL_REASON="borg extract failed"
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
        pass "$svc: PASS  (archive: $archive_ts, restored $RESTORED_FILES file(s))"
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
    ntfy_send "Borg backup test passed (${PASS_N}/${TOTAL})" \
        "$(date '+%F %T') — All ${PASS_N} service(s) restore-tested OK. Log: $LOG" \
        "low" "white_check_mark,microscope"
    exit 0
else
    fail_str="$(IFS=', '; echo "${FAIL_LIST[*]}")"
    ntfy_send "Borg backup test FAILED (${FAIL_N}/${TOTAL} failed)" \
        "$(date '+%F %T') — FAILED: ${fail_str}. Log: $LOG" \
        "high" "rotating_light,microscope"
    exit 1
fi
