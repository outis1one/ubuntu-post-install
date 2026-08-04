#!/usr/bin/env bash
# Detect GPU VRAM and install appropriate Stable Diffusion models for
# InvokeAI and/or ComfyUI.  Run anytime — safe to re-run.
#
# Usage: ./setup-image-models.sh [--auto]
#   --auto    Skip prompts, install the recommended default for your GPU
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[..]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[!!]${NC}  $*"; }

AUTO=false
[[ "${1:-}" == "--auto" ]] && AUTO=true

# ── Detect GPU ────────────────────────────────────────────────────────────────
VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
          | head -1 | awk '{printf "%d", $1/1024}' 2>/dev/null || echo "0")
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo "0")
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "None")
TOTAL_VRAM=$((VRAM_GB * GPU_COUNT))

echo ""
echo -e "${BOLD}━━━  Image Generation Model Setup  ━━━${NC}"
echo ""
info "GPU       : $GPU_NAME"
[[ "$GPU_COUNT" -gt 1 ]] && info "GPU count : $GPU_COUNT"
info "VRAM/card : ${VRAM_GB}GB"
info "Total VRAM: ${TOTAL_VRAM}GB"
echo ""

# ── Determine which containers are available ──────────────────────────────────
HAS_INVOKEAI=false
HAS_COMFYUI=false
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^invokeai$' && HAS_INVOKEAI=true
docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^comfyui$'  && HAS_COMFYUI=true

if ! $HAS_INVOKEAI && ! $HAS_COMFYUI; then
    echo -e "${RED}Error:${NC} Neither InvokeAI nor ComfyUI containers found."
    echo "  Run the setup script first to deploy the AI stack."
    exit 1
fi

$HAS_INVOKEAI && info "InvokeAI : found"
$HAS_COMFYUI  && info "ComfyUI  : found"
echo ""

# ── Build model menu based on VRAM ────────────────────────────────────────────
# Model VRAM requirements (generation, not just loading):
#   SD 1.5          ~4GB   512x512 native
#   SDXL            ~7GB   1024x1024 native
#   SDXL Turbo      ~7GB   512x512 (4-step)
#   Flux.1-schnell  ~12GB  fast, high quality
#   Flux.1-dev      ~20GB  best quality, slow

declare -a MODEL_IDS=()
declare -a MODEL_NAMES=()
declare -a MODEL_VRAM=()
declare -a MODEL_NOTES=()

add_model() {
    MODEL_IDS+=("$1"); MODEL_NAMES+=("$2"); MODEL_VRAM+=("$3"); MODEL_NOTES+=("$4")
}

# Always offer SD 1.5 if any GPU exists
if [[ "$TOTAL_VRAM" -ge 4 ]]; then
    add_model "sd15" "Stable Diffusion 1.5" "4" "512px native, most LoRA compatible, fast"
fi

if [[ "$TOTAL_VRAM" -ge 8 ]]; then
    add_model "sdxl" "Stable Diffusion XL" "7" "1024px native, better quality, more detail"
    add_model "sdxl-turbo" "SDXL Turbo" "7" "4-step generation, very fast, good quality"
fi

if [[ "$TOTAL_VRAM" -ge 12 ]]; then
    add_model "flux-schnell" "Flux.1-schnell" "12" "fast Flux variant, excellent quality"
fi

if [[ "$TOTAL_VRAM" -ge 20 ]]; then
    add_model "flux-dev" "Flux.1-dev" "20" "best quality, slower, needs lots of VRAM"
fi

if [[ ${#MODEL_IDS[@]} -eq 0 ]]; then
    warn "No GPU with sufficient VRAM detected (need at least 4GB)."
    warn "CPU-only image generation is extremely slow and not recommended."
    exit 1
fi

# ── Determine default recommendation ─────────────────────────────────────────
if   [[ "$TOTAL_VRAM" -ge 20 ]]; then DEFAULT_ID="flux-dev"
elif [[ "$TOTAL_VRAM" -ge 12 ]]; then DEFAULT_ID="sdxl"
elif [[ "$TOTAL_VRAM" -ge 8 ]];  then DEFAULT_ID="sdxl"
elif [[ "$TOTAL_VRAM" -ge 4 ]];  then DEFAULT_ID="sd15"
else DEFAULT_ID="sd15"
fi

echo -e "${BOLD}Available models for your ${TOTAL_VRAM}GB GPU:${NC}"
echo ""
for i in "${!MODEL_IDS[@]}"; do
    DEFAULT_TAG=""
    [[ "${MODEL_IDS[$i]}" == "$DEFAULT_ID" ]] && DEFAULT_TAG=" ${GREEN}← recommended${NC}"
    printf "  ${BOLD}%d)${NC}  %-25s  ~%sGB VRAM  %s%b\n" \
        $((i+1)) "${MODEL_NAMES[$i]}" "${MODEL_VRAM[$i]}" "${MODEL_NOTES[$i]}" "$DEFAULT_TAG"
done
echo ""

if $AUTO; then
    SELECTED="$DEFAULT_ID"
    info "Auto mode: installing $SELECTED"
else
    echo -e "  Enter number(s) separated by spaces, or press Enter for recommended."
    echo -e "  Example: ${BOLD}1 2${NC} to install both SD 1.5 and SDXL"
    echo ""
    read -rp "  Selection [recommended]: " CHOICE

    if [[ -z "$CHOICE" ]]; then
        SELECTED="$DEFAULT_ID"
    else
        SELECTED=""
        for num in $CHOICE; do
            idx=$((num - 1))
            if [[ $idx -ge 0 && $idx -lt ${#MODEL_IDS[@]} ]]; then
                SELECTED+=" ${MODEL_IDS[$idx]}"
            else
                warn "Invalid selection: $num (skipping)"
            fi
        done
        SELECTED="${SELECTED# }"
    fi
fi

[[ -z "$SELECTED" ]] && { warn "No models selected."; exit 1; }

echo ""
info "Will install: $SELECTED"
echo ""

# ── HuggingFace model identifiers ────────────────────────────────────────────
declare -A HF_MODELS=(
    [sd15]="stabilityai/stable-diffusion-v1-5"
    [sdxl]="stabilityai/stable-diffusion-xl-base-1.0"
    [sdxl-turbo]="stabilityai/sdxl-turbo"
    [flux-schnell]="black-forest-labs/FLUX.1-schnell"
    [flux-dev]="black-forest-labs/FLUX.1-dev"
)

declare -A MODEL_SIZES=(
    [sd15]="~4GB"
    [sdxl]="~7GB"
    [sdxl-turbo]="~7GB"
    [flux-schnell]="~12GB"
    [flux-dev]="~24GB"
)

# ── Install into InvokeAI ────────────────────────────────────────────────────
if $HAS_INVOKEAI; then
    echo -e "${BOLD}━━━  Installing into InvokeAI  ━━━${NC}"

    # Make sure container is running
    if ! docker ps --format '{{.Names}}' | grep -q '^invokeai$'; then
        info "Starting InvokeAI container..."
        docker start invokeai
        sleep 5
    fi

    for model_id in $SELECTED; do
        hf_id="${HF_MODELS[$model_id]:-}"
        [[ -z "$hf_id" ]] && { warn "Unknown model: $model_id"; continue; }
        info "Installing $model_id (${MODEL_SIZES[$model_id]}) → ${hf_id}..."
        info "  This may take a while depending on your connection."

        if docker exec invokeai invokeai-model-install --add "$hf_id" 2>&1; then
            ok "$model_id installed in InvokeAI"
        else
            warn "$model_id install failed in InvokeAI — try manually via Model Manager at :9090"
        fi
        echo ""
    done
fi

# ── Install into ComfyUI ─────────────────────────────────────────────────────
if $HAS_COMFYUI; then
    echo -e "${BOLD}━━━  Installing into ComfyUI  ━━━${NC}"
    info "ComfyUI downloads models on first use via its UI."
    info "To pre-download, use the ComfyUI Manager at http://localhost:8188"
    echo ""

    # Make sure container is running
    if ! docker ps --format '{{.Names}}' | grep -q '^comfyui$'; then
        info "Starting ComfyUI container..."
        docker start comfyui
        sleep 5
    fi

    # For ComfyUI, download checkpoints into the models volume
    for model_id in $SELECTED; do
        hf_id="${HF_MODELS[$model_id]:-}"
        [[ -z "$hf_id" ]] && continue

        # Check if model already exists
        CKPT_DIR="/opt/ComfyUI/models/checkpoints"
        if docker exec comfyui ls "$CKPT_DIR" 2>/dev/null | grep -qi "${model_id//-/_}"; then
            ok "$model_id already present in ComfyUI"
            continue
        fi

        info "Downloading $model_id for ComfyUI (${MODEL_SIZES[$model_id]})..."
        info "  Downloading from HuggingFace: $hf_id"

        # Use ComfyUI's built-in download mechanism via python
        case "$model_id" in
            sd15)
                docker exec comfyui bash -c \
                    "cd /opt/ComfyUI && python -c \"
from huggingface_hub import hf_hub_download
hf_hub_download('$hf_id', 'v1-5-pruned-emaonly.safetensors', local_dir='models/checkpoints')
\" 2>&1" && ok "$model_id downloaded for ComfyUI" \
                    || warn "$model_id download failed — install via ComfyUI Manager UI"
                ;;
            sdxl)
                docker exec comfyui bash -c \
                    "cd /opt/ComfyUI && python -c \"
from huggingface_hub import hf_hub_download
hf_hub_download('$hf_id', 'sd_xl_base_1.0.safetensors', local_dir='models/checkpoints')
\" 2>&1" && ok "$model_id downloaded for ComfyUI" \
                    || warn "$model_id download failed — install via ComfyUI Manager UI"
                ;;
            *)
                info "$model_id: use ComfyUI Manager to install (complex model structure)"
                ;;
        esac
        echo ""
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  Image model setup complete!${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  ${BOLD}Your GPU:${NC}  $GPU_NAME — ${TOTAL_VRAM}GB VRAM"
echo -e "  ${BOLD}Installed:${NC} $SELECTED"
echo ""
$HAS_INVOKEAI && echo -e "  ${CYAN}InvokeAI${NC}  →  http://localhost:9090"
$HAS_COMFYUI  && echo -e "  ${CYAN}ComfyUI${NC}   →  http://localhost:8188"
echo ""

if $HAS_INVOKEAI; then
    echo -e "  ${YELLOW}InvokeAI quick start:${NC}"
    echo "    1. Open Model Manager → verify your model appears"
    echo "    2. Go to Text to Image → select the model"
    echo "    3. For inpainting: use the Unified Canvas tab"
    echo "       - Upload image → brush over the area to change"
    echo "       - Write what you want in that area → Invoke"
    echo ""
fi

if $HAS_COMFYUI; then
    echo -e "  ${YELLOW}ComfyUI quick start:${NC}"
    echo "    1. Open ComfyUI → load a basic txt2img workflow"
    echo "    2. Select your checkpoint in the Load Checkpoint node"
    echo "    3. For Open WebUI integration: enable Dev Mode → export API workflow"
    echo ""
fi

echo -e "  ${YELLOW}GPU sharing:${NC} Ollama and image gen share the GPU."
echo "    Ollama auto-unloads models after 24h idle (KEEP_ALIVE=24h)."
echo "    For immediate unload before heavy image gen:"
echo "      docker exec ollama ollama stop <model-name>"
echo ""
echo -e "  ${YELLOW}Import LoRAs:${NC} ./invokeai-import-lora.sh <file.safetensors>"
echo ""
