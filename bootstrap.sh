#!/bin/bash
# bootstrap.sh — get and run ubuntu-post-install on a fresh system.
#
# THREE ways to use this:
#
#  1. Public repo — paste on any new box (internet required):
#       curl -fsSL https://raw.githubusercontent.com/outis1one/ubuntu-post-install/main/bootstrap.sh | sudo bash
#
#  2. Private repo — copy just this file, supply a fine-grained read-only PAT:
#       sudo bash bootstrap.sh --pat ghp_xxxxxxxxxxxxxxxxxxxx
#
#  3. USB / offline — copy the WHOLE REPO to a thumb drive, run from there
#     (no auth, no internet needed for the scripts themselves):
#       sudo bash /media/user/DRIVE/ubuntu-post-install/bootstrap.sh
#
# Option 3 is the recommended approach for private repos: clone once on a
# connected machine, put the directory on a USB drive, done.
set -euo pipefail

# Self-elevate: if double-clicked or run without sudo, ask for password.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

REPO_URL="https://github.com/outis1one/ubuntu-post-install.git"

# Resolve actual user home when running under sudo
ACTUAL_HOME="${HOME:-/root}"
if [ -n "${SUDO_USER:-}" ]; then
    ACTUAL_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
fi
DEST="$ACTUAL_HOME/ubuntu-post-install"

# Parse --pat flag
PAT=""
for arg in "$@"; do
    case "$arg" in
        --pat) shift; PAT="${1:-}" ;;
        --pat=*) PAT="${arg#--pat=}" ;;
    esac
done

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ubuntu-post-install  ·  bootstrap                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Option 3: already running from inside the repo ───────────────────────────
# If setup.sh is sitting next to this script, we have everything we need.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo "")"
if [ -f "${SCRIPT_DIR}/setup.sh" ]; then
    echo "  Running from local copy at $SCRIPT_DIR"
    echo "  (No git or internet needed)"
    echo ""
    # Copy to home so the install persists after the USB is removed
    if [ "$SCRIPT_DIR" != "$DEST" ]; then
        echo "  Copying to $DEST for future use..."
        cp -r "$SCRIPT_DIR" "$DEST" 2>/dev/null \
            && chown -R "${SUDO_USER:-$(id -un)}:" "$DEST" 2>/dev/null || true
        echo ""
    fi
    exec bash "${SCRIPT_DIR}/setup.sh" </dev/tty >/dev/tty 2>/dev/tty
fi

# ── Options 1 & 2: clone from GitHub ─────────────────────────────────────────
if ! command -v git >/dev/null 2>&1; then
    echo "  Installing git..."
    apt-get update -qq && apt-get install -y git
fi

# Build clone URL (with PAT if supplied)
CLONE_URL="$REPO_URL"
if [ -n "$PAT" ]; then
    CLONE_URL="https://${PAT}@github.com/${REPO_URL#https://github.com/}"
fi

if [ -d "$DEST/.git" ]; then
    echo "  Repo already exists at $DEST — pulling latest..."
    git -C "$DEST" pull --ff-only || echo "  (pull failed — continuing with existing version)"
else
    echo "  Cloning to $DEST ..."
    git clone "$CLONE_URL" "$DEST"
    # Remove PAT from stored remote URL so it isn't saved in plain text
    if [ -n "$PAT" ]; then
        git -C "$DEST" remote set-url origin "$REPO_URL"
    fi
fi

echo ""
echo "  Launching setup..."
echo ""

exec bash "$DEST/setup.sh" </dev/tty
