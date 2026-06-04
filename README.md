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

No git required. Works for anyone with a browser.

### 1 — Put the repo on the USB

On GitHub: **Code → Download ZIP** → unzip → copy the
`ubuntu-post-install-main` folder to your USB drive.

To update it later, just download the ZIP again and replace the folder.

### 2 — Run on the target machine

Plug in the USB, then find the drive name:

```bash
ls /media/$(whoami)/
```

Run setup:

```bash
sudo bash /media/$(whoami)/DRIVENAME/ubuntu-post-install-main/bootstrap.sh
```

Replace `DRIVENAME` with what appeared in the `ls` output.

### Notes

- Everything the wizard installs goes to `~/docker/` on the **target machine's
  disk** — only the setup scripts live on the USB.
- **exFAT** is the best filesystem for the USB — readable on Windows and macOS
  for easy ZIP extraction, and works fine on Linux.

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
