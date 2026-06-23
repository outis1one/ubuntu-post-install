#!/bin/bash
# setup-kyber-linux.sh — Install the Kyber Launcher for SWBF2 (2017) on a
# native Linux Steam machine (headless or desktop) with Proton Experimental.
#
# Kyber is a community multiplayer client for Star Wars Battlefront II (2017)
# after EA shut down the official servers. It is a Windows app (Flutter/Rust).
#
# ── How Kyber's EA login actually works ────────────────────────────────────
#
# Kyber uses the "Maxima" OAuth PKCE flow:
#   1. Kyber starts a temporary HTTP server on 127.0.0.1 (dynamic port ~41413+)
#   2. It calls  cmd /c start ""  "<EA auth URL>"  to open a browser
#   3. You log in on the EA page; EA redirects to  127.0.0.1:PORT/?code=...
#   4. Kyber's HTTP server catches the code and exchanges it for tokens
#
# On native Linux, Wine's built-in cmd.exe passes http(s):// URLs to
# xdg-open, which launches your system browser. Steam's pressure-vessel
# (bwrap) sandbox does NOT block xdg-open on native Linux — xdg-open reaches
# the host desktop and the browser opens normally.
#
# After you approve the EA login page the browser is redirected to
# 127.0.0.1:PORT (Kyber's loopback server). The browser hits that address,
# Kyber receives the auth code, and login completes. No special shims needed.
#
# ── Why NOT to run Kyber inside Wolf / Games-on-Whales ─────────────────────
#
# Wolf runs Docker + Proton's bwrap nested. The double-sandbox blocks
# CLONE_NEWUSER which breaks WebView2, AND the inner bwrap prevents
# xdg-open from reaching the host display. Kyber's loopback redirect to
# 127.0.0.1:PORT also fails inside the container network stack. Use native
# Linux Steam instead — it's the supported path.
#
# ── WebView2 ───────────────────────────────────────────────────────────────
#
# WebView2 is NOT required for the login flow (Maxima handles that). This
# script still installs the WebView2 Evergreen runtime because Kyber may use
# it for in-app content rendering. Installing it causes no harm and prevents
# any fallback-related error dialogs inside Kyber.
#
# ── Headless note ──────────────────────────────────────────────────────────
#
# On a headless GPU box use Steam Remote Play: install Steam, configure a
# virtual/dummy display so Steam has something to render to, add Kyber +
# SWBF2, then connect with the Steam Link app from any device.
# This script warns if no display is detected at setup time.
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
KYBER_APPID="9900000001"         # non-Steam shortcut appid
KYBER_COMPAT_ID="$KYBER_APPID"  # prefix dir must match appid for Steam to find it

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

# ── Verify / download Kyber installer ─────────────────────────────────────
if [ ! -f "$KYBER_INSTALLER" ]; then
    echo ""
    echo "Kyber installer not found at: $KYBER_INSTALLER"
    echo "Downloading from kyber.gg API..."
    mkdir -p "$(dirname "$KYBER_INSTALLER")"
    KYBER_ZIP="/tmp/kyber-installer-$$.zip"
    KYBER_DL_URL="https://api.prod.kyber.gg/download/kyber-installer-win64.zip"
    if curl -L --progress-bar -o "$KYBER_ZIP" "$KYBER_DL_URL" && [ -s "$KYBER_ZIP" ]; then
        # Extract the installer .exe from the zip
        _exe=$(unzip -Z1 "$KYBER_ZIP" 2>/dev/null | grep -i '\.exe$' | head -1)
        if [ -z "$_exe" ]; then
            echo "ERROR: No .exe found inside the downloaded zip."
            rm -f "$KYBER_ZIP"
            exit 1
        fi
        unzip -p "$KYBER_ZIP" "$_exe" > "$KYBER_INSTALLER"
        rm -f "$KYBER_ZIP"
        echo "Extracted: $(basename "$_exe") → $KYBER_INSTALLER"
    else
        echo ""
        echo "ERROR: Download failed."
        echo "Download the zip manually from https://kyber.gg, extract the .exe, then:"
        echo "  $0 /path/to/KyberLauncher.exe"
        rm -f "$KYBER_ZIP"
        exit 1
    fi
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
echo "[1/7] Installing Kyber into Wine prefix..."

KYBER_PFX="$STEAM_HOME/steamapps/compatdata/$KYBER_COMPAT_ID"
OLD_PFX="$STEAM_HOME/steamapps/compatdata/kyber"

# Migrate old 'kyber' prefix to the numeric appid directory Steam expects
if [ -d "$OLD_PFX" ] && [ ! -d "$KYBER_PFX" ]; then
    echo "  Migrating prefix: compatdata/kyber → compatdata/$KYBER_COMPAT_ID"
    mv "$OLD_PFX" "$KYBER_PFX"
elif [ -d "$OLD_PFX" ] && [ -d "$KYBER_PFX" ]; then
    echo "  Removing old compatdata/kyber (numeric prefix already exists)..."
    rm -rf "$OLD_PFX"
fi

export STEAM_COMPAT_DATA_PATH="$KYBER_PFX"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_HOME"
export PROTON_NO_ESYNC=1

# Check if Kyber is already installed — skip the installer if so.
KYBER_EXE_PATH=$(find "$KYBER_PFX/pfx" -name "Kyber.exe" 2>/dev/null | head -1)
if [ -n "$KYBER_EXE_PATH" ]; then
    echo "  Kyber.exe already present — skipping installer."
else
    mkdir -p "$KYBER_PFX"
    # Kill any leftover Wine/Proton processes from a previous attempt.
    pkill -9 -f "compatdata/$KYBER_COMPAT_ID" 2>/dev/null || true
    sleep 1

    echo "  Running installer (silent)..."
    # /S = NSIS silent flag; if Kyber's installer ignores it a GUI appears.
    "$PROTON_DIR/proton" run "$KYBER_INSTALLER" /S 2>/dev/null || \
        "$PROTON_DIR/proton" run "$KYBER_INSTALLER" 2>/dev/null || true

    sleep 5

    KYBER_EXE_PATH=$(find "$KYBER_PFX/pfx" -name "Kyber.exe" 2>/dev/null | head -1)
    if [ -z "$KYBER_EXE_PATH" ]; then
        echo ""
        echo "WARNING: Kyber.exe not found after installation."
        echo "  Default install path assumed; continuing."
    fi
fi

# Resolve Windows-style paths for the shortcut
if [ -n "$KYBER_EXE_PATH" ]; then
    rel=$(echo "$KYBER_EXE_PATH" | sed "s|.*/pfx/drive_c/||")
    KYBER_EXE_WIN="C:\\$(echo "$rel" | sed 's|/|\\|g')"
    dir_rel=$(dirname "$rel")
    KYBER_START_DIR="C:\\$(echo "$dir_rel" | sed 's|/|\\|g')\\"
else
    KYBER_EXE_WIN='C:\Program Files (x86)\KYBER Launcher\Kyber.exe'
    KYBER_START_DIR='C:\Program Files (x86)\KYBER Launcher\'
fi
echo "  Windows path: $KYBER_EXE_WIN"

# ── Ensure WebView2 Evergreen runtime is installed ─────────────────────────
echo ""
echo "[2/7] Verifying WebView2 runtime in the Kyber prefix..."

# The Evergreen runtime lives here once installed.
WV2_FOUND=$(find "$KYBER_PFX/pfx/drive_c" -iname "msedgewebview2.exe" 2>/dev/null | head -1)
if [ -n "$WV2_FOUND" ]; then
    echo "  WebView2 runtime present:"
    echo "    $WV2_FOUND"
else
    echo "  WebView2 runtime NOT found — installing..."

    # Prefer winetricks if available — it handles the prefix env automatically
    # and uses a cached offline installer so no Wine-internal network call needed.
    if command -v winetricks >/dev/null 2>&1; then
        echo "  Using winetricks to install webview2..."
        WINEPREFIX="$KYBER_PFX/pfx" \
        WINE="$PROTON_DIR/files/bin/wine64" \
            winetricks -q webview2 || true
    else
        # Download the Evergreen STANDALONE (offline) installer — linkid=2135547.
        # The bootstrapper (linkid=2124703) requires a second download from inside
        # Wine which reliably fails. The standalone is ~150 MB but self-contained.
        echo "  Downloading WebView2 standalone installer (~150 MB)..."
        WV2_STANDALONE="/tmp/WebView2RuntimeInstaller_$$.exe"
        WV2_URL="https://go.microsoft.com/fwlink/p/?LinkId=2135547"
        if curl -L --progress-bar -o "$WV2_STANDALONE" "$WV2_URL" && [ -s "$WV2_STANDALONE" ]; then
            "$PROTON_DIR/proton" run "$WV2_STANDALONE" /silent /install || true
            rm -f "$WV2_STANDALONE"
        else
            echo "  WARNING: Could not download WebView2 standalone installer."
            rm -f "$WV2_STANDALONE"
        fi
    fi

    sleep 5
    WV2_FOUND=$(find "$KYBER_PFX/pfx/drive_c" -iname "msedgewebview2.exe" 2>/dev/null | head -1)
    if [ -n "$WV2_FOUND" ]; then
        echo "  WebView2 runtime installed:"
        echo "    $WV2_FOUND"
    else
        echo ""
        echo "  WARNING: WebView2 runtime still not found after install attempt."
        echo "  Install winetricks and re-run, or install manually:"
        echo "    sudo apt install winetricks"
        echo "    $0"
    fi
fi

# ── Install cmd shim + OAuth watcher ──────────────────────────────────────
# Wine's built-in cmd.exe crashes (exit 0xC0000005) when Kyber calls:
#   cmd /c start "" "<EA auth URL>"
# We replace cmd.exe in the Kyber prefix with a tiny shim that writes the
# URL to a known file, then a Linux-side watcher opens it with xdg-open.
echo ""
echo "[3/7] Installing cmd shim for OAuth login..."

# The shim lives in the prefix's system32, not in Proton's global wine dir,
# so it only affects Kyber and won't break other games.
KYBER_SYS32="$KYBER_PFX/pfx/drive_c/windows/system32"
CMD_REAL="$KYBER_SYS32/cmd-real.exe"
CMD_SHIM="$KYBER_SYS32/cmd.exe"

if [ -f "$CMD_REAL" ]; then
    echo "  cmd shim already installed."
else
    # Need mingw-w64 to compile the shim
    if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        echo "  Installing mingw-w64..."
        sudo apt-get install -y mingw-w64 || {
            echo "  WARNING: mingw-w64 install failed. Install manually:"
            echo "    sudo apt install mingw-w64"
            echo "  Then re-run this script."
        }
    fi

    if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        SHIM_C="/tmp/kyber_cmd_shim_$$.c"
        SHIM_EXE="/tmp/kyber_cmd_shim_$$.exe"
        cat > "$SHIM_C" << 'CEOF'
#include <windows.h>
/* ieq: case-insensitive wide string compare using only kernel32 */
static int ieq(LPCWSTR a, LPCWSTR b) {
    return CompareStringOrdinal(a, -1, b, -1, TRUE) == 2; /* CSTR_EQUAL==2 */
}
static void write_url(LPCWSTR url) {
    HANDLE h = CreateFileW(L"C:\\kyber_oauth_url.txt",
        GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    int n = WideCharToMultiByte(CP_UTF8, 0, url, -1, NULL, 0, NULL, NULL);
    char *buf = (char*)HeapAlloc(GetProcessHeap(), 0, n + 1);
    WideCharToMultiByte(CP_UTF8, 0, url, -1, buf, n, NULL, NULL);
    DWORD w; WriteFile(h, buf, n - 1, &w, NULL);
    HeapFree(GetProcessHeap(), 0, buf);
    CloseHandle(h);
}
int WINAPI mainCRTStartup(void) {
    int argc;
    LPWSTR *argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    for (int i = 1; i < argc - 1; i++) {
        if (ieq(argv[i], L"/c") && ieq(argv[i+1], L"start")) {
            for (int j = i+2; j < argc; j++) {
                if (argv[j][0] == L'h' || argv[j][0] == L'H') {
                    write_url(argv[j]);
                    LocalFree(argv);
                    ExitProcess(0);
                }
            }
        }
    }
    /* pass-through to original cmd */
    LPWSTR rest = GetCommandLineW();
    while (*rest && *rest != L' ') rest++;
    LPCWSTR prefix = L"cmd-real.exe";
    int plen = lstrlenW(prefix), rlen = lstrlenW(rest);
    LPWSTR newcl = (LPWSTR)HeapAlloc(GetProcessHeap(), 0,
                       (plen + rlen + 2) * sizeof(WCHAR));
    lstrcpyW(newcl, prefix);
    lstrcatW(newcl, rest);
    STARTUPINFOW si = {sizeof(si)};
    PROCESS_INFORMATION pi;
    CreateProcessW(NULL, newcl, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi);
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD code = 1; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    LocalFree(argv);
    ExitProcess(code);
}
CEOF
        if x86_64-w64-mingw32-gcc -O2 -ffreestanding -nostdlib \
                -mno-stack-arg-probe \
                -e mainCRTStartup -o "$SHIM_EXE" "$SHIM_C" \
                -lkernel32 -lshell32; then
            # If cmd.exe is a symlink, copy the real file out first,
            # then remove the symlink so we replace only this prefix.
            if [ -L "$CMD_SHIM" ]; then
                cp "$(readlink -f "$CMD_SHIM")" "$CMD_REAL"
                rm "$CMD_SHIM"
            else
                cp "$CMD_SHIM" "$CMD_REAL"
            fi
            cp "$SHIM_EXE" "$CMD_SHIM"
            echo "  cmd shim installed ($(stat -c%s "$CMD_SHIM") bytes)."
        else
            echo "  WARNING: cmd shim compile failed — login may not work."
        fi
        rm -f "$SHIM_C" "$SHIM_EXE"
    else
        echo "  WARNING: mingw-w64 not found. Install it and re-run:"
        echo "    sudo apt install mingw-w64"
    fi
fi

# ── OAuth watcher ──────────────────────────────────────────────────────────
echo ""
echo "[4/7] Installing OAuth watcher (opens EA login in your browser)..."

URL_FILE="$KYBER_PFX/pfx/drive_c/kyber_oauth_url.txt"
WATCHER="$HOME/.local/bin/kyber-oauth-watcher.sh"
mkdir -p "$HOME/.local/bin"

cat > "$WATCHER" << WEOF
#!/bin/bash
# Watches for Kyber's OAuth URL and opens it in the system browser.
URL_FILE="$URL_FILE"
echo "[kyber-watcher] Started. Watching \$URL_FILE"
rm -f "\$URL_FILE"
while true; do
    if [ -f "\$URL_FILE" ]; then
        URL=\$(cat "\$URL_FILE")
        rm -f "\$URL_FILE"
        if [[ "\$URL" == http* ]]; then
            echo "[kyber-watcher] Opening: \$URL"
            xdg-open "\$URL"
        fi
    fi
    sleep 0.5
done
WEOF
chmod +x "$WATCHER"

# Install as a systemd user service so it is always ready when Kyber runs
SVCDIR="$HOME/.config/systemd/user"
mkdir -p "$SVCDIR"
cat > "$SVCDIR/kyber-oauth-watcher.service" << SEOF
[Unit]
Description=Kyber EA OAuth URL watcher
After=graphical-session.target

[Service]
ExecStart=$WATCHER
Restart=always
RestartSec=2

[Install]
WantedBy=default.target
SEOF

if systemctl --user daemon-reload 2>/dev/null && \
   systemctl --user enable --now kyber-oauth-watcher.service 2>/dev/null; then
    echo "  Watcher service enabled and started."
    echo "  (It will auto-start on login from now on.)"
else
    echo "  NOTE: systemd user service could not be enabled."
    echo "  Start the watcher manually before clicking Login in Kyber:"
    echo "    $WATCHER &"
fi

# ── Add Kyber as a non-Steam shortcut ──────────────────────────────────────
echo ""
echo "[5/7] Adding Kyber as a non-Steam shortcut..."

STEAM_UID=$(ls "$STEAM_HOME/userdata/" 2>/dev/null | grep -E '^[0-9]+$' | head -1)
if [ -z "$STEAM_UID" ]; then
    echo "  WARNING: No Steam userdata found — sign in to Steam once, then re-run."
    echo "  Skipping shortcut + compat mapping."
    SKIP_STEAM_CFG=1
else
    SHORTCUTS_DIR="$STEAM_HOME/userdata/$STEAM_UID/config"
    SHORTCUTS_FILE="$SHORTCUTS_DIR/shortcuts.vdf"
    mkdir -p "$SHORTCUTS_DIR"
    if [ -f "$SHORTCUTS_FILE" ] && [ ! -w "$SHORTCUTS_FILE" ]; then
        echo "  Fixing permissions on shortcuts.vdf..."
        chmod 644 "$SHORTCUTS_FILE" || {
            echo "  WARNING: Cannot write $SHORTCUTS_FILE — run:"
            echo "    chmod 644 $SHORTCUTS_FILE"
            echo "  then re-run this script."
            SKIP_STEAM_CFG=1
        }
    fi
    [ -f "$SHORTCUTS_FILE" ] && cp "$SHORTCUTS_FILE" "$SHORTCUTS_FILE.bak"

    python3 - "$SHORTCUTS_FILE" "$KYBER_APPID" "$KYBER_EXE_WIN" "$KYBER_START_DIR" << 'PYEOF'
import sys, struct, os

def s(key, value):  # VDF string field
    return b'\x01' + key.encode() + b'\x00' + value.encode() + b'\x00'
def i(key, value):  # VDF int field
    return b'\x02' + key.encode() + b'\x00' + struct.pack('<I', value)

shortcuts_file, appid_s, exe_win, start_dir = sys.argv[1:5]
appid = int(appid_s)

existing = b''
idx = 0
if os.path.exists(shortcuts_file):
    try:
        with open(shortcuts_file, 'rb') as f:
            raw = f.read()
        head = b'\x00shortcuts\x00'
        if raw.startswith(head) and raw.endswith(b'\x08\x08'):
            existing = raw[len(head):-2]
            # Skip if Kyber Launcher entry already present
            if b'Kyber Launcher' in existing:
                print("  Kyber Launcher already in shortcuts.vdf — skipping.")
                sys.exit(0)
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
echo "[6/7] Forcing Proton Experimental for the Kyber shortcut..."
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
echo "[7/7] Done."
echo ""
echo "=== Kyber Setup Complete (native Linux) ==="
echo ""
echo "Next steps:"
echo "  1. RESTART Steam so it picks up the new shortcut and compat mapping."
echo "  2. The OAuth watcher is already running in the background."
echo "     (Confirm: systemctl --user status kyber-oauth-watcher)"
echo "  3. Launch 'Kyber Launcher' from your Steam Library."
echo "  4. Click Login. Kyber calls cmd /c start with the EA auth URL."
echo "     The cmd shim intercepts it and writes it to a file. The watcher"
echo "     picks it up and opens it in your browser via xdg-open."
echo "  5. Log in on the EA page (email / Steam / 2FA as usual)."
echo "  6. EA redirects to 127.0.0.1:<port>/?code=... — Kyber's loopback"
echo "     server catches the auth code and login completes."
echo "     The browser tab will show 'OK' or connection-refused — both normal."
echo ""
echo "Streaming from a headless box:"
echo "  Use Steam Remote Play — install the Steam Link app on your client,"
echo "  it discovers this host over your network."
echo ""
echo "Troubleshooting:"
echo "  Browser never opens after clicking Login:"
echo "    Check watcher is running: systemctl --user status kyber-oauth-watcher"
echo "    If not: $HOME/.local/bin/kyber-oauth-watcher.sh &"
echo ""
echo "  Browser opens but login loops back to EA sign-in page:"
echo "    Kyber's loopback server timed out. Close Kyber, reopen it,"
echo "    then click Login and log in quickly."
echo ""
echo "  'cmd shim' missing (mingw-w64 was not installed):"
echo "    sudo apt install mingw-w64 && $0"
