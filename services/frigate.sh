#!/bin/bash
# services/frigate.sh — AI-powered NVR for security cameras (Frigate).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FRIGATE NVR ----).
# Own ~/docker/frigate/ with a standalone docker-compose.yml + .env + config.yml.
# Auto-enables /dev/dri/renderD128 for hardware detection (Intel/AMD) when present.
# YOU MUST edit config/config.yml to add your camera RTSP streams before starting.

register_service frigate cameras "AI-powered NVR — object detection on security cameras (Frigate)" 5000

install_frigate() {
    require_docker || return 1

    local FRIGATE_DIR="$DOCKER_DIR/frigate"
    local DEFAULT_MEDIA="$ACTUAL_HOME/frigate"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Frigate would:"
        echo "  - Create $FRIGATE_DIR with docker-compose.yml + .env + config/config.yml"
        echo "  - Auto-enable /dev/dri/renderD128 for GPU-assisted detection if present"
        echo "  - Expose ports 5000 (web), 8554 (RTSP restream), 8555 (WebRTC)"
        echo "  - Write a starter config.yml — edit to add camera streams before starting"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local FRIGATE_MEDIA=""
    prompt_text "Path for recordings/snapshots [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" FRIGATE_MEDIA
    FRIGATE_MEDIA="${FRIGATE_MEDIA/#\~/$ACTUAL_HOME}"; FRIGATE_MEDIA="${FRIGATE_MEDIA%/}"

    mkdir -p "$FRIGATE_DIR"
    ensure_docker_dir_ownership "$FRIGATE_DIR"
    cd "$FRIGATE_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # Hardware detection: include /dev/dri only when a render node exists
    local DEVICE_BLOCK=""
    if [ -e /dev/dri/renderD128 ]; then
        DEVICE_BLOCK="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
        log_success "Render node found — enabling hardware-accelerated detection"
    else
        log_warning "No /dev/dri/renderD128 — Frigate will use CPU detection."
    fi

    cat > docker-compose.yml << FRIGATE_COMPOSE
name: frigate

services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    hostname: frigate
    restart: unless-stopped
    privileged: true
    shm_size: "256mb"
    environment:
      - TZ=$TZ_VAL
$DEVICE_BLOCK
    volumes:
      - ./config:/config
      - \${FRIGATE_MEDIA}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
FRIGATE_COMPOSE

    cat > .env << FRIGATE_ENV
FRIGATE_MEDIA=$FRIGATE_MEDIA
CADDY_NET=$SITE_CADDY_NET
FRIGATE_ENV

    mkdir -p config
    mkdir -p "$FRIGATE_MEDIA"

    cat > config/config.yml << 'FRIGATE_CONFIG'
# Frigate Configuration — Docs: https://docs.frigate.video
#
# ⚠️  YOU MUST EDIT THIS FILE to add your cameras before starting Frigate.

mqtt:
  enabled: false   # Set to true and configure if you use Home Assistant

cameras:
  # Example — replace with your camera details:
  # front_door:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://user:pass@192.168.1.100:554/stream
  #         roles: [detect, record]
  #   detect:
  #     width: 1280
  #     height: 720
  #     fps: 5

detectors:
  default:
    type: cpu   # Change to 'edgetpu' for Coral TPU or 'openvino' for Intel GPU

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 7
FRIGATE_CONFIG

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FRIGATE_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FRIGATE_MEDIA" 2>/dev/null || true
    log_success "Frigate configured at $FRIGATE_DIR"

    configure_caddy_for_service "Frigate" "frigate:5000" "frigate"

    write_readme "$FRIGATE_DIR" << MD
# Frigate NVR

AI-powered network video recorder with real-time object detection for
security cameras. Detects people, cars, animals, and more.

- Web UI: http://localhost:5000
- RTSP restream: port 8554
- WebRTC: port 8555
- Recordings: \`$FRIGATE_MEDIA\`
- Config: \`config/config.yml\` — **add your camera RTSP streams here**

## Manage
\`\`\`bash
cd $FRIGATE_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## First steps
1. Edit \`config/config.yml\` — add your camera RTSP URLs under \`cameras:\`
2. Start Frigate: \`docker compose up -d\`
3. Open http://localhost:5000 to view cameras and configure detection zones

## Hardware acceleration
- Intel/AMD GPU: uncomment the \`devices: [/dev/dri/renderD128]\` block
- Google Coral TPU: set \`detectors.default.type: edgetpu\` + add USB device
- Docs: https://docs.frigate.video/configuration/hardware_acceleration
MD

    echo ""
    log_warning "Edit config/config.yml to add your camera RTSP streams before starting."
    echo ""
    local START_FRIGATE=""
    prompt_yn "Start Frigate now anyway? (y/n):" "n" START_FRIGATE
    if [ "$START_FRIGATE" = "y" ] || [ "$START_FRIGATE" = "Y" ]; then
        docker compose up -d && log_success "Frigate started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:5000"
    echo "  Config:     $FRIGATE_DIR/config/config.yml  (add cameras here)"
    echo ""
}
