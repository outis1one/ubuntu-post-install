#!/bin/bash

# Caddy Setup Helper Script
# This script helps manage Caddy configuration, backups, and fail2ban integration
# for dockerized Caddy setups - FULLY AUTOMATED with error handling

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "==============================================="
echo "  Caddy Configuration & Fail2ban Setup Helper"
echo "==============================================="
echo ""

# Function to print colored output
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to ask yes/no questions
ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [ "$default" = "y" ]; then
        read -p "$prompt [Y/n]: " response
        response=${response:-y}
    else
        read -p "$prompt [y/N]: " response
        response=${response:-n}
    fi

    [[ "$response" =~ ^[Yy]$ ]]
}

# Track if we need to show manual instructions
SHOW_MANUAL=false
ERROR_MESSAGES=()

# ==============================
# 1. CHECK IF CADDY IS INSTALLED
# ==============================
print_info "Checking for Caddy installation..."

CADDY_CONTAINER=""
CADDYFILE_PATH=""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    print_error "Docker is not installed or not in PATH"
    exit 1
fi

# Try to find Caddy container
if docker ps --format '{{.Names}}' | grep -iq "caddy"; then
    CADDY_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i "caddy" | head -1)
    print_success "Found running Caddy container: $CADDY_CONTAINER"
else
    print_warning "No running Caddy container found"
    if ! ask_yn "Is Caddy installed?" "n"; then
        print_info "Caddy is not installed. Please install Caddy first."
        echo ""
        echo "To install Caddy with Docker, see CADDY-FAIL2BAN-SETUP.md"
        exit 0
    fi
fi

# ==============================
# 2. LOCATE CADDYFILE
# ==============================
print_info "Locating Caddyfile..."

# Common Caddyfile locations
POSSIBLE_PATHS=(
    "$HOME/docker/caddy/Caddyfile"
    "$HOME/docker/caddy/caddyfile"
    "$HOME/docker/caddy/config/Caddyfile"
    "/etc/caddy/Caddyfile"
)

for path in "${POSSIBLE_PATHS[@]}"; do
    if [ -f "$path" ]; then
        CADDYFILE_PATH="$path"
        print_success "Found Caddyfile at: $CADDYFILE_PATH"
        break
    fi
done

if [ -z "$CADDYFILE_PATH" ]; then
    print_warning "Caddyfile not found in common locations"
    read -p "Enter path to Caddyfile: " CUSTOM_PATH
    if [ -n "$CUSTOM_PATH" ] && [ -f "$CUSTOM_PATH" ]; then
        CADDYFILE_PATH="$CUSTOM_PATH"
        print_success "Using Caddyfile at: $CADDYFILE_PATH"
    else
        print_error "Cannot proceed without Caddyfile location"
        exit 1
    fi
fi

CADDY_DIR=$(dirname "$CADDYFILE_PATH")

# ==============================
# 3. BACKUP CADDYFILE (ALWAYS FIRST!)
# ==============================
print_info "Creating backup of Caddyfile..."

BACKUP_DIR="$CADDY_DIR/backups"
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CADDYFILE_PATH" "$BACKUP_FILE"
print_success "Backup created: $BACKUP_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BACKUP RESTORE INSTRUCTIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To restore this backup:"
echo "  cp $BACKUP_FILE $CADDYFILE_PATH"
if [ -n "$CADDY_CONTAINER" ]; then
    echo "  docker exec -w /etc/caddy $CADDY_CONTAINER caddy reload"
    echo "  docker exec -w /etc/caddy $CADDY_CONTAINER caddy fmt --overwrite"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ==============================
# 4. CHECK FOR FAIL2BAN INSTALLATION
# ==============================
print_info "Checking for fail2ban installation..."

FAIL2BAN_INSTALLED=false
if command -v fail2ban-client &> /dev/null; then
    print_success "fail2ban is installed"
    FAIL2BAN_INSTALLED=true
else
    print_warning "fail2ban is not installed"

    if ask_yn "Would you like to install fail2ban now?" "y"; then
        print_info "Installing fail2ban..."

        if sudo apt update && sudo apt install -y fail2ban; then
            print_success "fail2ban installed successfully"
            FAIL2BAN_INSTALLED=true
        else
            print_error "Failed to install fail2ban"
            ERROR_MESSAGES+=("Failed to install fail2ban - you may need to install it manually")
            SHOW_MANUAL=true
        fi
    else
        print_warning "Skipping fail2ban installation"
        SHOW_MANUAL=true
    fi
fi

# ==============================
# 5. CREATE LOG DIRECTORY
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ]; then
    print_info "Checking Caddy log directory..."

    LOG_DIR="/var/log/caddy"
    if [ ! -d "$LOG_DIR" ]; then
        if ask_yn "Create $LOG_DIR for Caddy logs?" "y"; then
            if sudo mkdir -p "$LOG_DIR" && sudo chmod 755 "$LOG_DIR"; then
                print_success "Log directory created: $LOG_DIR"
            else
                print_error "Failed to create log directory"
                ERROR_MESSAGES+=("Failed to create $LOG_DIR - create it manually with: sudo mkdir -p $LOG_DIR && sudo chmod 755 $LOG_DIR")
                SHOW_MANUAL=true
            fi
        fi
    else
        print_success "Log directory exists: $LOG_DIR"
    fi
fi

# ==============================
# 6. CHECK CADDY DOCKER COMPOSE FOR LOG VOLUME
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ] && [ -n "$CADDY_CONTAINER" ]; then
    print_info "Checking if Caddy container has log volume mounted..."

    # Check if the container has /var/log/caddy mounted
    if docker inspect "$CADDY_CONTAINER" 2>/dev/null | grep -q "/var/log/caddy"; then
        print_success "Caddy container has log volume mounted"
    else
        print_warning "Caddy container does not have /var/log/caddy volume mounted"

        # Check if there's a docker-compose.yml
        COMPOSE_FILE=""
        for file in "$CADDY_DIR/docker-compose.yml" "$CADDY_DIR/docker-compose.yaml"; do
            if [ -f "$file" ]; then
                COMPOSE_FILE="$file"
                break
            fi
        done

        if [ -n "$COMPOSE_FILE" ]; then
            if ask_yn "Add /var/log/caddy volume to docker-compose.yml?" "y"; then
                # Backup docker-compose.yml
                cp "$COMPOSE_FILE" "$COMPOSE_FILE.backup.$(date +%Y%m%d_%H%M%S)"

                # Check if volumes section exists
                if grep -q "volumes:" "$COMPOSE_FILE"; then
                    # Add to existing volumes
                    if ! grep -q "/var/log/caddy" "$COMPOSE_FILE"; then
                        # Find the volumes section and add our volume
                        sed -i '/volumes:/a\      - /var/log/caddy:/var/log/caddy' "$COMPOSE_FILE"
                        print_success "Added log volume to docker-compose.yml"
                        print_warning "You'll need to restart the Caddy container for this to take effect"

                        if ask_yn "Restart Caddy container now?" "n"; then
                            cd "$CADDY_DIR"
                            if docker compose down && docker compose up -d; then
                                print_success "Caddy container restarted"
                                # Update CADDY_CONTAINER name in case it changed
                                CADDY_CONTAINER=$(docker ps --format '{{.Names}}' | grep -i "caddy" | head -1)
                            else
                                print_error "Failed to restart Caddy container"
                                ERROR_MESSAGES+=("Failed to restart Caddy - restart manually with: cd $CADDY_DIR && docker compose restart")
                            fi
                        fi
                    fi
                else
                    print_warning "Could not automatically add volume - docker-compose.yml format is unexpected"
                    ERROR_MESSAGES+=("Add this volume manually to your Caddy service: /var/log/caddy:/var/log/caddy")
                    SHOW_MANUAL=true
                fi
            fi
        else
            print_warning "No docker-compose.yml found - you may need to add the volume manually"
            ERROR_MESSAGES+=("Add log volume to Caddy container: /var/log/caddy:/var/log/caddy")
            SHOW_MANUAL=true
        fi
    fi
fi

# ==============================
# 7. CREATE FAIL2BAN FILTER
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ]; then
    print_info "Checking fail2ban filter configuration..."

    FILTER_FILE="/etc/fail2ban/filter.d/caddy-auth.conf"
    if [ -f "$FILTER_FILE" ]; then
        print_success "fail2ban filter already exists: $FILTER_FILE"
    else
        if ask_yn "Create fail2ban filter for Caddy?" "y"; then
            print_info "Creating fail2ban filter..."

            FILTER_CONTENT='[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403|429).*$
            ^.*"remote_addr":"<HOST>.*"status":(?:401|403|429).*$
ignoreregex = ^.*"remote_ip":"(?:127\.0\.0\.1|::1)".*$
datepattern = "ts":%%s'

            if echo "$FILTER_CONTENT" | sudo tee "$FILTER_FILE" > /dev/null; then
                print_success "Created fail2ban filter: $FILTER_FILE"
            else
                print_error "Failed to create fail2ban filter"
                ERROR_MESSAGES+=("Failed to create $FILTER_FILE - create it manually (see CADDY-FAIL2BAN-SETUP.md)")
                SHOW_MANUAL=true
            fi
        fi
    fi
fi

# ==============================
# 8. CREATE FAIL2BAN JAIL
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ]; then
    print_info "Checking fail2ban jail configuration..."

    JAIL_FILE="/etc/fail2ban/jail.d/caddy.conf"
    if [ -f "$JAIL_FILE" ]; then
        print_success "fail2ban jail already exists: $JAIL_FILE"
    else
        if ask_yn "Create fail2ban jail for Caddy?" "y"; then
            print_info "Creating fail2ban jail..."

            # Ask for custom settings
            echo ""
            print_info "Fail2ban jail settings (press Enter for defaults):"
            read -p "  Max retries before ban [5]: " MAXRETRY
            MAXRETRY=${MAXRETRY:-5}

            read -p "  Find time window in seconds [600]: " FINDTIME
            FINDTIME=${FINDTIME:-600}

            read -p "  Ban duration in seconds [3600]: " BANTIME
            BANTIME=${BANTIME:-3600}

            JAIL_CONTENT="[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/access.log
          /var/log/caddy/*-access.log
maxretry = $MAXRETRY
findtime = $FINDTIME
bantime = $BANTIME
action = iptables-multiport[name=CaddyAuth, port=\"http,https\", protocol=tcp]
backend = auto"

            if echo "$JAIL_CONTENT" | sudo tee "$JAIL_FILE" > /dev/null; then
                print_success "Created fail2ban jail: $JAIL_FILE"
            else
                print_error "Failed to create fail2ban jail"
                ERROR_MESSAGES+=("Failed to create $JAIL_FILE - create it manually (see CADDY-FAIL2BAN-SETUP.md)")
                SHOW_MANUAL=true
            fi
        fi
    fi
fi

# ==============================
# 9. TEST FAIL2BAN CONFIGURATION
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ]; then
    print_info "Testing fail2ban configuration..."

    if sudo fail2ban-client -t &> /dev/null; then
        print_success "fail2ban configuration is valid"
    else
        print_error "fail2ban configuration has errors"
        ERROR_MESSAGES+=("fail2ban configuration is invalid - check with: sudo fail2ban-client -t")
        SHOW_MANUAL=true
    fi
fi

# ==============================
# 10. RESTART FAIL2BAN
# ==============================
if [ "$FAIL2BAN_INSTALLED" = true ]; then
    if ask_yn "Restart fail2ban to apply changes?" "y"; then
        print_info "Restarting fail2ban..."

        if sudo systemctl restart fail2ban; then
            print_success "fail2ban restarted successfully"

            # Wait a moment for fail2ban to start
            sleep 2

            # Check if caddy-auth jail is running
            if sudo fail2ban-client status caddy-auth &> /dev/null; then
                print_success "caddy-auth jail is active"
                echo ""
                print_info "Jail status:"
                sudo fail2ban-client status caddy-auth
            else
                print_warning "caddy-auth jail is not active"
                ERROR_MESSAGES+=("caddy-auth jail failed to start - check with: sudo fail2ban-client status")
                SHOW_MANUAL=true
            fi
        else
            print_error "Failed to restart fail2ban"
            ERROR_MESSAGES+=("Failed to restart fail2ban - check logs with: sudo journalctl -u fail2ban -n 50")
            SHOW_MANUAL=true
        fi
    fi
fi

# ==============================
# 11. ADD SERVICE CONFIGURATIONS TO CADDYFILE
# ==============================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ADDING NEW SERVICES TO CADDYFILE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

print_info "You can now add your services to the Caddyfile"
echo ""
echo "Available services to add:"
echo "  - ActualBudget (Personal Finance) - Port 5006"
echo "  - Keycloak (Identity & Access Management) - Port 8180"
echo ""

if ask_yn "Would you like to add ActualBudget to Caddyfile?" "n"; then
    read -p "Enter domain for ActualBudget (e.g., budget.yourdomain.com): " AB_DOMAIN

    if [ -n "$AB_DOMAIN" ]; then
        AB_CONFIG="
# ActualBudget - Personal Finance
$AB_DOMAIN {
    log {
        output file /var/log/caddy/actualbudget-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:5006

    # Security headers
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\"
        X-Frame-Options \"SAMEORIGIN\"
        X-Content-Type-Options \"nosniff\"
        X-XSS-Protection \"1; mode=block\"
        Referrer-Policy \"strict-origin-when-cross-origin\"
    }
}
"

        if echo "$AB_CONFIG" >> "$CADDYFILE_PATH"; then
            print_success "Added ActualBudget configuration to Caddyfile"
        else
            print_error "Failed to add ActualBudget configuration"
            ERROR_MESSAGES+=("Add ActualBudget manually - see CADDY-FAIL2BAN-SETUP.md")
        fi
    fi
fi

if ask_yn "Would you like to add Keycloak to Caddyfile?" "n"; then
    read -p "Enter domain for Keycloak (e.g., auth.yourdomain.com): " KC_DOMAIN

    if [ -n "$KC_DOMAIN" ]; then
        KC_CONFIG="
# Keycloak - Identity & Access Management
$KC_DOMAIN {
    log {
        output file /var/log/caddy/keycloak-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:8180

    # Security headers
    header {
        Strict-Transport-Security \"max-age=31536000; includeSubDomains; preload\"
        X-Frame-Options \"SAMEORIGIN\"
        X-Content-Type-Options \"nosniff\"
        X-XSS-Protection \"1; mode=block\"
        Referrer-Policy \"strict-origin-when-cross-origin\"
    }
}
"

        if echo "$KC_CONFIG" >> "$CADDYFILE_PATH"; then
            print_success "Added Keycloak configuration to Caddyfile"
        else
            print_error "Failed to add Keycloak configuration"
            ERROR_MESSAGES+=("Add Keycloak manually - see CADDY-FAIL2BAN-SETUP.md")
        fi
    fi
fi

# ==============================
# 12. VALIDATE AND RELOAD CADDY
# ==============================
if [ -n "$CADDY_CONTAINER" ]; then
    echo ""
    if ask_yn "Validate and reload Caddy configuration?" "y"; then
        print_info "Validating Caddyfile..."

        # Format first
        if docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy fmt --overwrite 2>/dev/null; then
            print_success "Caddyfile formatted"
        fi

        # Validate
        if docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
            print_success "Caddyfile is valid"

            # Reload
            print_info "Reloading Caddy configuration..."
            if docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy reload 2>/dev/null; then
                print_success "Caddy configuration reloaded successfully"
            else
                print_error "Failed to reload Caddy configuration"
                ERROR_MESSAGES+=("Failed to reload Caddy - check logs with: docker logs $CADDY_CONTAINER")
                SHOW_MANUAL=true
            fi
        else
            print_error "Caddyfile validation failed"
            ERROR_MESSAGES+=("Caddyfile has syntax errors - check with: docker exec $CADDY_CONTAINER caddy validate --config /etc/caddy/Caddyfile")
            SHOW_MANUAL=true
        fi
    fi
fi

# ==============================
# 13. FINAL SUMMARY
# ==============================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SETUP COMPLETE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ "$SHOW_MANUAL" = true ]; then
    print_warning "Some steps could not be completed automatically"
    echo ""
    echo "Issues encountered:"
    for msg in "${ERROR_MESSAGES[@]}"; do
        echo "  - $msg"
    done
    echo ""
    print_info "See CADDY-FAIL2BAN-SETUP.md for manual setup instructions"
    echo ""
fi

print_success "Caddyfile backed up to: $BACKUP_FILE"

if [ "$FAIL2BAN_INSTALLED" = true ]; then
    print_success "fail2ban is installed and configured"
    echo ""
    echo "Useful commands:"
    echo "  Check jail status:    sudo fail2ban-client status caddy-auth"
    echo "  View banned IPs:      sudo fail2ban-client get caddy-auth banip"
    echo "  Unban IP:             sudo fail2ban-client set caddy-auth unbanip 1.2.3.4"
    echo "  Test filter:          sudo fail2ban-regex /var/log/caddy/access.log /etc/fail2ban/filter.d/caddy-auth.conf"
fi

echo ""
echo "Caddyfile location:       $CADDYFILE_PATH"
echo "Backup location:          $BACKUP_FILE"
if [ -n "$CADDY_CONTAINER" ]; then
    echo "Caddy container:          $CADDY_CONTAINER"
    echo "Reload Caddy:             docker exec -w /etc/caddy $CADDY_CONTAINER caddy reload"
    echo "View Caddy logs:          docker logs $CADDY_CONTAINER --tail 50"
fi
echo ""
print_success "All done!"
echo ""
