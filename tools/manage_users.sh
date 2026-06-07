#!/usr/bin/env bash
# manage_users.sh — FileBrowser user management via the REST API.
#
# Placed in ~/docker/filebrowser/ by the filebrowser installer.
# Requires: curl, jq   (apt install curl jq)
#
# Usage:
#   ./manage_users.sh list
#   ./manage_users.sh add    <username> <scope> [--admin]
#   ./manage_users.sh delete <username>
#   ./manage_users.sh passwd <username>
#   ./manage_users.sh scope  <username> <new-scope>
#   ./manage_users.sh info   <username>
#
# ── Username rules ────────────────────────────────────────────────────────────
#   Letters, numbers, hyphens, underscores only.  No spaces or dots.
#   Examples:  alice   bob-smith   data_user2
#
# ── Password rules ────────────────────────────────────────────────────────────
#   Minimum 8 characters.  No maximum.
#   Must contain at least one letter and one number.
#   Special characters are allowed.
#
# ── Scope rules ───────────────────────────────────────────────────────────────
#   Scope is a path INSIDE the container, relative to the FileBrowser root (/srv).
#   The volume in docker-compose.yml mounts your host path (FB_PATH) as /srv.
#
#   If FB_PATH is ~/drives/data1 then:
#     /          → full access to ~/drives/data1
#     /music     → ~/drives/data1/music only
#     /docs/bob  → ~/drives/data1/docs/bob only
#
#   Admin account created on first login gets scope / by default.
#
# ── Examples ─────────────────────────────────────────────────────────────────
#   Add admin with full access:
#     ./manage_users.sh add admin /
#
#   Add alice with access to just the music directory:
#     ./manage_users.sh add alice /music
#
#   Add bob as an admin with full access:
#     ./manage_users.sh add bob / --admin
#
#   Change alice's password:
#     ./manage_users.sh passwd alice
#
#   Restrict alice to a subdirectory:
#     ./manage_users.sh scope alice /music/alice
#
#   List all users:
#     ./manage_users.sh list
#
#   Delete bob:
#     ./manage_users.sh delete bob
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FB_URL="${FB_URL:-http://localhost:8085}"

# ── Helpers ───────────────────────────────────────────────────────────────────
die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "  $*"; }

require_cmd() {
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || die "'$cmd' not found. Install it: sudo apt install $cmd"
    done
}

validate_username() {
    local u="$1"
    [[ -n "$u" ]]              || die "Username cannot be empty."
    [[ "$u" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid username '$u'. Only letters, numbers, hyphens, underscores allowed."
}

validate_password() {
    local p="$1"
    [[ ${#p} -ge 8 ]]          || die "Password too short (minimum 8 characters)."
    [[ "$p" =~ [a-zA-Z] ]]     || die "Password must contain at least one letter."
    [[ "$p" =~ [0-9] ]]        || die "Password must contain at least one number."
}

validate_scope() {
    local s="$1"
    [[ "$s" == /* ]] || die "Scope must be an absolute path starting with / (e.g. /music or /)"
}

prompt_password() {
    local varname="$1" prompt="${2:-Password}"
    local p1 p2
    while true; do
        read -r -s -p "$prompt: " p1; echo
        read -r -s -p "Confirm:  " p2; echo
        [[ "$p1" == "$p2" ]] || { echo "  Passwords do not match. Try again."; continue; }
        validate_password "$p1"
        printf -v "$varname" "%s" "$p1"
        break
    done
}

# ── Authentication ─────────────────────────────────────────────────────────────
get_token() {
    local admin_user admin_pass
    read -r -p "FileBrowser admin username [admin]: " admin_user
    admin_user="${admin_user:-admin}"
    read -r -s -p "FileBrowser admin password: " admin_pass; echo

    local resp
    resp=$(curl -s -o /dev/null -w "%{http_code}:%{stderr}" \
        -X POST "$FB_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}" 2>/dev/null || true)

    local token
    token=$(curl -s -X POST "$FB_URL/api/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$admin_user\",\"password\":\"$admin_pass\"}")

    [[ "$token" == *"."*"."* ]] || die "Login failed. Check credentials and that FileBrowser is running."
    echo "$token"
}

# ── API helpers ────────────────────────────────────────────────────────────────
api_get() {
    local token="$1" path="$2"
    curl -sf -X GET "$FB_URL$path" -H "X-Auth: $token"
}

api_post() {
    local token="$1" path="$2" body="$3"
    curl -sf -X POST "$FB_URL$path" \
        -H "X-Auth: $token" -H "Content-Type: application/json" -d "$body"
}

api_put() {
    local token="$1" path="$2" body="$3"
    curl -sf -X PUT "$FB_URL$path" \
        -H "X-Auth: $token" -H "Content-Type: application/json" -d "$body"
}

api_delete() {
    local token="$1" path="$2"
    curl -sf -X DELETE "$FB_URL$path" -H "X-Auth: $token"
}

# Returns user JSON object for the given username, or empty string if not found.
find_user() {
    local token="$1" username="$2"
    api_get "$token" "/api/users" | jq -r --arg u "$username" '.[] | select(.username==$u)'
}

get_user_id() {
    local token="$1" username="$2"
    local user
    user=$(find_user "$token" "$username")
    [[ -n "$user" ]] || die "User '$username' not found."
    echo "$user" | jq -r '.id'
}

# ── Default permissions for new non-admin users ──────────────────────────────
default_perms() {
    cat <<'JSON'
{
    "admin":    false,
    "execute":  false,
    "create":   true,
    "rename":   true,
    "modify":   true,
    "delete":   true,
    "share":    false,
    "download": true
}
JSON
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_list() {
    local token
    token=$(get_token)
    echo
    printf "%-20s  %-5s  %-30s\n" "USERNAME" "ADMIN" "SCOPE"
    printf "%-20s  %-5s  %-30s\n" "--------" "-----" "-----"
    api_get "$token" "/api/users" | \
        jq -r '.[] | [.username, (if .perm.admin then "yes" else "no" end), .scope] | @tsv' | \
        while IFS=$'\t' read -r uname is_admin scope; do
            printf "%-20s  %-5s  %s\n" "$uname" "$is_admin" "$scope"
        done
}

cmd_add() {
    local username="$1" scope="$2" is_admin="${3:-false}"
    validate_username "$username"
    validate_scope "$scope"

    local password
    echo
    echo "Setting password for new user '$username'."
    echo "  Min 8 chars, at least one letter and one number."
    echo
    prompt_password password "New password for $username"

    local token
    token=$(get_token)

    # Check if user already exists
    local existing
    existing=$(find_user "$token" "$username")
    [[ -z "$existing" ]] || die "User '$username' already exists. Use 'passwd' or 'scope' to modify."

    local perms
    perms=$(default_perms)
    if [[ "$is_admin" == "true" ]]; then
        perms=$(echo "$perms" | jq '.admin = true')
    fi

    local body
    body=$(jq -n \
        --arg u "$username" \
        --arg p "$password" \
        --arg s "$scope" \
        --argjson perms "$perms" \
        '{username: $u, password: $p, scope: $s, locale: "en",
          viewMode: "list", singleClick: false, sorting: {by: "name", asc: true},
          perm: $perms, commands: [], lockPassword: false,
          hideDotfiles: false, dateFormat: false}')

    api_post "$token" "/api/users" "$body" >/dev/null
    echo
    info "User '$username' created."
    info "  Scope:  $scope"
    info "  Admin:  $is_admin"
}

cmd_delete() {
    local username="$1"
    validate_username "$username"

    local token
    token=$(get_token)

    local uid
    uid=$(get_user_id "$token" "$username")

    local confirm
    read -r -p "Delete user '$username' (id=$uid)? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

    api_delete "$token" "/api/users/$uid" >/dev/null
    echo
    info "User '$username' deleted."
}

cmd_passwd() {
    local username="$1"
    validate_username "$username"

    local token
    token=$(get_token)

    local uid user
    uid=$(get_user_id "$token" "$username")
    user=$(find_user "$token" "$username")

    echo
    echo "Changing password for '$username'."
    echo "  Min 8 chars, at least one letter and one number."
    echo

    local password
    prompt_password password "New password for $username"

    local body
    body=$(echo "$user" | jq --arg p "$password" '. + {password: $p}')
    api_put "$token" "/api/users/$uid" "$body" >/dev/null
    echo
    info "Password updated for '$username'."
}

cmd_scope() {
    local username="$1" new_scope="$2"
    validate_username "$username"
    validate_scope "$new_scope"

    local token
    token=$(get_token)

    local uid user old_scope
    uid=$(get_user_id "$token" "$username")
    user=$(find_user "$token" "$username")
    old_scope=$(echo "$user" | jq -r '.scope')

    local body
    body=$(echo "$user" | jq --arg s "$new_scope" '. + {scope: $s}')
    api_put "$token" "/api/users/$uid" "$body" >/dev/null
    echo
    info "Scope updated for '$username': $old_scope → $new_scope"
}

cmd_info() {
    local username="$1"
    validate_username "$username"

    local token
    token=$(get_token)

    local user
    user=$(find_user "$token" "$username")
    [[ -n "$user" ]] || die "User '$username' not found."

    echo
    echo "$user" | jq '{
        username,
        scope,
        admin:    .perm.admin,
        create:   .perm.create,
        modify:   .perm.modify,
        delete:   .perm.delete,
        download: .perm.download,
        execute:  .perm.execute
    }'
}

usage() {
    cat <<'USAGE'
FileBrowser user management

Usage:
  manage_users.sh list
  manage_users.sh add    <username> <scope> [--admin]
  manage_users.sh delete <username>
  manage_users.sh passwd <username>
  manage_users.sh scope  <username> <new-scope>
  manage_users.sh info   <username>

Scope path is relative to /srv inside the container (= FB_PATH on the host).
  /          full access to everything under FB_PATH
  /music     only ~/drives/data1/music  (if FB_PATH=~/drives/data1)
  /docs/bob  only ~/drives/data1/docs/bob

Username: letters, numbers, hyphens, underscores only (no spaces or dots).
Password: min 8 chars, at least one letter and one number.

Examples:
  ./manage_users.sh add admin /
  ./manage_users.sh add alice /music
  ./manage_users.sh add bob / --admin
  ./manage_users.sh passwd alice
  ./manage_users.sh scope alice /music/alice
  ./manage_users.sh list
  ./manage_users.sh delete bob
USAGE
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
require_cmd curl jq

cmd="${1:-help}"
shift || true

case "$cmd" in
    list)   cmd_list ;;
    add)
        [[ $# -ge 2 ]] || die "Usage: manage_users.sh add <username> <scope> [--admin]"
        is_admin="false"
        [[ "${3:-}" == "--admin" ]] && is_admin="true"
        cmd_add "$1" "$2" "$is_admin"
        ;;
    delete) [[ $# -ge 1 ]] || die "Usage: manage_users.sh delete <username>"; cmd_delete "$1" ;;
    passwd) [[ $# -ge 1 ]] || die "Usage: manage_users.sh passwd <username>";  cmd_passwd "$1" ;;
    scope)
        [[ $# -ge 2 ]] || die "Usage: manage_users.sh scope <username> <new-scope>"
        cmd_scope "$1" "$2"
        ;;
    info)   [[ $# -ge 1 ]] || die "Usage: manage_users.sh info <username>";    cmd_info "$1"  ;;
    help|--help|-h) usage ;;
    *) echo "Unknown command: $cmd"; echo; usage; exit 2 ;;
esac
