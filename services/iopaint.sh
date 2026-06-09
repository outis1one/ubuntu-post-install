#!/bin/bash
# services/iopaint.sh — AI image editing: erase objects, fill regions, replace with text prompt.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash iopaint.sh
# (Docker must already be installed when run standalone)
#
# Three use cases:
#   Erase/remove  — mask an object, AI fills the gap (LaMa, CPU-safe)
#   Inpaint/fill  — restore damaged areas, remove watermarks (multiple models)
#   Replace       — mask + text prompt → AI draws new content (PowerPaint, GPU required)
#
# IOPaint is local-only: it cannot call a remote GPU or InvokeAI on another machine.
# For text-guided replacement the GPU must be on this same machine.
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
        echo "[DRY-RUN] Would prompt for model and GPU (CUDA) support"
        echo "[DRY-RUN] Would write docker-compose.yml and .env"
        echo "[DRY-RUN] Would offer Authelia SSO"
        return 0
    fi

    mkdir -p "$IOPAINT_DIR"
    ensure_docker_dir_ownership "$IOPAINT_DIR"
    cd "$IOPAINT_DIR" || return 1

    # ── GPU ──────────────────────────────────────────────────────────────────
    log_info "IOPaint can:"
    log_info "  • Erase / remove  — mask an object, AI fills the gap (works CPU-only)"
    log_info "  • Inpaint / fill  — restore damaged areas, remove watermarks"
    log_info "  • Replace         — mask + type what goes there → AI draws it (needs GPU)"
    log_info "  Note: inference is always local — IOPaint cannot use a GPU on another machine."
    echo ""
    local USE_GPU=""
    prompt_yn "Enable CUDA GPU support? Requires nvidia-container-toolkit (y/n):" "n" USE_GPU

    # ── Model selection ───────────────────────────────────────────────────────
    echo ""
    log_info "Select default model (you can switch models in the UI without restarting):"
    echo ""
    log_info "  ── CPU-safe — work on any machine ─────────────────────────────────────────"
    log_info "  1) lama                    Erase / removal. Intelligent gap fill. ~200 MB  ← Recommended"
    log_info "  2) cv2                     OpenCV fill. No download, instant. Rough quality."
    log_info "  3) zits                    Portrait & face restoration. ~200 MB."
    log_info "  4) manga                   Comic/manga text bubble removal. ~100 MB."
    echo ""
    if [[ "$USE_GPU" =~ ^[Yy]$ ]]; then
        log_info "  ── GPU-accelerated fill ───────────────────────────────────────────────────"
        log_info "  5) migan                   MiGAN: fast GPU inpainting. ~50 MB."
        log_info "  6) fcf                     FcF: high-quality contextual fill. ~600 MB."
        log_info "  7) mat                     MAT: large missing region fill. ~300 MB."
        log_info "  8) ldm                     LDM: latent diffusion texture fill. ~1.2 GB."
        echo ""
        log_info "  ── Text-guided REPLACEMENT (GPU + Stable Diffusion) ───────────────────────"
        log_info "  9) Sanster/PowerPaint-V2-filling"
        log_info "                             Mask + type 'a red barn' → AI draws it. ~4 GB."
        log_info "                             Modes: text-guided, shape-guided, erase, outpaint."
        log_info " 10) runwayml/stable-diffusion-inpainting"
        log_info "                             Classic SD 1.5 inpaint. Huge LoRA/style library. ~4 GB."
        echo ""
    fi

    local MODEL_NUM=""
    prompt_text "Model choice [1=lama]:" "1" MODEL_NUM

    local IOPAINT_MODEL="lama"
    case "$MODEL_NUM" in
        2)  IOPAINT_MODEL="cv2" ;;
        3)  IOPAINT_MODEL="zits" ;;
        4)  IOPAINT_MODEL="manga" ;;
        5)  IOPAINT_MODEL="migan" ;;
        6)  IOPAINT_MODEL="fcf" ;;
        7)  IOPAINT_MODEL="mat" ;;
        8)  IOPAINT_MODEL="ldm" ;;
        9)  IOPAINT_MODEL="Sanster/PowerPaint-V2-filling" ;;
        10) IOPAINT_MODEL="runwayml/stable-diffusion-inpainting" ;;
        *)  IOPAINT_MODEL="lama" ;;
    esac

    local DEVICE_VAL="cpu"
    [[ "$USE_GPU" =~ ^[Yy]$ ]] && DEVICE_VAL="cuda"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    # MODEL and DEVICE come from .env — change them there and restart to switch.
    # Volume ./models:/root/.cache persists ALL model caches:
    #   /root/.cache/torch/hub/checkpoints/  (LaMa, CV2, ZITS, etc.)
    #   /root/.cache/huggingface/             (SD, PowerPaint, LDM, etc.)
    if [[ "$USE_GPU" =~ ^[Yy]$ ]]; then
        cat > docker-compose.yml << 'IOPAINT_GPU'
name: iopaint

services:
  iopaint:
    image: cwq1913/iopaint:latest
    container_name: iopaint
    hostname: iopaint
    restart: unless-stopped
    command: >-
      iopaint start
      --model=${MODEL:-lama}
      --device=${DEVICE:-cuda}
      --port=8080
      --host=0.0.0.0
    ports:
      - "8100:8080"
    env_file: .env
    volumes:
      - ./models:/root/.cache
      - ./input:/app/input
      - ./output:/app/output
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
    else
        cat > docker-compose.yml << 'IOPAINT_CPU'
name: iopaint

services:
  iopaint:
    image: cwq1913/iopaint:latest
    container_name: iopaint
    hostname: iopaint
    restart: unless-stopped
    command: >-
      iopaint start
      --model=${MODEL:-lama}
      --device=${DEVICE:-cpu}
      --port=8080
      --host=0.0.0.0
    ports:
      - "8100:8080"
    env_file: .env
    volumes:
      - ./models:/root/.cache
      - ./input:/app/input
      - ./output:/app/output
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
IOPAINT_CPU
    fi

    # ── .env ─────────────────────────────────────────────────────────────────
    cat > .env << IOPAINT_ENV
# IOPaint — change MODEL and restart to switch (no need to edit docker-compose.yml)

# Current model (set during install — see README for full model list)
MODEL=${IOPAINT_MODEL}

# Device: cpu or cuda
# For GPU: also requires the deploy: block in docker-compose.yml
DEVICE=${DEVICE_VAL}

# Caddy network
CADDY_NET=${SITE_CADDY_NET}
IOPAINT_ENV
    chmod 600 .env

    mkdir -p models input output
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$IOPAINT_DIR"

    echo ""
    log_success "IOPaint configured — model: $IOPAINT_MODEL | device: $DEVICE_VAL"
    if [[ "$IOPAINT_MODEL" == *"PowerPaint"* ]] || [[ "$IOPAINT_MODEL" == *"stable-diffusion"* ]]; then
        log_info "SD-based model selected (~4 GB). It downloads from HuggingFace on first start."
        log_info "If the download fails, try: HF_TOKEN=your_token docker compose up -d"
    else
        log_info "Model downloads automatically on first start (LaMa ~200 MB)."
    fi
    log_info "Switch models any time by editing MODEL= in .env and restarting."

    # No built-in auth — offer Authelia SSO protection
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect IOPaint with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
    fi

    configure_caddy_for_service "IOPaint" "iopaint:8080" "inpaint" "$EXTRA_BLOCK"

    write_readme "$IOPAINT_DIR" << 'MD'
# IOPaint

AI-powered image editing:
- **Erase / remove** — mask an object, AI fills the background (LaMa, works CPU-only)
- **Inpaint / restore** — fix damaged areas, remove watermarks
- **Replace with AI** — mask something + type what goes there → AI draws it (PowerPaint, GPU)

Note: IOPaint is **local only** — all inference runs on this machine.
For text-guided replacement a CUDA GPU on this machine is required.

## Access
- URL: http://localhost:8100
- No built-in login — protect via Authelia SSO if exposed

## Switching models
Edit `MODEL=` in `.env` and restart — no need to touch `docker-compose.yml`:
```bash
cd ~/docker/iopaint
nano .env          # change MODEL= line
docker compose restart
```

## Model reference

| # | Model | Type | Size | Best for |
|---|-------|------|------|---------|
| 1 | `lama` | CPU-safe | ~200 MB | **Object erase/removal** (default) |
| 2 | `cv2` | CPU-safe | built-in | Basic fill, no download |
| 3 | `zits` | CPU-safe | ~200 MB | Portrait & face restoration |
| 4 | `manga` | CPU-safe | ~100 MB | Comic/manga text bubble removal |
| 5 | `migan` | GPU | ~50 MB | Fast GPU inpainting |
| 6 | `fcf` | GPU | ~600 MB | High-quality contextual fill |
| 7 | `mat` | GPU | ~300 MB | Large missing region fill |
| 8 | `ldm` | GPU | ~1.2 GB | Latent diffusion texture fill |
| 9 | `Sanster/PowerPaint-V2-filling` | GPU+SD | ~4 GB | **Text-guided replacement** |
| 10 | `runwayml/stable-diffusion-inpainting` | GPU+SD | ~4 GB | SD 1.5 inpaint, large LoRA library |

SD-based models (9, 10) download from HuggingFace on first start.
If a gated model needs a token: add `HF_TOKEN=xxx` to `.env`.

## How to use
1. Open http://localhost:8100
2. Upload an image (or drag & drop)
3. Paint a mask over the area to change
4. For erase models: click Run → gap fills automatically
5. For SD models (PowerPaint): type a text prompt → AI draws it into the masked area

## GPU acceleration
Requires `nvidia-container-toolkit`. The GPU compose adds a `deploy:` block.
Re-run the installer with GPU=y to regenerate docker-compose.yml, or manually add:
```yaml
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]
```
Then change `DEVICE=cuda` in `.env` and restart.

## Manage
```bash
cd ~/docker/iopaint
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose down && docker compose up -d
```

## Files
- docker-compose.yml — stack (MODEL and DEVICE come from .env)
- .env               — model and device config
- models/            — all cached model weights (torch + HuggingFace)
- input/, output/    — optional file staging
MD

    local START_IO=""
    prompt_yn "Start IOPaint now? (y/n):" "y" START_IO
    if [ "$START_IO" = "y" ] || [ "$START_IO" = "Y" ]; then
        docker compose up -d \
            && log_success "IOPaint started — model downloads on first use" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  URL:      http://localhost:8100"
    echo "  Model:    $IOPAINT_MODEL"
    echo "  Device:   $DEVICE_VAL"
    echo "  Switch:   edit MODEL= in $IOPAINT_DIR/.env and restart"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_iopaint
