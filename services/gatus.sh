#!/bin/bash
# services/gatus.sh — Gatus status/uptime monitoring page.
# Part of the modular post-install system (sourced by setup.sh).
#
# Gatus polls endpoints (HTTP, TCP, DNS, ICMP) on a schedule and shows a
# clean status dashboard. Config is hot-reloaded from gatus_config/config.yaml.

register_service gatus utilities "Status & uptime monitoring page (Gatus)" 8086

install_gatus() {
    require_docker || return 1
    log_info "Installing Gatus..."
    local GATUS_DIR="$DOCKER_DIR/gatus"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $GATUS_DIR (gatus_config/, gatus_data/)"
        echo "[DRY-RUN] Would deploy twinproduction/gatus:latest"
        echo "[DRY-RUN] Port 8086 published, config at gatus_config/config.yaml"
        return 0
    fi

    mkdir -p "$GATUS_DIR/gatus_config" "$GATUS_DIR/gatus_data"
    ensure_docker_dir_ownership "$GATUS_DIR"
    cd "$GATUS_DIR" || return 1

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'GATUS_COMPOSE'
name: gatus

services:
  gatus:
    image: twinproduction/gatus:latest
    container_name: gatus
    hostname: gatus
    restart: unless-stopped
    env_file: .env
    ports:
      - "8086:8080"
    volumes:
      - ./gatus_config:/config
      - ./gatus_data:/data
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
GATUS_COMPOSE

    cat > .env << GATUS_ENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET
GATUS_ENV

    # Write a sample config if none exists
    if [ ! -f gatus_config/config.yaml ]; then
        cat > gatus_config/config.yaml << 'GATUS_CFG'
# Gatus configuration — docs: https://github.com/TwiN/gatus
#
# Add or remove endpoints below. Config is hot-reloaded on changes.
# Alert types: ntfy, slack, discord, email, telegram, and more.

storage:
  type: sqlite
  path: /data/gatus.db

ui:
  title: "Status"
  header: "Services"

# ── Endpoints ─────────────────────────────────────────────────────────────────
endpoints:
  - name: Google DNS
    group: external
    url: "8.8.8.8"
    dns:
      query-name: "google.com"
      query-type: "A"
    interval: 5m
    conditions:
      - "[DNS_RCODE] == NOERROR"

  - name: Example HTTPS
    group: external
    url: "https://example.com"
    interval: 5m
    conditions:
      - "[STATUS] == 200"
      - "[RESPONSE_TIME] < 3000"
      - "[CERTIFICATE_EXPIRATION] > 48h"

  # ── Add your services below ────────────────────────────────────────────────
  # - name: Mealie
  #   group: homelab
  #   url: "http://mealie:9000/api/app/about"
  #   interval: 1m
  #   conditions:
  #     - "[STATUS] == 200"
  #     - "[RESPONSE_TIME] < 500"
  #
  # - name: Portainer
  #   group: homelab
  #   url: "https://portainer:9443"
  #   interval: 1m
  #   conditions:
  #     - "[STATUS] == 200"
  #   client:
  #     insecure: true
GATUS_CFG
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$GATUS_DIR"
    log_success "Gatus configured at $GATUS_DIR"

    configure_caddy_for_service "Gatus" "gatus:8080" "status"

    write_readme "$GATUS_DIR" << MD
# Gatus — status & uptime monitoring

Clean, self-hosted status page. Polls HTTP, TCP, DNS, and ICMP endpoints.

## Access
- URL: http://localhost:8086

## Configuration
Edit \`gatus_config/config.yaml\` — changes are **hot-reloaded** without restarting.

Key concepts:
- \`endpoints:\` — what to check (HTTP, TCP, DNS, ICMP)
- \`interval:\` — how often (e.g. 1m, 5m)
- \`conditions:\` — pass/fail rules ([STATUS], [RESPONSE_TIME], etc.)
- \`alerts:\` — notify via ntfy, Slack, Discord, email, etc.

Full docs: https://github.com/TwiN/gatus

## Manage
\`\`\`bash
cd $GATUS_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs (check config errors here)
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_GATUS=""
    prompt_yn "Start Gatus now? (y/n):" "y" START_GATUS
    if [ "$START_GATUS" = "y" ] || [ "$START_GATUS" = "Y" ]; then
        docker compose up -d \
            && log_success "Gatus started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo "  Access at:  http://localhost:8086"
    echo "  Config:     $GATUS_DIR/gatus_config/config.yaml (hot-reloaded)"
    echo ""
}
