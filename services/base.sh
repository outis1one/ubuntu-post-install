#!/bin/bash
# services/base.sh — essential CLI packages, Docker, SSH hardening, and NetBird.
# Part of the modular post-install system (sourced by setup.sh).

register_service base base "Essential CLI packages (net-tools, git, htop, btop, glow, …)"

install_base() {
    log_info "Installing essential packages..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install core apt packages"
        echo "[DRY-RUN] Would install glow from Charm repo"
        echo "[DRY-RUN] Would install Docker CE + Compose plugin"
        echo "[DRY-RUN] Would install/configure openssh-server"
        echo "[DRY-RUN] Would offer SSH key import from GitHub/Launchpad"
        echo "[DRY-RUN] Would offer to disable SSH password auth"
        echo "[DRY-RUN] Would offer NetBird install with --allow-server-ssh"
        return 0
    fi

    run_cmd apt-get update -y

    # Core utilities present on every install.
    run_cmd apt-get install -y \
        net-tools ncdu git curl wget htop btop tree zip unzip \
        ca-certificates gnupg jq rsync ssh-import-id \
        || log_warning "Some essential packages failed to install"

    # glow — terminal markdown reader (charmbracelet). Not in Ubuntu repos,
    # so add Charm's apt repository first.
    install_glow

    # ── Docker ───────────────────────────────────────────────────────────────
    require_docker || log_warning "Docker install failed — will retry after base setup"

    # ── OpenSSH server ───────────────────────────────────────────────────────
    _base_setup_ssh

    # ── NetBird ──────────────────────────────────────────────────────────────
    _base_setup_netbird
}

_base_setup_ssh() {
    log_info "Configuring SSH server..."

    if ! dpkg -l openssh-server &>/dev/null; then
        run_cmd apt-get install -y openssh-server
    fi
    run_cmd systemctl enable --now ssh

    # Import SSH public keys from GitHub and/or Launchpad.
    local GH_USER="" LP_USER="" _keys_imported=false

    prompt_text "GitHub username to import SSH keys from (blank to skip):" "" GH_USER
    if [ -n "$GH_USER" ]; then
        if ssh-import-id "gh:$GH_USER"; then
            log_success "Imported SSH keys from GitHub: $GH_USER"
            _keys_imported=true
        else
            log_warning "Could not import keys from GitHub: $GH_USER"
        fi
    fi

    prompt_text "Launchpad username to import SSH keys from (blank to skip):" "" LP_USER
    if [ -n "$LP_USER" ]; then
        if ssh-import-id "lp:$LP_USER"; then
            log_success "Imported SSH keys from Launchpad: $LP_USER"
            _keys_imported=true
        else
            log_warning "Could not import keys from Launchpad: $LP_USER"
        fi
    fi

    # Only offer to disable password auth if at least one key was imported.
    if [ "$_keys_imported" = true ]; then
        local DISABLE_PW=""
        prompt_yn "Disable SSH password authentication (key login only)? (y/n):" "y" DISABLE_PW
        if [[ "$DISABLE_PW" =~ ^[Yy]$ ]]; then
            sed -i \
                -e 's/^#*\s*PasswordAuthentication\s.*/PasswordAuthentication no/' \
                -e 's/^#*\s*KbdInteractiveAuthentication\s.*/KbdInteractiveAuthentication no/' \
                /etc/ssh/sshd_config
            # Ubuntu 22.04+ may also have a drop-in that re-enables password auth.
            local _dropin="/etc/ssh/sshd_config.d/50-cloud-init.conf"
            if [ -f "$_dropin" ]; then
                sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' "$_dropin"
            fi
            systemctl restart ssh
            log_success "SSH password authentication disabled — key login only"
        fi
    fi
}

_base_setup_netbird() {
    local INSTALL_NB=""
    prompt_yn "Install NetBird overlay network? (y/n):" "n" INSTALL_NB
    [[ "$INSTALL_NB" =~ ^[Yy]$ ]] || return 0

    log_info "Installing NetBird..."
    if curl -fsSL https://pkgs.netbird.io/install.sh | sh; then
        log_success "NetBird installed"
    else
        log_warning "NetBird install failed — see https://netbird.io"
        return 1
    fi

    local NB_SSH=""
    prompt_yn "Enable NetBird's built-in SSH server (--allow-server-ssh)? (y/n):" "y" NB_SSH

    local NB_KEY=""
    prompt_text "NetBird setup key (blank to run 'netbird up' manually later):" "" NB_KEY

    local _up_args=""
    [[ "$NB_SSH" =~ ^[Yy]$ ]] && _up_args="--allow-server-ssh"

    if [ -n "$NB_KEY" ]; then
        if netbird up --setup-key "$NB_KEY" $_up_args; then
            log_success "NetBird connected${NB_SSH:+ with SSH server enabled}"
        else
            log_warning "NetBird up failed — run manually: netbird up --setup-key <KEY>${NB_SSH:+ --allow-server-ssh}"
        fi
    else
        log_info "Run when ready: netbird up${_up_args:+ $_up_args}"
    fi
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
