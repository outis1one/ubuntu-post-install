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
#     /music     → ~/drives/data1/music only
#     /docs/bob  → ~/drives/data1/docs/bob only
#
#   For access to multiple unrelated directories:
#     • Set scope to a common parent (e.g. /)
#     • Create OS-level symlinks inside the scope dir pointing elsewhere
#
set -Eeuo pipefail

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
    [[ "$1" == /* ]] || { errmsg "Scope must start with /  (e.g. / or /music or /docs/bob)"; return 1; }
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
        echo "  ${B}Scope:${R}    FileBrowser supports ONE path per user."
        echo "             For multi-dir access: use a common parent or OS symlinks."
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
        echo "    /music      music subdir only"
        echo "    /docs/bob   docs/bob subdir only"
        echo
        read -r -p "  Scope for '$_username': " _scope
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
        echo "  Note: FileBrowser supports ONE path per user."
        echo "  Examples:  /   /music   /docs/bob"
        echo
        read -r -p "  New scope: " _new_scope
    fi
    validate_scope "$_new_scope" || return 1

    local _body
    _body=$(echo "$_user" | jq --arg s "$_new_scope" '. + {scope: $s}')
    api_put "/api/users/$_uid" "$_body" >/dev/null
    echo
    ok "Scope updated for '$_username': $_old_scope → $_new_scope"
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

Scope is relative to /srv inside the container (= FB_PATH on the host):
  /          full access to everything under FB_PATH
  /music     ~/drives/data1/music only  (if FB_PATH=~/drives/data1)
  /docs/bob  ~/drives/data1/docs/bob only

FileBrowser supports ONE scope path per user.
For multi-directory access: use a common parent, or place OS-level
symlinks inside the scope dir pointing to other locations.

Username: letters, numbers, hyphens, underscores only. No dots or @.
Password: min 8 chars, at least one letter and one number.

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
        echo "  4  Modify user  (username / password / scope / admin)"
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
