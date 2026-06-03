#!/bin/bash
# services/sky-cam.sh — Automated sky / timelapse camera scripts.
# Part of the modular post-install system (sourced by setup.sh).
#
# NON-DOCKER module. sky-cam produces:
#   • Daily sunrise clip — speed-adjusted video, uploaded to Mattermost
#   • Four Seasons timelapse — daily clips sized to Vivaldi movements' music
#   • Full-day timelapse — fixed-fps timelapse of every captured image
#   • Moon-track timelapse — moon tracked & cropped each visible night
#   • Monthly moon-phase close-ups — NASA Dial-a-Moon images posted to MM
#
# Source: https://github.com/outis1one/sky-cam (cloned via bootstrap.sh)
# Installs systemd user timers via sky-cam's install.sh.

register_service sky-cam cameras "Automated sky / timelapse camera scripts (sky-cam)"

install_sky-cam() {
    local SKYCAM_DIR="$ACTUAL_HOME/sky-cam"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sky-cam would:"
        echo "  - Install: ffmpeg bc fonts-dejavu curl python3-pip"
        echo "  - pip install: suntime pytz requests skyfield Pillow numpy scipy"
        echo "  - Clone sky-cam to $SKYCAM_DIR via bootstrap.sh"
        echo "  - Edit sky-cam.conf with your location and camera names"
        echo "  - Copy .env.example → .env and set Mattermost credentials"
        echo "  - Run ./install.sh to register systemd user timers"
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
    local PIP="pip3 install --user --quiet"
    sudo -u "$ACTUAL_USER" $PIP suntime pytz requests skyfield Pillow numpy scipy \
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
    prompt_text "  Timezone [America/New_York]:" "America/New_York" TIMEZONE

    echo ""
    echo "  Camera names are short identifiers, e.g.:  east north south west"
    echo "  These names must match the directories where your camera images are saved."
    echo ""
    prompt_text "  Camera names (space-separated) [east]:" "east" CAMERAS_LIST
    prompt_text "  Sunrise camera (faces east) [east]:" "east" SUNRISE_CAM

    echo ""
    echo "  BASE_DIR is where your camera images live."
    echo "  Each camera should have a sub-folder: BASE_DIR/<camera-name>/"
    local DEFAULT_BASE="$ACTUAL_HOME/sky-cam/data"
    prompt_text "  Image base directory [$DEFAULT_BASE]:" "$DEFAULT_BASE" BASE_DIR
    [ -z "$BASE_DIR" ] && BASE_DIR="$DEFAULT_BASE"

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
        echo "BASE_DIR=${BASE_DIR}"
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
        # Build CAMERAS=(...) line
        local CAM_ARRAY="(${CAMERAS_LIST})"
        sed -i "s|^CAMERAS=.*|CAMERAS=${CAM_ARRAY}|" "$CONF"
        sed -i "s|^SUNRISE_CAM=.*|SUNRISE_CAM=${SUNRISE_CAM:-east}|" "$CONF"
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

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  sky-cam installed"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Location: $SKYCAM_DIR"
    echo "  Data:     $BASE_DIR"
    echo "  Cameras:  $CAMERAS_LIST"
    echo "  Timezone: ${TIMEZONE:-America/New_York}"
    echo ""
    echo "  Next steps:"
    echo "   1. Review $SKYCAM_DIR/sky-cam.conf"
    echo "      — SCRIPT_DIR, MUSIC_DIR, schedules, encoding settings"
    echo "   2. Put your Vivaldi Four Seasons audio files in:"
    echo "      $SKYCAM_DIR/music/"
    echo "      (filenames and expected MUSIC_DIR path are in sky-cam.conf)"
    echo "   3. Verify systemd timers:"
    echo "      systemctl --user list-timers 'sky-cam-*'"
    echo "   4. Credentials → $SKYCAM_DIR/.env"
    echo ""
    echo "  To test the sunrise script manually:"
    echo "    cd $SKYCAM_DIR && ./daily_sunrise_video.sh"
    echo ""
    echo "  Logs:"
    echo "    journalctl --user -u sky-cam-sunrise.service -f"
    echo ""
}
