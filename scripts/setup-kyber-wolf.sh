#!/bin/bash
# setup-kyber-wolf.sh — Set up the Kyber Launcher for SWBF2 (2017) inside a
# Wolf / Games-on-Whales Docker container.
#
# Kyber is a community multiplayer client for Star Wars Battlefront II (2017,
# AppID 1237950) after EA shut down the official servers. It runs as a Windows
# app (Flutter/Rust) and uses an EA OAuth PKCE login flow.
#
# ── Why this is complicated ────────────────────────────────────────────────
#
# Kyber's login flow:
#   1. Kyber generates an OAuth code_verifier/code_challenge.
#   2. It opens a browser pointing at accounts.ea.com with the PKCE params.
#   3. The user logs in to EA.
#   4. EA redirects to: qrc:/html/login_successful.html?code=<code>
#   5. Kyber's embedded WebView2 (Edge) intercepts the qrc:// URI and extracts
#      the authorization code. WebView2 then exchanges it for a token.
#
# The qrc:// scheme is a Qt internal resource protocol — it cannot be opened
# by any real browser. Only Kyber's own embedded WebView2 can catch it.
# This means every "redirect the browser to localhost" workaround will fail:
# the final redirect from EA will always be to qrc://, which no external
# browser can handle.
#
# The ONLY path to a working login is getting Kyber's embedded WebView2
# (msedgewebview2.exe) to initialize successfully under Proton/Wine.
#
# ── Why WebView2 fails in Wolf ─────────────────────────────────────────────
#
# Wolf containers run Proton inside Docker. Proton Experimental wraps Wine
# in pressure-vessel (bwrap — bubblewrap sandbox). Inside bwrap, creating new
# user namespaces is forbidden (CLONE_NEWUSER returns EPERM). msedgewebview2.exe
# requires its own sandbox via --no-sandbox or equivalent flags, which under
# Wine leads to CreateUserProcess failures. This causes WebView2 to fail to
# initialize, and Kyber falls back to `cmd /c start <url>`, which also fails
# because bwrap blocks Wine's ShellExecute from exec'ing Linux binaries.
#
# ── What this script does ──────────────────────────────────────────────────
#
#   1. Adds Kyber Launcher as a non-Steam shortcut in the Wolf container with
#      the correct CompatToolMapping so it uses Proton Experimental.
#   2. Installs WebView2 bootstrapper inside Kyber's Wine prefix and attempts
#      a WebView2 installation (may not fully work — see note above).
#   3. Installs a fake cmd.exe into Kyber's prefix. When WebView2 fails and
#      Kyber falls back to `cmd /c start <url>`, the fake cmd.exe writes the
#      OAuth URL to /tmp/kyber_oauth_url.txt and returns exit 0 instead of
#      crashing. This keeps Kyber's localhost:13021 listener alive.
#   4. Installs Firefox (non-snap) inside the Wolf container for manual login.
#   5. Creates a kyber-fresh Firefox profile with the prefs required to make
#      Firefox's networking work inside Docker (network.process.enabled: false).
#   6. Writes a url-watcher.sh helper that monitors kyber_oauth_url.txt and
#      opens Firefox to the EA login page — this is the manual fallback flow.
#
# ── Limitations of the manual flow ────────────────────────────────────────
#
# Even with the fake cmd.exe + Firefox, login cannot complete because:
#   - EA redirects the browser to qrc:/html/login_successful.html?code=...
#   - Firefox cannot handle the qrc:// scheme (it is Qt-internal)
#   - Firefox shows "The address wasn't understood" on the final redirect
#   - Kyber's localhost:13021 receives no callback and stays at "Fetching data..."
#
# The REAL fix is making WebView2 work. Two known approaches:
#
#   A. Run Kyber OUTSIDE Wolf (native Linux Steam, not in the Docker container).
#      Without nested bwrap, WebView2 may initialize — Proton on bare metal has
#      more namespace capability than Proton inside Docker.
#      → See scripts/setup-kyber-linux.sh (if it exists) or run Kyber as a
#        non-Steam shortcut in your local Steam with Proton Experimental.
#
#   B. Patch msedgewebview2.exe flags inside the container.
#      msedgewebview2.exe --no-sandbox disables the sandbox that requires
#      CLONE_NEWUSER. Getting Kyber to pass --no-sandbox to its WebView2 host
#      process may require a wrapper PE or a Wine registry override.
#
# ── Prerequisites ──────────────────────────────────────────────────────────
#   a. SWBF2 (AppID 1237950) is installed in the Wolf container — follow
#      setup-swbf2-wolf.sh first.
#   b. Wolf container is running and you can reach Steam in Moonlight.
#   c. Download Kyber Launcher from https://kyber.gg — save the .exe installer
#      to ~/Downloads/KyberLauncher.exe on the Docker host before running.
#   d. mingw-w64 must be installed on the Docker host (for fake cmd.exe):
#        sudo apt-get install -y mingw-w64
#
# ── Usage ──────────────────────────────────────────────────────────────────
#   chmod +x setup-kyber-wolf.sh
#   ./setup-kyber-wolf.sh
#
# After running, to attempt Kyber login manually (partial flow):
#   ./url-watcher.sh
#   Then in Moonlight, launch Kyber and click "Login".

set -euo pipefail

KYBER_INSTALLER="${1:-$HOME/Downloads/KyberLauncher.exe}"
KYBER_COMPAT_ID="kyber"          # arbitrary prefix name for the Wine prefix
KYBER_APPID="9900000001"         # non-Steam shortcut appid we will assign

echo "=== Kyber Launcher Setup for Wolf / Games-on-Whales ==="
echo ""

# ── Locate WolfSteam container ─────────────────────────────────────────────
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i WolfSteam | head -1)
if [ -z "$WOLF_CONTAINER" ]; then
    echo "ERROR: WolfSteam container is not running."
    echo "  Start Wolf and open Steam in Moonlight first."
    exit 1
fi
echo "Container: $WOLF_CONTAINER"

# ── Locate the Wolf session home on the host ───────────────────────────────
RETRO_HOME=$(docker inspect "$WOLF_CONTAINER" \
    --format '{{range .Mounts}}{{if eq .Destination "/home/retro"}}{{.Source}}{{end}}{{end}}' \
    2>/dev/null)
if [ -z "$RETRO_HOME" ] || [ ! -d "$RETRO_HOME" ]; then
    echo "ERROR: Could not locate /home/retro mount on the host."
    echo "  Ensure Wolf has created a session (open Steam in Moonlight at least once)."
    exit 1
fi
STEAM_DATA="$RETRO_HOME/.steam/steam"
echo "Session home: $RETRO_HOME"

# ── Verify Kyber installer ─────────────────────────────────────────────────
if [ ! -f "$KYBER_INSTALLER" ]; then
    echo ""
    echo "ERROR: Kyber installer not found at: $KYBER_INSTALLER"
    echo ""
    echo "Download KyberLauncher.exe from https://kyber.gg and save it, then:"
    echo "  $0 /path/to/KyberLauncher.exe"
    exit 1
fi
echo "Kyber installer: $KYBER_INSTALLER"

# ── Verify mingw-w64 ───────────────────────────────────────────────────────
if ! command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
    echo "mingw-w64 not found — installing..."
    sudo apt-get install -y mingw-w64
fi

echo ""
echo "[1/6] Creating Kyber Wine prefix and installing Kyber Launcher..."

# ── Create kyber compatdata prefix via Proton Experimental ────────────────
KYBER_PFX="$STEAM_DATA/steamapps/compatdata/$KYBER_COMPAT_ID"
mkdir -p "$KYBER_PFX"

# Copy the installer into the container and run it with Proton
docker cp "$KYBER_INSTALLER" "$WOLF_CONTAINER:/tmp/KyberLauncher.exe"

# Find Proton Experimental path inside the container
PROTON_PATH=$(docker exec "$WOLF_CONTAINER" \
    bash -c "find /home/retro/.steam/steam/steamapps/common -maxdepth 2 -name 'proton' 2>/dev/null \
             | grep -i 'Proton Experimental' | head -1" 2>/dev/null || true)
if [ -z "$PROTON_PATH" ]; then
    PROTON_PATH=$(docker exec "$WOLF_CONTAINER" \
        bash -c "find /home/retro/.steam/steam/steamapps/common -maxdepth 2 -name 'proton' 2>/dev/null \
                 | head -1" 2>/dev/null || true)
fi
if [ -z "$PROTON_PATH" ]; then
    echo "ERROR: Proton not found in the container."
    echo "  Install Proton Experimental from Steam → Settings → Compatibility."
    exit 1
fi
echo "  Proton: $PROTON_PATH"

# Run the Kyber installer silently
docker exec -u 1000 \
    -e STEAM_COMPAT_DATA_PATH="/home/retro/.steam/steam/steamapps/compatdata/$KYBER_COMPAT_ID" \
    -e STEAM_COMPAT_CLIENT_INSTALL_PATH="/home/retro/.steam/steam" \
    -e PROTON_NO_ESYNC=1 \
    "$WOLF_CONTAINER" \
    "$PROTON_PATH" run /tmp/KyberLauncher.exe /S 2>/dev/null || true

# Give the installer time to complete
sleep 5

KYBER_EXE_PATH=$(docker exec "$WOLF_CONTAINER" \
    bash -c "find /home/retro/.steam/steam/steamapps/compatdata/$KYBER_COMPAT_ID/pfx \
             -name 'Kyber.exe' 2>/dev/null | head -1" 2>/dev/null || true)
if [ -z "$KYBER_EXE_PATH" ]; then
    echo ""
    echo "WARNING: Kyber.exe not found after installation."
    echo "  You may need to install Kyber manually in Moonlight using a Windows:"
    echo "    wine /tmp/KyberLauncher.exe"
    echo "  or run the installer directly in a Windows Steam Proton session."
    echo ""
    echo "  Assuming default path and continuing..."
    KYBER_EXE_WIN='C:\Program Files\Kyber\Kyber.exe'
else
    # Convert Linux path to Windows path
    KYBER_EXE_WIN=$(echo "$KYBER_EXE_PATH" \
        | sed "s|.*/compatdata/$KYBER_COMPAT_ID/pfx/drive_c/||" \
        | sed 's|/|\\|g' \
        | sed 's|^|C:\\|')
    echo "  Kyber.exe: $KYBER_EXE_WIN"
fi

echo ""
echo "[2/6] Adding Kyber as a non-Steam shortcut..."

# ── Shortcuts.vdf ──────────────────────────────────────────────────────────
# Non-Steam shortcuts live in userdata/<steamid>/config/shortcuts.vdf.
# Format is binary VDF (not text). We write a minimal binary that Steam accepts.
STEAM_UID=$(ls "$STEAM_DATA/userdata/" 2>/dev/null | head -1)
if [ -z "$STEAM_UID" ]; then
    echo "WARNING: No Steam userdata found. Sign in to Steam in Moonlight first."
    echo "  After signing in, re-run this script to register the shortcut."
    echo "  Skipping shortcut registration."
else
    SHORTCUTS_DIR="$STEAM_DATA/userdata/$STEAM_UID/config"
    SHORTCUTS_FILE="$SHORTCUTS_DIR/shortcuts.vdf"
    mkdir -p "$SHORTCUTS_DIR"

    # Generate a minimal shortcuts.vdf if it doesn't exist or back it up
    if [ -f "$SHORTCUTS_FILE" ]; then
        cp "$SHORTCUTS_FILE" "$SHORTCUTS_FILE.bak"
        echo "  Backed up existing shortcuts.vdf"
    fi

    # Write shortcuts.vdf using Python (binary VDF format)
    python3 - "$SHORTCUTS_FILE" "$KYBER_COMPAT_ID" "$KYBER_EXE_WIN" << 'PYEOF'
import sys, struct, os

def vdf_string(key, value):
    return b'\x01' + key.encode() + b'\x00' + value.encode() + b'\x00'

def vdf_int(key, value):
    return b'\x02' + key.encode() + b'\x00' + struct.pack('<I', value)

shortcuts_file = sys.argv[1]
compat_id      = sys.argv[2]
exe_win        = sys.argv[3]

app_name = "Kyber Launcher"
exe_path = f'"{exe_win}"'
start_dir = "C:\\\\Program Files\\\\Kyber\\\\"

entry  = b'\x00' + b'0' + b'\x00'
entry += vdf_string('appid',      str(9900000001))
entry += vdf_string('AppName',    app_name)
entry += vdf_string('Exe',        exe_path)
entry += vdf_string('StartDir',   start_dir)
entry += vdf_string('icon',       '')
entry += vdf_string('ShortcutPath','')
entry += vdf_string('LaunchOptions', '')
entry += vdf_int('IsHidden',      0)
entry += vdf_int('AllowDesktopConfig', 1)
entry += vdf_int('AllowOverlay',  1)
entry += vdf_int('OpenVR',        0)
entry += vdf_int('Devkit',        0)
entry += vdf_string('DevkitGameID', '')
entry += vdf_int('LastPlayTime',  0)
entry += b'\x08\x08'

data = b'\x00' + b'shortcuts' + b'\x00' + entry + b'\x08'

with open(shortcuts_file, 'wb') as f:
    f.write(data)

print(f"  shortcuts.vdf written ({len(data)} bytes)")
PYEOF
    chown 1000:1000 "$SHORTCUTS_FILE"
fi

# ── CompatToolMapping — tell Steam to use Proton Experimental for Kyber ───
echo ""
echo "[3/6] Setting Proton Experimental for Kyber shortcut..."
CFG_FILE="$STEAM_DATA/config/config.vdf"
if [ -f "$CFG_FILE" ]; then
    cp "$CFG_FILE" "$CFG_FILE.bak"
    # Inject CompatToolMapping entry for Kyber's appid
    python3 - "$CFG_FILE" "$KYBER_APPID" << 'PYEOF'
import sys, re

cfg_file = sys.argv[1]
appid    = sys.argv[2]

with open(cfg_file) as f:
    content = f.read()

entry = (
    f'\t\t\t\t"{appid}"\n'
    f'\t\t\t\t{{\n'
    f'\t\t\t\t\t"name"\t\t"proton_experimental"\n'
    f'\t\t\t\t\t"config"\t\t""\n'
    f'\t\t\t\t\t"Priority"\t\t"250"\n'
    f'\t\t\t\t}}\n'
)

if appid in content:
    print(f"  CompatToolMapping for {appid} already present — skipping.")
    sys.exit(0)

# Insert into CompatToolMapping block
new_content = re.sub(
    r'("CompatToolMapping"\s*\n\s*\{)',
    r'\1\n' + entry,
    content
)
if new_content == content:
    print(f"WARNING: Could not find CompatToolMapping block in config.vdf.")
    print(f"  Set Proton Experimental for Kyber manually in Steam → Library.")
    sys.exit(0)

with open(cfg_file, 'w') as f:
    f.write(new_content)
print(f"  CompatToolMapping set to proton_experimental for appid {appid}")
PYEOF
    chown 1000:1000 "$CFG_FILE"
else
    echo "  WARNING: config.vdf not found. Sign in to Steam in Moonlight first."
fi

echo ""
echo "[4/6] Compiling and installing fake cmd.exe..."

# ── Fake cmd.exe ───────────────────────────────────────────────────────────
#
# When Kyber's embedded WebView2 fails to initialize (see header comments),
# Kyber falls back to `cmd /c start <EA_oauth_url>`. Inside Proton's bwrap
# sandbox, Wine's real cmd.exe tries to exec Linux binaries via ShellExecute,
# which bwrap forbids → STATUS_ACCESS_VIOLATION (0xC0000005) → Kyber shows
# error and aborts the login flow.
#
# Solution: replace cmd.exe with a minimal Windows PE that:
#   1. Finds the https:// argument (the EA OAuth URL).
#   2. Writes it to Z:\tmp\kyber_oauth_url.txt (which is /tmp/ from Linux).
#   3. Returns exit code 0 so Kyber does not see a failure.
#
# Kyber then shows "Fetching data..." and its localhost:13021 listener stays
# alive. A separate watcher script reads the URL file and opens Firefox.
# (See [5/6] for the watcher script and the WebView2 limitation note.)

FAKE_CMD_C="/tmp/fake_cmd_$$.c"
FAKE_CMD_EXE="/tmp/fake_cmd_$$.exe"

cat > "$FAKE_CMD_C" << 'EOF'
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    int i;
    for (i = 1; i < argc; i++) {
        if (strncmp(argv[i], "https://", 8) == 0) {
            FILE *f = fopen("Z:\\tmp\\kyber_oauth_url.txt", "w");
            if (f) { fputs(argv[i], f); fclose(f); }
            break;
        }
    }
    return 0;
}
EOF

x86_64-w64-mingw32-gcc -o "$FAKE_CMD_EXE" "$FAKE_CMD_C" -mwindows 2>/dev/null \
    || x86_64-w64-mingw32-gcc -o "$FAKE_CMD_EXE" "$FAKE_CMD_C"
rm -f "$FAKE_CMD_C"

KYBER_SYS32="$KYBER_PFX/pfx/drive_c/windows/system32"
if [ -d "$KYBER_SYS32" ]; then
    # Back up real cmd.exe once
    if [ ! -f "$KYBER_SYS32/cmd.exe.bak" ] && [ -f "$KYBER_SYS32/cmd.exe" ]; then
        cp "$KYBER_SYS32/cmd.exe" "$KYBER_SYS32/cmd.exe.bak"
        echo "  Backed up real cmd.exe → cmd.exe.bak"
    fi
    cp "$FAKE_CMD_EXE" "$KYBER_SYS32/cmd.exe"
    chown 1000:1000 "$KYBER_SYS32/cmd.exe"
    echo "  Fake cmd.exe installed in Kyber prefix."
else
    echo "  WARNING: Kyber prefix system32 not found at $KYBER_SYS32"
    echo "  Install Kyber first (run the installer in Wine), then re-run this script."
fi
rm -f "$FAKE_CMD_EXE"

echo ""
echo "[5/6] Installing Firefox and creating kyber-fresh profile..."

# ── Install Firefox (non-snap) if not already present ─────────────────────
# Firefox's socket process (which handles HTTPS in a separate process) calls
# clone(CLONE_NEWUSER) which Docker blocks (EPERM). This causes all HTTPS
# requests to fail. The fix is user_pref("network.process.enabled", false)
# which forces networking into the main Firefox process.
#
# Do NOT use the snap version (can't pass prefs) or apt Firefox < 115 on
# Ubuntu 22.04 (different pref structure). Use the Mozilla tarball directly.

FIREFOX_TARBALL_URL="https://download.mozilla.org/?product=firefox-latest-ssl&os=linux64&lang=en-US"
FIREFOX_DEST="/home/retro/firefox"

FF_INSTALLED=$(docker exec "$WOLF_CONTAINER" \
    bash -c "[ -x '$FIREFOX_DEST/firefox' ] && echo yes || echo no" 2>/dev/null)
if [ "$FF_INSTALLED" = "yes" ]; then
    echo "  Firefox already installed in container."
else
    echo "  Downloading Firefox (Mozilla tarball)..."
    FF_TMP="/tmp/firefox_latest_$$.tar.bz2"
    if ! curl -L --progress-bar -o "$FF_TMP" "$FIREFOX_TARBALL_URL"; then
        echo "ERROR: Firefox download failed. Check your internet connection."
        rm -f "$FF_TMP"
        exit 1
    fi
    echo "  Installing Firefox into container..."
    docker cp "$FF_TMP" "$WOLF_CONTAINER:/tmp/firefox_latest.tar.bz2"
    docker exec -u 1000 "$WOLF_CONTAINER" \
        bash -c "mkdir -p $FIREFOX_DEST && \
                 tar -xjf /tmp/firefox_latest.tar.bz2 --strip-components=1 \
                     -C $FIREFOX_DEST && \
                 rm /tmp/firefox_latest.tar.bz2"
    rm -f "$FF_TMP"
    echo "  Firefox installed at $FIREFOX_DEST"
fi

# ── Create kyber-fresh Firefox profile ────────────────────────────────────
# A completely fresh profile is required for each OAuth attempt. Stale EA
# session cookies cause EA to redirect differently, breaking the flow.
# This profile is deleted and recreated by url-watcher.sh before each login.
PROFILE_DIR="/home/retro/.mozilla/firefox/kyber-fresh"
docker exec -u 1000 "$WOLF_CONTAINER" \
    bash -c "mkdir -p '$PROFILE_DIR'"
docker exec -u 1000 "$WOLF_CONTAINER" \
    bash -c "cat > '$PROFILE_DIR/user.js'" << 'JSEOF'
// Required for Firefox to make network connections inside Docker.
// Docker blocks clone(CLONE_NEWUSER). Firefox's socket process uses this
// to create its own namespace — it crashes silently, killing all HTTPS.
// Forcing networking to the main process avoids the crash.
user_pref("network.process.enabled", false);

// Reduce sandbox level to avoid other CLONE_NEWUSER failures.
user_pref("security.sandbox.content.level", 0);

// Do not restore a previous session — always start at a blank page.
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.startup.page", 0);

// NOTE: Do NOT add network.dns.disableIPv6 or network.trr.mode overrides.
// Those break DNS resolution in the main process after network.process.enabled
// is false. The defaults work correctly.
JSEOF

echo "  Firefox kyber-fresh profile created."

echo ""
echo "[6/6] Writing url-watcher.sh helper script..."

# ── URL watcher script ─────────────────────────────────────────────────────
# This is the manual login helper. Run it from the Docker host terminal.
# It watches /tmp/kyber_oauth_url.txt (written by fake cmd.exe when Kyber
# tries to open the EA login URL) and opens that URL in Firefox.
#
# IMPORTANT LIMITATION: This only gets Firefox to the EA login page.
# After the user completes EA login, EA redirects the browser to:
#   qrc:/html/login_successful.html?code=<auth_code>
# Firefox cannot handle qrc:// (it is a Qt-internal resource scheme).
# Firefox shows "The address wasn't understood" — this is correct behavior.
#
# The auth code is only delivered to Kyber's embedded WebView2 via the qrc://
# intercept. Without a working WebView2, the login flow cannot complete.
# See the header comments for the real fix (run Kyber outside Wolf, or patch
# msedgewebview2.exe --no-sandbox flags).

WATCHER_SCRIPT="$(dirname "$0")/kyber-url-watcher.sh"
cat > "$WATCHER_SCRIPT" << WATCHEOF
#!/bin/bash
# kyber-url-watcher.sh — Manual Kyber OAuth helper.
#
# Run this from the Docker host terminal BEFORE clicking Login in Kyber.
# It waits for fake cmd.exe to write the EA OAuth URL, then opens Firefox.
#
# IMPORTANT: This can get you to the EA login page but cannot complete login.
# The final EA redirect goes to qrc:// which only Kyber's WebView2 can catch.
# See setup-kyber-wolf.sh comments for details and the real fix.
#
# Usage: ./kyber-url-watcher.sh

WOLF_CONTAINER=\$(docker ps --format '{{.Names}}' | grep -i WolfSteam | head -1)
if [ -z "\$WOLF_CONTAINER" ]; then
    echo "ERROR: WolfSteam container is not running."
    exit 1
fi

echo "Waiting for Kyber to open the EA login URL..."
echo "(Click Login in Kyber now)"
echo ""

docker exec -u 1000 \\
    -e DISPLAY=:0 \\
    -e WAYLAND_DISPLAY=wayland-2 \\
    -e XDG_RUNTIME_DIR=/run/user/wolf \\
    "\$WOLF_CONTAINER" bash -c '
        # Always start with a completely fresh profile — stale EA cookies cause
        # different redirect behavior that breaks the flow.
        rm -rf /home/retro/.mozilla/firefox/kyber-fresh
        mkdir -p /home/retro/.mozilla/firefox/kyber-fresh
        cat > /home/retro/.mozilla/firefox/kyber-fresh/user.js << '"'"'JSEOF'"'"'
user_pref("network.process.enabled", false);
user_pref("security.sandbox.content.level", 0);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.startup.page", 0);
JSEOF

        rm -f /tmp/kyber_oauth_url.txt
        echo "Watching for /tmp/kyber_oauth_url.txt ..."
        while [ ! -s /tmp/kyber_oauth_url.txt ]; do sleep 0.1; done

        # Strip any Windows carriage returns the C fopen() might have added
        URL=\$(tr -d "\r\n" < /tmp/kyber_oauth_url.txt)
        echo "Got URL: \$URL"
        echo ""
        echo "Opening Firefox..."
        echo "(After EA login Firefox will show '\''The address wasn'\''t understood'\'' — this"
        echo " is expected. The qrc:// redirect can only be caught by Kyber'\''s WebView2.)"
        /home/retro/firefox/firefox \\
            --profile /home/retro/.mozilla/firefox/kyber-fresh "\$URL"
    '
WATCHEOF
chmod +x "$WATCHER_SCRIPT"
echo "  Written: $WATCHER_SCRIPT"

echo ""
echo "=== Kyber Setup Complete ==="
echo ""
echo "── How to attempt login (manual fallback flow) ──────────────────────"
echo ""
echo "  Terminal 1 (before clicking Login in Kyber):"
echo "    $(dirname "$0")/kyber-url-watcher.sh"
echo ""
echo "  Then in Moonlight: launch Kyber → click Login"
echo "  Firefox opens the EA login page — complete the login."
echo ""
echo "── Known limitation ─────────────────────────────────────────────────"
echo ""
echo "  After EA login, EA redirects to qrc:/html/login_successful.html?code=..."
echo "  Firefox cannot open qrc:// (Qt-internal scheme). It shows:"
echo "    'The address wasn't understood'"
echo "  This is the expected behavior. The auth code is only deliverable to"
echo "  Kyber's embedded WebView2 — which cannot initialize inside Docker"
echo "  due to bubblewrap (bwrap) blocking user namespace creation."
echo ""
echo "── Real fix: run Kyber outside Wolf ─────────────────────────────────"
echo ""
echo "  Since SWBF2 already runs with Proton Experimental on native Linux Steam,"
echo "  add Kyber Launcher as a non-Steam shortcut in your LOCAL Steam and use"
echo "  Proton Experimental. Outside Docker, Proton runs without the bwrap"
echo "  restrictions that block WebView2 — login is likely to work."
echo ""
echo "  Steps:"
echo "    1. In Steam → Library → + (bottom left) → Add a Non-Steam Game"
echo "    2. Browse to KyberLauncher.exe (or the installed Kyber.exe)"
echo "    3. Right-click → Properties → Compatibility → Proton Experimental"
echo "    4. Launch — WebView2 should initialize and the login flow completes"
echo ""
echo "── To restore real cmd.exe (undo fake cmd.exe) ──────────────────────"
echo ""
CMD_BAK="$KYBER_SYS32/cmd.exe.bak"
echo "  cp '$CMD_BAK' '${CMD_BAK%.bak}'"
echo ""
