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

# ── Get all non-data container mount points ───────────────────────────────────
get_data_mounts() {
    local compose="$1"
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -v '/home/filebrowser/data' \
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
    local dir="$1" config="$2" compose="$3"

    # Build list of available mounts from compose
    local mounts=()
    while IFS= read -r m; do mounts+=("$m"); done < <(get_data_mounts "$compose")

    echo ""
    if [[ ${#mounts[@]} -eq 0 ]]; then
        warn "No volume mounts detected in docker-compose.yml (other than data dir)."
    elif [[ ${#mounts[@]} -eq 1 ]]; then
        echo "  Volume mount: ${mounts[0]}"
    else
        echo "  Available volume mounts:"
        local i=1
        for m in "${mounts[@]}"; do
            printf "    %d) %s\n" "$i" "$m"
            i=$(( i + 1 ))
        done
    fi
    echo ""
    echo "  For each source: pick a mount number, then enter the subdirectory"
    echo "  (or type a full container path starting with / to skip the picker)."
    echo ""

    local added=0

    while true; do
        local raw=""
        read -r -p "  Mount number or full path (Enter to finish): " raw
        [[ -z "$raw" ]] && break

        local container_path=""
        if [[ "$raw" == /* ]]; then
            # Full path entered directly
            container_path="${raw%/}"
        elif [[ "$raw" =~ ^[0-9]+$ ]]; then
            local midx=$(( raw - 1 ))
            if [[ "$midx" -lt 0 || "$midx" -ge ${#mounts[@]} ]]; then
                warn "Invalid mount number."; continue
            fi
            local base_mount="${mounts[$midx]}"
            local subdir=""
            read -r -p "  Subdirectory under ${base_mount} (or Enter for root): " subdir
            subdir="${subdir#/}"
            if [[ -z "$subdir" ]]; then
                container_path="$base_mount"
            else
                container_path="${base_mount}/${subdir}"
            fi
        else
            warn "Enter a mount number or a full path starting with /."; continue
        fi

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

        backup "$config"
        # Strip inline comments first so yq edits cleanly
        local tmp; tmp=$(mktemp)
        sed 's/[[:space:]]*#.*$//' "$config" > "$tmp" && mv "$tmp" "$config"
        yq e -i ".server.sources += [{
            \"path\": \"${container_path}\",
            \"name\": \"${source_name}\",
            \"config\": {
                \"defaultEnabled\": ${default_enabled_bool}
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
        i=$(( i + 1 ))
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
        printf "  %-20s  %-35s  defaultEnabled=%s\n" \
            "${name}" "${p}" "${enabled}"
        count=$(( count + 1 ))
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

    info "Install dir : $install_dir"
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
            1) cmd_add    "$install_dir" "$config" "$compose" ;;
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
