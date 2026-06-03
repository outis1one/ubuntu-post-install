#!/bin/bash
# services/jellyfin.sh — Free media server for movies, TV, and music (Jellyfin).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- JELLYFIN ----).
# Lives in its own ~/docker/jellyfin/ with a standalone docker-compose.yml + .env.
# Hardware transcoding (Intel/AMD VAAPI) is auto-enabled when a render node
# (/dev/dri/renderD128) is present on the host.

register_service jellyfin media "Free media server — movies, TV, music (Jellyfin)" 8096

install_jellyfin() {
    require_docker || return 1

    local JELLYFIN_DIR="$DOCKER_DIR/jellyfin"
    local DEFAULT_MEDIA="$ACTUAL_HOME/media"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Jellyfin would:"
        echo "  - Create $JELLYFIN_DIR with docker-compose.yml + .env (config/ cache/)"
        echo "  - Mount a media folder (default $DEFAULT_MEDIA) read-only at /media"
        echo "  - Auto-enable VAAPI hw transcoding if /dev/dri/renderD128 exists"
        echo "  - Expose port 8096 (+ DLNA 1900/udp, discovery 7359/udp)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local MEDIA_PATH=""
    prompt_text "Path to media folder [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" MEDIA_PATH
    MEDIA_PATH="${MEDIA_PATH/#\~/$ACTUAL_HOME}"; MEDIA_PATH="${MEDIA_PATH%/}"

    mkdir -p "$JELLYFIN_DIR"
    ensure_docker_dir_ownership "$JELLYFIN_DIR"
    cd "$JELLYFIN_DIR" || return 1

    local TZ_VAL; TZ_VAL=$(cat /etc/timezone 2>/dev/null || echo "UTC")

    # Hardware acceleration: only wire /dev/dri through if a render node exists,
    # otherwise the container would fail to start on a GPU-less host.
    local HWACCEL_BLOCK="" RENDER_GID
    if [ -e /dev/dri/renderD128 ]; then
        RENDER_GID=$(getent group render | cut -d: -f3 2>/dev/null || echo "989")
        HWACCEL_BLOCK="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
    group_add:
      - \"$RENDER_GID\""
        log_success "Render node found — enabling VAAPI hardware transcoding (render gid $RENDER_GID)"
    else
        log_warning "No /dev/dri/renderD128 — Jellyfin will use CPU transcoding."
    fi

    cat > docker-compose.yml << JELLYFIN_COMPOSE
name: jellyfin

services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    hostname: jellyfin
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
$HWACCEL_BLOCK
    volumes:
      - ./config:/config
      - ./cache:/cache
      - \${MEDIA_PATH}:/media:ro
    ports:
      - "8096:8096"
      - "1900:1900/udp"
      - "7359:7359/udp"
JELLYFIN_COMPOSE

    cat > .env << JELLYFIN_ENV
MEDIA_PATH=$MEDIA_PATH
JELLYFIN_ENV

    mkdir -p config cache
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JELLYFIN_DIR"
    log_success "Jellyfin configured at $JELLYFIN_DIR"

    configure_caddy_for_service "Jellyfin" "8096" "jellyfin"

    write_readme "$JELLYFIN_DIR" << MD
# Jellyfin

Free media server (movies, TV, music) — a no-paywall alternative to Emby.

- Web UI: http://localhost:8096
- Media folder (read-only): \`$MEDIA_PATH\` → mounted at /media
- App data: \`config/\` and \`cache/\` in this folder
- Edit the media path in \`.env\` (\`MEDIA_PATH=\`), then \`docker compose up -d\`.

## Manage
\`\`\`bash
cd $JELLYFIN_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- Hardware transcoding (Intel/AMD VAAPI) is enabled automatically when
  \`/dev/dri/renderD128\` exists on the host; otherwise transcoding is CPU-only.
- First launch: open the web UI and complete the setup wizard, then add your
  media libraries pointing at /media.
MD

    local START_JF=""
    prompt_yn "Start Jellyfin now? (y/n):" "y" START_JF
    if [ "$START_JF" = "y" ] || [ "$START_JF" = "Y" ]; then
        docker compose up -d && log_success "Jellyfin started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8096"
    echo ""
}
