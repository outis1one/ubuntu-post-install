#!/bin/bash
# services/paintplus.sh — PaintPlus: self-hosted AI photo editor. Paint a mask over
# an object, describe the change, and AI replaces only that region.
#
# The full application source is vendored in this repo under ./paintplus and is
# copied to ~/docker/paintplus/src at install time (no network clone).
# Based on EditmaskwithAI (github.com/outis1one/EditmaskwithAI).
# Part of the modular post-install system (sourced by setup.sh).
#
# Two deployment modes (chosen at install):
#   Cloud  — no GPU; uses a cloud provider (OpenAI gpt-image / Replicate). Lightweight.
#   GPU    — local inference via the app's own installer (NVIDIA, downloads ~13 GB).
#
# The app reads config from a .env the compose file interpolates
# (${AI_PROVIDER}, ${OPENAI_API_KEY}, ${SECRET_KEY}, ...). No env_file: directive.
# No built-in auth — protect with Authelia via Caddy.

register_service paintplus utilities "AI photo editor — mask a region, AI replaces it (PaintPlus)" 3080

install_paintplus() {
    require_docker || return 1
    log_info "Installing PaintPlus (mask-based AI photo editor)..."

    # Vendored application source lives in this repo at <repo>/paintplus
    local SELF_DIR SRC_DIR
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SRC_DIR="$(cd "$SELF_DIR/.." && pwd)/paintplus"

    local PP_DIR="$DOCKER_DIR/paintplus"
    local APP_DIR="$PP_DIR/src"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would copy vendored source $SRC_DIR -> $APP_DIR"
        echo "[DRY-RUN] Would prompt for deployment mode (Cloud API / Local GPU)"
        echo "[DRY-RUN] Would create .env (AI_PROVIDER, API key, SECRET_KEY)"
        echo "[DRY-RUN] Cloud: docker compose up -d --build | GPU: install-local-gpu.sh + bring-up-local-gpu.sh"
        echo "[DRY-RUN] Would offer Authelia SSO and configure Caddy (paintplus:8000, host port 3080)"
        return 0
    fi

    if [ ! -d "$SRC_DIR" ]; then
        log_error "Vendored PaintPlus source not found at $SRC_DIR"
        return 1
    fi

    # ── Copy vendored source into the docker dir ──────────────────────────────
    # Refreshes app files; leaves a user-edited .env and the override untouched
    # (neither is part of the vendored source).
    mkdir -p "$APP_DIR"
    cp -a "$SRC_DIR/." "$APP_DIR/"
    ensure_docker_dir_ownership "$PP_DIR"
    cd "$APP_DIR" || return 1

    # ── Deployment mode ───────────────────────────────────────────────────────
    echo ""
    log_info "Deployment mode:"
    log_info "  1) Cloud API   No GPU needed. Uses OpenAI (gpt-image) or Replicate. Lightweight."
    log_info "  2) Local GPU   NVIDIA GPU; runs the app's installer and downloads ~13 GB of models."
    echo ""
    local PP_MODE=""
    prompt_text "Mode [1=Cloud]:" "1" PP_MODE

    # ── .env from the app's template ──────────────────────────────────────────
    if [ -f .env.example ]; then
        cp .env.example .env
    else
        log_warning ".env.example missing — writing a fresh .env"
        : > .env
    fi

    # Upsert KEY=VALUE into ./.env (drop any existing/commented line, then append)
    _pp_set_env() {
        sed -i -E "/^#?[[:space:]]*$1=/d" .env
        printf '%s=%s\n' "$1" "$2" >> .env
    }

    local PP_PROVIDER="local_gpu"
    if [[ "$PP_MODE" != "2" ]]; then
        echo ""
        log_info "Cloud provider:"
        log_info "  1) OpenAI     gpt-image editing. Key: https://platform.openai.com/api-keys"
        log_info "  2) Replicate  SDXL-inpaint / LaMa etc. Key: https://replicate.com/account/api-tokens"
        echo ""
        local _prov=""
        prompt_text "Provider [1=OpenAI]:" "1" _prov
        local _key=""
        if [[ "$_prov" == "2" ]]; then
            PP_PROVIDER="replicate"
            prompt_text "Replicate API key (enter to set later):" "" _key
            if [ -n "$_key" ]; then _pp_set_env REPLICATE_API_KEY "$_key"
            else log_warning "No key entered — set REPLICATE_API_KEY in .env later"; fi
        else
            PP_PROVIDER="openai"
            prompt_text "OpenAI API key (enter to set later):" "" _key
            if [ -n "$_key" ]; then _pp_set_env OPENAI_API_KEY "$_key"
            else log_warning "No key entered — set OPENAI_API_KEY in .env later"; fi
        fi
    else
        local _hf=""
        prompt_text "HuggingFace token (optional — for gated models, enter to skip):" "" _hf
        [ -n "$_hf" ] && _pp_set_env HF_TOKEN "$_hf"
    fi

    _pp_set_env AI_PROVIDER "$PP_PROVIDER"
    _pp_set_env SECRET_KEY "$(generate_password 48)"
    chmod 600 .env
    mkdir -p data
    ensure_docker_dir_ownership "$PP_DIR"

    # ── Caddy network override (cloud mode) ───────────────────────────────────
    # The base compose has no networks, so Caddy (on caddy_net) can't reach the
    # container by name. This override — auto-merged with the default compose —
    # attaches the app to caddy_net. The GPU compose runs with an explicit -f and
    # does NOT merge overrides, so GPU mode is wired with `docker network connect`.
    if [[ "$PP_MODE" != "2" ]] && [ -d "$DOCKER_DIR/caddy" ]; then
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
    fi

    # ── Bring the stack up ────────────────────────────────────────────────────
    local START_PP=""
    if [[ "$PP_MODE" == "2" ]]; then
        echo ""
        log_warning "GPU mode runs the app's installer (NVIDIA toolkit, DNS fix) and downloads ~13 GB."
        prompt_yn "Run the local-GPU installer now? (y/n):" "y" START_PP
        if [[ "$START_PP" =~ ^[Yy]$ ]]; then
            if [ -f install-local-gpu.sh ] && [ -f bring-up-local-gpu.sh ]; then
                chmod +x install-local-gpu.sh bring-up-local-gpu.sh 2>/dev/null || true
                bash install-local-gpu.sh || log_warning "install-local-gpu.sh reported an error — see output above"
                bash bring-up-local-gpu.sh || log_warning "bring-up-local-gpu.sh failed — check: docker compose -f docker-compose.gpu.yml logs"
            else
                log_warning "GPU scripts not found — start manually per src/README.md"
            fi
        fi
    else
        prompt_yn "Build and start PaintPlus now? (y/n):" "y" START_PP
        if [[ "$START_PP" =~ ^[Yy]$ ]]; then
            docker compose up -d --build \
                && log_success "PaintPlus started" \
                || log_warning "Start failed — check: docker compose logs"
        fi
    fi

    # Ensure the running container is on caddy_net (covers GPU mode, where the
    # override file above is not merged by the app's bring-up script).
    if [ -d "$DOCKER_DIR/caddy" ] && [[ "$START_PP" =~ ^[Yy]$ ]]; then
        docker network connect "$SITE_CADDY_NET" paintplus 2>/dev/null || true
    fi

    # ── Auth + Caddy ──────────────────────────────────────────────────────────
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect PaintPlus with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "PaintPlus" "paintplus:8000" "paintplus" "$EXTRA_BLOCK"

    # ── README (deploy notes; the app's own docs are at src/README.md) ────────
    write_readme "$PP_DIR" << MD
# PaintPlus (deployment)

Self-hosted AI photo editor: paint a mask over any object, describe what you
want, and the AI replaces just that region. The application source is vendored
in ubuntu-post-install and copied here to \`src/\` (no network clone).
App docs: \`src/README.md\`. Based on EditmaskwithAI.

- URL: http://localhost:3080
- No built-in login — protect via Authelia SSO if exposed.
- Provider: set \`AI_PROVIDER\` in \`src/.env\` (openai, replicate, local_gpu, stability, comfyui, invokeai).

## Configure providers / keys
Edit \`src/.env\` then restart (the compose file interpolates these — no env_file):
\`\`\`bash
cd $APP_DIR
nano .env        # AI_PROVIDER, OPENAI_API_KEY / REPLICATE_API_KEY, HF_TOKEN
docker compose up -d --build
\`\`\`
Keys: OpenAI https://platform.openai.com/api-keys · Replicate https://replicate.com/account/api-tokens

## Cloud mode (no GPU)
\`\`\`bash
cd $APP_DIR
docker compose up -d --build      # starts on http://localhost:3080
docker compose logs -f
docker compose down
\`\`\`

## Local GPU mode (NVIDIA, ~13 GB of models)
\`\`\`bash
cd $APP_DIR
./install-local-gpu.sh            # toolkit + DNS fix + model prefetch
./bring-up-local-gpu.sh           # docker compose -f docker-compose.gpu.yml up -d --build
\`\`\`
GPU auto-selects models by VRAM (FLUX >=24 GB, SDXL 12-24 GB, SD 1.5 <2 GB).

## Update the app
Re-run the PaintPlus installer (copies the latest vendored source over \`src/\`,
keeping your \`src/.env\`), then rebuild:
\`\`\`bash
cd $APP_DIR && docker compose up -d --build
\`\`\`

## Caddy
Reverse-proxied as \`paintplus:8000\` on \`${SITE_CADDY_NET:-caddy_net}\`. Cloud mode
joins that network via \`src/docker-compose.override.yml\`; GPU mode is attached
with \`docker network connect\` after start.
MD

    echo ""
    echo "  URL:       http://localhost:3080"
    echo "  App dir:   $APP_DIR"
    echo "  Provider:  $PP_PROVIDER  (change AI_PROVIDER in $APP_DIR/.env)"
    echo ""
}
