#!/bin/bash
# services/magicmirror.sh — Modular smart mirror / info dashboard (MagicMirror²).
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- MAGIC MIRROR ----).
# Supports 1-3 instances (ports 8081-8083) each in ~/docker/magicmirror/<N>/.
# If you provide an existing config.js, third-party MMM-* modules are detected
# and cloned from GitHub automatically.

register_service magicmirror utilities "Modular smart mirror / info dashboard (MagicMirror²)" 8081

install_magicmirror() {
    require_docker || return 1

    local MM_BASE="$DOCKER_DIR/magicmirror"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] MagicMirror would:"
        echo "  - Ask how many instances (1-3, ports 8081-8083)"
        echo "  - Create $MM_BASE/<N>/ for each instance"
        echo "  - Optionally copy your existing config.js + clone MMM-* modules"
        echo "  - Offer a Caddy reverse proxy (first instance) and to start"
        return 0
    fi

    # Number of instances
    local MM_COUNT=""
    prompt_text "How many MagicMirror instances? [1-3, default: 1]:" "1" MM_COUNT
    MM_COUNT="${MM_COUNT:-1}"
    [ "$MM_COUNT" -gt 3 ] 2>/dev/null && MM_COUNT=3
    [ "$MM_COUNT" -lt 1 ] 2>/dev/null && MM_COUNT=1

    mkdir -p "$MM_BASE"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$MM_BASE"

    local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    local i MM_PORT MM_DIR

    for i in $(seq 1 "$MM_COUNT"); do
        MM_PORT=$((8080 + i))
        MM_DIR="$MM_BASE/$i"

        echo ""
        echo "── Instance $i (port $MM_PORT) ──"
        mkdir -p "$MM_DIR"
        ensure_docker_dir_ownership "$MM_DIR"
        cd "$MM_DIR" || continue

        cat > docker-compose.yml << MM_COMPOSE
name: mm-$MM_PORT

services:
  magicmirror:
    image: karsten13/magicmirror:latest
    container_name: magicmirror-$MM_PORT
    hostname: magicmirror-$MM_PORT
    restart: unless-stopped
    environment:
      - TZ=$TZ_VAL
    volumes:
      - ./config:/opt/magic_mirror/config
      - ./modules:/opt/magic_mirror/modules
      - ./css:/opt/magic_mirror/css
    ports:
      - "$MM_PORT:8080"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
MM_COMPOSE

        mkdir -p config modules css

        # Offer to copy an existing config.js
        local MM_CONFIG_CHOICE=""
        echo ""
        echo "  Config options:"
        echo "    [1] Use default config (basic built-in modules)"
        echo "    [2] Copy existing config.js from a path"
        if [ "$UNATTENDED" = true ]; then
            MM_CONFIG_CHOICE="1"
        else
            read -r -p "  Choose [1]: " MM_CONFIG_CHOICE
            MM_CONFIG_CHOICE="${MM_CONFIG_CHOICE:-1}"
        fi

        if [ "$MM_CONFIG_CHOICE" = "2" ]; then
            local MM_CONFIG_PATH=""
            read -r -p "  Path to config.js: " MM_CONFIG_PATH
            if [ -f "$MM_CONFIG_PATH" ]; then
                cp "$MM_CONFIG_PATH" config/config.js
                log_success "Copied config from $MM_CONFIG_PATH"

                # Copy custom.css if it exists next to config.js
                local MM_CSS_DIR="${MM_CONFIG_PATH%/*}"
                [ -f "$MM_CSS_DIR/custom.css" ] && cp "$MM_CSS_DIR/custom.css" css/custom.css && log_success "Copied custom.css"

                # Detect MMM-* third-party modules referenced in config
                local THIRD_PARTY_MODS
                THIRD_PARTY_MODS=$(grep -oP "module:\s*[\"']MMM-[^\"']+[\"']" config/config.js 2>/dev/null \
                    | sed "s/module:\s*[\"']//g" | sed "s/[\"']//g" | sort -u)

                if [ -n "$THIRD_PARTY_MODS" ]; then
                    echo ""
                    echo "  Third-party modules found in config:"
                    echo "$THIRD_PARTY_MODS" | while read -r mod; do echo "    - $mod"; done
                    echo ""
                    local MM_DL_MODS=""
                    prompt_yn "  Download these modules from GitHub? (y/n):" "y" MM_DL_MODS
                    if [ "$MM_DL_MODS" = "y" ] || [ "$MM_DL_MODS" = "Y" ]; then
                        cd modules || true
                        echo "$THIRD_PARTY_MODS" | while read -r mod; do
                            [ -z "$mod" ] || [ -d "$mod" ] && continue
                            echo "  Downloading $mod..."
                            git clone --depth 1 "https://github.com/MichMich/${mod}.git" 2>/dev/null || \
                            git clone --depth 1 "https://github.com/bugsounet/${mod}.git" 2>/dev/null || \
                            git clone --depth 1 "https://github.com/MagicMirrorOrg/${mod}.git" 2>/dev/null || \
                            log_warning "Could not find $mod — search at https://github.com/topics/magicmirror"
                        done
                        cd "$MM_DIR" || true
                    fi
                fi
            else
                log_warning "File not found: $MM_CONFIG_PATH — using default config"
            fi
        fi

        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MM_DIR"
        log_success "MagicMirror instance $i configured at $MM_DIR (port $MM_PORT)"

        # Offer Caddy only for first instance
        [ "$i" -eq 1 ] && configure_caddy_for_service "MagicMirror" "$MM_PORT" "mirror"

        local START_MM=""
        prompt_yn "Start instance $i now? (y/n):" "y" START_MM
        if [ "$START_MM" = "y" ] || [ "$START_MM" = "Y" ]; then
            docker compose up -d && log_success "MagicMirror instance $i started" || log_warning "Failed to start — check: docker compose logs"
        fi

        echo "  Access at:  http://localhost:$MM_PORT"
    done

    write_readme "$MM_BASE" << MD
# MagicMirror²

Modular smart mirror / info dashboard. Each instance has its own port and
independent config, modules, and CSS.

| Instance | Port | Directory |
|----------|------|-----------|
$(for j in $(seq 1 "$MM_COUNT"); do echo "| $j | $((8080 + j)) | \`$MM_BASE/$j/\` |"; done)

## Manage
\`\`\`bash
cd $MM_BASE/1
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Config
- Edit \`<instance>/config/config.js\` for layout and module settings.
- Add CSS overrides in \`<instance>/css/custom.css\`.
- Third-party modules go in \`<instance>/modules/<module-name>/\`.
  Then run \`docker exec magicmirror-PORT sh -c 'cd /opt/magic_mirror/modules/<name> && npm install --production'\`

## Finding modules
Browse: https://github.com/topics/magicmirror
MD

    echo ""
    echo "  MagicMirror config: $MM_BASE/<instance>/config/config.js"
    echo ""
}
