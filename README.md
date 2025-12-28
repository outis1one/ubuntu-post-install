# Ubuntu 24.04 Desktop Post-Installation Script

Automated setup script for Ubuntu 24.04 Desktop that installs essential tools, configures SSH, sets up Docker, configures remote access, and creates a split-backup system using rclone.

## What This Script Does

### Core Utilities Installed
- **net-tools** - Network utilities (ifconfig, netstat)
- **ncdu** - Disk usage analyzer with ncurses interface
- **git** - Version control system
- **curl & wget** - Download tools
- **vim** - Text editor (instructions use nano)
- **htop** - Interactive process viewer
- **tree** - Directory structure visualizer
- **zip/unzip** - Archive utilities
- **rclone** - Sync tool for split backup strategy

### SSH Configuration
- **OpenSSH Server** - Enables remote SSH access
- **SSH Key Generation** - Creates 4096-bit RSA key pair for this computer
- **Key Import** - Optionally imports public keys from GitHub and/or Launchpad
- **Security** - Automatically disables password authentication if keys are imported

### Docker Installation
- **Docker Engine** - Latest version from official Docker repository (not snap)
- **Docker Compose** - Installed as a plugin (modern method)
- **User Configuration** - Adds your user to docker group (run docker without sudo)

### Samba File Sharing
- **Samba Server** - SMB/CIFS file server for network file sharing
- **Primary Drive Share** - Entire primary drive shared as "Primary"
- **User Configuration** - Creates Samba user matching your system username
- **Cross-Platform Access** - Works with Windows, Mac, and Linux

### Remote Access Tools
- **NetBird** - Mesh VPN for secure device connections
  - Supports both NetBird SSH and traditional SSH
  - Enables remote access across networks
- **RustDesk** - Open-source remote desktop software

### Backup System - Split Backup Strategy
- **Automated rclone backup script** using split-backup approach
- **Mount point management** at `~/drives/primary`, `~/drives/backup1`, `~/drives/backup2`
- **Interactive drive mounting** with automatic fstab configuration
- **Systemd timer** for scheduled daily backups (optional)

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

The script will ask you:
- **SSH Key Generation**: Generate new 4096-bit RSA key? (y/n)
- **Import SSH Keys**: GitHub username, Launchpad username (or leave blank)
- **Mount Drives**: Mount backup drives now? (y/n)
- **Drive Selection**: Device paths for primary, backup1, backup2 (e.g., /dev/sdb1)
- **fstab Configuration**: Add mounts to /etc/fstab for auto-mount? (y/n)
- **Samba Password**: Set password for Samba user (suggested: use same as system password)

### 5. Post-Installation Steps

**Required:**
```bash
# Log out and back in for docker group to take effect
logout
```

**Recommended:**
```bash
# Configure rclone backup (see Backup Configuration section)
sudo nano /usr/local/bin/backup-scripts/rclone-backup.sh
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

### Understanding Split Backup Strategy

**The Problem:**
- Your primary drive: 4TB
- Your backup drives: 2TB each
- Can't fit full primary on one backup drive

**The Solution:**
Divide your data between backup1 and backup2:
```
primary/work/    (500G)  → backup1/work/    ┐
primary/photos/  (800G)  → backup1/photos/  ├─ 1.3TB on backup1
                                             ┘
primary/videos/  (1.2T)  → backup2/videos/  ┐
primary/music/   (500G)  → backup2/music/   ├─ 1.7TB on backup2
                                             ┘
```

### Step-by-Step Backup Setup

#### 1. Check Your Folder Sizes

```bash
du -sh ~/drives/primary/*
```

Example output:
```
500G  primary/work
800G  primary/photos
1.2T  primary/videos
500G  primary/music
```

#### 2. Edit the Backup Script

```bash
sudo nano /usr/local/bin/backup-scripts/rclone-backup.sh
```

Find and edit these sections:

```bash
# Folders to backup to BACKUP1 only
BACKUP1_DIRS=(
    "work"        # 500G
    "photos"      # 800G
)
# Total: ~1.3TB

# Folders to backup to BACKUP2 only
BACKUP2_DIRS=(
    "videos"      # 1.2T
    "music"       # 500G
)
# Total: ~1.7TB
```

**Balance the data** so each backup drive has enough space.

#### 3. Test with Dry-Run (CRITICAL!)

```bash
# Test backup1 sync (shows what WOULD happen)
rclone sync ~/drives/primary/work ~/drives/backup1/work --checksum --dry-run -v

# Test backup2 sync
rclone sync ~/drives/primary/videos ~/drives/backup2/videos --checksum --dry-run -v
```

Review the output carefully!

#### 4. Run First Backup

```bash
sudo /usr/local/bin/backup-scripts/rclone-backup.sh
```

Monitor progress:
```bash
tail -f /var/log/rclone-backup.log
```

#### 5. Enable Automatic Backups (Optional)

After successful manual backup:
```bash
sudo systemctl enable rclone-backup.timer
sudo systemctl start rclone-backup.timer
```

Check status:
```bash
sudo systemctl status rclone-backup.timer
sudo systemctl list-timers
```

Change schedule (default: 2 AM daily):
```bash
sudo systemctl edit rclone-backup.timer
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

### If PRIMARY Drive Fails ⚠️ CRITICAL

You need **BOTH** backup drives to restore (data is split between them):

```bash
# 1. Get new drive (same size or larger)
# 2. Format it
sudo mkfs.ext4 /dev/sdX1

# 3. Mount as primary
sudo mount /dev/sdX1 ~/drives/primary

# 4. Restore from BOTH backups
rclone sync ~/drives/backup1/ ~/drives/primary/ --checksum
rclone sync ~/drives/backup2/ ~/drives/primary/ --checksum

# 5. Update /etc/fstab with new UUID
sudo blkid /dev/sdX1
sudo nano /etc/fstab
```

### If BACKUP Drive Fails

Example: backup1 fails (contained work/ and photos/ backups)

**Status:**
- ✓ Primary still has work/ and photos/ (original data is safe)
- ✓ backup2 still works (videos/ and music/ still backed up)
- ⚠️ work/ and photos/ have NO backup until backup1 is replaced

**Recovery:**
```bash
# 1. Replace the drive
# 2. Format it
sudo mkfs.ext4 /dev/sdX1

# 3. Mount it
sudo mount /dev/sdX1 ~/drives/backup1

# 4. Update /etc/fstab if needed
sudo nano /etc/fstab

# 5. Run backup script - syncs assigned folders back
sudo /usr/local/bin/backup-scripts/rclone-backup.sh
```

**⚠️ Replace failed backup drives quickly!** While a backup is down, those folders have no redundancy.

## Verification Commands

### Check Backups Match Primary

```bash
# Verify backup1 folders
rclone check ~/drives/primary/work ~/drives/backup1/work
rclone check ~/drives/primary/photos ~/drives/backup1/photos

# Verify backup2 folders
rclone check ~/drives/primary/videos ~/drives/backup2/videos
rclone check ~/drives/primary/music ~/drives/backup2/music
```

If perfect: "0 differences found"

### Check Space Usage

```bash
# See what's on each drive
du -sh ~/drives/primary/*
du -sh ~/drives/backup1/*
du -sh ~/drives/backup2/*

# Check free space
df -h ~/drives/primary
df -h ~/drives/backup1
df -h ~/drives/backup2
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

The script automatically shares your **entire primary drive** via Samba.

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

## Split Backup Advantages & Disadvantages

### ✓ Advantages
- **Budget-friendly**: 4TB primary = 2TB backup1 + 2TB backup2 (saves money)
- **Simpler than RAID**: No complex RAID setup or rebuild process
- **Easy recovery**: Mount points stay the same, just swap drives
- **No downtime**: Replace drives one at a time
- **Flexible**: Easily rebalance folders between drives

### ⚠️ Disadvantages
- **Split redundancy**: Each folder backed up to ONE drive only (not both)
- **Two-drive restore**: Need BOTH backups to fully restore primary
- **Urgent replacement**: Failed backup leaves some folders without redundancy
- **Manual balancing**: You must divide folders between drives yourself

## Files Created by This Script

```
/usr/local/bin/backup-scripts/rclone-backup.sh  # Backup script
/etc/systemd/system/rclone-backup.service       # Systemd service
/etc/systemd/system/rclone-backup.timer         # Systemd timer
/var/log/rclone-backup.log                      # Backup log
/etc/fstab.backup-TIMESTAMP                     # fstab backup (if modified)
/etc/ssh/sshd_config.backup                     # SSH config backup (if modified)
/etc/samba/smb.conf.backup-TIMESTAMP            # Samba config backup
~/drives/primary/                               # Primary mount point (shared via Samba)
~/drives/backup1/                               # Backup1 mount point
~/drives/backup2/                               # Backup2 mount point
~/.ssh/id_rsa                                   # Private SSH key (if generated)
~/.ssh/id_rsa.pub                               # Public SSH key (if generated)
~/.ssh/authorized_keys                          # Imported SSH keys (if any)
```

## Security Notes

- **Private SSH key** (`~/.ssh/id_rsa`): Keep secret! Never share!
- **Public SSH key** (`~/.ssh/id_rsa.pub`): Safe to share
- **Password authentication**: Disabled if keys imported (more secure)
- **Docker group**: Equivalent to root access - only add trusted users
- **Samba password**: Stored separately from system password; change with `sudo smbpasswd username`
- **Samba shares**: Only accessible to configured users; ensure strong passwords
- **Network security**: Samba shares are accessible to anyone on your local network who has credentials
- **Backup drives**: Consider encrypting sensitive data

## Support & Feedback

This script continues even if individual packages fail. Check the output for warnings or errors.

To report issues or improve the script:
- Review log files in `/var/log/`
- Check systemd service status
- Verify drive mounts with `df -h`

## License

This script is provided as-is for Ubuntu 24.04 Desktop installations.

## Changelog

- Initial version: Ubuntu 24.04 Desktop post-installation automation
- Features: SSH (with key generation and import), Docker, Samba file sharing, NetBird, RustDesk, split-backup with rclone