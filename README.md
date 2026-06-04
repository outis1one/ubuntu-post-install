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
no internet needed for the repo itself. The USB includes a double-click launcher
so you don't need to open a terminal at all.

### 1 — Clone the repo onto the USB (on your main machine)

Plug in the USB, then run:

```bash
# Find where Ubuntu mounted the USB
USB=$(lsblk -o MOUNTPOINT,RM --noheadings | awk '$2=="1" && $1!="" {print $1}' | head -1)
echo "USB mounted at: $USB"

# Clone directly onto it
git clone https://github.com/outis1one/ubuntu-post-install.git \
    "$USB/ubuntu-post-install"
```

Or if you already have a local clone, copy it across:
```bash
cp -r ~/ubuntu-post-install "$USB/ubuntu-post-install"
```

Keep it up to date before each use:
```bash
git -C "$USB/ubuntu-post-install" pull
```

### 2 — Enable right-click "Open in Terminal" (once per machine)

On a fresh Ubuntu Desktop install the Nautilus terminal extension so you can
right-click any folder on the USB and open a terminal there:

```bash
sudo apt install nautilus-extension-gnome-terminal
nautilus -q   # restart Files to pick it up
```

On Ubuntu 24.04+ this is often already present — right-click a folder to check.

### 3 — Double-click to run (no terminal needed)

The repo includes `Run Setup.desktop` — a launcher that opens a terminal and
runs the wizard with sudo when you double-click it in the Files app.

First time on a new machine: right-click the file → **Properties** →
**Executable as Program** toggle on (or tick "Allow executing file as program").
After that, double-clicking it prompts for your sudo password and starts the wizard.

If the toggle isn't there, enable it from the terminal once:
```bash
chmod +x /path/to/usb/ubuntu-post-install/Run\ Setup.desktop
```

### Notes

- Everything the wizard installs (Docker containers, service configs) goes to
  `~/docker/` on the **target machine** — only the scripts live on the USB.
- **exFAT vs ext4:** exFAT works on macOS and Windows too (handy for updating
  the repo from any machine). ext4 is Linux-only but preserves execute
  permissions so you never need the `chmod` step above.

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
