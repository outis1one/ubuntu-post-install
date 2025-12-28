# Ubuntu 24.04 Desktop Post-Installation Script

Automated setup script for Ubuntu 24.04 Desktop that installs essential tools, configures SSH, and optionally sets up Docker, Samba file sharing, remote access tools (NetBird, RustDesk), and an automated backup system.

**Key Features:**
- **Rerunnable** - Detects existing installations and offers to reinstall/reconfigure
- **Modular** - Every component is optional with y/n prompts
- **Backup options** - Choose rsync (faster, local) or rclone (cloud support)
- **Backup modes** - Full backup (one drive) or split backup (two drives)

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

### Remote Access Tools (Optional)
- **NetBird** - Mesh VPN for secure device connections
  - Supports both NetBird SSH and traditional SSH
  - Enables remote access across networks
  - Detects if already installed
- **RustDesk** - Open-source remote desktop software
  - Detects if already installed

### Backup System (Optional)
Choose your backup tool and mode:

**Backup Tools:**
- **rsync** (recommended for local drives)
  - Delta transfers - only changed bytes are copied
  - Faster incremental backups
  - Built into most Linux systems
- **rclone** (better for cloud storage)
  - Supports 40+ cloud providers (S3, Google Drive, Dropbox...)
  - File-level sync

**Backup Modes:**
- **Full** - Mirror entire primary to one backup drive (simpler)
- **Split** - Divide data between two smaller backup drives (budget-friendly)

**Features:**
- Mount point management at `~/drives/`
- Interactive drive mounting with automatic fstab configuration
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

### 4. Follow Interactive Prompts

The script shows current system status and asks:
- **SSH Key Generation**: Generate new 4096-bit RSA key? (y/n)
- **Import SSH Keys**: GitHub username, Launchpad username (or leave blank)
- **Docker**: Install Docker? (y/n) - or reinstall if detected
- **Samba File Sharing**: Install and configure Samba? (y/n)
  - If yes: Set password for Samba user
- **NetBird**: Install NetBird mesh VPN? (y/n)
- **RustDesk**: Install RustDesk remote desktop? (y/n)
- **Backup System**: Set up backup system? (y/n)
  - If yes: Choose tool (rsync/rclone), mode (full/split)
  - Mount drives now? Device paths, fstab configuration

### 5. Post-Installation Steps

**Required:**
```bash
# Log out and back in for docker group to take effect
logout
```

**If you enabled backup system (split mode):**
```bash
# Configure backup script to set which folders go to which drive
sudo nano /usr/local/bin/backup-scripts/rsync-backup.sh  # or rclone-backup.sh
```

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

### rsync vs rclone

| Feature | rsync | rclone |
|---------|-------|--------|
| **Best for** | Local drives | Cloud storage |
| **Transfer method** | Delta (byte-level) | File-level |
| **Speed** | Faster for incremental | Slower for local |
| **Cloud support** | SSH only | 40+ providers |

**Recommendation:** Use rsync for local drive backups, rclone for cloud backups.

### Full vs Split Backup Mode

**Full Backup:**
- Mirrors entire primary → backup1
- Requires: backup drive ≥ primary drive
- Example: 4TB primary → 4TB+ backup

**Split Backup:**
- Divides folders between backup1 and backup2
- Useful when: Primary > each backup drive
- Example: 4TB primary → 2TB backup1 + 2TB backup2

```
# Split backup example:
primary/work/    (500G)  → backup1/work/    ┐
primary/photos/  (800G)  → backup1/photos/  ├─ 1.3TB on backup1
                                             ┘
primary/videos/  (1.2T)  → backup2/videos/  ┐
primary/music/   (500G)  → backup2/music/   ├─ 1.7TB on backup2
                                             ┘
```

### Step-by-Step Backup Setup

Replace `{tool}` with your chosen tool (rsync or rclone).

#### 1. Check Your Folder Sizes (for split mode)

```bash
du -sh ~/drives/primary/*
```

#### 2. Edit the Backup Script (split mode only)

```bash
sudo nano /usr/local/bin/backup-scripts/{tool}-backup.sh
```

Configure which folders go to which backup drive:

```bash
# Folders to backup to BACKUP1 only
BACKUP1_DIRS=(
    "work"
    "photos"
)

# Folders to backup to BACKUP2 only
BACKUP2_DIRS=(
    "videos"
    "music"
)
```

#### 3. Run First Backup

```bash
sudo /usr/local/bin/backup-scripts/{tool}-backup.sh
```

Monitor progress:
```bash
tail -f /var/log/{tool}-backup.log
```

#### 4. Enable Automatic Backups (Optional)

```bash
sudo systemctl enable {tool}-backup.timer
sudo systemctl start {tool}-backup.timer

# Check status
sudo systemctl status {tool}-backup.timer
sudo systemctl list-timers
```

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

## NetBird Setup

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

## Backup Mode Comparison

### Full Backup
✓ Simpler setup - no folder configuration needed
✓ Single backup drive to manage
✓ Easy restore - just copy everything back
⚠️ Requires backup drive ≥ primary size

### Split Backup
✓ Budget-friendly - use two smaller drives
✓ No RAID complexity
✓ Flexible - rebalance folders anytime
⚠️ Manual folder configuration required
⚠️ Need BOTH backup drives to fully restore
⚠️ Failed backup = some folders without redundancy

## Files Created by This Script

```
# Always created
/etc/ssh/sshd_config.backup                     # SSH config backup (if modified)
~/.ssh/id_rsa                                   # Private SSH key (if generated)
~/.ssh/id_rsa.pub                               # Public SSH key (if generated)
~/.ssh/authorized_keys                          # Imported SSH keys (if any)

# If Samba is installed
/etc/samba/smb.conf.backup-TIMESTAMP            # Samba config backup

# If backup system is set up (rsync or rclone)
/usr/local/bin/backup-scripts/{tool}-backup.sh  # Backup script
/etc/systemd/system/{tool}-backup.service       # Systemd service
/etc/systemd/system/{tool}-backup.timer         # Systemd timer
/var/log/{tool}-backup.log                      # Backup log
/etc/fstab.backup-TIMESTAMP                     # fstab backup (if modified)
~/drives/primary/                               # Primary mount point
~/drives/backup1/                               # Backup1 mount point
~/drives/backup2/                               # Backup2 mount point (split mode only)
```

## Security Notes

- **Private SSH key** (`~/.ssh/id_rsa`): Keep secret! Never share!
- **Public SSH key** (`~/.ssh/id_rsa.pub`): Safe to share
- **Password authentication**: Disabled if keys imported (more secure)
- **Docker group**: Equivalent to root access - only add trusted users
- **Samba password** (if installed): Stored separately from system password; change with `sudo smbpasswd username`
- **Samba shares** (if installed): Only accessible to configured users; ensure strong passwords
- **Network security** (if Samba installed): Samba shares are accessible to anyone on your local network who has credentials
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

- **v2.0**: Major update
  - Script is now rerunnable - detects existing installations
  - All components optional with y/n prompts (Docker, Samba, NetBird, RustDesk)
  - Backup system: choice of rsync or rclone
  - Backup modes: full (one drive) or split (two drives)
  - Shows current system status at start
- **v1.0**: Initial version
  - SSH (with key generation and import), Docker, Samba file sharing
  - NetBird, RustDesk, split-backup with rclone