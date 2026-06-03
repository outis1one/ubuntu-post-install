#!/bin/bash
# services/frigate-notify.sh — Push notification sidecar for Frigate events.
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FRIGATE-NOTIFY ----).
# Own ~/docker/frigate-notify/ with a standalone docker-compose.yml + config.yml.
# Supports ntfy, Pushover, Discord, Gotify, Telegram, and more. No web UI.
# Auto-detects local Frigate and ntfy installs to pre-fill config defaults.

register_service frigate-notify cameras "Push alerts for Frigate detection events (Frigate-Notify)"

install_frigate-notify() {
    require_docker || return 1

    local FN_DIR="$DOCKER_DIR/frigate-notify"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Frigate-Notify would:"
        echo "  - Create $FN_DIR with docker-compose.yml + config.yml"
        echo "  - Auto-detect local Frigate and ntfy installs"
        echo "  - No web UI — configure via config.yml"
        return 0
    fi

    mkdir -p "$FN_DIR"
    ensure_docker_dir_ownership "$FN_DIR"
    cd "$FN_DIR" || return 1

    cat > docker-compose.yml << 'FN_COMPOSE'
name: frigate-notify

services:
  frigate-notify:
    image: ghcr.io/0x2142/frigate-notify:latest
    container_name: frigate-notify
    hostname: frigate-notify
    restart: unless-stopped
    volumes:
      - ./config.yml:/app/config.yml:ro
FN_COMPOSE

    # Smart defaults based on what's installed
    local FRIGATE_URL="http://frigate:5000"
    local NTFY_URL="https://ntfy.sh"
    local NTFY_TOPIC="frigate-alerts"

    if [ -d "$DOCKER_DIR/frigate" ]; then
        log_success "Local Frigate detected — using http://frigate:5000"
    else
        log_warning "Frigate not found locally — using default URL (update config.yml if needed)"
    fi

    if [ -d "$DOCKER_DIR/ntfy" ]; then
        NTFY_URL="http://ntfy:80"
        log_success "Local ntfy detected — using http://ntfy:80"
    else
        log_warning "Local ntfy not found — using ntfy.sh (update config.yml for self-hosted)"
    fi

    echo ""
    prompt_text "Frigate URL [$FRIGATE_URL]:" "$FRIGATE_URL" FRIGATE_URL
    prompt_text "ntfy server URL [$NTFY_URL]:" "$NTFY_URL" NTFY_URL
    prompt_text "ntfy topic [frigate-alerts]:" "frigate-alerts" NTFY_TOPIC

    cat > config.yml << FN_CONFIG
# Frigate-Notify Configuration
# Docs: https://frigate-notify.0x2142.com
#
# Edit this file if notifications don't arrive — check Frigate URL,
# ntfy server, and that containers share a Docker network.

frigate:
  server: $FRIGATE_URL
  webapi:
    enabled: true
    interval: 30

alerts:
  general:
    send_startup_message: true
  labels:
    - person
    - car
    # - dog
    # - package

notifiers:
  - name: ntfy
    enabled: true
    provider: ntfy
    config:
      server: $NTFY_URL
      topic: $NTFY_TOPIC
FN_CONFIG

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FN_DIR"
    log_success "Frigate-Notify configured at $FN_DIR"

    write_readme "$FN_DIR" << MD
# Frigate-Notify

Push notification sidecar for Frigate — sends alerts when Frigate detects
people, cars, animals, or custom objects. Supports ntfy, Pushover, Discord,
Gotify, Telegram, and more. No web UI.

- Config: \`config.yml\` — edit notification targets here
- Frigate events polled every 30 seconds by default
- Docs: https://frigate-notify.0x2142.com

## Manage
\`\`\`bash
cd $FN_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # check for delivery errors
docker compose pull && docker compose up -d   # update
\`\`\`

## Adding more notifiers
Edit \`config.yml\` and add entries under \`notifiers:\`. Supported providers:
ntfy, Pushover, Discord (webhook), Gotify, Telegram, SMTP, and more.
See: https://frigate-notify.0x2142.com/configuration/alerts/
MD

    local START_FN=""
    prompt_yn "Start Frigate-Notify now? (y/n):" "y" START_FN
    if [ "$START_FN" = "y" ] || [ "$START_FN" = "Y" ]; then
        docker compose up -d && log_success "Frigate-Notify started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Config:  $FN_DIR/config.yml"
    echo "  Docs:    https://frigate-notify.0x2142.com"
    echo ""
}
