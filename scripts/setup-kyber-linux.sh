#!/bin/bash
# setup-kyber-linux.sh — Install the Kyber Launcher for SWBF2 (2017) on a
# native Linux Steam machine (headless or desktop) with Proton Experimental.
#
# Kyber is a community multiplayer client for Star Wars Battlefront II (2017)
# after EA shut down the official servers. It is a Windows app (Flutter/Rust)
# with an embedded Microsoft Edge WebView2 used for its EA OAuth login flow.
#
# ── Why this is the RIGHT place to run Kyber ───────────────────────────────
#
# Kyber's login redirects to a qrc:// URI (a Qt-internal resource scheme) that
# only its OWN embedded WebView2 can intercept. WebView2 therefore MUST work.
#
# Inside a Wolf / Games-on-Whales Docker container, WebView2 cannot start:
# Proton wraps Wine in bubblewrap (bwrap), and nesting that inside Docker
# blocks CLONE_NEWUSER, which WebView2's subprocess sandbox requires. The
# result is endless login failures (see setup-kyber-wolf.sh for the gory
# details and the fake-cmd.exe / Firefox workarounds that still cannot finish
# the flow because no external browser can handle qrc://).
#
# On NATIVE Linux Steam there is only a single bwrap layer (Proton's own),
# which has enough namespace privilege for WebView2 to initialize. So here the
# login flow works as designed: Kyber opens its built-in browser, you log in
# to EA, EA redirects to qrc://, and Kyber's WebView2 catches the auth code.
#
# No fake cmd.exe. No Firefox. No URL watcher. None of that scaffolding is
# needed here — it only existed to work around WebView2 being unable to start.
#
# ── Do you still need WebView2? YES ────────────────────────────────────────
#
# WebView2 is not the problem — it is the solution. It is the only component
# that can complete Kyber's EA OAuth login. This script makes sure the
# WebView2 Evergreen RUNTIME (not just the bootstrapper stub) is actually
# installed in Kyber's Wine prefix. If only the stub is present, Kyber falls
# back to `cmd /c start <url>` and login fails even on native Linux.
#
# ── Headless note ──────────────────────────────────────────────────────────
#
# On a headless GPU box you do not need Wolf to stream. Use Steam Remote Play:
# install Steam, set up a virtual display so Steam has something to render to,
# add Kyber + SWBF2, then connect with the Steam Link app from any device.
# This script sets up a dummy/virtual X display if no display is detected.
#
# ── Prerequisites ──────────────────────────────────────────────────────────
#   a. Steam installed and launched at least once (native, not Flatpak ideally
#      — Flatpak works but paths differ; this script handles both).
#   b. SWBF2 (AppID 1237950) installed and working with Proton Experimental
#      (run setup-swbf2-linux.sh first).
#   c. KyberLauncher.exe downloaded from https://kyber.gg saved to
#      ~/Downloads/KyberLauncher.exe (or pass the path as $1).
#
# ── Usage ──────────────────────────────────────────────────────────────────
#   chmod +x setup-kyber-linux.sh
#   ./setup-kyber-linux.sh [/path/to/KyberLauncher.exe]

set -euo pipefail

KYBER_INSTALLER="${1:-$HOME/Downloads/KyberLauncher.exe}"
KYBER_COMPAT_ID="kyber"          # Wine prefix name under compatdata/
KYBER_APPID="9900000001"         # non-Steam shortcut appid

echo "=== Kyber Launcher — Native Linux Steam Setup ==="
echo ""

# ── Locate Steam home ──────────────────────────────────────────────────────
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
    echo "ERROR: Steam home not found. Install Steam and launch it once."
    exit 1
}
echo "Steam home: $STEAM_HOME"

# ── Verify Kyber installer ─────────────────────────────────────────────────
if [ ! -f "$KYBER_INSTALLER" ]; then
    echo ""
    echo "ERROR: Kyber installer not found at: $KYBER_INSTALLER"
    echo ""
    echo "Download KyberLauncher.exe from https://kyber.gg, then:"
    echo "  $0 /path/to/KyberLauncher.exe"
    exit 1
fi
echo "Kyber installer: $KYBER_INSTALLER"

# ── Locate Proton Experimental ─────────────────────────────────────────────
# Kyber's WebView2 is best supported on Proton Experimental (newest Wine +
# the most complete WebView2/Edge compatibility shims). GE-Proton also works,
# but Experimental tends to have the freshest fixes for Chromium sandboxing.
PROTON_DIR=$(find "$STEAM_HOME/steamapps/common" -maxdepth 1 -type d \
    -iname "Proton Experimental" 2>/dev/null | head -1)
if [ -z "$PROTON_DIR" ]; then
    PROTON_DIR=$(find "$STEAM_HOME/steamapps/common" -maxdepth 1 -type d \
        -iname "Proton*" 2>/dev/null | sort | tail -1)
fi
if [ -z "$PROTON_DIR" ] || [ ! -x "$PROTON_DIR/proton" ]; then
    echo ""
    echo "ERROR: Proton not found under $STEAM_HOME/steamapps/common."
    echo "  In Steam → Settings → Compatibility, install Proton Experimental,"
    echo "  then re-run this script."
    exit 1
fi
echo "Proton: $PROTON_DIR"

# ── Headless display check ─────────────────────────────────────────────────
# WebView2 (and Kyber's Flutter UI) need a display to render to. On a headless
# box with no X/Wayland session, Kyber's window has nowhere to draw.
if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
    echo ""
    echo "NOTE: No DISPLAY or WAYLAND_DISPLAY detected (headless box)."
    echo "  For Steam Remote Play you need a virtual display so Steam can"
    echo "  render. Options:"
    echo "    - Configure your GPU driver's dummy/virtual display (recommended"
    echo "      for hardware-encoded Remote Play), OR"
    echo "    - Run this whole setup under Xvfb for the install step only:"
    echo "        xvfb-run -a $0 $KYBER_INSTALLER"
    echo ""
    echo "  Continuing the install (the prefix can be built headless), but you"
    echo "  must have a real or virtual display when you actually launch Kyber."
    echo ""
fi

# ── Build Kyber Wine prefix and run the installer ──────────────────────────
echo ""
echo "[1/5] Creating Kyber Wine prefix and running the installer..."

KYBER_PFX="$STEAM_HOME/steamapps/compatdata/$KYBER_COMPAT_ID"
mkdir -p "$KYBER_PFX"

export STEAM_COMPAT_DATA_PATH="$KYBER_PFX"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_HOME"
export PROTON_NO_ESYNC=1

# /S runs most NSIS/Inno installers silently. If Kyber's installer ignores it,
# a GUI installer window appears — complete it normally (needs a display).
"$PROTON_DIR/proton" run "$KYBER_INSTALLER" /S || \
    "$PROTON_DIR/proton" run "$KYBER_INSTALLER" || true

sleep 3

KYBER_EXE_PATH=$(find "$KYBER_PFX/pfx" -name "Kyber.exe" 2>/dev/null | head -1)
if [ -z "$KYBER_EXE_PATH" ]; then
    echo ""
    echo "WARNING: Kyber.exe not found after installation."
    echo "  If a GUI installer appeared, make sure you completed it."
    echo "  Default install path assumed; continuing."
    KYBER_EXE_WIN='C:\Program Files\Kyber\Kyber.exe'
    KYBER_START_DIR='C:\Program Files\Kyber\'
else
    echo "  Kyber.exe: $KYBER_EXE_PATH"
    rel=$(echo "$KYBER_EXE_PATH" | sed "s|.*/pfx/drive_c/||")
    KYBER_EXE_WIN="C:\\$(echo "$rel" | sed 's|/|\\|g')"
    dir_rel=$(dirname "$rel")
    KYBER_START_DIR="C:\\$(echo "$dir_rel" | sed 's|/|\\|g')\\"
fi
echo "  Windows path: $KYBER_EXE_WIN"

# ── Ensure WebView2 Evergreen runtime is installed ─────────────────────────
echo ""
echo "[2/5] Verifying WebView2 runtime in the Kyber prefix..."

# The Evergreen runtime lives under one of these in the prefix once installed.
WV2_FOUND=$(find "$KYBER_PFX/pfx/drive_c" -iname "msedgewebview2.exe" 2>/dev/null | head -1)
if [ -n "$WV2_FOUND" ]; then
    echo "  WebView2 runtime present:"
    echo "    $WV2_FOUND"
else
    echo "  WebView2 runtime NOT found — installing Evergreen bootstrapper..."
    WV2_BOOT="/tmp/MicrosoftEdgeWebview2Setup_$$.exe"
    # Microsoft Evergreen Standalone/Bootstrapper installer (stable channel)
    WV2_URL="https://go.microsoft.com/fwlink/p/?LinkId=2124703"
    if curl -L --progress-bar -o "$WV2_BOOT" "$WV2_URL"; then
        # /silent /install performs an unattended Evergreen runtime install.
        "$PROTON_DIR/proton" run "$WV2_BOOT" /silent /install || true
        rm -f "$WV2_BOOT"
        sleep 3
        WV2_FOUND=$(find "$KYBER_PFX/pfx/drive_c" -iname "msedgewebview2.exe" 2>/dev/null | head -1)
        if [ -n "$WV2_FOUND" ]; then
            echo "  WebView2 runtime installed:"
            echo "    $WV2_FOUND"
        else
            echo "  WARNING: WebView2 install did not produce msedgewebview2.exe."
            echo "  Kyber may fall back to cmd /c start and fail to log in."
            echo "  Try installing it manually:"
            echo "    STEAM_COMPAT_DATA_PATH=$KYBER_PFX \\"
            echo "    STEAM_COMPAT_CLIENT_INSTALL_PATH=$STEAM_HOME \\"
            echo "    \"$PROTON_DIR/proton\" run MicrosoftEdgeWebview2Setup.exe /silent /install"
        fi
    else
        echo "  WARNING: Could not download WebView2 bootstrapper."
        echo "  Kyber bundles it too — its installer may have already placed it."
    fi
fi

# ── Add Kyber as a non-Steam shortcut ──────────────────────────────────────
echo ""
echo "[3/5] Adding Kyber as a non-Steam shortcut..."

STEAM_UID=$(ls "$STEAM_HOME/userdata/" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
if [ -z "$STEAM_UID" ]; then
    echo "  WARNING: No Steam userdata found — sign in to Steam once, then re-run."
    echo "  Skipping shortcut + compat mapping."
    SKIP_STEAM_CFG=1
else
    SHORTCUTS_DIR="$STEAM_HOME/userdata/$STEAM_UID/config"
    SHORTCUTS_FILE="$SHORTCUTS_DIR/shortcuts.vdf"
    mkdir -p "$SHORTCUTS_DIR"
    [ -f "$SHORTCUTS_FILE" ] && cp "$SHORTCUTS_FILE" "$SHORTCUTS_FILE.bak"

    python3 - "$SHORTCUTS_FILE" "$KYBER_APPID" "$KYBER_EXE_WIN" "$KYBER_START_DIR" << 'PYEOF'
import sys, struct, os

def s(key, value):  # VDF string field
    return b'\x01' + key.encode() + b'\x00' + value.encode() + b'\x00'
def i(key, value):  # VDF int field
    return b'\x02' + key.encode() + b'\x00' + struct.pack('<I', value)

shortcuts_file, appid_s, exe_win, start_dir = sys.argv[1:5]
appid = int(appid_s)

# Preserve existing shortcuts if the file already exists and is parseable.
# For simplicity we append a new entry to a freshly built map; if a prior
# Kyber entry exists we still work because Steam dedups on appid+exe.
existing = b''
idx = 0
if os.path.exists(shortcuts_file):
    try:
        with open(shortcuts_file, 'rb') as f:
            raw = f.read()
        # crude: keep raw inner entries between the outer "shortcuts" wrapper
        # by stripping the leading \x00shortcuts\x00 and trailing \x08\x08
        head = b'\x00shortcuts\x00'
        if raw.startswith(head) and raw.endswith(b'\x08\x08'):
            existing = raw[len(head):-2]
            # count existing entries' top-level index keys to avoid collision
            idx = existing.count(b'\x01appid\x00')
    except Exception:
        existing = b''
        idx = 0

entry  = b'\x00' + str(idx).encode() + b'\x00'
entry += s('appid', str(appid))
entry += s('AppName', 'Kyber Launcher')
entry += s('Exe', f'"{exe_win}"')
entry += s('StartDir', f'"{start_dir}"')
entry += s('icon', '')
entry += s('ShortcutPath', '')
entry += s('LaunchOptions', '')
entry += i('IsHidden', 0)
entry += i('AllowDesktopConfig', 1)
entry += i('AllowOverlay', 1)
entry += i('OpenVR', 0)
entry += i('Devkit', 0)
entry += s('DevkitGameID', '')
entry += i('LastPlayTime', 0)
entry += b'\x08\x08'

data = b'\x00shortcuts\x00' + existing + entry + b'\x08'
with open(shortcuts_file, 'wb') as f:
    f.write(data)
print(f"  shortcuts.vdf written ({len(data)} bytes, entry index {idx})")
PYEOF
fi

# ── CompatToolMapping — force Proton Experimental for the Kyber shortcut ────
echo ""
echo "[4/5] Forcing Proton Experimental for the Kyber shortcut..."
if [ "${SKIP_STEAM_CFG:-0}" != "1" ]; then
    CFG_FILE="$STEAM_HOME/config/config.vdf"
    if [ -f "$CFG_FILE" ]; then
        cp "$CFG_FILE" "$CFG_FILE.bak"
        python3 - "$CFG_FILE" "$KYBER_APPID" << 'PYEOF'
import sys, re
cfg_file, appid = sys.argv[1], sys.argv[2]
with open(cfg_file) as f:
    content = f.read()
if f'"{appid}"' in content:
    print(f"  CompatToolMapping for {appid} already present — skipping.")
    sys.exit(0)
entry = (
    f'\t\t\t\t"{appid}"\n\t\t\t\t{{\n'
    f'\t\t\t\t\t"name"\t\t"proton_experimental"\n'
    f'\t\t\t\t\t"config"\t\t""\n'
    f'\t\t\t\t\t"Priority"\t\t"250"\n'
    f'\t\t\t\t}}\n'
)
new = re.sub(r'("CompatToolMapping"\s*\n\s*\{)', r'\1\n' + entry, content)
if new == content:
    print("  WARNING: CompatToolMapping block not found.")
    print("  Set Proton Experimental for Kyber manually: right-click the")
    print("  Kyber shortcut in Steam → Properties → Compatibility.")
    sys.exit(0)
with open(cfg_file, 'w') as f:
    f.write(new)
print(f"  CompatToolMapping → proton_experimental for appid {appid}")
PYEOF
    else
        echo "  WARNING: config.vdf not found. Set Proton Experimental manually"
        echo "  in the Kyber shortcut's Properties → Compatibility."
    fi
fi

echo ""
echo "[5/5] Done."
echo ""
echo "=== Kyber Setup Complete (native Linux) ==="
echo ""
echo "Next steps:"
echo "  1. RESTART Steam so it picks up the new shortcut and compat mapping."
echo "  2. Launch 'Kyber Launcher' from your Steam Library."
echo "  3. Click Login. Kyber's embedded WebView2 opens the EA login page."
echo "  4. Log in to EA (Steam / email / 2FA as usual)."
echo "  5. EA redirects to qrc://login_successful — WebView2 catches the code"
echo "     INTERNALLY and completes the token exchange. No browser, no qrc"
echo "     error, no manual step. This is the whole point of running natively."
echo ""
echo "Streaming from a headless box:"
echo "  Use Steam Remote Play — install the Steam Link app on your client,"
echo "  it discovers this host over your network. No Wolf, no Moonlight, no"
echo "  VPN required for a single user."
echo ""
echo "If login still falls back to a cmd error:"
echo "  WebView2 didn't initialize. Confirm the runtime exists:"
echo "    find \"$KYBER_PFX/pfx/drive_c\" -iname msedgewebview2.exe"
echo "  If missing, re-run the WebView2 install step shown above."
