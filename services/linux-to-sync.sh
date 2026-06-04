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

    # ── Re-run: already cloned → offer pull ──────────────────────────────────
    if [ -d "$SYNC_DIR/.git" ]; then
        log_info "linux-to-sync already cloned at $SYNC_DIR"
        local DO_PULL=""
        prompt_yn "Pull latest changes? (y/n) [y]:" "y" DO_PULL
        if [[ ${DO_PULL:-y} =~ ^[Yy]$ ]]; then
            if sudo -u "$ACTUAL_USER" git -C "$SYNC_DIR" pull; then
                log_success "linux-to-sync updated"
            else
                log_warning "git pull failed — check connectivity and credentials"
            fi
        fi
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

        log_info "Cloning via HTTPS + PAT..."
        if sudo -u "$ACTUAL_USER" \
               git clone "https://$GH_TOKEN@github.com/outis1one/linux-to-sync.git" "$SYNC_DIR"; then
            # Remove token from remote URL so it isn't stored in plain text
            sudo -u "$ACTUAL_USER" git -C "$SYNC_DIR" remote set-url origin \
                "https://github.com/outis1one/linux-to-sync.git"
            log_success "linux-to-sync cloned to $SYNC_DIR"
            echo "  Token stripped from remote URL. For future pulls use:"
            echo "    git -C $SYNC_DIR pull   (will prompt for credentials)"
            echo "  Or set up a credential helper:"
            echo "    git config --global credential.helper store"
        else
            log_error "Clone failed — check your PAT and network, then retry."
            return 1
        fi
    else
        # SSH auth — git must run as the actual user to use their SSH keys.
        echo ""
        echo "  Checking for SSH key in $ACTUAL_HOME/.ssh/ ..."
        local SSH_KEY_FOUND=false
        for _k in id_ed25519 id_rsa id_ecdsa; do
            if [ -f "$ACTUAL_HOME/.ssh/$_k" ]; then
                log_info "  Found: $ACTUAL_HOME/.ssh/$_k"
                SSH_KEY_FOUND=true
                break
            fi
        done
        if [ "$SSH_KEY_FOUND" = false ]; then
            log_warning "No SSH key found in $ACTUAL_HOME/.ssh/"
            echo ""
            echo "  To generate one:"
            echo "    ssh-keygen -t ed25519 -C 'your@email.com'"
            echo "    cat $ACTUAL_HOME/.ssh/id_ed25519.pub"
            echo "    → Add the public key at: github.com/settings/keys"
            echo ""
            local CONTINUE=""
            prompt_yn "Continue anyway (will fail if no key on GitHub)? (y/n) [n]:" "n" CONTINUE
            [[ ${CONTINUE:-n} =~ ^[Yy]$ ]] || return 0
        fi

        log_info "Cloning via SSH (running as $ACTUAL_USER)..."
        if sudo -u "$ACTUAL_USER" \
               git clone git@github.com:outis1one/linux-to-sync.git "$SYNC_DIR"; then
            log_success "linux-to-sync cloned to $SYNC_DIR"
        else
            log_error "SSH clone failed."
            echo ""
            echo "  Common causes:"
            echo "   • SSH key not added to GitHub — go to github.com/settings/keys"
            echo "   • Key not accepted by ssh-agent — try: ssh-add $ACTUAL_HOME/.ssh/id_ed25519"
            echo "   • Test with: sudo -u $ACTUAL_USER ssh -T git@github.com"
            echo "  Then retry: sudo ./setup.sh linux-to-sync"
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
