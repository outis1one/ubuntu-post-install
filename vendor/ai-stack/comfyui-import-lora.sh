#!/usr/bin/env bash
# Import a LoRA (.safetensors) into ComfyUI's Docker volume
# Usage: ./comfyui-import-lora.sh /path/to/my-lora.safetensors
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

if [[ $# -lt 1 ]]; then
    echo -e "${BOLD}Usage:${NC} $0 <lora-file.safetensors> [display-name]"
    echo ""
    echo "  Copies a LoRA file into ComfyUI's models/loras/ directory so it"
    echo "  can be used in workflows (including via Open WebUI)."
    echo ""
    echo "  Examples:"
    echo "    $0 ~/Downloads/my-style-lora.safetensors"
    echo "    $0 ~/Downloads/my-style-lora.safetensors \"Anime Style\""
    echo ""
    echo "  After importing, create a workflow in ComfyUI that uses this LoRA,"
    echo "  export it as API format, and import into Open WebUI for chat-based"
    echo "  image generation with this LoRA applied automatically."
    exit 1
fi

LORA_FILE="$1"
DISPLAY_NAME="${2:-$(basename "$LORA_FILE" .safetensors)}"

# Validate file exists
if [[ ! -f "$LORA_FILE" ]]; then
    echo -e "${RED}Error:${NC} File not found: $LORA_FILE"
    exit 1
fi

# Validate file extension
if [[ "$LORA_FILE" != *.safetensors && "$LORA_FILE" != *.ckpt && "$LORA_FILE" != *.pt ]]; then
    echo -e "${YELLOW}Warning:${NC} File doesn't have a typical LoRA extension (.safetensors, .ckpt, .pt)"
    read -rp "Continue anyway? [y/N] " yn
    [[ "$yn" != [yY]* ]] && exit 1
fi

# Check if ComfyUI container exists
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^comfyui$'; then
    echo -e "${RED}Error:${NC} ComfyUI container not found. Is the AI stack running?"
    echo "  Try: docker compose up -d comfyui"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^comfyui$'; then
    echo -e "${YELLOW}ComfyUI container is stopped. Starting it...${NC}"
    docker start comfyui
    sleep 3
fi

FILENAME=$(basename "$LORA_FILE")

echo -e "${CYAN}[..]${NC} Copying ${BOLD}$FILENAME${NC} into ComfyUI..."

# Copy the LoRA file into the container's loras directory
docker exec comfyui mkdir -p /opt/ComfyUI/models/loras
docker cp "$LORA_FILE" "comfyui:/opt/ComfyUI/models/loras/$FILENAME"

echo -e "${GREEN}[OK]${NC} LoRA '${DISPLAY_NAME}' copied to ComfyUI!"
echo ""
echo -e "${BOLD}Next: Create a workflow that uses this LoRA${NC}"
echo ""
echo "  1. Open ComfyUI at http://localhost:8188"
echo "  2. Load or create a text-to-image workflow"
echo "  3. Add a ${BOLD}LoRA Loader${NC} node:"
echo "     Right-click canvas → Add Node → loaders → Load LoRA"
echo "  4. Wire it between the ${BOLD}checkpoint loader${NC} and the ${BOLD}CLIP/sampler${NC}:"
echo ""
echo "     [Load Checkpoint] → MODEL → [Load LoRA] → MODEL → [KSampler]"
echo "                       → CLIP  →             → CLIP  → [CLIP Text Encode]"
echo ""
echo "  5. In the LoRA Loader node, select ${BOLD}${FILENAME}${NC}"
echo "  6. Set ${BOLD}strength_model${NC} and ${BOLD}strength_clip${NC} (start with 0.7–0.85)"
echo ""
echo -e "${BOLD}To use from Open WebUI chat (no more ComfyUI interaction needed):${NC}"
echo ""
echo "  7. Click the ${BOLD}gear icon${NC} → enable ${BOLD}Dev Mode${NC}"
echo "  8. Click ${BOLD}Save (API Format)${NC} → saves workflow_api.json"
echo "  9. In Open WebUI → Admin → Settings → Images → ${BOLD}Import Workflow${NC}"
echo "  10. Upload the workflow_api.json and map the prompt node"
echo "  11. Now just chat: \"Generate an image of a forest in ${DISPLAY_NAME} style\""
echo ""
echo -e "${YELLOW}Tip:${NC} The LoRA must match your base model architecture."
echo "     SD 1.5 LoRA → SD 1.5 checkpoint.  SDXL LoRA → SDXL checkpoint."
echo ""
echo -e "${YELLOW}Tip:${NC} You can ${BOLD}chain multiple LoRAs${NC} in one workflow:"
echo "     [Checkpoint] → [Load LoRA 1] → [Load LoRA 2] → [KSampler]"
echo "     Each has its own strength slider so you can blend styles."
echo ""
echo -e "${YELLOW}Tip:${NC} Export multiple workflows (one per LoRA combo) and switch"
echo "     between them in Open WebUI's image settings as needed."
echo "     LoRAs are baked into the workflow — there's no keyword to"
echo "     toggle them on/off from chat."
