#!/bin/bash
# services/base.sh — essential CLI packages installed on every box.
# Part of the modular post-install system (sourced by setup.sh).

register_service base base "Essential CLI packages (net-tools, git, htop, btop, glow, …)"

install_base() {
    log_info "Installing essential packages..."
    run_cmd apt-get update -y

    # Core utilities present on every install.
    run_cmd apt-get install -y \
        net-tools ncdu git curl wget htop btop tree zip unzip \
        ca-certificates gnupg jq rsync || log_warning "Some essential packages failed to install"

    # glow — terminal markdown reader (charmbracelet). Not in Ubuntu repos,
    # so add Charm's apt repository first.
    install_glow
}

# glow is also exposed as its own module so it can be (re)installed on its own.
install_glow() {
    if command -v glow >/dev/null 2>&1; then
        log_success "glow already installed ($(glow --version 2>/dev/null | head -1))"
        return 0
    fi
    log_info "Installing glow (terminal markdown reader) from the Charm apt repo..."
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would add repo.charm.sh apt repo and install glow"
        return 0
    fi
    sudo mkdir -p /etc/apt/keyrings
    if curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg; then
        echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
            | sudo tee /etc/apt/sources.list.d/charm.list >/dev/null
        if sudo apt-get update -y && sudo apt-get install -y glow; then
            log_success "glow installed ($(glow --version 2>/dev/null | head -1))"
        else
            log_warning "glow install failed — see https://github.com/charmbracelet/glow"
        fi
    else
        log_warning "Could not fetch Charm signing key — skipping glow"
    fi
}

# Register glow as a standalone service too (./setup.sh glow).
register_service glow base "Terminal markdown reader (charmbracelet/glow)"
