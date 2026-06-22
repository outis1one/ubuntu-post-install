#!/bin/bash
# setup-swbf2-linux.sh — Fix Star Wars Battlefront II (2017, AppID 1237950)
# for native Linux Steam with GE-Proton (no Wolf / no Docker).
#
# What this does:
#   1. Extracts EA Desktop from the bundled ea_app.msi using msiextract —
#      bypasses JunoConfigureRegistry, a .NET custom action Wine cannot run,
#      which causes the full MSI installer to roll back.
#   2. Copies EA Desktop files (Link2EA.exe, EALocalHostSvc.exe, etc.) into the
#      game's Wine prefix.
#   3. Writes link2ea_fix.reg and ea_services.reg into drive_c so they survive
#      Wine prefix operations.
#   4. Installs a launch wrapper that imports the .reg files via Proton's own
#      wine binary on every launch — required because direct edits to system.reg
#      are overwritten when wineserver flushes to disk on shutdown.
#   5. Sets Steam launch options for SWBF2.
#
# Prerequisites — do these BEFORE running this script:
#   a. GE-Proton10-34 (or later) installed via ProtonUp-Qt or manually.
#      In Steam: SWBF2 → Properties → Compatibility → Force GE-Proton.
#   b. msitools installed:
#        sudo apt-get install -y msitools       # Debian/Ubuntu
#        sudo dnf install -y msitools           # Fedora
#   c. Launch SWBF2 once — wait ~10 seconds for the "Origin is not installed"
#      error, then close it. This creates the Wine prefix and drops ea_app.msi.
#   d. Your EA account is linked to your Steam account at ea.com (one-time;
#      persists on EA's servers across reinstalls).
#
# After this script completes:
#   Launch SWBF2. Let Vulkan shaders compile on first run (several minutes,
#   only once). EA App authenticates via your linked Steam/EA account.
#
# Usage:
#   chmod +x setup-swbf2-linux.sh
#   ./setup-swbf2-linux.sh

set -euo pipefail

APPID="1237950"
WRAPPER_PATH="$HOME/.local/bin/ea_install.sh"

echo "=== SWBF2 (2017) Linux Steam Setup ==="
echo ""

# ── Locate Steam home ───────────────────────────────────────────────────────
# Steam can live in either of two locations depending on install method.
find_steam_home() {
    for candidate in \
        "$HOME/.steam/steam" \
        "$HOME/.local/share/Steam" \
        "$HOME/.var/app/com.valvesoftware.Steam/.steam/steam"; do
        if [ -d "$candidate/steamapps" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

STEAM_HOME=$(find_steam_home) || {
    echo "ERROR: Steam home not found. Is Steam installed and have you launched it at least once?"
    exit 1
}
echo "Steam home: $STEAM_HOME"

PFX_C="$STEAM_HOME/steamapps/compatdata/$APPID/pfx/drive_c"
MSI="$PFX_C/ea_app.msi"

# ── Step 1: verify Wine prefix exists ──────────────────────────────────────
echo ""
if [ ! -d "$PFX_C" ]; then
    echo "ERROR: Wine prefix not found at $PFX_C"
    echo ""
    echo "Required before running this script:"
    echo "  1. In Steam: right-click SWBF2 → Properties → Compatibility"
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
    echo "Launch SWBF2 once so Steam drops ea_app.msi into the Wine prefix."
    echo "You will see an 'Origin is not installed' error — that is expected."
    echo "Close it, then re-run this script."
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
    echo "  Debian/Ubuntu: sudo apt-get install -y msitools"
    echo "  Fedora:        sudo dnf install -y msitools"
    exit 1
fi
EXTRACT_DIR="/tmp/ea_app_extracted_$$"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
if ! msiextract -C "$EXTRACT_DIR" "$MSI" >/dev/null 2>&1; then
    echo "ERROR: msiextract failed. Check that msitools is properly installed."
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

# Use the version from a broken symlink left by a failed install, or default.
EA_VERSION="14.2.0.3345"
if [ -L "$EA_DEST_BASE/EA Desktop" ]; then
    _linked=$(readlink "$EA_DEST_BASE/EA Desktop" 2>/dev/null || true)
    [ -n "$_linked" ] && EA_VERSION="$_linked"
fi

EA_DEST="$EA_DEST_BASE/$EA_VERSION"
mkdir -p "$EA_DEST"
cp -r "$EA_SRC/." "$EA_DEST/"

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

# Launch wrapper. Runs regedit through Proton's launch chain on every launch
# so registry entries survive wineserver restarts. Direct edits to system.reg
# are overwritten when wineserver flushes to disk on shutdown.
mkdir -p "$HOME/.local/bin"
cat > "$WRAPPER_PATH" << 'WRAPEOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\ea_services.reg"
exec "$@"
WRAPEOF
chmod +x "$WRAPPER_PATH"
echo "    .reg files written, wrapper installed at $WRAPPER_PATH"

# ── Step 6: set launch options in localconfig.vdf ──────────────────────────
echo "[6/6] Setting Steam launch options..."
STEAM_UID=$(ls "$STEAM_HOME/userdata/" 2>/dev/null | head -1)
if [ -z "$STEAM_UID" ]; then
    echo "WARNING: No Steam userdata found. Sign in to Steam first, then re-run."
    echo "  Or set launch options manually — see below."
else
    CFG_FILE="$STEAM_HOME/userdata/$STEAM_UID/config/localconfig.vdf"
    if [ ! -f "$CFG_FILE" ]; then
        echo "WARNING: localconfig.vdf not found. Launch Steam first, then re-run."
    else
        LAUNCH_OPT="$WRAPPER_PATH %command%"
        python3 - "$CFG_FILE" "$LAUNCH_OPT" << 'PYEOF'
import sys, re
path, opt = sys.argv[1], sys.argv[2]
with open(path) as f:
    c = f.read()
new = re.sub(r'("1237950".*?"LaunchOptions"\s*)"[^"]*"', rf'\1"{opt}"', c, flags=re.DOTALL)
if new == c:
    new = re.sub(r'("1237950"\s*\n\s*\{)', rf'\1\n\t\t\t\t"LaunchOptions"\t\t"{opt}"', c)
if new == c:
    print("WARNING: 1237950 block not found — set launch options manually (see below).")
    sys.exit(0)
with open(path, 'w') as f:
    f.write(new)
print("  LaunchOptions set.")
PYEOF
    fi
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Launch options set to: $WRAPPER_PATH %command%"
echo ""
echo "Next steps:"
echo "  1. Launch SWBF2 from Steam"
echo "  2. Let Vulkan shaders compile — do NOT skip (takes several minutes, once only)"
echo "  3. EA App authenticates automatically if your Steam and EA accounts are linked"
echo "  4. Game launches"
echo ""
echo "If launch options were not set automatically, set them in Steam:"
echo "  Right-click SWBF2 → Properties → Launch Options:"
echo "  $WRAPPER_PATH %command%"
echo ""
echo "Troubleshooting:"
echo "  Wrapper log:  tail /tmp/ea_install.log"
echo "  Proton log:   tail $STEAM_HOME/logs/steam_$APPID.log 2>/dev/null || \\"
echo "                tail \$(ls -t $STEAM_HOME/steamapps/compatdata/$APPID/../../../steam-$APPID.log 2>/dev/null | head -1)"
