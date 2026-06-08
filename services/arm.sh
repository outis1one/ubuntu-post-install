#!/bin/bash
# services/arm.sh — Automatic Ripping Machine: rip DVDs, Blu-rays, CDs.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash arm.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- A.R.M. ----).
# Own ~/docker/arm/ with a standalone docker-compose.yml + .env. Detects
# optical drives at install time; add more /dev/srN entries manually after.

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

register_service arm media "Automatic Ripping Machine — rip DVDs, Blu-rays, CDs" 8080

install_arm() {
    require_docker || return 1

    local ARM_DIR="$DOCKER_DIR/arm"
    local DEFAULT_OUTPUT="$ACTUAL_HOME/ripped"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] A.R.M. would:"
        echo "  - Create $ARM_DIR with docker-compose.yml + .env (config/ logs/)"
        echo "  - Detect optical drives (/dev/sr*) — defaults to /dev/sr0"
        echo "  - Create ripped output dirs (movies/ music/) under $DEFAULT_OUTPUT"
        echo "  - Run as UID/GID $(id -u "$ACTUAL_USER")/$(id -g "$ACTUAL_USER") with privileged: true"
        echo "  - Expose port 8080"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    local ARM_OUTPUT=""
    prompt_text "Path for ripped media output [$DEFAULT_OUTPUT]:" "$DEFAULT_OUTPUT" ARM_OUTPUT
    ARM_OUTPUT="${ARM_OUTPUT/#\~/$ACTUAL_HOME}"; ARM_OUTPUT="${ARM_OUTPUT%/}"

    echo ""
    echo "Detecting optical drives..."
    local OPTICAL_DRIVES
    OPTICAL_DRIVES=$(ls /dev/sr* 2>/dev/null || true)
    if [ -n "$OPTICAL_DRIVES" ]; then
        echo "  Found: $OPTICAL_DRIVES"
    else
        echo "  No optical drives detected. Defaulting to /dev/sr0 — add more later."
        OPTICAL_DRIVES="/dev/sr0"
    fi

    mkdir -p "$ARM_DIR"
    ensure_docker_dir_ownership "$ARM_DIR"
    cd "$ARM_DIR" || return 1

    local TZ_VAL UID_VAL GID_VAL
    TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    UID_VAL=$(id -u "$ACTUAL_USER"); GID_VAL=$(id -g "$ACTUAL_USER")

    cat > docker-compose.yml << ARM_COMPOSE
name: arm

services:
  automatic-ripping-machine:
    image: automaticrippingmachine/automatic-ripping-machine:latest
    container_name: arm
    hostname: arm
    restart: unless-stopped
    environment:
      - ARM_UID=$UID_VAL
      - ARM_GID=$GID_VAL
      - TZ=$TZ_VAL
    volumes:
      - ./config:/etc/arm/config
      - ./logs:/home/arm/logs
      - \${ARM_OUTPUT}/movies:/home/arm/media/completed
      - \${ARM_OUTPUT}/music:/home/arm/music
    ports:
      - "8080:8080"
    devices:
      - /dev/sr0:/dev/sr0
      # Add more optical drives as needed:
      # - /dev/sr1:/dev/sr1
    privileged: true
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
ARM_COMPOSE

    cat > .env << ARM_ENV
ARM_OUTPUT=$ARM_OUTPUT
CADDY_NET=$SITE_CADDY_NET
ARM_ENV

    mkdir -p config logs
    mkdir -p "$ARM_OUTPUT/movies" "$ARM_OUTPUT/music"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ARM_DIR"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$ARM_OUTPUT"
    log_success "A.R.M. configured at $ARM_DIR"

    configure_caddy_for_service "A.R.M." "arm:8080" "arm"

    write_readme "$ARM_DIR" << MD
# A.R.M. (Automatic Ripping Machine)

Auto-rips DVDs, Blu-rays, and CDs when you insert them — identifies the disc,
fetches metadata, and transcodes to a usable format.

- Web UI: http://localhost:8080 (complete setup on first visit)
- Ripped output: \`$ARM_OUTPUT\` → movies and music subdirs
- App data: \`config/\` and \`logs/\`

## Manage
\`\`\`bash
cd $ARM_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Adding optical drives
Edit \`docker-compose.yml\` and add more \`devices:\` entries:
\`\`\`yaml
    devices:
      - /dev/sr0:/dev/sr0
      - /dev/sr1:/dev/sr1
\`\`\`
Then \`docker compose up -d\` to apply.

## Notes
- First launch: open the web UI and complete the setup wizard.
- \`privileged: true\` is required for ARM to control the optical drive.
- Change the output path in \`.env\` (\`ARM_OUTPUT=\`), then \`docker compose up -d\`.
MD

    local START_ARM=""
    prompt_yn "Start A.R.M. now? (y/n):" "y" START_ARM
    if [ "$START_ARM" = "y" ] || [ "$START_ARM" = "Y" ]; then
        docker compose up -d && log_success "A.R.M. started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:8080"
    echo "  Complete setup in browser on first visit."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_arm
