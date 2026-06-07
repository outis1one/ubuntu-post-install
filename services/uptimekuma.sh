#!/bin/bash
# services/uptimekuma.sh — Uptime Kuma uptime/status monitoring.
# Part of the modular post-install system (sourced by setup.sh).

register_service uptimekuma utilities "Uptime/status monitoring (Uptime Kuma)" 3001

install_uptimekuma() {
    require_docker || return 1
    log_info "Installing Uptime Kuma..."
    local UPTIME_DIR="$DOCKER_DIR/uptime-kuma"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $UPTIME_DIR"
        return 0
    fi

    mkdir -p "$UPTIME_DIR"
    ensure_docker_dir_ownership "$UPTIME_DIR"
    cd "$UPTIME_DIR" || return 1

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
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
UPTIME_COMPOSE

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$UPTIME_DIR"

    echo ""
    log_success "Uptime Kuma configured at $UPTIME_DIR"

    write_readme "$UPTIME_DIR" << MD
# Uptime Kuma

Self-hosted uptime/status monitoring dashboard. Monitor websites, servers, and
Docker containers.

## Access
- URL: http://localhost:3001
- Create your admin account on first visit.

## Data
- App data: ./data (mounted to /app/data)
- Mounts the Docker socket (read-only) for container monitoring.

## Reverse proxy
If Caddy is installed, you can expose this via the prompt during install
(see configure_caddy_for_service). Default subdomain: uptime.

## Manage
\`\`\`
cd $UPTIME_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    # Configure Caddy reverse proxy before starting
    configure_caddy_for_service "Uptime Kuma" "uptime-kuma:3001" "uptime"

    local START_UPTIME=""
    prompt_yn "Start Uptime Kuma now? (y/n):" "y" START_UPTIME
    if [ "$START_UPTIME" = "y" ] || [ "$START_UPTIME" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Uptime Kuma started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:3001"
    echo ""
}
