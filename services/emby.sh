#!/bin/bash
# services/emby.sh — Media server for movies, TV, and music (Emby).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- EMBY ----).
# Own ~/docker/emby/ with a standalone docker-compose.yml + .env. Hardware
# transcoding is left commented in the compose (uncomment the /dev/dri block
# once you've confirmed your GPU) to match the original behavior.

register_service emby media "Media server — movies, TV, music (Emby)" 8096

install_emby() {
    require_docker || return 1

    local EMBY_DIR="$DOCKER_DIR/emby"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Emby would:"
        echo "  - Create $EMBY_DIR with docker-compose.yml + .env (config/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) at /media"
        echo "  - Run as UID/GID $(id -u "$ACTUAL_USER")/$(id -g "$ACTUAL_USER")"
        echo "  - Expose ports 8096 (web) and 8920 (https)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MEDIA_PATH=""
    prompt_text "Path to media folder [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH/#\~/$ACTUAL_HOME}"; MEDIA_PATH="${MEDIA_PATH%/}"

    mkdir -p "$EMBY_DIR"
    ensure_docker_dir_ownership "$EMBY_DIR"
    cd "$EMBY_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << EMBY_COMPOSE
name: emby

services:
  emby:
    image: emby/embyserver:latest
    container_name: emby
    hostname: emby
    restart: unless-stopped
    environment:
      - UID=$UID_VAL
      - GID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config
      - \${MEDIA_PATH}:/media
    ports:
      - "8096:8096"
      - "8920:8920"
    # Uncomment for hardware transcoding (Intel/AMD):
    # devices:
    #   - /dev/dri:/dev/dri
EMBY_COMPOSE

    cat > .env << EMBY_ENV
MEDIA_PATH=$MEDIA_PATH
EMBY_ENV

    mkdir -p config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$EMBY_DIR"
    log_success "Emby configured at $EMBY_DIR"

    configure_caddy_for_service "Emby" "8096" "emby"

    write_readme "$EMBY_DIR" << MD
# Emby

Media server for movies, TV, and music.

- Web UI: http://localhost:8096  (HTTPS on 8920)
- Media folder: \`$MEDIA_PATH\` → mounted at /media
- App data: \`config/\` in this folder
- Edit the media path in \`.env\` (\`MEDIA_PATH=\`), then \`docker compose up -d\`.

## Manage
\`\`\`bash
cd $EMBY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Hardware transcoding
Uncomment the \`devices: [/dev/dri:/dev/dri]\` block in \`docker-compose.yml\`
once you've confirmed your Intel/AMD GPU exposes a render node, then restart.
MD

    local START_EMBY=""
    prompt_yn "Start Emby now? (y/n):" "y" START_EMBY
    if [ "$START_EMBY" = "y" ] || [ "$START_EMBY" = "Y" ]; then
        docker compose up -d && log_success "Emby started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8096"
    echo ""
}
