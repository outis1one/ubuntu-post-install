#!/bin/bash
# setup.sh — modular post-install dispatcher.
#
# One source of truth, multiple ways to run it:
#   sudo ./setup.sh                 guided install: required packages, then a
#                                   category menu you loop through
#   sudo ./setup.sh <service> ...   install one or more services directly
#   ./setup.sh --list               list available services (grouped)
#   ./setup.sh --status             list services with install status (no whiptail)
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
# Retired service names that now resolve to another service. Keeps a name
# that used to work on the command line (and in docs/muscle memory) working
# after a merge, without giving it a second menu entry of its own.
declare -A SERVICE_ALIAS=( [asterisk-digital-ocean]=asterisk )

# ── Parse flags / collect service names ──────────────────────────────────────
DRY_RUN=false; UNATTENDED=false; DO_LIST=false; DO_STATUS=false
REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --unattended) UNATTENDED=true ;;
        --list|-l)    DO_LIST=true ;;
        --status)     DO_STATUS=true ;;
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
        security-dashboard) [ -f /opt/security-dashboard/app.py ] ;;
        kdeconnect) command -v kdeconnect >/dev/null 2>&1 ;;
        silent-send) [ -d "$ACTUAL_HOME/silent-send/.git" ] ;;
        sync-cc) [ -f "$ACTUAL_HOME/sync-cc/sync_cc.py" ] ;;
        sky-cam) [ -d "$ACTUAL_HOME/sky-cam/.git" ] ;;
        sky-cam-frigate) [ -d "$ACTUAL_HOME/sky-cam/.git" ] && [ -f "$ACTUAL_HOME/sky-cam/frigate-retime.sh" ] ;;
        # Either directory counts: boxes set up before the droplet edition was
        # merged back into `asterisk` still run out of ~/docker/asterisk-digital-ocean.
        asterisk) [ -e "$DOCKER_DIR/asterisk" ] || [ -e "$DOCKER_DIR/asterisk-digital-ocean" ] ;;
        pstn-trunk) [ -f "$DOCKER_DIR/asterisk-digital-ocean/config/asterisk/pstn-trunk-pjsip.conf" ] || [ -f "$DOCKER_DIR/asterisk/config/asterisk/pstn-trunk-pjsip.conf" ] ;;
        sms-inbound) [ -f /opt/sms-inbound/settings.env ] ;;
        ssh-config) false ;;   # repeatable management tool, never shows [installed]
        # Every WordPress site is named from the first one on (no plain
        # $DOCKER_DIR/wordpress dir the default case below could match) —
        # [installed] means "at least one site exists", not any specific one.
        wordpress) compgen -G "$DOCKER_DIR/wordpress-*" >/dev/null 2>&1 ;;
        # Not a Docker service — state lives in tagged /etc/fstab entries
        # (services/vpn-data-mount.sh's own convention), not $DOCKER_DIR.
        vpn-data-mount) grep -q '^# vpn-data-mount:' /etc/fstab 2>/dev/null ;;
        *) [ -e "$DOCKER_DIR/$1" ] ;;
    esac
}

# How many instances of a service are installed — most services here are
# single-instance, but several support the multi-instance pattern from
# CLAUDE.md (a base install plus any number of "<name>-<suffix>" siblings,
# e.g. mattermost + mattermost-team-b). Only the default case knows that
# naming convention; the specially-cased services above aren't part of the
# multi-instance pattern (wordpress and vpn-data-mount are the exceptions
# and already count sites/mounts directly), so for those this just mirrors
# is_installed() as 0 or 1.
install_count() {
    case "$1" in
        base|glow|crowdsec|security-dashboard|kdeconnect|silent-send|sync-cc|sky-cam|sky-cam-frigate|asterisk|pstn-trunk|sms-inbound|ssh-config)
            is_installed "$1" && echo 1 || echo 0 ;;
        wordpress)
            find "$DOCKER_DIR" -mindepth 1 -maxdepth 1 -name 'wordpress-*' -type d 2>/dev/null | wc -l ;;
        vpn-data-mount)
            grep -c '^# vpn-data-mount:' /etc/fstab 2>/dev/null || echo 0 ;;
        *)
            local c=0
            [ -e "$DOCKER_DIR/$1" ] && c=1
            c=$((c + $(find "$DOCKER_DIR" -mindepth 1 -maxdepth 1 -name "$1-*" -type d 2>/dev/null | wc -l)))
            echo "$c"
            ;;
    esac
}

run_service() {
    local name="$1"
    if [ -n "${SERVICE_ALIAS[$name]:-}" ]; then
        log_info "'$name' is now part of '${SERVICE_ALIAS[$name]}' — running that instead."
        name="${SERVICE_ALIAS[$name]}"
    fi
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

# Plain-text version of the whiptail checklist's [installed] marker — same
# is_installed() calls, no whiptail involved. Exists so "is X actually
# installed" can be answered by reading terminal output directly instead of
# a checklist screen, where a narrow/resized terminal can truncate or wrap
# the "[installed]" suffix off-screen without it being obvious that's what
# happened.
print_status() {
    local g name marker count
    while IFS= read -r g; do
        echo ""; echo "── ${g^^} ──"
        while IFS= read -r name; do
            count="$(install_count "$name")"
            marker="not installed"
            [ "$count" -gt 0 ] && marker="INSTALLED (x$count)"
            printf "  %-20s %-16s %s\n" "$name" "$marker" "${SERVICE_DESC[$name]}"
        done < <(services_in_group "$g")
    done < <(groups_present)
    echo ""
}

# ── Site defaults wizard ──────────────────────────────────────────────────────
# Prompts for timezone, base domain, and Caddy network name; saves to .config.
# Run directly:  sudo ./setup.sh configure
# Asks only "where does Caddy run?" and saves it. Always runs unconditionally
# (not gated behind a y/n) since every service's Caddy prompt depends on this.
ask_caddy_location() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Where does Caddy run?                                       ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    # Resolve current Caddy mode for display — handle legacy CADDY_REMOTE_HOST
    local _cur_mode="${CADDY_MODE:-}"
    [ -z "$_cur_mode" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _cur_mode="remote"
    [ -z "$_cur_mode" ] && _cur_mode="local"

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
    echo ""

    export CADDY_MODE CADDY_REMOTE_HOST
    mkdir -p "$DOCKER_DIR"
    save_site_config
    log_success "Caddy mode saved: $CADDY_MODE"
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

    prompt_text "  Timezone [${_cur_tz}]:" "$_cur_tz" SITE_TZ
    prompt_text "  Base domain (e.g., example.com) [${_cur_dom:-<not set>}]:" "$_cur_dom" SITE_DOMAIN

    # Caddy Docker network only matters when Caddy runs locally — it's the
    # shared bridge network services join to reach a local Caddy container
    # by name. Remote/none Caddy proxies via localhost:PORT instead.
    if [ "$CADDY_MODE" = "local" ]; then
        prompt_text "  Caddy Docker network [${_cur_net}]:" "$_cur_net" SITE_CADDY_NET
    fi

    export SITE_TZ SITE_DOMAIN SITE_CADDY_NET CADDY_MODE CADDY_REMOTE_HOST
    mkdir -p "$DOCKER_DIR"
    save_site_config
    log_success "Saved to $DOCKER_DIR/.config"
    echo ""
}

# ── --list ───────────────────────────────────────────────────────────────────
if [ "$DO_LIST" = true ]; then list_services; exit 0; fi

# ── --status ─────────────────────────────────────────────────────────────────
if [ "$DO_STATUS" = true ]; then print_status; exit 0; fi

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
fi

# Always ensure Docker is present — base may have been installed before Docker
# was added to it, or a previous install may have failed.
if ! command -v docker &>/dev/null && ! [ -x /usr/bin/docker ]; then
    log_info "Docker not found — installing now..."
    require_docker
fi

# 3) Ask where Caddy runs (unconditional — every service's Caddy prompt
#    depends on this), then only offer the timezone/domain/network wizard
#    if Caddy is local to this box.
if ! grep -q '^CADDY_MODE=' "$DOCKER_DIR/.config" 2>/dev/null; then
    ask_caddy_location
    load_site_config   # reload so subsequent prompts see CADDY_MODE

    if [ "$CADDY_MODE" = "local" ]; then
        echo "  Setting timezone/domain now pre-fills them for every service —"
        echo "  you type them once, not every time."
        OFFER_CONFIG=""
        prompt_yn "Configure site defaults (timezone, domain, network) now? (y/n):" "y" OFFER_CONFIG
        if [ "$OFFER_CONFIG" = "y" ] || [ "$OFFER_CONFIG" = "Y" ]; then
            run_site_configure
            load_site_config   # reload so subsequent service prompts see the new values
        fi
    fi
fi

# 4) Offer Caddy first (most services proxy through it) — only when Caddy is
#    (or will be) local to this box. Remote/none mode means Caddy lives
#    elsewhere, so installing it here would be wrong.
if [ -n "${SERVICE_GROUP[caddy]:-}" ] && ! is_installed caddy \
    && [ "${CADDY_MODE:-local}" = "local" ]; then
    echo ""
    OFFER_CADDY=""
    prompt_yn "Install Caddy now? It's the reverse proxy most services use. (y/n):" "y" OFFER_CADDY
    [ "$OFFER_CADDY" = "y" ] || [ "$OFFER_CADDY" = "Y" ] && run_service caddy
fi

# 5) Installed-service summary — show status before every menu session.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  INSTALLED SERVICES"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
_any_installed=false
while IFS= read -r _g; do
    _group_header_printed=false
    while IFS= read -r _svc; do
        if is_installed "$_svc"; then
            if [ "$_group_header_printed" = false ]; then
                printf "\n  %-12s\n" "${_g^^}"
                _group_header_printed=true
            fi
            printf "    ✓ %-20s %s\n" "$_svc" "${SERVICE_DESC[$_svc]}"
            _any_installed=true
        fi
    done < <(services_in_group "$_g")
done < <(groups_present)
[ "$_any_installed" = false ] && echo "  (none yet)"
echo ""

# 6) Category menu loop: pick a category → checklist → install → back to menu.
have_whiptail=false
command -v whiptail >/dev/null 2>&1 && have_whiptail=true
# Ensure the terminal is in a clean state before handing control to whiptail.
stty sane </dev/tty 2>/dev/null || true

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
        # listheight was a flat 14 regardless of category size — utilities
        # alone has 35+ services, so anything past row 14 only reachable by
        # scrolling, with no on-screen hint that more rows exist below the
        # fold. Size it to the category instead, capped to what the actual
        # terminal can show (tput lines, falling back to a conservative 24
        # for a non-terminal/unknown size) so this can't request a dialog
        # taller than the screen.
        _term_lines="$(tput lines 2>/dev/null </dev/tty || echo 24)"
        _term_cols="$(tput cols 2>/dev/null </dev/tty || echo 80)"
        _list_h=${#SVCS[@]}
        [ "$_list_h" -gt 20 ] && _list_h=20
        _term_cap=$((_term_lines - 10))
        [ "$_term_cap" -lt 6 ] && _term_cap=6
        [ "$_list_h" -gt "$_term_cap" ] && _list_h="$_term_cap"
        _box_h=$((_list_h + 8))
        [ "$_box_h" -gt "$((_term_lines - 2))" ] && _box_h=$((_term_lines - 2))
        # Was a flat 78 regardless of actual terminal size — descriptions
        # got cut off mid-sentence on any terminal wider than that, with no
        # way to read the rest. Scale with the terminal instead, floored at
        # the old 78 (safe on a plain 80-column default) and capped so a
        # very wide terminal doesn't get an absurdly wide dialog.
        _box_w=$((_term_cols - 4))
        [ "$_box_w" -lt 78 ] && _box_w=78
        [ "$_box_w" -gt 160 ] && _box_w=160

        # A real column header (distinct from the checklist's rows) would
        # need to sit flush against the top of the list box, but whiptail
        # always renders a blank line between the instructional text and
        # the list itself — confirmed by actually rendering this dialog
        # into a captured pty and inspecting the character grid; there's no
        # parameter that removes that gap. So the header idea is dropped in
        # favor of keeping "installed"/count directly legible in each row
        # without one, and just keeping the name close behind the count.
        svc_items=()
        for name in "${SVCS[@]}"; do
            _inst_field="$(printf '%-9s' '')"
            _count_field="$(printf '%-2s' '')"
            _count="$(install_count "$name")"
            if [ "$_count" -gt 0 ]; then
                _inst_field="installed"
                _count_field="$(printf '%-2s' "$_count")"
            fi
            svc_tag="$(printf "%s  %s   %s" "$_inst_field" "$_count_field" "$name")"
            svc_items+=("$svc_tag" "${SERVICE_DESC[$name]}" "OFF")
        done
        CHOICE=$(whiptail --title "${CHOSEN_CAT^^}" --checklist \
            "Space to select, Enter to install:" "$_box_h" "$_box_w" "$_list_h" \
            "${svc_items[@]}" 3>&1 1>&2 2>&3 </dev/tty) || continue
        eval "SELECTED=($CHOICE)"
        # Undo the display-only "x N " prefix — name is always the last
        # whitespace-separated token, since service names never contain spaces.
        for i in "${!SELECTED[@]}"; do SELECTED[$i]="${SELECTED[$i]##* }"; done
    else
        echo ""; echo "${CHOSEN_CAT^^}:"
        for name in "${SVCS[@]}"; do
            m=""; _count="$(install_count "$name")"
            [ "$_count" -gt 0 ] && m="[$_count] "
            printf "  %-16s %s%s\n" "$name" "$m" "${SERVICE_DESC[$name]}"
        done
        read -rp "Enter service names to install (space-separated, blank to go back): " -a SELECTED
    fi

    for name in "${SELECTED[@]}"; do run_service "$name"; done
done

echo ""
log_success "Done. Re-run 'sudo ./setup.sh' any time to add more."

# If Docker was installed this session (or already was), the invoking user
# was added to the docker group — but group membership only takes effect in
# a new login shell, not the one that ran sudo. Drop into a fresh login
# shell as that user so 'docker' works immediately without reconnecting SSH.
if [ -n "${SUDO_USER:-}" ] && [ "$UNATTENDED" != true ] \
    && getent group docker >/dev/null 2>&1 \
    && id -nG "$SUDO_USER" 2>/dev/null | grep -qw docker \
    && [ -t 0 ]; then
    echo ""
    log_info "Refreshing shell as $SUDO_USER so the docker group takes effect..."
    exec su - "$SUDO_USER"
fi
