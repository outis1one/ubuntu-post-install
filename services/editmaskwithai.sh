#!/bin/bash
# services/editmaskwithai.sh — Self-hosted AI photo editor: paint a mask over an
# object, describe the change, and AI replaces only that region.
# Source: https://github.com/outis1one/EditmaskwithAI
# Part of the modular post-install system (sourced by setup.sh).
#
# Two deployment modes (chosen at install):
#   Cloud  — no GPU; uses a cloud provider (OpenAI gpt-image / Replicate). Lightweight.
#   GPU    — local inference via the repo's own installer (NVIDIA, downloads ~13 GB).
#
# The app reads config from a .env file the compose file interpolates
# (${AI_PROVIDER}, ${OPENAI_API_KEY}, ${SECRET_KEY}, ...). No env_file: directive.
# No built-in auth — protect with Authelia via Caddy.

register_service editmaskwithai utilities "AI photo editor — mask a region, AI replaces it (EditmaskwithAI)" 3080

install_editmaskwithai() {
    require_docker || return 1
    log_info "Installing EditmaskwithAI (mask-based AI photo editor)..."

    local EMA_DIR="$DOCKER_DIR/editmaskwithai"
    local REPO_URL="https://github.com/outis1one/EditmaskwithAI.git"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would clone $REPO_URL to $EMA_DIR"
        echo "[DRY-RUN] Would prompt for deployment mode (Cloud API / Local GPU)"
        echo "[DRY-RUN] Would create .env from .env.example (AI_PROVIDER, API key, SECRET_KEY)"
        echo "[DRY-RUN] Cloud: docker compose up -d --build | GPU: install-local-gpu.sh + bring-up-local-gpu.sh"
        echo "[DRY-RUN] Would offer Authelia SSO and configure Caddy (ai-photo-edit:8000, host port 3080)"
        return 0
    fi

    # ── Clone / update ────────────────────────────────────────────────────────
    if [ -d "$EMA_DIR/.git" ]; then
        log_info "Updating EditmaskwithAI repo..."
        git -C "$EMA_DIR" pull --ff-only 2>/dev/null \
            && log_success "Repo updated" \
            || log_warning "Could not pull latest — using existing checkout"
    else
        log_info "Cloning EditmaskwithAI..."
        git clone --depth 1 "$REPO_URL" "$EMA_DIR" \
            || { log_error "Clone failed — check network and git access"; return 1; }
    fi
    ensure_docker_dir_ownership "$EMA_DIR"
    cd "$EMA_DIR" || return 1

    # ── Deployment mode ───────────────────────────────────────────────────────
    echo ""
    log_info "Deployment mode:"
    log_info "  1) Cloud API   No GPU needed. Uses OpenAI (gpt-image) or Replicate. Lightweight."
    log_info "  2) Local GPU   NVIDIA GPU; runs the repo's installer and downloads ~13 GB of models."
    echo ""
    local EMA_MODE=""
    prompt_text "Mode [1=Cloud]:" "1" EMA_MODE

    # ── .env from the repo's template ─────────────────────────────────────────
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        log_warning ".env.example missing from repo — writing a fresh .env"
        : > .env
    fi

    # Upsert KEY=VALUE into ./.env (drop any existing/commented line, then append)
    _ema_set_env() {
        sed -i -E "/^#?[[:space:]]*$1=/d" .env
        printf '%s=%s\n' "$1" "$2" >> .env
    }

    local EMA_PROVIDER="local_gpu"
    if [[ "$EMA_MODE" != "2" ]]; then
        echo ""
        log_info "Cloud provider:"
        log_info "  1) OpenAI     gpt-image editing. Key: https://platform.openai.com/api-keys"
        log_info "  2) Replicate  SDXL-inpaint / LaMa etc. Key: https://replicate.com/account/api-tokens"
        echo ""
        local _prov=""
        prompt_text "Provider [1=OpenAI]:" "1" _prov
        local _key=""
        if [[ "$_prov" == "2" ]]; then
            EMA_PROVIDER="replicate"
            prompt_text "Replicate API key (enter to set later):" "" _key
            if [ -n "$_key" ]; then _ema_set_env REPLICATE_API_KEY "$_key"
            else log_warning "No key entered — set REPLICATE_API_KEY in .env later"; fi
        else
            EMA_PROVIDER="openai"
            prompt_text "OpenAI API key (enter to set later):" "" _key
            if [ -n "$_key" ]; then _ema_set_env OPENAI_API_KEY "$_key"
            else log_warning "No key entered — set OPENAI_API_KEY in .env later"; fi
        fi
    else
        local _hf=""
        prompt_text "HuggingFace token (optional — for gated models, enter to skip):" "" _hf
        [ -n "$_hf" ] && _ema_set_env HF_TOKEN "$_hf"
    fi

    _ema_set_env AI_PROVIDER "$EMA_PROVIDER"
    _ema_set_env SECRET_KEY "$(generate_password 48)"
    chmod 600 .env
    mkdir -p data
    ensure_docker_dir_ownership "$EMA_DIR"

    # ── Caddy network override (cloud mode) ───────────────────────────────────
    # The base compose has no networks, so Caddy (on caddy_net) can't reach the
    # container by name. An override file — auto-merged with the default compose —
    # attaches the app to caddy_net. The GPU compose is run with an explicit -f and
    # does NOT merge overrides, so GPU mode is wired with `docker network connect`.
    if [[ "$EMA_MODE" != "2" ]] && [ -d "$DOCKER_DIR/caddy" ]; then
        cat > docker-compose.override.yml << OVR
# Added by ubuntu-post-install so Caddy (on caddy_net) can reach this app by name.
services:
  app:
    networks:
      - caddy_net
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
OVR
        ensure_docker_dir_ownership "$EMA_DIR/docker-compose.override.yml"
    fi

    # ── Bring the stack up ────────────────────────────────────────────────────
    local START_EMA=""
    if [[ "$EMA_MODE" == "2" ]]; then
        echo ""
        log_warning "GPU mode runs the repo's installer (NVIDIA toolkit, DNS fix) and downloads ~13 GB."
        prompt_yn "Run the local-GPU installer now? (y/n):" "y" START_EMA
        if [[ "$START_EMA" =~ ^[Yy]$ ]]; then
            if [ -f install-local-gpu.sh ] && [ -f bring-up-local-gpu.sh ]; then
                chmod +x install-local-gpu.sh bring-up-local-gpu.sh 2>/dev/null || true
                bash install-local-gpu.sh || log_warning "install-local-gpu.sh reported an error — see output above"
                bash bring-up-local-gpu.sh || log_warning "bring-up-local-gpu.sh failed — check: docker compose -f docker-compose.gpu.yml logs"
            else
                log_warning "GPU scripts not found in repo — start manually per the README"
            fi
        fi
    else
        prompt_yn "Build and start EditmaskwithAI now? (y/n):" "y" START_EMA
        if [[ "$START_EMA" =~ ^[Yy]$ ]]; then
            docker compose up -d --build \
                && log_success "EditmaskwithAI started" \
                || log_warning "Start failed — check: docker compose logs"
        fi
    fi

    # Ensure the running container is on caddy_net (covers GPU mode, where the
    # override file above is not merged by the repo's bring-up script).
    if [ -d "$DOCKER_DIR/caddy" ] && [[ "$START_EMA" =~ ^[Yy]$ ]]; then
        docker network connect "$SITE_CADDY_NET" ai-photo-edit 2>/dev/null || true
    fi

    # ── Auth + Caddy ──────────────────────────────────────────────────────────
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect EditmaskwithAI with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "EditmaskwithAI" "ai-photo-edit:8000" "editmask" "$EXTRA_BLOCK"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EMA_DIR" << MD
# EditmaskwithAI

Self-hosted AI photo editor: paint a mask over any object, describe what you
want, and the AI replaces just that region — pixels outside the mask are left
untouched. Source: https://github.com/outis1one/EditmaskwithAI

- URL: http://localhost:3080
- No built-in login — protect via Authelia SSO if exposed.
- Provider: set \`AI_PROVIDER\` in \`.env\` (openai, replicate, local_gpu, stability, comfyui, invokeai).

## Configure providers / keys
Edit \`.env\` then restart (the compose file interpolates these — there is no env_file):
\`\`\`bash
cd $EMA_DIR
nano .env        # AI_PROVIDER, OPENAI_API_KEY / REPLICATE_API_KEY, HF_TOKEN
docker compose up -d --build
\`\`\`
Keys: OpenAI https://platform.openai.com/api-keys · Replicate https://replicate.com/account/api-tokens

## Cloud mode (no GPU)
\`\`\`bash
cd $EMA_DIR
docker compose up -d --build      # starts on http://localhost:3080
docker compose logs -f
docker compose down
\`\`\`

## Local GPU mode (NVIDIA, ~13 GB of models)
\`\`\`bash
cd $EMA_DIR
./install-local-gpu.sh            # toolkit + DNS fix + model prefetch
./bring-up-local-gpu.sh           # docker compose -f docker-compose.gpu.yml up -d --build
./bring-up-local-gpu.sh logs -f
\`\`\`
GPU auto-selects models by VRAM (FLUX >=24 GB, SDXL 12-24 GB, SD 1.5 <2 GB).

## Caddy
Reverse-proxied as \`ai-photo-edit:8000\` on \`${SITE_CADDY_NET:-caddy_net}\`.
Cloud mode joins that network via \`docker-compose.override.yml\`; GPU mode is
attached with \`docker network connect\` after start (the GPU compose file does
not merge the override).
MD

    echo ""
    echo "  URL:       http://localhost:3080"
    echo "  Dir:       $EMA_DIR"
    echo "  Provider:  $EMA_PROVIDER  (change AI_PROVIDER in $EMA_DIR/.env)"
    echo ""
}
