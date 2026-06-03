#!/bin/bash
# services/linux-to-sync.sh — Clone the private linux-to-sync repository.
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- LINUX-TO-SYNC ----).
# Clones outis1one/linux-to-sync to ~/linux-to-sync via SSH or HTTPS+PAT.
# No server/container — this is a personal sync/config repo.

register_service linux-to-sync extras "Personal sync & config scripts (linux-to-sync private repo)"

install_linux-to-sync() {
    local SYNC_DIR="$ACTUAL_HOME/linux-to-sync"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] linux-to-sync would:"
        echo "  - Clone outis1one/linux-to-sync to $SYNC_DIR"
        echo "  - Authenticate via SSH key or GitHub Personal Access Token"
        return 0
    fi

    echo ""
    echo "  Requires access to github.com/outis1one/linux-to-sync"
    echo "  Authenticate with ONE of:"
    echo "    [1] SSH key already added to your GitHub account"
    echo "    [2] GitHub Personal Access Token (PAT)"
    echo ""

    local AUTH_METHOD=""
    prompt_text "Authentication method [1=SSH, 2=PAT, default: 1]:" "1" AUTH_METHOD
    AUTH_METHOD="${AUTH_METHOD:-1}"

    if [ "$AUTH_METHOD" = "2" ]; then
        echo ""
        echo "  Create a PAT at: https://github.com/settings/tokens/new"
        echo "  Select the 'repo' scope for full repository access."
        echo ""
        local GH_TOKEN=""
        prompt_text "GitHub Personal Access Token:" "" GH_TOKEN
        if [ -z "$GH_TOKEN" ]; then
            log_warning "No token provided — skipping."
            return 0
        fi

        if git clone "https://$GH_TOKEN@github.com/outis1one/linux-to-sync.git" "$SYNC_DIR" 2>/dev/null; then
            cd "$SYNC_DIR" || return 1
            # Remove token from remote URL so it isn't stored in plain text
            git remote set-url origin "https://github.com/outis1one/linux-to-sync.git"
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SYNC_DIR"
            log_success "linux-to-sync cloned to $SYNC_DIR"
            echo "  Note: re-enter your token for future push/pull, or:"
            echo "        git config credential.helper store"
        else
            log_error "Clone failed — check your token and try again."
            return 1
        fi
    else
        echo ""
        echo "  Attempting SSH clone (your SSH key must be added to GitHub)..."
        if git clone git@github.com:outis1one/linux-to-sync.git "$SYNC_DIR" 2>/dev/null; then
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SYNC_DIR"
            log_success "linux-to-sync cloned to $SYNC_DIR"
        else
            log_error "SSH clone failed."
            echo ""
            echo "  To add your SSH key to GitHub:"
            echo "    1. cat ~/.ssh/id_rsa.pub  (or id_ed25519.pub)"
            echo "    2. github.com/settings/keys → New SSH key → paste"
            echo "  Then retry:  sudo ./setup.sh linux-to-sync"
            return 1
        fi
    fi

    write_readme "$SYNC_DIR" << MD
# linux-to-sync

Private personal sync and config repository cloned from outis1one/linux-to-sync.

## Update
\`\`\`bash
cd $SYNC_DIR
git pull
\`\`\`
MD

    echo ""
    echo "  Cloned to: $SYNC_DIR"
    echo ""
}
