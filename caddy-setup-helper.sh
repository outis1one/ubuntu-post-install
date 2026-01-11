#!/bin/bash

# Caddy Setup Helper Script
# This script helps manage Caddy configuration, backups, and fail2ban integration
# for dockerized Caddy setups

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
if docker ps --format '{{.Names}}' | grep -q "caddy"; then
    CADDY_CONTAINER=$(docker ps --format '{{.Names}}' | grep "caddy" | head -1)
    print_success "Found running Caddy container: $CADDY_CONTAINER"
else
    print_warning "No running Caddy container found"
    read -p "Is Caddy installed? (y/n): " CADDY_INSTALLED
    if [ "$CADDY_INSTALLED" != "y" ] && [ "$CADDY_INSTALLED" != "Y" ]; then
        print_info "Caddy is not installed. Please install Caddy first."
        echo ""
        echo "To install Caddy with Docker:"
        echo "  mkdir -p ~/docker/caddy"
        echo "  cd ~/docker/caddy"
        echo "  # Create docker-compose.yml (see example below)"
        echo "  docker compose up -d"
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
    read -p "Enter path to Caddyfile (or press Enter to skip): " CUSTOM_PATH
    if [ -n "$CUSTOM_PATH" ] && [ -f "$CUSTOM_PATH" ]; then
        CADDYFILE_PATH="$CUSTOM_PATH"
        print_success "Using Caddyfile at: $CADDYFILE_PATH"
    else
        print_error "Cannot proceed without Caddyfile location"
        exit 1
    fi
fi

# ==============================
# 3. BACKUP CADDYFILE
# ==============================
print_info "Creating backup of Caddyfile..."

BACKUP_DIR=$(dirname "$CADDYFILE_PATH")/backups
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CADDYFILE_PATH" "$BACKUP_FILE"
print_success "Backup created: $BACKUP_FILE"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BACKUP RESTORE INSTRUCTIONS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "To restore this backup:"
echo "  1. Copy backup to original location:"
echo "     cp $BACKUP_FILE $CADDYFILE_PATH"
echo ""
echo "  2. Reload Caddy configuration:"
if [ -n "$CADDY_CONTAINER" ]; then
    echo "     docker exec -w /etc/caddy $CADDY_CONTAINER caddy reload"
    echo "     docker exec -w /etc/caddy $CADDY_CONTAINER caddy fmt --overwrite"
else
    echo "     docker exec -w /etc/caddy caddy caddy reload"
    echo "     docker exec -w /etc/caddy caddy caddy fmt --overwrite"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ==============================
# 4. CHECK FOR FAIL2BAN SUPPORT
# ==============================
print_info "Checking Caddy configuration for fail2ban support..."

NEEDS_FAIL2BAN_CONFIG=false

# Check if Caddyfile has access logging configured
if ! grep -q "log {" "$CADDYFILE_PATH" && ! grep -q "log " "$CADDYFILE_PATH"; then
    print_warning "No logging configuration found in Caddyfile"
    NEEDS_FAIL2BAN_CONFIG=true
else
    print_success "Logging configuration found"
fi

# Check for common security headers
if ! grep -q "header" "$CADDYFILE_PATH"; then
    print_warning "No security headers configured"
fi

# ==============================
# 5. OFFER TO ADD FAIL2BAN SUPPORT
# ==============================
if [ "$NEEDS_FAIL2BAN_CONFIG" = true ]; then
    echo ""
    read -p "Would you like to add fail2ban logging support to Caddyfile? (y/n): " ADD_FAIL2BAN

    if [ "$ADD_FAIL2BAN" = "y" ] || [ "$ADD_FAIL2BAN" = "Y" ]; then
        print_info "Adding fail2ban support..."

        # Create a new Caddyfile with fail2ban support
        TEMP_CADDYFILE="${CADDYFILE_PATH}.tmp"

        # Add global options if not present
        if ! grep -q "{" "$CADDYFILE_PATH" | head -1 | grep -q "^{"; then
            cat > "$TEMP_CADDYFILE" << 'EOF'
{
    # Global options
    admin off
    # Persist config
    persist_config off
}

EOF
        fi

        # Append original content
        cat "$CADDYFILE_PATH" >> "$TEMP_CADDYFILE"

        # Move temp file to original
        mv "$TEMP_CADDYFILE" "$CADDYFILE_PATH"

        print_success "Added global configuration"
        print_info "Note: You'll need to add logging to individual sites"
    fi
fi

# ==============================
# 6. PROVIDE FAIL2BAN CONFIGURATION
# ==============================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FAIL2BAN CONFIGURATION FOR CADDY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "To enable fail2ban protection for your Caddy services:"
echo ""
echo "1. Add logging to each site in your Caddyfile:"
echo ""
cat << 'EOF'
yourdomain.com {
    # Enable structured logging for fail2ban
    log {
        output file /var/log/caddy/access.log
        format json
        level INFO
    }

    # Reverse proxy or other directives
    reverse_proxy localhost:8080
}
EOF

echo ""
echo "2. Create fail2ban filter at /etc/fail2ban/filter.d/caddy-auth.conf:"
echo ""
cat << 'EOF'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403|429).*$
            ^.*"remote_addr":"<HOST>.*"status":(?:401|403|429).*$
ignoreregex =
EOF

echo ""
echo "3. Create fail2ban jail at /etc/fail2ban/jail.d/caddy.conf:"
echo ""
cat << 'EOF'
[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/access.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=CaddyAuth, port="http,https", protocol=tcp]
EOF

echo ""
echo "4. Restart fail2ban:"
echo "   sudo systemctl restart fail2ban"
echo "   sudo fail2ban-client status caddy-auth"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ==============================
# 7. EXAMPLE SITE CONFIGURATIONS
# ==============================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ADDING NEW SERVICES TO CADDY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add these blocks to your Caddyfile for your new services:"
echo ""

# ActualBudget example
echo "# ActualBudget (Personal Finance)"
cat << 'EOF'
budget.yourdomain.com {
    log {
        output file /var/log/caddy/actualbudget-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:5006

    # Security headers
    header {
        # Enable HSTS
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        # Prevent clickjacking
        X-Frame-Options "SAMEORIGIN"
        # Prevent MIME type sniffing
        X-Content-Type-Options "nosniff"
        # XSS protection
        X-XSS-Protection "1; mode=block"
        # Referrer policy
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF

echo ""
echo "# Keycloak (Identity & Access Management)"
cat << 'EOF'
auth.yourdomain.com {
    log {
        output file /var/log/caddy/keycloak-access.log
        format json
        level INFO
    }

    reverse_proxy localhost:8180

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Frame-Options "SAMEORIGIN"
        X-Content-Type-Options "nosniff"
        X-XSS-Protection "1; mode=block"
        Referrer-Policy "strict-origin-when-cross-origin"
    }
}
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ==============================
# 8. RELOAD CADDY
# ==============================
if [ -n "$CADDY_CONTAINER" ]; then
    read -p "Would you like to reload Caddy configuration now? (y/n): " RELOAD_NOW

    if [ "$RELOAD_NOW" = "y" ] || [ "$RELOAD_NOW" = "Y" ]; then
        print_info "Reloading Caddy configuration..."

        if docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy fmt --overwrite 2>/dev/null; then
            print_success "Caddyfile formatted"
        fi

        if docker exec -w /etc/caddy "$CADDY_CONTAINER" caddy reload 2>/dev/null; then
            print_success "Caddy configuration reloaded successfully"
        else
            print_error "Failed to reload Caddy configuration"
            print_info "Check Caddy logs: docker logs $CADDY_CONTAINER"
        fi
    fi
fi

echo ""
print_success "Caddy setup helper completed!"
echo ""
echo "Next steps:"
echo "  1. Review and edit Caddyfile: $CADDYFILE_PATH"
echo "  2. Add site configurations for ActualBudget and Keycloak (see examples above)"
echo "  3. Set up fail2ban filters and jails (see instructions above)"
echo "  4. Test Caddy configuration: docker exec $CADDY_CONTAINER caddy validate --config /etc/caddy/Caddyfile"
echo "  5. Reload Caddy: docker exec -w /etc/caddy $CADDY_CONTAINER caddy reload"
echo ""
