#!/usr/bin/env bash
# prefetch-models.sh — download AI models on the host, outside Docker.
#
# Use this when the container's outbound DNS/network is blocked (see
# README troubleshooting) and models can't be downloaded at container
# startup. Downloads land under ./data/, which both compose files already
# bind-mount into the container — so the container picks them up on next
# start with no rebuild and no in-container network access required.
#
# Usage:
#   ./prefetch-models.sh           # SAM + U2Net + BEN2 + BiRefNet-HR (~1.5GB)
#   ./prefetch-models.sh --sdxl    # also prefetch SDXL base + inpaint (~13GB)
#
# Safe to re-run: every download here skips files that already exist
# (HuggingFace Hub) or are already present (SAM/U2Net). Each model is
# independent — one failing (e.g. no network reachable at all) doesn't
# block the others from being attempted.

set -uo pipefail

cd "$(dirname "$0")"

if ! command -v python3 &>/dev/null; then
    echo "✗ python3 is required on the host for this script (Docker is not used here)." >&2
    echo "  Ubuntu/Debian: sudo apt install python3 python3-pip" >&2
    exit 1
fi

# mkdir -p succeeds silently on an already-existing directory even when we
# can't write into it, so actually test writability rather than trusting that.
check_writable() {
    mkdir -p "$1" 2>/dev/null
    touch "$1/.write_test" 2>/dev/null && rm -f "$1/.write_test"
}

NEED_CHOWN=0
for d in data/models data/hf_cache; do
    check_writable "$d" || NEED_CHOWN=1
done

if [ "$NEED_CHOWN" -eq 1 ]; then
    echo "⚠ ./data isn't writable by $(id -un) — this usually means Docker created it as root on a previous run."
    echo "  Fixing ownership (the container runs as root and will still work fine afterward):"
    echo "    sudo chown -R $(id -u):$(id -g) ./data"
    if ! sudo chown -R "$(id -u):$(id -g)" ./data; then
        echo "✗ Could not fix ownership automatically (sudo failed or unavailable)." >&2
        echo "  Run this manually, then re-run this script:" >&2
        echo "    sudo chown -R \$(id -u):\$(id -g) ./data" >&2
        exit 1
    fi
    for d in data/models data/hf_cache; do
        check_writable "$d" || { echo "✗ Still no write permission in ./$d after chown." >&2; exit 1; }
    done
    echo "✓ Fixed."
fi

PREFETCH_SDXL=0
if [ "${1:-}" = "--sdxl" ]; then
    PREFETCH_SDXL=1
fi

FAILED=()

echo "=================================================="
echo "  Prefetching AI models (host-side, no Docker)"
echo "=================================================="

echo ""
echo "── SAM (Smart Select) ───────────────────────────────"
python3 scripts/download_sam_model.py vit_b || FAILED+=("SAM")

echo ""
echo "── U2Net (Remove Background fallback) ──────────────"
python3 scripts/download_u2net_model.py u2net || FAILED+=("U2Net")

echo ""
echo "── HuggingFace Hub models (BEN2, BiRefNet-HR) ───────"

if ! python3 -c "import huggingface_hub" &>/dev/null; then
    echo "Installing huggingface_hub (lightweight — no torch/GPU needed for this step)..."
    PIP_ERR=$(python3 -m pip install --quiet --user "huggingface_hub>=0.23.0" 2>&1) || {
        if echo "$PIP_ERR" | grep -q "externally-managed-environment"; then
            # PEP 668 (Debian/Ubuntu 12+): --user already keeps this out of
            # apt-managed system site-packages, so overriding here is safe.
            echo "System Python is externally managed — retrying with --break-system-packages"
            python3 -m pip install --quiet --user --break-system-packages "huggingface_hub>=0.23.0" \
                || FAILED+=("huggingface_hub install")
        else
            echo "$PIP_ERR" >&2
            FAILED+=("huggingface_hub install")
        fi
    }
fi

if python3 -c "import huggingface_hub" &>/dev/null; then
    # HF_HOME must match what the container resolves by default: the bind mount
    # maps ./data/hf_cache -> /root/.cache/huggingface, and the container never
    # sets HF_HOME explicitly, so it defaults to ~/.cache/huggingface there.
    # huggingface_hub itself appends "/hub" to HF_HOME to get the actual cache
    # root (HF_HUB_CACHE) — setting HF_HOME here (instead of passing --cache-dir
    # or cache_dir=... directly) lets both sides derive that "/hub" nesting the
    # same way, rather than us hardcoding it and risking a mismatch.
    export HF_HOME="$(pwd)/data/hf_cache"

    PREFETCH_SDXL="$PREFETCH_SDXL" python3 - << 'PYEOF' || FAILED+=("HuggingFace models")
import os
from huggingface_hub import snapshot_download

repos = ["PramaLLC/BEN2", "zhengpeng7/BiRefNet_HR"]
if os.environ.get("PREFETCH_SDXL") == "1":
    repos += [
        "stabilityai/stable-diffusion-xl-base-1.0",
        "diffusers/stable-diffusion-xl-1.0-inpainting-0.1",
    ]

for repo_id in repos:
    print(f"\nDownloading {repo_id} ...")
    snapshot_download(repo_id=repo_id, ignore_patterns=["*.msgpack", "flax_*", "tf_*"])
    print(f"  done: {repo_id}")
PYEOF
else
    echo "⚠ Skipping BEN2/BiRefNet-HR — huggingface_hub unavailable (install failed above)"
    FAILED+=("HuggingFace models")
fi

echo ""
echo "=================================================="
if [ ${#FAILED[@]} -eq 0 ]; then
    echo "  Done. Models cached under ./data/models and ./data/hf_cache"
    if [ "$PREFETCH_SDXL" != "1" ]; then
        echo "  (SDXL not included — re-run with --sdxl to also prefetch txt2img/inpaint, ~13GB)"
    fi
    echo "  Start the app:  ./bring-up-local-gpu.sh"
else
    echo "  Finished with failures: ${FAILED[*]}"
    echo "  If ALL of the above failed, this host can't reach the internet right now"
    echo "  (check: curl -v https://github.com) — that's a host/network issue, not Docker."
    echo "  If only some failed, re-run this script to retry just those."
fi
echo "=================================================="
