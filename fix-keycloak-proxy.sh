#!/bin/bash
#
# Fix Keycloak proxy configuration
# This updates Keycloak to use v2 proxy headers (KC_PROXY_HEADERS)
# instead of deprecated v1 (KC_PROXY)
#

set -e

KC_DIR="$HOME/docker/keycloak"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Keycloak Proxy Configuration Fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This script will:"
echo "  1. Backup your current .env file"
echo "  2. Replace deprecated KC_PROXY with KC_PROXY_HEADERS"
echo "  3. Ensure docker-compose.yml uses env_file"
echo "  4. Restart Keycloak with new configuration"
echo ""

if [ ! -d "$KC_DIR" ]; then
    echo "❌ Error: Keycloak directory not found at $KC_DIR"
    exit 1
fi

cd "$KC_DIR"

# Backup existing configuration
BACKUP_DIR="$KC_DIR/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Check if .env exists
if [ -f ".env" ]; then
    echo "✓ Found existing .env file"
    cp .env "$BACKUP_DIR/.env.backup.$TIMESTAMP"
    echo "✓ Backed up .env to $BACKUP_DIR/.env.backup.$TIMESTAMP"

    # Check if it has the old KC_PROXY setting
    if grep -q "KC_PROXY=" .env 2>/dev/null; then
        echo ""
        echo "Updating .env file..."

        # Replace KC_PROXY with KC_PROXY_HEADERS
        sed -i 's/^KC_PROXY=.*/KC_PROXY_HEADERS=xforwarded/' .env

        # Add KC_PROXY_HEADERS if it doesn't exist and KC_PROXY didn't either
        if ! grep -q "KC_PROXY_HEADERS=" .env 2>/dev/null; then
            echo "" >> .env
            echo "# Proxy settings (v2) - Trust X-Forwarded-* headers from Caddy2" >> .env
            echo "KC_PROXY_HEADERS=xforwarded" >> .env
        fi

        echo "✓ Updated KC_PROXY to KC_PROXY_HEADERS=xforwarded"
    elif grep -q "KC_PROXY_HEADERS=" .env 2>/dev/null; then
        echo "✓ Already using KC_PROXY_HEADERS - no changes needed"
    else
        echo ""
        echo "Adding KC_PROXY_HEADERS to .env..."
        echo "" >> .env
        echo "# Proxy settings (v2) - Trust X-Forwarded-* headers from Caddy2" >> .env
        echo "KC_PROXY_HEADERS=xforwarded" >> .env
        echo "✓ Added KC_PROXY_HEADERS=xforwarded"
    fi
else
    echo "⚠ No .env file found"
    echo ""
    echo "Please create a .env file with your Keycloak credentials."
    echo "See SECURITY-IMPROVEMENTS.md for the template."
    exit 1
fi

# Check docker-compose.yml
if [ -f "docker-compose.yml" ]; then
    cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml.backup.$TIMESTAMP"
    echo "✓ Backed up docker-compose.yml to $BACKUP_DIR/docker-compose.yml.backup.$TIMESTAMP"

    # Check if docker-compose.yml has hardcoded KC_PROXY
    if grep -q "KC_PROXY=" docker-compose.yml 2>/dev/null; then
        echo ""
        echo "⚠ Found KC_PROXY in docker-compose.yml"
        echo "  Removing it (should be in .env file instead)..."

        # Remove the KC_PROXY line from docker-compose.yml
        sed -i '/KC_PROXY=/d' docker-compose.yml
        echo "✓ Removed KC_PROXY from docker-compose.yml"
    fi

    # Ensure it uses env_file
    if ! grep -q "env_file:" docker-compose.yml 2>/dev/null; then
        echo "⚠ docker-compose.yml doesn't use env_file"
        echo "  You may need to update it manually to use 'env_file: - .env'"
    else
        echo "✓ docker-compose.yml uses env_file"
    fi
fi

# Show current configuration
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Current Configuration:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -f ".env" ]; then
    echo "Proxy Settings:"
    grep "KC_PROXY" .env | grep -v "^#" || echo "  (none found)"
    echo ""

    if grep -q "KC_HOSTNAME=" .env | grep -v "^#" 2>/dev/null; then
        echo "Hostname:"
        grep "KC_HOSTNAME=" .env | grep -v "^#"
        echo ""
    fi
fi

# Ask to restart
echo ""
read -p "Restart Keycloak with new configuration? (y/n): " RESTART

if [ "$RESTART" = "y" ] || [ "$RESTART" = "Y" ]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Restarting Keycloak..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    docker compose down
    echo "✓ Stopped Keycloak"

    echo ""
    echo "Starting Keycloak (this may take a minute)..."
    docker compose up -d

    # Wait for Keycloak to be ready
    echo ""
    echo "Waiting for Keycloak to be ready..."
    KC_READY=false
    for i in {1..60}; do
        if docker exec keycloak curl -sf http://localhost:8080/health/ready > /dev/null 2>&1; then
            KC_READY=true
            echo ""
            echo "✓ Keycloak is ready"
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    if [ "$KC_READY" = true ]; then
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "✅ Keycloak successfully updated!"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "Changes applied:"
        echo "  • Deprecated KC_PROXY removed"
        echo "  • New KC_PROXY_HEADERS=xforwarded configured"
        echo "  • Configuration stored in .env file"
        echo ""
        echo "The 'Hostname v1 options [proxy]' warnings should be gone."
        echo ""
        echo "Check the logs:"
        echo "  docker compose logs -f keycloak"
        echo ""
    else
        echo ""
        echo "⚠ Keycloak may still be starting. Check logs:"
        echo "   docker compose logs -f keycloak"
    fi
else
    echo ""
    echo "Skipping restart. To apply changes later, run:"
    echo "  cd $KC_DIR && docker compose restart"
fi

echo ""
echo "Backup location: $BACKUP_DIR/"
echo "  - .env.backup.$TIMESTAMP"
echo "  - docker-compose.yml.backup.$TIMESTAMP"
echo ""
