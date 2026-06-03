#!/bin/bash
# services/homeassistant.sh — Home Assistant home-automation hub.
# Part of the modular post-install system (sourced by setup.sh).

register_service homeassistant homelab "Home automation hub (Home Assistant)" 8123

install_homeassistant() {
    require_docker || return 1
    log_info "Installing Home Assistant..."
    local HOMEASSISTANT_DIR="$DOCKER_DIR/homeassistant"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $HOMEASSISTANT_DIR"
        return 0
    fi

    mkdir -p "$HOMEASSISTANT_DIR"
    ensure_docker_dir_ownership "$HOMEASSISTANT_DIR"
    cd "$HOMEASSISTANT_DIR" || return 1

    # Networking mode: bridge (published port) vs host networking.
    echo ""
    echo "  Home Assistant networking mode:"
    echo "    1) Bridge  - container gets its own network; port 8123 is published"
    echo "                 to the host. Works behind the Caddy reverse proxy and"
    echo "                 keeps HA isolated. Recommended for most setups."
    echo "    2) Host    - HA shares the host's network directly. Needed for"
    echo "                 auto-discovery of devices on your LAN (Chromecast/Cast,"
    echo "                 HomeKit, mDNS/Zeroconf, some Zigbee/Z-Wave & Bluetooth)."
    local HA_NETMODE=""
    prompt_text "  Choose networking mode [1]:" "1" HA_NETMODE
    local HA_NET_LINES
    if [ "$HA_NETMODE" = "2" ]; then
        HA_NET_LINES="    network_mode: host"
        echo "  → Host networking selected (best device discovery)."
    else
        HA_NET_LINES="    ports:
      - \"8123:8123\""
        echo "  → Bridge networking selected (port 8123 published)."
    fi

    cat > docker-compose.yml << HOMEASSISTANT_COMPOSE
name: homeassistant

services:
  homeassistant:
    image: ghcr.io/home-assistant/home-assistant:stable
    container_name: homeassistant
    hostname: homeassistant
    restart: unless-stopped
    privileged: true
    environment:
      - TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
    volumes:
      - ./config:/config
      - /run/dbus:/run/dbus:ro
${HA_NET_LINES}
HOMEASSISTANT_COMPOSE

    mkdir -p config

    # Pre-seed trusted_proxies so HA works behind the Caddy reverse proxy.
    # Only written on a fresh install (never clobber an existing config).
    if [ ! -f config/configuration.yaml ]; then
        cat > config/configuration.yaml << 'HA_CONFIG'
# Loads default set of integrations. Do not remove.
default_config:

# Allow access through a reverse proxy (e.g. Caddy)
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
    - 192.168.0.0/16
    - 10.0.0.0/8
    - 127.0.0.1
    - ::1
HA_CONFIG
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$HOMEASSISTANT_DIR"
    echo ""
    log_success "Home Assistant configured at $HOMEASSISTANT_DIR"

    configure_caddy_for_service "Home Assistant" "8123" "home"

    local START_HA=""
    prompt_yn "Start Home Assistant now? (y/n):" "y" START_HA
    if [ "$START_HA" = "y" ] || [ "$START_HA" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Home Assistant started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:8123"
    echo "  First run:  open the URL and create your admin account (onboarding)."
    echo "  Note:       first startup can take a minute while HA initializes."
    echo ""
}
