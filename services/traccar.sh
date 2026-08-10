#!/bin/bash
# services/traccar.sh — GPS tracking server (Traccar).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash traccar.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- TRACCAR ----).
# Own ~/docker/traccar/ with a standalone docker-compose.yml + config XML.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() {
            command -v docker &>/dev/null || {
                log_error "Docker not found. Install it first:"
                log_error "  curl -fsSL https://get.docker.com | sudo sh"
                return 1
            }
            docker compose version &>/dev/null || {
                log_error "Docker Compose plugin missing:"
                log_error "  sudo apt-get install -y docker-compose-plugin"
                return 1
            }
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        port_in_use() {
            local _port="$1" _proto="${2:-tcp}"
            local _flag="-tlnH"
            [ "$_proto" = "udp" ] && _flag="-ulnH"
            ss "$_flag" "sport = :${_port}" 2>/dev/null | grep -q .
        }

        find_free_port() {
            local _varname="$1" _port="$2" _proto="${3:-tcp}"
            while port_in_use "$_port" "$_proto"; do
                _port=$((_port + 1))
            done
            eval "$_varname='$_port'"
        }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            # Determine mode: local Caddy, remote Caddy, or none
            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            # Domain prompt — pre-fill from SITE_DOMAIN when available
            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Build upstream — remote Caddy uses host IP:port, not container name
            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK
)"

            if [[ "$_mode" == "local" ]]; then
                if [[ -f "$_caddyfile" ]]; then
                    local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                    cp "$_caddyfile" "$_bk"
                    log_info "Backed up Caddyfile to $(basename "$_bk")"
                else
                    touch "$_caddyfile"
                fi

                if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                    log_warning "$_domain already in Caddyfile"
                    local _ow=""
                    read -r -p "  Overwrite? [y/N]: " _ow
                    [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                    sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
                fi

                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
        }
        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service traccar utilities "GPS tracking server — phones, vehicles, assets (Traccar)" 8082

install_traccar() {
    require_docker || return 1

    # ── Instance selection ───────────────────────────────────────────────────
    # First instance keeps the plain "traccar" name/paths/ports exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces suffixed naming — same pattern as
    # services/mattermost.sh and services/wordpress.sh.
    #
    # The device-protocol port range is the one thing that can't just be
    # auto-scanned port-by-port (150+ ports, and the first instance already
    # carves Asterisk's exact ports out of it) — instead each additional
    # instance's whole range shifts by 1000 (6000-6150 for the first extra
    # instance, 7000-7150 for the next, ...), determined by how many
    # traccar/traccar-* directories already exist. Those shifted ranges never
    # land on Asterisk's fixed ports (5038/5060/5061), so no exclusions are
    # needed there the way the first instance needs them.
    local TRACCAR_DIR="$DOCKER_DIR/traccar"
    local INSTANCE_SUFFIX="" CONTAINER="traccar" DB_CONTAINER="traccar-db"
    local AUTOHEAL_CONTAINER="traccar-autoheal" AUTOHEAL_LABEL="autoheal"
    local WEB_PORT="8082"
    local PROTO_MIN=5000 PROTO_MAX=5150

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Traccar would:"
        echo "  - Offer to add a new, separate instance if one already exists"
        echo "  - Create \$DOCKER_DIR/traccar(-<name>) with docker-compose.yml + .env"
        echo "  - Deploy a PostgreSQL database container (Traccar no longer ships H2)"
        echo "  - Point Traccar at it via env vars (CONFIG_USE_ENVIRONMENT_VARIABLES) — no secrets in a config file"
        echo "  - Deploy an autoheal container that restarts Traccar if its healthcheck fails"
        echo "  - Expose port 8082 (web) and 5000-5150 (device protocols; 5038/5060/5061 skipped — Asterisk keeps"
        echo "    priority on those); an additional instance's device-protocol range shifts by 1000 instead"
        echo "  - No default login — register the first account at the web UI, it becomes admin"
        echo "  - Offer optional ntfy push notifications (self-hosted anywhere, or ntfy.sh)"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    if [ -d "$TRACCAR_DIR" ]; then
        echo ""
        echo "  Traccar is already installed at $TRACCAR_DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Traccar instance alongside it (its own"
        echo "       server, database, and device-protocol port range — full isolation)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'fleet-b'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/traccar-$_suffix" ]; then
                    log_warning "traccar-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            TRACCAR_DIR="$DOCKER_DIR/traccar-$_suffix"
            CONTAINER="traccar-$_suffix"
            DB_CONTAINER="traccar-$_suffix-db"
            AUTOHEAL_CONTAINER="traccar-$_suffix-autoheal"
            AUTOHEAL_LABEL="autoheal-traccar-$_suffix"

            # Count existing traccar/traccar-* dirs (this new one isn't
            # created yet, so the first extra instance counts exactly 1
            # existing dir -> offset 1 -> 6000-6150).
            local _existing_count
            _existing_count="$(find "$DOCKER_DIR" -mindepth 1 -maxdepth 1 -name 'traccar*' -type d 2>/dev/null | wc -l)"
            local _offset=$((_existing_count * 1000))
            PROTO_MIN=$((5000 + _offset))
            PROTO_MAX=$((5150 + _offset))

            log_info "New instance: $TRACCAR_DIR (device protocols $PROTO_MIN-$PROTO_MAX)"
        else
            # "Manage that install" on THIS instance — the banner above promises
            # update/fresh/cancel, so actually offer it instead of falling straight
            # through into the same unconditional-overwrite flow as a new install.
            if [[ -f "$TRACCAR_DIR/docker-compose.yml" ]]; then
                local MODE=""
                prompt_reinstall_mode MODE
                case "$MODE" in
                    update)
                        log_info "Refreshing the Traccar image only — existing config, port, and Caddy setup are left as-is."
                        ( cd "$TRACCAR_DIR" && docker compose pull && docker compose up -d ) \
                            && log_success "Traccar image refreshed" \
                            || log_warning "Refresh failed — check: docker compose -f $TRACCAR_DIR/docker-compose.yml logs"
                        return 0
                        ;;
                    cancel)
                        log_info "Leaving the existing install as-is."
                        return 0
                        ;;
                    fresh) ;;  # fall through to the full install flow below
                esac
            fi
        fi
    fi

    # Scan for a free web port unconditionally — not just when adding an
    # explicit additional instance. A plain first install can just as easily
    # collide with an unrelated service that already claimed this default
    # port — see CLAUDE.md's "Port collision avoidance" section. The
    # PROTO_MIN/PROTO_MAX device-protocol range above is a different,
    # directory-count-based mechanism (not an ss scan) and is unaffected.
    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$TRACCAR_DIR"
    # Non-recursive on purpose — a rerun already has a `db/` full of Postgres's
    # own data files, owned by whatever uid the postgres container runs as
    # internally, not $ACTUAL_USER. ensure_docker_dir_ownership's chown -R
    # would reassign all of those to $ACTUAL_USER, and Postgres can't read
    # its own files anymore afterward ("could not open file
    # global/pg_filenode.map: Permission denied") — confirmed live on a
    # rerun. logs/ and data/ get their own chown -R further down instead;
    # db/ is never touched by this script again once created.
    chown "$ACTUAL_USER:$ACTUAL_USER" "$TRACCAR_DIR" 2>/dev/null || true
    cd "$TRACCAR_DIR" || return 1

    # Reuse an existing DB password across reruns instead of generating a new
    # one — the Postgres volume keeps the original password from its first
    # init, so overwriting .env with a fresh one would lock Traccar out.
    local DB_PASS=""
    if [ -f ".env" ]; then
        DB_PASS=$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)
    fi
    [ -n "$DB_PASS" ] || DB_PASS=$(generate_password 32)

    # ── Optional: ntfy push notifications ──────────────────────────────────
    # Traccar has no native ntfy support, but its "SMS" notification channel
    # is really just a generic HTTP webhook (sms.http.* config) under the
    # hood — pointing it at ntfy's JSON publish API instead of a real SMS
    # gateway is a well-known trick. Reuse whatever was configured last time
    # so a rerun (e.g. to pick up an unrelated fix) doesn't silently drop it.
    local _EXISTING_SMS_HTTP_URL="" _EXISTING_NTFY_TOPIC="" _EXISTING_SMS_HTTP_USER=""
    if [ -f ".env" ]; then
        _EXISTING_SMS_HTTP_URL=$(grep '^SMS_HTTP_URL=' .env | cut -d= -f2-)
        _EXISTING_NTFY_TOPIC=$(grep '^# NTFY_TOPIC=' .env | cut -d= -f2-)
        _EXISTING_SMS_HTTP_USER=$(grep '^SMS_HTTP_USER=' .env | cut -d= -f2-)
    fi

    echo ""
    local _ntfy_default_enable="n"
    [ -n "$_EXISTING_SMS_HTTP_URL" ] && _ntfy_default_enable="y"
    local ENABLE_NTFY=""
    prompt_yn "Set up push notifications via ntfy — self-hosted (this box or another server) or public ntfy.sh? (y/n):" "$_ntfy_default_enable" ENABLE_NTFY

    local SMS_HTTP_URL="" NTFY_TOPIC="" SMS_HTTP_USER="" SMS_HTTP_PASSWORD=""
    if [[ "$ENABLE_NTFY" =~ ^[Yy]$ ]]; then
        # Suggest this box's own ntfy install if one exists, but never assume
        # it — the whole point is this can point at any server, anywhere.
        local _default_ntfy_url="$_EXISTING_SMS_HTTP_URL"
        if [ -z "$_default_ntfy_url" ] && [ -d "$DOCKER_DIR/ntfy" ]; then
            if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
                _default_ntfy_url="https://ntfy.${SITE_DOMAIN}"
            else
                _default_ntfy_url="http://localhost:8090"
            fi
        fi
        prompt_text "ntfy server URL (self-hosted here, on another server, or https://ntfy.sh) [${_default_ntfy_url:-required}]:" "$_default_ntfy_url" SMS_HTTP_URL

        if [ -z "$SMS_HTTP_URL" ]; then
            log_warning "No ntfy URL entered — skipping notification setup."
        else
            local _default_topic="${_EXISTING_NTFY_TOPIC:-traccar-$(generate_password 8)}"
            prompt_text "ntfy topic for Traccar alerts [$_default_topic]:" "$_default_topic" NTFY_TOPIC

            local _ntfy_needs_auth="" _default_auth="n"
            [ -n "$_EXISTING_SMS_HTTP_USER" ] && _default_auth="y"
            prompt_yn "Does that ntfy topic require a username/password? (y/n):" "$_default_auth" _ntfy_needs_auth
            if [[ "$_ntfy_needs_auth" =~ ^[Yy]$ ]]; then
                prompt_text "ntfy username [${_EXISTING_SMS_HTTP_USER:-required}]:" "$_EXISTING_SMS_HTTP_USER" SMS_HTTP_USER
                prompt_text "ntfy password:" "" SMS_HTTP_PASSWORD
            fi
        fi
    fi

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh)
    # so this matches whatever Caddy setup the site actually has: an explicit
    # CADDY_MODE from the site config wins, then a local ~/docker/caddy, then
    # the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a remote
    # Caddy box can't resolve container names on this host's bridge network
    # anyway, it reaches Traccar via this host's published 8082 port instead.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_BLOCK=""
    local _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    # First instance keeps the exact existing Asterisk-exclusion port block
    # (5000-5150 with 5038/5060/5061 carved out). An additional instance's
    # range is shifted by 1000 per instance (computed above), which never
    # lands on Asterisk's fixed ports, so it just publishes the plain range
    # with no exclusions needed.
    local _PROTO_PORT_BLOCK
    if [ -z "$INSTANCE_SUFFIX" ]; then
        _PROTO_PORT_BLOCK="      # 5038 (AMI), 5060 (SIP, tcp+udp), and 5061 (SIP TLS, tcp) are skipped:
      # they're Asterisk's ports (services/asterisk.sh runs Asterisk with
      # network_mode: host, so it binds them directly on the host, not
      # through Docker networking). Publishing the full 5000-5150 range here
      # would fight Asterisk for those exact host ports on any box running
      # both services from this repo. Confirmed live: this is what made
      # \"docker network connect caddy_net traccar\" and then a plain
      # \`docker compose up -d\` both fail with \"failed to bind host port
      # 0.0.0.0:5038/tcp\" and then \"...5060/tcp: address already in use\" on
      # a box with Asterisk's PSTN trunk already installed. Checked every
      # other network_mode: host service in this repo (caddy, homeassistant,
      # kyber-server, lyrion, mattermost, watchyourlan, wolf-pair, wolf) —
      # none of them land in 5000-5150, so Asterisk is the only conflict.
      - \"5000-5037:5000-5037\"
      - \"5039-5059:5039-5059\"
      - \"5062-5150:5062-5150\"
      - \"5000-5059:5000-5059/udp\"
      - \"5061-5150:5061-5150/udp\""
    else
        _PROTO_PORT_BLOCK="      # Shifted by 1000 from the default 5000-5150 range so this instance
      # doesn't collide with the first (or any other) Traccar instance on
      # this box — never lands on Asterisk's fixed ports either, so no
      # exclusions are needed here the way the first instance needs them.
      - \"${PROTO_MIN}-${PROTO_MAX}:${PROTO_MIN}-${PROTO_MAX}\"
      - \"${PROTO_MIN}-${PROTO_MAX}:${PROTO_MIN}-${PROTO_MAX}/udp\""
    fi

    cat > docker-compose.yml << TRACCAR_COMPOSE
name: $CONTAINER

services:
  db:
    image: postgres:15-alpine
    container_name: $DB_CONTAINER
    hostname: $DB_CONTAINER
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db:/var/lib/postgresql/data
${_CADDY_NET_BLOCK}    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  traccar:
    image: traccar/traccar:latest
    container_name: $CONTAINER
    hostname: $CONTAINER
    restart: unless-stopped
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
    labels:
      - "${AUTOHEAL_LABEL}=true"
    environment:
      CONFIG_USE_ENVIRONMENT_VARIABLES: "true"
      DATABASE_DRIVER: org.postgresql.Driver
      DATABASE_URL: jdbc:postgresql://${DB_CONTAINER}:5432/\${POSTGRES_DB}?sslmode=disable
      DATABASE_USER: \${POSTGRES_USER}
      DATABASE_PASSWORD: \${POSTGRES_PASSWORD}
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8082/api/health"]
      interval: 2m
      timeout: 5s
      start_period: 1h
      retries: 3
    volumes:
      - ./logs:/opt/traccar/logs:rw
      - ./data:/opt/traccar/data:rw
    ports:
      - "${WEB_PORT}:8082"
${_PROTO_PORT_BLOCK}
${_CADDY_NET_BLOCK}
  autoheal:
    image: willfarrell/autoheal:latest
    container_name: $AUTOHEAL_CONTAINER
    restart: unless-stopped
    environment:
      AUTOHEAL_CONTAINER_LABEL: ${AUTOHEAL_LABEL}
      AUTOHEAL_INTERVAL: 60
      AUTOHEAL_START_PERIOD: 3600
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
${_CADDY_NET_SECTION}
TRACCAR_COMPOSE

    # Traccar's env-var config naming (dots→underscore, camelCase→SCREAMING_
    # SNAKE) already matches these key names exactly, and `traccar`'s
    # env_file: .env passes them straight through — no docker-compose.yml
    # changes needed for this at all. NTFY_TOPIC isn't read by anything; it's
    # a comment purely so a rerun can recall it (see the grep for it above)
    # and so it's easy to find on disk instead of scrolling back through chat.
    local _NTFY_ENV_BLOCK=""
    if [ -n "$SMS_HTTP_URL" ]; then
        _NTFY_ENV_BLOCK="
# ntfy push notifications — piggybacks on Traccar's \"SMS\" channel, which is
# really just a generic HTTP webhook under the hood.
NOTIFICATOR_TYPES=web,sms
SMS_HTTP_URL=$SMS_HTTP_URL
SMS_HTTP_TEMPLATE={\"topic\": \"{phone}\", \"message\": \"{message}\"}
# NTFY_TOPIC=$NTFY_TOPIC
# ^ set this as your Traccar user's Phone field (top-right avatar -> Edit),
# then enable \"SMS\" per event under the notifications bell.
"
        if [ -n "$SMS_HTTP_USER" ]; then
            _NTFY_ENV_BLOCK="${_NTFY_ENV_BLOCK}SMS_HTTP_USER=$SMS_HTTP_USER
SMS_HTTP_PASSWORD=$SMS_HTTP_PASSWORD
"
        fi
    fi

    cat > .env << TRACCAR_ENV
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# PostgreSQL — backs Traccar's database (Traccar's docker image no longer
# bundles the H2 driver, so a real database is required). Traccar reads
# these directly (CONFIG_USE_ENVIRONMENT_VARIABLES in docker-compose.yml)
# instead of a config file, so this is the only place the credentials live.
POSTGRES_DB=traccar
POSTGRES_USER=traccar
POSTGRES_PASSWORD=$DB_PASS
${_NTFY_ENV_BLOCK}
TRACCAR_ENV
    chmod 600 .env

    mkdir -p logs data db

    # db/ is deliberately excluded — see the comment on the earlier chown.
    chown "$ACTUAL_USER:$ACTUAL_USER" "$TRACCAR_DIR" docker-compose.yml .env
    chown -R "$ACTUAL_USER:$ACTUAL_USER" logs data
    log_success "Traccar${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} configured at $TRACCAR_DIR (port $WEB_PORT)"

    configure_caddy_for_service "Traccar${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${CONTAINER}:8082" "traccar${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"

    local _NTFY_README_BLOCK=""
    if [ -n "$SMS_HTTP_URL" ]; then
        _NTFY_README_BLOCK="
## Push notifications (ntfy)
Traccar has no native ntfy support — this uses its \"SMS\" channel as a
generic HTTP webhook pointed at ntfy's publish API instead of a real SMS
gateway. Configured in \`.env\`: \`SMS_HTTP_URL\`, \`SMS_HTTP_TEMPLATE\`
(and \`SMS_HTTP_USER\`/\`SMS_HTTP_PASSWORD\` if that topic needs auth).

- ntfy server: $SMS_HTTP_URL
- Topic: $NTFY_TOPIC — set this as your Traccar user's Phone field
  (top-right avatar → Edit)
- Enable \"SMS\" as a channel for whichever events you want, under the
  notifications bell — the UI still calls it \"SMS\", that's just the label.
- Subscribe to the topic in the ntfy app to receive them.
"
    fi

    write_readme "$TRACCAR_DIR" << MD
# Traccar${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

GPS tracking server. Track phones, vehicles, and assets via the Traccar
Android/iOS app, OwnTracks, or any of 200+ supported device protocols.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "
This is a separate, fully isolated instance (own server, own database, own
device-protocol port range) — not shared tracking data with another
Traccar instance.")

- Web UI: http://localhost:${WEB_PORT}
- No default login — Traccar ships with no built-in account. Open the web UI
  and register the first user; it's automatically made admin. Self-registration
  stays open to anyone who reaches this server until you turn it off, so do
  this right away, then go to Settings → Server → Permissions and uncheck
  Registration.
- Device protocols: ports ${PROTO_MIN}-${PROTO_MAX} (TCP + UDP$( [ -z "$INSTANCE_SUFFIX" ] && echo "; 5038/tcp, 5060/tcp+udp, and 5061/tcp are skipped — reserved for Asterisk's AMI and SIP if this box also runs Asterisk from this repo, which gets priority on those ports"))
- App data: \`data/\` and \`logs/\`
- Database: PostgreSQL (\`$DB_CONTAINER\` container, data in \`db/\`)
- All database settings (name, user, password) live in \`.env\` — Traccar
  reads them directly via env vars, nothing is duplicated in a config file.
  Change the password there (then recreate both containers) if you need to
  rotate it.
- Autoheal: \`$AUTOHEAL_CONTAINER\` restarts the \`$CONTAINER\` container if its healthcheck fails (scoped to this instance only via the \`$AUTOHEAL_LABEL\` label — it won't touch any other Traccar instance's container)
${_NTFY_README_BLOCK}
## Manage
\`\`\`bash
cd $TRACCAR_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Mobile apps
- Traccar Client (Android/iOS): set server to \`http://YOUR-IP:${WEB_PORT}\`
- OwnTracks (Android/iOS): configure HTTP endpoint to Traccar
MD

    local START_TRACCAR=""
    prompt_yn "Start Traccar${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} now? (y/n):" "y" START_TRACCAR
    if [ "$START_TRACCAR" = "y" ] || [ "$START_TRACCAR" = "Y" ]; then
        docker compose up -d && log_success "Traccar${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)} started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:${WEB_PORT}"
    echo "  No default login — register the first account now; it becomes admin."
    echo "  Then disable further registration: Settings → Server → Permissions."
    if [ -n "$SMS_HTTP_URL" ]; then
        echo ""
        echo "  ntfy notifications: set your user's Phone field to '$NTFY_TOPIC'"
        echo "  (top-right avatar → Edit), then enable \"SMS\" per event under the bell."
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_traccar
