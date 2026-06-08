#!/usr/bin/env bash
# additional_directories.sh — Give FileBrowser users access to extra folders.
#
# Placed in ~/docker/filebrowser/ by the installer.
# Requires: curl, jq, docker   (sudo apt install curl jq)
#
# FileBrowser gives each user one root directory (scope).  This script lets
# you mount additional folders into that root so the user sees them alongside
# their own files.
#
# IMPORTANT — avoid nested bind-mounts:
#   If a user's scope lives inside the main data bind-mount (/data/...) adding
#   extra folders would require nesting one bind-mount inside another, which
#   Docker does not handle reliably.  This script detects that situation and
#   migrates the user's scope into the named volume (/srv) instead, where
#   additional bind-mounts work cleanly.
#
#   Old (broken):   scope=/data/users/alice  → inside /srv/data bind-mount
#   New (correct):  scope=/alice             → inside fb_users named volume
#     Mounts added: /srv/alice/my-files  → /host/data/users/alice/
#                   /srv/alice/music     → /host/data/music/
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
info()   { echo "  $*"; }
errmsg() { echo "  ${RED}✗${R} $*" >&2; }
hr()     { printf '  %s\n' "────────────────────────────────────────────"; }
banner() { echo; hr; printf "  ${B}%-44s${R}\n" "$*"; hr; }

require_cmds() {
    for _c in "$@"; do
        command -v "$_c" &>/dev/null || die "'$_c' not found — sudo apt install $_c"
    done
}

[[ -f "$COMPOSE_FILE" ]] || die "docker-compose.yml not found at $COMPOSE_FILE"

# ── Read FB_PATH from .env or docker-compose.yml ──────────────────────────────
get_fb_path() {
    local _p=""
    if [[ -f "$ENV_FILE" ]]; then
        _p=$(grep '^FB_PATH=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
    fi
    if [[ -z "$_p" ]]; then
        _p=$(grep -oP '^\s+-\s+\K[^$][^:]+(?=:/srv(/data)?(\s|$))' \
             "$COMPOSE_FILE" 2>/dev/null | head -1) || true
    fi
    [[ -n "$_p" ]] || die "Cannot determine FB_PATH — check $ENV_FILE"
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

api_get() { curl -sf -X GET  "$FB_URL$1" -H "X-Auth: $TOKEN"; }
api_put() { curl -sf -X PUT  "$FB_URL$1" -H "X-Auth: $TOKEN" \
                -H "Content-Type: application/json" -d "$2"; }

find_user() {
    api_get "/api/users" | jq -r --arg u "$1" '.[] | select(.username==$u)'
}

update_user_scope() {
    local _username="$1" _new_scope="$2"
    local _user _uid _body
    _user=$(find_user "$_username") || true
    [[ -n "$_user" ]] || { errmsg "User '$_username' not found in FileBrowser."; return 1; }
    _uid=$(echo "$_user" | jq -r '.id')
    _body=$(echo "$_user" | jq --arg s "$_new_scope" '. + {scope: $s}')
    api_put "/api/users/$_uid" "$_body" >/dev/null \
        || { errmsg "API call to update scope failed."; return 1; }
}

# ── User selection ────────────────────────────────────────────────────────────
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
        [[ "$_s" == /* ]] || _s="/$_s"
        _users+=("$_u"); _dirs+=("$_s")
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

# ── Scope classification ──────────────────────────────────────────────────────
# Returns true if the scope lives inside the /data bind-mount path.
# Extra mounts for such users would be nested — unreliable.
scope_is_nested() {
    [[ "$1" == /data/* || "$1" == "/data" ]]
}

# Suggest a named-volume scope path from the current scope.
# /data/users/alice → /alice
suggest_volume_scope() {
    local _last; _last=$(basename "$1")
    echo "/$_last"
}

# ── Compose file helpers ──────────────────────────────────────────────────────
list_user_mounts() {
    local _scope="$1"
    # Match lines:   - /absolute/path:/srv<scope>/something
    grep -oP "^\s+-\s+\K/.+:/srv${_scope}/.+" "$COMPOSE_FILE" 2>/dev/null \
        | while IFS=: read -r _host _cont; do
            printf "    %-30s→  %s\n" "$(basename "$_cont")" "$_host"
          done || true
}

list_user_mounts_raw() {
    local _scope="$1"
    grep -oP "^\s+-\s+\K/.+:/srv${_scope}/.+" "$COMPOSE_FILE" 2>/dev/null || true
}

add_volume_entry() {
    local _host_path="$1" _container_path="$2"

    if grep -qF "${_host_path}:${_container_path}" "$COMPOSE_FILE" 2>/dev/null; then
        warn "'$(basename "$_container_path")' already in docker-compose.yml."
        return 0
    fi

    local _bk="$SCRIPT_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$_bk"

    if grep -q 'settings.json' "$COMPOSE_FILE"; then
        sed -i "/settings\.json/a\\      - ${_host_path}:${_container_path}" "$COMPOSE_FILE"
    else
        sed -i "/^\s*ports:/i\\      - ${_host_path}:${_container_path}" "$COMPOSE_FILE"
    fi

    ok "Mounted: $(basename "$_host_path")  →  $_container_path"
    echo "  ${DIM}Backup: $(basename "$_bk")${R}"
}

remove_volume_entry() {
    local _container_path="$1"
    local _bk="$SCRIPT_DIR/docker-compose.yml.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$COMPOSE_FILE" "$_bk"
    local _escaped; _escaped=$(printf '%s' "$_container_path" | sed 's|/|\\/|g')
    sed -i "/[[:space:]]-[[:space:]].*:${_escaped}/d" "$COMPOSE_FILE"
    ok "Removed: $_container_path"
    echo "  ${DIM}Backup: $(basename "$_bk")${R}"
}

# ── Restart ───────────────────────────────────────────────────────────────────
restart_container() {
    echo
    warn "Container restart required for changes to take effect."
    local _r=""
    read -r -p "  Restart FileBrowser now? [y/N]: " _r
    [[ "${_r,,}" == "y" ]] || {
        echo "  Run later:  docker compose down && docker compose up -d"
        return 0
    }
    cd "$SCRIPT_DIR"
    docker compose down
    docker compose up -d
    echo
    ok "FileBrowser restarted."
}

# ── Migrate scope from /data/... to named volume ──────────────────────────────
migrate_scope() {
    local _username="$1" _old_scope="$2" _fb_path="$3"
    local _c; _c=$(get_container_name)

    echo
    echo "  ${B}Scope migration required${R}"
    echo
    info "  ${CHOSEN_USER}'s scope ($_old_scope) is inside the /srv/data bind-mount."
    info "  Extra mounts nested inside a bind-mount are unreliable in Docker."
    info "  We'll move the scope to the named volume so mounts work cleanly."
    echo

    # Suggest new scope name
    local _suggested; _suggested=$(suggest_volume_scope "$_old_scope")
    local _new_scope=""
    read -r -p "  New scope path [${_suggested}]: " _new_scope
    _new_scope="${_new_scope:-$_suggested}"
    [[ "$_new_scope" == /* ]] || _new_scope="/$_new_scope"

    # Refuse if new scope is still inside /data
    if scope_is_nested "$_new_scope"; then
        errmsg "New scope '$_new_scope' is still inside /data — choose a path like $_suggested"
        return 1
    fi

    # Check not already used as a mount
    if grep -qF ":/srv${_new_scope}" "$COMPOSE_FILE" 2>/dev/null; then
        errmsg "'/srv${_new_scope}' is already used in docker-compose.yml"
        return 1
    fi

    echo
    # Create the scope directory in the named volume via docker exec
    if ! docker exec "$_c" test -d "/srv${_new_scope}" 2>/dev/null; then
        docker exec "$_c" mkdir -p "/srv${_new_scope}" \
            || { errmsg "Could not create '/srv${_new_scope}' in container."; return 1; }
        ok "Created /srv${_new_scope} in named volume"
    fi

    # Offer to keep personal files accessible as a sub-folder
    local _personal_host="$_fb_path/${_old_scope#/data/}"
    if [[ -d "$_personal_host" ]]; then
        echo
        info "  Personal files found at: $_personal_host"
        local _pname=""
        read -r -p "  Mount them as [my-files]: " _pname
        _pname="${_pname:-my-files}"
        add_volume_entry "$_personal_host" "/srv${_new_scope}/${_pname}"
    fi

    # Update scope in FileBrowser via API
    update_user_scope "$_username" "$_new_scope" \
        || { errmsg "Scope update failed — change it manually in the FileBrowser web UI."; }
    ok "Scope updated in FileBrowser: $_old_scope  →  $_new_scope"

    # Return new scope for caller to use
    CHOSEN_DIR="$_new_scope"
}

# ── Container name ────────────────────────────────────────────────────────────
get_container_name() {
    local _name
    _name=$(grep 'container_name:' "$COMPOSE_FILE" | head -1 | awk '{print $2}')
    echo "${_name:-filebrowser}"
}

# ── Add flow ──────────────────────────────────────────────────────────────────
do_add() {
    pick_user || return 1

    local _user_dir="$CHOSEN_DIR"

    if [[ "$_user_dir" == "/" || "$_user_dir" == "/data" ]]; then
        echo
        info "$CHOSEN_USER has full access — no extras needed."
        return 0
    fi

    local _fb_path; _fb_path=$(get_fb_path)

    # Migrate if scope is nested inside the data bind-mount
    if scope_is_nested "$_user_dir"; then
        migrate_scope "$CHOSEN_USER" "$_user_dir" "$_fb_path" || return 1
        _user_dir="$CHOSEN_DIR"   # updated by migrate_scope
    fi

    banner "Add directory — $CHOSEN_USER  (${_user_dir})"

    # Show already-mounted extras
    local _cur; _cur=$(list_user_mounts "$_user_dir")
    if [[ -n "$_cur" ]]; then
        info "Already added:"
        echo "$_cur"
        echo
    fi

    # List available source folders on the host
    info "Available folders in ${_fb_path}:"
    local _avail=()
    while IFS= read -r -d '' _d; do
        local _name; _name=$(basename "$_d")
        [[ "$_name" == .* ]] && continue
        _avail+=("$_name")
        printf "    %s\n" "$_name"
    done < <(find "$_fb_path" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null | sort -z)

    [[ ${#_avail[@]} -gt 0 ]] || { info "(none found)"; return 0; }
    echo

    local _changed=false
    while true; do
        local _src=""
        read -r -p "  Folder to add [done]: " _src
        [[ -n "$_src" ]] || break

        _src="${_src#/}"; _src="${_src%/}"
        [[ -n "$_src" ]] || continue

        local _host_path="$_fb_path/$_src"
        if [[ ! -d "$_host_path" ]]; then
            errmsg "'$_src' not found in $_fb_path"
            continue
        fi

        # Ask what name to show in FileBrowser (default: same as folder)
        local _display=""
        read -r -p "  Show as [${_src}]: " _display
        _display="${_display:-$_src}"
        _display="${_display#/}"; _display="${_display%/}"

        local _container_path="/srv${_user_dir}/${_display}"

        add_volume_entry "$_host_path" "$_container_path" && _changed=true || true
    done

    [[ "$_changed" == true ]] && restart_container || true
}

# ── Remove flow ───────────────────────────────────────────────────────────────
do_remove() {
    pick_user || return 1

    local _user_dir="$CHOSEN_DIR"
    banner "Remove directory — $CHOSEN_USER  (${_user_dir})"

    local _extras; _extras=$(list_user_mounts_raw "$_user_dir")
    if [[ -z "$_extras" ]]; then
        info "No extra directories configured for $CHOSEN_USER."
        return 0
    fi

    local -a _lines
    local _i=0
    while IFS= read -r _line; do
        _lines+=("$_line")
        local _cpath="${_line##*:}"
        printf "  %2d  %s\n" "$((_i+1))" "$(basename "$_cpath")"
        ((_i++)) || true
    done <<< "$_extras"
    echo

    local _pick=""
    read -r -p "  Select entry to remove (number): " _pick
    [[ "$_pick" =~ ^[0-9]+$ ]] || { errmsg "Enter a number."; return 1; }
    local _idx=$((_pick-1))
    [[ $_idx -ge 0 && $_idx -lt ${#_lines[@]} ]] || { errmsg "Out of range."; return 1; }

    local _cpath="${_lines[$_idx]##*:}"
    remove_volume_entry "$_cpath"
    restart_container
}

# ── Show flow ─────────────────────────────────────────────────────────────────
do_show() {
    pick_user || return 1
    banner "Extra directories — $CHOSEN_USER  (${CHOSEN_DIR})"
    local _mounts; _mounts=$(list_user_mounts "$CHOSEN_DIR")
    if [[ -n "$_mounts" ]]; then
        echo "$_mounts"
    else
        info "(none configured)"
    fi
    echo
}

# ── Main ──────────────────────────────────────────────────────────────────────
require_cmds curl jq docker

while true; do
    banner "FileBrowser — Extra Directories"
    echo "  ${DIM}Manage extra folder access for users.${R}"
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
        1) do_add    || true ;;
        2) do_remove || true ;;
        3) do_show   || true ;;
        0) echo; echo "  Goodbye."; echo; exit 0 ;;
        *) errmsg "Invalid choice." ;;
    esac
done
