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
        echo "[DRY-RUN] Would add a swapfile if RAM <= 4096MB and none exists"
        echo "[DRY-RUN] Would install/configure openssh-server"
        echo "[DRY-RUN] Would offer SSH key import from GitHub/Launchpad"
        echo "[DRY-RUN] Would offer to disable SSH password auth"
        echo "[DRY-RUN] Would offer NetBird install with --allow-server-ssh"
        echo "[DRY-RUN] Would offer to mount SMB data from a NetBird-connected home box (if NetBird is present)"
        echo "[DRY-RUN] Would offer Caddy reverse proxy install (full repo only)"
        echo "[DRY-RUN] Would offer CrowdSec intrusion prevention install (full repo only)"
        echo "[DRY-RUN] Would offer to add SSH Host aliases to ~/.ssh/config"
        echo "[DRY-RUN] Would add setup.sh tab completion to ~/.bashrc (if not already there)"
        echo "[DRY-RUN] Would offer daily pruning of old *.backup.* config files (systemd timer)"
        return 0
    fi

    run_cmd apt-get update -y

    # Core utilities present on every install. cifs-utils/keyutils here (not
    # lazily installed on first use, the way tools/mount-network-drive.sh and
    # vpn-data-mount.sh's own local-mount step would otherwise do it) so SMB
    # mounts work immediately whenever they're set up later, same reasoning
    # as Docker/Compose being unconditional here instead of on-demand.
    # keyutils explicitly, not left to cifs-utils' Recommends — some minimal
    # cloud VPS images disable install-recommends, and without keyutils'
    # /etc/request-key.d handlers every mount.cifs call (guest or fully
    # credentialed) fails with "mount error(79): Can not access a needed
    # shared library" regardless of the password being correct.
    run_cmd apt-get install -y \
        net-tools ncdu git curl wget htop btop tree zip unzip \
        ca-certificates gnupg jq rsync ssh-import-id cifs-utils keyutils \
        || log_warning "Some essential packages failed to install"

    # glow — terminal markdown reader (charmbracelet). Not in Ubuntu repos,
    # so add Charm's apt repository first.
    install_glow

    # ── Docker ───────────────────────────────────────────────────────────────
    require_docker || log_warning "Docker install failed — will retry after base setup"

    # ── Swapfile — default for every install, not just Asterisk droplets ────
    ensure_swapfile

    # ── NVIDIA GPU (driver + container toolkit) ─────────────────────────────
    _base_setup_nvidia_gpu

    # ── OpenSSH server ───────────────────────────────────────────────────────
    _base_setup_ssh

    # ── NetBird ──────────────────────────────────────────────────────────────
    _base_setup_netbird

    # ── VPN-connected data mount ────────────────────────────────────────────
    # Only offered if NetBird is actually present (installed just now, or
    # already there from a prior run) — chained here rather than folded into
    # _base_setup_netbird itself since it's independently repeatable (see
    # services/vpn-data-mount.sh's own header) and users may want to run it
    # again later for another home box without re-touching NetBird at all.
    _base_setup_vpn_mount

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

    # ── setup.sh tab completion ─────────────────────────────────────────────
    _base_setup_tab_completion

    # ── Old config-backup pruning ────────────────────────────────────────────
    _base_setup_backup_pruning
}

# Wires tools/setup-completion.bash into ACTUAL_USER's shell automatically —
# no reason to make everyone find and run this by hand when base already
# touches ~/.bashrc for other things. Idempotent (checked by grep before
# appending), so reruns don't pile up duplicate source lines.
_base_setup_tab_completion() {
    local comp_script="$HERE/tools/setup-completion.bash"
    [ -f "$comp_script" ] || return 0

    local bashrc="$ACTUAL_HOME/.bashrc"
    [ -f "$bashrc" ] || return 0
    grep -qF "$comp_script" "$bashrc" 2>/dev/null && return 0

    # No DRY_RUN check here — install_base()'s own top-level one (above)
    # already returns before this helper is ever called in that mode,
    # unlike install_glow()'s check further down, which is independently
    # invokable (sudo ./setup.sh glow --dry-run) and genuinely reachable.
    {
        echo ""
        echo "# ubuntu-post-install: setup.sh tab completion"
        echo "source $comp_script"
    } >> "$bashrc"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$bashrc" 2>/dev/null || true
    log_success "setup.sh tab completion added to $bashrc (takes effect in new shells, or: source $bashrc)"
}

# Every service in this repo backs up a live config before overwriting it
# (Caddyfile, /etc/fstab, ...) but none of them ever clean those up
# afterward — see tools/prune-old-backups.sh's own header for the full
# reasoning. Offers a daily systemd timer that prunes anything older than
# 30 days, always keeping at least the single newest backup per file
# regardless of age.
_base_setup_backup_pruning() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl list-unit-files prune-old-backups.timer --no-legend 2>/dev/null | grep -q . && return 0

    local prune_script="$HERE/tools/prune-old-backups.sh"
    [ -f "$prune_script" ] || return 0

    echo ""
    local ENABLE_PRUNE=""
    prompt_yn "Automatically prune old config backups (Caddyfile.backup.*, fstab.backup.*, etc — keeps 30 days, always keeps at least the newest one)? (y/n):" "y" ENABLE_PRUNE
    [[ "$ENABLE_PRUNE" =~ ^[Yy]$ ]] || return 0

    cat > /etc/systemd/system/prune-old-backups.service << UNIT
[Unit]
Description=Prune old *.backup.* config backups (Caddyfile, fstab, etc)

[Service]
Type=oneshot
ExecStart=/bin/bash ${prune_script} 30
UNIT
    cat > /etc/systemd/system/prune-old-backups.timer << 'UNIT'
[Unit]
Description=Daily backup pruning

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT
    systemctl daemon-reload
    if systemctl enable --now prune-old-backups.timer >/dev/null 2>&1; then
        log_success "Old config backups will be pruned daily, keeping 30 days (systemd timer: prune-old-backups)"
    else
        log_warning "Couldn't enable the pruning timer — run $prune_script manually to prune old backups."
    fi
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
    # The real logic lives in services/ssh-key-import.sh now — pulled out so
    # it can be re-run on its own later (another admin's key, a home box
    # that only needs this one step, ...) instead of only ever running once
    # as part of this whole required-setup flow. That file keeps its own
    # register_service call and stays independently selectable; this just
    # chains into it, same pattern services/asterisk.sh uses for
    # security-dashboard/pstn-trunk.
    if declare -F install_ssh-key-import >/dev/null 2>&1; then
        install_ssh-key-import
        return
    fi

    # Standalone `sudo bash base.sh` with no sibling services/*.sh sourced —
    # degrade to just getting the SSH server itself running, skip the
    # GitHub/Launchpad import convenience (needs the sibling file's fuller
    # standalone stubs, not worth duplicating here for this rare a path).
    log_info "Configuring SSH server..."
    if ! dpkg -l openssh-server &>/dev/null; then
        run_cmd apt-get install -y openssh-server
    fi
    run_cmd systemctl enable --now ssh
    log_info "Run services/ssh-key-import.sh (or the full repo's wizard) to import keys from GitHub/Launchpad."
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

_base_setup_vpn_mount() {
    command -v netbird >/dev/null 2>&1 || return 0
    # Only available when the full repo is sourced (setup.sh loads every
    # services/*.sh up front) — a standalone copy of base.sh doesn't have
    # install_vpn-data-mount, so skip silently rather than error.
    declare -F install_vpn-data-mount >/dev/null 2>&1 || return 0

    local SETUP_MOUNT=""
    prompt_yn "Mount data from a NetBird-connected home box now? (y/n):" "n" SETUP_MOUNT
    [[ "$SETUP_MOUNT" =~ ^[Yy]$ ]] || return 0
    install_vpn-data-mount
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
