#!/usr/bin/env bash
# manage_users.sh — FileBrowser user management via the REST API.
#
# Placed in ~/docker/filebrowser/ by the filebrowser installer.
# Requires: curl, jq   (sudo apt install curl jq)
#
# Run with no arguments for the interactive menu.
# Pass a command for one-shot use (see --help).
#
# ── Username rules ────────────────────────────────────────────────────────────
#   Letters, numbers, hyphens, underscores only.  No spaces, dots, or @.
#   Examples:  alice   bob-smith   data_user2
#
# ── Password rules ────────────────────────────────────────────────────────────
#   Minimum 8 characters.  No maximum.
#   Must contain at least one letter and one number.
#
# ── Scope ─────────────────────────────────────────────────────────────────────
#   Scope is the root folder a user sees when they log in.
#   It is a path inside the container relative to /srv.
#
#   New layout (fb_users named volume + /srv/data bind mount):
#     /data      → full access to all files (FB_PATH on the host)
#     /alice     → alice's private home folder (stored in Docker volume only)
#
#   Legacy layout (FB_PATH mounted directly at /srv):
#     /          → full access
#     /alice     → alice's private subdir inside FB_PATH on the host
#
# ── Additional directories ────────────────────────────────────────────────────
#   Each user has exactly one scope, but you can give them access to more
#   folders by adding directory shortcuts inside their scope.
#   FileBrowser follows symlinks, so a link placed in /alice pointing to
#   /data/music lets alice browse "music" alongside her own files.
#   These shortcuts live in the Docker named volume — no clutter on the host.
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

# ── Validation ────────────────────────────────────────────────────────────────
validate_username() {
    [[ -n "$1" ]]                   || { errmsg "Username cannot be empty."; return 1; }
    [[ "$1" =~ ^[a-zA-Z0-9_-]+$ ]] || {
        errmsg "Invalid username '$1'. Use only letters, numbers, hyphens, underscores."
        return 1
    }
}

validate_password() {
    [[ ${#1} -ge 8 ]]      || { errmsg "Password too short (minimum 8 characters)."; return 1; }
    [[ "$1" =~ [a-zA-Z] ]] || { errmsg "Password must contain at least one letter."; return 1; }
    [[ "$1" =~ [0-9] ]]    || { errmsg "Password must contain at least one number."; return 1; }
}

validate_scope() {
    [[ "$1" == /* ]] || { errmsg "Scope must start with /  (e.g. / or /alice or /music)"; return 1; }
}

# prompt_password VARNAME [label]
# Uses nameref (bash 4.3+) so the caller's local variable is set correctly.
prompt_password() {
    local -n _pp_ref="$1"
    local _label="${2:-New password}"
    local _p1 _p2
    while true; do
        read -r -s -p "  $_label: " _p1; echo
        validate_password "$_p1" || continue
        read -r -s -p "  Confirm:  " _p2; echo
        [[ "$_p1" == "$_p2" ]] || { errmsg "Passwords do not match. Try again."; continue; }
        _pp_ref="$_p1"
        break
    done
}

# ── Auth — login once, reuse token ────────────────────────────────────────────
ensure_token() {
    [[ -n "$TOKEN" ]] && return 0
    echo
    echo "  ${B}FileBrowser login${R}  ${DIM}(${FB_URL})${R}"
    local _u _p _payload _tok
    read -r -p "  Admin username [admin]: " _u
    _u="${_u:-admin}"
    read -r -s -p "  Admin password: " _p; echo

    # Build JSON with jq so special characters in passwords don't break the payload
    _payload=$(jq -n --arg u "$_u" --arg p "$_p" '{username:$u,password:$p}')

    # || true prevents set -e from exiting silently on connection refused
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
        die "Login failed — wrong credentials, or FileBrowser is not reachable at $FB_URL"
    fi
}

# ── REST wrappers ─────────────────────────────────────────────────────────────
api_get()    { curl -sf -X GET    "$FB_URL$1" -H "X-Auth: $TOKEN"; }
api_post()   { curl -sf -X POST   "$FB_URL$1" -H "X-Auth: $TOKEN" \
                   -H "Content-Type: application/json" -d "$2"; }
api_put()    { curl -sf -X PUT    "$FB_URL$1" -H "X-Auth: $TOKEN" \
                   -H "Content-Type: application/json" -d "$2"; }
api_delete() { curl -sf -X DELETE "$FB_URL$1" -H "X-Auth: $TOKEN"; }

find_user() {
    api_get "/api/users" | jq -r --arg u "$1" '.[] | select(.username==$u)'
}

get_user_id() {
    local _j
    _j=$(find_user "$1")
    [[ -n "$_j" ]] || { errmsg "User '$1' not found."; return 1; }
    echo "$_j" | jq -r '.id'
}

default_perms() {
    echo '{"admin":false,"execute":false,"create":true,"rename":true,
           "modify":true,"delete":true,"share":false,"download":true}'
}

# ── Docker helpers ─────────────────────────────────────────────────────────────

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
    require_cmds docker
    local _running
    _running=$(docker inspect --format='{{.State.Running}}' "$1" 2>/dev/null || echo "false")
    [[ "$_running" == "true" ]] \
        || { errmsg "Container '$1' is not running. Start it: docker compose up -d"; return 1; }
}

# Returns /srv/data if the new named-volume layout is in use, else /srv (legacy).
get_data_root() {
    local _c="$1"
    if docker exec "$_c" test -d /srv/data 2>/dev/null; then
        echo "/srv/data"
    else
        echo "/srv"
    fi
}

# Print additional directories inside /srv<scope>, one per line.
list_links() {
    local _c="$1" _scope="$2"
    docker exec "$_c" find "/srv$_scope" -maxdepth 1 -type l \
        -exec sh -c '
            _name=$(basename "$1")
            _target=$(readlink "$1")
            _display="${_target#/srv}"
            [ -z "$_display" ] && _display="/"
            printf "    %-24s→  %s\n" "$_name" "$_display"
        ' _ {} \; 2>/dev/null | sort || true
}

# ── prompt_add_dirs SCOPE ─────────────────────────────────────────────────────
# Loop: user types folder names as they appear in FileBrowser — blank to finish.
# Shared by cmd_add (offered inline) and menu_add_dirs (add option).
prompt_add_dirs() {
    local _scope="$1"
    local _c _data_root
    _c=$(get_container_name)
    check_container "$_c" || return 1
    _data_root=$(get_data_root "$_c")

    local _scope_dir="/srv$_scope"
    if ! docker exec "$_c" mkdir -p "$_scope_dir" 2>/dev/null; then
        errmsg "Could not create scope directory '$_scope_dir' in container (permission denied?)."
        return 1
    fi

    echo
    echo "  Type a folder name to add — ? to list available folders, blank when done."
    echo

    while true; do
        local _src=""
        read -r -p "  Directory to add [done]: " _src
        [[ -n "$_src" ]] || break

        if [[ "$_src" == "?" ]]; then
            local _avail
            _avail=$(docker exec "$_c" find "$_data_root" -maxdepth 1 -mindepth 1 \
                \( -type d -o -type l \) \
                -not -name ".*" 2>/dev/null \
                | sed "s|^${_data_root}/||" | sort | tr '\n' '  ') || true
            echo "  Available:  ${_avail:-(none — no subdirectories found)}"
            echo
            continue
        fi

        # Normalise: strip surrounding slashes
        _src="${_src#/}"
        _src="${_src%/}"
        [[ -n "$_src" ]] || continue

        local _target="$_data_root/$_src"
        local _link_name
        _link_name=$(basename "$_src")

        if ! docker exec "$_c" test -e "$_target" 2>/dev/null; then
            errmsg "'$_src' not found — type ? to see available folders."
            continue
        fi

        local _link_path="$_scope_dir/$_link_name"
        if docker exec "$_c" test -e "$_link_path" 2>/dev/null; then
            errmsg "'$_link_name' already added — use Remove to clear it first."
            continue
        fi

        if ! docker exec "$_c" ln -s "$_target" "$_link_path" 2>/dev/null; then
            errmsg "Failed to add directory (check: docker logs filebrowser)."
            continue
        fi
        if [[ "$_src" == "$_link_name" ]]; then
            ok "Added '$_link_name' to user's view"
        else
            ok "Added '$_link_name'  ${DIM}(from $_src)${R}"
        fi
    done
}

# ── Additional directories submenu (shown from Modify option 5) ──────────────
menu_add_dirs() {
    local _scope="$1"
    local _c
    _c=$(get_container_name)
    check_container "$_c" || return 1

    while true; do
        banner "Additional directories  (scope: $_scope)"
        echo "  Folders this user can access beyond their scope:"
        echo
        local _links
        _links=$(list_links "$_c" "$_scope")
        if [[ -n "$_links" ]]; then
            echo "$_links"
        else
            echo "    (none)"
        fi
        echo
        echo "  1  Add a directory"
        echo "  2  Remove a directory"
        echo "  0  Back"
        echo
        local _ch=""
        read -r -p "  Choice: " _ch
        case "$_ch" in
            1) prompt_add_dirs "$_scope" || true ;;
            2)
                local _link_name=""
                echo
                read -r -p "  Directory name to remove: " _link_name
                [[ -n "$_link_name" ]] || continue
                local _link_path="/srv${_scope}/${_link_name}"
                if ! docker exec "$_c" test -L "$_link_path" 2>/dev/null; then
                    errmsg "'$_link_name' is not an added directory — refusing to delete."
                    continue
                fi
                docker exec "$_c" rm "$_link_path"
                ok "'$_link_name' removed."
                ;;
            0) break ;;
            *) errmsg "Invalid choice." ;;
        esac
    done
}

# ── cmd: list ─────────────────────────────────────────────────────────────────
cmd_list() {
    ensure_token
    echo
    printf "  ${B}%-22s  %-5s  %s${R}\n" "USERNAME" "ADMIN" "SCOPE"
    printf "  %-22s  %-5s  %s\n"         "--------" "-----" "-----"
    api_get "/api/users" | \
        jq -r '.[] | [.username, (if .perm.admin then "yes" else "no" end), .scope] | @tsv' | \
        while IFS=$'\t' read -r _u _a _s; do
            printf "  %-22s  %-5s  %s\n" "$_u" "$_a" "$_s"
        done
    echo
}

# ── cmd: add ─────────────────────────────────────────────────────────────────
cmd_add() {
    local _username="${1:-}" _scope="${2:-}" _is_admin="false"
    [[ "${3:-}" == "--admin" ]] && _is_admin="true"

    ensure_token

    if [[ -z "$_username" ]]; then
        echo
        echo "  ${B}Username:${R} letters, numbers, hyphens, underscores only. No dots or @."
        echo "  ${B}Password:${R} min 8 chars, at least 1 letter and 1 number."
        echo "  ${B}Scope:${R}    the root folder the user sees — add extra directories after."
        echo
        read -r -p "  Username: " _username
        local _adm=""
        read -r -p "  Admin?    [y/N]: " _adm
        [[ "${_adm,,}" == "y" ]] && _is_admin="true"
    fi

    validate_username "$_username" || return 1

    if [[ -z "$_scope" ]]; then
        echo
        echo "  Scope — what the user sees as their root when they log in:"
        echo "    /data        full access to all files  (new layout)"
        echo "    /            full access to all files  (legacy layout)"
        echo "    /$_username   private home folder for this user"
        echo "    /music       music folder only (no home, can't add extras)"
        echo
        read -r -p "  Scope for '$_username': " _scope
        _scope="/${_scope#/}"   # ensure leading /
    fi

    validate_scope "$_scope" || return 1

    local _ex
    _ex=$(find_user "$_username")
    if [[ -n "$_ex" ]]; then
        errmsg "User '$_username' already exists. Use Modify to change it."
        return 1
    fi

    echo
    local password=""
    prompt_password password "Password for $_username"

    local _perms _body
    _perms=$(default_perms)
    [[ "$_is_admin" == "true" ]] && _perms=$(echo "$_perms" | jq '.admin = true')
    _body=$(jq -n \
        --arg u "$_username" --arg p "$password" --arg s "$_scope" \
        --argjson perms "$_perms" \
        '{username:$u, password:$p, scope:$s, locale:"en", viewMode:"list",
          perm:$perms, commands:[], lockPassword:false}')

    local _resp _http_code
    _resp=$(curl -s -w '\n%{http_code}' -X POST "$FB_URL/api/users" \
        -H "X-Auth: $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$_body" 2>&1) || true
    _http_code=$(printf '%s' "$_resp" | tail -1)
    _resp=$(printf '%s' "$_resp" | head -n -1)

    if [[ "$_http_code" != "200" && "$_http_code" != "201" ]]; then
        local _msg
        _msg=$(printf '%s' "$_resp" | jq -r '.message // .error // empty' 2>/dev/null) || true
        [[ -z "$_msg" ]] && _msg="$_resp"
        [[ -z "$_msg" ]] && _msg="HTTP $_http_code"
        errmsg "Failed to create user '$_username': $_msg"
        return 1
    fi

    echo
    ok "User '$_username' created  |  scope: $_scope  |  admin: $_is_admin"

    # Offer additional directories when user has a private home (not full access)
    if command -v docker &>/dev/null && [[ "$_scope" != "/" && "$_scope" != "/data" ]]; then
        local _do_dirs=""
        read -r -p "  Add additional directories for '$_username'? [y/N]: " _do_dirs
        if [[ "${_do_dirs,,}" == "y" ]]; then
            prompt_add_dirs "$_scope" || true
        fi
    fi
}

# ── cmd: delete ───────────────────────────────────────────────────────────────
cmd_delete() {
    local _username="${1:-}"
    ensure_token

    if [[ -z "$_username" ]]; then
        cmd_list
        read -r -p "  Username to delete: " _username
    fi
    validate_username "$_username" || return 1

    local _uid
    _uid=$(get_user_id "$_username") || return 1

    local _c=""
    read -r -p "  Delete '$_username' (id $_uid)? [y/N]: " _c
    [[ "${_c,,}" == "y" ]] || { echo "  Aborted."; return 0; }
    api_delete "/api/users/$_uid" >/dev/null
    ok "User '$_username' deleted."
    echo "  ${DIM}Note: their scope directory and additional directories still exist in the Docker volume.${R}"
}

# ── cmd: passwd ───────────────────────────────────────────────────────────────
cmd_passwd() {
    local _username="${1:-}"
    ensure_token

    if [[ -z "$_username" ]]; then
        cmd_list
        read -r -p "  Username: " _username
    fi
    validate_username "$_username" || return 1

    local _uid _user
    _uid=$(get_user_id "$_username") || return 1
    _user=$(find_user "$_username")

    echo
    echo "  ${B}Password rules:${R} min 8 chars, at least 1 letter and 1 number."
    echo
    local password=""
    prompt_password password "New password for $_username"

    local _body
    _body=$(echo "$_user" | jq --arg p "$password" '. + {password: $p}')
    api_put "/api/users/$_uid" "$_body" >/dev/null
    echo
    ok "Password updated for '$_username'."
}

# ── cmd: scope ────────────────────────────────────────────────────────────────
cmd_scope() {
    local _username="${1:-}" _new_scope="${2:-}"
    ensure_token

    if [[ -z "$_username" ]]; then
        cmd_list
        read -r -p "  Username: " _username
    fi
    validate_username "$_username" || return 1

    local _uid _user _old_scope
    _uid=$(get_user_id "$_username") || return 1
    _user=$(find_user "$_username")
    _old_scope=$(echo "$_user" | jq -r '.scope')

    if [[ -z "$_new_scope" ]]; then
        echo
        echo "  Current scope: $_old_scope"
        echo "  ${DIM}Additional directories in the old scope are not moved automatically.${R}"
        echo
        read -r -p "  New scope: " _new_scope
        _new_scope="/${_new_scope#/}"
    fi
    validate_scope "$_new_scope" || return 1

    local _body
    _body=$(echo "$_user" | jq --arg s "$_new_scope" '. + {scope: $s}')
    api_put "/api/users/$_uid" "$_body" >/dev/null
    echo
    ok "Scope updated for '$_username': $_old_scope → $_new_scope"

    # Offer to add directories into the new scope
    if command -v docker &>/dev/null && [[ "$_new_scope" != "/" && "$_new_scope" != "/data" ]]; then
        local _do_dirs=""
        read -r -p "  Add additional directories into '$_new_scope'? [y/N]: " _do_dirs
        if [[ "${_do_dirs,,}" == "y" ]]; then
            prompt_add_dirs "$_new_scope" || true
        fi
    fi
}

# ── cmd: rename ───────────────────────────────────────────────────────────────
cmd_rename() {
    local _username="${1:-}" _new_username="${2:-}"
    ensure_token

    if [[ -z "$_username" ]]; then
        cmd_list
        read -r -p "  Username to rename: " _username
    fi
    validate_username "$_username" || return 1

    if [[ -z "$_new_username" ]]; then
        read -r -p "  New username: " _new_username
    fi
    validate_username "$_new_username" || return 1

    local _uid _user _body
    _uid=$(get_user_id "$_username") || return 1
    _user=$(find_user "$_username")
    _body=$(echo "$_user" | jq --arg u "$_new_username" '. + {username: $u}')
    api_put "/api/users/$_uid" "$_body" >/dev/null
    ok "Renamed: '$_username' → '$_new_username'"
}

# ── cmd: info ─────────────────────────────────────────────────────────────────
cmd_info() {
    local _username="${1:-}"
    ensure_token

    if [[ -z "$_username" ]]; then
        cmd_list
        read -r -p "  Username: " _username
    fi
    validate_username "$_username" || return 1

    local _user
    _user=$(find_user "$_username")
    [[ -n "$_user" ]] || { errmsg "User '$_username' not found."; return 1; }
    echo
    echo "$_user" | jq '{username, scope,
        admin:    .perm.admin,
        create:   .perm.create,
        modify:   .perm.modify,
        delete:   .perm.delete,
        download: .perm.download,
        execute:  .perm.execute}'
    echo
}

# ── Modify submenu ────────────────────────────────────────────────────────────
menu_modify() {
    ensure_token
    cmd_list

    local _cur=""
    read -r -p "  Username to modify: " _cur
    validate_username "$_cur" || return 1
    get_user_id "$_cur" >/dev/null || return 1

    while true; do
        local _user _scope _admin
        _user=$(find_user "$_cur") || { errmsg "User '$_cur' no longer exists."; break; }
        [[ -n "$_user" ]] || { errmsg "User '$_cur' no longer exists."; break; }
        _scope=$(echo "$_user" | jq -r '.scope')
        _admin=$(echo "$_user" | jq -r 'if .perm.admin then "yes" else "no" end')

        banner "Modify: $_cur"
        echo "  ${B}Scope:${R}  $_scope"
        echo "  ${B}Admin:${R}  $_admin"
        echo
        echo "  1  Change username"
        echo "  2  Change password"
        echo "  3  Change scope (file path)"
        echo "  4  Toggle admin status"
        echo "  5  Additional directories  ${DIM}(add/remove extra folder access)${R}"
        echo "  0  Back"
        echo
        local _ch=""
        read -r -p "  Choice: " _ch

        case "$_ch" in
            1)
                local _new_u=""
                echo
                read -r -p "  New username: " _new_u
                validate_username "$_new_u" || continue
                local _uid1 _body1
                _uid1=$(get_user_id "$_cur") || continue
                _body1=$(echo "$_user" | jq --arg u "$_new_u" '. + {username: $u}')
                if api_put "/api/users/$_uid1" "$_body1" >/dev/null; then
                    ok "Renamed: '$_cur' → '$_new_u'"
                    _cur="$_new_u"
                else
                    errmsg "Rename failed."
                fi
                ;;
            2) cmd_passwd "$_cur" || true ;;
            3) cmd_scope  "$_cur" || true ;;
            4)
                local _uid4
                _uid4=$(get_user_id "$_cur") || continue
                local _toggled
                _toggled=$(echo "$_user" | jq '.perm.admin = (.perm.admin | not)')
                if api_put "/api/users/$_uid4" "$_toggled" >/dev/null; then
                    local _new_admin
                    _new_admin=$(echo "$_toggled" | jq -r 'if .perm.admin then "yes" else "no" end')
                    ok "Admin for '$_cur' is now: $_new_admin"
                else
                    errmsg "Toggle failed."
                fi
                ;;
            5) menu_add_dirs "$_scope" || true ;;
            0) break ;;
            *) errmsg "Invalid choice." ;;
        esac
    done
}

# ── usage ─────────────────────────────────────────────────────────────────────
usage() {
    cat <<'EOF'
FileBrowser user management

  Run with no arguments for the interactive menu.

One-shot usage:
  manage_users.sh list
  manage_users.sh add    <username> <scope> [--admin]
  manage_users.sh delete <username>
  manage_users.sh passwd <username>
  manage_users.sh scope  <username> <new-scope>
  manage_users.sh rename <username> <new-username>
  manage_users.sh info   <username>

Scope is relative to /srv inside the container (= FB_PATH on the host).
Username: letters, numbers, hyphens, underscores only. No dots or @.
Password: min 8 chars, at least one letter and one number.

Additional directories: use the interactive menu — extra folders
are offered automatically when you add a user or change their scope.

Override URL:  FB_URL=http://localhost:8085 ./manage_users.sh
EOF
}

# ── Main interactive menu ─────────────────────────────────────────────────────
run_interactive() {
    ensure_token
    while true; do
        banner "FileBrowser User Manager"
        echo "  ${DIM}${FB_URL}${R}"
        echo
        echo "  1  List users"
        echo "  2  Add user"
        echo "  3  Delete user"
        echo "  4  Modify user  (username / password / scope / admin / directories)"
        echo "  5  View user details"
        echo "  0  Exit"
        echo
        local _ch=""
        read -r -p "  Choice: " _ch
        case "$_ch" in
            1) cmd_list    || true ;;
            2) cmd_add     || true ;;
            3) cmd_delete  || true ;;
            4) menu_modify || true ;;
            5) cmd_info    || true ;;
            0) echo; echo "  Goodbye."; echo; exit 0 ;;
            *) errmsg "Invalid choice." ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────
require_cmds curl jq

_cmd="${1:-}"
shift || true

case "$_cmd" in
    "")             run_interactive ;;
    list)           ensure_token; cmd_list ;;
    add)            ensure_token; cmd_add "$@" ;;
    delete|del)     ensure_token; cmd_delete "${1:-}" ;;
    passwd|pw)      ensure_token; cmd_passwd "${1:-}" ;;
    scope)          ensure_token; cmd_scope "${1:-}" "${2:-}" ;;
    rename)         ensure_token; cmd_rename "${1:-}" "${2:-}" ;;
    info)           ensure_token; cmd_info "${1:-}" ;;
    help|--help|-h) usage ;;
    *) errmsg "Unknown command: $_cmd"; echo; usage; exit 2 ;;
esac
