#!/bin/bash
# services/wg-easy.sh — WireGuard VPN with a web management UI (wg-easy).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- WG-EASY ----).
# Own ~/docker/wg-easy/ with a standalone docker-compose.yml + .env.
# Requires cap_add: NET_ADMIN + SYS_MODULE and ip_forward sysctl.
# Forward UDP 51820 on your router to this server for external VPN access.

register_service wg-easy utilities "WireGuard VPN with web management UI (wg-easy)" 51821

install_wg-easy() {
    require_docker || return 1

    local WGEASY_DIR="$DOCKER_DIR/wg-easy"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] wg-easy would:"
        echo "  - Create $WGEASY_DIR with docker-compose.yml + .env (config/)"
        echo "  - Auto-detect public IP for WG_HOST"
        echo "  - Generate a random web UI password"
        echo "  - Expose port 51821 (web UI) + 51820/udp (VPN)"
        echo "  - Require router port-forward: UDP 51820 → this server"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$WGEASY_DIR"
    ensure_docker_dir_ownership "$WGEASY_DIR"
    cd "$WGEASY_DIR" || return 1

    # Auto-detect public IP as default for WG_HOST
    local PUBLIC_IP WG_HOST WG_PASSWORD
    PUBLIC_IP=$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || echo "your-public-ip")
    WG_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)

    prompt_text "Public IP or hostname for VPN [$PUBLIC_IP]:" "$PUBLIC_IP" WG_HOST

    cat > docker-compose.yml << 'WGEASY_COMPOSE'
name: wg-easy

services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    hostname: wg-easy
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      - WG_HOST=${WG_HOST}
      - PASSWORD=${WG_PASSWORD}
      - WG_DEFAULT_DNS=1.1.1.1
    volumes:
      - ./config:/etc/wireguard
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
WGEASY_COMPOSE

    cat > .env << WGEASY_ENV
WG_HOST=$WG_HOST
WG_PASSWORD=$WG_PASSWORD
CADDY_NET=$SITE_CADDY_NET
WGEASY_ENV

    mkdir -p config
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WGEASY_DIR"
    log_success "wg-easy configured at $WGEASY_DIR"

    configure_caddy_for_service "wg-easy" "wg-easy:51821" "vpn"

    write_readme "$WGEASY_DIR" << MD
# wg-easy

WireGuard VPN with a web UI for managing clients, generating QR codes,
and monitoring connections.

- Web UI: http://localhost:51821
- VPN:    UDP port 51820 (forward this on your router)
- Password: stored in \`.env\` (\`WG_PASSWORD\`)
- VPN host: \`$WG_HOST\` (update \`WG_HOST\` in .env if your IP changes)
- Config: \`config/\`

## Manage
\`\`\`bash
cd $WGEASY_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Router setup
Forward **UDP port 51820** to this server's LAN IP for external VPN access.

## Adding clients
Open http://localhost:51821, log in with your password, click "+ New Client",
download or scan the QR code with the WireGuard app.
MD

    local START_WGEASY=""
    prompt_yn "Start wg-easy now? (y/n):" "y" START_WGEASY
    if [ "$START_WGEASY" = "y" ] || [ "$START_WGEASY" = "Y" ]; then
        docker compose up -d && log_success "wg-easy started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Web UI:   http://localhost:51821"
    echo "  Password: $WG_PASSWORD  (saved in .env)"
    echo "  Router:   forward UDP 51820 → this server for external VPN access"
    echo ""
}
