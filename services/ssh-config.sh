#!/bin/bash
# services/ssh-config.sh — manage ~/.ssh/config Host aliases.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash ssh-config.sh
#
# Not a Docker service — edits the invoking (non-root) user's ~/.ssh/config
# so "ssh myserver" connects directly instead of "ssh user@1.2.3.4". Handy
# once NetBird/VPN peers have IPs you don't want to memorize or retype.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        ssh_config_path() { echo "$ACTUAL_HOME/.ssh/config"; }

        ssh_host_alias_exists() {
            local alias="$1" cfg; cfg="$(ssh_config_path)"
            [ -f "$cfg" ] && grep -qiE "^Host[[:space:]]+${alias}([[:space:]]|\$)" "$cfg"
        }

        add_ssh_host_alias() {
            local alias="$1" hostname="$2" user="$3" port="${4:-22}"
            local cfg; cfg="$(ssh_config_path)"
            mkdir -p "$(dirname "$cfg")"
            touch "$cfg"
            chmod 700 "$(dirname "$cfg")"
            chmod 600 "$cfg"
            if ssh_host_alias_exists "$alias"; then
                log_warning "Host alias '$alias' already exists in $cfg — skipping."
                return 1
            fi
            {
                echo ""
                echo "Host $alias"
                echo "    HostName $hostname"
                echo "    User $user"
                [ "$port" != "22" ] && echo "    Port $port"
            } >> "$cfg"
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$(dirname "$cfg")" 2>/dev/null || true
            log_success "Added SSH alias: ssh $alias  ->  $user@$hostname:$port"
        }

        list_ssh_host_aliases() {
            local cfg; cfg="$(ssh_config_path)"
            if [ ! -f "$cfg" ] || ! grep -qiE "^Host[[:space:]]+" "$cfg"; then
                echo "  (none — $cfg has no Host entries yet)"
                return 0
            fi
            grep -inE "^Host[[:space:]]+" "$cfg" | sed -E 's/^([0-9]+):Host[[:space:]]+/  \1) /'
        }

        remove_ssh_host_alias() {
            local alias="$1" cfg; cfg="$(ssh_config_path)"
            [ -f "$cfg" ] || { log_warning "No SSH config file found at $cfg"; return 1; }
            if ! ssh_host_alias_exists "$alias"; then
                log_warning "Host alias '$alias' not found in $cfg"
                return 1
            fi
            local tmp; tmp="$(mktemp)"
            awk -v alias="$alias" '
                BEGIN { skip=0 }
                tolower($1)=="host" && tolower($2)==tolower(alias) { skip=1; next }
                skip==1 && /^Host[[:space:]]/ { skip=0 }
                skip==1 && /^[[:space:]]*$/ { skip=0; next }
                skip==1 { next }
                { print }
            ' "$cfg" > "$tmp"
            mv "$tmp" "$cfg"
            chmod 600 "$cfg"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$cfg" 2>/dev/null || true
            log_success "Removed SSH alias: $alias"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before anything else
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service ssh-config extras "Manage SSH Host aliases in ~/.ssh/config (ssh <alias> instead of ssh user@ip)"

install_ssh-config() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would list/add/remove Host aliases in $(ssh_config_path)"
        return 0
    fi

    echo ""
    echo "Current SSH Host aliases in $(ssh_config_path):"
    list_ssh_host_aliases
    echo ""

    local ACTION=""
    echo "  [1] Add an alias"
    echo "  [2] Remove an alias"
    echo "  [3] Done"
    prompt_text "Choice [3]:" "3" ACTION

    case "$ACTION" in
        1)
            local ALIAS_NAME="" ALIAS_HOST="" ALIAS_USER="" ALIAS_PORT=""
            prompt_text "  Alias name (e.g. myserver):" "" ALIAS_NAME
            if [ -z "$ALIAS_NAME" ]; then
                log_warning "Alias name required."
                return 1
            fi
            prompt_text "  Hostname or IP to connect to (e.g. a NetBird peer IP):" "" ALIAS_HOST
            prompt_text "  Remote username:" "$ACTUAL_USER" ALIAS_USER
            prompt_text "  Port [22]:" "22" ALIAS_PORT
            add_ssh_host_alias "$ALIAS_NAME" "$ALIAS_HOST" "$ALIAS_USER" "$ALIAS_PORT"
            ;;
        2)
            local REMOVE_NAME=""
            prompt_text "  Alias name to remove:" "" REMOVE_NAME
            [ -n "$REMOVE_NAME" ] && remove_ssh_host_alias "$REMOVE_NAME"
            ;;
        *)
            log_info "No changes."
            ;;
    esac
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_ssh-config
