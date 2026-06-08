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
| `utilities` | `actualbudget`, `ddclient`, `filebrowser`, `fmd`, `gatus`, `magicmirror`, `mail-archiver`, `mattermost`, `mealie`, `meshcentral`, `nextcloud`, `ntfy`, `onlyoffice`, `portainer`, `rustdesk`, `syncthing`, `traccar`, `unifi`, `uptimekuma`, `vaultwarden`, `watchyourlan`, `watchtower`, `wg-easy` |
| `media` | `arm`, `audiobookshelf`, `emby`, `immich`, `jellyfin`, `lyrion` |
| `cameras` | `frigate`, `frigate-audio`, `frigate-notify`, `sky-cam` |
| `gaming` | `js99er`, `minecraft`, `wolf`, `wolf-pair` |
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
