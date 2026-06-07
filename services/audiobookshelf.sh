#!/bin/bash
# services/audiobookshelf.sh — Audiobook & podcast server (Audiobookshelf).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- AUDIOBOOKSHELF ----).
# Own ~/docker/audiobookshelf/ with a standalone docker-compose.yml + .env.

register_service audiobookshelf media "Audiobook & podcast server (Audiobookshelf)" 13378

install_audiobookshelf() {
    require_docker || return 1

    local ABS_DIR="$DOCKER_DIR/audiobookshelf"
    local DEFAULT_AUDIOBOOKS="$ACTUAL_HOME/audiobooks"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Audiobookshelf would:"
        echo "  - Create $ABS_DIR with docker-compose.yml + .env (config/ metadata/ podcasts/)"
        echo "  - Mount an audiobooks folder (default $DEFAULT_AUDIOBOOKS) at /audiobooks"
        echo "  - Expose port 13378"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local AUDIOBOOKS_PATH=""
    prompt_text "Path to audiobooks folder [$DEFAULT_AUDIOBOOKS]:" "$DEFAULT_AUDIOBOOKS" AUDIOBOOKS_PATH
    AUDIOBOOKS_PATH="${AUDIOBOOKS_PATH/#\~/$ACTUAL_HOME}"; AUDIOBOOKS_PATH="${AUDIOBOOKS_PATH%/}"

    mkdir -p "$ABS_DIR"
    ensure_docker_dir_ownership "$ABS_DIR"
    cd "$ABS_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << ABS_COMPOSE
name: audiobookshelf

services:
  audiobookshelf:
    image: ghcr.io/advplyr/audiobookshelf:latest
    container_name: audiobookshelf
    hostname: audiobookshelf
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config
      - ./metadata:/metadata
      - \${AUDIOBOOKS_PATH}:/audiobooks
      - \${PODCASTS_PATH:-./podcasts}:/podcasts
    ports:
      - "13378:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
ABS_COMPOSE

    cat > .env << ABS_ENV
AUDIOBOOKS_PATH=$AUDIOBOOKS_PATH
PODCASTS_PATH=./podcasts
CADDY_NET=$SITE_CADDY_NET
ABS_ENV

    mkdir -p config metadata podcasts
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ABS_DIR"
    log_success "Audiobookshelf configured at $ABS_DIR"

    configure_caddy_for_service "AudioBookshelf" "audiobookshelf:80" "audiobooks"

    write_readme "$ABS_DIR" << MD
# Audiobookshelf

Self-hosted audiobook and podcast server with progress sync across devices.

- Web UI: http://localhost:13378
- Audiobooks: \`$AUDIOBOOKS_PATH\` → mounted at /audiobooks
- Podcasts: \`podcasts/\` in this folder → /podcasts (change \`PODCASTS_PATH\` in .env)
- App data: \`config/\` and \`metadata/\`

## Manage
\`\`\`bash
cd $ABS_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

First launch: open the web UI, create your admin account, then add libraries
pointing at /audiobooks and /podcasts.
MD

    local START_ABS=""
    prompt_yn "Start Audiobookshelf now? (y/n):" "y" START_ABS
    if [ "$START_ABS" = "y" ] || [ "$START_ABS" = "Y" ]; then
        docker compose up -d && log_success "Audiobookshelf started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:13378"
    echo ""
}
