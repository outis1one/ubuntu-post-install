#!/bin/bash
# Install all local-ai systemd user units and enable timers
set -e

UNIT_DIR="$HOME/.config/systemd/user"
SRC="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$UNIT_DIR"

for unit in "$SRC"/*.service "$SRC"/*.timer; do
    name=$(basename "$unit")
    ln -sf "$unit" "$UNIT_DIR/$name"
    echo "Linked $name"
done

systemctl --user daemon-reload

for timer in "$SRC"/*.timer; do
    name=$(basename "$timer")
    systemctl --user enable --now "$name"
    echo "Enabled $name"
done

echo ""
systemctl --user list-timers kiwix-update.timer ollama-update.timer
echo ""
echo "Run manually:"
echo "  systemctl --user start kiwix-update.service"
echo "  systemctl --user start ollama-update.service"
echo ""
echo "Logs:"
echo "  journalctl --user -u kiwix-update.service -f"
echo "  journalctl --user -u ollama-update.service -f"
