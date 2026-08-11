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

# Pulls a NAME's value out of a pasted blob regardless of which shape it
# arrives in — Beszel's own "copy for docker compose" button (the most
# prominent option next to the key/token fields, confirmed live to be
# what people actually click) hands you YAML (`KEY: 'value'` or
# `- KEY=value`), not a bare string — matches "KEY"/"TOKEN" with either
# `:` or `=`, optional leading `- ` list marker, and strips a single
# layer of surrounding quotes if present.
_beszel_extract_field() {
    local field="$1" blob="$2"
    echo "$blob" | grep -iE "^[[:space:]]*-?[[:space:]]*${field}[[:space:]]*[:=]" | head -1 \
        | sed -E "s/^[[:space:]]*-?[[:space:]]*${field}[[:space:]]*[:=][[:space:]]*//I" \
        | sed -E "s/^[\"']//; s/[\"'][[:space:]]*\$//"
}

_beszel_configure_agent() {
    local dir="$1" login_url="$2"

    echo ""
    echo "  To finish connecting the agent, log into the hub first:"
    echo "    ${login_url}"
    echo ""
    echo "  Create the admin account, then go to Settings → Tokens & Fingerprints:"
    echo "    - Enable the universal token"
    echo "    - The key/token fields there usually offer a 'copy for docker"
    echo "      compose' shortcut — paste whatever that gives you below as-is,"
    echo "      whole snippet or just the two lines, doesn't matter which."
    echo ""

    if [ "${UNATTENDED:-false}" = "true" ]; then
        log_info "Skipping agent setup (unattended) — re-run this installer to finish it."
        return 0
    fi

    echo "  Paste it below, then an empty line to finish (blank first line to skip for now):"
    local PASTE="" LINE
    while IFS= read -r LINE; do
        [ -z "$LINE" ] && break
        PASTE="${PASTE}${LINE}"$'\n'
    done

    if [ -z "$PASTE" ]; then
        log_info "Skipping agent setup for now — re-run this installer once you have the key and token."
        return 0
    fi

    local AGENT_KEY AGENT_TOKEN
    AGENT_KEY="$(_beszel_extract_field KEY "$PASTE")"
    AGENT_TOKEN="$(_beszel_extract_field TOKEN "$PASTE")"

    # Didn't find a labeled KEY/TOKEN line at all — treat the paste as a
    # single bare value and ask for the other one directly, so a UI that
    # really does just show plain strings (no YAML) still works.
    if [ -z "$AGENT_KEY" ] && [ -z "$AGENT_TOKEN" ]; then
        AGENT_KEY="$(echo "$PASTE" | head -1)"
        prompt_text "  Paste the universal token:" "" AGENT_TOKEN
    fi

    if [ -z "$AGENT_KEY" ] || [ -z "$AGENT_TOKEN" ]; then
        log_warning "Couldn't find both a key and a token in that — skipping agent setup. Re-run this installer to try again."
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
        echo "[DRY-RUN] Would mount host systemd/dbus sockets + sensor paths read-only (Services/Temp columns)"
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
                    local FINISH_AGENT="" _WP
                    _WP="$(grep '^BESZEL_WEB_PORT=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
                    prompt_yn "  The agent was never connected — set it up now? (y/n):" "y" FINISH_AGENT
                    [[ "$FINISH_AGENT" =~ ^[Yy]$ ]] && _beszel_configure_agent "$DIR" "http://localhost:${_WP}  (or its Caddy domain, once configured)"
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
    #
    # The systemd/dbus/sensor mounts below aren't optional extras — without
    # them the agent silently reports empty Services and Temp columns for
    # this box, with no error anywhere pointing at why. A container is
    # isolated from the host's systemd/dbus and most of /sys by default;
    # docker.sock alone (already needed for the Docker-container-stats
    # feature) doesn't grant any of that. Confirmed live: a native
    # (non-Docker) agent install gets both for free just by virtue of
    # running as a normal host process, which is what first surfaced this
    # gap — a Docker-deployed agent sitting right next to it showed nothing
    # in either column until these were added.
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
      - /var/run/systemd/private:/var/run/systemd/private:ro
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro
      - /sys/class/hwmon:/sys/class/hwmon:ro
      - /sys/class/thermal:/sys/class/thermal:ro
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

    _beszel_configure_agent "$DIR" "http://localhost:${WEB_PORT}  (or its Caddy domain, once configured)"

    write_readme "$DIR" << 'BESZEL_README'
# Beszel — lightweight server + Docker monitoring

Hub (web dashboard) + agent (reports host and container stats), both on
this box. The agent reads `/var/run/docker.sock` (mounted read-only) to
report every currently-running container automatically — nothing to
configure per-service; install or remove a container on this box and the
agent's next poll just reflects it.

Also mounts the host's systemd/dbus sockets and sensor paths (read-only) so
the hub's **Services** (systemd units) and **Temp** (hardware sensors)
columns work for this box — without them a Docker-deployed agent silently
shows both empty, no error anywhere pointing at why.

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

Add another agent from the hub's UI ("Add System") to generate its
connection details, then on the OTHER box (a homelab machine, not this
VPS) run `sudo ./setup.sh beszel-agent` — a separate, agent-only install
(no hub, no web UI) built for exactly this. It connects OUTBOUND to this
hub over HTTPS, so no VPN, port-forwarding, or FQDN is needed for that box
— only this hub needs to be reachable, which it already is. See
`services/beszel.sh`'s `install_beszel-agent()`.

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

# ── Agent-only install, for a box that ISN'T the hub ────────────────────────
# A second register_service in this same file — precedented by base.sh's
# base+glow — rather than a separate services/beszel-agent.sh, since this
# shares _beszel_extract_field/_beszel_configure_agent with install_beszel()
# above and would otherwise duplicate that paste/parse logic across two
# files. Run this on a homelab/remote box (a plain VPN peer isn't needed —
# see the README this writes for why) pointed at a hub running on THIS repo's
# main box (install_beszel() above, or any other Beszel hub).
register_service beszel-agent utilities "Beszel monitoring AGENT only, for a remote/homelab box reporting to a hub running elsewhere"

install_beszel-agent() {
    require_docker || return 1
    log_info "Installing the Beszel agent (reports to a hub running on another machine)..."

    local DIR="$DOCKER_DIR/beszel-agent"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR"
        echo "[DRY-RUN] Would deploy henrygd/beszel-agent only (no hub, no web UI on this box)"
        echo "[DRY-RUN]   network_mode: host, /var/run/docker.sock mounted read-only"
        echo "[DRY-RUN]   plus host systemd/dbus sockets + sensor paths read-only (Services/Temp columns)"
        echo "[DRY-RUN] Would prompt for the hub's public URL, then its key + universal token"
        echo "[DRY-RUN]   (same paste flow as the hub-side installer)"
        echo "[DRY-RUN] No inbound port opened — the agent connects OUTBOUND to the hub, so no"
        echo "[DRY-RUN]   VPN, port-forwarding, or FQDN is needed for THIS box"
        return 0
    fi

    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing the image only — existing hub URL/key/token are left as-is."
                ( cd "$DIR" && docker compose pull && docker compose up -d ) \
                    && log_success "Beszel agent image refreshed" \
                    || log_warning "Refresh failed — check: docker compose -f $DIR/docker-compose.yml logs"
                if ! grep -q '^AGENT_KEY=' "$DIR/.env" 2>/dev/null; then
                    local FINISH_AGENT="" _HUB_URL
                    _HUB_URL="$(grep '^HUB_URL=' "$DIR/.env" 2>/dev/null | cut -d= -f2-)"
                    prompt_yn "  The agent was never connected — set it up now? (y/n):" "y" FINISH_AGENT
                    [[ "$FINISH_AGENT" =~ ^[Yy]$ ]] && _beszel_configure_agent "$DIR" "$_HUB_URL"
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

    mkdir -p "$DIR/beszel_agent_data"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    echo ""
    echo "  This box's agent connects OUTBOUND to a Beszel hub running elsewhere"
    echo "  (e.g. your VPS) — no VPN, no router port-forwarding, and no FQDN needed"
    echo "  for THIS box. Only the hub itself needs to already be reachable."
    echo ""
    local HUB_URL=""
    while [ -z "$HUB_URL" ]; do
        prompt_text "  Hub URL (e.g. https://beszel.yourdomain.com, or http://vps-ip:port):" "" HUB_URL
        [ -z "$HUB_URL" ] && log_warning "  A hub URL is required."
    done

    # No network_mode: host caveat here beyond what install_beszel() already
    # documents — same reasoning (accurate host network-interface stats),
    # and there's no caddy_net to conditionally join since this box never
    # runs a web UI of its own. See that function's own comment for why the
    # systemd/dbus/sensor mounts below matter (Services/Temp columns).
    cat > docker-compose.yml << AGENT_COMPOSE
name: beszel-agent

services:
  beszel-agent:
    image: henrygd/beszel-agent:latest
    container_name: beszel-agent
    restart: unless-stopped
    network_mode: host
    env_file: .env
    environment:
      - HUB_URL=\${HUB_URL}
      - TOKEN=\${AGENT_TOKEN:-}
      - KEY=\${AGENT_KEY:-}
    volumes:
      - ./beszel_agent_data:/var/lib/beszel-agent
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - /var/run/systemd/private:/var/run/systemd/private:ro
      - /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:ro
      - /sys/class/hwmon:/sys/class/hwmon:ro
      - /sys/class/thermal:/sys/class/thermal:ro
AGENT_COMPOSE

    cat > .env << AGENT_ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}
HUB_URL=$HUB_URL
AGENT_ENV
    chmod 600 .env

    _beszel_configure_agent "$DIR" "$HUB_URL"

    write_readme "$DIR" << AGENT_README_MD
# Beszel agent (remote/homelab box)

Reports this box's host resources and Docker container stats to a Beszel
HUB running elsewhere — no hub, no web UI, nothing web-facing on this box
at all.

Also mounts the host's systemd/dbus sockets and sensor paths (read-only) so
the hub's **Services** (systemd units) and **Temp** (hardware sensors)
columns work for this box too — without them a Docker-deployed agent
silently shows both empty, no error anywhere pointing at why.

## Connecting (if you skipped it during install)

Same flow as the hub side, just on a different machine: log into the hub at
\`$HUB_URL\`, go to Settings → Tokens & Fingerprints, enable the universal
token, and paste whatever it gives you (the "copy for docker compose"
shortcut works fine) by re-running:

\`\`\`bash
sudo ./setup.sh beszel-agent
\`\`\`

## Why no VPN or port-forwarding

This agent connects OUTBOUND to the hub over HTTPS/WebSocket using the key
and token above — nothing on this box ever needs to be reached FROM the
hub, so there's no inbound port to open, no router port-forward, no VPN
tunnel, and no FQDN needed for this box itself. Only the hub needs to
already be reachable at the URL you gave it.

## Manage

\`\`\`bash
docker compose up -d
docker compose logs -f
docker compose pull && docker compose up -d
docker compose down
\`\`\`
AGENT_README_MD

    echo ""
    log_success "Beszel agent configured at $DIR — connecting to $HUB_URL"
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_beszel
