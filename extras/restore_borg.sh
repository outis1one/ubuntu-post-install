#!/bin/bash
# extras/restore_borg.sh — interactive restore from a Borg archive.
# Installed to ~/docker/borg-backup/restore_borg.sh by the borg-backup installer.
#
# Run as root:
#   sudo ./restore_borg.sh          interactive
#   sudo ./restore_borg.sh --list   list all archives and exit
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
[ -f "$CONF" ]                 || die "backup.conf not found: $CONF"
command -v borg >/dev/null 2>&1 || die "borg not found — install: sudo apt install borgbackup"

# shellcheck source=/dev/null
source "$CONF"

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_BASE="$ACTUAL_HOME/docker"

# ── Destination picker (skipped when only one dest) ───────────────────────────
read -ra _DEST_ARR <<< "${DEST_NAMES:-default}"

if [ "${#_DEST_ARR[@]}" -gt 1 ]; then
    echo ""
    echo "Select backup destination:"
    echo ""
    for i in "${!_DEST_ARR[@]}"; do
        _repo_var="DEST_${_DEST_ARR[$i]}_REPO"
        printf "  %d)  %s  (%s)\n" "$((i+1))" "${_DEST_ARR[$i]}" "${!_repo_var:-unknown}"
    done
    echo ""
    read -rp "Destination [1-${#_DEST_ARR[@]}]: " _DEST_SEL
    [[ "$_DEST_SEL" =~ ^[0-9]+$ ]] && [ "$_DEST_SEL" -ge 1 ] && [ "$_DEST_SEL" -le "${#_DEST_ARR[@]}" ] \
        || die "Invalid selection"
    ACTIVE_DEST="${_DEST_ARR[$((_DEST_SEL-1))]}"
else
    ACTIVE_DEST="${_DEST_ARR[0]}"
fi

_REPO_VAR="DEST_${ACTIVE_DEST}_REPO"
_PASS_VAR="DEST_${ACTIVE_DEST}_PASSPHRASE"
export BORG_REPO="${!_REPO_VAR:-}"
export BORG_PASSPHRASE="${!_PASS_VAR:-}"
[ -n "$BORG_REPO" ] || die "No BORG_REPO found for destination '$ACTIVE_DEST'"

b() { borg "$@"; }
b info 2>/dev/null | grep -q "Repository" \
    || die "Cannot connect to Borg repository at $BORG_REPO — check backup.conf."

# ── --list ────────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--list" ]; then
    echo ""
    info "Archives in $BORG_REPO (dest: $ACTIVE_DEST):"
    echo ""
    b list 2>/dev/null | sort -t- -k2 -r
    echo ""
    exit 0
fi

# ── Interactive restore ───────────────────────────────────────────────────────
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Borg Restore                                        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
[ "${#_DEST_ARR[@]}" -gt 1 ] && info "Using destination: $ACTIVE_DEST  ($BORG_REPO)"

info "Loading archive list..."
ARCHIVE_LIST=$(b list --format '{archive}{NL}' 2>/dev/null)
[ -z "$ARCHIVE_LIST" ] && die "No archives found. Run a backup first: sudo $HERE/backup_borg.sh"

# Group archives by service prefix (everything before the timestamp)
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

# ── Pick an archive ───────────────────────────────────────────────────────────
echo ""
echo "Available archives (most recent first):"
echo ""
mapfile -t ARCHIVES < <(echo "$ARCHIVE_LIST" | grep "^${SELECTED_SVC}-" | sort -r | head -20)
[ "${#ARCHIVES[@]}" -eq 0 ] && die "No archives found for $SELECTED_SVC."

for i in "${!ARCHIVES[@]}"; do
    note=""; [ "$i" -eq 0 ] && note="  ← latest"
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

TARGET_DIR="$DOCKER_BASE/$SELECTED_SVC"
COMPOSE_FILE="$TARGET_DIR/docker-compose.yml"

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
1)
    TEMP_DIR="/tmp/borg-inspect-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$TEMP_DIR"
    echo ""
    info "Extracting $SELECTED_ARCHIVE to $TEMP_DIR (nothing live is changed)..."
    if ( cd "$TEMP_DIR" && b extract --progress "$BORG_REPO::$SELECTED_ARCHIVE" ); then
        echo ""
        ok "Done. Browse the extracted files:"
        echo ""
        echo "    ls -la $TEMP_DIR"
        echo "  Service directory: $TEMP_DIR${TARGET_DIR}"
        echo ""
        echo "  When finished:"
        echo "    rm -rf $TEMP_DIR"
    else
        rm -rf "$TEMP_DIR" 2>/dev/null || true
        die "Extraction failed — no changes were made."
    fi
    ;;

2)
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

    ASIDE="${TARGET_DIR}.pre-restore-$(date +%Y%m%d-%H%M%S)"
    echo ""
    if [ -e "$TARGET_DIR" ]; then
        info "Moving current data aside → $(basename "$ASIDE")"
        mv "$TARGET_DIR" "$ASIDE"
        ok "Current data saved at: $ASIDE"
    else
        warn "$TARGET_DIR does not exist — restoring fresh."
    fi

    mkdir -p "$TARGET_DIR"
    info "Restoring $SELECTED_ARCHIVE → $TARGET_DIR ..."
    EXTRACT_PATH="${TARGET_DIR#/}"
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
    if [ -e "$ASIDE" ]; then
        echo "  Keep the restore (delete aside copy when satisfied):"
        echo "    rm -rf \"$ASIDE\""
        echo ""
        echo "  Roll back to previous data:"
        [ -f "$COMPOSE_FILE" ] && echo "    docker compose -f $COMPOSE_FILE down"
        echo "    rm -rf \"$TARGET_DIR\""
        echo "    mv \"$ASIDE\" \"$TARGET_DIR\""
        [ -f "$COMPOSE_FILE" ] && echo "    docker compose -f $COMPOSE_FILE up -d"
    fi
    echo ""
    ;;

*)
    echo "Cancelled."
    exit 0
    ;;
esac
