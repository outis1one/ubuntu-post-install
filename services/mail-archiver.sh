#!/bin/bash
# services/mail-archiver.sh — Mail Archiver (IMAP email archive & search).
# Part of the modular post-install system (sourced by setup.sh).
#
# Self-hosted email archive — connects to IMAP accounts, indexes messages,
# and provides full-text search. No big-tech email required.
# Image: s1t5/mailarchiver  DB: postgres:17-alpine

register_service mail-archiver utilities "IMAP email archive & search (Mail Archiver)" 5000

install_mail-archiver() {
    require_docker || return 1
    log_info "Installing Mail Archiver..."
    local MA_DIR="$DOCKER_DIR/mail-archiver"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $MA_DIR (mailarchiver_database/)"
        echo "[DRY-RUN] Would deploy s1t5/mailarchiver:latest + postgres:17-alpine"
        echo "[DRY-RUN] Accessed via Caddy reverse proxy (no direct host port)"
        echo "[DRY-RUN] Would generate DB and admin passwords"
        return 0
    fi

    mkdir -p "$MA_DIR/mailarchiver_database"
    ensure_docker_dir_ownership "$MA_DIR"
    cd "$MA_DIR" || return 1

    local DB_PASS ADMIN_PASS TZ_VAL
    DB_PASS=$(generate_password 32)
    ADMIN_PASS=$(generate_password 24)
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    cat > docker-compose.yml << 'MA_COMPOSE'
name: mail-archiver

services:
  mailarchiver-app:
    image: s1t5/mailarchiver:latest
    container_name: mailarchiver-app
    hostname: mailarchiver-app
    restart: unless-stopped
    env_file: .env
    expose:
      - "5000"
    depends_on:
      mailarchiver-db:
        condition: service_healthy
    networks:
      - caddy_net

  mailarchiver-db:
    image: postgres:17-alpine
    container_name: mailarchiver-db
    hostname: mailarchiver-db
    restart: unless-stopped
    env_file: .env
    expose:
      - "5432"
    volumes:
      - ./mailarchiver_database:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U mailuser -d MailArchiver"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
MA_COMPOSE

    cat > .env << MA_ENV
# ── General ───────────────────────────────────────────────────────────────────
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# ── Database connection (app → postgres) ──────────────────────────────────────
ConnectionStrings__DefaultConnection=Host=mailarchiver-db;Database=MailArchiver;Username=mailuser;Password=$DB_PASS;

# ── Web authentication ────────────────────────────────────────────────────────
Authentication__Enabled=true
Authentication__Username=admin
Authentication__Password=$ADMIN_PASS
Authentication__SessionTimeoutMinutes=60
Authentication__CookieName=MailArchiverAuth

# ── Mail sync schedule ────────────────────────────────────────────────────────
MailSync__IntervalMinutes=15
MailSync__TimeoutMinutes=60
MailSync__ConnectionTimeoutSeconds=180
MailSync__CommandTimeoutSeconds=300

# ── Batch restore limits ──────────────────────────────────────────────────────
BatchRestore__AsyncThreshold=50
BatchRestore__MaxSyncEmails=150
BatchRestore__MaxAsyncEmails=50000
BatchRestore__SessionTimeoutMinutes=30
BatchRestore__DefaultBatchSize=50

# ── Postgres tuning ───────────────────────────────────────────────────────────
Npgsql__CommandTimeout=600

# ── Postgres container ────────────────────────────────────────────────────────
POSTGRES_DB=MailArchiver
POSTGRES_USER=mailuser
POSTGRES_PASSWORD=$DB_PASS
MA_ENV

    chmod 600 .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MA_DIR"
    log_success "Mail Archiver configured at $MA_DIR"

    configure_caddy_for_service "Mail Archiver" "mailarchiver-app:5000" "mail"

    write_readme "$MA_DIR" << MD
# Mail Archiver

Self-hosted IMAP email archive and full-text search.
Add your IMAP mail accounts through the web UI — Mail Archiver will pull
and index all messages, then let you search the full archive.

## Access
- URL: via Caddy reverse proxy (no direct host port)
- Login: admin / (see .env Authentication__Password)

## Adding mail accounts
1. Open the web UI → Settings → Mail Accounts
2. Add IMAP server, username, and password
3. Mail Archiver syncs every \`MailSync__IntervalMinutes\` minutes (default: 15)

## Credentials
Stored in \`.env\` (chmod 600):
- Web admin password: \`Authentication__Password\`
- DB password:        \`POSTGRES_PASSWORD\`

## Manage
\`\`\`bash
cd $MA_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`
MD

    local START_MA=""
    prompt_yn "Start Mail Archiver now? (y/n):" "y" START_MA
    if [ "$START_MA" = "y" ] || [ "$START_MA" = "Y" ]; then
        docker compose up -d \
            && log_success "Mail Archiver started" \
            || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Admin login:  admin / $(grep Authentication__Password .env | cut -d= -f2)"
    echo "  Add IMAP accounts via the web UI after starting."
    echo ""
}
