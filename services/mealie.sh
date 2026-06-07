#!/bin/bash
# services/mealie.sh — Recipe manager & meal planner (Mealie).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MEALIE ----).
# Own ~/docker/mealie/ with a standalone docker-compose.yml.

register_service mealie utilities "Recipe manager & meal planner (Mealie)" 9925

install_mealie() {
    require_docker || return 1

    local MEALIE_DIR="$DOCKER_DIR/mealie"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Mealie would:"
        echo "  - Create $MEALIE_DIR with docker-compose.yml (data/)"
        echo "  - Expose port 9925"
        echo "  - Default login: changeme@email.com / MyPassword (change immediately)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$MEALIE_DIR"
    ensure_docker_dir_ownership "$MEALIE_DIR"
    cd "$MEALIE_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << MEALIE_COMPOSE
name: mealie

services:
  mealie:
    image: ghcr.io/mealie-recipes/mealie:latest
    container_name: mealie
    hostname: mealie
    restart: unless-stopped
    environment:
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
      - ALLOW_SIGNUP=true
      - MAX_WORKERS=1
      - WEB_CONCURRENCY=1
      - BASE_URL=http://localhost:9925
    volumes:
      - ./data:/app/data
    ports:
      - "9925:9000"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
MEALIE_COMPOSE

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MEALIE_DIR"
    log_success "Mealie configured at $MEALIE_DIR"

    configure_caddy_for_service "Mealie" "mealie:9000" "recipes"

    write_readme "$MEALIE_DIR" << MD
# Mealie

Recipe manager and meal planner — import recipes from any URL, plan meals,
and generate shopping lists. Optional AI-powered recipe parsing.

- Web UI: http://localhost:9925
- Default login: changeme@email.com / MyPassword (change immediately!)
- App data: \`data/\`

## Manage
\`\`\`bash
cd $MEALIE_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- If using Caddy, update \`BASE_URL\` in \`docker-compose.yml\` to your domain.
MD

    local START_MEALIE=""
    prompt_yn "Start Mealie now? (y/n):" "y" START_MEALIE
    if [ "$START_MEALIE" = "y" ] || [ "$START_MEALIE" = "Y" ]; then
        docker compose up -d && log_success "Mealie started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:9925"
    echo "  Default:    changeme@email.com / MyPassword  (change immediately!)"
    echo ""
}
