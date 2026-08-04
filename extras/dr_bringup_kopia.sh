#!/bin/bash
# extras/dr_bringup_kopia.sh — non-interactive disaster-recovery bring-up.
# Installed to ~/docker/backup/dr_bringup.sh by the backup service installer.
#
# Restores the LATEST snapshot of every backed-up service (or one chosen
# service) straight into place and brings it up with `docker compose up -d`.
# Meant to run unattended on a cold spare box during a real outage — unlike
# restore_kopia.sh (one service at a time, interactive prompts per step),
# this walks every discovered service with no prompts so it can complete a
# full-stack recovery in one command.
#
#   sudo ./dr_bringup.sh                 restore + start every service
#   sudo ./dr_bringup.sh --service NAME  restore + start one service
#   sudo ./dr_bringup.sh --list          list restorable sources and exit
#   sudo ./dr_bringup.sh --dry-run       show what would happen, touch nothing
#   sudo ./dr_bringup.sh --no-start      restore only, skip docker compose up -d
#
# Reads backup.conf from the same directory. On the spare box this file
# won't exist yet on its own — copy it over from the primary box first (it
# holds the repository paths/passwords needed to connect):
#   scp primary:~/docker/backup/backup.conf ~/docker/backup/backup.conf
# If the destination repo is a local path shared with the primary (e.g. the
# spare box IS the box the primary's REMOTE_TYPE=sftp mirror targets),
# nothing else is needed — the repo data is already there.
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
[ -f "$CONF" ]                 || die "backup.conf not found: $CONF — copy it from the primary box first."
command -v jq >/dev/null 2>&1  || die "jq is required — install it: sudo apt install jq"

# shellcheck source=/dev/null
source "$CONF"

# gaming-backup's single-dest conf format normalises the same way restore_kopia.sh does.
if [ -z "${DEST_NAMES:-}" ]; then
    DEST_NAMES="default"
    DEST_default_CONFIG="${KOPIA_CONFIG:-}"
    DEST_default_PASSWORD="${KOPIA_PASSWORD:-}"
fi

command -v "$KOPIA" >/dev/null 2>&1 || die "Kopia not found: $KOPIA"
command -v docker   >/dev/null 2>&1 || die "Docker not found — run this repo's post-install (base + require_docker) on this box first."

ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_BASE="$ACTUAL_HOME/docker"

# ── Args ──────────────────────────────────────────────────────────────────────
DO_LIST=false DRY=false START=true ONLY_SVC=""
while [ $# -gt 0 ]; do
    case "$1" in
        --list)     DO_LIST=true; shift ;;
        --dry-run)  DRY=true; shift ;;
        --no-start) START=false; shift ;;
        --service)  ONLY_SVC="${2:-}"; shift 2 ;;
        *)          die "Unknown argument: $1 (see --help by reading the script header)" ;;
    esac
done

k_for() {
    local dest="$1"; shift
    local cfg_var="DEST_${dest}_CONFIG" pw_var="DEST_${dest}_PASSWORD"
    local cfg="${!cfg_var:-}" pw="${!pw_var:-}"
    [ -n "$cfg" ] || return 1
    env KOPIA_PASSWORD="$pw" "$KOPIA" --config-file="$cfg" "$@"
}

# ── Discover the latest restorable snapshot per service, across every
# destination — no dependency on backup.conf's SVC_<name> map, which only
# says where a *new* backup should go, not where past snapshots actually
# landed (relevant if a service was ever reassigned between destinations).
read -ra _DEST_ARR <<< "$DEST_NAMES"
declare -a SRC_PATH_LIST=() SRC_DEST_LIST=() SRC_SNAP_LIST=()

for dest in "${_DEST_ARR[@]}"; do
    if ! k_for "$dest" repository status >/dev/null 2>&1; then
        warn "Cannot connect to destination '$dest' — skipping."
        continue
    fi
    SNAP_JSON="$(k_for "$dest" snapshot list --all --json 2>/dev/null)"
    [ -z "$SNAP_JSON" ] && continue
    [ "$SNAP_JSON" = "null" ] && continue

    mapfile -t _paths < <(echo "$SNAP_JSON" | jq -r --arg base "$DOCKER_BASE/" \
        '[.[] | select(.source.path | startswith($base))] | group_by(.source.path)[] | .[0].source.path')

    for p in "${_paths[@]}"; do
        svc="$(basename "$p")"
        [ -n "$ONLY_SVC" ] && [ "$svc" != "$ONLY_SVC" ] && continue

        # First destination to claim a service name wins (DEST_NAMES always
        # lists "default" first — see backup.sh) so a stale duplicate in a
        # second repo can't shadow the current one.
        _dupe=false
        for _seen in "${SRC_PATH_LIST[@]:-}"; do
            [ "$(basename "$_seen")" = "$svc" ] && _dupe=true && break
        done
        [ "$_dupe" = true ] && continue

        latest_id="$(echo "$SNAP_JSON" | jq -r --arg p "$p" \
            '[.[] | select(.source.path == $p)] | sort_by(.startTime) | reverse | .[0].id')"
        [ -z "$latest_id" ] && continue
        [ "$latest_id" = "null" ] && continue

        SRC_PATH_LIST+=("$p")
        SRC_DEST_LIST+=("$dest")
        SRC_SNAP_LIST+=("$latest_id")
    done
done

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║   Kopia Disaster-Recovery Bring-Up                     ║"
echo "╚═══════════════════════════════════════════════════════╝"

if [ "$DO_LIST" = true ]; then
    echo ""
    [ "${#SRC_PATH_LIST[@]}" -eq 0 ] && { warn "No restorable sources found."; exit 0; }
    printf "  %-16s  %-10s  %s\n" "SERVICE" "DEST" "PATH"
    for i in "${!SRC_PATH_LIST[@]}"; do
        printf "  %-16s  %-10s  %s\n" "$(basename "${SRC_PATH_LIST[$i]}")" "${SRC_DEST_LIST[$i]}" "${SRC_PATH_LIST[$i]}"
    done
    exit 0
fi

if [ "${#SRC_PATH_LIST[@]}" -eq 0 ]; then
    if [ -n "$ONLY_SVC" ]; then
        die "No snapshots found for service '$ONLY_SVC'."
    else
        die "No snapshots found. Run a backup on the primary box first, then copy backup.conf here."
    fi
fi

# ── Restore + start ───────────────────────────────────────────────────────────
TOTAL_START=$(date +%s)
declare -a UP_SVCS=() FAILED_SVCS=()

for i in "${!SRC_PATH_LIST[@]}"; do
    path="${SRC_PATH_LIST[$i]}"
    dest="${SRC_DEST_LIST[$i]}"
    snap="${SRC_SNAP_LIST[$i]}"
    svc="$(basename "$path")"
    compose="${path%/}/docker-compose.yml"

    echo ""
    info "── $svc (dest: $dest, snapshot: ${snap:0:12}...) ──"

    if [ "$DRY" = true ]; then
        echo "    [DRY-RUN] Would restore → $path"
        [ "$START" = true ] && echo "    [DRY-RUN] Would run: docker compose -f $compose up -d"
        continue
    fi

    SVC_START=$(date +%s)

    if [ -e "$path" ]; then
        aside="${path%/}.pre-dr-$(date +%Y%m%d-%H%M%S)"
        mv "$path" "$aside"
        info "  Existing data moved aside → $(basename "$aside")"
    fi
    mkdir -p "$path"

    if ! k_for "$dest" restore "$snap" "$path"; then
        err "  Restore failed for $svc"
        FAILED_SVCS+=("$svc: restore failed")
        continue
    fi
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$path" 2>/dev/null || true
    ok "  Restored"

    if [ "$START" = true ]; then
        if [ ! -f "$compose" ]; then
            warn "  No docker-compose.yml at $path — restored but not started"
            FAILED_SVCS+=("$svc: no compose file")
            continue
        fi
        if docker compose -f "$compose" up -d 2>/dev/null; then
            ok "  Started"
        else
            err "  docker compose up -d failed for $svc"
            FAILED_SVCS+=("$svc: compose up failed")
            continue
        fi
    fi

    SVC_ELAPSED=$(( $(date +%s) - SVC_START ))
    UP_SVCS+=("$svc (${SVC_ELAPSED}s)")
done

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))

echo ""
echo "═══════════════════════════════════════════════════════"
if [ "$DRY" = true ]; then
    echo "  DRY-RUN COMPLETE — nothing was touched"
else
    echo "  DISASTER-RECOVERY BRING-UP COMPLETE"
fi
echo "═══════════════════════════════════════════════════════"
echo ""
[ "$DRY" = false ] && echo "  Total time: $((TOTAL_ELAPSED/60))m $((TOTAL_ELAPSED%60))s" && echo ""

if [ "${#UP_SVCS[@]}" -gt 0 ]; then
    echo "  Up:"
    for s in "${UP_SVCS[@]}"; do echo "    ✓ $s"; done
    echo ""
fi

if [ "${#FAILED_SVCS[@]}" -gt 0 ]; then
    echo "  Failed:"
    for s in "${FAILED_SVCS[@]}"; do echo "    ✗ $s"; done
    echo ""
    exit 1
fi

exit 0
