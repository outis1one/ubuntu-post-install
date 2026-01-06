# Ubuntu 24.04 Desktop Post-Installation Script

Automated setup script for Ubuntu 24.04 Desktop that installs essential tools, configures SSH, and optionally sets up Docker, Samba file sharing, remote access tools (NetBird, RustDesk), and an automated backup system.

**Key Features:**
- **Rerunnable** - Detects existing installations and offers to reinstall/reconfigure
- **Modular** - Every component is optional with y/n prompts
- **Dry-run mode** - Preview what would be installed without making changes
- **Unattended mode** - Run with defaults for automated/scripted installs
- **Disaster recovery** - One-click restore from Kopia backup after system failure
- **Logging** - All output logged to `/var/log/post-install.log`
- **Local backup** - rsync to 1-4 drives with customizable names
- **Cloud backup** - Encrypted backup to Google Drive, OneDrive, or 40+ providers

## What This Script Does

### Core Utilities Installed (Always)
- **net-tools** - Network utilities (ifconfig, netstat)
- **ncdu** - Disk usage analyzer with ncurses interface
- **git** - Version control system
- **curl & wget** - Download tools
- **htop** - Interactive process viewer
- **tree** - Directory structure visualizer
- **zip/unzip** - Archive utilities

### SSH Configuration
- **OpenSSH Server** - Enables remote SSH access
- **SSH Key Generation** - Creates 4096-bit RSA key pair for this computer
- **Key Import** - Optionally imports public keys from GitHub and/or Launchpad
- **Security** - Automatically disables password authentication if keys are imported

### Security Features (Optional)
- **fail2ban** (when password SSH enabled)
  - Protects against SSH brute-force attacks
  - Bans IPs after 5 failed attempts for 1 hour
  - Only offered when SSH password authentication remains enabled
  - **Note:** fail2ban provides no benefit with key-only SSH because SSH keys cannot be brute-forced (they're 4096-bit cryptographic keys, not passwords)
- **UFW Firewall**
  - Simple firewall management
  - Automatically allows SSH (port 22)
  - Automatically allows Samba if installed
  - Easy to add/remove port rules

### Docker Installation (Optional)
- **Docker Engine** - Latest version from official Docker repository (not snap)
- **Docker Compose** - Installed as a plugin (modern method)
- **User Configuration** - Adds your user to docker group (run docker without sudo)
- Detects if already installed and offers to reinstall

### Samba File Sharing (Optional)
- **Samba Server** - SMB/CIFS file server for network file sharing
- **Primary Drive Share** - Entire primary drive shared as "Primary"
- **User Configuration** - Creates Samba user matching your system username
- **Cross-Platform Access** - Works with Windows, Mac, and Linux
- Detects if already installed and offers to reconfigure

### VPN Tools (Optional)
- **NetBird** - Mesh VPN for secure device connections
  - Zero-config mesh VPN with built-in SSH
  - Manages SSH keys automatically (no manual key setup)
  - Detects if already installed
- **WireGuard** - Fast, modern VPN protocol
  - Lightweight and high-performance
  - Built into Linux kernel
  - Manual configuration via config files
- **Tailscale** - Zero-config mesh VPN built on WireGuard
  - Easy setup - just sign in
  - Built-in SSH (Tailscale SSH) - no keys needed
  - Automatic NAT traversal

### Remote Desktop Tools (Optional)
- **RustDesk** - Open-source remote desktop software
  - Self-hosted or use public servers
  - Cross-platform
- **TeamViewer** - Commercial remote desktop (free tier available)
  - Cross-platform (Windows, Mac, Linux, mobile)
  - No port forwarding needed
- **MeshCentral Agent** - Open-source remote management
  - Requires a MeshCentral server (self-hosted or public)
  - Web-based remote desktop, terminal, and file transfer

### Self-Hosted Docker Applications (Optional)
Install containerized applications to `~/docker/{appname}/`:

- **Immich** - Self-hosted photo & video backup (like Google Photos)
- **Audiobookshelf** - Audiobook & podcast server with progress sync
- **Emby** - Media server for movies, TV, and music
- **A.R.M.** - Automatic Ripping Machine for DVDs/Blu-rays/CDs
- **Filebrowser** - Web-based file manager
- **Magic Mirror** - Smart mirror dashboard (up to 3 instances)
- **Lyrion Music Server** - Music streaming to Squeezebox/Chromecast
- **Mealie** - Recipe manager & meal planner
- **Minecraft Server** - Fabric server with configurable RAM limit
- **linux-to-sync** - Private repository setup
- **Jellyfin** - Free media server (alternative to Emby)
- **Frigate** - NVR with AI object detection
- **Caddy** - Reverse proxy with automatic HTTPS
- **ddclient** - Dynamic DNS updater
- **ntfy** - Self-hosted push notifications
- **Uptime Kuma** - Service uptime monitoring
- **wg-easy** - WireGuard VPN with web UI
- **Traccar** - GPS tracking server
- **Portainer** - Docker management UI
- **MeshCentral Server** - Self-hosted remote management server
- **FindMyDevice** - Self-hosted Android device tracking
- **Frigate-Notify** - Push notifications for Frigate AI events
- **Watchtower** - Container update monitoring (notify-only by default)

### Container Backup & Restore (Kopia)
Backup all Docker container data (configs, databases, app data) to your backup drives for disaster recovery. Includes restore functionality to recover containers after OS drive failure.

**What lives where:**
- `~/docker/*/` (OS drive) - App configs, databases, compose files → **Backed up by Kopia**
- `~/drives/primary/` (data drive) - Media files, photos, documents → **Backed up by rsync**
- `/var/lib/docker/` (OS drive) - Container images, runtime state → **Not backed up** (re-pulled on restore)

### Backup System (Optional)

**Local Backup (rsync):**
- Syncs your primary drive to 1-4 backup drives
- Delta transfers - only changed bytes are copied
- Customizable drive names (default: primary, backup1, backup2, etc.)
- Systemd timer for scheduled daily backups at 2 AM

**Why rsync instead of RAID?**
- RAID mirrors corruption instantly - rsync gives you time to notice problems
- RAID requires identical drives - rsync works with any sizes
- RAID is complex to set up/recover - rsync is simple copy
- rsync can run on schedule - RAID is always-on (more wear)
- With rsync, backup drives can be disconnected for safety

**Cloud Backup (rclone, optional):**
- Encrypted cloud backup to Google Drive, OneDrive, or 40+ providers
- Files are encrypted BEFORE upload - cloud provider cannot read them
- Guided setup for Google Drive and OneDrive with encryption
- rclone.conf automatically backed up to all local backup drives

**Drive Mount Points (`~/drives/`):**
The script creates and manages mount points for your drives:
```
~/drives/
├── primary/    # Your main data drive
├── backup1/    # First backup drive
└── backup2/    # Second backup drive (split mode only)
```

**Interactive Drive Mounting:**
During backup setup, the script:
1. Shows available block devices (`lsblk`)
2. Asks for device paths (e.g., `/dev/sdb1`, `/dev/sdc1`)
3. Mounts drives to `~/drives/` directories
4. Optionally adds entries to `/etc/fstab` for auto-mount at boot

**Features:**
- Systemd timer for scheduled daily backups at 2 AM
- Detects existing configuration and offers to reconfigure

## Prerequisites

- Fresh Ubuntu 24.04 Desktop installation
- Sudo/root access
- Internet connection
- (Optional) External drives for backup configuration

## Quick Start

### 1. Download the Script

```bash
# Clone the repository
git clone https://github.com/outis1one/post-ubuntu-install.git
cd post-ubuntu-install

# Or download the script directly
wget https://raw.githubusercontent.com/outis1one/post-ubuntu-install/main/ubuntu-post-install.sh -O post-install.sh
```

### 2. Make Executable

```bash
chmod +x post-install.sh
```

### 3. Run the Script

```bash
sudo ./post-install.sh
```

### 4. Command-Line Options

```bash
# Interactive mode (default)
sudo ./post-install.sh

# Preview what would be installed (no changes made)
sudo ./post-install.sh --dry-run

# Automated install with defaults (no prompts)
sudo ./post-install.sh --unattended

# Disaster recovery - restore from Kopia backup
sudo ./post-install.sh --restore

# Show help
sudo ./post-install.sh --help
```

**Unattended mode defaults:**
- Skip SSH key generation
- No SSH key imports (password auth stays enabled)
- Install Docker
- Install fail2ban (since password auth is enabled)
- Enable UFW firewall

## Disaster Recovery

If your OS drive fails, you can restore everything from a Kopia backup.

### One-Click Recovery

```bash
# 1. Install fresh Ubuntu 24.04
# 2. Connect your backup drive
# 3. Download and run the script

wget https://raw.githubusercontent.com/outis1one/post-ubuntu-install/main/ubuntu-post-install.sh
chmod +x ubuntu-post-install.sh
sudo ./ubuntu-post-install.sh --restore
```

### What the Recovery Does

1. **Installs core utilities** - openssh-server, git, curl, Kopia, etc.
2. **Finds your backup drive** - Shows available drives, auto-detects Kopia repo
3. **Gets Kopia password** - For repository access
4. **Installs Docker** - If not already installed
5. **Lists snapshots** - Shows all available backups, lets you choose
6. **Restores from backup** - Extracts files to temp location
7. **Selects services** - Whiptail checklist to pick which services to restore
8. **Starts containers** - Optionally starts all services immediately
9. **Reconnects Kopia** - Sets up ongoing backups to the same repository

### What Gets Restored

Everything in `~/docker/` that Kopia backed up:
- **App configs** - All settings, users, preferences
- **Databases** - Immich, Mealie, Traccar, etc.
- **Media metadata** - Emby/Jellyfin watch history, thumbnails
- **Minecraft worlds** - Saves, mods, permissions
- **Frigate** - Camera configs, detection settings
- **All other container data**

### Recovery Requirements

- Fresh Ubuntu 24.04 installation
- Backup drive with Kopia repository
- Kopia password (stored in `~/docker/kopia/.env` on backup, or remembered)

### Interactive Mode

When you run the script without `--restore`, you'll be asked:
```
INSTALLATION MODE
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  [N] Normal install - Fresh install or modify existing
  [M] Migration - Import existing Docker containers
  [R] Disaster recovery - Restore from Kopia backup

Select mode (N/M/R) [N]:
```

## Migration Mode

If you have existing Docker containers from another setup (different directory structure, another server, etc.), migration mode imports them without changing versions.

### When to Use Migration

- Moving from `/var/docker` or `/opt/docker` to `~/docker`
- Importing containers from another machine
- Adopting this script's structure for existing setups

### What Migration Does

1. **Scans source directory** - Auto-detects Docker directories, finds all compose files
2. **Shows containers found** - Lists each container with size
3. **Select what to migrate** - Whiptail checklist or text menu
4. **Stops containers** (optional) - Ensures clean copy of databases
5. **Copies containers** - Preserves versions, configs, and all data
6. **Starts containers** - In the new location
7. **Offers additional services** - Continue with normal install for more apps

### Migration vs Restore

| Feature | Migration | Disaster Recovery |
|---------|-----------|-------------------|
| Source | Existing Docker directory | Kopia backup |
| Versions | Preserved exactly | Preserved exactly |
| After | Install more services | Reconnect backups |
| Use case | Restructuring setup | OS drive failure |

### 5. Follow Interactive Prompts

The script shows current system status and asks:
- **SSH Key Generation**: Generate new 4096-bit RSA key? (y/n)
- **Import SSH Keys**: GitHub username, Launchpad username (or leave blank)
- **fail2ban**: Install fail2ban? (only if password SSH remains enabled)
- **Docker**: Install Docker? (y/n) - or reinstall if detected
- **Samba File Sharing**: Install and configure Samba? (y/n)
  - If yes: Set password for Samba user
- **NetBird**: Install NetBird mesh VPN? (y/n)
- **WireGuard**: Install WireGuard VPN? (y/n)
- **Tailscale**: Install Tailscale VPN? (y/n)
- **RustDesk**: Install RustDesk remote desktop? (y/n)
- **TeamViewer**: Install TeamViewer remote desktop? (y/n)
- **MeshCentral**: Install MeshCentral agent? (y/n)
  - If yes: Provide MeshCentral server agent URL
- **Docker Apps**: Install self-hosted applications? (each individually)
  - Immich, Audiobookshelf, Emby, A.R.M., Filebrowser
  - Magic Mirror (1-3 instances), Lyrion, Mealie, Minecraft
  - linux-to-sync (private repo)
- **Local Backup**: Set up local backup with rsync? (y/n)
  - If yes: Configure drive names, mount drives, fstab configuration
- **Cloud Backup**: Set up encrypted cloud backup? (y/n)
  - If yes: Choose provider (Google Drive, OneDrive, other), set up encryption
- **UFW Firewall**: Enable and configure UFW? (y/n)

### 5. Post-Installation Steps

**Required:**
```bash
# Log out and back in for docker group to take effect
logout
```

**If you enabled cloud backup:**
- Run `rclone config` if you need to reconfigure
- Keep your `~/.config/rclone/rclone.conf` backed up securely off-site

## SSH Configuration

### SSH Key Combinations Supported

You can use **any combination** of:
- ✓ GitHub keys + Launchpad keys + NetBird SSH
- ✓ GitHub keys only
- ✓ Launchpad keys only
- ✓ NetBird SSH only
- ✓ Your generated key + any of the above
- ✓ Password authentication only (if no keys imported)

### Traditional SSH vs NetBird SSH

**Traditional SSH** (uses imported keys):
```bash
ssh user@hostname
ssh user@192.168.1.100
```

**NetBird SSH** (manages keys automatically):
```bash
netbird ssh peer-name
```

These work independently - NetBird SSH works even if password auth is disabled.

### Your Generated SSH Key

After installation, find your public key:
```bash
cat ~/.ssh/id_rsa.pub
```

Use it to:
- Add to GitHub: Settings → SSH and GPG keys → New SSH key
- Add to other servers: Append to remote `~/.ssh/authorized_keys`
- Connect from this computer to other servers

## Backup Configuration

*This section applies if you chose to set up the backup system during installation.*

### Local Backup (rsync)

The local backup system uses rsync to sync your primary drive to one or more backup drives.

**Run Backup:**
```bash
sudo /usr/local/bin/backup-scripts/local-backup.sh
```

**View Log:**
```bash
tail -f /var/log/rsync-backup.log
```

**Enable Automatic Daily Backups:**
```bash
sudo systemctl enable rsync-backup.timer
sudo systemctl start rsync-backup.timer

# Check status
sudo systemctl list-timers | grep rsync
```

### Cloud Backup (rclone)

If you set up cloud backup, your files are encrypted locally before being uploaded.

**Run Cloud Backup:**
```bash
sudo /usr/local/bin/backup-scripts/cloud-backup.sh
```

**View Log:**
```bash
tail -f /var/log/cloud-backup.log
```

### Protecting Your rclone Configuration

Your `~/.config/rclone/rclone.conf` file contains your encryption keys and cloud credentials. **Without this file, your encrypted cloud files cannot be decrypted.**

**The script automatically:**
- Backs up rclone.conf to all local backup drives
- Reminds you to store a copy off-site

**Recommended off-site backup methods for rclone.conf:**
- **Signal** - End-to-end encrypted; send to yourself or a trusted contact
- **Box.com** - Better privacy policy than some alternatives
- **Password manager** - 1Password, Bitwarden, etc.
- **Encrypted USB drive** - Store at another physical location

**Note on Dropbox:** Works but has broader data access policies. Consider alternatives.

### Restoring Files on Another Computer

If you need to decrypt your cloud-backed files on a new machine:

1. **Install rclone:**
   ```bash
   sudo apt install rclone
   ```

2. **Copy your rclone.conf to the new machine:**
   ```bash
   mkdir -p ~/.config/rclone
   # Copy your backed-up rclone.conf to ~/.config/rclone/rclone.conf
   ```

3. **Download and decrypt files:**
   ```bash
   # List your encrypted remote
   rclone ls cloud-crypt:

   # Download and decrypt to local folder
   rclone copy cloud-crypt: /path/to/restore/
   ```

The "cloud-crypt" remote automatically decrypts files during download using the keys stored in rclone.conf.

### Manual Drive Mounting

If you skipped auto-mounting during installation:

```bash
# Create mount points (already done by script)
mkdir -p ~/drives/primary ~/drives/backup1 ~/drives/backup2

# Find your drives
lsblk -f
sudo blkid

# Mount drives
sudo mount /dev/sdb1 ~/drives/primary
sudo mount /dev/sdc1 ~/drives/backup1
sudo mount /dev/sdd1 ~/drives/backup2

# Make permanent (add to /etc/fstab)
sudo nano /etc/fstab
```

Add lines like:
```
UUID=xxxx-xxxx /home/username/drives/primary auto defaults 0 2
UUID=yyyy-yyyy /home/username/drives/backup1 auto defaults 0 2
UUID=zzzz-zzzz /home/username/drives/backup2 auto defaults 0 2
```

## Drive Failure Recovery

### If PRIMARY Drive Fails

```bash
# 1. Get new drive (same size or larger)
# 2. Format and mount it
sudo mkfs.ext4 /dev/sdX1
sudo mount /dev/sdX1 ~/drives/primary

# 3. Restore from backup(s)
# Full mode: restore from backup1
rsync -avh ~/drives/backup1/ ~/drives/primary/  # or rclone sync

# Split mode: restore from BOTH backups
rsync -avh ~/drives/backup1/ ~/drives/primary/
rsync -avh ~/drives/backup2/ ~/drives/primary/

# 4. Update /etc/fstab with new UUID
sudo blkid /dev/sdX1
sudo nano /etc/fstab
```

### If BACKUP Drive Fails

Your primary still has all data - it's safe. Just replace the backup drive and re-run the backup script:

```bash
sudo mkfs.ext4 /dev/sdX1
sudo mount /dev/sdX1 ~/drives/backup1
sudo /usr/local/bin/backup-scripts/{tool}-backup.sh
```

**⚠️ Replace failed backup drives quickly!** While down, those folders have no redundancy.

## Verification Commands

### Check Backups Match Primary

```bash
# Using rsync (dry-run shows differences)
rsync -avhn --delete ~/drives/primary/ ~/drives/backup1/

# Using rclone
rclone check ~/drives/primary ~/drives/backup1
```

### Check Space Usage

```bash
# See what's on each drive
du -sh ~/drives/primary/*
du -sh ~/drives/backup1/*

# Check free space
df -h ~/drives/
```

## VPN Setup

### NetBird

```bash
# 1. Connect to NetBird (opens browser for auth)
netbird up

# 2. View connected peers
netbird status

# 3. SSH via NetBird (if enabled in dashboard)
netbird ssh peer-name

# 4. Configure ACLs and settings
# Visit: https://app.netbird.io
```

**NetBird SSH:** NetBird manages its own SSH keys automatically. Enable SSH in the NetBird dashboard, then use `netbird ssh <peer-name>` to connect. No manual key configuration needed.

### WireGuard

```bash
# Generate keys
wg genkey | sudo tee /etc/wireguard/privatekey | wg pubkey | sudo tee /etc/wireguard/publickey

# Create config
sudo nano /etc/wireguard/wg0.conf

# Start VPN
sudo wg-quick up wg0

# Enable on boot
sudo systemctl enable wg-quick@wg0

# Check status
sudo wg show
```

### Tailscale

```bash
# Connect (opens browser for auth)
sudo tailscale up

# View connected devices
tailscale status

# Get your Tailscale IP
tailscale ip

# Tailscale SSH (enable in admin console first)
ssh user@device-name
```

**Tailscale SSH:** Enable in the Tailscale admin console. Uses Tailscale identity - no traditional SSH keys required.

## Remote Desktop Setup

### RustDesk

After installation, launch RustDesk from the application menu. Note your ID and set a password for remote access.

### TeamViewer

```bash
# Launch TeamViewer
teamviewer

# For unattended access:
# 1. Open TeamViewer
# 2. Go to Extras → Options → Security
# 3. Set personal password
# 4. Note your TeamViewer ID
```

### MeshCentral

MeshCentral agent connects to your MeshCentral server automatically after installation. Check your server's web interface - the device should appear in "My Devices".

To manually install/reinstall:
1. Log into your MeshCentral web interface
2. Go to "My Devices" → "Add Agent"
3. Download and run the Linux agent installer

## Docker Applications

Self-hosted applications are installed to `~/docker/{appname}/` with docker-compose.

### Managing Docker Apps

```bash
# Start an application
cd ~/docker/{appname}
docker compose up -d

# View logs
docker compose logs -f

# Stop an application
docker compose down

# Update an application
docker compose pull
docker compose up -d
```

### Application Ports

| Application | Port | URL |
|-------------|------|-----|
| Immich | 2283 | http://localhost:2283 |
| Audiobookshelf | 13378 | http://localhost:13378 |
| Emby | 8096 | http://localhost:8096 |
| Jellyfin | 8097 | http://localhost:8097 |
| A.R.M. | 8080 | http://localhost:8080 |
| Filebrowser | 8085 | http://localhost:8085 |
| Magic Mirror | 8081-8083 | http://localhost:808X |
| Lyrion (LMS) | 9000 | http://localhost:9000 |
| Mealie | 9925 | http://localhost:9925 |
| Minecraft | 25565 | localhost:25565 |
| Frigate | 5000 | http://localhost:5000 |
| Caddy | 80, 443 | http://localhost |
| ntfy | 8090 | http://localhost:8090 |
| Uptime Kuma | 3001 | http://localhost:3001 |
| wg-easy | 51821 | http://localhost:51821 |
| Traccar | 8082 | http://localhost:8082 |
| Portainer | 9443 | https://localhost:9443 |
| FindMyDevice | 8084 | http://localhost:8084 |
| MeshCentral Server | 4430 | https://localhost:4430 |

### Container Backup & Restore (Kopia)

Backup all Docker container data to your backup drives for disaster recovery.

**Run Container Backup:**
```bash
~/docker/kopia/backup-containers.sh
```

**Restore Containers (after OS drive failure):**
```bash
~/docker/kopia/restore-containers.sh
```

**What Gets Backed Up:**
- All container configs and databases
- Immich facial recognition data and memories
- Emby/Jellyfin metadata and watch history
- Minecraft worlds, mods, and permissions
- Mealie recipes, Audiobookshelf progress
- All application state and settings

**Kopia Repository Location:** Your backup drive(s) in `~/drives/backupX/container-backups/`

### Frigate + ntfy Notifications

If you installed Frigate, ntfy, and Frigate-Notify, they work together:

1. **Frigate** detects objects (person, car, etc.) on your cameras
2. **Frigate-Notify** monitors Frigate for events
3. **ntfy** sends push notifications to your phone

**Subscribe to alerts:**
```bash
# On your phone: Install ntfy app, add topic "frigate-alerts"
# Or visit: http://localhost:8090/frigate-alerts
```

**Customize alerts:** Edit `~/docker/frigate-notify/config.yml`
- Change which objects trigger alerts (person, car, dog, package)
- Set quiet hours for no notifications
- Add multiple notification services (Discord, Pushover, etc.)

### Caddy Reverse Proxy Network

To route traffic through Caddy, containers must be on the `caddy_net` network:

```yaml
# Add to any container's docker-compose.yml:
networks:
  default:
    name: caddy_net
    external: true
```

Then uncomment the service in `~/docker/caddy/Caddyfile`.

### Private Repository (linux-to-sync)

To clone a private GitHub repository, you need authentication:

**Option 1: SSH Key (Recommended)**
```bash
# Your SSH key must be added to GitHub
cat ~/.ssh/id_rsa.pub
# Add at: https://github.com/settings/keys
```

**Option 2: Personal Access Token**
```bash
# Create token at: https://github.com/settings/tokens/new
# Select 'repo' scope
```

## Samba File Sharing

If you chose to install Samba, it shares your **entire primary drive** via SMB/CIFS.

### Share Details

- **Share name**: Primary
- **Path**: `~/drives/primary`
- **Username**: Your system username
- **Password**: The Samba password you set during installation (suggested to match your system password)
- **Permissions**: Read/Write access for the configured user

### Accessing the Share

**From Windows:**
```
1. Open File Explorer
2. In the address bar, type:
   \\hostname\Primary
   Or use IP: \\192.168.1.100\Primary

3. Enter credentials when prompted:
   Username: your_username
   Password: your_samba_password
```

**From macOS:**
```
1. Open Finder
2. Press Cmd+K (or Go → Connect to Server)
3. Enter:
   smb://hostname/Primary
   Or: smb://192.168.1.100/Primary

4. Click Connect and enter credentials
```

**From Linux:**
```bash
# Browse in file manager
smb://hostname/Primary

# Or mount manually
sudo mkdir /mnt/primary-share
sudo mount -t cifs //hostname/Primary /mnt/primary-share -o username=your_username
```

### Find Your Hostname/IP

```bash
# Show hostname
hostname

# Show IP address
hostname -I
ip addr show
```

### Managing Samba

```bash
# Restart Samba
sudo systemctl restart smbd nmbd

# Check status
sudo systemctl status smbd

# View share configuration
sudo nano /etc/samba/smb.conf

# Change Samba password
sudo smbpasswd your_username

# Add additional users
sudo smbpasswd -a new_username
```

### Add Additional Shares

Edit `/etc/samba/smb.conf`:

```bash
sudo nano /etc/samba/smb.conf
```

Add new share:
```ini
[ShareName]
   comment = Description of share
   path = /path/to/share
   browseable = yes
   read only = no
   writable = yes
   valid users = username
   create mask = 0775
   directory mask = 0775
```

Restart Samba:
```bash
sudo systemctl restart smbd nmbd
```

### Troubleshooting Samba

**Can't connect to share:**
```bash
# Check if Samba is running
sudo systemctl status smbd

# Check firewall (if enabled)
sudo ufw allow samba

# Test configuration
testparm

# View active connections
sudo smbstatus
```

**Permission denied:**
```bash
# Check share permissions
ls -la ~/drives/primary

# Ensure Samba user exists
sudo pdbedit -L

# Reset Samba password
sudo smbpasswd your_username
```

## Troubleshooting

### View Installation Log

```bash
# Check what was installed and any errors
cat /var/log/post-install.log

# View last 50 lines
tail -50 /var/log/post-install.log
```

### Docker Permission Denied

```bash
# If you get "permission denied" after install
# Log out and back in for group membership to take effect
logout
```

### SSH Key Already Exists

If you see "key already exists" warning:
- Choose 'n' to keep existing key
- Or choose 'y' to overwrite (cannot be undone!)

### Drive Won't Mount

```bash
# Check if drive is recognized
lsblk -f

# Check filesystem
sudo fsck /dev/sdX1

# Try manual mount
sudo mount -t auto /dev/sdX1 ~/drives/primary
```

### Backup Script Fails

```bash
# Check if drives are mounted
df -h | grep drives

# Check log for errors
tail -50 /var/log/rclone-backup.log

# Verify directories exist on primary
ls -la ~/drives/primary/
```

### NetBird Won't Connect

```bash
# Check service status
sudo systemctl status netbird

# Restart service
sudo systemctl restart netbird

# Check logs
sudo journalctl -u netbird -f
```

### Samba Share Not Accessible

```bash
# Verify Samba is running
sudo systemctl status smbd

# Check share configuration
testparm

# View Samba users
sudo pdbedit -L

# Check if firewall is blocking
sudo ufw status
sudo ufw allow samba

# Restart Samba
sudo systemctl restart smbd nmbd
```

### fail2ban Issues

```bash
# Check if fail2ban is running
sudo systemctl status fail2ban

# View SSH jail status
sudo fail2ban-client status sshd

# Unban an IP address
sudo fail2ban-client set sshd unbanip 192.168.1.100

# Check fail2ban logs
sudo tail -50 /var/log/fail2ban.log
```

### UFW Firewall Issues

```bash
# Check UFW status
sudo ufw status verbose

# If locked out, disable UFW temporarily
sudo ufw disable

# Re-enable with SSH allowed first
sudo ufw allow ssh
sudo ufw enable

# List all rules with numbers
sudo ufw status numbered

# Delete a specific rule
sudo ufw delete 3
```

## Backup Strategy Summary

### Local Backup (rsync)
✓ Simple setup - just specify your drives
✓ Delta transfers - only changed bytes copied (fast incremental backups)
✓ Supports 1-4 backup drives with custom names
✓ Time to notice corruption before it propagates (unlike RAID)
✓ Backup drives can be disconnected for safety
✓ Easy restore - just rsync back

### Cloud Backup (rclone)
✓ Files encrypted locally before upload (cloud provider can't read them)
✓ Guided setup for Google Drive and OneDrive
✓ 40+ cloud providers supported
✓ Config automatically backed up to local drives
⚠️ Requires rclone.conf for decryption - keep it safe!

## Files Created by This Script

```
# Always created
/var/log/post-install.log                       # Installation log
/etc/ssh/sshd_config.backup                     # SSH config backup (if modified)
~/.ssh/id_rsa                                   # Private SSH key (if generated)
~/.ssh/id_rsa.pub                               # Public SSH key (if generated)
~/.ssh/authorized_keys                          # Imported SSH keys (if any)

# If fail2ban is installed
/etc/fail2ban/jail.local                        # fail2ban SSH jail configuration

# If Samba is installed
/etc/samba/smb.conf.backup-TIMESTAMP            # Samba config backup

# If local backup is set up
/usr/local/bin/backup-scripts/local-backup.sh   # Local rsync backup script
/etc/systemd/system/rsync-backup.service        # Systemd service
/etc/systemd/system/rsync-backup.timer          # Systemd timer (daily at 2 AM)
/var/log/rsync-backup.log                       # Backup log
/etc/fstab.backup-TIMESTAMP                     # fstab backup (if modified)
~/drives/{your-drive-names}/                    # Mount points (customizable names)

# If cloud backup is set up
/usr/local/bin/backup-scripts/cloud-backup.sh   # Cloud rclone backup script
~/.config/rclone/rclone.conf                    # rclone config (KEEP SAFE - has encryption keys!)
~/drives/*/rclone-config-backup/rclone.conf     # Config backed up to each local drive
```

## Security Notes

- **Private SSH key** (`~/.ssh/id_rsa`): Keep secret! Never share!
- **Public SSH key** (`~/.ssh/id_rsa.pub`): Safe to share
- **Password authentication**: Disabled if keys imported (more secure)
- **Docker group**: Equivalent to root access - only add trusted users
- **Samba password** (if installed): Stored separately from system password; change with `sudo smbpasswd username`
- **Samba shares** (if installed): Only accessible to configured users; ensure strong passwords
- **Network security** (if Samba installed): Samba shares are accessible to anyone on your local network who has credentials
- **rclone.conf** (if cloud backup enabled): Contains encryption keys - without it, cloud files cannot be decrypted. Back up securely off-site!
- **Backup drives** (if backup enabled): Consider encrypting sensitive data

## Support & Feedback

This script continues even if individual packages fail. Check the output for warnings or errors.

To report issues or improve the script:
- Review log files in `/var/log/`
- Check systemd service status
- Verify drive mounts with `df -h`

## License

This script is provided as-is for Ubuntu 24.04 Desktop installations.

## Changelog

- **v2.10**: Migration mode for existing Docker setups
  - New **Migration mode** - Import existing Docker containers from any directory
  - Auto-detects Docker directories and scans for compose files
  - Preserves container versions (no unwanted upgrades)
  - Whiptail checklist for selecting which containers to migrate
  - Option to stop containers for clean database copy
  - After migration, offers to install additional services
  - Three modes now: Normal install, Migration, Disaster Recovery
- **v2.9**: Immich photo library, Watchtower, recovery improvements
  - **Immich**: Now asks for photo storage location (default: `~/drives/primary/photos`)
  - **Immich**: External library support for existing photos (read-only, no duplication)
  - **Immich**: Storage template guidance for yyyy/mm folder organization
  - Added Watchtower for container update monitoring (notify-only by default)
  - Documented what Docker data lives where and what gets backed up
  - **Recovery**: Now installs Kopia during recovery (Step 1)
  - **Recovery**: Reconnects Kopia repository after restore (Step 9) for ongoing backups
- **v2.8**: MeshCentral Server and improved recovery
  - Added MeshCentral Server (self-hosted remote management, web-based RDP/terminal)
  - Recovery mode now installs core utilities first (openssh-server, git, curl, etc.)
  - Added whiptail checklist for service selection during restore (Ubuntu-server style)
  - Recovery supports restoring some/none/all services instead of all-or-nothing
- **v2.7**: Disaster recovery mode
  - **One-click restore** from Kopia backup after system failure
  - New `--restore` flag for disaster recovery mode
  - Interactive mode selector at script start: Normal install or Disaster recovery
  - Auto-detects Kopia repository on backup drives
  - Auto-detects and restores all backed-up Docker services
  - Installs Docker if needed, starts all containers after restore
  - Recovery flow: Mount drive → Find repo → Enter password → Select snapshot → Restore → Start
- **v2.6**: FindMyDevice, Frigate-Notify, and resilient install
  - Added FindMyDevice server (self-hosted Android tracking)
  - Added Frigate-Notify (push alerts for Frigate AI detections)
  - Caddy now asks for domain and creates comprehensive Caddyfile
  - **Resilient install pattern**: Install first, configure with defaults, continue on errors
  - All Docker apps now use "install → try config → use defaults if fail" approach
  - Config templates include clear "EDIT THIS FILE" warnings
  - Script won't stop if configuration prompts fail - uses sensible defaults
- **v2.5**: Additional Docker apps and container backup
  - Added Jellyfin (free media server with hardware acceleration)
  - Added Frigate NVR (AI-powered object detection)
  - Added Caddy (reverse proxy with automatic HTTPS)
  - Added ddclient (dynamic DNS updater)
  - Added ntfy (self-hosted push notifications)
  - Added Uptime Kuma (service monitoring)
  - Added wg-easy (WireGuard with web UI)
  - Added Traccar (GPS tracking server)
  - Added Portainer (Docker management UI)
  - Added Kopia backup for all Docker containers
  - Added container import/restore for disaster recovery
- **v2.4**: Self-hosted Docker applications
  - Added Immich (photo/video backup)
  - Added Audiobookshelf (audiobook server)
  - Added Emby (media server)
  - Added A.R.M. (automatic ripping machine)
  - Added Filebrowser (web file manager)
  - Added Magic Mirror (up to 3 instances)
  - Added Lyrion Music Server (LMS)
  - Added Mealie (recipe manager)
  - Added Minecraft Server (Fabric, RAM-limited)
  - Added linux-to-sync private repo setup
  - All apps use docker-compose in ~/docker/{appname}/
- **v2.3**: Additional VPN and remote desktop options
  - Added WireGuard VPN installation
  - Added Tailscale VPN installation (with Tailscale SSH info)
  - Added TeamViewer remote desktop installation
  - Added MeshCentral agent installation
  - Updated NetBird documentation to clarify SSH key management
- **v2.2**: Backup system overhaul
  - Local backups now use rsync exclusively (simpler, better for local drives)
  - Support for 1-4 backup drives with customizable names
  - Cloud backup added as separate option using rclone with encryption
  - Guided setup for Google Drive and OneDrive cloud backups
  - rclone.conf automatically backed up to all local drives
  - Added guidance for secure off-site config backup (Signal, Box.com, password managers)
  - Documentation: why rsync instead of RAID, why fail2ban with key-only SSH is unnecessary
- **v2.1**: QoL improvements
  - Added `--dry-run` flag to preview installations without changes
  - Added `--unattended` flag for automated/scripted installs
  - Added logging to `/var/log/post-install.log`
  - Added fail2ban (offered when SSH password auth is enabled)
  - Added UFW firewall configuration
  - All prompts support unattended mode with sensible defaults
- **v2.0**: Major update
  - Script is now rerunnable - detects existing installations
  - All components optional with y/n prompts (Docker, Samba, NetBird, RustDesk)
  - Backup system: choice of rsync or rclone
  - Backup modes: full (one drive) or split (two drives)
  - Shows current system status at start
- **v1.0**: Initial version
  - SSH (with key generation and import), Docker, Samba file sharing
  - NetBird, RustDesk, split-backup with rclone