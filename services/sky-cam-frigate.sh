#!/bin/bash
# services/sky-cam-frigate.sh — Automated sky / timelapse camera scripts,
# sourced from Frigate recordings instead of raw JPEG image folders.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash sky-cam-frigate.sh
# (Docker must already be installed when run standalone; Frigate should
# already be configured — see services/frigate.sh — with continuous
# recording enabled for the cameras you want timelapses from.)
#
# NON-DOCKER module. Duplicate of sky-cam.sh, adapted so the timelapse
# source is Frigate's recordings (via its HTTP export API) rather than a
# directory of per-frame JPEGs dropped by motionEye. Produces the same
# outputs sky-cam always has:
#   • Daily sunrise clip — speed-adjusted video, uploaded to Mattermost
#   • Four Seasons timelapse — daily clips sized to Vivaldi movements' music
#   • Full-day timelapse — fixed-length timelapse of the day's recording
#   • Moon-track timelapse — moon tracked & cropped each visible night
#   • Monthly moon-phase close-ups — NASA Dial-a-Moon images posted to MM
#
# Source: https://github.com/outis1one/sky-cam (cloned via bootstrap.sh)
# Installs systemd user timers via sky-cam's install.sh.
#
# Frigate integration: since Frigate stores recordings in its own rolling
# storage rather than per-frame JPEGs, this installer wires up a
# frigate-retime.sh helper (dropped alongside the cloned sky-cam scripts)
# that:
#   1. Requests a coarse timelapse export from Frigate's API for a given
#      start/end window (Frigate stitches its continuous-recording segments
#      together for you — no manual concatenation needed).
#   2. ffprobes the exported clip's *actual* duration (never trusts the
#      requested export speed — hardware-accelerated exports can silently
#      fall back to realtime).
#   3. Computes the exact speed factor needed to hit a target duration
#      (e.g. a Vivaldi movement's runtime) and re-encodes once with
#      `setpts=PTS/factor`, hard-clipped with `-t <target>` and the music
#      muxed in.
# The daily/moon/four-seasons timer scripts call this helper instead of
# assembling JPEGs directly.

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

register_service sky-cam-frigate cameras "Automated sky / timelapse camera scripts sourced from Frigate recordings (sky-cam + Frigate)"

# Writes $SKYCAM_DIR/frigate-retime.sh — see header comment in that file for
# the export/measure/retime algorithm. Not part of the upstream sky-cam repo,
# so it's safe from being clobbered by `git pull` there (different filename).
_write_frigate_retime_helper() {
    local dir="$1"
    cat > "$dir/frigate-retime.sh" << 'RETIME'
#!/bin/bash
# frigate-retime.sh — Export a Frigate timelapse for a time window and
# re-time it to hit an exact target duration (e.g. a music track's length).
#
# Frigate's export API only offers fixed-speed presets (e.g. timelapse_25x),
# so two source windows of different real-world length come out at
# different durations. To land on an exact target (a Vivaldi movement's
# runtime, a fixed "full day" length, etc.) this script:
#   1. Requests a coarse export from Frigate covering start..end.
#   2. Measures what actually came out with ffprobe — never trusts the
#      requested speed, since hardware-accelerated exports can silently
#      fall back to realtime.
#   3. Computes the exact speed factor to hit the target and re-encodes
#      once with setpts=PTS/factor, hard-clipped to the target length.
#
# Usage:
#   frigate-retime.sh <camera> <start_unix> <end_unix> <target_seconds> \
#       <output.mp4> [audio_file]
#
# Requires FRIGATE_URL and FRIGATE_EXPORT_DIR in the environment (sky-cam's
# .env sets these — source it before calling, or run via sky-cam's timers
# which already do).
set -euo pipefail

CAMERA="${1:?camera name required}"
START="${2:?start unix timestamp required}"
END="${3:?end unix timestamp required}"
TARGET="${4:?target duration in seconds required}"
OUT="${5:?output path required}"
AUDIO="${6:-}"

: "${FRIGATE_URL:?Set FRIGATE_URL (e.g. http://localhost:5000)}"
: "${FRIGATE_EXPORT_DIR:?Set FRIGATE_EXPORT_DIR (host path to Frigate's media/exports)}"

NAME="skycam_$(date +%s)_$$"

log() { echo "[frigate-retime] $*"; }

# 1. Kick off a coarse timelapse export covering the window. Frigate
#    stitches together whatever continuous-recording segments fall in
#    start..end — no manual concatenation needed on our end.
log "Requesting export for ${CAMERA} ${START}..${END} (name=${NAME})"
curl -fsS -H "Content-Type: application/json" -X POST \
    -d "{\"playback\": \"timelapse_25x\", \"name\": \"${NAME}\"}" \
    "${FRIGATE_URL}/api/export/${CAMERA}/start/${START}/end/${END}" > /dev/null

# 2. Wait for the export file to land in Frigate's media volume on disk.
COARSE=""
for _ in $(seq 1 120); do
    COARSE="$(find "$FRIGATE_EXPORT_DIR" -maxdepth 1 -iname "*${NAME}*.mp4" -print -quit 2>/dev/null || true)"
    [ -n "$COARSE" ] && break
    sleep 5
done
[ -n "$COARSE" ] || { log "ERROR: export ${NAME} never appeared in ${FRIGATE_EXPORT_DIR}"; exit 1; }
log "Coarse export ready: $COARSE"

# 3. Measure the actual duration — this is what makes the retime exact
#    regardless of what speed Frigate actually delivered.
ACTUAL_SECONDS="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$COARSE")"
log "Coarse export duration: ${ACTUAL_SECONDS}s — target: ${TARGET}s"

# 4. Compute the speed factor and re-encode once, hard-clipped to target.
FACTOR="$(echo "$ACTUAL_SECONDS / $TARGET" | bc -l)"
log "Speed factor: ${FACTOR}x"

if [ -n "$AUDIO" ]; then
    ffmpeg -y -i "$COARSE" -i "$AUDIO" \
        -filter:v "setpts=PTS/${FACTOR}" -r 30 \
        -map 0:v -map 1:a -shortest -t "$TARGET" \
        -c:v libx264 -c:a aac "$OUT"
else
    ffmpeg -y -i "$COARSE" \
        -filter:v "setpts=PTS/${FACTOR}" -r 30 -t "$TARGET" \
        -an -c:v libx264 "$OUT"
fi

rm -f "$COARSE"
log "Wrote $OUT"
RETIME
    chmod +x "$dir/frigate-retime.sh"
}

install_sky-cam-frigate() {
    local SKYCAM_DIR="$ACTUAL_HOME/sky-cam"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sky-cam-frigate would:"
        echo "  - Install: ffmpeg bc fonts-dejavu curl python3-pip"
        echo "  - pip install: suntime pytz requests skyfield Pillow numpy scipy"
        echo "  - Clone sky-cam to $SKYCAM_DIR via bootstrap.sh (shared with sky-cam.sh)"
        echo "  - Drop frigate-retime.sh into $SKYCAM_DIR (export + exact-duration retime helper)"
        echo "  - Detect an existing Frigate install (\$DOCKER_DIR/frigate/.env) for URL/export dir defaults"
        echo "  - Write FRIGATE_URL / FRIGATE_EXPORT_DIR / camera names into .env"
        echo "  - Copy .env.example → .env and set Mattermost credentials"
        echo "  - Run ./install.sh to register systemd user timers"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  sky-cam + Frigate — Sky & Timelapse Camera System   ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""
    log_info "This variant sources footage from Frigate's recordings via its"
    log_info "export API, instead of a folder of per-frame JPEGs."
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
    local FRIGATE_ENV="$DOCKER_DIR/frigate/.env"
    local DEFAULT_FRIGATE_URL="http://localhost:5000"
    local DEFAULT_EXPORT_DIR=""
    if [ -f "$FRIGATE_ENV" ]; then
        log_success "Found existing Frigate install at $DOCKER_DIR/frigate"
        local _frigate_media
        _frigate_media="$(grep -E '^FRIGATE_MEDIA=' "$FRIGATE_ENV" | head -1 | cut -d= -f2-)"
        [ -n "$_frigate_media" ] && DEFAULT_EXPORT_DIR="$_frigate_media/exports"
    else
        log_warning "No Frigate install found at $DOCKER_DIR/frigate — run services/frigate.sh first,"
        log_warning "or enter its URL/export path manually below."
    fi

    echo ""
    log_info "Frigate connection"
    local FRIGATE_URL="" FRIGATE_EXPORT_DIR=""
    prompt_text "  Frigate URL [$DEFAULT_FRIGATE_URL]:" "$DEFAULT_FRIGATE_URL" FRIGATE_URL
    prompt_text "  Frigate export directory on this host [${DEFAULT_EXPORT_DIR:-required}]:" \
        "$DEFAULT_EXPORT_DIR" FRIGATE_EXPORT_DIR
    if [ -z "$FRIGATE_EXPORT_DIR" ]; then
        log_warning "No export directory set — frigate-retime.sh will fail until FRIGATE_EXPORT_DIR is set in .env"
    fi

    # ── Essential configuration ──────────────────────────────────────────────
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
    echo "  config.yml (services/frigate.sh), e.g.:  east north south west"
    echo ""
    prompt_text "  Frigate camera names (space-separated) [east]:" "east" CAMERAS_LIST
    prompt_text "  Sunrise camera (faces east) [east]:" "east" SUNRISE_CAM

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
        echo "# Frigate is the recording source for this variant — see"
        echo "# frigate-retime.sh for how clips are exported and re-timed to an"
        echo "# exact target duration (e.g. a music movement's runtime)."
        echo "FRIGATE_URL=${FRIGATE_URL:-$DEFAULT_FRIGATE_URL}"
        echo "FRIGATE_EXPORT_DIR=${FRIGATE_EXPORT_DIR}"
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
        sed -i "s|^SUNRISE_CAM=.*|SUNRISE_CAM=${SUNRISE_CAM:-east}|" "$CONF"
        log_success "sky-cam.conf updated"
    else
        log_warning "sky-cam.conf not found — check $SKYCAM_DIR"
    fi

    # ── Frigate export/retime helper ─────────────────────────────────────────
    log_info "Writing frigate-retime.sh helper to $SKYCAM_DIR..."
    _write_frigate_retime_helper "$SKYCAM_DIR"
    log_success "frigate-retime.sh installed"

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
    echo "  Frigate URL: ${FRIGATE_URL:-$DEFAULT_FRIGATE_URL}"
    echo "  Export dir:  ${FRIGATE_EXPORT_DIR:-<not set>}"
    echo "  Cameras:     $CAMERAS_LIST"
    echo "  Timezone:    ${TIMEZONE:-America/New_York}"
    echo ""
    echo "  Next steps:"
    echo "   1. Review $SKYCAM_DIR/sky-cam.conf — schedules, encoding settings"
    echo "   2. sky-cam's own timer scripts still assemble from JPEGs by default;"
    echo "      point the ones you want Frigate-backed (daily sunrise, four"
    echo "      seasons, full-day, moon-track) at frigate-retime.sh — see its"
    echo "      header comment for the exact usage/args."
    echo "   3. Put your Vivaldi Four Seasons audio files in:"
    echo "      $SKYCAM_DIR/music/"
    echo "   4. Verify systemd timers:"
    echo "      systemctl --user list-timers 'sky-cam-*'"
    echo "   5. Credentials → $SKYCAM_DIR/.env"
    echo ""
    echo "  Test the export/retime helper manually:"
    echo "    cd $SKYCAM_DIR && source .env && ./frigate-retime.sh east \\"
    echo "      \$(date -d 'today 06:00' +%s) \$(date -d 'today 08:00' +%s) 30 test.mp4"
    echo ""
    echo "  Logs:"
    echo "    journalctl --user -u sky-cam-sunrise.service -f"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_sky-cam-frigate
