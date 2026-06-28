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
CADDY_MODE=""          # local | remote | none  (set by site configure wizard)
CADDY_REMOTE_HOST=""   # legacy — kept for backward compat with old .config files

load_site_config() {
    local cfg="$DOCKER_DIR/.config"
    [ -f "$cfg" ] || return 0
    local key val
    while IFS='=' read -r key val; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key// }" ]] && continue
        case "$key" in
            SITE_TZ)           SITE_TZ="$val"                              ;;
            SITE_DOMAIN)       SITE_DOMAIN="$val"                          ;;
            SITE_CADDY_NET)    SITE_CADDY_NET="$val"                       ;;
            SITE_PUID)         SITE_PUID="$val"                            ;;
            SITE_PGID)         SITE_PGID="$val"                            ;;
            CADDY_MODE)        CADDY_MODE="$val"                           ;;
            CADDY_REMOTE_HOST) CADDY_REMOTE_HOST="$val"                    ;;
            BASE_DOMAIN)       [ -z "$SITE_DOMAIN" ] && SITE_DOMAIN="$val" ;;
        esac
    done < "$cfg"
    # Backward compat: old installs used CADDY_REMOTE_HOST to signal remote mode
    [ -z "$CADDY_MODE" ] && [ -n "$CADDY_REMOTE_HOST" ] && CADDY_MODE="remote"
    export SITE_TZ SITE_DOMAIN SITE_CADDY_NET SITE_PUID SITE_PGID CADDY_MODE CADDY_REMOTE_HOST
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
        [ -n "$CADDY_MODE" ]     && echo "CADDY_MODE=$CADDY_MODE"
        # Backward-compat alias for services that still read BASE_DOMAIN directly
        [ -n "$SITE_DOMAIN" ]    && echo "BASE_DOMAIN=$SITE_DOMAIN"
    } > "$cfg"
    chmod 600 "$cfg"
}

# Load immediately so all service modules inherit the values when sourced
load_site_config

# ── OS detection ─────────────────────────────────────────────────────────────
OS_DISTRO="unknown"
OS_VERSION="unknown"
OS_CODENAME="unknown"

detect_os() {
    [ -f /etc/os-release ] || return 0
    local key val
    while IFS='=' read -r key val; do
        val="${val//\"/}"
        case "$key" in
            ID)              OS_DISTRO="$val"                                       ;;
            VERSION_ID)      OS_VERSION="$val"                                      ;;
            VERSION_CODENAME|UBUNTU_CODENAME)
                [ "$OS_CODENAME" = "unknown" ] && OS_CODENAME="$val"               ;;
        esac
    done < /etc/os-release
    export OS_DISTRO OS_VERSION OS_CODENAME
}

# Return 0 (true) if the detected Ubuntu version is >= the argument (e.g., "24.04").
ubuntu_version_ge() {
    [ "$OS_DISTRO" = "ubuntu" ] || return 1
    local a="${OS_VERSION//./}" b="${1//./}"
    [ "${a:-0}" -ge "${b:-0}" ] 2>/dev/null
}

# pip install --user as actual user.
# --break-system-packages overrides PEP 668 ("externally managed environment"),
# required on Ubuntu 24.04+ — the flag name sounds alarming but with --user the
# install goes to ~/.local/ which apt never touches; nothing system-level is at risk.
# The flag was added in pip 22.3; probe once so older pip (Ubuntu 22.04) still works.
_PIP_HAS_BSP=""
_pip_probe() {
    [ -n "$_PIP_HAS_BSP" ] && return
    pip3 install --help 2>/dev/null | grep -q -- '--break-system-packages' \
        && _PIP_HAS_BSP=1 || _PIP_HAS_BSP=0
}

pip_user_install() {
    _pip_probe
    local flags="--user --quiet"
    [ "$_PIP_HAS_BSP" = "1" ] && flags="$flags --break-system-packages"
    sudo -u "$ACTUAL_USER" pip3 install $flags "$@"
}

detect_os

# ── Pre-flight ───────────────────────────────────────────────────────────────
require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        log_error "Please run as root (use sudo)."
        exit 1
    fi
}

require_docker() {
    if command -v docker &>/dev/null; then
        return 0
    fi

    log_info "Docker is not installed — installing now..."
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install Docker CE and Docker Compose plugin via get.docker.com"
        return 0
    fi

    # Official Docker convenience script — installs Docker CE + Compose plugin.
    # DEBIAN_FRONTEND suppresses interactive apt hooks (needrestart etc.) that
    # would block waiting on the piped stdin and cause a silent install failure.
    export DEBIAN_FRONTEND=noninteractive
    curl -fsSL https://get.docker.com | sh
    local _rc=${PIPESTATUS[1]}
    unset DEBIAN_FRONTEND
    hash -r 2>/dev/null || true  # flush command hash so new binary is found

    if [ "$_rc" -ne 0 ]; then
        log_error "Docker installation failed. Try manually: curl -fsSL https://get.docker.com | sh"
        return 1
    fi

    if ! command -v docker &>/dev/null; then
        log_error "Docker binary not found after install — something went wrong."
        return 1
    fi

    if [ -n "$ACTUAL_USER" ] && [ "$ACTUAL_USER" != "root" ]; then
        usermod -aG docker "$ACTUAL_USER" \
            && log_info "Added $ACTUAL_USER to the docker group (re-login or run 'newgrp docker' to activate)"
    fi

    log_success "Docker installed ($(docker --version 2>/dev/null))"
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
# Usage: configure_caddy_for_service "Name" "UPSTREAM" "default-subdomain" ["extra"]
# UPSTREAM: container:port for caddy_net routing (e.g. "filebrowser:80"),
#           or plain port number for localhost fallback (e.g. "8085").
configure_caddy_for_service() {
    local SERVICE_NAME="$1" SERVICE_UPSTREAM="$2" DEFAULT_SUBDOMAIN="$3" EXTRA_CONFIG="${4:-}"

    # Derive the proxy upstream and a port number for display messages.
    # Plain number  → localhost:PORT  (host-network or legacy services)
    # name:port     → used as-is      (preferred: service on shared caddy_net)
    local _UPSTREAM _DISPLAY_PORT
    case "$SERVICE_UPSTREAM" in
        *:*) _UPSTREAM="$SERVICE_UPSTREAM";           _DISPLAY_PORT="${SERVICE_UPSTREAM##*:}" ;;
        *)   _UPSTREAM="localhost:$SERVICE_UPSTREAM"; _DISPLAY_PORT="$SERVICE_UPSTREAM"      ;;
    esac

    # ── Determine Caddy mode ──────────────────────────────────────────────────
    # Explicit CADDY_MODE (set by site wizard) takes priority.
    # Fall back to: local if ~/docker/caddy exists, remote if legacy CADDY_REMOTE_HOST set.
    local _CADDY_MODE="${CADDY_MODE:-none}"
    [ "$_CADDY_MODE" = "none" ] && [ -d "$DOCKER_DIR/caddy" ]  && _CADDY_MODE="local"
    [ "$_CADDY_MODE" = "none" ] && [ -n "${CADDY_REMOTE_HOST:-}" ] && _CADDY_MODE="remote"
    [ "$_CADDY_MODE" = "none" ] && return 0

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  CADDY REVERSE PROXY CONFIGURATION"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    if [ "$_CADDY_MODE" = "remote" ]; then
        echo "  Caddy is on a remote machine — a snippet file will be saved to"
        echo "  ~/docker/caddy-snippets/ for you to copy to your Caddy machine."
    else
        echo "  Caddy is installed on this machine."
    fi
    echo ""

    local CONFIGURE_CADDY=""
    prompt_yn "Configure Caddy reverse proxy for $SERVICE_NAME? (y/n):" "n" CONFIGURE_CADDY
    if [ "$CONFIGURE_CADDY" != "y" ] && [ "$CONFIGURE_CADDY" != "Y" ]; then
        echo "  Skipping Caddy configuration."
        echo "  Access $SERVICE_NAME at: http://localhost:$_DISPLAY_PORT"
        return 0
    fi

    # Domain prompt — pre-fill from SITE_DOMAIN when available
    echo ""
    local _default_domain=""
    if [ -n "$SITE_DOMAIN" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        _default_domain="${DEFAULT_SUBDOMAIN}.${SITE_DOMAIN}"
        echo "  Default: $_default_domain"
    else
        echo "  Examples: ${DEFAULT_SUBDOMAIN}.example.com, ${DEFAULT_SUBDOMAIN}.yourdomain.com"
    fi
    echo ""
    local SERVICE_DOMAIN=""
    prompt_text "Domain [${_default_domain:-required}]:" "$_default_domain" SERVICE_DOMAIN
    if [ -z "$SERVICE_DOMAIN" ]; then
        echo "  ⚠ No domain provided, skipping Caddy configuration."; return 0
    fi

    # Build the site block — upstream differs by mode
    local _BLOCK_UPSTREAM="$_UPSTREAM"
    if [ "$_CADDY_MODE" = "remote" ]; then
        # Remote Caddy can't resolve Docker container names — use this machine's IP + published port.
        # Prefer legacy CADDY_REMOTE_HOST if set (old installs that stored it explicitly),
        # otherwise auto-detect the primary non-loopback IP.
        local _THIS_IP="${CADDY_REMOTE_HOST:-}"
        if [ -z "$_THIS_IP" ]; then
            _THIS_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
        fi
        [ -z "$_THIS_IP" ] && _THIS_IP="$(hostname -f 2>/dev/null || echo "127.0.0.1")"
        _BLOCK_UPSTREAM="${_THIS_IP}:${_DISPLAY_PORT}"
    fi

    local _SITE_BLOCK
    _SITE_BLOCK="$(cat << CADDY_BLOCK

# $SERVICE_NAME
${SERVICE_DOMAIN} {
    reverse_proxy ${_BLOCK_UPSTREAM}

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
${EXTRA_CONFIG}
}
CADDY_BLOCK
)"

    # ── Local Caddy: write to Caddyfile and reload ────────────────────────────
    if [ "$_CADDY_MODE" = "local" ]; then
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
        printf '%s\n' "$_SITE_BLOCK" >> "$CADDYFILE"

        echo "  ✓ Configuration added to Caddyfile"
        echo "  Reloading Caddy configuration..."
        docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
        if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
            echo "  ✓ $SERVICE_NAME is now accessible at: https://$SERVICE_DOMAIN"
        else
            echo "  ⚠ Failed to reload Caddy. Check: docker logs caddy"
            echo "  You can restore from backup: $BACKUP_FILE"
        fi

    # ── Remote Caddy: write snippet file ─────────────────────────────────────
    else
        local SNIPPET_DIR="$DOCKER_DIR/caddy-snippets"
        local SNIPPET_FILE="$SNIPPET_DIR/${DEFAULT_SUBDOMAIN}.caddy"
        mkdir -p "$SNIPPET_DIR"
        printf '%s\n' "$_SITE_BLOCK" > "$SNIPPET_FILE"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$SNIPPET_FILE" 2>/dev/null || true

        echo "  ✓ Snippet saved: $SNIPPET_FILE"
        echo ""
        echo "  Copy to your Caddy machine and append to its Caddyfile:"
        echo "    scp $SNIPPET_FILE caddy-host:~/caddy-snippets/"
        echo "    # then on the Caddy machine:"
        echo "    cat ~/caddy-snippets/${DEFAULT_SUBDOMAIN}.caddy >> /path/to/Caddyfile"
        echo "    docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
        echo ""
        echo "  Or rsync all snippets at once:"
        echo "    rsync -av $SNIPPET_DIR/ caddy-host:~/caddy-snippets/"
    fi
    echo ""
}
