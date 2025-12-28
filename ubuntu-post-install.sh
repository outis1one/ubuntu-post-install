#!/bin/bash

# Ubuntu 24.04 Post-Installation Script
# Run with: sudo bash post-install.sh

echo "=== Ubuntu 24.04 Post-Installation Script ==="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run as root (use sudo)"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

echo "Note: Script will continue even if individual packages fail to install"
echo ""

# Update package list
echo "Updating package lists..."
apt update

# Install basic utilities
echo ""
echo "Installing basic utilities..."
echo "  - net-tools: Network configuration tools (ifconfig, netstat, etc.)"
echo "  - ncdu: Disk usage analyzer with ncurses interface"
echo "  - git: Version control system"
echo "  - curl: Command-line tool for transferring data with URLs"
echo "  - wget: Network downloader"
echo "  - vim: Advanced text editor"
echo "  - htop: Interactive process viewer"
echo "  - tree: Display directory structure in tree format"
echo "  - zip/unzip: Archive compression utilities"
echo "  - rclone: Rsync for cloud storage and local drives (backup tool)"
echo ""

apt install -y \
    net-tools \
    ncdu \
    git \
    curl \
    wget \
    vim \
    htop \
    tree \
    zip \
    unzip \
    rclone || echo "Warning: Some utilities failed to install, continuing..."

# Install OpenSSH Server
echo ""
echo "Installing OpenSSH Server..."
echo "  - openssh-server: SSH server for remote access"
echo ""

apt install -y openssh-server || echo "Warning: OpenSSH server installation failed, continuing..."

# Start and enable SSH service
systemctl start ssh || echo "Warning: Failed to start SSH"
systemctl enable ssh || echo "Warning: Failed to enable SSH"

# Generate SSH key for this computer
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SSH KEY GENERATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Generate a new SSH key for this computer? (y/n): " GENERATE_KEY

if [ "$GENERATE_KEY" = "y" ] || [ "$GENERATE_KEY" = "Y" ]; then
    echo ""
    read -p "Enter a label/comment for the key (e.g., email or hostname) [default: $ACTUAL_USER@$(hostname)]: " KEY_COMMENT
    
    if [ -z "$KEY_COMMENT" ]; then
        KEY_COMMENT="$ACTUAL_USER@$(hostname)"
    fi
    
    # Check if key already exists
    if [ -f "$ACTUAL_HOME/.ssh/id_rsa" ]; then
        echo ""
        echo "⚠️  WARNING: SSH key already exists at $ACTUAL_HOME/.ssh/id_rsa"
        read -p "Overwrite existing key? This cannot be undone! (y/n): " OVERWRITE_KEY
        
        if [ "$OVERWRITE_KEY" != "y" ] && [ "$OVERWRITE_KEY" != "Y" ]; then
            echo "Skipping key generation."
            GENERATE_KEY="n"
        fi
    fi
    
    if [ "$GENERATE_KEY" = "y" ] || [ "$GENERATE_KEY" = "Y" ]; then
        echo ""
        echo "Generating 4096-bit RSA key pair..."
        echo "This may take a moment..."
        
        # Generate key as the actual user, not root
        sudo -u "$ACTUAL_USER" ssh-keygen -t rsa -b 4096 -C "$KEY_COMMENT" -f "$ACTUAL_HOME/.ssh/id_rsa" -N ""
        
        if [ $? -eq 0 ]; then
            echo ""
            echo "✓ SSH key generated successfully!"
            echo ""
            echo "Private key: $ACTUAL_HOME/.ssh/id_rsa (keep this secret!)"
            echo "Public key:  $ACTUAL_HOME/.ssh/id_rsa.pub"
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Your PUBLIC key (safe to share):"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            cat "$ACTUAL_HOME/.ssh/id_rsa.pub"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "To use this key:"
            echo "  • Add to GitHub: Settings → SSH and GPG keys → New SSH key"
            echo "  • Add to servers: Copy above key to remote ~/.ssh/authorized_keys"
            echo "  • View anytime: cat ~/.ssh/id_rsa.pub"
            echo ""
        else
            echo "✗ Failed to generate SSH key"
        fi
    fi
else
    echo "Skipping SSH key generation."
fi

# Import SSH keys from GitHub/Launchpad
echo ""
read -p "Import SSH keys from GitHub? (enter username or leave blank to skip): " GITHUB_USER
read -p "Import SSH keys from Launchpad? (enter username or leave blank to skip): " LAUNCHPAD_USER

KEYS_IMPORTED=false

# Create .ssh directory if it doesn't exist
mkdir -p "$ACTUAL_HOME/.ssh"
touch "$ACTUAL_HOME/.ssh/authorized_keys"
chmod 700 "$ACTUAL_HOME/.ssh"
chmod 600 "$ACTUAL_HOME/.ssh/authorized_keys"

if [ -n "$GITHUB_USER" ]; then
    echo "Importing SSH keys from GitHub user: $GITHUB_USER"
    if curl -fsSL "https://github.com/$GITHUB_USER.keys" >> "$ACTUAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "✓ GitHub keys imported successfully"
        KEYS_IMPORTED=true
    else
        echo "✗ Failed to import GitHub keys"
    fi
fi

if [ -n "$LAUNCHPAD_USER" ]; then
    echo "Importing SSH keys from Launchpad user: $LAUNCHPAD_USER"
    if curl -fsSL "https://launchpad.net/~$LAUNCHPAD_USER/+sshkeys" >> "$ACTUAL_HOME/.ssh/authorized_keys" 2>/dev/null; then
        echo "✓ Launchpad keys imported successfully"
        KEYS_IMPORTED=true
    else
        echo "✗ Failed to import Launchpad keys"
    fi
fi

# Fix ownership
chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/.ssh"

# Disable password authentication if keys were imported
if [ "$KEYS_IMPORTED" = true ]; then
    echo ""
    echo "SSH keys imported. Disabling password authentication..."
    
    # Backup sshd_config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    # Disable password authentication
    sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication no/PasswordAuthentication no/' /etc/ssh/sshd_config
    
    # Ensure these settings are also set
    grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
    
    # Restart SSH service to apply changes
    systemctl restart ssh
    
    echo "✓ Password authentication disabled. SSH key authentication required."
    echo "✓ Backup saved to /etc/ssh/sshd_config.backup"
else
    echo ""
    echo "No SSH keys imported. Password authentication remains enabled."
fi


# Install Docker prerequisites
echo ""
echo "Installing Docker prerequisites..."
echo "  - ca-certificates: SSL/TLS certificates for secure connections"
echo "  - gnupg: GNU Privacy Guard for package verification"
echo "  - lsb-release: Provides Ubuntu version information"
echo ""

apt install -y \
    ca-certificates \
    gnupg \
    lsb-release || echo "Warning: Some prerequisites failed to install, continuing..."

# Install Docker
echo ""
echo "Installing Docker..."
echo "  - Docker Engine: Container runtime platform"
echo "  - Docker Compose: Multi-container application orchestration"
echo ""

# Remove old Docker packages if they exist
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# Add Docker's official GPG key
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package list with Docker repo
apt update

# Install Docker Engine, CLI, containerd, and Docker Compose plugin
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || echo "Warning: Docker installation failed, continuing..."

# Start and enable Docker service
systemctl start docker || echo "Warning: Failed to start Docker"
systemctl enable docker || echo "Warning: Failed to enable Docker"

# Add current user to docker group (if not root)
if [ -n "$SUDO_USER" ]; then
    usermod -aG docker "$SUDO_USER"
    echo "User $SUDO_USER added to docker group"
fi

# Verify Docker installation
echo ""
echo "Verifying Docker installation..."
docker --version || echo "Warning: Docker verification failed"
docker compose version || echo "Warning: Docker Compose verification failed"

# Samba File Sharing (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SAMBA FILE SHARING (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Samba allows you to share folders over the network to Windows, Mac, and Linux."
echo "The script will share your primary drive at ~/drives/primary"
echo ""
read -p "Install and configure Samba file sharing? (y/n): " INSTALL_SAMBA

if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo ""
    echo "Installing Samba file sharing..."
    echo "  - Samba: SMB/CIFS file server for network file sharing"
    echo ""

    apt install -y samba || echo "Warning: Samba installation failed, continuing..."

    # Configure Samba share for primary drive
    if command -v smbd &> /dev/null; then
        echo ""
        echo "Configuring Samba share for primary drive..."

        # Backup existing config
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup-$(date +%Y%m%d-%H%M%S)

        # Add Primary share configuration
        if ! grep -q "\[Primary\]" /etc/samba/smb.conf; then
            cat >> /etc/samba/smb.conf << SAMBA_CONFIG

# Primary drive share - added by post-install script
[Primary]
   comment = Primary Drive
   path = $ACTUAL_HOME/drives/primary
   browseable = yes
   read only = no
   writable = yes
   valid users = $ACTUAL_USER
   create mask = 0775
   directory mask = 0775
SAMBA_CONFIG
            echo "✓ Added [Primary] share to Samba configuration"
        else
            echo "Samba [Primary] share already configured, skipping..."
        fi

        # Add Samba user
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "SAMBA PASSWORD SETUP"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Set a password for Samba file sharing access."
        echo "Tip: Using the same password as your system login is convenient."
        echo ""
        smbpasswd -a "$ACTUAL_USER"

        # Enable and restart Samba services
        systemctl enable smbd nmbd || echo "Warning: Failed to enable Samba services"
        systemctl restart smbd nmbd || echo "Warning: Failed to restart Samba services"

        echo ""
        echo "✓ Samba configured successfully"
        echo "  Share name: Primary"
        echo "  Path: $ACTUAL_HOME/drives/primary"
        echo "  Access: \\\\$(hostname)\\Primary (Windows) or smb://$(hostname)/Primary (Mac/Linux)"
    else
        echo "✗ Samba installation failed, skipping configuration"
    fi
else
    echo "Skipping Samba installation."
fi

# Install NetBird
echo ""
echo "Installing NetBird..."
echo "  - NetBird: Secure mesh VPN for connecting devices"
echo ""

curl -fsSL https://pkgs.netbird.io/install.sh | sh || echo "Warning: NetBird installation failed, continuing..."

echo ""
echo "NetBird installed. Setup instructions:"
echo "  1. Create account at https://app.netbird.io (or self-host)"
echo "  2. Run 'netbird up' and authenticate via browser"
echo ""
echo "For NetBird SSH functionality:"
echo "  • Enable SSH in NetBird dashboard settings"
echo "  • Use 'netbird ssh <peer-name>' to connect to peers"
echo "  • NetBird manages SSH keys automatically when using 'netbird ssh'"
echo "  • Traditional SSH also works using peer IPs from 'netbird status'"
echo "  • Configure ACL rules in dashboard for SSH access (port 22)"
echo ""

# Install RustDesk
echo ""
echo "Installing RustDesk..."
echo "  - RustDesk: Open-source remote desktop software"
echo ""

# Download latest RustDesk .deb package
RUSTDESK_VERSION=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
RUSTDESK_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.deb"

wget -O /tmp/rustdesk.deb "$RUSTDESK_URL" || echo "Warning: RustDesk download failed, continuing..."

if [ -f /tmp/rustdesk.deb ]; then
    apt install -y /tmp/rustdesk.deb || echo "Warning: RustDesk installation failed, continuing..."
    rm /tmp/rustdesk.deb
fi

# Rclone Split Backup System (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RCLONE SPLIT BACKUP SYSTEM (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This sets up a split backup system using rclone:"
echo "  - Creates mount points for primary + 2 backup drives"
echo "  - Installs backup script that splits data across backup drives"
echo "  - Optionally configures automatic daily backups"
echo ""
echo "Useful when: Primary drive (e.g., 4TB) > individual backup drives (e.g., 2TB each)"
echo ""
read -p "Set up rclone split backup system? (y/n): " SETUP_BACKUP

if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo ""
    echo "Setting up rclone backup configuration..."
    echo ""

    # Create backup script directory
    mkdir -p /usr/local/bin/backup-scripts

    # Create mount point directories
    echo ""
    echo "Creating mount point directories in $ACTUAL_HOME/drives/..."
    mkdir -p "$ACTUAL_HOME/drives/primary"
    mkdir -p "$ACTUAL_HOME/drives/backup1"
    mkdir -p "$ACTUAL_HOME/drives/backup2"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/drives"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DRIVE SETUP - Mount your drives"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Available block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
    echo ""

    read -p "Do you want to mount drives now? (y/n): " MOUNT_NOW

    if [ "$MOUNT_NOW" = "y" ] || [ "$MOUNT_NOW" = "Y" ]; then
        echo ""
        echo "Enter device paths (e.g., /dev/sdb1) or leave blank to skip"
        echo ""

        read -p "Primary drive device (e.g., /dev/sdb1): " PRIMARY_DEV
        read -p "Backup1 drive device (e.g., /dev/sdc1): " BACKUP1_DEV
        read -p "Backup2 drive device (e.g., /dev/sdd1): " BACKUP2_DEV

        # Mount primary
        if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
            echo "Mounting $PRIMARY_DEV to $ACTUAL_HOME/drives/primary..."
            mount "$PRIMARY_DEV" "$ACTUAL_HOME/drives/primary" && echo "✓ Primary mounted" || echo "✗ Failed to mount primary"
        fi

        # Mount backup1
        if [ -n "$BACKUP1_DEV" ] && [ -b "$BACKUP1_DEV" ]; then
            echo "Mounting $BACKUP1_DEV to $ACTUAL_HOME/drives/backup1..."
            mount "$BACKUP1_DEV" "$ACTUAL_HOME/drives/backup1" && echo "✓ Backup1 mounted" || echo "✗ Failed to mount backup1"
        fi

        # Mount backup2
        if [ -n "$BACKUP2_DEV" ] && [ -b "$BACKUP2_DEV" ]; then
            echo "Mounting $BACKUP2_DEV to $ACTUAL_HOME/drives/backup2..."
            mount "$BACKUP2_DEV" "$ACTUAL_HOME/drives/backup2" && echo "✓ Backup2 mounted" || echo "✗ Failed to mount backup2"
        fi

        echo ""
        echo "Current mounts:"
        df -h | grep "$ACTUAL_HOME/drives"

        echo ""
        read -p "Add these mounts to /etc/fstab for automatic mounting at boot? (y/n): " ADD_FSTAB

        if [ "$ADD_FSTAB" = "y" ] || [ "$ADD_FSTAB" = "Y" ]; then
            echo ""
            echo "Adding entries to /etc/fstab..."
            cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S)

            if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
                PRIMARY_UUID=$(blkid -s UUID -o value "$PRIMARY_DEV")
                if [ -n "$PRIMARY_UUID" ]; then
                    echo "UUID=$PRIMARY_UUID $ACTUAL_HOME/drives/primary auto defaults 0 2" >> /etc/fstab
                    echo "✓ Added primary to fstab"
                fi
            fi

            if [ -n "$BACKUP1_DEV" ] && [ -b "$BACKUP1_DEV" ]; then
                BACKUP1_UUID=$(blkid -s UUID -o value "$BACKUP1_DEV")
                if [ -n "$BACKUP1_UUID" ]; then
                    echo "UUID=$BACKUP1_UUID $ACTUAL_HOME/drives/backup1 auto defaults 0 2" >> /etc/fstab
                    echo "✓ Added backup1 to fstab"
                fi
            fi

            if [ -n "$BACKUP2_DEV" ] && [ -b "$BACKUP2_DEV" ]; then
                BACKUP2_UUID=$(blkid -s UUID -o value "$BACKUP2_DEV")
                if [ -n "$BACKUP2_UUID" ]; then
                    echo "UUID=$BACKUP2_UUID $ACTUAL_HOME/drives/backup2 auto defaults 0 2" >> /etc/fstab
                    echo "✓ Added backup2 to fstab"
                fi
            fi

            echo "✓ Backup of original fstab saved with timestamp"
        fi
    else
        echo ""
        echo "Skipping drive mounting. You can mount manually later."
        echo "Mount points created at:"
        echo "  $ACTUAL_HOME/drives/primary"
        echo "  $ACTUAL_HOME/drives/backup1"
        echo "  $ACTUAL_HOME/drives/backup2"
    fi

    # Create example backup script with correct paths
    cat > /usr/local/bin/backup-scripts/rclone-backup.sh << BACKUP_SCRIPT
#!/bin/bash

################################################################################
# Rclone SPLIT Backup Script - Divide data between multiple backup drives
################################################################################
#
# RCLONE TERMINOLOGY:
#   SOURCE (PRIMARY)      = Where your data currently lives
#   DESTINATION (BACKUP)  = Where you want exact copies stored
#
# SPLIT BACKUP STRATEGY:
#   This script splits your primary data between backup1 and backup2
#   Perfect for when: Primary is 4TB, Backup1 is 2TB, Backup2 is 2TB
#
# Example:
#   primary/work/         → backup1/work/        (backup1 only)
#   primary/photos/       → backup1/photos/      (backup1 only)
#   primary/videos/       → backup2/videos/      (backup2 only)
#   primary/music/        → backup2/music/       (backup2 only)
#
################################################################################

# ┌────────────────────────────────────────────────────────────────────┐
# │ CONFIGURE THESE PATHS                                              │
# └────────────────────────────────────────────────────────────────────┘

# SOURCE: Primary drive (where your data lives)
PRIMARY="$ACTUAL_HOME/drives/primary"

# DESTINATIONS: Backup drives (where copies will be stored)
BACKUP1="$ACTUAL_HOME/drives/backup1"
BACKUP2="$ACTUAL_HOME/drives/backup2"

# ┌────────────────────────────────────────────────────────────────────┐
# │ ⚠️  CRITICAL: CONFIGURE WHICH FOLDERS GO TO WHICH BACKUP DRIVE! ⚠️ │
# └────────────────────────────────────────────────────────────────────┘
#
# List folder names that exist in PRIMARY and assign them to backup drives.
# Balance the data so each backup drive has roughly equal capacity used.
#
# Example setup (adjust to match YOUR actual folders):

# Folders to backup to BACKUP1 only
BACKUP1_DIRS=(
    "documents"
    "work"
    "photos"
)

# Folders to backup to BACKUP2 only
BACKUP2_DIRS=(
    "videos"
    "music"
    "downloads"
)

# ┌────────────────────────────────────────────────────────────────────┐
# │ HOW TO BALANCE YOUR DATA:                                          │
# └────────────────────────────────────────────────────────────────────┘
#
# 1. Check size of each folder on PRIMARY:
#    du -sh $ACTUAL_HOME/drives/primary/*
#
# 2. Divide folders between BACKUP1_DIRS and BACKUP2_DIRS so the total
#    size in each list fits on the respective backup drive
#
# Example output from du -sh:
#   500G  primary/work
#   800G  primary/photos
#   1.2T  primary/videos
#   500G  primary/music
#
# Split strategy (for 2TB backup drives):
#   BACKUP1_DIRS: work (500G) + photos (800G) = 1.3TB → fits on 2TB drive
#   BACKUP2_DIRS: videos (1.2T) + music (500G) = 1.7TB → fits on 2TB drive
#

################################################################################
# Script logic below - you shouldn't need to edit anything below this line
################################################################################

# Log file
LOG="/var/log/rclone-backup.log"

echo "=== Rclone SPLIT Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "SOURCE (Primary): \$PRIMARY" | tee -a "\$LOG"
echo "Strategy: Split data between backup drives" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

# Function to backup specific directories to a destination
backup_to_drive() {
    local dest=\$1
    local drive_name=\$2
    shift 2
    local dirs_array=("\$@")
    
    if [ ! -d "\$dest" ]; then
        echo "⚠️  WARNING: \$drive_name (\$dest) not mounted, skipping" | tee -a "\$LOG"
        return 1
    fi
    
    if [ \${#dirs_array[@]} -eq 0 ]; then
        echo "⚠️  WARNING: No directories assigned to \$drive_name, skipping" | tee -a "\$LOG"
        return 1
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "\$LOG"
    echo "DESTINATION: \$drive_name (\$dest)" | tee -a "\$LOG"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "\$LOG"
    
    for dir in "\${dirs_array[@]}"; do
        if [ ! -d "\$PRIMARY/\$dir" ]; then
            echo "  ⚠️  WARNING: \$PRIMARY/\$dir does not exist, skipping" | tee -a "\$LOG"
            continue
        fi
        
        echo "" | tee -a "\$LOG"
        echo "  Syncing: \$dir" | tee -a "\$LOG"
        echo "    FROM: \$PRIMARY/\$dir" | tee -a "\$LOG"
        echo "    TO:   \$dest/\$dir" | tee -a "\$LOG"
        
        # Use rclone sync for exact mirroring
        # SOURCE -> DESTINATION (one-way)
        # --checksum: verify with checksums (slower but accurate)
        # --verbose: show what's being copied
        # --progress: show progress
        # --delete-during: delete files from dest that don't exist in source
        
        rclone sync "\$PRIMARY/\$dir" "\$dest/\$dir" \\
            --checksum \\
            --verbose \\
            --progress \\
            --log-file="\$LOG" \\
            --stats=30s
            
        if [ \$? -eq 0 ]; then
            echo "  ✓ \$dir synced successfully to \$drive_name" | tee -a "\$LOG"
        else
            echo "  ✗ \$dir sync to \$drive_name FAILED" | tee -a "\$LOG"
        fi
    done
    echo "" | tee -a "\$LOG"
}

# Sync to backup drives with their assigned directories
backup_to_drive "\$BACKUP1" "Backup Drive 1" "\${BACKUP1_DIRS[@]}"
backup_to_drive "\$BACKUP2" "Backup Drive 2" "\${BACKUP2_DIRS[@]}"

echo "=== Backup Completed: \$(date) ===" | tee -a "\$LOG"
BACKUP_SCRIPT

    chmod +x /usr/local/bin/backup-scripts/rclone-backup.sh

    # Create systemd service for automatic backups (optional)
    cat > /etc/systemd/system/rclone-backup.service << 'SERVICE'
[Unit]
Description=Rclone Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-scripts/rclone-backup.sh
User=root
SERVICE

    # Create systemd timer for daily backups at 2 AM (optional)
    cat > /etc/systemd/system/rclone-backup.timer << 'TIMER'
[Unit]
Description=Daily Rclone Backup Timer
Requires=rclone-backup.service

[Timer]
OnCalendar=daily
OnCalendar=02:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    echo "✓ Rclone backup script created at /usr/local/bin/backup-scripts/rclone-backup.sh"
    echo "✓ Systemd service/timer created (disabled by default)"
else
    echo "Skipping rclone backup system setup."
fi

# Full system upgrade
echo ""
echo "Performing full system upgrade..."
apt upgrade -y

# Clean up
echo ""
echo "Cleaning up..."
apt autoremove -y
apt autoclean

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Installed Software:"
echo "  ✓ net-tools, ncdu, git, curl, wget, vim, htop, tree, zip/unzip, rclone"
echo "  ✓ OpenSSH Server - SSH remote access"
echo "  ✓ Docker Engine + Docker Compose"
if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo "  ✓ Samba - File sharing (Primary drive shared)"
fi
echo "  ✓ NetBird - Mesh VPN"
echo "  ✓ RustDesk - Remote desktop"
if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo "  ✓ Rclone split backup system configured"
fi
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SSH AUTHENTICATION SETUP"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  SSH Key for This Computer:"
if [ "$GENERATE_KEY" = "y" ] || [ "$GENERATE_KEY" = "Y" ]; then
    if [ -f "$ACTUAL_HOME/.ssh/id_rsa.pub" ]; then
echo "    ✓ 4096-bit RSA key generated"
echo "    Public key: $ACTUAL_HOME/.ssh/id_rsa.pub"
echo "    View with: cat ~/.ssh/id_rsa.pub"
    else
echo "    ✗ Key generation was attempted but may have failed"
    fi
else
echo "    Not generated (skipped during install)"
echo "    Generate later: ssh-keygen -t rsa -b 4096 -C \"your@email.com\""
fi
echo ""
echo "  SSH Server Status:"
if [ "$KEYS_IMPORTED" = true ]; then
echo "    Password authentication: DISABLED (key-only access)"
echo "    Imported SSH keys: ~/.ssh/authorized_keys"
else
echo "    Password authentication: ENABLED"
fi
echo ""
echo "  Traditional SSH Access:"
echo "    - Uses keys from GitHub/Launchpad (if imported)"
echo "    - Connect with: ssh user@hostname"
if [ "$KEYS_IMPORTED" = true ]; then
echo "    - Password login: DISABLED (keys required)"
else
echo "    - Password login: ENABLED"
fi
echo ""
echo "  NetBird SSH Access (independent of traditional SSH):"
echo "    - NetBird manages its own keys automatically"
echo "    - Works even with password auth disabled"
echo "    - Connect with: netbird ssh <peer-name>"
echo "    - Enable in NetBird dashboard first"
echo ""
echo "  You can use ANY combination:"
echo "    ✓ GitHub + Launchpad + NetBird SSH"
echo "    ✓ GitHub + NetBird SSH"
echo "    ✓ Launchpad + NetBird SSH"
echo "    ✓ GitHub + Launchpad (no NetBird)"
echo "    ✓ Just GitHub or just Launchpad"
echo "    ✓ Just NetBird SSH"
echo "    ✓ None (password auth only - if no keys imported)"
echo ""
if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RCLONE BACKUP SETUP - Exact Drive Mirroring"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Mount points created at:"
echo "    $ACTUAL_HOME/drives/primary"
echo "    $ACTUAL_HOME/drives/backup1"
echo "    $ACTUAL_HOME/drives/backup2"
echo ""
if [ "$MOUNT_NOW" = "y" ] || [ "$MOUNT_NOW" = "Y" ]; then
echo "  ✓ Drives have been mounted (if you provided valid device paths)"
echo ""
else
echo "  → Drives NOT mounted yet. To mount manually:"
echo "     See available drives: lsblk -f"
echo "     Mount: sudo mount /dev/sdX1 $ACTUAL_HOME/drives/primary"
echo "     Make permanent: Add to /etc/fstab (see instructions below)"
echo ""
fi
echo "  ⚠️  CRITICAL: CONFIGURE BEFORE RUNNING ⚠️"
echo "  The backup script uses SPLIT BACKUP strategy"
echo "  You decide which folders go to which backup drive"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 1: CONFIGURE THE SPLIT BACKUP SCRIPT                  │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Edit the backup script:"
echo "    sudo nano /usr/local/bin/backup-scripts/rclone-backup.sh"
echo ""
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║ SPLIT BACKUP EXPLAINED:                                       ║"
echo "  ║                                                               ║"
echo "  ║ Your PRIMARY drive is bigger than either backup drive        ║"
echo "  ║ Example: Primary=4TB, Backup1=2TB, Backup2=2TB               ║"
echo "  ║                                                               ║"
echo "  ║ Solution: DIVIDE your folders between the two backups        ║"
echo "  ║   • Some folders → backup1 only                              ║"
echo "  ║   • Other folders → backup2 only                             ║"
echo "  ║                                                               ║"
echo "  ║ Each folder is backed up to ONE drive, NOT both              ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Step 1a: Check how much space your folders use"
echo "    du -sh $ACTUAL_HOME/drives/primary/*"
echo ""
echo "  Example output:"
echo "    500G  primary/work"
echo "    800G  primary/photos"
echo "    1.2T  primary/videos"
echo "    500G  primary/music"
echo ""
echo "  Step 1b: Divide folders so each backup drive has enough space"
echo ""
echo "  In the script, find these two lists:"
echo ""
echo "    # Folders to backup to BACKUP1 only (example: 1.3TB total)"
echo "    BACKUP1_DIRS=("
echo "      \"work\"        # 500G"
echo "      \"photos\"      # 800G"
echo "    )"
echo ""
echo "    # Folders to backup to BACKUP2 only (example: 1.7TB total)"
echo "    BACKUP2_DIRS=("
echo "      \"videos\"      # 1.2T"
echo "      \"music\"       # 500G"
echo "    )"
echo ""
echo "  ⚠️  What this means:"
echo "    primary/work/    → backup1/work/    (backup1 ONLY)"
echo "    primary/photos/  → backup1/photos/  (backup1 ONLY)"
echo "    primary/videos/  → backup2/videos/  (backup2 ONLY)"
echo "    primary/music/   → backup2/music/   (backup2 ONLY)"
echo ""
echo "  ✓ Benefit: Your 4TB primary fits across two 2TB backups"
echo "  ⚠️ Risk: If backup1 fails, you lose work/ and photos/ backups"
echo "          (but original data on primary is still safe!)"
echo ""
echo "  Save with: Ctrl+O, then Enter, then Ctrl+X to exit"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 2: TEST WITH DRY-RUN (DO THIS FIRST!)                 │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Test what would sync to BACKUP1 (without actually copying):"
echo ""
echo "    rclone sync $ACTUAL_HOME/drives/primary/work \\"
echo "                 $ACTUAL_HOME/drives/backup1/work \\"
echo "                 --checksum --dry-run -v"
echo ""
echo "  Test what would sync to BACKUP2:"
echo ""
echo "    rclone sync $ACTUAL_HOME/drives/primary/videos \\"
echo "                 $ACTUAL_HOME/drives/backup2/videos \\"
echo "                 --checksum --dry-run -v"
echo ""
echo "  The dry-run shows:"
echo "    • Files that would copy FROM primary TO backup"
echo "    • Files that would be DELETED from backup (not on primary)"
echo "    • Total data that would transfer"
echo ""
echo "  ⚠️  Read carefully! Make sure the right folders go to the right drives!"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 3: RUN FIRST BACKUP MANUALLY                           │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Only after dry-run looks correct:"
echo "    sudo /usr/local/bin/backup-scripts/rclone-backup.sh"
echo ""
echo "  The script will sync:"
echo "    FROM: $ACTUAL_HOME/drives/primary/[BACKUP1_DIRS]"
echo "    TO:   $ACTUAL_HOME/drives/backup1/[same folders]"
echo ""
echo "    FROM: $ACTUAL_HOME/drives/primary/[BACKUP2_DIRS]"
echo "    TO:   $ACTUAL_HOME/drives/backup2/[same folders]"
echo ""
echo "  Each folder goes to its assigned backup drive only!"
echo ""
echo "  Monitor live progress:"
echo "    tail -f /var/log/rclone-backup.log"
echo ""
echo "  The log shows which folders sync to which backup drives"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 4: ENABLE AUTOMATIC DAILY BACKUPS (Optional)          │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Only enable after successful manual backup:"
echo "    sudo systemctl enable rclone-backup.timer"
echo "    sudo systemctl start rclone-backup.timer"
echo ""
echo "  This will automatically run the split backup daily at 2 AM"
echo "  (Each folder syncs to its assigned backup drive)"
echo ""
echo "     Check status:"
echo "       sudo systemctl status rclone-backup.timer"
echo "       sudo systemctl list-timers"
echo ""
echo "     Change schedule (default: 2 AM daily):"
echo "       sudo systemctl edit rclone-backup.timer"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 5: MANUAL MOUNT INSTRUCTIONS (if you skipped earlier) │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Find drive UUIDs:"
echo "    sudo blkid"
echo ""
echo "  Edit /etc/fstab for permanent mounts:"
echo "    sudo nano /etc/fstab"
echo ""
echo "  Add lines like (replace UUID with actual values from blkid):"
echo "    UUID=xxxx-xxxx $ACTUAL_HOME/drives/primary auto defaults 0 2"
echo "    UUID=yyyy-yyyy $ACTUAL_HOME/drives/backup1 auto defaults 0 2"
echo "    UUID=zzzz-zzzz $ACTUAL_HOME/drives/backup2 auto defaults 0 2"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 6: DRIVE FAILURE & RECOVERY (Split Backup Strategy)  │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  If SOURCE (primary) drive fails - CRITICAL SITUATION:"
echo "    ⚠️  With split backup, you need BOTH backup drives to restore!"
echo ""
echo "    1. Get a new drive (same size or larger than primary)"
echo "    2. Format it: sudo mkfs.ext4 /dev/sdX1"
echo "    3. Mount as primary: sudo mount /dev/sdX1 $ACTUAL_HOME/drives/primary"
echo "    4. Restore from BOTH backups:"
echo "       rclone sync $ACTUAL_HOME/drives/backup1/ $ACTUAL_HOME/drives/primary/ --checksum"
echo "       rclone sync $ACTUAL_HOME/drives/backup2/ $ACTUAL_HOME/drives/primary/ --checksum"
echo "    5. Update /etc/fstab with new UUID"
echo ""
echo "  If DESTINATION (backup1 or backup2) drive fails:"
echo "    ⚠️  You lose backup of those specific folders until drive is replaced!"
echo ""
echo "    Example: backup1 fails (had work/ and photos/ backups)"
echo "    • Your PRIMARY still has work/ and photos/ (original data is safe)"
echo "    • backup2 still works (videos/ and music/ are still backed up)"
echo "    • But work/ and photos/ have NO backup until you fix backup1"
echo ""
echo "    Recovery:"
echo "    1. Replace the failed drive"
echo "    2. Format: sudo mkfs.ext4 /dev/sdX1"
echo "    3. Mount: sudo mount /dev/sdX1 $ACTUAL_HOME/drives/backup1"
echo "    4. Update /etc/fstab if needed"
echo "    5. Run backup script - rclone will sync the assigned folders back"
echo ""
echo "  ⚠️  IMPORTANT: Replace failed backup drives quickly!"
echo "      While a backup drive is down, those folders have no redundancy."
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ STEP 7: VERIFY BACKUPS - Check Sync Status                 │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  ┌─────────────────────────────────────────────────────────────┐"
echo "  │ VERIFY BACKUPS - Check if PRIMARY and BACKUP match         │"
echo "  └─────────────────────────────────────────────────────────────┘"
echo ""
echo "  Compare SOURCE (primary) vs DESTINATION (backup):"
echo "    rclone check $ACTUAL_HOME/drives/primary/documents \\"
echo "                  $ACTUAL_HOME/drives/backup1/documents"
echo ""
echo "  This shows any differences between the two locations."
echo "  If they match perfectly, you'll see: \"0 differences found\""
echo ""
echo "  One-way check (files that exist on primary but not backup):"
echo "    rclone check $ACTUAL_HOME/drives/primary/documents \\"
echo "                  $ACTUAL_HOME/drives/backup1/documents \\"
echo "                  --checksum --one-way"
echo ""
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "OTHER IMPORTANT NOTES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo "  Samba File Sharing:"
    if command -v smbd &> /dev/null && grep -q "\[Primary\]" /etc/samba/smb.conf 2>/dev/null; then
        echo "    ✓ Share 'Primary' is accessible at:"
        echo "      Windows: \\\\$(hostname)\\Primary"
        echo "      Mac/Linux: smb://$(hostname)/Primary"
        echo "    • Username: $ACTUAL_USER"
        echo "    • Use the Samba password you just set"
        echo ""
    else
        echo "    ✗ Installation may have failed - check 'systemctl status smbd'"
        echo ""
    fi
fi
echo "  Docker: Log out and back in for group membership to take effect"
echo ""
echo "  NetBird:"
echo "    1. Run 'netbird up' (opens browser for authentication)"
echo "    2. View connected peers: netbird status"
echo "    3. Configure ACLs in dashboard: https://app.netbird.io"
echo ""
echo "  RustDesk: Launch from applications menu or run 'rustdesk'"
echo ""