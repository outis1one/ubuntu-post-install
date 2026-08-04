#!/bin/bash
# =============================================================================
# Ollama Model Auto-Updater
# Pulls latest version of every installed model. Ollama compares digests
# server-side — no download happens if the model is already current.
# Safe to run as a systemd timer.
# =============================================================================

OLLAMA_URL="${OLLAMA_HOST:-http://localhost:11434}"
LOG="$HOME/docker/ai-stack/logs/ollama-update.log"
mkdir -p "$(dirname "$LOG")"

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N}  $1" | tee -a "$LOG"; }
inf() { echo -e "${C}[..]${N}  $1" | tee -a "$LOG"; }
wrn() { echo -e "${Y}[!!]${N}  $1" | tee -a "$LOG"; }
err() { echo -e "${R}[XX]${N}  $1" | tee -a "$LOG"; }

echo "" | tee -a "$LOG"
echo "=== Ollama Model Update: $(date) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Check Ollama is reachable
if ! curl -sf "$OLLAMA_URL/api/tags" > /dev/null; then
    err "Ollama not reachable at $OLLAMA_URL — is the container running?"
    exit 1
fi

# Get installed model names from the API
mapfile -t MODELS < <(
    curl -sf "$OLLAMA_URL/api/tags" | \
    grep -oP '"name"\s*:\s*"\K[^"]+' | \
    sort -u
)

if [[ ${#MODELS[@]} -eq 0 ]]; then
    wrn "No models found — nothing to update"
    exit 0
fi

inf "Found ${#MODELS[@]} model(s): ${MODELS[*]}"
echo "" | tee -a "$LOG"

UPDATED=0
FAILED=0

for model in "${MODELS[@]}"; do
    inf "Pulling $model..."
    output=$(ollama pull "$model" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        err "$model: pull failed"
        echo "$output" >> "$LOG"
        FAILED=$((FAILED + 1))
    elif echo "$output" | grep -q "up to date"; then
        ok "$model: already up to date"
    else
        ok "$model: updated"
        UPDATED=$((UPDATED + 1))
    fi
done

echo "" | tee -a "$LOG"
inf "Done — $UPDATED updated, $FAILED failed"
echo "=== Complete: $(date) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"
