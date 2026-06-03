#!/bin/bash
# lib/common.sh — shared helpers for the modular post-install system.
#
# This is the single source of truth for the helper functions every service
# module relies on (logging, prompts, ownership, Caddy wiring, the service
# registry). Both the full menu (setup.sh) and single-service runs source it,
# so there is exactly ONE implementation of each helper.
#
# Modules under services/*.sh source this file (guarded), register themselves
# with register_service, and define an install_<name> function.

# Guard against double-sourcing
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# ── Global modes (overridable by the dispatcher / environment) ───────────────
DRY_RUN="${DRY_RUN:-false}"
UNATTENDED="${UNATTENDED:-false}"

# ── Identity / paths ─────────────────────────────────────────────────────────
# The actual (non-root) user, even when run under sudo.
ACTUAL_USER="${SUDO_USER:-${USER:-$(id -un)}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6)"
[ -z "$ACTUAL_HOME" ] && ACTUAL_HOME="$HOME"
# Per-service docker folders live here:  ~/docker/<service>/docker-compose.yml
DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"

# ── Colored logging ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ── Service registry ─────────────────────────────────────────────────────────
# Modules call:  register_service <name> <group> <description> [port]
declare -gA SERVICE_GROUP=()
declare -gA SERVICE_DESC=()
declare -gA SERVICE_PORT=()
declare -ga SERVICE_ORDER=()

register_service() {
    local name="$1" group="$2" desc="$3" port="${4:-}"
    SERVICE_GROUP["$name"]="$group"
    SERVICE_DESC["$name"]="$desc"
    SERVICE_PORT["$name"]="$port"
    SERVICE_ORDER+=("$name")
}

# ── Site-wide defaults ────────────────────────────────────────────────────────
# Stored in $DOCKER_DIR/.config (key=value, one per line).
# Service modules read these as prompt defaults so the user only types
# timezone, domain, and Caddy network once.  Run: sudo ./setup.sh configure
SITE_TZ=""
SITE_DOMAIN=""
SITE_CADDY_NET="caddy_net"
SITE_PUID=""
SITE_PGID=""

load_site_config() {
    local cfg="$DOCKER_DIR/.config"
    [ -f "$cfg" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        case "$key" in
            SITE_TZ)        SITE_TZ="$val"                              ;;
            SITE_DOMAIN)    SITE_DOMAIN="$val"                          ;;
            SITE_CADDY_NET) SITE_CADDY_NET="$val"                       ;;
            SITE_PUID)      SITE_PUID="$val"                            ;;
            SITE_PGID)      SITE_PGID="$val"                            ;;
            BASE_DOMAIN)    [ -z "$SITE_DOMAIN" ] && SITE_DOMAIN="$val" ;;
        esac
    done < "$cfg"
    export SITE_TZ SITE_DOMAIN SITE_CADDY_NET SITE_PUID SITE_PGID
}

save_site_config() {
    local cfg="$DOCKER_DIR/.config"
    mkdir -p "$(dirname "$cfg")"
    {
        echo "# ubuntu-post-install site defaults"
        echo "# Re-run wizard:  sudo ./setup.sh configure"
        [ -n "$SITE_TZ" ]        && echo "SITE_TZ=$SITE_TZ"
        [ -n "$SITE_DOMAIN" ]    && echo "SITE_DOMAIN=$SITE_DOMAIN"
        [ -n "$SITE_CADDY_NET" ] && echo "SITE_CADDY_NET=$SITE_CADDY_NET"
        [ -n "$SITE_PUID" ]      && echo "SITE_PUID=$SITE_PUID"
        [ -n "$SITE_PGID" ]      && echo "SITE_PGID=$SITE_PGID"
        # Backward-compat alias for services that still read BASE_DOMAIN directly
        [ -n "$SITE_DOMAIN" ]    && echo "BASE_DOMAIN=$SITE_DOMAIN"
    } > "$cfg"
    chmod 600 "$cfg"
}

# Load immediately so all service modules inherit the values when sourced
load_site_config

# ── Pre-flight ───────────────────────────────────────────────────────────────
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "Please run as root (use sudo)."
        exit 1
    fi
}

require_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed. Install Docker first (run: $0 docker)."
        return 1
    fi
}

# ── Command execution honoring dry-run ───────────────────────────────────────
run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

# Ensure Docker directories are owned by the actual user (not root)
ensure_docker_dir_ownership() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would set ownership of $* to $ACTUAL_USER:$ACTUAL_USER"
        return 0
    fi
    for dir in "$@"; do
        [ -d "$dir" ] && chown -R "$ACTUAL_USER:$ACTUAL_USER" "$dir" 2>/dev/null || true
    done
}

# Generate a secure alphanumeric password (no special characters)
generate_password() {
    local length="${1:-32}"
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
}

# Validate password (alphanumeric only, minimum length). Returns 0/1.
validate_password() {
    local password="$1" min_length="${2:-12}"
    if [ ${#password} -lt "$min_length" ]; then
        echo "  ⚠ Password must be at least $min_length characters long"; return 1
    fi
    if echo "$password" | grep -q '[^a-zA-Z0-9]'; then
        echo "  ⚠ Password must contain only letters and numbers (no special characters)"; return 1
    fi
    return 0
}

# Prompt yes/no, honoring unattended.  prompt_yn "Question?" "default" VARNAME
prompt_yn() {
    local question="$1" default="$2" varname="$3" response
    if [ "$UNATTENDED" = true ]; then
        eval "$varname='$default'"; echo "$question [auto: $default]"; return
    fi
    read -p "$question " response
    eval "$varname='$response'"
}

# Prompt text, honoring unattended.  prompt_text "Question?" "default" VARNAME
prompt_text() {
    local question="$1" default="$2" varname="$3" response
    if [ "$UNATTENDED" = true ]; then
        eval "$varname='$default'"; echo "$question [auto: $default]"; return
    fi
    read -p "$question " response
    eval "$varname='${response:-$default}'"
}

# ── Per-service README generation ────────────────────────────────────────────
# Write <dir>/README.md from stdin (markdown). Every module is encouraged to
# call this so each ~/docker/<service>/ folder is self-documenting.
# Usage:
#   write_readme "$DIR" <<MD
#   # Title
#   ...
#   MD
write_readme() {
    local dir="$1"
    if [ "$DRY_RUN" = true ]; then
        cat >/dev/null            # consume the heredoc so the caller isn't blocked
        echo "[DRY-RUN] Would write $dir/README.md"
        return 0
    fi
    mkdir -p "$dir"
    cat > "$dir/README.md"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$dir/README.md" 2>/dev/null || true
}

# ── Caddy reverse-proxy wiring (shared by every web service) ─────────────────
# Usage: configure_caddy_for_service "Name" "PORT" "default-subdomain" ["extra"]
configure_caddy_for_service() {
    local SERVICE_NAME="$1" SERVICE_PORT="$2" DEFAULT_SUBDOMAIN="$3" EXTRA_CONFIG="${4:-}"

    # Caddy not installed → nothing to do
    [ -d "$DOCKER_DIR/caddy" ] || return 0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CADDY REVERSE PROXY CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Caddy is installed. You can configure a reverse proxy for $SERVICE_NAME."
    echo ""

    local CONFIGURE_CADDY=""
    prompt_yn "Configure Caddy reverse proxy for $SERVICE_NAME? (y/n):" "n" CONFIGURE_CADDY
    if [ "$CONFIGURE_CADDY" != "y" ] && [ "$CONFIGURE_CADDY" != "Y" ]; then
        echo "  Skipping Caddy configuration."
        echo "  Access $SERVICE_NAME at: http://localhost:$SERVICE_PORT"
        return 0
    fi

    echo ""
    echo "Enter the full domain for $SERVICE_NAME:"
    echo "  Examples: $DEFAULT_SUBDOMAIN.example.com, $DEFAULT_SUBDOMAIN.yourdomain.com"
    echo ""
    local SERVICE_DOMAIN=""
    prompt_text "Domain:" "" SERVICE_DOMAIN
    if [ -z "$SERVICE_DOMAIN" ]; then
        echo "  ⚠ No domain provided, skipping Caddy configuration."; return 0
    fi

    local CADDY_DIR="$DOCKER_DIR/caddy"
    local CADDYFILE="$CADDY_DIR/Caddyfile"
    local BACKUP_FILE="$CADDY_DIR/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"

    if [ -f "$CADDYFILE" ]; then
        echo "  Backing up Caddyfile to: $(basename "$BACKUP_FILE")"
        cp "$CADDYFILE" "$BACKUP_FILE"
    else
        echo "  Creating new Caddyfile"; touch "$CADDYFILE"
    fi

    if grep -q "^${SERVICE_DOMAIN}" "$CADDYFILE" 2>/dev/null; then
        echo "  ⚠ $SERVICE_DOMAIN already exists in Caddyfile"
        local OVERWRITE=""
        prompt_yn "Overwrite existing configuration? (y/n):" "n" OVERWRITE
        if [ "$OVERWRITE" != "y" ] && [ "$OVERWRITE" != "Y" ]; then
            echo "  Keeping existing configuration."; return 0
        fi
        sed -i "/^${SERVICE_DOMAIN}/,/^}/d" "$CADDYFILE"
    fi

    echo "  Adding $SERVICE_NAME configuration to Caddyfile..."
    cat >> "$CADDYFILE" << CADDY_BLOCK

# $SERVICE_NAME
$SERVICE_DOMAIN {
    reverse_proxy localhost:$SERVICE_PORT

    # Security headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    # Logging for CrowdSec (Caddy JSON access logs)
    log {
        output file /var/log/caddy/${SERVICE_DOMAIN}.log
        format json
    }
$EXTRA_CONFIG
}
CADDY_BLOCK

    echo "  ✓ Configuration added to Caddyfile"
    echo "  Reloading Caddy configuration..."
    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
    if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
        echo "  ✓ $SERVICE_NAME is now accessible at: https://$SERVICE_DOMAIN"
    else
        echo "  ⚠ Failed to reload Caddy. Check: docker logs caddy"
        echo "  You can restore from backup: $BACKUP_FILE"
    fi
    echo ""
}
