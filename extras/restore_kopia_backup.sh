#!/bin/bash
# extras/restore_kopia_backup.sh — interactive restore from a Kopia snapshot.
# Installed to ~/docker/backup/ by the backup service installer.
#
# Run as root:
#   sudo ./restore_kopia_backup.sh          interactive
#   sudo ./restore_kopia_backup.sh --list   list all snapshot sources and exit
#
# Reads backup.conf from the same directory. The repository password is stored
# there (chmod 600, root-only) — no password prompt needed.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="${BACKUP_CONF:-$HERE/backup.conf}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
[ "${EUID:-$(id -u)}" -eq 0 ] || die "Run as root: sudo $0"
[ -f "$CONF" ]                 || die "backup.conf not found: $CONF  (run: sudo setup.sh backup)"
command -v jq >/dev/null 2>&1  || die "jq is required — install it: sudo apt install jq"

# shellcheck source=/dev/null
source "$CONF"
export KOPIA_PASSWORD

command -v "$KOPIA" >/dev/null 2>&1 || die "Kopia not found: $KOPIA"
k() { "$KOPIA" --config-file="$KOPIA_CONFIG" "$@"; }
k repository status >/dev/null 2>&1 || die "Cannot connect to Kopia repository. Check backup.conf."

# ── Derive Docker dir (mirrors lib/common.sh logic) ───────────────────────────
ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_BASE="$ACTUAL_HOME/docker"

# ── Snapshot helpers ──────────────────────────────────────────────────────────
all_snapshots_json() {
    k snapshot list --all --json 2>/dev/null
}

# Given a source path like ~/docker/minecraft/data, return "service_name /path/to/compose.yml"
# or empty string if not a Docker service.
docker_info_for_path() {
    local path="$1"
    [[ "$path" == "$DOCKER_BASE"/* ]] || return 0
    local relative="${path#$DOCKER_BASE/}"
    local service="${relative%%/*}"
    local compose="$DOCKER_BASE/$service/docker-compose.yml"
    [ -f "$compose" ] && echo "$service $compose"
}

# ── --list ────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
    echo ""
    info "Loading snapshots..."
    JSON=$(all_snapshots_json)
    echo ""
    echo "Backup sources:"
    echo ""
    echo "$JSON" | jq -r '
        group_by(.source.path)[] |
        (.[0].source.path) as $p |
        (.[0].description // "-") as $d |
        (.[0].startTime | split("T") | "\(.[0]) \(.[1][:8]) UTC") as $t |
        (length | tostring) as $n |
        "\($p)\n    \($d)  |  latest: \($t)  |  \($n) snapshot(s)\n"
    '
    exit 0
fi

# ── Interactive restore ───────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Kopia Backup Restore                                ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

info "Loading snapshot index..."
SNAP_JSON=$(all_snapshots_json)

[ -z "$SNAP_JSON" ] || [ "$SNAP_JSON" = "[]" ] || [ "$SNAP_JSON" = "null" ] \
    && die "No snapshots found. Run a backup first: sudo $HERE/backup.sh"

# Build source arrays (newest-first per source)
mapfile -t SRC_PATHS  < <(echo "$SNAP_JSON" | jq -r 'group_by(.source.path)[] | .[0].source.path')
mapfile -t SRC_DESCS  < <(echo "$SNAP_JSON" | jq -r 'group_by(.source.path)[] | .[0].description // "-"')
mapfile -t SRC_LATEST < <(echo "$SNAP_JSON" | jq -r 'group_by(.source.path)[] | .[0].startTime | split("T") | "\(.[0]) \(.[1][:8])"')
mapfile -t SRC_COUNTS < <(echo "$SNAP_JSON" | jq -r 'group_by(.source.path)[] | length')

[ "${#SRC_PATHS[@]}" -eq 0 ] && die "No snapshot sources found."

echo "What do you want to restore?"
echo ""
for i in "${!SRC_PATHS[@]}"; do
    printf "  %2d)  %s\n       %s  |  latest: %s  |  %s snapshots\n\n" \
        "$((i+1))" "${SRC_PATHS[$i]}" "${SRC_DESCS[$i]}" \
        "${SRC_LATEST[$i]}" "${SRC_COUNTS[$i]}"
done

read -rp "Select source [1-${#SRC_PATHS[@]}] or q to quit: " SEL
[[ "$SEL" =~ ^[qQ]$ ]] && echo "Cancelled." && exit 0
[[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#SRC_PATHS[@]}" ] \
    || die "Invalid selection: $SEL"

SOURCE_PATH="${SRC_PATHS[$((SEL-1))]}"
echo ""
ok "Source: $SOURCE_PATH"

# ── Pick a snapshot ───────────────────────────────────────────────────────────
echo ""
echo "Available snapshots (most recent first):"
echo ""

mapfile -t SNAP_IDS   < <(echo "$SNAP_JSON" | jq -r --arg p "$SOURCE_PATH" '
    [.[] | select(.source.path == $p)] | sort_by(.startTime) | reverse | .[0:15] | .[].id')
mapfile -t SNAP_TIMES < <(echo "$SNAP_JSON" | jq -r --arg p "$SOURCE_PATH" '
    [.[] | select(.source.path == $p)] | sort_by(.startTime) | reverse | .[0:15] |
    .[].startTime | split("T") | "\(.[0]) \(.[1][:8]) UTC"')

[ "${#SNAP_IDS[@]}" -eq 0 ] && die "No snapshots found for that source."

for i in "${!SNAP_IDS[@]}"; do
    note=""; [ "$i" -eq 0 ] && note="  ← latest"
    printf "  %2d)  %s  (id: %s...)%s\n" \
        "$((i+1))" "${SNAP_TIMES[$i]}" "${SNAP_IDS[$i]:0:12}" "$note"
done

echo ""
read -rp "Select snapshot [1-${#SNAP_IDS[@]}, Enter = latest]: " SNAP_SEL
SNAP_SEL="${SNAP_SEL:-1}"
[[ "$SNAP_SEL" =~ ^[0-9]+$ ]] && [ "$SNAP_SEL" -ge 1 ] && [ "$SNAP_SEL" -le "${#SNAP_IDS[@]}" ] \
    || die "Invalid selection: $SNAP_SEL"

SNAPSHOT_ID="${SNAP_IDS[$((SNAP_SEL-1))]}"
SNAPSHOT_TIME="${SNAP_TIMES[$((SNAP_SEL-1))]}"
echo ""
ok "Snapshot: $SNAPSHOT_TIME  (id: ${SNAPSHOT_ID:0:16}...)"

# ── Choose restore mode ───────────────────────────────────────────────────────
echo ""
echo "Restore mode:"
echo ""
echo "  1) Inspect — restore to /tmp so you can browse files without touching anything live"
echo "  2) Restore — move current data aside, restore snapshot in its place"
echo "               old data kept as .pre-restore-DATE (easy rollback)"
echo ""
read -rp "Select [1/2] or q to quit: " MODE
[[ "$MODE" =~ ^[qQ]$ ]] && echo "Cancelled." && exit 0

case "$MODE" in

# ── Inspect: restore to /tmp, nothing touched ─────────────────────────────────
1)
    TEMP_DIR="/tmp/kopia-inspect-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$TEMP_DIR"
    echo ""
    info "Restoring snapshot to $TEMP_DIR (nothing live is changed)..."
    if k restore "$SNAPSHOT_ID" "$TEMP_DIR"; then
        echo ""
        ok "Done. Browse the restored files:"
        echo ""
        echo "    ls -la $TEMP_DIR"
        echo ""
        echo "  When finished:"
        echo "    rm -rf $TEMP_DIR"
    else
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        die "Restore failed — no changes were made."
    fi
    ;;

# ── Restore in place: move aside, restore, offer rollback instructions ─────────
2)
    SINFO=$(docker_info_for_path "$SOURCE_PATH")
    SVC_NAME="${SINFO%% *}"
    COMPOSE_FILE="${SINFO##* }"
    # If no match, both vars will be empty or equal
    [ "$SVC_NAME" = "$COMPOSE_FILE" ] && SVC_NAME="" && COMPOSE_FILE=""

    # Stop associated Docker service if running
    STOPPED=false
    if [ -n "$SVC_NAME" ] && [ -n "$COMPOSE_FILE" ] \
       && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SVC_NAME"; then
        echo ""
        warn "Container '$SVC_NAME' is currently running."
        read -rp "  Stop it before restoring? Recommended to avoid data corruption. (Y/n): " STOP_YN
        if [[ ! "$STOP_YN" =~ ^[Nn]$ ]]; then
            info "Stopping $SVC_NAME..."
            docker compose -f "$COMPOSE_FILE" down 2>/dev/null \
                || docker stop "$SVC_NAME" 2>/dev/null \
                || warn "Could not stop $SVC_NAME — continuing anyway."
            STOPPED=true
            ok "$SVC_NAME stopped."
        else
            warn "Restoring with $SVC_NAME running — consistency not guaranteed."
        fi
    fi

    # Move current data aside
    ASIDE="${SOURCE_PATH}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    echo ""
    if [ -e "$SOURCE_PATH" ]; then
        info "Moving current data aside → $(basename "$ASIDE")"
        mv "$SOURCE_PATH" "$ASIDE"
        ok "Current data saved at: $ASIDE"
    else
        warn "Source path doesn't exist yet: $SOURCE_PATH — restoring fresh."
    fi

    # Restore snapshot
    mkdir -p "$SOURCE_PATH"
    info "Restoring $SNAPSHOT_TIME → $SOURCE_PATH ..."
    if k restore "$SNAPSHOT_ID" "$SOURCE_PATH"; then
        ok "Restore complete."
    else
        err "Restore failed — rolling back to original data."
        rm -rf "$SOURCE_PATH" 2>/dev/null || true
        if [ -e "$ASIDE" ]; then
            mv "$ASIDE" "$SOURCE_PATH"
            ok "Original data recovered from aside copy."
        fi
        if [ "$STOPPED" = true ] && [ -n "$COMPOSE_FILE" ]; then
            docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true
        fi
        exit 1
    fi

    # Restart container
    if [ "$STOPPED" = true ] && [ -n "$COMPOSE_FILE" ]; then
        echo ""
        read -rp "  Start '$SVC_NAME' now? (Y/n): " START_YN
        if [[ ! "$START_YN" =~ ^[Nn]$ ]]; then
            info "Starting $SVC_NAME..."
            docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null \
                && ok "$SVC_NAME started." \
                || warn "Start failed — check: docker compose -f $COMPOSE_FILE logs"
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  RESTORE COMPLETE"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Restored from : $SNAPSHOT_TIME"
    echo "  Restored to   : $SOURCE_PATH"
    [ -e "$ASIDE" ] && echo "  Previous data  : $ASIDE"
    echo ""
    echo "  Verify your data, then:"
    echo ""
    if [ -e "$ASIDE" ]; then
        echo "    Keep the restore (delete aside copy when satisfied):"
        echo "      rm -rf \"$ASIDE\""
        echo ""
        echo "    Roll back to previous data:"
        [ -n "$COMPOSE_FILE" ] && echo "      docker compose -f $COMPOSE_FILE down"
        echo "      rm -rf \"$SOURCE_PATH\""
        echo "      mv \"$ASIDE\" \"$SOURCE_PATH\""
        [ -n "$COMPOSE_FILE" ] && echo "      docker compose -f $COMPOSE_FILE up -d"
    fi
    echo ""
    ;;

*)
    echo "Cancelled."
    exit 0
    ;;
esac
