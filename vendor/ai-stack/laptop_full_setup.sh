#!/usr/bin/env bash
# =============================================================================
# Local AI Setup — Ubuntu 24.04
# One script to rule them all. Select what you need, answer questions, walk away.
#
# Options (checklist at launch):
#   • Full system setup — Ubuntu apps, security, backups (ubuntu-post-install.sh)
#   • AI stack         — Ollama · Open WebUI · RAG · MCP · ChromaDB
#                        Gitea · InvokeAI · ComfyUI · Portainer
#   • Kiwix            — Offline Wikipedia, Stack Overflow, Arch Wiki, etc.
#
# Usage:
#   ./laptop_full_setup.sh           — interactive (asks everything upfront)
#   ./laptop_full_setup.sh --force   — overwrite existing config files too
#
# GPU: Ollama auto-detects VRAM — works with any NVIDIA GPU
# =============================================================================
set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[..]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[!!]${NC}  $*"; }
die()     { echo -e "${RED}[XX]${NC}  $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}━━━  $*  ━━━${NC}"; }

# ── args ──────────────────────────────────────────────────────────────────────
FORCE=false
for arg in "$@"; do [[ "$arg" == "--force" ]] && FORCE=true; done

# ── config ────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE="$SCRIPT_DIR"
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' \
           || hostname -I | awk '{print $1}')
[[ -z "$LOCAL_IP" ]] && read -rp "Enter your LAN IP: " LOCAL_IP

# Models (defaults, may be adjusted below based on VRAM)
EMBED_MODEL="nomic-embed-text"
CHAT_MODEL="qwen3.5:9b"
CODE_MODEL="qwen3.5:9b"
FAST_MODEL="qwen3.5:4b"

# ── detect GPU ────────────────────────────────────────────────────────────────
VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
          | head -1 | awk '{printf "%d", $1/1024}' 2>/dev/null || echo "0")
GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo "0")
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "None")
TOTAL_VRAM=$((VRAM_GB * GPU_COUNT))

# Ollama optimization flags (stacked — see docs/gpu-setup-research.md)
OLLAMA_KV_CACHE="q8_0"          # halves KV cache VRAM (q4_0 for aggressive)
OLLAMA_FLASH="1"                # flash attention: less VRAM, no quality loss

if   [[ "$TOTAL_VRAM" -ge 40 ]]; then
    CHAT_MODEL="qwen3.5:27b";  CODE_MODEL="qwen3.5:27b"
    CTX=131072; GPU_TIER="${TOTAL_VRAM}GB VRAM — 27B dense, 128K context"
elif [[ "$TOTAL_VRAM" -ge 28 ]]; then
    CHAT_MODEL="qwen3.5-35b-a3b";  CODE_MODEL="qwen3.5-35b-a3b"
    CTX=131072; GPU_TIER="${TOTAL_VRAM}GB VRAM — 35B MoE, 128K context"
elif [[ "$TOTAL_VRAM" -ge 14 ]]; then
    CHAT_MODEL="qwen3.5-35b-a3b";  CODE_MODEL="qwen3.5-35b-a3b"
    CTX=65536;  GPU_TIER="${TOTAL_VRAM}GB VRAM — 35B MoE + KV quant, 64K context"
elif [[ "$TOTAL_VRAM" -ge 8 ]]; then
    CHAT_MODEL="qwen3.5:9b";  CODE_MODEL="qwen3.5:9b"
    CTX=32768;  GPU_TIER="${TOTAL_VRAM}GB VRAM — 9B dense, 32K context"
elif [[ "$TOTAL_VRAM" -ge 6 ]]; then
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=32768;  GPU_TIER="${TOTAL_VRAM}GB VRAM — 4B + KV quant, 32K context (3.5GB free for cache)"
elif [[ "$TOTAL_VRAM" -ge 4 ]]; then
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=16384;  GPU_TIER="${TOTAL_VRAM}GB VRAM — 4B models, 16K context"
elif [[ "$TOTAL_VRAM" -gt 0 ]]; then
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=8192;   GPU_TIER="${TOTAL_VRAM}GB VRAM — 4B models"
else
    CHAT_MODEL="qwen3.5:4b";  CODE_MODEL="qwen3.5:4b"
    CTX=4096;   OLLAMA_KV_CACHE="q4_0"; GPU_TIER="CPU only — 4B models (slow)"
fi

# ── Image generation model tiers (VRAM-aware) ────────────────────────────────
# Image gen shares GPU with Ollama — Ollama unloads after KEEP_ALIVE timeout,
# so image gen gets full VRAM when Ollama is idle.
if   [[ "$TOTAL_VRAM" -ge 24 ]]; then
    IMG_MODELS="SD 1.5, SDXL, SDXL Turbo, Flux.1-dev, Flux.1-schnell"
    IMG_TIER="all models including Flux"
    IMG_DEFAULT="SDXL"
elif [[ "$TOTAL_VRAM" -ge 12 ]]; then
    IMG_MODELS="SD 1.5, SDXL, SDXL Turbo, Flux.1-schnell (tight)"
    IMG_TIER="SDXL + Flux-schnell"
    IMG_DEFAULT="SDXL"
elif [[ "$TOTAL_VRAM" -ge 8 ]]; then
    IMG_MODELS="SD 1.5, SDXL (tight at 512px), SDXL Turbo"
    IMG_TIER="SD 1.5 comfortable, SDXL possible"
    IMG_DEFAULT="SD 1.5"
elif [[ "$TOTAL_VRAM" -ge 4 ]]; then
    IMG_MODELS="SD 1.5 (float16)"
    IMG_TIER="SD 1.5 only"
    IMG_DEFAULT="SD 1.5"
else
    IMG_MODELS="none (CPU generation extremely slow)"
    IMG_TIER="CPU only — not recommended"
    IMG_DEFAULT=""
fi

# ── InvokeAI precision (GPU-aware) ───────────────────────────────────────────
# Ampere+ (compute 8.0+) supports bfloat16 natively for better precision.
# All modern NVIDIA GPUs support float16. Fall back to auto if unsure.
GPU_COMPUTE=$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
              | head -1 | tr -d '.' || echo "0")
if   [[ "$GPU_COMPUTE" -ge 80 ]]; then
    INVOKEAI_PRECISION="bfloat16"   # Ampere+ (RTX 30xx/40xx/50xx, A-series, H100)
elif [[ "$GPU_COMPUTE" -ge 60 ]]; then
    INVOKEAI_PRECISION="float16"    # Pascal+ (GTX 10xx, RTX 20xx, Tesla P40/V100)
else
    INVOKEAI_PRECISION="auto"       # Let InvokeAI decide
fi

# ── new vs update ─────────────────────────────────────────────────────────────
IS_UPDATE=false
[[ -f "$BASE/docker-compose.yml" ]] && IS_UPDATE=true

# =============================================================================
#  QUESTIONS UPFRONT — answer everything, then walk away
# =============================================================================
section "Local AI Stack — Setup Wizard"
echo ""
echo -e "  ${BOLD}Answer the questions below, then leave it overnight.${NC}"
echo -e "  Everything will install and download while you sleep."
echo ""
info "Machine : $(hostname)"
info "LAN IP  : $LOCAL_IP"
info "GPU     : ${GPU_NAME} (${VRAM_GB}GB VRAM)"
info "Image   : $IMG_TIER"
$IS_UPDATE && warn "Existing install found. Config files kept unless --force is passed."

# ── Q1: Top-level — what to run ───────────────────────────────────────────────
INSTALL_POSTINSTALL=false
INSTALL_AI=true

# Per-service flags (all default ON — toggled off in Q1a)
SVC_WEBUI=true; SVC_RAG=true; SVC_MCP=true
SVC_GITEA=true; SVC_INVOKEAI=true; SVC_COMFYUI=true; SVC_PORTAINER=true; SVC_KIWIX=true

POSTINSTALL_SCRIPT="$SCRIPT_DIR/ubuntu-post-install.sh"
HAS_POSTINSTALL=false
[[ -f "$POSTINSTALL_SCRIPT" ]] && HAS_POSTINSTALL=true

if command -v whiptail &>/dev/null; then
    WHIP_ARGS=()
    $HAS_POSTINSTALL && WHIP_ARGS+=(
        "postinstall" "Full system setup — Ubuntu apps, security, backups" OFF
    )
    WHIP_ARGS+=( "aistack" "AI stack          — select services on next screen" ON )
    SELECTED=$(whiptail --title "Local AI Setup" \
        --checklist "SPACE = toggle   TAB = move   ENTER = confirm" \
        12 68 "${#WHIP_ARGS[@]}" "${WHIP_ARGS[@]}" 3>&1 1>&2 2>&3) || die "Cancelled."
    INSTALL_AI=false
    [[ "$SELECTED" == *"postinstall"* ]] && INSTALL_POSTINSTALL=true
    [[ "$SELECTED" == *"aistack"*     ]] && INSTALL_AI=true
else
    echo ""
    echo -e "  ${BOLD}[1] Select what to run${NC}"
    echo "  (Type a number to toggle, Enter to confirm)"
    SEL_POST=false; SEL_AI=true
    while true; do
        echo ""
        $HAS_POSTINSTALL && printf "  [%s] 1. Full system setup — Ubuntu apps, security, backups\n" "$($SEL_POST && echo '*' || echo ' ')"
        printf "  [%s] 2. AI stack          — select services on next screen\n" "$($SEL_AI && echo '*' || echo ' ')"
        echo ""
        read -rp "  Toggle [number] or Enter to confirm: " T
        case "$T" in
            1) $HAS_POSTINSTALL && { $SEL_POST && SEL_POST=false || SEL_POST=true; } ;;
            2) $SEL_AI && SEL_AI=false || SEL_AI=true ;;
            "") break ;;
        esac
    done
    INSTALL_POSTINSTALL=$SEL_POST
    INSTALL_AI=$SEL_AI
fi

$INSTALL_AI || $INSTALL_POSTINSTALL \
    || die "Nothing selected — run again and select at least one option."

# ── Q1a: AI stack service selection ───────────────────────────────────────────
if $INSTALL_AI; then
    # detect which containers already exist (mark them ON)
    existing_svc() {
        docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^$1$" && echo ON || echo OFF
    }

    if command -v whiptail &>/dev/null; then
        SELECTED_SVCS=$(whiptail --title "AI Stack — Select Services" \
            --checklist "Ollama always installed (core).  SPACE = toggle   ENTER = confirm" \
            22 78 10 \
            "open-webui" "Open WebUI    — Chat interface (like ChatGPT, uses Ollama)"    "$(existing_svc open-webui)" \
            "rag"        "RAG + ChromaDB— Code & document search (needed by MCP)"        "$(existing_svc rag-server)" \
            "mcp"        "MCP Server    — Claude Code tools (bash, files, git, search)"  "$(existing_svc mcp-server)" \
            "gitea"      "Gitea         — Self-hosted Git server"                        "$(existing_svc gitea)"      \
            "invokeai"   "InvokeAI      — Image generation (Stable Diffusion)"           "$(existing_svc invokeai)"   \
            "comfyui"    "ComfyUI       — Node-based image gen (integrates w/ Open WebUI)" "$(existing_svc comfyui)"  \
            "portainer"  "Portainer     — Docker management web UI"                      "$(existing_svc portainer)"  \
            "kiwix"      "Kiwix         — Offline Wikipedia, Stack Overflow, Arch Wiki"  "$(existing_svc kiwix)"      \
            3>&1 1>&2 2>&3) || die "Cancelled."

        SVC_WEBUI=false;    [[ "$SELECTED_SVCS" == *'"open-webui"'* ]] && SVC_WEBUI=true
        SVC_RAG=false;      [[ "$SELECTED_SVCS" == *'"rag"'*        ]] && SVC_RAG=true
        SVC_MCP=false;      [[ "$SELECTED_SVCS" == *'"mcp"'*        ]] && SVC_MCP=true
        SVC_GITEA=false;    [[ "$SELECTED_SVCS" == *'"gitea"'*      ]] && SVC_GITEA=true
        SVC_INVOKEAI=false; [[ "$SELECTED_SVCS" == *'"invokeai"'*   ]] && SVC_INVOKEAI=true
        SVC_COMFYUI=false;  [[ "$SELECTED_SVCS" == *'"comfyui"'*    ]] && SVC_COMFYUI=true
        SVC_PORTAINER=false;[[ "$SELECTED_SVCS" == *'"portainer"'*  ]] && SVC_PORTAINER=true
        SVC_KIWIX=false;    [[ "$SELECTED_SVCS" == *'"kiwix"'*      ]] && SVC_KIWIX=true
    else
        # Text toggle fallback
        echo ""
        echo -e "  ${BOLD}[1a] AI Stack — select services to install${NC}"
        echo "  Ollama always included (required core).  Type number to toggle, Enter to confirm."
        _W=$SVC_WEBUI; _R=$SVC_RAG; _M=$SVC_MCP
        _G=$SVC_GITEA; _I=$SVC_INVOKEAI; _C=$SVC_COMFYUI; _P=$SVC_PORTAINER; _K=$SVC_KIWIX
        while true; do
            echo ""
            printf "  [%s] 1. Open WebUI   — Chat interface\n"                     "$($_W && echo '*' || echo ' ')"
            printf "  [%s] 2. RAG+ChromaDB — Code & document search\n"             "$($_R && echo '*' || echo ' ')"
            printf "  [%s] 3. MCP Server   — Claude Code tools (needs RAG)\n"      "$($_M && echo '*' || echo ' ')"
            printf "  [%s] 4. Gitea        — Self-hosted Git\n"                    "$($_G && echo '*' || echo ' ')"
            printf "  [%s] 5. InvokeAI     — Image generation\n"                   "$($_I && echo '*' || echo ' ')"
            printf "  [%s] 6. ComfyUI      — Node-based image gen (OWUI integration)\n" "$($_C && echo '*' || echo ' ')"
            printf "  [%s] 7. Portainer    — Docker management UI\n"               "$($_P && echo '*' || echo ' ')"
            printf "  [%s] 8. Kiwix        — Offline Wikipedia, Stack Overflow\n"  "$($_K && echo '*' || echo ' ')"
            echo ""
            read -rp "  Toggle [number] or Enter to confirm: " T
            case "$T" in
                1) $_W && _W=false || _W=true ;;
                2) $_R && _R=false || _R=true ;;
                3) $_M && _M=false || _M=true ;;
                4) $_G && _G=false || _G=true ;;
                5) $_I && _I=false || _I=true ;;
                6) $_C && _C=false || _C=true ;;
                7) $_P && _P=false || _P=true ;;
                8) $_K && _K=false || _K=true ;;
                "") break ;;
            esac
        done
        SVC_WEBUI=$_W; SVC_RAG=$_R; SVC_MCP=$_M
        SVC_GITEA=$_G; SVC_INVOKEAI=$_I; SVC_COMFYUI=$_C; SVC_PORTAINER=$_P; SVC_KIWIX=$_K
    fi

    # Enforce dependencies: MCP needs RAG
    $SVC_MCP && ! $SVC_RAG && { warn "MCP Server requires RAG — enabling RAG+ChromaDB"; SVC_RAG=true; }
fi

# ── Q1b: SSH keys from GitHub / Launchpad ─────────────────────────────────────
SSH_IMPORT_IDS=()   # list of "gh:username" or "lp:username" entries

if ! $IS_UPDATE || [[ ! -f "$HOME/.ssh/authorized_keys" ]]; then
    if command -v whiptail &>/dev/null; then
        SSH_INPUT=$(whiptail --title "SSH Key Import" \
            --inputbox "Import SSH public keys for passwordless SSH into this machine.\n\nExamples:  gh:yourusername   lp:yourlaunchpadid\nMultiple:  gh:alice lp:alice\n\nLeave blank to skip." \
            14 68 "" 3>&1 1>&2 2>&3) || SSH_INPUT=""
    else
        echo ""
        echo -e "  ${BOLD}[SSH] Import SSH public keys? (for passwordless SSH into this machine)${NC}"
        echo "  Pulls your public keys from GitHub or Launchpad and adds them to"
        echo "  ~/.ssh/authorized_keys using ssh-import-id."
        echo ""
        echo "  Examples:  gh:yourusername   lp:yourlaunchpadid"
        echo "  Multiple:  gh:alice lp:alice"
        echo ""
        read -rp "  Usernames (or Enter to skip): " SSH_INPUT
    fi
    if [[ -n "$SSH_INPUT" ]]; then
        read -ra SSH_IMPORT_IDS <<< "$SSH_INPUT"
    fi
fi

# ── Q2: Storage for Ollama models ─────────────────────────────────────────────
OLLAMA_STORAGE="volume"   # "volume" = Docker named volume, else a host path
OLLAMA_HOST_PATH=""

if $INSTALL_AI; then
    mapfile -t _MPTS < <(
        df -h --output=target,avail,fstype 2>/dev/null \
        | awk 'NR>1 && $2~/[0-9]/ {
              val=$2; unit=substr(val,length(val));
              num=substr(val,1,length(val)-1)+0;
              if ((unit=="G" && num>=20) || unit=="T") print $0
          }' | head -10
    )

    if command -v whiptail &>/dev/null; then
        WHIP_STORAGE=("volume" "Docker volume (default — /var/lib/docker/volumes/)" ON)
        for _i in "${!_MPTS[@]}"; do
            _mp_path=$(awk '{print $1}' <<< "${_MPTS[$_i]}")
            _mp_avail=$(awk '{print $2}' <<< "${_MPTS[$_i]}")
            WHIP_STORAGE+=("$_mp_path" "${_mp_path} (${_mp_avail} free)" OFF)
        done
        STORAGE_CHOICE=$(whiptail --title "Ollama Model Storage" \
            --radiolist "Models are large (5-50GB each). Choose a location.\nSPACE = select   ENTER = confirm" \
            $((10 + ${#_MPTS[@]})) 72 $((1 + ${#_MPTS[@]})) \
            "${WHIP_STORAGE[@]}" 3>&1 1>&2 2>&3) || STORAGE_CHOICE="volume"
        STORAGE_CHOICE="${STORAGE_CHOICE//\"/}"
        if [[ "$STORAGE_CHOICE" == "volume" ]]; then
            OLLAMA_STORAGE="volume"
        else
            OLLAMA_HOST_PATH="${STORAGE_CHOICE}/ollama-models"
            OLLAMA_STORAGE="bind"
            ok "Ollama models → $OLLAMA_HOST_PATH"
        fi
    else
        echo ""
        echo -e "  ${BOLD}[2/6] Where should Ollama models be stored?${NC}"
        echo "  (Models are large — 5-50GB each. A fast SSD or large HDD is ideal.)"
        echo ""
        echo "  0) Docker volume  (default — /var/lib/docker/volumes/)"
        for _i in "${!_MPTS[@]}"; do
            printf "  %d) %s\n" "$((_i+1))" "${_MPTS[$_i]}"
        done
        echo ""
        read -rp "  Choice [0]: " STORAGE_CHOICE
        STORAGE_CHOICE="${STORAGE_CHOICE:-0}"
        if [[ "$STORAGE_CHOICE" == "0" ]]; then
            OLLAMA_STORAGE="volume"
        elif [[ "$STORAGE_CHOICE" =~ ^[0-9]+$ ]] && (( STORAGE_CHOICE >= 1 && STORAGE_CHOICE <= ${#_MPTS[@]} )); then
            _MP=$(awk '{print $1}' <<< "${_MPTS[$(( STORAGE_CHOICE-1 ))]}")
            OLLAMA_HOST_PATH="$_MP/ollama-models"
            OLLAMA_STORAGE="bind"
            ok "Ollama models → $OLLAMA_HOST_PATH"
        else
            OLLAMA_HOST_PATH="${STORAGE_CHOICE%/}"
            [[ -z "$OLLAMA_HOST_PATH" ]] && die "No path entered."
            OLLAMA_STORAGE="bind"
        fi
    fi
    unset _MPTS _MP _i WHIP_STORAGE
fi

# ── Q3: Storage for Kiwix ZIMs ────────────────────────────────────────────────
KIWIX_DIR="$BASE/kiwix"   # default

if $SVC_KIWIX; then
    mapfile -t _MPTS < <(
        df -h --output=target,avail,fstype 2>/dev/null \
        | awk 'NR>1 && $2~/[0-9]/ {
              val=$2; unit=substr(val,length(val));
              num=substr(val,1,length(val)-1)+0;
              if ((unit=="G" && num>=50) || unit=="T") print $0
          }' | head -10
    )

    if command -v whiptail &>/dev/null; then
        WHIP_KIWIX=("default" "Default: $KIWIX_DIR" ON)
        for _i in "${!_MPTS[@]}"; do
            _mp_path=$(awk '{print $1}' <<< "${_MPTS[$_i]}")
            _mp_avail=$(awk '{print $2}' <<< "${_MPTS[$_i]}")
            WHIP_KIWIX+=("$_mp_path" "${_mp_path} (${_mp_avail} free)" OFF)
        done
        _KIWIX_SEL=$(whiptail --title "Kiwix ZIM Storage" \
            --radiolist "ZIMs are large — Wikipedia alone ~46GB, total ~130GB.\nSPACE = select   ENTER = confirm" \
            $((10 + ${#_MPTS[@]})) 72 $((1 + ${#_MPTS[@]})) \
            "${WHIP_KIWIX[@]}" 3>&1 1>&2 2>&3) || _KIWIX_SEL="default"
        _KIWIX_SEL="${_KIWIX_SEL//\"/}"
        if [[ "$_KIWIX_SEL" != "default" ]]; then
            KIWIX_DIR="${_KIWIX_SEL}/kiwix"
            ok "Kiwix ZIMs → $KIWIX_DIR"
        fi
    else
        echo ""
        echo -e "  ${BOLD}[3/6] Where should Kiwix ZIM files be stored?${NC}"
        echo "  (ZIMs are large — Wikipedia alone is ~46GB. Total collection ~130GB.)"
        echo ""
        echo "  0) Default: $KIWIX_DIR"
        for _i in "${!_MPTS[@]}"; do
            printf "  %d) %s\n" "$((_i+1))" "${_MPTS[$_i]}"
        done
        echo ""
        read -rp "  Choice [0]: " KIWIX_CHOICE
        KIWIX_CHOICE="${KIWIX_CHOICE:-0}"
        if [[ "$KIWIX_CHOICE" != "0" ]] && [[ "$KIWIX_CHOICE" =~ ^[0-9]+$ ]] && (( KIWIX_CHOICE >= 1 && KIWIX_CHOICE <= ${#_MPTS[@]} )); then
            _MP=$(awk '{print $1}' <<< "${_MPTS[$(( KIWIX_CHOICE-1 ))]}")
            KIWIX_DIR="$_MP/kiwix"
            ok "Kiwix ZIMs → $KIWIX_DIR"
        elif [[ "$KIWIX_CHOICE" != "0" ]] && [[ -n "$KIWIX_CHOICE" ]]; then
            KIWIX_DIR="${KIWIX_CHOICE%/}"
        fi
    fi
    unset _MPTS _MP _i _KIWIX_CHOICE WHIP_KIWIX

    # ── Q4: Download ZIMs now? ─────────────────────────────────────────────────
    # ON if any matching ZIM file already exists in KIWIX_DIR
    _zimon() { ls "$KIWIX_DIR/${1}"*.zim 2>/dev/null | grep -q . && echo ON || echo OFF; }

    ZIM_CHOICE="3"
    ZIM_PICKS=""

    if command -v whiptail &>/dev/null && [[ -t 0 ]]; then
        if _ZIM_MODE=$(whiptail --backtitle "Kiwix" \
              --title "[4/6] Kiwix ZIM Downloads" \
              --radiolist "Download offline Wikipedia, Stack Overflow, etc.? (runs in background)" \
              11 68 3 \
              "select" "Choose individual ZIMs              " ON \
              "all"    "Download everything (~130 GB)       " OFF \
              "skip"   "Skip — run kiwix_download.sh later  " OFF \
              3>&1 1>&2 2>&3 2>/dev/null); then
            _ZIM_MODE="${_ZIM_MODE//\"/}"
            case "$_ZIM_MODE" in
                all) ZIM_CHOICE="1" ;;
                select|*)
                    ZIM_CHOICE="2"
                    if _ZIM_SEL=$(whiptail --backtitle "Kiwix" \
                          --title "Select ZIMs to Download" \
                          --checklist "SPACE = toggle   ENTER = confirm   ESC = skip\nPre-checked = already downloaded" \
                          28 76 22 \
                          "wikipedia"     "$(printf '%-30s %7s' 'Wikipedia'            '~46 GB')"  "$(_zimon wikipedia_en_all_nopic)" \
                          "stackoverflow" "$(printf '%-30s %7s' 'Stack Overflow'       '~3 GB')"   "$(_zimon stackoverflow.com_en_all)" \
                          "askubuntu"     "$(printf '%-30s %7s' 'Ask Ubuntu'           '~1 GB')"   "$(_zimon askubuntu.com_en_all)" \
                          "superuser"     "$(printf '%-30s %7s' 'Super User'           '~1 GB')"   "$(_zimon superuser.com_en_all)" \
                          "unixse"        "$(printf '%-30s %7s' 'Unix & Linux SE'      '~500 MB')" "$(_zimon unix.stackexchange.com_en_all)" \
                          "serverfault"   "$(printf '%-30s %7s' 'Server Fault'         '~500 MB')" "$(_zimon serverfault.com_en_all)" \
                          "devdocs"       "$(printf '%-30s %7s' 'DevDocs (API docs)'   '~1 GB')"   "$(_zimon devdocs_en_zig)" \
                          "archlinux"     "$(printf '%-30s %7s' 'Arch Linux Wiki'      '~30 MB')"  "$(_zimon archlinux_en_all)" \
                          "freecodecamp"  "$(printf '%-30s %7s' 'FreeCodeCamp'         'small')"   "$(_zimon freecodecamp_en_all)" \
                          "wiktionary"    "$(printf '%-30s %7s' 'Wiktionary'           '~2 GB')"   "$(_zimon wiktionary_en_all_nopic)" \
                          "wikibooks"     "$(printf '%-30s %7s' 'Wikibooks'            '~500 MB')" "$(_zimon wikibooks_en_all_nopic)" \
                          "wikisource"    "$(printf '%-30s %7s' 'Wikisource'           '~4 GB')"   "$(_zimon wikisource_en_all_nopic)" \
                          "wikivoyage"    "$(printf '%-30s %7s' 'Wikivoyage'           '~200 MB')" "$(_zimon wikivoyage_en_all_nopic)" \
                          "wikiversity"   "$(printf '%-30s %7s' 'Wikiversity'          '~500 MB')" "$(_zimon wikiversity_en_all_nopic)" \
                          "wikinews"      "$(printf '%-30s %7s' 'WikiNews'             '~300 MB')" "$(_zimon wikinews_en_all_nopic)" \
                          "wikiquote"     "$(printf '%-30s %7s' 'Wikiquote'            '~300 MB')" "$(_zimon wikiquote_en_all_nopic)" \
                          "vikidia"       "$(printf '%-30s %7s' 'Vikidia (kids K-8)'   '~66 MB')"  "$(_zimon vikidia_en_all_nopic)" \
                          "ted"           "$(printf '%-30s %7s' 'TED Talks'            '~5 GB')"   "$(_zimon ted_mul_youth)" \
                          "phet"          "$(printf '%-30s %7s' 'PhET Simulations'     '~500 MB')" "$(_zimon phet_en_all)" \
                          "ifixit"        "$(printf '%-30s %7s' 'iFixit'               '~2 GB')"   "$(_zimon ifixit_en_all)" \
                          "libretexts"    "$(printf '%-30s %7s' 'LibreTexts'           'varies')"  "$(_zimon libretexts.org_en)" \
                          "gutenberg"     "$(printf '%-30s %7s' 'Project Gutenberg'    '~60 GB')"  "$(_zimon gutenberg_en_all)" \
                          3>&1 1>&2 2>&3 2>/dev/null); then
                        if [[ -n "$_ZIM_SEL" ]]; then
                            ZIM_PICKS=$(tr -d '"' <<< "$_ZIM_SEL")
                        else
                            ZIM_CHOICE="3"   # Enter with nothing checked → skip
                        fi
                    else
                        ZIM_CHOICE="3"       # ESC → skip
                    fi
                    ;;
            esac
        fi  # ESC on radiolist → ZIM_CHOICE stays "3"
    else
        # Text fallback
        echo ""
        echo -e "  ${BOLD}[4/6] Download ZIM files? (offline Wikipedia, Stack Overflow, etc.)${NC}"
        echo "  Downloads run in the background — safe to start now and leave overnight."
        echo "  Total: ~130GB (Wikipedia 46GB, Project Gutenberg 60GB, others smaller)"
        echo ""
        echo "  1) Yes — download all ZIMs overnight (~130GB)"
        echo "  2) Select — choose which ZIMs to download"
        echo "  3) No  — skip for now (run ./kiwix_download.sh later)"
        echo ""
        read -rp "  Choice [3]: " ZIM_CHOICE
        ZIM_CHOICE="${ZIM_CHOICE:-3}"

        if [[ "$ZIM_CHOICE" == "2" ]]; then
            _zim_tag() {
                ls "$KIWIX_DIR/${1}"*.zim 2>/dev/null | grep -q . && echo "  ${GREEN}[downloaded]${NC}" || echo ""
            }
            echo ""
            echo "  Select ZIMs to download (space-separated numbers, e.g. 1 3 5):"
            echo "  ── Dev & Sysadmin (most useful for AI coding) ──"
            printf "  %2s)  %-26s %7s  %s\n"  1  "Wikipedia"            "~46 GB"  "$(_zim_tag wikipedia_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n"  2  "Stack Overflow"        "~3 GB"   "$(_zim_tag stackoverflow.com_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  3  "Ask Ubuntu"            "~1 GB"   "$(_zim_tag askubuntu.com_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  4  "Super User"            "~1 GB"   "$(_zim_tag superuser.com_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  5  "Unix & Linux SE"       "~500 MB" "$(_zim_tag unix.stackexchange.com_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  6  "Server Fault"          "~500 MB" "$(_zim_tag serverfault.com_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  7  "DevDocs (API docs)"    "~1 GB"   "$(_zim_tag devdocs_en_zig)"
            printf "  %2s)  %-26s %7s  %s\n"  8  "Arch Linux Wiki"       "~30 MB"  "$(_zim_tag archlinux_en_all)"
            printf "  %2s)  %-26s %7s  %s\n"  9  "FreeCodeCamp"          "small"   "$(_zim_tag freecodecamp_en_all)"
            echo "  ── Reference ──"
            printf "  %2s)  %-26s %7s  %s\n" 10  "Wiktionary"            "~2 GB"   "$(_zim_tag wiktionary_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 11  "Wikibooks"             "~500 MB" "$(_zim_tag wikibooks_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 12  "Wikisource"            "~4 GB"   "$(_zim_tag wikisource_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 13  "Wikivoyage"            "~200 MB" "$(_zim_tag wikivoyage_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 14  "Wikiversity"           "~500 MB" "$(_zim_tag wikiversity_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 15  "WikiNews"              "~300 MB" "$(_zim_tag wikinews_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 16  "Wikiquote"             "~300 MB" "$(_zim_tag wikiquote_en_all_nopic)"
            printf "  %2s)  %-26s %7s  %s\n" 17  "Vikidia (kids K-8)"    "~66 MB"  "$(_zim_tag vikidia_en_all_nopic)"
            echo "  ── Other ──"
            printf "  %2s)  %-26s %7s  %s\n" 18  "TED Talks"             "~5 GB"   "$(_zim_tag ted_mul_youth)"
            printf "  %2s)  %-26s %7s  %s\n" 19  "PhET Simulations"      "~500 MB" "$(_zim_tag phet_en_all)"
            printf "  %2s)  %-26s %7s  %s\n" 20  "iFixit"                "~2 GB"   "$(_zim_tag ifixit_en_all)"
            printf "  %2s)  %-26s %7s  %s\n" 21  "LibreTexts"            "varies"  "$(_zim_tag libretexts.org_en)"
            printf "  %2s)  %-26s %7s  %s\n" 22  "Project Gutenberg"     "~60 GB"  "$(_zim_tag gutenberg_en_all)"
            echo ""
            read -rp "  Your choices (e.g. 1 2 3): " _ZIM_NUMS
            for _n in $_ZIM_NUMS; do
                case "$_n" in
                    1)  ZIM_PICKS+="${ZIM_PICKS:+ }wikipedia" ;;
                    2)  ZIM_PICKS+="${ZIM_PICKS:+ }stackoverflow" ;;
                    3)  ZIM_PICKS+="${ZIM_PICKS:+ }askubuntu" ;;
                    4)  ZIM_PICKS+="${ZIM_PICKS:+ }superuser" ;;
                    5)  ZIM_PICKS+="${ZIM_PICKS:+ }unixse" ;;
                    6)  ZIM_PICKS+="${ZIM_PICKS:+ }serverfault" ;;
                    7)  ZIM_PICKS+="${ZIM_PICKS:+ }devdocs" ;;
                    8)  ZIM_PICKS+="${ZIM_PICKS:+ }archlinux" ;;
                    9)  ZIM_PICKS+="${ZIM_PICKS:+ }freecodecamp" ;;
                    10) ZIM_PICKS+="${ZIM_PICKS:+ }wiktionary" ;;
                    11) ZIM_PICKS+="${ZIM_PICKS:+ }wikibooks" ;;
                    12) ZIM_PICKS+="${ZIM_PICKS:+ }wikisource" ;;
                    13) ZIM_PICKS+="${ZIM_PICKS:+ }wikivoyage" ;;
                    14) ZIM_PICKS+="${ZIM_PICKS:+ }wikiversity" ;;
                    15) ZIM_PICKS+="${ZIM_PICKS:+ }wikinews" ;;
                    16) ZIM_PICKS+="${ZIM_PICKS:+ }wikiquote" ;;
                    17) ZIM_PICKS+="${ZIM_PICKS:+ }vikidia" ;;
                    18) ZIM_PICKS+="${ZIM_PICKS:+ }ted" ;;
                    19) ZIM_PICKS+="${ZIM_PICKS:+ }phet" ;;
                    20) ZIM_PICKS+="${ZIM_PICKS:+ }ifixit" ;;
                    21) ZIM_PICKS+="${ZIM_PICKS:+ }libretexts" ;;
                    22) ZIM_PICKS+="${ZIM_PICKS:+ }gutenberg" ;;
                esac
            done
            unset -f _zim_tag
        fi
    fi
    unset -f _zimon
else
    ZIM_CHOICE="3"
fi

# ── Q4b: Firewall (LAN subnet) ────────────────────────────────────────────────
LAN_SUBNET="192.168.1.0/24"
if command -v ufw &>/dev/null && { [[ ! -f "$BASE/.ufw-done" ]] || $FORCE; }; then
    AUTO_SUBNET=$(echo "$LOCAL_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    if command -v whiptail &>/dev/null; then
        LAN_INPUT=$(whiptail --title "Firewall — LAN Access" \
            --inputbox "Allow LAN access to all services.\n\nYour detected subnet:" \
            10 60 "$AUTO_SUBNET" 3>&1 1>&2 2>&3) || LAN_INPUT=""
    else
        echo ""
        echo -e "  ${BOLD}[4b/6] Firewall — allow LAN access to services${NC}"
        read -rp "  LAN subnet [${AUTO_SUBNET}]: " LAN_INPUT
    fi
    LAN_SUBNET="${LAN_INPUT:-$AUTO_SUBNET}"
    [[ "$LAN_SUBNET" =~ /[0-9]+$ ]] || LAN_SUBNET="${LAN_SUBNET}/24"
fi

# ── Q5: Model selection wizard ────────────────────────────────────────────────
PULL_MODELS=false
REASON_MODEL=""

if $INSTALL_AI; then

    # speed estimate: model_file_size + ~1.5GB overhead for KV cache/CUDA vs VRAM
    # Ollama has no hard limits — silently offloads to CPU when over VRAM
    speed_label() {
        local mgb="$1"                 # approximate Q4 file size in GB
        local needed=$(( mgb + 2 ))    # +2GB for KV cache, attention, CUDA overhead
        if [[ "$VRAM_GB" -eq 0 ]]; then
            printf "CPU only — very slow"
        elif (( needed <= VRAM_GB )); then
            printf "✓ fast  — fits in VRAM (~%dGB needed)" "$needed"
        elif (( needed <= VRAM_GB + 2 )); then
            printf "~ tight — ~%dGB needed, may spill to CPU" "$needed"
        elif (( needed <= VRAM_GB + 8 )); then
            printf "✗ slow  — ~%dGB needed, partial CPU offload" "$needed"
        else
            printf "✗ very slow — ~%dGB needed, heavy CPU offload" "$needed"
        fi
    }

    if command -v whiptail &>/dev/null; then
        MODEL_PREF=$(whiptail --title "Model Selection — ${GPU_NAME:-No GPU} (${VRAM_GB}GB VRAM)" \
            --radiolist "Choose model origin preference.\nSPACE = select   ENTER = confirm" \
            14 78 4 \
            "2" "Performance-first — Qwen 3.5 (top benchmarks, vision+code)" ON \
            "1" "Western-only      — Codestral · Phi4 · Mistral 7B" OFF \
            "3" "Mixed             — Western chat + Qwen 3.5 coding" OFF \
            "4" "Custom            — enter model names manually" OFF \
            3>&1 1>&2 2>&3) || MODEL_PREF="2"
        MODEL_PREF="${MODEL_PREF//\"/}"
    else
        echo ""
        echo -e "  ${BOLD}[5/6] Model selection${NC}"
        echo "  GPU: ${GPU_NAME:-None} (${VRAM_GB}GB VRAM)"
        echo ""
        echo "  Origin preference:"
        echo "  1) Western-only      — Codestral (Mistral) · Phi4 (Microsoft) · Mistral 7B"
        echo "  2) Performance-first — Qwen 3.5 (Feb 2026, top benchmarks, vision+code)"
        echo "  3) Mixed             — Western for chat, Qwen 3.5 for coding"
        echo "  4) Custom            — enter model names manually"
        echo ""
        read -rp "  Choice [2]: " MODEL_PREF
        MODEL_PREF="${MODEL_PREF:-2}"
    fi

    # Q4_K_M approximate weights in GB: 4B=2.5, 7B=4, 9B=5.5, 14B=9, 22B=13, 27B=17, 35B-MoE=12, 70B=41

    # VRAM-based recommendation (soft — shown as suggestion only)
    case "$MODEL_PREF" in
        2)  # Performance (Qwen 3.5)
            if   [[ "$TOTAL_VRAM" -ge 28 ]]; then REC_TIER="27B"
            elif [[ "$TOTAL_VRAM" -ge 14 ]]; then REC_TIER="35B"
            elif [[ "$TOTAL_VRAM" -ge  8 ]]; then REC_TIER="9B"
            else                                   REC_TIER="4B"
            fi
            ;;
        *)  # Western / Mixed
            if   [[ "$TOTAL_VRAM" -ge 40 ]]; then REC_TIER="70B"
            elif [[ "$TOTAL_VRAM" -ge 12 ]]; then REC_TIER="35B"
            elif [[ "$TOTAL_VRAM" -ge  8 ]]; then REC_TIER="14B"
            else                                   REC_TIER="7B"
            fi
            ;;
    esac

    echo ""
    echo "  Size tier — estimated speed on your ${VRAM_GB}GB GPU:"
    echo "  (No hard limits — Ollama uses all available VRAM automatically)"
    echo ""
    printf "  %-4s  %-8s  %-42s  %s\n" "#" "Tier" "Models" "Speed on your system"
    printf "  %-4s  %-8s  %-42s  %s\n" "----" "--------" "------------------------------------------" "--------------------"

    declare -a _TIER_NAMES
    case "$MODEL_PREF" in
        1)  # Western
            _TIER_NAMES=(7B 14B 22B 70B)
            printf "  %-4s  %-8s  %-42s  %s\n" "1)" "7B"   "mistral:7b + codellama:7b"              "$(speed_label 4)"
            printf "  %-4s  %-8s  %-42s  %s\n" "2)" "14B"  "phi4:14b + starcoder2:15b"              "$(speed_label 9)"
            printf "  %-4s  %-8s  %-42s  %s\n" "3)" "22B"  "phi4:14b + codestral:22b"               "$(speed_label 13)"
            printf "  %-4s  %-8s  %-42s  %s\n" "4)" "70B"  "llama3.3:70b + codestral:22b"           "$(speed_label 41)"
            ;;
        2)  # Performance (Qwen 3.5 — Feb 2026)
            _TIER_NAMES=(4B 9B 35B 27B)
            printf "  %-4s  %-8s  %-42s  %s\n" "1)" "4B"   "qwen3.5:4b (chat+code)"                "$(speed_label 2)"
            printf "  %-4s  %-8s  %-42s  %s\n" "2)" "9B"   "qwen3.5:9b (chat+code)"                "$(speed_label 5)"
            printf "  %-4s  %-8s  %-42s  %s\n" "3)" "35B"  "qwen3.5-35b-a3b (MoE, 3B active)"      "$(speed_label 12)"
            printf "  %-4s  %-8s  %-42s  %s\n" "4)" "27B"  "qwen3.5:27b (dense, A- quality)"        "$(speed_label 17)"
            ;;
        3)  # Mixed (Western chat + Qwen 3.5 code)
            _TIER_NAMES=(7B 14B 35B 70B)
            printf "  %-4s  %-8s  %-42s  %s\n" "1)" "7B"   "mistral:7b + qwen3.5:4b"               "$(speed_label 4)"
            printf "  %-4s  %-8s  %-42s  %s\n" "2)" "14B"  "phi4:14b + qwen3.5:9b"                 "$(speed_label 9)"
            printf "  %-4s  %-8s  %-42s  %s\n" "3)" "35B"  "phi4:14b + qwen3.5-35b-a3b"            "$(speed_label 19)"
            printf "  %-4s  %-8s  %-42s  %s\n" "4)" "70B"  "llama3.3:70b + qwen3.5-35b-a3b"        "$(speed_label 41)"
            ;;
    esac

    # Figure out recommended number from REC_TIER
    REC_NUM=2
    for i in "${!_TIER_NAMES[@]}"; do
        [[ "${_TIER_NAMES[$i]}" == "$REC_TIER" ]] && REC_NUM=$((i+1))
    done

    echo ""

    if [[ "$MODEL_PREF" == "4" ]]; then
        # Custom — free-form entry
        if command -v whiptail &>/dev/null; then
            _in=$(whiptail --title "Custom Models — Fast/Chat" \
                --inputbox "Fast/chat model (small, quick responses):" \
                9 60 "$FAST_MODEL" 3>&1 1>&2 2>&3) && FAST_MODEL="${_in:-$FAST_MODEL}"
            _in=$(whiptail --title "Custom Models — Smart Chat" \
                --inputbox "Smart chat model (main model for complex tasks):" \
                9 60 "$CHAT_MODEL" 3>&1 1>&2 2>&3) && CHAT_MODEL="${_in:-$CHAT_MODEL}"
            _in=$(whiptail --title "Custom Models — Code" \
                --inputbox "Code model:" \
                9 60 "$CODE_MODEL" 3>&1 1>&2 2>&3) && CODE_MODEL="${_in:-$CODE_MODEL}"
            REASON_MODEL=$(whiptail --title "Custom Models — Reasoning" \
                --inputbox "Reasoning model (leave blank to skip):" \
                9 60 "" 3>&1 1>&2 2>&3) || REASON_MODEL=""
        else
            echo "  Current defaults: fast=$FAST_MODEL  chat=$CHAT_MODEL  code=$CODE_MODEL"
            echo "  Press Enter on any line to keep the default shown."
            echo ""
            read -rp "  Fast/chat model  [$FAST_MODEL]: " _in; FAST_MODEL="${_in:-$FAST_MODEL}"
            read -rp "  Smart chat model [$CHAT_MODEL]: " _in; CHAT_MODEL="${_in:-$CHAT_MODEL}"
            read -rp "  Code model       [$CODE_MODEL]: " _in; CODE_MODEL="${_in:-$CODE_MODEL}"
            read -rp "  Reasoning model  (Enter to skip): " REASON_MODEL
        fi
    else
        if command -v whiptail &>/dev/null; then
            # Build whiptail radiolist with recommended tier pre-selected
            WHIP_TIERS=()
            declare -A _TIER_LABELS
            case "$MODEL_PREF" in
                1) _TIER_LABELS=([7B]="mistral:7b + codellama:7b" [14B]="phi4:14b + starcoder2:15b" [22B]="phi4:14b + codestral:22b" [70B]="llama3.3:70b + codestral:22b")
                   _TIER_SPEEDS=([7B]="$(speed_label 4)" [14B]="$(speed_label 9)" [22B]="$(speed_label 13)" [70B]="$(speed_label 41)") ;;
                2) _TIER_LABELS=([4B]="qwen3.5:4b (chat+code)" [9B]="qwen3.5:9b (chat+code)" [35B]="qwen3.5-35b-a3b (MoE, 3B active)" [27B]="qwen3.5:27b (dense)")
                   _TIER_SPEEDS=([4B]="$(speed_label 2)" [9B]="$(speed_label 5)" [35B]="$(speed_label 12)" [27B]="$(speed_label 17)") ;;
                3) _TIER_LABELS=([7B]="mistral:7b + qwen3.5:4b" [14B]="phi4:14b + qwen3.5:9b" [35B]="phi4:14b + qwen3.5-35b-a3b" [70B]="llama3.3:70b + qwen3.5-35b-a3b")
                   _TIER_SPEEDS=([7B]="$(speed_label 4)" [14B]="$(speed_label 9)" [35B]="$(speed_label 19)" [70B]="$(speed_label 41)") ;;
            esac
            for _tn in "${_TIER_NAMES[@]}"; do
                _onoff="OFF"; [[ "$_tn" == "$REC_TIER" ]] && _onoff="ON"
                WHIP_TIERS+=("$_tn" "${_TIER_LABELS[$_tn]}  |  ${_TIER_SPEEDS[$_tn]}" "$_onoff")
            done
            TIER_PICK=$(whiptail --title "Model Size — ${VRAM_GB}GB GPU" \
                --radiolist "Recommended tier pre-selected based on your GPU.\nSPACE = select   ENTER = confirm" \
                14 90 4 \
                "${WHIP_TIERS[@]}" 3>&1 1>&2 2>&3) || TIER_PICK="$REC_TIER"
            TIER_PICK="${TIER_PICK//\"/}"
            unset WHIP_TIERS _TIER_LABELS _TIER_SPEEDS
        else
            read -rp "  Choose tier [$REC_NUM]: " _TIER_INPUT
            _TIER_INPUT="${_TIER_INPUT:-$REC_NUM}"
            if [[ "$_TIER_INPUT" =~ ^[1-4]$ ]]; then
                TIER_PICK="${_TIER_NAMES[$((_TIER_INPUT-1))]}"
            else
                TIER_PICK="$_TIER_INPUT"
            fi
        fi
        unset _TIER_NAMES _TIER_INPUT REC_NUM

        case "${MODEL_PREF}:${TIER_PICK}" in
            # Western
            1:7B)   FAST_MODEL="mistral:7b";   CHAT_MODEL="mistral:7b";   CODE_MODEL="codellama:7b";    REASON_MODEL="" ;;
            1:14B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="phi4:14b";     CODE_MODEL="starcoder2:15b";  REASON_MODEL="phi4:14b" ;;
            1:22B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="phi4:14b";     CODE_MODEL="codestral:22b";   REASON_MODEL="phi4:14b" ;;
            1:70B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="llama3.3:70b"; CODE_MODEL="codestral:22b";   REASON_MODEL="llama3.3:70b" ;;
            # Performance-first (Qwen 3.5)
            2:4B)   FAST_MODEL="qwen3.5:4b";          CHAT_MODEL="qwen3.5:4b";          CODE_MODEL="qwen3.5:4b";          REASON_MODEL="" ;;
            2:9B)   FAST_MODEL="qwen3.5:4b";          CHAT_MODEL="qwen3.5:9b";          CODE_MODEL="qwen3.5:9b";          REASON_MODEL="" ;;
            2:35B)  FAST_MODEL="qwen3.5:4b";          CHAT_MODEL="qwen3.5-35b-a3b";     CODE_MODEL="qwen3.5-35b-a3b";     REASON_MODEL="" ;;
            2:27B)  FAST_MODEL="qwen3.5:9b";          CHAT_MODEL="qwen3.5:27b";         CODE_MODEL="qwen3.5:27b";         REASON_MODEL="" ;;
            # Mixed (Western chat + Qwen 3.5 code)
            3:7B)   FAST_MODEL="mistral:7b";   CHAT_MODEL="mistral:7b";   CODE_MODEL="qwen3.5:4b";          REASON_MODEL="" ;;
            3:14B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="phi4:14b";     CODE_MODEL="qwen3.5:9b";          REASON_MODEL="phi4:14b" ;;
            3:35B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="phi4:14b";     CODE_MODEL="qwen3.5-35b-a3b";     REASON_MODEL="phi4:14b" ;;
            3:70B)  FAST_MODEL="mistral:7b";   CHAT_MODEL="llama3.3:70b"; CODE_MODEL="qwen3.5-35b-a3b";     REASON_MODEL="llama3.3:70b" ;;
            *)
                warn "Unrecognised tier '$TIER_PICK' — keeping detected defaults"
                ;;
        esac
    fi

    # Show selected models and ask about download
    _MODEL_SUMMARY="Fast chat:   $FAST_MODEL\nSmart chat:  $CHAT_MODEL\nCode:        $CODE_MODEL"
    [[ -n "$REASON_MODEL" ]] && _MODEL_SUMMARY+="\nReasoning:   $REASON_MODEL"
    _MODEL_SUMMARY+="\nEmbed (RAG): $EMBED_MODEL"

    if command -v whiptail &>/dev/null; then
        if whiptail --title "Download Models Now?" \
            --yesno "Models selected:\n\n$_MODEL_SUMMARY\n\nDownload these models now? (can take 10-40 min)" \
            14 60 3>&1 1>&2 2>&3; then
            PULL_MODELS=true
        fi
    else
        echo ""
        echo "  Models selected:"
        printf "    %-16s %s\n" "Fast chat:"  "$FAST_MODEL"
        printf "    %-16s %s\n" "Smart chat:" "$CHAT_MODEL"
        printf "    %-16s %s\n" "Code:"       "$CODE_MODEL"
        [[ -n "$REASON_MODEL" ]] && printf "    %-16s %s\n" "Reasoning:" "$REASON_MODEL"
        printf "    %-16s %s\n" "Embed (RAG):" "$EMBED_MODEL"
        echo ""
        read -rp "  Download these models now? [Y/n]: " DO_PULL
        [[ "${DO_PULL,,}" != "n" ]] && PULL_MODELS=true
    fi
fi


# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  Setup plan — starting now:${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
$INSTALL_POSTINSTALL && echo "  ✓ Full system setup (ubuntu-post-install.sh — interactive)"
[[ "${#SSH_IMPORT_IDS[@]}" -gt 0 ]] && echo "  ✓ SSH keys    → ${SSH_IMPORT_IDS[*]}"
if $INSTALL_AI; then
    _svcs="Ollama"
    $SVC_WEBUI     && _svcs+=" · Open WebUI"
    $SVC_RAG       && _svcs+=" · RAG+ChromaDB"
    $SVC_MCP       && _svcs+=" · MCP"
    $SVC_GITEA     && _svcs+=" · Gitea"
    $SVC_INVOKEAI  && _svcs+=" · InvokeAI"
    $SVC_COMFYUI   && _svcs+=" · ComfyUI"
    $SVC_PORTAINER && _svcs+=" · Portainer"
    $SVC_KIWIX     && _svcs+=" · Kiwix"
    echo "  ✓ AI stack    → $_svcs"
fi
if $INSTALL_AI; then
    if [[ "$OLLAMA_STORAGE" == "bind" ]]; then
        echo "  ✓ Ollama models → $OLLAMA_HOST_PATH"
    else
        echo "  ✓ Ollama models → Docker volume (default)"
    fi
fi
$SVC_KIWIX && echo "  ✓ Kiwix ZIMs   → $KIWIX_DIR"
$PULL_MODELS   && echo "  ✓ Pull models  : $EMBED_MODEL + $FAST_MODEL + $CHAT_MODEL + $CODE_MODEL${REASON_MODEL:+ + $REASON_MODEL}"
[[ "$ZIM_CHOICE" == "1" ]] && echo "  ✓ Download all ZIMs in background (~130 GB)"
if [[ "$ZIM_CHOICE" == "2" ]]; then
    _nzim=$(wc -w <<< "$ZIM_PICKS")
    echo "  ✓ Download ${_nzim} ZIM(s): $ZIM_PICKS"
fi
echo ""
if command -v whiptail &>/dev/null; then
    whiptail --title "Ready to Install" \
        --yesno "Everything above will be installed and configured.\n\nProceed?" \
        9 50 3>&1 1>&2 2>&3 || { echo "Aborted."; exit 0; }
else
    read -rp "  Proceed? [Y/n]: " CONFIRM
    [[ "${CONFIRM,,}" == "n" ]] && echo "Aborted." && exit 0
fi
echo ""

# ── helper: write only if missing (or --force) ────────────────────────────────
# Usage:  write_if_new /path/to/file << 'EOF' ... EOF
write_if_new() {
    local dest="$1"
    local content; content=$(cat)
    if [[ ! -f "$dest" ]] || $FORCE; then
        if [[ -e "$dest" ]] && [[ ! -w "$dest" ]]; then
            printf '%s\n' "$content" | sudo tee "$dest" > /dev/null
        else
            printf '%s\n' "$content" > "$dest"
        fi
        ok "Wrote $(basename "$dest")"
    else
        info "Kept   $(basename "$dest")  (--force to overwrite)"
    fi
}

# =============================================================================
# Run full system post-install first (sets up Docker, security, base services)
# =============================================================================
if $INSTALL_POSTINSTALL; then
    section "Full System Setup"
    if [[ ! -f "$POSTINSTALL_SCRIPT" ]]; then
        die "ubuntu-post-install.sh not found at $POSTINSTALL_SCRIPT"
    fi
    info "Launching ubuntu-post-install.sh in normal install mode..."
    echo ""
    bash "$POSTINSTALL_SCRIPT"
    echo ""
    ok "System setup complete — continuing with selected components..."
    echo ""
fi

# =============================================================================
section "Prerequisites"
# =============================================================================

# ── Docker (always check — required whether new install or update) ─────────────
if ! command -v docker &>/dev/null; then
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group — changes take effect on next login."
    warn "If docker commands fail, run: newgrp docker"
else
    ok "Docker: $(docker --version | sed 's/Docker version //')"
fi

# Ensure Docker Compose plugin is present (included with modern Docker)
if ! docker compose version &>/dev/null; then
    info "Installing docker-compose-plugin..."
    sudo apt-get install -y docker-compose-plugin
fi
ok "Docker Compose: $(docker compose version --short 2>/dev/null || echo 'ok')"

# ── NVIDIA Container Toolkit ───────────────────────────────────────────────────
if command -v nvidia-smi &>/dev/null; then
    if ! dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
        info "Installing NVIDIA Container Toolkit..."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
          | sudo gpg --dearmor --yes \
            -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
          | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
          | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
        sudo apt-get update -qq
        sudo apt-get install -y nvidia-container-toolkit
        sudo nvidia-ctk runtime configure --runtime=docker
        sudo systemctl restart docker
        ok "NVIDIA Container Toolkit installed"
    else
        ok "NVIDIA Container Toolkit: already present"
    fi
else
    info "No NVIDIA GPU detected — Ollama will run on CPU"
fi

# ── ripgrep (used by MCP search_code tool) ─────────────────────────────────────
if ! command -v rg &>/dev/null; then
    sudo apt-get install -y ripgrep
    ok "ripgrep installed"
fi

# ── SSH key import from GitHub / Launchpad ─────────────────────────────────────
if [[ "${#SSH_IMPORT_IDS[@]}" -gt 0 ]]; then
    section "SSH Keys"
    if ! command -v ssh-import-id &>/dev/null; then
        info "Installing ssh-import-id..."
        sudo apt-get install -y ssh-import-id
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    for id in "${SSH_IMPORT_IDS[@]}"; do
        info "Importing SSH keys: $id"
        ssh-import-id "$id" && ok "Keys imported: $id" || warn "Failed to import: $id"
    done
fi

# =============================================================================
section "Directories"
# =============================================================================
for d in papers repos workspace index invokeai-data invokeai-outputs \
          comfyui-data comfyui-output gitea portainer-data logs; do
    mkdir -p "$BASE/$d"
done
# Kiwix ZIM dir — may be on a different drive
mkdir -p "$KIWIX_DIR"
# Ollama bind-mount dir (if using custom path)
[[ "$OLLAMA_STORAGE" == "bind" ]] && mkdir -p "$OLLAMA_HOST_PATH"
ok "Directories ready"

# =============================================================================
if $INSTALL_AI; then
section "Server Files"
# =============================================================================

# Copy Python servers from repo (always update — they are version-controlled)
cp "$SCRIPT_DIR/server.py"     "$BASE/server.py"     && ok "server.py"
cp "$SCRIPT_DIR/mcp_server.py" "$BASE/mcp_server.py" && ok "mcp_server.py"

# RAG dependencies
cat > "$BASE/requirements.txt" << 'REQ'
fastapi
uvicorn[standard]
httpx
pydantic
chromadb
pypdf
watchdog
python-multipart
REQ
ok "requirements.txt"

# MCP server dependencies
cat > "$BASE/mcp_requirements.txt" << 'REQ'
mcp[cli]
fastapi
uvicorn[standard]
httpx
duckduckgo-search
REQ
ok "mcp_requirements.txt"

fi  # INSTALL_AI

# =============================================================================
section ".env File"
# =============================================================================
# Never overwrite — this is where users store their tokens
if [[ ! -f "$BASE/.env" ]]; then
    cat > "$BASE/.env" << ENV
# Local AI Stack — API Tokens
# Edit this file, then restart: bash $BASE/start.sh

# Open WebUI — set to your public FQDN when behind a reverse proxy (Caddy etc.)
# Without this, sessions/cookies break when accessed via domain name.
# Example: WEBUI_URL=https://webui.yourdomain.com
WEBUI_URL=

# Gitea — generate at http://$LOCAL_IP:3001/user/settings/applications
GITEA_TOKEN=your-gitea-token-here

# GitHub — optional, for GitHub API access via MCP and Gitea↔GitHub sync
GITHUB_TOKEN=your-github-token-here

# Gitea URL — used by sync script (default: http://localhost:3001)
GITEA_URL=http://$LOCAL_IP:3001
ENV
    ok "Created .env — add your tokens before using MCP Gitea/GitHub tools"
else
    info "Kept   .env (never overwritten)"
fi

# =============================================================================
section "Docker Compose"
# =============================================================================
# Build ollama volume line based on storage choice
if [[ "$OLLAMA_STORAGE" == "bind" ]]; then
    OLLAMA_VOLUME_LINE="      - ${OLLAMA_HOST_PATH}:/root/.ollama"
    OLLAMA_VOLUMES_DECL=""
else
    OLLAMA_VOLUME_LINE="      - ollama-models:/root/.ollama"
    OLLAMA_VOLUMES_DECL="  ollama-models:"
fi

# Always written — it's the stack definition and safe to update
cat > "$BASE/docker-compose.yml" << COMPOSE
# Local AI Stack — generated $(date '+%Y-%m-%d')
# Edit .env in this folder to add API tokens.
# GPU: OLLAMA_NUM_GPU=999 means "use all available VRAM" — auto-adapts to any GPU.
#
# ── Common commands (run from this folder) ─────────────────────────────────────
# Start everything:          docker compose up -d
# Stop everything:           docker compose down
# Restart one service:       docker compose restart <service>
# Stop one service:          docker compose stop <service>
# Start one service:         docker compose up -d <service>
# Follow all logs:           docker compose logs -f
# Follow one service logs:   docker compose logs -f <service>
# Pull latest images:        docker compose pull && docker compose up -d
# Show status:               docker compose ps
#
# Services: ollama  open-webui  chromadb  rag-server  mcp-server
#           kiwix  gitea  invokeai  comfyui  portainer
# ───────────────────────────────────────────────────────────────────────────────

services:

  # ── Ollama — LLM inference ──────────────────────────────────────────────────
  ollama:
    image: ollama/ollama:latest
    container_name: ollama
    restart: unless-stopped
    ports:
      - "0.0.0.0:11434:11434"
    volumes:
${OLLAMA_VOLUME_LINE}
    environment:
      - OLLAMA_NUM_GPU=999              # use all available VRAM (auto-detects GPU size)
      - OLLAMA_NUM_CTX=$CTX             # auto-set by detected VRAM
      - OLLAMA_KEEP_ALIVE=24h
      - OLLAMA_MAX_LOADED_MODELS=1
      - OLLAMA_KV_CACHE_TYPE=$OLLAMA_KV_CACHE  # q8_0 halves KV cache; q4_0 = 1/3 size
      - OLLAMA_FLASH_ATTENTION=$OLLAMA_FLASH    # tiled attention: less VRAM, no quality loss
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    healthcheck:
      test: ["CMD", "ollama", "list"]
      interval: 30s
      timeout: 10s
      retries: 5

  # ── Open WebUI — Chat interface ─────────────────────────────────────────────
  open-webui:
    image: ghcr.io/open-webui/open-webui:main
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "0.0.0.0:3000:8080"
    volumes:
      - open-webui-data:/app/backend/data
    environment:
      - OLLAMA_BASE_URL=http://ollama:11434
      - OPENAI_API_BASE_URL=http://rag-server:8001/v1
      - OPENAI_API_KEY=local-rag-key
      - ENABLE_OPENAI_API=true
      - ENABLE_TOOL_SERVERS=true
      - WEBUI_AUTH=true
      - WEBUI_URL=${WEBUI_URL:-}
      - ENABLE_RAG_WEB_SEARCH=true
      - RAG_WEB_SEARCH_ENGINE=duckduckgo
$( $SVC_COMFYUI && cat <<'IMGENV'
      - ENABLE_IMAGE_GENERATION=true
      - IMAGE_GENERATION_ENGINE=comfyui
      - COMFYUI_BASE_URL=http://comfyui:8188
IMGENV
)
    depends_on:
      ollama:
        condition: service_healthy

  # ── ChromaDB — Vector store ─────────────────────────────────────────────────
  chromadb:
    image: chromadb/chroma:latest
    container_name: chromadb
    restart: unless-stopped
    ports:
      - "0.0.0.0:8000:8000"
    volumes:
      - $BASE/index:/chroma/chroma
    environment:
      - IS_PERSISTENT=TRUE
      - ANONYMIZED_TELEMETRY=FALSE

  # ── RAG Server — code-aware retrieval ──────────────────────────────────────
  rag-server:
    image: python:3.11-slim
    container_name: rag-server
    restart: unless-stopped
    ports:
      - "0.0.0.0:8001:8001"
    volumes:
      - $BASE/papers:/papers
      - $BASE/repos:/repos
      - $BASE/index:/index
      - $BASE/server.py:/app/server.py
      - $BASE/requirements.txt:/app/requirements.txt
    working_dir: /app
    environment:
      - OLLAMA_URL=http://ollama:11434
      - CHROMA_URL=http://chromadb:8000
      - EMBED_MODEL=nomic-embed-text
      - CHAT_MODEL=$CHAT_MODEL
      - PAPERS_DIR=/papers
      - REPOS_DIR=/repos
    command: >
      bash -c "apt-get update -qq &&
               apt-get install -y --no-install-recommends git &&
               pip install --no-cache-dir -r requirements.txt &&
               uvicorn server:app --host 0.0.0.0 --port 8001"
    depends_on:
      chromadb:
        condition: service_started
      ollama:
        condition: service_healthy

  # ── MCP Server — Claude Code-equivalent tools ───────────────────────────────
  # Connect via: http://$LOCAL_IP:8002/sse
  # Add to Claude Code:  claude mcp add local http://$LOCAL_IP:8002/sse
  mcp-server:
    image: python:3.11-slim
    container_name: mcp-server
    restart: unless-stopped
    ports:
      - "0.0.0.0:8002:8002"
    volumes:
      - $BASE/workspace:/workspace
      - $BASE/repos:/repos
      - $BASE/mcp_server.py:/app/mcp_server.py
      - $BASE/mcp_requirements.txt:/app/mcp_requirements.txt
      - $SCRIPT_DIR/gitea-github-sync.sh:/app/gitea-github-sync.sh:ro
    working_dir: /app
    env_file: $BASE/.env
    environment:
      - WORKSPACE_DIR=/workspace
      - REPOS_DIR=/repos
      - GITEA_URL=http://gitea:3000
      - RAG_URL=http://rag-server:8001
      - KIWIX_URL=http://kiwix:80
    command: >
      bash -c "apt-get update -qq &&
               apt-get install -y --no-install-recommends git ripgrep curl &&
               pip install --no-cache-dir -r mcp_requirements.txt &&
               python mcp_server.py"
    depends_on:
      - rag-server

  # ── Kiwix — Offline Wikipedia/docs ─────────────────────────────────────────
  kiwix:
    image: ghcr.io/kiwix/kiwix-serve:latest
    container_name: kiwix
    restart: unless-stopped
    ports:
      - "0.0.0.0:8181:80"
    volumes:
      - $KIWIX_DIR:/data
    entrypoint: ["sh", "-c"]
    command: ["ls /data/*.zim >/dev/null 2>&1 && exec kiwix-serve /data/*.zim || { echo 'No ZIM files in /data yet - sleeping. Add .zim files and restart kiwix.'; exec sleep infinity; }"]

  # ── Gitea — Self-hosted Git ─────────────────────────────────────────────────
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    ports:
      - "0.0.0.0:3001:3000"
      - "0.0.0.0:2222:22"
    volumes:
      - $BASE/gitea:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
      - GITEA__webhook__ALLOWED_HOST_LIST=rag-server,mcp-server

  # ── InvokeAI — Image generation ────────────────────────────────────────────
  invokeai:
    image: ghcr.io/invoke-ai/invokeai:latest
    container_name: invokeai
    restart: unless-stopped
    ports:
      - "0.0.0.0:9090:9090"
    volumes:
      - invokeai-models:/invokeai/models
      - $BASE/invokeai-outputs:/invokeai/outputs
      - $BASE/invokeai-data:/invokeai/databases
    environment:
      - INVOKEAI_HOST=0.0.0.0
      - INVOKEAI_PORT=9090
      - INVOKEAI_PRECISION=$INVOKEAI_PRECISION
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  # ── ComfyUI — Node-based image generation ──────────────────────────────────
  comfyui:
    image: ghcr.io/ai-dock/comfyui:latest
    container_name: comfyui
    restart: unless-stopped
    ports:
      - "0.0.0.0:8188:8188"
    volumes:
      - comfyui-models:/opt/ComfyUI/models
      - $BASE/comfyui-output:/opt/ComfyUI/output
      - $BASE/comfyui-data:/opt/ComfyUI/custom_nodes
    environment:
      - CLI_ARGS=--listen 0.0.0.0
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

  # ── Portainer — Docker management UI ───────────────────────────────────────
  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    restart: unless-stopped
    ports:
      - "0.0.0.0:9000:9000"
      - "0.0.0.0:9443:9443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - $BASE/portainer-data:/data

volumes:
${OLLAMA_VOLUMES_DECL}
  open-webui-data:
  invokeai-models:
  comfyui-models:
COMPOSE
ok "docker-compose.yml written"

# =============================================================================
section "Firewall (UFW)"
# =============================================================================
if command -v ufw &>/dev/null; then
    if [[ ! -f "$BASE/.ufw-done" ]] || $FORCE; then
        for port_comment in \
            "3000:Open WebUI" "11434:Ollama" "8001:RAG Server" \
            "8002:MCP Server" "8000:ChromaDB" \
            "8181:Kiwix" "3001:Gitea" "2222:Gitea SSH" \
            "9090:InvokeAI" "8188:ComfyUI" "9000:Portainer" "9443:Portainer S"; do
            port="${port_comment%%:*}"
            comment="${port_comment##*:}"
            sudo ufw allow from "$LAN_SUBNET" to any port "$port" proto tcp \
                comment "$comment" > /dev/null
        done
        sudo ufw reload > /dev/null
        ok "UFW rules set for $LAN_SUBNET"
        touch "$BASE/.ufw-done"
    else
        info "UFW rules already set (--force to redo)"
    fi
else
    warn "ufw not found — skipping firewall config"
fi

# =============================================================================
section "Helper Scripts"
# =============================================================================

# Build URL list for start.sh (only include selected services)
_START_URLS=""
$SVC_WEBUI     && _START_URLS+=$'echo "  Open WebUI  →  http://'"$LOCAL_IP"$':3000"\n'
$SVC_INVOKEAI  && _START_URLS+=$'echo "  InvokeAI    →  http://'"$LOCAL_IP"$':9090"\n'
$SVC_COMFYUI   && _START_URLS+=$'echo "  ComfyUI     →  http://'"$LOCAL_IP"$':8188"\n'
$SVC_GITEA     && _START_URLS+=$'echo "  Gitea       →  http://'"$LOCAL_IP"$':3001"\n'
$SVC_RAG       && _START_URLS+=$'echo "  RAG Health  →  http://'"$LOCAL_IP"$':8001/health"\n'
$SVC_MCP       && _START_URLS+=$'echo "  MCP SSE     →  http://'"$LOCAL_IP"$':8002/sse"\n'
$SVC_PORTAINER && _START_URLS+=$'echo "  Portainer   →  https://'"$LOCAL_IP"$':9443"\n'
$SVC_KIWIX     && _START_URLS+=$'echo "  Kiwix       →  http://'"$LOCAL_IP"$':8181"\n'
_START_MCP=""
$SVC_MCP && _START_MCP=$'echo ""\necho "  Claude Code MCP:"\necho "    claude mcp add local http://'"$LOCAL_IP"$':8002/sse"\n'
_START_PDFS=""
$SVC_RAG && _START_PDFS=$'echo "  Drop PDFs   →  '"$BASE"$'/papers/"\n'
_START_IMGS=""
$SVC_INVOKEAI && _START_IMGS=$'echo "  Images out  →  '"$BASE"$'/invokeai-outputs/"\n'

cat > "$BASE/start.sh" << STARTSH
#!/bin/bash
cd "$BASE"
echo "Pulling latest images..."
docker compose pull --quiet
docker compose up -d
echo ""
$_START_URLS
echo "  Workspace   →  $BASE/workspace/"
$_START_PDFS$_START_IMGS$_START_MCP
STARTSH
chmod +x "$BASE/start.sh"
ok "start.sh"

cat > "$BASE/stop.sh" << STOPSH
#!/bin/bash
cd "$BASE"
docker compose down
echo "All services stopped."
STOPSH
chmod +x "$BASE/stop.sh"
ok "stop.sh"

cat > "$BASE/status.sh" << 'STATUSSH'
#!/bin/bash
echo "=== GPU ==="
nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,memory.used,memory.total \
    --format=csv,noheader 2>/dev/null || echo "(no GPU)"

echo ""
echo "=== Containers ==="
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo ""
echo "=== Ollama models ==="
docker exec ollama ollama ps 2>/dev/null || echo "(not running)"

echo ""
echo "=== RAG ==="
curl -s http://localhost:8001/health | python3 -m json.tool 2>/dev/null \
    || echo "(not running)"

echo ""
echo "=== MCP ==="
curl -s http://localhost:8002/health 2>/dev/null || echo "(not running)"

echo ""
echo "=== Disk ==="
du -sh ~/docker/ai-stack/*/  2>/dev/null
STATUSSH
chmod +x "$BASE/status.sh"
ok "status.sh"

cat > "$BASE/pull-models.sh" << PULLSH
#!/bin/bash
# Models chosen at install time — re-run setup to change selection
EMBED_MODEL="$EMBED_MODEL"
FAST_MODEL="$FAST_MODEL"
CHAT_MODEL="$CHAT_MODEL"
CODE_MODEL="$CODE_MODEL"
REASON_MODEL="$REASON_MODEL"

echo "Waiting for Ollama..."
until docker exec ollama ollama list &>/dev/null; do sleep 3; done
echo "Ollama ready."

echo ""
echo "Pulling embed model (RAG — required)..."
docker exec ollama ollama pull "\$EMBED_MODEL"

echo "Pulling fast chat model..."
docker exec ollama ollama pull "\$FAST_MODEL"

echo "Pulling smart chat model..."
[[ "\$CHAT_MODEL" != "\$FAST_MODEL" ]] && docker exec ollama ollama pull "\$CHAT_MODEL"

echo "Pulling code model..."
docker exec ollama ollama pull "\$CODE_MODEL"

if [[ -n "\$REASON_MODEL" && "\$REASON_MODEL" != "\$CHAT_MODEL" ]]; then
    echo "Pulling reasoning model..."
    docker exec ollama ollama pull "\$REASON_MODEL"
fi

echo ""
echo "Done. Installed models:"
docker exec ollama ollama list
PULLSH
chmod +x "$BASE/pull-models.sh"
ok "pull-models.sh"

write_if_new "$BASE/Caddyfile.example" << CADDY
# Caddy2 reverse proxy — copy to your proxy machine
# Replace yourdomain.com with your actual domain

webui.yourdomain.com {
    reverse_proxy $LOCAL_IP:3000 {
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host  {host}
    }
}
invokeai.yourdomain.com { reverse_proxy $LOCAL_IP:9090 }
comfyui.yourdomain.com  { reverse_proxy $LOCAL_IP:8188 }
git.yourdomain.com      { reverse_proxy $LOCAL_IP:3001 }
kiwix.yourdomain.com    { reverse_proxy $LOCAL_IP:8181 }
rag.yourdomain.com      { reverse_proxy $LOCAL_IP:8001 }
mcp.yourdomain.com      { reverse_proxy $LOCAL_IP:8002 }
portainer.yourdomain.com {
    reverse_proxy https://$LOCAL_IP:9443 {
        transport http { tls_insecure_skip_verify }
    }
}
CADDY

# =============================================================================
section "Systemd Auto-Start"
# =============================================================================
sudo tee /etc/systemd/system/local-ai.service > /dev/null << SYSD
[Unit]
Description=Local AI Stack
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=$USER
WorkingDirectory=$BASE
ExecStart=/bin/bash $BASE/start.sh
ExecStop=/bin/bash $BASE/stop.sh
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
SYSD
sudo systemctl daemon-reload
sudo systemctl enable local-ai.service
ok "Systemd service enabled (local-ai.service)"

# =============================================================================
section "Starting Stack"
# =============================================================================
cd "$BASE"
info "Pulling images (this takes a few minutes on first run)..."

COMPOSE_SERVICES=""
if $INSTALL_AI; then
    COMPOSE_SERVICES="ollama"
    $SVC_WEBUI     && COMPOSE_SERVICES+=" open-webui"
    $SVC_RAG       && COMPOSE_SERVICES+=" chromadb rag-server"
    $SVC_MCP       && COMPOSE_SERVICES+=" mcp-server"
    $SVC_GITEA     && COMPOSE_SERVICES+=" gitea"
    $SVC_INVOKEAI  && COMPOSE_SERVICES+=" invokeai"
    $SVC_COMFYUI   && COMPOSE_SERVICES+=" comfyui"
    $SVC_PORTAINER && COMPOSE_SERVICES+=" portainer"
    $SVC_KIWIX     && COMPOSE_SERVICES+=" kiwix"
fi

# shellcheck disable=SC2086
docker compose pull --quiet $COMPOSE_SERVICES
# shellcheck disable=SC2086
docker compose up -d $COMPOSE_SERVICES
ok "Stack started"

# ── Pull Ollama models (answer was captured upfront) ─────────────────────────
if $INSTALL_AI && $PULL_MODELS; then
    section "Pulling Ollama Models"
    info "Waiting for Ollama to be ready..."
    until docker exec ollama ollama list &>/dev/null; do sleep 3; done
    ok "Ollama ready."

    info "Pulling embed model (required for RAG)..."
    docker exec ollama ollama pull "$EMBED_MODEL"

    info "Pulling fast chat model..."
    docker exec ollama ollama pull "$FAST_MODEL"

    info "Pulling smart chat model..."
    docker exec ollama ollama pull "$CHAT_MODEL"

    info "Pulling code model..."
    docker exec ollama ollama pull "$CODE_MODEL"

    if [[ -n "$REASON_MODEL" ]]; then
        info "Pulling reasoning model ($REASON_MODEL)..."
        docker exec ollama ollama pull "$REASON_MODEL"
    fi

    ok "All models pulled."
    echo ""
    docker exec ollama ollama list
elif $INSTALL_AI; then
    info "Skipping model pull — run later: bash $BASE/pull-models.sh"
fi

# ── Install image generation base model (GPU-aware) ──────────────────────────
if $INSTALL_AI && ($SVC_INVOKEAI || $SVC_COMFYUI) && $PULL_MODELS; then
    section "Image Generation Models"
    info "GPU: ${TOTAL_VRAM}GB VRAM → $IMG_TIER"
    if [[ -n "$IMG_DEFAULT" ]]; then
        info "Auto-installing recommended model: $IMG_DEFAULT"
        info "Supported on your GPU: $IMG_MODELS"
        bash "$SCRIPT_DIR/setup-image-models.sh" --auto
    else
        warn "Not enough VRAM for image generation models (need at least 4GB)"
    fi
elif $INSTALL_AI && ($SVC_INVOKEAI || $SVC_COMFYUI); then
    info "Skipping image model install — run later: bash $SCRIPT_DIR/setup-image-models.sh"
fi

# ── Start ZIM downloads (answer was captured upfront) ────────────────────────
if $SVC_KIWIX && [[ "$ZIM_CHOICE" != "3" ]]; then
    section "Starting ZIM Downloads"
    LOG="$BASE/logs/kiwix-download.log"
    mkdir -p "$(dirname "$LOG")"

    info "Checking mirrors for latest ZIM filenames..."

    MIRROR="https://ftp.fau.de/kiwix/zim"
    MIRROR2="https://download.kiwix.org/zim"

    latest_zim() {
        local base_url="$1" pattern="$2"
        curl -s "$base_url/" | grep -oP "${pattern}_[0-9-]+\.zim" | sort -u | tail -1
    }

    dl_zim() {
        local cat="$1" file="$2" desc="$3" mirror="${4:-$MIRROR}"
        local dest="$KIWIX_DIR/$file"
        if [[ -z "$file" ]]; then warn "Could not find $desc — skipping"; return; fi
        if [[ -f "$dest" ]]; then ok "$desc already downloaded"; return; fi
        info "Starting: $desc"
        nohup wget -c "$mirror/$cat/$file" -O "$dest" >> "$LOG" 2>&1 &
        echo $! >> "$KIWIX_DIR/.download_pids"
        ok "Download started (PID $!) — $desc"
    }

    WIKI=$(latest_zim "$MIRROR/wikipedia"    "wikipedia_en_all_nopic")
    SO=$(latest_zim   "$MIRROR/stack_exchange" "stackoverflow.com_en_all")
    ASKUBUNTU=$(latest_zim "$MIRROR/stack_exchange" "askubuntu.com_en_all")
    SUPERUSER=$(latest_zim "$MIRROR/stack_exchange" "superuser.com_en_all")
    UNIXSE=$(latest_zim    "$MIRROR/stack_exchange" "unix.stackexchange.com_en_all")
    SERVERFAULT=$(latest_zim "$MIRROR/stack_exchange" "serverfault.com_en_all")
    ARCH=$(latest_zim "$MIRROR/other"        "archlinux_en_all_maxi")
    WIKT=$(latest_zim "$MIRROR/wiktionary"   "wiktionary_en_all_nopic")
    WIKB=$(latest_zim "$MIRROR/wikibooks"    "wikibooks_en_all_nopic")
    WIKS=$(latest_zim "$MIRROR/wikisource"   "wikisource_en_all_nopic")
    WIKV=$(latest_zim "$MIRROR/wikivoyage"   "wikivoyage_en_all_nopic")
    WIKUNI=$(latest_zim "$MIRROR/wikiversity" "wikiversity_en_all_nopic")
    WIKNEWS=$(latest_zim "$MIRROR/wikinews"  "wikinews_en_all_nopic")
    WIKQ=$(latest_zim "$MIRROR/wikiquote"    "wikiquote_en_all_nopic")
    VIKIDIA=$(latest_zim "$MIRROR/vikidia"   "vikidia_en_all_nopic")
    TED=$(latest_zim   "$MIRROR/ted"         "ted_mul_youth")
    PHET=$(latest_zim  "$MIRROR/phet"        "phet_en_all")
    DEVDOCS=$(latest_zim "$MIRROR/devdocs"   "devdocs_en_zig")
    FCC=$(latest_zim   "$MIRROR/freecodecamp" "freecodecamp_en_all")
    IFIX=$(latest_zim  "$MIRROR/ifixit"      "ifixit_en_all")
    LIBRE=$(latest_zim "$MIRROR/libretexts"  "libretexts.org_en_workforce")
    GUT=$(latest_zim   "$MIRROR2/gutenberg"  "gutenberg_en_all")

    if [[ "$ZIM_CHOICE" == "2" ]]; then
        # ZIM_PICKS contains space-separated ZIM names selected during the wizard
        rm -f "$KIWIX_DIR/.download_pids"
        for _zn in $ZIM_PICKS; do
            case "$_zn" in
                wikipedia)     dl_zim "wikipedia"      "$WIKI"       "Wikipedia" ;;
                stackoverflow) dl_zim "stack_exchange" "$SO"        "Stack Overflow" ;;
                askubuntu)     dl_zim "stack_exchange" "$ASKUBUNTU" "Ask Ubuntu" ;;
                superuser)     dl_zim "stack_exchange" "$SUPERUSER" "Super User" ;;
                unixse)        dl_zim "stack_exchange" "$UNIXSE"    "Unix & Linux SE" ;;
                serverfault)   dl_zim "stack_exchange" "$SERVERFAULT" "Server Fault" ;;
                archlinux)     dl_zim "other"          "$ARCH"      "Arch Linux Wiki" ;;
                wiktionary)   dl_zim "wiktionary"      "$WIKT"   "Wiktionary" ;;
                wikibooks)    dl_zim "wikibooks"        "$WIKB"   "Wikibooks" ;;
                wikisource)   dl_zim "wikisource"       "$WIKS"   "Wikisource" ;;
                wikivoyage)   dl_zim "wikivoyage"       "$WIKV"   "Wikivoyage" ;;
                wikiversity)  dl_zim "wikiversity"      "$WIKUNI" "Wikiversity" ;;
                wikinews)     dl_zim "wikinews"         "$WIKNEWS" "WikiNews" ;;
                wikiquote)    dl_zim "wikiquote"        "$WIKQ"   "Wikiquote" ;;
                vikidia)      dl_zim "vikidia"          "$VIKIDIA" "Vikidia (kids K-8)" ;;
                ted)          dl_zim "ted"              "$TED"    "TED Talks" ;;
                phet)         dl_zim "phet"             "$PHET"   "PhET Simulations" ;;
                devdocs)      dl_zim "devdocs"          "$DEVDOCS" "DevDocs" ;;
                freecodecamp) dl_zim "freecodecamp"     "$FCC"    "FreeCodeCamp" ;;
                ifixit)       dl_zim "ifixit"           "$IFIX"   "iFixit" ;;
                libretexts)   dl_zim "libretexts"       "$LIBRE"  "LibreTexts" ;;
                gutenberg)    dl_zim "gutenberg"        "$GUT"    "Project Gutenberg" "$MIRROR2" ;;
            esac
        done
    else
        # Download all
        rm -f "$KIWIX_DIR/.download_pids"
        dl_zim "wikipedia"      "$WIKI"       "Wikipedia"
        dl_zim "stack_exchange" "$SO"        "Stack Overflow"
        dl_zim "stack_exchange" "$ASKUBUNTU" "Ask Ubuntu"
        dl_zim "stack_exchange" "$SUPERUSER" "Super User"
        dl_zim "stack_exchange" "$UNIXSE"    "Unix & Linux SE"
        dl_zim "stack_exchange" "$SERVERFAULT" "Server Fault"
        dl_zim "other"          "$ARCH"      "Arch Linux Wiki"
        dl_zim "wiktionary"     "$WIKT"    "Wiktionary"
        dl_zim "wikibooks"      "$WIKB"    "Wikibooks"
        dl_zim "wikisource"     "$WIKS"    "Wikisource"
        dl_zim "wikivoyage"     "$WIKV"    "Wikivoyage"
        dl_zim "wikiversity"    "$WIKUNI"  "Wikiversity"
        dl_zim "wikinews"       "$WIKNEWS" "WikiNews"
        dl_zim "wikiquote"      "$WIKQ"    "Wikiquote"
        dl_zim "vikidia"        "$VIKIDIA" "Vikidia (kids K-8)"
        dl_zim "ted"            "$TED"     "TED Talks"
        dl_zim "phet"           "$PHET"    "PhET Simulations"
        dl_zim "devdocs"        "$DEVDOCS" "DevDocs"
        dl_zim "freecodecamp"   "$FCC"     "FreeCodeCamp"
        dl_zim "ifixit"         "$IFIX"    "iFixit"
        dl_zim "libretexts"     "$LIBRE"   "LibreTexts"
        dl_zim "gutenberg"      "$GUT"     "Project Gutenberg" "$MIRROR2"
    fi
    ok "ZIM downloads running in background — monitor: tail -f $LOG"
fi

# =============================================================================
echo ""
echo -e "${GREEN}${BOLD}━━━  Done!  ━━━${NC}"
echo ""
if $INSTALL_AI; then
    $SVC_WEBUI     && echo -e "  ${CYAN}Open WebUI${NC}   →  http://$LOCAL_IP:3000"
    $SVC_INVOKEAI  && echo -e "  ${CYAN}InvokeAI${NC}     →  http://$LOCAL_IP:9090"
    $SVC_COMFYUI   && echo -e "  ${CYAN}ComfyUI${NC}      →  http://$LOCAL_IP:8188"
    $SVC_GITEA     && echo -e "  ${CYAN}Gitea${NC}        →  http://$LOCAL_IP:3001"
    $SVC_RAG       && echo -e "  ${CYAN}RAG Health${NC}   →  http://$LOCAL_IP:8001/health"
    $SVC_MCP       && echo -e "  ${CYAN}MCP SSE${NC}      →  http://$LOCAL_IP:8002/sse"
    $SVC_PORTAINER && echo -e "  ${CYAN}Portainer${NC}    →  https://$LOCAL_IP:9443"
    $SVC_KIWIX     && echo -e "  ${CYAN}Kiwix${NC}        →  http://$LOCAL_IP:8181"
fi
echo ""
if $INSTALL_AI; then
    $SVC_MCP && $SVC_WEBUI && {
        echo -e "  ${YELLOW}Add MCP to Open WebUI (one-time):${NC}"
        echo "    Open WebUI → Admin → Settings → Tools → ＋"
        echo "    URL:  http://$LOCAL_IP:8002/sse"
        echo ""
    }
    $SVC_MCP && { echo -e "  ${YELLOW}Add MCP to Claude Code:${NC}"; echo "    claude mcp add local http://$LOCAL_IP:8002/sse"; echo ""; }
    echo -e "  ${YELLOW}Add API tokens to:${NC}  $BASE/.env"
    $SVC_RAG && echo -e "  ${YELLOW}Drop PDFs into:${NC}     $BASE/papers/"
    echo -e "  ${YELLOW}Your workspace:${NC}     $BASE/workspace/"
    $SVC_GITEA && {
        echo ""
        echo -e "  ${YELLOW}Gitea ↔ GitHub sync:${NC}"
        echo "    First time:   $SCRIPT_DIR/gitea-github-sync.sh --init"
        echo "    Sync now:     $SCRIPT_DIR/gitea-github-sync.sh"
        echo "    Auto (6h):    $SCRIPT_DIR/gitea-github-sync.sh --install-timer"
        echo "    Via MCP:      gitea_github_sync(mode='all')"
    }
fi
if $INSTALL_AI; then
    echo ""
    echo -e "  ${YELLOW}Recommended Open WebUI Functions (install from Admin → Functions → ＋):${NC}"
    echo "    Context tracker:    https://openwebui.com/f/centrisic/context_tracker"
    echo "      → Shows tokens used vs available, progress bar, context % remaining"
    echo "    Context compaction: https://openwebui.com/f/projectmoon/checkpoint_summarization_filter"
    echo "      → Auto-summarizes old messages when context fills up (like Claude)"
    echo "    Auto Memory:        Install from Admin → Functions → Discover → search 'Auto Memory'"
    echo "      → Automatically stores relevant info as persistent memories across chats"
    ($SVC_COMFYUI || $SVC_INVOKEAI) && {
        echo ""
        echo -e "  ${YELLOW}Image Generation — GPU: ${TOTAL_VRAM}GB → $IMG_TIER${NC}"
        echo "    Install base models (detects your GPU automatically):"
        echo "      ./setup-image-models.sh          # interactive"
        echo "      ./setup-image-models.sh --auto   # install recommended default"
        echo "    Supports: $IMG_MODELS"
    }
    $SVC_COMFYUI && {
        echo ""
        echo -e "  ${YELLOW}ComfyUI → Open WebUI (chat-integrated image gen):${NC}"
        echo "    1. Run ./setup-image-models.sh to install a base model"
        echo "    2. In ComfyUI: Settings (gear) → enable 'Dev Mode' → Save workflow as 'API Format'"
        echo "    3. In Open WebUI: Admin → Settings → Images"
        echo "       Engine: ComfyUI  |  URL: http://comfyui:8188  (already set via env vars)"
        echo "    4. Import your workflow JSON and map the prompt/output nodes"
        echo "    5. Ask any model to 'generate an image of...' — it will use ComfyUI"
    }
    $SVC_INVOKEAI && {
        echo ""
        echo -e "  ${YELLOW}InvokeAI (standalone UI — inpainting, img2img, LoRA):${NC}"
        echo "    InvokeAI runs at http://$LOCAL_IP:9090"
        echo "    For inpainting: Unified Canvas tab → brush over area → describe replacement"
        echo "    Import LoRAs:   ./invokeai-import-lora.sh <file.safetensors>"
        $SVC_COMFYUI || echo "    For Open WebUI chat integration, enable ComfyUI in the setup wizard"
    }
fi
if $SVC_KIWIX && [[ "$ZIM_CHOICE" == "3" ]]; then
    echo -e "  ${YELLOW}ZIM downloads:${NC}      ./kiwix_download.sh  (not started)"
elif $SVC_KIWIX; then
    echo -e "  ${YELLOW}ZIM progress:${NC}       tail -f $BASE/logs/kiwix-download.log"
    echo -e "  ${YELLOW}ZIM location:${NC}       $KIWIX_DIR/"
fi
echo ""
$IS_UPDATE && echo -e "  ${GREEN}Update complete.${NC}" \
           || echo -e "  ${GREEN}Fresh install complete.${NC}"
echo ""
