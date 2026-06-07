#!/bin/bash
# services/ntfy.sh — ntfy self-hosted push notification server.
# Part of the modular post-install system (sourced by setup.sh).

register_service ntfy utilities "Self-hosted push notifications (ntfy)" 8090

install_ntfy() {
    require_docker || return 1
    log_info "Installing ntfy..."
    local NTFY_DIR="$DOCKER_DIR/ntfy"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $NTFY_DIR"
        return 0
    fi

    mkdir -p "$NTFY_DIR"
    ensure_docker_dir_ownership "$NTFY_DIR"
    cd "$NTFY_DIR" || return 1

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
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
NTFY_COMPOSE

    cat > .env << NTFY_ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
CADDY_NET=$SITE_CADDY_NET
NTFY_ENV

    mkdir -p cache config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$NTFY_DIR"

    echo ""
    log_success "ntfy configured at $NTFY_DIR"

    configure_caddy_for_service "ntfy" "8090" "ntfy"

    write_readme "$NTFY_DIR" << MD
# ntfy

Self-hosted push notification server. Send notifications from scripts to your
phone or browser.

## Access
- URL: http://localhost:8090

## Usage
- Send a notification: \`curl -d "Hello!" localhost:8090/mytopic\`
- Subscribe on phone: ntfy app -> Add subscription -> localhost:8090/mytopic

## Data
- Config: ./config (mounted to /etc/ntfy)
- Cache: ./cache (mounted to /var/cache/ntfy)

## Manage
\`\`\`
cd $NTFY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_NTFY=""
    prompt_yn "Start ntfy now? (y/n):" "y" START_NTFY
    if [ "$START_NTFY" = "y" ] || [ "$START_NTFY" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "ntfy started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:8090"
    echo ""
    echo "  Send notification: curl -d \"Hello!\" localhost:8090/mytopic"
    echo "  Subscribe on phone: ntfy app → Add subscription → localhost:8090/mytopic"
    echo ""
}
