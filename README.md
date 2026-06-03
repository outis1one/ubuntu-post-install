# ubuntu-post-install

Automated post-installation scripts for Ubuntu 24.04 and 26.04. Installs core utilities, configures SSH, and optionally sets up Docker, Samba, VPN tools, remote desktop, self-hosted applications, and a backup system.

## Quick Start

```bash
git clone https://github.com/outis1one/ubuntu-post-install.git
cd ubuntu-post-install

sudo bash ubuntu-post-install-24.04.sh   # Ubuntu 24.04
sudo bash ubuntu-post-install-26.04.sh   # Ubuntu 26.04
```

## Flags

| Flag | Description |
|------|-------------|
| `--dry-run` | Preview what would be installed — no changes made |
| `--unattended` | Automated install with defaults, no prompts |
| `--restore` | Disaster recovery: restore from Kopia backup |

## What the Scripts Do

### Core Utilities (always installed)

`net-tools`, `ncdu`, `git`, `curl`, `wget`, `htop`, `tree`, `zip`/`unzip`

### SSH Configuration

- OpenSSH server
- 4096-bit RSA key generation
- Optional key import from GitHub / Launchpad
- Disables password authentication if keys are imported

### Security (optional)

- **fail2ban** — SSH brute-force protection; only offered when password authentication is still enabled
- **UFW firewall** — allows SSH; allows Samba if installed

### Docker (optional)

- Latest Docker Engine from the official repo (not snap)
- Docker Compose plugin
- Adds user to the `docker` group

### Samba File Sharing (optional)

Shares your primary drive over SMB/CIFS.

### VPN Tools (optional)

- **NetBird** — mesh VPN; `--allow-server-ssh` pre-configured via systemd override so SSH works without re-auth per connection
- **WireGuard**
- **Tailscale**

### Remote Desktop (optional)

- RustDesk
- TeamViewer
- MeshCentral Agent

### Docker Applications (optional)

Installed to `~/docker/{appname}/`. All apps use Docker Compose.

| Application | Description |
|-------------|-------------|
| Immich | Photo & video backup |
| Audiobookshelf | Audiobook & podcast server |
| Emby | Media server |
| A.R.M. | Automatic Ripping Machine |
| Filebrowser | Web file manager |
| Magic Mirror | Smart mirror dashboard |
| ActualBudget | Personal finance |
| Keycloak | Identity & Access Management (SSO) |
| Caddy | Reverse proxy with automatic HTTPS |
| Authelia | SSO + two-factor auth portal |
| Lyrion Music Server | Music streaming |
| Mealie | Recipe manager |
| Minecraft Server | Fabric-based game server |
| Jellyfin | Free media server |
| Frigate NVR | NVR with AI object detection |
| Frigate-Notify | Push notifications for Frigate events |
| ntfy | Self-hosted push notifications |
| Uptime Kuma | Uptime monitoring |
| wg-easy | WireGuard with web UI |
| Traccar | GPS tracking server |
| Portainer | Docker management UI |
| MeshCentral Server | Self-hosted remote management server |
| FindMyDevice | Android device tracking |
| Watchtower | Container update notifications |

#### Authelia notes

Authelia protects Caddy subdomains and auto-configures Caddy on install. Install **Caddy first** — the script handles ordering automatically.

Authelia requires:
- A domain name
- SMTP credentials (for TOTP emails)
- Caddy already installed

### Backup & Restore (Kopia, optional)

- Backs up `~/docker/*` to backup drives
- Local rsync to 1–4 backup drives, scheduled daily at 2 AM via systemd timer
- Cloud backup via rclone (Google Drive, OneDrive, 40+ providers)
- `--restore` flag for disaster recovery after OS drive failure
