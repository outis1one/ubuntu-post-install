#!/bin/bash
# bootstrap.sh — get and run ubuntu-post-install on a fresh system.
#
# One command to paste into a new Ubuntu box:
#   curl -fsSL https://raw.githubusercontent.com/outis1one/ubuntu-post-install/main/bootstrap.sh | sudo bash
#
# What it does:
#   1. Installs git if missing (the only hard dependency)
#   2. Clones (or updates) the repo to ~/ubuntu-post-install
#   3. Launches the interactive setup wizard
set -euo pipefail

REPO_URL="https://github.com/outis1one/ubuntu-post-install.git"
DEST="${HOME:-/root}/ubuntu-post-install"

# Resolve actual user home when running under sudo
if [ -n "${SUDO_USER:-}" ]; then
    ACTUAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    DEST="$ACTUAL_HOME/ubuntu-post-install"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ubuntu-post-install  ·  bootstrap                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# 1) Ensure git is available
if ! command -v git >/dev/null 2>&1; then
    echo "Installing git..."
    apt-get update -qq && apt-get install -y git
fi

# 2) Clone or update
if [ -d "$DEST/.git" ]; then
    echo "Repo already exists at $DEST — pulling latest..."
    git -C "$DEST" pull --ff-only || echo "  (pull failed — continuing with existing version)"
else
    echo "Cloning to $DEST ..."
    git clone "$REPO_URL" "$DEST"
fi

echo ""
echo "Launching setup..."
echo ""

exec bash "$DEST/setup.sh"
