#!/bin/bash
# setup.sh — modular post-install dispatcher.
#
# One source of truth, two ways to run it:
#   sudo ./setup.sh                 interactive menu (pick any services)
#   sudo ./setup.sh <service> ...   install one or more services directly
#   ./setup.sh --list               list available services (grouped)
#
# Flags:
#   --dry-run      preview actions without making changes
#   --unattended   use defaults, no prompts
#
# Every service lives in services/<name>.sh, registers itself, and defines
# install_<name>. Adding a service = adding one file. Updating a service =
# editing one file. Nothing is duplicated or generated.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse global flags, collect service names ────────────────────────────────
DRY_RUN=false
UNATTENDED=false
DO_LIST=false
REQUESTED=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --unattended) UNATTENDED=true ;;
        --list|-l)    DO_LIST=true ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *)  REQUESTED+=("$arg") ;;
    esac
done
export DRY_RUN UNATTENDED

# ── Load helpers + all service modules (they self-register) ──────────────────
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

shopt -s nullglob
for _mod in "$HERE"/services/*.sh; do
    # shellcheck source=/dev/null
    source "$_mod"
done
shopt -u nullglob

# Ordered list of unique groups, in first-seen order.
groups_in_order() {
    local seen=" " g
    for name in "${SERVICE_ORDER[@]}"; do
        g="${SERVICE_GROUP[$name]}"
        case "$seen" in *" $g "*) : ;; *) echo "$g"; seen="$seen$g " ;; esac
    done
}

list_services() {
    local g name
    while IFS= read -r g; do
        echo ""
        echo "── ${g^^} ──"
        for name in "${SERVICE_ORDER[@]}"; do
            [ "${SERVICE_GROUP[$name]}" = "$g" ] || continue
            printf "  %-16s %s\n" "$name" "${SERVICE_DESC[$name]}"
        done
    done < <(groups_in_order)
    echo ""
}

run_service() {
    local name="$1"
    if [ -z "${SERVICE_GROUP[$name]:-}" ]; then
        log_error "Unknown service: $name  (try: $0 --list)"
        return 1
    fi
    if ! declare -F "install_${name}" >/dev/null; then
        log_error "Service '$name' has no install_${name} function."
        return 1
    fi
    log_info "=== ${name} (${SERVICE_DESC[$name]}) ==="
    "install_${name}"
}

# ── --list ───────────────────────────────────────────────────────────────────
if [ "$DO_LIST" = true ]; then
    list_services
    exit 0
fi

# ── Direct service install:  ./setup.sh minecraft homeassistant ─────────────
if [ "${#REQUESTED[@]}" -gt 0 ]; then
    require_root
    rc=0
    for name in "${REQUESTED[@]}"; do
        run_service "$name" || rc=1
    done
    exit "$rc"
fi

# ── Interactive menu ─────────────────────────────────────────────────────────
require_root

SELECTED=()
if command -v whiptail >/dev/null 2>&1; then
    _items=()
    for name in "${SERVICE_ORDER[@]}"; do
        _items+=("$name" "${SERVICE_DESC[$name]}" "OFF")
    done
    _choice=$(whiptail --title "Ubuntu Post-Install — Services" \
        --checklist "Select services to install (space to toggle):" 25 78 16 \
        "${_items[@]}" 3>&1 1>&2 2>&3) || { echo "Cancelled."; exit 0; }
    # whiptail returns space-separated, quoted names
    eval "SELECTED=($_choice)"
else
    echo "Available services:"
    list_services
    read -rp "Enter service names to install (space-separated): " -a SELECTED
fi

[ "${#SELECTED[@]}" -eq 0 ] && { echo "Nothing selected."; exit 0; }

rc=0
for name in "${SELECTED[@]}"; do
    run_service "$name" || rc=1
done
exit "$rc"
