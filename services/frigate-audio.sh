#!/bin/bash
# services/frigate-audio.sh — Frigate NVR + Mosquitto MQTT + frigate-notify
#   full-stack with audio support and push notifications via ntfy.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash frigate-audio.sh
# (Docker must already be installed when run standalone)
#
# Based on outis1one/frigate_w_audio. This is the full stack:
#   Frigate 0.17   NVR, face recognition, LPR, motion detection
#   Mosquitto      MQTT broker (events bus between Frigate and notify)
#   frigate-notify Event consumer — sends ntfy push notifications
#
# Audio is OFF by default in the Frigate config (audio.enabled: false).
# To enable it you need at least one camera with a working microphone —
# see the HOW TO ADD A CAMERA WITH A MIC section in the generated config.yml.
#
# Hardware acceleration and Coral TPU are opt-in during setup; the
# default falls back to CPU detection so the stack runs everywhere.
#
# Differs from services/frigate.sh (simpler, standalone Frigate only):
#   • includes Mosquitto + frigate-notify
#   • audio-ready camera config template
#   • Frigate 0.17 schema with face recognition + LPR pre-configured

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() {
            command -v docker &>/dev/null || {
                log_error "Docker not found. Install it first:"
                log_error "  curl -fsSL https://get.docker.com | sudo sh"
                return 1
            }
            docker compose version &>/dev/null || {
                log_error "Docker Compose plugin missing:"
                log_error "  sudo apt-get install -y docker-compose-plugin"
                return 1
            }
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$_len"
        }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            # Determine mode: local Caddy, remote Caddy, or none
            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            # Domain prompt — pre-fill from SITE_DOMAIN when available
            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Build upstream — remote Caddy uses host IP:port, not container name
            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK
)"

            if [[ "$_mode" == "local" ]]; then
                if [[ -f "$_caddyfile" ]]; then
                    local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                    cp "$_caddyfile" "$_bk"
                    log_info "Backed up Caddyfile to $(basename "$_bk")"
                else
                    touch "$_caddyfile"
                fi

                if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                    log_warning "$_domain already in Caddyfile"
                    local _ow=""
                    read -r -p "  Overwrite? [y/N]: " _ow
                    [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                    sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
                fi

                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
        }
        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service frigate-audio cameras "Frigate NVR + MQTT + push notifications (audio-ready stack)" 8971

install_frigate-audio() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/frigate-audio"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] frigate-audio would:"
        echo "  Create $DIR with Frigate + Mosquitto + frigate-notify stack"
        echo "  Prompt for camera RTSP credentials, IPs, MQTT password, ntfy server"
        echo "  Generate docker-compose.yml, frigate config, mosquitto config, .env"
        echo "  Bootstrap the Mosquitto password file"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║   Frigate + Mosquitto + frigate-notify (audio-ready stack)   ║"
    echo "║   Face recognition · LPR · ntfy push alerts                  ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""

    # ── Media storage path ─────────────────────────────────────────────────────
    log_info "Frigate media storage (recordings, snapshots)"
    echo "  Recordings can fill tens of GB quickly — a dedicated drive is recommended."
    echo ""
    local FRIGATE_MEDIA_DIR=""
    local DEFAULT_MEDIA="$DOCKER_DIR/frigate-audio/media"
    if declare -f select_storage_path &>/dev/null; then
        select_storage_path "Frigate recordings" FRIGATE_MEDIA_DIR
        [ -z "$FRIGATE_MEDIA_DIR" ] && FRIGATE_MEDIA_DIR="$DEFAULT_MEDIA"
    else
        prompt_text "Frigate media path [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" FRIGATE_MEDIA_DIR
    fi
    log_info "Media path: $FRIGATE_MEDIA_DIR"

    # ── Camera credentials ─────────────────────────────────────────────────────
    echo ""
    log_info "Camera 1 — Front Door (required)"
    local CAM1_USER="" CAM1_PASS="" CAM1_IP=""
    prompt_text "  RTSP username [admin]:" "admin" CAM1_USER
    prompt_text "  RTSP password:" "" CAM1_PASS
    prompt_text "  Camera IP [192.168.1.100]:" "192.168.1.100" CAM1_IP

    echo ""
    log_info "Camera 2 — Back Door (optional, press Enter to skip IP)"
    local CAM2_USER="" CAM2_PASS="" CAM2_IP=""
    prompt_text "  RTSP username [admin]:" "admin" CAM2_USER
    prompt_text "  RTSP password [changeme]:" "changeme" CAM2_PASS
    prompt_text "  Camera IP (Enter to disable):" "" CAM2_IP

    echo ""
    log_info "Camera 3 — Third camera (optional)"
    local CAM3_USER="" CAM3_PASS="" CAM3_IP=""
    prompt_text "  RTSP username [admin]:" "admin" CAM3_USER
    prompt_text "  RTSP password [changeme]:" "changeme" CAM3_PASS
    prompt_text "  Camera IP (Enter to disable):" "" CAM3_IP

    # ── MQTT password ──────────────────────────────────────────────────────────
    echo ""
    log_info "MQTT credentials (Frigate ↔ Mosquitto ↔ frigate-notify)"
    local MQTT_PASS=""
    prompt_text "  MQTT username [frigate]:" "frigate" MQTT_USER
    if [ -z "${MQTT_USER:-}" ]; then MQTT_USER="frigate"; fi
    MQTT_PASS=$(generate_password 24)
    log_info "  Generated MQTT password: $MQTT_PASS"

    # ── ntfy server ─────────────────────────────────────────────────────────
    echo ""
    log_info "ntfy push notifications"
    echo "  frigate-notify sends alerts via ntfy. Set to your ntfy server URL."
    local NTFY_SERVER="" NTFY_TOPIC="frigate"
    prompt_text "  ntfy server URL [https://ntfy.yourdomain.com]:" "https://ntfy.yourdomain.com" NTFY_SERVER
    prompt_text "  ntfy topic [frigate]:" "frigate" NTFY_TOPIC

    # ── Frigate public URL ─────────────────────────────────────────────────────
    echo ""
    local BASE_DOMAIN="${SITE_DOMAIN:-}"
    local FRIGATE_PUBLIC_URL=""
    if [ -n "$BASE_DOMAIN" ]; then
        local _PFX=""
        prompt_text "  Subdomain prefix for Frigate [cam].${BASE_DOMAIN}:" "cam" _PFX
        FRIGATE_PUBLIC_URL="https://${_PFX:-cam}.${BASE_DOMAIN}"
    else
        prompt_text "  Frigate public URL [https://cam.yourdomain.com]:" "https://cam.yourdomain.com" FRIGATE_PUBLIC_URL
    fi

    # ── Detector choice ────────────────────────────────────────────────────────
    echo ""
    log_info "Object detector"
    echo "  1) CPU (works everywhere, higher CPU usage)"
    echo "  2) USB Coral TPU (faster detection, lower CPU — requires USB Coral stick)"
    echo "  3) PCIe Coral TPU"
    local DET_CHOICE=""
    prompt_text "Detector [1]:" "1" DET_CHOICE
    local DETECTOR_BLOCK HWA_COMMENT
    case "${DET_CHOICE:-1}" in
        2) DETECTOR_BLOCK="detectors:\n  coral:\n    type: edgetpu\n    device: usb"
           HWA_COMMENT="  devices:\n      - /dev/bus/usb:/dev/bus/usb  # USB Coral" ;;
        3) DETECTOR_BLOCK="detectors:\n  coral:\n    type: edgetpu\n    device: pci"
           HWA_COMMENT="  devices:\n      - /dev/apex_0:/dev/apex_0  # PCIe Coral" ;;
        *) DETECTOR_BLOCK="detectors:\n  cpu:\n    type: cpu\n    num_threads: 3"
           HWA_COMMENT="" ;;
    esac

    # ── Hardware acceleration for re-encoding ──────────────────────────────────
    echo ""
    local HWA=""
    prompt_yn "  Enable hardware video decode (Intel/AMD /dev/dri/renderD128)? (y/n) [n]:" "n" HWA
    local DRI_LINE=""
    [[ ${HWA:-n} =~ ^[Yy]$ ]] && DRI_LINE="      - /dev/dri/renderD128  # Intel/AMD hwaccel"

    # ── Create directory structure ─────────────────────────────────────────────
    mkdir -p "$DIR"/{frigate_config,mosquitto/config,mosquitto/data,mosquitto/log,"frigate-notify"}
    mkdir -p "$FRIGATE_MEDIA_DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # ── .env ──────────────────────────────────────────────────────────────────
    log_info "Writing .env..."
    cat > "$DIR/.env" << ENVEOF
# Frigate audio stack — generated by setup.sh
# DO NOT commit this file — it contains credentials.

# ---- Camera 1: Front Door ----
FRIGATE_RTSP_USER=${CAM1_USER:-admin}
FRIGATE_RTSP_PASSWORD=${CAM1_PASS:-changeme}
FRIGATE_FRONT_DOOR_IP=${CAM1_IP:-192.168.1.100}

# ---- Camera 2: Back Door ----
FRIGATE_RTSP_USER1=${CAM2_USER:-admin}
FRIGATE_RTSP_PASSWORD1=${CAM2_PASS:-changeme}
FRIGATE_BACK_DOOR_IP=${CAM2_IP:-192.168.1.101}

# ---- Camera 3 (optional) ----
FRIGATE_RTSP_USER2=${CAM3_USER:-admin}
FRIGATE_RTSP_PASSWORD2=${CAM3_PASS:-changeme}
FRIGATE_SQUIRREL_IP=${CAM3_IP:-192.168.1.102}

# ---- MQTT ----
FRIGATE_MQTT_USER=${MQTT_USER:-frigate}
FRIGATE_MQTT_PASSWORD=${MQTT_PASS}

# ---- frigate-notify ----
FN_FRIGATE__MQTT__PASSWORD=${MQTT_PASS}
FN_FRIGATE__SERVER=http://frigate:5000
FN_FRIGATE__PUBLIC_URL=${FRIGATE_PUBLIC_URL}
FN_ALERTS__NTFY__SERVER=${NTFY_SERVER}
CADDY_NET=$SITE_CADDY_NET
ENVEOF
    chmod 600 "$DIR/.env"
    log_success ".env written"

    # ── docker-compose.yml ─────────────────────────────────────────────────────
    log_info "Writing docker-compose.yml..."

    local DEVICES_BLOCK=""
    [ -n "$HWA_COMMENT" ] && DEVICES_BLOCK="    devices:\n${HWA_COMMENT}"
    [ -n "$DRI_LINE" ] && DEVICES_BLOCK="${DEVICES_BLOCK}\n      ${DRI_LINE}"
    if [ -n "$DET_CHOICE" ] && [ "$DET_CHOICE" = "2" ]; then
        DEVICES_BLOCK="    devices:\n${HWA_COMMENT}"
        [ -n "$DRI_LINE" ] && DEVICES_BLOCK="${DEVICES_BLOCK}\n      ${DRI_LINE}"
    fi

    cat > "$DIR/docker-compose.yml" << 'COMPOSEEOF'
# Frigate NVR + Mosquitto MQTT + frigate-notify
# Generated by ubuntu-post-install setup.sh
name: frigate-audio

services:

  frigate:
    container_name: frigate-audio
    image: ghcr.io/blakeblackshear/frigate:0.17.1
    restart: unless-stopped
    stop_grace_period: 30s
    privileged: true
    shm_size: "512mb"
    env_file: .env
    depends_on:
      - mosquitto
COMPOSEEOF

    # Inject devices block if hardware acceleration chosen
    if [ -n "$HWA_COMMENT" ] || [ -n "$DRI_LINE" ]; then
        echo "    devices:" >> "$DIR/docker-compose.yml"
        [ -n "$HWA_COMMENT" ] && printf "      %s\n" "$HWA_COMMENT" | sed 's|^  *||' >> "$DIR/docker-compose.yml"
        [ -n "$DRI_LINE" ] && echo "      $DRI_LINE" >> "$DIR/docker-compose.yml"
    fi

    cat >> "$DIR/docker-compose.yml" << COMPOSEEOF
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - ./frigate_config:/config
      - ${FRIGATE_MEDIA_DIR}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "8971:8971"
      - "5001:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
    networks:
      - caddy_net
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:5000/api/version"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 60s

  mosquitto:
    container_name: frigate-audio-mqtt
    hostname: mosquitto
    image: eclipse-mosquitto:2
    restart: unless-stopped
    ports:
      - "1883:1883"
    volumes:
      - ./mosquitto/config:/mosquitto/config
      - ./mosquitto/data:/mosquitto/data
      - ./mosquitto/log:/mosquitto/log

  frigate-notify:
    container_name: frigate-audio-notify
    hostname: frigate-notify
    image: ghcr.io/0x2142/frigate-notify:latest
    restart: unless-stopped
    env_file: .env
    depends_on:
      mosquitto:
        condition: service_started
      frigate:
        condition: service_healthy
    volumes:
      - ./frigate-notify/config.yml:/app/config.yml:ro

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
COMPOSEEOF
    log_success "docker-compose.yml written"

    # ── Mosquitto config ───────────────────────────────────────────────────────
    log_info "Writing Mosquitto config..."
    cat > "$DIR/mosquitto/config/mosquitto.conf" << 'MQTTEOF'
listener 1883 0.0.0.0
protocol mqtt

persistence true
persistence_location /mosquitto/data/

log_dest stdout
log_dest file /mosquitto/log/mosquitto.log

allow_anonymous false
password_file /mosquitto/config/passwd
MQTTEOF

    # Bootstrap the Mosquitto password file
    log_info "Bootstrapping Mosquitto password file..."
    if docker run --rm -i eclipse-mosquitto:2 \
           mosquitto_passwd -b -c /dev/stdout "$MQTT_USER" "$MQTT_PASS" \
           > "$DIR/mosquitto/config/passwd" 2>/dev/null; then
        log_success "Mosquitto passwd file created"
    else
        log_warning "Could not bootstrap Mosquitto passwd — do it manually:"
        log_warning "  docker run --rm eclipse-mosquitto:2 mosquitto_passwd -b -c /passwd ${MQTT_USER} '${MQTT_PASS}'"
        log_warning "  Then copy the output to ${DIR}/mosquitto/config/passwd"
    fi

    # ── Frigate config.yml ─────────────────────────────────────────────────────
    log_info "Writing Frigate config..."
    local CAM2_ENABLED="false"; [ -n "$CAM2_IP" ] && CAM2_ENABLED="true"
    local CAM3_ENABLED="false"; [ -n "$CAM3_IP" ] && CAM3_ENABLED="true"

    local DETECTOR_YAML
    case "${DET_CHOICE:-1}" in
        2) DETECTOR_YAML="detectors:\n  coral:\n    type: edgetpu\n    device: usb" ;;
        3) DETECTOR_YAML="detectors:\n  coral:\n    type: edgetpu\n    device: pci" ;;
        *) DETECTOR_YAML="detectors:\n  cpu:\n    type: cpu\n    num_threads: 3" ;;
    esac

    cat > "$DIR/frigate_config/config.yml" << FRIGCFGEOF
version: 0.17-0

mqtt:
  enabled: true
  host: mosquitto
  port: 1883
  user: "{FRIGATE_MQTT_USER}"
  password: "{FRIGATE_MQTT_PASSWORD}"
  topic_prefix: frigate
  client_id: frigate
  stats_interval: 60

tls:
  enabled: false

# Audio detection — set true when you have a camera with a working mic.
# See the HOW TO ADD A CAMERA WITH A MIC section at the bottom of this file.
audio:
  enabled: false

$(printf "$DETECTOR_YAML")

birdseye:
  mode: continuous

semantic_search:
  enabled: false
  model_size: small

face_recognition:
  enabled: true
  model_size: small

lpr:
  enabled: true
  model_size: small

objects:
  track:
    - person

record:
  enabled: true
  continuous:
    days: 0
  motion:
    days: 10

go2rtc:
  streams:
    front_door:
      - rtsp://{FRIGATE_RTSP_USER}:{FRIGATE_RTSP_PASSWORD}@{FRIGATE_FRONT_DOOR_IP}:554/Streaming/Channels/101
    back_door:
      - rtsp://{FRIGATE_RTSP_USER1}:{FRIGATE_RTSP_PASSWORD1}@{FRIGATE_BACK_DOOR_IP}:554/Streaming/Channels/101
    squirrel:
      - rtsp://{FRIGATE_RTSP_USER2}:{FRIGATE_RTSP_PASSWORD2}@{FRIGATE_SQUIRREL_IP}:554/Streaming/Channels/101

cameras:
  front_door:
    enabled: true
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/front_door
          input_args: preset-rtsp-restream
          roles:
            - detect
            - record
    detect:
      enabled: true
      width: 2688
      height: 1520
      fps: 5

  back_door:
    enabled: ${CAM2_ENABLED}
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/back_door
          input_args: preset-rtsp-restream
          roles:
            - detect
            - record
    detect:
      enabled: true
      width: 2688
      height: 1520
      fps: 5

  squirrel:
    enabled: ${CAM3_ENABLED}
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/squirrel
          input_args: preset-rtsp-restream
          roles:
            - detect
            - record
    detect:
      enabled: true
      width: 2688
      height: 1520
      fps: 5

##############################################################################
# HOW TO ADD A CAMERA WITH A MIC
#
# 1. Set audio.enabled: true at the top of this file.
#
# 2. In go2rtc.streams, add the audio transcode line:
#      your_cam:
#        - rtsp://{FRIGATE_RTSP_USER3}:{FRIGATE_RTSP_PASSWORD3}@{IP}:554/path#backchannel=0
#        - "ffmpeg:your_cam#audio=aac#audio=opus"
#
# 3. In cameras, add the 'audio' role and audio-aware record preset:
#      your_cam:
#        enabled: true
#        ffmpeg:
#          output_args:
#            record: preset-record-generic-audio-aac
#          inputs:
#            - path: rtsp://127.0.0.1:8554/your_cam
#              input_args: preset-rtsp-restream
#              roles:
#                - detect
#                - record
#                - audio
#
# 4. Add credentials to .env:
#      FRIGATE_RTSP_USER3=admin
#      FRIGATE_RTSP_PASSWORD3=yourpass
#
# 5. RTSP paths by vendor:
#      Hikvision / Hikvision OEM: /Streaming/Channels/101 (main), /102 (sub)
#      Dahua / Dahua OEM: /cam/realmonitor?channel=1&subtype=0 (main)
##############################################################################
FRIGCFGEOF
    log_success "Frigate config.yml written"

    # ── frigate-notify config.yml ─────────────────────────────────────────────
    log_info "Writing frigate-notify config..."
    cat > "$DIR/frigate-notify/config.yml" << FNEOF
## frigate-notify config
## Docs: https://frigate-notify.0x2142.com
## Secrets come from .env via FN_* environment variables.

frigate:
  server:           # FN_FRIGATE__SERVER
  ignoressl: true
  public_url:       # FN_FRIGATE__PUBLIC_URL

  startup_check:
    attempts: 5
    interval: 30

  mqtt:
    enabled: true
    server: mosquitto
    port: 1883
    clientid: frigate-notify
    username: ${MQTT_USER:-frigate}
    password:       # FN_FRIGATE__MQTT__PASSWORD
    topic_prefix: frigate

alerts:
  general:
    title: 'Frigate - {{ if .SubLabel }}{{ .SubLabel }}{{ else }}{{ .Label }}{{ end }} at {{ .Camera }}'
    nosnap: allow
    recheck_delay: 10

  ntfy:
    enabled: true
    server:         # FN_ALERTS__NTFY__SERVER
    topic: "${NTFY_TOPIC:-frigate}"
    ignoressl: false
    headers:
      - X-Priority: '{{ if .SubLabel }}3{{ else }}4{{ end }}'
      - X-Tags: '{{ if .SubLabel }}wave{{ else }}rotating_light{{ end }}'
    template: |
      {{ if .SubLabel -}}{{ .SubLabel }}{{ else }}{{ .Label }}{{ end }} at {{ .Camera }}
      {{- if gt (len .CurrentZones) 0 }}
      Zone: {{ range \$i, \$z := .CurrentZones }}{{ if \$i }}, {{ end }}{{ \$z }}{{ end }}{{ end }}
      Score: {{ printf "%.0f" (mul .TopScore 100) }}%
      Time: {{ .StartTime.Format "Mon 3:04 PM" }}

monitor:
  enabled: false

  discord:
    enabled: false
  gotify:
    enabled: false
  smtp:
    enabled: false
  telegram:
    enabled: false
  pushover:
    enabled: false
  webhook:
    enabled: false
FNEOF
    log_success "frigate-notify config.yml written"

    # ── Caddy snippet ──────────────────────────────────────────────────────────
    if [ -n "$FRIGATE_PUBLIC_URL" ] && [ "$FRIGATE_PUBLIC_URL" != "https://cam.yourdomain.com" ]; then
        local _DOM="${FRIGATE_PUBLIC_URL#https://}"
        configure_caddy_for_service "Frigate" "frigate-audio:8971" "frigate-audio" || true
    fi

    ensure_docker_dir_ownership "$DIR"

    # ── Summary ────────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Frigate Audio Stack — Setup Complete"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Directory:   $DIR"
    echo "  Media:       $FRIGATE_MEDIA_DIR"
    echo "  Public URL:  $FRIGATE_PUBLIC_URL"
    echo "  MQTT user:   ${MQTT_USER:-frigate}"
    echo "  ntfy server: $NTFY_SERVER  topic: ${NTFY_TOPIC:-frigate}"
    echo ""
    echo "  Before starting:"
    echo "   1. Edit frigate_config/config.yml — adjust RTSP paths for your cameras"
    echo "      (paths vary by vendor; check your camera's manual)"
    echo "   2. Edit frigate_config/config.yml — remove/adjust motion masks"
    echo "      (the masks are blanks — add yours via the Frigate UI after first run)"
    echo "   3. Verify .env credentials are correct"
    echo ""
    echo "  Start:"
    echo "    cd $DIR && docker compose up -d"
    echo ""
    echo "  Face recognition training (after Frigate is running):"
    echo "    — Go to Frigate UI → Faces → add face photos for household members"
    echo "    → In frigate-notify/config.yml, add names to alerts.sublabels.block"
    echo "      to silence push notifications for recognized family members."
    echo ""

    local START_NOW=""
    prompt_yn "Start the stack now? (y/n) [n]:" "n" START_NOW
    if [[ ${START_NOW:-n} =~ ^[Yy]$ ]]; then
        log_info "Starting frigate-audio stack..."
        if ( cd "$DIR" && docker compose up -d ); then
            log_success "Stack started — Frigate UI: http://localhost:8971"
        else
            log_warning "Start failed — check: cd $DIR && docker compose logs"
        fi
    else
        echo ""
        log_info "When ready: cd $DIR && docker compose up -d"
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_frigate-audio
