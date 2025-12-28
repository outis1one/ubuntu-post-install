#!/bin/bash

# Ubuntu 24.04 Post-Installation Script
# Run with: sudo bash post-install.sh
# This script is rerunnable - it detects existing installations

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

# ============================================================================
# SOFTWARE DETECTION FUNCTIONS
# ============================================================================

is_docker_installed() {
    command -v docker &> /dev/null && systemctl is-active --quiet docker 2>/dev/null
}

is_samba_installed() {
    command -v smbd &> /dev/null && systemctl is-active --quiet smbd 2>/dev/null
}

is_netbird_installed() {
    command -v netbird &> /dev/null
}

is_rustdesk_installed() {
    command -v rustdesk &> /dev/null || dpkg -l rustdesk &> /dev/null
}

is_rclone_installed() {
    command -v rclone &> /dev/null
}

is_rsync_installed() {
    command -v rsync &> /dev/null
}

# ============================================================================
# SHOW CURRENT INSTALLATION STATUS
# ============================================================================
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CURRENT SYSTEM STATUS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if is_docker_installed; then
    echo "  ✓ Docker: Installed ($(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ','))"
else
    echo "  ○ Docker: Not installed"
fi
if is_samba_installed; then
    echo "  ✓ Samba: Installed and running"
else
    echo "  ○ Samba: Not installed"
fi
if is_netbird_installed; then
    echo "  ✓ NetBird: Installed"
else
    echo "  ○ NetBird: Not installed"
fi
if is_rustdesk_installed; then
    echo "  ✓ RustDesk: Installed"
else
    echo "  ○ RustDesk: Not installed"
fi
if is_rclone_installed; then
    echo "  ✓ rclone: Installed"
else
    echo "  ○ rclone: Not installed"
fi
if is_rsync_installed; then
    echo "  ✓ rsync: Installed"
else
    echo "  ○ rsync: Not installed"
fi
echo ""
echo "This script can reinstall/reconfigure any component."
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


# Docker Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DOCKER INSTALLATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

INSTALL_DOCKER="y"
if is_docker_installed; then
    echo "Docker is already installed: $(docker --version 2>/dev/null)"
    read -p "Reinstall Docker? (y/n): " INSTALL_DOCKER
fi

if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
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
else
    echo "Skipping Docker installation."
fi

# Samba File Sharing (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SAMBA FILE SHARING (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Samba allows you to share folders over the network to Windows, Mac, and Linux."
echo "The script will share your primary drive at ~/drives/primary"
echo ""

if is_samba_installed; then
    echo "Samba is already installed and running."
    if grep -q "\[Primary\]" /etc/samba/smb.conf 2>/dev/null; then
        echo "  Share 'Primary' is configured at: $ACTUAL_HOME/drives/primary"
    fi
    echo ""
    read -p "Reconfigure Samba? (y/n): " INSTALL_SAMBA
else
    read -p "Install and configure Samba file sharing? (y/n): " INSTALL_SAMBA
fi

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

# NetBird Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NETBIRD MESH VPN (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "NetBird is a secure mesh VPN for connecting devices across networks."
echo ""

INSTALL_NETBIRD="y"
if is_netbird_installed; then
    echo "NetBird is already installed."
    netbird status 2>/dev/null || true
    echo ""
    read -p "Reinstall NetBird? (y/n): " INSTALL_NETBIRD
else
    read -p "Install NetBird? (y/n): " INSTALL_NETBIRD
fi

if [ "$INSTALL_NETBIRD" = "y" ] || [ "$INSTALL_NETBIRD" = "Y" ]; then
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
else
    echo "Skipping NetBird installation."
fi

# RustDesk Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RUSTDESK REMOTE DESKTOP (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "RustDesk is an open-source remote desktop software."
echo ""

INSTALL_RUSTDESK="y"
if is_rustdesk_installed; then
    echo "RustDesk is already installed."
    echo ""
    read -p "Reinstall RustDesk? (y/n): " INSTALL_RUSTDESK
else
    read -p "Install RustDesk? (y/n): " INSTALL_RUSTDESK
fi

if [ "$INSTALL_RUSTDESK" = "y" ] || [ "$INSTALL_RUSTDESK" = "Y" ]; then
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
        echo "✓ RustDesk installed"
    fi
else
    echo "Skipping RustDesk installation."
fi

# Backup System (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "BACKUP SYSTEM (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This sets up an automated backup system for local drives."
echo ""

# Check if backup is already configured
BACKUP_CONFIGURED=false
if [ -f /usr/local/bin/backup-scripts/rclone-backup.sh ] || [ -f /usr/local/bin/backup-scripts/rsync-backup.sh ]; then
    BACKUP_CONFIGURED=true
    echo "Backup system is already configured."
    if [ -f /usr/local/bin/backup-scripts/rclone-backup.sh ]; then
        echo "  Current: rclone backup script"
    fi
    if [ -f /usr/local/bin/backup-scripts/rsync-backup.sh ]; then
        echo "  Current: rsync backup script"
    fi
    echo ""
    read -p "Reconfigure backup system? (y/n): " SETUP_BACKUP
else
    read -p "Set up backup system? (y/n): " SETUP_BACKUP
fi

if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "BACKUP TOOL SELECTION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Choose your backup tool:"
    echo ""
    echo "  [1] rsync  - RECOMMENDED for local drive backups"
    echo "              • Delta transfers (only changed bytes are copied)"
    echo "              • Faster incremental backups"
    echo "              • Built into most Linux systems"
    echo ""
    echo "  [2] rclone - Better for cloud storage backups"
    echo "              • Supports 40+ cloud providers (S3, GDrive, Dropbox...)"
    echo "              • File-level sync (copies entire changed files)"
    echo "              • Good for local drives, but rsync is more efficient"
    echo ""
    read -p "Select backup tool [1=rsync, 2=rclone]: " BACKUP_TOOL_CHOICE

    if [ "$BACKUP_TOOL_CHOICE" = "2" ]; then
        BACKUP_TOOL="rclone"
    else
        BACKUP_TOOL="rsync"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "BACKUP MODE SELECTION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Choose your backup mode:"
    echo ""
    echo "  [1] FULL BACKUP - Mirror entire primary drive to one backup drive"
    echo "              • Simpler setup (primary → backup1)"
    echo "              • Requires: backup drive >= primary drive size"
    echo "              • Example: 4TB primary → 4TB+ backup"
    echo ""
    echo "  [2] SPLIT BACKUP - Divide data between two smaller backup drives"
    echo "              • Useful when: Primary > each backup drive"
    echo "              • Example: 4TB primary → 2TB backup1 + 2TB backup2"
    echo "              • You configure which folders go to which backup"
    echo ""
    read -p "Select backup mode [1=full, 2=split]: " BACKUP_MODE_CHOICE

    if [ "$BACKUP_MODE_CHOICE" = "2" ]; then
        BACKUP_MODE="split"
    else
        BACKUP_MODE="full"
    fi

    echo ""
    echo "Selected: $BACKUP_TOOL with $BACKUP_MODE backup mode"
    echo ""
    echo "Setting up backup configuration..."
    echo ""

    # Install the selected backup tool if needed
    if [ "$BACKUP_TOOL" = "rsync" ]; then
        if ! is_rsync_installed; then
            apt install -y rsync || echo "Warning: rsync installation failed"
        fi
    else
        if ! is_rclone_installed; then
            apt install -y rclone || echo "Warning: rclone installation failed"
        fi
    fi

    # Create backup script directory
    mkdir -p /usr/local/bin/backup-scripts

    # Create mount point directories based on mode
    echo ""
    echo "Creating mount point directories in $ACTUAL_HOME/drives/..."
    mkdir -p "$ACTUAL_HOME/drives/primary"
    mkdir -p "$ACTUAL_HOME/drives/backup1"
    if [ "$BACKUP_MODE" = "split" ]; then
        mkdir -p "$ACTUAL_HOME/drives/backup2"
    fi
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
        if [ "$BACKUP_MODE" = "split" ]; then
            read -p "Backup2 drive device (e.g., /dev/sdd1): " BACKUP2_DEV
        fi

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

        # Mount backup2 (only in split mode)
        if [ "$BACKUP_MODE" = "split" ] && [ -n "$BACKUP2_DEV" ] && [ -b "$BACKUP2_DEV" ]; then
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

            if [ "$BACKUP_MODE" = "split" ] && [ -n "$BACKUP2_DEV" ] && [ -b "$BACKUP2_DEV" ]; then
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
        if [ "$BACKUP_MODE" = "split" ]; then
            echo "  $ACTUAL_HOME/drives/backup2"
        fi
    fi

    # Create backup script based on selected tool and mode
    SCRIPT_NAME="${BACKUP_TOOL}-backup.sh"

    if [ "$BACKUP_TOOL" = "rsync" ] && [ "$BACKUP_MODE" = "full" ]; then
        # RSYNC FULL BACKUP
        cat > /usr/local/bin/backup-scripts/$SCRIPT_NAME << BACKUP_SCRIPT
#!/bin/bash
################################################################################
# rsync FULL Backup Script - Mirror entire primary to backup drive
################################################################################
# Tool: rsync (delta transfers - only changed bytes are copied)
# Mode: Full backup (entire primary → backup1)
################################################################################

PRIMARY="$ACTUAL_HOME/drives/primary"
BACKUP1="$ACTUAL_HOME/drives/backup1"
LOG="/var/log/rsync-backup.log"

echo "=== rsync FULL Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "FROM: \$PRIMARY" | tee -a "\$LOG"
echo "TO:   \$BACKUP1" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

if [ ! -d "\$PRIMARY" ]; then
    echo "ERROR: Primary drive not mounted at \$PRIMARY" | tee -a "\$LOG"
    exit 1
fi

if [ ! -d "\$BACKUP1" ]; then
    echo "ERROR: Backup drive not mounted at \$BACKUP1" | tee -a "\$LOG"
    exit 1
fi

# rsync options:
#   -a = archive mode (preserves permissions, timestamps, etc.)
#   -v = verbose
#   -h = human-readable sizes
#   --delete = remove files from backup that don't exist on primary
#   --progress = show progress
#   --stats = show transfer statistics

rsync -avh --delete --progress --stats "\$PRIMARY/" "\$BACKUP1/" 2>&1 | tee -a "\$LOG"

if [ \$? -eq 0 ]; then
    echo "" | tee -a "\$LOG"
    echo "✓ Backup completed successfully: \$(date)" | tee -a "\$LOG"
else
    echo "" | tee -a "\$LOG"
    echo "✗ Backup failed: \$(date)" | tee -a "\$LOG"
fi
BACKUP_SCRIPT

    elif [ "$BACKUP_TOOL" = "rsync" ] && [ "$BACKUP_MODE" = "split" ]; then
        # RSYNC SPLIT BACKUP
        cat > /usr/local/bin/backup-scripts/$SCRIPT_NAME << BACKUP_SCRIPT
#!/bin/bash
################################################################################
# rsync SPLIT Backup Script - Divide data between two backup drives
################################################################################
# Tool: rsync (delta transfers - only changed bytes are copied)
# Mode: Split backup (folders divided between backup1 and backup2)
#
# CONFIGURE: Edit BACKUP1_DIRS and BACKUP2_DIRS below
################################################################################

PRIMARY="$ACTUAL_HOME/drives/primary"
BACKUP1="$ACTUAL_HOME/drives/backup1"
BACKUP2="$ACTUAL_HOME/drives/backup2"
LOG="/var/log/rsync-backup.log"

# ⚠️ CONFIGURE: Which folders go to which backup drive
# Check folder sizes: du -sh $ACTUAL_HOME/drives/primary/*
BACKUP1_DIRS=(
    "documents"
    "work"
    "photos"
)

BACKUP2_DIRS=(
    "videos"
    "music"
    "downloads"
)

echo "=== rsync SPLIT Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "PRIMARY: \$PRIMARY" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

backup_to_drive() {
    local dest=\$1
    local drive_name=\$2
    shift 2
    local dirs_array=("\$@")

    if [ ! -d "\$dest" ]; then
        echo "⚠️  WARNING: \$drive_name (\$dest) not mounted, skipping" | tee -a "\$LOG"
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
        echo "  Syncing: \$dir → \$dest/\$dir" | tee -a "\$LOG"

        rsync -avh --delete --progress "\$PRIMARY/\$dir/" "\$dest/\$dir/" 2>&1 | tee -a "\$LOG"

        if [ \$? -eq 0 ]; then
            echo "  ✓ \$dir synced successfully" | tee -a "\$LOG"
        else
            echo "  ✗ \$dir sync FAILED" | tee -a "\$LOG"
        fi
    done
}

backup_to_drive "\$BACKUP1" "Backup Drive 1" "\${BACKUP1_DIRS[@]}"
backup_to_drive "\$BACKUP2" "Backup Drive 2" "\${BACKUP2_DIRS[@]}"

echo "" | tee -a "\$LOG"
echo "=== Backup Completed: \$(date) ===" | tee -a "\$LOG"
BACKUP_SCRIPT

    elif [ "$BACKUP_TOOL" = "rclone" ] && [ "$BACKUP_MODE" = "full" ]; then
        # RCLONE FULL BACKUP
        cat > /usr/local/bin/backup-scripts/$SCRIPT_NAME << BACKUP_SCRIPT
#!/bin/bash
################################################################################
# rclone FULL Backup Script - Mirror entire primary to backup drive
################################################################################
# Tool: rclone (file-level sync, great for cloud storage)
# Mode: Full backup (entire primary → backup1)
################################################################################

PRIMARY="$ACTUAL_HOME/drives/primary"
BACKUP1="$ACTUAL_HOME/drives/backup1"
LOG="/var/log/rclone-backup.log"

echo "=== rclone FULL Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "FROM: \$PRIMARY" | tee -a "\$LOG"
echo "TO:   \$BACKUP1" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

if [ ! -d "\$PRIMARY" ]; then
    echo "ERROR: Primary drive not mounted at \$PRIMARY" | tee -a "\$LOG"
    exit 1
fi

if [ ! -d "\$BACKUP1" ]; then
    echo "ERROR: Backup drive not mounted at \$BACKUP1" | tee -a "\$LOG"
    exit 1
fi

# rclone sync: one-way sync from source to destination
rclone sync "\$PRIMARY" "\$BACKUP1" \\
    --checksum \\
    --verbose \\
    --progress \\
    --stats=30s \\
    --log-file="\$LOG"

if [ \$? -eq 0 ]; then
    echo "" | tee -a "\$LOG"
    echo "✓ Backup completed successfully: \$(date)" | tee -a "\$LOG"
else
    echo "" | tee -a "\$LOG"
    echo "✗ Backup failed: \$(date)" | tee -a "\$LOG"
fi
BACKUP_SCRIPT

    else
        # RCLONE SPLIT BACKUP (default)
        cat > /usr/local/bin/backup-scripts/$SCRIPT_NAME << BACKUP_SCRIPT
#!/bin/bash
################################################################################
# rclone SPLIT Backup Script - Divide data between two backup drives
################################################################################
# Tool: rclone (file-level sync, great for cloud storage)
# Mode: Split backup (folders divided between backup1 and backup2)
#
# CONFIGURE: Edit BACKUP1_DIRS and BACKUP2_DIRS below
################################################################################

PRIMARY="$ACTUAL_HOME/drives/primary"
BACKUP1="$ACTUAL_HOME/drives/backup1"
BACKUP2="$ACTUAL_HOME/drives/backup2"
LOG="/var/log/rclone-backup.log"

# ⚠️ CONFIGURE: Which folders go to which backup drive
# Check folder sizes: du -sh $ACTUAL_HOME/drives/primary/*
BACKUP1_DIRS=(
    "documents"
    "work"
    "photos"
)

BACKUP2_DIRS=(
    "videos"
    "music"
    "downloads"
)

echo "=== rclone SPLIT Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "PRIMARY: \$PRIMARY" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

backup_to_drive() {
    local dest=\$1
    local drive_name=\$2
    shift 2
    local dirs_array=("\$@")

    if [ ! -d "\$dest" ]; then
        echo "⚠️  WARNING: \$drive_name (\$dest) not mounted, skipping" | tee -a "\$LOG"
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
        echo "  Syncing: \$dir → \$dest/\$dir" | tee -a "\$LOG"

        rclone sync "\$PRIMARY/\$dir" "\$dest/\$dir" \\
            --checksum \\
            --verbose \\
            --progress \\
            --stats=30s \\
            --log-file="\$LOG"

        if [ \$? -eq 0 ]; then
            echo "  ✓ \$dir synced successfully" | tee -a "\$LOG"
        else
            echo "  ✗ \$dir sync FAILED" | tee -a "\$LOG"
        fi
    done
}

backup_to_drive "\$BACKUP1" "Backup Drive 1" "\${BACKUP1_DIRS[@]}"
backup_to_drive "\$BACKUP2" "Backup Drive 2" "\${BACKUP2_DIRS[@]}"

echo "" | tee -a "\$LOG"
echo "=== Backup Completed: \$(date) ===" | tee -a "\$LOG"
BACKUP_SCRIPT
    fi

    chmod +x /usr/local/bin/backup-scripts/$SCRIPT_NAME

    # Create systemd service for automatic backups
    cat > /etc/systemd/system/${BACKUP_TOOL}-backup.service << SERVICE
[Unit]
Description=${BACKUP_TOOL} Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-scripts/${SCRIPT_NAME}
User=root
SERVICE

    # Create systemd timer for daily backups at 2 AM
    cat > /etc/systemd/system/${BACKUP_TOOL}-backup.timer << TIMER
[Unit]
Description=Daily ${BACKUP_TOOL} Backup Timer
Requires=${BACKUP_TOOL}-backup.service

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    echo ""
    echo "✓ Backup script created: /usr/local/bin/backup-scripts/$SCRIPT_NAME"
    echo "✓ Systemd service/timer created (disabled by default)"
    echo ""
    echo "Configuration: $BACKUP_TOOL + $BACKUP_MODE mode"
    if [ "$BACKUP_MODE" = "split" ]; then
        echo ""
        echo "⚠️  IMPORTANT: Edit the backup script to configure which folders"
        echo "   go to which backup drive before running!"
        echo ""
        echo "   sudo nano /usr/local/bin/backup-scripts/$SCRIPT_NAME"
    fi
else
    echo "Skipping backup system setup."
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
echo "  ✓ net-tools, ncdu, git, curl, wget, htop, tree, zip/unzip"
echo "  ✓ OpenSSH Server - SSH remote access"
if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
    echo "  ✓ Docker Engine + Docker Compose"
fi
if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo "  ✓ Samba - File sharing (Primary drive shared)"
fi
if [ "$INSTALL_NETBIRD" = "y" ] || [ "$INSTALL_NETBIRD" = "Y" ]; then
    echo "  ✓ NetBird - Mesh VPN"
fi
if [ "$INSTALL_RUSTDESK" = "y" ] || [ "$INSTALL_RUSTDESK" = "Y" ]; then
    echo "  ✓ RustDesk - Remote desktop"
fi
if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo "  ✓ Backup system configured: $BACKUP_TOOL ($BACKUP_MODE mode)"
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
echo "BACKUP SYSTEM - $BACKUP_TOOL ($BACKUP_MODE mode)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Mount points:"
echo "    $ACTUAL_HOME/drives/primary"
echo "    $ACTUAL_HOME/drives/backup1"
if [ "$BACKUP_MODE" = "split" ]; then
echo "    $ACTUAL_HOME/drives/backup2"
fi
echo ""
echo "  Backup script: /usr/local/bin/backup-scripts/${BACKUP_TOOL}-backup.sh"
echo "  Log file: /var/log/${BACKUP_TOOL}-backup.log"
echo ""
if [ "$BACKUP_MODE" = "split" ]; then
echo "  ⚠️  CONFIGURE BEFORE RUNNING:"
echo "     Edit the script to set which folders go to which backup drive."
echo "     sudo nano /usr/local/bin/backup-scripts/${BACKUP_TOOL}-backup.sh"
echo ""
fi
echo "  Quick start:"
echo "    1. Test (dry-run):  sudo ${BACKUP_TOOL}-backup.sh --dry-run  # (edit script first)"
echo "    2. Run manually:    sudo /usr/local/bin/backup-scripts/${BACKUP_TOOL}-backup.sh"
echo "    3. Enable auto:     sudo systemctl enable ${BACKUP_TOOL}-backup.timer"
echo "                        sudo systemctl start ${BACKUP_TOOL}-backup.timer"
echo ""
echo "  Monitor: tail -f /var/log/${BACKUP_TOOL}-backup.log"
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
if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
    echo "  Docker: Log out and back in for group membership to take effect"
    echo ""
fi
if [ "$INSTALL_NETBIRD" = "y" ] || [ "$INSTALL_NETBIRD" = "Y" ]; then
    echo "  NetBird:"
    echo "    1. Run 'netbird up' (opens browser for authentication)"
    echo "    2. View connected peers: netbird status"
    echo "    3. Configure ACLs in dashboard: https://app.netbird.io"
    echo ""
fi
if [ "$INSTALL_RUSTDESK" = "y" ] || [ "$INSTALL_RUSTDESK" = "Y" ]; then
    echo "  RustDesk: Launch from applications menu or run 'rustdesk'"
    echo ""
fi