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
    echo "  --restore      Disaster recovery mode - restore from backup"
    echo "  --help         Show this help message"
    echo ""
    echo "Examples:"
    echo "  sudo ./post-install.sh                # Interactive mode"
    echo "  sudo ./post-install.sh --dry-run      # Preview installations"
    echo "  sudo ./post-install.sh --unattended   # Automated install"
    echo "  sudo ./post-install.sh --restore      # Disaster recovery"
    echo ""
    exit 0
}

RESTORE_MODE=false

for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --unattended)
            UNATTENDED=true
            ;;
        --restore)
            RESTORE_MODE=true
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
DOCKER_DIR="$ACTUAL_HOME/docker"

echo "Note: Script will continue even if individual packages fail to install"
echo "Log file: $LOG_FILE"
echo ""

# ============================================================================
# INSTALLATION MODE SELECTOR
# ============================================================================

INSTALL_MODE="normal"

# Disaster recovery function
run_disaster_recovery() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DISASTER RECOVERY MODE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This will restore your system and Docker apps from a Kopia backup."
    echo ""
    echo "Requirements:"
    echo "  • Backup drive connected (with kopia-repo folder)"
    echo "  • Kopia password (saved in .env or you remember it)"
    echo ""

    # Step 1: Install core utilities
    echo "Step 1: Installing core utilities"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Installing essential packages..."
    apt-get update
    apt-get install -y \
        net-tools \
        openssh-server \
        git \
        curl \
        wget \
        htop \
        ncdu \
        tree \
        zip \
        unzip \
        whiptail \
        2>/dev/null || echo "  ⚠ Some packages may have failed"

    # Start SSH
    systemctl enable ssh 2>/dev/null || true
    systemctl start ssh 2>/dev/null || true
    echo "✓ Core utilities installed"
    echo ""

    # Step 2: Find/mount backup drive
    echo "Step 2: Locate backup drive"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Available block devices:"
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null || lsblk
    echo ""

    # Check if drives are already mounted
    if [ -d "$ACTUAL_HOME/drives" ]; then
        echo "Existing mount points in ~/drives/:"
        ls -la "$ACTUAL_HOME/drives/" 2>/dev/null || echo "  (none)"
        echo ""
    fi

    read -p "Enter path to backup drive or Kopia repo (e.g., /dev/sdb1 or ~/drives/backup1): " BACKUP_PATH

    # If it's a device, mount it
    if [[ "$BACKUP_PATH" == /dev/* ]]; then
        MOUNT_POINT="$ACTUAL_HOME/drives/restore-backup"
        mkdir -p "$MOUNT_POINT" 2>/dev/null
        echo "Mounting $BACKUP_PATH to $MOUNT_POINT..."
        mount "$BACKUP_PATH" "$MOUNT_POINT" || { echo "Failed to mount. Check device path."; return 1; }
        BACKUP_PATH="$MOUNT_POINT"
    fi

    # Expand ~ to home directory
    BACKUP_PATH="${BACKUP_PATH/#\~/$ACTUAL_HOME}"

    # Look for kopia-repo
    KOPIA_REPO=""
    if [ -d "$BACKUP_PATH/kopia-repo" ]; then
        KOPIA_REPO="$BACKUP_PATH/kopia-repo"
    elif [ -d "$BACKUP_PATH/kopia.repository" ] || [ -f "$BACKUP_PATH/kopia.repository.f" ]; then
        KOPIA_REPO="$BACKUP_PATH"
    else
        echo ""
        echo "Looking for Kopia repository..."
        FOUND_REPO=$(find "$BACKUP_PATH" -maxdepth 3 -name "kopia.repository*" -type f 2>/dev/null | head -1)
        if [ -n "$FOUND_REPO" ]; then
            KOPIA_REPO=$(dirname "$FOUND_REPO")
        fi
    fi

    if [ -z "$KOPIA_REPO" ] || [ ! -d "$KOPIA_REPO" ]; then
        echo "❌ Could not find Kopia repository at $BACKUP_PATH"
        echo "   Look for a folder containing 'kopia.repository' files"
        return 1
    fi

    echo "✓ Found Kopia repository at: $KOPIA_REPO"
    echo ""

    # Step 3: Get Kopia password
    echo "Step 3: Kopia password"
    echo "━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Try to find password in backed-up .env
    if [ -f "$BACKUP_PATH/kopia/.env" ]; then
        KOPIA_PASS=$(grep "KOPIA_PASSWORD" "$BACKUP_PATH/kopia/.env" 2>/dev/null | cut -d= -f2)
        if [ -n "$KOPIA_PASS" ]; then
            echo "Found password in backup. Use this? (y/n)"
            read -p "> " USE_FOUND_PASS
            [ "$USE_FOUND_PASS" != "y" ] && KOPIA_PASS=""
        fi
    fi

    if [ -z "$KOPIA_PASS" ]; then
        read -s -p "Enter Kopia repository password: " KOPIA_PASS
        echo ""
    fi

    # Step 4: Install Docker if needed
    echo ""
    echo "Step 4: Ensure Docker is installed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        apt-get update
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        usermod -aG docker "$ACTUAL_USER"
        echo "✓ Docker installed"
    else
        echo "✓ Docker already installed"
    fi
    echo ""

    # Step 5: List snapshots and let user choose
    echo "Step 5: Select snapshot to restore"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Connecting to repository and listing snapshots..."
    echo ""

    # Use docker to run kopia
    SNAPSHOT_LIST=$(docker run --rm \
        -v "$KOPIA_REPO:/repository" \
        -e KOPIA_PASSWORD="$KOPIA_PASS" \
        kopia/kopia:latest \
        snapshot list --all 2>&1)

    if echo "$SNAPSHOT_LIST" | grep -q "invalid password"; then
        echo "❌ Invalid password"
        return 1
    fi

    echo "$SNAPSHOT_LIST"
    echo ""
    read -p "Enter snapshot ID to restore (or 'latest' for most recent): " SNAPSHOT_ID

    if [ "$SNAPSHOT_ID" = "latest" ]; then
        SNAPSHOT_ID=$(echo "$SNAPSHOT_LIST" | grep -oE "^[a-f0-9]+" | tail -1)
        echo "Using latest snapshot: $SNAPSHOT_ID"
    fi

    # Step 6: Restore to temp location
    echo ""
    echo "Step 6: Restoring from backup"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    RESTORE_TEMP="$ACTUAL_HOME/docker-restore-temp"
    mkdir -p "$RESTORE_TEMP"

    echo "Restoring to $RESTORE_TEMP..."
    docker run --rm \
        -v "$KOPIA_REPO:/repository" \
        -v "$RESTORE_TEMP:/restore" \
        -e KOPIA_PASSWORD="$KOPIA_PASS" \
        kopia/kopia:latest \
        restore "$SNAPSHOT_ID" /restore

    if [ $? -ne 0 ]; then
        echo "❌ Restore failed"
        return 1
    fi
    echo "✓ Snapshot restored to temp location"
    echo ""

    # Step 7: Detect and select services to restore
    echo "Step 7: Select services to restore"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    mkdir -p "$DOCKER_DIR"

    # Find all docker-compose.yml files in restored backup
    declare -A SERVICE_DIRS
    SERVICES_FOUND=()
    for compose_file in $(find "$RESTORE_TEMP" -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null); do
        SERVICE_DIR=$(dirname "$compose_file")
        SERVICE_NAME=$(basename "$SERVICE_DIR")
        SERVICES_FOUND+=("$SERVICE_NAME")
        SERVICE_DIRS["$SERVICE_NAME"]="$SERVICE_DIR"
    done

    if [ ${#SERVICES_FOUND[@]} -eq 0 ]; then
        echo "No Docker services found in backup"
    else
        echo "Found ${#SERVICES_FOUND[@]} services in backup."
        echo ""

        # Check if whiptail is available for nice UI
        if command -v whiptail &> /dev/null; then
            # Build whiptail checklist arguments
            CHECKLIST_ARGS=()
            for svc in "${SERVICES_FOUND[@]}"; do
                CHECKLIST_ARGS+=("$svc" "" "ON")
            done

            # Show checklist - returns selected items
            SELECTED=$(whiptail --title "Select Services to Restore" \
                --checklist "Use SPACE to select/deselect, ENTER to confirm:" \
                20 60 12 \
                "${CHECKLIST_ARGS[@]}" \
                3>&1 1>&2 2>&3)

            # Parse selected services (whiptail returns quoted strings)
            SELECTED_SERVICES=()
            for item in $SELECTED; do
                # Remove quotes
                svc=$(echo "$item" | tr -d '"')
                SELECTED_SERVICES+=("$svc")
            done
        else
            # Fallback: text-based selection
            echo "Select services to restore:"
            echo "  [A] All services"
            echo "  [N] None (skip restore)"
            echo "  [S] Select individually"
            echo ""
            read -p "Choice (A/N/S) [A]: " RESTORE_CHOICE

            case "${RESTORE_CHOICE^^}" in
                N)
                    SELECTED_SERVICES=()
                    ;;
                S)
                    SELECTED_SERVICES=()
                    for svc in "${SERVICES_FOUND[@]}"; do
                        read -p "  Restore $svc? (y/n) [y]: " RESTORE_SVC
                        if [ "$RESTORE_SVC" != "n" ] && [ "$RESTORE_SVC" != "N" ]; then
                            SELECTED_SERVICES+=("$svc")
                        fi
                    done
                    ;;
                *)
                    SELECTED_SERVICES=("${SERVICES_FOUND[@]}")
                    ;;
            esac
        fi

        # Restore selected services
        echo ""
        if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
            echo "No services selected for restore."
        else
            echo "Restoring ${#SELECTED_SERVICES[@]} services..."
            echo ""
            for svc in "${SELECTED_SERVICES[@]}"; do
                SERVICE_DIR="${SERVICE_DIRS[$svc]}"
                TARGET_DIR="$DOCKER_DIR/$svc"

                echo "  Restoring $svc..."

                # Copy entire service directory
                cp -r "$SERVICE_DIR" "$TARGET_DIR" 2>/dev/null || true

                # Fix ownership
                chown -R "$ACTUAL_USER:$ACTUAL_USER" "$TARGET_DIR" 2>/dev/null || true

                echo "    ✓ $svc restored to $TARGET_DIR"
            done
        fi
    fi

    # Step 8: Start services
    echo ""
    echo "Step 8: Starting services"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Count restored services
    RESTORED_COUNT=0
    for dir in "$DOCKER_DIR"/*/; do
        if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/compose.yml" ]; then
            ((RESTORED_COUNT++))
        fi
    done

    if [ $RESTORED_COUNT -eq 0 ]; then
        echo "No services to start."
    else
        echo "Start restored services?"
        echo "  [A] All services"
        echo "  [S] Select which to start"
        echo "  [N] None (start manually later)"
        echo ""
        read -p "Choice (A/S/N) [A]: " START_CHOICE

        case "${START_CHOICE^^}" in
            N)
                echo "Services not started. Start manually with:"
                echo "  cd ~/docker/{service} && docker compose up -d"
                ;;
            S)
                for dir in "$DOCKER_DIR"/*/; do
                    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/compose.yml" ]; then
                        SERVICE_NAME=$(basename "$dir")
                        read -p "  Start $SERVICE_NAME? (y/n) [y]: " START_SVC
                        if [ "$START_SVC" != "n" ] && [ "$START_SVC" != "N" ]; then
                            echo "    Starting $SERVICE_NAME..."
                            (cd "$dir" && docker compose up -d 2>/dev/null) || echo "    ⚠ Failed to start $SERVICE_NAME"
                        fi
                    fi
                done
                ;;
            *)
                for dir in "$DOCKER_DIR"/*/; do
                    if [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/compose.yml" ]; then
                        SERVICE_NAME=$(basename "$dir")
                        echo "  Starting $SERVICE_NAME..."
                        (cd "$dir" && docker compose up -d 2>/dev/null) || echo "    ⚠ Failed to start $SERVICE_NAME"
                    fi
                done
                ;;
        esac
    fi

    # Cleanup
    echo ""
    read -p "Remove temporary restore files? (y/n): " CLEANUP
    if [ "$CLEANUP" = "y" ]; then
        rm -rf "$RESTORE_TEMP"
        echo "✓ Cleaned up temp files"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DISASTER RECOVERY COMPLETE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Services restored to: $DOCKER_DIR"
    echo ""
    echo "To check running containers:"
    echo "  docker ps"
    echo ""
    echo "To view logs:"
    echo "  docker compose logs -f"
    echo ""
    echo "⚠️  Some services may need manual configuration:"
    echo "  • Frigate: Edit config/config.yml with camera URLs"
    echo "  • Caddy: Update Caddyfile with your domain"
    echo "  • ddclient: Edit config/ddclient.conf with DNS credentials"
    echo ""

    return 0
}

# Check for restore mode flag
if [ "$RESTORE_MODE" = true ]; then
    run_disaster_recovery
    exit $?
fi

# Interactive mode selector (if not unattended)
if [ "$UNATTENDED" != true ]; then
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "INSTALLATION MODE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  [N] Normal install - Fresh install or modify existing"
    echo "  [R] Disaster recovery - Restore from Kopia backup"
    echo ""
    read -p "Select mode (N/R) [N]: " MODE_SELECT

    case "${MODE_SELECT^^}" in
        R)
            run_disaster_recovery
            exit $?
            ;;
        *)
            INSTALL_MODE="normal"
            ;;
    esac
    echo ""
fi

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
            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "ADDING MORE SAMBA SHARES"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "To add another share, edit the Samba config file:"
            echo ""
            echo "  sudo nano /etc/samba/smb.conf"
            echo ""
            echo "Add a new section at the end:"
            echo ""
            echo "  [ShareName]"
            echo "     comment = Description of share"
            echo "     path = /path/to/folder"
            echo "     browseable = yes"
            echo "     read only = no"
            echo "     writable = yes"
            echo "     valid users = $ACTUAL_USER"
            echo "     create mask = 0775"
            echo "     directory mask = 0775"
            echo ""
            echo "Save (Ctrl+O, Enter) and exit (Ctrl+X), then restart Samba:"
            echo ""
            echo "  sudo systemctl restart smbd nmbd"
            echo ""
            echo "Verify the share is active:"
            echo ""
            echo "  testparm -s"
            echo ""
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

# ============================================================================
# SELF-HOSTED DOCKER APPLICATIONS (Optional)
# ============================================================================
# These applications run in Docker containers using docker-compose
# Each app is installed to ~/docker/{appname}/

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "SELF-HOSTED DOCKER APPLICATIONS (Optional)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Install self-hosted applications using Docker Compose."
echo "Each app will be installed to ~/docker/{appname}/"
echo ""
echo "Note: Docker must be installed for these applications."
echo ""

if ! is_docker_installed && [ "$INSTALL_DOCKER" != "y" ] && [ "$INSTALL_DOCKER" != "Y" ]; then
    echo "Docker is not installed. Skipping self-hosted applications."
    echo "Install Docker first, then rerun this script."
else
    # Create docker apps directory
    DOCKER_DIR="$ACTUAL_HOME/docker"
    if [ "$DRY_RUN" != true ]; then
        mkdir -p "$DOCKER_DIR"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$DOCKER_DIR"
    fi

    # ---- IMMICH ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ IMMICH - Self-hosted photo & video backup                       │"
    echo "│ Like Google Photos but private. Mobile app auto-uploads.        │"
    echo "│ Port: 2283                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Immich? (y/n):" "n" INSTALL_IMMICH

    if [ "$INSTALL_IMMICH" = "y" ] || [ "$INSTALL_IMMICH" = "Y" ]; then
        echo "Installing Immich..."
        IMMICH_DIR="$DOCKER_DIR/immich"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $IMMICH_DIR"
            echo "[DRY-RUN] Would create docker-compose.yml and .env"
        else
            mkdir -p "$IMMICH_DIR"
            cd "$IMMICH_DIR"

            # Create docker-compose.yml
            cat > docker-compose.yml << 'IMMICH_COMPOSE'
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    env_file:
      - .env
    ports:
      - 2283:2283
    depends_on:
      - redis
      - database
    restart: always
    healthcheck:
      disable: false

  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:${IMMICH_VERSION:-release}
    volumes:
      - model-cache:/cache
    env_file:
      - .env
    restart: always
    healthcheck:
      disable: false

  redis:
    container_name: immich_redis
    image: docker.io/valkey/valkey:8-bookworm
    healthcheck:
      test: valkey-cli ping || exit 1
    restart: always

  database:
    container_name: immich_postgres
    image: docker.io/tensorchord/pgvecto-rs:pg14-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
      POSTGRES_INITDB_ARGS: '--data-checksums'
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready --dbname='${DB_DATABASE_NAME}' --username='${DB_USERNAME}' || exit 1; Chksum="$$(psql --dbname='${DB_DATABASE_NAME}' --username='${DB_USERNAME}' --tuples-only --no-align --command='SELECT COALESCE(SUM(googlechecksum(googlechecksum(SPLIT_PART(googlechecksum::text, ''x'', 2)::bit(32)::int)), 0) FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = ''public'' AND c.relkind = ''r''')"; echo "googlechecksum: $$Chksum"; exit 0
      interval: 5m
      start_interval: 30s
      start_period: 5m
    command: ["postgres", "-c", "shared_preload_libraries=vectors.so", "-c", 'search_path="$$user", public, vectors', "-c", "logging_collector=on", "-c", "max_wal_size=2GB", "-c", "shared_buffers=512MB", "-c", "wal_compression=on"]
    restart: always

volumes:
  model-cache:
IMMICH_COMPOSE

            # Generate random password
            DB_PASS=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

            # Create .env file
            cat > .env << IMMICH_ENV
# Immich Configuration
UPLOAD_LOCATION=./library
DB_DATA_LOCATION=./postgres

IMMICH_VERSION=release

DB_PASSWORD=$DB_PASS
DB_USERNAME=postgres
DB_DATABASE_NAME=immich

TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
IMMICH_ENV

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$IMMICH_DIR"

            echo ""
            echo "✓ Immich configured at $IMMICH_DIR"
            echo "  Start with: cd $IMMICH_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:2283"
            echo ""
        fi
    fi

    # ---- AUDIOBOOKSHELF ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ AUDIOBOOKSHELF - Audiobook & podcast server                     │"
    echo "│ Stream audiobooks with progress sync across devices.            │"
    echo "│ Port: 13378                                                     │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Audiobookshelf? (y/n):" "n" INSTALL_AUDIOBOOKSHELF

    if [ "$INSTALL_AUDIOBOOKSHELF" = "y" ] || [ "$INSTALL_AUDIOBOOKSHELF" = "Y" ]; then
        echo "Installing Audiobookshelf..."
        ABS_DIR="$DOCKER_DIR/audiobookshelf"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $ABS_DIR"
        else
            mkdir -p "$ABS_DIR"
            cd "$ABS_DIR"

            prompt_text "Path to audiobooks folder [default: $ACTUAL_HOME/drives/primary/audiobooks]:" "$ACTUAL_HOME/drives/primary/audiobooks" AUDIOBOOKS_PATH

            cat > docker-compose.yml << ABS_COMPOSE
name: audiobookshelf

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    hostname: audiobookshelf
    restart: unless-stopped
    environment:
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ./config:/config
      - ./metadata:/metadata
      - ${AUDIOBOOKS_PATH}:/audiobooks
      - ${PODCASTS_PATH:-./podcasts}:/podcasts
    ports:
      - "13378:80"
ABS_COMPOSE

            cat > .env << ABS_ENV
AUDIOBOOKS_PATH=$AUDIOBOOKS_PATH
PODCASTS_PATH=./podcasts
ABS_ENV

            mkdir -p config metadata podcasts
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ABS_DIR"

            echo ""
            echo "✓ Audiobookshelf configured at $ABS_DIR"
            echo "  Start with: cd $ABS_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:13378"
            echo ""
        fi
    fi

    # ---- EMBY ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ EMBY - Media server for movies, TV, music                       │"
    echo "│ Stream your media library to any device.                        │"
    echo "│ Port: 8096 (web), 8920 (https)                                  │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Emby? (y/n):" "n" INSTALL_EMBY

    if [ "$INSTALL_EMBY" = "y" ] || [ "$INSTALL_EMBY" = "Y" ]; then
        echo "Installing Emby..."
        EMBY_DIR="$DOCKER_DIR/emby"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $EMBY_DIR"
        else
            mkdir -p "$EMBY_DIR"
            cd "$EMBY_DIR"

            prompt_text "Path to media folder [default: $ACTUAL_HOME/drives/primary/media]:" "$ACTUAL_HOME/drives/primary/media" MEDIA_PATH

            cat > docker-compose.yml << EMBY_COMPOSE
name: emby

services:
  emby:
    image: emby/embyserver:latest
    container_name: emby
    hostname: emby
    restart: unless-stopped
    environment:
      - UID=$(id -u "$ACTUAL_USER")
      - GID=$(id -g "$ACTUAL_USER")
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ./config:/config
      - ${MEDIA_PATH}:/media
    ports:
      - "8096:8096"
      - "8920:8920"
    # Uncomment for hardware transcoding (Intel/AMD)
    # devices:
    #   - /dev/dri:/dev/dri
EMBY_COMPOSE

            cat > .env << EMBY_ENV
MEDIA_PATH=$MEDIA_PATH
EMBY_ENV

            mkdir -p config
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EMBY_DIR"

            echo ""
            echo "✓ Emby configured at $EMBY_DIR"
            echo "  Start with: cd $EMBY_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8096"
            echo ""
        fi
    fi

    # ---- A.R.M. (Automatic Ripping Machine) ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ A.R.M. - Automatic Ripping Machine                              │"
    echo "│ Automatically rip DVDs, Blu-rays, and CDs.                      │"
    echo "│ Port: 8080                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install A.R.M.? (y/n):" "n" INSTALL_ARM

    if [ "$INSTALL_ARM" = "y" ] || [ "$INSTALL_ARM" = "Y" ]; then
        echo "Installing A.R.M...."
        ARM_DIR="$DOCKER_DIR/arm"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $ARM_DIR"
        else
            mkdir -p "$ARM_DIR"
            cd "$ARM_DIR"

            prompt_text "Path for ripped media output [default: $ACTUAL_HOME/drives/primary/ripped]:" "$ACTUAL_HOME/drives/primary/ripped" ARM_OUTPUT

            # Detect optical drives
            echo ""
            echo "Detecting optical drives..."
            OPTICAL_DRIVES=$(ls /dev/sr* 2>/dev/null || echo "")
            if [ -n "$OPTICAL_DRIVES" ]; then
                echo "Found: $OPTICAL_DRIVES"
            else
                echo "No optical drives detected. You can add them later."
                OPTICAL_DRIVES="/dev/sr0"
            fi

            cat > docker-compose.yml << ARM_COMPOSE
name: arm

services:
  automatic-ripping-machine:
    image: automaticrippingmachine/automatic-ripping-machine:latest
    container_name: arm
    hostname: arm
    restart: unless-stopped
    environment:
      - ARM_UID=$(id -u "$ACTUAL_USER")
      - ARM_GID=$(id -g "$ACTUAL_USER")
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ./config:/etc/arm/config
      - ./logs:/home/arm/logs
      - ${ARM_OUTPUT}/movies:/home/arm/media/completed
      - ${ARM_OUTPUT}/music:/home/arm/music
    ports:
      - "8080:8080"
    devices:
      - /dev/sr0:/dev/sr0
      # Add more drives as needed:
      # - /dev/sr1:/dev/sr1
    privileged: true
ARM_COMPOSE

            cat > .env << ARM_ENV
ARM_OUTPUT=$ARM_OUTPUT
ARM_ENV

            mkdir -p config logs
            mkdir -p "$ARM_OUTPUT/movies" "$ARM_OUTPUT/music"
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ARM_DIR"

            echo ""
            echo "✓ A.R.M. configured at $ARM_DIR"
            echo "  Start with: cd $ARM_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8080"
            echo "  Note: Edit docker-compose.yml to add more optical drives"
            echo ""
        fi
    fi

    # ---- FILEBROWSER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ FILEBROWSER - Web-based file manager                            │"
    echo "│ Browse, upload, download files via web interface.               │"
    echo "│ Port: 8085                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Filebrowser? (y/n):" "n" INSTALL_FILEBROWSER

    if [ "$INSTALL_FILEBROWSER" = "y" ] || [ "$INSTALL_FILEBROWSER" = "Y" ]; then
        echo "Installing Filebrowser..."
        FB_DIR="$DOCKER_DIR/filebrowser"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $FB_DIR"
        else
            mkdir -p "$FB_DIR"
            cd "$FB_DIR"

            prompt_text "Path to browse [default: $ACTUAL_HOME/drives/primary]:" "$ACTUAL_HOME/drives/primary" FB_PATH

            cat > docker-compose.yml << FB_COMPOSE
name: filebrowser

services:
  filebrowser:
    image: filebrowser/filebrowser:s6
    container_name: filebrowser
    hostname: filebrowser
    restart: unless-stopped
    environment:
      - PUID=$(id -u "$ACTUAL_USER")
      - PGID=$(id -g "$ACTUAL_USER")
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ${FB_PATH}:/srv
      - ./database/filebrowser.db:/database/filebrowser.db
      - ./config/settings.json:/config/settings.json
    ports:
      - "8085:80"
FB_COMPOSE

            cat > .env << FB_ENV
FB_PATH=$FB_PATH
FB_ENV

            mkdir -p database config
            touch database/filebrowser.db
            cat > config/settings.json << 'FB_SETTINGS'
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
FB_SETTINGS

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR"

            echo ""
            echo "✓ Filebrowser configured at $FB_DIR"
            echo "  Start with: cd $FB_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8085"
            echo "  Default login: admin / admin (change immediately!)"
            echo ""
        fi
    fi

    # ---- MAGIC MIRROR ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ MAGIC MIRROR - Smart mirror / dashboard display                 │"
    echo "│ Modular smart mirror platform. Run up to 3 instances.           │"
    echo "│ Ports: 8081, 8082, 8083                                         │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Magic Mirror? (y/n):" "n" INSTALL_MAGICMIRROR

    if [ "$INSTALL_MAGICMIRROR" = "y" ] || [ "$INSTALL_MAGICMIRROR" = "Y" ]; then
        echo ""
        prompt_text "How many Magic Mirror instances? [1-3, default: 1]:" "1" MM_COUNT
        MM_COUNT=${MM_COUNT:-1}
        if [ "$MM_COUNT" -gt 3 ]; then MM_COUNT=3; fi
        if [ "$MM_COUNT" -lt 1 ]; then MM_COUNT=1; fi

        echo "Installing $MM_COUNT Magic Mirror instance(s)..."

        for i in $(seq 1 $MM_COUNT); do
            MM_PORT=$((8080 + i))
            MM_DIR="$DOCKER_DIR/magicmirror-$MM_PORT"

            if [ "$DRY_RUN" = true ]; then
                echo "[DRY-RUN] Would create $MM_DIR (port $MM_PORT)"
            else
                mkdir -p "$MM_DIR"
                cd "$MM_DIR"

                cat > docker-compose.yml << MM_COMPOSE
name: mm-$MM_PORT

services:
  magicmirror:
    image: karsten13/magicmirror:latest
    container_name: magicmirror-$MM_PORT
    hostname: magicmirror-$MM_PORT
    restart: unless-stopped
    environment:
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ./config:/opt/magic_mirror/config
      - ./modules:/opt/magic_mirror/modules
      - ./css:/opt/magic_mirror/css
    ports:
      - "$MM_PORT:8080"
MM_COMPOSE

                mkdir -p config modules css

                # Create basic config.js
                cat > config/config.js << 'MM_CONFIG'
let config = {
    address: "0.0.0.0",
    port: 8080,
    ipWhitelist: [],
    language: "en",
    timeFormat: 12,
    units: "imperial",
    modules: [
        {
            module: "alert",
        },
        {
            module: "clock",
            position: "top_left"
        },
        {
            module: "calendar",
            header: "Calendar",
            position: "top_left",
            config: {
                calendars: [
                    {
                        symbol: "calendar-check",
                        url: "webcal://www.calendarlabs.com/ical-calendar/ics/76/US_Holidays.ics"
                    }
                ]
            }
        },
        {
            module: "weather",
            position: "top_right",
            config: {
                weatherProvider: "openmeteo",
                type: "current",
                lat: 40.7128,
                lon: -74.0060
            }
        },
        {
            module: "weather",
            position: "top_right",
            header: "Weather Forecast",
            config: {
                weatherProvider: "openmeteo",
                type: "forecast",
                lat: 40.7128,
                lon: -74.0060
            }
        },
        {
            module: "newsfeed",
            position: "bottom_bar",
            config: {
                feeds: [
                    {
                        title: "BBC",
                        url: "https://feeds.bbci.co.uk/news/rss.xml"
                    }
                ],
                showSourceTitle: true,
                showPublishDate: true,
                broadcastNewsFeeds: true,
                broadcastNewsUpdates: true
            }
        },
    ]
};

/*************** DO NOT EDIT THE LINE BELOW ***************/
if (typeof module !== "undefined") {module.exports = config;}
MM_CONFIG

                chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MM_DIR"

                echo "  ✓ Magic Mirror #$i configured at $MM_DIR (port $MM_PORT)"
            fi
        done

        if [ "$DRY_RUN" != true ]; then
            echo ""
            echo "  Start with: cd ~/docker/magicmirror-808X && docker compose up -d"
            echo "  Access at:  http://localhost:808X"
            echo "  Edit config: ~/docker/magicmirror-808X/config/config.js"
            echo ""
        fi
    fi

    # ---- LYRION MUSIC SERVER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ LYRION MUSIC SERVER (LMS) - Music streaming server              │"
    echo "│ Stream music to Squeezebox devices, apps, and Chromecast.       │"
    echo "│ Port: 9000 (web), 9090 (CLI), 3483 (players)                    │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Lyrion Music Server? (y/n):" "n" INSTALL_LMS

    if [ "$INSTALL_LMS" = "y" ] || [ "$INSTALL_LMS" = "Y" ]; then
        echo "Installing Lyrion Music Server..."
        LMS_DIR="$DOCKER_DIR/lyrion"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $LMS_DIR"
        else
            mkdir -p "$LMS_DIR"
            cd "$LMS_DIR"

            prompt_text "Path to music folder [default: $ACTUAL_HOME/drives/primary/music]:" "$ACTUAL_HOME/drives/primary/music" MUSIC_PATH

            cat > docker-compose.yml << LMS_COMPOSE
name: lyrion

services:
  lyrion:
    image: lmscommunity/lyrionmusicserver:stable
    container_name: lyrion
    hostname: lyrion
    restart: unless-stopped
    network_mode: host
    environment:
      - HTTP_PORT=9000
      - PUID=$(id -u "$ACTUAL_USER")
      - PGID=$(id -g "$ACTUAL_USER")
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    volumes:
      - ./config:/config:rw
      - ${MUSIC_PATH}:/music:ro
      - ./playlists:/playlists:rw
      - /etc/localtime:/etc/localtime:ro
LMS_COMPOSE

            cat > .env << LMS_ENV
MUSIC_PATH=$MUSIC_PATH
LMS_ENV

            mkdir -p config playlists
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LMS_DIR"

            echo ""
            echo "✓ Lyrion Music Server configured at $LMS_DIR"
            echo "  Start with: cd $LMS_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:9000"
            echo "  Note: Uses host networking for Chromecast support"
            echo ""
        fi
    fi

    # ---- MEALIE ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ MEALIE - Recipe manager & meal planner                          │"
    echo "│ Save recipes, plan meals, generate shopping lists.              │"
    echo "│ Port: 9925                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Mealie? (y/n):" "n" INSTALL_MEALIE

    if [ "$INSTALL_MEALIE" = "y" ] || [ "$INSTALL_MEALIE" = "Y" ]; then
        echo "Installing Mealie..."
        MEALIE_DIR="$DOCKER_DIR/mealie"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $MEALIE_DIR"
        else
            mkdir -p "$MEALIE_DIR"
            cd "$MEALIE_DIR"

            cat > docker-compose.yml << MEALIE_COMPOSE
name: mealie

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:latest
    container_name: mealie
    hostname: mealie
    restart: unless-stopped
    environment:
      - PUID=$(id -u "$ACTUAL_USER")
      - PGID=$(id -g "$ACTUAL_USER")
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
      - ALLOW_SIGNUP=true
      - MAX_WORKERS=1
      - WEB_CONCURRENCY=1
      - BASE_URL=http://localhost:9925
    volumes:
      - ./data:/app/data
    ports:
      - "9925:9000"
MEALIE_COMPOSE

            mkdir -p data
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MEALIE_DIR"

            echo ""
            echo "✓ Mealie configured at $MEALIE_DIR"
            echo "  Start with: cd $MEALIE_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:9925"
            echo "  Default:    changeme@email.com / MyPassword"
            echo ""
        fi
    fi

    # ---- MINECRAFT SERVER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ MINECRAFT SERVER - Game server with RAM limit                   │"
    echo "│ Fabric server with configurable memory allocation.              │"
    echo "│ Port: 25565                                                     │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Minecraft Server? (y/n):" "n" INSTALL_MINECRAFT

    if [ "$INSTALL_MINECRAFT" = "y" ] || [ "$INSTALL_MINECRAFT" = "Y" ]; then
        echo "Installing Minecraft Server..."
        MC_DIR="$DOCKER_DIR/minecraft"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $MC_DIR"
        else
            mkdir -p "$MC_DIR"
            cd "$MC_DIR"

            echo ""
            prompt_text "Maximum RAM for Minecraft (e.g., 2G, 4G) [default: 2G]:" "2G" MC_RAM
            MC_RAM=${MC_RAM:-2G}

            cat > docker-compose.yml << MC_COMPOSE
name: minecraft

services:
  minecraft:
    image: itzg/minecraft-server:latest
    container_name: minecraft
    hostname: minecraft
    restart: unless-stopped
    tty: true
    stdin_open: true
    environment:
      - EULA=TRUE
      - TYPE=FABRIC
      - VERSION=LATEST
      - MEMORY=${MC_RAM}
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
      - OPS=
      - MOTD=A Minecraft Server
      - DIFFICULTY=normal
      - MODE=survival
    volumes:
      - ./data:/data
    ports:
      - "25565:25565"
    deploy:
      resources:
        limits:
          memory: ${MC_RAM}
MC_COMPOSE

            cat > .env << MC_ENV
MC_RAM=$MC_RAM
MC_ENV

            mkdir -p data
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR"

            echo ""
            echo "✓ Minecraft Server configured at $MC_DIR"
            echo "  Start with: cd $MC_DIR && docker compose up -d"
            echo "  Connect:    localhost:25565"
            echo "  RAM limit:  $MC_RAM"
            echo "  Console:    docker attach minecraft (Ctrl+P, Ctrl+Q to detach)"
            echo ""
        fi
    fi

    # ---- LINUX-TO-SYNC (Private Repo) ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ LINUX-TO-SYNC - Private sync repository                         │"
    echo "│ Clone and set up your private linux-to-sync repository.         │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""
    echo "Note: This requires access to github.com/outis1one/linux-to-sync"
    echo ""
    echo "To grant access, you need ONE of these:"
    echo "  1. SSH key already added to your GitHub account"
    echo "  2. GitHub Personal Access Token (PAT)"
    echo "  3. GitHub CLI (gh) authenticated"
    echo ""
    prompt_yn "Set up linux-to-sync? (y/n):" "n" INSTALL_LINUXTOSYNC

    if [ "$INSTALL_LINUXTOSYNC" = "y" ] || [ "$INSTALL_LINUXTOSYNC" = "Y" ]; then
        SYNC_DIR="$DOCKER_DIR/linux-to-sync"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would clone linux-to-sync to $SYNC_DIR"
        else
            echo ""
            echo "Choose authentication method:"
            echo "  [1] SSH (if you have SSH key added to GitHub)"
            echo "  [2] HTTPS with token (requires Personal Access Token)"
            echo ""
            prompt_text "Enter 1 or 2 [default: 1]:" "1" AUTH_METHOD

            if [ "$AUTH_METHOD" = "2" ]; then
                echo ""
                echo "Create a Personal Access Token at:"
                echo "  https://github.com/settings/tokens/new"
                echo "  - Select 'repo' scope for full repository access"
                echo ""
                prompt_text "Enter your GitHub Personal Access Token:" "" GH_TOKEN

                if [ -n "$GH_TOKEN" ]; then
                    git clone "https://$GH_TOKEN@github.com/outis1one/linux-to-sync.git" "$SYNC_DIR" 2>/dev/null
                    if [ $? -eq 0 ]; then
                        # Remove token from remote URL for security
                        cd "$SYNC_DIR"
                        git remote set-url origin "https://github.com/outis1one/linux-to-sync.git"
                        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SYNC_DIR"
                        echo ""
                        echo "✓ linux-to-sync cloned to $SYNC_DIR"
                        echo "  Note: You'll need to enter token again for push/pull"
                        echo "  Or set up: git config credential.helper store"
                    else
                        echo "✗ Clone failed. Check your token and try again."
                    fi
                else
                    echo "No token provided. Skipping."
                fi
            else
                echo ""
                echo "Attempting SSH clone..."
                echo "(Make sure your SSH key is added to GitHub)"
                echo ""
                git clone git@github.com:outis1one/linux-to-sync.git "$SYNC_DIR" 2>/dev/null
                if [ $? -eq 0 ]; then
                    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SYNC_DIR"
                    echo ""
                    echo "✓ linux-to-sync cloned to $SYNC_DIR"
                else
                    echo ""
                    echo "✗ SSH clone failed."
                    echo ""
                    echo "To add your SSH key to GitHub:"
                    echo "  1. Copy your public key: cat ~/.ssh/id_rsa.pub"
                    echo "  2. Go to: https://github.com/settings/keys"
                    echo "  3. Click 'New SSH key' and paste your key"
                    echo ""
                    echo "Then retry this script or manually clone:"
                    echo "  git clone git@github.com:outis1one/linux-to-sync.git ~/docker/linux-to-sync"
                fi
            fi
        fi
    fi

    # ---- JELLYFIN (Alternative to Emby) ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ JELLYFIN - Free media server (alternative to Emby)              │"
    echo "│ Stream movies, TV, music. No premium features locked.           │"
    echo "│ Port: 8096                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Jellyfin? (y/n):" "n" INSTALL_JELLYFIN

    if [ "$INSTALL_JELLYFIN" = "y" ] || [ "$INSTALL_JELLYFIN" = "Y" ]; then
        echo "Installing Jellyfin..."
        JELLYFIN_DIR="$DOCKER_DIR/jellyfin"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $JELLYFIN_DIR"
        else
            mkdir -p "$JELLYFIN_DIR"
            cd "$JELLYFIN_DIR"

            prompt_text "Path to media folder [default: $ACTUAL_HOME/drives/primary/media]:" "$ACTUAL_HOME/drives/primary/media" MEDIA_PATH

            # Get render group ID for hardware acceleration
            RENDER_GID=$(getent group render | cut -d: -f3 2>/dev/null || echo "989")

            cat > docker-compose.yml << JELLYFIN_COMPOSE
name: jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped
    environment:
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
    group_add:
      - "$RENDER_GID"
    volumes:
      - ./config:/config
      - ./cache:/cache
      - \${MEDIA_PATH}:/media:ro
    ports:
      - "8096:8096"
      - "1900:1900/udp"
      - "7359:7359/udp"
JELLYFIN_COMPOSE

            cat > .env << JELLYFIN_ENV
MEDIA_PATH=$MEDIA_PATH
JELLYFIN_ENV

            mkdir -p config cache
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JELLYFIN_DIR"

            echo ""
            echo "✓ Jellyfin configured at $JELLYFIN_DIR"
            echo "  Start with: cd $JELLYFIN_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8096"
            echo "  Note: Hardware acceleration enabled (Intel GPU)"
            echo ""
        fi
    fi

    # ---- FRIGATE NVR ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ FRIGATE - AI-powered NVR for security cameras                   │"
    echo "│ Object detection, recordings, 24/7 monitoring.                  │"
    echo "│ Port: 5000 (web), 8554 (RTSP), 8555 (WebRTC)                    │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Frigate? (y/n):" "n" INSTALL_FRIGATE

    if [ "$INSTALL_FRIGATE" = "y" ] || [ "$INSTALL_FRIGATE" = "Y" ]; then
        echo "Installing Frigate..."
        FRIGATE_DIR="$DOCKER_DIR/frigate"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $FRIGATE_DIR"
        else
            # STEP 1: Create directory and install docker-compose
            mkdir -p "$FRIGATE_DIR" 2>/dev/null || true
            cd "$FRIGATE_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            # Default path
            FRIGATE_PATH="$ACTUAL_HOME/drives/primary/frigate"

            cat > docker-compose.yml << FRIGATE_COMPOSE
name: frigate

services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    hostname: frigate
    restart: unless-stopped
    privileged: true
    shm_size: "256mb"
    environment:
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
    volumes:
      - ./config:/config
      - \${FRIGATE_MEDIA}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
FRIGATE_COMPOSE
            echo "✓ Installed docker-compose.yml"

            # STEP 2: Try to configure (uses defaults if fails)
            prompt_text "Path for recordings [$FRIGATE_PATH]:" "$FRIGATE_PATH" FRIGATE_PATH 2>/dev/null || FRIGATE_PATH="$ACTUAL_HOME/drives/primary/frigate"

            cat > .env << FRIGATE_ENV
FRIGATE_MEDIA=$FRIGATE_PATH
FRIGATE_ENV

            mkdir -p config 2>/dev/null || true
            mkdir -p "$FRIGATE_PATH" 2>/dev/null || echo "  ⚠ Could not create $FRIGATE_PATH - create manually"

            # Create template config
            cat > config/config.yml << 'FRIGATE_CONFIG'
# Frigate Configuration
# Docs: https://docs.frigate.video
#
# ⚠️  YOU MUST EDIT THIS FILE to add your cameras!

mqtt:
  enabled: false

cameras:
  # EXAMPLE - Replace with your camera:
  # front_door:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://user:pass@192.168.1.100:554/stream
  #         roles: [detect, record]
  #   detect:
  #     width: 1280
  #     height: 720
  #     fps: 5

detectors:
  default:
    type: cpu

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 7
FRIGATE_CONFIG

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FRIGATE_DIR" 2>/dev/null || true

            echo ""
            echo "✓ Frigate installed at $FRIGATE_DIR"
            echo "  Start: cd $FRIGATE_DIR && docker compose up -d"
            echo "  Access: http://localhost:5000"
            echo ""
            echo "  ⚠️  REQUIRED: Edit config/config.yml to add your cameras!"
            echo "  Docs: https://docs.frigate.video"
            echo ""
        fi
    fi

    # ---- CADDY REVERSE PROXY ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ CADDY - Automatic HTTPS reverse proxy                           │"
    echo "│ Route domains to containers with automatic SSL certificates.    │"
    echo "│ Ports: 80, 443                                                  │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Caddy reverse proxy? (y/n):" "n" INSTALL_CADDY

    if [ "$INSTALL_CADDY" = "y" ] || [ "$INSTALL_CADDY" = "Y" ]; then
        echo "Installing Caddy..."
        CADDY_DIR="$DOCKER_DIR/caddy"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $CADDY_DIR"
        else
            # STEP 1: Create directory and install docker-compose
            mkdir -p "$CADDY_DIR" 2>/dev/null || true
            cd "$CADDY_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            cat > docker-compose.yml << 'CADDY_COMPOSE'
name: caddy

services:
  caddy:
    image: caddy:latest
    container_name: caddy
    hostname: caddy
    restart: unless-stopped
    env_file: .env
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./config:/config
      - ./data:/data
      - ./site:/srv

networks:
  default:
    name: caddy_net
    external: true
CADDY_COMPOSE
            echo "✓ Installed docker-compose.yml"

            # STEP 2: Try configuration (uses defaults if fails)
            CADDY_DOMAIN=""
            prompt_text "Your domain (e.g., example.com) [blank for local]:" "" CADDY_DOMAIN 2>/dev/null || CADDY_DOMAIN=""

            cat > .env << CADDY_ENV
MY_DOMAIN=${CADDY_DOMAIN:-localhost}
TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
CADDY_ENV

            # Create Docker network for Caddy (ignore if exists)
            docker network create caddy_net 2>/dev/null || true

            # Create comprehensive Caddyfile with all services
            cat > Caddyfile << 'CADDY_FILE'
# Caddy reverse proxy configuration
# Edit MY_DOMAIN in .env file, then uncomment services below
#
# To use: containers must be on 'caddy_net' network
# Add to each container's docker-compose.yml:
#   networks:
#     default:
#       name: caddy_net
#       external: true

# ============================================================================
# GLOBAL OPTIONS
# ============================================================================
{
    # Uncomment for local-only (no domain/SSL):
    # auto_https off
}

# ============================================================================
# MEDIA SERVERS
# ============================================================================

# Immich (photo backup)
# immich.{$MY_DOMAIN} {
#     reverse_proxy immich_server:2283
# }

# Jellyfin (media server)
# jellyfin.{$MY_DOMAIN} {
#     reverse_proxy jellyfin:8096
# }

# Emby (media server)
# emby.{$MY_DOMAIN} {
#     reverse_proxy emby:8096
# }

# Audiobookshelf
# audiobooks.{$MY_DOMAIN} {
#     reverse_proxy audiobookshelf:80
# }

# Lyrion Music Server
# music.{$MY_DOMAIN} {
#     reverse_proxy lms:9000
# }

# ============================================================================
# HOME AUTOMATION & MONITORING
# ============================================================================

# Frigate NVR
# frigate.{$MY_DOMAIN} {
#     reverse_proxy frigate:5000
# }

# Uptime Kuma
# status.{$MY_DOMAIN} {
#     reverse_proxy uptime-kuma:3001
# }

# Magic Mirror
# mirror.{$MY_DOMAIN} {
#     reverse_proxy magicmirror:8080
# }

# Traccar GPS
# gps.{$MY_DOMAIN} {
#     reverse_proxy traccar:8082
# }

# FindMyDevice
# fmd.{$MY_DOMAIN} {
#     reverse_proxy fmd:8080
# }

# ============================================================================
# UTILITIES
# ============================================================================

# Filebrowser
# files.{$MY_DOMAIN} {
#     reverse_proxy filebrowser:80
# }

# Mealie (recipes)
# recipes.{$MY_DOMAIN} {
#     reverse_proxy mealie:9000
# }

# ntfy (notifications)
# ntfy.{$MY_DOMAIN} {
#     reverse_proxy ntfy:80
# }

# Portainer
# docker.{$MY_DOMAIN} {
#     reverse_proxy portainer:9000
# }

# Kopia backup UI
# backup.{$MY_DOMAIN} {
#     reverse_proxy kopia:51515
# }

# ============================================================================
# TESTING / CATCH-ALL
# ============================================================================

# Local testing (always responds)
:80 {
    respond "Caddy is running! Edit Caddyfile to enable your services."
}
CADDY_FILE

            mkdir -p config data site 2>/dev/null || true
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$CADDY_DIR" 2>/dev/null || true

            echo ""
            echo "✓ Caddy installed at $CADDY_DIR"
            echo "  Start: cd $CADDY_DIR && docker compose up -d"
            echo "  Domain: ${CADDY_DOMAIN:-localhost} (edit .env)"
            echo "  Config: $CADDY_DIR/Caddyfile (uncomment services)"
            echo ""
            echo "  ⚠️  Containers must be on 'caddy_net' network"
            echo "  Docs: https://caddyserver.com/docs/"
            echo ""
        fi
    fi

    # ---- DDCLIENT DYNAMIC DNS ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ DDCLIENT - Dynamic DNS updater                                  │"
    echo "│ Keep your domain pointing to your home IP.                      │"
    echo "│ Supports: Cloudflare, DuckDNS, No-IP, and more.                 │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install ddclient? (y/n):" "n" INSTALL_DDCLIENT

    if [ "$INSTALL_DDCLIENT" = "y" ] || [ "$INSTALL_DDCLIENT" = "Y" ]; then
        echo "Installing ddclient..."
        DDCLIENT_DIR="$DOCKER_DIR/ddclient"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $DDCLIENT_DIR"
        else
            # STEP 1: Install docker-compose
            mkdir -p "$DDCLIENT_DIR" 2>/dev/null || true
            cd "$DDCLIENT_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            cat > docker-compose.yml << 'DDCLIENT_COMPOSE'
name: ddclient

services:
  ddclient:
    image: lscr.io/linuxserver/ddclient:latest
    container_name: ddclient
    hostname: ddclient
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}
    volumes:
      - ./config:/config
DDCLIENT_COMPOSE
            echo "✓ Installed docker-compose.yml"

            cat > .env << DDCLIENT_ENV
TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
DDCLIENT_ENV

            mkdir -p config 2>/dev/null || true

            # Create template config
            cat > config/ddclient.conf << 'DDCLIENT_CONF'
# ddclient configuration
# ⚠️  YOU MUST EDIT THIS FILE!
# Uncomment and edit for your DNS provider

daemon=300
syslog=yes
pid=/var/run/ddclient/ddclient.pid
ssl=yes

# Cloudflare example:
# use=web, web=cloudflare
# protocol=cloudflare
# zone=example.com
# login=token
# password=your-api-token
# example.com

# DuckDNS example:
# use=web
# protocol=duckdns
# password=your-duckdns-token
# yourdomain.duckdns.org
DDCLIENT_CONF

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DDCLIENT_DIR" 2>/dev/null || true

            echo ""
            echo "✓ ddclient installed at $DDCLIENT_DIR"
            echo "  Start: cd $DDCLIENT_DIR && docker compose up -d"
            echo ""
            echo "  ⚠️  REQUIRED: Edit config/ddclient.conf first!"
            echo "  Docs: https://ddclient.net/"
            echo ""
        fi
    fi

    # ---- NTFY NOTIFICATIONS ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ NTFY - Push notifications server                                │"
    echo "│ Send notifications from scripts to your phone.                  │"
    echo "│ Port: 8090                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install ntfy? (y/n):" "n" INSTALL_NTFY

    if [ "$INSTALL_NTFY" = "y" ] || [ "$INSTALL_NTFY" = "Y" ]; then
        echo "Installing ntfy..."
        NTFY_DIR="$DOCKER_DIR/ntfy"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $NTFY_DIR"
        else
            mkdir -p "$NTFY_DIR"
            cd "$NTFY_DIR"

            cat > docker-compose.yml << 'NTFY_COMPOSE'
name: ntfy

services:
  ntfy:
    image: binwiederhier/ntfy:latest
    container_name: ntfy
    hostname: ntfy
    restart: unless-stopped
    command: serve
    environment:
      - TZ=${TZ}
    volumes:
      - ./cache:/var/cache/ntfy
      - ./config:/etc/ntfy
    ports:
      - "8090:80"
NTFY_COMPOSE

            cat > .env << NTFY_ENV
TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
NTFY_ENV

            mkdir -p cache config
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$NTFY_DIR"

            echo ""
            echo "✓ ntfy configured at $NTFY_DIR"
            echo "  Start with: cd $NTFY_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8090"
            echo ""
            echo "  Send notification: curl -d \"Hello!\" localhost:8090/mytopic"
            echo "  Subscribe on phone: ntfy app → Add subscription → localhost:8090/mytopic"
            echo ""
        fi
    fi

    # ---- UPTIME KUMA ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ UPTIME KUMA - Service monitoring dashboard                      │"
    echo "│ Monitor websites, servers, Docker containers.                   │"
    echo "│ Port: 3001                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Uptime Kuma? (y/n):" "n" INSTALL_UPTIMEKUMA

    if [ "$INSTALL_UPTIMEKUMA" = "y" ] || [ "$INSTALL_UPTIMEKUMA" = "Y" ]; then
        echo "Installing Uptime Kuma..."
        UPTIME_DIR="$DOCKER_DIR/uptime-kuma"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $UPTIME_DIR"
        else
            mkdir -p "$UPTIME_DIR"
            cd "$UPTIME_DIR"

            cat > docker-compose.yml << 'UPTIME_COMPOSE'
name: uptime-kuma

services:
  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    hostname: uptime-kuma
    restart: unless-stopped
    volumes:
      - ./data:/app/data
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "3001:3001"
UPTIME_COMPOSE

            mkdir -p data
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$UPTIME_DIR"

            echo ""
            echo "✓ Uptime Kuma configured at $UPTIME_DIR"
            echo "  Start with: cd $UPTIME_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:3001"
            echo ""
        fi
    fi

    # ---- WG-EASY (WireGuard with Web UI) ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ WG-EASY - WireGuard VPN with web management                     │"
    echo "│ Easy WireGuard setup with QR codes for clients.                 │"
    echo "│ Port: 51821 (web), 51820 (VPN)                                  │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install wg-easy? (y/n):" "n" INSTALL_WGEASY

    if [ "$INSTALL_WGEASY" = "y" ] || [ "$INSTALL_WGEASY" = "Y" ]; then
        echo "Installing wg-easy..."
        WGEASY_DIR="$DOCKER_DIR/wg-easy"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $WGEASY_DIR"
        else
            mkdir -p "$WGEASY_DIR"
            cd "$WGEASY_DIR"

            # Get public IP or hostname
            PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "your-public-ip")
            WG_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

            prompt_text "Public IP or hostname for VPN [default: $PUBLIC_IP]:" "$PUBLIC_IP" WG_HOST

            cat > docker-compose.yml << WGEASY_COMPOSE
name: wg-easy

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    hostname: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - WG_HOST=\${WG_HOST}
      - PASSWORD=\${WG_PASSWORD}
      - WG_DEFAULT_DNS=1.1.1.1
    volumes:
      - ./config:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
WGEASY_COMPOSE

            cat > .env << WGEASY_ENV
WG_HOST=$WG_HOST
WG_PASSWORD=$WG_PASSWORD
WGEASY_ENV

            mkdir -p config
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WGEASY_DIR"

            echo ""
            echo "✓ wg-easy configured at $WGEASY_DIR"
            echo "  Start with: cd $WGEASY_DIR && docker compose up -d"
            echo "  Web UI:     http://localhost:51821"
            echo "  Password:   $WG_PASSWORD (saved in .env)"
            echo "  VPN Port:   51820/udp (forward this in your router)"
            echo ""
        fi
    fi

    # ---- TRACCAR GPS TRACKING ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ TRACCAR - GPS tracking server                                   │"
    echo "│ Track phones, vehicles, assets with OwnTracks/Traccar apps.     │"
    echo "│ Port: 8082 (web), 5055 (OsmAnd), 5000+ (devices)                │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Traccar? (y/n):" "n" INSTALL_TRACCAR

    if [ "$INSTALL_TRACCAR" = "y" ] || [ "$INSTALL_TRACCAR" = "Y" ]; then
        echo "Installing Traccar..."
        TRACCAR_DIR="$DOCKER_DIR/traccar"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $TRACCAR_DIR"
        else
            mkdir -p "$TRACCAR_DIR"
            cd "$TRACCAR_DIR"

            cat > docker-compose.yml << 'TRACCAR_COMPOSE'
name: traccar

services:
  traccar:
    image: traccar/traccar:latest
    container_name: traccar
    hostname: traccar
    restart: unless-stopped
    volumes:
      - ./logs:/opt/traccar/logs:rw
      - ./data:/opt/traccar/data:rw
      - ./config/traccar.xml:/opt/traccar/conf/traccar.xml:ro
    ports:
      - "8082:8082"
      - "5000-5150:5000-5150"
      - "5000-5150:5000-5150/udp"
TRACCAR_COMPOSE

            mkdir -p logs data config

            # Create basic traccar.xml config
            cat > config/traccar.xml << 'TRACCAR_XML'
<?xml version='1.0' encoding='UTF-8'?>

<!DOCTYPE properties SYSTEM 'http://java.sun.com/dtd/properties.dtd'>

<properties>
    <entry key='config.default'>./conf/default.xml</entry>
    <entry key='database.driver'>org.h2.Driver</entry>
    <entry key='database.url'>jdbc:h2:/opt/traccar/data/database</entry>
    <entry key='database.user'>sa</entry>
    <entry key='database.password'></entry>
</properties>
TRACCAR_XML

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$TRACCAR_DIR"

            echo ""
            echo "✓ Traccar configured at $TRACCAR_DIR"
            echo "  Start with: cd $TRACCAR_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8082"
            echo "  Default:    admin@admin.com / admin (change immediately!)"
            echo ""
        fi
    fi

    # ---- PORTAINER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ PORTAINER - Docker management web UI                            │"
    echo "│ Manage containers, images, volumes via browser.                 │"
    echo "│ Port: 9443 (https), 9000 (http)                                 │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Portainer? (y/n):" "n" INSTALL_PORTAINER

    if [ "$INSTALL_PORTAINER" = "y" ] || [ "$INSTALL_PORTAINER" = "Y" ]; then
        echo "Installing Portainer..."
        PORTAINER_DIR="$DOCKER_DIR/portainer"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $PORTAINER_DIR"
        else
            mkdir -p "$PORTAINER_DIR"
            cd "$PORTAINER_DIR"

            cat > docker-compose.yml << 'PORTAINER_COMPOSE'
name: portainer

services:
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    hostname: portainer
    restart: always
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
    ports:
      - "9000:9000"
      - "9443:9443"
PORTAINER_COMPOSE

            mkdir -p data
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$PORTAINER_DIR"

            echo ""
            echo "✓ Portainer configured at $PORTAINER_DIR"
            echo "  Start with: cd $PORTAINER_DIR && docker compose up -d"
            echo "  Access at:  https://localhost:9443"
            echo "  Create admin account on first visit"
            echo ""
        fi
    fi

    # ---- MESHCENTRAL SERVER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ MESHCENTRAL SERVER - Self-hosted remote management             │"
    echo "│ Full MeshCentral server (not just agent). Manage all devices.  │"
    echo "│ Port: 4430 (https), 4433 (agent)                               │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install MeshCentral Server? (y/n):" "n" INSTALL_MESHCENTRAL_SERVER

    if [ "$INSTALL_MESHCENTRAL_SERVER" = "y" ] || [ "$INSTALL_MESHCENTRAL_SERVER" = "Y" ]; then
        echo "Installing MeshCentral Server..."
        MC_DIR="$DOCKER_DIR/meshcentral"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $MC_DIR"
        else
            mkdir -p "$MC_DIR" 2>/dev/null || true
            cd "$MC_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            cat > docker-compose.yml << 'MC_COMPOSE'
name: meshcentral

services:
  meshcentral:
    image: ghcr.io/ylianst/meshcentral:latest
    container_name: meshcentral
    hostname: meshcentral
    restart: unless-stopped
    environment:
      - NODE_ENV=production
      - HOSTNAME=${MC_HOSTNAME:-localhost}
      - REVERSE_PROXY=${MC_REVERSE_PROXY:-false}
      - REVERSE_PROXY_TLS_PORT=${MC_TLS_PORT:-443}
      - IFRAME=false
      - ALLOW_NEW_ACCOUNTS=true
      - WEBRTC=true
    volumes:
      - ./data:/opt/meshcentral/meshcentral-data
      - ./files:/opt/meshcentral/meshcentral-files
      - ./backups:/opt/meshcentral/meshcentral-backups
    ports:
      - "4430:443"
      - "4433:4433"
MC_COMPOSE
            echo "✓ Installed docker-compose.yml"

            # Ask for hostname
            echo ""
            prompt_text "MeshCentral hostname (domain or IP) [localhost]:" "localhost" MC_HOSTNAME 2>/dev/null || MC_HOSTNAME="localhost"

            cat > .env << MC_ENV
MC_HOSTNAME=$MC_HOSTNAME
MC_REVERSE_PROXY=false
MC_TLS_PORT=443
MC_ENV

            mkdir -p data files backups 2>/dev/null || true
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR" 2>/dev/null || true

            echo ""
            echo "✓ MeshCentral Server installed at $MC_DIR"
            echo "  Start: cd $MC_DIR && docker compose up -d"
            echo "  Access: https://localhost:4430"
            echo ""
            echo "  First visit: Create admin account"
            echo "  Then: Add devices → Download agent for each OS"
            echo ""
            echo "  ⚠️  For remote access, set MC_HOSTNAME in .env to your domain/IP"
            echo "  Docs: https://meshcentral.com/docs/"
            echo ""
        fi
    fi

    # ---- FINDMYDEVICE (FMD) ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ FINDMYDEVICE - Self-hosted device tracking                      │"
    echo "│ Track and locate Android devices. Alternative to Google Find.  │"
    echo "│ Port: 8084                                                      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install FindMyDevice server? (y/n):" "n" INSTALL_FMD

    if [ "$INSTALL_FMD" = "y" ] || [ "$INSTALL_FMD" = "Y" ]; then
        echo "Installing FindMyDevice..."
        FMD_DIR="$DOCKER_DIR/fmd"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $FMD_DIR"
        else
            mkdir -p "$FMD_DIR"
            cd "$FMD_DIR"

            # Generate random admin password
            FMD_ADMIN_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

            cat > docker-compose.yml << FMD_COMPOSE
name: fmd

services:
  fmd:
    image: nulide/findmydevice
    container_name: fmd
    hostname: fmd
    restart: unless-stopped
    environment:
      - FMD_ADMIN_PASSWORD=\${FMD_ADMIN_PASSWORD}
    volumes:
      - ./data:/fmd/data
    ports:
      - "8084:8080"
FMD_COMPOSE

            cat > .env << FMD_ENV
FMD_ADMIN_PASSWORD=$FMD_ADMIN_PASS
FMD_ENV

            mkdir -p data
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FMD_DIR"

            echo ""
            echo "✓ FindMyDevice configured at $FMD_DIR"
            echo "  Start with: cd $FMD_DIR && docker compose up -d"
            echo "  Access at:  http://localhost:8084"
            echo "  Admin password: $FMD_ADMIN_PASS (saved in .env)"
            echo ""
            echo "  Mobile app: Install 'FindMyDevice' from F-Droid"
            echo "  Configure app to point to: http://YOUR-SERVER-IP:8084"
            echo ""
        fi
    fi

    # ---- FRIGATE-NOTIFY ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ FRIGATE-NOTIFY - Push notifications for Frigate events         │"
    echo "│ Get alerts when Frigate detects people, cars, etc.             │"
    echo "│ Sends to: ntfy, Pushover, Discord, Gotify, and more.           │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Frigate-Notify? (y/n):" "n" INSTALL_FRIGATE_NOTIFY

    if [ "$INSTALL_FRIGATE_NOTIFY" = "y" ] || [ "$INSTALL_FRIGATE_NOTIFY" = "Y" ]; then
        echo "Installing Frigate-Notify..."
        FN_DIR="$DOCKER_DIR/frigate-notify"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $FN_DIR"
        else
            # STEP 1: Create directory and docker-compose (always succeeds)
            mkdir -p "$FN_DIR" 2>/dev/null || true
            cd "$FN_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            cat > docker-compose.yml << 'FN_COMPOSE'
name: frigate-notify

services:
  frigate-notify:
    image: ghcr.io/0x2142/frigate-notify:latest
    container_name: frigate-notify
    hostname: frigate-notify
    restart: unless-stopped
    volumes:
      - ./config.yml:/app/config.yml:ro
FN_COMPOSE
            echo "✓ Installed docker-compose.yml"

            # STEP 2: Try configuration (uses defaults if prompts fail)
            echo ""
            echo "Attempting auto-configuration..."

            # Set smart defaults based on what's installed
            FRIGATE_URL="http://frigate:5000"
            NTFY_URL="https://ntfy.sh"
            NTFY_TOPIC="frigate-alerts"

            [ -d "$DOCKER_DIR/frigate" ] && echo "  ✓ Frigate detected" || echo "  ⚠ Frigate not found (using default URL)"
            [ -d "$DOCKER_DIR/ntfy" ] && { NTFY_URL="http://ntfy:80"; echo "  ✓ ntfy detected"; } || echo "  ⚠ ntfy not found (using ntfy.sh)"

            # Try prompts, use defaults if they fail
            echo ""
            prompt_text "Frigate URL [$FRIGATE_URL]:" "$FRIGATE_URL" FRIGATE_URL 2>/dev/null || FRIGATE_URL="http://frigate:5000"
            prompt_text "ntfy server [$NTFY_URL]:" "$NTFY_URL" NTFY_URL 2>/dev/null || NTFY_URL="https://ntfy.sh"
            prompt_text "ntfy topic [frigate-alerts]:" "frigate-alerts" NTFY_TOPIC 2>/dev/null || NTFY_TOPIC="frigate-alerts"

            # Create config (template with user values or defaults)
            cat > config.yml << FN_CONFIG
# Frigate-Notify Configuration
# Docs: https://frigate-notify.0x2142.com
#
# ⚠️  YOU MAY NEED TO EDIT THIS FILE!
# If notifications don't work, check:
#   - Frigate server URL is correct
#   - ntfy server is reachable
#   - Containers are on same Docker network

frigate:
  server: $FRIGATE_URL
  webapi:
    enabled: true
    interval: 30

alerts:
  general:
    send_startup_message: true
  labels:
    - person
    - car
    # - dog
    # - package

notifiers:
  - name: ntfy
    enabled: true
    provider: ntfy
    config:
      server: $NTFY_URL
      topic: $NTFY_TOPIC
FN_CONFIG

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FN_DIR" 2>/dev/null || true

            echo ""
            echo "✓ Frigate-Notify installed at $FN_DIR"
            echo "  Start: cd $FN_DIR && docker compose up -d"
            echo "  Config: $FN_DIR/config.yml (edit if needed)"
            echo "  Docs: https://frigate-notify.0x2142.com"
            echo ""
        fi
    fi

    # ============================================================================
    # KOPIA BACKUP FOR DOCKER CONTAINERS
    # ============================================================================
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DOCKER CONTAINER BACKUP (Kopia)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Backup all Docker containers (configs, databases, app data) to your"
    echo "backup drives. Essential for disaster recovery - if your OS drive"
    echo "fails, you can restore everything including:"
    echo "  • Immich memories, facial recognition data"
    echo "  • Emby/Jellyfin metadata, watch history"
    echo "  • Minecraft worlds, mods, permissions"
    echo "  • All app configs, users, and databases"
    echo ""
    prompt_yn "Set up Kopia container backup? (y/n):" "n" INSTALL_KOPIA

    if [ "$INSTALL_KOPIA" = "y" ] || [ "$INSTALL_KOPIA" = "Y" ]; then
        echo "Installing Kopia backup..."
        KOPIA_DIR="$DOCKER_DIR/kopia"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $KOPIA_DIR"
        else
            mkdir -p "$KOPIA_DIR"
            cd "$KOPIA_DIR"

            KOPIA_PASSWORD=$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 24)

            echo ""
            echo "Select backup destination(s):"
            echo "  Backups will be stored in ~/drives/{backup-drive}/kopia-repo/"
            echo ""

            # List available backup drives
            echo "Available mount points in ~/drives/:"
            ls -1 "$ACTUAL_HOME/drives/" 2>/dev/null | grep -v "^primary$" || echo "  (none found - set up drives first)"
            echo ""

            prompt_text "Backup drive name [default: backup1]:" "backup1" KOPIA_BACKUP_DRIVE

            KOPIA_REPO="$ACTUAL_HOME/drives/$KOPIA_BACKUP_DRIVE/kopia-repo"

            cat > docker-compose.yml << KOPIA_COMPOSE
name: kopia

services:
  kopia:
    image: kopia/kopia:latest
    container_name: kopia
    hostname: kopia
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/fuse:/dev/fuse:rwm
    environment:
      - TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
      - KOPIA_PASSWORD=\${KOPIA_PASSWORD}
    command: >
      server start
      --tls-generate-cert
      --disable-csrf-token-checks
      --address=0.0.0.0:51515
      --server-username=admin
      --server-password=\${KOPIA_PASSWORD}
    volumes:
      - ./config:/app/config
      - ./cache:/app/cache
      - ./logs:/app/logs
      - $DOCKER_DIR:/data/docker:ro
      - $KOPIA_REPO:/repository
      - ./tmp:/tmp:shared
    ports:
      - "51515:51515"
KOPIA_COMPOSE

            cat > .env << KOPIA_ENV
KOPIA_PASSWORD=$KOPIA_PASSWORD
KOPIA_ENV

            mkdir -p config cache logs tmp
            mkdir -p "$KOPIA_REPO"

            # Create backup script
            cat > backup-containers.sh << 'BACKUP_SCRIPT'
#!/bin/bash
# Backup all Docker containers using Kopia

DOCKER_DIR="$HOME/docker"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

echo "=== Docker Container Backup: $TIMESTAMP ==="
echo ""

# Stop containers before backup for consistency (optional)
read -p "Stop containers during backup for consistency? (y/n): " STOP_CONTAINERS

if [ "$STOP_CONTAINERS" = "y" ]; then
    echo "Stopping containers..."
    for dir in "$DOCKER_DIR"/*/; do
        if [ -f "$dir/docker-compose.yml" ]; then
            echo "  Stopping $(basename $dir)..."
            (cd "$dir" && docker compose stop) 2>/dev/null
        fi
    done
fi

echo ""
echo "Running Kopia backup..."
docker exec kopia kopia snapshot create /data/docker --description "Container backup $TIMESTAMP"

if [ "$STOP_CONTAINERS" = "y" ]; then
    echo ""
    echo "Restarting containers..."
    for dir in "$DOCKER_DIR"/*/; do
        if [ -f "$dir/docker-compose.yml" ]; then
            echo "  Starting $(basename $dir)..."
            (cd "$dir" && docker compose start) 2>/dev/null
        fi
    done
fi

echo ""
echo "=== Backup Complete ==="
docker exec kopia kopia snapshot list /data/docker --max-results 5
BACKUP_SCRIPT

            # Create restore script
            cat > restore-containers.sh << 'RESTORE_SCRIPT'
#!/bin/bash
# Restore Docker containers from Kopia backup

echo "=== Docker Container Restore ==="
echo ""
echo "Available snapshots:"
docker exec kopia kopia snapshot list /data/docker

echo ""
echo "To restore a specific snapshot:"
echo "  docker exec kopia kopia restore <snapshot-id> /tmp/restore"
echo "  Then copy files from ~/docker/kopia/tmp/restore/ to ~/docker/"
echo ""
echo "To mount snapshots for browsing:"
echo "  docker exec kopia kopia mount all /tmp/mnt &"
echo "  Then browse: ~/docker/kopia/tmp/mnt/"
RESTORE_SCRIPT

            chmod +x backup-containers.sh restore-containers.sh
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$KOPIA_DIR"

            echo ""
            echo "✓ Kopia backup configured at $KOPIA_DIR"
            echo "  Start Kopia:    cd $KOPIA_DIR && docker compose up -d"
            echo "  Web UI:         https://localhost:51515"
            echo "  Username:       admin"
            echo "  Password:       $KOPIA_PASSWORD (saved in .env)"
            echo ""
            echo "  Repository at:  $KOPIA_REPO"
            echo ""
            echo "  Backup now:     cd $KOPIA_DIR && ./backup-containers.sh"
            echo "  Restore:        cd $KOPIA_DIR && ./restore-containers.sh"
            echo ""
            echo "  ⚠️  SAVE YOUR KOPIA PASSWORD! Without it, backups cannot be restored."
            echo ""
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Docker applications configured in: $DOCKER_DIR"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "To start an application:"
    echo "  cd ~/docker/{appname}"
    echo "  docker compose up -d"
    echo ""
    echo "To view logs:"
    echo "  docker compose logs -f"
    echo ""
    echo "To stop:"
    echo "  docker compose down"
    echo ""
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