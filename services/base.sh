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
        echo "[DRY-RUN] Would detect an NVIDIA GPU and offer to install the driver"
        echo "    + NVIDIA Container Toolkit (for GPU-accelerated Docker services)"
        echo "[DRY-RUN] Would install/configure openssh-server"
        echo "[DRY-RUN] Would offer SSH key import from GitHub/Launchpad"
        echo "[DRY-RUN] Would offer to disable SSH password auth"
        echo "[DRY-RUN] Would offer NetBird install with --allow-server-ssh"
        echo "[DRY-RUN] Would offer Caddy reverse proxy install (full repo only)"
        echo "[DRY-RUN] Would offer CrowdSec intrusion prevention install (full repo only)"
        echo "[DRY-RUN] Would offer to add SSH Host aliases to ~/.ssh/config"
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

    # ── NVIDIA GPU (driver + container toolkit) ─────────────────────────────
    _base_setup_nvidia_gpu

    # ── OpenSSH server ───────────────────────────────────────────────────────
    _base_setup_ssh

    # ── NetBird ──────────────────────────────────────────────────────────────
    _base_setup_netbird

    # ── Caddy + CrowdSec ──────────────────────────────────────────────────────
    # Not this script's own install — just an early, recommended nudge toward
    # two services most other things in this repo end up wanting (a reverse
    # proxy, and something watching for brute-force/scan traffic). Both stay
    # fully optional and available later from the whiptail menu either way.
    local _BASE_PWD="$PWD"
    _base_setup_caddy
    cd "$_BASE_PWD" 2>/dev/null || true
    _base_setup_crowdsec
    cd "$_BASE_PWD" 2>/dev/null || true

    # ── SSH Host aliases ─────────────────────────────────────────────────────
    _base_setup_ssh_aliases
}

_base_setup_nvidia_gpu() {
    # Only bother if an NVIDIA GPU is physically present — silent no-op otherwise.
    command -v lspci >/dev/null 2>&1 || return 0
    lspci | grep -iE '(VGA compatible controller|3D controller)' | grep -qi nvidia || return 0

    log_info "NVIDIA GPU detected."

    local _reboot_needed=false
    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
        log_success "NVIDIA driver already active ($(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1))"
    else
        local INSTALL_DRIVER=""
        prompt_yn "Install the recommended NVIDIA driver? Needed for GPU-accelerated Docker services (y/n):" "y" INSTALL_DRIVER
        if [[ "$INSTALL_DRIVER" =~ ^[Yy]$ ]]; then
            command -v ubuntu-drivers >/dev/null 2>&1 || run_cmd apt-get install -y ubuntu-drivers-common
            log_info "Detected hardware and recommended driver:"
            ubuntu-drivers devices || true
            if run_cmd ubuntu-drivers autoinstall; then
                log_warning "NVIDIA driver installed — a REBOOT is required before the GPU is usable."
                _reboot_needed=true
            else
                log_warning "Driver autoinstall failed — install manually: sudo ubuntu-drivers autoinstall"
                return 1
            fi
        else
            log_info "Skipping — GPU-accelerated services (ai-gpu, wolf, etc.) need a driver first."
            return 0
        fi
    fi

    # NVIDIA Container Toolkit — lets Docker containers request the GPU
    # (--gpus / device requests). Only useful once Docker is present.
    if command -v docker >/dev/null 2>&1 && ! command -v nvidia-container-cli >/dev/null 2>&1; then
        local INSTALL_TOOLKIT=""
        prompt_yn "Install NVIDIA Container Toolkit so Docker services can use the GPU? (y/n):" "y" INSTALL_TOOLKIT
        if [[ "$INSTALL_TOOLKIT" =~ ^[Yy]$ ]]; then
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
            curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
                | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
                | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
            run_cmd apt-get update -y
            if run_cmd apt-get install -y nvidia-container-toolkit; then
                run_cmd nvidia-ctk runtime configure --runtime=docker
                run_cmd systemctl restart docker
                log_success "NVIDIA Container Toolkit installed and Docker configured for GPU access."
            else
                log_warning "NVIDIA Container Toolkit install failed — GPU-accelerated Docker services will need it manually."
            fi
        fi
    fi

    if [ "$_reboot_needed" = true ]; then
        local REBOOT_NOW=""
        prompt_yn "Reboot now to finish activating the NVIDIA driver? (y/n):" "n" REBOOT_NOW
        if [[ "$REBOOT_NOW" =~ ^[Yy]$ ]]; then
            log_info "Rebooting..."
            reboot
        else
            log_warning "Remember to reboot before using GPU-accelerated services."
        fi
    fi
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

_base_setup_caddy() {
    if [[ -d "$DOCKER_DIR/caddy" ]]; then
        log_info "Caddy already installed."
        return 0
    fi
    # Only available when the full repo is sourced (setup.sh loads every
    # services/*.sh up front) — a standalone copy of base.sh doesn't have
    # install_caddy, so skip silently rather than error.
    declare -F install_caddy &>/dev/null || return 0

    local INSTALL_CADDY=""
    prompt_yn "Install Caddy reverse proxy? Recommended — gives every other service here a trusted HTTPS front door. (y/n):" "y" INSTALL_CADDY
    [[ "$INSTALL_CADDY" =~ ^[Yy]$ ]] || return 0
    install_caddy
}

_base_setup_crowdsec() {
    if command -v cscli &>/dev/null; then
        log_info "CrowdSec already installed."
        return 0
    fi
    declare -F install_crowdsec &>/dev/null || return 0

    local INSTALL_CS=""
    prompt_yn "Install CrowdSec intrusion prevention? Recommended — bans brute-force/scan traffic against SSH and anything Caddy fronts. (y/n):" "y" INSTALL_CS
    [[ "$INSTALL_CS" =~ ^[Yy]$ ]] || return 0
    install_crowdsec
}

_base_setup_ssh_aliases() {
    local ADD_ALIAS=""
    prompt_yn "Add an SSH Host alias now ('ssh myserver' instead of 'ssh user@1.2.3.4')? (y/n):" "n" ADD_ALIAS
    [[ "$ADD_ALIAS" =~ ^[Yy]$ ]] || return 0

    while true; do
        local ALIAS_NAME="" ALIAS_HOST="" ALIAS_USER="" ALIAS_PORT=""
        prompt_text "  Alias name (e.g. myserver):" "" ALIAS_NAME
        if [ -z "$ALIAS_NAME" ]; then
            log_warning "Alias name required — skipping."
        else
            prompt_text "  Hostname or IP to connect to (e.g. a NetBird peer IP):" "" ALIAS_HOST
            prompt_text "  Remote username:" "$ACTUAL_USER" ALIAS_USER
            prompt_text "  Port [22]:" "22" ALIAS_PORT
            add_ssh_host_alias "$ALIAS_NAME" "$ALIAS_HOST" "$ALIAS_USER" "$ALIAS_PORT"
        fi
        local ADD_ANOTHER=""
        prompt_yn "  Add another alias? (y/n):" "n" ADD_ANOTHER
        [[ "$ADD_ANOTHER" =~ ^[Yy]$ ]] || break
    done
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
