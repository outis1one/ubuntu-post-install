## Star Wars Battlefront II (2017) + Kyber

Kyber is the community multiplayer replacement for SWBF2 after EA shut down
official servers in 2022. It went open-source (GPL) in January 2026.

**The correct approach is a native Linux AppImage** — not Wine or Proton for
the launcher itself. The AppImage is maintained at:
https://github.com/simonlinuxcraft/kyber-linuxport-unofficial

This service (`sudo ./setup.sh kyber-launcher`) downloads the latest
AppImage, installs a desktop entry, and creates a `kyber` command in
`~/.local/bin`. A standalone equivalent also exists at
`scripts/setup-kyber-linux.sh` for machines not running the full wizard.

**Every time you want to play:**
1. Open **Steam** (must be running for library validation) — do NOT click Play on SWBF2
2. Launch **Kyber** (`kyber` or from the app menu)
3. In Kyber: join a server (HOME) or create one (HOST)
4. Kyber/Maxima launches SWBF2 via its own bundled GE-Proton — wait 1-3 minutes
5. If the SWBF2 window appears but won't focus: press **Alt+Tab** or click its
   taskbar entry — this is normal when the game is launched by a wrapper process

Do NOT launch SWBF2 from Steam directly. If Steam's SWBF2 is already running
when Kyber starts, kill it first — Kyber cannot inject into a Steam-launched instance.

**If Kyber says "Game Not Found":**
Click **SET GAME FOLDER** and point it to the SWBF2 install directory.
Find it with:
```bash
find ~/.steam/steam/steamapps -name "starwarsbattlefrontii.exe" 2>/dev/null | head -1 | xargs dirname
```
Paste that path into the SET GAME FOLDER dialog.

**If Origin Error: "title installed in language not entitled to play":**
Maxima's Wine prefix is missing locale registry keys — its setup commands fail silently on some systems. Fix:
```bash
cat > /tmp/swbf2_fix.reg << 'EOF'
Windows Registry Editor Version 5.00
[HKEY_LOCAL_MACHINE\Software\Origin Games\1035052]
"locale"="en_US"
"displayname"="STAR WARS Battlefront II"
[HKEY_LOCAL_MACHINE\Software\Wow6432Node\Origin Games\1035052]
"locale"="en_US"
"displayname"="STAR WARS Battlefront II"
[HKEY_LOCAL_MACHINE\Software\Electronic Arts\EA Desktop]
"InstallSuccessful"="true"
[HKEY_LOCAL_MACHINE\Software\Origin]
"InstallSuccessful"="true"
"ClientPath"="C:\\Windows\\System32\\conhost.exe"
[HKEY_CURRENT_USER\Control Panel\International]
"Locale"="00000409"
"LocaleName"="en-US"
"sLanguage"="ENU"
EOF
WINEPREFIX=~/.local/share/maxima/wine/prefix wine64 regedit /tmp/swbf2_fix.reg
```
Then restart Kyber and try again.

**First run (one-time setup):**
1. Click **EA Account** → log in with your EA credentials in the browser
2. Click **Skip** on Nexus Mods (optional, only needed for mods)
3. EA login is cached — you stay logged in across sessions

**Hosting a private server with bots:**
- HOST → pick maps/modes → set a **name** and **PASSWORD** → Start Server
- Share the server name + password with friends; they search by name in HOME
- Bot count: in the HOST panel right side → **AUTOPLAYERS** section →
  set **BOTS TEAM 1** and **BOTS TEAM 2** (e.g. 4 each) → click **UPDATE SERVER**
- Bot difficulty: the **BOT DIFFICULTY** slider (RECRUIT → OFFICER → KNIGHT → MASTER)
- After the game loads you can also update settings live and hit UPDATE SERVER again
- For a headless, always-on dedicated server instead (no local Kyber client
  needed to host), see the separate `kyber-server` service.

**Requirements:**
- SWBF2 (Steam AppID 1237950) installed via Steam
  (Kyber manages its own GE-Proton for launching the game)
- glibc 2.38+ — Ubuntu 24.04+, Fedora 38+, SteamOS 3.7+
- EA account (free) at ea.com
- Unprivileged user namespaces enabled (Ubuntu 24.04 restricts these by default):
  ```bash
  sudo sysctl -w kernel.unprivileged_userns_clone=1
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  ```
  The setup script applies this automatically when run with sudo and saves it
  to `/etc/sysctl.d/99-userns.conf` to persist across reboots.
  Without this fix Kyber fails with: `bwrap: setting up uid map: Permission denied`

**If SWBF2 crashes immediately when a level starts loading:**
Likely a DXVK rendering issue, especially on integrated GPUs (Intel Iris Xe, etc.).
Disable fullscreen and HDR in the game settings file — the game writes this on first run:
```bash
PROFILE=$(find ~/.local/share/maxima -name "ProfileOptions_profile" 2>/dev/null | head -1)
sed -i 's/GstRender.FullscreenEnabled 1/GstRender.FullscreenEnabled 0/' "$PROFILE"
sed -i 's/GstRender.EnableHDR 1/GstRender.EnableHDR 0/' "$PROFILE"
```
Then restart Kyber and try hosting/joining again.

**What does NOT work:**
- Running the Windows `kyber_launcher.exe` under Wine/Proton: EA's auth
  callback uses the `eadesktop://` URI scheme which has no Linux handler,
  and Wine's cmd.exe crashes on long OAuth URLs anyway
- Running Kyber inside Wolf/Games-on-Whales: the Docker double-sandbox
  blocks the user namespace clone that Proton requires

**Fixing the base game on native Linux Steam** (EA Desktop/Origin
registration, unrelated to Kyber itself) is a separate script:
`scripts/setup-swbf2-linux.sh` — see that file's header for what it does
and its prerequisites.
