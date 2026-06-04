# ubuntu-post-install

Modular post-install system for Ubuntu servers. One repo, one entry point,
install exactly what you need — interactively or by name.

## Quick start on a fresh box

**Public repo — paste on any new box:**
```bash
curl -fsSL https://raw.githubusercontent.com/outis1one/ubuntu-post-install/main/bootstrap.sh | sudo bash
```

**Private repo — USB thumb drive (recommended):**
```bash
# Once, on any connected machine:
git clone https://github.com/outis1one/ubuntu-post-install.git
cp -r ubuntu-post-install /media/user/DRIVE/

# On every new box — plug in USB, run:
sudo bash /media/$(whoami)/DRIVE/ubuntu-post-install/bootstrap.sh
```
No auth, no internet needed for the scripts. The bootstrap detects it is
running from the repo and copies it to `~/ubuntu-post-install` before
launching the wizard, so the USB can be unplugged once setup starts.

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
1. Installs essential CLI packages (`git`, `curl`, `htop`, `ncdu`, `jq`, `glow`, …)
2. Checks Docker is present (tells you how to install it if not)
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

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
