#!/bin/bash
# services/filebrowser.sh — FileBrowser web-based file manager.
# Part of the modular post-install system (sourced by setup.sh).

register_service filebrowser utilities "Web file manager (FileBrowser)" 8085

install_filebrowser() {
    require_docker || return 1
    log_info "Installing Filebrowser..."
    local FB_DIR="$DOCKER_DIR/filebrowser"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $FB_DIR"
        return 0
    fi

    mkdir -p "$FB_DIR"
    ensure_docker_dir_ownership "$FB_DIR"
    cd "$FB_DIR" || return 1

    local FB_PATH=""
    prompt_text "Path to browse [default: $ACTUAL_HOME]:" "$ACTUAL_HOME" FB_PATH

    cat > docker-compose.yml << FB_COMPOSE
name: filebrowser

services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser
    hostname: filebrowser
    restart: unless-stopped
    environment:
      - TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
    volumes:
      - ${FB_PATH}:/srv
      - ./database/filebrowser.db:/database/filebrowser.db
      - ./config/settings.json:/config/settings.json
    ports:
      - "8085:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
FB_COMPOSE

    cat > .env << FB_ENV
FB_PATH=$FB_PATH
CADDY_NET=$SITE_CADDY_NET
FB_ENV

    mkdir -p database config
    touch database/filebrowser.db
    cat > config/settings.json << 'FB_SETTINGS'
{
  "port": 80,
  "baseURL": "",
  "address": "",
  "log": "stdout",
  "database": "/database/filebrowser.db",
  "root": "/srv"
}
FB_SETTINGS

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR"

    # Deploy user-management helper script
    local _TOOLS_DIR
    _TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" 2>/dev/null && pwd)" || true
    if [ -f "$_TOOLS_DIR/manage_users.sh" ]; then
        cp "$_TOOLS_DIR/manage_users.sh" "$FB_DIR/manage_users.sh"
        chmod 750 "$FB_DIR/manage_users.sh"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$FB_DIR/manage_users.sh"
        log_success "manage_users.sh installed at $FB_DIR/manage_users.sh"
    fi

    echo ""
    log_success "Filebrowser configured at $FB_DIR"

    configure_caddy_for_service "FileBrowser" "filebrowser:80" "files"

    write_readme "$FB_DIR" << MD
# FileBrowser

Web-based file manager. Browse, upload, and download files through a browser.

## Access
- URL: http://localhost:8085
- Default login: admin / admin (change immediately!)

## Data
- Browsed path: $FB_PATH (mounted to /srv)
- Database: ./database/filebrowser.db
- Settings: ./config/settings.json

## Manage
\`\`\`
cd $FB_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`
MD

    local START_FB=""
    prompt_yn "Start Filebrowser now? (y/n):" "y" START_FB
    if [ "$START_FB" = "y" ] || [ "$START_FB" = "Y" ]; then
        docker compose up -d 2>/dev/null && log_success "Filebrowser started" || log_warning "Failed to start"
    fi

    echo "  Access at:  http://localhost:8085"
    echo "  Default login: admin / admin (change immediately!)"
    echo ""
}
