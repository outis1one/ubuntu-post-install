#!/bin/bash
# setup-swbf2-wolf.sh — Fix Star Wars Battlefront II (2017, AppID 1237950)
# for Wolf / Games-on-Whales + Moonlight streaming.
#
# What this does:
#   1. Extracts EA Desktop from the bundled ea_app.msi using msiextract on the
#      host — bypasses JunoConfigureRegistry, a .NET custom action that Wine
#      cannot run, which causes the full MSI installer to roll back.
#   2. Copies EA Desktop files (Link2EA.exe, EALocalHostSvc.exe, etc.) into the
#      game's Wine prefix.
#   3. Writes link2ea_fix.reg and ea_services.reg into drive_c so they survive
#      Wine prefix operations.
#   4. Installs a launch wrapper that imports the .reg files via Proton's own
#      wine binary on every launch — required because direct edits to system.reg
#      are overwritten when wineserver flushes to disk on shutdown.
#   5. Sets Steam launch options for SWBF2 and locks the config directory so
#      Steam cannot overwrite them via atomic rename on shutdown.
#
# Prerequisites — do these BEFORE running this script:
#   a. Wolf is running and Steam is open in Moonlight
#   b. GE-Proton10-34 (or later) is installed — in Steam go to
#      Settings → Compatibility → Enable Steam Play for all titles, then in
#      SWBF2 Properties → Compatibility force GE-Proton
#   c. msitools is installed on the Docker host:
#        sudo apt-get install -y msitools
#   d. Launch SWBF2 once from Moonlight — wait ~10 seconds for the
#      "Origin is not installed" error, then close it. This creates the Wine
#      prefix and drops ea_app.msi into drive_c.
#   e. Your EA account is linked to your Steam account at ea.com (one-time;
#      persists on EA's servers across reinstalls).
#
# After this script completes:
#   Launch SWBF2 from Moonlight. Let Vulkan shaders compile on first run
#   (several minutes, only happens once). EA App authenticates via your linked
#   Steam/EA account — no manual login needed if accounts are linked.
#
# Usage:
#   chmod +x setup-swbf2-wolf.sh
#   ./setup-swbf2-wolf.sh

set -euo pipefail

APPID="1237950"
GE_PROTON_VERSION="GE-Proton10-34"

echo "=== SWBF2 (2017) Wolf/Moonlight Setup ==="
echo ""

# ── Locate the WolfSteam container ─────────────────────────────────────────
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i WolfSteam | head -1)
if [ -z "$WOLF_CONTAINER" ]; then
    echo "ERROR: WolfSteam container is not running."
    echo "  Start Wolf and open Steam in Moonlight first."
    exit 1
fi
echo "Container: $WOLF_CONTAINER"

# ── Locate the Steam session home (Wolf mounts it as /home/retro) ──────────
STEAM_HOME=$(find /etc/wolf /opt/wolf "$HOME" -maxdepth 6 \
    -type d -name Steam 2>/dev/null | grep -i 'wolf\|apps' | head -1)
if [ -z "$STEAM_HOME" ]; then
    # Fallback: ask Docker where /home/retro actually lives on the host
    STEAM_HOME=$(docker inspect "$WOLF_CONTAINER" \
        --format '{{range .Mounts}}{{if eq .Destination "/home/retro"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null)
fi
if [ -z "$STEAM_HOME" ] || [ ! -d "$STEAM_HOME" ]; then
    echo "ERROR: Could not find Steam session home on the host."
    echo "  Open Steam in Moonlight at least once so Wolf creates the session directory."
    exit 1
fi
echo "Steam home: $STEAM_HOME"

# ── Install GE-Proton inside the container if not present ──────────────────
GEP_CONTAINER_DIR="/home/retro/.steam/compatibilitytools.d"
GEP_INSTALLED=$(docker exec "$WOLF_CONTAINER" \
    bash -c "ls '$GEP_CONTAINER_DIR' 2>/dev/null | grep -i '$GE_PROTON_VERSION'" 2>/dev/null || true)
if [ -n "$GEP_INSTALLED" ]; then
    echo "GE-Proton: $GE_PROTON_VERSION already installed in container"
else
    echo "Installing $GE_PROTON_VERSION into WolfSteam container..."
    GEP_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_PROTON_VERSION/$GE_PROTON_VERSION.tar.gz"
    GEP_TMP="/tmp/$GE_PROTON_VERSION.tar.gz"
    if ! curl -L --progress-bar -o "$GEP_TMP" "$GEP_URL"; then
        echo "ERROR: Download failed. Check your internet connection and try again."
        exit 1
    fi
    docker exec "$WOLF_CONTAINER" mkdir -p "$GEP_CONTAINER_DIR"
    docker cp "$GEP_TMP" "$WOLF_CONTAINER:/tmp/$GE_PROTON_VERSION.tar.gz"
    docker exec -u 1000 "$WOLF_CONTAINER" \
        tar -xzf "/tmp/$GE_PROTON_VERSION.tar.gz" -C "$GEP_CONTAINER_DIR"
    docker exec "$WOLF_CONTAINER" rm -f "/tmp/$GE_PROTON_VERSION.tar.gz"
    rm -f "$GEP_TMP"
    echo "GE-Proton installed in container."
    echo ""
    echo "IMPORTANT: In Steam (via Moonlight):"
    echo "  Right-click SWBF2 → Properties → Compatibility"
    echo "  → Force a specific Steam Play compatibility tool → $GE_PROTON_VERSION"
    echo "Then re-run this script."
    echo ""
    read -rp "Press Enter after you have set GE-Proton in Steam, or Ctrl+C to abort..."
fi

PFX_C="$STEAM_HOME/.steam/steam/steamapps/compatdata/$APPID/pfx/drive_c"
MSI="$PFX_C/ea_app.msi"

# ── Step 1: verify Wine prefix exists ──────────────────────────────────────
echo ""
if [ ! -d "$PFX_C" ]; then
    echo "ERROR: Wine prefix not found at $PFX_C"
    echo ""
    echo "Required before running this script:"
    echo "  1. In Steam (via Moonlight): right-click SWBF2 → Properties → Compatibility"
    echo "     → Force GE-Proton10-34 (or later)"
    echo "  2. Click Play on SWBF2 — wait ~10 seconds for 'Origin is not installed'"
    echo "  3. Close the error, then re-run this script"
    exit 1
fi
echo "[1/6] Wine prefix: OK"

# ── Step 2: verify ea_app.msi exists ───────────────────────────────────────
if [ ! -f "$MSI" ]; then
    echo ""
    echo "ERROR: ea_app.msi not found at $MSI"
    echo ""
    echo "Launch SWBF2 once from Moonlight so Steam drops ea_app.msi into the"
    echo "Wine prefix. You will see an 'Origin is not installed' error — that is"
    echo "expected. Close it, then re-run this script."
    exit 1
fi
MSI_SIZE=$(stat -c%s "$MSI")
if [ "$MSI_SIZE" -lt 50000000 ]; then
    echo "WARNING: ea_app.msi is only $MSI_SIZE bytes (expected ~227 MB)."
    echo "It may still be copying. Wait a moment and re-run."
    exit 1
fi
echo "[2/6] ea_app.msi ($(( MSI_SIZE / 1048576 )) MB): OK"

# ── Step 3: extract MSI on the host ────────────────────────────────────────
echo "[3/6] Extracting EA Desktop files from MSI (~30s)..."
if ! command -v msiextract >/dev/null 2>&1; then
    echo "ERROR: msitools not installed."
    echo "  sudo apt-get install -y msitools"
    exit 1
fi
EXTRACT_DIR="/tmp/ea_app_extracted_$$"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if ! msiextract -C "$EXTRACT_DIR" "$MSI" >/dev/null 2>&1; then
    echo "ERROR: msiextract failed. Check msitools is properly installed."
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
EA_SRC=$(find "$EXTRACT_DIR" -maxdepth 5 \
    -path "*/Electronic Arts/EA Desktop/EA Desktop" -type d 2>/dev/null | head -1)
if [ -z "$EA_SRC" ] || [ ! -f "$EA_SRC/Link2EA.exe" ]; then
    echo "ERROR: Link2EA.exe not found after extraction. MSI structure may have changed."
    ls -la "$EXTRACT_DIR/Electronic Arts/EA Desktop/" 2>/dev/null || true
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
echo "    $(ls "$EA_SRC" | wc -l) files extracted including Link2EA.exe"

# ── Step 4: copy EA Desktop files into Wine prefix ─────────────────────────
echo "[4/6] Installing EA Desktop files into Wine prefix..."
EA_DEST_BASE="$PFX_C/Program Files/Electronic Arts/EA Desktop"

# Determine the versioned directory name. Use the broken symlink target from a
# previous failed install attempt if present; otherwise default.
EA_VERSION=$(docker exec "$WOLF_CONTAINER" \
    readlink "/home/retro/.steam/steam/steamapps/compatdata/$APPID/pfx/drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop" \
    2>/dev/null || echo "14.2.0.3345")

EA_DEST="$EA_DEST_BASE/$EA_VERSION"
mkdir -p "$EA_DEST"
cp -r "$EA_SRC/." "$EA_DEST/"
chown -R 1000:1000 "$EA_DEST_BASE"

# Remove any stale symlink, then create a clean one
rm -f "$EA_DEST_BASE/EA Desktop"
ln -sf "$EA_VERSION" "$EA_DEST_BASE/EA Desktop"

if [ ! -f "$EA_DEST/Link2EA.exe" ]; then
    echo "ERROR: Copy failed — Link2EA.exe not found at $EA_DEST/Link2EA.exe"
    rm -rf "$EXTRACT_DIR"
    exit 1
fi
echo "    EA Desktop $EA_VERSION installed"
rm -rf "$EXTRACT_DIR"

# ── Step 5: write .reg files and launch wrapper ─────────────────────────────
echo "[5/6] Writing registry fix files and launch wrapper..."

# link2ea:// protocol handler — tells Wine how to find Link2EA.exe.
# GE-Proton's steam.exe intercepts link2ea:// URLs and uses this handler
# to launch Link2EA.exe, which hands off to EA Desktop for authentication.
cat > "$PFX_C/link2ea_fix.reg" << 'REGEOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea]
@="URL:link2ea Protocol"
"URL Protocol"=""

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea\shell\open\command]
@="\"C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\Link2EA.exe\" \"%1\""
REGEOF

# EA Windows services — EALocalHostSvc provides local IPC that Link2EA.exe
# needs. Without it launch fails with RPC_S_SERVER_UNAVAILABLE (0x800706ba).
cat > "$PFX_C/ea_services.reg" << 'REGEOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EALocalHostSvc]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EALocalHostSvc.exe"
"DisplayName"="EA Local Host Service"
"ObjectName"="LocalSystem"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EABackgroundService]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EABackgroundService.exe"
"DisplayName"="EA Background Service"
"ObjectName"="LocalSystem"
REGEOF

chown 1000:1000 "$PFX_C/link2ea_fix.reg" "$PFX_C/ea_services.reg"

# Launch wrapper. Runs regedit through Steam's Proton/sniper launch chain on
# every launch so registry entries survive wineserver restarts. Direct edits
# to system.reg are overwritten when wineserver flushes to disk on shutdown —
# going through the launch chain writes into wineserver's live memory instead.
WRAPPER=$(mktemp)
cat > "$WRAPPER" << 'WRAPEOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\ea_services.reg"
exec "$@"
WRAPEOF
chmod +x "$WRAPPER"
docker cp "$WRAPPER" "$WOLF_CONTAINER":/home/retro/ea_install.sh
docker exec "$WOLF_CONTAINER" chmod +x /home/retro/ea_install.sh
rm -f "$WRAPPER"
echo "    .reg files and wrapper installed"

# ── Step 6: set launch options and lock localconfig.vdf ────────────────────
echo "[6/6] Setting Steam launch options..."
STEAM_UID=$(ls "$STEAM_HOME/.steam/steam/userdata/" 2>/dev/null | head -1)
if [ -z "$STEAM_UID" ]; then
    echo "WARNING: No Steam userdata found. Open Steam in Moonlight and sign in first."
    echo "  Then re-run this script to set launch options, or set them manually:"
    echo "  SWBF2 → Properties → Launch Options:"
    echo "    STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%"
else
    CFG_DIR="$STEAM_HOME/.steam/steam/userdata/$STEAM_UID/config"
    CFG_FILE="$CFG_DIR/localconfig.vdf"
    if [ ! -f "$CFG_FILE" ]; then
        echo "WARNING: localconfig.vdf not found. Open Steam in Moonlight first, then re-run."
    else
        # Stop Steam so it flushes before we edit
        docker exec "$WOLF_CONTAINER" pkill -f steam.sh 2>/dev/null || true
        sleep 5
        chmod 755 "$CFG_DIR" 2>/dev/null || true

        LAUNCH_OPT='STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%'
        python3 - "$CFG_FILE" "$LAUNCH_OPT" << 'PYEOF'
import sys, re
path, opt = sys.argv[1], sys.argv[2]
with open(path) as f:
    c = f.read()
new = re.sub(r'("1237950".*?"LaunchOptions"\s*)"[^"]*"', rf'\1"{opt}"', c, flags=re.DOTALL)
if new == c:
    new = re.sub(r'("1237950"\s*\n\s*\{)', rf'\1\n\t\t\t\t"LaunchOptions"\t\t"{opt}"', c)
if new == c:
    print("WARNING: 1237950 block not found — set launch options manually in Steam:")
    print("  SWBF2 → Properties → Launch Options:")
    print("  STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%")
    sys.exit(0)
with open(path, 'w') as f:
    f.write(new)
print("  LaunchOptions set.")
PYEOF
        chown 1000:1000 "$CFG_FILE"

        # Lock the config directory so Steam can't overwrite localconfig.vdf via
        # atomic rename (writes a temp file then renames into the directory).
        # chmod 444 on the file is bypassed by rename; locking the directory is not.
        chmod 555 "$CFG_DIR"
        echo "    Config directory locked (chmod 555)"
    fi
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Open Steam in Moonlight"
echo "  2. Click Play on SWBF2"
echo "  3. Let Vulkan shaders compile — do NOT skip (takes several minutes, once only)"
echo "  4. EA App authenticates automatically if your Steam and EA accounts are linked"
echo "  5. Game launches"
echo ""
echo "Troubleshooting:"
echo "  Check wrapper log:  docker exec $WOLF_CONTAINER tail /tmp/ea_install.log"
echo "  Check Proton log:   tail $STEAM_HOME/steam-$APPID.log"
echo ""
echo "If launch options were not set automatically, set them manually in Steam:"
echo "  Right-click SWBF2 → Properties → Launch Options:"
echo "  STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%"
