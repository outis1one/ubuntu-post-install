#!/bin/bash

# Ubuntu 24.04 Post-Installation Script
# Run with: sudo bash post-install.sh
# This script is rerunnable - it detects existing installations

# ============================================================================
# COMMAND-LINE ARGUMENT PARSING
# ============================================================================

DRY_RUN=false
UNATTENDED=false
LOG_FILE="/var/log/post-install.log"

show_help() {
    echo "Ubuntu 24.04 Post-Installation Script"
    echo ""
    echo "Usage: sudo ./post-install.sh [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run      Preview what would be installed without making changes"
    echo "  --unattended   Run with default options (no prompts)"
    echo "                 Defaults: skip key generation, no SSH imports,"
    echo "                 install Docker, skip VPNs/Remote Desktop/Backup"
    echo "  --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo ./post-install.sh                # Interactive mode"
    echo "  sudo ./post-install.sh --dry-run      # Preview installations"
    echo "  sudo ./post-install.sh --unattended   # Automated install"
    echo ""
    exit 0
}

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --unattended)
            UNATTENDED=true
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown option: $arg"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ============================================================================
# LOGGING SETUP
# ============================================================================

# Create log file and tee all output
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "=== Post-Install Log Started: $(date) ===" >> "$LOG_FILE"

echo "=== Ubuntu 24.04 Post-Installation Script ==="
echo ""

if [ "$DRY_RUN" = true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DRY RUN MODE - No changes will be made"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

if [ "$UNATTENDED" = true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "UNATTENDED MODE - Using default options"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
fi

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Get the actual user (not root)
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME=$(getent passwd "$ACTUAL_USER" | cut -d: -f6)

echo "Note: Script will continue even if individual packages fail to install"
echo "Log file: $LOG_FILE"
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

is_ufw_installed() {
    command -v ufw &> /dev/null
}

is_wireguard_installed() {
    command -v wg &> /dev/null
}

is_tailscale_installed() {
    command -v tailscale &> /dev/null
}

is_teamviewer_installed() {
    command -v teamviewer &> /dev/null || dpkg -l teamviewer &> /dev/null 2>&1
}

is_meshcentral_installed() {
    # MeshCentral agent is typically installed as meshagent
    command -v meshagent &> /dev/null || [ -f /usr/local/mesh_services/meshagent/meshagent ]
}

# ============================================================================
# DRY-RUN AND UNATTENDED HELPER FUNCTIONS
# ============================================================================

# Run a command, but skip it in dry-run mode
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

# Prompt for yes/no, with unattended default
# Usage: prompt_yn "Question?" "default" VARNAME
# default can be "y" or "n"
prompt_yn() {
    local question="$1"
    local default="$2"
    local varname="$3"

    if [ "$UNATTENDED" = true ]; then
        eval "$varname='$default'"
        echo "$question [auto: $default]"
        return
    fi

    read -p "$question " response
    eval "$varname='$response'"
}

# Prompt for text input, with unattended default
# Usage: prompt_text "Question?" "default" VARNAME
prompt_text() {
    local question="$1"
    local default="$2"
    local varname="$3"

    if [ "$UNATTENDED" = true ]; then
        eval "$varname='$default'"
        echo "$question [auto: $default]"
        return
    fi

    read -p "$question " response
    eval "$varname='$response'"
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
if is_teamviewer_installed; then
    echo "  ✓ TeamViewer: Installed"
else
    echo "  ○ TeamViewer: Not installed"
fi
if is_meshcentral_installed; then
    echo "  ✓ MeshCentral Agent: Installed"
else
    echo "  ○ MeshCentral Agent: Not installed"
fi
if is_wireguard_installed; then
    echo "  ✓ WireGuard: Installed"
else
    echo "  ○ WireGuard: Not installed"
fi
if is_tailscale_installed; then
    echo "  ✓ Tailscale: Installed"
else
    echo "  ○ Tailscale: Not installed"
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
if is_ufw_installed; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "  ✓ UFW Firewall: Enabled"
    else
        echo "  ○ UFW Firewall: Installed but disabled"
    fi
else
    echo "  ○ UFW Firewall: Not installed"
fi
echo ""
echo "This script can reinstall/reconfigure any component."
echo ""

# Update package list
echo "Updating package lists..."
run_cmd apt update

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

run_cmd apt install -y \
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
prompt_yn "Generate a new SSH key for this computer? (y/n):" "n" GENERATE_KEY

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
prompt_text "Import SSH keys from GitHub? (enter username or leave blank to skip):" "" GITHUB_USER
prompt_text "Import SSH keys from Launchpad? (enter username or leave blank to skip):" "" LAUNCHPAD_USER

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

    # Offer fail2ban since password auth is still enabled
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "FAIL2BAN (Recommended with password SSH)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Since password authentication is enabled, fail2ban is recommended"
    echo "to protect against brute-force SSH attacks."
    echo ""

    prompt_yn "Install and enable fail2ban? (y/n):" "y" INSTALL_FAIL2BAN

    if [ "$INSTALL_FAIL2BAN" = "y" ] || [ "$INSTALL_FAIL2BAN" = "Y" ]; then
        echo ""
        echo "Installing fail2ban..."
        run_cmd apt install -y fail2ban

        if [ "$DRY_RUN" != true ]; then
            # Create local config to protect SSH
            cat > /etc/fail2ban/jail.local << 'FAIL2BAN_CONFIG'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
FAIL2BAN_CONFIG

            run_cmd systemctl enable fail2ban
            run_cmd systemctl restart fail2ban
            echo "✓ fail2ban installed and configured"
            echo "  - 5 failed attempts = 1 hour ban"
            echo "  - View banned IPs: sudo fail2ban-client status sshd"
        fi
    else
        echo "Skipping fail2ban installation."
    fi
fi

INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-n}"

# Docker Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "DOCKER INSTALLATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if is_docker_installed; then
    echo "Docker is already installed: $(docker --version 2>/dev/null)"
    prompt_yn "Reinstall Docker? (y/n):" "n" INSTALL_DOCKER
else
    prompt_yn "Install Docker? (y/n):" "y" INSTALL_DOCKER
fi

if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
    echo ""
    echo "Installing Docker prerequisites..."
    echo "  - ca-certificates: SSL/TLS certificates for secure connections"
    echo "  - gnupg: GNU Privacy Guard for package verification"
    echo "  - lsb-release: Provides Ubuntu version information"
    echo ""

    run_cmd apt install -y \
        ca-certificates \
        gnupg \
        lsb-release || echo "Warning: Some prerequisites failed to install, continuing..."

    echo ""
    echo "Installing Docker..."
    echo "  - Docker Engine: Container runtime platform"
    echo "  - Docker Compose: Multi-container application orchestration"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would remove old Docker packages"
        echo "[DRY-RUN] Would add Docker GPG key and repository"
        echo "[DRY-RUN] Would install docker-ce, docker-ce-cli, containerd.io, plugins"
        echo "[DRY-RUN] Would start and enable Docker service"
        echo "[DRY-RUN] Would add $SUDO_USER to docker group"
    else
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
    fi
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
    prompt_yn "Reconfigure Samba? (y/n):" "n" INSTALL_SAMBA
else
    prompt_yn "Install and configure Samba file sharing? (y/n):" "n" INSTALL_SAMBA
fi

if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo ""
    echo "Installing Samba file sharing..."
    echo "  - Samba: SMB/CIFS file server for network file sharing"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install samba"
        echo "[DRY-RUN] Would configure [Primary] share at $ACTUAL_HOME/drives/primary"
        echo "[DRY-RUN] Would prompt for Samba password"
        echo "[DRY-RUN] Would enable and start smbd/nmbd services"
    else
        run_cmd apt install -y samba || echo "Warning: Samba installation failed, continuing..."

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

            # Add Samba user (skip in unattended mode - user must set password manually)
            if [ "$UNATTENDED" != true ]; then
                echo ""
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo "SAMBA PASSWORD SETUP"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                echo "Set a password for Samba file sharing access."
                echo "Tip: Using the same password as your system login is convenient."
                echo ""
                smbpasswd -a "$ACTUAL_USER"
            else
                echo "Skipping Samba password setup (unattended mode)"
                echo "Set password later with: sudo smbpasswd -a $ACTUAL_USER"
            fi

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

if is_netbird_installed; then
    echo "NetBird is already installed."
    netbird status 2>/dev/null || true
    echo ""
    prompt_yn "Reinstall NetBird? (y/n):" "n" INSTALL_NETBIRD
else
    prompt_yn "Install NetBird? (y/n):" "n" INSTALL_NETBIRD
fi

if [ "$INSTALL_NETBIRD" = "y" ] || [ "$INSTALL_NETBIRD" = "Y" ]; then
    echo ""
    echo "Installing NetBird..."
    echo "  - NetBird: Secure mesh VPN for connecting devices"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would download and run NetBird install script"
    else
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
    fi
else
    echo "Skipping NetBird installation."
fi

# WireGuard Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "WIREGUARD VPN (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "WireGuard is a fast, modern VPN protocol."
echo "  • Lightweight and high-performance"
echo "  • Simple configuration via config files"
echo "  • Built into Linux kernel"
echo ""

if is_wireguard_installed; then
    echo "WireGuard is already installed."
    echo ""
    prompt_yn "Reinstall WireGuard? (y/n):" "n" INSTALL_WIREGUARD
else
    prompt_yn "Install WireGuard? (y/n):" "n" INSTALL_WIREGUARD
fi

if [ "$INSTALL_WIREGUARD" = "y" ] || [ "$INSTALL_WIREGUARD" = "Y" ]; then
    echo ""
    echo "Installing WireGuard..."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install wireguard wireguard-tools"
    else
        apt install -y wireguard wireguard-tools || echo "Warning: WireGuard installation failed, continuing..."

        echo ""
        echo "WireGuard installed. Setup instructions:"
        echo ""
        echo "Generate keys:"
        echo "  wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey"
        echo ""
        echo "Create config at /etc/wireguard/wg0.conf:"
        echo "  [Interface]"
        echo "  PrivateKey = <your-private-key>"
        echo "  Address = 10.0.0.1/24"
        echo "  ListenPort = 51820"
        echo ""
        echo "  [Peer]"
        echo "  PublicKey = <peer-public-key>"
        echo "  AllowedIPs = 10.0.0.2/32"
        echo "  Endpoint = peer.example.com:51820"
        echo ""
        echo "Start WireGuard:"
        echo "  sudo wg-quick up wg0"
        echo "  sudo systemctl enable wg-quick@wg0  # Start on boot"
        echo ""
    fi
else
    echo "Skipping WireGuard installation."
fi

# Tailscale Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TAILSCALE VPN (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Tailscale is a zero-config mesh VPN built on WireGuard."
echo "  • Easy setup - just sign in"
echo "  • Built on WireGuard for performance"
echo "  • Automatic NAT traversal"
echo "  • Built-in SSH (Tailscale SSH)"
echo ""

if is_tailscale_installed; then
    echo "Tailscale is already installed."
    tailscale status 2>/dev/null || true
    echo ""
    prompt_yn "Reinstall Tailscale? (y/n):" "n" INSTALL_TAILSCALE
else
    prompt_yn "Install Tailscale? (y/n):" "n" INSTALL_TAILSCALE
fi

if [ "$INSTALL_TAILSCALE" = "y" ] || [ "$INSTALL_TAILSCALE" = "Y" ]; then
    echo ""
    echo "Installing Tailscale..."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would add Tailscale apt repository"
        echo "[DRY-RUN] Would install tailscale"
    else
        # Add Tailscale's package signing key and repository
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
        curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/jammy.tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list

        apt update
        apt install -y tailscale || echo "Warning: Tailscale installation failed, continuing..."

        echo ""
        echo "Tailscale installed. Setup instructions:"
        echo ""
        echo "Connect to Tailscale network:"
        echo "  sudo tailscale up"
        echo ""
        echo "This opens a browser to authenticate. After that:"
        echo "  tailscale status     # View connected devices"
        echo "  tailscale ip         # Show your Tailscale IP"
        echo ""
        echo "Tailscale SSH (optional - enable in admin console):"
        echo "  • Enable 'SSH' in Tailscale admin console for this machine"
        echo "  • Connect with: ssh user@device-name (uses Tailscale identity)"
        echo "  • No SSH keys needed - Tailscale handles authentication"
        echo ""
    fi
else
    echo "Skipping Tailscale installation."
fi

# RustDesk Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "RUSTDESK REMOTE DESKTOP (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "RustDesk is an open-source remote desktop software."
echo ""

if is_rustdesk_installed; then
    echo "RustDesk is already installed."
    echo ""
    prompt_yn "Reinstall RustDesk? (y/n):" "n" INSTALL_RUSTDESK
else
    prompt_yn "Install RustDesk? (y/n):" "n" INSTALL_RUSTDESK
fi

if [ "$INSTALL_RUSTDESK" = "y" ] || [ "$INSTALL_RUSTDESK" = "Y" ]; then
    echo ""
    echo "Installing RustDesk..."
    echo "  - RustDesk: Open-source remote desktop software"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would download latest RustDesk from GitHub"
        echo "[DRY-RUN] Would install rustdesk .deb package"
    else
        # Download latest RustDesk .deb package
        RUSTDESK_VERSION=$(curl -s https://api.github.com/repos/rustdesk/rustdesk/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
        RUSTDESK_URL="https://github.com/rustdesk/rustdesk/releases/download/${RUSTDESK_VERSION}/rustdesk-${RUSTDESK_VERSION}-x86_64.deb"

        wget -O /tmp/rustdesk.deb "$RUSTDESK_URL" || echo "Warning: RustDesk download failed, continuing..."

        if [ -f /tmp/rustdesk.deb ]; then
            apt install -y /tmp/rustdesk.deb || echo "Warning: RustDesk installation failed, continuing..."
            rm /tmp/rustdesk.deb
            echo "✓ RustDesk installed"
        fi
    fi
else
    echo "Skipping RustDesk installation."
fi

# TeamViewer Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEAMVIEWER REMOTE DESKTOP (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "TeamViewer is commercial remote desktop software with a free tier."
echo "  • Cross-platform (Windows, Mac, Linux, mobile)"
echo "  • Easy to use - no port forwarding needed"
echo "  • Requires TeamViewer account for unattended access"
echo ""

if is_teamviewer_installed; then
    echo "TeamViewer is already installed."
    echo ""
    prompt_yn "Reinstall TeamViewer? (y/n):" "n" INSTALL_TEAMVIEWER
else
    prompt_yn "Install TeamViewer? (y/n):" "n" INSTALL_TEAMVIEWER
fi

if [ "$INSTALL_TEAMVIEWER" = "y" ] || [ "$INSTALL_TEAMVIEWER" = "Y" ]; then
    echo ""
    echo "Installing TeamViewer..."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would download TeamViewer .deb package"
        echo "[DRY-RUN] Would install teamviewer"
    else
        # Download TeamViewer .deb package
        wget -O /tmp/teamviewer.deb "https://download.teamviewer.com/download/linux/teamviewer_amd64.deb" || echo "Warning: TeamViewer download failed, continuing..."

        if [ -f /tmp/teamviewer.deb ]; then
            apt install -y /tmp/teamviewer.deb || echo "Warning: TeamViewer installation failed, continuing..."
            rm /tmp/teamviewer.deb

            echo ""
            echo "TeamViewer installed. Setup instructions:"
            echo ""
            echo "Start TeamViewer:"
            echo "  teamviewer"
            echo ""
            echo "For unattended access:"
            echo "  1. Open TeamViewer"
            echo "  2. Go to Extras → Options → Security"
            echo "  3. Set a personal password for unattended access"
            echo "  4. Note your TeamViewer ID (shown in main window)"
            echo ""
            echo "✓ TeamViewer installed"
        fi
    fi
else
    echo "Skipping TeamViewer installation."
fi

# MeshCentral Installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "MESHCENTRAL AGENT (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "MeshCentral is an open-source remote management solution."
echo "  • Self-hosted or use public servers"
echo "  • Web-based remote desktop (no client software needed)"
echo "  • Terminal, file transfer, and remote desktop"
echo "  • Requires a MeshCentral server to connect to"
echo ""

if is_meshcentral_installed; then
    echo "MeshCentral Agent is already installed."
    echo ""
    prompt_yn "Reinstall MeshCentral Agent? (y/n):" "n" INSTALL_MESHCENTRAL
else
    prompt_yn "Install MeshCentral Agent? (y/n):" "n" INSTALL_MESHCENTRAL
fi

if [ "$INSTALL_MESHCENTRAL" = "y" ] || [ "$INSTALL_MESHCENTRAL" = "Y" ]; then
    echo ""
    echo "MeshCentral requires a server URL to connect to."
    echo ""
    echo "If you have a MeshCentral server, the agent install is typically done by:"
    echo "  1. Log into your MeshCentral web interface"
    echo "  2. Go to 'My Devices' → 'Add Agent'"
    echo "  3. Download and run the Linux agent installer"
    echo ""
    echo "Example (replace with your server's URL):"
    echo "  wget -O meshagent https://your-meshcentral-server/meshagents?id=XXXXX"
    echo "  chmod +x meshagent"
    echo "  sudo ./meshagent -install"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would prompt for MeshCentral server URL"
        echo "[DRY-RUN] Would download and install meshagent"
    else
        prompt_text "Enter MeshCentral agent URL (or leave blank to skip):" "" MESHCENTRAL_URL

        if [ -n "$MESHCENTRAL_URL" ]; then
            wget -O /tmp/meshagent "$MESHCENTRAL_URL" || echo "Warning: MeshCentral agent download failed"

            if [ -f /tmp/meshagent ]; then
                chmod +x /tmp/meshagent
                /tmp/meshagent -install || echo "Warning: MeshCentral agent installation failed"
                rm /tmp/meshagent
                echo ""
                echo "✓ MeshCentral Agent installed"
                echo "  Check your MeshCentral server - this device should appear shortly."
            fi
        else
            echo ""
            echo "No URL provided. Skipping MeshCentral agent installation."
            echo "You can install later by downloading the agent from your MeshCentral server."
        fi
    fi
else
    echo "Skipping MeshCentral installation."
fi

# Backup System (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "LOCAL BACKUP SYSTEM (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Set up rsync backup from primary drive(s) to backup drive(s)."
echo ""
echo "Why rsync instead of RAID?"
echo "  • RAID mirrors corruption instantly - rsync gives you time to notice"
echo "  • RAID requires identical drives - rsync works with any sizes"
echo "  • RAID is complex to set up/recover - rsync is simple copy"
echo "  • rsync can run on schedule - RAID is always-on (more wear)"
echo "  • With rsync, backup drives can be disconnected for safety"
echo ""

# Check if backup is already configured
BACKUP_CONFIGURED=false
if [ -f /usr/local/bin/backup-scripts/rsync-backup.sh ]; then
    BACKUP_CONFIGURED=true
    echo "Local backup system is already configured."
    echo ""
    prompt_yn "Reconfigure local backup system? (y/n):" "n" SETUP_BACKUP
else
    prompt_yn "Set up local backup system? (y/n):" "n" SETUP_BACKUP
fi

if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DRIVE CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Configure your drive mount points in ~/drives/"
    echo "Default names: primary, backup1, backup2, etc."
    echo "You can customize these (e.g., 'media', 'documents', 'photos-backup')"
    echo ""

    # Install rsync if needed
    if ! is_rsync_installed; then
        run_cmd apt install -y rsync || echo "Warning: rsync installation failed"
    fi

    # Create backup script directory
    mkdir -p /usr/local/bin/backup-scripts

    # Ask for primary drive name
    echo "PRIMARY DRIVE (source for backups):"
    prompt_text "  Mount point name [default: primary]:" "primary" PRIMARY_NAME
    PRIMARY_NAME="${PRIMARY_NAME:-primary}"

    # Ask for number of backup drives
    echo ""
    echo "BACKUP DRIVES (destinations):"
    prompt_text "  How many backup drives? [1-4, default: 1]:" "1" NUM_BACKUPS
    NUM_BACKUPS="${NUM_BACKUPS:-1}"

    # Validate number
    case $NUM_BACKUPS in
        1|2|3|4) ;;
        *) NUM_BACKUPS=1 ;;
    esac

    # Collect backup drive names
    declare -a BACKUP_NAMES
    for i in $(seq 1 $NUM_BACKUPS); do
        prompt_text "  Backup drive $i name [default: backup$i]:" "backup$i" "BACKUP_NAME_$i"
        eval "BACKUP_NAMES[$i]=\${BACKUP_NAME_$i:-backup$i}"
    done

    # Create mount point directories
    echo ""
    echo "Creating mount point directories..."
    mkdir -p "$ACTUAL_HOME/drives/$PRIMARY_NAME"
    for i in $(seq 1 $NUM_BACKUPS); do
        mkdir -p "$ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}"
    done
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/drives"

    echo "✓ Created mount points:"
    echo "  Primary: $ACTUAL_HOME/drives/$PRIMARY_NAME"
    for i in $(seq 1 $NUM_BACKUPS); do
        echo "  Backup$i: $ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}"
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DRIVE MOUNTING"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Available block devices:"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
    echo ""

    prompt_yn "Mount drives now? (y/n):" "n" MOUNT_NOW

    if [ "$MOUNT_NOW" = "y" ] || [ "$MOUNT_NOW" = "Y" ]; then
        echo ""
        echo "Enter device paths (e.g., /dev/sdb1) or leave blank to skip"
        echo ""

        read -p "Primary drive ($PRIMARY_NAME) device: " PRIMARY_DEV

        declare -a BACKUP_DEVS
        for i in $(seq 1 $NUM_BACKUPS); do
            read -p "Backup drive ${BACKUP_NAMES[$i]} device: " "BACKUP_DEV_$i"
            eval "BACKUP_DEVS[$i]=\$BACKUP_DEV_$i"
        done

        # Mount primary
        if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
            echo "Mounting $PRIMARY_DEV to $ACTUAL_HOME/drives/$PRIMARY_NAME..."
            mount "$PRIMARY_DEV" "$ACTUAL_HOME/drives/$PRIMARY_NAME" && echo "✓ $PRIMARY_NAME mounted" || echo "✗ Failed to mount $PRIMARY_NAME"
        fi

        # Mount backups
        for i in $(seq 1 $NUM_BACKUPS); do
            if [ -n "${BACKUP_DEVS[$i]}" ] && [ -b "${BACKUP_DEVS[$i]}" ]; then
                echo "Mounting ${BACKUP_DEVS[$i]} to $ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}..."
                mount "${BACKUP_DEVS[$i]}" "$ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}" && echo "✓ ${BACKUP_NAMES[$i]} mounted" || echo "✗ Failed to mount ${BACKUP_NAMES[$i]}"
            fi
        done

        echo ""
        echo "Current mounts:"
        df -h | grep "$ACTUAL_HOME/drives" || echo "  (no drives currently mounted)"

        echo ""
        prompt_yn "Add to /etc/fstab for auto-mount at boot? (y/n):" "n" ADD_FSTAB

        if [ "$ADD_FSTAB" = "y" ] || [ "$ADD_FSTAB" = "Y" ]; then
            echo ""
            echo "Adding entries to /etc/fstab..."
            cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S)

            if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
                PRIMARY_UUID=$(blkid -s UUID -o value "$PRIMARY_DEV")
                if [ -n "$PRIMARY_UUID" ]; then
                    echo "UUID=$PRIMARY_UUID $ACTUAL_HOME/drives/$PRIMARY_NAME auto defaults,nofail 0 2" >> /etc/fstab
                    echo "✓ Added $PRIMARY_NAME to fstab"
                fi
            fi

            for i in $(seq 1 $NUM_BACKUPS); do
                if [ -n "${BACKUP_DEVS[$i]}" ] && [ -b "${BACKUP_DEVS[$i]}" ]; then
                    BACKUP_UUID=$(blkid -s UUID -o value "${BACKUP_DEVS[$i]}")
                    if [ -n "$BACKUP_UUID" ]; then
                        echo "UUID=$BACKUP_UUID $ACTUAL_HOME/drives/${BACKUP_NAMES[$i]} auto defaults,nofail 0 2" >> /etc/fstab
                        echo "✓ Added ${BACKUP_NAMES[$i]} to fstab"
                    fi
                fi
            done
        fi
    fi

    # Create rsync backup script
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "CREATING BACKUP SCRIPT"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Build backup destinations list
    BACKUP_DESTS=""
    for i in $(seq 1 $NUM_BACKUPS); do
        BACKUP_DESTS="$BACKUP_DESTS \"$ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}\""
    done

    cat > /usr/local/bin/backup-scripts/rsync-backup.sh << BACKUP_SCRIPT
#!/bin/bash
################################################################################
# rsync Local Backup Script
# Backs up primary drive to all backup drives
################################################################################

PRIMARY="$ACTUAL_HOME/drives/$PRIMARY_NAME"
BACKUP_DRIVES=($BACKUP_DESTS)
LOG="/var/log/rsync-backup.log"

echo "=== rsync Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "Source: \$PRIMARY" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

if [ ! -d "\$PRIMARY" ] || [ -z "\$(ls -A \$PRIMARY 2>/dev/null)" ]; then
    echo "ERROR: Primary drive not mounted or empty at \$PRIMARY" | tee -a "\$LOG"
    exit 1
fi

for BACKUP in "\${BACKUP_DRIVES[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "\$LOG"
    echo "Backing up to: \$BACKUP" | tee -a "\$LOG"

    if [ ! -d "\$BACKUP" ]; then
        echo "⚠️  WARNING: \$BACKUP not mounted, skipping" | tee -a "\$LOG"
        continue
    fi

    # rsync options:
    #   -a = archive mode (preserves permissions, timestamps, etc.)
    #   -v = verbose
    #   -h = human-readable sizes
    #   --delete = remove files from backup that don't exist on primary
    #   --progress = show progress

    rsync -avh --delete --progress "\$PRIMARY/" "\$BACKUP/" 2>&1 | tee -a "\$LOG"

    if [ \$? -eq 0 ]; then
        echo "✓ Backup to \$BACKUP completed" | tee -a "\$LOG"
    else
        echo "✗ Backup to \$BACKUP FAILED" | tee -a "\$LOG"
    fi
done

echo "" | tee -a "\$LOG"
echo "=== Backup Completed: \$(date) ===" | tee -a "\$LOG"
BACKUP_SCRIPT

    chmod +x /usr/local/bin/backup-scripts/rsync-backup.sh

    # Create systemd service
    cat > /etc/systemd/system/rsync-backup.service << SERVICE
[Unit]
Description=rsync Local Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/backup-scripts/rsync-backup.sh
User=root
SERVICE

    # Create systemd timer for daily backups at 2 AM
    cat > /etc/systemd/system/rsync-backup.timer << TIMER
[Unit]
Description=Daily rsync Backup Timer
Requires=rsync-backup.service

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    echo ""
    echo "✓ Backup script created: /usr/local/bin/backup-scripts/rsync-backup.sh"
    echo "✓ Systemd service/timer created (disabled by default)"
    echo ""
    echo "Quick start:"
    echo "  Test backup:    sudo /usr/local/bin/backup-scripts/rsync-backup.sh"
    echo "  Enable daily:   sudo systemctl enable --now rsync-backup.timer"
    echo "  View log:       tail -f /var/log/rsync-backup.log"
else
    echo "Skipping local backup setup."
fi

# Cloud Backup with rclone (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CLOUD BACKUP (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Set up encrypted cloud backup using rclone."
echo "Supports: Google Drive, OneDrive, Dropbox, and 40+ other providers."
echo ""
echo "Your files are encrypted BEFORE upload - the cloud provider cannot read them."
echo ""

prompt_yn "Set up encrypted cloud backup? (y/n):" "n" SETUP_CLOUD_BACKUP

if [ "$SETUP_CLOUD_BACKUP" = "y" ] || [ "$SETUP_CLOUD_BACKUP" = "Y" ]; then
    echo ""

    # Install rclone if needed
    if ! is_rclone_installed; then
        echo "Installing rclone..."
        run_cmd apt install -y rclone || echo "Warning: rclone installation failed"
    fi

    if is_rclone_installed; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "CHOOSE CLOUD PROVIDER"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  [1] Google Drive (15GB free)"
        echo "  [2] Microsoft OneDrive (5GB free, 1TB with Microsoft 365)"
        echo "  [3] Other (manual rclone config)"
        echo ""
        prompt_text "Select provider [1/2/3]:" "1" CLOUD_PROVIDER

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "RCLONE CONFIGURATION"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""

        case $CLOUD_PROVIDER in
            1)
                echo "Setting up Google Drive..."
                echo ""
                echo "Step 1: Run 'rclone config' to create a Google Drive remote"
                echo "Step 2: When prompted:"
                echo "   - Choose 'n' for new remote"
                echo "   - Name it 'gdrive'"
                echo "   - Choose 'drive' (Google Drive)"
                echo "   - Leave client_id and client_secret blank"
                echo "   - Choose scope '1' (full access)"
                echo "   - Leave root_folder_id blank"
                echo "   - Leave service_account_file blank"
                echo "   - Choose 'n' for advanced config"
                echo "   - Choose 'y' for auto config (opens browser)"
                echo "   - Choose 'n' for team drive"
                echo "   - Confirm with 'y'"
                echo ""
                CLOUD_REMOTE="gdrive"
                ;;
            2)
                echo "Setting up Microsoft OneDrive..."
                echo ""
                echo "Step 1: Run 'rclone config' to create a OneDrive remote"
                echo "Step 2: When prompted:"
                echo "   - Choose 'n' for new remote"
                echo "   - Name it 'onedrive'"
                echo "   - Choose 'onedrive' (Microsoft OneDrive)"
                echo "   - Leave client_id and client_secret blank"
                echo "   - Choose region (usually 'global')"
                echo "   - Choose 'n' for advanced config"
                echo "   - Choose 'y' for auto config (opens browser)"
                echo "   - Choose 'onedrive' for account type"
                echo "   - Choose your drive from the list (usually option 0)"
                echo "   - Confirm with 'y'"
                echo ""
                CLOUD_REMOTE="onedrive"
                ;;
            *)
                echo "Manual configuration selected."
                echo "Run 'rclone config' to set up your cloud provider."
                echo ""
                prompt_text "Enter the remote name you will create:" "cloud" CLOUD_REMOTE
                ;;
        esac

        if [ "$UNATTENDED" != true ]; then
            echo "Press Enter to launch rclone config..."
            read
            sudo -u "$ACTUAL_USER" rclone config
        else
            echo "Skipping interactive rclone config (unattended mode)"
            echo "Run 'rclone config' manually to complete setup"
        fi

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "ENCRYPTION SETUP"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Now we'll create an encrypted wrapper around your cloud storage."
        echo "This encrypts file names AND contents before upload."
        echo ""
        echo "⚠️  IMPORTANT: You will set a password. Without this password and"
        echo "   the rclone config file, your files CANNOT be recovered!"
        echo ""

        if [ "$UNATTENDED" != true ]; then
            echo "In rclone config:"
            echo "   - Choose 'n' for new remote"
            echo "   - Name it '${CLOUD_REMOTE}-crypt'"
            echo "   - Choose 'crypt' (Encrypt/Decrypt)"
            echo "   - Remote: '${CLOUD_REMOTE}:backup' (folder on cloud storage)"
            echo "   - Choose 'standard' for filename encryption"
            echo "   - Choose 'true' for directory name encryption"
            echo "   - Choose 'y' to enter your own password"
            echo "   - Enter a STRONG password (you'll need this to decrypt!)"
            echo "   - Choose 'y' for salt password (or 'n' to skip)"
            echo "   - Confirm with 'y'"
            echo ""
            echo "Press Enter to continue rclone config..."
            read
            sudo -u "$ACTUAL_USER" rclone config
        fi

        # Backup the rclone config to local drives
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "BACKUP YOUR RCLONE CONFIG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Your rclone config contains your encryption keys."
        echo "WITHOUT IT, YOUR ENCRYPTED CLOUD FILES CANNOT BE DECRYPTED!"
        echo ""
        echo "The config file is at: $ACTUAL_HOME/.config/rclone/rclone.conf"
        echo ""

        # Copy config to any mounted backup drives
        if [ -d "$ACTUAL_HOME/drives" ]; then
            for drive_dir in "$ACTUAL_HOME/drives"/*/; do
                if [ -d "$drive_dir" ] && mountpoint -q "$drive_dir" 2>/dev/null; then
                    mkdir -p "${drive_dir}.rclone-config-backup"
                    if [ -f "$ACTUAL_HOME/.config/rclone/rclone.conf" ]; then
                        cp "$ACTUAL_HOME/.config/rclone/rclone.conf" "${drive_dir}.rclone-config-backup/rclone.conf.backup"
                        echo "✓ Config backed up to: ${drive_dir}.rclone-config-backup/"
                    fi
                fi
            done
        fi

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "SECURE OFF-SITE BACKUP OF CONFIG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "For disaster recovery, store a copy of rclone.conf OFF-SITE:"
        echo ""
        echo "Recommended secure methods:"
        echo "  • Signal (end-to-end encrypted, send to yourself or trusted contact)"
        echo "  • Box.com (better privacy policy than Dropbox)"
        echo "  • Password manager (1Password, Bitwarden, etc.)"
        echo "  • Encrypted USB drive stored at another location"
        echo ""
        echo "⚠️  Dropbox: Works but has broader data access policies."
        echo "    Consider encrypting the config file before uploading."
        echo ""
        echo "To use on another computer:"
        echo "  1. Install rclone"
        echo "  2. Copy rclone.conf to ~/.config/rclone/"
        echo "  3. Run: rclone ls ${CLOUD_REMOTE}-crypt:"
        echo ""

        # Create cloud backup script
        mkdir -p /usr/local/bin/backup-scripts

        SOURCE_PATH="${PRIMARY_NAME:-primary}"

        cat > /usr/local/bin/backup-scripts/cloud-backup.sh << CLOUD_SCRIPT
#!/bin/bash
################################################################################
# rclone Encrypted Cloud Backup Script
################################################################################

SOURCE="$ACTUAL_HOME/drives/$SOURCE_PATH"
REMOTE="${CLOUD_REMOTE:-gdrive}-crypt"
LOG="/var/log/cloud-backup.log"

echo "=== Cloud Backup Started: \$(date) ===" | tee -a "\$LOG"
echo "Source: \$SOURCE" | tee -a "\$LOG"
echo "Destination: \$REMOTE:" | tee -a "\$LOG"
echo "" | tee -a "\$LOG"

if [ ! -d "\$SOURCE" ] || [ -z "\$(ls -A \$SOURCE 2>/dev/null)" ]; then
    echo "ERROR: Source not mounted or empty at \$SOURCE" | tee -a "\$LOG"
    exit 1
fi

# Sync to encrypted cloud storage
rclone sync "\$SOURCE" "\$REMOTE:" \\
    --progress \\
    --stats=30s \\
    --log-file="\$LOG" \\
    --log-level INFO

if [ \$? -eq 0 ]; then
    echo "" | tee -a "\$LOG"
    echo "✓ Cloud backup completed: \$(date)" | tee -a "\$LOG"
else
    echo "" | tee -a "\$LOG"
    echo "✗ Cloud backup FAILED: \$(date)" | tee -a "\$LOG"
fi
CLOUD_SCRIPT

        chmod +x /usr/local/bin/backup-scripts/cloud-backup.sh
        chown "$ACTUAL_USER:$ACTUAL_USER" /usr/local/bin/backup-scripts/cloud-backup.sh

        echo ""
        echo "✓ Cloud backup script created: /usr/local/bin/backup-scripts/cloud-backup.sh"
        echo ""
        echo "Quick start:"
        echo "  Test backup:  sudo /usr/local/bin/backup-scripts/cloud-backup.sh"
        echo "  View log:     tail -f /var/log/cloud-backup.log"
    else
        echo "rclone installation failed. Skipping cloud backup setup."
    fi
else
    echo "Skipping cloud backup setup."
fi

# UFW Firewall Configuration (Optional)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "UFW FIREWALL (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "UFW (Uncomplicated Firewall) provides a simple interface for managing"
echo "iptables firewall rules."
echo ""

UFW_ACTIVE=false
if is_ufw_installed && ufw status 2>/dev/null | grep -q "Status: active"; then
    UFW_ACTIVE=true
    echo "UFW is already enabled."
    ufw status 2>/dev/null | head -20
    echo ""
    prompt_yn "Reconfigure UFW? (y/n):" "n" CONFIGURE_UFW
else
    if is_ufw_installed; then
        echo "UFW is installed but not enabled."
    else
        echo "UFW is not installed."
    fi
    echo ""
    prompt_yn "Enable and configure UFW firewall? (y/n):" "y" CONFIGURE_UFW
fi

if [ "$CONFIGURE_UFW" = "y" ] || [ "$CONFIGURE_UFW" = "Y" ]; then
    echo ""
    echo "Configuring UFW firewall..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install ufw if needed"
        echo "[DRY-RUN] Would allow SSH (port 22)"
        if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
            echo "[DRY-RUN] Would allow Samba"
        fi
        echo "[DRY-RUN] Would enable UFW"
    else
        # Install UFW if not present
        if ! is_ufw_installed; then
            apt install -y ufw || echo "Warning: UFW installation failed"
        fi

        if is_ufw_installed; then
            # Always allow SSH first (before enabling!)
            ufw allow ssh
            echo "✓ Allowed SSH (port 22)"

            # Allow Samba if installed
            if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ] || is_samba_installed; then
                ufw allow samba
                echo "✓ Allowed Samba"
            fi

            # Enable UFW (with --force to avoid prompt)
            ufw --force enable
            echo "✓ UFW firewall enabled"

            echo ""
            echo "Current UFW status:"
            ufw status
        else
            echo "✗ UFW installation failed, skipping configuration"
        fi
    fi
else
    echo "Skipping UFW configuration."
fi

CONFIGURE_UFW="${CONFIGURE_UFW:-n}"

# Full system upgrade
echo ""
echo "Performing full system upgrade..."
run_cmd apt upgrade -y

# Clean up
echo ""
echo "Cleaning up..."
run_cmd apt autoremove -y
run_cmd apt autoclean

echo ""
echo "=== Installation Complete! ==="
echo ""
echo "Installed Software:"
echo "  ✓ net-tools, ncdu, git, curl, wget, htop, tree, zip/unzip"
echo "  ✓ OpenSSH Server - SSH remote access"
if [ "$INSTALL_FAIL2BAN" = "y" ] || [ "$INSTALL_FAIL2BAN" = "Y" ]; then
    echo "  ✓ fail2ban - SSH brute-force protection"
fi
if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
    echo "  ✓ Docker Engine + Docker Compose"
fi
if [ "$INSTALL_SAMBA" = "y" ] || [ "$INSTALL_SAMBA" = "Y" ]; then
    echo "  ✓ Samba - File sharing (Primary drive shared)"
fi
if [ "$INSTALL_NETBIRD" = "y" ] || [ "$INSTALL_NETBIRD" = "Y" ]; then
    echo "  ✓ NetBird - Mesh VPN"
fi
if [ "$INSTALL_WIREGUARD" = "y" ] || [ "$INSTALL_WIREGUARD" = "Y" ]; then
    echo "  ✓ WireGuard - VPN"
fi
if [ "$INSTALL_TAILSCALE" = "y" ] || [ "$INSTALL_TAILSCALE" = "Y" ]; then
    echo "  ✓ Tailscale - Mesh VPN"
fi
if [ "$INSTALL_RUSTDESK" = "y" ] || [ "$INSTALL_RUSTDESK" = "Y" ]; then
    echo "  ✓ RustDesk - Remote desktop"
fi
if [ "$INSTALL_TEAMVIEWER" = "y" ] || [ "$INSTALL_TEAMVIEWER" = "Y" ]; then
    echo "  ✓ TeamViewer - Remote desktop"
fi
if [ "$INSTALL_MESHCENTRAL" = "y" ] || [ "$INSTALL_MESHCENTRAL" = "Y" ]; then
    echo "  ✓ MeshCentral Agent - Remote management"
fi
if [ "$SETUP_BACKUP" = "y" ] || [ "$SETUP_BACKUP" = "Y" ]; then
    echo "  ✓ Local backup configured (rsync)"
fi
if [ "$SETUP_CLOUD_BACKUP" = "y" ] || [ "$SETUP_CLOUD_BACKUP" = "Y" ]; then
    echo "  ✓ Cloud backup configured (rclone)"
fi
if [ "$CONFIGURE_UFW" = "y" ] || [ "$CONFIGURE_UFW" = "Y" ]; then
    echo "  ✓ UFW Firewall - enabled"
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
if [ "$INSTALL_FAIL2BAN" = "y" ] || [ "$INSTALL_FAIL2BAN" = "Y" ]; then
    echo "  fail2ban:"
    echo "    • Check status: sudo fail2ban-client status sshd"
    echo "    • View banned IPs: sudo fail2ban-client status sshd"
    echo "    • Unban IP: sudo fail2ban-client set sshd unbanip <IP>"
    echo ""
fi
if [ "$CONFIGURE_UFW" = "y" ] || [ "$CONFIGURE_UFW" = "Y" ]; then
    echo "  UFW Firewall:"
    echo "    • Check status: sudo ufw status"
    echo "    • Allow port: sudo ufw allow <port>"
    echo "    • Deny port: sudo ufw deny <port>"
    echo "    • Disable: sudo ufw disable"
    echo ""
fi