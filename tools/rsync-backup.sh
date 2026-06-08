#!/usr/bin/env bash
# tools/rsync-backup.sh — Interactive rsync mirror backup with versioned deletes.
#
# Usage:
#   bash rsync-backup.sh
#
# How it works:
#   - dest/current/   is always a plain mirror of the source (any file browser works)
#   - dest/versions/YYYY-MM-DD/  holds files that were deleted or overwritten that day
#   - Unchanged files in versions/ are hardlinked (no extra disk cost)
#   - --delete is active, so intentional source deletions propagate; accidental
#     deletes are safe because the file lands in today's versions/ folder first
#
# Requirements:
#   - rsync installed on both source and destination hosts
#   - Passwordless SSH access already configured (ssh-copy-id or equivalent)
#     Run: ssh-copy-id user@remotehost  before using this script for remote jobs.

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()      { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()     { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# ── Config file ───────────────────────────────────────────────────────────────
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rsync-backup"
CONFIG_FILE="$CONFIG_DIR/jobs.conf"

save_job() {
    # save_job NAME SOURCE DEST EXCLUDES
    mkdir -p "$CONFIG_DIR"
    # Remove any existing entry for this name
    if [[ -f "$CONFIG_FILE" ]]; then
        grep -v "^JOB_${1}=" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE" || true
    fi
    printf 'JOB_%s=%s\n' "$1" "$(printf '%q %q %q' "$2" "$3" "$4")" >> "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

load_jobs() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
}

list_jobs() {
    [[ -f "$CONFIG_FILE" ]] || return 0
    grep '^JOB_' "$CONFIG_FILE" | sed 's/^JOB_/  /' | sed 's/=.*//'
}

# ── Helpers ───────────────────────────────────────────────────────────────────
ask() {
    # ask PROMPT DEFAULT VARNAME
    local _prompt="$1" _default="$2" _var="$3" _input=""
    read -r -p "  $_prompt${_default:+ [$_default]}: " _input
    printf -v "$_var" '%s' "${_input:-$_default}"
}

ask_yn() {
    # ask_yn PROMPT DEFAULT(y/n) VARNAME
    local _prompt="$1" _default="$2" _var="$3" _input=""
    read -r -p "  $_prompt [${_default^^}/${_default,,}]: " _input
    _input="${_input:-$_default}"
    printf -v "$_var" '%s' "${_input,,}"
}

require_rsync() {
    command -v rsync &>/dev/null && return 0
    err "rsync is not installed. Install with: sudo apt install rsync"
    exit 1
}

test_ssh() {
    local host="$1"
    info "Testing SSH connection to $host ..."
    if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" true 2>/dev/null; then
        ok "SSH connection OK"
        return 0
    else
        err "Cannot connect to $host via SSH without a password."
        echo ""
        echo "  Passwordless SSH is required. Set it up with:"
        echo "    ssh-copy-id $host"
        echo ""
        return 1
    fi
}

is_remote() {
    # returns true if path contains user@host: or host:
    [[ "$1" == *:* ]]
}

remote_host() {
    echo "${1%%:*}"
}

# ── Core backup logic ─────────────────────────────────────────────────────────
run_backup() {
    local name="$1" source="$2" dest="$3" excludes="$4"

    local today; today="$(date +%Y-%m-%d)"
    local current="${dest%/}/current"
    local versions_today="${dest%/}/versions/${today}"
    local versions_prev="${dest%/}/versions/$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo 'prev')"

    echo ""
    info "Job: $name"
    info "Source : $source"
    info "Dest   : $current"
    info "Versions → $versions_today"
    echo ""

    # Build exclude args
    local -a excl_args=()
    if [[ -n "$excludes" ]]; then
        IFS=',' read -ra _excl_list <<< "$excludes"
        for _e in "${_excl_list[@]}"; do
            excl_args+=(--exclude="${_e// /}")
        done
    fi

    # Build rsync command
    local -a cmd=(
        rsync
        -avh
        --delete
        --backup
        --backup-dir="$versions_today"
        --progress
        --stats
        "${excl_args[@]}"
    )

    # Add --link-dest if yesterday's versions folder exists (saves space via hardlinks)
    if is_remote "$dest"; then
        local rhost; rhost="$(remote_host "$dest")"
        local remote_prev="${dest#*:}"
        remote_prev="${remote_prev%/}/versions/$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo 'prev')"
        if ssh "$rhost" "[ -d '$remote_prev' ]" 2>/dev/null; then
            cmd+=(--link-dest="$remote_prev")
        fi
    else
        if [[ -d "$versions_prev" ]]; then
            cmd+=(--link-dest="$versions_prev")
        fi
    fi

    cmd+=("${source%/}/" "$current/")

    info "Running: ${cmd[*]}"
    echo ""

    if "${cmd[@]}"; then
        echo ""
        ok "Backup complete: $name"
        ok "Mirror : $current"
        ok "Changed/deleted files saved to: $versions_today"
    else
        local rc=$?
        # rsync exit 24 = vanished files (harmless)
        if [[ $rc -eq 24 ]]; then
            warn "Some files vanished during sync (exit 24) — this is usually harmless."
            ok "Backup finished: $name"
        else
            err "rsync exited with code $rc — check output above."
            return $rc
        fi
    fi
}

# ── Prune old versions ────────────────────────────────────────────────────────
prune_versions() {
    local dest="$1" keep_days="$2"

    if is_remote "$dest"; then
        local rhost; rhost="$(remote_host "$dest")"
        local rpath="${dest#*:}"
        local versions_dir="${rpath%/}/versions"
        info "Pruning remote versions older than $keep_days days from $rhost:$versions_dir ..."
        ssh "$rhost" "find '$versions_dir' -maxdepth 1 -mindepth 1 -type d -mtime +${keep_days} -exec rm -rf {} + 2>/dev/null; echo done" \
            && ok "Prune complete" || warn "Prune failed (non-fatal)"
    else
        local versions_dir="${dest%/}/versions"
        if [[ -d "$versions_dir" ]]; then
            info "Pruning local versions older than $keep_days days from $versions_dir ..."
            find "$versions_dir" -maxdepth 1 -mindepth 1 -type d -mtime "+${keep_days}" \
                -exec rm -rf {} + 2>/dev/null || true
            ok "Prune complete"
        fi
    fi
}

# ── Wizard: create / edit a job ───────────────────────────────────────────────
wizard_job() {
    echo ""
    echo "  ── Job Configuration ─────────────────────────────────────"
    echo ""
    echo "  Paths can be local (/home/user/photos) or remote (user@host:/path)."
    echo "  Remote paths require passwordless SSH (ssh-copy-id user@host)."
    echo ""

    local name="" source="" dest="" excludes="" save=""

    ask "Job name (letters/numbers/hyphens)" "my-backup" name
    name="${name//[^a-zA-Z0-9_-]/-}"

    ask "Source path" "" source
    [[ -z "$source" ]] && { warn "Source cannot be empty."; return 1; }

    ask "Destination base path (current/ and versions/ created here)" "" dest
    [[ -z "$dest" ]] && { warn "Destination cannot be empty."; return 1; }

    ask "Exclude patterns, comma-separated (e.g. *.tmp,Thumbs.db) or leave blank" "" excludes

    echo ""
    # Test SSH if remote is involved
    if is_remote "$source"; then
        test_ssh "$(remote_host "$source")" || return 1
    fi
    if is_remote "$dest"; then
        test_ssh "$(remote_host "$dest")" || return 1
    fi

    echo ""
    ask_yn "Save this job for future runs?" "y" save
    if [[ "$save" == "y" ]]; then
        save_job "$name" "$source" "$dest" "$excludes"
        ok "Job '$name' saved to $CONFIG_FILE"
    fi

    echo ""
    local run_now=""
    ask_yn "Run the backup now?" "y" run_now
    if [[ "$run_now" == "y" ]]; then
        run_backup "$name" "$source" "$dest" "$excludes"

        echo ""
        local do_prune=""
        ask_yn "Prune old version folders now?" "y" do_prune
        if [[ "$do_prune" == "y" ]]; then
            local keep=""
            ask "Keep versions for how many days?" "30" keep
            prune_versions "$dest" "$keep"
        fi
    fi
}

# ── Run a saved job ───────────────────────────────────────────────────────────
run_saved_job() {
    load_jobs

    local names=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && names+=("$line")
    done < <(list_jobs)

    if [[ ${#names[@]} -eq 0 ]]; then
        warn "No saved jobs found."
        return 0
    fi

    echo ""
    echo "  Saved jobs:"
    echo ""
    local i=1
    for n in "${names[@]}"; do
        printf "    %2d)  %s\n" "$i" "$n"
        i=$(( i + 1 ))
    done
    echo ""

    local choice=""
    read -r -p "  Run job number [1]: " choice
    choice="${choice:-1}"
    [[ ! "$choice" =~ ^[0-9]+$ ]] && { warn "Invalid."; return 1; }

    local idx=$(( choice - 1 ))
    [[ "$idx" -lt 0 || "$idx" -ge ${#names[@]} ]] && { warn "Invalid selection."; return 1; }

    local job_name="${names[$idx]// /}"
    local var="JOB_${job_name}"
    local job_val="${!var:-}"
    [[ -z "$job_val" ]] && { err "Could not load job '$job_name'."; return 1; }

    # Parse the three quoted fields back out
    eval "local _parts=($job_val)"
    local src="${_parts[0]}" dst="${_parts[1]}" excl="${_parts[2]:-}"

    run_backup "$job_name" "$src" "$dst" "$excl"

    echo ""
    local do_prune=""
    ask_yn "Prune old version folders now?" "n" do_prune
    if [[ "$do_prune" == "y" ]]; then
        local keep=""
        ask "Keep versions for how many days?" "30" keep
        prune_versions "$dst" "$keep"
    fi
}

# ── Cron helper ───────────────────────────────────────────────────────────────
show_cron_hint() {
    echo ""
    echo "  ── Automate with cron ────────────────────────────────────"
    echo ""
    echo "  To run a saved job automatically, add a line like this to crontab"
    echo "  (edit with: crontab -e):"
    echo ""
    echo "  # Daily at 2 AM — run job 'my-backup'"
    echo "  0 2 * * * bash $PWD/$(basename "$0") --job my-backup >> /var/log/rsync-backup.log 2>&1"
    echo ""
    echo "  Or use a systemd timer — ask the setup wizard for details."
    echo ""
}

# ── Non-interactive job run (--job NAME) ──────────────────────────────────────
run_job_by_name() {
    local name="$1"
    load_jobs
    local var="JOB_${name}"
    local job_val="${!var:-}"
    [[ -z "$job_val" ]] && { err "No saved job named '$name'. Run without --job to create one."; exit 1; }
    eval "local _parts=($job_val)"
    local src="${_parts[0]}" dst="${_parts[1]}" excl="${_parts[2]:-}"
    run_backup "$name" "$src" "$dst" "$excl"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    # Non-interactive mode
    if [[ "${1:-}" == "--job" ]]; then
        require_rsync
        run_job_by_name "${2:?--job requires a job name}"
        exit $?
    fi

    require_rsync

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  rsync Mirror Backup with Versioned Deletes              │"
    echo "│                                                          │"
    echo "│  dest/current/          — plain mirror (always current) │"
    echo "│  dest/versions/DATE/    — deleted/changed files by day  │"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""
    echo "  NOTE: Passwordless SSH is required for remote paths."
    echo "        Set up with:  ssh-copy-id user@remotehost"
    echo ""

    while true; do
        echo "  What would you like to do?"
        echo "    1) Create a new backup job (and optionally run it)"
        echo "    2) Run a saved job"
        echo "    3) Show cron/automation hint"
        echo "    0) Quit"
        echo ""
        read -r -p "  Choice [1]: " action
        action="${action:-1}"
        echo ""

        case "$action" in
            1) wizard_job ;;
            2) run_saved_job ;;
            3) show_cron_hint ;;
            0|q|Q) break ;;
            *) warn "Invalid choice." ;;
        esac
        echo ""
    done

    ok "Done."
}

main "$@"
