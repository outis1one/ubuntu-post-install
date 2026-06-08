#!/usr/bin/env bash
# fbq-add-source.sh — Manage file sources for FileBrowser Quantum.
#
# Handles both docker-compose.yml volume mounts and config.yaml source
# entries together, keeping them in sync.
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

# ── Get all non-data container mount points from compose ──────────────────────
get_compose_mounts() {
    local compose="$1"
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -v '/home/filebrowser/data' \
        | grep -v '^\./' \
        | sed 's|/$||'
}

# ── Check if a volume mount already exists in compose ────────────────────────
volume_exists() {
    local compose="$1" container_path="$2"
    yq e '.services.filebrowser.volumes[]' "$compose" 2>/dev/null \
        | grep -qF ":${container_path}"
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
            warn "Remember to restart: cd $dir && docker compose down && docker compose up -d"
            return 0
        }
    fi

    info "Restarting FileBrowser Quantum..."
    docker compose -f "$dir/docker-compose.yml" down \
        && docker compose -f "$dir/docker-compose.yml" up -d \
        && ok "FileBrowser Quantum restarted." \
        || warn "Restart failed — try: cd $dir && docker compose down && docker compose up -d"
}

# ── ADD ───────────────────────────────────────────────────────────────────────
cmd_add() {
    local dir="$1" config="$2" compose="$3"

    # Build list of existing mounts from compose (host:container pairs)
    local mount_pairs=()
    local container_paths=()
    while IFS= read -r line; do
        mount_pairs+=("$line")
        container_paths+=("$(echo "$line" | cut -d: -f2 | sed 's|/$||')")
    done < <(get_compose_mounts "$compose")

    echo ""
    if [[ ${#container_paths[@]} -gt 0 ]]; then
        echo "  Current volume mounts:"
        echo ""
        local i=1
        for pair in "${mount_pairs[@]}"; do
            local h; h=$(echo "$pair" | cut -d: -f1)
            local c; c=$(echo "$pair" | cut -d: -f2 | sed 's|/$||')
            printf "    %d)  %-30s  →  %s\n" "$i" "$h" "$c"
            i=$(( i + 1 ))
        done
    else
        echo "  No existing volume mounts detected."
    fi

    echo ""
    echo "  Options:"
    echo "    • Enter a number to add a source under an existing mount"
    echo "    • Enter a host path (e.g. /mnt/data2) to add a NEW mount + source"
    echo "    • Enter a full container path (e.g. /data2/music) for an existing mount"
    echo "    • Enter to finish"
    echo ""

    local added=0
    local compose_changed=0

    while true; do
        local raw=""
        read -r -p "  Number, host path, container path, or Enter to finish: " raw
        [[ -z "$raw" ]] && break

        local host_path="" container_path=""

        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            # Existing mount by number
            local midx=$(( raw - 1 ))
            if [[ "$midx" -lt 0 || "$midx" -ge ${#container_paths[@]} ]]; then
                warn "Invalid number."; continue
            fi
            local base="${container_paths[$midx]}"
            local subdir=""
            read -r -p "  Subdirectory under ${base} (or Enter for the mount root): " subdir
            subdir="${subdir#/}"
            container_path="${base}${subdir:+/$subdir}"

        elif [[ "$raw" == /* ]]; then
            # Could be a host path or a container path
            if [[ -d "$raw" ]] && ! volume_exists "$compose" "$raw"; then
                # Looks like a host path not yet mounted
                host_path="$raw"
                local default_cname
                default_cname="/$(basename "$raw" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')"
                local cname=""
                read -r -p "  Container mount point [${default_cname}]: " cname
                cname="${cname:-$default_cname}"
                cname="/${cname#/}"
                container_path="$cname"
            else
                # Treat as full container path
                container_path="${raw%/}"
            fi
        else
            warn "Enter a number, a host path, or a container path starting with /."; continue
        fi

        # If this is a new host mount, add it to docker-compose.yml
        if [[ -n "$host_path" ]]; then
            if volume_exists "$compose" "$container_path"; then
                warn "Volume mount ':${container_path}' already in docker-compose.yml."
            else
                backup "$compose"
                yq e -i ".services.filebrowser.volumes += [\"${host_path}:${container_path}\"]" "$compose"
                ok "Added volume mount: ${host_path}:${container_path}"
                compose_changed=1
            fi
        fi

        # Default source name from container path basename
        local default_name
        default_name=$(basename "$container_path" | tr '[:upper:]' '[:lower:]' | tr ' _' '-')
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
        added=$(( added + 1 ))
    done

    if [[ "$added" -gt 0 || "$compose_changed" -gt 0 ]]; then
        if [[ "$compose_changed" -gt 0 ]]; then
            info "docker-compose.yml was changed — a full down/up is required (not just restart)."
        fi
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
    local dir="$1" config="$2" compose="$3"

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
        name=$(sed 's/[[:space:]]*#.*$//' "$config" \
            | yq e ".server.sources[] | select(.path == \"$p\") | .name // \"(unnamed)\"" - 2>/dev/null \
            || echo "(unnamed)")
        printf "  %2d)  %-20s  %s\n" "$i" "${name}" "$p"
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

    # Check if there's also a compose volume mount for this exact path
    local remove_mount=false
    if volume_exists "$compose" "$target"; then
        local yn=""
        read -r -p "  Also remove the volume mount for '$target' from docker-compose.yml? [y/N]: " yn
        [[ "${yn,,}" == "y" ]] && remove_mount=true
    fi

    local confirm=""
    read -r -p "  Confirm? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; return 0; }

    backup "$config"
    yq e -i "del(.server.sources[] | select(.path == \"${target}\"))" "$config"
    ok "Removed source '$target' from config.yaml."

    if [[ "$remove_mount" == true ]]; then
        backup "$compose"
        yq e -i "del(.services.filebrowser.volumes[] | select(test(\":${target}$\")))" "$compose"
        ok "Removed volume mount from docker-compose.yml."
        info "A full down/up is required to apply compose changes."
    fi

    restart_container "$dir"
}

# ── SHOW ──────────────────────────────────────────────────────────────────────
cmd_show() {
    local config="$1" compose="$2"

    echo ""
    echo "  Volume mounts (docker-compose.yml):"
    echo ""
    local i=1
    while IFS= read -r pair; do
        local h; h=$(echo "$pair" | cut -d: -f1)
        local c; c=$(echo "$pair" | cut -d: -f2 | sed 's|/$||')
        printf "  %2d)  %-35s  →  %s\n" "$i" "$h" "$c"
        i=$(( i + 1 ))
    done < <(get_compose_mounts "$compose")
    [[ "$i" -eq 1 ]] && echo "  (none)"

    echo ""
    echo "  Sources (config.yaml):"
    echo ""

    local count=0
    while IFS= read -r p; do
        local name enabled
        name=$(sed 's/[[:space:]]*#.*$//' "$config" \
            | yq e ".server.sources[] | select(.path == \"$p\") | .name // \"(unnamed)\"" - 2>/dev/null \
            || echo "?")
        enabled=$(sed 's/[[:space:]]*#.*$//' "$config" \
            | yq e ".server.sources[] | select(.path == \"$p\") | .config.defaultEnabled // false" - 2>/dev/null \
            || echo "false")
        printf "  %-20s  %-35s  defaultEnabled=%s\n" "${name}" "${p}" "${enabled}"
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
    echo "│  Manages docker-compose.yml and config.yaml in sync      │"
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
        echo "    3) Show current mounts and sources"
        echo "    0) Quit"
        echo ""
        read -r -p "  Choice [1]: " action
        action="${action:-1}"
        echo ""

        case "$action" in
            1) cmd_add    "$install_dir" "$config" "$compose" ;;
            2) cmd_remove "$install_dir" "$config" "$compose" ;;
            3) cmd_show   "$config" "$compose" ;;
            0|q|Q) break ;;
            *) warn "Invalid choice." ;;
        esac
        echo ""
    done

    ok "Done."
}

main "$@"
