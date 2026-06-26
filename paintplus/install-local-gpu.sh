#!/usr/bin/env bash
# install-local-gpu.sh — one-time setup for local GPU inference.
#
# Run this once on a new machine. It:
#   1. Checks prerequisites (Docker, NVIDIA driver, curl)
#   2. Installs the NVIDIA container toolkit (so Docker can use the GPU)
#   3. Installs a systemd service that permanently fixes Docker container DNS
#      (allows containers to resolve hostnames — does not touch ufw)
#   4. Restarts Docker so both changes take effect
#   5. Verifies the GPU is accessible inside Docker
#
# After this, use ./bring-up-local-gpu.sh each time to start the app.

set -euo pipefail

# ── Must run as root (or via sudo) ───────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    exec sudo bash "$0" "$@"
fi

echo "=================================================="
echo "  EditmaskwithAI — Local GPU one-time setup"
echo "=================================================="
echo ""

# ── 0. Prerequisite checks ────────────────────────────────────────────────────
MISSING=0

# Docker
if ! command -v docker &>/dev/null; then
    echo "✗ Docker is not installed."
    echo "  Install it from https://docs.docker.com/engine/install/"
    echo "  Quick install (Ubuntu/Debian):"
    echo "    curl -fsSL https://get.docker.com | sh"
    echo "    sudo usermod -aG docker \$USER   # then log out and back in"
    echo ""
    MISSING=1
else
    echo "✓ Docker $(docker --version | awk '{print $3}' | tr -d ',')"
fi

# Docker daemon running
if command -v docker &>/dev/null && ! docker info &>/dev/null 2>&1; then
    echo "✗ Docker daemon is not running."
    echo "    sudo systemctl start docker"
    echo ""
    MISSING=1
fi

# NVIDIA driver
if ! command -v nvidia-smi &>/dev/null; then
    echo "✗ NVIDIA driver not found (nvidia-smi missing)."
    echo "  Install the driver first (≥ 525 required for CUDA 12.x):"
    echo "    Ubuntu: sudo apt install nvidia-driver-525"
    echo "    Or download from https://www.nvidia.com/drivers"
    echo "  After installing, reboot before re-running this script."
    echo ""
    MISSING=1
else
    DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    echo "✓ NVIDIA driver $DRIVER_VER"
fi

# curl (used to fetch toolkit repo config)
if ! command -v curl &>/dev/null; then
    echo "✗ curl is not installed."
    echo "    sudo apt install curl   # or: sudo dnf install curl"
    echo ""
    MISSING=1
else
    echo "✓ curl"
fi

if [ "$MISSING" -ne 0 ]; then
    echo "──────────────────────────────────────────────────"
    echo "  Fix the above issues then re-run this script."
    echo "=================================================="
    exit 1
fi

echo ""

# ── 0.5. Pre-create ./data with correct ownership ────────────────────────────
# Docker's daemon (always root) auto-creates bind-mount source directories on
# the first 'compose up' if they don't exist yet — leaving ./data root-owned
# and blocking the invoking user from later running ./prefetch-models.sh
# without a manual 'sudo chown'. Create it now, owned by the real (non-root)
# user, so that problem has no chance to happen on a fresh checkout.
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$REPO_DIR"/data/{models,hf_cache,projects,patches}
chown -R "${SUDO_UID:-$(id -u)}:${SUDO_GID:-$(id -g)}" "$REPO_DIR/data"
echo "✓ ./data prepared (writable without sudo)"
echo ""

# ── 1. NVIDIA container toolkit ──────────────────────────────────────────────
if command -v nvidia-ctk &>/dev/null; then
    echo "✓ nvidia-container-toolkit already installed — skipping"
else
    echo "Installing nvidia-container-toolkit..."
    . /etc/os-release
    case "$ID" in
        ubuntu|debian)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-ctk.gpg
            curl -fsSL "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-ctk.gpg] https://#g' \
                | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
            apt-get update -qq
            apt-get install -y nvidia-container-toolkit
            ;;
        rhel|fedora|rocky|centos|almalinux)
            dnf install -y nvidia-container-toolkit
            ;;
        *)
            echo "⚠ Unrecognised distro ($ID). Install nvidia-container-toolkit manually."
            echo "  See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
            ;;
    esac
fi

nvidia-ctk runtime configure --runtime=docker

# ── 2. Permanent Docker DNS fix via systemd ───────────────────────────────────
# Adds a rule to the DOCKER-USER iptables chain so containers can resolve
# hostnames. Runs after docker.service on every boot. Does NOT touch ufw.
echo ""
echo "Installing docker-dns-fix systemd service..."

cat > /etc/systemd/system/docker-dns-fix.service << 'EOF'
[Unit]
Description=Allow Docker containers to resolve DNS (DOCKER-USER iptables rule)
After=docker.service
Requires=docker.service
BindsTo=docker.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c \
  'iptables -C DOCKER-USER -p udp --dport 53 -j ACCEPT 2>/dev/null || \
   iptables -I DOCKER-USER -p udp --dport 53 -j ACCEPT'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable docker-dns-fix.service
echo "✓ docker-dns-fix.service installed and enabled"

# ── 3. Restart Docker ─────────────────────────────────────────────────────────
echo ""
echo "Restarting Docker..."
systemctl restart docker
sleep 2
echo "✓ Docker restarted"

# ── 4. Apply DNS rule now (don't wait for next boot) ─────────────────────────
systemctl start docker-dns-fix.service
echo "✓ DNS fix applied"

# ── 5. Verify GPU access ─────────────────────────────────────────────────────
echo ""
echo "Verifying GPU access inside Docker..."
if docker run --rm --gpus all nvidia/cuda:12.1.0-base-ubuntu22.04 nvidia-smi &>/dev/null; then
    echo "✓ GPU is accessible inside Docker"
else
    echo "⚠ GPU check failed. Is the NVIDIA driver installed on the host?"
    echo "  Check: nvidia-smi"
    echo "  Minimum driver version: 525"
fi

# ── 6. Prefetch all AI models (host-side, outside Docker) ───────────────────
# In-container DNS/network is unreliable on some hosts, so downloading on the
# host up front (including SDXL/inpaint, ~13GB) is the default now rather
# than a manual troubleshooting step. Best-effort: this script must finish
# (and leave the GPU/Docker setup done) even if prefetch fails outright.
# Run as the real invoking user, not root, so downloaded files (and any
# `pip install --user` side effects) end up owned by that user — this script
# itself is already running as root via the sudo re-exec above.
echo ""
echo "Prefetching AI models (this can take a while for SDXL, ~13GB)..."
if [ -n "${SUDO_USER:-}" ]; then
    sudo -u "$SUDO_USER" -H "$REPO_DIR/prefetch-models.sh" --sdxl \
        || echo "⚠ Model prefetch had failures (see above) — continuing anyway, the container will retry in-container."
else
    "$REPO_DIR/prefetch-models.sh" --sdxl \
        || echo "⚠ Model prefetch had failures (see above) — continuing anyway, the container will retry in-container."
fi

echo ""
echo "=================================================="
echo "  Setup complete."
echo "  Start the app with:  ./bring-up-local-gpu.sh"
echo ""
echo "  Models are prefetched automatically by this script and by"
echo "  bring-up-local-gpu.sh on every start. If any failed above (no"
echo "  network, etc.), re-run manually any time:"
echo "    ./prefetch-models.sh --sdxl"
echo "=================================================="
