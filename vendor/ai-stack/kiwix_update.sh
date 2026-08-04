#!/bin/bash
# =============================================================================
# Kiwix ZIM Auto-Updater
# Checks each ZIM for a newer version on the mirror, downloads it, removes old.
# Safe to run as a cron job — only acts when a newer version exists.
# Usage: bash kiwix_update.sh
# Cron example (monthly): 0 3 1 * * /bin/bash /path/to/kiwix_update.sh
# =============================================================================

KIWIX_DIR="$HOME/docker/ai-stack/kiwix"
MIRROR="https://ftp.fau.de/kiwix/zim"
MIRROR2="https://download.kiwix.org/zim"
LOG="$HOME/docker/ai-stack/logs/kiwix-update.log"
mkdir -p "$KIWIX_DIR" "$(dirname "$LOG")"

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; R='\033[0;31m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N}  $1" | tee -a "$LOG"; }
inf() { echo -e "${C}[..]${N}  $1" | tee -a "$LOG"; }
wrn() { echo -e "${Y}[!!]${N}  $1" | tee -a "$LOG"; }
err() { echo -e "${R}[XX]${N}  $1" | tee -a "$LOG"; }

echo "" | tee -a "$LOG"
echo "=== Kiwix Update Check: $(date) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"

# Find latest filename on mirror
latest_zim() {
    local base_url="$1"
    local pattern="$2"
    curl -s "$base_url/" | \
        grep -oP "${pattern}_[\d-]+\.zim" | \
        sort -u | tail -1
}

# Find what's currently on disk matching a pattern
current_zim() {
    local pattern="$1"
    ls "$KIWIX_DIR"/${pattern}_*.zim 2>/dev/null | sort | tail -1 | xargs basename 2>/dev/null
}

# Check and update one ZIM
# Usage: check_update "category" "pattern" "description" ["mirror"]
UPDATED=0
check_update() {
    local category="$1"
    local pattern="$2"
    local description="$3"
    local mirror="${4:-$MIRROR}"

    inf "Checking $description..."
    local latest
    latest=$(latest_zim "$mirror/$category" "$pattern")

    if [[ -z "$latest" ]]; then
        wrn "$description: could not find latest on mirror — skipping"
        return
    fi

    local current
    current=$(current_zim "$pattern")

    if [[ -z "$current" ]]; then
        inf "$description: not downloaded yet — skipping (run kiwix_download.sh first)"
        return
    fi

    if [[ "$latest" == "$current" ]]; then
        ok "$description: up to date ($current)"
        return
    fi

    echo ""
    inf "$description: update available"
    inf "  Current: $current"
    inf "  Latest:  $latest"

    local url="$mirror/$category/$latest"
    local dest="$KIWIX_DIR/$latest"
    local old="$KIWIX_DIR/$current"

    inf "  Downloading $latest..."
    if wget -q --show-progress -c "$url" -O "$dest" >> "$LOG" 2>&1; then
        ok "  Download complete — removing old file"
        rm -f "$old"
        UPDATED=$((UPDATED + 1))
    else
        err "  Download failed — keeping old file"
        rm -f "$dest"
    fi
    echo ""
}

# ── Check each ZIM ─────────────────────────────────────────────────────────
check_update "wikipedia"     "wikipedia_en_all_nopic"          "Wikipedia"
check_update "wiktionary"    "wiktionary_en_all_nopic"         "Wiktionary"
check_update "wikiquote"     "wikiquote_en_all_nopic"          "Wikiquote"
check_update "wikisource"    "wikisource_en_all_nopic"         "Wikisource"
check_update "wikibooks"     "wikibooks_en_all_nopic"          "Wikibooks"
check_update "wikivoyage"    "wikivoyage_en_all_nopic"         "Wikivoyage"
check_update "wikiversity"   "wikiversity_en_all_nopic"        "Wikiversity"
check_update "wikinews"      "wikinews_en_all_nopic"           "WikiNews"
check_update "vikidia"       "vikidia_en_all_nopic"            "Vikidia"
check_update "stack_exchange" "stackoverflow.com_en_all"       "Stack Overflow"
check_update "stack_exchange" "askubuntu.com_en_all"           "Ask Ubuntu"
check_update "stack_exchange" "superuser.com_en_all"           "Super User"
check_update "stack_exchange" "unix.stackexchange.com_en_all"  "Unix & Linux SE"
check_update "stack_exchange" "serverfault.com_en_all"         "Server Fault"
check_update "other"         "archlinux_en_all_maxi"           "Arch Wiki"
check_update "ted"           "ted_mul_youth"                   "TED Talks"
check_update "phet"          "phet_en_all"                     "PhET Simulations"
check_update "devdocs"       "devdocs_en_zig"                  "DevDocs"
check_update "freecodecamp"  "freecodecamp_en_all"             "FreeCodeCamp"
check_update "ifixit"        "ifixit_en_all"                   "iFixit"
check_update "libretexts"    "libretexts.org_en_workforce"     "LibreTexts"
check_update "gutenberg"     "gutenberg_en_all"                "Project Gutenberg" "$MIRROR2"

# ── Restart Kiwix if anything changed ─────────────────────────────────────
echo ""
if [[ $UPDATED -gt 0 ]]; then
    ok "$UPDATED ZIM(s) updated — restarting Kiwix container"
    docker compose -f "$HOME/docker/ai-stack/docker-compose.yml" restart kiwix >> "$LOG" 2>&1 \
        && ok "Kiwix restarted" \
        || wrn "Could not restart Kiwix — do it manually: docker compose restart kiwix"
else
    ok "All ZIMs are up to date — no restart needed"
fi

echo ""
echo "=== Update check complete: $(date) ===" | tee -a "$LOG"
echo ""
