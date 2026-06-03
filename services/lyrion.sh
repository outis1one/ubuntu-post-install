#!/bin/bash
# services/lyrion.sh — Lyrion Music Server for Squeezebox devices, apps, Chromecast.
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- LYRION MUSIC SERVER ----).
# Uses network_mode: host so UDP discovery (Chromecast, Squeezebox) works without
# manual port-forwarding. Own ~/docker/lyrion/ with compose + .env.

register_service lyrion media "Music streaming server — Squeezebox, Chromecast (Lyrion)" 9000

install_lyrion() {
    require_docker || return 1

    local LYRION_DIR="$DOCKER_DIR/lyrion"
    local DEFAULT_MUSIC="$ACTUAL_HOME/music"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Lyrion Music Server would:"
        echo "  - Create $LYRION_DIR with docker-compose.yml + .env (config/ playlists/)"
        echo "  - Mount a music folder (default $DEFAULT_MUSIC) read-only at /music"
        echo "  - Run with network_mode: host (required for Chromecast/Squeezebox UDP discovery)"
        echo "  - Expose port 9000 (web), 9090 (CLI), 3483 (players)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MUSIC_PATH=""
    prompt_text "Path to music folder [$DEFAULT_MUSIC]:" "$DEFAULT_MUSIC" MUSIC_PATH
    MUSIC_PATH="${MUSIC_PATH/#\~/$ACTUAL_HOME}"; MUSIC_PATH="${MUSIC_PATH%/}"

    mkdir -p "$LYRION_DIR"
    ensure_docker_dir_ownership "$LYRION_DIR"
    cd "$LYRION_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << LYRION_COMPOSE
name: lyrion

services:
  lyrion:
    image: lmscommunity/lyrionmusicserver:stable
    container_name: lyrion
    hostname: lyrion
    restart: unless-stopped
    network_mode: host
    environment:
      - HTTP_PORT=9000
      - PUID=$UID_VAL
      - PGID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/config:rw
      - \${MUSIC_PATH}:/music:ro
      - ./playlists:/playlists:rw
      - /etc/localtime:/etc/localtime:ro
LYRION_COMPOSE

    cat > .env << LYRION_ENV
MUSIC_PATH=$MUSIC_PATH
LYRION_ENV

    mkdir -p config playlists
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$LYRION_DIR"
    log_success "Lyrion Music Server configured at $LYRION_DIR"

    configure_caddy_for_service "Lyrion" "9000" "lyrion"

    write_readme "$LYRION_DIR" << MD
# Lyrion Music Server

Stream music to Squeezebox devices, the Squeezer Android/iOS app, and Chromecast.
Formerly known as Logitech Media Server (LMS).

- Web UI: http://localhost:9000
- Player port: 3483 (Squeezeboxes / apps)
- CLI port: 9090
- Music folder (read-only): \`$MUSIC_PATH\` → mounted at /music
- App data: \`config/\` and \`playlists/\`

## Manage
\`\`\`bash
cd $LYRION_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- Uses \`network_mode: host\` so UDP discovery for Chromecast and Squeezebox devices
  works without manual port mapping.
- Change the music path in \`.env\` (\`MUSIC_PATH=\`), then \`docker compose up -d\`.
- Add music libraries in the web UI under Settings → Music Library.
MD

    local START_LMS=""
    prompt_yn "Start Lyrion Music Server now? (y/n):" "y" START_LMS
    if [ "$START_LMS" = "y" ] || [ "$START_LMS" = "Y" ]; then
        docker compose up -d && log_success "Lyrion started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:9000"
    echo "  Note: uses host networking for Chromecast/Squeezebox UDP discovery"
    echo ""
}
