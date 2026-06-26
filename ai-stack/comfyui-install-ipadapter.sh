#!/usr/bin/env bash
# Install IP-Adapter custom nodes + models into ComfyUI's Docker container
# Enables: same face/different settings, age up/down, emotion changes, style transfer
#
# Usage:
#   ./comfyui-install-ipadapter.sh              — install for SDXL (recommended)
#   ./comfyui-install-ipadapter.sh --sd15       — install for SD 1.5
#   ./comfyui-install-ipadapter.sh --all        — install both SDXL + SD 1.5
#   ./comfyui-install-ipadapter.sh --faceid     — also install FaceID (better face lock)
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[..]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[!!]${NC}  $*"; }
die()   { echo -e "${RED}[XX]${NC}  $*" >&2; exit 1; }

# ── parse args ──────────────────────────────────────────────────────────────
INSTALL_SD15=false
INSTALL_SDXL=true
INSTALL_FACEID=false

for arg in "$@"; do
    case "$arg" in
        --sd15)   INSTALL_SD15=true; INSTALL_SDXL=false ;;
        --all)    INSTALL_SD15=true; INSTALL_SDXL=true ;;
        --faceid) INSTALL_FACEID=true ;;
        --help|-h)
            echo -e "${BOLD}Usage:${NC} $0 [--sd15] [--all] [--faceid]"
            echo ""
            echo "  Installs IP-Adapter custom nodes and models into ComfyUI."
            echo "  Enables reference-image workflows: same face in different"
            echo "  settings, age changes, emotions, style transfer."
            echo ""
            echo "  Options:"
            echo "    --sd15     Install SD 1.5 models (instead of SDXL)"
            echo "    --all      Install both SDXL + SD 1.5 models"
            echo "    --faceid   Also install FaceID models (better face lock,"
            echo "               requires insightface — adds ~1GB)"
            echo ""
            echo "  Default: SDXL models only (~2.5GB download)"
            exit 0
            ;;
    esac
done

# ── check container ─────────────────────────────────────────────────────────
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^comfyui$'; then
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^comfyui$'; then
        warn "ComfyUI container is stopped. Starting it..."
        docker start comfyui
        sleep 5
    else
        die "ComfyUI container not found. Is the AI stack running?"
    fi
fi

# ── helper: download into container ─────────────────────────────────────────
# Usage: dl_model <url> <container_path>
dl_model() {
    local url="$1" dest="$2"
    local filename; filename=$(basename "$dest")
    if docker exec comfyui test -f "$dest" 2>/dev/null; then
        ok "Already exists: $filename"
        return 0
    fi
    local dir; dir=$(dirname "$dest")
    docker exec comfyui mkdir -p "$dir"
    info "Downloading $filename..."
    if ! docker exec comfyui wget -q --show-progress -O "$dest" "$url" 2>&1; then
        # wget --show-progress not always available
        docker exec comfyui wget -q -O "$dest" "$url"
    fi
    ok "Downloaded $filename"
}

HF_IPA="https://huggingface.co/h94/IP-Adapter/resolve/main"
MODELS="/opt/ComfyUI/models"

# ── Step 1: Install custom nodes ────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━  IP-Adapter Installation for ComfyUI  ━━━${NC}"
echo ""

info "Installing ComfyUI_IPAdapter_plus custom nodes..."
if docker exec comfyui test -d /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus 2>/dev/null; then
    info "Custom nodes already installed — pulling updates..."
    docker exec comfyui bash -c "cd /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus && git pull -q"
    ok "Custom nodes updated"
else
    docker exec comfyui bash -c "cd /opt/ComfyUI/custom_nodes && git clone --depth 1 https://github.com/cubiq/ComfyUI_IPAdapter_plus.git"
    ok "Custom nodes installed"
fi

# Install Python dependencies if requirements.txt exists
if docker exec comfyui test -f /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus/requirements.txt 2>/dev/null; then
    info "Installing Python dependencies..."
    docker exec comfyui pip install -q -r /opt/ComfyUI/custom_nodes/ComfyUI_IPAdapter_plus/requirements.txt 2>/dev/null || true
fi

# ── Step 2: CLIP Vision models (required by all variants) ───────────────────
echo ""
info "Downloading CLIP Vision encoders..."

dl_model \
    "https://huggingface.co/h94/IP-Adapter/resolve/main/models/image_encoder/model.safetensors" \
    "$MODELS/clip_vision/CLIP-ViT-H-14-laion2B-s32B-b79K.safetensors"

if $INSTALL_SDXL; then
    dl_model \
        "https://huggingface.co/h94/IP-Adapter/resolve/main/sdxl_models/image_encoder/model.safetensors" \
        "$MODELS/clip_vision/CLIP-ViT-bigG-14-laion2B-39B-b160k.safetensors"
fi

# ── Step 3: IP-Adapter models ──────────────────────────────────────────────
echo ""
docker exec comfyui mkdir -p "$MODELS/ipadapter"

if $INSTALL_SDXL; then
    info "Downloading SDXL IP-Adapter models..."
    dl_model "$HF_IPA/sdxl_models/ip-adapter-plus_sdxl_vit-h.safetensors" \
             "$MODELS/ipadapter/ip-adapter-plus_sdxl_vit-h.safetensors"
    dl_model "$HF_IPA/sdxl_models/ip-adapter-plus-face_sdxl_vit-h.safetensors" \
             "$MODELS/ipadapter/ip-adapter-plus-face_sdxl_vit-h.safetensors"
fi

if $INSTALL_SD15; then
    info "Downloading SD 1.5 IP-Adapter models..."
    dl_model "$HF_IPA/models/ip-adapter-plus_sd15.safetensors" \
             "$MODELS/ipadapter/ip-adapter-plus_sd15.safetensors"
    dl_model "$HF_IPA/models/ip-adapter-plus-face_sd15.safetensors" \
             "$MODELS/ipadapter/ip-adapter-plus-face_sd15.safetensors"
fi

# ── Step 4 (optional): FaceID models ───────────────────────────────────────
if $INSTALL_FACEID; then
    echo ""
    info "Installing FaceID dependencies (insightface, onnxruntime)..."
    docker exec comfyui pip install -q insightface onnxruntime 2>/dev/null \
        || warn "Could not install insightface — FaceID nodes may not work"

    HF_FACEID="https://huggingface.co/h94/IP-Adapter-FaceID/resolve/main"
    info "Downloading FaceID models..."

    if $INSTALL_SDXL; then
        dl_model "$HF_FACEID/ip-adapter-faceid-plusv2_sdxl.bin" \
                 "$MODELS/ipadapter/ip-adapter-faceid-plusv2_sdxl.bin"
    fi
    if $INSTALL_SD15; then
        dl_model "$HF_FACEID/ip-adapter-faceid-plusv2_sd15.bin" \
                 "$MODELS/ipadapter/ip-adapter-faceid-plusv2_sd15.bin"
    fi

    # FaceID LoRAs (required for FaceID models)
    docker exec comfyui mkdir -p "$MODELS/loras"
    if $INSTALL_SDXL; then
        dl_model "$HF_FACEID/ip-adapter-faceid-plusv2_sdxl_lora.safetensors" \
                 "$MODELS/loras/ip-adapter-faceid-plusv2_sdxl_lora.safetensors"
    fi
    if $INSTALL_SD15; then
        dl_model "$HF_FACEID/ip-adapter-faceid-plusv2_sd15_lora.safetensors" \
                 "$MODELS/loras/ip-adapter-faceid-plusv2_sd15_lora.safetensors"
    fi
fi

# ── Done ────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━  Installation complete!  ━━━${NC}"
echo ""
echo -e "${BOLD}Restart ComfyUI to load new nodes:${NC}"
echo "  docker restart comfyui"
echo ""
echo -e "${BOLD}Then open ComfyUI at http://localhost:8188 and try it:${NC}"
echo ""
echo "  Basic reference image (style/scene transfer):"
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │ [Load Checkpoint]──→[Load Image]──→[IPAdapter Unified Loader]   │"
echo "  │         │                               │                       │"
echo "  │         ├── MODEL ──────────────→ [IPAdapter Apply] → [KSampler]│"
echo "  │         └── CLIP → [CLIP Text Encode]──→ positive ──→           │"
echo "  │                    \"a castle at sunset\"                         │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
echo "  1. Add nodes: right-click → Add Node → ipadapter"
echo "  2. ${BOLD}IPAdapter Unified Loader${NC}: set preset to '${BOLD}PLUS FACE (portrait)${NC}'"
echo "  3. ${BOLD}Load Image${NC}: upload your reference photo"
echo "  4. ${BOLD}IPAdapter Apply${NC}: connect model + image, set weight 0.7–1.0"
echo "  5. Text prompt controls the new scene: \"elderly, sitting in cafe, smiling\""
echo ""
echo -e "${BOLD}What each preset does:${NC}"
echo "  PLUS          — general style/scene transfer"
echo "  PLUS FACE     — preserves face likeness (best for your use case)"
if $INSTALL_FACEID; then
echo "  FACEID PLUSV2  — strongest face lock (uses insightface for detection)"
fi
echo ""
echo -e "${BOLD}Example prompts with a reference face:${NC}"
echo "  • \"same person, elderly, wise expression, studio lighting\""
echo "  • \"same person as a child, playing in a park, happy\""
echo "  • \"same person, crying, dramatic lighting, black and white\""
echo "  • \"same person, oil painting style, renaissance setting\""
echo ""
echo -e "${YELLOW}Note:${NC} This works directly in ComfyUI. Open WebUI's ComfyUI integration"
echo "     only sends text prompts — it can't attach a reference image."
echo "     For chat-based image gen (without reference images), use LoRAs instead."
