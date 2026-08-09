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
1. Installs essential CLI packages (`net-tools`, `ncdu`, `git`, `curl`, `wget`, `htop`, `tree`, `zip`/`unzip`, `ca-certificates`, `gnupg`, `jq`, `rsync`, `glow`), Docker CE + Compose plugin, and `openssh-server` — offers to import SSH keys from GitHub/Launchpad (`ssh-import-id`), disable password login once a key is confirmed, install NetBird, and add SSH Host aliases (see [SSH Host aliases](#ssh-host-aliases))
2. Asks **where Caddy runs** — this machine, a remote machine/VPN peer, or none — before anything else, since every later service prompt depends on the answer
3. If Caddy is local: offers to set **site defaults** — timezone, base domain, Caddy Docker network — so every service picks them up automatically instead of asking each time, then offers to install Caddy itself
4. Drops into a **category menu** — pick a group, tick services, install, repeat
5. Ends by dropping you into a fresh login shell so the `docker` group takes effect immediately (no manual `newgrp docker` or SSH reconnect needed)

**Re-run:** skips steps already completed, shows a summary of installed services, and goes straight to the menu.

**Site defaults** are saved to `~/docker/.config` and pre-fill every service prompt.
Update them any time with `sudo ./setup.sh configure`. Remote/none Caddy mode
skips the domain/timezone prompt entirely — service installers instead save
a ready-to-copy Caddy config snippet to `~/docker/caddy-snippets/`.

## Services

| Group | Services |
|-------|---------|
| `base` | `net-tools`, `ncdu`, `git`, `curl`, `wget`, `htop`, `tree`, `zip`/`unzip`, `ca-certificates`, `gnupg`, `jq`, `rsync`; `glow` (terminal markdown reader, Charm apt repo); Docker CE + Compose plugin; `openssh-server` with GitHub/Launchpad SSH key import, optional password-auth lockdown, and SSH Host aliases; optional NetBird overlay network |
| `homelab` | `caddy`, `crowdsec`, `authelia`, `coturn` (shared TURN/STUN relay — Asterisk, Mattermost Calls, and future WebRTC-capable services all register a dedicated credential against one instance instead of each running its own), `homeassistant`, `asterisk`, `pstn-trunk`, `sms-inbound`, `security-dashboard`, `sunshine` |
| `utilities` | `actualbudget`, `ai-gpu`, `ai-stack`, `archivebox`, `changedetection`, `ddclient`, `filebrowser`, `fmd`, `gatus`, `homebox`, `iopaint`, `joplin`, `koha`, `magicmirror`, `mail-archiver`, `mattermost`, `mealie`, `meshcentral`, `n8n`, `nextcloud`, `ntfy`, `onlyoffice`, `paintplus`, `portainer`, `rustdesk`, `stirling-pdf`, `syncthing`, `traccar`, `unifi`, `uptimekuma`, `vaultwarden`, `watchyourlan`, `watchtower`, `wg-easy`, `wordpress` (multi-site, dedicated MariaDB per site — blogs, business sites, e-commerce via WooCommerce) |
| `media` | `arm`, `audiobookshelf`, `calibre-web`, `emby`, `immich`, `jellyfin`, `lyrion` |
| `cameras` | `frigate`, `frigate-audio`, `frigate-notify`, `sky-cam` |
| `gaming` | `drum-rhythm-game`, `js99er`, `kyber-launcher`, `kyber-server`, `minecraft`, `wolf`, `wolf-pair` |
| `extras` | `kdeconnect`, `silent-send`, `ssh-config`, `sync-cc` |
| `backup` | `backup` — complete recovery: entire `~/docker/<service>/` for every service via Kopia (Minecraft: flush+snap, no downtime; others: stop/snap/start for DB consistency), optional offsite mirror (`kopia repository sync-to`), plus `dr_bringup.sh` — unattended restore-everything-and-start for standing up a cold spare box; `borg-backup` — same coverage via Borg (chunk dedup, SSH remote repos, Borgmatic/Vorta compatible); `gaming-backup` — frequent game-save snapshots (Minecraft world data, emulator saves, Steam — no downtime, run hourly) |

Run `./setup.sh --list` to see descriptions.

<details>
<summary>Copiable list of all services by category</summary>

```
base
  base
  glow

homelab
  caddy
  crowdsec
  authelia
  coturn
  homeassistant
  asterisk
  pstn-trunk
  sms-inbound
  security-dashboard
  sunshine

utilities
  actualbudget
  ai-gpu
  ai-stack
  archivebox
  changedetection
  ddclient
  filebrowser
  fmd
  gatus
  homebox
  iopaint
  joplin
  koha
  magicmirror
  mail-archiver
  mattermost
  mealie
  meshcentral
  n8n
  nextcloud
  ntfy
  onlyoffice
  paintplus
  portainer
  rustdesk
  stirling-pdf
  syncthing
  traccar
  unifi
  uptimekuma
  vaultwarden
  watchyourlan
  watchtower
  wg-easy
  wordpress

media
  arm
  audiobookshelf
  calibre-web
  emby
  immich
  jellyfin
  lyrion

cameras
  frigate
  frigate-audio
  frigate-notify
  sky-cam

gaming
  drum-rhythm-game
  js99er
  kyber-launcher
  kyber-server
  minecraft
  wolf
  wolf-pair

extras
  kdeconnect
  silent-send
  ssh-config
  sync-cc

backup
  backup
  borg-backup
  gaming-backup
```

</details>

## Layout

```
setup.sh          dispatcher — wizard, direct install, --list, --dry-run
lib/common.sh     shared helpers: logging, prompts, site config, OS detection
services/         one file per service (self-registering)
vendor/           full app source trees vendored for a service (e.g. ai-stack,
                  paintplus, easy-asterisk) — copied into place at install time,
                  no network clone needed
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

## SSH Host aliases

`~/.ssh/config` lets you `ssh <alias>` instead of typing `ssh user@1.2.3.4`
every time — especially handy once machines are reachable over a VPN/NetBird
overlay network where the IP is easy to forget:

```
Host myserver
    HostName 100.x.x.x
    User someuser
    Port 22
```

Three ways to manage these entries:

- **During `base` install** — after SSH key import, the wizard offers to add
  one or more aliases interactively
- **Any time** — `sudo ./setup.sh ssh-config` lists, adds, or removes aliases
  without touching anything else
- **By hand** — edit `~/.ssh/config` directly; it's a plain OpenSSH client
  config file, nothing generated or templated beyond the `Host` block itself

Aliases are written to the invoking user's own config (not root's), since
that's whose terminal actually runs `ssh`.

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

Gaming setup walkthroughs live next to their service files, not here — see
`services/<name>.md` (e.g. [`services/kyber-launcher.md`](services/kyber-launcher.md)
for SWBF2 (2017) + Kyber: playing, hosting, and troubleshooting). It's
appended automatically to `~/.local/share/kyber/README.md` when you run
`sudo ./setup.sh kyber-launcher`.

Also in `scripts/` (standalone, not part of the main wizard):
`setup-swbf2-linux.sh` (native Steam/Proton fixes for the base game),
`setup-kyber-linux.sh` (standalone equivalent of the `kyber-launcher`
service), and Wolf/Games-on-Whales container variants
(`setup-swbf2-wolf.sh`, `setup-kyber-wolf.sh`).
