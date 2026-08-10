#!/bin/bash
# services/ssh-key-import.sh — import SSH public keys from GitHub/Launchpad
# for passwordless login, and optionally lock down password auth.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash ssh-key-import.sh
#
# Extracted out of services/base.sh's required setup (which still chains
# into this) so it can be re-run on its own — e.g. a box that already went
# through base setup but needs another admin's key added later, or a home
# box (see services/vpn-data-mount.sh) that just needs this one step and
# nothing else base.sh does.
#
# What ssh-import-id actually does: fetches the PUBLIC keys listed at
# https://github.com/<user>.keys (or https://launchpad.net/~<user>/+sshkeys
# for Launchpad — Canonical/Ubuntu's own code-hosting + bug-tracker
# platform, the "other option") over HTTPS and appends them to this box's
# ~/.ssh/authorized_keys. That's the same information already publicly
# visible on that profile page — nothing secret is transmitted, and no
# PRIVATE key ever leaves the machine that generated it. This box only
# gains the ability to authenticate INBOUND connections from whoever holds
# the matching private key; it does NOT gain that person's identity for
# OUTBOUND connections (e.g. this box still can't clone a private GitHub
# repo just because it imported someone's public key — that would need a
# separate keypair generated on this box, with ITS public half added to
# GitHub, which is a different, deliberate step).

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

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

        run_cmd() {
            [[ "${DRY_RUN:-false}" == "true" ]] && { echo "[DRY-RUN] Would execute: $*"; return 0; }
            "$@"
        }

        register_service() { :; }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"

    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service ssh-key-import extras "Import SSH public keys from GitHub/Launchpad for passwordless login; optionally disable password auth"

install_ssh-key-import() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would ensure openssh-server is installed and running"
        echo "[DRY-RUN] Would offer to import SSH public keys from GitHub and/or Launchpad"
        echo "[DRY-RUN] Would offer to disable SSH password authentication if any key was imported"
        return 0
    fi

    log_info "Configuring SSH server..."

    if ! dpkg -l openssh-server &>/dev/null; then
        run_cmd apt-get install -y openssh-server
    fi
    run_cmd systemctl enable --now ssh

    local GH_USER="" LP_USER="" _keys_imported=false

    prompt_text "GitHub username to import SSH keys from (blank to skip):" "" GH_USER
    if [ -n "$GH_USER" ]; then
        if ssh-import-id "gh:$GH_USER"; then
            log_success "Imported SSH keys from GitHub: $GH_USER"
            _keys_imported=true
        else
            log_warning "Could not import keys from GitHub: $GH_USER"
        fi
    fi

    prompt_text "Launchpad username to import SSH keys from (blank to skip):" "" LP_USER
    if [ -n "$LP_USER" ]; then
        if ssh-import-id "lp:$LP_USER"; then
            log_success "Imported SSH keys from Launchpad: $LP_USER"
            _keys_imported=true
        else
            log_warning "Could not import keys from Launchpad: $LP_USER"
        fi
    fi

    if [ "$_keys_imported" = false ]; then
        log_info "No keys imported — nothing else to do."
        return 0
    fi

    local DISABLE_PW=""
    prompt_yn "Disable SSH password authentication (key login only)? (y/n):" "y" DISABLE_PW
    if [[ "$DISABLE_PW" =~ ^[Yy]$ ]]; then
        sed -i \
            -e 's/^#*\s*PasswordAuthentication\s.*/PasswordAuthentication no/' \
            -e 's/^#*\s*KbdInteractiveAuthentication\s.*/KbdInteractiveAuthentication no/' \
            /etc/ssh/sshd_config
        # Ubuntu 22.04+ may also have a drop-in that re-enables password auth.
        local _dropin="/etc/ssh/sshd_config.d/50-cloud-init.conf"
        if [ -f "$_dropin" ]; then
            sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$_dropin"
        fi
        systemctl restart ssh
        log_success "SSH password authentication disabled — key login only"
    fi
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_ssh-key-import
