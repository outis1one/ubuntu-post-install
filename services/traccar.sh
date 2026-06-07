#!/bin/bash
# services/traccar.sh — GPS tracking server (Traccar).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- TRACCAR ----).
# Own ~/docker/traccar/ with a standalone docker-compose.yml + config XML.

register_service traccar utilities "GPS tracking server — phones, vehicles, assets (Traccar)" 8082

install_traccar() {
    require_docker || return 1

    local TRACCAR_DIR="$DOCKER_DIR/traccar"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Traccar would:"
        echo "  - Create $TRACCAR_DIR with docker-compose.yml + config/traccar.xml"
        echo "  - Expose port 8082 (web) and 5000-5150 (device protocols)"
        echo "  - Default login: admin@admin.com / admin (change immediately!)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$TRACCAR_DIR"
    ensure_docker_dir_ownership "$TRACCAR_DIR"
    cd "$TRACCAR_DIR" || return 1

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
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
TRACCAR_COMPOSE

    mkdir -p logs data config

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
    log_success "Traccar configured at $TRACCAR_DIR"

    configure_caddy_for_service "Traccar" "traccar:8082" "traccar"

    write_readme "$TRACCAR_DIR" << MD
# Traccar

GPS tracking server. Track phones, vehicles, and assets via the Traccar
Android/iOS app, OwnTracks, or any of 200+ supported device protocols.

- Web UI: http://localhost:8082
- Default login: admin@admin.com / admin  (change immediately!)
- Device protocols: ports 5000-5150 (TCP + UDP)
- Config: \`config/traccar.xml\`
- App data: \`data/\` and \`logs/\`

## Manage
\`\`\`bash
cd $TRACCAR_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Mobile apps
- Traccar Client (Android/iOS): set server to \`http://YOUR-IP:8082\`
- OwnTracks (Android/iOS): configure HTTP endpoint to Traccar
MD

    local START_TRACCAR=""
    prompt_yn "Start Traccar now? (y/n):" "y" START_TRACCAR
    if [ "$START_TRACCAR" = "y" ] || [ "$START_TRACCAR" = "Y" ]; then
        docker compose up -d && log_success "Traccar started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8082"
    echo "  Default:    admin@admin.com / admin  (change immediately!)"
    echo ""
}
