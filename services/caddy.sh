#!/bin/bash
# services/caddy.sh — Caddy reverse proxy + automatic HTTPS.
# Part of the modular post-install system (sourced by setup.sh).
#
# Caddy is the front door for the homelab: it terminates TLS (automatic
# Let's Encrypt certificates), reverse-proxies to your other services, and
# writes JSON access logs that CrowdSec reads for intrusion prevention.
#
# Each web service adds its own site block to $CADDY_DIR/Caddyfile (the shared
# configure_caddy_for_service helper does this automatically), then Caddy is
# reloaded without downtime.

register_service caddy homelab "Reverse proxy + automatic HTTPS (Caddy)" 443

install_caddy() {
    require_docker || return 1
    log_info "Installing Caddy reverse proxy..."

    local CADDY_DIR="$DOCKER_DIR/caddy"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ CADDY - Modern Web Server & Reverse Proxy                       │"
    echo "│ Automatic HTTPS, reverse proxy for all your services            │"
    echo "│ Port: 80 (HTTP), 443 (HTTPS)                                    │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    # ── DRY-RUN: describe the plan and bail before touching anything real ────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $CADDY_DIR (data/, config/)"
        echo "[DRY-RUN] Would write $CADDY_DIR/docker-compose.yml (ports 80/443 + HTTP/3)"
        echo "[DRY-RUN] Would write a starter $CADDY_DIR/Caddyfile (if none exists)"
        echo "[DRY-RUN] Would write $CADDY_DIR/README.md"
        echo "[DRY-RUN] Would optionally start Caddy (docker compose up -d)"
        return 0
    fi

    # Reconfigure guard: warn if Caddy already looks installed.
    if [ -f "$CADDY_DIR/Caddyfile" ] || [ -f "$CADDY_DIR/docker-compose.yml" ]; then
        echo ""
        echo "⚠  Caddy appears to be already installed at $CADDY_DIR"
        local RECONFIGURE_CADDY=""
        prompt_yn "Do you want to reconfigure it? (y/n):" "n" RECONFIGURE_CADDY
        if [ "$RECONFIGURE_CADDY" != "y" ] && [ "$RECONFIGURE_CADDY" != "Y" ]; then
            echo "  Skipping Caddy installation"
            return 0
        fi
    fi

    mkdir -p "$CADDY_DIR/data" "$CADDY_DIR/config"
    ensure_docker_dir_ownership "$CADDY_DIR"

    # Backup existing Caddyfile if it exists
    if [ -f "$CADDY_DIR/Caddyfile" ]; then
        mkdir -p "$CADDY_DIR/backups"
        local BACKUP_FILE="$CADDY_DIR/backups/Caddyfile.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CADDY_DIR/Caddyfile" "$BACKUP_FILE"
        echo "  ✓ Backed up existing Caddyfile to: $BACKUP_FILE"
    fi

    cd "$CADDY_DIR" || return 1

    cat > docker-compose.yml << 'CADDY_COMPOSE'
name: caddy

services:
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"  # HTTP/3
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ./data:/data
      - ./config:/config
      - /var/log/caddy:/var/log/caddy
    environment:
      - ACME_AGREE=true
    labels:
      - "io.podman.annotations.label/crowdsec.enable=true"
    networks:
      - caddy_net

networks:
  caddy_net:
    driver: bridge
    name: caddy_net
CADDY_COMPOSE

    # Create Caddyfile if it doesn't exist
    if [ ! -f "Caddyfile" ]; then
        cat > Caddyfile << 'CADDYFILE'
{
    # Global options
    admin off
    # Email for Let's Encrypt notifications
    # email admin@yourdomain.com
}

# Example configuration - edit this for your services
# Uncomment and modify these examples:

# ── Authelia SSO snippet (auto-added by installer if Authelia is installed) ───
# (authelia) {
#     forward_auth authelia:9091 {
#         uri /api/authz/forward-auth
#         copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
#     }
# }
#
# Authelia login portal
# auth.yourdomain.com {
#     reverse_proxy authelia:9091
# }
#
# To protect any service with Authelia, add:  import authelia
# Example:
# myservice.yourdomain.com {
#     import authelia
#     reverse_proxy container_name:port
# }

# ActualBudget
# budget.yourdomain.com {
#     log {
#         output file /var/log/caddy/actualbudget-access.log
#         format json
#         level INFO
#     }
#     reverse_proxy actualbudget:5006
#     header {
#         Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
#         X-Frame-Options "SAMEORIGIN"
#         X-Content-Type-Options "nosniff"
#         X-XSS-Protection "1; mode=block"
#         Referrer-Policy "strict-origin-when-cross-origin"
#     }
# }

# Add more services here...
CADDYFILE
        echo "  ✓ Created example Caddyfile"
    else
        echo "  ℹ Using existing Caddyfile"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$CADDY_DIR"
    echo "  ✓ Caddy configured at $CADDY_DIR"

    write_readme "$CADDY_DIR" << 'CADDY_README'
# Caddy — reverse proxy + automatic HTTPS

Caddy is the front door for this box. It:

- Reverse-proxies incoming requests to your other services.
- Obtains and renews TLS certificates automatically (Let's Encrypt / ZeroSSL),
  so every site is HTTPS with no manual cert wrangling.
- Listens on **80** (HTTP, redirects to HTTPS) and **443** (HTTPS, incl. HTTP/3
  on 443/udp).
- Writes JSON access logs to `/var/log/caddy/` — these are what CrowdSec reads
  to detect and ban malicious traffic.

## Adding services

Other services add their own **site blocks** to `./Caddyfile` (the installer's
`configure_caddy_for_service` helper appends them automatically when you install
a web service). You can also edit it by hand:

```
myservice.example.com {
    reverse_proxy container_name:1234
    log {
        output file /var/log/caddy/myservice.example.com.log
        format json
    }
}
```

## Reloading after edits

Apply Caddyfile changes without downtime:

```
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

## Start / stop

From this folder (`~/docker/caddy`):

```
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # follow logs
```

## Where things live

- Caddyfile:  `~/docker/caddy/Caddyfile`  (mounted at `/etc/caddy/Caddyfile`)
- Access logs: `/var/log/caddy/*.log`  (JSON; consumed by CrowdSec)
- Certs/state: `~/docker/caddy/data` and `~/docker/caddy/config`
- Backups of the Caddyfile: `~/docker/caddy/backups/`
CADDY_README

    local START_CADDY=""
    prompt_yn "Start Caddy now? (y/n):" "y" START_CADDY
    if [ "$START_CADDY" = "y" ] || [ "$START_CADDY" = "Y" ]; then
        docker compose up -d 2>/dev/null && echo "  ✓ Caddy started" || echo "  ⚠ Failed to start Caddy"
    fi

    echo ""
    echo "  Configuration file: $CADDY_DIR/Caddyfile"
    echo "  Edit Caddyfile to add your domains and services"
    echo "  Reload config:      docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
    echo ""
    echo "  ⚠  IMPORTANT: Edit the Caddyfile to configure your domains!"
    echo "     - Uncomment and modify the example configurations"
    echo "     - Add your domain names"
    echo "     - Configure services you want to expose"
    echo ""
}
