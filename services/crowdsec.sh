#!/bin/bash
# services/crowdsec.sh — CrowdSec intrusion prevention (fail2ban successor).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash crowdsec.sh
# (Docker must already be installed when run standalone)
#
# CrowdSec is a SYSTEM install (apt repo + agent), NOT a docker-compose service:
#   • Installs the CrowdSec agent and the iptables firewall bouncer (enforces bans).
#   • Installs detection collections for SSH, Linux, Caddy and base HTTP scenarios.
#   • Reads Caddy's JSON access logs (/var/log/caddy/*.log) to spot attacks.
#   • Optionally pushes ban alerts to an ntfy topic.
#   • Adds community IP reputation + optional geo-enrichment on top.
#
# There is no ~/docker/crowdsec compose; we only create a docs-only folder there
# with a README pointing at the real config under /etc/crowdsec.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
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

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service crowdsec homelab "Intrusion prevention: bans + geo + IP reputation (CrowdSec)"

install_crowdsec() {
    log_info "Installing CrowdSec intrusion prevention..."

    local DOCS_DIR="$DOCKER_DIR/crowdsec"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ CROWDSEC - Intrusion Prevention (fail2ban successor)            │"
    echo "│ Bans malicious IPs + geo-blocking + community IP reputation     │"
    echo "│ Protects SSH, Caddy, and other services                         │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    # ── DRY-RUN: describe the plan and bail before touching anything real ────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install the CrowdSec agent (curl https://install.crowdsec.net | sh; apt install crowdsec)"
        echo "[DRY-RUN] Would install the firewall bouncer (crowdsec-firewall-bouncer-iptables)"
        echo "[DRY-RUN] Would ensure /var/log/caddy exists for log acquisition"
        echo "[DRY-RUN] Would install collections: sshd, linux, caddy, base-http-scenarios"
        echo "[DRY-RUN] Would write Caddy acquisition /etc/crowdsec/acquis.d/caddy.yaml"
        echo "[DRY-RUN] Would install crowdsecurity/asterisk + write an acquisition if asterisk-digital-ocean is installed"
        echo "[DRY-RUN] Would optionally wire ntfy ban alerts into the default profile"
        echo "[DRY-RUN] Would optionally register with a remote/central LAPI and disable the local one"
        echo "[DRY-RUN] Would enable + restart crowdsec and crowdsec-firewall-bouncer"
        echo "[DRY-RUN] Would write $DOCS_DIR/README.md (docs-only folder)"
        return 0
    fi

    # ── 1. Install the CrowdSec agent ────────────────────────────────────────
    if command -v cscli &> /dev/null; then
        echo "  ✓ CrowdSec is already installed"
    else
        echo "  Adding CrowdSec repository and installing agent..."
        if curl -s https://install.crowdsec.net | sudo sh && sudo apt install -y crowdsec; then
            echo "  ✓ CrowdSec installed successfully"
        else
            echo "  ⚠ Failed to install CrowdSec"
            echo "  See https://docs.crowdsec.net/ for manual installation"
        fi
    fi

    # ── 2. Firewall bouncer (enforces bans via iptables/nftables) ────────────
    echo "  Installing firewall bouncer..."
    sudo apt install -y crowdsec-firewall-bouncer-iptables 2>/dev/null || \
        echo "  ⚠ Could not install firewall bouncer automatically"

    # ── 3. Create log directory for Caddy ────────────────────────────────────
    if [ ! -d "/var/log/caddy" ]; then
        sudo mkdir -p /var/log/caddy
        sudo chmod 755 /var/log/caddy
        echo "  ✓ Created /var/log/caddy directory"
    fi

    # ── 4. Detection collections: SSH, Caddy HTTP scenarios, base http ───────
    echo "  Installing CrowdSec collections (sshd, caddy, base-http)..."
    sudo cscli collections install crowdsecurity/sshd crowdsecurity/linux crowdsecurity/caddy crowdsecurity/base-http-scenarios 2>/dev/null || \
        echo "  ⚠ Some collections may already be installed"

    # ── 5. Tell CrowdSec to read Caddy's JSON access logs ────────────────────
    local ACQUIS_FILE="/etc/crowdsec/acquis.d/caddy.yaml"
    if [ ! -f "$ACQUIS_FILE" ]; then
        echo "  Creating Caddy log acquisition for CrowdSec..."
        sudo mkdir -p /etc/crowdsec/acquis.d
        local ACQUIS_CONTENT='filenames:
  - /var/log/caddy/*.log
  - /var/log/caddy/*-access.log
labels:
  type: caddy'
        if echo "$ACQUIS_CONTENT" | sudo tee "$ACQUIS_FILE" > /dev/null; then
            echo "  ✓ Created Caddy acquisition ($ACQUIS_FILE)"
        else
            echo "  ⚠ Failed to create acquisition - create it manually"
        fi
    else
        echo "  ✓ Caddy acquisition already exists"
    fi

    # ── 5b. SIP brute-force/enumeration protection, if asterisk-digital-ocean
    # is installed (services/asterisk-digital-ocean.sh patches Asterisk to log
    # security events — auth failures, registration scanning — to
    # $EA_DIR/logs/full. The plain LAN asterisk.sh doesn't emit that file yet,
    # so it's intentionally not detected here.)
    local ASTERISK_LOG_DIR="$DOCKER_DIR/asterisk-digital-ocean/logs"
    if [ -d "$ASTERISK_LOG_DIR" ]; then
        echo "  Detected asterisk-digital-ocean — installing SIP brute-force/enumeration protection..."
        sudo cscli collections install crowdsecurity/asterisk 2>/dev/null || \
            echo "  ⚠ crowdsecurity/asterisk collection may already be installed"

        local ASTERISK_ACQUIS="/etc/crowdsec/acquis.d/asterisk-digital-ocean.yaml"
        if [ ! -f "$ASTERISK_ACQUIS" ]; then
            local ASTERISK_ACQUIS_CONTENT="filenames:
  - $ASTERISK_LOG_DIR/full
  - $ASTERISK_LOG_DIR/full.*
labels:
  type: asterisk"
            if echo "$ASTERISK_ACQUIS_CONTENT" | sudo tee "$ASTERISK_ACQUIS" > /dev/null; then
                echo "  ✓ Created Asterisk acquisition ($ASTERISK_ACQUIS)"
            else
                echo "  ⚠ Failed to create Asterisk acquisition - create it manually"
            fi
        else
            echo "  ✓ Asterisk acquisition already exists"
        fi
    fi

    # ── 6. Geo-blocking + reputation (the capability fail2ban/Authelia lack) ─
    echo ""
    echo "  Geo-blocking & IP reputation (optional):"
    echo "    Subscribe to community/3rd-party blocklists at:"
    echo "      https://app.crowdsec.net/"
    echo ""
    local GEO_ALLOWLIST=""
    prompt_yn "Restrict Caddy-fronted web traffic to North America + Europe only (block every other country)? Does NOT affect SSH. (y/n):" "n" GEO_ALLOWLIST
    if [ "$GEO_ALLOWLIST" = "y" ] || [ "$GEO_ALLOWLIST" = "Y" ]; then
        echo "  Installing geoip-enrich (tags every event with a country code; no MaxMind"
        echo "  account needed — CrowdSec bundles its own redistributable GeoLite2 data)..."
        sudo cscli collections install crowdsecurity/geoip-enrich 2>/dev/null || \
            echo "  ⚠ crowdsecurity/geoip-enrich may already be installed"

        # North America + Europe, ISO 3166-1 alpha-2. Russia, Belarus, and
        # Turkey are left out (common abuse-traffic sources, and not really
        # "Europe" in the sense meant here). Core Eastern Europe (Bulgaria,
        # Czechia, Hungary, Moldova, Poland, Romania, Slovakia, Ukraine) is
        # left out too — the Balkans and Baltics (Albania, Bosnia, Croatia,
        # Estonia, Latvia, Lithuania, Montenegro, North Macedonia, Serbia,
        # Slovenia) are kept in deliberately, since several of them (Estonia
        # especially) don't fit the same risk profile despite the old
        # Cold-War grouping. To adjust, edit the two lists below and re-run,
        # or hand-edit $GEO_SCENARIO directly (it's plain YAML — no reinstall
        # needed, just restart crowdsec after).
        local _GEO_NA="US CA MX"
        local _GEO_EU="AD AL AT BA BE CH CY DE DK EE ES FI FR GB GR HR IE IS IT LI LT LU LV MC ME MK MT NL NO PT RS SE SI SM VA"
        local _geo_expr_list
        _geo_expr_list="$(printf "'%s', " $_GEO_NA $_GEO_EU)"
        _geo_expr_list="${_geo_expr_list%, }"

        # Scope: evt.Line.Labels.type is the acquisition-level "labels: type:"
        # field set in acquis.d/caddy.yaml (section 5 above) — this only ever
        # matches Caddy-sourced events, never SSH/syslog, so a mistake here
        # can't lock out the session running this installer.
        sudo mkdir -p /etc/crowdsec/scenarios
        local GEO_SCENARIO="/etc/crowdsec/scenarios/geo-allowlist-web.yaml"
        local GEO_SCENARIO_CONTENT="type: trigger
name: local/geo-allowlist-web
description: \"Block Caddy-fronted web requests from outside the allowed country list\"
filter: \"evt.Line.Labels.type == 'caddy' && evt.Enriched.IsoCode != '' && !(evt.Enriched.IsoCode in [${_geo_expr_list}])\"
groupby: evt.Meta.source_ip
blackhole: 1m
labels:
  service: http
  type: geo_allowlist
  remediation: true"
        if echo "$GEO_SCENARIO_CONTENT" | sudo tee "$GEO_SCENARIO" > /dev/null; then
            echo "  ✓ Geo-allowlist scenario written ($GEO_SCENARIO)"
            echo "  ⚠ This blocks ALL web visitors outside the allowed countries, including"
            echo "    Let's Encrypt's out-of-region validation checks (deliberately used to"
            echo "    prevent BGP-hijacking attacks) — if a cert renewal ever fails"
            echo "    mysteriously, check this scenario first."
            echo "  ℹ Allowed: $_GEO_NA $_GEO_EU"
            echo "  ℹ After restarting, verify it actually loaded (no typo/syntax issue):"
            echo "      sudo cscli metrics | grep geo-allowlist"
            echo "      sudo systemctl status crowdsec   # should stay 'active', not restart-looping"
        else
            echo "  ⚠ Failed to write geo-allowlist scenario — create it manually"
        fi
    fi

    # ── 7. Optional: push ban alerts to ntfy ─────────────────────────────────
    echo ""
    local CS_NTFY=""
    prompt_yn "Send CrowdSec ban alerts to an ntfy topic? (y/n):" "n" CS_NTFY
    if [ "$CS_NTFY" = "y" ] || [ "$CS_NTFY" = "Y" ]; then
        # Prefer a locally-installed ntfy's own base-url as the default, if one
        # exists and actually looks configured (not still the placeholder
        # domain ntfy.sh writes when no SITE_DOMAIN was set at its own install
        # time). Otherwise, nudge toward a hosted instance elsewhere (e.g. a
        # homelab) instead of silently defaulting to the public ntfy.sh.
        local _ntfy_default="https://ntfy.sh/crowdsec-alerts"
        if [ -f "$DOCKER_DIR/ntfy/config/server.yml" ]; then
            local _local_base_url
            _local_base_url="$(grep -oP '(?<=base-url: ")[^"]+' "$DOCKER_DIR/ntfy/config/server.yml" 2>/dev/null || true)"
            if [ -n "$_local_base_url" ] && [ "$_local_base_url" != "https://ntfy.example.com" ]; then
                _ntfy_default="${_local_base_url}/crowdsec-alerts"
                echo "  Detected a configured local ntfy instance at $_local_base_url — using it as the default."
            fi
        fi
        if [ "$_ntfy_default" = "https://ntfy.sh/crowdsec-alerts" ]; then
            echo "  No configured ntfy instance detected on this box. If you have one hosted"
            echo "  elsewhere (e.g. a homelab), enter its topic URL below instead of the public"
            echo "  ntfy.sh default — e.g. https://ntfy.your-homelab.com/crowdsec-alerts"
        fi
        local CS_NTFY_URL=""
        prompt_text "  ntfy topic URL:" "$_ntfy_default" CS_NTFY_URL
        sudo mkdir -p /etc/crowdsec/notifications
        local NTFY_FILE="/etc/crowdsec/notifications/ntfy.yaml"
        local NTFY_CONTENT="type: http
name: ntfy
log_level: info
format: |
  {{range . -}}
  {{range .Decisions -}}
  {{.Value}} banned: {{.Scenario}} for {{.Duration}}
  Check all bans:  sudo cscli decisions list
  Unban this IP:   sudo cscli decisions delete --ip {{.Value}}
  {{end -}}
  {{end -}}
url: $CS_NTFY_URL
method: POST
headers:
  Title: CrowdSec ban
  Priority: high
  Tags: rotating_light"
        if echo "$NTFY_CONTENT" | sudo tee "$NTFY_FILE" > /dev/null; then
            echo "  ✓ Created ntfy notification ($NTFY_FILE)"
            # Wire the notification into the default profile (only once)
            if ! grep -qE "^\s*- ntfy" /etc/crowdsec/profiles.yaml 2>/dev/null; then
                sudo awk '1; /^on_success:/ && !d {print "notifications:"; print "  - ntfy"; d=1}' \
                    /etc/crowdsec/profiles.yaml | sudo tee /etc/crowdsec/profiles.yaml.new > /dev/null \
                    && sudo mv /etc/crowdsec/profiles.yaml.new /etc/crowdsec/profiles.yaml
                echo "  ✓ Enabled ntfy alerts in CrowdSec default profile"
            else
                echo "  ✓ ntfy already referenced in CrowdSec profile"
            fi
            echo "  ℹ Alerts fire when an IP is banned (after repeated failed attempts),"
            echo "    not on every individual failed login."
        else
            echo "  ⚠ Failed to write ntfy notification config"
        fi
    fi

    # ── 7b. Optional: point this agent at a remote/central LAPI ──────────────
    # CrowdSec's real multi-server support: parsers/scenarios/bouncer still
    # run locally (banning only works where traffic actually arrives), but
    # the decision database (LAPI) can live on one central machine instead
    # of every box running its own. Useful if you already have CrowdSec on
    # a homelab and don't want a second LAPI+SQLite DB on this droplet.
    echo ""
    local USE_REMOTE_LAPI="" _REMOTE_LAPI_PENDING=""
    prompt_yn "Point this agent at a remote/central LAPI instead of running its own (e.g. one already on a homelab)? (y/n):" "n" USE_REMOTE_LAPI
    if [ "$USE_REMOTE_LAPI" = "y" ] || [ "$USE_REMOTE_LAPI" = "Y" ]; then
        echo ""
        echo "  This registers this machine and disables its local API server."
        echo "  The registration is PENDING until approved on the central LAPI"
        echo "  machine — that approval step can't be automated from here."
        echo ""
        local LAPI_URL="" LAPI_MACHINE=""
        prompt_text "  Central LAPI URL (e.g. http://homelab-ip:8080):" "" LAPI_URL
        prompt_text "  Machine name to register as:" "$(hostname)" LAPI_MACHINE
        if [ -n "$LAPI_URL" ]; then
            if sudo cscli lapi register -u "$LAPI_URL" --machine "$LAPI_MACHINE"; then
                echo "  ✓ Registered with $LAPI_URL as '$LAPI_MACHINE'"

                # Disable the local API server (remove the 'api.server:' block
                # from config.yaml) now that this agent forwards to the
                # central one instead. Backed up first — this is a direct
                # edit to CrowdSec's core config.
                local CS_CONFIG="/etc/crowdsec/config.yaml"
                local CS_BACKUP="$CS_CONFIG.backup.$(date +%Y%m%d-%H%M%S)"
                sudo cp "$CS_CONFIG" "$CS_BACKUP"
                sudo awk '
                    /^  server:/ { skip=1; next }
                    skip && /^([a-zA-Z]|  [a-zA-Z])/ { skip=0 }
                    !skip { print }
                ' "$CS_CONFIG" | sudo tee "$CS_CONFIG.new" > /dev/null \
                    && sudo mv "$CS_CONFIG.new" "$CS_CONFIG"
                echo "  ✓ Local API server disabled in config.yaml (backup: $(basename "$CS_BACKUP"))"
                echo ""
                echo "  ⚠ Not usable yet — on the CENTRAL LAPI machine, run:"
                echo "      sudo cscli machines validate $LAPI_MACHINE"
                echo "    Then restart this agent: sudo systemctl restart crowdsec"
                echo "    If it fails to start afterward, restore the backup and check logs:"
                echo "      sudo cp $CS_BACKUP $CS_CONFIG && sudo systemctl restart crowdsec"
                _REMOTE_LAPI_PENDING="y"
            else
                echo "  ⚠ cscli lapi register failed — keeping the local LAPI. See:"
                echo "    sudo cscli lapi register -u $LAPI_URL --machine $LAPI_MACHINE"
            fi
        else
            echo "  No URL entered — keeping the local LAPI."
        fi
    fi

    # ── 8. Restart services to apply ─────────────────────────────────────────
    if [ "$_REMOTE_LAPI_PENDING" = "y" ]; then
        echo ""
        echo "  Skipping the restart below — it would fail until the machine is"
        echo "  validated on the central LAPI (see above). Restart manually after:"
        echo "    sudo systemctl restart crowdsec"
    else
        local RESTART_CS=""
        prompt_yn "Restart CrowdSec to apply changes? (y/n):" "y" RESTART_CS
        if [ "$RESTART_CS" = "y" ] || [ "$RESTART_CS" = "Y" ]; then
            sudo systemctl enable crowdsec 2>/dev/null || true
            if sudo systemctl restart crowdsec; then
                echo "  ✓ CrowdSec restarted successfully"
                sudo systemctl enable crowdsec-firewall-bouncer 2>/dev/null || true
                sudo systemctl restart crowdsec-firewall-bouncer 2>/dev/null || true
                sleep 2
                sudo cscli metrics 2>/dev/null | head -20 || true
            else
                echo "  ⚠ Failed to restart CrowdSec"
                echo "  Check logs: sudo journalctl -u crowdsec -n 50"
            fi
        fi
    fi

    # ── 9. Docs-only folder under ~/docker for discoverability ───────────────
    write_readme "$DOCS_DIR" << 'CROWDSEC_README'
# CrowdSec — intrusion prevention

CrowdSec is a **system service** (installed via apt), not a Docker container, so
there is no `docker-compose.yml` in this folder — it exists only to document the
install. The real configuration lives under `/etc/crowdsec`.

## What it does

- Detects malicious behaviour (SSH brute force, web scans, SIP brute
  force/enumeration if `asterisk-digital-ocean` is installed) by parsing logs.
- Bans offending IPs via the **firewall bouncer** (iptables/nftables).
- Pulls **community IP reputation** blocklists so known-bad IPs are blocked
  before they ever touch your services.
- Optionally enriches events with **geo/ASN** data for geo-blocking.

## Key commands

```
sudo cscli metrics                      # parsers/scenarios/acquisition health
sudo cscli decisions list               # currently banned IPs
sudo cscli decisions delete --ip <IP>   # unban an IP
sudo cscli decisions add --ip <IP>      # manually ban an IP
sudo cscli alerts list                  # recent alerts
sudo cscli collections list             # installed detection collections
```

## Where configs live

- Log acquisition (what to watch): `/etc/crowdsec/acquis.d/`
  - Caddy access logs: `/etc/crowdsec/acquis.d/caddy.yaml`
    (`/var/log/caddy/*.log` — Caddy writes JSON access logs there)
  - Asterisk SIP auth events (if `asterisk-digital-ocean` is installed):
    `/etc/crowdsec/acquis.d/asterisk-digital-ocean.yaml`
    (`~/docker/asterisk-digital-ocean/logs/full` — auth failures, registration scans)
- Notifications: `/etc/crowdsec/notifications/`
  - ntfy ban alerts (if enabled): `/etc/crowdsec/notifications/ntfy.yaml`,
    wired into `/etc/crowdsec/profiles.yaml`
- Bouncer config: `/etc/crowdsec/bouncers/`
- Remote/central LAPI (if enabled): `/etc/crowdsec/local_api_credentials.yaml`
  points at the remote URL; the local API server block is removed from
  `/etc/crowdsec/config.yaml` (backed up as `config.yaml.backup.<timestamp>`
  next to it before editing). Parsers, scenarios, and the firewall bouncer
  still run locally regardless — only the decision database is centralized.

## Multi-server (remote LAPI) notes

- On THIS machine: `sudo cscli lapi register -u <url> --machine <name>`
  registers and disables the local API server.
- On the CENTRAL machine: `sudo cscli machines validate <name>` approves it —
  not automated, since that's a different box.
- Check registration status here: `sudo cscli lapi status`
- Revert: restore the `config.yaml` backup and
  `sudo systemctl restart crowdsec`.

## Geo + reputation notes

- Geo-enrichment (country/ASN tagging) is optional:
  `sudo cscli collections install crowdsecurity/geoip-enrich`
- Subscribe to community / 3rd-party blocklists at https://app.crowdsec.net/
- ntfy alerts fire when an IP is **banned** (after repeated failed attempts),
  not on every individual failed login.
- Geo-allowlist (if enabled): `/etc/crowdsec/scenarios/geo-allowlist-web.yaml`
  bans any Caddy-fronted web request from outside the countries listed in its
  `filter:` line. Web traffic only — SSH is never affected. Edit the country
  list directly in that file, then `sudo systemctl restart crowdsec`. This
  can block Let's Encrypt's out-of-region ACME validation checks; if a cert
  renewal fails mysteriously, check here first.

## Service control

```
sudo systemctl status crowdsec
sudo systemctl restart crowdsec
sudo systemctl status crowdsec-firewall-bouncer
sudo journalctl -u crowdsec -n 50
```
CROWDSEC_README

    echo ""
    echo "  Useful commands:"
    echo "    List active bans:   sudo cscli decisions list"
    echo "    List alerts:        sudo cscli alerts list"
    echo "    Manually ban IP:    sudo cscli decisions add --ip 1.2.3.4"
    echo "    Unban IP:           sudo cscli decisions delete --ip 1.2.3.4"
    echo "    Show metrics:       sudo cscli metrics"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_crowdsec
