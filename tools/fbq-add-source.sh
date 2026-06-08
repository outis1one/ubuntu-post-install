#!/usr/bin/env bash
# fbq-add-source.sh — Add file sources to a FileBrowser Quantum installation.
#
# Edits docker-compose.yml and config.yaml together so they stay in sync:
#   - Adds a volume mount to the filebrowser service
#   - Adds a matching source entry under server.sources
#   - Optionally restarts the container to apply changes
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
_blue()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
_green()   { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
_yellow()  { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
_red()     { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# ── Dependency checks ─────────────────────────────────────────────────────────
check_deps() {
    local missing=0

    if ! command -v yq &>/dev/null; then
        _red "yq is required but not installed."
        echo ""
        echo "  Install with:"
        echo "    sudo wget -qO /usr/local/bin/yq \\"
        echo "      https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64"
        echo "    sudo chmod +x /usr/local/bin/yq"
        echo ""
        missing=1
    else
        local yq_ver
        yq_ver=$(yq --version 2>&1 | grep -oP '\d+\.\d+' | head -1)
        local major="${yq_ver%%.*}"
        if [[ "$major" -lt 4 ]]; then
            _red "yq v4+ is required (found v${yq_ver}). The mikefarah/yq version is needed."
            missing=1
        fi
    fi

    if ! docker compose version &>/dev/null; then
        _red "Docker Compose plugin (v2) is required."
        echo "  Install: sudo apt-get install -y docker-compose-plugin"
        missing=1
    fi

    [[ "$missing" -eq 0 ]] || exit 1
}

# ── Locate install directory ──────────────────────────────────────────────────
find_install_dir() {
    local dir="${1:-}"

    if [[ -n "$dir" ]]; then
        echo "$dir"
        return
    fi

    # Common locations
    local candidates=(
        "$HOME/docker/filebrowser-quantum"
        "$HOME/docker/filebrowser"
        "/opt/filebrowser-quantum"
        "/opt/filebrowser"
    )

    for c in "${candidates[@]}"; do
        if [[ -f "$c/docker-compose.yml" && -f "$c/data/config.yaml" ]]; then
            echo "$c"
            return
        fi
    done

    # Not found — ask
    echo ""
    read -r -p "  Path to FileBrowser Quantum directory (contains docker-compose.yml): " dir
    dir="${dir%/}"
    if [[ ! -f "$dir/docker-compose.yml" ]]; then
        _red "docker-compose.yml not found in: $dir"
        exit 1
    fi
    if [[ ! -f "$dir/data/config.yaml" ]]; then
        _red "data/config.yaml not found in: $dir"
        exit 1
    fi
    echo "$dir"
}

# ── Backup a file ─────────────────────────────────────────────────────────────
backup() {
    local file="$1"
    local bk="${file}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$file" "$bk"
    _blue "Backed up $(basename "$file") → $(basename "$bk")"
}

# ── Check if a volume mount already exists in compose ────────────────────────
volume_exists() {
    local compose="$1" container_path="$2"
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -qF ":${container_path}" || return 1
}

# ── Check if a source already exists in config ───────────────────────────────
source_exists() {
    local config="$1" container_path="$2"
    yq e '.server.sources[].path' "$config" 2>/dev/null \
        | grep -qxF "$container_path" || return 1
}

# ── Add a single source ───────────────────────────────────────────────────────
add_source() {
    local compose="$1" config="$2"

    echo ""
    echo "────────────────────────────────────────────────"

    # Host path
    local host_path=""
    while true; do
        read -r -p "  Host directory path (e.g. /mnt/data/music): " host_path
        host_path="${host_path%/}"
        if [[ -z "$host_path" ]]; then
            _yellow "No path entered — skipping."
            return 0
        fi
        if [[ ! -d "$host_path" ]]; then
            _yellow "'$host_path' does not exist on this host."
            local yn=""
            read -r -p "  Add it anyway? [y/N]: " yn
            [[ "${yn,,}" == "y" ]] && break
        else
            break
        fi
    done

    # Source name (used as both the container mount point and the Quantum source name)
    local default_name
    default_name=$(basename "$host_path" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local source_name=""
    read -r -p "  Source name [${default_name}]: " source_name
    source_name="${source_name:-$default_name}"
    # Sanitise: lowercase, alphanumeric + hyphen only
    source_name=$(echo "$source_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/-*$//')

    local container_path="/${source_name}"

    # Collision checks
    if volume_exists "$compose" "$container_path"; then
        _yellow "Volume mount ':${container_path}' already exists in docker-compose.yml — skipping."
        return 0
    fi
    if source_exists "$config" "$container_path"; then
        _yellow "Source path '${container_path}' already exists in config.yaml — skipping."
        return 0
    fi

    # Access defaults
    local default_enabled=""
    read -r -p "  Enable for all users by default? [y/N]: " default_enabled
    local default_enabled_bool="false"
    [[ "${default_enabled,,}" == "y" ]] && default_enabled_bool="true"

    local read_only=""
    read -r -p "  Read-only? [y/N]: " read_only
    local read_only_bool="false"
    [[ "${read_only,,}" == "y" ]] && read_only_bool="true"

    # ── Write changes ──────────────────────────────────────────────────────────

    # 1. docker-compose.yml — add volume mount
    backup "$compose"
    yq e -i ".services.filebrowser.volumes += [\"${host_path}:${container_path}\"]" "$compose"
    _green "Added volume: ${host_path}:${container_path}"

    # 2. config.yaml — add source entry
    backup "$config"
    yq e -i ".server.sources += [{
        \"path\": \"${container_path}\",
        \"name\": \"${source_name}\",
        \"config\": {
            \"defaultEnabled\": ${default_enabled_bool},
            \"readOnly\": ${read_only_bool}
        }
    }]" "$config"
    _green "Added source: ${source_name} → ${container_path}"
}

# ── Remove a source ───────────────────────────────────────────────────────────
remove_source() {
    local compose="$1" config="$2"

    echo ""
    echo "Current sources:"
    echo ""

    # List sources from config
    local paths=()
    while IFS= read -r p; do
        paths+=("$p")
    done < <(yq e '.server.sources[].path' "$config" 2>/dev/null)

    if [[ ${#paths[@]} -eq 0 ]]; then
        _yellow "No sources found in config.yaml."
        return 0
    fi

    local i=1
    for p in "${paths[@]}"; do
        printf "  %2d)  %s\n" "$i" "$p"
        (( i++ ))
    done
    echo ""

    local choice=""
    read -r -p "  Remove source number [cancel]: " choice
    if [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]]; then
        _blue "Cancelled."
        return 0
    fi

    local idx=$(( choice - 1 ))
    if [[ "$idx" -lt 0 || "$idx" -ge ${#paths[@]} ]]; then
        _yellow "Invalid selection."
        return 0
    fi

    local target_path="${paths[$idx]}"

    # Confirm
    echo ""
    _yellow "Will remove source '$target_path' from config.yaml and its volume mount from docker-compose.yml."
    local confirm=""
    read -r -p "  Confirm? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { _blue "Cancelled."; return 0; }

    # Remove from config.yaml
    backup "$config"
    yq e -i "del(.server.sources[] | select(.path == \"${target_path}\"))" "$config"
    _green "Removed source from config.yaml"

    # Remove from docker-compose.yml (volume entry ending with :target_path)
    if volume_exists "$compose" "$target_path"; then
        backup "$compose"
        yq e -i "del(.services.filebrowser.volumes[] | select(. == \"*:${target_path}\"))" "$compose"
        # yq glob select doesn't do substring — use a precise match
        yq e -i "del(.services.filebrowser.volumes[] | select(test(\":${target_path}$\")))" "$compose"
        _green "Removed volume mount from docker-compose.yml"
    else
        _yellow "No matching volume mount found in docker-compose.yml (may have been added manually)."
    fi
}

# ── Show current sources ──────────────────────────────────────────────────────
show_sources() {
    local compose="$1" config="$2"

    echo ""
    echo "  Sources in config.yaml:"
    echo ""
    yq e '.server.sources[] | "    " + .name + "  →  " + .path +
        "  (defaultEnabled: " + (.config.defaultEnabled | tostring) + ")"' \
        "$config" 2>/dev/null || _yellow "  None found."

    echo ""
    echo "  Volume mounts in docker-compose.yml:"
    echo ""
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -v '/home/filebrowser/data' \
        | sed 's/^/    /' \
        || _yellow "  None found."
    echo ""
}

# ── Restart container ─────────────────────────────────────────────────────────
restart_container() {
    local dir="$1"
    echo ""
    local yn=""
    read -r -p "  Restart FileBrowser Quantum now to apply changes? [Y/n]: " yn
    if [[ "${yn,,}" != "n" ]]; then
        _blue "Restarting..."
        docker compose -f "$dir/docker-compose.yml" down
        docker compose -f "$dir/docker-compose.yml" up -d
        _green "FileBrowser Quantum restarted."
        echo ""
        _blue "Assign the new source(s) to users: Settings → Users → edit user → Add source"
    else
        _yellow "Remember to restart manually: docker compose down && docker compose up -d"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    local explicit_dir=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir|-d) explicit_dir="$2"; shift 2 ;;
            *) _red "Unknown argument: $1"; exit 1 ;;
        esac
    done

    check_deps

    echo ""
    echo "┌──────────────────────────────────────────────────────┐"
    echo "│  FileBrowser Quantum — Source Manager                │"
    echo "│  Edits docker-compose.yml + config.yaml in sync     │"
    echo "└──────────────────────────────────────────────────────┘"

    local install_dir
    install_dir=$(find_install_dir "$explicit_dir")
    local compose="$install_dir/docker-compose.yml"
    local config="$install_dir/data/config.yaml"

    _blue "Install dir: $install_dir"

    local changed=0

    while true; do
        echo ""
        echo "  What would you like to do?"
        echo "    1) Add a source"
        echo "    2) Remove a source"
        echo "    3) Show current sources"
        echo "    4) Quit"
        echo ""
        read -r -p "  Choice [1]: " action
        action="${action:-1}"

        case "$action" in
            1)
                add_source "$compose" "$config"
                changed=1
                local another=""
                read -r -p "  Add another source? [y/N]: " another
                [[ "${another,,}" == "y" ]] || break
                ;;
            2)
                remove_source "$compose" "$config"
                changed=1
                ;;
            3)
                show_sources "$compose" "$config"
                ;;
            4|q|Q)
                break
                ;;
            *)
                _yellow "Invalid choice."
                ;;
        esac
    done

    if [[ "$changed" -eq 1 ]]; then
        restart_container "$install_dir"
    fi

    echo ""
    _green "Done."
}

main "$@"
