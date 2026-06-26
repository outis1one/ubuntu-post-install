#!/bin/bash
# services/kyber-launcher.sh — Kyber Launcher (native Linux AppImage) for SWBF2 (2017).
# Part of the modular post-install system (sourced by setup.sh).
#
# Kyber is the community multiplayer client for Star Wars Battlefront II (2017)
# after EA shut down official servers in 2022. It went open-source (GPL) in
# January 2026. This installs the native Linux AppImage port.
#
# Repo: https://github.com/simonlinuxcraft/kyber-linuxport-unofficial
#
# ── Requirements ──────────────────────────────────────────────────────────────
# - SWBF2 (Steam AppID 1237950) installed via Steam on this machine
# - glibc 2.38+ (Ubuntu/Mint 24.04+, Fedora 38+, SteamOS 3.7+)
#   Linux Mint: Mint 21.x uses Ubuntu 22.04 base (glibc 2.35 — too old).
#               Mint 22.x uses Ubuntu 24.04 base (glibc 2.39 — works).
# - A real discrete GPU with Vulkan drivers (NVIDIA or AMD recommended)
#   Intel Iris Xe (integrated) is not supported by the Kyber Linux port.
# - EA account (free) that owns SWBF2
#
# ── How to play ───────────────────────────────────────────────────────────────
# 1. Open Steam (must be running; do NOT click Play on SWBF2)
# 2. Launch Kyber (kyber command or app menu)
# 3. Join a server (HOME) or host one (HOST)
# 4. Kyber/Maxima launches SWBF2 via its own bundled GE-Proton (~1-3 min)
# 5. If the SWBF2 window appears but won't focus: press Alt+Tab or click it
#
# ── bwrap / unprivileged user namespaces ──────────────────────────────────────
# Ubuntu/Mint 24.04 restricts these by default. This installer fixes it
# automatically when run with sudo (required for setup.sh anyway).
# Without the fix: bwrap: setting up uid map: Permission denied

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        source "$_COMMON"
    else
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        ACTUAL_USER="${SUDO_USER:-$USER}"
        ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
        DRY_RUN="${DRY_RUN:-false}"
        UNATTENDED="${UNATTENDED:-false}"
    fi

    install_kyber_launcher
    exit $?
fi

# ── Registration ──────────────────────────────────────────────────────────────
register_service kyber-launcher gaming "Kyber Launcher — native Linux AppImage for SWBF2 (2017) multiplayer (requires discrete GPU)"

# ── Install function ──────────────────────────────────────────────────────────
install_kyber_launcher() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     Kyber Launcher — SWBF2 (2017) Multiplayer       ║"
    echo "║     Native Linux AppImage (simonlinuxcraft)          ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would check glibc version (needs 2.38+)"
        echo "[DRY-RUN] Would fix unprivileged user namespaces (bwrap requirement)"
        echo "[DRY-RUN] Would download latest Kyber AppImage from GitHub"
        echo "[DRY-RUN] Would install desktop entry and 'kyber' bin symlink"
        echo "[DRY-RUN] Would warn if no discrete GPU detected"
        return 0
    fi

    local KYBER_REPO="simonlinuxcraft/kyber-linuxport-unofficial"
    local INSTALL_DIR="$ACTUAL_HOME/.local/share/kyber"
    local APPIMAGE_PATH="$INSTALL_DIR/KyberLinuxPort.AppImage"
    local DESKTOP_FILE="$ACTUAL_HOME/.local/share/applications/kyber-launcher.desktop"
    local BIN_LINK="$ACTUAL_HOME/.local/bin/kyber"

    # ── glibc check ───────────────────────────────────────────────────────────
    local GLIBC GLIBC_MAJOR GLIBC_MINOR
    GLIBC=$(ldd --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+$' || echo "0.0")
    GLIBC_MAJOR=$(echo "$GLIBC" | cut -d. -f1)
    GLIBC_MINOR=$(echo "$GLIBC" | cut -d. -f2)
    if [[ "$GLIBC_MAJOR" -lt 2 ]] || { [[ "$GLIBC_MAJOR" -eq 2 ]] && [[ "$GLIBC_MINOR" -lt 38 ]]; }; then
        log_warning "glibc $GLIBC detected — Kyber requires glibc 2.38+."
        log_warning "Ubuntu/Mint 22.x ships glibc 2.35 (too old). Upgrade to 24.04-based distro."
        log_warning "Continuing install anyway — the AppImage may not run."
        echo ""
    else
        log_info "glibc $GLIBC — OK"
    fi

    # ── GPU check (informational) ─────────────────────────────────────────────
    local HAS_DISCRETE=false
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        log_info "GPU: NVIDIA detected"
        HAS_DISCRETE=true
    elif lspci 2>/dev/null | grep -qiE "VGA.*AMD|AMD.*VGA|Radeon"; then
        log_info "GPU: AMD detected"
        HAS_DISCRETE=true
    elif lspci 2>/dev/null | grep -qiE "VGA.*Intel|Intel.*VGA"; then
        log_warning "GPU: Intel integrated graphics detected."
        log_warning "The Kyber Linux port requires a real discrete GPU (NVIDIA or AMD)."
        log_warning "Game levels will likely crash on Intel Iris Xe."
        log_warning "Consider the Sunshine + Moonlight setup instead: sudo ./setup.sh sunshine"
    fi

    # ── Fix unprivileged user namespaces (bwrap) ──────────────────────────────
    log_info "Checking unprivileged user namespace support (required for Kyber)..."
    local CLONE_VAL APPARMOR_VAL
    CLONE_VAL=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
    APPARMOR_VAL=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo "0")

    if [[ "$CLONE_VAL" != "1" ]] || [[ "$APPARMOR_VAL" != "0" ]]; then
        log_warning "Unprivileged user namespaces restricted — applying fix..."
        sysctl -w kernel.unprivileged_userns_clone=1
        sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
        cat > /etc/sysctl.d/99-userns.conf << 'SYSCTL'
# Required for Kyber AppImage (bubblewrap sandbox)
kernel.unprivileged_userns_clone = 1
kernel.apparmor_restrict_unprivileged_userns = 0
SYSCTL
        log_success "bwrap fix applied (saved to /etc/sysctl.d/99-userns.conf)."
    else
        log_info "Unprivileged user namespaces: OK"
    fi

    # ── Fetch latest release ───────────────────────────────────────────────────
    log_info "Fetching latest Kyber Linux release..."
    local API_URL="https://api.github.com/repos/${KYBER_REPO}/releases/latest"
    local APPIMAGE_URL VERSION
    APPIMAGE_URL=$(curl -fsSL "$API_URL" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    url = a['browser_download_url']
    if url.endswith('.AppImage'):
        print(url)
        break
" 2>/dev/null)

    if [[ -z "$APPIMAGE_URL" ]]; then
        log_error "Could not fetch Kyber AppImage URL from GitHub."
        log_error "Check: https://github.com/${KYBER_REPO}/releases"
        log_error "Download manually, chmod +x, and run it."
        return 1
    fi

    VERSION=$(echo "$APPIMAGE_URL" | grep -oP 'v[\d.a-z-]+' | head -1)
    log_info "Latest: $VERSION"

    # ── Download ───────────────────────────────────────────────────────────────
    sudo -u "$ACTUAL_USER" mkdir -p "$INSTALL_DIR"

    local CURRENT_VERSION=""
    [[ -f "$APPIMAGE_PATH.version" ]] && CURRENT_VERSION=$(cat "$APPIMAGE_PATH.version")

    if [[ -f "$APPIMAGE_PATH" ]] && [[ "$CURRENT_VERSION" == "$VERSION" ]]; then
        log_info "Already up to date ($VERSION) — skipping download."
    else
        log_info "Downloading Kyber AppImage ($VERSION)..."
        sudo -u "$ACTUAL_USER" curl -L --progress-bar -o "$APPIMAGE_PATH" "$APPIMAGE_URL"
        sudo -u "$ACTUAL_USER" chmod +x "$APPIMAGE_PATH"
        echo "$VERSION" | sudo -u "$ACTUAL_USER" tee "$APPIMAGE_PATH.version" > /dev/null
        log_success "Downloaded: $APPIMAGE_PATH"
    fi

    # ── Desktop entry + bin symlink ────────────────────────────────────────────
    sudo -u "$ACTUAL_USER" mkdir -p "$(dirname "$DESKTOP_FILE")" "$ACTUAL_HOME/.local/bin"

    sudo -u "$ACTUAL_USER" tee "$DESKTOP_FILE" > /dev/null << EOF
[Desktop Entry]
Type=Application
Name=Kyber Launcher
Comment=Community multiplayer for Star Wars Battlefront II (2017)
Exec=${APPIMAGE_PATH}
Icon=kyber
Categories=Game;
StartupNotify=true
EOF

    sudo -u "$ACTUAL_USER" ln -sf "$APPIMAGE_PATH" "$BIN_LINK"
    sudo -u "$ACTUAL_USER" update-desktop-database "$ACTUAL_HOME/.local/share/applications" 2>/dev/null || true

    log_success "Desktop entry and 'kyber' command installed."

    # ── Summary ────────────────────────────────────────────────────────────────
    echo ""
    log_success "Kyber Launcher installed ($VERSION)."
    echo ""
    echo "  Launch:       kyber   (terminal)  or search 'Kyber Launcher' in app menu"
    echo "  AppImage:     $APPIMAGE_PATH"
    echo ""
    echo "  Every time you play:"
    echo "    1. Open Steam (keep running; do NOT click Play on SWBF2)"
    echo "    2. Launch Kyber → join (HOME) or host (HOST)"
    echo "    3. Kyber launches SWBF2 via its own GE-Proton — wait 1-3 min"
    echo "    4. If SWBF2 window won't focus: press Alt+Tab or click taskbar"
    echo ""
    echo "  First run:"
    echo "    1. Click 'EA Account' → log in at accounts.ea.com"
    echo "    2. Click 'Skip' on Nexus Mods (optional)"
    echo "    3. EA login is cached across sessions"
    echo ""
    if [[ "$HAS_DISCRETE" == "false" ]]; then
        echo "  NOTE: No discrete GPU detected. If the game crashes when a level loads,"
        echo "  consider streaming via Sunshine from a machine with a real GPU instead."
        echo "  Install Sunshine on the GPU machine: sudo ./setup.sh sunshine"
        echo ""
    fi
    echo "  To update Kyber later, re-run: sudo ./setup.sh kyber-launcher"
    echo ""
    echo "  Troubleshooting — 'Game Not Found':"
    echo "    find ~/.steam/steam/steamapps -name 'starwarsbattlefrontii.exe' 2>/dev/null | head -1 | xargs dirname"
    echo "    Paste that path into Kyber's SET GAME FOLDER dialog."
    echo ""
    echo "  Troubleshooting — 'Origin Error: language not entitled':"
    echo "    See README.md Gaming section for the registry fix."
}
