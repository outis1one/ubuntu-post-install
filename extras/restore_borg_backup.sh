#!/bin/bash
# extras/restore_borg_backup.sh — interactive restore from a Borg archive.
# Installed to ~/docker/borg-backup/restore/<dest>/ by the borg-backup installer.
#
# Run as root:
#   sudo ./restore_borg_backup.sh          interactive
#   sudo ./restore_borg_backup.sh --list   list all archives and exit
#
# Reads backup.conf from the same directory (chmod 600, root-only).
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
[ -f "$CONF" ]                 || die "backup.conf not found: $CONF  (run: sudo setup.sh borg-backup)"
command -v borg >/dev/null 2>&1 || die "borg not found — install: sudo apt install borgbackup"

# shellcheck source=/dev/null
source "$CONF"
export BORG_PASSPHRASE BORG_REPO
b() { borg "$@"; }

b info 2>/dev/null | grep -q "Repository" \
    || die "Cannot connect to Borg repository at $BORG_REPO — check backup.conf."

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_BASE="$ACTUAL_HOME/docker"

# ── List all archives ──────────────────────────────────────────────────────────
list_archives() {
    b list --format '{archive}{NL}' 2>/dev/null
}

# ── --list ────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
    echo ""
    info "Archives in $BORG_REPO:"
    echo ""
    b list 2>/dev/null | sort -t- -k2 -r
    echo ""
    exit 0
fi

# ── Interactive restore ───────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Borg Backup Restore                                 ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

info "Loading archive list from $BORG_REPO ..."
ARCHIVE_LIST=$(list_archives)
[ -z "$ARCHIVE_LIST" ] && die "No archives found. Run a backup first: sudo ~/docker/borg-backup/borg-backup.sh"

# ── Group archives by service prefix (everything before the first timestamp) ──
# Archive names: <service>-YYYY-MM-DDTHH-MM-SS
# Extract unique service prefixes.
mapfile -t SERVICES < <(echo "$ARCHIVE_LIST" | sed 's/-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T.*//' | sort -u)

echo "Backed-up services:"
echo ""
for i in "${!SERVICES[@]}"; do
    svc="${SERVICES[$i]}"
    latest=$(echo "$ARCHIVE_LIST" | grep "^${svc}-" | sort | tail -1)
    count=$(echo "$ARCHIVE_LIST" | grep -c "^${svc}-")
    printf "  %2d)  %-28s  latest: %s  |  %s archive(s)\n" \
        "$((i+1))" "$svc" "${latest#${svc}-}" "$count"
done
echo ""

read -rp "Select service [1-${#SERVICES[@]}] or q to quit: " SEL
[[ "$SEL" =~ ^[qQ]$ ]] && echo "Cancelled." && exit 0
[[ "$SEL" =~ ^[0-9]+$ ]] && [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#SERVICES[@]}" ] \
    || die "Invalid selection: $SEL"

SELECTED_SVC="${SERVICES[$((SEL-1))]}"
ok "Service: $SELECTED_SVC"

# ── Pick an archive for that service ─────────────────────────────────────────
echo ""
echo "Available archives (most recent first):"
echo ""

mapfile -t ARCHIVES < <(echo "$ARCHIVE_LIST" | grep "^${SELECTED_SVC}-" | sort -r | head -20)
[ "${#ARCHIVES[@]}" -eq 0 ] && die "No archives found for $SELECTED_SVC."

for i in "${!ARCHIVES[@]}"; do
    note=""; [ "$i" -eq 0 ] && note="  ← latest"
    # Parse timestamp from archive name: svc-YYYY-MM-DDTHH-MM-SS
    ts="${ARCHIVES[$i]#${SELECTED_SVC}-}"
    printf "  %2d)  %s%s\n" "$((i+1))" "$ts" "$note"
done
echo ""

read -rp "Select archive [1-${#ARCHIVES[@]}, Enter = latest]: " ARCH_SEL
ARCH_SEL="${ARCH_SEL:-1}"
[[ "$ARCH_SEL" =~ ^[0-9]+$ ]] && [ "$ARCH_SEL" -ge 1 ] && [ "$ARCH_SEL" -le "${#ARCHIVES[@]}" ] \
    || die "Invalid selection: $ARCH_SEL"

SELECTED_ARCHIVE="${ARCHIVES[$((ARCH_SEL-1))]}"
ok "Archive: $SELECTED_ARCHIVE"

# ── Determine the Docker service directory ────────────────────────────────────
# Archive contains the full absolute path: home/user/docker/svc/ (without leading /)
# Derive expected restore target.
TARGET_DIR="$DOCKER_BASE/$SELECTED_SVC"

# ── Choose restore mode ───────────────────────────────────────────────────────
echo ""
echo "Restore mode:"
echo ""
echo "  1) Inspect — extract to /tmp so you can browse without touching live data"
echo "  2) Restore — move current data aside, restore archive in its place"
echo "               old data kept as .pre-restore-DATE (easy rollback)"
echo ""
read -rp "Select [1/2] or q to quit: " MODE
[[ "$MODE" =~ ^[qQ]$ ]] && echo "Cancelled." && exit 0

case "$MODE" in

# ── Inspect: extract to /tmp ──────────────────────────────────────────────────
1)
    TEMP_DIR="/tmp/borg-inspect-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$TEMP_DIR"
    echo ""
    info "Extracting $SELECTED_ARCHIVE to $TEMP_DIR (nothing live is changed)..."
    # borg extract strips leading / — run from TEMP_DIR
    if ( cd "$TEMP_DIR" && b extract --progress "$BORG_REPO::$SELECTED_ARCHIVE" ); then
        echo ""
        ok "Done. Browse the extracted files:"
        echo ""
        echo "    ls -la $TEMP_DIR"
        echo ""
        echo "  The service directory will be under: $TEMP_DIR${TARGET_DIR}"
        echo ""
        echo "  When finished:"
        echo "    rm -rf $TEMP_DIR"
    else
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        die "Extraction failed — no changes were made."
    fi
    ;;

# ── Restore in place ──────────────────────────────────────────────────────────
2)
    COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"

    STOPPED=false
    if [ -f "$COMPOSE_FILE" ] \
       && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SELECTED_SVC"; then
        echo ""
        warn "Container '$SELECTED_SVC' is currently running."
        read -rp "  Stop it before restoring? Recommended to avoid corruption. (Y/n): " STOP_YN
        if [[ ! "$STOP_YN" =~ ^[Nn]$ ]]; then
            info "Stopping $SELECTED_SVC..."
            docker compose -f "$COMPOSE_FILE" down 2>/dev/null \
                || docker stop "$SELECTED_SVC" 2>/dev/null \
                || warn "Could not stop $SELECTED_SVC — continuing anyway."
            STOPPED=true
            ok "$SELECTED_SVC stopped."
        else
            warn "Restoring with $SELECTED_SVC running — consistency not guaranteed."
        fi
    fi

    # Move current data aside
    ASIDE="${TARGET_DIR}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    echo ""
    if [ -e "$TARGET_DIR" ]; then
        info "Moving current data aside → $(basename "$ASIDE")"
        mv "$TARGET_DIR" "$ASIDE"
        ok "Current data saved at: $ASIDE"
    else
        warn "$TARGET_DIR does not exist — restoring fresh."
    fi

    # borg extract strips leading /: run from / to restore to original absolute path
    mkdir -p "$TARGET_DIR"
    info "Restoring $SELECTED_ARCHIVE → $TARGET_DIR ..."
    # Extract only the service subdirectory to keep things scoped
    EXTRACT_PATH="${TARGET_DIR#/}"   # strip leading / for borg
    if ( cd / && b extract --progress "$BORG_REPO::$SELECTED_ARCHIVE" "$EXTRACT_PATH" ); then
        ok "Restore complete."
    else
        err "Restore failed — rolling back to original data."
        rm -rf "$TARGET_DIR" 2>/dev/null || true
        if [ -e "$ASIDE" ]; then
            mv "$ASIDE" "$TARGET_DIR"
            ok "Original data recovered from aside copy."
        fi
        if [ "$STOPPED" = true ] && [ -f "$COMPOSE_FILE" ]; then
            docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null || true
        fi
        exit 1
    fi

    # Restart container
    if [ "$STOPPED" = true ] && [ -f "$COMPOSE_FILE" ]; then
        echo ""
        read -rp "  Start '$SELECTED_SVC' now? (Y/n): " START_YN
        if [[ ! "$START_YN" =~ ^[Nn]$ ]]; then
            info "Starting $SELECTED_SVC..."
            docker compose -f "$COMPOSE_FILE" up -d 2>/dev/null \
                && ok "$SELECTED_SVC started." \
                || warn "Start failed — check: docker compose -f $COMPOSE_FILE logs"
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  RESTORE COMPLETE"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Restored from : $SELECTED_ARCHIVE"
    echo "  Restored to   : $TARGET_DIR"
    [ -e "$ASIDE" ] && echo "  Previous data  : $ASIDE"
    echo ""
    echo "  Verify your data, then:"
    echo ""
    if [ -e "$ASIDE" ]; then
        echo "    Keep the restore (delete aside copy when satisfied):"
        echo "      rm -rf \"$ASIDE\""
        echo ""
        echo "    Roll back to previous data:"
        [ -f "$COMPOSE_FILE" ] && echo "      docker compose -f $COMPOSE_FILE down"
        echo "      rm -rf \"$TARGET_DIR\""
        echo "      mv \"$ASIDE\" \"$TARGET_DIR\""
        [ -f "$COMPOSE_FILE" ] && echo "      docker compose -f $COMPOSE_FILE up -d"
    fi
    echo ""
    ;;

*)
    echo "Cancelled."
    exit 0
    ;;
esac
