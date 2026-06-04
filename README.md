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

You can carry the repo on a USB stick and run setup directly from it on any
fresh Ubuntu machine — no git, no internet needed for the repo itself.

### 1 — Put the repo on the USB drive (on your main machine)

Format the USB as ext4 or exFAT, then clone directly onto it:

```bash
# Find your USB device
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT

# Clone the repo onto the USB (adjust mount path to match yours)
git clone https://github.com/outis1one/ubuntu-post-install.git \
    /media/$USER/YOURUSBNAME/ubuntu-post-install
```

Or copy an existing clone:
```bash
cp -r ~/ubuntu-post-install /media/$USER/YOURUSBNAME/ubuntu-post-install
```

### 2 — Run setup on the target machine

Plug the USB in. Ubuntu auto-mounts it under `/media/<username>/` or
`/run/media/<username>/`. Find it:

```bash
ls /media/$USER/          # Ubuntu Desktop
ls /run/media/$USER/      # some distros / servers
lsblk -o NAME,MOUNTPOINT  # always works
```

Then run setup directly from the USB:

```bash
sudo /media/$USER/YOURUSBNAME/ubuntu-post-install/setup.sh
```

Everything the wizard installs (Docker containers, service configs) still goes
to `~/docker/` on the **target machine's disk** — only the setup scripts live
on the USB.

### Tips

- **Keep it updated:** `git pull` inside the USB copy before each use to get
  the latest service scripts.
- **exFAT vs ext4:** exFAT works on macOS and Windows too (easier to update the
  repo from any machine). ext4 is Linux-only but preserves file permissions —
  either works fine for running bash scripts.
- **Permissions:** If the scripts aren't executable after copying, fix with:
  ```bash
  chmod +x /media/$USER/YOURUSBNAME/ubuntu-post-install/setup.sh
  chmod +x /media/$USER/YOURUSBNAME/ubuntu-post-install/services/*.sh
  ```

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
