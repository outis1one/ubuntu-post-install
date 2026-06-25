# ubuntu-post-install

Modular post-install system for Ubuntu servers. One repo, one entry point,
install only what you need — interactively or by name.

## Quick start on a fresh box

**Public repo — paste on any new box:**
```bash
curl -fsSL https://raw.githubusercontent.com/outis1one/ubuntu-post-install/main/bootstrap.sh | sudo bash
```

**USB thumb drive — works for public or private repos:**

Prepare the USB once on any machine (no git required):
1. Go to the repo on GitHub → green **Code** button → **Download ZIP**
2. Unzip it — you'll get a folder called `ubuntu-post-install-main`
3. Copy that folder to your USB drive

On every new box:
1. Plug in the USB — it opens in the file manager
2. Navigate into the `ubuntu-post-install-main` folder
3. **Either:**
   - Right-click inside the folder → **Open in Terminal** → type `bash bootstrap.sh`
   - **Or** double-click `bootstrap.sh` → if prompted, choose **Run in Terminal**

The script asks for your password if needed. It detects it is running from
inside the repo, copies everything to `~/ubuntu-post-install`, then launches
the wizard — the USB can be unplugged once setup starts.

**Private repo — PAT (alternative):**
```bash
sudo bash bootstrap.sh --pat ghp_xxxxxxxxxxxxxxxxxxxx
```
Use a fine-grained read-only PAT scoped to just this repo (Contents: Read).
The PAT is stripped from the stored remote URL after cloning.

## Usage

```bash
sudo ./setup.sh                        # interactive wizard
sudo ./setup.sh caddy immich           # install specific services
sudo ./setup.sh configure              # set site defaults (timezone, domain, Caddy network)
./setup.sh --list                      # list all services grouped by category
sudo ./setup.sh --dry-run immich       # preview without making changes
sudo ./setup.sh --unattended base      # non-interactive, use defaults
```

## What the wizard does

**First run:**
1. Installs essential CLI packages (`net-tools`, `ncdu`, `git`, `curl`, `wget`, `htop`, `tree`, `zip`/`unzip`, `ca-certificates`, `gnupg`, `jq`, `rsync`, `glow`)
2. Checks for Docker CE + Compose plugin; prompts to install if missing
3. Offers to set **site defaults** — timezone, base domain, Caddy Docker network —
   so every service picks them up automatically instead of asking each time
4. Offers to install Caddy (the reverse proxy most services use)
5. Drops into a **category menu** — pick a group, tick services, install, repeat

**Re-run:** skips steps 1–2 (already done), goes straight to the menu.

**Site defaults** are saved to `~/docker/.config` and pre-fill every service prompt.
Update them any time with `sudo ./setup.sh configure`.

## Services

| Group | Services |
|-------|---------|
| `base` | `net-tools`, `ncdu`, `git`, `curl`, `wget`, `htop`, `tree`, `zip`/`unzip`, `ca-certificates`, `gnupg`, `jq`, `rsync`; `glow` (terminal markdown reader, Charm apt repo) |
| `homelab` | `caddy`, `crowdsec`, `authelia`, `homeassistant`, `asterisk` |
| `utilities` | `actualbudget`, `ai-gpu`, `archivebox`, `changedetection`, `ddclient`, `filebrowser`, `fmd`, `gatus`, `homebox`, `iopaint`, `joplin`, `koha`, `magicmirror`, `mail-archiver`, `mattermost`, `mealie`, `meshcentral`, `n8n`, `nextcloud`, `ntfy`, `onlyoffice`, `portainer`, `rustdesk`, `stirling-pdf`, `syncthing`, `traccar`, `unifi`, `uptimekuma`, `vaultwarden`, `watchyourlan`, `watchtower`, `wg-easy` |
| `media` | `arm`, `audiobookshelf`, `calibre-web`, `emby`, `immich`, `jellyfin`, `lyrion` |
| `cameras` | `frigate`, `frigate-audio`, `frigate-notify`, `sky-cam` |
| `gaming` | `drum-rhythm-game`, `js99er`, `kyber-server`, `minecraft`, `wolf`, `wolf-pair` |
| `extras` | `kdeconnect`, `silent-send`, `sync-cc` |
| `backup` | `backup` — complete recovery: entire `~/docker/<service>/` for every service via Kopia (Minecraft: flush+snap, no downtime; others: stop/snap/start for DB consistency); `borg-backup` — same coverage via Borg (chunk dedup, SSH remote repos, Borgmatic/Vorta compatible); `gaming-backup` — frequent game-save snapshots (Minecraft world data, emulator saves, Steam — no downtime, run hourly) |

Run `./setup.sh --list` to see descriptions.

## Layout

```
setup.sh          dispatcher — wizard, direct install, --list, --dry-run
lib/common.sh     shared helpers: logging, prompts, site config, OS detection
services/         one file per service (self-registering)
extras/           non-Docker assets bundled with the repo (e.g. sync_cc.py)
CLAUDE.md         contributor guide — how to add services, available helpers
```

## Managing installed services

Every Docker service installs to its own `~/docker/<name>/` folder:

```bash
cd ~/docker/immich
docker compose up -d        # start
docker compose logs -f      # logs
docker compose pull && docker compose up -d   # update
docker compose down         # stop
```

## Installing from a USB thumb drive

No git required. Works for anyone with a browser.

### 1 — Put the repo on the USB

1. On GitHub: click **Code → Download ZIP**
2. Open your Downloads folder — right-click the ZIP → **Extract Here**
3. Drag the `ubuntu-post-install-main` folder onto the USB drive in the
   file manager sidebar

To update later: download the ZIP again, extract, drag the new folder to the
USB and replace the old one.

### 2 — Run on the target machine

Plug in the USB. Open the `ubuntu-post-install-main` folder in the file manager,
then either:

- **Right-click inside the folder → Open in Terminal**, then run:
  ```bash
  sudo bash bootstrap.sh
  ```

- **Double-click `bootstrap.sh`** → click *Run in Terminal* → it prompts for
  your sudo password and starts the wizard automatically.

### Notes

- Everything the wizard installs goes to `~/docker/` on the **target machine's
  disk** — only the setup scripts live on the USB.
- **exFAT** is the best filesystem for the USB — readable on Windows and macOS
  for easy ZIP extraction, and works fine on Linux.

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.

## Gaming scripts

Standalone scripts in `scripts/` for gaming setup — not part of the main
wizard, run separately.

### Star Wars Battlefront II (2017) + Kyber

**`scripts/setup-swbf2-linux.sh`** — Configure SWBF2 on native Linux Steam
(Proton, controller, performance tweaks).

**`scripts/setup-kyber-linux.sh`** — Install the native Linux Kyber launcher.

Kyber is the community multiplayer replacement for SWBF2 after EA shut down
official servers in 2022. It went open-source (GPL) in January 2026.

**The correct approach is a native Linux AppImage** — not Wine or Proton for
the launcher itself. The AppImage is maintained at:
https://github.com/simonlinuxcraft/kyber-linuxport-unofficial

```bash
chmod +x scripts/setup-kyber-linux.sh
./scripts/setup-kyber-linux.sh
```

The script downloads the latest AppImage, installs a desktop entry, and
creates a `kyber` command in `~/.local/bin`.

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
