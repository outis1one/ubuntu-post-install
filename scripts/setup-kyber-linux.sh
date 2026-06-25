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
#
# ── Login flow ─────────────────────────────────────────────────────────────
#
#   1. Launch the AppImage.
#   2. Click "EA Account" — a browser window opens to accounts.ea.com.
#   3. Log in with your EA account.
#   4. Kyber completes authentication via Maxima (no redirect hacks needed).
#   5. Click "Skip" on Nexus Mods if you don't use mods.
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
#   a. SWBF2 (AppID 1237950) installed via Steam with Proton (GE-Proton
#      recommended). Run setup-swbf2-linux.sh first if needed.
#   b. Internet access to download the AppImage (~173 MB).
#   c. glibc 2.38+ (Ubuntu 24.04+, Fedora 38+, SteamOS 3.7+).
#      On Ubuntu 22.04 the AppImage may not run — upgrade to 24.04.
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
    echo "[1/3] Already up to date ($VERSION) — skipping download."
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
echo "  1. Launch SWBF2 from Steam first — let it fully load to the main menu."
echo "  2. Then launch Kyber and join or host a server."
echo "  Kyber does not launch the game itself — Steam must start SWBF2 first."
echo ""
echo "First run (one-time):"
echo "  1. Click 'EA Account' and log in with your EA credentials."
echo "  2. Click 'Skip' on the Nexus Mods step (optional — only needed for mods)."
echo "  3. EA login is cached — you stay logged in across sessions."
echo ""
echo "Hosting a private server with bots:"
echo "  HOST → pick maps → set a name and PASSWORD → Start Server."
echo "  Share the server name + password with friends (they search by name in HOME)."
echo "  Bots fill empty slots automatically — no separate bot setting needed."
echo ""
echo "SWBF2 must be installed via Steam (AppID 1237950) with GE-Proton."
echo "GE-Proton: https://github.com/GloriousEggroll/proton-ge-custom/releases"
echo ""
echo "To update Kyber later, re-run this script."
