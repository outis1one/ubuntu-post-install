#!/bin/bash
# services/mattermost.sh — Team messaging with voice/video calls (Mattermost + coturn).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash mattermost.sh
# (Docker must already be installed when run standalone)

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
        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

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

            # Remote Caddy support: if CADDY_REMOTE_HOST is set, operate on the
            # remote machine via SSH instead of the local filesystem.
            if [[ -n "${CADDY_REMOTE_HOST:-}" ]]; then
                echo ""
                local _do_caddy=""
                read -r -p "  Configure Caddy reverse proxy for $_name on $CADDY_REMOTE_HOST? [y/N]: " _do_caddy
                [[ "${_do_caddy,,}" == "y" ]] || {
                    log_info "Skipping — access at: http://$(hostname -I | awk '{print $1}'):${_upstream##*:}"
                    return 0
                }

                local _domain=""
                read -r -p "  Domain (e.g. ${_subdomain}.${SITE_DOMAIN:-example.com}): " _domain
                [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

                local _block
                _block="$(cat << CBLOCK

# $_name
$_domain {
    reverse_proxy $_upstream

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
                echo "$_block" | ssh "$CADDY_REMOTE_HOST" "cat >> $_caddyfile"
                ssh "$CADDY_REMOTE_HOST" "docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true"
                if ssh "$CADDY_REMOTE_HOST" "docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null"; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: ssh $CADDY_REMOTE_HOST docker logs caddy"
                fi
                return 0
            fi

            if [[ ! -d "$_caddy_dir" ]]; then
                log_info "Access $_name directly on port ${_upstream##*:}."
                return 0
            fi

            echo ""
            local _do_caddy=""
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:${_upstream##*:}"
                return 0
            }

            local _domain=""
            read -r -p "  Domain (e.g. ${_subdomain}.${SITE_DOMAIN:-example.com}): " _domain
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Back up before touching
            if [[ -f "$_caddyfile" ]]; then
                local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                cp "$_caddyfile" "$_bk"
                log_info "Backed up Caddyfile to $(basename "$_bk")"
            else
                touch "$_caddyfile"
            fi

            # Remove existing block for this domain if present
            if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                log_warning "$_domain already in Caddyfile"
                local _ow=""
                read -r -p "  Overwrite? [y/N]: " _ow
                [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
            fi

            cat >> "$_caddyfile" << CBLOCK

# $_name
$_domain {
    reverse_proxy $_upstream

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

            log_success "Added $_domain to Caddyfile"
            docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
            if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                log_success "$_name accessible at: https://$_domain"
            else
                log_warning "Reload failed — check: docker logs caddy"
                log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
            fi
        }

        write_readme() {
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service mattermost utilities "Team messaging with voice/video calls (Mattermost; TURN via the shared coturn service); supports multiple isolated instances" 8065

install_mattermost() {
    require_docker || return 1

    # ── Instance selection ──────────────────────────────────────────────────
    # First instance keeps the plain "mattermost" name/paths/ports exactly as
    # before (zero behavior change for anyone with a single instance). Only
    # asking to add a second one introduces the suffixed naming.
    local DIR="$DOCKER_DIR/mattermost"
    local INSTANCE_SUFFIX="" PROJECT="mattermost"
    local MM_CONTAINER="mattermost" DB_CONTAINER="mattermost-db"
    local WEB_PORT="8065" CALLS_UDP_PORT="8443"
    local COTURN_CONSUMER="mattermost"

    if [ -d "$DIR" ]; then
        echo ""
        echo "  Mattermost is already installed at $DIR."
        echo "    1) Manage that install (update / full reinstall / cancel)"
        echo "    2) Add a NEW, separate Mattermost instance alongside it (its own"
        echo "       server, database, and TURN credential — full isolation, not Teams)"
        echo ""
        local _TOP_CHOICE=""
        prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
        if [ "$_TOP_CHOICE" = "2" ]; then
            local _suffix=""
            while true; do
                prompt_text "  Short name for the new instance (letters/numbers/hyphens, e.g. 'team-b'):" "" _suffix
                _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
                if [ -z "$_suffix" ]; then
                    log_warning "Name can't be empty."; continue
                fi
                if [ -d "$DOCKER_DIR/mattermost-$_suffix" ]; then
                    log_warning "mattermost-$_suffix already exists — pick another name."; continue
                fi
                break
            done
            INSTANCE_SUFFIX="$_suffix"
            DIR="$DOCKER_DIR/mattermost-$_suffix"
            PROJECT="mattermost-$_suffix"
            MM_CONTAINER="mattermost-$_suffix"
            DB_CONTAINER="mattermost-$_suffix-db"
            COTURN_CONSUMER="mattermost-$_suffix"
            log_info "New instance: $DIR"
        fi
    fi

    # WEB_PORT/CALLS_UDP_PORT are resolved further down, after we know
    # whether this is an update (read the existing port back, never rescan
    # — see the comment there) or a fresh/new install (scan from these
    # defaults). Scanning here, before that's known, used to mean an
    # update run could see this instance's OWN currently-published port as
    # "in use" and silently move it — see git history on this block.

    log_info "Installing Mattermost${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml"
        echo "[DRY-RUN] Would write .env with DB and Mattermost secrets"
        echo "[DRY-RUN] Would create data/ logs/ config/ plugins/ db/ subdirectories"
        echo "[DRY-RUN] Would register a TURN user with the shared coturn service for '$COTURN_CONSUMER'"
        echo "[DRY-RUN]   (falling back to a dedicated coturn if the shared service is unavailable)"
        echo "[DRY-RUN] Would open UFW ports ${WEB_PORT}/tcp, ${CALLS_UDP_PORT}/udp"
        return 0
    fi

    # ── Existing install (this exact instance)? Offer update-in-place ───────
    local MODE="fresh"
    local _HAD_EMBEDDED_COTURN=false
    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        prompt_reinstall_mode MODE
        grep -q '^  coturn:' "$DIR/docker-compose.yml" 2>/dev/null && _HAD_EMBEDDED_COTURN=true
        case "$MODE" in
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh)
                if [ "$_HAD_EMBEDDED_COTURN" = true ]; then
                    echo ""
                    log_warning "This install has its own dedicated coturn. Continuing may switch it to"
                    log_warning "the shared coturn service — the Calls plugin's TURN config in System"
                    log_warning "Console will need updating to the new credentials afterward (see below)."
                fi
                echo ""
                log_warning "Full reinstall stops the existing containers and re-runs every prompt"
                log_warning "below from scratch. The TURN credential registered with the shared"
                log_warning "coturn service is reused as-is — no need to touch coturn for this."
                local _WIPE_MM_DATA=""
                prompt_yn "  Also delete stored data (Postgres database, uploaded files, config, plugins)? (y/n):" "n" _WIPE_MM_DATA

                log_info "Stopping the existing containers..."
                (cd "$DIR" && docker compose down 2>/dev/null)

                if [[ "$_WIPE_MM_DATA" =~ ^[Yy]$ ]]; then
                    rm -rf "$DIR/db" "$DIR/data" "$DIR/logs" "$DIR/config" "$DIR/plugins"
                    log_warning "Deleted the Postgres database, uploaded files, config, and plugins."
                fi
                ;;
        esac
    fi

    # ── Web/Calls ports: read back on update, scan fresh on a new/full install ──
    # Mirrors services/asterisk.sh's WEB_ADMIN_PORT handling: update must
    # never rescan here — nothing has stopped the currently-running
    # container yet at this point (fresh/"Full reinstall" already did,
    # above), so find_free_port would see this instance's OWN
    # already-published port as "in use" and silently move it to a
    # different one on every single update run. Falls back to parsing the
    # existing MM_SERVICESETTINGS_LISTENADDRESS / docker-compose.yml port
    # mapping for installs from before WEB_PORT/CALLS_UDP_PORT were written
    # to .env directly — so this doesn't regress anyone already running.
    if [ "$MODE" = "update" ] && [ -f "$DIR/.env" ]; then
        local _EXISTING_WEB_PORT _EXISTING_CALLS_PORT
        _EXISTING_WEB_PORT="$(grep '^WEB_PORT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
        [ -z "$_EXISTING_WEB_PORT" ] && _EXISTING_WEB_PORT="$(grep '^MM_SERVICESETTINGS_LISTENADDRESS=:' "$DIR/.env" 2>/dev/null | sed 's/.*://')"
        [ -n "$_EXISTING_WEB_PORT" ] && WEB_PORT="$_EXISTING_WEB_PORT"

        _EXISTING_CALLS_PORT="$(grep '^CALLS_UDP_PORT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
        [ -z "$_EXISTING_CALLS_PORT" ] && _EXISTING_CALLS_PORT="$(grep -oE '"[0-9]+:8443/udp"' "$DIR/docker-compose.yml" 2>/dev/null | head -1 | cut -d: -f1 | tr -d '"')"
        [ -n "$_EXISTING_CALLS_PORT" ] && CALLS_UDP_PORT="$_EXISTING_CALLS_PORT"
    else
        # Fresh/new install — runs unconditionally, not just when adding an
        # explicit additional instance, so a plain first install also can't
        # collide with an unrelated service that already claimed these
        # default ports. WEB_PORT is also set as Mattermost's own internal
        # ListenAddress below (not just the host publish side), so
        # configure_caddy_for_service's single upstream "name:port" string
        # works unmodified in both local and remote-Caddy mode — it assumes
        # host-published-port == container-internal-port, true for every
        # other service in this repo and made true here too rather than
        # special-casing the shared helper for one caller. See CLAUDE.md's
        # "Port collision avoidance" section.
        find_free_port WEB_PORT "$WEB_PORT"
        find_free_port CALLS_UDP_PORT "$CALLS_UDP_PORT" udp
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # Reuse existing secrets whenever the Postgres data volume already has
    # real data in it — not just when MODE=update. Confirmed live: picking
    # "fresh" after removing only the mattermost APP container (docker rm,
    # not the whole ~/docker/mattermost directory) regenerates
    # POSTGRES_PASSWORD in a new .env while db/ still holds the OLD
    # password baked in from its first init (postgres:15-alpine's
    # entrypoint skips re-initializing an existing data directory, so the
    # old credential is still the one actually enforced) — "password
    # authentication failed for user mattermost" on every start
    # afterward. Whether the data volume already has real data in it is
    # what actually determines whether the old password is still live,
    # not which reinstall mode was chosen.
    local DB_PASS="" MM_SECRET=""
    local _db_has_data=false
    [ -d db ] && [ -n "$(ls -A db 2>/dev/null)" ] && _db_has_data=true
    if [ "$MODE" = "update" ] || [ "$_db_has_data" = true ]; then
        DB_PASS="$(grep '^POSTGRES_PASSWORD=' .env 2>/dev/null | cut -d= -f2-)"
        [ "$_HAD_EMBEDDED_COTURN" = true ] && MM_SECRET="$(grep '^COTURN_SECRET=' .env 2>/dev/null | cut -d= -f2-)"
    fi
    [ -n "$DB_PASS" ] || DB_PASS=$(generate_password 32)

    local TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

    # Compute SITE_URL — extra instances default to a distinct subdomain so
    # they don't collide with the first instance's.
    local _default_subdomain="mattermost${INSTANCE_SUFFIX:+-$INSTANCE_SUFFIX}"
    local SITE_URL="http://localhost:${WEB_PORT}"
    if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        SITE_URL="https://${_default_subdomain}.${SITE_DOMAIN}"
    fi
    local CONFIGURED_SITEURL=""
    prompt_text "Mattermost site URL [$SITE_URL]:" "$SITE_URL" CONFIGURED_SITEURL
    [[ -n "$CONFIGURED_SITEURL" ]] && SITE_URL="$CONFIGURED_SITEURL"

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
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

    # ── TURN: shared coturn preferred, dedicated coturn as fallback ─────────
    # See services/coturn.sh's header for why one shared TURN server beats
    # every service (Asterisk, each Mattermost instance, ...) running its
    # own and fighting over host relay ports.
    local USE_EMBEDDED_COTURN=true
    local TURN_HOST_VAL="" TURN_PORT_VAL="" TURN_USERNAME_VAL="" TURN_PASSWORD_VAL=""

    if [ "$MODE" = "update" ] && [ "$_HAD_EMBEDDED_COTURN" = true ]; then
        USE_EMBEDDED_COTURN=true   # preserve exactly — never switch on update
    else
        ensure_coturn_user "$COTURN_CONSUMER"
        if [ -n "${COTURN_HOST:-}" ]; then
            USE_EMBEDDED_COTURN=false
            TURN_HOST_VAL="$COTURN_HOST"; TURN_PORT_VAL="$COTURN_PORT"
            TURN_USERNAME_VAL="$COTURN_USERNAME"; TURN_PASSWORD_VAL="$COTURN_PASSWORD"
            log_success "Using the shared coturn service — TURN username '$COTURN_USERNAME'."
        else
            log_info "Shared coturn unavailable — this instance will run its own dedicated coturn."
        fi
    fi
    [ -n "$MM_SECRET" ] || MM_SECRET=$(generate_password 48)

    # Each embedded-coturn instance (this Mattermost falls back to its own
    # dedicated coturn when the shared one isn't available) needs its own
    # listening port and relay range, or two instances both on embedded
    # coturn collide on identical fixed numbers — confirmed live for the
    # Asterisk-vs-Mattermost case this same offset scheme now also fixes
    # (see the git history on this block). A relay range can't be found by
    # scanning port-by-port like find_free_port does for a single port
    # (CLAUDE.md's port-collision-avoidance section is explicit about this
    # for large ranges) — so instead each instance gets an integer "slot"
    # or the next one already used elsewhere, and a wide-enough width
    # (200, matching this range's existing size) keeps slots from
    # overlapping each other. base 3479/49253 is right after Asterisk's own
    # embedded-coturn numbers (3478/49152-49252) so slot 0 doesn't collide
    # with Asterisk either.
    #
    # The slot is assigned once (the smallest integer not already claimed
    # by another mattermost*/.env on this box) and cached in THIS
    # instance's own .env as EMBEDDED_COTURN_SLOT, so re-running this same
    # instance's installer (update or full reinstall) always reads the
    # same slot back instead of potentially reassigning it — reassignment
    # would silently move an already-configured instance's TURN port out
    # from under it.
    local EMBEDDED_COTURN_SLOT=""
    [ -f "$DIR/.env" ] && EMBEDDED_COTURN_SLOT="$(grep '^EMBEDDED_COTURN_SLOT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
    if [ -z "$EMBEDDED_COTURN_SLOT" ]; then
        # Assigning a NEW slot — also live-verify the candidate control port
        # and relay-range boundaries aren't already bound by something this
        # box's own .env files don't know about (a manually-run process, an
        # unrelated service). An already-cached slot (the branch above) is
        # trusted as-is and never re-verified — that's what "stable across
        # re-runs" means; a live process squatting on an already-assigned
        # slot's port is a conflict to report, not silently route around by
        # moving an already-configured instance. Can't scan the full
        # 200-port relay range port-by-port (CLAUDE.md's
        # port-collision-avoidance section covers why large ranges use an
        # offset instead of scanning) — checking the control port plus the
        # relay range's own two boundary ports is the practical middle
        # ground between "no live check at all" and a full range scan.
        local _used_slots _cand _p _min _max
        _used_slots="$(grep -h '^EMBEDDED_COTURN_SLOT=' "$DOCKER_DIR"/mattermost*/.env 2>/dev/null | cut -d= -f2-)"
        _cand=0
        while true; do
            _p=$((3479 + _cand)); _min=$((49253 + _cand * 200)); _max=$((_min + 199))
            if echo "$_used_slots" | grep -qx "$_cand" \
               || port_in_use "$_p" || port_in_use "$_p" udp \
               || port_in_use "$_min" udp || port_in_use "$_max" udp; then
                _cand=$((_cand + 1))
                continue
            fi
            break
        done
        EMBEDDED_COTURN_SLOT="$_cand"
    fi
    local _MM_COTURN_PORT=$((3479 + EMBEDDED_COTURN_SLOT))
    local _MM_COTURN_MIN=$((49253 + EMBEDDED_COTURN_SLOT * 200))
    local _MM_COTURN_MAX=$((_MM_COTURN_MIN + 199))

    local _COTURN_SERVICE=""
    if [ "$USE_EMBEDDED_COTURN" = true ]; then
        _COTURN_SERVICE="
  coturn:
    image: coturn/coturn:latest
    container_name: ${MM_CONTAINER}-coturn
    network_mode: host
    user: root
    command:
      - -n
      - --listening-port=${_MM_COTURN_PORT}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --use-auth-secret
      - --static-auth-secret=\${COTURN_SECRET}
      - --realm=\${MM_REALM:-localhost}
      - --min-port=${_MM_COTURN_MIN}
      - --max-port=${_MM_COTURN_MAX}
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped
"
    fi

    cat > docker-compose.yml << EOF
name: ${PROJECT}

services:
  db:
    image: postgres:15-alpine
    container_name: ${DB_CONTAINER}
    hostname: ${DB_CONTAINER}
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./db:/var/lib/postgresql/data
${_CADDY_NET_BLOCK}    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 5

  # Fixes ownership on the bind-mounted volumes below to the fixed UID/GID
  # (2000) mattermost/mattermost-team-edition runs as, before the mattermost
  # service starts — every time, not just at install time. Confirmed live:
  # importing data from another host (e.g. a PikaPods migration) can leave
  # these owned by whatever UID did the copy instead of 2000, and the
  # container doesn't fix this itself on start the way postgres's official
  # image does — it just fails every file write with "permission denied"
  # until someone notices and runs chown by hand. This removes the "by
  # hand" part permanently: runs on every `docker compose up`, including a
  # plain host reboot, so ownership drift from any future cause self-heals
  # without needing this installer re-run again.
  mattermost-fix-perms:
    image: busybox:latest
    container_name: ${MM_CONTAINER}-fix-perms
    command: sh -c "chown -R 2000:2000 /data /logs /config /plugins"
    volumes:
      - ./data:/data
      - ./logs:/logs
      - ./config:/config
      - ./plugins:/plugins
    restart: "no"

  mattermost:
    image: mattermost/mattermost-team-edition:latest
    container_name: ${MM_CONTAINER}
    hostname: ${MM_CONTAINER}
    restart: unless-stopped
    env_file: .env
    depends_on:
      db:
        condition: service_healthy
      mattermost-fix-perms:
        condition: service_completed_successfully
    volumes:
      - ./data:/mattermost/data
      - ./logs:/mattermost/logs
      - ./config:/mattermost/config
      - ./plugins:/mattermost/plugins
    ports:
      - "${WEB_PORT}:${WEB_PORT}"
      - "${CALLS_UDP_PORT}:8443/udp"
${_CADDY_NET_BLOCK}${_COTURN_SERVICE}${_CADDY_NET_SECTION}
EOF

    cat > .env << EOF
TZ=$TZ_VAL
CADDY_NET=$SITE_CADDY_NET

# Host-published ports this install is actually using — read back on every
# Update run (see the WEB_PORT/CALLS_UDP_PORT resolution above
# install_mattermost's mkdir) instead of rescanning while this instance's
# own container is still up.
WEB_PORT=$WEB_PORT
CALLS_UDP_PORT=$CALLS_UDP_PORT

# PostgreSQL
POSTGRES_DB=mattermost
POSTGRES_USER=mattermost
POSTGRES_PASSWORD=$DB_PASS

# Mattermost
MM_SQLSETTINGS_DRIVERNAME=postgres
MM_SQLSETTINGS_DATASOURCE=postgres://mattermost:${DB_PASS}@${DB_CONTAINER}:5432/mattermost?sslmode=disable&connect_timeout=10
MM_SERVICESETTINGS_SITEURL=$SITE_URL
MM_SERVICESETTINGS_LISTENADDRESS=:${WEB_PORT}
MM_SERVICESETTINGS_ENABLELOCALMODE=true
MM_FILESETTINGS_DRIVERNAME=local
MM_PLUGINSETTINGS_ENABLE=true

# ── TURN/STUN (Calls plugin) ─────────────────────────────────
$( [ "$USE_EMBEDDED_COTURN" = true ] \
    && echo "# This instance runs its own dedicated coturn (the coturn: service in docker-compose.yml)." \
    || echo "# Using the shared coturn service — see ~/docker/coturn/README.md." )
# coturn HMAC secret — only used if this instance runs its own dedicated coturn.
COTURN_SECRET=$MM_SECRET
MM_REALM=${SITE_DOMAIN:-localhost}
TURN_HOST=$TURN_HOST_VAL
TURN_PORT=$TURN_PORT_VAL
TURN_USERNAME=$TURN_USERNAME_VAL
TURN_PASSWORD=$TURN_PASSWORD_VAL
# This instance's embedded-coturn port slot (see the comment above the
# EMBEDDED_COTURN_SLOT assignment in mattermost.sh) — read back on every
# re-run so it never gets reassigned out from under an already-running
# instance. Reserved even when USE_EMBEDDED_COTURN is currently false, in
# case this instance ever falls back to its own coturn later.
EMBEDDED_COTURN_SLOT=$EMBEDDED_COTURN_SLOT
EOF
    chmod 600 .env

    mkdir -p data logs config plugins db
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"
    # mattermost/mattermost-team-edition's image runs as a fixed UID/GID
    # 2000 baked in at build time — unlike some other images in this repo,
    # it does NOT read PUID/PGID env vars (that's a LinuxServer.io s6-overlay
    # convention this image doesn't use; a previous version of this file set
    # them anyway, which did nothing). Confirmed live: leaving ./data,
    # ./logs, ./config, ./plugins owned by ACTUAL_USER instead of 2000:2000
    # makes the container fail on its very first start with "could not
    # create config file: open /mattermost/config/config.json: permission
    # denied" and crash-loop — db (postgres:15-alpine) isn't affected, its
    # entrypoint fixes ownership itself on startup when it needs to.
    chown -R 2000:2000 data logs config plugins

    # ── Firewall ─────────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow "${WEB_PORT}/tcp" comment "Mattermost${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}"
        ufw allow "${CALLS_UDP_PORT}/udp" comment "Mattermost Calls RTC${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}"
        if [ "$USE_EMBEDDED_COTURN" = true ]; then
            ufw allow "${_MM_COTURN_PORT}/udp"; ufw allow "${_MM_COTURN_PORT}/tcp"
            ufw allow "${_MM_COTURN_MIN}:${_MM_COTURN_MAX}/udp" comment "Mattermost coturn relay${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}"
        fi
        # Shared coturn opens its own ports once, at its own install time.
    fi

    echo ""
    log_success "Mattermost configured at $DIR"

    configure_caddy_for_service "Mattermost${INSTANCE_SUFFIX:+ ($INSTANCE_SUFFIX)}" "${MM_CONTAINER}:${WEB_PORT}" "$_default_subdomain"

    # Exact ICEServersConfigs JSON to paste into System Console — verified
    # against the Calls plugin's actual config schema (plugin.json): this
    # field takes a fixed username/credential pair, which is what a
    # --lt-cred-mech coturn (shared or dedicated) expects, as opposed to the
    # "TURN Static Auth Secret" field (HMAC/REST-API mode, which coturn
    # cannot run at the same time as --lt-cred-mech on one instance).
    local _ICE_JSON _turn_config_md
    if [ "$USE_EMBEDDED_COTURN" = true ]; then
        _ICE_JSON="[{\"urls\":[\"turn:${SITE_DOMAIN:-YOUR_IP}:${_MM_COTURN_PORT}?transport=udp\"],\"username\":\"static\",\"credential\":\"see COTURN_SECRET below — this dedicated coturn uses use-auth-secret/HMAC, not a fixed credential\"}]"
        _turn_config_md="This instance runs its own dedicated coturn (HMAC/REST-API auth):
- TURN Server URI: \`turn:${SITE_DOMAIN:-YOUR_IP}:${_MM_COTURN_PORT}?transport=udp\`
- System Console → Plugins → Calls → **TURN Static Auth Secret**: value of \`COTURN_SECRET\` in \`.env\`"
    else
        _ICE_JSON="[{\"urls\":[\"turn:${TURN_HOST_VAL}:${TURN_PORT_VAL}?transport=udp\"],\"username\":\"${TURN_USERNAME_VAL}\",\"credential\":\"${TURN_PASSWORD_VAL}\"}]"
        _turn_config_md="This instance uses the shared coturn service (fixed username/credential, not HMAC):
- System Console → Plugins → Calls → **ICE Servers Configurations** — paste:
\`\`\`json
$_ICE_JSON
\`\`\`
- Leave **TURN Static Auth Secret** empty — that field is for the OTHER auth
  mode coturn supports and doesn't apply here."
    fi
    [ "${CALLS_UDP_PORT}" != "8443" ] && _turn_config_md="$_turn_config_md
- System Console → Plugins → Calls → **ICE Host Port Override**: \`${CALLS_UDP_PORT}\` (this instance publishes Calls RTC on a non-default port)"

    write_readme "$DIR" << MD
# Mattermost${INSTANCE_SUFFIX:+ — $INSTANCE_SUFFIX}

Team messaging with voice/video calls. PostgreSQL backend.
$( [ -n "$INSTANCE_SUFFIX" ] && echo "

This is a separate, fully isolated instance (own server, own database, own
TURN credential) — not a Team within another instance. See that instance's
own README for its own access details." )

## Access
- URL: $SITE_URL (or http://localhost:${WEB_PORT})
- First run: create admin account at the URL above — this account becomes
  System Admin automatically.

## Teams
Team Edition (the free edition this installer uses) includes multiple Teams
natively — separate spaces (their own channels, their own members) on the
same server, same database, same login. No Enterprise license needed; this
is the resource-efficient alternative to running a second Mattermost
instance for a second group.

Create one:
- Click the **+** at the bottom of the team sidebar (the narrow column on
  the far left) → **Create a new team**, or
- System Console → User Management → Teams → **Create Team**

Add people to a team:
- Team name (top-left) → **Invite People** → share the invite link, or send
  email invites (requires SMTP — System Console → Environment → SMTP), or
- System Console → User Management → Teams → the team → **Add Members**
  (adds existing server accounts directly, no invite flow)

Users can belong to more than one team and switch between them via the team
sidebar icons. By default any user can create a team — restrict that at
System Console → User Management → Permissions if you only want admins
creating them.

By default, Direct Messages ignore team boundaries — anyone on the server
can DM anyone else regardless of shared team membership. To limit the DM
picker to teammates only: **System Console → Site Configuration → Users and
Teams → "Enable users to open Direct Message channels with" → Any member of
the team** (free in Team Edition, no license needed). This is a UI filter,
not a hard boundary — it doesn't hide DM channels that already exist, and a
user in multiple teams can still DM anyone across all of them, not just the
team currently open. If you need real isolation between groups rather than
a tidier picker, that means separate Mattermost instances, not this setting.

## Voice/Video Calls (Calls plugin)
Port ${CALLS_UDP_PORT}/udp must be open on your router/firewall.

${_turn_config_md}

## Manage
\`\`\`bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
\`\`\`
MD

    if [[ "$SITE_URL" == http://* ]]; then
        log_warning "WebRTC (voice/video calls) requires HTTPS. Configure Caddy and update SITE_URL."
    fi

    # ── Migration helper (new/fresh installs only — not "update" reruns,
    # where an existing instance is already in real use and importing over
    # it would be destructive) ────────────────────────────────────────────
    if [ "$MODE" != "update" ]; then
        echo ""
        local MIGRATING=""
        prompt_yn "Migrating from an existing Mattermost instance (e.g. PikaPods)? (y/n):" "n" MIGRATING
        if [[ "$MIGRATING" =~ ^[Yy]$ ]]; then
            cat > "$DIR/migrate-from-pikapods.sh" << 'MIGRATE_HEAD'
#!/bin/bash
################################################################################
# migrate-from-pikapods.sh — generated by ubuntu-post-install
#
# Imports a Mattermost database dump + file storage exported from another
# instance (e.g. PikaPods) into THIS freshly-created instance, replacing its
# empty database and populating its file storage.
#
# PikaPods export procedure (Pod Settings): enable SFTP + Database access,
# STOP the pod first (flushes anything still in memory to disk), SFTP the
# pod's files down, then use the Adminer link PikaPods gives you to export
# the database as a plain SQL dump. See docs.pikapods.com/manage/backup.
#
# This script assumes a PLAIN-TEXT SQL dump (what Adminer produces by
# default). If you have a custom-format pg_dump instead, use `pg_restore`
# in place of the `psql < dump` step below.
#
# IMPORTANT: point the files argument at the SUBDIRECTORY that holds
# Mattermost's own file storage inside whatever you downloaded via SFTP
# (commonly named `data`), not the whole SFTP root — PikaPods' exact
# layout wasn't verified against a live pod, so confirm this yourself
# before running.
#
# Usage:
#   ./migrate-from-pikapods.sh <path-to-sql-dump> <path-to-files-dir>
################################################################################

MIGRATE_HEAD

            cat >> "$DIR/migrate-from-pikapods.sh" << MIGRATE_VARS
PROJECT_DIR="$DIR"
MM_CONTAINER="$MM_CONTAINER"
DB_CONTAINER="$DB_CONTAINER"
DB_NAME="mattermost"
DB_USER="mattermost"
MIGRATE_VARS

            cat >> "$DIR/migrate-from-pikapods.sh" << 'MIGRATE_BODY'
set -uo pipefail
cd "$PROJECT_DIR" || exit 1

SQL_DUMP="${1:-}"
FILES_DIR="${2:-}"

if [ -z "$SQL_DUMP" ] || [ -z "$FILES_DIR" ]; then
    echo "Usage: $0 <path-to-sql-dump> <path-to-files-dir>"
    exit 1
fi
[ -f "$SQL_DUMP" ]  || { echo "SQL dump not found: $SQL_DUMP"; exit 1; }
[ -d "$FILES_DIR" ] || { echo "Files directory not found: $FILES_DIR"; exit 1; }
[ -f "docker-compose.yml" ] || { echo "Run this from $PROJECT_DIR (docker-compose.yml not found here)."; exit 1; }

echo ""
echo "┌─────────────────────────────────────────────────────────────────┐"
echo "│ MATTERMOST MIGRATION — THIS REPLACES THE CURRENT DATABASE         │"
echo "└─────────────────────────────────────────────────────────────────┘"
echo ""
echo "  Target instance: $PROJECT_DIR"
echo "  SQL dump:        $SQL_DUMP"
echo "  Files:            $FILES_DIR  (copied into ./data)"
echo ""
read -r -p "  Type YES to proceed: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Aborted — no changes made."; exit 0; }

echo ""
echo "Stopping $MM_CONTAINER (keeping $DB_CONTAINER running)..."
docker compose stop mattermost

echo "Waiting for $DB_CONTAINER to accept connections..."
tries=0
until docker exec "$DB_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1 || [ "$tries" -ge 30 ]; do
    sleep 1; tries=$((tries + 1))
done

echo "Dropping and recreating '$DB_NAME' (owned by the existing '$DB_USER' role — .env credentials are untouched)..."
if ! docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -c "DROP DATABASE IF EXISTS $DB_NAME;" \
    || ! docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d postgres -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"; then
    echo "Failed to reset the database — check: docker compose logs db"
    exit 1
fi

echo "Importing $SQL_DUMP..."
if ! docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" < "$SQL_DUMP" > /tmp/mm-migrate-import.log 2>&1; then
    echo "Import reported errors — check /tmp/mm-migrate-import.log before continuing."
    echo "(Some warnings, e.g. about extensions already existing, are expected and harmless."
    echo " Look for actual failures — missing tables, permission errors — before deciding.)"
fi

echo "Copying files into ./data..."
mkdir -p ./data
rsync -a "$FILES_DIR"/ ./data/ 2>/dev/null || cp -a "$FILES_DIR"/. ./data/

echo "Starting Mattermost..."
docker compose up -d

echo ""
echo "Done. Verify before treating this as live:"
echo "  - Open the site and confirm you can log in as an existing (migrated) user"
echo "  - Spot-check a channel with history and a message that has an attached file"
echo "  - Check System Console → users/teams counts look right"
echo ""
echo "Import log: /tmp/mm-migrate-import.log"
MIGRATE_BODY

            chmod +x "$DIR/migrate-from-pikapods.sh"
            chown "$ACTUAL_USER:$ACTUAL_USER" "$DIR/migrate-from-pikapods.sh"
            log_success "Migration helper written: $DIR/migrate-from-pikapods.sh"
            log_info "Run it once you have both a SQL dump and the files directory from PikaPods."
        fi
    fi

    local START=""
    prompt_yn "Start Mattermost now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        if docker compose up -d; then
            log_success "Mattermost started"
            # Reference implementation of the shared health check — a
            # "Started" message alone doesn't mean the app is actually up;
            # it can still crash-loop (bad DB password, missing required
            # env var, etc.) with no visible sign until someone separately
            # runs `docker ps -a` much later. Mattermost's own first DB
            # connection attempt can take a few seconds, hence the longer
            # wait than check_container_health's 8s default.
            declare -F check_container_health >/dev/null 2>&1 && check_container_health "$MM_CONTAINER" 12
        else
            log_warning "Start failed — check: docker compose logs"
        fi
    fi

    echo ""
    echo "  Access at:  $SITE_URL"
    echo "  First run:  open the URL above and create your admin account."
    echo "  Teams:      team sidebar '+' → Create a new team (see README.md — no"
    echo "              Enterprise license needed, Team Edition includes this)."
    echo "  Calls plugin TURN config: see README.md (System Console → Plugins → Calls)."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_mattermost
