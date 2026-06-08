#!/bin/bash
# services/sync-cc.sh — Subtitle sync & generation tool (sync_cc).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash sync-cc.sh
# (Docker must already be installed when run standalone)
#
# NON-DOCKER module. sync_cc is a Python CLI tool that:
#   - GENERATE: Whisper AI transcribes video audio → SRT
#   - SYNC:     ffsubsync aligns an existing SRT to the video
#   - BATCH:    process all video+SRT pairs in a directory
#   - RENAME:   look up episode titles on TMDB, rename to Plex format
#   - EXTRACT:  pull embedded subtitle / CC tracks out of MKV/MP4/TS
#   - REMUX:    MP4 → MKV stream-copy (no re-encode)
#   - EMBED:    soft-mux an SRT into a container via mkvmerge
#   - BURNSUBS: OCR burnt-in subs → SRT (and optionally erase from video)
#
# GPU is used automatically when CUDA or MPS is detected.
# Heavy deps (easyocr, pgsreader) are installed on first use by the script
# itself. This module installs the always-needed system + pip packages.
#
# Source script: extras/sync_cc.py in this repo.

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
    HERE="${HERE:-$_SELF_DIR/..}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service sync-cc extras "Subtitle sync/generate tool — Whisper + ffsubsync (sync_cc)"

install_sync-cc() {
    local SYNCCC_DIR="$ACTUAL_HOME/sync-cc"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] sync-cc would:"
        echo "  - Install: python3-pip ffmpeg mkvtoolnix ccextractor"
        echo "  - pip install: openai-whisper ffsubsync"
        echo "  - Copy extras/sync_cc.py → $SYNCCC_DIR/sync_cc.py"
        echo "  - Write $SYNCCC_DIR/.env with TMDB_API_KEY"
        echo "  - Create /usr/local/bin/sync-cc wrapper"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Subtitle Sync & Generation — sync_cc               ║"
    echo "║   Whisper AI · ffsubsync · TMDB rename · OCR subs   ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""

    # ── System packages ──────────────────────────────────────────────────────
    log_info "Installing system dependencies..."
    run_cmd apt-get update -qq
    run_cmd apt-get install -y --no-install-recommends \
        python3 python3-pip ffmpeg mkvtoolnix ccextractor
    log_success "System packages installed"

    # ── pip packages ─────────────────────────────────────────────────────────
    log_info "Installing Python packages (openai-whisper, ffsubsync)..."
    if pip_user_install openai-whisper ffsubsync; then
        log_success "Python packages installed"
    else
        log_warning "pip install reported errors — the tool may still work if packages were partially installed"
    fi

    # ── Install script ───────────────────────────────────────────────────────
    mkdir -p "$SYNCCC_DIR"
    cp "$HERE/extras/sync_cc.py" "$SYNCCC_DIR/sync_cc.py"
    chmod +x "$SYNCCC_DIR/sync_cc.py"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SYNCCC_DIR"
    log_success "sync_cc.py installed to $SYNCCC_DIR/"

    # ── TMDB API key ─────────────────────────────────────────────────────────
    echo ""
    log_info "TMDB API Key (optional — needed for episode rename mode)"
    echo "  The rename feature looks up episode titles via The Movie Database."
    echo "  Get a free key at https://www.themoviedb.org/settings/api"
    echo "  (Leave blank to skip — you can add it later to $SYNCCC_DIR/.env)"
    echo ""
    local TMDB_KEY=""
    if [ "$UNATTENDED" != true ]; then
        read -p "  TMDB API key [Enter to skip]: " TMDB_KEY
    fi

    # Write .env (creates or replaces)
    {
        echo "# sync_cc configuration"
        echo "# Get a free TMDB key at https://www.themoviedb.org/settings/api"
        if [ -n "$TMDB_KEY" ]; then
            echo "TMDB_API_KEY=${TMDB_KEY}"
        else
            echo "# TMDB_API_KEY=your_key_here"
        fi
    } > "$SYNCCC_DIR/.env"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$SYNCCC_DIR/.env"
    chmod 600 "$SYNCCC_DIR/.env"
    log_success ".env written to $SYNCCC_DIR/.env"

    # ── Wrapper in PATH ───────────────────────────────────────────────────────
    # cd into the user's current dir first so .env from cwd is preferred;
    # falls back to the one next to sync_cc.py.
    cat > /usr/local/bin/sync-cc << WRAPEOF
#!/bin/bash
exec python3 "$SYNCCC_DIR/sync_cc.py" "\$@"
WRAPEOF
    chmod +x /usr/local/bin/sync-cc
    log_success "wrapper created: /usr/local/bin/sync-cc"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  sync_cc installed"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Run from any directory containing video / SRT files:"
    echo "    sync-cc"
    echo ""
    echo "  Modes:"
    echo "    1 SYNC     — align an existing SRT to the video"
    echo "    2 GENERATE — Whisper AI transcribes video → SRT"
    echo "    3 BATCH    — sync all video+SRT pairs in directory"
    echo "    4 RENAME   — TMDB episode lookup + rename to Plex format"
    echo "    5 EXTRACT  — pull embedded subtitle tracks from MKV/MP4/TS"
    echo "    6 REMUX    — MP4 → MKV stream copy (no re-encode)"
    echo "    7 EMBED    — soft-mux an SRT into a container"
    echo "    8 BURNSUBS — OCR burnt-in subs → SRT"
    echo ""
    echo "  Config: $SYNCCC_DIR/.env"
    if [ -z "$TMDB_KEY" ]; then
        echo "  → Set TMDB_API_KEY in .env to enable episode rename mode"
    fi
    echo ""
    echo "  Whisper models download automatically on first use."
    echo "  First run may take a few minutes while the model downloads."
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_sync-cc
