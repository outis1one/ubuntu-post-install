#!/usr/bin/env bash
# bring-up-local-gpu.sh — start the GPU container.
#
# Run this each time you want to start the app.
# Run ./install-local-gpu.sh once first on a new machine.
#
# Before starting, this fetches any missing models on the host (outside
# Docker) via ./prefetch-models.sh — in-container DNS/network is unreliable
# on some hosts, so this is the default now, not a manual troubleshooting
# step. It never blocks startup: if it fails (no network, no python3, etc.)
# the container still starts and falls back to its own in-container download.
#
# Usage:
#   ./bring-up-local-gpu.sh              # start (detached, rebuild if needed)
#   ./bring-up-local-gpu.sh --no-build   # start without rebuilding
#   ./bring-up-local-gpu.sh down         # stop and remove container
#   ./bring-up-local-gpu.sh logs -f      # tail logs
#
# Force pip layer rebuild (e.g. after requirements change):
#   BUILDID=$(date +%s) ./bring-up-local-gpu.sh

set -euo pipefail

cd "$(dirname "$0")"

# Pre-create ./data as the current (non-root) user. Otherwise, on a fresh
# checkout, Docker's daemon (root) auto-creates these bind-mount sources on
# the first 'up' — leaving them root-owned and blocking this same user from
# later writing to them without sudo (e.g. ./prefetch-models.sh). No-op if
# they already exist, regardless of current ownership.
mkdir -p data/models data/hf_cache data/projects data/patches

if [ $# -eq 0 ]; then
    # Best-effort: fetch any missing models on the host first (see header).
    ./prefetch-models.sh --sdxl \
        || echo "⚠ Model prefetch had failures (see above) — continuing anyway, the container will retry in-container."
    exec docker compose -f docker-compose.gpu.yml up -d --build
else
    exec docker compose -f docker-compose.gpu.yml "$@"
fi
