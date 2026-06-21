#!/bin/bash
# services/wolf.sh — Cloud gaming via Moonlight (Games-on-Whales Wolf).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash wolf.sh
# (Docker must already be installed when run standalone)
#
# Self-hosted Moonlight streaming server. One Wolf container spins up app
# containers (ES-DE/RetroArch, Steam, Lutris, Firefox, full desktop) on demand,
# with virtual displays and virtual gamepads — no monitor, no dummy plug.
# Stream to any Moonlight client (TV, phone, PC, Fire TV stick, etc.).
#
# Ported from setup-wolf.sh. The dispatcher runs as root (require_root), so the
# original's refuse-root check and sudo prefixes are dropped. The wolf-pair
# helper service is dropped (it depended on repo files we don't ship); the
# `./manage.sh pin` command replaces it.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() {
            command -v docker &>/dev/null || {
                log_error "Docker not found. Install it first:"
                log_error "  curl -fsSL https://get.docker.com | sudo sh"
                return 1
            }
            docker compose version &>/dev/null || {
                log_error "Docker Compose plugin missing:"
                log_error "  sudo apt-get install -y docker-compose-plugin"
                return 1
            }
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK
)"

            if [[ "$_mode" == "local" ]]; then
                if [[ -f "$_caddyfile" ]]; then
                    local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                    cp "$_caddyfile" "$_bk"
                    log_info "Backed up Caddyfile to $(basename "$_bk")"
                else
                    touch "$_caddyfile"
                fi
                if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                    log_warning "$_domain already in Caddyfile"
                    local _ow=""
                    read -r -p "  Overwrite? [y/N]: " _ow
                    [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                    sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
                fi
                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
        }

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service wolf gaming "Cloud gaming via Moonlight (Games-on-Whales Wolf)" 47989

install_wolf() {
    require_docker || return 1

    local WOLF_DIR="$DOCKER_DIR/wolf"

    # Moonlight / Wolf default ports
    local WOLF_PORTS_TCP=(47984 47989 48010)
    local WOLF_PORTS_UDP=(47999 48100 48200)

    cat << "EOF"
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║   WOLF CLOUD GAMING SETUP                            ║
║   Self-hosted Moonlight streaming (Games-on-Whales)  ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
    echo ""

    # ── Dry-run summary (do nothing that touches hardware/docker/apt) ─────────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Wolf install would:"
        echo "  - Check for an NVIDIA GPU with driver >= 530 and detect its render node"
        echo "  - Ensure nvidia-drm modeset=1 (modprobe.d + GRUB/systemd-boot), may need reboot"
        echo "  - Install the NVIDIA Container Toolkit if missing"
        echo "  - Set up uinput/uhid modules + virtual-input udev rules"
        echo "  - Build the NVIDIA driver volume (nvidia-driver-vol) + copy CUDA/NVENC libs"
        echo "  - Detect LAN / Tailscale IP for Wolf to advertise"
        echo "  - Write $WOLF_DIR/docker-compose.yml and $WOLF_DIR/manage.sh"
        echo "  - Open Moonlight UFW ports: TCP ${WOLF_PORTS_TCP[*]} / UDP ${WOLF_PORTS_UDP[*]}"
        echo "  - Start Wolf and inject Steam + EmulationStation app profiles"
        return 0
    fi

    # ── OS / Docker Compose sanity ────────────────────────────────────────────
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        log_success "OS: $PRETTY_NAME"
    fi
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose v2 not found. Install: apt-get install docker-compose-plugin"
        return 1
    fi
    log_success "Docker found (Compose: $(docker compose version --short))"

    # ── NVIDIA checks ─────────────────────────────────────────────────────────
    local HAS_NVIDIA=false DRIVER_VER GPU_NAME DRIVER_MAJOR
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        HAS_NVIDIA=true
        DRIVER_VER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n1)
        GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader | head -n1)
        log_success "NVIDIA GPU: $GPU_NAME (driver $DRIVER_VER)"

        # Wolf requires driver >= 530.30.02
        DRIVER_MAJOR=$(echo "$DRIVER_VER" | cut -d. -f1)
        if [ "$DRIVER_MAJOR" -lt 530 ] 2>/dev/null; then
            log_error "Wolf needs NVIDIA driver >= 530.30.02 (you have $DRIVER_VER)."
            log_error "Update: apt-get install nvidia-driver-535 && reboot"
            return 1
        fi
    else
        log_error "No working NVIDIA GPU detected (nvidia-smi failed)."
        log_error "Wolf needs a working NVIDIA driver for hardware encoding."
        log_error "Install one, reboot, and re-run this module."
        return 1
    fi

    # ── Detect the NVIDIA DRM render node ─────────────────────────────────────
    # Wolf reads WOLF_RENDER_NODE (default /dev/dri/renderD128) to detect the GPU
    # vendor, then only selects an encoder whose vendor matches. On systems with
    # both an Intel iGPU and an NVIDIA card, renderD128 is usually the Intel GPU,
    # so Wolf detects "Intel", picks VA-API, and never tries NVENC.
    #
    # 0x10de is NVIDIA's PCI vendor ID. To pick the exact card the driver manages
    # (unambiguous on multi-GPU hosts) we cross-check each candidate's PCI bus
    # address against the bus IDs nvidia-smi reports.
    local WOLF_RENDER_NODE="" NV_BUS_SHORT _rnode _dev _pci_short
    NV_BUS_SHORT=$(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null \
        | awk -F: '{print $(NF-1)":"$NF}' | tr 'A-F' 'a-f')
    for _rnode in /dev/dri/renderD*; do
        [ -e "$_rnode" ] || continue
        _dev="/sys/class/drm/$(basename "$_rnode")/device"
        [ "$(cat "$_dev/vendor" 2>/dev/null)" = "0x10de" ] || continue   # NVIDIA vendor
        _pci_short=$(basename "$(readlink -f "$_dev" 2>/dev/null)" | awk -F: '{print $(NF-1)":"$NF}')
        if [ -n "$NV_BUS_SHORT" ]; then
            if printf '%s\n' "$NV_BUS_SHORT" | grep -qix "$_pci_short"; then
                WOLF_RENDER_NODE="$_rnode"; break
            fi
        else
            WOLF_RENDER_NODE="$_rnode"; break
        fi
    done
    if [ -n "$WOLF_RENDER_NODE" ]; then
        log_success "NVIDIA render node detected: $WOLF_RENDER_NODE (Wolf will use it for NVENC)"
    else
        WOLF_RENDER_NODE="/dev/dri/renderD128"
        log_warning "Could not match an NVIDIA render node to nvidia-smi — defaulting to $WOLF_RENDER_NODE"
        log_warning "If Wolf logs 'Using h265 encoder: va', set WOLF_RENDER_NODE manually to your NVIDIA card."
        log_warning "List candidates with:  for n in /dev/dri/renderD*; do echo \$n \$(cat /sys/class/drm/\$(basename \$n)/device/vendor); done"
    fi

    # ── nvidia-drm modeset=1 (required for Wolf's virtual displays) ───────────
    # Primary method: modprobe.d (bootloader-agnostic). Also set it in GRUB and
    # systemd-boot cmdline as a backup. Check sysfs (older: Y/N, newer 5xx: 1/0)
    # and /proc/cmdline — if either confirms modeset=1 we are good.
    local MODESET
    MODESET=$(cat /sys/module/nvidia_drm/parameters/modeset 2>/dev/null | tr -d '[:space:]')
    if grep -q "nvidia-drm.modeset=1" /proc/cmdline 2>/dev/null; then
        MODESET="1"   # cmdline is authoritative — module may just not be loaded yet
    fi
    if [[ "$MODESET" != "Y" && "$MODESET" != "1" && "$MODESET" != "2" ]]; then
        echo ""
        log_warning "Kernel module nvidia-drm is NOT loaded with modeset=1."
        log_warning "Wolf needs this to create virtual displays."
        echo ""
        local ENABLE_MODESET="y"
        if [ "$UNATTENDED" = true ]; then
            log_warning "Unattended mode — enabling nvidia-drm modeset=1 (no auto-reboot)."
            ENABLE_MODESET="y"
        else
            read -p "Enable nvidia-drm modeset=1 now (requires reboot)? (y/n) [y]: " -n 1 -r; echo
            ENABLE_MODESET="${REPLY:-y}"
        fi
        if [[ "$ENABLE_MODESET" =~ ^[Yy]$ ]]; then

            # ── Method 1: modprobe.d (bootloader-agnostic, most reliable) ──
            local MODPROBE_CONF="/etc/modprobe.d/nvidia-drm-modeset.conf"
            if ! grep -qs "modeset=1" "$MODPROBE_CONF" 2>/dev/null; then
                echo "options nvidia-drm modeset=1" | tee "$MODPROBE_CONF" >/dev/null
                log_success "Written: $MODPROBE_CONF"
            fi
            # Rebuild initramfs so the option is baked in
            if command -v update-initramfs &>/dev/null; then
                log_info "Rebuilding initramfs (this takes ~30 s)..."
                update-initramfs -u -k all
            fi

            # ── Method 2: GRUB (if present) ──
            local GRUB_FILE="/etc/default/grub"
            if [ -f "$GRUB_FILE" ] && ! grep -q "nvidia-drm.modeset=1" "$GRUB_FILE"; then
                sed -i \
                    's/\(GRUB_CMDLINE_LINUX_DEFAULT="[^"]*\)"/\1 nvidia-drm.modeset=1"/' \
                    "$GRUB_FILE"
                if command -v update-grub &>/dev/null; then
                    update-grub 2>/dev/null
                    log_success "Added nvidia-drm.modeset=1 to GRUB"
                fi
            fi

            # ── Method 3: systemd-boot (Ubuntu 24.04+ EFI installs) ──
            local SBOOT_CONF
            SBOOT_CONF=$(find /boot/loader/entries/ -name "*.conf" 2>/dev/null | head -1)
            if [ -n "$SBOOT_CONF" ] && ! grep -q "nvidia-drm.modeset=1" "$SBOOT_CONF"; then
                sed -i 's/\(^options .*\)/\1 nvidia-drm.modeset=1/' "$SBOOT_CONF"
                log_success "Added nvidia-drm.modeset=1 to systemd-boot entry: $(basename "$SBOOT_CONF")"
            fi

            echo ""
            log_warning "A REBOOT is required. Re-run this module after rebooting."
            if [ "$UNATTENDED" = true ]; then
                log_warning "Unattended mode — skipping reboot. Reboot manually, then re-run: sudo ./setup.sh wolf"
                return 0
            fi
            read -p "Reboot now? (y/n) [y]: " -n 1 -r; echo
            if [[ ${REPLY:-y} =~ ^[Yy]$ ]]; then
                reboot
            fi
            return 0
        else
            log_warning "Continuing without modeset=1 — Wolf may fail to start virtual displays."
        fi
    else
        log_success "nvidia-drm modeset is active (sysfs reports: $MODESET)"
    fi

    # ── NVIDIA Container Toolkit (bootstraps the driver volume build) ─────────
    if ! command -v nvidia-container-cli &>/dev/null; then
        log_warning "nvidia-container-cli not found — installing NVIDIA Container Toolkit..."
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
            gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
        curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
            sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
            tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null
        apt-get update
        apt-get install -y nvidia-container-toolkit
        nvidia-ctk runtime configure --runtime=docker
        systemctl restart docker
        log_success "NVIDIA Container Toolkit installed"
    fi

    # ── Virtual input devices (gamepads) ──────────────────────────────────────
    log_info "Setting up virtual gamepad support..."

    # uinput / uhid kernel modules
    if [ ! -e /dev/uinput ]; then
        log_info "Loading uinput kernel module..."
        modprobe uinput || log_warning "Could not load uinput module"
    fi
    [ -e /dev/uhid ] || modprobe uhid 2>/dev/null || true

    # Make uinput load at boot
    if [ ! -f /etc/modules-load.d/uinput.conf ]; then
        echo "uinput" | tee /etc/modules-load.d/uinput.conf >/dev/null
    fi

    # udev rules so Wolf can access virtual input devices
    local UDEV_RULES="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"
    if [ ! -f "$UDEV_RULES" ]; then
        log_info "Installing Wolf virtual-input udev rules..."
        tee "$UDEV_RULES" >/dev/null << 'UDEV'
# Wolf virtual input devices
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"
KERNEL=="hidraw*",   ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV
        udevadm control --reload-rules && udevadm trigger
        log_success "udev rules installed"
    else
        log_info "Wolf udev rules already present"
    fi

    # ── Build the NVIDIA driver volume (GoW recommended 'manual' method) ──────
    # More stable than the container-toolkit method for Wolf. The volume holds
    # userspace driver files matching the host kernel driver, mounted into app
    # containers.
    log_info "Building NVIDIA driver volume for Wolf (matches host driver $DRIVER_VER)..."
    local NV_KVER VOL_HAS
    NV_KVER=$(cat /sys/module/nvidia/version 2>/dev/null || echo "$DRIVER_VER")

    if docker volume ls --format '{{.Name}}' | grep -q '^nvidia-driver-vol$'; then
        # Check if the volume matches the current driver; if not, rebuild
        VOL_HAS=$(docker run --rm -v nvidia-driver-vol:/usr/nvidia alpine \
            sh -c 'ls /usr/nvidia/lib 2>/dev/null | grep -o "libnvidia-glcore.so.[0-9.]*" | head -1' 2>/dev/null || echo "")
        if echo "$VOL_HAS" | grep -q "$NV_KVER"; then
            log_success "nvidia-driver-vol already matches driver $NV_KVER"
        else
            log_warning "Driver volume is stale — rebuilding for $NV_KVER"
            docker volume rm nvidia-driver-vol >/dev/null 2>&1 || true
        fi
    fi

    if ! docker volume ls --format '{{.Name}}' | grep -q '^nvidia-driver-vol$'; then
        log_info "Building gow/nvidia-driver:latest (driver $NV_KVER)..."
        curl -fsSL https://raw.githubusercontent.com/games-on-whales/gow/master/images/nvidia-driver/Dockerfile \
            | docker build -t gow/nvidia-driver:latest -f - --build-arg NV_VERSION="$NV_KVER" . \
            || { log_error "Failed to build the NVIDIA driver image."; return 1; }
        log_info "Populating nvidia-driver-vol..."
        docker create --rm --mount source=nvidia-driver-vol,destination=/usr/nvidia gow/nvidia-driver:latest sh >/dev/null
        log_success "nvidia-driver-vol created"
    fi

    # The GOW nvidia-driver image only ships OpenGL/Vulkan libs — not libcuda.so,
    # libnvcuvid.so, or libnvidia-encode.so, which GStreamer's nvcodec elements
    # need for NVENC. Copy them straight from the host driver into the volume:
    # host userspace libs always match the running kernel module, so there's no
    # version-skew risk; Wolf finds them via LD_LIBRARY_PATH=/usr/nvidia/lib.
    local _VOL_HAS_CUDA HOST_CUDA HOST_LIB_DIR
    _VOL_HAS_CUDA=$(docker run --rm -v nvidia-driver-vol:/usr/nvidia alpine \
        sh -c 'ls /usr/nvidia/lib/libcuda.so* 2>/dev/null | head -1' 2>/dev/null || echo "")
    if [ -z "$_VOL_HAS_CUDA" ]; then
        log_info "Copying CUDA/NVENC libs from host driver into nvidia-driver-vol..."
        HOST_CUDA=$(ldconfig -p 2>/dev/null | awk '/libcuda\.so\.1/ {print $NF; exit}')
        [ -z "$HOST_CUDA" ] && HOST_CUDA=$(find /usr/lib /usr/lib64 /usr/lib/x86_64-linux-gnu \
            -name 'libcuda.so.*' 2>/dev/null | head -1)
        if [ -z "$HOST_CUDA" ] || [ ! -e "$HOST_CUDA" ]; then
            log_warning "Could not find libcuda.so on the host — Wolf may fall back to VA-API."
            log_warning "Confirm the NVIDIA driver is fully installed (nvidia-smi works)."
        else
            HOST_LIB_DIR=$(dirname "$HOST_CUDA")
            log_info "Host NVIDIA libs: $HOST_LIB_DIR"
            if docker run --rm \
                -v nvidia-driver-vol:/usr/nvidia \
                -v "$HOST_LIB_DIR":/hostlib:ro \
                alpine sh -c '
                    mkdir -p /usr/nvidia/lib
                    ok=0
                    for base in libcuda libnvcuvid libnvidia-encode libnvidia-ptxjitcompiler; do
                        for f in /hostlib/${base}.so*; do
                            [ -e "$f" ] && cp -a "$f" /usr/nvidia/lib/ && ok=1
                        done
                    done
                    [ -e /usr/nvidia/lib/libcuda.so.1 ] && echo "have-cuda-symlink"
                    [ $ok -eq 1 ]
                ' 2>&1; then
                log_success "CUDA/NVENC libs copied — Wolf should now select the NVIDIA encoder"
            else
                log_warning "Failed to copy CUDA libs into the volume — Wolf may use VA-API."
            fi
        fi
    else
        log_success "nvidia-driver-vol already has CUDA libs"
    fi

    # ── Game storage location ─────────────────────────────────────────────────
    # ROMs, Steam library, and saves all live under GAME_STORAGE_DIR.
    #   $GAME_STORAGE_DIR/roms/    → ES-DE at /ROMs
    #   $GAME_STORAGE_DIR/steam/   → Steam at /home/retro/.steam
    #   $GAME_STORAGE_DIR/saves/   → RetroArch saves
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  GAME STORAGE LOCATION"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  ROMs, Steam library, and saves all live under one directory."
    echo "  Recommended: a large secondary drive so the OS SSD stays free."
    echo ""

    # ── Build a numbered candidate list ──────────────────────────────────────
    # Slots:  0 = home dir,  1..N = mounted non-system partitions,
    #         last = unmounted block devices (for formatting+mounting)
    local -a _CAND_PATH _CAND_LABEL _CAND_DEV _CAND_UUID
    local _ci=0

    # Option 0 — home directory
    local _home_free _home_dev _home_uuid
    _home_free=$(df -h "$ACTUAL_HOME" 2>/dev/null | awk 'NR==2{print $4}')
    _home_dev=$(df "$ACTUAL_HOME" 2>/dev/null | awk 'NR==2{print $1}')
    _home_uuid=$(blkid -s UUID -o value "$_home_dev" 2>/dev/null)
    _CAND_PATH[0]="$ACTUAL_HOME/games"
    _CAND_LABEL[0]="Home directory  ($ACTUAL_HOME, ${_home_free:-?} free)"
    _CAND_DEV[0]="$_home_dev"
    _CAND_UUID[0]="${_home_uuid:-n/a}"
    _ci=1

    # Mounted block devices — skip root, system paths, and home itself.
    # Enumerate with lsblk -P (key="value" pairs) so whole-disk mounts (e.g. an
    # nvme formatted directly with no partition table) and empty LABEL/UUID
    # fields are handled reliably — df round-trips miss some of these.
    while IFS= read -r _line; do
        local NAME="" MOUNTPOINT="" SIZE="" LABEL="" UUID=""
        eval "$_line"
        local _mnt="$MOUNTPOINT"
        [[ -z "$_mnt" ]] && continue
        [[ "$_mnt" == "/"        ]] && continue
        [[ "$_mnt" == /boot*     ]] && continue
        [[ "$_mnt" == /snap*     ]] && continue
        [[ "$_mnt" == /tmp*      ]] && continue
        [[ "$_mnt" == /run*      ]] && continue
        [[ "$_mnt" == /sys*      ]] && continue
        [[ "$_mnt" == /proc*     ]] && continue
        [[ "$_mnt" == /dev*      ]] && continue
        [[ "$_mnt" == "[SWAP]"   ]] && continue
        [[ "$_mnt" == "$ACTUAL_HOME" ]] && continue
        local _free
        _free=$(df -h "$_mnt" 2>/dev/null | awk 'NR==2{print $4}')
        local _display="${LABEL:-$NAME}"
        _CAND_PATH[$_ci]="$_mnt/games"
        _CAND_LABEL[$_ci]="$_mnt  (${_display}, ${SIZE:-?} total, ${_free:-?} free)"
        _CAND_DEV[$_ci]="/dev/$NAME"
        _CAND_UUID[$_ci]="${UUID:-n/a}"
        ((_ci++))
    done < <(lsblk -Pno NAME,MOUNTPOINT,SIZE,LABEL,UUID 2>/dev/null)

    # Unmounted block devices — skip disks that have any mounted partition
    local -a _UNMT_DEV _UNMT_LABEL _UNMT_UUID
    local _ui=0
    while IFS= read -r _line; do
        local _name _size _type _fstype _mnt _label
        read -r _name _size _type _fstype _mnt _label <<< "$_line"
        [[ "$_name" =~ ^loop ]] && continue
        [[ "$_type" != "disk" && "$_type" != "part" ]] && continue
        [[ -n "$_mnt" ]] && continue   # this entry itself is mounted
        # For whole disks, also skip if any child partition is mounted
        if [[ "$_type" == "disk" ]]; then
            lsblk -no MOUNTPOINT "/dev/$_name" 2>/dev/null | grep -q '[^[:space:]]' && continue
        fi
        local _uuid
        _uuid=$(blkid -s UUID -o value "/dev/$_name" 2>/dev/null)
        _UNMT_DEV[$_ui]="$_name"
        _UNMT_LABEL[$_ui]="${_label:+$_label, }${_size}${_fstype:+ ($_fstype)}"
        _UNMT_UUID[$_ui]="${_uuid:-no UUID}"
        ((_ui++))
    done < <(lsblk -no NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,LABEL 2>/dev/null)

    # ── Display the menu ──────────────────────────────────────────────────────
    echo "  Mounted locations:"
    local _n
    for _n in "${!_CAND_PATH[@]}"; do
        printf "    %2d)  %s\n"   "$((_n + 1))" "${_CAND_LABEL[$_n]}"
        printf "         UUID: %s\n" "${_CAND_UUID[$_n]}"
        printf "         → %s\n"  "${_CAND_PATH[$_n]}"
    done

    if [ "${#_UNMT_DEV[@]}" -gt 0 ]; then
        echo ""
        echo "  Unmounted drives (script can format + mount):"
        for _n in "${!_UNMT_DEV[@]}"; do
            printf "    U%d)  /dev/%s  %s\n" "$((_n + 1))" "${_UNMT_DEV[$_n]}" "${_UNMT_LABEL[$_n]}"
            printf "         UUID: %s\n" "${_UNMT_UUID[$_n]}"
        done
    fi

    echo ""
    echo "   c)  Enter a custom path"
    echo ""

    local _PICK="" _BASE_PATH="" GAME_STORAGE_DIR=""
    if [ "$UNATTENDED" = true ]; then
        _BASE_PATH="${_CAND_PATH[0]}"
        log_info "Unattended — using default: $_BASE_PATH"
    else
        while true; do
            read -r -p "  Select drive [1]: " _PICK
            _PICK="${_PICK:-1}"

            if [[ "$_PICK" =~ ^[0-9]+$ ]] && [ "$_PICK" -ge 1 ] && [ "$_PICK" -le "${#_CAND_PATH[@]}" ]; then
                _BASE_PATH="${_CAND_PATH[$((_PICK - 1))]}"
                break
            elif [[ "${_PICK,,}" =~ ^u([0-9]+)$ ]]; then
                local _uidx=$(( ${BASH_REMATCH[1]} - 1 ))
                if [ "$_uidx" -ge 0 ] && [ "$_uidx" -lt "${#_UNMT_DEV[@]}" ]; then
                    _BASE_PATH=""   # will be set after mounting below
                    break
                fi
                echo "  Invalid selection — try again."
            elif [[ "${_PICK,,}" == "c" ]]; then
                _BASE_PATH=""
                break
            else
                echo "  Invalid selection — enter a number, U<n>, or c."
            fi
        done
    fi

    # ── Handle unmounted drive selection ─────────────────────────────────────
    if [[ "${_PICK,,}" =~ ^u([0-9]+)$ ]]; then
        local _uidx=$(( ${BASH_REMATCH[1]} - 1 ))
        local _RAW_DEV="${_UNMT_DEV[$_uidx]}"
        local _DEV="/dev/$_RAW_DEV"
        local _DEFAULT_MP="$ACTUAL_HOME/drives/${_RAW_DEV%%[0-9]}"
        local _MOUNT_POINT=""
        prompt_text "  Mount point for /dev/$_RAW_DEV [${_DEFAULT_MP}]:" "$_DEFAULT_MP" _MOUNT_POINT
        _MOUNT_POINT="${_MOUNT_POINT:-$_DEFAULT_MP}"

        local _PARTITION="$_DEV"
        [[ "$_DEV" =~ [0-9]$ ]] || _PARTITION="${_DEV}1"

        if ! blkid "$_PARTITION" &>/dev/null; then
            log_info "Creating partition on $_DEV..."
            printf 'g\nn\n1\n\n\nw\n' | fdisk "$_DEV"
            partprobe "$_DEV"; sleep 2
        fi

        if ! blkid -s TYPE "$_PARTITION" 2>/dev/null | grep -q TYPE; then
            log_info "Formatting $_PARTITION as ext4..."
            mkfs.ext4 -F -L "games" "$_PARTITION"
        else
            log_info "$_PARTITION already has a filesystem — keeping existing data"
        fi

        mkdir -p "$_MOUNT_POINT"
        mount "$_PARTITION" "$_MOUNT_POINT"

        local _PART_UUID
        _PART_UUID=$(blkid -s UUID -o value "$_PARTITION")
        if [ -n "$_PART_UUID" ]; then
            if grep -qs "$_PART_UUID" /etc/fstab; then
                log_info "fstab: UUID=${_PART_UUID} already present"
            else
                echo "UUID=${_PART_UUID}  ${_MOUNT_POINT}  ext4  defaults,nofail  0  2" \
                    | tee -a /etc/fstab >/dev/null
                log_success "fstab: UUID=${_PART_UUID} → ${_MOUNT_POINT}"
            fi
        else
            log_warning "Could not read UUID — add /etc/fstab entry manually"
        fi
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$_MOUNT_POINT" 2>/dev/null || true
        log_success "$_PARTITION mounted at $_MOUNT_POINT"
        _BASE_PATH="$_MOUNT_POINT/games"
    fi

    # ── Handle custom path ────────────────────────────────────────────────────
    if [[ "${_PICK,,}" == "c" ]]; then
        local _CUSTOM=""
        prompt_text "  Full game storage path:" "$ACTUAL_HOME/games" _CUSTOM
        _BASE_PATH="${_CUSTOM:-$ACTUAL_HOME/games}"
        _BASE_PATH="${_BASE_PATH/#\~/$ACTUAL_HOME}"
    fi

    # ── Let user confirm / edit the subdirectory ──────────────────────────────
    # _BASE_PATH is now the full suggested path (e.g. /mnt/bigdrive/games).
    # Show it and let the user change the trailing component.
    echo ""
    log_info "Suggested game storage path: $_BASE_PATH"
    local _FINAL=""
    prompt_text "  Confirm or edit path [${_BASE_PATH}]:" "$_BASE_PATH" _FINAL
    GAME_STORAGE_DIR="${_FINAL:-$_BASE_PATH}"
    GAME_STORAGE_DIR="${GAME_STORAGE_DIR/#\~/$ACTUAL_HOME}"

    log_success "Game storage: $GAME_STORAGE_DIR"

    # Create the storage sub-directories
    mkdir -p "$GAME_STORAGE_DIR/saves" \
             "$GAME_STORAGE_DIR/media" "$GAME_STORAGE_DIR/lutris" \
             "$GAME_STORAGE_DIR/firefox" "$GAME_STORAGE_DIR/minecraft" \
             "$GAME_STORAGE_DIR/kodi" "$GAME_STORAGE_DIR/emulators" \
             "$GAME_STORAGE_DIR/steam-cache"

    # ── Wolf state folder on the game drive ───────────────────────────────────
    # This is the clean way to keep Steam (and everything else) off the OS
    # drive: relocate Wolf's ENTIRE state folder onto the game drive instead of
    # symlinking individual app homes. Wolf stores each app's session home,
    # Steam install, downloaded games, and Proton prefixes under this folder,
    # and writes its own config.toml under <state>/cfg/. We mount it at the
    # SAME path inside and outside the wolf container so that the app containers
    # Wolf spawns through the Docker socket (which receive HOST paths) resolve
    # correctly on the host. No symlinks, no libraryfolders.vdf, no fix-perms.
    local WOLF_STATE_DIR="$GAME_STORAGE_DIR/wolf-state"
    local WOLF_CFG="$WOLF_STATE_DIR/cfg/config.toml"
    mkdir -p "$WOLF_STATE_DIR/cfg"
    chown -R 1000:1000 "$WOLF_STATE_DIR" 2>/dev/null || true

    # Migrate any pre-existing Wolf state from the default OS-drive location so
    # an upgrading user keeps their Steam install / games instead of losing them.
    if [ -d /etc/wolf ] && [ -n "$(ls -A /etc/wolf 2>/dev/null)" ] \
       && [ -z "$(ls -A "$WOLF_STATE_DIR" 2>/dev/null | grep -v '^cfg$')" ]; then
        local _MIGRATE=""
        prompt_yn "Existing Wolf data found at /etc/wolf (OS drive). Move it to $WOLF_STATE_DIR now? (y/n):" "y" _MIGRATE
        if [[ "$_MIGRATE" =~ ^[Yy]$ ]]; then
            log_info "Migrating /etc/wolf → $WOLF_STATE_DIR (this can take a while for large Steam installs)..."
            cp -a /etc/wolf/. "$WOLF_STATE_DIR"/ \
                && rm -rf /etc/wolf/* \
                && log_success "Migration complete — old data now on the game drive" \
                || log_warning "Migration hit an error; check $WOLF_STATE_DIR before deleting /etc/wolf"
            chown -R 1000:1000 "$WOLF_STATE_DIR" 2>/dev/null || true
        fi
    fi

    # Pre-create ES-DE ROM directories so the user knows where to drop files
    # and ES-DE shows the system in its list immediately on first launch.
    local _ESDE_SYSTEMS=(
        3do amstradcpc arcade atari2600 atari5200 atari7800 atari800
        atarijaguar atarilynx atarist c64 cavestory channelf coco colecovision
        dreamcast dos famicom fds gamegear gb gba gbc gc genesis
        gx4000 intellivision j2me lynx mame megadrive megadrive-japan
        msx msx2 n64 naomi nds neogeo neogeocd ngp ngpc nes nintendo3ds
        odyssey2 pc88 pc98 pcengine pcenginecd pcfx pokemini ps2 ps3 psp psx
        saturn scummvm sega32x segacd sg-1000 snes snesmsu1 supervision
        switch tg16 tg-cd vectrex vic20 videopac wii wiiu wonderswan
        wonderswancolor x68000 xbox xbox360 zmachine zxspectrum
    )
    local _sys
    for _sys in "${_ESDE_SYSTEMS[@]}"; do
        mkdir -p "$GAME_STORAGE_DIR/roms/$_sys"
    done

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$GAME_STORAGE_DIR" 2>/dev/null || true
    log_success "Storage layout: $GAME_STORAGE_DIR/{roms/<system>/,steam,saves,media,emulators,...}"
    log_info "ES-DE ROM directories pre-created. Drop ROMs in the matching subfolder."

    # ── Optional: download Azahar (3DS emulator) ─────────────────────────────
    # Azahar is an open-source Citra fork — the recommended legal 3DS emulator
    # for ES-DE. AppImages dropped in emulators/ are found automatically by
    # ES-DE's app finder (checks ~/Applications inside the container).
    local _AZAHAR_DIR="$GAME_STORAGE_DIR/emulators"
    if ! ls "$_AZAHAR_DIR"/azahar*.AppImage 2>/dev/null | grep -q .; then
        local _get_az=""
        echo ""
        log_info "3DS emulation: Azahar (open-source Citra fork) can be auto-downloaded."
        prompt_yn "Download Azahar 3DS emulator AppImage now? (y/n):" "y" _get_az
        if [[ "$_get_az" =~ ^[Yy]$ ]]; then
            log_info "Fetching latest Azahar release from GitHub..."
            local _AZ_URL
            _AZ_URL=$(curl -fsSL "https://api.github.com/repos/azahar-emu/azahar/releases/latest" \
                | python3 -c "import sys,json; r=json.load(sys.stdin); \
                  print(next((a['browser_download_url'] for a in r['assets'] \
                  if a['name'].endswith('.AppImage')), ''))" 2>/dev/null)
            if [[ -n "$_AZ_URL" ]]; then
                local _AZ_FILE="$_AZAHAR_DIR/$(basename "$_AZ_URL")"
                curl -fL --progress-bar -o "$_AZ_FILE" "$_AZ_URL" \
                    && chmod +x "$_AZ_FILE" \
                    && chown "$ACTUAL_USER:$ACTUAL_USER" "$_AZ_FILE" \
                    && log_success "Azahar downloaded: $_AZ_FILE" \
                    || log_warning "Download failed — get it manually from https://github.com/azahar-emu/azahar/releases"
            else
                log_warning "Could not resolve download URL — get it manually from https://github.com/azahar-emu/azahar/releases"
            fi
        fi
    else
        log_info "Azahar already present in $GAME_STORAGE_DIR/emulators/"
    fi

    # ── App selection ─────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  WOLF APPS"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Select apps to add to Wolf (shown in Moonlight)."
    echo "  Containers are pulled on first launch, not now."
    echo ""
    echo "   1) Steam              - Big Picture + Proton (PC games)"
    echo "   2) EmulationStation   - ES-DE + RetroArch (retro ROMs) [default]"
    echo "   3) Lutris             - GOG / Epic / Wine / non-Steam"
    echo "   4) RetroArch          - standalone emulator frontend"
    echo "   5) Prism Launcher     - Minecraft (Java + Bedrock)"
    echo "   6) Kodi               - media center"
    echo "   7) Firefox            - browser"
    echo "   8) Desktop            - full XFCE desktop session"
    echo ""
    echo "  Enter numbers separated by spaces, or 'all', or Enter for [1 2]:"
    echo ""

    local _APP_PICKS="" _SELECTED_APPS=()
    if [ "$UNATTENDED" = true ]; then
        _SELECTED_APPS=(1 2)
        log_info "Unattended — selecting Steam + EmulationStation"
    else
        read -r -p "  Apps [1 2]: " _APP_PICKS
        _APP_PICKS="${_APP_PICKS:-1 2}"
        if [[ "${_APP_PICKS,,}" == "all" ]]; then
            _SELECTED_APPS=(1 2 3 4 5 6 7 8)
        else
            read -ra _SELECTED_APPS <<< "$_APP_PICKS"
        fi
    fi

    # Map numbers to app keys for the Python injector
    local _APP_KEYS=""
    for _n in "${_SELECTED_APPS[@]}"; do
        case "$_n" in
            1) _APP_KEYS="$_APP_KEYS steam" ;;
            2) _APP_KEYS="$_APP_KEYS esde" ;;
            3) _APP_KEYS="$_APP_KEYS lutris" ;;
            4) _APP_KEYS="$_APP_KEYS retroarch" ;;
            5) _APP_KEYS="$_APP_KEYS prismlauncher" ;;
            6) _APP_KEYS="$_APP_KEYS kodi" ;;
            7) _APP_KEYS="$_APP_KEYS firefox" ;;
            8) _APP_KEYS="$_APP_KEYS desktop" ;;
        esac
    done
    _APP_KEYS="${_APP_KEYS# }"   # trim leading space
    log_info "Will add: ${_APP_KEYS:-none}"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    log_info "Generating docker-compose.yml..."
    mkdir -p "$WOLF_STATE_DIR/cfg"
    mkdir -p "$WOLF_DIR"
    ensure_docker_dir_ownership "$WOLF_DIR"
    cd "$WOLF_DIR" || return 1

    # Detect the LAN interface (the one used to reach the internet, not VPN/loopback)
    local LAN_IFACE LAN_IP LAN_MAC
    LAN_IFACE=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \K\S+' | head -1)
    LAN_IP=$(ip route get 8.8.8.8 2>/dev/null | grep -oP 'src \K\S+' | head -1)
    LAN_MAC=$(ip link show "$LAN_IFACE" 2>/dev/null | grep -oP 'ether \K\S+' | head -1)
    log_success "LAN interface: $LAN_IFACE  IP: $LAN_IP  MAC: $LAN_MAC"

    # If Tailscale is running, Wolf must advertise the Tailscale IP so Moonlight
    # clients on the tailnet can connect.
    local TS_IP TS_MAC WOLF_IP WOLF_MAC
    TS_IP=$(tailscale ip -4 2>/dev/null | head -1)
    if [ -n "$TS_IP" ]; then
        TS_MAC=$(ip link show tailscale0 2>/dev/null | grep -oP 'ether \K\S+' | head -1)
        WOLF_IP="$TS_IP"
        WOLF_MAC="${TS_MAC:-$LAN_MAC}"
        log_success "Tailscale detected — Wolf will advertise Tailscale IP: $TS_IP"
        log_info "In Moonlight use 'Add PC' and enter: $TS_IP"
    else
        WOLF_IP="$LAN_IP"
        WOLF_MAC="$LAN_MAC"
    fi

    # Write compose using a mixed heredoc: WOLF_STATE_DIR comes from .env at
    # runtime (docker compose variable substitution), so it stays correct even
    # if the drive is remounted at a different path. IP/MAC/render-node are
    # baked in at install time because they're hardware-specific and not stored
    # in .env — use 'manage.sh update-network' to regenerate if they change.
    cat > docker-compose.yml << EOF
name: wolf

services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    network_mode: host
    restart: unless-stopped
    environment:
      - NVIDIA_DRIVER_VOLUME_NAME=nvidia-driver-vol
      # WOLF_STATE_DIR is read from .env at runtime — edit .env to relocate.
      # Must be the same path inside and outside the container so that app
      # containers Wolf spawns via the Docker socket resolve it on the host.
      - HOST_APPS_STATE_FOLDER=\${WOLF_STATE_DIR}
      - WOLF_CFG_FOLDER=\${WOLF_STATE_DIR}/cfg
      - WOLF_INTERNAL_IP=${WOLF_IP}
      - WOLF_INTERNAL_MAC=${WOLF_MAC}
      - WOLF_RENDER_NODE=${WOLF_RENDER_NODE}
      - LD_LIBRARY_PATH=/usr/nvidia/lib:/usr/nvidia/lib32
    volumes:
      - \${WOLF_STATE_DIR}:\${WOLF_STATE_DIR}:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /dev/:/dev/:rw
      - /run/udev:/run/udev:rw
      - nvidia-driver-vol:/usr/nvidia:rw
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
      - /dev/nvidia-uvm
      - /dev/nvidia-uvm-tools
      - /dev/nvidia-caps/nvidia-cap1
      - /dev/nvidia-caps/nvidia-cap2
      - /dev/nvidiactl
      - /dev/nvidia0
      - /dev/nvidia-modeset
    device_cgroup_rules:
      - 'c 13:* rmw'

volumes:
  nvidia-driver-vol:
    external: true
EOF
    log_success "docker-compose.yml created"

    # Save the game storage path so it's visible and editable later
    cat > .env << EOF
# Wolf game/ROM storage root — edit this and run ./manage.sh update-storage to apply
GAME_STORAGE_DIR=${GAME_STORAGE_DIR}
# Wolf state folder (config.toml + every app session home) — lives on the game
# drive so Steam installs, games, and Proton prefixes stay off the OS drive.
WOLF_STATE_DIR=${WOLF_STATE_DIR}
# Timezone for app containers (Steam/Proton etc.) — set on each app's TZ env so
# Steam, EA App, and games show the correct local time. Edit + ./manage.sh apps.
WOLF_TZ=${SITE_TZ}
EOF
    chmod 600 .env
    chown "$ACTUAL_USER:$ACTUAL_USER" .env
    log_success ".env written with GAME_STORAGE_DIR=${GAME_STORAGE_DIR}"

    # ── Firewall ──────────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening Moonlight ports in UFW..."
        for p in "${WOLF_PORTS_TCP[@]}"; do ufw allow "${p}/tcp" comment "Wolf/Moonlight" >/dev/null 2>&1 || true; done
        for p in "${WOLF_PORTS_UDP[@]}"; do ufw allow "${p}/udp" comment "Wolf/Moonlight" >/dev/null 2>&1 || true; done
        log_success "Ports opened: TCP ${WOLF_PORTS_TCP[*]} / UDP ${WOLF_PORTS_UDP[*]}"
    else
        log_warning "ufw not installed — if you use a firewall, open these ports:"
        echo "  TCP: ${WOLF_PORTS_TCP[*]}   UDP: ${WOLF_PORTS_UDP[*]}"
    fi

    # ── Management script ─────────────────────────────────────────────────────
    cat > manage.sh << 'MEOF'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Wolf's state folder (config.toml + every app session home, Steam install,
# games, Proton prefixes) lives on the game drive — see WOLF_STATE_DIR in .env.
# Nothing here needs to relocate or symlink anything; Wolf writes straight to
# the drive because docker-compose.yml mounts it as HOST_APPS_STATE_FOLDER.
WOLF_STATE_DIR=$(grep '^WOLF_STATE_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2-)
WOLF_CFG="${WOLF_STATE_DIR:-/etc/wolf}/cfg/config.toml"
WOLF_TZ=$(grep '^WOLF_TZ=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2-)

# Locate the Steam home under the Wolf state folder (born on first Steam launch).
_steam_home() {
    find "${WOLF_STATE_DIR:-/etc/wolf}" -maxdepth 2 -type d -name Steam 2>/dev/null | head -1
}

# Download the GE-Proton tarball to a local cache dir so it is ready to
# extract the moment Steam has launched (no re-download needed).
# Idempotent — skips the download if the cache file already exists.
_cache_ge_proton() {
    local version="${1:-}"
    local cache_dir="$SCRIPT_DIR/ge-proton-cache"
    mkdir -p "$cache_dir"
    local url name
    if [ -n "$version" ]; then
        url="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$version/$version.tar.gz"
    else
        echo "Fetching latest GE-Proton release info..."
        url=$(curl -sL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
              | grep browser_download_url | grep '\.tar\.gz' | cut -d'"' -f4)
        if [ -z "$url" ]; then
            echo "Could not determine GE-Proton download URL (GitHub rate-limited or offline?)."
            return 1
        fi
    fi
    name=$(basename "$url" .tar.gz)
    local cached="$cache_dir/$name.tar.gz"
    if [ -f "$cached" ]; then
        echo "GE-Proton already cached: $cached"
        echo "$name" > "$cache_dir/.version"
        return 0
    fi
    echo "Downloading $name (~500 MB) to cache..."
    if curl -L -o "$cached" "$url"; then
        echo "$name" > "$cache_dir/.version"
        echo "Cached: $cached"
    else
        echo "Download failed."; rm -f "$cached"; return 1
    fi
}

# Pre-satisfy the EA App install-script markers in a game's Proton prefix so
# Steam stops looping on "running install script (EA app)". The EA Desktop
# InstallSuccessful flag is shared across all EA titles; the Valve has-run key
# is per-AppID but identical in form for every EA game — so this works for any
# of them. Safe + idempotent; only touches the AppID passed in.
#
# IMPORTANT: wineserver holds registry state in memory and flushes it back to
# disk, overwriting any edits made while the container is running. We stop the
# WolfSteam container first, patch the files on disk, then restart — so the
# keys survive intact when wineserver next starts.
_apply_ea_fix() {
    local appid="$1"
    local steam_home reg acf container_was_running=0
    steam_home=$(_steam_home)
    reg="$steam_home/.steam/steam/steamapps/compatdata/$appid/pfx/system.reg"
    acf="$steam_home/.steam/steam/steamapps/appmanifest_${appid}.acf"

    if [ ! -f "$reg" ]; then
        echo "No Proton prefix for AppID $appid yet (looked for $reg)."
        echo "In Steam: set the game to GE-Proton (./manage.sh ge-proton),"
        echo "click Play once to build the prefix, then re-run this."
        return 1
    fi

    # Stop the Steam container so wineserver is not running when we edit the
    # registry.  We restart it at the end so the user's session resumes.
    local steam_container
    steam_container=$(docker ps --format '{{.Names}}' | grep -i 'WolfSteam' | head -1)
    if [ -n "$steam_container" ]; then
        echo "Stopping $steam_container so wineserver is not running during patch..."
        docker stop "$steam_container" >/dev/null
        container_was_running=1
        sleep 2
    fi

    # Locate EA App executables inside the Proton prefix.
    # Prefer EADesktop.exe (full EA App install); fall back to Link2EA.exe (stub or partial).
    local pfx_root
    pfx_root="$steam_home/.steam/steam/steamapps/compatdata/$appid/pfx/drive_c"
    local ureg
    ureg="$steam_home/.steam/steam/steamapps/compatdata/$appid/pfx/user.reg"
    local ea_exe link2ea_exe
    ea_exe=$(sudo find "$pfx_root" -maxdepth 8 \
        -ipath "*/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe" \
        -print -quit 2>/dev/null)
    link2ea_exe=$(sudo find "$pfx_root" -maxdepth 8 \
        -ipath "*/Electronic Arts/EA Desktop/*/EA Desktop/Link2EA.exe" \
        -print -quit 2>/dev/null)

    # check both system.reg AND user.reg for existing link2ea registration
    local _has_link2ea=0
    { sudo grep -q 'link2ea' "$reg" 2>/dev/null || sudo grep -q 'link2ea' "$ureg" 2>/dev/null; } \
        && _has_link2ea=1

    if sudo grep -q 'EADesktopSetup' "$reg" 2>/dev/null && [ "$_has_link2ea" = 1 ]; then
        echo "Registry keys already present in AppID $appid prefix."
        if [ -n "$ea_exe" ]; then
            echo "  EA App: $ea_exe"
        elif [ -n "$link2ea_exe" ]; then
            echo "  Link2EA.exe: $link2ea_exe"
            echo "  NOTE: Full EA App not yet installed. Run ./manage.sh install-ea-app to install it."
        fi
    else
        echo "Patching EA install-script markers for AppID $appid..."
        # Wine v2 registry format uses doubled backslashes as path separator.
        # Wow6432Node version is the one wineserver preserves on flush;
        # Steam's HasRunStringKey check is satisfied by the 32-bit view.
        {
            printf '\n[Software\\\\Electronic Arts\\\\EA Desktop] 1781772837\n"InstallSuccessful"="true"\n'
            printf '\n[Software\\\\Wow6432Node\\\\Electronic Arts\\\\EA Desktop] 1781772837\n"InstallSuccessful"="true"\n'
            printf '\n[Software\\\\Valve\\\\Steam\\\\Apps\\\\%s] 1781772837\n"EADesktopSetup"=dword:00000001\n' "$appid"
            printf '\n[Software\\\\Wow6432Node\\\\Valve\\\\Steam\\\\Apps\\\\%s] 1781772837\n"EADesktopSetup"=dword:00000001\n' "$appid"

            # Register the link2ea:// URL protocol handler in system.reg (HKLM).
            # SWBF2 calls ShellExecute("link2ea://launchgame/...") and exits; the
            # EA App (EADesktop.exe) re-authenticates and re-launches the game.
            # GE-Proton's steam.exe intercepts link2ea:// and forwards to Link2EA.exe.
            # NOTE: user.reg (HKCU) takes priority; GE-Proton may already have registered
            #       this there during prefix setup. Check with: ./manage.sh diagnose-ea
            local _handler_exe=""
            if [ -n "$ea_exe" ]; then
                _handler_exe="$ea_exe"
                echo "  Using real EA App: $ea_exe"
            elif [ -n "$link2ea_exe" ]; then
                _handler_exe="$link2ea_exe"
                echo "  Using Link2EA.exe stub: $link2ea_exe"
                echo "  NOTE: Run ./manage.sh install-ea-app to install full EA App."
            fi

            if [ -n "$_handler_exe" ]; then
                local win_path
                win_path=$(echo "$_handler_exe" \
                    | sed "s|$pfx_root||" \
                    | sed 's|/|\\\\|g' \
                    | sed 's|^|C:|')
                printf '\n[Software\\\\Classes\\\\link2ea] 1781772837\n@="link2ea Protocol"\n"URL Protocol"=""\n'
                printf '\n[Software\\\\Classes\\\\link2ea\\\\shell] 1781772837\n'
                printf '\n[Software\\\\Classes\\\\link2ea\\\\shell\\\\open] 1781772837\n'
                printf '\n[Software\\\\Classes\\\\link2ea\\\\shell\\\\open\\\\command] 1781772837\n@="%s \\"%%1\\""\n' "$win_path"
                printf '\n[Software\\\\Wow6432Node\\\\Classes\\\\link2ea] 1781772837\n@="link2ea Protocol"\n"URL Protocol"=""\n'
                printf '\n[Software\\\\Wow6432Node\\\\Classes\\\\link2ea\\\\shell] 1781772837\n'
                printf '\n[Software\\\\Wow6432Node\\\\Classes\\\\link2ea\\\\shell\\\\open] 1781772837\n'
                printf '\n[Software\\\\Wow6432Node\\\\Classes\\\\link2ea\\\\shell\\\\open\\\\command] 1781772837\n@="%s \\"%%1\\""\n' "$win_path"
                echo "  link2ea:// handler registered in system.reg → $win_path"
            else
                echo "  WARNING: EA App not found (neither EADesktop.exe nor Link2EA.exe)."
                echo "  link2ea:// handler NOT registered in system.reg."
                echo "  GE-Proton may have already registered it in user.reg — check with:"
                echo "    ./manage.sh diagnose-ea $appid"
                echo "  To install EA App: ./manage.sh install-ea-app $appid"
            fi
        } | sudo tee -a "$reg" >/dev/null
        sudo chown 1000:1000 "$reg"
        echo "  Registry patched."
    fi

    # Reset StateFlags to 4 (fully installed) so Steam won't re-run install scripts.
    if [ -f "$acf" ]; then
        sudo sed -i 's/"StateFlags"\s*"[0-9]*"/"StateFlags"\t\t"4"/' "$acf"
        # StateFlags 4 = update required (re-runs install scripts); 6 = fully installed.
        # We want 6 so Steam launches the game directly.
        sudo sed -i 's/"StateFlags"\t\t"4"/"StateFlags"\t\t"6"/' "$acf"
        sudo chown 1000:1000 "$acf"
        echo "  StateFlags set to 6 (fully installed)."
    fi

    if [ "$container_was_running" = 1 ]; then
        echo "Restarting Wolf (Steam will reconnect automatically)..."
        docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d >/dev/null 2>&1 || \
            docker start "$steam_container" >/dev/null 2>&1 || true
        echo "  Wolf restarted. Reconnect from Moonlight and click Play."
    fi
    echo "Done. In Steam: if the 'running install script' screen appears, cancel it, then Play."
}

case "$1" in
    start)
        docker compose up -d
        echo "Wolf started. Pair Moonlight to this server's IP."
        # If GE-Proton is cached but not yet extracted (Steam launched since
        # install), extract it now so it appears in the Compatibility dropdown.
        _STEAM_H=$(_steam_home)
        if [ -n "$_STEAM_H" ]; then
            _COMPAT="$_STEAM_H/.steam/compatibilitytools.d"
            _CACHE="$SCRIPT_DIR/ge-proton-cache"
            _CACHED_VER=""
            [ -f "$_CACHE/.version" ] && _CACHED_VER=$(cat "$_CACHE/.version")
            if [ -n "$_CACHED_VER" ] && [ -f "$_CACHE/$_CACHED_VER.tar.gz" ] \
               && [ ! -d "$_COMPAT/$_CACHED_VER" ]; then
                echo "Extracting cached GE-Proton $_CACHED_VER..."
                sudo mkdir -p "$_COMPAT"
                sudo tar -xzf "$_CACHE/$_CACHED_VER.tar.gz" -C "$_COMPAT"
                sudo chown -R 1000:1000 "$_COMPAT"
                echo "GE-Proton $_CACHED_VER ready. In Steam: game → Properties → Compatibility → Force $_CACHED_VER"
            fi
        fi
        ;;
    stop)    docker compose down ;;
    restart) docker compose restart ;;
    logs)    docker compose logs -f wolf ;;
    status)  docker compose ps; echo; docker ps --filter "name=Wolf" --format "table {{.Names}}\t{{.Status}}" ;;
    update)
        docker compose pull
        docker compose up -d
        ;;
    apps|add-apps|update-storage)
        # WOLF_CFG resolved at top of script from .env

        # Resolve game storage dir: explicit arg > .env > prompt
        GAME_DIR="${2:-}"
        if [ -z "$GAME_DIR" ]; then
            GAME_DIR=$(grep '^GAME_STORAGE_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2-)
        fi
        if [ -z "$GAME_DIR" ]; then
            read -r -p "  Game storage path: " GAME_DIR
        fi
        if [ -z "$GAME_DIR" ]; then echo "No game storage path."; exit 1; fi

        # Persist path back to .env if it changed
        if grep -qs '^GAME_STORAGE_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null; then
            sed -i "s|^GAME_STORAGE_DIR=.*|GAME_STORAGE_DIR=${GAME_DIR}|" "$SCRIPT_DIR/.env"
        else
            echo "GAME_STORAGE_DIR=${GAME_DIR}" >> "$SCRIPT_DIR/.env"
        fi

        # Ensure steam-cache dir exists (persists DXVK/Mesa shader cache across sessions)
        mkdir -p "$GAME_DIR/steam-cache"
        sudo chown -R 1000:1000 "$GAME_DIR/steam-cache" 2>/dev/null || true

        if [ ! -f "$WOLF_CFG" ]; then
            echo "Wolf config not found at $WOLF_CFG — is Wolf running?"
            exit 1
        fi

        # Show which apps are already installed and what's available
        echo ""
        echo "  Checking current Wolf config..."
        INSTALLED=$(sudo grep "^    name = 'Wolf" "$WOLF_CFG" 2>/dev/null | sed "s/.*name = '//;s/'//" | tr '\n' ' ')
        [ -n "$INSTALLED" ] && echo "  Already installed: $INSTALLED" || echo "  No Wolf apps installed yet."
        echo ""
        echo "  Available apps:"
        echo "   1) Steam              - Big Picture + Proton (PC games)"
        echo "   2) EmulationStation   - ES-DE + RetroArch (retro ROMs)"
        echo "   3) Lutris             - GOG / Epic / Wine / non-Steam"
        echo "   4) RetroArch          - standalone emulator frontend"
        echo "   5) Prism Launcher     - Minecraft (Java + Bedrock)"
        echo "   6) Kodi               - media center"
        echo "   7) Firefox            - browser"
        echo "   8) Desktop            - full XFCE desktop session"
        echo ""
        echo "  Enter numbers (space-separated), 'all', or Enter to update existing mounts only:"
        read -r -p "  Apps [Enter=update mounts only]: " _PICKS
        if [[ "${_PICKS,,}" == "all" ]]; then
            APP_KEYS="steam esde lutris retroarch prismlauncher kodi firefox desktop"
        elif [ -z "$_PICKS" ]; then
            # No new apps — just re-run with whatever keys are already installed
            APP_KEYS=""
            [[ "$INSTALLED" == *WolfSteam* ]]         && APP_KEYS="$APP_KEYS steam"
            [[ "$INSTALLED" == *WolfES-DE* ]]          && APP_KEYS="$APP_KEYS esde"
            [[ "$INSTALLED" == *WolfLutris* ]]         && APP_KEYS="$APP_KEYS lutris"
            [[ "$INSTALLED" == *WolfRetroArch* ]]      && APP_KEYS="$APP_KEYS retroarch"
            [[ "$INSTALLED" == *WolfPrismLauncher* ]]  && APP_KEYS="$APP_KEYS prismlauncher"
            [[ "$INSTALLED" == *WolfKodi* ]]           && APP_KEYS="$APP_KEYS kodi"
            [[ "$INSTALLED" == *WolfFirefox* ]]        && APP_KEYS="$APP_KEYS firefox"
            [[ "$INSTALLED" == *WolfDesktop* ]]        && APP_KEYS="$APP_KEYS desktop"
            APP_KEYS="${APP_KEYS# }"
            [ -z "$APP_KEYS" ] && APP_KEYS="steam esde"
        else
            APP_KEYS=""
            for _n in $_PICKS; do
                case "$_n" in
                    1) APP_KEYS="$APP_KEYS steam" ;;
                    2) APP_KEYS="$APP_KEYS esde" ;;
                    3) APP_KEYS="$APP_KEYS lutris" ;;
                    4) APP_KEYS="$APP_KEYS retroarch" ;;
                    5) APP_KEYS="$APP_KEYS prismlauncher" ;;
                    6) APP_KEYS="$APP_KEYS kodi" ;;
                    7) APP_KEYS="$APP_KEYS firefox" ;;
                    8) APP_KEYS="$APP_KEYS desktop" ;;
                esac
            done
            APP_KEYS="${APP_KEYS# }"
        fi

        echo "  Applying: ${APP_KEYS:-none}"
        [ -z "$APP_KEYS" ] && exit 0

        sudo python3 - "$GAME_DIR" "$WOLF_CFG" "$WOLF_TZ" $APP_KEYS << 'PYEOF'
import sys, json

games    = sys.argv[1].rstrip('/')
cfg      = sys.argv[2]
TZ       = sys.argv[3].strip()
selected = set(sys.argv[4:])

STD_CAP   = ['NET_RAW', 'MKNOD', 'NET_ADMIN']
STD_ENV   = ['RUN_SWAY=1', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*']
STD_RULES = ['c 13:* rmw', 'c 244:* rmw']

CATALOG = {
    'steam': dict(
        name='WolfSteam', title='Steam',
        icon='https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png',
        image='ghcr.io/games-on-whales/steam:edge',
        mounts=['/etc/localtime:/etc/localtime:ro', '/etc/timezone:/etc/timezone:ro',
                f'{games}/steam-cache:/home/retro/.cache:rw'],
        env=['PROTON_LOG=1', 'RUN_SWAY=true',
             'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*'],
        cap_add=['SYS_ADMIN', 'SYS_NICE', 'SYS_PTRACE', 'NET_RAW', 'MKNOD', 'NET_ADMIN'],
        security_opt=['seccomp=unconfined', 'apparmor=unconfined'],
        ipc_mode='host', ulimits=[{'Name': 'nofile', 'Hard': 10240, 'Soft': 10240}],
        privileged=False,
    ),
    'esde': dict(
        name='WolfES-DE', title='EmulationStation',
        icon='https://games-on-whales.github.io/wildlife/apps/es-de/assets/icon.png',
        image='ghcr.io/games-on-whales/es-de:edge',
        mounts=[f'{games}/roms:/ROMs:rw',
                f'{games}/saves:/mnt/games/saves:rw',
                f'{games}/media:/media:rw',
                f'{games}/emulators:/mnt/games/emulators:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'lutris': dict(
        name='WolfLutris', title='Lutris',
        icon='https://games-on-whales.github.io/wildlife/apps/lutris/assets/icon.png',
        image='ghcr.io/games-on-whales/lutris:edge',
        mounts=[f'{games}/lutris:/mnt/games/lutris:rw'],
        env=['RUN_SWAY=true',
             'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*'],
        cap_add=['SYS_ADMIN', 'NET_RAW', 'MKNOD', 'NET_ADMIN'],
        security_opt=['seccomp=unconfined', 'apparmor=unconfined'],
        ipc_mode='host', ulimits=[], privileged=False,
    ),
    'retroarch': dict(
        name='WolfRetroArch', title='RetroArch',
        icon='https://games-on-whales.github.io/wildlife/apps/retroarch/assets/icon.png',
        image='ghcr.io/games-on-whales/retroarch:edge',
        mounts=[f'{games}/roms:/ROMs:rw',
                f'{games}/saves:/mnt/games/saves:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'prismlauncher': dict(
        name='WolfPrismLauncher', title='Prism Launcher',
        icon='https://games-on-whales.github.io/wildlife/apps/prismlauncher/assets/icon.png',
        image='ghcr.io/games-on-whales/prismlauncher:edge',
        mounts=[f'{games}/minecraft:/mnt/games/minecraft:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'kodi': dict(
        name='WolfKodi', title='Kodi',
        icon='https://games-on-whales.github.io/wildlife/apps/kodi/assets/icon.png',
        image='ghcr.io/games-on-whales/kodi:edge',
        mounts=[f'{games}/kodi:/mnt/games/kodi:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'firefox': dict(
        name='WolfFirefox', title='Firefox',
        icon='https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png',
        image='ghcr.io/games-on-whales/firefox:edge',
        mounts=[f'{games}/firefox:/mnt/games/firefox:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'desktop': dict(
        name='WolfDesktop', title='Desktop',
        icon='https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png',
        image='ghcr.io/games-on-whales/desktop:edge',
        mounts=[],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
}

def ensure_tz(env_list):
    # Set the container timezone so Steam / EA App / games show local time
    # (a wrong/UTC display can confuse EA App's installer). Driven by WOLF_TZ.
    e = [x for x in env_list if not x.startswith('TZ=')]
    if TZ:
        e.append(f'TZ={TZ}')
    return e

def make_app_block(app):
    host_cfg = {'IpcMode': app['ipc_mode'], 'CapAdd': app['cap_add'],
                'Privileged': app['privileged'], 'DeviceCgroupRules': STD_RULES}
    if app['security_opt']: host_cfg['SecurityOpt'] = app['security_opt']
    if app['ulimits']:       host_cfg['Ulimits'] = app['ulimits']
    create_json = json.dumps({'HostConfig': host_cfg}, indent=2)
    mounts_str  = str(app['mounts']).replace('"', "'")
    env_str     = str(ensure_tz(app['env'])).replace('"', "'")
    return (
        f"\n"
        f"    [[profiles.apps]]\n"
        f"    icon_png_path = '{app['icon']}'\n"
        f"    start_virtual_compositor = true\n"
        f"    title = '{app['title']}'\n"
        f"\n"
        f"        [profiles.apps.runner]\n"
        f"        base_create_json = '''{create_json}\n"
        f"'''\n"
        f"        devices = []\n"
        f"        env = {env_str}\n"
        f"        image = '{app['image']}'\n"
        f"        mounts = {mounts_str}\n"
        f"        name = '{app['name']}'\n"
        f"        ports = []\n"
        f"        type = 'docker'\n"
    )

def update_field(lines, wolf_name, field, new_value):
    # Wolf rewrites config.toml and reformats arrays (mounts/env) as MULTI-LINE,
    # so we must replace the entire array (from `<field> =` to its closing `]`),
    # not just the first line — otherwise the old elements are left orphaned and
    # the file becomes invalid TOML. Always rewrite as a single line, and heal
    # any orphaned remnants left by a previously corrupted single-line rewrite.
    for i, line in enumerate(lines):
        if f"name = '{wolf_name}'" in line:
            for j in range(max(0, i-25), min(len(lines), i+25)):
                if lines[j].lstrip().startswith(field + ' ='):
                    indent = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                    k = j
                    while k < len(lines) and ']' not in lines[k]:
                        k += 1
                    m = k + 1
                    while m < len(lines):
                        s = lines[m].lstrip()
                        if s.startswith("'") or s.startswith(']'):
                            m += 1
                        else:
                            break
                    lines[j:m] = [f"{indent}{field} = {new_value}\n"]
                    return True
    return False

with open(cfg, 'r') as f:
    lines = f.readlines()

profiles_seen, first_start, insert_at = 0, None, len(lines)
for i, line in enumerate(lines):
    if line.strip() == '[[profiles]]':
        profiles_seen += 1
        if profiles_seen == 1: first_start = i
        elif profiles_seen == 2: insert_at = i; break

if first_start is None:
    print('ERROR: no [[profiles]] section found'); sys.exit(1)

first_block = lines[first_start:insert_at]
added, updated, to_insert = [], [], []

for key in list(CATALOG.keys()):
    if key not in selected: continue
    app = CATALOG[key]
    wolf_name  = app['name']
    new_mounts = str(app['mounts']).replace('"', "'")
    new_env    = str(ensure_tz(app['env'])).replace('"', "'")
    already    = any(f"name = '{wolf_name}'" in l for l in first_block)
    if already:
        ok = update_field(lines, wolf_name, 'mounts', new_mounts)
        ok = update_field(lines, wolf_name, 'env', new_env) or ok
        if ok:
            updated.append(app['title'])
    else:
        to_insert.append(make_app_block(app))
        added.append(app['title'])

if to_insert:
    block_lines = []
    for block in to_insert:
        block_lines += [l + '\n' if not l.endswith('\n') else l
                        for l in block.splitlines()]
    new_lines = lines[:insert_at] + block_lines + lines[insert_at:]
    with open(cfg, 'w') as f:
        f.writelines(new_lines)
elif updated:
    with open(cfg, 'w') as f:
        f.writelines(lines)

if added:   print(f"Added: {', '.join(added)}")
if updated: print(f"Updated mounts + timezone: {', '.join(updated)}")
if not added and not updated:
    print('All selected apps already present and up to date')
PYEOF
        docker compose restart wolf
        echo "Wolf restarted. Apps will appear in Moonlight on next connection."
        ;;
    reorder)
        # Interactively reorder the Moonlight tiles by reordering the
        # [[profiles.apps]] blocks in Wolf's config.toml (Moonlight shows them
        # in file order). config.toml is root-owned, so run Python under sudo;
        # the prompt is read from /dev/tty since stdin is the heredoc script.
        if [ ! -f "$WOLF_CFG" ]; then
            echo "Wolf config not found at $WOLF_CFG — start Wolf once first."
            exit 1
        fi
        sudo python3 - "$WOLF_CFG" << 'PYEOF'
import sys, re
cfg = sys.argv[1]
with open(cfg) as f:
    lines = f.readlines()

prof = [i for i, l in enumerate(lines) if l.strip() == '[[profiles]]']
if not prof:
    print('No [[profiles]] section found.'); sys.exit(1)
start = prof[0]
end   = prof[1] if len(prof) > 1 else len(lines)

marks = [i for i in range(start, end) if lines[i].strip() == '[[profiles.apps]]']
if len(marks) < 2:
    print('Fewer than two apps — nothing to reorder.'); sys.exit(2)

head     = lines[:start]
preamble = lines[start:marks[0]]
tail     = lines[end:]
blocks   = [lines[s:(marks[k+1] if k+1 < len(marks) else end)]
            for k, s in enumerate(marks)]

def title_of(b):
    for l in b:
        m = re.match(r"\s*title = '(.*)'\s*$", l)
        if m:
            return m.group(1)
    return '(untitled)'

titles = [title_of(b) for b in blocks]
print('\nCurrent Moonlight order:')
for i, t in enumerate(titles, 1):
    print('  %d. %s' % (i, t))
print('\nType the new order as space-separated numbers (each once).')
print('Example: 3 1 2%s   — blank line cancels.'
      % (''.join(' %d' % n for n in range(4, len(blocks) + 1))))

tty = open('/dev/tty')
sys.stdout.write('New order: '); sys.stdout.flush()
resp = tty.readline().strip()
if not resp:
    print('Cancelled — nothing changed.'); sys.exit(2)
try:
    order = [int(x) for x in resp.split()]
except ValueError:
    print('Invalid input — expected numbers.'); sys.exit(2)
if sorted(order) != list(range(1, len(blocks) + 1)):
    print('Must list each number 1..%d exactly once.' % len(blocks)); sys.exit(2)

out = head + preamble
for n in order:
    out += blocks[n - 1]
out += tail
with open(cfg, 'w') as f:
    f.writelines(out)
print('\nNew order: ' + ' -> '.join(titles[n - 1] for n in order))
sys.exit(0)
PYEOF
        if [ $? -eq 0 ]; then
            docker compose restart wolf
            echo "Wolf restarted — the new tile order shows on next Moonlight connection."
        fi
        ;;
    add-web)
        # Add a Moonlight tile that opens a URL in a Firefox kiosk streaming container.
        # Usage: ./manage.sh add-web [name] [url]
        if [ ! -f "$WOLF_CFG" ]; then
            echo "Wolf config not found at $WOLF_CFG — start Wolf once first."
            exit 1
        fi

        # Gather display name
        WEB_TITLE="${2:-}"
        if [ -z "$WEB_TITLE" ]; then
            read -r -p "  Display name (e.g. 'Dinosaur Game'): " WEB_TITLE
        fi
        WEB_TITLE="${WEB_TITLE:-Web App}"

        # Gather URL
        WEB_URL="${3:-}"
        if [ -z "$WEB_URL" ]; then
            read -r -p "  URL (e.g. https://dinosaur-game.io/): " WEB_URL
        fi
        if [ -z "$WEB_URL" ]; then echo "No URL entered."; exit 1; fi
        # Prepend https:// if no scheme given
        [[ "$WEB_URL" =~ ^https?:// ]] || WEB_URL="https://$WEB_URL"

        # Try to auto-detect an icon
        WEB_DOMAIN=$(python3 -c "from urllib.parse import urlparse; u=urlparse('$WEB_URL'); print(u.scheme+'://'+u.netloc)" 2>/dev/null)
        WEB_ICON=""
        echo "  Looking for icon at $WEB_DOMAIN..."
        for _try_icon in \
            "$WEB_DOMAIN/apple-touch-icon.png" \
            "$WEB_DOMAIN/apple-touch-icon-precomposed.png" \
            "$WEB_DOMAIN/icon.png" \
            "$WEB_DOMAIN/favicon.png"; do
            if curl -fsSL --max-time 5 -o /dev/null -w "%{http_code}" "$_try_icon" 2>/dev/null \
               | grep -q "^2"; then
                WEB_ICON="$_try_icon"
                echo "  Found icon: $WEB_ICON"
                break
            fi
        done
        if [ -z "$WEB_ICON" ]; then
            echo "  Could not auto-detect a PNG icon."
            echo "  Options:"
            echo "    1) Enter an image URL (PNG)"
            echo "    2) Enter a local PNG file path"
            echo "    3) Use default browser icon"
            read -r -p "  Choice [3]: " _ICON_CHOICE
            _ICON_CHOICE="${_ICON_CHOICE:-3}"
            if [ "$_ICON_CHOICE" = "1" ]; then
                read -r -p "  Image URL: " WEB_ICON
            elif [ "$_ICON_CHOICE" = "2" ]; then
                read -r -p "  Local PNG path: " _LOCAL_PNG
                _LOCAL_PNG="${_LOCAL_PNG/#\~/$HOME}"
                if [ -f "$_LOCAL_PNG" ]; then
                    # Copy to wolf state dir so Wolf can find it
                    _ICONS_DIR="${WOLF_STATE_DIR:-/etc/wolf}/cfg/icons"
                    sudo mkdir -p "$_ICONS_DIR"
                    _ICON_NAME="$(basename "$_LOCAL_PNG")"
                    sudo cp "$_LOCAL_PNG" "$_ICONS_DIR/$_ICON_NAME"
                    WEB_ICON="$_ICONS_DIR/$_ICON_NAME"
                else
                    echo "  File not found — using default icon."
                fi
            fi
        fi
        [ -z "$WEB_ICON" ] && \
            WEB_ICON="https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png"

        # Sanitize title → WolfWeb-<CamelCase>
        WOLF_WEB_NAME="WolfWeb-$(echo "$WEB_TITLE" | tr -s ' \t' '-' | tr -cd 'A-Za-z0-9-')"

        # The GoW firefox image launches `firefox` with no URL and honors no
        # START_URL env var — it reads a Firefox enterprise policy file at
        # /etc/firefox/policies/policies.json. Generate a per-app policy that
        # sets the homepage to our URL and mount it into the container so the
        # tile opens that site on launch instead of a blank default tab.
        WEBAPP_DIR="${WOLF_STATE_DIR:-/etc/wolf}/cfg/webapps/$WOLF_WEB_NAME"
        sudo mkdir -p "$WEBAPP_DIR"
        sudo tee "$WEBAPP_DIR/policies.json" >/dev/null << JSON
{
  "policies": {
    "Homepage": { "URL": "$WEB_URL", "StartPage": "homepage", "Locked": false },
    "OverrideFirstRunPage": "",
    "OverridePostUpdatePage": "",
    "DisableAppUpdate": true,
    "DisableTelemetry": true,
    "Preferences": {
      "gfx.webrender.all": { "Value": true, "Status": "default" },
      "webgl.force-enabled": { "Value": true, "Status": "default" }
    }
  }
}
JSON

        echo ""
        echo "  Adding Moonlight tile:"
        echo "    Title : $WEB_TITLE"
        echo "    URL   : $WEB_URL"
        echo "    Icon  : $WEB_ICON"
        echo "    Name  : $WOLF_WEB_NAME"
        echo ""

        sudo python3 - "$WOLF_CFG" "$WOLF_WEB_NAME" "$WEB_TITLE" "$WEB_ICON" "$WEBAPP_DIR/policies.json" << 'PYEOF'
import sys, json, re

cfg          = sys.argv[1]
wolf_name    = sys.argv[2]
title        = sys.argv[3]
icon         = sys.argv[4]
policies     = sys.argv[5]   # host path to the per-app firefox policies.json

STD_RULES = ['c 13:* rmw', 'c 244:* rmw']
cap_add   = ['NET_RAW', 'MKNOD', 'NET_ADMIN']
env       = [
    'MOZ_ENABLE_WAYLAND=1',
    'RUN_SWAY=1',
    'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*',
]
# Mount our policy file over the image's default so Firefox opens the homepage.
mounts    = [f'{policies}:/etc/firefox/policies/policies.json:ro']
host_cfg = {
    'IpcMode': 'host',
    'CapAdd': cap_add,
    'Privileged': False,
    'DeviceCgroupRules': STD_RULES,
}
create_json = json.dumps({'HostConfig': host_cfg}, indent=2)
env_str     = str(env).replace('"', "'")
mounts_str  = str(mounts).replace('"', "'")

block = (
    f"\n"
    f"    [[profiles.apps]]\n"
    f"    icon_png_path = '{icon}'\n"
    f"    start_virtual_compositor = true\n"
    f"    title = '{title}'\n"
    f"\n"
    f"        [profiles.apps.runner]\n"
    f"        base_create_json = '''{create_json}\n"
    f"'''\n"
    f"        devices = []\n"
    f"        env = {env_str}\n"
    f"        image = 'ghcr.io/games-on-whales/firefox:edge'\n"
    f"        mounts = {mounts_str}\n"
    f"        name = '{wolf_name}'\n"
    f"        ports = []\n"
    f"        type = 'docker'\n"
)

with open(cfg) as f:
    lines = f.readlines()

# If a tile with this name already exists, remove its whole [[profiles.apps]]
# block first so re-running add-web replaces it (e.g. to fix the URL/mounts).
def remove_existing(lines, wolf_name):
    name_idx = next((i for i, l in enumerate(lines)
                     if f"name = '{wolf_name}'" in l), None)
    if name_idx is None:
        return lines, False
    # Start of this app block = nearest [[profiles.apps]] at/above the name line
    start = name_idx
    while start > 0 and lines[start].strip() != '[[profiles.apps]]':
        start -= 1
    # End = next app/profiles marker after the name line, else EOF
    end = name_idx + 1
    while end < len(lines) and lines[end].strip() not in ('[[profiles.apps]]', '[[profiles]]'):
        end += 1
    del lines[start:end]
    return lines, True

lines, replaced = remove_existing(lines, wolf_name)

# Find insert point: just before the second [[profiles]] block, or end of file
profiles_seen, insert_at = 0, len(lines)
for i, line in enumerate(lines):
    if line.strip() == '[[profiles]]':
        profiles_seen += 1
        if profiles_seen == 2:
            insert_at = i
            break

block_lines = [l + '\n' if not l.endswith('\n') else l for l in block.splitlines()]
new_lines   = lines[:insert_at] + block_lines + lines[insert_at:]
with open(cfg, 'w') as f:
    f.writelines(new_lines)
action = 'Replaced' if replaced else 'Added'
print(f"{action} '{title}' ({wolf_name}) — tile updates in Moonlight after Wolf restarts.")
sys.exit(0)
PYEOF
        if [ $? -eq 0 ]; then
            docker compose restart wolf
            echo "Wolf restarted — '$WEB_TITLE' will appear in Moonlight on next connection."
            echo ""
            echo "  Controller tip: Wolf injects a virtual gamepad into the streaming container."
            echo "  Sites that use the browser Gamepad API (many classic arcade ports, etc.)"
            echo "  will respond to your controller. Keyboard-driven sites won't respond to"
            echo "  gamepad buttons directly, but Wolf's virtual keyboard lets you type."
        fi
        ;;
    backup)
        echo "Set up backups with the modular system:  sudo ./setup.sh backup"
        ;;
    ge-proton)
        # Install the latest GloriousEggroll Proton-GE build into Steam's
        # compatibilitytools.d so it appears in each game's Compatibility
        # dropdown. GE-Proton ships fixes (notably for the EA App installer)
        # that stock Proton / Proton Experimental lack — required to get EA
        # titles like Star Wars Battlefront II (2017) past their install script.
        STEAM_HOME=$(find "${WOLF_STATE_DIR:-/etc/wolf}" -maxdepth 2 -type d -name Steam 2>/dev/null | head -1)
        if [ -z "$STEAM_HOME" ]; then
            echo "No Steam home found yet under ${WOLF_STATE_DIR:-/etc/wolf}."
            echo "Launch Steam once from Moonlight, then re-run: ./manage.sh ge-proton"
            exit 1
        fi
        # Steam scans ~/.steam/root/compatibilitytools.d, which resolves to
        # <Steam home>/.steam/compatibilitytools.d on disk.
        COMPAT="$STEAM_HOME/.steam/compatibilitytools.d"
        # Check for a pre-downloaded cache (populated by wolf.sh at install time).
        CACHE_DIR="$SCRIPT_DIR/ge-proton-cache"
        CACHED_VER=""
        [ -f "$CACHE_DIR/.version" ] && CACHED_VER=$(cat "$CACHE_DIR/.version")

        if [ -n "$2" ]; then
            # Explicit version requested — use cache if it matches, else download.
            NAME="$2"
            CACHED_FILE="$CACHE_DIR/$NAME.tar.gz"
        elif [ -n "$CACHED_VER" ] && [ -f "$CACHE_DIR/$CACHED_VER.tar.gz" ]; then
            NAME="$CACHED_VER"
            CACHED_FILE="$CACHE_DIR/$NAME.tar.gz"
            echo "Using pre-downloaded GE-Proton: $NAME"
        else
            echo "Fetching latest GE-Proton release info..."
            URL=$(curl -sL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
                  | grep browser_download_url | grep '\.tar\.gz' | cut -d'"' -f4)
            if [ -z "$URL" ]; then
                echo "Could not determine GE-Proton download URL (GitHub rate-limited or offline?)."
                exit 1
            fi
            NAME=$(basename "$URL" .tar.gz)
            CACHED_FILE=""
        fi

        if [ -d "$COMPAT/$NAME" ]; then
            echo "$NAME already installed."
        else
            sudo mkdir -p "$COMPAT"
            if [ -n "$CACHED_FILE" ] && [ -f "$CACHED_FILE" ]; then
                echo "Extracting $NAME from cache..."
                sudo tar -xzf "$CACHED_FILE" -C "$COMPAT"
            else
                URL="${URL:-https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$NAME/$NAME.tar.gz}"
                echo "Downloading $NAME (~500 MB)..."
                TMP=$(mktemp -d)
                if ! curl -L -o "$TMP/ge.tar.gz" "$URL"; then
                    echo "Download failed."; rm -rf "$TMP"; exit 1
                fi
                sudo tar -xzf "$TMP/ge.tar.gz" -C "$COMPAT"
                rm -rf "$TMP"
            fi
        fi
        # Wolf's app containers run as uid 1000 (retro). The compat tool must be
        # owned by that user or Wine refuses to use it / Steam can't launch it.
        sudo chown -R 1000:1000 "$COMPAT"
        echo ""
        echo "Installed: $COMPAT/$NAME"
        echo "Now fully quit and reopen Steam in Moonlight, then per game:"
        echo "  Properties → Compatibility → Force the use of $NAME"
        ;;
    games)
        # List installed Steam games (numbered) with their AppIDs, then offer to
        # apply the EA App install-script fix to whichever one you pick. Read
        # straight from the Steam app manifests.
        STEAM_HOME=$(_steam_home)
        APPSDIR="$STEAM_HOME/.steam/steam/steamapps"
        if [ ! -d "$APPSDIR" ]; then
            echo "No Steam library found yet. Launch Steam and install a game first."
            exit 1
        fi
        shopt -s nullglob
        ids=(); names=(); n=0
        for acf in "$APPSDIR"/appmanifest_*.acf; do
            id=$(grep -oP '"appid"\s*"\K[0-9]+' "$acf" | head -1)
            name=$(grep -oP '"name"\s*"\K[^"]+' "$acf" | head -1)
            [ -z "$id" ] && continue
            n=$((n+1))
            ids+=("$id"); names+=("$name")
        done
        if [ "$n" = 0 ]; then
            echo "  (no games installed yet)"
            exit 0
        fi
        printf "  %-4s %-10s  %s\n" "#" "AppID" "Name"
        printf "  %-4s %-10s  %s\n" "-" "-----" "----"
        for i in $(seq 1 "$n"); do
            printf "  %-4s %-10s  %s\n" "$i" "${ids[$((i-1))]}" "${names[$((i-1))]}"
        done
        echo ""
        echo "An EA game stuck on 'running install script (EA app)'? Enter its"
        echo "number to apply the EA fix, or just press Enter to skip."
        read -r -p "  Apply EA fix to # (or Enter to skip): " pick
        if [ -z "$pick" ]; then
            exit 0
        fi
        if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "$n" ]; then
            echo "Not a valid number from the list."
            exit 1
        fi
        sel_id="${ids[$((pick-1))]}"
        sel_name="${names[$((pick-1))]}"
        echo "Applying EA fix to '$sel_name' (AppID $sel_id)..."
        _apply_ea_fix "$sel_id"
        ;;
    fix-ea-game)
        # Apply the EA App install-script fix directly to an AppID (defaults to
        # Star Wars Battlefront II 2017, AppID 1237950). For an interactive
        # picker use './manage.sh games' instead. Run AFTER setting the game to
        # GE-Proton and clicking Play once (so the Proton prefix exists).
        _apply_ea_fix "${2:-1237950}"
        ;;
    wait-ea-app)
        # Wait for EAappInstaller to finish installing EA App in the background
        # (it runs async via RunType=1 in installScript.vdf), then apply the full
        # EA fix including the link2ea:// protocol handler registration.
        #
        # Usage: ./manage.sh wait-ea-app [AppID]
        #
        # Flow:
        #   1. Click Play on the game in Steam — SWBF2 will launch and quit after ~6s
        #   2. EAappInstaller is now running in the background inside the container
        #   3. Run this command — it polls every 15s for EADesktop.exe to appear
        #   4. Once found, it stops the container, patches the registry, restarts
        _wea_appid="${2:-1237950}"
        _wea_steam_home=$(_steam_home)
        _wea_pfx="$_wea_steam_home/.steam/steam/steamapps/compatdata/$_wea_appid/pfx/drive_c"
        echo "Watching for EA App (EADesktop.exe) to appear in AppID $_wea_appid prefix..."
        echo "If you haven't yet: go to Steam → click Play on the game now."
        echo "Press Ctrl+C to abort."
        _wea_found=0
        for _wea_i in $(seq 1 80); do
            _wea_exe=$(sudo find "$_wea_pfx" -maxdepth 6 \
                -ipath "*/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe" \
                -print -quit 2>/dev/null)
            if [ -n "$_wea_exe" ]; then
                _wea_found=1
                echo ""
                echo "EA App found at: $_wea_exe"
                break
            fi
            printf "\r  Waiting... (%ds elapsed)" "$((_wea_i * 15))"
            sleep 15
        done
        if [ "$_wea_found" = 0 ]; then
            echo ""
            echo "EA App did not appear after 20 minutes. Things to check:"
            echo "  • Did you click Play in Steam while Wolf was running?"
            echo "  • Is the WolfSteam container still up? (./manage.sh status)"
            echo "  • Check container logs: docker logs \$(docker ps --format '{{.Names}}' | grep WolfSteam | head -1)"
            exit 1
        fi
        echo "Applying full EA fix (includes link2ea:// handler)..."
        _apply_ea_fix "$_wea_appid"
        ;;
    install-ea-app)
        # Run EAappInstaller.exe INSIDE the WolfSteam container using GE-Proton's
        # wine binary so it sees a virtual display and can complete its GUI.
        #
        # Usage: ./manage.sh install-ea-app [AppID]
        #
        # Workflow:
        #   1. Start Wolf and open Steam in Moonlight: ./manage.sh start
        #   2. From a terminal/SSH: ./manage.sh install-ea-app
        #   3. Watch Moonlight — the EA App installer window appears; click through it
        #   4. Log in to your EA account when prompted
        #   5. After EA App installs, run: ./manage.sh fix-ea-game
        #   6. Click Play on the game — it should launch via EA App now
        _ia_appid="${2:-1237950}"
        _ia_steam_home=$(_steam_home)
        if [ -z "$_ia_steam_home" ]; then
            echo "No Steam home found. Start Wolf and open the Steam app in Moonlight first."
            exit 1
        fi
        _ia_container=$(docker ps --format '{{.Names}}' | grep -i WolfSteam | head -1)
        if [ -z "$_ia_container" ]; then
            echo "WolfSteam container is not running."
            echo "  Start Wolf: ./manage.sh start"
            echo "  Open the Steam app in Moonlight, wait for Steam to load, then re-run."
            exit 1
        fi
        # Find EAappInstaller bundled with the game (in steamapps/common, NOT in
        # compatdata — ignore temp-extracted copies inside the Wine prefix).
        _ia_installer_host=$(sudo find \
            "$_ia_steam_home/.steam/steam/steamapps/common" -maxdepth 12 \
            -name "EAappInstaller.exe" -print -quit 2>/dev/null)
        if [ -z "$_ia_installer_host" ]; then
            echo "EAappInstaller.exe not found under steamapps/common."
            echo "Make sure the game (AppID $_ia_appid) is fully downloaded/installed."
            exit 1
        fi
        # Container mounts the session home at /home/retro — translate paths
        _ia_installer_container="${_ia_installer_host/#$_ia_steam_home//home/retro}"
        # Find GE-Proton inside the container
        _ia_gep=$(docker exec -u 1000 "$_ia_container" bash -c \
            'ls /home/retro/.steam/compatibilitytools.d/ 2>/dev/null | grep -i GE-Proton | sort -V | tail -1' 2>/dev/null)
        if [ -z "$_ia_gep" ]; then
            echo "GE-Proton not found inside the container."
            echo "  Install it: ./manage.sh ge-proton"
            echo "  Then open Steam in Moonlight, set the game to use GE-Proton in Compatibility,"
            echo "  click Play once to create the prefix, and re-run this command."
            exit 1
        fi
        _ia_wine="/home/retro/.steam/compatibilitytools.d/$_ia_gep/files/bin/wine"
        _ia_wineprefix="/home/retro/.steam/steam/steamapps/compatdata/$_ia_appid/pfx"
        _ia_display=$(docker exec "$_ia_container" printenv DISPLAY 2>/dev/null)
        _ia_display="${_ia_display:-:0}"
        echo "Installing EA App inside the WolfSteam container..."
        echo "  Container:  $_ia_container"
        echo "  GE-Proton:  $_ia_gep"
        echo "  Installer:  $_ia_installer_container"
        echo "  Display:    $_ia_display"
        echo ""
        echo "IMPORTANT: The EA App installer window will appear in Moonlight."
        echo "           Click through it and log in to your EA account."
        echo "           This may take 2-10 minutes."
        echo ""
        # Remove the fake InstallSuccessful keys we added earlier with fix-ea-game.
        # If those keys are present, EAappInstaller detects EA App is "already installed"
        # and exits immediately without doing anything — this is why it exited in ~15s.
        # The real EA App installer will re-create these keys correctly after install.
        echo "Clearing fake InstallSuccessful registry markers (so the installer actually runs)..."
        for _ia_key in \
            "HKLM\\\\Software\\\\Electronic Arts\\\\EA Desktop" \
            "HKLM\\\\Software\\\\Wow6432Node\\\\Electronic Arts\\\\EA Desktop"; do
            docker exec -u 1000 \
                -e DISPLAY="$_ia_display" \
                -e WINEPREFIX="$_ia_wineprefix" \
                "$_ia_container" \
                "$_ia_wine" reg delete "$_ia_key" /v InstallSuccessful /f 2>/dev/null || true
        done
        sleep 1
        # Start wineserver in foreground mode (-f) so it keeps running even after
        # the WiX bootstrapper exits. Without this, wineserver shuts down when
        # the foreground wine process exits and kills the real installer.
        # wineserver -f stays alive until explicitly killed with wineserver -k.
        _ia_wineserver="${_ia_wine%/wine}/wineserver"
        echo "Starting wineserver anchor (keeps Wine alive while installer runs)..."
        docker exec -d -u 1000 \
            -e DISPLAY="$_ia_display" \
            -e WINEPREFIX="$_ia_wineprefix" \
            "$_ia_container" \
            "$_ia_wineserver" -f
        sleep 3

        # Launch the installer detached — it will spawn background processes
        # and exit, but those processes stay alive because the anchor above
        # keeps the shared wineserver running.
        echo "Launching EA App installer (watch Moonlight for the install window)..."
        docker exec -d -u 1000 \
            -e DISPLAY="$_ia_display" \
            -e WINEPREFIX="$_ia_wineprefix" \
            -e WINE_LARGE_ADDRESS_AWARE=1 \
            "$_ia_container" \
            "$_ia_wine" "$_ia_installer_container"

        # Poll on the HOST for EADesktop.exe to appear (up to 15 min)
        _ia_pfx_host="$_ia_steam_home/.steam/steam/steamapps/compatdata/$_ia_appid/pfx/drive_c"
        _ia_found=0
        for _ia_i in $(seq 1 60); do
            _ia_exe=$(sudo find "$_ia_pfx_host" -maxdepth 8 \
                -ipath "*/Electronic Arts/EA Desktop/EA Desktop/EADesktop.exe" \
                -print -quit 2>/dev/null)
            if [ -n "$_ia_exe" ]; then
                _ia_found=1
                echo ""
                echo "EA App installed at: $_ia_exe"
                break
            fi
            printf "\r  Waiting for EA App to install... (%ds elapsed)" "$((_ia_i * 15))"
            sleep 15
        done

        # Kill the anchor (and any remaining wine processes for this prefix)
        echo "Stopping wineserver anchor..."
        docker exec -u 1000 \
            -e WINEPREFIX="$_ia_wineprefix" \
            "$_ia_container" \
            "$_ia_wineserver" -k 2>/dev/null || true
        if [ "$_ia_found" = 1 ]; then
            echo "Applying EA fix (registering link2ea:// handler)..."
            _apply_ea_fix "$_ia_appid"
            echo ""
            echo "Next: Click Play on the game in Steam. EA App should authenticate and launch it."
        else
            echo ""
            echo "EA App did not finish installing within 15 minutes."
            echo "  • Did the installer window appear in Moonlight?"
            echo "  • Try running ./manage.sh diagnose-ea $_ia_appid for current state"
            echo "  • If the installer appeared but failed: check the EA App website for a newer installer"
            exit 1
        fi
        ;;
    diagnose-ea)
        # Show the current state of the EA App / link2ea:// setup for debugging.
        # Run this after ./manage.sh fix-ea-game to verify the registry is correct,
        # or when troubleshooting why an EA game returns to the Play screen.
        #
        # Usage: ./manage.sh diagnose-ea [AppID]
        _dx_appid="${2:-1237950}"
        _dx_sh=$(_steam_home)
        _dx_pfx="$_dx_sh/.steam/steam/steamapps/compatdata/$_dx_appid/pfx"
        _dx_acf="$_dx_sh/.steam/steam/steamapps/appmanifest_${_dx_appid}.acf"
        echo "=== EA Diagnostic — AppID $_dx_appid ==="
        echo "Prefix: $_dx_pfx"
        echo ""
        echo "--- system.reg: link2ea entries ---"
        sudo grep -i -A3 "link2ea" "$_dx_pfx/system.reg" 2>/dev/null || echo "(none in system.reg)"
        echo ""
        echo "--- user.reg: link2ea entries ---"
        sudo grep -i -A3 "link2ea" "$_dx_pfx/user.reg" 2>/dev/null || echo "(none in user.reg)"
        echo ""
        echo "--- EA App executables in prefix ---"
        _dx_desktop=$(sudo find "$_dx_pfx/drive_c" -maxdepth 8 -iname "EADesktop.exe" -print 2>/dev/null)
        _dx_link2ea=$(sudo find "$_dx_pfx/drive_c" -maxdepth 8 -iname "Link2EA.exe" -print 2>/dev/null)
        echo "EADesktop.exe: ${_dx_desktop:-(not found)}"
        echo "Link2EA.exe:   ${_dx_link2ea:-(not found)}"
        echo ""
        echo "--- system.reg: InstallSuccessful ---"
        sudo grep -i "InstallSuccessful" "$_dx_pfx/system.reg" 2>/dev/null | head -5 \
            || echo "(none)"
        echo ""
        echo "--- AppManifest StateFlags ---"
        if [ -f "$_dx_acf" ]; then
            grep "StateFlags" "$_dx_acf"
        else
            echo "(acf not found at $_dx_acf)"
        fi
        echo ""
        echo "--- Recent Proton log entries (errors + EA-related) ---"
        _dx_log="$_dx_sh/steam-${_dx_appid}.log"
        if [ -f "$_dx_log" ]; then
            grep -i "link2ea\|EA Desktop\|run_process\|ShellExecute\|err:" "$_dx_log" 2>/dev/null \
                | grep -v "mscoree\|seh_unwind\|loaddll\|fixme" | tail -20
        else
            echo "(no log yet — launch the game once to generate it)"
            echo "Expected path: $_dx_log"
        fi
        ;;
    fix-perms)
        # Wolf creates each app's home dir under WOLF_STATE_DIR/<session-id>/<App>
        # and mounts it as /home/retro inside the app container. If anything in
        # there ends up root-owned, the in-container 'retro' user (uid 1000)
        # can't write to it and the app bails on startup with "Permission
        # denied". Re-own the whole state folder + game storage to uid/gid 1000.
        echo "Fixing ownership of Wolf state + game storage (uid 1000)..."
        found=0
        if [ -n "$WOLF_STATE_DIR" ] && [ -d "$WOLF_STATE_DIR" ]; then
            sudo chown -R 1000:1000 "$WOLF_STATE_DIR"
            echo "  fixed: $WOLF_STATE_DIR"
            found=1
        fi
        GAME_DIR=$(grep '^GAME_STORAGE_DIR=' "$SCRIPT_DIR/.env" 2>/dev/null | cut -d= -f2-)
        if [ -n "$GAME_DIR" ] && [ -d "$GAME_DIR" ]; then
            sudo chown -R 1000:1000 "$GAME_DIR"
            echo "  fixed: $GAME_DIR"
            found=1
        fi
        [ "$found" = 0 ] && echo "  Nothing to fix (no Wolf state dir found yet)."
        echo "Done. Reconnect from Moonlight to relaunch the app."
        ;;
    install-completion)
        # Install bash tab-completion for this manage.sh so that double-tab
        # after './manage.sh ' shows all available commands. Works for any
        # user whose shell sources ~/.bash_completion.d/ (most modern setups
        # do; Ubuntu 22.04+ sources it automatically via /etc/bash.bashrc).
        COMP_DIR="$HOME/.bash_completion.d"
        COMP_FILE="$COMP_DIR/manage-wolf"
        mkdir -p "$COMP_DIR"
        cat > "$COMP_FILE" << 'COMPEOF'
_manage_wolf_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local commands="start stop restart logs status pin update apps reorder
                    add-web ge-proton games fix-ea-game wait-ea-app
                    install-ea-app diagnose-ea fix-perms install-completion backup"
    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
}
# Register for both 'manage.sh' and './manage.sh' invocation styles
complete -F _manage_wolf_complete manage.sh
complete -F _manage_wolf_complete ./manage.sh
COMPEOF
        # Also source it immediately in the current shell if possible
        echo "source \"$COMP_FILE\"" >> "$HOME/.bash_completion" 2>/dev/null || true
        echo "Bash completion installed → $COMP_FILE"
        echo "Open a new terminal (or run: source \"$COMP_FILE\"), then:"
        echo "  ./manage.sh <TAB><TAB>  shows all commands"
        ;;
    pin)
        # Wolf logs: "Insert pin at http://SOMEIP:47989/pin/#HEXHASH"
        # Extract just the hash fragment and build URLs for every interface
        # so it works whether you're on LAN, VPN, or any other network.
        HASH=$(docker compose logs wolf 2>&1 | grep "Insert pin at" | tail -1 \
               | grep -oP '#[A-Fa-f0-9]+')
        if [ -z "$HASH" ]; then
            echo ""
            echo "  No pairing request found."
            echo "  Open Moonlight, add this server by IP, and a PIN URL will appear here."
            echo ""
        else
            # Collect all non-loopback IPv4 addresses
            ALL_IPS=$(ip -4 addr show | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+(?=/)' \
                      | grep -v '^127\.')
            echo ""
            echo "  Moonlight is showing a 4-digit PIN."
            echo "  Open ONE of these URLs in a browser and enter that PIN:"
            echo ""
            while IFS= read -r ip; do
                IFACE=$(ip -4 addr show | grep -B2 "inet $ip/" | grep -oP '^\d+: \K\S+(?=:)' | head -1)
                echo "    http://$ip:47989/pin/$HASH   ($IFACE)"
            done <<< "$ALL_IPS"
            echo ""
            echo "  Use the URL matching whichever network Moonlight is on."
            echo "  (LAN IP for local, VPN/mesh IP for remote)"
            echo ""
        fi
        ;;
    *)
        echo "Wolf Cloud Gaming"
        echo "  ./manage.sh start                        - Start Wolf"
        echo "  ./manage.sh stop                         - Stop Wolf"
        echo "  ./manage.sh restart                      - Restart Wolf"
        echo "  ./manage.sh logs                         - Follow Wolf logs"
        echo "  ./manage.sh status                       - Show Wolf + app containers"
        echo "  ./manage.sh pin                          - Show recent Moonlight pairing PIN link"
        echo "  ./manage.sh update                       - Pull latest Wolf image and restart"
        echo "  ./manage.sh apps                         - Add / update game launchers in Wolf"
        echo "  ./manage.sh reorder                      - Reorder the Moonlight tile list"
        echo "  ./manage.sh add-web [name] [url]         - Add a URL shortcut tile (Firefox kiosk)"
        echo "  ./manage.sh ge-proton [version]          - Install GE-Proton (latest, or pin a version)"
        echo "  ./manage.sh games                        - List games; pick one to apply the EA fix"
        echo "  ./manage.sh fix-ea-game [appid]          - Apply EA fix directly (default: SWBF2 1237950)"
        echo "  ./manage.sh wait-ea-app [appid]          - Watch for EA App to install, then register link2ea:// handler"
        echo "  ./manage.sh install-ea-app [appid]       - Run EA App installer inside container (GUI appears in Moonlight)"
        echo "  ./manage.sh diagnose-ea [appid]          - Show link2ea:// registry state and Proton log"
        echo "  ./manage.sh fix-perms                    - Fix 'Permission denied' app startup errors"
        echo "  ./manage.sh install-completion           - Enable tab-completion for this script"
        echo "  ./manage.sh backup                       - How to set up backups"
        ;;
esac
MEOF
    chmod +x manage.sh

    # ── Start Wolf ────────────────────────────────────────────────────────────
    echo ""
    log_info "Starting Wolf (first start pulls the image — give it a minute)..."
    docker compose up -d

    # Wolf writes $WOLF_CFG (on the game drive) on first start. Wait for it,
    # then wire in game storage.
    log_info "Waiting for Wolf to generate config.toml at $WOLF_CFG..."
    local _i
    for _i in $(seq 1 30); do
        [ -f "$WOLF_CFG" ] && break
        sleep 2
    done

    if [ -f "$WOLF_CFG" ]; then
        log_info "Injecting selected apps into Wolf config..."
        python3 - "$GAME_STORAGE_DIR" "$WOLF_CFG" "$SITE_TZ" $([[ -n "$_APP_KEYS" ]] && echo "$_APP_KEYS" || echo "steam esde") << 'PYEOF'
import sys, json

games    = sys.argv[1].rstrip('/')
cfg      = sys.argv[2]
TZ       = sys.argv[3].strip()
selected = set(sys.argv[4:])   # app keys chosen by the user

# ── App catalog ───────────────────────────────────────────────────────────────
# Each entry: (wolf_name, title, icon_url, image, mounts, env, cap_add,
#              security_opt, ipc_mode, ulimits, privileged)
STD_CAP   = ['NET_RAW', 'MKNOD', 'NET_ADMIN']
STD_ENV   = ['RUN_SWAY=1', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*']
STD_RULES = ['c 13:* rmw', 'c 244:* rmw']

CATALOG = {
    'steam': dict(
        name='WolfSteam', title='Steam',
        icon='https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png',
        image='ghcr.io/games-on-whales/steam:edge',
        mounts=['/etc/localtime:/etc/localtime:ro', '/etc/timezone:/etc/timezone:ro',
                f'{games}/steam-cache:/home/retro/.cache:rw'],
        env=['PROTON_LOG=1', 'RUN_SWAY=true',
             'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*'],
        cap_add=['SYS_ADMIN', 'SYS_NICE', 'SYS_PTRACE', 'NET_RAW', 'MKNOD', 'NET_ADMIN'],
        security_opt=['seccomp=unconfined', 'apparmor=unconfined'],
        ipc_mode='host',
        ulimits=[{'Name': 'nofile', 'Hard': 10240, 'Soft': 10240}],
        privileged=False,
    ),
    'esde': dict(
        name='WolfES-DE', title='EmulationStation',
        icon='https://games-on-whales.github.io/wildlife/apps/es-de/assets/icon.png',
        image='ghcr.io/games-on-whales/es-de:edge',
        mounts=[f'{games}/roms:/ROMs:rw',
                f'{games}/saves:/mnt/games/saves:rw',
                f'{games}/media:/media:rw',
                f'{games}/emulators:/mnt/games/emulators:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'lutris': dict(
        name='WolfLutris', title='Lutris',
        icon='https://games-on-whales.github.io/wildlife/apps/lutris/assets/icon.png',
        image='ghcr.io/games-on-whales/lutris:edge',
        mounts=[f'{games}/lutris:/mnt/games/lutris:rw'],
        env=['RUN_SWAY=true',
             'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*'],
        cap_add=['SYS_ADMIN', 'NET_RAW', 'MKNOD', 'NET_ADMIN'],
        security_opt=['seccomp=unconfined', 'apparmor=unconfined'],
        ipc_mode='host', ulimits=[], privileged=False,
    ),
    'retroarch': dict(
        name='WolfRetroArch', title='RetroArch',
        icon='https://games-on-whales.github.io/wildlife/apps/retroarch/assets/icon.png',
        image='ghcr.io/games-on-whales/retroarch:edge',
        mounts=[f'{games}/roms:/ROMs:rw',
                f'{games}/saves:/mnt/games/saves:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'prismlauncher': dict(
        name='WolfPrismLauncher', title='Prism Launcher',
        icon='https://games-on-whales.github.io/wildlife/apps/prismlauncher/assets/icon.png',
        image='ghcr.io/games-on-whales/prismlauncher:edge',
        mounts=[f'{games}/minecraft:/mnt/games/minecraft:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'kodi': dict(
        name='WolfKodi', title='Kodi',
        icon='https://games-on-whales.github.io/wildlife/apps/kodi/assets/icon.png',
        image='ghcr.io/games-on-whales/kodi:edge',
        mounts=[f'{games}/kodi:/mnt/games/kodi:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'firefox': dict(
        name='WolfFirefox', title='Firefox',
        icon='https://games-on-whales.github.io/wildlife/apps/firefox/assets/icon.png',
        image='ghcr.io/games-on-whales/firefox:edge',
        mounts=[f'{games}/firefox:/mnt/games/firefox:rw'],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
    'desktop': dict(
        name='WolfDesktop', title='Desktop',
        icon='https://games-on-whales.github.io/wildlife/apps/desktop/assets/icon.png',
        image='ghcr.io/games-on-whales/desktop:edge',
        mounts=[],
        env=STD_ENV, cap_add=STD_CAP, security_opt=[], ipc_mode='host',
        ulimits=[], privileged=False,
    ),
}

def ensure_tz(env_list):
    # Set the container timezone so Steam / EA App / games show local time
    # (a wrong/UTC display can confuse EA App's installer). Driven by SITE_TZ.
    e = [x for x in env_list if not x.startswith('TZ=')]
    if TZ:
        e.append(f'TZ={TZ}')
    return e

def make_app_block(app):
    """Render a [[profiles.apps]] TOML block from a catalog entry."""
    host_cfg = {'IpcMode': app['ipc_mode'], 'CapAdd': app['cap_add'],
                'Privileged': app['privileged'], 'DeviceCgroupRules': STD_RULES}
    if app['security_opt']: host_cfg['SecurityOpt'] = app['security_opt']
    if app['ulimits']:       host_cfg['Ulimits'] = app['ulimits']
    create_json = json.dumps({'HostConfig': host_cfg}, indent=2)
    mounts_str  = str(app['mounts']).replace('"', "'")
    env_str     = str(ensure_tz(app['env'])).replace('"', "'")
    return (
        f"\n"
        f"    [[profiles.apps]]\n"
        f"    icon_png_path = '{app['icon']}'\n"
        f"    start_virtual_compositor = true\n"
        f"    title = '{app['title']}'\n"
        f"\n"
        f"        [profiles.apps.runner]\n"
        f"        base_create_json = '''{create_json}\n"
        f"'''\n"
        f"        devices = []\n"
        f"        env = {env_str}\n"
        f"        image = '{app['image']}'\n"
        f"        mounts = {mounts_str}\n"
        f"        name = '{app['name']}'\n"
        f"        ports = []\n"
        f"        type = 'docker'\n"
    )

def update_field(lines, wolf_name, field, new_value):
    # Wolf rewrites config.toml and reformats arrays (mounts/env) as MULTI-LINE,
    # so we must replace the entire array (from `<field> =` to its closing `]`),
    # not just the first line — otherwise the old elements are left orphaned and
    # the file becomes invalid TOML. Always rewrite as a single line, and heal
    # any orphaned remnants left by a previously corrupted single-line rewrite.
    for i, line in enumerate(lines):
        if f"name = '{wolf_name}'" in line:
            for j in range(max(0, i-25), min(len(lines), i+25)):
                if lines[j].lstrip().startswith(field + ' ='):
                    indent = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                    k = j
                    while k < len(lines) and ']' not in lines[k]:
                        k += 1
                    m = k + 1
                    while m < len(lines):
                        s = lines[m].lstrip()
                        if s.startswith("'") or s.startswith(']'):
                            m += 1
                        else:
                            break
                    lines[j:m] = [f"{indent}{field} = {new_value}\n"]
                    return True
    return False

with open(cfg, 'r') as f:
    lines = f.readlines()

profiles_seen, first_start, insert_at = 0, None, len(lines)
for i, line in enumerate(lines):
    if line.strip() == '[[profiles]]':
        profiles_seen += 1
        if profiles_seen == 1: first_start = i
        elif profiles_seen == 2: insert_at = i; break

if first_start is None:
    print('[ERROR] No [[profiles]] section found in config'); sys.exit(1)

first_block = lines[first_start:insert_at]

added, updated = [], []
to_insert = []

for key in list(CATALOG.keys()):   # preserve display order
    if key not in selected:
        continue
    app = CATALOG[key]
    wolf_name = app['name']
    already   = any(f"name = '{wolf_name}'" in l for l in first_block)
    new_mounts = str(app['mounts']).replace('"', "'")
    new_env    = str(ensure_tz(app['env'])).replace('"', "'")
    if already:
        ok = update_field(lines, wolf_name, 'mounts', new_mounts)
        ok = update_field(lines, wolf_name, 'env', new_env) or ok
        if ok:
            updated.append(app['title'])
    else:
        to_insert.append(make_app_block(app))
        added.append(app['title'])

if to_insert:
    block_lines = []
    for block in to_insert:
        block_lines += [l + '\n' if not l.endswith('\n') else l
                        for l in block.splitlines()]
    new_lines = lines[:insert_at] + block_lines + lines[insert_at:]
    with open(cfg, 'w') as f:
        f.writelines(new_lines)
elif updated:
    with open(cfg, 'w') as f:
        f.writelines(lines)

if added:   print(f"[INFO] Added: {', '.join(added)}")
if updated: print(f"[INFO] Updated mounts: {', '.join(updated)}")
if not added and not updated:
    print('[INFO] All selected apps already present and up to date')
PYEOF
        docker compose restart wolf
        log_success "Wolf restarted with updated config"
        # Nothing else to do for Steam storage: Wolf's state folder lives on the
        # game drive, so Steam installs, games, and Proton prefixes land there
        # automatically the first time you connect. No fix-perms, no symlinks.
        if echo "$APP_KEYS" | grep -qw steam; then
            log_success "Steam will install games to $WOLF_STATE_DIR (on the game drive)"
        fi
    else
        log_warning "Wolf config not generated in time. Add apps manually to $WOLF_CFG"
        log_warning "Then run: ./manage.sh apps"
    fi

    # Hand the folder back to the real user
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WOLF_DIR"

    local ALL_IPS
    ALL_IPS=$(ip -4 addr show | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+(?=/)' | grep -v '^127\.')

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "          WOLF IS RUNNING"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Server addresses:"
    while IFS= read -r ip; do
        IFACE=$(ip -4 addr show | grep -B2 "inet $ip/" | grep -oP '^\d+: \K\S+(?=:)' | head -1)
        printf "    %-18s (%s)\n" "$ip" "$IFACE"
    done <<< "$ALL_IPS"
    echo ""
    echo "── PAIRING ──────────────────────────────────────────"
    echo ""
    echo "  1. Install Moonlight on your device:"
    echo "       • Sony Bravia / Google TV → Play Store ('Moonlight Game Streaming')"
    echo "       • Roku TV → plug in a Fire TV / Chromecast / NVIDIA Shield,"
    echo "         install Moonlight there"
    echo "       • Phone / PC / Mac → moonlight-stream.org"
    echo ""
    echo "  2. In Moonlight, add this server by IP:"
    if [ -n "$TS_IP" ]; then
        echo "       Tailscale: $TS_IP  ← use this (Wolf is configured for Tailscale)"
        echo "       LAN:       $LAN_IP  (only works on the local network)"
    else
        echo "       LAN: $LAN_IP"
        echo "       For remote access install Tailscale, then re-run this module."
    fi
    echo ""
    echo "  3. Moonlight shows a 4-digit PIN. On this server run:"
    echo "       cd $WOLF_DIR && ./manage.sh pin"
    echo "     It prints a URL for every interface — open the one matching"
    echo "     whichever network Moonlight is on, then type the PIN."
    echo ""
    echo "  4. First launch of each app downloads its container image."
    echo "     A black screen for ~60 s is normal."
    echo ""
    echo "  Return to launcher:  Ctrl+Alt+Shift+W  or  START+UP+RB (controller)"
    echo ""
    echo "── PAIRING (the ./manage.sh pin workflow) ────────────"
    echo ""
    echo "  Wolf's PIN entry page is served directly by Wolf on port 47989 — no"
    echo "  separate pairing service or reverse proxy is needed. Workflow:"
    echo ""
    echo "    1. Open Moonlight → add server by IP → a 4-digit PIN appears."
    echo "    2. On this server run:  cd $WOLF_DIR && ./manage.sh pin"
    echo "    3. It extracts the pairing URL from 'docker logs wolf' and prints"
    echo "       one link per interface (LAN, Tailscale, etc.)."
    echo "    4. Open the link matching Moonlight's network and type the PIN."
    echo ""
    echo "  NOTE: Moonlight streaming uses direct UDP/TCP to this server's IP"
    echo "  (LAN or VPN). Pairing is just the one-time PIN exchange above."
    echo ""
    echo "── GAME STORAGE ──────────────────────────────────────"
    echo ""
    echo "  ${GAME_STORAGE_DIR}/"
    echo "    roms/    → /ROMs                              (EmulationStation)"
    echo "    saves/   → /home/retro/.config/retroarch/saves (RetroArch saves)"
    echo "    media/   → /media                             (ES-DE scraped artwork)"
    echo "    wolf-state/ → Wolf state: Steam install, games, Proton prefixes,"
    echo "                  ES-DE settings, controller maps, config.toml"
    echo ""
    echo "  Wolf's entire state folder lives on the game drive, so Steam games"
    echo "  and everything else stay off the OS drive automatically."
    echo ""
    echo "── APPS ──────────────────────────────────────────────"
    echo ""
    echo "  • EmulationStation  - ES-DE + RetroArch + Dolphin/PCSX2/Cemu/Ryujinx/more"
    echo "  • Steam             - Big Picture + Proton"
    echo "  • Lutris            - Wine / GOG / Epic / non-Steam"
    echo "  • RetroArch         - standalone, all cores"
    echo "  • Prismlauncher     - Minecraft"
    echo "  • Kodi              - media center"
    echo "  • Firefox / Desktop - browser and full XFCE desktop"
    echo "  • Wolf UI / Pegasus - alternative launchers"
    echo ""
    echo "── MULTIPLAYER ───────────────────────────────────────"
    echo ""
    echo "  Same-screen co-op  → create a LOBBY in Wolf UI; each joiner gets"
    echo "                        their own virtual gamepad (1 stream)"
    echo "  Online together    → each player launches their own session,"
    echo "                        all connect to the same game server"
    echo ""
    echo "Manage:  cd $WOLF_DIR && ./manage.sh {start|stop|restart|logs|status|pin|update|apps|reorder|add-web|ge-proton|fix-ea-game}"
    echo ""
    echo "── EA GAMES (Battlefront II, etc.) ───────────────────"
    echo ""
    echo "  EA titles need GE-Proton + a full EA App install:"
    echo "    1. ./manage.sh ge-proton            # install GE-Proton once"
    echo "    2. In Steam: game → Properties → Compatibility → Force GE-Proton"
    echo "    3. Click Play once (builds the Proton prefix; hang is expected)"
    echo "    4. ./manage.sh install-ea-app       # runs EA App installer in the container"
    echo "       (watch Moonlight — an installer window appears; click through + log in)"
    echo "    5. ./manage.sh fix-ea-game          # unstick the install-script loop"
    echo "    6. Click Play — EA App authenticates and launches the game"
    echo ""
    echo "  Diagnose: ./manage.sh diagnose-ea   # check link2ea:// registry state"
    echo ""
    echo "── BACKUPS ───────────────────────────────────────────"
    echo ""
    echo "  Back up your saves, progress and user data (Wolf's state folder:"
    echo "  ES-DE settings, controller mappings, RetroArch saves/states, emulator"
    echo "  saves, Steam user data). ROMs and game installs are skipped."
    echo ""
    echo "  Set up automatic backups with the backup module:"
    echo "       sudo ./setup.sh backup"
    echo ""
    # Wolf's web UI (pair/manage) has no built-in auth — protect with Authelia if available
    local WOLF_EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Wolf web UI with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && WOLF_EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "Wolf" "wolf:47990" "wolf" "$WOLF_EXTRA_BLOCK"

    write_readme "$WOLF_DIR" << MD
# Wolf — Cloud Gaming

Cloud gaming via Moonlight. Stream any Moonlight-compatible game or app from
this server to any device on your network.
# Wolf — Cloud Gaming (Games-on-Whales)

Stream games to any Moonlight client over your LAN or Tailscale VPN.

## Pair a new client
1. Open Moonlight on the client device
2. Add host: this server's IP
3. Run the pin command on the server:
\`\`\`bash
cd $WOLF_DIR && ./manage.sh pin
\`\`\`

## Manage
\`\`\`bash
cd $WOLF_DIR
./manage.sh start              # start Wolf
./manage.sh stop               # stop
./manage.sh restart            # restart
./manage.sh logs               # live logs
./manage.sh status             # container status
./manage.sh update             # pull latest image and restart
./manage.sh apps               # add / update game launchers
./manage.sh reorder            # reorder the Moonlight tile list
./manage.sh add-web            # add a URL shortcut tile (Firefox kiosk)
./manage.sh ge-proton          # install GE-Proton (needed for EA games)
./manage.sh games              # list installed games + their AppIDs
./manage.sh fix-ea-game        # unstick the EA App install loop for a game
./manage.sh install-ea-app     # install EA App inside the container (GUI in Moonlight)
./manage.sh diagnose-ea        # check link2ea:// state when game returns to Play
./manage.sh install-completion # enable tab-completion for manage.sh
\`\`\`

### Tab completion
Run \`./manage.sh install-completion\` once, then re-open your shell (or
\`source ~/.bashrc\`). After that, \`./manage.sh <TAB><TAB>\` lists all commands.

## EA games (Battlefront II 2017, etc.)
EA titles require GE-Proton and the EA App to be installed inside the Wine
prefix. The EA App handles authentication — without it, the game launches
and immediately returns to the Play screen.

\`\`\`bash
cd $WOLF_DIR
./manage.sh ge-proton           # 1. install GE-Proton once
#                                  2. Steam → game → Properties →
#                                     Compatibility → Force GE-Proton
#                                  3. Click Play once (builds the prefix;
#                                     it will hang — that's expected)
./manage.sh install-ea-app      # 4. runs EA App installer INSIDE the container
#                                     (watch Moonlight — installer GUI appears;
#                                      click through it and log in to EA account)
./manage.sh fix-ea-game         # 5. unstick the install-script loop
#                                  6. Click Play — EA App authenticates + launches
\`\`\`

**Troubleshooting**: If the game returns straight to the Play screen after step 6:
\`\`\`bash
./manage.sh diagnose-ea         # shows link2ea:// registry state + Proton log
\`\`\`

Notes:
- Steam **AppIDs are global** — SWBF2 (2017) is always \`1237950\` on every
  machine — but you don't need to know it; the \`games\` picker handles it.
- \`fix-ea-game\` is idempotent and only touches the game you pick.
- \`ge-proton\` takes an optional version to pin, e.g.
  \`./manage.sh ge-proton GE-Proton10-34\`.

## Ports (open on firewall / router)
| Port(s) | Protocol | Use |
|---------|----------|-----|
| 47984–47990 | TCP | Moonlight control |
| 48010 | TCP | RTSP |
| 47998–48000 | UDP | RTP video/audio/control |

## Storage layout
Two things live on the game drive (\`$GAME_STORAGE_DIR\`):

**1. Shared media folders** — bind-mounted into app containers:
- \`roms/<system>/\` → /ROMs (EmulationStation — drop ROMs here)
- \`saves/\`         → /mnt/games/saves (RetroArch saves & states)
- \`emulators/\`     → /mnt/games/emulators (Azahar 3DS AppImage, etc.)

**2. \`wolf-state/\`** — Wolf's entire state folder (\`WOLF_STATE_DIR\` in
\`.env\`). This is the key to keeping games off the OS drive: it holds
\`cfg/config.toml\` plus every app's session home, including the Steam install,
downloaded games, and Proton prefixes.

## Why games land on the game drive (no config needed)
Wolf stores all app state under \`HOST_APPS_STATE_FOLDER\`. We point that — and
the matching docker-compose volume — at \`wolf-state/\` on the game drive, mounted
at the **same path inside and outside** the wolf container so the app containers
Wolf spawns through the Docker socket resolve it correctly on the host. Because
Steam's home is born on the game drive, its installs, games, and Proton prefixes
go there with nothing to configure — no \`libraryfolders.vdf\` seeding, no
symlinks, no \`fix-perms\` dance.

## 3DS emulation
Azahar (open-source Citra fork) AppImage lives in \`emulators/\` → mounted at
\`/mnt/games/emulators\`. Point ES-DE's 3DS system at it via Alternative
Emulators if it isn't auto-detected. Re-download with:
\`\`\`bash
cd $WOLF_DIR && ./manage.sh apps
\`\`\`

## Troubleshooting: app exits immediately ("Permission denied")
If a launcher (Steam, etc.) closes the moment it opens, its Wolf-managed home
dir has root-owned files the in-container user (uid 1000) can't write. Fix:
\`\`\`bash
cd $WOLF_DIR && ./manage.sh fix-perms
\`\`\`
Then reconnect from Moonlight.

## Backup
\`\`\`bash
sudo ./setup.sh backup   # covers wolf-state/ saves and ES-DE settings
\`\`\`
MD

    # ── Pre-download GE-Proton ────────────────────────────────────────────────
    # GE-Proton is required for EA games (Battlefront II etc.) and needs to be
    # installed into Steam's compatibilitytools.d after first launch. Download
    # the tarball now while we have the user's attention so that
    # './manage.sh ge-proton' later is instant (just extracts from cache).
    log_info "Pre-downloading GE-Proton for EA game support (~500 MB)..."
    (
        CACHE_DIR="$WOLF_DIR/ge-proton-cache"
        mkdir -p "$CACHE_DIR"
        URL=$(curl -sL https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest \
              | grep browser_download_url | grep '\.tar\.gz' | cut -d'"' -f4)
        if [ -z "$URL" ]; then
            log_warning "Could not fetch GE-Proton URL — run './manage.sh ge-proton' later."
        else
            NAME=$(basename "$URL" .tar.gz)
            CACHED="$CACHE_DIR/$NAME.tar.gz"
            if [ -f "$CACHED" ]; then
                log_success "GE-Proton already cached: $NAME"
            elif curl -L -o "$CACHED" "$URL"; then
                echo "$NAME" > "$CACHE_DIR/.version"
                log_success "GE-Proton cached: $NAME"
            else
                log_warning "GE-Proton download failed — run './manage.sh ge-proton' later."
                rm -f "$CACHED"
            fi
        fi
    )

    local START_WOLF=""
    prompt_yn "Start Wolf now? (y/n):" "y" START_WOLF
    if [[ "$START_WOLF" =~ ^[Yy]$ ]]; then
        docker compose up -d \
            && log_success "Wolf started — pair Moonlight to this server's IP" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    log_success "Done. Pair Moonlight and play."
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wolf
