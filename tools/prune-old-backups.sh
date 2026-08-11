#!/usr/bin/env bash
# tools/prune-old-backups.sh — Deletes old *.backup.* files this repo's
# services create before overwriting a live config (Caddyfile, /etc/fstab,
# etc — the pattern is always <name>.backup.<timestamp>, though the exact
# timestamp format varies by service: %Y%m%d-%H%M%S vs %Y%m%d_%H%M%S).
# Nothing in this repo ever cleans these up at the point they're created —
# every service backs up before a destructive write, none of them prune
# afterward, so they accumulate forever on any box reconfigured regularly.
#
# Prunes by file mtime (not by parsing the timestamp out of the filename —
# robust to the format inconsistency above, since it never has to parse it
# at all), and always keeps the single newest backup per distinct file
# regardless of age, so a box that hasn't been touched in months never
# ends up with zero backups for something.
#
# Usage:
#   sudo bash prune-old-backups.sh [KEEP_DAYS]   (default 30)

set -uo pipefail

KEEP_DAYS="${1:-30}"
[[ "$KEEP_DAYS" =~ ^[0-9]+$ ]] || { echo "KEEP_DAYS must be a number" >&2; exit 1; }

ACTUAL_USER="${SUDO_USER:-${USER:-root}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$ACTUAL_USER")"
DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"

SEARCH_DIRS=()
[ -d "$DOCKER_DIR" ] && SEARCH_DIRS+=("$DOCKER_DIR")
[ -d /etc ] && SEARCH_DIRS+=(/etc)

if [ "${#SEARCH_DIRS[@]}" -eq 0 ]; then
    echo "Nothing to scan (no $DOCKER_DIR, no /etc)."
    exit 0
fi

# Pass 1: find every distinct "base" (the path with .backup.TIMESTAMP
# stripped) and remember its single newest match — that one is always
# kept below, regardless of age.
declare -A NEWEST_PER_BASE
while IFS= read -r -d '' f; do
    base="${f%.backup.*}"
    cur="${NEWEST_PER_BASE[$base]:-}"
    if [ -z "$cur" ] || [ "$f" -nt "$cur" ]; then
        NEWEST_PER_BASE["$base"]="$f"
    fi
done < <(find "${SEARCH_DIRS[@]}" -maxdepth 6 -type f -name "*.backup.*" -print0 2>/dev/null)

DELETED=0
KEPT_AS_NEWEST=0

# Pass 2: delete only files older than KEEP_DAYS, skipping any that are
# the sole/newest backup for their base (the safety net above).
while IFS= read -r -d '' f; do
    is_newest=false
    for keep in "${NEWEST_PER_BASE[@]}"; do
        if [ "$f" = "$keep" ]; then
            is_newest=true
            break
        fi
    done
    if [ "$is_newest" = true ]; then
        KEPT_AS_NEWEST=$((KEPT_AS_NEWEST + 1))
        continue
    fi
    rm -f "$f" && DELETED=$((DELETED + 1))
done < <(find "${SEARCH_DIRS[@]}" -maxdepth 6 -type f -name "*.backup.*" -mtime "+${KEEP_DAYS}" -print0 2>/dev/null)

echo "Backup pruning: removed $DELETED file(s) older than ${KEEP_DAYS} days (kept $KEPT_AS_NEWEST as the newest-per-file safety net)"
