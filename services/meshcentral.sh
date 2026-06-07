#!/bin/bash
# services/meshcentral.sh — Self-hosted remote device management server (MeshCentral).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MESHCENTRAL SERVER ----).
# Own ~/docker/meshcentral/ with a standalone docker-compose.yml + .env.
# HTTPS on port 4430, agent listener on 4433. First visit: create admin account.

register_service meshcentral utilities "Self-hosted remote device management server (MeshCentral)" 4430

install_meshcentral() {
    require_docker || return 1

    local MC_DIR="$DOCKER_DIR/meshcentral"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] MeshCentral would:"
        echo "  - Create $MC_DIR with docker-compose.yml + .env (data/ files/ backups/)"
        echo "  - Prompt for hostname (domain or IP for agent connections)"
        echo "  - Expose port 4430 (HTTPS web) and 4433 (agent)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MC_HOSTNAME=""
    prompt_text "MeshCentral hostname (domain or IP) [localhost]:" "localhost" MC_HOSTNAME
    MC_HOSTNAME="${MC_HOSTNAME:-localhost}"

    mkdir -p "$MC_DIR"
    ensure_docker_dir_ownership "$MC_DIR"
    cd "$MC_DIR" || return 1

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
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
MC_COMPOSE

    cat > .env << MC_ENV
MC_HOSTNAME=$MC_HOSTNAME
MC_REVERSE_PROXY=false
MC_TLS_PORT=443
CADDY_NET=$SITE_CADDY_NET
MC_ENV

    mkdir -p data files backups
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR"
    log_success "MeshCentral configured at $MC_DIR"

    configure_caddy_for_service "MeshCentral" "4430" "mesh"

    write_readme "$MC_DIR" << MD
# MeshCentral

Self-hosted remote device management — remotely access, manage, and monitor
all your computers from a single web interface. Install agents on each device.

- Web UI: https://localhost:4430  (self-signed cert on first launch)
- Agent listener: port 4433 (devices connect here — forward this port if remote)
- Hostname: \`$MC_HOSTNAME\` (update \`MC_HOSTNAME\` in .env if it changes)
- App data: \`data/\`, \`files/\`, \`backups/\`

## Manage
\`\`\`bash
cd $MC_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## First launch
1. Open https://localhost:4430 (accept the self-signed cert warning)
2. Create your admin account
3. Go to "My Devices" → "+ Add Device" → download the agent for each OS
4. Install the agent on every computer you want to manage

## Remote access
For devices outside your LAN to connect:
- Forward **TCP port 4433** on your router to this server
- Set \`MC_HOSTNAME\` in \`.env\` to your public domain/IP, then restart

## Docs
https://meshcentral.com/docs/
MD

    local START_MC=""
    prompt_yn "Start MeshCentral now? (y/n):" "y" START_MC
    if [ "$START_MC" = "y" ] || [ "$START_MC" = "Y" ]; then
        docker compose up -d && log_success "MeshCentral started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  https://localhost:4430  (accept self-signed cert)"
    echo "  First visit: create your admin account"
    echo ""
}
