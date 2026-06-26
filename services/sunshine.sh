#!/bin/bash
# services/sunshine.sh — Sunshine game streaming host (Moonlight-compatible).
# Part of the modular post-install system (sourced by setup.sh).
#
# Sunshine streams your desktop or a specific app to any Moonlight client
# (phone, TV, another PC, etc.) with hardware-accelerated encoding and low
# latency. Ideal for playing games on a GPU machine from a thin client.
#
# ── Coexistence with Wolf ──────────────────────────────────────────────────
# Wolf and Sunshine both use Moonlight protocol ports. This installer offsets
# Sunshine to port base 48090 (vs Wolf's default 47984) so both can run
# simultaneously. On Moonlight clients, add the host twice — once on default
# port (Wolf) and once on port 48090 (Sunshine).
#
# To switch between them if you prefer not to run both:
#   sudo systemctl stop wolf   && sudo systemctl start sunshine
#   sudo systemctl stop sunshine && sudo systemctl start wolf
#
# ── Closed-lid laptop / headless ──────────────────────────────────────────
# Sunshine captures a real display (Xorg/Wayland). For closed-lid use:
#   Option A: Dummy HDMI/DisplayPort plug (~$5) — simplest, most reliable
#   Option B: Virtual display via xrandr (software only, set up below)
#
# ── Controller input ──────────────────────────────────────────────────────
# Moonlight sends controller input to Sunshine via uinput (virtual gamepad).
# Works for most games; requires uinput udev rules (applied by this script).
# Keyboard and mouse work reliably for all games including SWBF2 2017.
#
# ── Kyber / SWBF2 app entry ───────────────────────────────────────────────
# This script pre-configures a "Kyber SWBF2" app entry in Sunshine so
# Moonlight shows it as a launchable app. The Kyber AppImage must already
# be installed (run setup-kyber-linux.sh first).
# ── Registration ──────────────────────────────────────────────────────────
command -v register_service &>/dev/null && \
    register_service sunshine homelab "Sunshine game streaming host for Moonlight clients (coexists with Wolf on offset ports)"

# ── Install function ──────────────────────────────────────────────────────
install_sunshine() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     Sunshine — Game Streaming Host                   ║"
    echo "║     Stream to Moonlight on any device                ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would download and install Sunshine .deb"
        echo "[DRY-RUN] Would configure uinput udev rules"
        echo "[DRY-RUN] Would write Sunshine config (offset ports for Wolf coexistence)"
        echo "[DRY-RUN] Would add Kyber SWBF2 app entry if Kyber AppImage found"
        echo "[DRY-RUN] Would optionally set up virtual display for closed-lid use"
        echo "[DRY-RUN] Would enable and start sunshine systemd service"
        return 0
    fi

    # ── Detect Ubuntu version for correct .deb ────────────────────────────
    local UBUNTU_VER
    UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "24.04")
    local DEB_DISTRO
    case "$UBUNTU_VER" in
        22*) DEB_DISTRO="ubuntu-22.04" ;;
        24*) DEB_DISTRO="ubuntu-24.04" ;;
        26*) DEB_DISTRO="ubuntu-26.04" ;;
        *)   DEB_DISTRO="ubuntu-24.04" ;;
    esac

    # ── Download and install Sunshine ─────────────────────────────────────
    if command -v sunshine &>/dev/null; then
        log_info "Sunshine already installed: $(sunshine --version 2>/dev/null || echo 'version unknown')"
    else
        log_info "Fetching latest Sunshine release for $DEB_DISTRO..."

        local API_URL="https://api.github.com/repos/LizardByte/Sunshine/releases/latest"
        local DEB_URL
        DEB_URL=$(curl -fsSL "$API_URL" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    name = a['name']
    if '${DEB_DISTRO}' in name and name.endswith('.deb') and 'debuginfo' not in name:
        print(a['browser_download_url'])
        break
" 2>/dev/null)

        if [[ -z "$DEB_URL" ]]; then
            log_error "Could not find Sunshine .deb for $DEB_DISTRO."
            log_error "Download manually from: https://github.com/LizardByte/Sunshine/releases/latest"
            return 1
        fi

        local DEB_FILE="/tmp/sunshine.deb"
        log_info "Downloading: $DEB_URL"
        curl -L --progress-bar -o "$DEB_FILE" "$DEB_URL"
        apt-get install -y "$DEB_FILE" || {
            log_error "Sunshine install failed."
            return 1
        }
        rm -f "$DEB_FILE"
        log_success "Sunshine installed."
    fi

    # ── uinput udev rules (controller/mouse input from Moonlight) ─────────
    log_info "Configuring uinput for controller and mouse input..."
    cat > /etc/udev/rules.d/85-sunshine-input.rules << 'EOF'
KERNEL=="uinput", GROUP="input", MODE="0660", OPTIONS+="static_node=uinput"
EOF
    usermod -aG input "$ACTUAL_USER" 2>/dev/null || true
    udevadm control --reload-rules && udevadm trigger || true
    log_success "uinput configured (user added to 'input' group)."

    # ── Sunshine config directory ─────────────────────────────────────────
    local CONF_DIR="$ACTUAL_HOME/.config/sunshine"
    mkdir -p "$CONF_DIR"

    # ── Port config (offset from Wolf to allow coexistence) ───────────────
    log_info "Configuring Sunshine ports (offset from Wolf defaults)..."
    cat > "$CONF_DIR/sunshine.conf" << 'EOF'
# Sunshine configuration
# Ports offset from Wolf defaults so both can run simultaneously.
# Wolf uses: 47984/47989/48010
# Sunshine uses: 48090/48095/48100
# On Moonlight clients, add this host manually with port 48090.
port = 48090

# Hardware encoding — auto-detects GPU (NVIDIA NVENC, Intel QSV, AMD VCE)
encoder = auto

# Logging
log_path = /tmp/sunshine.log
min_log_level = info
EOF

    # ── Kyber app entry ───────────────────────────────────────────────────
    local KYBER_PATH=""
    for p in \
        "$ACTUAL_HOME/Applications/KyberLinuxPort-x86_64.AppImage" \
        "$ACTUAL_HOME/.local/share/kyber/KyberLinuxPort.AppImage" \
        "$ACTUAL_HOME/Downloads/kyber/KyberLinuxPort.AppImage"
    do
        if [[ -f "$p" ]]; then
            KYBER_PATH="$p"
            break
        fi
    done

    local APPS_JSON="$CONF_DIR/apps.json"
    if [[ -n "$KYBER_PATH" ]]; then
        log_info "Kyber AppImage found at $KYBER_PATH — adding app entry..."
        cat > "$APPS_JSON" << EOF
{
  "env": {},
  "apps": [
    {
      "name": "Kyber SWBF2",
      "output": "",
      "cmd": "${KYBER_PATH}",
      "exclude-global-prep-cmd": false,
      "elevated": false,
      "auto-detach": true,
      "wait-all": true,
      "exit-timeout": 5,
      "image-path": ""
    },
    {
      "name": "SWBF2 Single Player",
      "output": "",
      "cmd": "steam steam://rungameid/1237950",
      "exclude-global-prep-cmd": false,
      "elevated": false,
      "auto-detach": true,
      "wait-all": true,
      "exit-timeout": 5,
      "image-path": ""
    },
    {
      "name": "Desktop",
      "output": "",
      "cmd": "",
      "exclude-global-prep-cmd": false,
      "elevated": false,
      "auto-detach": true,
      "wait-all": true,
      "exit-timeout": 5,
      "image-path": ""
    }
  ]
}
EOF
        log_success "Kyber SWBF2 app entry added."
    else
        log_warning "Kyber AppImage not found — skipping Kyber app entry."
        log_warning "Run setup-kyber-linux.sh first, then re-run this installer."
        cat > "$APPS_JSON" << 'EOF'
{
  "env": {},
  "apps": [
    {
      "name": "SWBF2 Single Player",
      "output": "",
      "cmd": "steam steam://rungameid/1237950",
      "exclude-global-prep-cmd": false,
      "elevated": false,
      "auto-detach": true,
      "wait-all": true,
      "exit-timeout": 5,
      "image-path": ""
    },
    {
      "name": "Desktop",
      "output": "",
      "cmd": "",
      "exclude-global-prep-cmd": false,
      "elevated": false,
      "auto-detach": true,
      "wait-all": true,
      "exit-timeout": 5,
      "image-path": ""
    }
  ]
}
EOF
    fi

    ensure_docker_dir_ownership "$CONF_DIR"

    # ── Virtual display for closed-lid / headless ─────────────────────────
    local VIRTUAL_DISPLAY=""
    prompt_yn "Set up virtual display for closed-lid/headless use? (y/n):" "n" VIRTUAL_DISPLAY
    if [[ "$VIRTUAL_DISPLAY" =~ ^[Yy]$ ]]; then
        log_info "Installing virtual display support..."
        apt-get install -y xserver-xorg-video-dummy x11-xserver-utils 2>/dev/null || true

        cat > /etc/X11/xorg.conf.d/20-sunshine-virtual.conf << 'EOF'
# Virtual display for Sunshine streaming (closed-lid / headless)
# Provides a 1920x1080 virtual monitor so Sunshine always has a display to capture.
Section "Device"
    Identifier "DummyDevice"
    Driver "dummy"
    VideoRam 256000
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync 28.0-80.0
    VertRefresh 48.0-75.0
    Modeline "1920x1080" 148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync
EndSection
EOF
        log_success "Virtual display configured at 1920x1080."
        log_warning "A physical dummy HDMI plug is simpler and more reliable."
        log_warning "If you have one, plug it in and skip this virtual display config."
    fi

    # ── Systemd service ───────────────────────────────────────────────────
    log_info "Enabling Sunshine systemd service..."

    # Sunshine installs its own systemd user service
    sudo -u "$ACTUAL_USER" systemctl --user enable sunshine 2>/dev/null || true

    # ── Wolf coexistence note ─────────────────────────────────────────────
    if systemctl is-enabled wolf &>/dev/null 2>&1; then
        log_warning "Wolf is installed on this machine."
        log_warning "Both can run simultaneously — Sunshine uses ports 48090-48100."
        log_warning "On Moonlight, add this host twice:"
        log_warning "  Wolf:    $(hostname -I | awk '{print $1}') (default port)"
        log_warning "  Sunshine: $(hostname -I | awk '{print $1}'):48090"
    fi

    # ── README ────────────────────────────────────────────────────────────
    local DIR="$DOCKER_DIR/sunshine"
    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"

    write_readme "$DIR" << 'MD'
# Sunshine — Game Streaming Host

Streams your desktop or apps to any Moonlight client with hardware-accelerated
encoding (NVIDIA NVENC / Intel QSV / AMD VCE).

## Manage
```bash
systemctl --user start sunshine     # start
systemctl --user stop sunshine      # stop
systemctl --user restart sunshine   # restart
systemctl --user status sunshine    # check status
```

## Web UI
Configure apps and settings at: https://localhost:47990
(First run prompts you to create a username and password)

## Moonlight client setup
1. Install Moonlight on the client machine:
   - Ubuntu/Debian: sudo apt install moonlight-qt
   - Or AppImage from https://moonlight-stream.org
2. On first connection, Moonlight shows a PIN — enter it in the Sunshine web UI
3. Sunshine is on port 48090 (offset from Wolf). Add the host manually:
   - In Moonlight: Add Host → enter IP:48090

## Coexistence with Wolf
Sunshine (ports 48090-48100) and Wolf (ports 47984-47989) can run simultaneously.
On Moonlight, add two separate host entries — one for each.

To run only one at a time:
```bash
# Switch to Sunshine
sudo systemctl stop wolf && systemctl --user start sunshine

# Switch back to Wolf
systemctl --user stop sunshine && sudo systemctl start wolf
```

## Closed-lid / headless use
A cheap HDMI/DisplayPort dummy plug is the most reliable solution.
Plugin it into the GPU output and close the lid — Sunshine streams the
virtual monitor the dummy plug creates.

Alternative: virtual display via xrandr (if xserver-xorg-video-dummy installed):
```bash
xrandr --addmode VIRTUAL1 1920x1080
xrandr --output VIRTUAL1 --mode 1920x1080
```

## Kyber SWBF2
The "Kyber SWBF2" app appears in Moonlight if the Kyber AppImage was found
at install time. Click it in Moonlight to launch Kyber on the host machine.
If not shown, re-run: sudo ./setup.sh sunshine

## Keyboard and mouse
Moonlight passes keyboard and mouse input transparently — works perfectly
for all games including SWBF2 2017.

## Controller input
Moonlight injects a virtual gamepad via uinput. Works for most games.
SWBF2 2017 is fully playable with keyboard and mouse if controller has issues.
MD

    # ── Start now? ────────────────────────────────────────────────────────
    local START=""
    prompt_yn "Start Sunshine now? (y/n):" "y" START
    if [[ "$START" =~ ^[Yy]$ ]]; then
        sudo -u "$ACTUAL_USER" systemctl --user start sunshine \
            && log_success "Sunshine started." \
            || log_warning "Start failed — check: systemctl --user status sunshine"
    fi

    echo ""
    log_success "Sunshine installed."
    echo ""
    echo "  Web UI:     https://localhost:47990  (set username/password on first visit)"
    echo "  Moonlight:  add this host at $(hostname -I | awk '{print $1}'):48090"
    echo "  Logs:       /tmp/sunshine.log"
    if [[ -n "$KYBER_PATH" ]]; then
        echo "  Kyber app:  'Kyber SWBF2' visible in Moonlight app list"
    fi
    echo ""
    echo "NOTE: Log out and back in (or reboot) for the 'input' group to take effect"
    echo "      (required for controller and mouse input from Moonlight)."
}

# ── Standalone bootstrap ──────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        source "$_COMMON"
    else
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() { return 0; }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

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

        write_readme() {
            local _dir="$1"; shift
            [[ "$DRY_RUN" == "true" ]] && return 0
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }

        ACTUAL_USER="${SUDO_USER:-$USER}"
        ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
        DOCKER_DIR="$ACTUAL_HOME/docker"
        DRY_RUN="${DRY_RUN:-false}"
        UNATTENDED="${UNATTENDED:-false}"
    fi

    install_sunshine
    exit $?
fi
