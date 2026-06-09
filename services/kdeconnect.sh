#!/bin/bash
# services/kdeconnect.sh — Phone/desktop integration via KDE Connect.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash kdeconnect.sh
#
# KDE Connect is an APT package — NOT a Docker service.
# It enables Android/iPhone ↔ Linux integration:
#   • Shared clipboard                  • File transfer
#   • Phone notifications on desktop    • Remote input (trackpad/keyboard)
#   • SMS from desktop                  • Battery status
#
# NOTE: setup.sh is_installed() needs a case entry for this service:
#   kdeconnect) command -v kdeconnect >/dev/null 2>&1 ;;

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
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service kdeconnect extras "Phone/desktop integration — notifications, clipboard, file transfer (KDE Connect)"

install_kdeconnect() {
    log_info "Installing KDE Connect phone/desktop integration..."

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ KDE CONNECT — Phone / Desktop Integration                       │"
    echo "│ Shared clipboard, notifications, file transfer, remote input    │"
    echo "│ Works with Android (Play Store / F-Droid) and iPhone (App Store)│"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    # ── Already installed? ────────────────────────────────────────────────────
    if command -v kdeconnect &>/dev/null; then
        log_info "KDE Connect is already installed — skipping."
        return 0
    fi

    # ── DRY-RUN: describe the plan and bail before touching anything real ─────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install: kdeconnect"
        if dpkg -l gnome-shell 2>/dev/null | grep -q ^ii; then
            echo "[DRY-RUN] Would install: indicator-kdeconnect (GNOME/Ubuntu detected)"
        fi
        if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
            echo "[DRY-RUN] Would open UFW ports 1714:1764/tcp and 1714:1764/udp"
        fi
        return 0
    fi

    # ── 1. Install kdeconnect ─────────────────────────────────────────────────
    log_info "Installing kdeconnect package..."
    if apt-get install -y kdeconnect; then
        log_success "kdeconnect installed"
    else
        log_error "Failed to install kdeconnect — check apt output above"
        return 1
    fi

    # ── 2. GNOME indicator (Ubuntu/GNOME only) ────────────────────────────────
    if dpkg -l gnome-shell 2>/dev/null | grep -q ^ii; then
        log_info "GNOME detected — installing indicator-kdeconnect for system tray support..."
        if apt-get install -y indicator-kdeconnect; then
            log_success "indicator-kdeconnect installed"
        else
            log_warning "Could not install indicator-kdeconnect — continuing without it"
        fi
    fi

    # ── 3. Open UFW firewall ports (KDE Connect port range) ───────────────────
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        log_info "Opening UFW ports 1714:1764/tcp and 1714:1764/udp (KDE Connect)..."
        ufw allow 1714:1764/tcp
        ufw allow 1714:1764/udp
        log_success "UFW ports 1714-1764 opened"
    else
        log_info "UFW not active — skipping firewall rules"
        echo "  If you enable UFW later, run:"
        echo "    sudo ufw allow 1714:1764/tcp"
        echo "    sudo ufw allow 1714:1764/udp"
    fi

    # ── 4. Usage instructions ─────────────────────────────────────────────────
    echo ""
    echo "  ┌─ Next steps ────────────────────────────────────────────────────┐"
    echo "  │ 1. Install KDE Connect on your phone:                           │"
    echo "  │      Android: Play Store or F-Droid → search 'KDE Connect'     │"
    echo "  │      iPhone:  App Store → search 'KDE Connect'                  │"
    echo "  │                                                                  │"
    echo "  │ 2. Ensure your phone and computer are on the same WiFi network. │"
    echo "  │                                                                  │"
    echo "  │ 3. Open KDE Connect on your phone — your computer should        │"
    echo "  │    appear automatically. Tap it and accept the pairing request  │"
    echo "  │    on both devices.                                              │"
    echo "  │                                                                  │"
    echo "  │ Linux Mint Cinnamon: a system tray applet is available —        │"
    echo "  │    right-click the desktop → Applets → search 'KDE Connect'    │"
    echo "  │    and add it to your panel.                                     │"
    echo "  └──────────────────────────────────────────────────────────────────┘"
    echo ""

    log_success "KDE Connect installation complete"
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_kdeconnect
