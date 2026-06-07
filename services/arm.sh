#!/bin/bash
# services/arm.sh — Automatic Ripping Machine: rip DVDs, Blu-rays, CDs.
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- A.R.M. ----).
# Own ~/docker/arm/ with a standalone docker-compose.yml + .env. Detects
# optical drives at install time; add more /dev/srN entries manually after.

register_service arm media "Automatic Ripping Machine — rip DVDs, Blu-rays, CDs" 8080

install_arm() {
    require_docker || return 1

    local ARM_DIR="$DOCKER_DIR/arm"
    local DEFAULT_OUTPUT="$ACTUAL_HOME/ripped"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] A.R.M. would:"
        echo "  - Create $ARM_DIR with docker-compose.yml + .env (config/ logs/)"
        echo "  - Detect optical drives (/dev/sr*) — defaults to /dev/sr0"
        echo "  - Create ripped output dirs (movies/ music/) under $DEFAULT_OUTPUT"
        echo "  - Run as UID/GID $(id -u "$ACTUAL_USER")/$(id -g "$ACTUAL_USER") with privileged: true"
        echo "  - Expose port 8080"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local ARM_OUTPUT=""
    prompt_text "Path for ripped media output [$DEFAULT_OUTPUT]:" "$DEFAULT_OUTPUT" ARM_OUTPUT
    ARM_OUTPUT="${ARM_OUTPUT/#\~/$ACTUAL_HOME}"; ARM_OUTPUT="${ARM_OUTPUT%/}"

    echo ""
    echo "Detecting optical drives..."
    local OPTICAL_DRIVES
    OPTICAL_DRIVES=$(ls /dev/sr* 2>/dev/null || true)
    if [ -n "$OPTICAL_DRIVES" ]; then
        echo "  Found: $OPTICAL_DRIVES"
    else
        echo "  No optical drives detected. Defaulting to /dev/sr0 — add more later."
        OPTICAL_DRIVES="/dev/sr0"
    fi

    mkdir -p "$ARM_DIR"
    ensure_docker_dir_ownership "$ARM_DIR"
    cd "$ARM_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << ARM_COMPOSE
name: arm

services:
  automatic-ripping-machine:
    image: automaticrippingmachine/automatic-ripping-machine:latest
    container_name: arm
    hostname: arm
    restart: unless-stopped
    environment:
      - ARM_UID=$UID_VAL
      - ARM_GID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/etc/arm/config
      - ./logs:/home/arm/logs
      - \${ARM_OUTPUT}/movies:/home/arm/media/completed
      - \${ARM_OUTPUT}/music:/home/arm/music
    ports:
      - "8080:8080"
    devices:
      - /dev/sr0:/dev/sr0
      # Add more optical drives as needed:
      # - /dev/sr1:/dev/sr1
    privileged: true
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
ARM_COMPOSE

    cat > .env << ARM_ENV
ARM_OUTPUT=$ARM_OUTPUT
CADDY_NET=$SITE_CADDY_NET
ARM_ENV

    mkdir -p config logs
    mkdir -p "$ARM_OUTPUT/movies" "$ARM_OUTPUT/music"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ARM_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ARM_OUTPUT"
    log_success "A.R.M. configured at $ARM_DIR"

    configure_caddy_for_service "A.R.M." "arm:8080" "arm"

    write_readme "$ARM_DIR" << MD
# A.R.M. (Automatic Ripping Machine)

Auto-rips DVDs, Blu-rays, and CDs when you insert them — identifies the disc,
fetches metadata, and transcodes to a usable format.

- Web UI: http://localhost:8080 (complete setup on first visit)
- Ripped output: \`$ARM_OUTPUT\` → movies and music subdirs
- App data: \`config/\` and \`logs/\`

## Manage
\`\`\`bash
cd $ARM_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Adding optical drives
Edit \`docker-compose.yml\` and add more \`devices:\` entries:
\`\`\`yaml
    devices:
      - /dev/sr0:/dev/sr0
      - /dev/sr1:/dev/sr1
\`\`\`
Then \`docker compose up -d\` to apply.

## Notes
- First launch: open the web UI and complete the setup wizard.
- \`privileged: true\` is required for ARM to control the optical drive.
- Change the output path in \`.env\` (\`ARM_OUTPUT=\`), then \`docker compose up -d\`.
MD

    local START_ARM=""
    prompt_yn "Start A.R.M. now? (y/n):" "y" START_ARM
    if [ "$START_ARM" = "y" ] || [ "$START_ARM" = "Y" ]; then
        docker compose up -d && log_success "A.R.M. started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8080"
    echo "  Complete setup in browser on first visit."
    echo ""
}
