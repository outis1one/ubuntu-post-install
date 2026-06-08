#!/usr/bin/env bash
# manage_users.sh — Add/remove extra folder access for FileBrowser users.
#
# Placed in ~/docker/filebrowser/ by the filebrowser installer.
# Requires: curl, jq, docker   (sudo apt install curl jq)
#
# FileBrowser only gives each user one root directory. This script adds
# shortcuts inside that directory so a user can reach multiple folders
# without getting full access to everything.
#
# Create and manage users through the FileBrowser web UI instead.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB_URL="${FB_URL:-http://localhost:8085}"
TOKEN=""

# ── Output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    B=$'\e[1m' R=$'\e[0m' GRN=$'\e[32m' RED=$'\e[31m' DIM=$'\e[2m'
else
    B="" R="" GRN="" RED="" DIM=""
fi

die()    { echo "${RED}ERROR:${R} $*" >&2; exit 1; }
ok()     { echo "  ${GRN}✓${R} $*"; }
errmsg() { echo "  ${RED}✗${R} $*" >&2; }
hr()     { printf '  %s\n' "────────────────────────────────────────────"; }
banner() { echo; hr; printf "  ${B}%-44s${R}\n" "$*"; hr; }

# ── Prerequisites ─────────────────────────────────────────────────────────────
require_cmds() {
    for _c in "$@"; do
        command -v "$_c" &>/dev/null || die "'$_c' not found — sudo apt install $_c"
    done
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
        -H "Content-Type: application/json" \
        -d "$_payload") || true

    if [[ -z "$_tok" ]]; then
        die "No response from FileBrowser at $FB_URL — is it running? (docker compose up -d)"
    elif [[ "$_tok" == *"."*"."* ]]; then
        TOKEN="$_tok"
        ok "Logged in as $_u"
    else
        echo "  FileBrowser responded: $_tok" >&2
        die "Login failed — wrong credentials or FileBrowser not reachable at $FB_URL"
    fi
}

api_get() { curl -sf -X GET "$FB_URL$1" -H "X-Auth: $TOKEN"; }

# ── Docker helpers ────────────────────────────────────────────────────────────
get_container_name() {
    local _compose="$SCRIPT_DIR/docker-compose.yml"
    if [[ -f "$_compose" ]]; then
        local _name
        _name=$(grep 'container_name:' "$_compose" | head -1 | awk '{print $2}')
        [[ -n "$_name" ]] && { echo "$_name"; return; }
    fi
    echo "filebrowser"
}

check_container() {
    local _running
    _running=$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null || echo "false")
    [[ "$_running" == "true" ]] \
        || die "Container '$1' is not running — start it first: docker compose up -d"
}

# Returns /srv/data (new named-volume layout) or /srv (legacy bind-mount layout).
get_data_root() {
    local _c="$1"
    if docker exec "$_c" test -d /srv/data 2>/dev/null; then
        echo "/srv/data"
    else
        echo "/srv"
    fi
}

# ── User selection ────────────────────────────────────────────────────────────
# Prints a numbered list and returns chosen username + directory via globals.
CHOSEN_USER=""
CHOSEN_DIR=""

pick_user() {
    ensure_token
    echo

    local _raw
    _raw=$(api_get "/api/users" | jq -r '.[] | [.username, .scope] | @tsv') || true
    [[ -n "$_raw" ]] || die "No users returned from FileBrowser."

    local -a _users _dirs
    local _i=0
    while IFS=$'\t' read -r _u _s; do
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
    [[ $_idx -ge 0 && $_idx -lt ${#_users[@]} ]] || { errmsg "Out of range."; return 1; }

    CHOSEN_USER="${_users[$_idx]}"
    CHOSEN_DIR="${_dirs[$_idx]}"
}

# ── Directory listing ─────────────────────────────────────────────────────────
list_extras() {
    local _c="$1" _dir="$2"
    docker exec "$_c" find "/srv$_dir" -maxdepth 1 -type l \
        -exec sh -c '
            _name=$(basename "$1")
            _target=$(readlink "$1")
            _display="${_target#/srv}"
            [ -z "$_display" ] && _display="/"
            printf "    %-24s→  %s\n" "$_name" "$_display"
        ' _ {} \; 2>/dev/null | sort || true
}

# ── Add extra directories ─────────────────────────────────────────────────────
add_extras() {
    local _dir="$1" _c="$2" _data_root="$3"
    local _scope_dir="/srv$_dir"

    if ! docker exec "$_c" test -d "$_scope_dir" 2>/dev/null; then
        echo
        echo "  The directory '$_dir' does not exist in the container yet."
        local _mk=""
        read -r -p "  Create it now? [y/N]: " _mk
        if [[ "${_mk,,}" == "y" ]]; then
            docker exec "$_c" mkdir -p "$_scope_dir" \
                || die "Could not create '$_scope_dir' (permission denied?)."
            ok "Created '$_dir'"
        else
            errmsg "Cannot add extras — '$_dir' must exist first."
            return 1
        fi
    fi

    echo
    echo "  Type a folder name to add — ? to list available, blank when done."
    echo

    while true; do
        local _src=""
        read -r -p "  Folder to add [done]: " _src
        [[ -n "$_src" ]] || break

        if [[ "$_src" == "?" ]]; then
            local _avail
            _avail=$(docker exec "$_c" find "$_data_root" -maxdepth 1 -mindepth 1 \
                \( -type d -o -type l \) -not -name ".*" 2>/dev/null \
                | sed "s|^${_data_root}/||" | sort | tr '\n' '  ') || true
            echo "  Available:  ${_avail:-(none found)}"
            echo
            continue
        fi

        _src="${_src#/}"; _src="${_src%/}"
        [[ -n "$_src" ]] || continue

        local _target="$_data_root/$_src"
        local _link_name; _link_name=$(basename "$_src")
        local _link_path="$_scope_dir/$_link_name"

        if ! docker exec "$_c" test -e "$_target" 2>/dev/null; then
            errmsg "'$_src' not found — type ? to see available folders."
            continue
        fi
        if docker exec "$_c" test -e "$_link_path" 2>/dev/null; then
            errmsg "'$_link_name' already added."
            continue
        fi
        if ! docker exec "$_c" ln -s "$_target" "$_link_path" 2>/dev/null; then
            errmsg "Failed to add '$_link_name' (check: docker logs filebrowser)."
            continue
        fi
        ok "Added '$_link_name'"
    done
}

# ── Remove extra directory ────────────────────────────────────────────────────
remove_extra() {
    local _dir="$1" _c="$2"
    local _scope_dir="/srv$_dir"

    echo
    local _links
    _links=$(list_extras "$_c" "$_dir")
    if [[ -z "$_links" ]]; then
        echo "  No extras to remove."
        return 0
    fi
    echo "$_links"
    echo

    local _name=""
    read -r -p "  Name to remove: " _name
    [[ -n "$_name" ]] || return 0

    local _link_path="$_scope_dir/$_name"
    if ! docker exec "$_c" test -L "$_link_path" 2>/dev/null; then
        errmsg "'$_name' is not an added folder — not removing."
        return 1
    fi
    docker exec "$_c" rm "$_link_path"
    ok "'$_name' removed."
}

# ── Main ──────────────────────────────────────────────────────────────────────
require_cmds curl jq docker

_c=$(get_container_name)
check_container "$_c"
_data_root=$(get_data_root "$_c")

while true; do
    banner "FileBrowser — Extra Folder Access"
    echo "  ${DIM}Manage additional folders for users beyond their root directory.${R}"
    echo "  ${DIM}Create/delete users in the FileBrowser web UI.${R}"
    echo
    echo "  1  Add extra folders to a user"
    echo "  2  Remove an extra folder from a user"
    echo "  3  Show a user's extra folders"
    echo "  0  Exit"
    echo
    _ch=""
    read -r -p "  Choice: " _ch

    case "$_ch" in
        1)
            pick_user || continue
            banner "Add extras — $CHOSEN_USER  (${CHOSEN_DIR})"
            if [[ "$CHOSEN_DIR" == "/" || "$CHOSEN_DIR" == "/data" ]]; then
                echo "  This user has full access — no extras needed."
            else
                add_extras "$CHOSEN_DIR" "$_c" "$_data_root" || true
            fi
            ;;
        2)
            pick_user || continue
            banner "Remove extra — $CHOSEN_USER  (${CHOSEN_DIR})"
            remove_extra "$CHOSEN_DIR" "$_c" || true
            ;;
        3)
            pick_user || continue
            banner "Extras — $CHOSEN_USER  (${CHOSEN_DIR})"
            _links=$(list_extras "$_c" "$CHOSEN_DIR")
            if [[ -n "$_links" ]]; then echo "$_links"; else echo "  (none)"; fi
            echo
            ;;
        0) echo; echo "  Goodbye."; echo; exit 0 ;;
        *) errmsg "Invalid choice." ;;
    esac
done
