#!/bin/bash
# cloud-init.sh — payload for a cloud provider's "install script" / user-data
# field (IONOS Cloud Server image deploy, DigitalOcean droplet user-data,
# Hetzner Cloud user-data, etc). The provider runs this as root, unattended,
# with no TTY, while the box is still being provisioned — before you have
# ever logged in.
#
# It deliberately does NOT run the interactive wizard itself (there's no
# terminal for whiptail to talk to yet). Instead it does two things:
#
#   1. Clones this repo to /root/ubuntu-post-install (pulls if already there).
#   2. Installs a one-shot /etc/profile.d hook that launches setup.sh —
#      the normal whiptail service menu — the first time you actually log
#      in over SSH, then deletes itself so it never fires again.
#
# End result: the provider boots Ubuntu 24.04, this runs in the background,
# and by the time you SSH in the checklist menu is sitting there waiting —
# the same experience as running bootstrap.sh by hand, just already started.
#
# Usage: paste this whole file's contents into the provider's install-script /
# user-data field (or use an "import from file" option if it has one).
# User-data fields run the content you give them directly — they don't fetch
# a URL — so paste the script itself, not a link to it.
#
# Assumes the provider logs you in as root (the default for IONOS Cloud
# Server, DigitalOcean droplets, and Hetzner Cloud server images). If you've
# provisioned a separate non-root sudo user instead, the hook won't reach
# you automatically — SSH in and run:
#   sudo bash /root/ubuntu-post-install/setup.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "cloud-init.sh must run as root — that's how provider install-script hooks already run it." >&2
    exit 1
fi

REPO_URL="https://github.com/outis1one/ubuntu-post-install.git"
DEST="/root/ubuntu-post-install"
MARKER="/root/.ubuntu-post-install-pending"
HOOK="/etc/profile.d/99-ubuntu-post-install.sh"
export DEBIAN_FRONTEND=noninteractive

command -v git >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y git; }

if [ -d "$DEST/.git" ]; then
    git -C "$DEST" pull --ff-only || true
else
    git clone "$REPO_URL" "$DEST"
fi

touch "$MARKER"

# POSIX sh, not bash — /etc/profile.d/*.sh gets sourced by whatever shell
# the login uses, not necessarily bash.
cat > "$HOOK" << 'EOF'
# Installed by cloud-init.sh — launches the ubuntu-post-install wizard on
# the first interactive login, then removes itself so it never fires again.
MARKER="/root/.ubuntu-post-install-pending"
HOOK="/etc/profile.d/99-ubuntu-post-install.sh"
DEST="/root/ubuntu-post-install"

if [ -f "$MARKER" ] && [ -t 0 ] && [ "$(id -u)" -eq 0 ] && [ -f "$DEST/setup.sh" ]; then
    rm -f "$MARKER" "$HOOK"
    echo ""
    echo "ubuntu-post-install: launching the setup wizard..."
    echo ""
    bash "$DEST/setup.sh"
fi
EOF
chmod 644 "$HOOK"

echo "cloud-init.sh: repo cloned to $DEST — the setup wizard will launch on first login."
