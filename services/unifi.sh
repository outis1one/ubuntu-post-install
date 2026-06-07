#!/bin/bash
# services/unifi.sh — UniFi Network Application (Ubiquiti controller).
# Part of the modular post-install system (sourced by setup.sh).
#
# Two containers: mongo:4 (DB) + linuxserver unifi-network-application (app).
# Web UI runs on HTTPS port 8443 — no plain HTTP web interface.
# Caddy reverse-proxy wiring uses TLS passthrough or tls_insecure_skip_verify.

register_service unifi utilities "Ubiquiti network controller (UniFi)" 8443

install_unifi() {
    require_docker || return 1
    log_info "Installing UniFi Network Application..."
    local UNIFI_DIR="$DOCKER_DIR/unifi"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $UNIFI_DIR (mongo_db_data/, unifi_data/)"
        echo "[DRY-RUN] Would deploy mongo:4 + linuxserver/unifi-network-application:latest"
        echo "[DRY-RUN] Ports: 8443 (HTTPS web UI), 8080 (device inform), 3478/udp (STUN), 10001/udp (discovery)"
        echo "[DRY-RUN] Would generate MongoDB credentials"
        return 0
    fi

    mkdir -p "$UNIFI_DIR"
    ensure_docker_dir_ownership "$UNIFI_DIR"
    cd "$UNIFI_DIR" || return 1

    local MONGO_PASS TZ_VAL UID_VAL GID_VAL
    MONGO_PASS=$(generate_password 24)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER")
    GID_VAL=$(id -g "$ACTUAL_USER")

    # Single-quoted heredoc: ${...} left literal for Docker Compose to expand from .env
    cat > docker-compose.yml << 'UNIFI_COMPOSE'
name: unifi

services:
  unifi-db:
    image: mongo:4
    container_name: unifi-db
    hostname: unifi-db
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./mongo_db_data:/data/db
    expose:
      - "27017"
    configs:
      - source: init-mongo.js
        target: /docker-entrypoint-initdb.d/init-mongo.js

  unifi-app:
    image: lscr.io/linuxserver/unifi-network-application:latest
    container_name: unifi-app
    hostname: unifi-app
    restart: unless-stopped
    env_file: .env
    depends_on:
      - unifi-db
    volumes:
      - ./unifi_data:/config
    ports:
      - "8443:8443"
      - "8080:8080"
      - "3478:3478/udp"
      - "10001:10001/udp"
      # Optional — uncomment as needed:
      # - "1900:1900/udp"   # L2 discovery (may conflict with UPnP)
      # - "8843:8843"       # guest portal HTTPS
      # - "8880:8880"       # guest portal HTTP
      # - "6789:6789"       # mobile speed test
      # - "5514:5514/udp"   # remote syslog
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}

# Inline MongoDB init — Docker Compose interpolates vars from .env at startup.
configs:
  init-mongo.js:
    content: |
      db.getSiblingDB("${MONGO_DBNAME}").createUser({user: "${MONGO_USER}", pwd: "${MONGO_PASS}", roles: [{role: "${MONGO_ROLE}", db: "${MONGO_DBNAME}"}]});
      db.getSiblingDB("${MONGO_DBNAME}_stat").createUser({user: "${MONGO_USER}", pwd: "${MONGO_PASS}", roles: [{role: "${MONGO_ROLE}", db: "${MONGO_DBNAME}_stat"}]});
UNIFI_COMPOSE

    cat > .env << UNIFI_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── LinuxServer — UniFi app ───────────────────────────────────────────────────
PUID=$UID_VAL
PGID=$GID_VAL
MEM_LIMIT=1024
MEM_STARTUP=512

# ── MongoDB connection ────────────────────────────────────────────────────────
MONGO_USER=unifi
MONGO_PASS=$MONGO_PASS
MONGO_HOST=unifi-db
MONGO_PORT=27017
MONGO_DBNAME=unifi_db
MONGO_ROLE=dbOwner
# MONGO_TLS=        # optional
# MONGO_AUTHSOURCE= # optional
UNIFI_ENV

    chmod 600 .env
    mkdir -p mongo_db_data unifi_data
    ensure_docker_dir_ownership "$UNIFI_DIR"

    log_success "UniFi configured at $UNIFI_DIR"

    # ── Optional Caddy reverse proxy (HTTPS backend requires special config) ──
    if [ -d "$DOCKER_DIR/caddy" ]; then
        echo ""
        echo "  UniFi web UI is HTTPS-only (self-signed cert internally)."
        echo "  Caddy can proxy it, but requires tls_insecure_skip_verify."
        echo ""
        local CADDY_UNIFI=""
        prompt_yn "Configure Caddy reverse proxy for UniFi? (y/n):" "n" CADDY_UNIFI
        if [ "$CADDY_UNIFI" = "y" ] || [ "$CADDY_UNIFI" = "Y" ]; then
            local UNIFI_DOMAIN=""
            prompt_text "UniFi domain (e.g. unifi.example.com):" "unifi.${SITE_DOMAIN:-example.com}" UNIFI_DOMAIN
            if [ -n "$UNIFI_DOMAIN" ]; then
                local CADDYFILE="$DOCKER_DIR/caddy/Caddyfile"
                cp "$CADDYFILE" "$CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
                cat >> "$CADDYFILE" << CADDY_BLOCK

# UniFi Network Application
$UNIFI_DOMAIN {
    reverse_proxy https://unifi-app:8443 {
        transport http {
            tls_insecure_skip_verify
        }
    }

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/$UNIFI_DOMAIN.log
        format json
    }
}
CADDY_BLOCK
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null \
                    && log_success "Caddy configured for $UNIFI_DOMAIN" \
                    || log_warning "Caddy reload failed — check: docker logs caddy"
            fi
        fi
    fi

    write_readme "$UNIFI_DIR" << MD
# UniFi Network Application

Ubiquiti network controller. Manages UniFi APs, switches, and gateways.

## Access
- Web UI: **https://localhost:8443** (HTTPS, self-signed cert — accept the warning)
- First run: complete the setup wizard and adopt your devices.

## Device adoption
Make sure devices can reach **http://<server-ip>:8080/inform** as the inform URL.
In the controller: Settings → System → Application Configuration → Override inform host.

## Ports
| Port | Protocol | Purpose |
|------|----------|---------|
| 8443 | TCP | HTTPS web UI |
| 8080 | TCP | Device inform / HTTP redirect |
| 3478 | UDP | STUN |
| 10001 | UDP | AP discovery |

## Manage
\`\`\`bash
cd $UNIFI_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update (wait for DB first)
\`\`\`

## Migration from old UniFi Controller
1. Backup: Settings → System → Backup → Create Backup
2. Down the old container
3. Spin up this stack
4. Restore: Settings → System → Backup → Restore
MD

    local START_UNIFI=""
    prompt_yn "Start UniFi now? (y/n):" "y" START_UNIFI
    if [ "$START_UNIFI" = "y" ] || [ "$START_UNIFI" = "Y" ]; then
        docker compose up -d \
            && log_success "UniFi started (first startup takes ~60 s while DB initializes)" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Web UI:  https://localhost:8443  (accept the self-signed cert warning)"
    echo "  MongoDB credentials saved to: $UNIFI_DIR/.env"
    echo ""
}
