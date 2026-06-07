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
# ── Scope (file path) ─────────────────────────────────────────────────────────
#   FileBrowser supports ONE scope path per user.
#   Scope is an absolute path inside the container, relative to /srv (= FB_PATH).
#
#   If FB_PATH=~/drives/data1:
#     /          → full access (all of ~/drives/data1)
#     /alice     → alice's own subdir (pair with linked dirs below)
#     /music     → music subdir only
#
# ── Multi-directory access via linked directories ────────────────────────────
#   FileBrowser follows symlinks inside the scope dir.
#   Give a user scope=/alice, then link extra folders into /alice:
#
#     /alice/music  → /srv/music    (alice sees "music" in her root)
#     /alice/photos → /srv/photos   (alice sees "photos" too)
#
#   This script creates those symlinks via "docker exec", so they live in
#   the bind-mount on the host as well (target is /srv/... so it appears
#   broken from the host, but resolves correctly inside the container).
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
    local _u _p _tok
    read -r -p "  Admin username [admin]: " _u
    _u="${_u:-admin}"
    read -r -s -p "  Admin password: " _p; echo
    _tok=$(curl -s -X POST "$FB_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$_u\",\"password\":\"$_p\"}")
    [[ "$_tok" == *"."*"."* ]] \
        || die "Login failed. Check credentials and that FileBrowser is running at $FB_URL"
    TOKEN="$_tok"
    ok "Logged in as $_u"
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

# Print symlinks inside /srv<scope>, one per line.
list_links() {
    local _c="$1" _scope="$2"
    docker exec "$_c" find "/srv$_scope" -maxdepth 1 -type l \
        -exec sh -c 'printf "    %-24s→  %s\n" "$(basename "$1")" "$(readlink "$1")"' _ {} \; \
        2>/dev/null | sort || true
}

# ── prompt_add_links SCOPE ────────────────────────────────────────────────────
# Loop: ask for /srv source paths, create symlinks, blank line to finish.
# Shared by cmd_add (offered inline) and menu_links (add option).
prompt_add_links() {
    local _scope="$1"
    local _c
    _c=$(get_container_name)
    check_container "$_c" || return 1

    local _scope_dir="/srv$_scope"
    docker exec "$_c" mkdir -p "$_scope_dir" >/dev/null 2>&1 || true

    echo
    echo "  Link directories into '$_scope_dir'."
    echo "  Enter a /srv path for each directory to add — blank line when done."
    echo

    while true; do
        local _src=""
        read -r -p "  /srv path [done]: /" _src
        [[ -n "$_src" ]] || break

        _src="/${_src#/}"   # normalise leading slash
        _src="${_src%/}"    # strip trailing slash

        if ! docker exec "$_c" test -e "/srv$_src" 2>/dev/null; then
            errmsg "/srv$_src does not exist inside the container. Skipping."
            continue
        fi

        local _default_name
        _default_name=$(basename "$_src")
        local _link_name=""
        read -r -p "  Name in user's folder [$_default_name]: " _link_name
        _link_name="${_link_name:-$_default_name}"

        if ! [[ "$_link_name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
            errmsg "Invalid name. Use letters, numbers, dots, hyphens, underscores."
            continue
        fi

        local _link_path="$_scope_dir/$_link_name"
        local _target="/srv$_src"

        if docker exec "$_c" test -e "$_link_path" 2>/dev/null; then
            errmsg "'$_link_name' already exists at $_link_path — skipping. Use Remove to clear it first."
            continue
        fi

        docker exec "$_c" ln -s "$_target" "$_link_path"
        ok "'$_link_name'  →  $_target"
    done
}

# ── Linked-directory submenu (shown from Modify option 5) ────────────────────
menu_links() {
    local _scope="$1"
    local _c
    _c=$(get_container_name)
    check_container "$_c" || return 1

    while true; do
        banner "Linked directories  (scope: $_scope)"
        echo "  ${DIM}Symlinks inside /srv${_scope} — visible as folders in FileBrowser${R}"
        echo
        local _links
        _links=$(list_links "$_c" "$_scope")
        if [[ -n "$_links" ]]; then
            echo "$_links"
        else
            echo "    (none)"
        fi
        echo
        echo "  1  Add linked directories"
        echo "  2  Remove a linked directory"
        echo "  0  Back"
        echo
        local _ch=""
        read -r -p "  Choice: " _ch
        case "$_ch" in
            1) prompt_add_links "$_scope" || true ;;
            2)
                local _link_name=""
                echo
                read -r -p "  Link name to remove: " _link_name
                [[ -n "$_link_name" ]] || continue
                local _link_path="/srv${_scope}/${_link_name}"
                if ! docker exec "$_c" test -L "$_link_path" 2>/dev/null; then
                    errmsg "'$_link_name' is not a symlink — refusing to delete."
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
        echo "  ${B}Scope:${R}    one path per user — use linked dirs for multi-folder access."
        echo
        read -r -p "  Username: " _username
        local _adm=""
        read -r -p "  Admin?    [y/N]: " _adm
        [[ "${_adm,,}" == "y" ]] && _is_admin="true"
    fi

    validate_username "$_username" || return 1

    if [[ -z "$_scope" ]]; then
        echo
        echo "  Scope examples:"
        echo "    /           full access (all of FB_PATH)"
        echo "    /$_username    user's own private subdir (recommended with linked dirs)"
        echo "    /music      music subdir only"
        echo
        read -r -p "  Scope for '$_username': /" _scope
        _scope="/${_scope#/}"
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
          singleClick:false, sorting:{by:"name",asc:true}, perm:$perms,
          commands:[], lockPassword:false, hideDotfiles:false, dateFormat:false}')
    api_post "/api/users" "$_body" >/dev/null
    echo
    ok "User '$_username' created  |  scope: $_scope  |  admin: $_is_admin"

    # Offer to add linked directories inline
    if command -v docker &>/dev/null; then
        local _do_links=""
        read -r -p "  Add linked directories for '$_username'? [y/N]: " _do_links
        if [[ "${_do_links,,}" == "y" ]]; then
            prompt_add_links "$_scope" || true
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
    echo "  ${DIM}Note: symlinks in their scope dir still exist on disk if you want to reuse them.${R}"
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
        echo "  ${DIM}Existing symlinks in the old scope dir are not moved automatically.${R}"
        echo
        read -r -p "  New scope: /" _new_scope
        _new_scope="/${_new_scope#/}"
    fi
    validate_scope "$_new_scope" || return 1

    local _body
    _body=$(echo "$_user" | jq --arg s "$_new_scope" '. + {scope: $s}')
    api_put "/api/users/$_uid" "$_body" >/dev/null
    echo
    ok "Scope updated for '$_username': $_old_scope → $_new_scope"

    # Offer to add links into the new scope
    if command -v docker &>/dev/null && [[ "$_new_scope" != "/" ]]; then
        local _do_links=""
        read -r -p "  Add linked directories into '$_new_scope'? [y/N]: " _do_links
        if [[ "${_do_links,,}" == "y" ]]; then
            prompt_add_links "$_new_scope" || true
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
        echo "  5  Linked directories  ${DIM}(add/remove multi-folder symlinks)${R}"
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
            5) menu_links "$_scope" || true ;;
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

Multi-directory access: use the interactive menu — linked directories
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
        echo "  4  Modify user  (username / password / scope / admin / links)"
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
