#!/usr/bin/env bash
# additional_directories.sh — Give FileBrowser users access to extra folders.
#
# Placed in ~/docker/filebrowser/ by the installer.
# Requires: curl, jq, docker   (sudo apt install curl jq)
#
# FileBrowser only shows each user the one folder set as their root (directory).
# This script gives a user access to extra folders by adding bind-mount entries
# to docker-compose.yml so FileBrowser sees them as real subdirectories within
# the user's root — no symlinks, no scope-boundary issues.
#
# A container restart is required for changes to take effect.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
ENV_FILE="$SCRIPT_DIR/.env"
FB_URL="${FB_URL:-http://localhost:8085}"
TOKEN=""

# ── Output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    B=$'\e[1m' R=$'\e[0m' GRN=$'\e[32m' RED=$'\e[31m' YEL=$'\e[33m' DIM=$'\e[2m'
else
    B="" R="" GRN="" RED="" YEL="" DIM=""
fi

die()    { echo "${RED}ERROR:${R} $*" >&2; exit 1; }
ok()     { echo "  ${GRN}✓${R} $*"; }
warn()   { echo "  ${YEL}!${R} $*"; }
errmsg() { echo "  ${RED}✗${R} $*" >&2; }
hr()     { printf '  %s\n' "────────────────────────────────────────────"; }
banner() { echo; hr; printf "  ${B}%-44s${R}\n" "$*"; hr; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
require_cmds() {
    for _c in "$@"; do
        command -v "$_c" &>/dev/null || die "'$_c' not found — sudo apt install $_c"
    done
}

[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found at $COMPOSE_FILE"

# ── Read FB_PATH from .env ────────────────────────────────────────────────────
get_fb_path() {
    local _p=""
    if [[ -f "$ENV_FILE" ]]; then
        _p=$(grep '^FB_PATH=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    # Fall back to parsing compose file for the bind-mount line
    if [[ -z "$_p" ]]; then
        # Match:  - /some/path:/srv  or  - /some/path:/srv/data
        _p=$(grep -oP '^\s+-\s+\K[^$][^:]+(?=:/srv(/data)?(\s|$))' "$COMPOSE_FILE" \
             2>/dev/null | head -1) || true
    fi
    [[ -n "$_p" ]] || die "Cannot determine FB_PATH — check $ENV_FILE or $COMPOSE_FILE"
    echo "$_p"
}

# ── Auth ──────────────────────────────────────────────────────────────────────
ensure_token() {
    [[ -n "$TOKEN" ]] && return 0
    echo
    echo "  ${B}FileBrowser login${R}  ${DIM}(${FB_URL})${R}"
    local _u _p _payload _tok
    read -r -p "  Admin username [admin]: " _u
    _u="${_u:-admin}"
    read -r -s -p "  Admin password: " _p; echo

    _payload=$(jq -n --arg u "$_u" --arg p "$_p" '{username:$u,password:$p}')
    _tok=$(curl -s -X POST "$FB_URL/api/login" \
        -H "Content-Type: application/json" -d "$_payload") || true

    if [[ -z "$_tok" ]]; then
        die "No response from FileBrowser at $FB_URL — is it running?"
    elif [[ "$_tok" == *"."*"."* ]]; then
        TOKEN="$_tok"
        ok "Logged in as $_u"
    else
        echo "  FileBrowser responded: $_tok" >&2
        die "Login failed — wrong credentials or FileBrowser not reachable"
    fi
}

api_get() { curl -sf -X GET "$FB_URL$1" -H "X-Auth: $TOKEN"; }

# ── User selection ────────────────────────────────────────────────────────────
CHOSEN_USER=""
CHOSEN_DIR=""

pick_user() {
    ensure_token
    echo

    local _raw
    _raw=$(api_get "/api/users" \
        | jq -r '.[] | [.username, .scope] | @tsv') || true
    [[ -n "$_raw" ]] || die "No users returned from FileBrowser."

    local -a _users _dirs
    local _i=0
    while IFS=$'\t' read -r _u _s; do
        # Normalise: ensure leading slash
        [[ "$_s" == /* ]] || _s="/$_s"
        _users+=("$_u")
        _dirs+=("$_s")
        printf "  %2d  %-20s  %s\n" "$((_i+1))" "$_u" "$_s"
        ((_i++)) || true
    done <<< "$_raw"
    echo

    local _pick=""
    read -r -p "  Select user (number): " _pick
    [[ "$_pick" =~ ^[0-9]+$ ]] || { errmsg "Enter a number."; return 1; }
    local _idx=$((_pick-1))
    [[ $_idx -ge 0 && $_idx -lt ${#_users[@]} ]] \
        || { errmsg "Out of range."; return 1; }

    CHOSEN_USER="${_users[$_idx]}"
    CHOSEN_DIR="${_dirs[$_idx]}"
}

# ── Parse existing extra mounts for a user ────────────────────────────────────
# Extra mounts are any volume line matching  HOST_PATH:/srv/USER_DIR/...
# (as opposed to base mounts like fb_users:/srv or ./database/... etc.)
list_extras_compose() {
    local _user_dir="$1"   # e.g. /jda
    # Match lines like:      - /absolute/path:/srv/jda/something
    grep -oP "^\s+-\s+\K/.+:/srv${_user_dir}/.+" "$COMPOSE_FILE" 2>/dev/null \
        | sed 's/.*:\(.*\)/\1/' \
        | sed "s|/srv${_user_dir}/||" \
        || true
}

list_extras_compose_full() {
    local _user_dir="$1"
    grep -oP "^\s+-\s+\K/.+:/srv${_user_dir}/.+" "$COMPOSE_FILE" 2>/dev/null \
        || true
}

# ── Add a bind-mount entry to docker-compose.yml ─────────────────────────────
add_volume_entry() {
    local _host_path="$1" _container_path="$2"

    # Check not already present
    if grep -qF "${_host_path}:${_container_path}" "$COMPOSE_FILE" 2>/dev/null; then
        errmsg "Already in docker-compose.yml."
        return 1
    fi

    # Back up before editing
    local _bk="$SCRIPT_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$_bk"

    # Insert after the settings.json volume line (our known anchor)
    # Works for both new-layout (fb_users) and legacy compose files
    if grep -q 'settings.json' "$COMPOSE_FILE"; then
        sed -i "/settings\.json/a\\      - ${_host_path}:${_container_path}" \
            "$COMPOSE_FILE"
    else
        # Fallback: insert before the ports: line
        sed -i "/^\s*ports:/i\\      - ${_host_path}:${_container_path}" \
            "$COMPOSE_FILE"
    fi

    ok "Added to docker-compose.yml: ${_host_path} → ${_container_path}"
    echo "  ${DIM}Backup saved: $(basename "$_bk")${R}"
}

# ── Remove a bind-mount entry from docker-compose.yml ────────────────────────
remove_volume_entry() {
    local _container_path="$1"

    local _bk="$SCRIPT_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$_bk"

    # Escape path for sed pattern
    local _escaped
    _escaped=$(printf '%s' "$_container_path" | sed 's|/|\\/|g')
    sed -i "/[[:space:]]-[[:space:]].*:${_escaped}/d" "$COMPOSE_FILE"

    ok "Removed from docker-compose.yml: ${_container_path}"
    echo "  ${DIM}Backup saved: $(basename "$_bk")${R}"
}

# ── Restart container ─────────────────────────────────────────────────────────
restart_container() {
    echo
    warn "A container restart is required for changes to take effect."
    local _r=""
    read -r -p "  Restart FileBrowser now? [y/N]: " _r
    [[ "${_r,,}" == "y" ]] || { echo "  Restart later with: docker compose down && docker compose up -d"; return 0; }

    cd "$SCRIPT_DIR"
    docker compose down
    docker compose up -d
    echo
    ok "FileBrowser restarted."
}

# ── Add flow ──────────────────────────────────────────────────────────────────
do_add() {
    pick_user || return 1

    local _user_dir="$CHOSEN_DIR"

    if [[ "$_user_dir" == "/" || "$_user_dir" == "/data" ]]; then
        echo
        echo "  $CHOSEN_USER has full access — no extra directories needed."
        return 0
    fi

    local _fb_path
    _fb_path=$(get_fb_path)

    banner "Add directory — $CHOSEN_USER  (${_user_dir})"

    # Show what's already added
    local _cur
    _cur=$(list_extras_compose "$_user_dir")
    if [[ -n "$_cur" ]]; then
        echo "  Already added:"
        echo "$_cur" | while read -r _n; do printf "    - %s\n" "$_n"; done
        echo
    fi

    # List available source folders on the host
    echo "  Available folders in ${_fb_path}:"
    local _avail=()
    while IFS= read -r -d '' _d; do
        local _name; _name=$(basename "$_d")
        [[ "$_name" == .* ]] && continue  # skip hidden
        _avail+=("$_name")
        printf "    %s\n" "$_name"
    done < <(find "$_fb_path" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)

    [[ ${#_avail[@]} -gt 0 ]] || { echo "    (none found)"; return 0; }
    echo

    local _changed=false
    while true; do
        local _src=""
        read -r -p "  Folder to add [done]: " _src
        [[ -n "$_src" ]] || break

        _src="${_src#/}"; _src="${_src%/}"
        [[ -n "$_src" ]] || continue

        local _host_path="$_fb_path/$_src"
        local _container_path="/srv${_user_dir}/$_src"

        if [[ ! -d "$_host_path" ]]; then
            errmsg "'$_src' not found in $_fb_path"
            continue
        fi

        # The container path may land inside an existing bind-mount (e.g. /srv/data/...).
        # Docker needs an empty mount-point directory to already exist on the host at that
        # location before it can overlay the inner mount on top of the outer one.
        # Derive the host equivalent: strip /srv/data prefix → prepend FB_PATH.
        local _mount_point_host=""
        if [[ "$_container_path" == /srv/data/* ]]; then
            _mount_point_host="$_fb_path/${_container_path#/srv/data/}"
        elif [[ "$_container_path" == /srv/* ]]; then
            # Legacy layout: /srv IS the bind mount
            _mount_point_host="$_fb_path/${_container_path#/srv/}"
        fi

        if [[ -n "$_mount_point_host" && ! -d "$_mount_point_host" ]]; then
            mkdir -p "$_mount_point_host" \
                && echo "  ${DIM}Created mount point: $_mount_point_host${R}" \
                || { errmsg "Could not create mount point '$_mount_point_host' — check permissions."; continue; }
        fi

        add_volume_entry "$_host_path" "$_container_path" && _changed=true || true
    done

    [[ "$_changed" == true ]] && restart_container || true
}

# ── Remove flow ───────────────────────────────────────────────────────────────
do_remove() {
    pick_user || return 1

    local _user_dir="$CHOSEN_DIR"
    banner "Remove directory — $CHOSEN_USER  (${_user_dir})"

    local _extras
    _extras=$(list_extras_compose_full "$_user_dir")
    if [[ -z "$_extras" ]]; then
        echo "  No extra directories configured for $CHOSEN_USER."
        return 0
    fi

    echo "  Extra directories for $CHOSEN_USER:"
    echo
    local -a _names _container_paths
    local _i=0
    while IFS= read -r _line; do
        local _cpath; _cpath="${_line##*:}"
        local _fname; _fname="${_cpath##*/}"
        _names+=("$_fname")
        _container_paths+=("$_cpath")
        printf "  %2d  %s\n" "$((_i+1))" "$_fname"
        ((_i++)) || true
    done <<< "$_extras"
    echo

    local _pick=""
    read -r -p "  Select entry to remove (number): " _pick
    [[ "$_pick" =~ ^[0-9]+$ ]] || { errmsg "Enter a number."; return 1; }
    local _idx=$((_pick-1))
    [[ $_idx -ge 0 && $_idx -lt ${#_names[@]} ]] || { errmsg "Out of range."; return 1; }

    remove_volume_entry "${_container_paths[$_idx]}"
    restart_container
}

# ── Show flow ─────────────────────────────────────────────────────────────────
do_show() {
    pick_user || return 1

    banner "Extra directories — $CHOSEN_USER  (${CHOSEN_DIR})"

    local _extras
    _extras=$(list_extras_compose "$CHOSEN_DIR")
    if [[ -n "$_extras" ]]; then
        echo "$_extras" | while read -r _n; do printf "    - %s\n" "$_n"; done
    else
        echo "    (none configured)"
    fi
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
require_cmds curl jq docker

while true; do
    banner "FileBrowser — Extra Directories"
    echo "  ${DIM}Adds bind-mount entries so users can access extra folders.${R}"
    echo "  ${DIM}Create/delete users via the FileBrowser web UI.${R}"
    echo
    echo "  1  Add a directory to a user"
    echo "  2  Remove a directory from a user"
    echo "  3  Show a user's extra directories"
    echo "  0  Exit"
    echo
    _ch=""
    read -r -p "  Choice: " _ch

    case "$_ch" in
        1) do_add    || true ;;
        2) do_remove || true ;;
        3) do_show   || true ;;
        0) echo; echo "  Goodbye."; echo; exit 0 ;;
        *) errmsg "Invalid choice." ;;
    esac
done
