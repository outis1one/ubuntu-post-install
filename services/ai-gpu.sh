#!/bin/bash
# services/ai-gpu.sh — GPU AI stack: InvokeAI image gen + Ollama/OpenWebUI LLM + swap portal.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash ai-gpu.sh
# (Docker + nvidia-container-toolkit must already be installed)
#
# Clones https://github.com/outis1one/ai-6gb-gpu and installs three stacks:
#   image-gen/  — InvokeAI (port 9090), nvidia GPU, optimised for 6 GB VRAM
#   llm/        — Ollama (11434) + Open WebUI (3000) + SearXNG (internal)
#   portal/     — Flask app (port 8080), mounts Docker socket, hot-swaps GPU between stacks
#
# Because a 6 GB GPU can only run ONE stack at a time, the portal handles the swap:
# stop the active stack, start the requested one. Stop image-gen before starting llm, and vice versa.

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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

register_service ai-gpu utilities "GPU AI stack — InvokeAI image gen + Ollama/OpenWebUI LLM (6 GB VRAM)" 9090

install_ai_gpu() {
    require_docker || return 1
    log_info "Installing AI GPU stack (InvokeAI + Ollama/OpenWebUI + portal)..."
    log_info "Requires: nvidia GPU with 6 GB+ VRAM, nvidia-container-toolkit installed."

    local AI_DIR="$DOCKER_DIR/ai-gpu"
    local REPO_URL="https://github.com/outis1one/ai-6gb-gpu.git"
    local REPO_DIR="$AI_DIR/src"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would clone $REPO_URL to $REPO_DIR"
        echo "[DRY-RUN] Would create stacks: image-gen (InvokeAI:9090), llm (Ollama:11434 + OpenWebUI:3000), portal (8080)"
        echo "[DRY-RUN] Would write .env files and patch portal volume paths to $ACTUAL_HOME/docker"
        echo "[DRY-RUN] Would configure Caddy for portal (localai) and InvokeAI (images)"
        return 0
    fi

    # TZ — repo defaults to America/New_York, replace with user preference
    local TZ_VAL="${SITE_TZ:-UTC}"
    prompt_text "Timezone (e.g. America/New_York) [$TZ_VAL]:" "$TZ_VAL" TZ_VAL
    TZ_VAL="${TZ_VAL:-UTC}"

    mkdir -p "$AI_DIR"

    # ── Clone / update repo ───────────────────────────────────────────────────
    if [ -d "$REPO_DIR/.git" ]; then
        log_info "Updating ai-6gb-gpu repo..."
        git -C "$REPO_DIR" pull --ff-only 2>/dev/null \
            && log_success "Repo updated" \
            || log_warning "Could not pull latest — using existing version"
    else
        log_info "Cloning ai-6gb-gpu repo..."
        git clone --depth 1 "$REPO_URL" "$REPO_DIR" \
            || { log_error "Clone failed — check network and git access"; return 1; }
    fi

    # ── Image-gen stack (InvokeAI) ────────────────────────────────────────────
    local IMAGE_GEN_DIR="$AI_DIR/image-gen"
    mkdir -p "$IMAGE_GEN_DIR"
    if [ -d "$REPO_DIR/ai-image-gen" ]; then
        cp -rn "$REPO_DIR/ai-image-gen/." "$IMAGE_GEN_DIR/" 2>/dev/null || true
        # Replace any hardcoded timezone
        find "$IMAGE_GEN_DIR" -name "docker-compose.yml" -exec \
            sed -i "s|America/New_York|$TZ_VAL|g" {} \;
    fi

    cat > "$IMAGE_GEN_DIR/.env" << IMGENV
# InvokeAI — image generation
TZ=${TZ_VAL}
# VRAM cap: 3 GB leaves headroom on a 6 GB card
INVOKEAI_vram=3
# RAM cache for model layers
INVOKEAI_ram=8
CADDY_NET=${SITE_CADDY_NET}
IMGENV
    chmod 600 "$IMAGE_GEN_DIR/.env"

    # ── LLM stack (Ollama + Open WebUI + SearXNG) ─────────────────────────────
    local LLM_DIR="$AI_DIR/llm"
    mkdir -p "$LLM_DIR"
    if [ -d "$REPO_DIR/ai-llm" ]; then
        cp -rn "$REPO_DIR/ai-llm/." "$LLM_DIR/" 2>/dev/null || true
        find "$LLM_DIR" -name "docker-compose.yml" -exec \
            sed -i "s|America/New_York|$TZ_VAL|g" {} \;
    fi

    local WEBUI_SECRET
    WEBUI_SECRET="$(generate_password 32)"

    cat > "$LLM_DIR/.env" << LLMENV
# Ollama + Open WebUI + SearXNG
TZ=${TZ_VAL}
# Open WebUI session secret
WEBUI_SECRET_KEY=${WEBUI_SECRET}
CADDY_NET=${SITE_CADDY_NET}
LLMENV
    chmod 600 "$LLM_DIR/.env"

    # ── Portal stack (Flask GPU swap controller) ──────────────────────────────
    local PORTAL_DIR="$AI_DIR/portal"
    mkdir -p "$PORTAL_DIR"
    if [ -d "$REPO_DIR/ai-portal" ]; then
        cp -rn "$REPO_DIR/ai-portal/." "$PORTAL_DIR/" 2>/dev/null || true
        # Fix hardcoded home path in docker-compose.yml volume mounts
        if [ -f "$PORTAL_DIR/docker-compose.yml" ]; then
            sed -i \
                "s|/home/[^/]*/docker:|${ACTUAL_HOME}/docker:|g" \
                "$PORTAL_DIR/docker-compose.yml"
            sed -i "s|America/New_York|$TZ_VAL|g" "$PORTAL_DIR/docker-compose.yml"
        fi
    fi

    cat > "$PORTAL_DIR/.env" << PORTALENV
# AI Portal — GPU stack swap controller
TZ=${TZ_VAL}
# Paths inside the container (Docker socket mount maps ACTUAL_HOME/docker → /docker)
IMAGE_STACK=/docker/ai-gpu/image-gen
LLM_STACK=/docker/ai-gpu/llm
CADDY_NET=${SITE_CADDY_NET}
PORTALENV
    chmod 600 "$PORTAL_DIR/.env"

    # Set ownership across everything
    ensure_docker_dir_ownership "$AI_DIR"

    echo ""
    log_success "AI GPU stacks configured under $AI_DIR"
    log_info "Stack layout:"
    log_info "  image-gen/  — InvokeAI  (port 9090,  nvidia GPU)"
    log_info "  llm/        — Ollama (11434) + Open WebUI (3000) + SearXNG (internal)"
    log_info "  portal/     — GPU swap portal (port 8080)"
    echo ""
    log_warning "Only ONE GPU stack can run at a time on a 6 GB card."
    log_warning "Use the portal to switch, or manually: docker compose -f <stack>/docker-compose.yml down/up."

    # ── Caddy ─────────────────────────────────────────────────────────────────
    configure_caddy_for_service "AI Portal" "ai-portal:8080" "localai"
    configure_caddy_for_service "InvokeAI" "invokeai:9090" "images"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$AI_DIR" << MD
# AI GPU Stack

Three Docker stacks optimised for a 6 GB VRAM nvidia GPU.
Source: https://github.com/outis1one/ai-6gb-gpu

## Stacks

| Stack | Service | Port | Notes |
|-------|---------|------|-------|
| \`image-gen/\` | InvokeAI | 9090 | Image generation (SDXL, Flux, etc.) |
| \`llm/\` | Ollama | 11434 | LLM inference engine |
| \`llm/\` | Open WebUI | 3000 | Chat UI for Ollama |
| \`llm/\` | SearXNG | — | Internal web search for RAG |
| \`portal/\` | AI Portal | 8080 | GPU swap controller UI |

## Important: GPU time-sharing

A 6 GB GPU can only run one AI stack at a time. Use the portal at
http://localhost:8080 to swap between image-gen and llm — it stops the
active stack before starting the requested one.

Manual swap:
\`\`\`bash
# Stop image-gen, start llm
docker compose -f $AI_DIR/image-gen/docker-compose.yml down
docker compose -f $AI_DIR/llm/docker-compose.yml up -d

# Stop llm, start image-gen
docker compose -f $AI_DIR/llm/docker-compose.yml down
docker compose -f $AI_DIR/image-gen/docker-compose.yml up -d
\`\`\`

## First-run setup

### InvokeAI
1. Open http://localhost:9090
2. Install models via the Model Manager (HuggingFace token may be needed)
3. Recommended for 6 GB: SDXL-Turbo, Flux-Schnell-quantised

### Ollama
\`\`\`bash
# Pull a model (while llm stack is running)
docker exec ollama ollama pull llama3.2
docker exec ollama ollama pull nomic-embed-text  # for RAG embeddings
\`\`\`

### Open WebUI
Open http://localhost:3000 — create admin account on first visit.

## Manage individual stacks
\`\`\`bash
# Image generation
cd $AI_DIR/image-gen
docker compose up -d
docker compose down
docker compose logs -f invokeai

# LLM + chat
cd $AI_DIR/llm
docker compose up -d
docker compose down
docker compose logs -f openwebui

# Portal
cd $AI_DIR/portal
docker compose up -d
docker compose down
\`\`\`

## Update
\`\`\`bash
# Pull latest repo changes and rebuild
cd $REPO_DIR && git pull
cd $AI_DIR/image-gen && docker compose pull && docker compose up -d
cd $AI_DIR/llm       && docker compose pull && docker compose up -d
cd $AI_DIR/portal    && docker compose build --pull && docker compose up -d
\`\`\`

## Files
- image-gen/.env  — InvokeAI VRAM/RAM limits and TZ
- llm/.env        — Open WebUI secret key and TZ
- portal/.env     — stack paths and TZ
MD

    # ── Start prompt ──────────────────────────────────────────────────────────
    echo ""
    log_info "Which stack do you want to start now?"
    log_info "  1) Portal only (recommended first — lets you manage the others)"
    log_info "  2) Portal + image-gen (InvokeAI)"
    log_info "  3) Portal + llm (Ollama/OpenWebUI)"
    log_info "  4) None — start manually later"

    local START_CHOICE=""
    prompt_text "Choice [1]:" "1" START_CHOICE

    case "$START_CHOICE" in
        1)
            docker compose -f "$PORTAL_DIR/docker-compose.yml" up -d \
                && log_success "Portal started — http://localhost:8080" \
                || log_warning "Portal start failed — check: docker compose -f $PORTAL_DIR/docker-compose.yml logs"
            ;;
        2)
            docker compose -f "$PORTAL_DIR/docker-compose.yml" up -d \
                && log_success "Portal started" \
                || log_warning "Portal start failed"
            docker compose -f "$IMAGE_GEN_DIR/docker-compose.yml" up -d \
                && log_success "InvokeAI started — http://localhost:9090" \
                || log_warning "InvokeAI start failed — check: docker compose -f $IMAGE_GEN_DIR/docker-compose.yml logs"
            ;;
        3)
            docker compose -f "$PORTAL_DIR/docker-compose.yml" up -d \
                && log_success "Portal started" \
                || log_warning "Portal start failed"
            docker compose -f "$LLM_DIR/docker-compose.yml" up -d \
                && log_success "LLM stack started — Open WebUI: http://localhost:3000" \
                || log_warning "LLM start failed — check: docker compose -f $LLM_DIR/docker-compose.yml logs"
            ;;
        *)
            log_info "Skipped. Start when ready:"
            log_info "  docker compose -f $PORTAL_DIR/docker-compose.yml up -d"
            ;;
    esac

    echo ""
    echo "  Portal:    http://localhost:8080"
    echo "  InvokeAI:  http://localhost:9090  (image-gen stack)"
    echo "  OpenWebUI: http://localhost:3000  (llm stack)"
    echo "  Source:    $REPO_DIR"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_ai_gpu
