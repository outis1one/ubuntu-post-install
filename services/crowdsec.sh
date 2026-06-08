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
        echo "[DRY-RUN] Would optionally wire ntfy ban alerts into the default profile"
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

    # ── 6. Geo-blocking + reputation (the capability fail2ban/Authelia lack) ─
    echo ""
    echo "  Geo-blocking & IP reputation (optional):"
    echo "    Enrich events with country/ASN data:"
    echo "      sudo cscli collections install crowdsecurity/geoip-enrich"
    echo "    Subscribe to community/3rd-party blocklists at:"
    echo "      https://app.crowdsec.net/"

    # ── 7. Optional: push ban alerts to ntfy ─────────────────────────────────
    local CS_NTFY=""
    prompt_yn "Send CrowdSec ban alerts to an ntfy topic? (y/n):" "n" CS_NTFY
    if [ "$CS_NTFY" = "y" ] || [ "$CS_NTFY" = "Y" ]; then
        local CS_NTFY_URL=""
        prompt_text "  ntfy topic URL (e.g. https://ntfy.sh/my-crowdsec):" "https://ntfy.sh/crowdsec-alerts" CS_NTFY_URL
        sudo mkdir -p /etc/crowdsec/notifications
        local NTFY_FILE="/etc/crowdsec/notifications/ntfy.yaml"
        local NTFY_CONTENT="type: http
name: ntfy
log_level: info
format: |
  {{range . -}}
  {{range .Decisions -}}
  {{.Value}} banned: {{.Scenario}} for {{.Duration}}
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

    # ── 8. Restart services to apply ─────────────────────────────────────────
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

    # ── 9. Docs-only folder under ~/docker for discoverability ───────────────
    write_readme "$DOCS_DIR" << 'CROWDSEC_README'
# CrowdSec — intrusion prevention

CrowdSec is a **system service** (installed via apt), not a Docker container, so
there is no `docker-compose.yml` in this folder — it exists only to document the
install. The real configuration lives under `/etc/crowdsec`.

## What it does

- Detects malicious behaviour (SSH brute force, web scans, etc.) by parsing logs.
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
- Notifications: `/etc/crowdsec/notifications/`
  - ntfy ban alerts (if enabled): `/etc/crowdsec/notifications/ntfy.yaml`,
    wired into `/etc/crowdsec/profiles.yaml`
- Bouncer config: `/etc/crowdsec/bouncers/`

## Geo + reputation notes

- Geo-enrichment (country/ASN tagging) is optional:
  `sudo cscli collections install crowdsecurity/geoip-enrich`
- Subscribe to community / 3rd-party blocklists at https://app.crowdsec.net/
- ntfy alerts fire when an IP is **banned** (after repeated failed attempts),
  not on every individual failed login.

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
