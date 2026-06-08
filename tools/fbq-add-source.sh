#!/usr/bin/env bash
# fbq-add-source.sh — Manage file sources for FileBrowser Quantum.
#
# Assumes the parent data directory is already mounted in docker-compose.yml.
# Subdirectories of that mount are already accessible inside the container,
# so only config.yaml needs editing — no compose changes required.
#
# Usage:
#   bash fbq-add-source.sh [--dir /path/to/compose]
#
# Requirements:
#   - yq v4+ (https://github.com/mikefarah/yq)
#     Install: sudo wget -qO /usr/local/bin/yq \
#       https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
#       && sudo chmod +x /usr/local/bin/yq
#   - docker compose v2

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()      { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()     { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
    local missing=0

    if ! command -v yq &>/dev/null; then
        err "yq is required but not installed."
        echo ""
        echo "  Install with:"
        echo "    sudo wget -qO /usr/local/bin/yq \\"
        echo "      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "    sudo chmod +x /usr/local/bin/yq"
        echo ""
        missing=1
    else
        local major
        major=$(yq --version 2>&1 | grep -oP '(?<=v)\d+' | head -1 || echo 0)
        if [[ "$major" -lt 4 ]]; then
            err "yq v4+ required (found v${major}). Get it from github.com/mikefarah/yq"
            missing=1
        fi
    fi

    if ! docker compose version &>/dev/null; then
        err "Docker Compose plugin (v2) is required."
        echo "  Install: sudo apt-get install -y docker-compose-plugin"
        missing=1
    fi

    [[ "$missing" -eq 0 ]] || exit 1
}

# ── Locate install directory ──────────────────────────────────────────────────
find_install_dir() {
    local dir="${1:-}"

    if [[ -n "$dir" ]]; then
        [[ -f "$dir/docker-compose.yml" ]] || { err "docker-compose.yml not found in: $dir"; exit 1; }
        [[ -f "$dir/data/config.yaml"   ]] || { err "data/config.yaml not found in: $dir"; exit 1; }
        echo "$dir"; return
    fi

    local candidates=(
        "$HOME/docker/filebrowser-quantum"
        "$HOME/docker/filebrowser"
        "/opt/filebrowser-quantum"
        "/opt/filebrowser"
    )
    for c in "${candidates[@]}"; do
        if [[ -f "$c/docker-compose.yml" && -f "$c/data/config.yaml" ]]; then
            echo "$c"; return
        fi
    done

    echo ""
    read -r -p "  Path to FileBrowser Quantum directory: " dir
    dir="${dir%/}"
    [[ -f "$dir/docker-compose.yml" ]] || { err "docker-compose.yml not found in: $dir"; exit 1; }
    [[ -f "$dir/data/config.yaml"   ]] || { err "data/config.yaml not found in: $dir"; exit 1; }
    echo "$dir"
}

# ── Get the container-side path for the main data mount ──────────────────────
# Reads docker-compose.yml and returns the container path of the first
# non-data-dir volume mount (i.e. the user files mount).
get_data_mount() {
    local compose="$1"
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -v '/home/filebrowser/data' \
        | head -1 \
        | cut -d: -f2 \
        | sed 's|/$||'
}

# ── Backup a file ─────────────────────────────────────────────────────────────
backup() {
    local file="$1"
    local bk="${file}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$bk"
    info "Backed up $(basename "$file") → $(basename "$bk")"
}

# ── Check if a source path already exists in config ──────────────────────────
source_exists() {
    local config="$1" path="$2"
    sed 's/[[:space:]]*#.*$//' "$config" \
        | yq e '.server.sources[].path' - 2>/dev/null \
        | grep -qxF "$path"
}

# ── List existing sources ─────────────────────────────────────────────────────
list_sources() {
    local config="$1"
    # Strip inline comments before parsing — yq can mishandle them mid-array
    sed 's/[[:space:]]*#.*$//' "$config" | yq e '.server.sources[] | .path' - 2>/dev/null
}

# ── Restart the container ─────────────────────────────────────────────────────
restart_container() {
    local dir="$1" prompt="${2:-true}"

    if [[ "$prompt" == "true" ]]; then
        echo ""
        local yn=""
        read -r -p "  Restart FileBrowser Quantum now to apply changes? [Y/n]: " yn
        [[ "${yn,,}" == "n" ]] && {
            warn "Remember to restart: cd $dir && docker compose restart"
            return 0
        }
    fi

    info "Restarting FileBrowser Quantum..."
    docker compose -f "$dir/docker-compose.yml" restart \
        && ok "FileBrowser Quantum restarted." \
        || warn "Restart failed — try: cd $dir && docker compose restart"
}

# ── ADD ───────────────────────────────────────────────────────────────────────
cmd_add() {
    local dir="$1" config="$2" data_mount="$3"

    echo ""
    echo "  The data directory is mounted at: ${data_mount:-unknown}"
    echo "  Enter subdirectory names (relative to that mount) to add as sources."
    echo "  Example: if your music lives at ${data_mount}/music, enter 'music'"
    echo ""

    local added=0

    while true; do
        local subdir=""
        read -r -p "  Subdirectory to add (or Enter to finish): " subdir
        [[ -z "$subdir" ]] && break
        subdir="${subdir#/}"   # strip any leading slash

        local container_path="${data_mount}/${subdir}"

        # Default name = subdir basename, lowercase, hyphenated
        local default_name
        default_name=$(basename "$subdir" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
        local source_name=""
        read -r -p "  Display name for this source [${default_name}]: " source_name
        source_name="${source_name:-$default_name}"
        source_name=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/-*$//')

        if source_exists "$config" "$container_path"; then
            warn "Source '$container_path' already in config.yaml — skipping."
            continue
        fi

        local default_enabled_bool="false"
        local yn=""
        read -r -p "  Enable for all users by default? [y/N]: " yn
        [[ "${yn,,}" == "y" ]] && default_enabled_bool="true"

        local read_only_bool="false"
        read -r -p "  Read-only? [y/N]: " read_only_bool_raw
        [[ "${read_only_bool_raw,,}" == "y" ]] && read_only_bool="true"

        backup "$config"
        # Strip inline comments first so yq edits cleanly
        local tmp; tmp=$(mktemp)
        sed 's/[[:space:]]*#.*$//' "$config" > "$tmp" && mv "$tmp" "$config"
        yq e -i ".server.sources += [{
            \"path\": \"${container_path}\",
            \"name\": \"${source_name}\",
            \"config\": {
                \"defaultEnabled\": ${default_enabled_bool},
                \"readOnly\": ${read_only_bool}
            }
        }]" "$config"

        ok "Added source '${source_name}' → ${container_path}"
        (( added++ ))
    done

    if [[ "$added" -gt 0 ]]; then
        restart_container "$dir"
        echo ""
        ok "$added source(s) added."
        info "Assign them to users: Settings → Users → edit user → Add source"
    else
        info "Nothing added."
    fi
}

# ── REMOVE ────────────────────────────────────────────────────────────────────
cmd_remove() {
    local dir="$1" config="$2"

    local paths=()
    while IFS= read -r p; do paths+=("$p"); done < <(list_sources "$config")

    if [[ ${#paths[@]} -eq 0 ]]; then
        warn "No sources found in config.yaml."
        return 0
    fi

    echo ""
    echo "  Current sources:"
    echo ""
    local i=1
    for p in "${paths[@]}"; do
        local name
        name=$(yq e ".server.sources[] | select(.path == \"$p\") | .name // \"(unnamed)\"" "$config" 2>/dev/null || echo "(unnamed)")
        printf "  %2d)  %-20s  %s\n" "$i" "${name:-?}" "$p"
        (( i++ ))
    done
    echo ""

    local choice=""
    read -r -p "  Remove source number [cancel]: " choice
    [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && { info "Cancelled."; return 0; }

    local idx=$(( choice - 1 ))
    if [[ "$idx" -lt 0 || "$idx" -ge ${#paths[@]} ]]; then
        warn "Invalid selection."; return 0
    fi

    local target="${paths[$idx]}"
    warn "Will remove source '$target' from config.yaml."
    local confirm=""
    read -r -p "  Confirm? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; return 0; }

    backup "$config"
    yq e -i "del(.server.sources[] | select(.path == \"${target}\"))" "$config"
    ok "Removed source '$target' from config.yaml."
    restart_container "$dir"
}

# ── SHOW ──────────────────────────────────────────────────────────────────────
cmd_show() {
    local config="$1"
    echo ""
    echo "  Sources configured in config.yaml:"
    echo ""

    local count=0
    while IFS= read -r p; do
        local name enabled ro
        name=$(yq e ".server.sources[] | select(.path == \"$p\") | .name // \"(unnamed)\"" "$config" 2>/dev/null || echo "?")
        enabled=$(yq e ".server.sources[] | select(.path == \"$p\") | .config.defaultEnabled // false" "$config" 2>/dev/null || echo "false")
        ro=$(yq e ".server.sources[] | select(.path == \"$p\") | .config.readOnly // false" "$config" 2>/dev/null || echo "false")
        printf "  %-20s  %-35s  defaultEnabled=%-5s  readOnly=%s\n" \
            "${name}" "${p}" "${enabled}" "${ro}"
        (( count++ ))
    done < <(list_sources "$config")

    [[ "$count" -eq 0 ]] && warn "No sources found."
    echo ""
}

# ── MAIN ──────────────────────────────────────────────────────────────────────
main() {
    local explicit_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir|-d) explicit_dir="$2"; shift 2 ;;
            *) err "Unknown argument: $1"; exit 1 ;;
        esac
    done

    check_deps

    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  FileBrowser Quantum — Source Manager                    │"
    echo "│  Manages config.yaml and restarts the container          │"
    echo "└──────────────────────────────────────────────────────────┘"

    local install_dir
    install_dir=$(find_install_dir "$explicit_dir")
    local config="$install_dir/data/config.yaml"
    local compose="$install_dir/docker-compose.yml"
    local data_mount
    data_mount=$(get_data_mount "$compose")

    info "Install dir : $install_dir"
    info "Data mount  : ${data_mount:-not detected — enter full container paths}"
    echo ""

    while true; do
        echo "  What would you like to do?"
        echo "    1) Add source(s)"
        echo "    2) Remove a source"
        echo "    3) Show current sources"
        echo "    0) Quit"
        echo ""
        read -r -p "  Choice [1]: " action
        action="${action:-1}"
        echo ""

        case "$action" in
            1) cmd_add    "$install_dir" "$config" "$data_mount" ;;
            2) cmd_remove "$install_dir" "$config" ;;
            3) cmd_show   "$config" ;;
            0|q|Q) break ;;
            *) warn "Invalid choice." ;;
        esac
        echo ""
    done

    ok "Done."
}

main "$@"
