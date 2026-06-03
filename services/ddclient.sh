#!/bin/bash
# services/ddclient.sh — Dynamic DNS updater (ddclient).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- DDCLIENT ----).
# Own ~/docker/ddclient/ with a standalone docker-compose.yml + config.
# Supports Cloudflare, DuckDNS, No-IP, and many other providers.
# Edit config/ddclient.conf before starting — no web UI.

register_service ddclient utilities "Dynamic DNS updater — keep your domain pointing at your home IP (ddclient)"

install_ddclient() {
    require_docker || return 1

    local DDCLIENT_DIR="$DOCKER_DIR/ddclient"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] ddclient would:"
        echo "  - Create $DDCLIENT_DIR with docker-compose.yml + config/ddclient.conf template"
        echo "  - No web UI — edit config/ddclient.conf for your DNS provider before starting"
        return 0
    fi

    mkdir -p "$DDCLIENT_DIR"
    ensure_docker_dir_ownership "$DDCLIENT_DIR"
    cd "$DDCLIENT_DIR" || return 1

    local TZ_VAL; TZ_VAL=$(cat /etc/timezone 2>/dev/null || echo "UTC")

    cat > docker-compose.yml << 'DDCLIENT_COMPOSE'
name: ddclient

services:
  ddclient:
    image: lscr.io/linuxserver/ddclient:latest
    container_name: ddclient
    hostname: ddclient
    restart: unless-stopped
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=${TZ}
    volumes:
      - ./config:/config
DDCLIENT_COMPOSE

    cat > .env << DDCLIENT_ENV
TZ=$TZ_VAL
DDCLIENT_ENV

    mkdir -p config

    cat > config/ddclient.conf << 'DDCLIENT_CONF'
# ddclient configuration
# Docs: https://ddclient.net/
#
# ⚠️  YOU MUST EDIT THIS FILE before starting ddclient.
# Uncomment and fill in the block for your DNS provider.

daemon=300
syslog=yes
pid=/var/run/ddclient/ddclient.pid
ssl=yes

# Cloudflare example:
# use=web, web=cloudflare
# protocol=cloudflare
# zone=example.com
# login=token
# password=your-api-token
# example.com

# DuckDNS example:
# use=web
# protocol=duckdns
# password=your-duckdns-token
# yourdomain.duckdns.org

# No-IP example:
# use=web
# protocol=noip
# login=your@email.com
# password=your-password
# yourhostname.ddns.net
DDCLIENT_CONF

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DDCLIENT_DIR"
    log_success "ddclient configured at $DDCLIENT_DIR"

    write_readme "$DDCLIENT_DIR" << MD
# ddclient

Dynamic DNS client — keeps your domain pointing at your home IP address
even when your ISP changes it. No web UI; runs as a background daemon.

- Config: \`config/ddclient.conf\` — **edit before starting**
- Supported providers: Cloudflare, DuckDNS, No-IP, FreeDNS, and more

## Setup
1. Edit \`config/ddclient.conf\` for your DNS provider.
2. Start: \`docker compose up -d\`
3. Check logs: \`docker compose logs -f\`

## Manage
\`\`\`bash
cd $DDCLIENT_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Docs
- https://ddclient.net/
- Cloudflare setup: https://ddclient.net/protocols/cloudflare.html
MD

    echo ""
    log_warning "Edit config/ddclient.conf for your DNS provider before starting."
    echo ""
    local START_DDC=""
    prompt_yn "Start ddclient now? (y/n):" "n" START_DDC
    if [ "$START_DDC" = "y" ] || [ "$START_DDC" = "Y" ]; then
        docker compose up -d && log_success "ddclient started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Config:  $DDCLIENT_DIR/config/ddclient.conf"
    echo "  Docs:    https://ddclient.net/"
    echo ""
}
