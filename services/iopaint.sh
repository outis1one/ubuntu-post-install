#!/bin/bash
# services/iopaint.sh — AI image inpainting: object removal, fill, restore (IOPaint + LaMa).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash iopaint.sh
# (Docker must already be installed when run standalone)
#
# Runs the LaMa model (erase/fill objects) by default on CPU.
# For GPU inference set DEVICE=cuda in .env and install nvidia-container-toolkit.
# IOPaint has no built-in auth — protect with Authelia via Caddy.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        source "$_COMMON"
    else
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
            local _display_port="${_upstream##*:}"

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

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

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
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service iopaint utilities "AI image inpainting — erase objects, fill, restore (IOPaint)" 8100

install_iopaint() {
    require_docker || return 1
    log_info "Installing IOPaint..."

    local IOPAINT_DIR="$DOCKER_DIR/iopaint"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $IOPAINT_DIR"
        echo "[DRY-RUN] Would write docker-compose.yml and .env"
        echo "[DRY-RUN] Would offer GPU (CUDA) support and Authelia SSO"
        return 0
    fi

    mkdir -p "$IOPAINT_DIR"
    ensure_docker_dir_ownership "$IOPAINT_DIR"
    cd "$IOPAINT_DIR" || return 1

    # Ask about GPU
    local USE_GPU=""
    prompt_yn "Enable CUDA GPU support? Requires nvidia-container-toolkit (y/n):" "n" USE_GPU

    if [[ "$USE_GPU" =~ ^[Yy]$ ]]; then
        cat > docker-compose.yml << 'IOPAINT_GPU'
name: iopaint

services:
  iopaint:
    image: cwq1913/iopaint:latest
    container_name: iopaint
    hostname: iopaint
    restart: unless-stopped
    command: iopaint start --model=lama --device=cuda --port=8080 --host=0.0.0.0
    ports:
      - "8100:8080"
    volumes:
      - ./models:/root/.cache/iopaint
      - ./input:/app/input
      - ./output:/app/output
    environment:
      - DEVICE=cuda
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
IOPAINT_GPU
        log_info "CUDA GPU mode enabled."
    else
        cat > docker-compose.yml << 'IOPAINT_CPU'
name: iopaint

services:
  iopaint:
    image: cwq1913/iopaint:latest
    container_name: iopaint
    hostname: iopaint
    restart: unless-stopped
    command: iopaint start --model=lama --device=cpu --port=8080 --host=0.0.0.0
    ports:
      - "8100:8080"
    volumes:
      - ./models:/root/.cache/iopaint
      - ./input:/app/input
      - ./output:/app/output
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
IOPAINT_CPU
        log_info "CPU mode (default). Change DEVICE to cuda in .env and update the command to use GPU later."
    fi

    cat > .env << IOPAINT_ENV
# IOPaint configuration

# Model to use for inpainting (lama recommended for object removal/erase)
# Other models: ldm, zits, mat, fcf, manga, cv2, migan
MODEL=lama

# Device: cpu or cuda (cuda requires nvidia-container-toolkit + GPU deploy block)
DEVICE=$([ "${USE_GPU,,}" = "y" ] && echo "cuda" || echo "cpu")

# Caddy network
CADDY_NET=${SITE_CADDY_NET}
IOPAINT_ENV
    chmod 600 .env

    mkdir -p models input output
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$IOPAINT_DIR"

    echo ""
    log_success "IOPaint configured at $IOPAINT_DIR"
    log_info "LaMa model downloads on first start (~170 MB). Upload images via the web UI."
    log_info "To switch models later: edit the --model= argument in docker-compose.yml and restart."

    # No built-in auth — offer Authelia SSO protection
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect IOPaint with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
    fi

    configure_caddy_for_service "IOPaint" "iopaint:8080" "inpaint" "$EXTRA_BLOCK"

    write_readme "$IOPAINT_DIR" << MD
# IOPaint

AI-powered image inpainting — erase objects, fill regions, restore photos.
Uses the LaMa (Large Mask) model for high-quality object removal by default.

## Access
- URL: http://localhost:8100
- No built-in login — protect via Authelia SSO if needed

## Models
The \`--model\` argument in docker-compose.yml selects the AI model:
| Model  | Best for |
|--------|----------|
| \`lama\` | Object removal, erase (default) |
| \`ldm\`  | Texture-aware fill |
| \`zits\` | Face/portrait restoration |
| \`mat\`  | Large missing region fill |
| \`manga\`| Manga/comic text removal |

Models download automatically on first use. Cached in \`./models/\`.

## GPU acceleration
Requires \`nvidia-container-toolkit\`. To enable:
1. Edit docker-compose.yml: change \`--device=cpu\` → \`--device=cuda\`
2. Uncomment the \`deploy:\` block (or re-run this installer with GPU=y)
3. Restart: \`docker compose down && docker compose up -d\`

## Manage
\`\`\`bash
cd $IOPAINT_DIR
docker compose up -d                                      # start
docker compose down                                       # stop
docker compose logs -f                                    # logs
docker compose pull && docker compose down && docker compose up -d  # update
\`\`\`

## Files
- docker-compose.yml — stack definition (edit for model/device changes)
- .env               — runtime config
- models/            — cached AI model weights
- input/             — optional: place images here
- output/            — processed images written here
MD

    local START_IO=""
    prompt_yn "Start IOPaint now? (y/n):" "y" START_IO
    if [ "$START_IO" = "y" ] || [ "$START_IO" = "Y" ]; then
        docker compose up -d \
            && log_success "IOPaint started — LaMa model will download on first use" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  URL:      http://localhost:8100"
    echo "  Model:    LaMa (erase / object removal)"
    echo "  Device:   $([ "${USE_GPU,,}" = "y" ] && echo "CUDA GPU" || echo "CPU")"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_iopaint
