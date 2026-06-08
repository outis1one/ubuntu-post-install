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

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
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

    log_info "Drives on this machine:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v "^loop" | sed 's/^/  /'
    echo ""
    echo "  ROMs, Steam library, and saves will be stored under one directory."
    echo "  Recommended: a larger/secondary drive (HDD) to keep the OS SSD free."
    echo "  The directory will be created if it doesn't exist."
    echo "  If it's on an unmounted drive the script will mount it and add it to fstab."
    echo ""

    local DEFAULT_STORAGE="$ACTUAL_HOME/drives/games" GAME_STORAGE_DIR=""
    prompt_text "  Game storage path [${DEFAULT_STORAGE}]:" "$DEFAULT_STORAGE" GAME_STORAGE_DIR
    GAME_STORAGE_DIR="${GAME_STORAGE_DIR:-$DEFAULT_STORAGE}"
    GAME_STORAGE_DIR="${GAME_STORAGE_DIR/#\~/$ACTUAL_HOME}"

    # Check if the path crosses an unmounted drive
    local _PARENT
    _PARENT=$(dirname "$GAME_STORAGE_DIR")
    if [ ! -d "$_PARENT" ]; then
        log_warning "Parent directory $_PARENT does not exist."
        echo ""
        echo "  If this path is on a separate drive, pick the device to mount:"
        echo ""
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v "^loop" | sed 's/^/  /'
        echo ""
        local RAW_DEV=""
        prompt_text "  Device to mount at ${GAME_STORAGE_DIR%/*} (e.g. sda, sdb1) or Enter to skip:" "" RAW_DEV
        if [ -n "$RAW_DEV" ]; then
            RAW_DEV="${RAW_DEV##/dev/}"
            local DEV="/dev/$RAW_DEV"
            local MOUNT_POINT="${GAME_STORAGE_DIR%/*}"

            if [ -b "$DEV" ]; then
                local PARTITION="${DEV}"
                [[ "$DEV" =~ [0-9]$ ]] || PARTITION="${DEV}1"

                if ! blkid "$PARTITION" &>/dev/null && \
                   ! fdisk -l "$DEV" 2>/dev/null | grep -q "^${PARTITION}"; then
                    log_info "Creating partition on $DEV..."
                    printf 'g\nn\n1\n\n\nw\n' | fdisk "$DEV"
                    partprobe "$DEV"; sleep 2
                fi

                if ! blkid -s TYPE "$PARTITION" 2>/dev/null | grep -q TYPE; then
                    log_info "Formatting ${PARTITION} as ext4..."
                    mkfs.ext4 -F -L "games" "$PARTITION"
                else
                    log_info "${PARTITION} already has a filesystem — keeping data"
                fi

                mkdir -p "$MOUNT_POINT"
                mount "$PARTITION" "$MOUNT_POINT"

                local PART_UUID
                PART_UUID=$(blkid -s UUID -o value "$PARTITION")
                if [ -n "$PART_UUID" ]; then
                    if grep -qs "$PART_UUID" /etc/fstab; then
                        log_info "fstab: UUID=${PART_UUID} already present"
                    else
                        echo "UUID=${PART_UUID}  ${MOUNT_POINT}  ext4  defaults,nofail  0  2" \
                            | tee -a /etc/fstab >/dev/null
                        log_success "fstab: UUID=${PART_UUID} → ${MOUNT_POINT} (nofail, auto-mount on boot)"
                    fi
                else
                    log_warning "Could not read UUID for ${PARTITION} — add /etc/fstab entry manually"
                fi

                chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MOUNT_POINT" 2>/dev/null || true
                log_success "${PARTITION} mounted at ${MOUNT_POINT}"
            else
                log_warning "$DEV not found — continuing, ensure drive is mounted before starting Wolf"
            fi
        fi
    fi

    # Create the storage sub-directories
    mkdir -p "$GAME_STORAGE_DIR/roms" "$GAME_STORAGE_DIR/steam" \
             "$GAME_STORAGE_DIR/saves" "$GAME_STORAGE_DIR/media"
    log_success "Storage layout: $GAME_STORAGE_DIR/{roms,steam,saves,media}"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    log_info "Generating docker-compose.yml..."
    mkdir -p /etc/wolf/cfg
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
      - HOST_APPS_STATE_FOLDER=/etc/wolf
      - WOLF_INTERNAL_IP=${WOLF_IP}
      - WOLF_INTERNAL_MAC=${WOLF_MAC}
      - WOLF_RENDER_NODE=${WOLF_RENDER_NODE}
      - LD_LIBRARY_PATH=/usr/nvidia/lib:/usr/nvidia/lib32
    volumes:
      - /etc/wolf/:/etc/wolf:rw
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
case "$1" in
    start)   docker compose up -d; echo "Wolf started. Pair Moonlight to this server's IP." ;;
    stop)    docker compose down ;;
    restart) docker compose restart ;;
    logs)    docker compose logs -f wolf ;;
    status)  docker compose ps; echo; docker ps --filter "name=Wolf" --format "table {{.Names}}\t{{.Status}}" ;;
    update)
        docker compose pull
        docker compose up -d
        ;;
    add-apps)
        WOLF_CFG=/etc/wolf/cfg/config.toml
        GAME_DIR="${2}"
        if [ -z "$GAME_DIR" ]; then
            echo "Usage: ./manage.sh add-apps /path/to/game/storage"
            echo "  e.g. ./manage.sh add-apps /home/user/drives/games"
            exit 1
        fi
        if [ ! -f "$WOLF_CFG" ]; then
            echo "Wolf config not found at $WOLF_CFG — is Wolf running?"
            exit 1
        fi
        python3 - "$GAME_DIR" "$WOLF_CFG" << 'PYEOF'
import sys

games = sys.argv[1].rstrip('/')
cfg   = sys.argv[2]

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
has_steam = any("name = 'WolfSteam'" in l for l in first_block)
has_esde  = any("name = 'WolfES-DE'"  in l for l in first_block)

to_insert = []
if not has_steam:
    to_insert += [
        '\n',
        "    [[profiles.apps]]\n",
        "    icon_png_path = 'https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png'\n",
        "    start_virtual_compositor = true\n",
        "    title = 'Steam'\n",
        '\n',
        "        [profiles.apps.runner]\n",
        "        base_create_json = '''{\n",
        '  "HostConfig": {\n',
        '    "IpcMode": "host",\n',
        '    "CapAdd": ["SYS_ADMIN", "SYS_NICE", "SYS_PTRACE", "NET_RAW", "MKNOD", "NET_ADMIN"],\n',
        '    "SecurityOpt": ["seccomp=unconfined", "apparmor=unconfined"],\n',
        '    "Ulimits": [{"Name":"nofile", "Hard":10240, "Soft":10240}],\n',
        '    "Privileged": false,\n',
        '    "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]\n',
        '  }\n',
        "}\n",
        "'''\n",
        "        devices = []\n",
        "        env = [ 'PROTON_LOG=1', 'RUN_SWAY=true', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*' ]\n",
        "        image = 'ghcr.io/games-on-whales/steam:edge'\n",
        "        mounts = [ '" + games + "/steam:/home/retro/.steam:rw' ]\n",
        "        name = 'WolfSteam'\n",
        "        ports = []\n",
        "        type = 'docker'\n",
    ]
if not has_esde:
    to_insert += [
        '\n',
        "    [[profiles.apps]]\n",
        "    icon_png_path = 'https://games-on-whales.github.io/wildlife/apps/es-de/assets/icon.png'\n",
        "    start_virtual_compositor = true\n",
        "    title = 'EmulationStation'\n",
        '\n',
        "        [profiles.apps.runner]\n",
        "        base_create_json = '''{\n",
        '  "HostConfig": {\n',
        '    "IpcMode": "host",\n',
        '    "Privileged": false,\n',
        '    "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN"],\n',
        '    "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]\n',
        '  }\n',
        "}\n",
        "'''\n",
        "        devices = []\n",
        "        env = [ 'RUN_SWAY=1', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*' ]\n",
        "        image = 'ghcr.io/games-on-whales/es-de:edge'\n",
        "        mounts = [ '" + games + "/roms:/ROMs:rw', '" + games + "/saves:/home/retro/.config/retroarch/saves:rw', '" + games + "/media:/media:rw' ]\n",
        "        name = 'WolfES-DE'\n",
        "        ports = []\n",
        "        type = 'docker'\n",
    ]

if to_insert:
    new_lines = lines[:insert_at] + to_insert + lines[insert_at:]
    with open(cfg, 'w') as f:
        f.writelines(new_lines)
    added = [n for n, exists in [('Steam', has_steam), ('EmulationStation', has_esde)] if not exists]
    print(f"Added to default profile: {', '.join(added)}")
else:
    print('Both apps already in default profile')
PYEOF
        docker compose restart wolf
        echo "Wolf restarted. Steam and EmulationStation should now appear in Moonlight."
        ;;
    backup)
        echo "Set up backups with the modular system:  sudo ./setup.sh backup"
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
        echo "  ./manage.sh start              - Start Wolf"
        echo "  ./manage.sh stop               - Stop Wolf"
        echo "  ./manage.sh restart            - Restart Wolf"
        echo "  ./manage.sh logs               - Follow Wolf logs"
        echo "  ./manage.sh status             - Show Wolf + app containers"
        echo "  ./manage.sh pin                - Show recent Moonlight pairing PIN link"
        echo "  ./manage.sh update             - Pull latest Wolf image and restart"
        echo "  ./manage.sh add-apps <path>    - Add Steam + ES-DE to Wolf config"
        echo "  ./manage.sh backup             - How to set up backups (sudo ./setup.sh backup)"
        ;;
esac
MEOF
    chmod +x manage.sh

    # ── Start Wolf ────────────────────────────────────────────────────────────
    echo ""
    log_info "Starting Wolf (first start pulls the image — give it a minute)..."
    docker compose up -d

    # Wolf writes /etc/wolf/cfg/config.toml on first start. Wait for it, then
    # wire in game storage.
    log_info "Waiting for Wolf to generate /etc/wolf/cfg/config.toml..."
    local WOLF_CFG=/etc/wolf/cfg/config.toml _i
    for _i in $(seq 1 30); do
        [ -f "$WOLF_CFG" ] && break
        sleep 2
    done

    if [ -f "$WOLF_CFG" ]; then
        log_info "Adding Steam and EmulationStation to Wolf config..."
        python3 - "$GAME_STORAGE_DIR" "$WOLF_CFG" << 'PYEOF'
import sys

games = sys.argv[1].rstrip('/')
cfg   = sys.argv[2]

with open(cfg, 'r') as f:
    lines = f.readlines()

# Wolf uses [[profiles]] / [[profiles.apps]] format.
# Apps must be inserted into the FIRST profile (the default paired-client
# profile) before the second [[profiles]] section starts.
profiles_seen, first_start, insert_at = 0, None, len(lines)
for i, line in enumerate(lines):
    if line.strip() == '[[profiles]]':
        profiles_seen += 1
        if profiles_seen == 1: first_start = i
        elif profiles_seen == 2: insert_at = i; break

if first_start is None:
    print('[ERROR] No [[profiles]] section found in config'); sys.exit(1)

first_block = lines[first_start:insert_at]
has_steam = any("name = 'WolfSteam'" in l for l in first_block)
has_esde  = any("name = 'WolfES-DE'"  in l for l in first_block)

to_insert = []
if not has_steam:
    to_insert += [
        '\n',
        "    [[profiles.apps]]\n",
        "    icon_png_path = 'https://games-on-whales.github.io/wildlife/apps/steam/assets/icon.png'\n",
        "    start_virtual_compositor = true\n",
        "    title = 'Steam'\n",
        '\n',
        "        [profiles.apps.runner]\n",
        "        base_create_json = '''{\n",
        '  "HostConfig": {\n',
        '    "IpcMode": "host",\n',
        '    "CapAdd": ["SYS_ADMIN", "SYS_NICE", "SYS_PTRACE", "NET_RAW", "MKNOD", "NET_ADMIN"],\n',
        '    "SecurityOpt": ["seccomp=unconfined", "apparmor=unconfined"],\n',
        '    "Ulimits": [{"Name":"nofile", "Hard":10240, "Soft":10240}],\n',
        '    "Privileged": false,\n',
        '    "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]\n',
        '  }\n',
        "}\n",
        "'''\n",
        "        devices = []\n",
        "        env = [ 'PROTON_LOG=1', 'RUN_SWAY=true', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*' ]\n",
        "        image = 'ghcr.io/games-on-whales/steam:edge'\n",
        f"        mounts = [ '{games}/steam:/home/retro/.steam:rw' ]\n",
        "        name = 'WolfSteam'\n",
        "        ports = []\n",
        "        type = 'docker'\n",
    ]
if not has_esde:
    to_insert += [
        '\n',
        "    [[profiles.apps]]\n",
        "    icon_png_path = 'https://games-on-whales.github.io/wildlife/apps/es-de/assets/icon.png'\n",
        "    start_virtual_compositor = true\n",
        "    title = 'EmulationStation'\n",
        '\n',
        "        [profiles.apps.runner]\n",
        "        base_create_json = '''{\n",
        '  "HostConfig": {\n',
        '    "IpcMode": "host",\n',
        '    "Privileged": false,\n',
        '    "CapAdd": ["NET_RAW", "MKNOD", "NET_ADMIN"],\n',
        '    "DeviceCgroupRules": ["c 13:* rmw", "c 244:* rmw"]\n',
        '  }\n',
        "}\n",
        "'''\n",
        "        devices = []\n",
        "        env = [ 'RUN_SWAY=1', 'GOW_REQUIRED_DEVICES=/dev/input/* /dev/dri/* /dev/nvidia*' ]\n",
        "        image = 'ghcr.io/games-on-whales/es-de:edge'\n",
        f"        mounts = [ '{games}/roms:/ROMs:rw', '{games}/saves:/home/retro/.config/retroarch/saves:rw', '{games}/media:/media:rw' ]\n",
        "        name = 'WolfES-DE'\n",
        "        ports = []\n",
        "        type = 'docker'\n",
    ]

if to_insert:
    new_lines = lines[:insert_at] + to_insert + lines[insert_at:]
    with open(cfg, 'w') as f:
        f.writelines(new_lines)
    added = [n for n, exists in [('Steam', has_steam), ('EmulationStation', has_esde)] if not exists]
    print(f"[INFO] Added to default profile: {', '.join(added)}")
else:
    print('[INFO] Steam and EmulationStation already in default profile')
PYEOF
        docker compose restart wolf
        log_success "Wolf restarted with updated config"
    else
        log_warning "Wolf config not generated in time. Add apps manually to /etc/wolf/cfg/config.toml"
        log_warning "Then run: ./manage.sh restart"
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
    echo "    steam/   → /home/retro/.steam                 (Steam Big Picture)"
    echo "    saves/   → /home/retro/.config/retroarch/saves (RetroArch saves)"
    echo "    media/   → /media                             (ES-DE scraped artwork)"
    echo ""
    echo "  Other app data (ES-DE settings, controller mappings, save states,"
    echo "  standalone-emulator saves) is persisted by Wolf under /etc/wolf and"
    echo "  is included when you set up backups."
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
    echo "Manage:  cd $WOLF_DIR && ./manage.sh {start|stop|restart|logs|status|pin|update|add-apps}"
    echo ""
    echo "── BACKUPS ───────────────────────────────────────────"
    echo ""
    echo "  Back up your saves, progress and user data (Steam user data and all of"
    echo "  /etc/wolf: ES-DE settings, controller mappings, RetroArch saves/states,"
    echo "  emulator saves). ROMs and game installs are skipped."
    echo ""
    echo "  Set up automatic backups with the backup module:"
    echo "       sudo ./setup.sh backup"
    echo ""
    log_success "Done. Pair Moonlight and play."
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wolf
