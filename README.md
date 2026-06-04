# ubuntu-post-install

Modular post-install system for Ubuntu servers. One repo, one entry point,
install exactly what you need — interactively or by name.

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

## Using a USB drive for Docker data

Storing Docker volumes and service data on a large USB drive keeps your OS
disk free and makes migrating to a new machine trivial.

### 1 — Mount the USB drive

Find the device name:
```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
```

Format as ext4 if needed (skip if already formatted):
```bash
sudo mkfs.ext4 /dev/sdX1   # replace sdX1 with your partition
```

Create a permanent mount point and mount it:
```bash
sudo mkdir -p /mnt/docker-data
sudo mount /dev/sdX1 /mnt/docker-data
```

Make it mount automatically on boot by adding to `/etc/fstab`:
```bash
# Get the drive's UUID (stable across reboots)
sudo blkid /dev/sdX1
# Add a line like this to /etc/fstab:
UUID=your-uuid-here  /mnt/docker-data  ext4  defaults,nofail  0  2
```

The `nofail` option means the system still boots normally if the drive is absent.

### 2 — Point this setup at the USB drive

The wizard stores all Docker service folders under `~/docker/` by default.
To use the USB drive instead, set `DOCKER_DIR` before running setup:

```bash
export DOCKER_DIR=/mnt/docker-data/docker
sudo -E ./setup.sh
```

Or configure it as the permanent default by creating/editing `~/.config/ubuntu-post-install.conf`:
```bash
echo 'DOCKER_DIR=/mnt/docker-data/docker' >> ~/.config/ubuntu-post-install.conf
```

The wizard reads this file on every run, so you only need to set it once.

### 3 — Move existing Docker data (optional)

If you already have data under `~/docker/` and want to move it:
```bash
sudo systemctl stop docker
sudo cp -a ~/docker/. /mnt/docker-data/docker/
sudo mv ~/docker ~/docker.bak            # keep as backup
export DOCKER_DIR=/mnt/docker-data/docker
sudo systemctl start docker
```

Verify everything works, then delete the backup: `sudo rm -rf ~/docker.bak`

### Tips

- Check free space on the USB drive: `df -h /mnt/docker-data`
- Check the drive's health: `sudo smartctl -a /dev/sdX` (install: `sudo apt install smartmontools`)
- For Minecraft world data especially, a fast USB 3.0 drive or SSD is recommended
  — spinning drives can cause I/O lag during chunk generation

## Compatibility

Tested on **Ubuntu 24.04 LTS** and **26.04 LTS**.
Works on any Ubuntu LTS ≥ 22.04; non-LTS releases also work.
The wizard shows the detected OS in the header and warns on unknown versions.
