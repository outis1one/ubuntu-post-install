#!/bin/bash
# services/drum-rhythm-game.sh — Browser-based drum rhythm game (outis1one/drum-rhythm-game).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash drum-rhythm-game.sh
# (Docker must already be installed when run standalone)
#
# Serves a single self-contained index.html via nginx. No login — protect
# with Authelia via Caddy if you want access control.
# Source: https://github.com/outis1one/drum-rhythm-game

# ── Standalone bootstrap ──────────────────────────────────────────────────────
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

        port_in_use() {
            local _port="$1" _proto="${2:-tcp}"
            local _flag="-tlnH"
            [ "$_proto" = "udp" ] && _flag="-ulnH"
            ss "$_flag" "sport = :${_port}" 2>/dev/null | grep -q .
        }

        find_free_port() {
            local _varname="$1" _port="$2" _proto="${3:-tcp}"
            while port_in_use "$_port" "$_proto"; do
                _port=$((_port + 1))
            done
            eval "$_varname='$_port'"
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

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service drum-rhythm-game gaming "Browser-based drum rhythm game (outis1one/drum-rhythm-game)" 8096

install_drum-rhythm-game() {
    require_docker || return 1

    local DRUM_DIR="$DOCKER_DIR/drum-rhythm-game"
    local REPO_URL="https://github.com/outis1one/drum-rhythm-game.git"
    local WEB_PORT="8096"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] drum-rhythm-game would:"
        echo "  - Clone $REPO_URL to $DRUM_DIR/html"
        echo "  - Build the repo's own Dockerfile (nginx, gzip, /healthz) on port 8096"
        echo "    (auto-scanned for a free host port — 8096 is also emby/jellyfin's default)"
        echo "  - Offer Authelia SSO protection via Caddy (no built-in auth)"
        return 0
    fi

    # Scan for a free host port — this default (8096) is also emby's and
    # jellyfin's default, so a plain install shouldn't silently claim a port
    # another already-running service holds. See CLAUDE.md's "Port collision
    # avoidance" section.
    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$DRUM_DIR"
    ensure_docker_dir_ownership "$DRUM_DIR"
    cd "$DRUM_DIR" || return 1

    # Clone or update the game source
    if [ -d "$DRUM_DIR/html/.git" ]; then
        log_info "Updating drum-rhythm-game source..."
        git -C "$DRUM_DIR/html" pull --ff-only 2>/dev/null \
            && log_success "Updated to latest" \
            || log_warning "Could not pull latest — using existing version"
    else
        log_info "Cloning drum-rhythm-game..."
        git clone --depth 1 "$REPO_URL" "$DRUM_DIR/html" \
            || { log_error "Clone failed — check network and git access"; return 1; }
    fi

    # Apply local runtime fixes for the upstream single-page game.  The game is
    # intentionally static, so we patch index.html after clone/pull instead of
    # forking the deployment source.  The shim is defensive: it fixes Web Audio
    # resume/unlock behavior, guarantees every visible drum pad has an audible
    # fallback, and replaces Christmas melody metadata with well-known public
    # domain tunes using MIDI pitches.
    log_info "Applying drum-rhythm-game Christmas/audio fixes..."
    cat > "$DRUM_DIR/html/ubuntu-post-install-fixes.js" <<'DRUM_FIXES_JS'
(() => {
  'use strict';

  const NOTE_TO_MIDI = { C: 0, D: 2, E: 4, F: 5, G: 7, A: 9, B: 11 };
  // Sourced tune corrections.  Do not add songs here from memory: every
  // melody/rhythm entry must point at a reproducible score/ABC source.
  // The properly sourced passes now cover Christmas songs from Milwaukee
  // Irish Fest School of Music, plus Sing Along and Classical songs from
  // abcnotation.com.  The classical selections below are public-domain
  // compositions; source URLs are retained for reproducible transcription.
  const CATEGORY_TUNES = {
    'jingle bells': {
      title: 'Jingle Bells', bpm: 112,
      source: 'Milwaukee Irish Fest School of Music ABC notation PDF: https://irishfestschoolofmusic.com/School-of-Music/Tunes/ifsm-polkas-xmas-jinglebells-abc.pdf',
      sourceAbc: '|: BB B2 | BB B2 | Bd GA | B4 | |cc c>c|cB B>B |[1 BA AB | A2 d2 :|[2 dd cA | G2- G2 || DB AG | D2- DD/D/ | DB AG | E2- EE/E/ | Ec BA | F2- FA/A/ | dd cA | B4 | DB AG | D2 DD/D/| DB AG | E2- EE/E/ | Ec BA | dd dd/d/ | ed cA | G2 d2|]',
      // Source metadata: M:2/4, L:1/8, K:Gmaj.  Repeats/endings are expanded
      // explicitly below so the game receives deterministic note events.
      melody: 'B4 B4 B4 B4 B4 B4 B4 B4 B4 D5 G4 A4 B4 C5 C5 C5 C5 C5 B4 B4 B4 B4 A4 A4 A4 B4 A4 D5 B4 B4 B4 B4 B4 B4 B4 B4 B4 D5 G4 A4 B4 C5 C5 C5 C5 C5 B4 B4 B4 B4 D5 D5 C5 A4 G4',
      beats:  '1 1 2 1 1 2 1 1 1 1 4 1 1 1.5 0.5 1 1.5 0.5 1 1 1 1 2 2 1 1 1 4 1 1 1 1 1 2 1 1 1 1 4 1 1 1.5 0.5 1 1.5 0.5 1 1 1 1 1 1 1 1 4'
    },
    'deck the halls': {
      title: 'Deck The Halls', bpm: 128,
      source: 'Milwaukee Irish Fest School of Music ABC notation PDF: https://irishfestschoolofmusic.com/School-of-Music/Tunes/ifsm-xmas-deckthehalls-abc.pdf',
      sourceAbc: '|: d3 c B2 A2 | G2 A2 B2 G2 | ABcA B3 A | G2 F2 G4 :| |A3 B c2 A2 |B3 c d2 A2 | Bc d2 ef g2 |f2 e2 d4 |d3 c B2 A2 | G2 A2 B2 G2 |ABcA B3 A | G2 F2 G4|]',
      melody: 'D5 C5 B4 A4 G4 A4 B4 G4 A4 B4 C5 A4 B4 A4 G4 F#4 G4 D5 C5 B4 A4 G4 A4 B4 G4 A4 B4 C5 A4 B4 A4 G4 F#4 G4 A4 B4 C5 A4 B4 C5 D5 A4 B4 C5 D5 E5 F#5 G5 F#5 E5 D5 D5 C5 B4 A4 G4 A4 B4 G4 A4 B4 C5 A4 B4 A4 G4 F#4 G4',
      beats:  '3 1 2 2 2 2 2 2 1 1 1 1 3 1 2 2 4 3 1 2 2 2 2 2 2 1 1 1 1 3 1 2 2 4 3 1 2 2 3 1 2 2 1 1 2 1 1 2 2 2 4 3 1 2 2 2 2 2 2 1 1 1 1 3 1 2 2 4'
    },
    'we wish you a merry christmas': {
      title: 'We Wish You a Merry Christmas', bpm: 108,
      source: 'Milwaukee Irish Fest School of Music ABC notation PDF: https://irishfestschoolofmusic.com/School-of-Music/Tunes/ifsm-waltz-xmas-wewishyouamerrychristmas-abc.pdf',
      sourceAbc: 'D2 ||G2 GA GF| E2 E2 E2|A2 AB AG |F2 D2 D2| |B2 Bc BA | G2 E2 DD | E2 A2 F2 | G4 D2|| |G2 G2 G2 | F4 F2 | G2 F2 E2 | D4 A2 | |B2 A2 GG | d2 D2 DD | E2 A2 F2 | G4 D2 |]',
      melody: 'D4 G4 G4 A4 G4 F#4 E4 E4 E4 A4 A4 B4 A4 G4 F#4 D4 D4 B4 B4 C5 B4 A4 G4 E4 D4 D4 E4 A4 F#4 G4 D4 G4 G4 G4 F#4 F#4 G4 F#4 E4 D4 A4 B4 A4 G4 G4 D5 D4 D4 E4 A4 F#4 G4 D4',
      beats:  '2 2 1 1 1 1 2 2 2 2 1 1 1 1 2 2 2 2 1 1 1 1 2 2 1 1 2 2 2 4 2 2 2 2 4 2 2 2 2 4 2 2 2 1 1 2 2 1 1 2 2 4 2'
    },
    'twinkle twinkle little star': {
      title: 'Twinkle, Twinkle, Little Star', bpm: 96,
      source: 'abcnotation.com tune page from the John Chambers abc collection: https://abcnotation.com/tunePage?a=trillian.mit.edu%2F~jc%2Fmusic%2Fabc%2Fmirror%2Fgulfweb.net%3A34043%2F~rlwalker%2Fabc%2Ftwinkle%2F0000',
      sourceAbc: '|"D"D D A A|"G"B B "D"A2|"G"G G "D"F F|"A"E/2E/2E/2E/2 "D"D2|"D"A A "G"G G|"D"F F "A"E2|"D"A A "G"G G|"D"F F "A"E2|"D"D D A A|"G"B B "D"A2|"G"G G "D"F F|"A"E/2E/2E/2E/2 "D"D2|]',
      // Source metadata: M:4/4, L:1/4, K:D.  F notes are raised for K:D.
      melody: 'D4 D4 A4 A4 B4 B4 A4 G4 G4 F#4 F#4 E4 E4 E4 E4 D4 A4 A4 G4 G4 F#4 F#4 E4 A4 A4 G4 G4 F#4 F#4 E4 D4 D4 A4 A4 B4 B4 A4 G4 G4 F#4 F#4 E4 E4 E4 E4 D4',
      beats:  '1 1 1 1 1 1 2 1 1 1 1 0.5 0.5 0.5 0.5 2 1 1 1 1 1 1 2 1 1 1 1 1 1 2 1 1 1 1 1 1 2 1 1 1 1 0.5 0.5 0.5 0.5 2'
    },
    'mary had a little lamb': {
      title: 'Mary had a little lamb', bpm: 108,
      source: 'abcnotation.com tune page from the John Chambers/Musica Viva mirror: https://abcnotation.com/tunePage?a=trillian.mit.edu%2F~jc%2Fmusic%2Fabc%2Fmirror%2Fmusicaviva.com%2Fengland%2Fmary-had-a-little-lamb-f%2F0000',
      sourceAbc: 'AGFG|AAA2|GGG2|AAA2|AGFG|AAAA|GGAG|F4|]',
      melody: 'A4 G4 F4 G4 A4 A4 A4 G4 G4 G4 A4 A4 A4 A4 G4 F4 G4 A4 A4 A4 A4 G4 G4 A4 G4 F4',
      beats:  '1 1 1 1 1 1 2 1 1 2 1 1 2 1 1 1 1 1 1 1 1 1 1 1 1 4'
    },
    'row row row your boat': {
      title: 'Row, row, row your boat', bpm: 100,
      source: 'abcnotation.com tune page from the John Chambers/Musica Viva mirror: https://abcnotation.com/tunePage?a=trillian.mit.edu%2F~jc%2Fmusic%2Fabc%2Fmirror%2Fmusicaviva.com%2Fengland%2Frow-row-c%2Frow-row-c-c24%2F0000',
      sourceAbc: 'C3 C3|C2D E3|E2D E2F|G6|ccc GGG|EEE CCC|G2F E2D|C6:|',
      melody: 'C4 C4 C4 D4 E4 E4 D4 E4 F4 G4 C5 C5 C5 G4 G4 G4 E4 E4 E4 C4 C4 C4 G4 F4 E4 D4 C4',
      beats:  '3 3 2 1 3 2 1 2 1 6 1 1 1 1 1 1 1 1 1 1 1 1 2 1 2 1 6'
    },
    'old macdonald': {
      title: 'Old Mac Donald', bpm: 140,
      source: 'abcnotation.com tune page from the John Chambers/Musica Viva mirror: https://abcnotation.com/tunePage?a=trillian.mit.edu%2F~jc%2Fmusic%2Fabc%2Fmirror%2Fmusicaviva.com%2Fengland%2Fold-mac-donald-f%2Fold-mac-donald-f-1%2F0000',
      sourceAbc: '"F"FFFC|"Bb"DD"F"C2|"G7"AA"C7"GG|"F"F2 z C|"F"FFFC|"Bb"DD"F"C2|"G7"AA"C7"GG|"F"F2 z2|]',
      melody: 'F4 F4 F4 C4 D4 D4 C4 A4 A4 G4 G4 F4 R C4 F4 F4 F4 C4 D4 D4 C4 A4 A4 G4 G4 F4 R',
      beats:  '1 1 1 1 1 1 2 1 1 1 1 2 1 1 1 1 1 1 1 1 2 1 1 1 1 2 2'
    },
    'ode to joy': {
      title: 'Ode to Joy', bpm: 112,
      publicDomainComposition: true,
      composer: 'Ludwig van Beethoven',
      source: 'abcnotation.com tune page from the John Chambers mirror: https://abcnotation.com/tunePage?a=trillian.mit.edu%2F~jc%2Fmusic%2Fabc%2Fmirror%2Fmindspring.com%2F~thornton.rose%2FOdeToJoy%2F0001',
      sourceAbc: 'F F G A | A G F E | D D E F | F>E E2 | F F G A | A G F E | D D E F | E>D D2 |: E E F D | E F/2G/2 F D | E F/2G/2 F E | D E A,2 | F F G A | A G F E | D D E F | E>D D2 :|',
      // Source metadata: C:L. Van Beethoven, M:4/4, L:1/4, K:D. F notes are raised for K:D.
      melody: 'F#4 F#4 G4 A4 A4 G4 F#4 E4 D4 D4 E4 F#4 F#4 E4 E4 F#4 F#4 G4 A4 A4 G4 F#4 E4 D4 D4 E4 F#4 E4 D4 D4 E4 E4 F#4 D4 E4 F#4 G4 F#4 D4 E4 F#4 G4 F#4 E4 D4 E4 A3 F#4 F#4 G4 A4 A4 G4 F#4 E4 D4 D4 E4 F#4 E4 D4 D4',
      beats:  '1 1 1 1 1 1 1 1 1 1 1 1 1.5 0.5 2 1 1 1 1 1 1 1 1 1 1 1 1 1.5 0.5 2 1 1 1 1 1 0.5 0.5 1 1 1 0.5 0.5 1 1 1 1 2 1 1 1 1 1 1 1 1 1 1 1 1 1.5 0.5 2'
    },
    'minuet in g major': {
      title: 'Minuet in G Major', bpm: 108,
      publicDomainComposition: true,
      composer: 'Christian Petzold',
      source: 'abcnotation.com tune page for BWV Anhang 114: https://abcnotation.com/tunePage?a=spuds.thursdaycontra.com%2FTuneSwaps%2FSPUDS_TS20_Old%2F0012',
      sourceAbc: 'd G/A/ B/c/ | d G G | e c/d/e/f/ | g G G |',
      // Source metadata: C:Christian Petzold (1677-1733), formerly attributed to J. S. Bach; L:1/4, M:3/4, K:G.
      melody: 'D5 G4 A4 B4 C5 D5 G4 G4 E5 C5 D5 E5 F#5 G5 G4 G4',
      beats:  '1 0.5 0.5 0.5 0.5 1 1 1 1 0.5 0.5 0.5 0.5 1 1 1'
    }
  };

  const toMidi = (note) => {
    if (!note || note === 'R') return null;
    const match = /^([A-G])([#b]?)(-?\d+)$/.exec(note);
    if (!match) return null;
    const accidental = match[2] === '#' ? 1 : match[2] === 'b' ? -1 : 0;
    return 12 * (Number(match[3]) + 1) + NOTE_TO_MIDI[match[1]] + accidental;
  };
  const freq = (midi) => 440 * (2 ** ((midi - 69) / 12));
  const tuneNotes = (tune) => {
    const notes = tune.melody.split(/\s+/);
    const beats = tune.beats.split(/\s+/);
    return notes.map((note, idx) => {
      const midi = toMidi(note);
      return { note, midi, frequency: midi == null ? 0 : freq(midi), beat: Number(beats[idx] || 1) };
    });
  };

  const findAudioContext = () => {
    const AudioCtor = window.AudioContext || window.webkitAudioContext;
    return AudioCtor ? safeObjectValues(window).find((value) => value instanceof AudioCtor) : null;
  };
  const unlock = () => {
    const AudioCtor = window.AudioContext || window.webkitAudioContext;
    window.__drumRhythmAudioContext = window.__drumRhythmAudioContext || (AudioCtor ? new AudioCtor() : null);
    [window.__drumRhythmAudioContext, findAudioContext()].filter(Boolean).forEach((ctx) => ctx.state === 'suspended' && ctx.resume());
  };
  ['pointerdown', 'keydown', 'gamepadconnected', 'touchstart', 'click'].forEach((eventName) => window.addEventListener(eventName, unlock, { passive: true }));

  const padSound = (index = 0) => {
    unlock();
    const ctx = window.__drumRhythmAudioContext;
    if (!ctx) return;
    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = ['sine', 'triangle', 'square', 'sawtooth'][index % 4];
    osc.frequency.setValueAtTime([110, 146.83, 196, 246.94, 329.63, 392][index % 6], now);
    gain.gain.setValueAtTime(0.24, now);
    gain.gain.exponentialRampToValueAtTime(0.001, now + 0.13);
    osc.connect(gain).connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.14);
  };
  window.ubuntuPostInstallDrumPadSound = padSound;

  document.addEventListener('pointerdown', (event) => {
    const pad = event.target.closest('[data-pad], .pad, .drum-pad, button');
    if (!pad || /play|start|stop|pause|song/i.test(pad.textContent || '')) return;
    padSound([...document.querySelectorAll('[data-pad], .pad, .drum-pad, button')].indexOf(pad));
  }, true);

  const normalize = (name) => String(name || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();
  const safeObjectValues = (object) => Object.keys(object).flatMap((key) => {
    try {
      return [object[key]];
    } catch (_error) {
      return [];
    }
  });
  const safeWindowObjects = () => safeObjectValues(window).filter((value) => value && typeof value === 'object');
  const patchSongs = () => {
    for (const root of [window, ...safeWindowObjects()]) {
      for (const key of Object.keys(root)) {
        let list;
        try {
          list = root[key];
        } catch (_error) {
          continue;
        }
        if (!Array.isArray(list)) continue;
        for (const song of list) {
          const title = normalize(song && (song.title || song.name));
          const tuneKey = Object.keys(CATEGORY_TUNES).find((candidate) => title.includes(candidate));
          if (!tuneKey) continue;
          const tune = CATEGORY_TUNES[tuneKey];
          song.title = song.title || tune.title;
          song.name = song.name || tune.title;
          song.bpm = tune.bpm;
          song.notes = tuneNotes(tune);
          song.melody = tune.melody;
          song.beats = tune.beats;
        }
      }
    }
  };
  window.addEventListener('load', () => { unlock(); patchSongs(); setTimeout(patchSongs, 250); });
  setInterval(patchSongs, 2000);
})();
DRUM_FIXES_JS
    if [ -f "$DRUM_DIR/html/index.html" ] && ! grep -q "ubuntu-post-install-fixes.js" "$DRUM_DIR/html/index.html"; then
        sed -i 's#</body>#  <script src="ubuntu-post-install-fixes.js"></script>\n</body>#' "$DRUM_DIR/html/index.html"
    fi

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DRUM_DIR/html"

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh):
    # explicit CADDY_MODE from the site config wins, then a local ~/docker/caddy,
    # then the legacy CADDY_REMOTE_HOST var. Only "local" joins caddy_net — a
    # remote Caddy box can't resolve container names on this host's bridge
    # network anyway; it reaches this service via the host's published port.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ] && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"

    local _CADDY_NET_BLOCK=""
    local _CADDY_NET_SECTION=""
    if [ "$_CADDY_MODE" = "local" ]; then
        _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
    fi

    cat > docker-compose.yml << DRUM_COMPOSE
name: drum-rhythm-game

services:
  drum-rhythm-game:
    build:
      context: ./html
    container_name: drum-rhythm-game
    hostname: drum-rhythm-game
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:80"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
DRUM_COMPOSE

    cat > .env << DRUM_ENV
CADDY_NET=${SITE_CADDY_NET}
DRUM_ENV

    ensure_docker_dir_ownership "$DRUM_DIR"
    log_success "drum-rhythm-game configured at $DRUM_DIR"

    # No built-in auth — offer Authelia SSO protection
    local DRUM_EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect drum-rhythm-game with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && DRUM_EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "Drum Rhythm Game" "drum-rhythm-game:80" "drums" "$DRUM_EXTRA_BLOCK"

    write_readme "$DRUM_DIR" << MD
# Drum Rhythm Game

Browser-based drum rhythm game — 18 genres covering 119 synth-orchestra
songs (nursery rhymes, sea shanties, Christmas, folk, spirituals, world,
ragtime, classical, video game themes, chiptune originals) plus 120 drum
beat patterns across 8 genres (rock, metal, jazz, hip hop, funk, latin,
electronic, country). Supports keyboard, Wii/Xbox/PS Rock Band drums,
Guitar Hero drums, or any USB gamepad via the in-game Remap Pads button.
Multiplayer take-turns mode, adjustable speed/volume, and a leaderboard —
all state lives in browser localStorage. No server required; all audio is
synthesized in-browser via the Web Audio API.

Built and served from the repo's own \`Dockerfile\` (nginx + gzip + a
\`/healthz\` endpoint) — only \`index.html\` ends up in the image, so the
repo's docs/license/dev files never get served.

Source: https://github.com/outis1one/drum-rhythm-game

## Access
- URL: http://localhost:${WEB_PORT}

## Manage
\`\`\`bash
cd ~/docker/drum-rhythm-game
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
\`\`\`

## Update game
\`\`\`bash
cd ~/docker/drum-rhythm-game
git -C html pull
docker compose up -d --build
\`\`\`
MD

    local START_DRUM=""
    prompt_yn "Start drum-rhythm-game now? (y/n):" "y" START_DRUM
    if [ "$START_DRUM" = "y" ] || [ "$START_DRUM" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Drum Rhythm Game started — http://localhost:${WEB_PORT}" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "  URL:         http://localhost:8096"
    echo "  Controls:    keyboard, USB Rock Band/Guitar Hero drums, or any USB gamepad (Remap Pads in-game)"
    echo "  Update:      git -C $DRUM_DIR/html pull && docker compose -f $DRUM_DIR/docker-compose.yml up -d --build"
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_drum-rhythm-game
