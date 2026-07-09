#!/bin/bash
# services/sky-cam.sh — Automated sky / timelapse camera scripts.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash sky-cam.sh
# (Docker must already be installed when run standalone)
#
# NON-DOCKER module. sky-cam produces:
#   • Daily sunrise clip — speed-adjusted video (+ optional audio), uploaded to Mattermost
#   • Four Seasons timelapse — daily clips sized to Vivaldi movements' music
#   • Full-day timelapse — fixed-fps timelapse of every captured image
#   • Moon-track timelapse — moon tracked & cropped each visible night
#   • Monthly moon-phase close-ups — NASA Dial-a-Moon images posted to MM
#
# No motionEye or any NVR required — sky-cam's own capture.sh connects
# directly to each camera's RTSP stream and grabs frames itself
# (CAM_RTSP_<cam> in .env is the only thing capture.sh and the optional
# sunrise-audio/ambient-audio recorders need). This installer prompts for
# that per camera, so install.sh can generate every applicable systemd
# timer/service (capture, watchdog, sunrise, audio, ambient, moon jobs,
# per-camera seasons clips) in one pass.
#
# Source: https://github.com/outis1one/sky-cam (cloned via bootstrap.sh)
# Installs systemd user timers via sky-cam's install.sh.

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

register_service sky-cam cameras "Automated sky / timelapse camera scripts (sky-cam)"

install_sky-cam() {
    local SKYCAM_DIR="$ACTUAL_HOME/sky-cam"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sky-cam would:"
        echo "  - Install: ffmpeg bc fonts-dejavu curl python3-pip"
        echo "  - pip install: suntime pytz requests skyfield Pillow numpy scipy"
        echo "  - Clone sky-cam to $SKYCAM_DIR via bootstrap.sh"
        echo "  - Prompt for each camera's RTSP URL -> CAM_RTSP_<cam> in .env"
        echo "    (capture.sh connects directly - no motionEye or other NVR needed)"
        echo "  - Prompt for sunrise audio / optional ambient audio library"
        echo "  - Prompt for Mattermost (mattermost_url/access_token/channel_id) + ntfy"
        echo "  - Patch sky-cam.conf: cameras, audio toggles, per-camera seasons schedule"
        echo "  - Run ./install.sh to register every applicable systemd timer/service"
        echo "  - Add retry-on-failure drop-ins (3x, 60s apart) to sunrise/seasons/moon jobs"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   sky-cam — Automated Sky & Timelapse Camera System  ║"
    echo "╚═══════════════════════════════════════════════════════╝"
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

    # ── Essential configuration ──────────────────────────────────────────────
    echo ""
    log_info "Location and camera configuration"
    echo "  sky-cam needs your GPS coordinates and timezone to calculate"
    echo "  sunrise times accurately. Use decimal degrees (e.g. 40.7128, -74.0060)."
    echo ""

    local LATITUDE="" LONGITUDE="" TIMEZONE="" BASE_DIR="" CAMERAS_LIST="" SUNRISE_CAM=""
    prompt_text "  Latitude (decimal degrees) [0.0000]:" "0.0000" LATITUDE
    prompt_text "  Longitude (decimal degrees) [0.0000]:" "0.0000" LONGITUDE
    prompt_text "  Timezone [${SITE_TZ:-America/New_York}]:" "${SITE_TZ:-America/New_York}" TIMEZONE

    echo ""
    echo "  Camera names are short identifiers, e.g.:  east north south west"
    echo "  capture.sh creates BASE_DIR/<camera-name>/ itself — no pre-existing folders needed."
    echo ""
    prompt_text "  Camera names (space-separated) [east]:" "east" CAMERAS_LIST
    prompt_text "  Sunrise camera (faces east) [east]:" "east" SUNRISE_CAM

    echo ""
    echo "  BASE_DIR is where captured images/videos are written. Leave default unless"
    echo "  you want them on a separate drive or network mount."
    local DEFAULT_BASE="$ACTUAL_HOME/sky-cam/data"
    prompt_text "  Image base directory [$DEFAULT_BASE]:" "$DEFAULT_BASE" BASE_DIR
    [ -z "$BASE_DIR" ] && BASE_DIR="$DEFAULT_BASE"

    # ── Camera RTSP connections ───────────────────────────────────────────────
    # capture.sh IS the motionEye replacement — it needs each camera's RTSP URL
    # directly. This is the one variable every downstream script depends on
    # (capture.sh for frames, sunrise-audio-capture.sh/ambient-record.sh for audio).
    echo ""
    log_info "Camera RTSP connections"
    echo "  Find each camera's RTSP URL in its web UI (usually Network → Video → RTSP)"
    echo "  or its manual. Format: rtsp://username:password@camera-ip:554/stream-path"
    echo "  If the password has special characters, sky-cam's url-encode-password.py"
    echo "  can encode it for you (run after cloning, before pasting the URL below)."
    echo "  Leave blank to skip a camera for now — add CAM_RTSP_<cam> to .env later."
    echo ""
    local CAM_RTSP_ENV="" _cam _rtsp
    for _cam in $CAMERAS_LIST; do
        _rtsp=""
        prompt_text "  ${_cam} RTSP URL:" "" _rtsp
        if [ -n "$_rtsp" ]; then
            CAM_RTSP_ENV="${CAM_RTSP_ENV}CAM_RTSP_${_cam}=${_rtsp}
"
        else
            log_warning "No RTSP URL for ${_cam} — capture won't start until CAM_RTSP_${_cam} is set in .env"
        fi
    done

    # ── Sunrise audio ─────────────────────────────────────────────────────────
    echo ""
    echo "  If the sunrise camera has a mic, sky-cam records natural audio centred"
    echo "  on the actual sunrise moment and mixes it into the video."
    local AUDIO_MIC=""
    prompt_yn "  Does ${SUNRISE_CAM} have a working microphone? (y/n):" "y" AUDIO_MIC

    # ── Ambient audio library (optional fallback) ─────────────────────────────
    echo ""
    echo "  Optional: continuously record an ambient sound library (birds/rain/wind)"
    echo "  as a fallback for the sunrise video on days with no dedicated recording."
    local AMBIENT="" AMBIENT_CAMS_LIST=""
    prompt_yn "  Enable the ambient audio library? (y/n):" "n" AMBIENT
    if [[ "$AMBIENT" =~ ^[Yy]$ ]]; then
        prompt_text "  Camera(s) to record ambient audio from (space-separated) [${SUNRISE_CAM}]:" \
            "$SUNRISE_CAM" AMBIENT_CAMS_LIST
    fi

    # ── Mattermost (file uploads) ─────────────────────────────────────────────
    # sunrise2mm.py reads mattermost_url / access_token / channel_id (lowercase,
    # bot/PAT REST-API upload) — NOT an incoming webhook. Incoming webhooks can't
    # attach binary files, so a webhook URL alone would silently never upload.
    echo ""
    log_info "Mattermost (uploads sunrise clips + moon photos)"
    echo "  Needs a token that can post in the target channel — Mattermost System"
    echo "  Console → Integrations → Bot Accounts, or a user's own Personal Access"
    echo "  Token (Account Settings → Security → Personal Access Tokens)."
    echo "  (Leave the URL blank to skip — add to $SKYCAM_DIR/.env later)"
    echo ""
    local MM_URL="" MM_TOKEN="" MM_CHANNEL_ID=""
    read -p "  Mattermost URL (e.g. https://mattermost.example.com) [Enter to skip]: " MM_URL
    if [ -n "$MM_URL" ]; then
        prompt_text "  Access token:" "" MM_TOKEN
        prompt_text "  Channel ID (for sunrise/moon uploads):" "" MM_CHANNEL_ID
    fi

    # ── ntfy push notifications (optional, separate from Mattermost) ─────────
    echo ""
    local NTFY="" NTFY_TOPIC_URL=""
    prompt_yn "  Enable ntfy.sh push notifications for job status/failures? (y/n):" "n" NTFY
    if [[ "$NTFY" =~ ^[Yy]$ ]]; then
        prompt_text "  ntfy topic URL (e.g. https://ntfy.sh/your-topic):" "" NTFY_TOPIC_URL
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
        echo "BASE_DIR=${BASE_DIR}"
        echo ""
        echo "# Per-camera RTSP — capture.sh connects directly (replaces motionEye)."
        printf '%s' "$CAM_RTSP_ENV"
        echo ""
        if [ -n "$MM_URL" ]; then
            echo "mattermost_url=${MM_URL}"
            echo "access_token=${MM_TOKEN}"
            echo "channel_id=${MM_CHANNEL_ID}"
        else
            echo "# mattermost_url=https://mattermost.yourdomain.com"
            echo "# access_token=your-bot-or-personal-access-token"
            echo "# channel_id=your-channel-id"
        fi
        if [ -n "$NTFY_TOPIC_URL" ]; then
            echo "NTFY_URL=${NTFY_TOPIC_URL}"
        fi
    } > "$SKYCAM_DIR/.env"
    chmod 600 "$SKYCAM_DIR/.env"

    # ── Patch sky-cam.conf ────────────────────────────────────────────────────
    local CONF="$SKYCAM_DIR/sky-cam.conf"
    if [ -f "$CONF" ]; then
        log_info "Patching sky-cam.conf with location, cameras, audio, and schedules..."
        local CAM_ARRAY="(${CAMERAS_LIST})"
        sed -i "s|^CAMERAS=.*|CAMERAS=${CAM_ARRAY}|" "$CONF"
        sed -i "s|^SUNRISE_CAM=.*|SUNRISE_CAM=${SUNRISE_CAM:-east}|" "$CONF"

        if [[ "$AUDIO_MIC" =~ ^[Yy]$ ]]; then
            sed -i "s|^AUDIO_ENABLED=.*|AUDIO_ENABLED=true|" "$CONF"
        else
            sed -i "s|^AUDIO_ENABLED=.*|AUDIO_ENABLED=false|" "$CONF"
        fi

        if [[ "$AMBIENT" =~ ^[Yy]$ ]]; then
            sed -i "s|^AMBIENT_ENABLED=.*|AMBIENT_ENABLED=true|" "$CONF"
            sed -i "s|^AMBIENT_CAMS=.*|AMBIENT_CAMS=(${AMBIENT_CAMS_LIST})|" "$CONF"
        fi

        if [ -n "$NTFY_TOPIC_URL" ]; then
            sed -i "s|^NTFY_ENABLED=.*|NTFY_ENABLED=true|" "$CONF"
        fi

        # Every configured camera needs its own seasons schedule — stock
        # sky-cam.conf only ships defaults for east/north/south, staggered
        # 30 min apart starting at 01:00 (upstream's own spacing advice).
        local _idx=0
        for _cam in $CAMERAS_LIST; do
            local _total_min=$(( 60 + _idx * 30 ))
            local _hh=$(( (_total_min / 60) % 24 ))
            local _mm=$(( _total_min % 60 ))
            local _sched; _sched="$(printf '%02d:%02d:00' "$_hh" "$_mm")"
            if grep -q "^SCHEDULE_SEASONS_${_cam}=" "$CONF"; then
                sed -i "s|^SCHEDULE_SEASONS_${_cam}=.*|SCHEDULE_SEASONS_${_cam}=${_sched}|" "$CONF"
            else
                echo "SCHEDULE_SEASONS_${_cam}=${_sched}" >> "$CONF"
            fi
            _idx=$((_idx+1))
        done

        log_success "sky-cam.conf updated"
    else
        log_warning "sky-cam.conf not found — check $SKYCAM_DIR"
    fi

    # ── Create image directories ─────────────────────────────────────────────
    mkdir -p "$BASE_DIR"
    for _cam in $CAMERAS_LIST; do
        mkdir -p "$BASE_DIR/$_cam"
    done
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SKYCAM_DIR" "$BASE_DIR" 2>/dev/null || true
    log_success "Image directories created under $BASE_DIR"

    # ── Install systemd timers ────────────────────────────────────────────────
    if [ -f "$SKYCAM_DIR/install.sh" ]; then
        log_info "Installing systemd user timers via install.sh..."
        ( cd "$SKYCAM_DIR" && sudo -u "$ACTUAL_USER" bash install.sh ) \
            && log_success "Systemd timers installed" \
            || log_warning "install.sh failed — run manually: cd $SKYCAM_DIR && ./install.sh"
    else
        log_warning "install.sh not found in $SKYCAM_DIR — run it manually after review"
    fi

    # ── Resilience: retry-on-failure for the daily/nightly oneshot jobs ──────
    # install.sh generates sunrise/seasons/moon jobs as Type=oneshot with only
    # OnFailure=notify (no retry) — a transient ffmpeg/network blip fails the
    # whole day's job with just an alert. Drop-in overrides add bounded
    # auto-restart without touching install.sh's generated units directly
    # (those get overwritten every time install.sh re-runs, e.g. after editing
    # sky-cam.conf, so any hand-edit there would silently vanish next time).
    # systemd only fires OnFailure once retries are exhausted, so this doesn't
    # spam a notification per attempt — just one, after 3 tries.
    local UNIT_DIR="$ACTUAL_HOME/.config/systemd/user"
    if [ -d "$UNIT_DIR" ]; then
        log_info "Adding retry-on-failure to sunrise/seasons/moon jobs..."
        local _retry_units=("sky-cam-sunrise" "sky-cam-sunrise-upload" "sky-cam-moon-track" "sky-cam-moon-phase")
        [[ "$AUDIO_MIC" =~ ^[Yy]$ ]] && _retry_units+=("sky-cam-audio-capture")
        for _cam in $CAMERAS_LIST; do
            _retry_units+=("sky-cam-seasons-${_cam}")
        done

        local _unit _patched=0
        for _unit in "${_retry_units[@]}"; do
            if [ -f "$UNIT_DIR/${_unit}.service" ]; then
                mkdir -p "$UNIT_DIR/${_unit}.service.d"
                cat > "$UNIT_DIR/${_unit}.service.d/override.conf" << 'EOF'
[Unit]
StartLimitIntervalSec=600
StartLimitBurst=3

[Service]
Restart=on-failure
RestartSec=60
EOF
                _patched=$((_patched+1))
            fi
        done
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$UNIT_DIR" 2>/dev/null || true

        if [ "$_patched" -gt 0 ]; then
            sudo -u "$ACTUAL_USER" bash -c '
                export XDG_RUNTIME_DIR="/run/user/$(id -u)"
                systemctl --user daemon-reload
            ' && log_success "${_patched} job(s) will retry up to 3x (60s apart) before alerting" \
              || log_warning "daemon-reload failed — run manually: systemctl --user daemon-reload"
        fi
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  sky-cam installed"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Location:  $SKYCAM_DIR"
    echo "  Data:      $BASE_DIR"
    echo "  Cameras:   $CAMERAS_LIST"
    echo "  Timezone:  ${TIMEZONE:-America/New_York}"
    echo "  Audio:     $([ "$AUDIO_MIC" = "y" ] || [ "$AUDIO_MIC" = "Y" ] && echo "sunrise mic enabled" || echo "disabled")"
    echo "  Ambient:   $([[ "$AMBIENT" =~ ^[Yy]$ ]] && echo "enabled ($AMBIENT_CAMS_LIST)" || echo "disabled")"
    echo "  Mattermost: $([ -n "$MM_URL" ] && echo "configured" || echo "not configured")"
    echo "  ntfy:      $([ -n "$NTFY_TOPIC_URL" ] && echo "configured" || echo "not configured")"
    echo "  Retries:   sunrise/seasons/moon jobs retry up to 3x (60s apart) before alerting"
    echo ""
    echo "  Next steps:"
    echo "   1. Review $SKYCAM_DIR/sky-cam.conf"
    echo "      — MUSIC_DIR, encoding settings, moon-job thresholds"
    echo "   2. Put your Vivaldi Four Seasons audio files in:"
    echo "      $SKYCAM_DIR/music/"
    echo "      (filenames and expected MUSIC_DIR path are in sky-cam.conf)"
    echo "   3. Confirm frames are landing:"
    echo "      systemctl --user status sky-cam-capture-${SUNRISE_CAM}.service"
    echo "      ls $BASE_DIR/${SUNRISE_CAM}/\$(date +%Y-%m-%d)/"
    echo "   4. Verify all timers:"
    echo "      systemctl --user list-timers 'sky-cam-*'"
    echo ""
    echo "  To test the sunrise script manually:"
    echo "    cd $SKYCAM_DIR && ./daily_sunrise_video.sh"
    echo ""
    echo "  Logs:"
    echo "    journalctl --user -u sky-cam-capture-${SUNRISE_CAM}.service -f"
    echo "    journalctl --user -u sky-cam-sunrise.service -f"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_sky-cam
