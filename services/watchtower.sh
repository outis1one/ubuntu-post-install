#!/bin/bash
# services/watchtower.sh — Watchtower automatic container update monitoring.
# Part of the modular post-install system (sourced by setup.sh).

register_service watchtower utilities "Automatic container updates (Watchtower)"

install_watchtower() {
    require_docker || return 1
    log_info "Installing Watchtower..."
    local WT_DIR="$DOCKER_DIR/watchtower"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $WT_DIR"
        return 0
    fi

    mkdir -p "$WT_DIR" 2>/dev/null || true
    ensure_docker_dir_ownership "$WT_DIR"
    cd "$WT_DIR" 2>/dev/null || cd "$DOCKER_DIR" || return 1

    # Ask about mode
    echo ""
    echo "Watchtower Mode:"
    echo "  [M] Monitor only - Get notifications about available updates (SAFE)"
    echo "  [A] Auto-update - Automatically pull and restart containers (RISKY)"
    echo ""
    echo "  ⚠️  Auto-update can break apps like Immich that need DB migrations!"
    echo "  Recommendation: Use monitor mode, update manually when ready."
    echo ""
    local WT_MODE="M"
    prompt_text "Mode [M/A]:" "M" WT_MODE
    WT_MODE=$(echo "$WT_MODE" | tr '[:lower:]' '[:upper:]')

    local MONITOR_ONLY
    if [ "$WT_MODE" = "A" ]; then
        MONITOR_ONLY="false"
        echo "  Mode: Auto-update (containers will be updated automatically)"
    else
        MONITOR_ONLY="true"
        echo "  Mode: Monitor only (you'll be notified of updates)"
    fi

    # Check for ntfy
    local NTFY_URL=""
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
      - WATCHTOWER_NOTIFICATION_URL=\${NOTIFICATION_URL:-}
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
    log_success "Watchtower installed at $WT_DIR"

    write_readme "$WT_DIR" << MD
# Watchtower

Monitors running containers for image updates. Defaults to NOTIFY-ONLY mode,
because apps like Immich can have breaking DB migrations on auto-update.

## No web interface
Watchtower has no web UI/port. It runs in the background and checks for updates
daily at 4 AM.

## Configuration
- Mode: $([ "$MONITOR_ONLY" = "true" ] && echo "Monitor only" || echo "Auto-update") (set MONITOR_ONLY in .env; "false" = auto-update)
- Notifications: set NOTIFICATION_URL in .env (ntfy, Discord, Slack, Gotify, ...)
  See https://containrrr.dev/shoutrrr/services/overview/

## Exclude a container
Add this label to any container you want Watchtower to ignore:
\`com.centurylinklabs.watchtower.enable=false\`

## Update an app manually
\`\`\`
cd ~/docker/<app>
docker compose pull
docker compose up -d
\`\`\`

## Manage
\`\`\`
cd $WT_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_WATCHTOWER=""
    prompt_yn "Start Watchtower now? (y/n):" "y" START_WATCHTOWER
    if [ "$START_WATCHTOWER" = "y" ] || [ "$START_WATCHTOWER" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Watchtower started" || log_warning "Failed to start"
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
}
