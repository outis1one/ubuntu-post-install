#!/bin/bash
# services/onlyoffice.sh — Self-hosted OnlyOffice Document Server for Nextcloud/FileBrowser.
# Part of the modular post-install system (sourced by setup.sh).
#
# OnlyOffice Document Server provides collaborative editing for Nextcloud and
# other platforms. JWT is enabled to secure the API endpoint.

register_service onlyoffice utilities "Self-hosted OnlyOffice Document Server for Nextcloud/FileBrowser" 8082

install_onlyoffice() {
    require_docker || return 1
    log_info "Installing OnlyOffice Document Server..."
    local DIR="$DOCKER_DIR/onlyoffice"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml and .env"
        echo "[DRY-RUN] Would deploy onlyoffice/documentserver:latest on port 8082"
        echo "[DRY-RUN] Would generate JWT secret"
        echo "[DRY-RUN] Would configure Nextcloud via occ (if $DOCKER_DIR/nextcloud exists)"
        echo "[DRY-RUN] Would configure FileBrowser config.yaml (if present)"
        return 0
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    local JWT_SECRET
    JWT_SECRET=$(generate_password 32)

    cat > docker-compose.yml << 'OO_COMPOSE'
name: onlyoffice

services:
  onlyoffice:
    image: onlyoffice/documentserver:latest
    container_name: onlyoffice
    hostname: onlyoffice
    restart: unless-stopped
    env_file: .env
    ports:
      - "8082:80"
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
OO_COMPOSE

    cat > .env << OO_ENV
# ── OnlyOffice Document Server ────────────────────────────────────────────────
CADDY_NET=$SITE_CADDY_NET

# JWT authentication — keep JWT_SECRET secret; used by Nextcloud integration
JWT_ENABLED=true
JWT_SECRET=$JWT_SECRET
JWT_HEADER=AuthorizationJwt
OO_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"
    log_success "OnlyOffice configured at $DIR"

    configure_caddy_for_service "OnlyOffice" "onlyoffice:80" "office"

    # ── Start container ────────────────────────────────────────────────────────
    local START=""
    prompt_yn "Start OnlyOffice now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "OnlyOffice started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Nextcloud integration ──────────────────────────────────────────────────
    if [ -d "$DOCKER_DIR/nextcloud" ]; then
        log_info "Nextcloud detected — configuring OnlyOffice integration via occ..."
        docker exec --user www-data nextcloud php occ app:enable onlyoffice \
            && log_success "OnlyOffice app enabled in Nextcloud" \
            || log_warning "Could not enable OnlyOffice app — run manually: docker exec --user www-data nextcloud php occ app:enable onlyoffice"
        docker exec --user www-data nextcloud php occ config:app:set onlyoffice DocumentServerUrl --value "http://onlyoffice:80/" \
            && log_success "Nextcloud DocumentServerUrl set" \
            || log_warning "Could not set DocumentServerUrl"
        docker exec --user www-data nextcloud php occ config:app:set onlyoffice jwt_secret --value "$JWT_SECRET" \
            && log_success "Nextcloud jwt_secret set" \
            || log_warning "Could not set jwt_secret"
        docker exec --user www-data nextcloud php occ config:app:set onlyoffice jwt_header --value "AuthorizationJwt" \
            && log_success "Nextcloud jwt_header set" \
            || log_warning "Could not set jwt_header"
    else
        echo ""
        echo "  Nextcloud not found. To integrate OnlyOffice with Nextcloud manually:"
        echo "    1. Install the OnlyOffice app in Nextcloud (Apps > Office & Text)"
        echo "    2. Go to Settings > OnlyOffice and set:"
        echo "       Document Server URL: http://onlyoffice:80/"
        echo "       JWT Secret:          $JWT_SECRET"
        echo "       JWT Header:          AuthorizationJwt"
        echo ""
    fi

    # ── FileBrowser integration ────────────────────────────────────────────────
    local FB_CONFIG="$DOCKER_DIR/filebrowser/data/config.yaml"
    if [ -f "$FB_CONFIG" ]; then
        if command -v yq >/dev/null 2>&1; then
            yq e -i '.officeServer = "http://onlyoffice:80/"' "$FB_CONFIG" \
                && log_success "FileBrowser config.yaml updated with officeServer" \
                || log_warning "yq failed to update $FB_CONFIG — set officeServer manually"
        else
            log_info "yq not found. To enable OnlyOffice in FileBrowser, add to $FB_CONFIG:"
            log_info "  officeServer: \"http://onlyoffice:80/\""
        fi
    fi

    write_readme "$DIR" << MD
# OnlyOffice Document Server

Self-hosted document editing server. Integrates with Nextcloud and FileBrowser
to provide collaborative editing of ODT, DOCX, XLSX, and PPTX files.

## JWT Secret
The JWT secret is stored in \`.env\` (chmod 600). If you rotate it, update:
- Nextcloud: Settings > OnlyOffice > JWT Secret
- Any other integrations using this server

JWT Secret (at install time): see \`JWT_SECRET\` in .env

## Nextcloud Integration
If Nextcloud was running at install time, the OnlyOffice app was auto-configured.
To reconfigure or verify:
\`\`\`bash
docker exec --user www-data nextcloud php occ config:app:get onlyoffice DocumentServerUrl
docker exec --user www-data nextcloud php occ config:app:get onlyoffice jwt_secret
\`\`\`

## FileBrowser Integration
Set \`officeServer: "http://onlyoffice:80/"\` in FileBrowser's config.yaml, then
restart FileBrowser.

## Manage
\`\`\`bash
cd $DIR
docker compose up -d                          # start
docker compose down                           # stop
docker compose logs -f                        # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    echo ""
    echo "  OnlyOffice Document Server"
    echo "  Directory:  $DIR"
    echo "  Port:       8082 (internal: 80)"
    echo "  JWT Secret: $JWT_SECRET"
    echo "  (Secret also saved to $DIR/.env)"
    echo ""
}

# ── Standalone bootstrap ───────────────────────────────────────────────────────
# Run this file directly to install OnlyOffice without the full setup.sh wizard:
#   sudo _RUN_STANDALONE=1 bash services/onlyoffice.sh
if [[ "${_RUN_STANDALONE:-0}" == 1 ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # shellcheck source=../lib/common.sh
    source "$SCRIPT_DIR/../lib/common.sh"
    require_root
    load_site_config 2>/dev/null || true
    install_onlyoffice
fi
