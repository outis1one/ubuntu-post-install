#!/bin/bash
# services/portainer.sh — Portainer Docker management web UI.
# Part of the modular post-install system (sourced by setup.sh).

register_service portainer utilities "Docker management UI (Portainer)" 9443

install_portainer() {
    require_docker || return 1
    log_info "Installing Portainer..."
    local PORTAINER_DIR="$DOCKER_DIR/portainer"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $PORTAINER_DIR"
        return 0
    fi

    mkdir -p "$PORTAINER_DIR"
    ensure_docker_dir_ownership "$PORTAINER_DIR"
    cd "$PORTAINER_DIR" || return 1

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
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
PORTAINER_COMPOSE

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$PORTAINER_DIR"

    echo ""
    log_success "Portainer configured at $PORTAINER_DIR"

    configure_caddy_for_service "Portainer" "9000" "portainer"

    write_readme "$PORTAINER_DIR" << MD
# Portainer

Web UI for managing Docker — containers, images, volumes, and networks.

## Access
- HTTPS: https://localhost:9443
- HTTP:  http://localhost:9000
- Create your admin account on first visit.

## Data
- App data: ./data (mounted to /data)
- Mounts the Docker socket to manage the host's Docker.

## Manage
\`\`\`
cd $PORTAINER_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_PORTAINER=""
    prompt_yn "Start Portainer now? (y/n):" "y" START_PORTAINER
    if [ "$START_PORTAINER" = "y" ] || [ "$START_PORTAINER" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Portainer started" || log_warning "Failed to start"
    fi

    echo "  Access at:  https://localhost:9443"
    echo "  Create admin account on first visit"
    echo ""
}
