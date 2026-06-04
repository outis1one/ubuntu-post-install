#!/bin/bash
# extras/test_backup.sh — Verify a backup: restore latest snapshot, compare to live data.
# Installed alongside the backup worker by the backup service installers.
#
# Run as root:
#   sudo ./test_backup.sh                  pick service interactively
#   sudo ./test_backup.sh <service-name>   test specific service (most recent backup)
#   sudo ./test_backup.sh --list           list testable services and exit
#
# What it does:
#   1. Identifies the most recent backup for the chosen service
#   2. Stops the container briefly (so data is stable during comparison)
#   3. Moves live data aside — nothing is deleted until the test completes
#   4. Restores the backup into the original location
#   5. Compares restored data vs live data (content, not timestamps)
#   6. Moves live data back and restarts the container
#   7. Reports PASS/FAIL and sends ntfy notification if NTFY_URL is set
#
# PASS = restore succeeded (diff output is informational — files changed since backup are normal)
# FAIL = restore command failed or target was empty after restore
#
# Detects Kopia or Borg automatically from backup.conf.
# Requires: rsync, diff; plus jq (Kopia) or borg (Borg).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root: sudo $0"
[ -f "$CONF" ]                 || die "backup.conf not found: $CONF"
command -v rsync >/dev/null 2>&1 || die "rsync required — install: sudo apt install rsync"

# shellcheck source=/dev/null
source "$CONF"

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_BASE="$ACTUAL_HOME/docker"
HOST="$(hostname -s 2>/dev/null || hostname)"

# ── ntfy ───────────────────────────────────────────────────────────────────────
ntfy_send() {
    local title="$1" msg="$2" priority="${3:-default}" tags="${4:-}"
    [ -z "${NTFY_URL:-}" ] && return 0
    local -a _args=(-fsS -o /dev/null)
    _args+=(-H "Title: $title" -H "Priority: $priority")
    [ -n "$tags" ]           && _args+=(-H "Tags: $tags")
    [ -n "${NTFY_TOKEN:-}" ] && _args+=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl "${_args[@]}" -d "$msg" "$NTFY_URL" 2>/dev/null || true
}

# ── Detect backend ─────────────────────────────────────────────────────────────
if [ -n "${BORG:-}" ]; then
    BACKEND="borg"
    BORG_BIN="$BORG"
    command -v "$BORG_BIN" >/dev/null 2>&1 || die "borg not found at $BORG_BIN"
elif [ -n "${KOPIA:-}" ]; then
    BACKEND="kopia"
    KOPIA_BIN="$KOPIA"
    command -v jq >/dev/null 2>&1 || die "jq required — install: sudo apt install jq"
else
    die "Cannot detect backup backend — backup.conf must set KOPIA= or BORG="
fi

# ── Normalise Kopia single-dest (gaming) → multi-dest format ──────────────────
if [ "$BACKEND" = "kopia" ] && [ -z "${DEST_NAMES:-}" ]; then
    DEST_NAMES="default"
    DEST_default_CONFIG="${KOPIA_CONFIG:-}"
    DEST_default_PASSWORD="${KOPIA_PASSWORD:-}"
fi

# ── Destination picker (skipped for single dest) ───────────────────────────────
read -ra _DEST_ARR <<< "${DEST_NAMES:-default}"

if [ "${#_DEST_ARR[@]}" -gt 1 ]; then
    echo ""
    echo "Select backup destination:"
    echo ""
    for i in "${!_DEST_ARR[@]}"; do
        printf "  %d)  %s\n" "$((i+1))" "${_DEST_ARR[$i]}"
    done
    echo ""
    read -rp "Destination [1-${#_DEST_ARR[@]}]: " _DEST_SEL
    [[ "$_DEST_SEL" =~ ^[0-9]+$ ]] && [ "$_DEST_SEL" -ge 1 ] && [ "$_DEST_SEL" -le "${#_DEST_ARR[@]}" ] \
        || die "Invalid selection"
    ACTIVE_DEST="${_DEST_ARR[$((_DEST_SEL-1))]}"
else
    ACTIVE_DEST="${_DEST_ARR[0]}"
fi

# ── Connect to backend ─────────────────────────────────────────────────────────
if [ "$BACKEND" = "kopia" ]; then
    _CFG_VAR="DEST_${ACTIVE_DEST}_CONFIG"
    _PW_VAR="DEST_${ACTIVE_DEST}_PASSWORD"
    K_CFG="${!_CFG_VAR:-}"
    K_PW="${!_PW_VAR:-}"
    [ -n "$K_CFG" ] || die "No Kopia config found for destination '$ACTIVE_DEST'"
    export KOPIA_PASSWORD="$K_PW"
    k() { "$KOPIA_BIN" --config-file="$K_CFG" "$@"; }
    k repository status >/dev/null 2>&1 \
        || die "Cannot connect to Kopia repo '$ACTIVE_DEST' — check backup.conf"
else
    _REPO_VAR="DEST_${ACTIVE_DEST}_REPO"
    _PASS_VAR="DEST_${ACTIVE_DEST}_PASSPHRASE"
    export BORG_REPO="${!_REPO_VAR:-}"
    export BORG_PASSPHRASE="${!_PASS_VAR:-}"
    [ -n "$BORG_REPO" ] || die "No Borg repo found for destination '$ACTIVE_DEST'"
    b() { "$BORG_BIN" "$@"; }
    b info >/dev/null 2>&1 \
        || die "Cannot connect to Borg repo at $BORG_REPO — check backup.conf"
fi

# ── Build list of testable services ───────────────────────────────────────────
declare -a SERVICES=()
declare -A SVC_SNAP_SRC=()   # service name → backup source path
SNAP_JSON=""

if [ "$BACKEND" = "kopia" ]; then
    SNAP_JSON=$(k snapshot list --all --json 2>/dev/null)
    [ -z "$SNAP_JSON" ] || [ "$SNAP_JSON" = "[]" ] || [ "$SNAP_JSON" = "null" ] \
        && die "No snapshots found. Run a backup first."
    while IFS= read -r src_path; do
        [[ "$src_path" == "$DOCKER_BASE/"* ]] || continue
        rel="${src_path#"$DOCKER_BASE/"}"
        svc="${rel%%/*}"
        [[ "$svc" == "backup" || "$svc" == "borg-backup" || "$svc" == "gaming-backup" ]] && continue
        _already=false
        for _s in "${SERVICES[@]+"${SERVICES[@]}"}"; do [ "$_s" = "$svc" ] && _already=true && break; done
        if [ "$_already" = false ]; then
            SERVICES+=("$svc")
            SVC_SNAP_SRC["$svc"]="$src_path"
        fi
    done < <(echo "$SNAP_JSON" | jq -r 'group_by(.source.path)[] | .[0].source.path')
else
    _seen=""
    while IFS= read -r arch; do
        svc="${arch%-[0-9][0-9][0-9][0-9]-*}"
        [[ "$svc" == "backup" || "$svc" == "borg-backup" || "$svc" == "gaming-backup" ]] && continue
        [ -z "$svc" ] && continue
        [[ "$_seen" == *"|${svc}|"* ]] && continue
        _seen+="|${svc}|"
        SERVICES+=("$svc")
    done < <(b list --format '{archive}{NL}' 2>/dev/null | sort)
fi

[ "${#SERVICES[@]}" -eq 0 ] && die "No backed-up services found. Run a backup first."

# ── --list ─────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
    echo ""
    info "Testable services (dest: $ACTIVE_DEST, backend: $BACKEND):"
    echo ""
    for svc in "${SERVICES[@]}"; do printf "  • %s\n" "$svc"; done
    echo ""
    exit 0
fi

# ── Service selection ──────────────────────────────────────────────────────────
SELECTED_SVC=""
if [ -n "${1:-}" ] && [ "${1:-}" != "--list" ]; then
    SELECTED_SVC="${1:-}"
    _found=false
    for _s in "${SERVICES[@]}"; do [ "$_s" = "$SELECTED_SVC" ] && _found=true && break; done
    [ "$_found" = true ] || die "Service '$SELECTED_SVC' has no backups. Use --list."
else
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Backup Verification Test                            ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    info "Destination: $ACTIVE_DEST  (backend: $BACKEND)"
    echo ""
    echo "Services with backups:"
    echo ""
    for i in "${!SERVICES[@]}"; do
        printf "  %2d)  %s\n" "$((i+1))" "${SERVICES[$i]}"
    done
    echo ""
    read -rp "Select service [1-${#SERVICES[@]}] or q to quit: " SEL
    [[ "$SEL" =~ ^[qQ]$ ]] && echo "Cancelled." && exit 0
    [[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#SERVICES[@]}" ] \
        || die "Invalid selection: $SEL"
    SELECTED_SVC="${SERVICES[$((SEL-1))]}"
fi
ok "Testing service: $SELECTED_SVC"

# ── Find most recent backup ────────────────────────────────────────────────────
SNAP_ID="" SNAP_DESC="" ARCHIVE_NAME="" SOURCE_PATH=""

if [ "$BACKEND" = "kopia" ]; then
    SOURCE_PATH="${SVC_SNAP_SRC[$SELECTED_SVC]:-$DOCKER_BASE/$SELECTED_SVC}"
    SNAP_ID=$(echo "$SNAP_JSON" | jq -r --arg p "$SOURCE_PATH" \
        '[.[] | select(.source.path == $p)] | sort_by(.startTime) | last | .id // empty')
    SNAP_DESC=$(echo "$SNAP_JSON" | jq -r --arg p "$SOURCE_PATH" \
        '[.[] | select(.source.path == $p)] | sort_by(.startTime) | last |
         .startTime | split("T") | "\(.[0]) \(.[1][:8]) UTC"' 2>/dev/null || echo "unknown")
    [ -n "$SNAP_ID" ] || die "No Kopia snapshot for '$SELECTED_SVC' at $SOURCE_PATH"
else
    SOURCE_PATH="$DOCKER_BASE/$SELECTED_SVC"
    ARCHIVE_NAME=$(b list --format '{archive}{NL}' 2>/dev/null \
        | grep "^${SELECTED_SVC}-" | sort | tail -1)
    [ -n "$ARCHIVE_NAME" ] || die "No Borg archive found for '$SELECTED_SVC'"
    SNAP_DESC="${ARCHIVE_NAME#"${SELECTED_SVC}-"}"
fi
info "Most recent backup: $SNAP_DESC"

# ── Resolve paths ──────────────────────────────────────────────────────────────
# TARGET_DIR = the exact path that was backed up (may be a sub-path for gaming)
# SVC_DIR    = top-level docker service dir (for container stop/start)
TARGET_DIR="$SOURCE_PATH"
SVC_DIR="$DOCKER_BASE/$SELECTED_SVC"
COMPOSE_FILE="$SVC_DIR/docker-compose.yml"

TS="$(date +%Y%m%d-%H%M%S)"
ASIDE_DIR="${TARGET_DIR}.test-aside-${TS}"
ERR_LOG="$(mktemp)"
STOPPED=false

# ── Cleanup trap — always restores live data ───────────────────────────────────
cleanup() {
    rm -f "$ERR_LOG" 2>/dev/null || true
    if [ -d "$ASIDE_DIR" ]; then
        warn "Restoring live data from aside copy..."
        rm -rf "$TARGET_DIR" 2>/dev/null || true
        mv "$ASIDE_DIR" "$TARGET_DIR"
        ok "Live data restored to $TARGET_DIR"
    fi
    if [ "$STOPPED" = true ] && [ -f "$COMPOSE_FILE" ]; then
        info "Restarting $SELECTED_SVC..."
        docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null \
            && ok "$SELECTED_SVC restarted." \
            || warn "Auto-restart failed — run: docker compose -f $COMPOSE_FILE up -d"
    fi
}
trap cleanup EXIT

echo ""
warn "This test will briefly stop '$SELECTED_SVC', move its data aside, restore"
warn "from the most recent backup, compare, then move everything back."
echo ""
read -rp "Proceed? (y/N): " _CONFIRM
[[ "$_CONFIRM" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ── Stop container ─────────────────────────────────────────────────────────────
if [ -f "$COMPOSE_FILE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SELECTED_SVC"; then
    info "Stopping $SELECTED_SVC..."
    docker compose -f "$COMPOSE_FILE" down 2>/dev/null \
        || docker stop "$SELECTED_SVC" 2>/dev/null \
        || warn "Could not stop container — data may be inconsistent."
    STOPPED=true
    ok "$SELECTED_SVC stopped."
fi

# ── Move live data aside ───────────────────────────────────────────────────────
if [ -e "$TARGET_DIR" ]; then
    info "Moving live data aside → $(basename "$ASIDE_DIR") ..."
    mv "$TARGET_DIR" "$ASIDE_DIR"
    ok "Live data saved at: $ASIDE_DIR"
else
    warn "$TARGET_DIR not found — testing fresh restore (no live data to compare)."
fi

# ── Restore from backup ────────────────────────────────────────────────────────
mkdir -p "$TARGET_DIR"
info "Restoring from backup..."

if [ "$BACKEND" = "kopia" ]; then
    if ! k restore "$SNAP_ID" "$TARGET_DIR" 2>"$ERR_LOG"; then
        FAIL_MSG="Restore failed: $(head -3 "$ERR_LOG" | tr '\n' ' ')"
        err "$FAIL_MSG"
        ntfy_send "✗ Backup test FAILED: $SELECTED_SVC" "$HOST\n$FAIL_MSG" \
            "urgent" "rotating_light"
        exit 1
    fi
else
    EXTRACT_PATH="${SOURCE_PATH#/}"
    if ! ( cd / && b extract "$BORG_REPO::$ARCHIVE_NAME" "$EXTRACT_PATH" 2>"$ERR_LOG" ); then
        FAIL_MSG="Restore failed: $(head -3 "$ERR_LOG" | tr '\n' ' ')"
        err "$FAIL_MSG"
        ntfy_send "✗ Backup test FAILED: $SELECTED_SVC" "$HOST\n$FAIL_MSG" \
            "urgent" "rotating_light"
        exit 1
    fi
fi
ok "Restore complete."

# Sanity check — something must have been restored
RESTORED_COUNT=$(find "$TARGET_DIR" -mindepth 1 -maxdepth 2 2>/dev/null | wc -l)
if [ "$RESTORED_COUNT" -eq 0 ]; then
    FAIL_MSG="Restore succeeded but target directory is empty"
    err "$FAIL_MSG"
    ntfy_send "✗ Backup test FAILED: $SELECTED_SVC" "$HOST\n$FAIL_MSG" \
        "urgent" "rotating_light"
    exit 1
fi

# ── Compare restored vs live data ─────────────────────────────────────────────
DIFF_COUNT=0
DIFF_SAMPLE=""

if [ -d "$ASIDE_DIR" ]; then
    info "Comparing restored vs live data (content, not timestamps)..."
    DIFF_OUT="$(diff -rq "$ASIDE_DIR" "$TARGET_DIR" 2>/dev/null || true)"
    DIFF_COUNT=$(printf '%s' "$DIFF_OUT" | grep -c '^' 2>/dev/null || echo 0)

    if [ "$DIFF_COUNT" -eq 0 ]; then
        ok "Perfect match — restored data is identical to live data."
    else
        DIFF_SAMPLE="$(printf '%s' "$DIFF_OUT" | head -10)"
        warn "$DIFF_COUNT file(s) differ between backup and live data."
        warn "(Normal — these files changed between the last backup and now.)"
        echo ""
        echo "  Files changed since last backup (up to 10):"
        printf '%s\n' "$DIFF_SAMPLE" | while IFS= read -r line; do echo "    $line"; done
        [ "$DIFF_COUNT" -gt 10 ] && echo "    ... and $((DIFF_COUNT - 10)) more"
    fi
else
    warn "No live data to compare. Restored $RESTORED_COUNT item(s) from backup."
fi

# ── Result ─────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
if [ "$DIFF_COUNT" -eq 0 ]; then
    echo "  BACKUP TEST PASSED ✓  (perfect match)"
else
    echo "  BACKUP TEST PASSED ✓  ($DIFF_COUNT file(s) changed since last backup)"
fi
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Service  : $SELECTED_SVC"
echo "  Backend  : $BACKEND"
echo "  Backup   : $SNAP_DESC"
echo "  Restored : $RESTORED_COUNT item(s)"
[ "$DIFF_COUNT" -gt 0 ] && echo "  Changed  : $DIFF_COUNT file(s) modified since last backup (normal)"
echo ""

if [ "$DIFF_COUNT" -eq 0 ]; then
    ntfy_send "✓ Backup test PASSED: $SELECTED_SVC" \
        "$HOST: $SELECTED_SVC backup verified — perfect match (${RESTORED_COUNT} items)" \
        "low" "white_check_mark"
else
    ntfy_send "✓ Backup test PASSED: $SELECTED_SVC" \
        "$HOST: $SELECTED_SVC backup OK — ${DIFF_COUNT} file(s) changed since last backup" \
        "default" "white_check_mark"
fi

# cleanup trap handles data restoration and container restart
