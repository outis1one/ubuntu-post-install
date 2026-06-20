#!/bin/bash
# services/frigate.sh — AI-powered NVR for security cameras (Frigate).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash frigate.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FRIGATE NVR ----).
# Own ~/docker/frigate/ with a standalone docker-compose.yml + .env + config.yml.
# Auto-enables /dev/dri/renderD128 for hardware detection (Intel/AMD) when present.
# YOU MUST edit config/config.yml to add your camera RTSP streams before starting.

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

    local _CADDY_NET_BLOCK=""
    if [ -d "$DOCKER_DIR/caddy" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
    fi

    local _CADDY_NET_SECTION=""
    if [ -d "$DOCKER_DIR/caddy" ]; then
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
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
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
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

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_frigate
