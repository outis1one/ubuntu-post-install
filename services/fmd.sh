#!/bin/bash
# services/fmd.sh — FindMyDevice server for Android device tracking (FMD).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FINDMYDEVICE ----).
# Own ~/docker/fmd/ with a standalone docker-compose.yml + .env.
# Mobile app: "FindMyDevice" on F-Droid — not the Play Store version.

register_service fmd utilities "Android device tracking — alternative to Google Find My Device (FMD)" 8084

install_fmd() {
    require_docker || return 1

    local FMD_DIR="$DOCKER_DIR/fmd"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] FindMyDevice would:"
        echo "  - Create $FMD_DIR with docker-compose.yml + .env (data/)"
        echo "  - Generate a random admin password"
        echo "  - Expose port 8084"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$FMD_DIR"
    ensure_docker_dir_ownership "$FMD_DIR"
    cd "$FMD_DIR" || return 1

    local FMD_PASS
    FMD_PASS=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    cat > docker-compose.yml << 'FMD_COMPOSE'
name: fmd

services:
  fmd:
    image: nulide/findmydevice
    container_name: fmd
    hostname: fmd
    restart: unless-stopped
    environment:
      - FMD_ADMIN_PASSWORD=${FMD_ADMIN_PASSWORD}
    volumes:
      - ./data:/fmd/data
    ports:
      - "8084:8080"
FMD_COMPOSE

    cat > .env << FMD_ENV
FMD_ADMIN_PASSWORD=$FMD_PASS
FMD_ENV

    mkdir -p data
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FMD_DIR"
    log_success "FindMyDevice configured at $FMD_DIR"

    configure_caddy_for_service "FindMyDevice" "8084" "fmd"

    write_readme "$FMD_DIR" << MD
# FindMyDevice (FMD)

Self-hosted Android device tracking — locate, lock, or wipe your device
from the web UI. Alternative to Google's Find My Device.

- Web UI: http://localhost:8084
- Admin password: stored in \`.env\` (\`FMD_ADMIN_PASSWORD\`)
- App data: \`data/\`

## Manage
\`\`\`bash
cd $FMD_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Mobile app
Install **FindMyDevice** from **F-Droid** (not the Play Store version):
1. Open the app → Settings → Server URL → \`http://YOUR-SERVER-IP:8084\`
2. Enter your admin password from \`.env\`
3. Grant location and accessibility permissions
MD

    local START_FMD=""
    prompt_yn "Start FindMyDevice now? (y/n):" "y" START_FMD
    if [ "$START_FMD" = "y" ] || [ "$START_FMD" = "Y" ]; then
        docker compose up -d && log_success "FindMyDevice started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8084"
    echo "  Password:   $FMD_PASS  (saved in .env)"
    echo "  Mobile app: FindMyDevice on F-Droid"
    echo ""
}
