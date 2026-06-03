#!/bin/bash
# services/sync-cc.sh — Subtitle sync & generation tool (sync_cc).
# Part of the modular post-install system (sourced by setup.sh).
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
    # Install as the actual (non-root) user so packages land in ~/.local
    log_info "Installing Python packages (openai-whisper, ffsubsync)..."
    local PIP_CMD="pip3 install --user --quiet openai-whisper ffsubsync"
    if sudo -u "$ACTUAL_USER" $PIP_CMD; then
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
