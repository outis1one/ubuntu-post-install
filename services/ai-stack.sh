#!/bin/bash
# services/ai-stack.sh — Local AI Stack: a full self-hosted AI environment.
#
# Vendored from github.com/outis1one/local-ai into this repo under ./ai-stack and
# copied to ~/docker/ai-stack at install time (no network clone). Bundles:
#   Ollama · Open WebUI · RAG + MCP servers · ChromaDB · SearXNG · Kiwix ·
#   Gitea · InvokeAI · ComfyUI · Portainer
#
# Script-driven (unlike most services here): the app ships its own VRAM-aware
# installer (local-ai-setup.sh) that generates docker-compose.yml/.env, starts the
# stack, and registers a `local-ai` systemd unit. This wrapper copies the vendored
# source into place and hands off to that installer, then optionally wires cloud
# LLM providers into Open WebUI alongside the local RAG connection.
#
# Open WebUI ships with built-in auth (WEBUI_AUTH=true) — no Authelia needed.
# Distinct from `ai-gpu` (the ai-6gb-gpu repo: a leaner 3-stack GPU-swap setup for
# 6 GB cards). Both can coexist.
# Part of the modular post-install system (sourced by setup.sh).

register_service ai-stack utilities "Full self-hosted AI stack — Ollama/OpenWebUI + RAG + ComfyUI + more (local-ai)" 3000

install_ai-stack() {
    require_docker || return 1
    log_info "Installing Local AI Stack (Ollama + Open WebUI + RAG + image gen + more)..."

    # Vendored application source lives in this repo at <repo>/ai-stack
    local SELF_DIR SRC_DIR
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SRC_DIR="$(cd "$SELF_DIR/.." && pwd)/ai-stack"

    local AS_DIR="$DOCKER_DIR/ai-stack"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would copy vendored source $SRC_DIR -> $AS_DIR"
        echo "[DRY-RUN] Would optionally collect cloud LLM provider keys (Groq/DeepInfra/OpenAI/OpenRouter)"
        echo "[DRY-RUN] Would run the app installer local-ai-setup.sh (Docker/NVIDIA toolkit, VRAM-aware models, generates compose/.env, starts stack, registers systemd 'local-ai')"
        echo "[DRY-RUN] Would wire cloud providers into Open WebUI (OPENAI_API_BASE_URLS) preserving the local RAG connection"
        echo "[DRY-RUN] Would write gpu-mode.sh and optionally enable the GPU switcher (one small GPU shared by Ollama and InvokeAI/ComfyUI)"
        echo "[DRY-RUN] Would attach Open WebUI to caddy_net and configure Caddy (open-webui:8080, host port 3000)"
        return 0
    fi

    if [ ! -d "$SRC_DIR" ]; then
        log_error "Vendored Local AI Stack source not found at $SRC_DIR"
        return 1
    fi

    # ── Copy vendored source into the docker dir ──────────────────────────────
    # The installer generates its compose/.env/systemd as siblings here (it uses
    # its own dir as BASE), matching the upstream layout. The installer never
    # overwrites a user-edited .env on re-run.
    mkdir -p "$AS_DIR"
    cp -a "$SRC_DIR/." "$AS_DIR/"
    ensure_docker_dir_ownership "$AS_DIR"
    cd "$AS_DIR" || return 1
    chmod +x ./*.sh systemd/*.sh 2>/dev/null || true

    # ── Cloud LLM providers (optional) ────────────────────────────────────────
    # Open WebUI already uses the *singular* OPENAI_API_* slot for the local RAG
    # server. To add cloud providers we switch it to the *plural* list form and
    # keep RAG as the first entry, so RAG keeps working.
    echo ""
    log_info "Cloud LLM providers — optional, added to Open WebUI alongside local Ollama + RAG."
    log_info "All are OpenAI-compatible. Pick any combination (you enter a key for each):"
    echo ""
    log_info "  1) Groq        Fast LPU inference, generous free tier. Key: https://console.groq.com/keys"
    log_info "  2) DeepInfra   Cheapest host for open models, zero-retention. Key: https://deepinfra.com/dash/api_keys"
    log_info "  3) OpenAI      GPT-5.x, o-series, gpt-image. Key: https://platform.openai.com/api-keys"
    log_info "  4) OpenRouter  One key, 300+ models. Key: https://openrouter.ai/keys"
    echo ""
    log_info "  Example: '1 2' wires Groq + DeepInfra. Leave blank to stay fully local."
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
            CLOUD_NAMES+=("$_cname"); CLOUD_URLS+=("$_curl"); CLOUD_KEYS+=("$_ckey")
        else
            log_warning "No key for $_cname — skipping."
        fi
    done

    # ── Hand off to the app's own installer ───────────────────────────────────
    echo ""
    log_warning "The Local AI Stack installer is heavy: it can install Docker + the NVIDIA"
    log_warning "container toolkit, pulls several GB of images, and registers a systemd unit."
    local RUN_NOW=""
    prompt_yn "Run the Local AI Stack installer now? (y/n):" "y" RUN_NOW

    local INSTALLER_RAN=false
    if [[ "$RUN_NOW" =~ ^[Yy]$ ]]; then
        # --no-pull skips the (large, slow) Ollama model downloads when unattended.
        local _flags=""
        [ "$UNATTENDED" = true ] && _flags="--no-pull"
        if [ -f local-ai-setup.sh ]; then
            if bash local-ai-setup.sh $_flags; then
                INSTALLER_RAN=true
                log_success "Local AI Stack installer finished"
            else
                log_warning "local-ai-setup.sh reported an error — see output above"
            fi
        else
            log_error "local-ai-setup.sh missing from vendored source"
        fi
    else
        log_info "Skipped. Run later: cd $AS_DIR && bash local-ai-setup.sh"
    fi

    # ── Wire cloud providers into the generated compose ───────────────────────
    if [ ${#CLOUD_NAMES[@]} -gt 0 ] && [ -f "$AS_DIR/docker-compose.yml" ]; then
        # Prepend the local RAG connection so RAG keeps working, then the clouds.
        local URLS="http://rag-server:8001/v1" KEYS="local-rag" _i
        for _i in "${!CLOUD_NAMES[@]}"; do
            URLS+=";${CLOUD_URLS[$_i]}"; KEYS+=";${CLOUD_KEYS[$_i]}"
        done

        # Upsert into the stack .env (compose interpolates these; keys stay out of
        # the committed-looking compose file). Drop any existing line, then append.
        _as_set_env() {
            sed -i -E "/^#?[[:space:]]*$1=/d" "$AS_DIR/.env" 2>/dev/null
            printf '%s=%s\n' "$1" "$2" >> "$AS_DIR/.env"
        }
        touch "$AS_DIR/.env"
        _as_set_env OPENAI_API_BASE_URLS "$URLS"
        _as_set_env OPENAI_API_KEYS "$KEYS"
        chmod 600 "$AS_DIR/.env"

        # Swap Open WebUI's singular RAG slot to the plural list form (idempotent).
        if grep -q 'OPENAI_API_BASE_URL=http://rag-server' "$AS_DIR/docker-compose.yml"; then
            sed -i 's|- OPENAI_API_BASE_URL=http://rag-server:8001/v1|- OPENAI_API_BASE_URLS=${OPENAI_API_BASE_URLS}|' "$AS_DIR/docker-compose.yml"
            sed -i 's|- OPENAI_API_KEY=local-rag|- OPENAI_API_KEYS=${OPENAI_API_KEYS}|' "$AS_DIR/docker-compose.yml"
            log_success "Cloud providers wired into Open WebUI: ${CLOUD_NAMES[*]} (local RAG preserved)"
            (cd "$AS_DIR" && docker compose up -d open-webui) \
                && log_success "Open WebUI recreated with cloud providers" \
                || log_warning "Could not recreate Open WebUI — run: cd $AS_DIR && docker compose up -d"
        else
            log_warning "Open WebUI RAG env not found in compose — add cloud providers via Open WebUI → Settings → Connections instead."
        fi
        ensure_docker_dir_ownership "$AS_DIR"
    elif [ ${#CLOUD_NAMES[@]} -gt 0 ]; then
        log_warning "No generated docker-compose.yml yet — add ${CLOUD_NAMES[*]} via Open WebUI → Settings → Connections after first start."
    fi

    # ── Optional GPU switcher ─────────────────────────────────────────────────
    # One small GPU can't run local chat (Ollama) and local image-gen
    # (InvokeAI/ComfyUI) at once. gpu-mode.sh time-shares it; the always-on
    # services (Open WebUI, Gitea, RAG, MCP, Kiwix) are never touched. Cloud
    # models need no swap. Open WebUI = chat/research/code+git; PaintPlus = images.
    cat > "$AS_DIR/gpu-mode.sh" << 'GPUEOF'
#!/usr/bin/env bash
# gpu-mode.sh — time-share ONE small GPU between local LLM and local image-gen.
#
#   llm      Ollama up (Open WebUI local chat);  InvokeAI + ComfyUI stopped
#   images   InvokeAI + ComfyUI up (PaintPlus local backend);  Ollama stopped
#   status   show which GPU services run + VRAM use
#
# Only needed when one small GPU serves BOTH locally. Cloud models and the
# always-on services (Open WebUI, Gitea, RAG, MCP, Kiwix) are unaffected.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LLM_SVCS=(ollama)
IMG_SVCS=(invokeai comfyui)
case "${1:-status}" in
  llm)
    docker compose stop "${IMG_SVCS[@]}" 2>/dev/null || true
    docker compose up -d "${LLM_SVCS[@]}"
    echo "GPU -> LLM: Ollama up, image-gen stopped. Open WebUI local models ready." ;;
  images)
    docker compose stop "${LLM_SVCS[@]}" 2>/dev/null || true
    docker compose up -d "${IMG_SVCS[@]}"
    echo "GPU -> Images: InvokeAI+ComfyUI up, Ollama stopped. PaintPlus local backend ready." ;;
  status)
    for s in "${LLM_SVCS[@]}" "${IMG_SVCS[@]}"; do
      printf "  %-10s %s\n" "$s" "$(docker inspect -f '{{.State.Running}}' "$s" 2>/dev/null || echo absent)"
    done
    command -v nvidia-smi >/dev/null 2>&1 && \
      nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader || true ;;
  *) echo "Usage: gpu-mode.sh {llm|images|status}"; exit 1 ;;
esac
GPUEOF
    chmod +x "$AS_DIR/gpu-mode.sh"

    local SMALL_GPU=""
    prompt_yn "Small local GPU shared between local chat and local image-gen? (sets up the GPU switcher) (y/n):" "n" SMALL_GPU
    if [[ "$SMALL_GPU" =~ ^[Yy]$ ]]; then
        if [ "$INSTALLER_RAN" = true ]; then
            log_info "Small-GPU mode: handing the GPU to local chat (Ollama) and stopping image-gen."
            (cd "$AS_DIR" && bash gpu-mode.sh llm) \
                || log_warning "Could not set chat mode — run: $AS_DIR/gpu-mode.sh llm"
        fi
        echo ""
        log_warning "SMALL-GPU MODE: only ONE of {local chat, local images} runs at a time."
        log_warning "  Swap the GPU yourself when you change tasks:"
        log_warning "    $AS_DIR/gpu-mode.sh images   # before generating locally in PaintPlus"
        log_warning "    $AS_DIR/gpu-mode.sh llm       # back to local chat in Open WebUI"
        log_warning "    $AS_DIR/gpu-mode.sh status    # see which is active"
        log_warning "  (Cloud models work anytime and need no swap.)"
        echo ""
    else
        log_info "GPU switcher written to $AS_DIR/gpu-mode.sh — use it if a small GPU ever needs to time-share."
    fi
    ensure_docker_dir_ownership "$AS_DIR"

    # ── Caddy (Open WebUI has built-in auth — no Authelia) ────────────────────
    # The generated compose doesn't join caddy_net, so attach the container by name.
    if [ -d "$DOCKER_DIR/caddy" ] && [ "$INSTALLER_RAN" = true ]; then
        docker network connect "$SITE_CADDY_NET" open-webui 2>/dev/null || true
    fi
    configure_caddy_for_service "Open WebUI" "open-webui:8080" "ai"

    # ── Deploy notes (the app's own docs stay at $AS_DIR/README.md) ───────────
    cat > "$AS_DIR/POST-INSTALL-NOTES.md" << MD
# Local AI Stack — deployment notes (ubuntu-post-install)

Vendored app source copied here from the \`ai-stack\` service. Full app docs:
\`README.md\` in this directory. Source: github.com/outis1one/local-ai

## Roles
- **Open WebUI** (chat, research, light coding) — local Ollama + any cloud providers
  in one model dropdown; wired to your code via the RAG + MCP servers and Gitea.
- **PaintPlus** (separate \`paintplus\` service) — the front end for all image work
  (inpaint / upscale / generate). Point its \`AI_PROVIDER\` at a cloud API, or at this
  stack's local \`comfyui\` / \`invokeai\` for local image-gen.
- **Gitea + GitHub sync** — \`bash gitea-github-sync.sh\` mirrors repos both ways
  (pull GitHub → local git, or push local → GitHub).
- **RAG / MCP / Kiwix** — retrieve just the relevant context so you feed the model
  less text (saves tokens), for both local and cloud models.
- Web search uses **DuckDuckGo** (no SearXNG in this build).

## GPU switcher (small local GPU only)
One small GPU can't run local chat and local image-gen at once. Swap it:
\`\`\`bash
$AS_DIR/gpu-mode.sh images   # before generating locally in PaintPlus
$AS_DIR/gpu-mode.sh llm       # back to local chat in Open WebUI
$AS_DIR/gpu-mode.sh status    # see which is active
\`\`\`
Cloud models work anytime and need no swap.

## Service URLs
| Service    | URL                       | Auth                |
|------------|---------------------------|---------------------|
| Open WebUI | http://localhost:3000     | built-in (first visit = admin) |
| InvokeAI   | http://localhost:9090     | none                |
| ComfyUI    | http://localhost:8188     | none                |
| Kiwix      | http://localhost:8181     | none                |
| Gitea      | http://localhost:3001     | built-in            |
| Portainer  | https://localhost:9443    | built-in            |

## Manage the stack
\`\`\`bash
cd $AS_DIR
bash start.sh          # pull latest images + docker compose up -d
bash stop.sh           # docker compose down
bash status.sh         # GPU / container / RAG health
bash pull-models.sh    # pull Ollama models (run once after first install)
\`\`\`
Also a systemd unit: \`sudo systemctl {start,stop,status} local-ai\`

## Cloud LLM providers (Open WebUI)
Open WebUI uses an OpenAI-compatible connection list. The local RAG server is the
first entry; any cloud providers added at install follow it. Two semicolon-separated
lists in \`.env\`, matched by position (RAG must stay first):
\`\`\`bash
# $AS_DIR/.env
OPENAI_API_BASE_URLS=http://rag-server:8001/v1;https://api.groq.com/openai/v1
OPENAI_API_KEYS=local-rag;gsk_xxx
cd $AS_DIR && docker compose up -d open-webui   # apply
\`\`\`
| Provider | Base URL | Key |
|----------|----------|-----|
| Groq | \`https://api.groq.com/openai/v1\` | https://console.groq.com/keys |
| DeepInfra | \`https://api.deepinfra.com/v1/openai\` | https://deepinfra.com/dash/api_keys |
| OpenAI | \`https://api.openai.com/v1\` | https://platform.openai.com/api-keys |
| OpenRouter | \`https://openrouter.ai/api/v1\` | https://openrouter.ai/keys |

Alternatively, add them at runtime in Open WebUI → Settings → Admin → Connections
(no file edits, survives image upgrades).

## Update
Re-run the \`ai-stack\` installer (refreshes vendored source, keeps your \`.env\`),
then \`bash $AS_DIR/start.sh\`. Or in place: \`cd $AS_DIR && bash local-ai-setup.sh --force\`.

## Caddy
Open WebUI is reverse-proxied as \`open-webui:8080\` on \`${SITE_CADDY_NET:-caddy_net}\`
(attached with \`docker network connect\` after start). Other services are LAN-only by
default — add Caddy site blocks for them if you want remote access.
MD
    ensure_docker_dir_ownership "$AS_DIR"

    echo ""
    echo "  Open WebUI:  http://localhost:3000   (chat/research/code — Ollama + cloud, built-in login)"
    echo "  InvokeAI:    http://localhost:9090   ComfyUI:   http://localhost:8188   (PaintPlus image backends)"
    echo "  Kiwix:       http://localhost:8181   Gitea:     http://localhost:3001   Portainer: https://localhost:9443"
    echo "  App dir:     $AS_DIR   (app docs: README.md · deploy notes: POST-INSTALL-NOTES.md)"
    if [ ${#CLOUD_NAMES[@]} -gt 0 ]; then
        echo "  Cloud LLM:   ${CLOUD_NAMES[*]} (wired into Open WebUI)"
    fi
    if [[ "$SMALL_GPU" =~ ^[Yy]$ ]]; then
        echo "  GPU switch:  $AS_DIR/gpu-mode.sh {images|llm|status}  (small-GPU mode ON)"
    fi
    echo ""
}
