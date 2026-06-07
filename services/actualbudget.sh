#!/bin/bash
# services/actualbudget.sh — Open-source personal finance / budgeting (Actual Budget).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- ACTUALBUDGET ----).
# Own ~/docker/actualbudget/ with a standalone docker-compose.yml.

register_service actualbudget utilities "Open-source personal finance & budgeting (Actual Budget)" 5006

install_actualbudget() {
    require_docker || return 1

    local AB_DIR="$DOCKER_DIR/actualbudget"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Actual Budget would:"
        echo "  - Create $AB_DIR with docker-compose.yml (data/)"
        echo "  - Expose port 5006"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$AB_DIR/data"
    ensure_docker_dir_ownership "$AB_DIR"
    cd "$AB_DIR" || return 1

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'AB_COMPOSE'
name: actualbudget

services:
  actualbudget:
    image: actualbudget/actual-server:latest
    container_name: actualbudget
    restart: unless-stopped
    ports:
      - "5006:5006"
    volumes:
      - ./data:/data
    env_file:
      - .env
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
AB_COMPOSE

    cat > .env << AB_ENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET
AB_ENV

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$AB_DIR"
    log_success "Actual Budget configured at $AB_DIR"

    configure_caddy_for_service "ActualBudget" "5006" "budget"

    write_readme "$AB_DIR" << MD
# Actual Budget

Open-source personal finance and budgeting tool. Supports bank sync via
SimpleFIN (requires a SimpleFIN account at simplefin.org).

- Web UI: http://localhost:5006
- App data: \`data/\`

## Manage
\`\`\`bash
cd $AB_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Notes
- First launch: create a budget file or import an existing one.
- Bank sync requires a SimpleFIN bridge subscription (simplefin.org).
MD

    local START_AB=""
    prompt_yn "Start Actual Budget now? (y/n):" "y" START_AB
    if [ "$START_AB" = "y" ] || [ "$START_AB" = "Y" ]; then
        docker compose up -d && log_success "Actual Budget started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:5006"
    echo "  Bank sync:  simplefin.org (optional, paid)"
    echo ""
}
