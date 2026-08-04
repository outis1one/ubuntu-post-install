#!/usr/bin/env bash
# configure-storage.sh — interactively assign drives for ZIM and model storage
# then patches docker-compose.yml in place
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${CYAN}[..]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[!!]${NC}  $*"; }
die()     { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$BASE/docker-compose.yml"

[[ -f "$COMPOSE" ]] || die "docker-compose.yml not found at $BASE — run local-ai-setup.sh first"

# ── collect drives ─────────────────────────────────────────────────────────────
echo -e "\n${BOLD}━━━  Detected Drives  ━━━${NC}\n"

# build array of mountpoints excluding tiny/system ones
mapfile -t MOUNTS < <(
  df -h --output=target,size,avail,pcent 2>/dev/null \
  | tail -n +2 \
  | grep -v -E '^\s*(/$|/boot|/sys|/proc|/dev|/run|/snap|/var/lib/docker|/etc|tmpfs)' \
  | awk '$3 ~ /[0-9]/ {print}' \
  | sort -u
)

if [[ ${#MOUNTS[@]} -eq 0 ]]; then
  warn "No additional mounted drives found beyond system disk."
  warn "Mount your drives first (e.g. /mnt/storage), then re-run this script."
  echo ""
  echo "Quick mount example:"
  echo "  sudo mkdir -p /mnt/storage"
  echo "  sudo mount /dev/sdb1 /mnt/storage"
  echo "  # To make permanent, add to /etc/fstab"
  exit 0
fi

# display numbered list
echo -e "  ${BOLD}#   Mount Point                  Size    Free    Used${NC}"
echo    "  ─────────────────────────────────────────────────────"
IDX=0
declare -a MOUNT_PATHS
for line in "${MOUNTS[@]}"; do
  mp=$(echo "$line" | awk '{print $1}')
  sz=$(echo "$line" | awk '{print $2}')
  av=$(echo "$line" | awk '{print $3}')
  pc=$(echo "$line" | awk '{print $4}')
  printf "  ${CYAN}%-3d${NC} %-30s %-7s %-7s %s\n" "$IDX" "$mp" "$sz" "$av" "$pc"
  MOUNT_PATHS[$IDX]="$mp"
  (( IDX++ ))
done
echo ""

pick_drive() {
  local purpose="$1"
  local varname="$2"
  local skip_ok="${3:-true}"

  echo -e "${BOLD}$purpose storage${NC}"
  if $skip_ok; then
    read -rp "  Enter drive number (or Enter to skip): " choice
  else
    read -rp "  Enter drive number: " choice
  fi

  if [[ -z "$choice" ]]; then
    eval "$varname=''"
    info "Skipping $purpose storage."
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -lt "$IDX" ]]; then
    eval "$varname='${MOUNT_PATHS[$choice]}'"
    ok "Selected: ${MOUNT_PATHS[$choice]}"
  else
    warn "Invalid choice — skipping $purpose."
    eval "$varname=''"
  fi
  echo ""
}

# ── ZIM storage ────────────────────────────────────────────────────────────────
echo -e "${BOLD}━━━  Kiwix ZIM Storage  ━━━${NC}\n"
echo "  ZIM files can be large (Wikipedia alone is ~100GB)."
echo "  Pick a drive with plenty of space."
echo ""
pick_drive "ZIM" ZIM_DRIVE

ZIM_PATH=""
if [[ -n "$ZIM_DRIVE" ]]; then
  read -rp "  Folder name on that drive [zims]: " ZIM_FOLDER
  ZIM_FOLDER="${ZIM_FOLDER:-zims}"
  ZIM_PATH="$ZIM_DRIVE/$ZIM_FOLDER"
  mkdir -p "$ZIM_PATH"
  ok "ZIM path: $ZIM_PATH"
  echo ""
fi

# ── Model storage ──────────────────────────────────────────────────────────────
echo -e "${BOLD}━━━  Ollama Model Storage  ━━━${NC}\n"
echo "  Models range from 4GB (7B) to 30GB+ (70B)."
echo "  Pick a fast drive (SSD preferred) with 50–200GB free."
echo ""
pick_drive "Model" MODEL_DRIVE

MODEL_PATH=""
if [[ -n "$MODEL_DRIVE" ]]; then
  read -rp "  Folder name on that drive [ollama-models]: " MODEL_FOLDER
  MODEL_FOLDER="${MODEL_FOLDER:-ollama-models}"
  MODEL_PATH="$MODEL_DRIVE/$MODEL_FOLDER"
  mkdir -p "$MODEL_PATH"
  ok "Model path: $MODEL_PATH"
  echo ""
fi

# ── bail if nothing selected ───────────────────────────────────────────────────
if [[ -z "$ZIM_PATH" && -z "$MODEL_PATH" ]]; then
  info "Nothing selected — no changes made."
  exit 0
fi

# ── summary + confirm ──────────────────────────────────────────────────────────
echo -e "${BOLD}━━━  Planned Changes  ━━━${NC}\n"
[[ -n "$ZIM_PATH"   ]] && echo "  Kiwix ZIMs  →  $ZIM_PATH"
[[ -n "$MODEL_PATH" ]] && echo "  Ollama models →  $MODEL_PATH"
echo ""
read -rp "Apply these changes to docker-compose.yml? [Y/n]: " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && { info "Aborted — no changes made."; exit 0; }

# ── backup ────────────────────────────────────────────────────────────────────
cp "$COMPOSE" "$COMPOSE.bak"
info "Backed up to docker-compose.yml.bak"

# ── patch kiwix volumes ────────────────────────────────────────────────────────
if [[ -n "$ZIM_PATH" ]]; then
  # Replace the kiwix volumes line to add extra ZIM mounts
  # Current:  volumes: [$BASE/kiwix:/data]
  # New:      volumes:
  #             - $BASE/kiwix:/data
  #             - /mnt/drive/zims:/data/external

  python3 - "$COMPOSE" "$BASE" "$ZIM_PATH" << 'PY'
import sys, re

compose_file = sys.argv[1]
base         = sys.argv[2]
zim_path     = sys.argv[3]

text = open(compose_file).read()

# Find the kiwix service volumes line (single-line array style)
old = f"    volumes: [{base}/kiwix:/data]"
new = (
    f"    volumes:\n"
    f"      - {base}/kiwix:/data\n"
    f"      - {zim_path}:/data/external"
)

if old in text:
    text = text.replace(old, new)
    open(compose_file, "w").write(text)
    print(f"[OK]  Kiwix volumes updated")
else:
    # Already multi-line — append the new mount if not already there
    marker = "container_name: kiwix"
    if marker in text and zim_path not in text:
        # find the volumes block under kiwix and append
        lines = text.splitlines()
        in_kiwix = False
        in_vols  = False
        insert_after = -1
        for i, line in enumerate(lines):
            if marker in line:
                in_kiwix = True
            if in_kiwix and "volumes:" in line:
                in_vols = True
            if in_vols and line.strip().startswith("- ") and ":/data" in line:
                insert_after = i
            if in_vols and insert_after > 0 and not line.strip().startswith("- "):
                break
        if insert_after > 0:
            lines.insert(insert_after + 1, f"      - {zim_path}:/data/external")
            open(compose_file, "w").write("\n".join(lines) + "\n")
            print(f"[OK]  Kiwix extra ZIM volume appended")
        else:
            print(f"[!!]  Could not patch kiwix volumes — edit manually: add  - {zim_path}:/data/external")
    else:
        print(f"[!!]  Kiwix volumes line not found in expected format — edit manually")
PY
fi

# ── patch ollama volumes ───────────────────────────────────────────────────────
if [[ -n "$MODEL_PATH" ]]; then
  python3 - "$COMPOSE" "$MODEL_PATH" << 'PY'
import sys

compose_file = sys.argv[1]
model_path   = sys.argv[2]

text = open(compose_file).read()

# Replace Docker-managed volume with host path
old = "    volumes: [ollama-models:/root/.ollama]"
new = f"    volumes: [{model_path}:/root/.ollama]"

if old in text:
    text = text.replace(old, new)
    # Remove ollama-models from the top-level volumes section if present
    text = text.replace("  ollama-models:\n", "")
    open(compose_file, "w").write(text)
    print(f"[OK]  Ollama volume → {model_path}")
else:
    print(f"[!!]  ollama volumes line not in expected format — edit manually:")
    print(f"      change  ollama-models:/root/.ollama  to  {model_path}:/root/.ollama")
PY
fi

# ── restart if running ─────────────────────────────────────────────────────────
echo ""
if docker compose -f "$COMPOSE" ps --quiet 2>/dev/null | grep -q .; then
  read -rp "Stack is running — restart now to apply changes? [Y/n]: " RESTART
  if [[ "${RESTART,,}" != "n" ]]; then
    cd "$BASE"
    docker compose down
    docker compose up -d
    ok "Stack restarted"
  else
    warn "Remember to restart: cd $BASE && docker compose down && docker compose up -d"
  fi
else
  info "Stack not running — changes will apply on next start."
fi

echo ""
echo -e "${GREEN}${BOLD}Done!${NC}"
[[ -n "$ZIM_PATH"   ]] && echo "  Drop .zim files into: $ZIM_PATH"
[[ -n "$MODEL_PATH" ]] && echo "  Ollama models stored in: $MODEL_PATH"
echo ""
echo "  Undo: cp $COMPOSE.bak $COMPOSE"
