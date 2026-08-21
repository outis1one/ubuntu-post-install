#!/bin/bash
# services/ai-stack.sh — Local AI Stack: a full self-hosted AI environment.
#
# Vendored from github.com/outis1one/local-ai into this repo under vendor/ai-stack
# and copied to ~/docker/ai-stack at install time (no network clone). Bundles:
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
    SRC_DIR="$(cd "$SELF_DIR/.." && pwd)/vendor/ai-stack"

    local AS_DIR="$DOCKER_DIR/ai-stack"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would copy vendored source $SRC_DIR -> $AS_DIR"
        echo "[DRY-RUN] Would optionally collect cloud LLM provider keys (Groq/DeepInfra/OpenAI/OpenRouter)"
        echo "[DRY-RUN] Would run the app installer local-ai-setup.sh (Docker/NVIDIA toolkit, VRAM-aware models, generates compose/.env, starts stack, registers systemd 'local-ai')"
        echo "[DRY-RUN] Would offer an optional vision-capable model to pull (moondream/llava/qwen2.5vl/llama3.2-vision) via the generated pull-models.sh"
        echo "[DRY-RUN] Would offer to stop optional services not wanted (Gitea/Portainer/Kiwix/InvokeAI/ComfyUI/Aider) after the full stack starts"
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
    log_info "  0) Skip — stay fully local"
    echo ""
    log_info "  Example: '1 2' wires Groq + DeepInfra."
    echo ""

    local CLOUD_CHOICES=""
    prompt_text "Cloud providers to add (0 or blank = skip, stay fully local):" "" CLOUD_CHOICES

    # Parallel arrays: display name, OpenAI-compatible base URL, and entered key
    declare -a CLOUD_NAMES=() CLOUD_URLS=() CLOUD_KEYS=()
    local _c _cname _curl _ckey
    for _c in $CLOUD_CHOICES; do
        _cname="" ; _curl=""
        case "$_c" in
            0) continue ;;
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

    # local-ai-setup.sh runs as whoever invoked this wrapper — root, since
    # setup.sh itself is run via sudo — so everything it just generated
    # (docker-compose.yml, .env, requirements.txt, server.py, pull-models.sh,
    # etc.) comes out root-owned. Hand it back to ACTUAL_USER unconditionally,
    # not just on the cloud-provider path below. Confirmed live: without this,
    # re-running local-ai-setup.sh directly later (the update path, plain user,
    # no sudo — exactly what its own "run later" message above tells you to do)
    # fails with "Permission denied" on any file the first root-run created,
    # e.g. requirements.txt.
    ensure_docker_dir_ownership "$AS_DIR"

    # ── Optional services — not everyone wants the whole stack running ────────
    # local-ai-setup.sh above always generates and starts every service in the
    # stack unconditionally — Ollama/Open WebUI/ChromaDB/RAG/MCP (the core) plus
    # Gitea, Portainer, Kiwix, InvokeAI, ComfyUI, and Aider. Several of those
    # are genuinely optional depending on the box — e.g. Gitea when you already
    # run git elsewhere, or Portainer when you manage Docker some other way.
    # Rather than make local-ai-setup.sh's own compose generation conditional
    # (risky: it's vendored upstream code, and other services reference these
    # by container name/network in ways that would need auditing one by one),
    # just stop the ones not wanted after the fact — images are already pulled
    # either way, and `docker compose up -d <name>` brings any of them back
    # later with no reinstall needed. User feedback: wanted this choice instead
    # of always getting the full stack.
    if [ "$INSTALLER_RAN" = true ]; then
        echo ""
        log_info "The full stack is running. Some of these are genuinely optional —"
        log_info "stop the ones you don't need (start any of them again later with"
        log_info "'docker compose up -d <service>', no reinstall required):"
        echo ""
        echo "    1) Gitea         — skip if you already run git elsewhere"
        echo "    2) Portainer     — skip if you manage Docker some other way"
        echo "    3) Kiwix         — offline Wikipedia/docs server"
        echo "    4) InvokeAI      — image generation (SD/SDXL/Flux)"
        echo "    5) ComfyUI       — image generation (node-based)"
        echo "    6) Aider         — AI pair-programming CLI"
        echo "    7) RAG/MCP stack — ChromaDB + rag-server + mcp-server, for Open WebUI's"
        echo "                       RAG tab and MCP tool-calling. Skip if you don't use"
        echo "                       those — plain Ollama chat in Open WebUI (and anything"
        echo "                       else, like Mealie, talking to Ollama directly) works"
        echo "                       fine without this; only that one tab needs it."
        echo ""
        local STOP_CHOICES=""
        prompt_text "Stop which of these? (space-separated numbers, blank to keep everything running):" "" STOP_CHOICES
        local _s _svc
        declare -a _TO_STOP=()
        local _stopping_kiwix=false
        for _s in $STOP_CHOICES; do
            case "$_s" in
                1) _TO_STOP+=("gitea") ;;
                2) _TO_STOP+=("portainer") ;;
                3) _TO_STOP+=("kiwix"); _stopping_kiwix=true ;;
                4) _TO_STOP+=("invokeai") ;;
                5) _TO_STOP+=("comfyui") ;;
                6) _TO_STOP+=("aider") ;;
                # Bundled, not three separate numbers: mcp-server depends_on
                # rag-server which depends_on chromadb, so stopping only one
                # of the three leaves the others running against a dead
                # dependency instead of a clean, fully-stopped chain.
                7) _TO_STOP+=("mcp-server" "rag-server" "chromadb") ;;
                *) log_warning "Ignoring unknown choice '$_s'"; continue ;;
            esac
        done
        # mcp-server also depends_on kiwix (not just rag-server) — stopping
        # kiwix without also stopping mcp-server leaves it running against a
        # dependency that's down, the same inconsistent state option 7 above
        # is written to avoid. Cascade automatically rather than trust the
        # user to notice the same rule applies here too.
        if [ "$_stopping_kiwix" = true ] && [[ ! " ${_TO_STOP[*]} " == *" mcp-server "* ]]; then
            log_info "Kiwix is also a dependency of mcp-server — stopping that too."
            _TO_STOP+=("mcp-server")
        fi
        if [ ${#_TO_STOP[@]} -gt 0 ]; then
            # Dedupe in case option 7 and the kiwix cascade both added mcp-server.
            local -a _TO_STOP_UNIQUE=()
            local _seen=" "
            for _svc in "${_TO_STOP[@]}"; do
                [[ "$_seen" == *" $_svc "* ]] && continue
                _TO_STOP_UNIQUE+=("$_svc")
                _seen+="$_svc "
            done
            (cd "$AS_DIR" && docker compose stop "${_TO_STOP_UNIQUE[@]}") \
                && log_success "Stopped: ${_TO_STOP_UNIQUE[*]} (images still pulled — bring any back with: docker compose up -d <name>)" \
                || log_warning "Couldn't stop one or more services — check: docker compose ps"
        fi
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
    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't reach this container by name over a bridge network
    # it isn't on anyway.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"
    if [ "$_CADDY_MODE" = "local" ] && [ "$INSTALLER_RAN" = true ]; then
        docker network connect "$SITE_CADDY_NET" open-webui 2>/dev/null || true
    fi
    configure_caddy_for_service "Open WebUI" "open-webui:8080" "ai"

    # ── Deploy notes (the app's own docs stay at $AS_DIR/README.md) ───────────
    # Filename is deliberately not README.md — that name is already taken by
    # the vendored app's own docs, copied into this same directory above.
    # Static content (roles, GPU switcher, service URLs, etc.) lives in the
    # companion services/ai-stack.md and gets appended below, same idea as
    # write_readme's own companion-doc convention (lib/common.sh) but manual
    # here since write_readme always targets README.md.
    cat > "$AS_DIR/POST-INSTALL-NOTES.md" << MD
# Local AI Stack — deployment notes (ubuntu-post-install)

Vendored app source copied here from the \`ai-stack\` service. Full app docs:
\`README.md\` in this directory. Source: github.com/outis1one/local-ai
MD
    if [ -f "$SELF_DIR/ai-stack.md" ]; then
        cat "$SELF_DIR/ai-stack.md" >> "$AS_DIR/POST-INSTALL-NOTES.md"
    fi
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
