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
1. Installs essential CLI packages (see [Base packages](#base-packages) below)
2. Checks for Docker CE + Compose plugin; prompts to install if missing
3. Offers to set **site defaults** — timezone, base domain, Caddy Docker network —
   so every service picks them up automatically instead of asking each time
4. Offers to install Caddy (the reverse proxy most services use)
5. Drops into a **category menu** — pick a group, tick services, install, repeat

**Re-run:** skips steps 1–2 (already done), goes straight to the menu.

**Site defaults** are saved to `~/docker/.config` and pre-fill every service prompt.
Update them any time with `sudo ./setup.sh configure`.

## Base packages

The `base` service installs the following on every box:

| Package | Purpose |
|---------|---------|
| `net-tools` | Classic network tools — `ifconfig`, `netstat`, `arp` |
| `ncdu` | Interactive ncurses disk-usage viewer |
| `git` | Version control |
| `curl` | URL data transfer |
| `wget` | File downloader |
| `htop` | Interactive process viewer |
| `tree` | Directory tree display |
| `zip` / `unzip` | Archive packing / unpacking |
| `ca-certificates` | Up-to-date SSL certificate bundle |
| `gnupg` | GPG — used to verify apt signing keys |
| `jq` | Command-line JSON processor |
| `rsync` | Fast file sync / remote copy |
| `glow` | Terminal markdown reader (from [Charm's apt repo](https://github.com/charmbracelet/glow)) |

`glow` is also installable on its own: `sudo ./setup.sh glow`

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

## Backup

The `backup` service (under the `backup` group) sets up **Kopia** — but you are
not limited to it. Below is a guide to every backup strategy in this repo,
with advice on when to reach for each one.

---

### Kopia — the built-in `backup` service

**What it does:** block-level deduplication + zstd compression + AES-256
encryption, scheduled automatically via a systemd timer (cron fallback).
Each run snapshots configured paths and retains versions according to a
policy (latest N, daily, weekly, monthly). An optional `sync-to` step
mirrors the whole encrypted repository to another computer or a cloud
bucket (SFTP, Backblaze B2, S3, rclone).

**Install:** `sudo ./setup.sh backup`

**When to use:** files that change *constantly* — Minecraft region files,
game saves, Steam Proton prefixes, Docker config volumes. Every changed
block is stored once; identical blocks across snapshots share storage.
Kopia is the right default for homelab data that changes on every write.

---

### Borg Backup

**What it is:** `borgbackup` — chunk-based deduplication + lz4/zstd/zlib
compression + AES-CTR encryption. Mature, battle-tested, wide ecosystem
(Borgmatic for YAML-driven automation, Vorta for a GUI).

```bash
sudo apt install borgbackup

# initialise a repo
borg init --encryption=repokey /backups/borg-repo

# take a snapshot
borg create --stats --progress /backups/borg-repo::'{hostname}-{now}' ~/docker

# list snapshots
borg list /backups/borg-repo

# restore
borg extract /backups/borg-repo::snapshot-name
```

**When to use:** same class of problem as Kopia — frequently-changing files
where deduplication pays off. Choose Borg over Kopia if you prefer its
mature ecosystem, Borgmatic config files, or need to share a repo across
multiple machines. Both are excellent; pick the one whose tooling you
prefer.

---

### rsync — plain mirror (no versioning)

**What it is:** `rsync -av --delete SOURCE/ DEST/` — fast one-way mirror.
`--delete` removes files in `DEST` that no longer exist in `SOURCE`.
The destination is a plain readable copy of the source; no special tool
needed to browse or restore.

```bash
rsync -av --delete /source/media/ /backups/media/
```

**When to use:** files that rarely or never change — media libraries,
ROM collections, game installs you could re-download but prefer to keep
locally. You just need *a copy*, not versioning. rsync is lightweight,
transparent, and the destination needs no special format.

**Not suitable for:** files that change often, because one bad `--delete`
run (source corruption, accidental deletion) immediately destroys the
only copy in the destination.

---

### rsync `--link-dest` — versioned snapshots with original structure

**What it is:** each backup run creates a new dated directory. Unchanged
files are **hard-linked** from the previous backup rather than copied, so
unchanged files cost no extra disk space. Every dated directory looks like
a complete independent snapshot of the source — original folder structure
preserved, no rsnapshot-style naming convention.

```bash
#!/bin/bash
DEST=/backups/snapshots
PREV="$DEST/$(ls -1 "$DEST" | tail -1)"  # most recent snapshot
TODAY="$DEST/$(date +%F)"

rsync -av --delete --link-dest="$PREV" /source/ "$TODAY/"
```

Run this daily (via cron or a systemd timer) and you get:

```
/backups/snapshots/
  2024-01-13/    ← full copy (first run)
  2024-01-14/    ← only changed files stored; rest are hard links
  2024-01-15/    ← same
```

If yesterday's run with `--delete` removed everything from the source
(accidental wipe, filesystem corruption), today's snapshot will also be
empty — but `2024-01-14/` and `2024-01-13/` are untouched and fully
restorable with a plain `cp -al` or `rsync`.

**When to use:** general files where you want versioned point-in-time
backups **and** need the original folder structure preserved. No extra
tool required to restore — every dated folder is browsable with `ls` and
copyable with standard Unix tools. Simpler than Borg/Kopia; no encryption
or deduplication across snapshot boundaries.

**Compared to rsnapshot:** rsync `--link-dest` keeps your own naming and
structure; rsnapshot imposes `daily.0/`, `daily.1/`, etc. and manages
rotation automatically. `--link-dest` gives you more control; rsnapshot
gives you easier automation.

---

### rsnapshot — automated versioned snapshots

**What it is:** a wrapper around rsync that manages hard-link snapshots
automatically using a retention scheme (`hourly.0`, `daily.0`, `weekly.0`,
…). Configure sources and retention in `/etc/rsnapshot.conf`, then run on
a schedule.

```bash
sudo apt install rsnapshot
# edit /etc/rsnapshot.conf — set snapshot_root, backup sources, retain counts
rsnapshot daily     # run manually or via cron
rsnapshot -t daily  # dry-run / test config
```

The resulting layout looks like:

```
/backups/rsnapshot/
  daily.0/  ← most recent
  daily.1/
  daily.2/
  weekly.0/
```

Each interval directory contains a full view of the source, hard-linked
where files are unchanged.

**When to use:** you want automated versioned backups without writing your
own `--link-dest` rotation script, and you don't mind that the destination
uses rsnapshot's own directory naming rather than your original structure.
Good for simple setups (home directories, config files) where the rotation
automation saves time.

**Not ideal for:** frequently-changing large files (game saves, databases)
— use Kopia or Borg instead for efficient deduplication across many
changed blocks.

---

### Choosing the right tool

| Scenario | Recommended tool |
|----------|-----------------|
| Minecraft worlds, game saves, Steam prefixes — change on every write | **Kopia** (built-in) or **Borg** |
| Media library, ROMs — rarely change, just need a copy | **rsync plain** |
| General files — want versioning, want original folder structure | **rsync `--link-dest`** |
| Want automated rotation without scripting `--link-dest` yourself | **rsnapshot** |
| Multi-machine deduplicated repo, YAML-driven config (Borgmatic) | **Borg** |

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
