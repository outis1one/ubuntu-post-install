#!/bin/bash
# setup.sh — modular post-install dispatcher.
#
# One source of truth, multiple ways to run it:
#   sudo ./setup.sh                 guided install: required packages, then a
#                                   category menu you loop through
#   sudo ./setup.sh <service> ...   install one or more services directly
#   ./setup.sh --list               list available services (grouped)
#   ./setup.sh --version            print version
#
# Flags:
#   --dry-run      preview actions without making changes
#   --unattended   use defaults, no prompts (pair with explicit service names)
#
# Every service lives in services/<name>.sh, registers itself with
# register_service, and defines install_<name>. Adding a service = adding one
# file; it appears in the menu automatically. Nothing is generated.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# whiptail requires a valid TERM; when piped through bash (curl | bash) TERM
# may be unset, causing raw-mode to fail and arrow keys to leak to the shell.
export TERM="${TERM:-xterm-256color}"

# Category display order (groups not listed here are appended alphabetically).
CATEGORY_ORDER=(base homelab utilities media cameras gaming extras backup)
# Service ordering hint within a category (lower = earlier). Default 50.
declare -A SERVICE_PRIORITY=( [caddy]=1 [crowdsec]=2 [authelia]=3 )

# ── Parse flags / collect service names ──────────────────────────────────────
DRY_RUN=false; UNATTENDED=false; DO_LIST=false
REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --unattended) UNATTENDED=true ;;
        --list|-l)    DO_LIST=true ;;
        --version|-V) cat "$HERE/VERSION" 2>/dev/null || echo "unknown"; exit 0 ;;
        -h|--help)    sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)  REQUESTED+=("$arg") ;;
    esac
done
export DRY_RUN UNATTENDED

# ── Load helpers + all service modules (they self-register) ──────────────────
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
shopt -s nullglob
for _mod in "$HERE"/services/*.sh; do source "$_mod"; done
shopt -u nullglob

# ── Helpers over the registry ────────────────────────────────────────────────
# Groups present, in CATEGORY_ORDER first, then any extras alphabetically.
groups_present() {
    local g present=() seen=" "
    for name in "${SERVICE_ORDER[@]}"; do
        g="${SERVICE_GROUP[$name]}"
        case "$seen" in *" $g "*) : ;; *) present+=("$g"); seen="$seen$g " ;; esac
    done
    local out=()
    for g in "${CATEGORY_ORDER[@]}"; do
        printf '%s\n' "${present[@]}" | grep -qx "$g" && out+=("$g")
    done
    for g in "${present[@]}"; do
        printf '%s\n' "${CATEGORY_ORDER[@]}" | grep -qx "$g" || out+=("$g")
    done
    printf '%s\n' "${out[@]}"
}

# Services in a group, ordered by SERVICE_PRIORITY then name.
services_in_group() {
    local group="$1" name
    for name in "${SERVICE_ORDER[@]}"; do
        [ "${SERVICE_GROUP[$name]}" = "$group" ] && echo "${SERVICE_PRIORITY[$name]:-50} $name"
    done | sort -n -k1 | awk '{print $2}'
}

# Best-effort "is it already installed?" for the [installed] marker.
is_installed() {
    case "$1" in
        base) command -v ncdu >/dev/null 2>&1 ;;
        glow) command -v glow >/dev/null 2>&1 ;;
        crowdsec) command -v cscli >/dev/null 2>&1 ;;
        kdeconnect) command -v kdeconnect >/dev/null 2>&1 ;;
        silent-send) [ -d "$ACTUAL_HOME/silent-send/.git" ] ;;
        sync-cc) [ -f "$ACTUAL_HOME/sync-cc/sync_cc.py" ] ;;
        sky-cam) [ -d "$ACTUAL_HOME/sky-cam/.git" ] ;;
        *) [ -e "$DOCKER_DIR/$1" ] ;;
    esac
}

run_service() {
    local name="$1"
    if [ -z "${SERVICE_GROUP[$name]:-}" ]; then log_error "Unknown service: $name (try --list)"; return 1; fi
    declare -F "install_${name}" >/dev/null || { log_error "Service '$name' has no install_${name}"; return 1; }
    log_info "=== ${name} (${SERVICE_DESC[$name]}) ==="
    "install_${name}"
}

list_services() {
    local g name
    while IFS= read -r g; do
        echo ""; echo "── ${g^^} ──"
        while IFS= read -r name; do
            printf "  %-16s %s\n" "$name" "${SERVICE_DESC[$name]}"
        done < <(services_in_group "$g")
    done < <(groups_present)
    echo ""
}

# ── Site defaults wizard ──────────────────────────────────────────────────────
# Prompts for timezone, base domain, and Caddy network name; saves to .config.
# Run directly:  sudo ./setup.sh configure
run_site_configure() {
    local _sys_tz; _sys_tz=$(cat /etc/timezone 2>/dev/null || echo "UTC")
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Site defaults  ·  pre-filled into every service prompt     ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  These become the default answer each time a service asks for"
    echo "  timezone, domain, etc.  Press Enter to keep the shown value."
    echo ""
    local _cur_tz="${SITE_TZ:-$_sys_tz}"
    local _cur_dom="${SITE_DOMAIN:-}"
    local _cur_net="${SITE_CADDY_NET:-caddy_net}"
    # Resolve current Caddy mode for display — handle legacy CADDY_REMOTE_HOST
    local _cur_mode="${CADDY_MODE:-}"
    [ -z "$_cur_mode" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _cur_mode="remote"
    [ -z "$_cur_mode" ] && _cur_mode="local"

    prompt_text "  Timezone [${_cur_tz}]:" "$_cur_tz" SITE_TZ
    prompt_text "  Base domain (e.g., example.com) [${_cur_dom:-<not set>}]:" "$_cur_dom" SITE_DOMAIN
    prompt_text "  Caddy Docker network [${_cur_net}]:" "$_cur_net" SITE_CADDY_NET

    echo ""
    echo "  Where does Caddy run?"
    echo "    [1] This machine  — Caddy installed here (default)"
    echo "    [2] Remote machine — different server, VPN node, or Netbird peer"
    echo "        (service installers save snippet files to ~/docker/caddy-snippets/)"
    echo "    [3] None / skip   — configure Caddy later"
    echo ""
    local _caddy_default="1"
    case "$_cur_mode" in remote) _caddy_default="2" ;; none) _caddy_default="3" ;; esac
    local _caddy_choice=""
    prompt_text "  Caddy location [${_caddy_default}]:" "$_caddy_default" _caddy_choice
    case "${_caddy_choice:-$_caddy_default}" in
        2) CADDY_MODE="remote" ;;
        3) CADDY_MODE="none"   ;;
        *) CADDY_MODE="local"  ;;
    esac
    CADDY_REMOTE_HOST=""   # clear legacy value; CADDY_MODE is authoritative now

    export SITE_TZ SITE_DOMAIN SITE_CADDY_NET CADDY_MODE CADDY_REMOTE_HOST
    mkdir -p "$DOCKER_DIR"
    save_site_config
    log_success "Saved to $DOCKER_DIR/.config"
    echo ""
}

# ── --list ───────────────────────────────────────────────────────────────────
if [ "$DO_LIST" = true ]; then list_services; exit 0; fi

# ── configure: show/update site-wide defaults ────────────────────────────────
if [ "${REQUESTED[*]:-}" = "configure" ]; then
    require_root
    run_site_configure
    exit 0
fi

# ── Direct install: ./setup.sh caddy homeassistant ──────────────────────────
if [ "${#REQUESTED[@]}" -gt 0 ]; then
    require_root
    rc=0; for name in "${REQUESTED[@]}"; do run_service "$name" || rc=1; done
    exit "$rc"
fi

# ── Guided interactive flow ──────────────────────────────────────────────────
require_root

_VER="$(cat "$HERE/VERSION" 2>/dev/null || echo '?')"
_OS_LINE="${OS_DISTRO^} ${OS_VERSION} (${OS_CODENAME})"

if is_installed base; then
    # ── Re-run: base already present — skip required step ────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Ubuntu Post-Install  ·  v${_VER}  ·  ${_OS_LINE}"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Base packages already installed — skipping required setup."
    echo "  Use 'sudo ./setup.sh base' to force a reinstall."
    echo ""
else
    # ── First run: show required banner, confirm, install ────────────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Ubuntu Post-Install  ·  v${_VER}  ·  ${_OS_LINE}"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    if [ "$OS_DISTRO" != "ubuntu" ]; then
        log_warning "Detected OS: ${_OS_LINE} — this script targets Ubuntu. Proceed with caution."
        echo ""
    elif ! ubuntu_version_ge "24.04"; then
        log_warning "Ubuntu ${OS_VERSION} detected — tested on 24.04+. Some packages may differ."
        echo ""
    fi
    echo "REQUIRED (installed/verified first):"
    echo "  • Essential CLI packages: net-tools, git, curl, wget, htop, tree,"
    echo "    ncdu, zip/unzip, jq, rsync, and glow (markdown reader)"
    echo "  • Docker presence check (needed by all containerized services)"
    echo ""
    echo "Then you'll get a category menu to pick optional services."
    echo ""
    PROCEED=""
    prompt_yn "Proceed with the required setup? (y/n):" "y" PROCEED
    if [ "$PROCEED" != "y" ] && [ "$PROCEED" != "Y" ]; then
        echo "Cancelled. Nothing was changed."
        exit 0
    fi

    run_service base
    if ! command -v docker >/dev/null 2>&1; then
        log_warning "Docker is not installed. Containerized services need it."
        echo "  Install with:  curl -fsSL https://get.docker.com | sh"
    fi
fi

# 3) Offer site defaults wizard if .config has no SITE_TZ yet (first run).
if ! grep -q '^SITE_TZ=' "$DOCKER_DIR/.config" 2>/dev/null; then
    echo ""
    echo "  No site defaults found. Setting them now pre-fills timezone, domain,"
    echo "  and Caddy network for every service — you type them once, not every time."
    OFFER_CONFIG=""
    prompt_yn "Configure site defaults now? (y/n):" "y" OFFER_CONFIG
    if [ "$OFFER_CONFIG" = "y" ] || [ "$OFFER_CONFIG" = "Y" ]; then
        run_site_configure
        load_site_config   # reload so subsequent service prompts see the new values
    fi
fi

# 4) Offer Caddy first (most services proxy through it).
if [ -n "${SERVICE_GROUP[caddy]:-}" ] && ! is_installed caddy; then
    echo ""
    OFFER_CADDY=""
    prompt_yn "Install Caddy now? It's the reverse proxy most services use. (y/n):" "y" OFFER_CADDY
    [ "$OFFER_CADDY" = "y" ] || [ "$OFFER_CADDY" = "Y" ] && run_service caddy
fi

# 5) Category menu loop: pick a category → checklist → install → back to menu.
have_whiptail=false
command -v whiptail >/dev/null 2>&1 && have_whiptail=true

while true; do
    mapfile -t CATS < <(groups_present)

    if [ "$have_whiptail" = true ]; then
        cat_items=()
        for g in "${CATS[@]}"; do
            n=$(services_in_group "$g" | wc -l)
            cat_items+=("$g" "$n service(s)")
        done
        cat_items+=("DONE" "Finish and exit")
        CHOSEN_CAT=$(whiptail --title "Service Categories" --menu \
            "Pick a category (services you install come back here):" 22 70 14 \
            "${cat_items[@]}" 3>&1 1>&2 2>&3 </dev/tty) || break
    else
        echo ""; echo "Categories:"; i=1
        for g in "${CATS[@]}"; do echo "  $i) $g"; i=$((i+1)); done
        echo "  d) Done"
        read -rp "Pick a category [d]: " pick
        [ "$pick" = "d" ] || [ -z "$pick" ] && break
        CHOSEN_CAT="${CATS[$((pick-1))]:-}"
        [ -z "$CHOSEN_CAT" ] && { echo "Invalid."; continue; }
    fi
    [ "$CHOSEN_CAT" = "DONE" ] && break

    mapfile -t SVCS < <(services_in_group "$CHOSEN_CAT")
    SELECTED=()
    if [ "$have_whiptail" = true ]; then
        svc_items=()
        for name in "${SVCS[@]}"; do
            tag="${SERVICE_DESC[$name]}"
            is_installed "$name" && tag="$tag  [installed]"
            svc_items+=("$name" "$tag" "OFF")
        done
        CHOICE=$(whiptail --title "${CHOSEN_CAT^^}" --checklist \
            "Space to select, Enter to install. Already-installed are marked:" 22 78 14 \
            "${svc_items[@]}" 3>&1 1>&2 2>&3 </dev/tty) || continue
        eval "SELECTED=($CHOICE)"
    else
        echo ""; echo "${CHOSEN_CAT^^}:"
        for name in "${SVCS[@]}"; do
            m=""; is_installed "$name" && m="  [installed]"
            printf "  %-16s %s%s\n" "$name" "${SERVICE_DESC[$name]}" "$m"
        done
        read -rp "Enter service names to install (space-separated, blank to go back): " -a SELECTED
    fi

    for name in "${SELECTED[@]}"; do run_service "$name"; done
done

echo ""
log_success "Done. Re-run 'sudo ./setup.sh' any time to add more."
