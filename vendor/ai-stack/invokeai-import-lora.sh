#!/usr/bin/env bash
# Import a LoRA (.safetensors) file into InvokeAI's Docker volume
# Usage: ./invokeai-import-lora.sh /path/to/my-lora.safetensors
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

if [[ $# -lt 1 ]]; then
    echo -e "${BOLD}Usage:${NC} $0 <lora-file.safetensors> [display-name]"
    echo ""
    echo "  Copies a LoRA file into InvokeAI's model volume so it appears"
    echo "  in the Model Manager automatically."
    echo ""
    echo "  Examples:"
    echo "    $0 ~/Downloads/my-character-lora.safetensors"
    echo "    $0 ~/Downloads/my-character-lora.safetensors \"My Character\""
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

# Check if InvokeAI container exists
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^invokeai$'; then
    echo -e "${RED}Error:${NC} InvokeAI container not found. Is the AI stack running?"
    echo "  Try: bash ~/docker/ai-stack/start.sh"
    exit 1
fi

# Check if container is running
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^invokeai$'; then
    echo -e "${YELLOW}InvokeAI container is stopped. Starting it...${NC}"
    docker start invokeai
    sleep 3
fi

FILENAME=$(basename "$LORA_FILE")

echo -e "${CYAN}[..]${NC} Copying ${BOLD}$FILENAME${NC} into InvokeAI..."

# Copy the LoRA file into the container's models directory
# InvokeAI looks for LoRA files in /invokeai/models/lora/
docker exec invokeai mkdir -p /invokeai/models/lora
docker cp "$LORA_FILE" "invokeai:/invokeai/models/lora/$FILENAME"

echo -e "${GREEN}[OK]${NC} LoRA file copied successfully!"
echo ""
echo -e "${BOLD}Next steps in InvokeAI (http://localhost:9090):${NC}"
echo ""
echo "  1. Open the ${BOLD}Model Manager${NC} (cube icon in the left sidebar)"
echo "  2. Click ${BOLD}\"Scan for Models\"${NC} or ${BOLD}\"Sync Models\"${NC} button"
echo "     - Your LoRA '${DISPLAY_NAME}' should appear in the list"
echo "  3. If it doesn't auto-detect, click ${BOLD}\"Add Model\" > \"Scan Folder\"${NC}"
echo "     and enter: ${BOLD}/invokeai/models/lora${NC}"
echo ""
echo -e "${BOLD}To use the LoRA when generating images:${NC}"
echo ""
echo "  1. Go to the ${BOLD}Text to Image${NC} or ${BOLD}Image to Image${NC} tab"
echo "  2. In the left panel, find the ${BOLD}\"LoRA\"${NC} section"
echo "     (expand it if collapsed — it's below the main model selector)"
echo "  3. Click ${BOLD}\"+\"${NC} to add your LoRA from the dropdown"
echo "  4. Adjust the ${BOLD}weight${NC} slider (start with 0.7–0.85)"
echo "  5. Make sure your ${BOLD}base model${NC} matches what the LoRA was trained on"
echo "     (e.g., if trained on SD 1.5, select a SD 1.5 checkpoint)"
echo ""
echo -e "${YELLOW}Tip:${NC} If the LoRA was trained on SD 1.5, you MUST use an SD 1.5"
echo "     base model — it won't work with SDXL or other architectures."
