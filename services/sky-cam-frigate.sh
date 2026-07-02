#!/bin/bash
# services/sky-cam-frigate.sh — Automated sky / timelapse camera scripts
# (sky-cam), configured to source frames from Frigate instead of a camera's
# RTSP stream directly.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash sky-cam-frigate.sh
# (Docker must already be installed when run standalone; Frigate should
# already be configured with the cameras you want — see services/frigate.sh.)
#
# NON-DOCKER module — this is the exact same upstream sky-cam project as
# services/sky-cam.sh (same clone, same scripts, same systemd timers). The
# only difference is what CAM_RTSP_<cam> points to in .env:
#
#   sky-cam.sh          CAM_RTSP_<cam> = the camera's own RTSP URL directly
#   sky-cam-frigate.sh  CAM_RTSP_<cam> = Frigate's go2rtc restream for that
#                       camera (rtsp://<frigate-host>:8554/<cam>)
#
# Why this is the only change needed: sky-cam's capture.sh is itself a
# from-scratch RTSP frame-grabber that "replaces MotionEye or any NVR" (its
# own header comment) — it pulls one JPEG frame every CAPTURE_INTERVAL
# seconds from whatever CAM_RTSP_<cam> points to and writes it to
# BASE_DIR/<cam>/YYYY-MM-DD/HH-MM-SS.jpg. Every other script in the pipeline
# (4-seasons.sh, montage-mvt.sh, year-end-join.sh, moon-track.sh,
# moon-phase-monthly.sh, daily_sunrise_video.sh) only ever reads JPEGs/audio
# already sitting in BASE_DIR — none of them know or care whether the camera
# was reached directly or through Frigate's restream. Pointing capture.sh at
# Frigate's go2rtc endpoint instead of the camera means Frigate stays the
# single RTSP client against the camera (recording + detection), and sky-cam
# becomes a second, cheap consumer of Frigate's already-open stream — no
# upstream sky-cam script edits required.
#
# Source: https://github.com/outis1one/sky-cam (cloned via bootstrap.sh)
# Installs systemd user timers via sky-cam's own install.sh.

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

        run_cmd() {
            "$@"
        }

        pip_user_install() {
            pip3 --user --break-system-packages "$@" 2>/dev/null \
                || pip3 --user "$@"
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

register_service sky-cam-frigate cameras "Automated sky / timelapse camera scripts sourced from Frigate's restream instead of RTSP directly (sky-cam + Frigate)"

# Prints space-separated camera names parsed from an existing Frigate
# config.yml's top-level `cameras:` block. Best-effort only — same 2-space
# indent assumption services/frigate.sh's own parser relies on.
_skycam_frigate_detect_cameras() {
    local cfg="$1"
    [ -f "$cfg" ] || return 0
    awk '
        /^cameras:/ { in_cams=1; next }
        in_cams && /^[a-zA-Z]/ { in_cams=0 }
        in_cams && /^  [a-z0-9_]+:[[:space:]]*$/ { gsub(/[: ]/, ""); print }
    ' "$cfg" | tr '\n' ' '
}

install_sky-cam-frigate() {
    local SKYCAM_DIR="$ACTUAL_HOME/sky-cam"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sky-cam-frigate would:"
        echo "  - Install: ffmpeg bc fonts-dejavu curl python3-pip"
        echo "  - pip install: suntime pytz requests skyfield Pillow numpy scipy"
        echo "  - Clone sky-cam to $SKYCAM_DIR via bootstrap.sh (same repo as sky-cam.sh)"
        echo "  - Detect cameras from an existing Frigate config.yml, if present"
        echo "  - Write CAM_RTSP_<cam>=rtsp://<frigate-host>:8554/<cam> into .env"
        echo "    (Frigate's go2rtc restream, instead of the camera's own RTSP URL)"
        echo "  - Edit sky-cam.conf with your location and camera names"
        echo "  - Copy .env.example → .env and set Mattermost credentials"
        echo "  - Run ./install.sh to register systemd user timers"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  sky-cam + Frigate — Sky & Timelapse Camera System   ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    log_info "This is the same sky-cam project as services/sky-cam.sh — the only"
    log_info "difference is CAM_RTSP_<cam> points at Frigate's restream instead of"
    log_info "the camera directly, so Frigate stays the single RTSP client per camera."
    echo ""

    # ── System packages ──────────────────────────────────────────────────────
    log_info "Installing system dependencies..."
    run_cmd apt-get update -qq
    run_cmd apt-get install -y --no-install-recommends \
        ffmpeg bc fonts-dejavu curl python3-pip git
    log_success "System packages installed"

    # ── Python packages ──────────────────────────────────────────────────────
    log_info "Installing Python packages..."
    pip_user_install suntime pytz requests skyfield Pillow numpy scipy \
        || log_warning "Some pip packages may have failed — check output above"
    log_success "Python packages installed"

    # ── Clone sky-cam ────────────────────────────────────────────────────────
    if [ -d "$SKYCAM_DIR/.git" ]; then
        log_info "sky-cam already cloned at $SKYCAM_DIR — pulling latest..."
        sudo -u "$ACTUAL_USER" git -C "$SKYCAM_DIR" pull --ff-only \
            || log_warning "git pull failed — continuing with existing version"
    else
        log_info "Cloning sky-cam from GitHub..."
        sudo -u "$ACTUAL_USER" bash -c "
            curl -fsSL https://raw.githubusercontent.com/outis1one/sky-cam/main/bootstrap.sh \
            | bash -s -- '$SKYCAM_DIR'
        " || { log_error "Failed to clone sky-cam — check internet connection"; return 1; }
        log_success "sky-cam cloned to $SKYCAM_DIR"
    fi

    # ── Frigate detection ────────────────────────────────────────────────────
    local FRIGATE_CFG="$DOCKER_DIR/frigate/config/config.yml"
    local DEFAULT_CAMS="east"
    local FRIGATE_HOST="127.0.0.1"
    if [ -f "$FRIGATE_CFG" ]; then
        log_success "Found existing Frigate config at $DOCKER_DIR/frigate"
        local _detected
        _detected="$(_skycam_frigate_detect_cameras "$FRIGATE_CFG")"
        [ -n "$_detected" ] && DEFAULT_CAMS="$_detected"
    else
        log_warning "No Frigate config found at $DOCKER_DIR/frigate — run services/frigate.sh first"
        log_warning "if Frigate isn't configured yet. Camera names below must match Frigate's"
        log_warning "config.yml camera keys once it is, or capture.sh will connect to nothing."
    fi

    echo ""
    log_info "Location and camera configuration"
    echo "  sky-cam needs your GPS coordinates and timezone to calculate"
    echo "  sunrise times accurately. Use decimal degrees (e.g. 40.7128, -74.0060)."
    echo ""

    local LATITUDE="" LONGITUDE="" TIMEZONE="" CAMERAS_LIST="" SUNRISE_CAM=""
    prompt_text "  Latitude (decimal degrees) [0.0000]:" "0.0000" LATITUDE
    prompt_text "  Longitude (decimal degrees) [0.0000]:" "0.0000" LONGITUDE
    prompt_text "  Timezone [${SITE_TZ:-America/New_York}]:" "${SITE_TZ:-America/New_York}" TIMEZONE

    echo ""
    echo "  Camera names must match the camera keys configured in Frigate's"
    echo "  config.yml (services/frigate.sh)."
    echo ""
    prompt_text "  Camera names (space-separated) [$DEFAULT_CAMS]:" "$DEFAULT_CAMS" CAMERAS_LIST
    local _default_sunrise; _default_sunrise="$(awk '{print $1}' <<< "$CAMERAS_LIST")"
    prompt_text "  Sunrise camera (faces east) [$_default_sunrise]:" "$_default_sunrise" SUNRISE_CAM

    echo ""
    log_info "Frigate connection"
    echo "  sky-cam's capture.sh runs directly on this host and connects to"
    echo "  Frigate's go2rtc RTSP restream (port 8554) instead of the camera."
    echo ""
    prompt_text "  Frigate host [$FRIGATE_HOST]:" "$FRIGATE_HOST" FRIGATE_HOST

    # Prompt for Mattermost credentials
    echo ""
    log_info "Mattermost webhook (for automated uploads)"
    echo "  sky-cam posts sunrise clips and moon photos to a Mattermost channel."
    echo "  Create an incoming webhook in Mattermost: Settings → Integrations → Webhooks"
    echo "  (Leave blank to skip — add to $SKYCAM_DIR/.env later)"
    echo ""
    local MM_WEBHOOK="" MM_CHANNEL=""
    if [ "$UNATTENDED" != true ]; then
        read -p "  Mattermost webhook URL [Enter to skip]: " MM_WEBHOOK
        if [ -n "$MM_WEBHOOK" ]; then
            prompt_text "  Mattermost channel name [sky-cam]:" "sky-cam" MM_CHANNEL
        fi
    fi

    # ── Write .env ───────────────────────────────────────────────────────────
    log_info "Writing sky-cam.conf overrides to $SKYCAM_DIR/.env..."
    {
        echo "# sky-cam site configuration — generated by ubuntu-post-install"
        echo "# Edit sky-cam.conf for full settings."
        echo ""
        echo "LATITUDE=${LATITUDE:-0.0000}"
        echo "LONGITUDE=${LONGITUDE:-0.0000}"
        echo "TIMEZONE=${TIMEZONE:-America/New_York}"
        echo ""
        echo "# Frigate's go2rtc restream stands in for each camera's direct RTSP"
        echo "# URL — Frigate stays the only RTSP client against the camera itself."
        for _cam in $CAMERAS_LIST; do
            local _var; _var="CAM_RTSP_${_cam}"
            echo "${_var}=rtsp://${FRIGATE_HOST}:8554/${_cam}"
        done
        echo ""
        if [ -n "$MM_WEBHOOK" ]; then
            echo "MM_WEBHOOK_URL=${MM_WEBHOOK}"
            echo "MM_CHANNEL=${MM_CHANNEL:-sky-cam}"
        else
            echo "# MM_WEBHOOK_URL=https://mattermost.yourdomain.com/hooks/your-webhook-id"
            echo "# MM_CHANNEL=sky-cam"
        fi
    } > "$SKYCAM_DIR/.env"
    chmod 600 "$SKYCAM_DIR/.env"

    # ── Patch sky-cam.conf with cameras and basic settings ───────────────────
    local CONF="$SKYCAM_DIR/sky-cam.conf"
    if [ -f "$CONF" ]; then
        log_info "Patching sky-cam.conf with location and camera names..."
        local CAM_ARRAY="(${CAMERAS_LIST})"
        sed -i "s|^CAMERAS=.*|CAMERAS=${CAM_ARRAY}|" "$CONF"
        sed -i "s|^SUNRISE_CAM=.*|SUNRISE_CAM=${SUNRISE_CAM}|" "$CONF"
        log_success "sky-cam.conf updated"
    else
        log_warning "sky-cam.conf not found — check $SKYCAM_DIR"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SKYCAM_DIR" 2>/dev/null || true

    # ── Install systemd timers ────────────────────────────────────────────────
    if [ -f "$SKYCAM_DIR/install.sh" ]; then
        log_info "Installing systemd user timers via install.sh..."
        ( cd "$SKYCAM_DIR" && sudo -u "$ACTUAL_USER" bash install.sh ) \
            && log_success "Systemd timers installed" \
            || log_warning "install.sh failed — run manually: cd $SKYCAM_DIR && ./install.sh"
    else
        log_warning "install.sh not found in $SKYCAM_DIR — run it manually after review"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  sky-cam-frigate installed"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Location:    $SKYCAM_DIR"
    echo "  Frigate:     rtsp://${FRIGATE_HOST}:8554/<camera>"
    echo "  Cameras:     $CAMERAS_LIST"
    echo "  Timezone:    ${TIMEZONE:-America/New_York}"
    echo ""
    echo "  Next steps:"
    echo "   1. Review $SKYCAM_DIR/sky-cam.conf"
    echo "      — schedules, encoding settings, moon-job thresholds"
    echo "   2. Put your Vivaldi Four Seasons audio files in:"
    echo "      $SKYCAM_DIR/music/"
    echo "   3. Confirm frames are landing:"
    echo "      systemctl --user status sky-cam-capture-${SUNRISE_CAM}.service"
    echo "      ls $SKYCAM_DIR/data/${SUNRISE_CAM}/\$(date +%Y-%m-%d)/"
    echo "   4. Verify all timers:"
    echo "      systemctl --user list-timers 'sky-cam-*'"
    echo ""
    echo "  Logs:"
    echo "    journalctl --user -u sky-cam-capture-${SUNRISE_CAM}.service -f"
    echo "    journalctl --user -u sky-cam-sunrise.service -f"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_sky-cam-frigate
