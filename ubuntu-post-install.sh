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

    # Install Kopia for backup management
    echo "Installing Kopia..."
    if ! command -v kopia &> /dev/null; then
        curl -s https://kopia.io/signing-key | gpg --dearmor -o /usr/share/keyrings/kopia-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/kopia-keyring.gpg] https://packages.kopia.io/apt/ stable main" | tee /etc/apt/sources.list.d/kopia.list
        apt-get update
        apt-get install -y kopia 2>/dev/null || echo "  ⚠ Kopia install failed"
    fi

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

    # Step 9: Reconnect Kopia for future backups
    echo ""
    echo "Step 9: Setting up future backups"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Reconnecting Kopia to backup repository for future backups..."

    if command -v kopia &> /dev/null && [ -n "$KOPIA_REPO" ]; then
        # Reconnect to the repository
        if kopia repository connect filesystem --path="$KOPIA_REPO" --password="$KOPIA_PASSWORD" 2>/dev/null; then
            echo "✓ Kopia reconnected to repository"
            echo "  Repository: $KOPIA_REPO"

            # Verify backup scripts exist
            if [ -f "$DOCKER_DIR/kopia/backup-containers.sh" ]; then
                chmod +x "$DOCKER_DIR/kopia/backup-containers.sh" 2>/dev/null || true
                echo "✓ Backup script ready: $DOCKER_DIR/kopia/backup-containers.sh"
            else
                echo "  ⚠ Backup script not found - run normal install to set up"
            fi
        else
            echo "  ⚠ Could not reconnect to repository"
            echo "  Run manually: kopia repository connect filesystem --path=\"$KOPIA_REPO\""
        fi
    else
        echo "  ⚠ Kopia not available or repository not found"
        echo "  Run the normal install script to set up backups"
    fi
    echo ""

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DISASTER RECOVERY COMPLETE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Services restored to: $DOCKER_DIR"
    echo ""
    echo "Backups: $(command -v kopia &>/dev/null && kopia repository status &>/dev/null && echo "✓ Connected" || echo "⚠ Not connected")"
    echo "  Run backups: $DOCKER_DIR/kopia/backup-containers.sh"
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

# Migration function - import existing Docker containers
run_migration() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "MIGRATION MODE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This will migrate existing Docker containers to this script's structure."
    echo "Containers will be copied (not moved) and versions preserved."
    echo ""

    # Step 1: Get source Docker directory
    echo "Step 1: Locate existing containers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Try to auto-detect Docker directories
    DETECTED_DIRS=()

    # Check common locations
    for check_dir in /var/docker /opt/docker "$HOME/docker" /home/*/docker; do
        if [ -d "$check_dir" ] && [ "$(find "$check_dir" -maxdepth 2 -name 'docker-compose.yml' -o -name 'compose.yml' 2>/dev/null | head -1)" ]; then
            DETECTED_DIRS+=("$check_dir")
        fi
    done

    # Check mounted drives: ~/drives/*, /mnt/*, /media/*
    for mount_base in "$HOME/drives" "$HOME_DIR/drives" /mnt /media; do
        if [ -d "$mount_base" ]; then
            for mount_dir in "$mount_base"/*; do
                if [ -d "$mount_dir/docker" ]; then
                    check_dir="$mount_dir/docker"
                    if [ "$(find "$check_dir" -maxdepth 2 -name 'docker-compose.yml' -o -name 'compose.yml' 2>/dev/null | head -1)" ]; then
                        DETECTED_DIRS+=("$check_dir")
                    fi
                fi
            done
        fi
    done

    if [ ${#DETECTED_DIRS[@]} -gt 0 ]; then
        echo "Auto-detected Docker directories:"
        for i in "${!DETECTED_DIRS[@]}"; do
            dir="${DETECTED_DIRS[$i]}"
            count=$(find "$dir" -maxdepth 2 \( -name 'docker-compose.yml' -o -name 'compose.yml' \) 2>/dev/null | wc -l)
            echo "  [$((i+1))] $dir ($count containers)"
        done
        echo ""
        echo "Enter a number to select, or type a custom path:"
    else
        echo "No Docker directories auto-detected."
        echo ""
        echo "Common locations:"
        echo "  • ~/docker"
        echo "  • ~/drives/primary/docker"
        echo "  • /var/docker"
        echo "  • /opt/docker"
        echo "  • /mnt/data/docker"
        echo ""
        echo "Enter the full path to your Docker directory:"
    fi
    echo ""
    read -p "Source directory: " SOURCE_DOCKER_DIR

    # Check if user entered a number (to select from detected list)
    if [[ "$SOURCE_DOCKER_DIR" =~ ^[0-9]+$ ]] && [ ${#DETECTED_DIRS[@]} -gt 0 ]; then
        idx=$((SOURCE_DOCKER_DIR - 1))
        if [ $idx -ge 0 ] && [ $idx -lt ${#DETECTED_DIRS[@]} ]; then
            SOURCE_DOCKER_DIR="${DETECTED_DIRS[$idx]}"
            echo "Selected: $SOURCE_DOCKER_DIR"
        fi
    fi

    # Expand ~ if used
    SOURCE_DOCKER_DIR="${SOURCE_DOCKER_DIR/#\~/$HOME}"

    if [ ! -d "$SOURCE_DOCKER_DIR" ]; then
        echo "❌ Directory not found: $SOURCE_DOCKER_DIR"
        return 1
    fi

    # Step 2: Scan for containers
    echo ""
    echo "Step 2: Scanning for containers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    CONTAINERS_FOUND=()
    CONTAINER_PATHS=()

    while IFS= read -r compose_file; do
        if [ -n "$compose_file" ]; then
            container_dir=$(dirname "$compose_file")
            container_name=$(basename "$container_dir")
            CONTAINERS_FOUND+=("$container_name")
            CONTAINER_PATHS+=("$container_dir")
        fi
    done < <(find "$SOURCE_DOCKER_DIR" -maxdepth 2 \( -name 'docker-compose.yml' -o -name 'compose.yml' \) 2>/dev/null)

    if [ ${#CONTAINERS_FOUND[@]} -eq 0 ]; then
        echo "❌ No Docker containers found in $SOURCE_DOCKER_DIR"
        return 1
    fi

    echo "Found ${#CONTAINERS_FOUND[@]} container(s):"
    for i in "${!CONTAINERS_FOUND[@]}"; do
        container="${CONTAINERS_FOUND[$i]}"
        path="${CONTAINER_PATHS[$i]}"
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        echo "  [$((i+1))] $container ($size)"
    done
    echo ""

    # Step 3: Select containers to migrate
    echo "Step 3: Select containers to migrate"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    SELECTED_CONTAINERS=()

    if command -v whiptail &> /dev/null && [ ${#CONTAINERS_FOUND[@]} -gt 3 ]; then
        # Use whiptail for many containers
        CHECKLIST_ARGS=()
        for container in "${CONTAINERS_FOUND[@]}"; do
            CHECKLIST_ARGS+=("$container" "" "ON")
        done

        SELECTED=$(whiptail --title "Select Containers to Migrate" \
            --checklist "Use SPACE to select/deselect, ENTER to confirm:" \
            20 60 12 \
            "${CHECKLIST_ARGS[@]}" \
            3>&1 1>&2 2>&3)

        if [ $? -eq 0 ] && [ -n "$SELECTED" ]; then
            # Parse whiptail output
            for container in $SELECTED; do
                # Remove quotes
                container="${container//\"/}"
                SELECTED_CONTAINERS+=("$container")
            done
        fi
    else
        # Text-based selection
        echo "Select containers to migrate:"
        echo "  [A] All containers"
        echo "  [S] Select individually"
        echo "  [N] None (cancel)"
        echo ""
        read -p "Choice (A/S/N) [A]: " MIGRATE_CHOICE

        case "${MIGRATE_CHOICE^^}" in
            N)
                echo "Migration cancelled."
                return 0
                ;;
            S)
                for container in "${CONTAINERS_FOUND[@]}"; do
                    read -p "  Migrate $container? (y/n) [y]: " MIGRATE_THIS
                    if [ "$MIGRATE_THIS" != "n" ] && [ "$MIGRATE_THIS" != "N" ]; then
                        SELECTED_CONTAINERS+=("$container")
                    fi
                done
                ;;
            *)
                SELECTED_CONTAINERS=("${CONTAINERS_FOUND[@]}")
                ;;
        esac
    fi

    if [ ${#SELECTED_CONTAINERS[@]} -eq 0 ]; then
        echo "No containers selected."
        return 0
    fi

    echo ""
    echo "Will migrate ${#SELECTED_CONTAINERS[@]} container(s):"
    for container in "${SELECTED_CONTAINERS[@]}"; do
        echo "  • $container"
    done
    echo ""

    # Step 4: Stop running containers (optional)
    echo "Step 4: Container status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Should running containers be stopped before migration?"
    echo "  • Stopping ensures clean copy of data/databases"
    echo "  • Not stopping may result in inconsistent state"
    echo ""
    read -p "Stop containers before copying? (y/n) [y]: " STOP_CONTAINERS

    if [ "$STOP_CONTAINERS" != "n" ] && [ "$STOP_CONTAINERS" != "N" ]; then
        echo "Stopping containers..."
        for container in "${SELECTED_CONTAINERS[@]}"; do
            for i in "${!CONTAINERS_FOUND[@]}"; do
                if [ "${CONTAINERS_FOUND[$i]}" = "$container" ]; then
                    container_dir="${CONTAINER_PATHS[$i]}"
                    if [ -f "$container_dir/docker-compose.yml" ] || [ -f "$container_dir/compose.yml" ]; then
                        echo "  Stopping $container..."
                        (cd "$container_dir" && docker compose down 2>/dev/null) || true
                    fi
                fi
            done
        done
        echo ""
    fi

    # Step 5: Decide migration method
    echo "Step 5: Migration method"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if source is on a different drive (mounted drive, not home on OS)
    SOURCE_ON_EXTERNAL=false
    if [[ "$SOURCE_DOCKER_DIR" == /mnt/* ]] || [[ "$SOURCE_DOCKER_DIR" == /media/* ]] || [[ "$SOURCE_DOCKER_DIR" == */drives/* ]]; then
        SOURCE_ON_EXTERNAL=true
    fi

    MIGRATION_METHOD="copy"
    if [ "$SOURCE_ON_EXTERNAL" = true ]; then
        echo "Source is on a mounted drive: $SOURCE_DOCKER_DIR"
        echo ""
        echo "How would you like to migrate?"
        echo ""
        echo "  [C] Copy - Copy containers to ~/docker on OS drive"
        echo "             Best for: old OS drive mounted temporarily"
        echo ""
        echo "  [S] Symlink - Create ~/docker as symlink to source location"
        echo "                Best for: data drive you'll keep using"
        echo ""
        echo "  [U] Use in-place - Use source location directly, no copy"
        echo "                     Best for: already on your data drive"
        echo ""
        read -p "Method (C/S/U) [C]: " MIGRATION_METHOD

        case "${MIGRATION_METHOD^^}" in
            S)
                MIGRATION_METHOD="symlink"
                ;;
            U)
                MIGRATION_METHOD="use"
                ;;
            *)
                MIGRATION_METHOD="copy"
                ;;
        esac
    else
        echo "Source: $SOURCE_DOCKER_DIR"
        echo "Target: $DOCKER_DIR"
        echo ""
        echo "Will copy containers to $DOCKER_DIR"
    fi

    echo ""

    # Handle different migration methods
    case "$MIGRATION_METHOD" in
        symlink)
            echo "Creating symlink: $DOCKER_DIR → $SOURCE_DOCKER_DIR"
            echo ""

            # Check if target exists
            if [ -e "$DOCKER_DIR" ] || [ -L "$DOCKER_DIR" ]; then
                echo "  ⚠ $DOCKER_DIR already exists"
                read -p "  Remove and create symlink? (y/n) [n]: " REMOVE_EXISTING
                if [ "$REMOVE_EXISTING" = "y" ] || [ "$REMOVE_EXISTING" = "Y" ]; then
                    rm -rf "$DOCKER_DIR"
                else
                    echo "  Cancelled."
                    return 1
                fi
            fi

            ln -s "$SOURCE_DOCKER_DIR" "$DOCKER_DIR"
            chown -h "$ACTUAL_USER:$ACTUAL_USER" "$DOCKER_DIR"

            echo "✓ Symlink created"
            echo "  Containers stay at: $SOURCE_DOCKER_DIR"
            echo "  Accessible via: $DOCKER_DIR → $SOURCE_DOCKER_DIR"
            MIGRATED_COUNT=${#SELECTED_CONTAINERS[@]}
            ;;

        use)
            echo "Using source location directly"
            echo ""
            DOCKER_DIR="$SOURCE_DOCKER_DIR"
            echo "✓ DOCKER_DIR set to: $DOCKER_DIR"
            echo "  No files copied - containers remain in place"
            MIGRATED_COUNT=${#SELECTED_CONTAINERS[@]}
            ;;

        copy|*)
            echo "Copying containers to $DOCKER_DIR"
            echo ""

            # Create target directory
            mkdir -p "$DOCKER_DIR"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$DOCKER_DIR"

            MIGRATED_COUNT=0
            for container in "${SELECTED_CONTAINERS[@]}"; do
                for i in "${!CONTAINERS_FOUND[@]}"; do
                    if [ "${CONTAINERS_FOUND[$i]}" = "$container" ]; then
                        source_dir="${CONTAINER_PATHS[$i]}"
                        target_dir="$DOCKER_DIR/$container"

                        # Check if already exists
                        if [ -d "$target_dir" ]; then
                            echo "  ⚠ $container already exists at $target_dir"
                            read -p "    Overwrite? (y/n) [n]: " OVERWRITE
                            if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
                                echo "    Skipping $container"
                                continue
                            fi
                            rm -rf "$target_dir"
                        fi

                        echo "  Copying $container..."
                        cp -a "$source_dir" "$target_dir"
                        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$target_dir"
                        ((MIGRATED_COUNT++))
                        echo "    ✓ $container copied"
                    fi
                done
            done
            ;;
    esac

    echo ""
    echo "✓ Migrated $MIGRATED_COUNT container(s)"
    echo ""

    # Step 6: Update volume paths
    echo "Step 6: Update volume paths"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Scanning docker-compose files for volume mounts that may need updating..."
    echo ""

    # Find all absolute paths in volume mounts (excluding relative paths like ./ or named volumes)
    PATHS_FOUND=()
    PATHS_FILES=()

    for container in "${SELECTED_CONTAINERS[@]}"; do
        compose_file="$DOCKER_DIR/$container/docker-compose.yml"
        [ -f "$compose_file" ] || compose_file="$DOCKER_DIR/$container/compose.yml"
        [ -f "$compose_file" ] || continue

        # Extract volume mount paths (lines with : that look like /path:/container/path)
        while IFS= read -r line; do
            # Match absolute paths in volume mounts (starting with /)
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(/[^:]+): ]]; then
                host_path="${BASH_REMATCH[1]}"
                # Skip if it's a relative path or standard paths
                if [[ "$host_path" != "./"* ]] && [[ "$host_path" != "/etc/"* ]] && [[ "$host_path" != "/var/run/"* ]]; then
                    # Check if this path doesn't exist on current system
                    if [ ! -e "$host_path" ]; then
                        # Avoid duplicates
                        if [[ ! " ${PATHS_FOUND[*]} " =~ " ${host_path} " ]]; then
                            PATHS_FOUND+=("$host_path")
                            PATHS_FILES+=("$compose_file")
                        fi
                    fi
                fi
            fi
        done < "$compose_file"
    done

    if [ ${#PATHS_FOUND[@]} -eq 0 ]; then
        echo "✓ No volume paths need updating (all paths exist or are relative)"
        echo ""
    else
        echo "Found ${#PATHS_FOUND[@]} volume path(s) that don't exist on this system:"
        echo ""

        # Default new base path
        DEFAULT_NEW_BASE="$HOME_DIR/drives/primary"

        for i in "${!PATHS_FOUND[@]}"; do
            old_path="${PATHS_FOUND[$i]}"
            compose_file="${PATHS_FILES[$i]}"
            container_name=$(basename "$(dirname "$compose_file")")

            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Container: $container_name"
            echo "Old path:  $old_path"

            # Suggest a new path based on the old path structure
            # Extract the last part of the path for suggestion
            path_tail=$(basename "$old_path")
            suggested_path="$DEFAULT_NEW_BASE/$path_tail"

            echo "Suggested: $suggested_path"
            echo ""
            echo "Options:"
            echo "  [Enter] Accept suggested path"
            echo "  [S] Skip - keep original path"
            echo "  [path]  Enter custom path"
            echo ""
            read -p "New path: " NEW_PATH_INPUT

            case "$NEW_PATH_INPUT" in
                ""|" ")
                    new_path="$suggested_path"
                    ;;
                [Ss])
                    echo "  Skipping - keeping original path"
                    continue
                    ;;
                *)
                    new_path="${NEW_PATH_INPUT/#\~/$HOME_DIR}"
                    ;;
            esac

            # Update the compose file
            echo "  Updating: $old_path → $new_path"

            # Escape paths for sed (handle slashes)
            old_escaped=$(printf '%s\n' "$old_path" | sed 's/[[\.*^$()+?{|]/\\&/g; s/\//\\\//g')
            new_escaped=$(printf '%s\n' "$new_path" | sed 's/[[\.*^$()+?{|]/\\&/g; s/\//\\\//g')

            sed -i "s|$old_path|$new_path|g" "$compose_file"

            # Create directory if it doesn't exist
            if [ ! -d "$new_path" ]; then
                echo "  Creating directory: $new_path"
                mkdir -p "$new_path" 2>/dev/null || echo "    ⚠ Could not create (may need manual creation)"
                chown -R "$ACTUAL_USER:$ACTUAL_USER" "$new_path" 2>/dev/null || true
            fi

            echo "  ✓ Updated"
            echo ""
        done

        echo "✓ Volume paths updated"
        echo ""
    fi

    # Step 7: Start migrated containers (optional)
    echo "Step 7: Start containers"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    read -p "Start migrated containers? (y/n) [y]: " START_MIGRATED

    if [ "$START_MIGRATED" != "n" ] && [ "$START_MIGRATED" != "N" ]; then
        for container in "${SELECTED_CONTAINERS[@]}"; do
            target_dir="$DOCKER_DIR/$container"
            if [ -d "$target_dir" ]; then
                echo "  Starting $container..."
                (cd "$target_dir" && docker compose up -d 2>/dev/null) || echo "    ⚠ Failed to start $container"
            fi
        done
        echo ""
    fi

    # Step 8: Offer additional services
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "MIGRATION COMPLETE"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Containers migrated to: $DOCKER_DIR"
    echo ""
    echo "Would you like to install additional services not in your migration?"
    echo "This will continue with the normal install process where you can"
    echo "choose which additional apps to install (Immich, Frigate, etc.)"
    echo ""
    read -p "Continue to install additional services? (y/n) [y]: " INSTALL_MORE

    if [ "$INSTALL_MORE" = "n" ] || [ "$INSTALL_MORE" = "N" ]; then
        echo ""
        echo "Migration complete. You can run this script again to install more services."
        echo ""
        echo "To check running containers:"
        echo "  docker ps"
        echo ""
        return 0
    fi

    # Return to continue with normal install
    INSTALL_MODE="post-migration"
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
    echo "  [M] Migration - Import existing Docker containers"
    echo "  [R] Disaster recovery - Restore from Kopia backup"
    echo ""
    read -p "Select mode (N/M/R) [N]: " MODE_SELECT

    case "${MODE_SELECT^^}" in
        R)
            run_disaster_recovery
            exit $?
            ;;
        M)
            run_migration
            # If migration returns 0 and INSTALL_MODE is post-migration, continue
            if [ $? -ne 0 ]; then
                exit 1
            fi
            if [ "$INSTALL_MODE" != "post-migration" ]; then
                exit 0
            fi
            echo ""
            echo "Continuing with additional service installation..."
            echo ""
            ;;
        *)
            INSTALL_MODE="normal"
            ;;
    esac
    echo ""
fi

# ============================================================================
# DRIVE SETUP (Runs before everything else)
# ============================================================================

setup_drives() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "DRIVE SETUP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This script uses ~/drives/ for data storage:"
    echo "  ~/drives/primary  - Main data drive (media, photos, etc.)"
    echo "  ~/drives/backup1  - Backup drive(s)"
    echo ""

    # Create base drives directory
    mkdir -p "$ACTUAL_HOME/drives"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/drives"

    # Check for existing mounts
    if mount | grep -q "$ACTUAL_HOME/drives/"; then
        echo "Existing mounted drives:"
        df -h | grep "$ACTUAL_HOME/drives" | awk '{print "  " $6 " (" $2 " total, " $4 " free)"}'
        echo ""
        prompt_yn "Configure additional drives? (y/n):" "n" SETUP_DRIVES
    else
        echo "No drives currently mounted in ~/drives/"
        echo ""
        prompt_yn "Set up drives now? (y/n):" "y" SETUP_DRIVES
    fi

    if [ "$SETUP_DRIVES" != "y" ] && [ "$SETUP_DRIVES" != "Y" ]; then
        echo "Skipping drive setup. You can run this script again later."
        return 0
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "AVAILABLE BLOCK DEVICES"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
    echo ""

    # Detect drives without partition tables (new drives)
    echo "Checking for new/unpartitioned drives..."
    NEW_DRIVES=()
    for disk in /dev/sd? /dev/nvme?n?; do
        [ -b "$disk" ] || continue
        # Check if disk has no partitions
        if ! lsblk -n "$disk" | grep -q "part"; then
            # Check if it has no partition table
            if ! blkid "$disk" &>/dev/null; then
                size=$(lsblk -n -d -o SIZE "$disk" 2>/dev/null)
                NEW_DRIVES+=("$disk ($size)")
            fi
        fi
    done

    if [ ${#NEW_DRIVES[@]} -gt 0 ]; then
        echo ""
        echo "⚠️  Found unpartitioned drives (no filesystem):"
        for drive in "${NEW_DRIVES[@]}"; do
            echo "  • $drive"
        done
        echo ""
        prompt_yn "Would you like to partition and format any of these? (y/n):" "n" FORMAT_DRIVES

        if [ "$FORMAT_DRIVES" = "y" ] || [ "$FORMAT_DRIVES" = "Y" ]; then
            for drive_info in "${NEW_DRIVES[@]}"; do
                drive=$(echo "$drive_info" | cut -d' ' -f1)
                echo ""
                prompt_yn "Format $drive_info as ext4? (ALL DATA WILL BE ERASED) (y/n):" "n" FORMAT_THIS

                if [ "$FORMAT_THIS" = "y" ] || [ "$FORMAT_THIS" = "Y" ]; then
                    echo "  Creating partition table on $drive..."
                    parted -s "$drive" mklabel gpt
                    parted -s "$drive" mkpart primary ext4 0% 100%

                    # Wait for partition to appear
                    sleep 2

                    # Format the partition
                    part="${drive}1"
                    [ -b "${drive}p1" ] && part="${drive}p1"  # nvme drives

                    if [ -b "$part" ]; then
                        echo "  Formatting $part as ext4..."
                        mkfs.ext4 -F "$part"
                        echo "  ✓ Formatted $part"
                    else
                        echo "  ⚠ Could not find partition after creation"
                    fi
                fi
            done
            echo ""
            echo "Updated block devices:"
            lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL
            echo ""
        fi
    fi

    # Configure mount points
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "CONFIGURE MOUNT POINTS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Primary drive
    echo "PRIMARY DRIVE (for media, photos, docker data):"
    prompt_text "  Mount point name [primary]:" "primary" PRIMARY_NAME
    PRIMARY_NAME="${PRIMARY_NAME:-primary}"
    mkdir -p "$ACTUAL_HOME/drives/$PRIMARY_NAME"

    # Check if already mounted
    if mount | grep -q "$ACTUAL_HOME/drives/$PRIMARY_NAME"; then
        echo "  ✓ Already mounted"
    else
        echo "  Enter device (e.g., /dev/sdb1) or leave blank to skip:"
        read -p "  Device for $PRIMARY_NAME: " PRIMARY_DEV

        if [ -n "$PRIMARY_DEV" ] && [ -b "$PRIMARY_DEV" ]; then
            # Add to fstab
            PRIMARY_UUID=$(blkid -s UUID -o value "$PRIMARY_DEV" 2>/dev/null)
            if [ -n "$PRIMARY_UUID" ]; then
                # Check if not already in fstab
                if ! grep -q "$PRIMARY_UUID" /etc/fstab 2>/dev/null; then
                    cp /etc/fstab /etc/fstab.backup-$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
                    echo "UUID=$PRIMARY_UUID $ACTUAL_HOME/drives/$PRIMARY_NAME auto defaults,nofail 0 2" >> /etc/fstab
                    echo "  ✓ Added to fstab"
                fi
            fi
        fi
    fi

    # Backup drives
    echo ""
    echo "BACKUP DRIVES (optional, for rsync backups):"
    prompt_text "  How many backup drives? [0-4, default: 0]:" "0" NUM_BACKUPS
    NUM_BACKUPS="${NUM_BACKUPS:-0}"

    # Validate number
    case $NUM_BACKUPS in
        0|1|2|3|4) ;;
        *) NUM_BACKUPS=0 ;;
    esac

    declare -a BACKUP_NAMES
    declare -a BACKUP_DEVS
    for i in $(seq 1 $NUM_BACKUPS); do
        echo ""
        prompt_text "  Backup drive $i name [backup$i]:" "backup$i" "BACKUP_NAME"
        BACKUP_NAMES[$i]="${BACKUP_NAME:-backup$i}"
        mkdir -p "$ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}"

        if ! mount | grep -q "$ACTUAL_HOME/drives/${BACKUP_NAMES[$i]}"; then
            read -p "  Device for ${BACKUP_NAMES[$i]}: " "BACKUP_DEV"
            BACKUP_DEVS[$i]="$BACKUP_DEV"

            if [ -n "$BACKUP_DEV" ] && [ -b "$BACKUP_DEV" ]; then
                BACKUP_UUID=$(blkid -s UUID -o value "$BACKUP_DEV" 2>/dev/null)
                if [ -n "$BACKUP_UUID" ]; then
                    if ! grep -q "$BACKUP_UUID" /etc/fstab 2>/dev/null; then
                        echo "UUID=$BACKUP_UUID $ACTUAL_HOME/drives/${BACKUP_NAMES[$i]} auto defaults,nofail 0 2" >> /etc/fstab
                        echo "  ✓ Added ${BACKUP_NAMES[$i]} to fstab"
                    fi
                fi
            fi
        else
            echo "  ✓ Already mounted"
        fi
    done

    # Set permissions
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ACTUAL_HOME/drives"

    # Mount all from fstab
    echo ""
    echo "Mounting drives from fstab..."
    mount -a 2>/dev/null || true

    echo ""
    echo "Current mounts in ~/drives/:"
    df -h | grep "$ACTUAL_HOME/drives" | awk '{print "  " $6 " - " $2 " total, " $4 " free"}' || echo "  (none)"
    echo ""

    # Export drive names for later use
    export PRIMARY_DRIVE_NAME="$PRIMARY_NAME"
    export BACKUP_DRIVE_COUNT="$NUM_BACKUPS"
    for i in $(seq 1 $NUM_BACKUPS); do
        export "BACKUP_DRIVE_${i}_NAME=${BACKUP_NAMES[$i]}"
    done

    echo "✓ Drive setup complete"
    echo ""
}

# Run drive setup for normal installs (not migration/recovery)
if [ "$INSTALL_MODE" = "normal" ] && [ "$UNATTENDED" != true ]; then
    setup_drives
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

        # Photo storage configuration
        echo ""
        echo "Photo Storage Configuration:"
        echo ""
        echo "Immich needs two separate locations:"
        echo "  1. UPLOAD folder - Where NEW photos from phone/web uploads go"
        echo "  2. EXTERNAL folder - Where EXISTING photos are (read-only access)"
        echo ""

        # Upload location (for new photos)
        DEFAULT_UPLOAD_DIR="$HOME_DIR/drives/primary/photos/immich-uploads"
        echo "NEW UPLOADS (from phone apps, web uploads):"
        echo "  Default: $DEFAULT_UPLOAD_DIR"
        prompt_text "  Upload folder path:" "$DEFAULT_UPLOAD_DIR" UPLOAD_LOCATION 2>/dev/null || UPLOAD_LOCATION="$DEFAULT_UPLOAD_DIR"
        UPLOAD_LOCATION="${UPLOAD_LOCATION/#\~/$HOME_DIR}"

        # External library (for existing photos)
        echo ""
        DEFAULT_EXTERNAL_DIR="$HOME_DIR/drives/primary/photos"
        echo "EXISTING PHOTOS (external library, read-only):"
        echo "  Default: $DEFAULT_EXTERNAL_DIR"
        echo "  Leave blank if you don't have existing photos to import"
        prompt_text "  Existing photos path:" "$DEFAULT_EXTERNAL_DIR" EXTERNAL_LIBRARY 2>/dev/null || EXTERNAL_LIBRARY=""
        EXTERNAL_LIBRARY="${EXTERNAL_LIBRARY/#\~/$HOME_DIR}"

        # If external library is same as upload, warn
        if [ -n "$EXTERNAL_LIBRARY" ] && [ "$EXTERNAL_LIBRARY" = "$UPLOAD_LOCATION" ]; then
            echo ""
            echo "  ⚠️  Warning: External library and upload location are the same."
            echo "     This may cause duplicate imports. Consider using different paths."
            echo ""
        fi

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $IMMICH_DIR"
            echo "[DRY-RUN] Would store uploads at $UPLOAD_LOCATION"
            [ -n "$EXTERNAL_LIBRARY" ] && echo "[DRY-RUN] Would mount external library at $EXTERNAL_LIBRARY"
            echo "[DRY-RUN] Would create docker-compose.yml and .env"
        else
            mkdir -p "$IMMICH_DIR" 2>/dev/null || true
            mkdir -p "$UPLOAD_LOCATION" 2>/dev/null || true
            [ -n "$EXTERNAL_LIBRARY" ] && mkdir -p "$EXTERNAL_LIBRARY" 2>/dev/null || true
            cd "$IMMICH_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            # Create docker-compose.yml with external library support
            cat > docker-compose.yml << 'IMMICH_COMPOSE'
name: immich

services:
  immich-server:
    container_name: immich_server
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    volumes:
      # Main photo storage - new uploads go here
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
      # External library - for existing photos (read-only by Immich)
      - ${EXTERNAL_LIBRARY:-/dev/null}:/usr/src/app/external:ro
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
# ============================================================
# IMMICH CONFIGURATION
# ============================================================
#
# STORAGE TEMPLATE (configure in Immich web UI):
#   Admin → Settings → Storage Template → Enable
#   Template: {{y}}/{{MM}}/{{filename}}
#   This organizes new uploads into: immich-uploads/2026/01/filename.jpg
#
# UPLOADING OLD PHOTOS WITH CORRECT DATES:
#   Use immich-cli to import with proper EXIF date extraction:
#
#   npm install -g @immich/cli
#   immich login http://localhost:2283/api <your-api-key>
#   immich upload --recursive /path/to/old/photos
#
#   The CLI reads EXIF data to set correct dates automatically.
#   Get your API key from: User Settings → API Keys
#
# ============================================================

# Photo storage location (new uploads from phone/web)
UPLOAD_LOCATION=$UPLOAD_LOCATION

# External library for existing photos (read-only)
# Configure in: Admin → External Libraries → Create Library
# Import path inside container: /usr/src/app/external
EXTERNAL_LIBRARY=${EXTERNAL_LIBRARY:-}

# Database location (keep on fast storage)
DB_DATA_LOCATION=./postgres

IMMICH_VERSION=release

DB_PASSWORD=$DB_PASS
DB_USERNAME=postgres
DB_DATABASE_NAME=immich

TZ=$(cat /etc/timezone 2>/dev/null || echo "UTC")
IMMICH_ENV

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$IMMICH_DIR" 2>/dev/null || true
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$UPLOAD_LOCATION" 2>/dev/null || true
            [ -n "$EXTERNAL_LIBRARY" ] && chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EXTERNAL_LIBRARY" 2>/dev/null || true

            echo ""
            echo "✓ Immich configured at $IMMICH_DIR"
            echo "  Uploads: $UPLOAD_LOCATION"
            [ -n "$EXTERNAL_LIBRARY" ] && echo "  External: $EXTERNAL_LIBRARY"
            echo ""

            # Ask to start container
            prompt_yn "Start Immich now? (y/n):" "y" START_IMMICH
            if [ "$START_IMMICH" = "y" ] || [ "$START_IMMICH" = "Y" ]; then
                echo "  Starting Immich..."
                docker compose up -d 2>/dev/null && echo "  ✓ Immich started" || echo "  ⚠ Failed to start"
            fi

            echo ""
            echo "  Access at: http://localhost:2283"
            echo ""
            echo "  SETUP STEPS:"
            echo "    1. Create admin account on first visit"
            echo "    2. Go to Admin → Settings → Storage Template"
            echo "    3. Enable and set template to: {{y}}/{{MM}}/{{filename}}"
            echo ""
            if [ -n "$EXTERNAL_LIBRARY" ]; then
                echo "  FOR EXISTING PHOTOS:"
                echo "    1. Go to Admin → External Libraries → Create Library"
                echo "    2. Set import path to: /usr/src/app/external"
                echo "    3. Scan library to import"
                echo ""
            fi
            echo "  UPLOADING OLD PHOTOS WITH CORRECT DATES:"
            echo "    npm install -g @immich/cli"
            echo "    immich login http://localhost:2283/api <your-api-key>"
            echo "    immich upload --recursive /path/to/old/photos"
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

            prompt_yn "Start Audiobookshelf now? (y/n):" "y" START_ABS
            if [ "$START_ABS" = "y" ] || [ "$START_ABS" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Audiobookshelf started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Emby now? (y/n):" "y" START_EMBY
            if [ "$START_EMBY" = "y" ] || [ "$START_EMBY" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Emby started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start A.R.M. now? (y/n):" "y" START_ARM
            if [ "$START_ARM" = "y" ] || [ "$START_ARM" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ A.R.M. started" || echo "  ⚠ Failed to start"
            fi

            echo "  Access at:  http://localhost:8080"
            echo "  ⚠️  Complete setup in browser on first visit!"
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

            prompt_yn "Start Filebrowser now? (y/n):" "y" START_FB
            if [ "$START_FB" = "y" ] || [ "$START_FB" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Filebrowser started" || echo "  ⚠ Failed to start"
            fi

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

                # Ask if user has existing config to copy
                echo ""
                echo "  Config options:"
                echo "    [1] Use default config (basic modules)"
                echo "    [2] Copy existing config from path"
                read -p "  Choose [1]: " MM_CONFIG_CHOICE
                MM_CONFIG_CHOICE=${MM_CONFIG_CHOICE:-1}

                if [ "$MM_CONFIG_CHOICE" = "2" ]; then
                    read -p "  Path to config.js: " MM_CONFIG_PATH
                    if [ -f "$MM_CONFIG_PATH" ]; then
                        cp "$MM_CONFIG_PATH" config/config.js
                        echo "  ✓ Copied config from $MM_CONFIG_PATH"

                        # Also copy custom.css if exists in same directory
                        MM_CSS_PATH="${MM_CONFIG_PATH%/*}/custom.css"
                        if [ -f "$MM_CSS_PATH" ]; then
                            cp "$MM_CSS_PATH" css/custom.css
                            echo "  ✓ Copied custom.css"
                        fi

                        # Parse config for third-party modules and offer to download
                        echo ""
                        echo "  Scanning for third-party modules..."

                        # Extract module names starting with MMM- (third-party convention)
                        THIRD_PARTY_MODULES=$(grep -oP 'module:\s*["\x27]MMM-[^"\x27]+["\x27]' config/config.js 2>/dev/null | sed "s/module:\s*[\"']//g" | sed "s/[\"']//g" | sort -u)

                        if [ -n "$THIRD_PARTY_MODULES" ]; then
                            echo "  Found third-party modules:"
                            echo "$THIRD_PARTY_MODULES" | while read mod; do
                                echo "    - $mod"
                            done
                            echo ""
                            prompt_yn "  Download these modules from GitHub? (y/n):" "y" MM_DOWNLOAD_MODS
                            if [ "$MM_DOWNLOAD_MODS" = "y" ] || [ "$MM_DOWNLOAD_MODS" = "Y" ]; then
                                cd modules
                                echo "$THIRD_PARTY_MODULES" | while read mod; do
                                    if [ -n "$mod" ] && [ ! -d "$mod" ]; then
                                        echo "  Downloading $mod..."
                                        # Try common GitHub patterns
                                        git clone --depth 1 "https://github.com/MichMich/$mod.git" 2>/dev/null || \
                                        git clone --depth 1 "https://github.com/bugsounet/$mod.git" 2>/dev/null || \
                                        git clone --depth 1 "https://github.com/MagicMirrorOrg/$mod.git" 2>/dev/null || \
                                        echo "    ⚠ Could not find $mod - search at https://github.com/topics/magicmirror"
                                    fi
                                done
                                cd ..

                                # Run npm install for each downloaded module
                                echo ""
                                echo "  Installing npm dependencies for modules..."
                                for mod_dir in modules/MMM-*/; do
                                    if [ -d "$mod_dir" ] && [ -f "$mod_dir/package.json" ]; then
                                        mod_name=$(basename "$mod_dir")
                                        echo "  Installing dependencies for $mod_name..."
                                        (cd "$mod_dir" && npm install --production 2>/dev/null) && \
                                            echo "    ✓ $mod_name dependencies installed" || \
                                            echo "    ⚠ $mod_name - npm install failed (may work anyway)"
                                    fi
                                done
                                echo ""
                            fi
                        else
                            echo "  No third-party modules (MMM-*) found in config"
                        fi
                    else
                        echo "  ⚠ File not found: $MM_CONFIG_PATH"
                        echo "  Using default config..."
                        MM_CONFIG_CHOICE="1"
                    fi
                fi

                # Create default config if not copying
                if [ "$MM_CONFIG_CHOICE" != "2" ]; then
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
                fi

                chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MM_DIR"

                echo "  ✓ Magic Mirror #$i configured at $MM_DIR (port $MM_PORT)"
            fi
        done

        if [ "$DRY_RUN" != true ]; then
            echo ""
            prompt_yn "Start Magic Mirror instance(s) now? (y/n):" "y" START_MM
            if [ "$START_MM" = "y" ] || [ "$START_MM" = "Y" ]; then
                for i in $(seq 1 $MM_COUNT); do
                    MM_PORT=$((8080 + i))
                    MM_DIR="$DOCKER_DIR/magicmirror-$MM_PORT"
                    (cd "$MM_DIR" && docker compose up -d 2>/dev/null) && echo "  ✓ Magic Mirror #$i started (port $MM_PORT)" || echo "  ⚠ Failed to start Magic Mirror #$i"
                done
            fi

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

            prompt_yn "Start Lyrion Music Server now? (y/n):" "y" START_LMS
            if [ "$START_LMS" = "y" ] || [ "$START_LMS" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Lyrion Music Server started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Mealie now? (y/n):" "y" START_MEALIE
            if [ "$START_MEALIE" = "y" ] || [ "$START_MEALIE" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Mealie started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Minecraft Server now? (y/n):" "y" START_MC
            if [ "$START_MC" = "y" ] || [ "$START_MC" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Minecraft Server started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Jellyfin now? (y/n):" "y" START_JELLYFIN
            if [ "$START_JELLYFIN" = "y" ] || [ "$START_JELLYFIN" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Jellyfin started" || echo "  ⚠ Failed to start"
            fi

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
            echo ""
            echo "  ⚠️  Note: You should edit config/config.yml to add cameras before starting."
            prompt_yn "Start Frigate now anyway? (y/n):" "n" START_FRIGATE
            if [ "$START_FRIGATE" = "y" ] || [ "$START_FRIGATE" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Frigate started" || echo "  ⚠ Failed to start"
            fi

            echo "  Access: http://localhost:5000"
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

            prompt_yn "Start Caddy now? (y/n):" "y" START_CADDY
            if [ "$START_CADDY" = "y" ] || [ "$START_CADDY" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Caddy started" || echo "  ⚠ Failed to start"
            fi

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
            echo ""
            echo "  ⚠️  Note: You should edit config/ddclient.conf before starting."
            prompt_yn "Start ddclient now anyway? (y/n):" "n" START_DDCLIENT
            if [ "$START_DDCLIENT" = "y" ] || [ "$START_DDCLIENT" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ ddclient started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start ntfy now? (y/n):" "y" START_NTFY
            if [ "$START_NTFY" = "y" ] || [ "$START_NTFY" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ ntfy started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Uptime Kuma now? (y/n):" "y" START_UPTIME
            if [ "$START_UPTIME" = "y" ] || [ "$START_UPTIME" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Uptime Kuma started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start wg-easy now? (y/n):" "y" START_WGEASY
            if [ "$START_WGEASY" = "y" ] || [ "$START_WGEASY" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ wg-easy started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Traccar now? (y/n):" "y" START_TRACCAR
            if [ "$START_TRACCAR" = "y" ] || [ "$START_TRACCAR" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Traccar started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Portainer now? (y/n):" "y" START_PORTAINER
            if [ "$START_PORTAINER" = "y" ] || [ "$START_PORTAINER" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Portainer started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start MeshCentral now? (y/n):" "y" START_MESHCENTRAL
            if [ "$START_MESHCENTRAL" = "y" ] || [ "$START_MESHCENTRAL" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ MeshCentral started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start FindMyDevice now? (y/n):" "y" START_FMD
            if [ "$START_FMD" = "y" ] || [ "$START_FMD" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ FindMyDevice started" || echo "  ⚠ Failed to start"
            fi

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

            prompt_yn "Start Frigate-Notify now? (y/n):" "y" START_FN
            if [ "$START_FN" = "y" ] || [ "$START_FN" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Frigate-Notify started" || echo "  ⚠ Failed to start"
            fi

            echo "  Config: $FN_DIR/config.yml (edit if needed)"
            echo "  Docs: https://frigate-notify.0x2142.com"
            echo ""
        fi
    fi

    # ---- WATCHTOWER ----
    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ WATCHTOWER - Container update monitoring                        │"
    echo "│ Monitor containers for updates. NOTIFY ONLY by default.         │"
    echo "│ Why notify-only? Apps like Immich have breaking DB migrations.  │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    prompt_yn "Install Watchtower? (y/n):" "n" INSTALL_WATCHTOWER

    if [ "$INSTALL_WATCHTOWER" = "y" ] || [ "$INSTALL_WATCHTOWER" = "Y" ]; then
        echo "Installing Watchtower..."
        WT_DIR="$DOCKER_DIR/watchtower"

        if [ "$DRY_RUN" = true ]; then
            echo "[DRY-RUN] Would create $WT_DIR"
        else
            mkdir -p "$WT_DIR" 2>/dev/null || true
            cd "$WT_DIR" 2>/dev/null || cd "$DOCKER_DIR"

            # Ask about mode
            echo ""
            echo "Watchtower Mode:"
            echo "  [M] Monitor only - Get notifications about available updates (SAFE)"
            echo "  [A] Auto-update - Automatically pull and restart containers (RISKY)"
            echo ""
            echo "  ⚠️  Auto-update can break apps like Immich that need DB migrations!"
            echo "  Recommendation: Use monitor mode, update manually when ready."
            echo ""
            WT_MODE="M"
            prompt_text "Mode [M/A]:" "M" WT_MODE 2>/dev/null || WT_MODE="M"
            WT_MODE=$(echo "$WT_MODE" | tr '[:lower:]' '[:upper:]')

            if [ "$WT_MODE" = "A" ]; then
                MONITOR_ONLY="false"
                echo "  Mode: Auto-update (containers will be updated automatically)"
            else
                MONITOR_ONLY="true"
                echo "  Mode: Monitor only (you'll be notified of updates)"
            fi

            # Check for ntfy
            NTFY_URL=""
            if [ -d "$DOCKER_DIR/ntfy" ]; then
                echo "  ✓ ntfy detected - configuring notifications"
                NTFY_URL="http://ntfy/watchtower"
            fi

            cat > docker-compose.yml << WT_COMPOSE
name: watchtower

services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    hostname: watchtower
    restart: unless-stopped
    environment:
      # Check for updates daily at 4 AM
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      # Monitor only - don't auto-update (change to false for auto-update)
      - WATCHTOWER_MONITOR_ONLY=${MONITOR_ONLY}
      # Cleanup old images after update
      - WATCHTOWER_CLEANUP=true
      # Include stopped containers
      - WATCHTOWER_INCLUDE_STOPPED=true
      # Notification URL (ntfy, Discord, Slack, etc.)
      - WATCHTOWER_NOTIFICATION_URL=${NOTIFICATION_URL:-}
      # Show debug info
      - WATCHTOWER_DEBUG=false
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
WT_COMPOSE

            # Create .env
            cat > .env << WT_ENV
# Watchtower Configuration
# =========================
#
# Monitor-only mode: Watchtower checks for updates but doesn't apply them.
# This is SAFER because some apps (Immich, Mealie) have database migrations
# that can break if you update without proper procedures.
#
# To update manually:
#   cd ~/docker/{app}
#   docker compose pull
#   docker compose up -d

# Set to "false" to enable auto-updates (RISKY!)
MONITOR_ONLY=$MONITOR_ONLY

# Notification URL (optional)
# Examples:
#   ntfy:    ntfy://ntfy.example.com/watchtower
#   Discord: discord://token@id
#   Slack:   slack://hook-url
#   Gotify:  gotify://hostname/token
#
# Full list: https://containrrr.dev/shoutrrr/services/overview/
NOTIFICATION_URL=$NTFY_URL
WT_ENV

            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WT_DIR" 2>/dev/null || true

            echo ""
            echo "✓ Watchtower installed at $WT_DIR"

            prompt_yn "Start Watchtower now? (y/n):" "y" START_WATCHTOWER
            if [ "$START_WATCHTOWER" = "y" ] || [ "$START_WATCHTOWER" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Watchtower started" || echo "  ⚠ Failed to start"
            fi

            echo "  Mode: $([ "$MONITOR_ONLY" = "true" ] && echo "Monitor only" || echo "Auto-update")"
            echo ""
            echo "  Checks for updates daily at 4 AM."
            if [ -n "$NTFY_URL" ]; then
                echo "  Notifications: $NTFY_URL"
            else
                echo "  Configure NOTIFICATION_URL in .env for alerts."
            fi
            echo ""
            echo "  To exclude a container from Watchtower:"
            echo "    Add label: com.centurylinklabs.watchtower.enable=false"
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

            prompt_yn "Start Kopia now? (y/n):" "y" START_KOPIA
            if [ "$START_KOPIA" = "y" ] || [ "$START_KOPIA" = "Y" ]; then
                docker compose up -d 2>/dev/null && echo "  ✓ Kopia started" || echo "  ⚠ Failed to start"
            fi

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

            # Allow Docker service ports (only if Docker was installed)
            if [ "$INSTALL_DOCKER" = "y" ] || [ "$INSTALL_DOCKER" = "Y" ]; then
                echo ""
                echo "Opening firewall ports for Docker services..."

                prompt_yn "Open firewall ports for installed Docker services? (y/n):" "y" OPEN_DOCKER_PORTS
                if [ "$OPEN_DOCKER_PORTS" = "y" ] || [ "$OPEN_DOCKER_PORTS" = "Y" ]; then

                    # Reverse proxies (NPM or Caddy)
                    if [ "$INSTALL_CADDY" = "y" ] || [ "$INSTALL_CADDY" = "Y" ]; then
                        ufw allow 80/tcp comment 'HTTP' 2>/dev/null
                        ufw allow 443/tcp comment 'HTTPS' 2>/dev/null
                        echo "  ✓ Allowed HTTP/HTTPS (80, 443)"
                    fi

                    # Media servers
                    if [ "$INSTALL_IMMICH" = "y" ] || [ "$INSTALL_IMMICH" = "Y" ]; then
                        ufw allow 2283/tcp comment 'Immich' 2>/dev/null
                        echo "  ✓ Allowed Immich (2283)"
                    fi
                    if [ "$INSTALL_JELLYFIN" = "y" ] || [ "$INSTALL_JELLYFIN" = "Y" ]; then
                        ufw allow 8096/tcp comment 'Jellyfin' 2>/dev/null
                        echo "  ✓ Allowed Jellyfin (8096)"
                    fi
                    if [ "$INSTALL_EMBY" = "y" ] || [ "$INSTALL_EMBY" = "Y" ]; then
                        ufw allow 8096/tcp comment 'Emby' 2>/dev/null
                        echo "  ✓ Allowed Emby (8096)"
                    fi

                    # NVR
                    if [ "$INSTALL_FRIGATE" = "y" ] || [ "$INSTALL_FRIGATE" = "Y" ]; then
                        ufw allow 5000/tcp comment 'Frigate' 2>/dev/null
                        ufw allow 8554/tcp comment 'Frigate RTSP' 2>/dev/null
                        ufw allow 8555/tcp comment 'Frigate WebRTC' 2>/dev/null
                        ufw allow 8555/udp comment 'Frigate WebRTC UDP' 2>/dev/null
                        echo "  ✓ Allowed Frigate (5000, 8554, 8555)"
                    fi

                    # Utilities
                    if [ "$INSTALL_PORTAINER" = "y" ] || [ "$INSTALL_PORTAINER" = "Y" ]; then
                        ufw allow 9000/tcp comment 'Portainer HTTP' 2>/dev/null
                        ufw allow 9443/tcp comment 'Portainer HTTPS' 2>/dev/null
                        echo "  ✓ Allowed Portainer (9000, 9443)"
                    fi
                    if [ "$INSTALL_UPTIMEKUMA" = "y" ] || [ "$INSTALL_UPTIMEKUMA" = "Y" ]; then
                        ufw allow 3001/tcp comment 'Uptime Kuma' 2>/dev/null
                        echo "  ✓ Allowed Uptime Kuma (3001)"
                    fi

                    # VPN
                    if [ "$INSTALL_WGEASY" = "y" ] || [ "$INSTALL_WGEASY" = "Y" ]; then
                        ufw allow 51820/udp comment 'WireGuard VPN' 2>/dev/null
                        ufw allow 51821/tcp comment 'WG-Easy Web UI' 2>/dev/null
                        echo "  ✓ Allowed WireGuard (51820/udp, 51821)"
                    fi

                    # GPS Tracking
                    if [ "$INSTALL_TRACCAR" = "y" ] || [ "$INSTALL_TRACCAR" = "Y" ]; then
                        ufw allow 8082/tcp comment 'Traccar' 2>/dev/null
                        ufw allow 5055/tcp comment 'Traccar OsmAnd' 2>/dev/null
                        echo "  ✓ Allowed Traccar (8082, 5055)"
                    fi

                    # Music server
                    if [ "$INSTALL_LMS" = "y" ] || [ "$INSTALL_LMS" = "Y" ]; then
                        ufw allow 9000/tcp comment 'Lyrion Music Server' 2>/dev/null
                        ufw allow 3483/tcp comment 'LMS Players' 2>/dev/null
                        ufw allow 3483/udp comment 'LMS Players UDP' 2>/dev/null
                        echo "  ✓ Allowed Lyrion Music Server (9000, 3483)"
                    fi

                    # Notifications
                    if [ "$INSTALL_NTFY" = "y" ] || [ "$INSTALL_NTFY" = "Y" ]; then
                        ufw allow 8090/tcp comment 'ntfy' 2>/dev/null
                        echo "  ✓ Allowed ntfy (8090)"
                    fi

                    # Minecraft
                    if [ "$INSTALL_MINECRAFT" = "y" ] || [ "$INSTALL_MINECRAFT" = "Y" ]; then
                        ufw allow 25565/tcp comment 'Minecraft' 2>/dev/null
                        echo "  ✓ Allowed Minecraft (25565)"
                    fi

                    # Other services
                    if [ "$INSTALL_FILEBROWSER" = "y" ] || [ "$INSTALL_FILEBROWSER" = "Y" ]; then
                        ufw allow 8085/tcp comment 'Filebrowser' 2>/dev/null
                        echo "  ✓ Allowed Filebrowser (8085)"
                    fi
                    if [ "$INSTALL_FMD" = "y" ] || [ "$INSTALL_FMD" = "Y" ]; then
                        ufw allow 8084/tcp comment 'FindMyDevice' 2>/dev/null
                        echo "  ✓ Allowed FindMyDevice (8084)"
                    fi
                    if [ "$INSTALL_MEALIE" = "y" ] || [ "$INSTALL_MEALIE" = "Y" ]; then
                        ufw allow 9925/tcp comment 'Mealie' 2>/dev/null
                        echo "  ✓ Allowed Mealie (9925)"
                    fi
                    if [ "$INSTALL_MAGICMIRROR" = "y" ] || [ "$INSTALL_MAGICMIRROR" = "Y" ]; then
                        ufw allow 8081:8083/tcp comment 'MagicMirror' 2>/dev/null
                        echo "  ✓ Allowed MagicMirror (8081-8083)"
                    fi
                    if [ "$INSTALL_ARM" = "y" ] || [ "$INSTALL_ARM" = "Y" ]; then
                        ufw allow 8080/tcp comment 'A.R.M.' 2>/dev/null
                        echo "  ✓ Allowed A.R.M. (8080)"
                    fi
                    if [ "$INSTALL_AUDIOBOOKSHELF" = "y" ] || [ "$INSTALL_AUDIOBOOKSHELF" = "Y" ]; then
                        ufw allow 13378/tcp comment 'Audiobookshelf' 2>/dev/null
                        echo "  ✓ Allowed Audiobookshelf (13378)"
                    fi

                    echo ""
                fi
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