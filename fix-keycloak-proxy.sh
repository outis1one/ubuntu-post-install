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
echo "  1. Backup your current configuration"
echo "  2. Create .env file for credentials"
echo "  3. Update docker-compose.yml to use env_file"
echo "  4. Replace deprecated KC_PROXY with KC_PROXY_HEADERS"
echo "  5. Restart Keycloak with new configuration"
echo ""

if [ ! -d "$KC_DIR" ]; then
    echo "❌ Error: Keycloak directory not found at $KC_DIR"
    exit 1
fi

cd "$KC_DIR"

# Check if docker-compose.yml exists
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found in $KC_DIR"
    exit 1
fi

# Backup existing configuration
BACKUP_DIR="$KC_DIR/backups"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml.backup.$TIMESTAMP"
echo "✓ Backed up docker-compose.yml to $BACKUP_DIR/docker-compose.yml.backup.$TIMESTAMP"

# Extract passwords from existing docker-compose.yml
echo ""
echo "Extracting credentials from existing configuration..."

KC_ADMIN_PASS=$(grep "KEYCLOAK_ADMIN_PASSWORD" docker-compose.yml | head -1 | sed 's/.*KEYCLOAK_ADMIN_PASSWORD[=:]\s*//' | tr -d '"' | tr -d "'" | xargs)
KC_DB_PASS=$(grep "POSTGRES_PASSWORD" docker-compose.yml | head -1 | sed 's/.*POSTGRES_PASSWORD[=:]\s*//' | tr -d '"' | tr -d "'" | xargs)
KC_HOSTNAME=$(grep "KC_HOSTNAME[=:]" docker-compose.yml | grep -v STRICT | head -1 | sed 's/.*KC_HOSTNAME[=:]\s*//' | tr -d '"' | tr -d "'" | xargs)
KC_START_CMD=$(grep -A 2 "keycloak:" docker-compose.yml | grep "command:" -A 1 | tail -1 | sed 's/.*- //' | xargs)

# Validate we got the passwords
if [ -z "$KC_ADMIN_PASS" ] || [ -z "$KC_DB_PASS" ]; then
    echo "❌ Error: Could not extract passwords from docker-compose.yml"
    echo "   Please check your configuration manually"
    exit 1
fi

echo "✓ Admin password: ${KC_ADMIN_PASS:0:4}***${KC_ADMIN_PASS: -4}"
echo "✓ Database password: ${KC_DB_PASS:0:4}***${KC_DB_PASS: -4}"
[ -n "$KC_HOSTNAME" ] && echo "✓ Hostname: $KC_HOSTNAME"
echo "✓ Start command: $KC_START_CMD"

# Determine hostname strict mode
if [ "$KC_START_CMD" = "start" ]; then
    KC_HOSTNAME_STRICT="false"
else
    KC_HOSTNAME_STRICT="false"
fi

# Create .env file
echo ""
echo "Creating .env file..."

cat > .env << KC_ENV
# Keycloak Environment Variables
# ⚠ KEEP THIS FILE SECURE - Contains sensitive passwords
# Generated: $TIMESTAMP

# Admin Credentials
KEYCLOAK_ADMIN=admin
KEYCLOAK_ADMIN_PASSWORD=$KC_ADMIN_PASS

# Database Credentials
POSTGRES_DB=keycloak
POSTGRES_USER=keycloak
POSTGRES_PASSWORD=$KC_DB_PASS
KC_DB=postgres
KC_DB_URL=jdbc:postgresql://postgres:5432/keycloak
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=$KC_DB_PASS

# Keycloak Configuration (v2 Proxy Headers)
KC_PROXY_HEADERS=xforwarded
KC_HTTP_ENABLED=true
KC_HOSTNAME_STRICT=$KC_HOSTNAME_STRICT
KC_LOG_LEVEL=INFO
KC_HEALTH_ENABLED=true
KC_METRICS_ENABLED=true
KC_ENV

# Add hostname if it was configured
if [ -n "$KC_HOSTNAME" ]; then
    echo "KC_HOSTNAME=$KC_HOSTNAME" >> .env
fi

# Set proper ownership
chown "$USER:$USER" .env
chmod 600 .env

echo "✓ Created .env file with secure permissions (600)"

# Create new docker-compose.yml
echo ""
echo "Creating new docker-compose.yml..."

cat > docker-compose.yml << KC_COMPOSE
name: keycloak

services:
  postgres:
    image: postgres:16-alpine
    container_name: keycloak-db
    restart: unless-stopped
    env_file:
      - .env
    volumes:
      - ./postgres-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U keycloak"]
      interval: 10s
      timeout: 5s
      retries: 5

  keycloak:
    image: quay.io/keycloak/keycloak:latest
    container_name: keycloak
    restart: unless-stopped
    command:
      - $KC_START_CMD
    env_file:
      - .env
    ports:
      - "8180:8080"
    volumes:
      - ./data:/opt/keycloak/data
    depends_on:
      postgres:
        condition: service_healthy
    labels:
      - "io.podman.annotations.label/fail2ban.enable=true"
      - "io.podman.annotations.label/fail2ban.filter=caddy-auth"
KC_COMPOSE

echo "✓ Created new docker-compose.yml with v2 proxy headers"

# Restart Keycloak
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Restarting Keycloak with new configuration..."
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
    echo "Configuration changes:"
    echo "  • Deprecated KC_PROXY removed"
    echo "  • New KC_PROXY_HEADERS=xforwarded added"
    echo "  • Credentials moved to .env file"
    echo "  • docker-compose.yml uses env_file"
    echo ""
    echo "Your Keycloak instance is now using v2 proxy configuration."
    echo "The warnings about deprecated proxy options should be gone."
    echo ""
    [ -n "$KC_HOSTNAME" ] && echo "Access URL: https://$KC_HOSTNAME" || echo "Access URL: http://localhost:8180"
    echo ""
else
    echo ""
    echo "⚠ Keycloak may still be starting. Check logs:"
    echo "   docker compose logs -f keycloak"
fi

echo ""
echo "Backup location: $BACKUP_DIR/docker-compose.yml.backup.$TIMESTAMP"
echo ""
