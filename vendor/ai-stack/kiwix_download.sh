#!/bin/bash
# =============================================================================
# Kiwix ZIM Download Script
# Downloads all ZIM files to ~/docker/ai-stack/kiwix/
# Finds latest version of each file automatically
# Usage: bash kiwix-download.sh
# =============================================================================

KIWIX_DIR="$HOME/docker/ai-stack/kiwix"
MIRROR="https://ftp.fau.de/kiwix/zim"
MIRROR2="https://download.kiwix.org/zim"   # fallback for files missing on fau.de
LOG="$HOME/docker/ai-stack/logs/kiwix-download.log"
mkdir -p "$KIWIX_DIR" "$(dirname "$LOG")"

G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; N='\033[0m'
ok()  { echo -e "${G}[OK]${N}  $1" | tee -a "$LOG"; }
inf() { echo -e "${C}[..]${N}  $1" | tee -a "$LOG"; }
wrn() { echo -e "${Y}[!!]${N}  $1" | tee -a "$LOG"; }

# Find latest version of a ZIM file from mirror
# Usage: latest_zim "base_url" "pattern"
latest_zim() {
    local base_url="$1"
    local pattern="$2"
    curl -s "$base_url/" | \
        grep -oP "${pattern}_[\d-]+\.zim" | \
        sort -u | tail -1
}

# Download a ZIM file if not already present
# Usage: download_zim "category" "filename" "description" "size" ["mirror"]
download_zim() {
    local category="$1"
    local filename="$2"
    local description="$3"
    local size="$4"
    local mirror="${5:-$MIRROR}"
    local url="$mirror/$category/$filename"
    local dest="$KIWIX_DIR/$filename"

    if [[ -f "$dest" ]]; then
        ok "$description already downloaded — skipping"
        return
    fi

    inf "Queuing: $description (~$size)"
    inf "  URL: $url"

    nohup wget -c "$url" -O "$dest" \
        >> "$LOG" 2>&1 &
    echo $! >> "$KIWIX_DIR/.download_pids"
    ok "Started download PID $! — $description"
}

echo "" | tee -a "$LOG"
echo "=== Kiwix Download Started: $(date) ===" | tee -a "$LOG"
echo "" | tee -a "$LOG"
echo -e "${C}Finding latest versions...${N}"
echo ""

# ── Find latest filenames ──────────────────────────────────────────────────
inf "Checking Wikipedia..."
WIKI=$(latest_zim "$MIRROR/wikipedia" "wikipedia_en_all_nopic")

inf "Checking Wiktionary..."
WIKT=$(latest_zim "$MIRROR/wiktionary" "wiktionary_en_all_nopic")

inf "Checking Wikiquote..."
WIKQ=$(latest_zim "$MIRROR/wikiquote" "wikiquote_en_all_nopic")

inf "Checking Wikisource..."
WIKS=$(latest_zim "$MIRROR/wikisource" "wikisource_en_all_nopic")

inf "Checking Wikibooks..."
WIKB=$(latest_zim "$MIRROR/wikibooks" "wikibooks_en_all_nopic")

inf "Checking Wikivoyage..."
WIKV=$(latest_zim "$MIRROR/wikivoyage" "wikivoyage_en_all_nopic")

inf "Checking Wikiversity..."
WIKUNI=$(latest_zim "$MIRROR/wikiversity" "wikiversity_en_all_nopic")

inf "Checking WikiNews..."
WIKNEWS=$(latest_zim "$MIRROR/wikinews" "wikinews_en_all_nopic")

inf "Checking Vikidia (kids K-8)..."
VIKIDIA=$(latest_zim "$MIRROR/vikidia" "vikidia_en_all_nopic")

# Stack Exchange sites: domain-style filenames in stack_exchange/
inf "Checking Stack Overflow..."
SO=$(latest_zim "$MIRROR/stack_exchange" "stackoverflow.com_en_all")

inf "Checking Ask Ubuntu..."
ASKUBUNTU=$(latest_zim "$MIRROR/stack_exchange" "askubuntu.com_en_all")

inf "Checking Super User..."
SUPERUSER=$(latest_zim "$MIRROR/stack_exchange" "superuser.com_en_all")

inf "Checking Unix & Linux SE..."
UNIX=$(latest_zim "$MIRROR/stack_exchange" "unix.stackexchange.com_en_all")

inf "Checking Server Fault..."
SERVERFAULT=$(latest_zim "$MIRROR/stack_exchange" "serverfault.com_en_all")

# Arch Wiki: _maxi is part of the base name, not the date stamp
inf "Checking Arch Wiki..."
ARCH=$(latest_zim "$MIRROR/other" "archlinux_en_all_maxi")

# TED: lives in ted/ folder, mul_youth variant
inf "Checking TED Talks..."
TED=$(latest_zim "$MIRROR/ted" "ted_mul_youth")

# PhET: own folder
inf "Checking PhET Simulations..."
PHET=$(latest_zim "$MIRROR/phet" "phet_en_all")

# DevDocs: variant is zig not all
inf "Checking DevDocs..."
DEVDOCS=$(latest_zim "$MIRROR/devdocs" "devdocs_en_zig")

inf "Checking FreeCodeCamp..."
FCC=$(latest_zim "$MIRROR/freecodecamp" "freecodecamp_en_all")

inf "Checking iFixit..."
IFIX=$(latest_zim "$MIRROR/ifixit" "ifixit_en_all")

# LibreTexts: own folder, workforce variant (no _all on this mirror)
inf "Checking LibreTexts..."
LIBRE=$(latest_zim "$MIRROR/libretexts" "libretexts.org_en_workforce")

# Gutenberg: en_all exists on download.kiwix.org, not ftp.fau.de
inf "Checking Project Gutenberg..."
GUT=$(latest_zim "$MIRROR2/gutenberg" "gutenberg_en_all")

echo ""
echo -e "${C}═══════════════════════════════════════════════════${N}"
echo -e "${C}  Download Queue${N}"
echo -e "${C}═══════════════════════════════════════════════════${N}"
echo ""
echo "  Wikipedia (no images)     ${WIKI:-NOT FOUND}     ~46GB"
echo "  Wiktionary                ${WIKT:-NOT FOUND}     ~2GB"
echo "  Wikiquote                 ${WIKQ:-NOT FOUND}     ~300MB"
echo "  Wikisource                ${WIKS:-NOT FOUND}     ~4GB"
echo "  Wikibooks                 ${WIKB:-NOT FOUND}     ~500MB"
echo "  Wikivoyage                ${WIKV:-NOT FOUND}     ~200MB"
echo "  Wikiversity               ${WIKUNI:-NOT FOUND}   ~500MB"
echo "  WikiNews                  ${WIKNEWS:-NOT FOUND}  ~300MB"
echo "  Vikidia (kids K-8)        ${VIKIDIA:-NOT FOUND}  ~66MB"
echo "  Stack Overflow            ${SO:-NOT FOUND}       ~3GB"
echo "  Ask Ubuntu                ${ASKUBUNTU:-NOT FOUND}  ~1GB"
echo "  Super User                ${SUPERUSER:-NOT FOUND}  ~1GB"
echo "  Unix & Linux SE           ${UNIX:-NOT FOUND}     ~500MB"
echo "  Server Fault              ${SERVERFAULT:-NOT FOUND} ~500MB"
echo "  Arch Linux Wiki           ${ARCH:-NOT FOUND}     ~30MB"
echo "  TED Talks                 ${TED:-NOT FOUND}      ~5GB"
echo "  PhET Simulations          ${PHET:-NOT FOUND}     ~500MB"
echo "  DevDocs                   ${DEVDOCS:-NOT FOUND}  ~1GB"
echo "  FreeCodeCamp              ${FCC:-NOT FOUND}      ~small"
echo "  iFixit (repair guides)    ${IFIX:-NOT FOUND}     ~2GB"
echo "  LibreTexts (textbooks)    ${LIBRE:-NOT FOUND}    ~varies"
echo "  Project Gutenberg         ${GUT:-NOT FOUND}      ~60GB"
echo ""
echo -e "${Y}  Total estimate: ~133GB — make sure you have space!${N}"
echo ""

df -h "$KIWIX_DIR" | tail -1 | awk '{print "  Available disk space: " $4}'
echo ""

read -rp "  Proceed with all downloads? (Y/n): " CONFIRM
[[ "${CONFIRM,,}" == "n" ]] && exit 0

# ── Start downloads ────────────────────────────────────────────────────────
echo ""
rm -f "$KIWIX_DIR/.download_pids"

[[ -n "$WIKI"    ]] && download_zim "wikipedia"     "$WIKI"    "Wikipedia (no images)"    "46GB"
[[ -n "$WIKT"    ]] && download_zim "wiktionary"    "$WIKT"    "Wiktionary"               "2GB"
[[ -n "$WIKQ"    ]] && download_zim "wikiquote"     "$WIKQ"    "Wikiquote"                "300MB"
[[ -n "$WIKS"    ]] && download_zim "wikisource"    "$WIKS"    "Wikisource"               "4GB"
[[ -n "$WIKB"    ]] && download_zim "wikibooks"     "$WIKB"    "Wikibooks"                "500MB"
[[ -n "$WIKV"    ]] && download_zim "wikivoyage"    "$WIKV"    "Wikivoyage"               "200MB"
[[ -n "$WIKUNI"  ]] && download_zim "wikiversity"   "$WIKUNI"  "Wikiversity"              "500MB"
[[ -n "$WIKNEWS" ]] && download_zim "wikinews"      "$WIKNEWS" "WikiNews"                 "300MB"
[[ -n "$VIKIDIA" ]] && download_zim "vikidia"       "$VIKIDIA" "Vikidia (kids K-8)"       "66MB"
[[ -n "$SO"          ]] && download_zim "stack_exchange" "$SO"          "Stack Overflow"       "3GB"
[[ -n "$ASKUBUNTU"   ]] && download_zim "stack_exchange" "$ASKUBUNTU"   "Ask Ubuntu"           "1GB"
[[ -n "$SUPERUSER"   ]] && download_zim "stack_exchange" "$SUPERUSER"   "Super User"           "1GB"
[[ -n "$UNIX"        ]] && download_zim "stack_exchange" "$UNIX"        "Unix & Linux SE"      "500MB"
[[ -n "$SERVERFAULT" ]] && download_zim "stack_exchange" "$SERVERFAULT" "Server Fault"         "500MB"
[[ -n "$ARCH"    ]] && download_zim "other"         "$ARCH"    "Arch Linux Wiki"          "30MB"
[[ -n "$TED"     ]] && download_zim "ted"           "$TED"     "TED Talks"                "5GB"
[[ -n "$PHET"    ]] && download_zim "phet"          "$PHET"    "PhET Simulations"         "500MB"
[[ -n "$DEVDOCS" ]] && download_zim "devdocs"       "$DEVDOCS" "DevDocs"                  "1GB"
[[ -n "$FCC"     ]] && download_zim "freecodecamp"  "$FCC"     "FreeCodeCamp"             "small"
[[ -n "$IFIX"    ]] && download_zim "ifixit"        "$IFIX"    "iFixit (repair guides)"   "2GB"
[[ -n "$LIBRE"   ]] && download_zim "libretexts"    "$LIBRE"   "LibreTexts (textbooks)"   "varies"
[[ -n "$GUT"     ]] && download_zim "gutenberg"     "$GUT"     "Project Gutenberg"        "60GB"   "$MIRROR2"

echo ""
echo -e "${G}════════════════════════════════════════════════════${N}"
echo -e "${G}  All downloads started in background${N}"
echo -e "${G}════════════════════════════════════════════════════${N}"
echo ""
echo "  Monitor progress:"
echo "    tail -f $LOG"
echo ""
echo "  Check file sizes growing:"
echo "    watch -n 60 'ls -lh $KIWIX_DIR/'"
echo ""
echo "  Check active downloads:"
echo "    jobs -l"
echo "    ps aux | grep wget"
echo ""
echo "  Once all downloads complete, restart Kiwix:"
echo "    cd ~/docker/ai-stack"
echo "    docker compose up -d kiwix"
echo ""
echo -e "${Y}  NOTE: Downloads resume automatically if interrupted (-c flag)${N}"
