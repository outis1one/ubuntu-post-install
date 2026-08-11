#!/bin/bash
# services/beszel.sh — Beszel lightweight server + Docker monitoring (hub + agent).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash beszel.sh
# (Docker must already be installed when run standalone)
#
# Beszel is a hub+agent monitor: the hub is the web dashboard, the agent runs
# on each box you want metrics from and reports host resources (CPU, RAM,
# disk, network) plus per-container Docker stats — read directly off
# /var/run/docker.sock (mounted read-only), so it picks up whatever
# containers are currently running automatically. No per-container config;
# add/remove a service on this box and the agent just reports what it sees
# on its next poll.
#
# This installs both hub and agent on THIS box (the "same-system" layout —
# see supplemental/docker/same-system/docker-compose.yml in beszel's own
# repo, which this mirrors). The agent can also be pointed at additional
# remote boxes later; that's a from-the-hub-UI step, not something this
# installer sets up.
#
# Complements Gatus, doesn't replace it: Gatus is a black-box HTTP check —
# is the site actually responding, from the outside, like a visitor would
# see it. Beszel is white-box host/process monitoring — is the box itself
# under memory/disk pressure, is a specific container actually running vs.
# crash-looping. A container can be "Up" in Docker (Beszel sees it as
# healthy) while the app inside it is serving errors or hanging (only
# Gatus's actual HTTP probe would catch that) — they answer different
# questions, worth running both.
#
# Two-phase install, unavoidably: the hub generates its own SSH keypair and
# (once you enable it in Settings → Tokens & Fingerprints) a universal
# token, both only available after you've logged into the hub's web UI at
# least once — there's no way to generate or guess these ahead of time.
# This installer starts the hub first, waits for you to grab those two
# values, then wires up the agent. Re-run this installer later if you skip
# the agent step now — it'll pick up right where you left off instead of
# re-asking everything.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
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

        prompt_reinstall_mode() {
            local _var="$1" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='cancel'"; return; }
            echo "    1) Update (refresh image, keep everything else)"
            echo "    2) Fresh reinstall"
            echo "    3) Cancel"
            read -r -p "  Choice [1/2/3]: " _r
            case "$_r" in
                2) eval "$_var='fresh'" ;;
                1|"") eval "$_var='update'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        register_service() { :; }
        write_readme() {
            local _dir="$1"; mkdir -p "$_dir"; cat > "$_dir/README.md"
            local _companion; _companion="$(dirname "${BASH_SOURCE[0]}")/beszel.md"
            [ -f "$_companion" ] && cat "$_companion" >> "$_dir/README.md"
        }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"

    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service beszel utilities "Lightweight server + Docker monitoring (Beszel) — CPU/RAM/disk/network, auto-discovers running containers" 8090

_beszel_configure_agent() {
    local dir="$1" web_port="$2"

    echo ""
    echo "  To finish connecting the agent, log into the hub first:"
    echo "    http://localhost:${web_port}  (or its Caddy domain, once configured)"
    echo ""
    echo "  Create the admin account, then go to Settings → Tokens & Fingerprints:"
    echo "    - Enable the universal token and copy its value"
    echo "    - Copy the public key shown there too"
    echo ""

    local AGENT_KEY="" AGENT_TOKEN=""
    prompt_text "  Paste the public key (blank to skip and do this later):" "" AGENT_KEY
    if [ -z "$AGENT_KEY" ]; then
        log_info "Skipping agent setup for now — re-run this installer once you have the key and token."
        return 0
    fi
    prompt_text "  Paste the universal token:" "" AGENT_TOKEN
    if [ -z "$AGENT_TOKEN" ]; then
        log_info "No token entered — skipping agent setup for now. Re-run this installer to finish."
        return 0
    fi

    {
        echo "AGENT_KEY=$AGENT_KEY"
        echo "AGENT_TOKEN=$AGENT_TOKEN"
    } >> "$dir/.env"
    chmod 600 "$dir/.env"

    ( cd "$dir" && docker compose up -d beszel-agent ) \
        && log_success "Agent connected — it should appear in the hub within a few seconds." \
        || log_warning "Agent failed to start — check: docker compose -f $dir/docker-compose.yml logs beszel-agent"
}

install_beszel() {
    require_docker || return 1
    log_info "Installing Beszel..."

    local DIR="$DOCKER_DIR/beszel"
    local WEB_PORT="8090"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR (beszel_data/, beszel_socket/, beszel_agent_data/)"
        echo "[DRY-RUN] Would deploy henrygd/beszel (hub) and henrygd/beszel-agent (agent, network_mode: host)"
        echo "[DRY-RUN] Port 8090 published for the hub (auto-scanned for a free host port)"
        echo "[DRY-RUN] Agent connects to the hub over a shared unix socket, not a TCP port"
        echo "[DRY-RUN] Would pause for you to log into the hub and provide its key + universal token to finish the agent"
        return 0
    fi

    # ── Existing install? Offer update/fresh/cancel ─────────────────────────
    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing images only — existing config, port, and Caddy setup are left as-is."
                ( cd "$DIR" && docker compose pull && docker compose up -d ) \
                    && log_success "Beszel images refreshed" \
                    || log_warning "Refresh failed — check: docker compose -f $DIR/docker-compose.yml logs"
                if ! grep -q '^AGENT_KEY=' "$DIR/.env" 2>/dev/null; then
                    local FINISH_AGENT=""
                    prompt_yn "  The agent was never connected — set it up now? (y/n):" "y" FINISH_AGENT
                    [[ "$FINISH_AGENT" =~ ^[Yy]$ ]] && _beszel_configure_agent "$DIR" "$(grep '^BESZEL_WEB_PORT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
                fi
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) ;;  # fall through to the full install flow below
        esac
    fi

    # A second hub on this same box wouldn't mean anything — additional
    # boxes get their own agent pointed at this one hub, not a second hub
    # instance. Skip the multi-instance pattern entirely (same reasoning
    # CLAUDE.md gives for caddy/crowdsec).
    find_free_port WEB_PORT "$WEB_PORT"

    mkdir -p "$DIR/beszel_data" "$DIR/beszel_socket" "$DIR/beszel_agent_data"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # Mirrors configure_caddy_for_service's own mode resolution (lib/common.sh).
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

    # Agent uses network_mode: host (for accurate network-interface stats,
    # matching beszel's own reference same-system compose) — that's mutually
    # exclusive with a `networks:` block in Compose, so it never joins
    # caddy_net regardless of Caddy mode; it doesn't need to, since it talks
    # to the hub over the shared beszel_socket volume, not a published port.
    cat > docker-compose.yml << BESZEL_COMPOSE
name: beszel

services:
  beszel:
    image: henrygd/beszel:latest
    container_name: beszel
    hostname: beszel
    restart: unless-stopped
    env_file: .env
    ports:
      - "${WEB_PORT}:8090"
    volumes:
      - ./beszel_data:/beszel_data
      - ./beszel_socket:/beszel_socket
${_CADDY_NET_BLOCK}
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    env_file: .env
    environment:
      - LISTEN=/beszel_socket/beszel.sock
      - HUB_URL=http://localhost:${WEB_PORT}
      - TOKEN=\${AGENT_TOKEN:-}
      - KEY=\${AGENT_KEY:-}
    volumes:
      - ./beszel_agent_data:/var/lib/beszel-agent
      - ./beszel_socket:/beszel_socket
      - /var/run/docker.sock:/var/run/docker.sock:ro
${_CADDY_NET_SECTION}
BESZEL_COMPOSE

    # APP_URL only matters for the hub's own generated links and origin
    # checks — http://localhost is fine until you front this with Caddy,
    # at which point update it to the real https:// domain and restart (see
    # README). Not threaded through automatically here because Caddy setup
    # (below) happens after this file is written, same ordering every
    # other service in this repo uses for its own Caddy prompt.
    cat > .env << BESZEL_ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
CADDY_NET=$SITE_CADDY_NET
BESZEL_WEB_PORT=$WEB_PORT
APP_URL=http://localhost:${WEB_PORT}
BESZEL_ENV
    chmod 600 .env

    log_info "Starting the hub (agent connects after you grab its key/token from the hub UI)..."
    if docker compose up -d beszel; then
        log_success "Hub started"
        declare -F check_container_health >/dev/null 2>&1 && check_container_health beszel 8
    else
        log_warning "Hub failed to start — check: docker compose logs"
        return 1
    fi

    configure_caddy_for_service "Beszel" "beszel:8090" "beszel"
    if [ "${CADDY_SERVICE_CONFIGURED:-false}" != "true" ] || [ "${CADDY_SERVICE_MODE:-}" = "remote" ]; then
        if command -v ufw &>/dev/null; then
            ufw allow "${WEB_PORT}/tcp" comment "Beszel" >/dev/null 2>&1
            declare -F ensure_ufw_enabled >/dev/null 2>&1 && ensure_ufw_enabled
        fi
    fi

    _beszel_configure_agent "$DIR" "$WEB_PORT"

    write_readme "$DIR" << 'BESZEL_README'
# Beszel — lightweight server + Docker monitoring

Hub (web dashboard) + agent (reports host and container stats), both on
this box. The agent reads `/var/run/docker.sock` (mounted read-only) to
report every currently-running container automatically — nothing to
configure per-service; install or remove a container on this box and the
agent's next poll just reflects it.

## First login

No default account — open the hub and register the first user, which
becomes admin:

- URL: printed at the end of the install (Caddy domain if configured,
  otherwise `http://localhost:<port>`)

## Connecting the agent (if you skipped it during install)

The agent needs the hub's public key and a universal token, both only
available after logging in:

1. Settings → Tokens & Fingerprints → enable the universal token, copy it
2. Copy the public key shown on the same page
3. Re-run `sudo ./setup.sh beszel` — it'll detect the agent isn't
   connected yet and prompt for both values

## Monitoring additional boxes

Add another agent from the hub's UI ("Add System") — that generates the
connection details for a *remote* box's agent. This installer only sets
up the agent for the box it's run on.

## Fronting this with Caddy

If you configured Caddy for Beszel, also update `APP_URL` in `.env` to
the real `https://` domain (it defaults to `http://localhost:<port>`,
which is what the hub uses for its own generated links and origin
checks) and restart:

```bash
docker compose restart beszel
```

## Manage

```bash
docker compose up -d
docker compose logs -f
docker compose pull && docker compose up -d
docker compose down
```
BESZEL_README

    echo ""
    log_success "Beszel configured at $DIR"
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_beszel
