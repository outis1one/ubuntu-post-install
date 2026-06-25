#!/bin/bash
# setup-kyber-linux.sh — Install the Kyber Launcher (native Linux port) for
# SWBF2 (2017) on a native Linux Steam machine.
#
# Kyber is a community multiplayer client for Star Wars Battlefront II (2017)
# after EA shut down the official servers in 2022. Kyber went open-source
# under GPL in January 2026.
#
# ── The RIGHT way: native Linux AppImage ───────────────────────────────────
#
# As of 2026 there is an unofficial native Linux port of Kyber:
#   https://github.com/simonlinuxcraft/kyber-linuxport-unofficial
#
# It ships as a self-contained AppImage (x86_64). No Wine, no Proton, no
# cmd.exe shims, no OAuth watcher daemons. EA login is handled natively by
# the bundled Maxima service (open-source EA Desktop replacement by the
# Armchair Developers team).
#
# Tested on: Ubuntu 24.04+, Fedora, SteamOS 3.7+ (requires glibc 2.38+)
# Recommended Proton for SWBF2 itself: GE-Proton 10.x or proton-cachyos 11.x
# (Kyber/Maxima downloads and manages its own GE-Proton automatically)
#
# ── Login flow ─────────────────────────────────────────────────────────────
#
#   1. Launch the AppImage.
#   2. Click "EA Account" — a browser window opens to accounts.ea.com.
#   3. Log in with your EA account.
#   4. Kyber completes authentication via Maxima (no redirect hacks needed).
#   5. Click "Skip" on Nexus Mods if you don't use mods.
#
# ── How to play ────────────────────────────────────────────────────────────
#
#   Kyber launches SWBF2 itself — do NOT launch SWBF2 from Steam first.
#   If Steam's SWBF2 is running when Kyber starts, kill it.
#
#   1. Open Steam (must be running for library access, but do NOT click Play).
#   2. Launch Kyber (AppImage or 'kyber' command).
#   3. In Kyber: join a server (HOME) or create one (HOST).
#   4. Kyber/Maxima launches SWBF2 via its own bundled GE-Proton.
#   5. Wait for the Frostbite/SWBF2 loading screen. This takes 1-3 minutes.
#   6. If the SWBF2 window appears but looks stuck: click its taskbar entry
#      or press Alt+Tab to bring it into focus — this is normal behaviour
#      when the game is launched by a wrapper process rather than directly.
#
# ── Hosting a private server ───────────────────────────────────────────────
#
#   1. In Kyber, click HOST.
#   2. Select maps/modes for your rotation (drag into Active Rotation).
#   3. In the right panel: set a name, set a PASSWORD (keeps it private).
#   4. Click Settings to adjust max players etc.
#   5. Click START SERVER.
#   6. Share the server name + password with friends — they search by name
#      in the HOME tab and enter the password to join.
#
#   Bots: SWBF2 fills empty player slots with AI automatically. No separate
#   bot count setting is needed — just start the server and join it.
#
# ── Why NOT Wine/Proton for the Kyber launcher ─────────────────────────────
#
# The Windows Kyber launcher (kyber_launcher.exe) has a fatal flaw on Linux:
# its EA OAuth flow calls  cmd /c start "" "<URL>"  to open a browser.
# Wine's cmd.exe crashes with STATUS_ACCESS_VIOLATION (0xC0000005) on long
# URLs. Fixing this requires replacing Proton's own cmd.exe binary with a
# shim — and the shim gets overwritten on every Proton update. Additionally,
# EA's auth callback uses the eadesktop:// URI scheme (not http://127.0.0.1
# as originally believed), which has no Linux handler. The native AppImage
# bypasses all of this entirely.
#
# ── Prerequisites ──────────────────────────────────────────────────────────
#   a. SWBF2 (AppID 1237950) installed via Steam.
#      Run setup-swbf2-linux.sh first if needed.
#      NOTE: Kyber manages its own GE-Proton for launching the game — you
#      do not need to configure a Proton version for SWBF2 in Steam.
#   b. Internet access to download the AppImage (~173 MB).
#   c. glibc 2.38+ (Ubuntu 24.04+, Fedora 38+, SteamOS 3.7+).
#      On Ubuntu 22.04 the AppImage may not run — upgrade to 24.04.
#   d. Unprivileged user namespaces enabled (required for Kyber's sandbox).
#      This script checks and optionally fixes this for you (see below).
#
# ── Unprivileged user namespaces (bwrap) ───────────────────────────────────
#
# Kyber's AppImage uses bubblewrap (bwrap) for sandboxing. Ubuntu 24.04
# restricts unprivileged user namespaces by default, which causes the error:
#   bwrap: setting up uid map: Permission denied
#
# Fix (this script can apply these automatically):
#   sudo sysctl -w kernel.unprivileged_userns_clone=1
#   sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
#
# To make permanent across reboots, write to /etc/sysctl.d/99-userns.conf:
#   kernel.unprivileged_userns_clone = 1
#   kernel.apparmor_restrict_unprivileged_userns = 0
#
# ── "Game Not Found" dialog ────────────────────────────────────────────────
#
# If Kyber shows "Game Not Found" after launching:
#   1. Click SET GAME FOLDER in Kyber.
#   2. Run this command to find your SWBF2 install path:
#        find ~/.steam/steam/steamapps -name 'starwarsbattlefrontii.exe' 2>/dev/null | head -1 | xargs dirname
#   3. Paste that path into the dialog. Kyber remembers it after this.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#   chmod +x setup-kyber-linux.sh
#   ./setup-kyber-linux.sh

set -euo pipefail

KYBER_REPO="simonlinuxcraft/kyber-linuxport-unofficial"
INSTALL_DIR="$HOME/.local/share/kyber"
DESKTOP_FILE="$HOME/.local/share/applications/kyber-launcher.desktop"
BIN_LINK="$HOME/.local/bin/kyber"

echo "=== Kyber Launcher — Native Linux Setup ==="
echo ""

# ── Check glibc version ────────────────────────────────────────────────────
GLIBC=$(ldd --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+$' || echo "0.0")
GLIBC_MAJOR=$(echo "$GLIBC" | cut -d. -f1)
GLIBC_MINOR=$(echo "$GLIBC" | cut -d. -f2)
if [ "$GLIBC_MAJOR" -lt 2 ] || { [ "$GLIBC_MAJOR" -eq 2 ] && [ "$GLIBC_MINOR" -lt 38 ]; }; then
    echo "WARNING: glibc $GLIBC detected. The Kyber AppImage requires glibc 2.38+."
    echo "  Ubuntu 22.04 ships glibc 2.35 — upgrade to Ubuntu 24.04 or use"
    echo "  a newer distro. Continuing anyway in case your system has it..."
    echo ""
fi

# ── Check/fix unprivileged user namespaces (bwrap requirement) ────────────
echo "[0/3] Checking unprivileged user namespace support (required for Kyber)..."

USERNS_OK=true
CLONE_VAL=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
APPARMOR_VAL=$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null || echo "0")

if [ "$CLONE_VAL" != "1" ] || [ "$APPARMOR_VAL" != "0" ]; then
    USERNS_OK=false
    echo "  WARNING: Unprivileged user namespaces are restricted."
    echo "  Kyber uses bubblewrap (bwrap) which requires them."
    echo "  Without this fix you will see: bwrap: setting up uid map: Permission denied"
    echo ""
    if [ "$(id -u)" -eq 0 ]; then
        echo "  Applying fix now (running as root)..."
        sysctl -w kernel.unprivileged_userns_clone=1
        sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
        SYSCTL_FILE="/etc/sysctl.d/99-userns.conf"
        cat > "$SYSCTL_FILE" << 'SYSCTL'
# Required for Kyber AppImage (bubblewrap sandbox)
kernel.unprivileged_userns_clone = 1
kernel.apparmor_restrict_unprivileged_userns = 0
SYSCTL
        echo "  Saved to $SYSCTL_FILE — will persist across reboots."
        USERNS_OK=true
    else
        echo "  To fix, run these commands (requires sudo):"
        echo "    sudo sysctl -w kernel.unprivileged_userns_clone=1"
        echo "    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
        echo ""
        echo "  To make permanent, create /etc/sysctl.d/99-userns.conf:"
        echo "    echo 'kernel.unprivileged_userns_clone = 1' | sudo tee /etc/sysctl.d/99-userns.conf"
        echo "    echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee -a /etc/sysctl.d/99-userns.conf"
        echo ""
        echo "  Re-run this script with sudo to apply automatically."
        echo "  Continuing with download regardless..."
    fi
else
    echo "  OK — unprivileged user namespaces are enabled."
fi
echo ""

# ── Fetch latest release URL ───────────────────────────────────────────────
echo "[1/3] Fetching latest Kyber Linux release..."
API_URL="https://api.github.com/repos/${KYBER_REPO}/releases/latest"
APPIMAGE_URL=$(curl -fsSL "$API_URL" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
assets = data.get('assets', [])
for a in assets:
    url = a['browser_download_url']
    if url.endswith('.AppImage'):
        print(url)
        break
" 2>/dev/null)

if [ -z "$APPIMAGE_URL" ]; then
    echo "ERROR: Could not fetch AppImage URL from GitHub."
    echo "  Check: https://github.com/${KYBER_REPO}/releases"
    echo "  Download the AppImage manually and run:  chmod +x KyberLinuxPort*.AppImage && ./KyberLinuxPort*.AppImage"
    exit 1
fi

VERSION=$(echo "$APPIMAGE_URL" | grep -oP 'v[\d.a-z-]+' | head -1)
echo "  Latest: $VERSION"
echo "  URL: $APPIMAGE_URL"
echo ""

# ── Download ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"
APPIMAGE_PATH="$INSTALL_DIR/KyberLinuxPort.AppImage"

CURRENT_VERSION=""
if [ -f "$APPIMAGE_PATH.version" ]; then
    CURRENT_VERSION=$(cat "$APPIMAGE_PATH.version")
fi

if [ -f "$APPIMAGE_PATH" ] && [ "$CURRENT_VERSION" = "$VERSION" ]; then
    echo "[2/3] Already up to date ($VERSION) — skipping download."
else
    echo "[2/3] Downloading Kyber Linux AppImage ($VERSION)..."
    curl -L --progress-bar -o "$APPIMAGE_PATH" "$APPIMAGE_URL"
    chmod +x "$APPIMAGE_PATH"
    echo "$VERSION" > "$APPIMAGE_PATH.version"
    echo "  Saved to: $APPIMAGE_PATH"
fi
echo ""

# ── Desktop entry + bin symlink ────────────────────────────────────────────
echo "[3/3] Installing desktop entry and launcher..."

mkdir -p "$(dirname "$DESKTOP_FILE")" "$HOME/.local/bin"

cat > "$DESKTOP_FILE" << EOF
[Desktop Entry]
Type=Application
Name=Kyber Launcher
Comment=Community multiplayer for Star Wars Battlefront II (2017)
Exec=${APPIMAGE_PATH}
Icon=kyber
Categories=Game;
StartupNotify=true
EOF

ln -sf "$APPIMAGE_PATH" "$BIN_LINK"
update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true

echo ""
echo "=== Kyber Setup Complete ==="
echo ""
echo "Launch Kyber:"
echo "  From terminal:    kyber"
echo "  From app menu:    search 'Kyber Launcher'"
echo "  Direct:           $APPIMAGE_PATH"
echo ""
echo "Every time you want to play:"
echo "  1. Open Steam (must be running for library validation)."
echo "     Do NOT click Play on SWBF2 in Steam — Kyber launches it."
echo "  2. Launch Kyber and join or host a server."
echo "  3. Kyber/Maxima will launch SWBF2 using its own bundled GE-Proton."
echo "  4. Wait 1-3 minutes for the Frostbite loading screen."
echo "  5. If SWBF2 appears but you can't click into it: press Alt+Tab or"
echo "     click its taskbar entry to bring it into focus."
echo ""
echo "First run (one-time):"
echo "  1. Click 'EA Account' and log in with your EA credentials."
echo "     The browser opens to accounts.ea.com — log in there."
echo "  2. Click 'Skip' on the Nexus Mods step (only needed for mods)."
echo "  3. EA login is cached — you stay logged in across sessions."
echo ""
echo "If Kyber says 'Game Not Found':"
echo "  Click SET GAME FOLDER and run this to find the path:"
echo "    find ~/.steam/steam/steamapps -name 'starwarsbattlefrontii.exe' 2>/dev/null | head -1 | xargs dirname"
echo "  Paste that path into the SET GAME FOLDER dialog. Kyber remembers it."
echo ""
echo "Hosting a private server with bots:"
echo "  HOST → pick maps/modes → set a name and PASSWORD → Start Server."
echo "  Share the server name + password with friends (they search by name in HOME)."
echo "  Bot count: HOST panel → AUTOPLAYERS → set BOTS TEAM 1 and BOTS TEAM 2"
echo "    (e.g. 4 each) → click UPDATE SERVER."
echo "  Bot difficulty: use the BOT DIFFICULTY slider (RECRUIT / OFFICER / KNIGHT / MASTER)."
echo ""
if [ "$USERNS_OK" = "false" ]; then
    echo "IMPORTANT: Fix unprivileged user namespaces before launching Kyber:"
    echo "  sudo sysctl -w kernel.unprivileged_userns_clone=1"
    echo "  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
    echo "  Or re-run this script with sudo to apply automatically."
    echo ""
fi
echo "SWBF2 must be installed via Steam (AppID 1237950)."
echo "To update Kyber later, re-run this script."
