# ubuntu-post-install

Modular post-install system for Ubuntu servers. One repo, one entry point,
install exactly what you need — interactively or by name.

## Quick start on a fresh box

```bash
curl -fsSL https://raw.githubusercontent.com/outis1one/ubuntu-post-install/main/bootstrap.sh | sudo bash
```

That installs git (if missing), clones the repo to `~/ubuntu-post-install`,
and drops you into the interactive wizard.

If you already have git:

```bash
git clone https://github.com/outis1one/ubuntu-post-install.git
cd ubuntu-post-install
sudo ./setup.sh
```

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
1. Installs essential CLI packages (`git`, `curl`, `htop`, `ncdu`, `jq`, `glow`, …)
2. Installs Docker CE and the Compose plugin automatically if not already present
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
| `base` | `base`, `glow` |
| `homelab` | `caddy`, `crowdsec`, `authelia`, `homeassistant` |
| `utilities` | `actualbudget`, `ddclient`, `filebrowser`, `fmd`, `magicmirror`, `mealie`, `meshcentral`, `ntfy`, `portainer`, `traccar`, `uptimekuma`, `watchtower`, `wg-easy` |
| `media` | `arm`, `audiobookshelf`, `emby`, `immich`, `jellyfin`, `lyrion` |
| `cameras` | `frigate`, `frigate-audio`, `frigate-notify`, `sky-cam` |
| `gaming` | `js99er`, `minecraft`, `wolf`, `wolf-pair` |
| `extras` | `linux-to-sync`, `silent-send`, `sync-cc` |
| `backup` | `backup` |

Run `./setup.sh --list` to see descriptions.

## Layout

```
setup.sh          dispatcher — wizard, direct install, --list, --dry-run
lib/common.sh     shared helpers: logging, prompts, site config, OS detection
services/         one file per service (self-registering)
extras/           non-Docker assets bundled with the repo (e.g. sync_cc.py)
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

Carry the repo on a USB stick and run setup on any fresh Ubuntu machine —
no internet needed for the repo itself.

### 1 — Put the repo on the USB (on your main machine)

Open a terminal in the repo and clone onto the USB from there. The file
manager shows the USB in the sidebar — right-click it → **Open in Terminal**,
then:

```bash
git clone https://github.com/outis1one/ubuntu-post-install.git .
```

Or copy an existing clone:
```bash
cp -r ~/ubuntu-post-install /path/to/usb/ubuntu-post-install
```

Keep it up to date before each use:
```bash
git pull
```

### 2 — Run on the target machine (two ways)

**Option A — Right-click → Open in Terminal** (quickest)

In the Files app, navigate to the USB → right-click the
`ubuntu-post-install` folder → **Open in Terminal**, then:

```bash
sudo ./setup.sh
```

If "Open in Terminal" isn't in the menu, install it once:
```bash
sudo apt install nautilus-extension-gnome-terminal && nautilus -q
```

**Option B — Double-click `bootstrap.sh`**

Right-click `bootstrap.sh` → **Properties** → turn on **Executable as Program**.
After that, double-clicking it asks *"Run in Terminal?"* — click that, and it
prompts for your sudo password and starts the wizard automatically.
(The script re-elevates itself with sudo so you don't need to type anything
extra in the terminal.)

### Notes

- Everything the wizard installs goes to `~/docker/` on the **target machine's
  disk** — only the setup scripts live on the USB.
- **exFAT vs ext4:** exFAT works on macOS and Windows too (handy for updating
  the repo from any machine). ext4 is Linux-only but preserves the executable
  bit on `bootstrap.sh` so the Properties step above is only needed once.

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
