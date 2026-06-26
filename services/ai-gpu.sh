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
#               + optional cloud LLM providers (Groq/DeepInfra/OpenAI/OpenRouter) as OpenAI connections
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
        echo "[DRY-RUN] Would prompt for Ollama and InvokeAI model selection"
        echo "[DRY-RUN] Would optionally wire cloud LLM providers (Groq/DeepInfra/OpenAI/OpenRouter) into Open WebUI"
        echo "[DRY-RUN] Would auto-pull selected Ollama models after LLM stack starts"
        echo "[DRY-RUN] Would queue InvokeAI starter model via REST API"
        return 0
    fi

    # ── Timezone ──────────────────────────────────────────────────────────────
    local TZ_VAL="${SITE_TZ:-UTC}"
    prompt_text "Timezone (e.g. America/New_York) [$TZ_VAL]:" "$TZ_VAL" TZ_VAL
    TZ_VAL="${TZ_VAL:-UTC}"

    # ── Ollama model selection ────────────────────────────────────────────────
    echo ""
    log_info "Ollama LLM models — select which to download (enter numbers separated by spaces):"
    log_info "All models are quantized (Q4_K_M) and run comfortably on 6 GB VRAM."
    echo ""
    log_info "  1) llama3.2:3b       ~2.0 GB  Fast general chat. Great all-rounder.  ← Recommended"
    log_info "  2) llama3.2:1b       ~1.3 GB  Ultra-fast. Light tasks, low latency."
    log_info "  3) qwen2.5:7b        ~4.7 GB  Top code + math model. Strong reasoning."
    log_info "  4) mistral:7b        ~4.1 GB  Solid all-rounder. Good at instruction follow."
    log_info "  5) phi4-mini         ~2.5 GB  Microsoft Phi-4 mini. Excellent for coding."
    log_info "  6) gemma3:4b         ~2.5 GB  Google Gemma 3. Well-rounded, multilingual."
    log_info "  7) deepseek-r1:7b    ~4.7 GB  Strong reasoning and math. Think-step model."
    log_info "  8) nomic-embed-text  ~274 MB  Embedding model — enables RAG/doc search."
    log_info "                                 Recommended to add alongside a chat model."
    echo ""
    log_info "  Example: '1 8' pulls llama3.2:3b + nomic-embed-text"
    log_info "  Enter '0' or leave blank to skip and pull models manually later."
    echo ""

    local OLLAMA_CHOICES=""
    prompt_text "Models to download [1 8]:" "1 8" OLLAMA_CHOICES

    declare -a OLLAMA_MODELS=()
    for _n in $OLLAMA_CHOICES; do
        case "$_n" in
            1) OLLAMA_MODELS+=("llama3.2:3b") ;;
            2) OLLAMA_MODELS+=("llama3.2:1b") ;;
            3) OLLAMA_MODELS+=("qwen2.5:7b") ;;
            4) OLLAMA_MODELS+=("mistral:7b") ;;
            5) OLLAMA_MODELS+=("phi4-mini") ;;
            6) OLLAMA_MODELS+=("gemma3:4b") ;;
            7) OLLAMA_MODELS+=("deepseek-r1:7b") ;;
            8) OLLAMA_MODELS+=("nomic-embed-text") ;;
        esac
    done

    # ── Cloud LLM providers (optional) ─────────────────────────────────────────────
    echo ""
    log_info "Cloud LLM providers — optional, wired into Open WebUI alongside local Ollama."
    log_info "All are OpenAI-compatible. Pick any combination (you enter a key for each):"
    echo ""
    log_info "  1) Groq        Fast LPU inference, generous free tier. Open models (Llama, Qwen, gpt-oss, Kimi)."
    log_info "                 Key: https://console.groq.com/keys"
    log_info "  2) DeepInfra   Cheapest host for open models. Zero-retention, no training (US)."
    log_info "                 Key: https://deepinfra.com/dash/api_keys"
    log_info "  3) OpenAI      GPT-5.x, o-series, gpt-image. Pay-as-you-go."
    log_info "                 Key: https://platform.openai.com/api-keys"
    log_info "  4) OpenRouter  One key, 300+ models across many providers (incl. free variants)."
    log_info "                 Key: https://openrouter.ai/keys"
    echo ""
    log_info "  Example: '1 2' wires Groq + DeepInfra. Leave blank to skip cloud providers."
    echo ""

    local CLOUD_CHOICES=""
    prompt_text "Cloud providers to add []:" "" CLOUD_CHOICES

    # Parallel arrays: display name, OpenAI-compatible base URL, and entered key
    declare -a CLOUD_NAMES=() CLOUD_URLS=() CLOUD_KEYS=()
    local _c _cname _curl _ckey
    for _c in $CLOUD_CHOICES; do
        _cname="" ; _curl=""
        case "$_c" in
            1) _cname="Groq";       _curl="https://api.groq.com/openai/v1" ;;
            2) _cname="DeepInfra";  _curl="https://api.deepinfra.com/v1/openai" ;;
            3) _cname="OpenAI";     _curl="https://api.openai.com/v1" ;;
            4) _cname="OpenRouter"; _curl="https://openrouter.ai/api/v1" ;;
            *) log_warning "Ignoring unknown choice '$_c'"; continue ;;
        esac
        _ckey=""
        prompt_text "$_cname API key (enter to skip):" "" _ckey
        if [ -n "$_ckey" ]; then
            CLOUD_NAMES+=("$_cname")
            CLOUD_URLS+=("$_curl")
            CLOUD_KEYS+=("$_ckey")
        else
            log_warning "No key for $_cname — skipping."
        fi
    done

    # Semicolon-joined lists for Open WebUI (OPENAI_API_BASE_URLS / OPENAI_API_KEYS)
    local CLOUD_URLS_JOINED="" CLOUD_KEYS_JOINED="" _i
    for _i in "${!CLOUD_NAMES[@]}"; do
        CLOUD_URLS_JOINED+="${CLOUD_URLS[$_i]};"
        CLOUD_KEYS_JOINED+="${CLOUD_KEYS[$_i]};"
    done
    CLOUD_URLS_JOINED="${CLOUD_URLS_JOINED%;}"
    CLOUD_KEYS_JOINED="${CLOUD_KEYS_JOINED%;}"

    # ── InvokeAI model selection ──────────────────────────────────────────────
    echo ""
    log_info "InvokeAI image generation models (for 6 GB VRAM with partial GPU offload):"
    log_info "InvokeAI uses VRAM=3 GB + 8 GB RAM cache, so all models below work on 6 GB."
    echo ""
    log_info "  1) stabilityai/stable-diffusion-v1-5   ~4 GB  SD 1.5 — fast, huge style/LoRA library."
    log_info "                                                  Best starting model for most uses."
    log_info "  2) stabilityai/sdxl-turbo              ~7 GB  SDXL Turbo — 4-step generation."
    log_info "                                                  Fast, high quality, slightly slower on 6 GB."
    log_info "  3) stabilityai/stable-diffusion-xl-base-1.0"
    log_info "                                         ~7 GB  SDXL base — best quality at 1024px."
    log_info "                                                  Slowest due to RAM offload on 6 GB."
    log_info "  4) Skip — install models via the Model Manager at http://localhost:9090"
    echo ""
    log_info "  Tip: SD 1.5 (choice 1) is fastest and most compatible. Start here."
    log_info "  HuggingFace token: required for some gated models (free at huggingface.co/settings/tokens)"
    echo ""

    local INVOKE_CHOICE=""
    prompt_text "InvokeAI starter model [1]:" "1" INVOKE_CHOICE

    local INVOKE_MODEL_SOURCE=""
    local INVOKE_MODEL_NAME=""
    case "$INVOKE_CHOICE" in
        2) INVOKE_MODEL_SOURCE="stabilityai/sdxl-turbo"
           INVOKE_MODEL_NAME="SDXL Turbo" ;;
        3) INVOKE_MODEL_SOURCE="stabilityai/stable-diffusion-xl-base-1.0"
           INVOKE_MODEL_NAME="SDXL Base" ;;
        4) INVOKE_MODEL_SOURCE=""
           INVOKE_MODEL_NAME="" ;;
        *) INVOKE_MODEL_SOURCE="stabilityai/stable-diffusion-v1-5"
           INVOKE_MODEL_NAME="SD 1.5" ;;
    esac

    local HF_TOKEN=""
    if [ -n "$INVOKE_MODEL_SOURCE" ]; then
        prompt_text "HuggingFace token (optional — needed for gated models, enter to skip):" "" HF_TOKEN
    fi

    # ── Clone / update repo ───────────────────────────────────────────────────
    mkdir -p "$AI_DIR"
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
        find "$IMAGE_GEN_DIR" -name "docker-compose.yml" -exec \
            sed -i "s|America/New_York|$TZ_VAL|g" {} \;
    fi

    cat > "$IMAGE_GEN_DIR/.env" << IMGENV
# InvokeAI — image generation
TZ=${TZ_VAL}
# VRAM cap: 3 GB leaves headroom on a 6 GB card; remaining model layers go to RAM
INVOKEAI_vram=3
# RAM cache size for model layer offload
INVOKEAI_ram=8
${HF_TOKEN:+HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}}
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

    # Wire selected cloud providers into Open WebUI as OpenAI-compatible
    # connections (idempotent). Keys live in .env; only ${VAR} refs go in compose.
    if [ -n "$CLOUD_URLS_JOINED" ]; then
        local LLM_COMPOSE="$LLM_DIR/docker-compose.yml"
        if [ -f "$LLM_COMPOSE" ] && ! grep -q "OPENAI_API_BASE_URLS" "$LLM_COMPOSE"; then
            sed -i '/- OLLAMA_BASE_URL=http:\/\/ollama:11434/a\
      - ENABLE_OPENAI_API=true\
      - OPENAI_API_BASE_URLS=${OPENAI_API_BASE_URLS}\
      - OPENAI_API_KEYS=${OPENAI_API_KEYS}' "$LLM_COMPOSE"
            grep -q "OPENAI_API_BASE_URLS" "$LLM_COMPOSE" \
                && log_success "Cloud providers wired into Open WebUI: ${CLOUD_NAMES[*]}" \
                || log_warning "Could not patch docker-compose.yml — add ENABLE_OPENAI_API/OPENAI_API_BASE_URLS/OPENAI_API_KEYS to the open-webui service's environment manually"
        fi
    fi

    local WEBUI_SECRET
    WEBUI_SECRET="$(generate_password 32)"

    cat > "$LLM_DIR/.env" << LLMENV
# Ollama + Open WebUI + SearXNG
TZ=${TZ_VAL}
WEBUI_SECRET_KEY=${WEBUI_SECRET}
# Open WebUI: enable SearXNG for web search in chats
ENABLE_RAG_WEB_SEARCH=true
RAG_WEB_SEARCH_ENGINE=searxng
SEARXNG_QUERY_URL=http://searxng:8080/search?q=<query>&format=json
# Cloud LLM providers for Open WebUI — OpenAI-compatible, semicolon-separated,
# matched by position. Blank = local Ollama only. Add/rotate later: append a base
# URL + its key to these two lines (same order), then run docker compose up -d.
#   Groq        https://api.groq.com/openai/v1        key: https://console.groq.com/keys
#   DeepInfra   https://api.deepinfra.com/v1/openai   key: https://deepinfra.com/dash/api_keys
#   OpenAI      https://api.openai.com/v1             key: https://platform.openai.com/api-keys
#   OpenRouter  https://openrouter.ai/api/v1          key: https://openrouter.ai/keys
OPENAI_API_BASE_URLS=${CLOUD_URLS_JOINED}
OPENAI_API_KEYS=${CLOUD_KEYS_JOINED}
CADDY_NET=${SITE_CADDY_NET}
LLMENV
    chmod 600 "$LLM_DIR/.env"

    # ── Portal stack (Flask GPU swap controller) ──────────────────────────────
    local PORTAL_DIR="$AI_DIR/portal"
    mkdir -p "$PORTAL_DIR"
    if [ -d "$REPO_DIR/ai-portal" ]; then
        cp -rn "$REPO_DIR/ai-portal/." "$PORTAL_DIR/" 2>/dev/null || true
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
# Paths inside the container (/docker maps to ${ACTUAL_HOME}/docker via volume mount)
IMAGE_STACK=/docker/ai-gpu/image-gen
LLM_STACK=/docker/ai-gpu/llm
CADDY_NET=${SITE_CADDY_NET}
PORTALENV
    chmod 600 "$PORTAL_DIR/.env"

    ensure_docker_dir_ownership "$AI_DIR"

    echo ""
    log_success "AI GPU stacks configured under $AI_DIR"
    log_warning "Only ONE GPU stack can run at a time on a 6 GB card."
    log_info "Use the portal (port 8080) to hot-swap between image-gen and llm."
    echo ""

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
| \`image-gen/\` | InvokeAI | 9090 | Image generation (SD 1.5, SDXL, Flux…) |
| \`llm/\` | Ollama | 11434 | LLM inference engine |
| \`llm/\` | Open WebUI | 3000 | Chat UI — models, RAG, web search |
| \`llm/\` | SearXNG | internal | Web search backend for RAG in OpenWebUI |
| \`portal/\` | AI Portal | 8080 | GPU swap controller — start/stop stacks |

## GPU time-sharing (important)

A 6 GB GPU can only run one AI stack at a time.
Use the portal at http://localhost:8080 to swap.

Manual swap:
\`\`\`bash
docker compose -f $AI_DIR/llm/docker-compose.yml down
docker compose -f $AI_DIR/image-gen/docker-compose.yml up -d
\`\`\`

## InvokeAI — add more models

Models installed at setup are in the Model Manager. To add more:
1. Open http://localhost:9090 → Model Manager → Add Model
2. Paste a HuggingFace repo ID (e.g. \`stabilityai/stable-diffusion-2-1\`)
3. Or import a local .safetensors file

For gated models, add \`HUGGING_FACE_HUB_TOKEN=xxx\` to \`image-gen/.env\`.

Recommended models for 6 GB (with partial GPU offload):

| Model | Source | Notes |
|-------|--------|-------|
| SD 1.5 | \`stabilityai/stable-diffusion-v1-5\` | Fast, huge LoRA library |
| SDXL Turbo | \`stabilityai/sdxl-turbo\` | 4-step, good quality |
| SDXL Base | \`stabilityai/stable-diffusion-xl-base-1.0\` | Best quality, slower |
| SD 2.1 | \`stabilityai/stable-diffusion-2-1\` | Good mid-size choice |

## Ollama — add more models

\`\`\`bash
# Pull any model while llm stack is running
docker exec ollama ollama pull llama3.2:3b
docker exec ollama ollama pull nomic-embed-text    # RAG embeddings
docker exec ollama ollama list                      # see installed models
\`\`\`

Browse models at: https://ollama.com/library
For 6 GB cards, stick to 7B or smaller with Q4_K_M quantisation (~4.5 GB).

## Open WebUI — first login

Open http://localhost:3000 and create your admin account on first visit.
Models pulled into Ollama appear automatically in the model dropdown.
Enable web search: Settings → Admin → Web Search (SearXNG is pre-configured).

## Cloud LLM providers

$([ ${#CLOUD_NAMES[@]} -gt 0 ] && echo "Configured at install time: ${CLOUD_NAMES[*]} — these appear in the Open WebUI model dropdown alongside local Ollama." || echo "None configured. To add one or more later:")

Open WebUI is OpenAI-compatible, so these plug in as extra connections. They share
two semicolon-separated lists, matched by position:

| Provider | Base URL | API key |
|----------|----------|---------|
| Groq | \`https://api.groq.com/openai/v1\` | https://console.groq.com/keys |
| DeepInfra | \`https://api.deepinfra.com/v1/openai\` | https://deepinfra.com/dash/api_keys |
| OpenAI | \`https://api.openai.com/v1\` | https://platform.openai.com/api-keys |
| OpenRouter | \`https://openrouter.ai/api/v1\` | https://openrouter.ai/keys |

Add/rotate providers:
\`\`\`bash
# llm/.env — semicolon-separated, SAME order in both lists:
OPENAI_API_BASE_URLS=https://api.groq.com/openai/v1;https://api.deepinfra.com/v1/openai
OPENAI_API_KEYS=gsk_xxx;di_xxx

# llm/docker-compose.yml — open-webui service needs these under 'environment:'
#   - ENABLE_OPENAI_API=true
#   - OPENAI_API_BASE_URLS=\${OPENAI_API_BASE_URLS}
#   - OPENAI_API_KEYS=\${OPENAI_API_KEYS}

cd $AI_DIR/llm && docker compose up -d   # recreate with the new keys
\`\`\`
Tip: Groq has a generous free tier; DeepInfra is the cheapest host for open models
with zero-retention privacy. Both are far faster than local Ollama on a 6 GB card.

## Manage individual stacks
\`\`\`bash
cd $AI_DIR/image-gen && docker compose up -d    # start InvokeAI
cd $AI_DIR/llm       && docker compose up -d    # start Ollama + OpenWebUI
cd $AI_DIR/portal    && docker compose up -d    # start portal
docker compose -f $AI_DIR/image-gen/docker-compose.yml logs -f invokeai
docker compose -f $AI_DIR/llm/docker-compose.yml       logs -f openwebui
\`\`\`

## Update
\`\`\`bash
cd $REPO_DIR && git pull
cd $AI_DIR/image-gen && docker compose pull && docker compose up -d
cd $AI_DIR/llm       && docker compose pull && docker compose up -d
cd $AI_DIR/portal    && docker compose build --pull && docker compose up -d
\`\`\`
MD

    # ── Start stacks + pull models ────────────────────────────────────────────
    echo ""
    log_info "What would you like to start now?"
    log_info "  1) Portal only           — start the swap controller, configure the rest later"
    log_info "  2) Portal + LLM stack    — start Ollama/OpenWebUI and pull selected models"
    log_info "  3) Portal + image-gen    — start InvokeAI and queue the starter model download"
    log_info "  4) None                  — start manually later"
    echo ""

    local START_CHOICE=""
    prompt_text "Choice [2]:" "2" START_CHOICE

    # Always start portal if any stack is starting
    if [[ "$START_CHOICE" =~ ^[123]$ ]]; then
        docker compose -f "$PORTAL_DIR/docker-compose.yml" up -d \
            && log_success "Portal started — http://localhost:8080" \
            || log_warning "Portal start failed — check: docker compose -f $PORTAL_DIR/docker-compose.yml logs"
    fi

    if [[ "$START_CHOICE" == "2" ]]; then
        # Start LLM stack
        docker compose -f "$LLM_DIR/docker-compose.yml" up -d \
            && log_success "LLM stack started" \
            || { log_warning "LLM stack start failed"; START_CHOICE="0"; }

        # Pull Ollama models if any were selected
        if [ ${#OLLAMA_MODELS[@]} -gt 0 ] && [[ "$START_CHOICE" == "2" ]]; then
            log_info "Waiting for Ollama to be ready..."
            local _w=0
            while ! curl -sf "http://localhost:11434/api/version" &>/dev/null; do
                sleep 3; _w=$((_w+3))
                [[ $_w -ge 90 ]] && { log_warning "Ollama not responding after 90s — pull models manually later"; break; }
            done

            if curl -sf "http://localhost:11434/api/version" &>/dev/null; then
                for _m in "${OLLAMA_MODELS[@]}"; do
                    log_info "Pulling $_m (this may take a while)..."
                    docker exec ollama ollama pull "$_m" \
                        && log_success "$_m ready" \
                        || log_warning "Pull failed for $_m — retry: docker exec ollama ollama pull $_m"
                done
                log_success "Open WebUI ready at: http://localhost:3000"
                log_info "Create your admin account on the first visit."
            fi
        fi
    fi

    if [[ "$START_CHOICE" == "3" ]]; then
        # Start image-gen stack
        docker compose -f "$IMAGE_GEN_DIR/docker-compose.yml" up -d \
            && log_success "InvokeAI started" \
            || { log_warning "InvokeAI start failed — check: docker compose -f $IMAGE_GEN_DIR/docker-compose.yml logs"; START_CHOICE="0"; }

        # Queue starter model via InvokeAI REST API
        if [ -n "$INVOKE_MODEL_SOURCE" ] && [[ "$START_CHOICE" == "3" ]]; then
            log_info "Waiting for InvokeAI to be ready (model database initialises on first start)..."
            local _w=0
            while ! curl -sf "http://localhost:9090/api/v1/app/version" &>/dev/null; do
                sleep 5; _w=$((_w+5))
                [[ $_w -ge 180 ]] && { log_warning "InvokeAI not responding after 3 min"; break; }
            done

            if curl -sf "http://localhost:9090/api/v1/app/version" &>/dev/null; then
                log_info "Queuing $INVOKE_MODEL_NAME download..."
                local _resp
                _resp=$(curl -s -X POST "http://localhost:9090/api/v2/models/install" \
                    -H "Content-Type: application/json" \
                    -d "{\"source\": \"${INVOKE_MODEL_SOURCE}\"}" 2>/dev/null)
                if echo "$_resp" | grep -q '"id"'; then
                    log_success "$INVOKE_MODEL_NAME queued — downloading in background"
                    log_info "Track progress: http://localhost:9090 → Model Manager → In Progress"
                else
                    log_warning "Could not queue via API. Install manually:"
                    log_info "  Open http://localhost:9090 → Model Manager → Add Model"
                    log_info "  Source: $INVOKE_MODEL_SOURCE"
                fi
            fi
        fi
    fi

    if [[ "$START_CHOICE" == "4" ]] || [[ "$START_CHOICE" == "0" ]]; then
        log_info "Start when ready:"
        log_info "  docker compose -f $PORTAL_DIR/docker-compose.yml up -d"
        log_info "  docker compose -f $LLM_DIR/docker-compose.yml up -d"
        log_info "  docker compose -f $IMAGE_GEN_DIR/docker-compose.yml up -d"
    fi

    echo ""
    echo "  Portal:       http://localhost:8080  (GPU swap controller)"
    echo "  InvokeAI:     http://localhost:9090  (image-gen stack)"
    echo "  Open WebUI:   http://localhost:3000  (llm stack)"
    echo "  Ollama API:   http://localhost:11434 (llm stack)"
    echo "  Source repo:  $REPO_DIR"
    echo ""
    if [ ${#OLLAMA_MODELS[@]} -gt 0 ]; then
        echo "  Ollama models queued: ${OLLAMA_MODELS[*]}"
    fi
    if [ -n "$INVOKE_MODEL_NAME" ]; then
        echo "  InvokeAI starter:     $INVOKE_MODEL_NAME ($INVOKE_MODEL_SOURCE)"
    fi
    if [ ${#CLOUD_NAMES[@]} -gt 0 ]; then
        echo "  Cloud LLM providers:  ${CLOUD_NAMES[*]} (wired into Open WebUI)"
    fi
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_ai_gpu
