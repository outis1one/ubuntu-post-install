#!/bin/bash
# services/security-dashboard.sh — Security dashboard: Asterisk failed-connection
# log + CrowdSec decisions (view/unban/ASN-exempt management), Authelia-protected.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash security-dashboard.sh
# (Docker must already be installed when run standalone — Caddy fronts this,
# even though the dashboard itself runs natively on the host, not in Docker)
#
# Why native, not Docker: it needs to run `cscli` (a host binary — CrowdSec is
# a system service, not a container, see services/crowdsec.sh) and read
# Asterisk's security log directly off disk. Running natively avoids bridging
# the container/host boundary entirely — no LAPI credentials to expose to a
# containerized frontend, no Docker socket mount. Same reasoning as why
# CrowdSec itself is a system service in this repo, not a docker-compose one.

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

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service security-dashboard homelab "Security dashboard: Asterisk failed-connections + CrowdSec bans (Authelia-protected)" 8092

install_security-dashboard() {
    local APP_DIR="/opt/security-dashboard"
    local DASHBOARD_PORT=8092
    local ASTERISK_LOG_DIR="$DOCKER_DIR/asterisk-digital-ocean/logs"
    local SVC_USER="secdash"
    local ASTERISK_ADMIN_URL=""
    if [ -f "$DOCKER_DIR/asterisk-digital-ocean/.env" ]; then
        local _ea_domain
        _ea_domain="$(grep -E '^DOMAIN_NAME=' "$DOCKER_DIR/asterisk-digital-ocean/.env" | cut -d= -f2-)"
        [ -n "$_ea_domain" ] && ASTERISK_ADMIN_URL="https://${_ea_domain}"
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ SECURITY DASHBOARD                                               │"
    echo "│ Asterisk failed-connection log + CrowdSec decisions, one page.  │"
    echo "│ Runs natively on the host (not Docker) so it can call cscli and │"
    echo "│ read Asterisk's security log directly. Authelia-protected.      │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [ ! -d "$ASTERISK_LOG_DIR" ]; then
        log_warning "No asterisk-digital-ocean install detected at $ASTERISK_LOG_DIR."
        log_warning "The Security Log tab will just be empty — CrowdSec's tab still works fine."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create system user $SVC_USER"
        echo "[DRY-RUN] Would write $APP_DIR/app.py"
        echo "[DRY-RUN] Would write /etc/sudoers.d/security-dashboard (scoped cscli/systemctl only)"
        echo "[DRY-RUN] Would write a systemd unit and start it on 0.0.0.0:$DASHBOARD_PORT (firewalled via UFW, not interface binding)"
        echo "[DRY-RUN] Would configure Caddy + Authelia for a domain you'll be prompted for"
        return 0
    fi

    if [ -f "$APP_DIR/app.py" ]; then
        local MODE=""
        prompt_reinstall_mode MODE 2>/dev/null || {
            # prompt_reinstall_mode isn't defined in the standalone stub — fall
            # back to a plain yes/no when run outside the full repo.
            local _r=""
            prompt_yn "  Security dashboard already exists at $APP_DIR — reconfigure? (y/n):" "n" _r
            [ "$_r" = "y" ] || [ "$_r" = "Y" ] && MODE="fresh" || MODE="cancel"
        }
        case "$MODE" in
            update)
                log_info "Refreshing app code only (no config/domain changes)..."
                _secdash_write_app "$APP_DIR"
                systemctl restart security-dashboard 2>/dev/null \
                    && log_success "security-dashboard restarted" \
                    || log_warning "Restart failed — check: systemctl status security-dashboard"
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) ;;
        esac
    fi

    # ── System user (no login, no home directory needed) ────────────────────
    if ! id "$SVC_USER" &>/dev/null; then
        useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"
        log_success "Created system user $SVC_USER"
    fi

    # Read access to the Asterisk security log without running as root or the
    # actual user — add secdash to the group that owns the log files instead.
    if [ -d "$ASTERISK_LOG_DIR" ]; then
        local _log_group
        _log_group="$(stat -c '%G' "$ASTERISK_LOG_DIR" 2>/dev/null || echo "$ACTUAL_USER")"
        usermod -aG "$_log_group" "$SVC_USER" 2>/dev/null || true
        chmod 750 "$ASTERISK_LOG_DIR" 2>/dev/null || true
    fi

    mkdir -p "$APP_DIR"
    _secdash_write_app "$APP_DIR"
    chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"

    # ── Scoped sudo — only the exact commands the app needs, nothing else ───
    # Numeric-only glob on the decision ID; Python subprocess calls always pass
    # args as a list (no shell=True anywhere), so there's no shell-metachar
    # injection surface even before sudoers' own pattern match kicks in — the
    # server-side ID validation (must be all-digits) happens before this is
    # ever reached, this is defense in depth, not the only check.
    cat > /etc/sudoers.d/security-dashboard << SUDOERS
$SVC_USER ALL=(root) NOPASSWD: /usr/bin/cscli decisions delete --id [0-9]*
$SVC_USER ALL=(root) NOPASSWD: /usr/bin/cscli decisions list -o json
$SVC_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart crowdsec
SUDOERS
    chmod 440 /etc/sudoers.d/security-dashboard
    visudo -c -f /etc/sudoers.d/security-dashboard >/dev/null 2>&1 \
        && log_success "Sudoers rule installed and validated" \
        || { log_error "Sudoers rule failed validation — removing it (dashboard's CrowdSec tab won't work until fixed)"; rm -f /etc/sudoers.d/security-dashboard; }

    # ── systemd unit ──────────────────────────────────────────────────────────
    cat > /etc/systemd/system/security-dashboard.service << SDSVC
[Unit]
Description=Security dashboard (Asterisk security log + CrowdSec decisions)
After=network.target

[Service]
Type=simple
User=$SVC_USER
Group=$SVC_USER
Environment=DASHBOARD_PORT=$DASHBOARD_PORT
Environment=ASTERISK_LOG=$ASTERISK_LOG_DIR/full
Environment=ASTERISK_ADMIN_URL=$ASTERISK_ADMIN_URL
ExecStart=/usr/bin/python3 $APP_DIR/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=false
ProtectSystem=strict
ReadOnlyPaths=$ASTERISK_LOG_DIR
ReadWritePaths=/etc/crowdsec/scenarios

[Install]
WantedBy=multi-user.target
SDSVC

    systemctl daemon-reload
    systemctl enable security-dashboard >/dev/null 2>&1
    if systemctl restart security-dashboard; then
        log_success "security-dashboard started on port $DASHBOARD_PORT (all interfaces — UFW scopes actual access)"
    else
        log_warning "Failed to start — check: systemctl status security-dashboard"
    fi

    # ── Caddy + Authelia ──────────────────────────────────────────────────────
    # This is deliberately more insistent about Authelia than most services —
    # it can delete active CrowdSec bans, so an unauthenticated exposure here
    # is a real security hole, not just an inconvenience.
    echo ""
    if command -v docker &>/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^caddy$"; then
        local _default_domain=""
        if [ -n "${SITE_DOMAIN:-}" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
            _default_domain="security.${SITE_DOMAIN}"
        fi
        local SD_DOMAIN=""
        prompt_text "  Domain for the dashboard (e.g. security.yourdomain.com), you'll need to point DNS at this droplet yourself [${_default_domain:-required}]:" "$_default_domain" SD_DOMAIN

        if [ -z "$SD_DOMAIN" ]; then
            log_warning "No domain entered — dashboard stays on http://localhost:$DASHBOARD_PORT only (not reachable from outside this box)."
        else
            local EXTRA_BLOCK=""
            if [ -d "$DOCKER_DIR/authelia" ]; then
                EXTRA_BLOCK="    import authelia"
                log_info "Local Authelia detected — protecting with it."
            else
                log_warning "No local Authelia found. This dashboard can delete active security"
                log_warning "bans — strongly recommend protecting it before exposing it publicly."
                local _use_remote=""
                prompt_yn "  Protect with a remote Authelia instance (e.g. on a homelab)? (y/n):" "y" _use_remote
                if [[ "$_use_remote" =~ ^[Yy]$ ]]; then
                    local _remote_authelia=""
                    prompt_text "  Remote Authelia address (bare host:port on a private network, or a full https:// URL on its own public domain+TLS):" "" _remote_authelia
                    if [ -n "$_remote_authelia" ]; then
                        # See services/asterisk-digital-ocean.sh for why
                        # X-Forwarded-Host must be a literal domain here, not
                        # the {host} placeholder — confirmed live that the
                        # placeholder still evaluates to the upstream
                        # Authelia's own hostname for a scheme-qualified
                        # remote upstream, not the original site's.
                        EXTRA_BLOCK="    forward_auth ${_remote_authelia} {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        header_up X-Forwarded-Method {method}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host ${SD_DOMAIN}
        header_up X-Forwarded-Uri {uri}
    }"
                    fi
                fi
            fi

            if [ -z "$EXTRA_BLOCK" ]; then
                log_error "Proceeding WITHOUT Authelia protection — anyone who finds this domain"
                log_error "can view and delete active security bans. Strongly reconsider."
                local _confirm_unsafe=""
                prompt_yn "  Really continue without auth protection? (y/n):" "n" _confirm_unsafe
                if [[ ! "$_confirm_unsafe" =~ ^[Yy]$ ]]; then
                    log_info "Skipping Caddy setup. Re-run this installer once Authelia is available."
                    SD_DOMAIN=""
                fi
            fi

            if [ -n "$SD_DOMAIN" ]; then
                local CADDY_FILE="$DOCKER_DIR/caddy/Caddyfile"
                if [ -f "$CADDY_FILE" ] && ! grep -q "^${SD_DOMAIN} {" "$CADDY_FILE"; then
                    cat >> "$CADDY_FILE" << CADDYBLOCK

# Security Dashboard
${SD_DOMAIN} {
${EXTRA_BLOCK}
    reverse_proxy host.docker.internal:${DASHBOARD_PORT}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${SD_DOMAIN}.log
        format json
    }
}
CADDYBLOCK
                    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                    docker compose -f "$DOCKER_DIR/caddy/docker-compose.yml" restart caddy 2>/dev/null \
                        && log_success "Caddy restarted — dashboard at https://${SD_DOMAIN}" \
                        || log_warning "Restart Caddy manually: cd $DOCKER_DIR/caddy && docker compose restart"
                elif [ -f "$CADDY_FILE" ]; then
                    log_warning "$SD_DOMAIN already in Caddyfile — leaving the existing entry alone."
                fi

                # Port 8092 never needs to be open to the internet — only Caddy
                # (local, via host.docker.internal) ever needs to reach it.
                if command -v ufw &>/dev/null; then
                    ufw delete allow "${DASHBOARD_PORT}/tcp" 2>/dev/null || true
                    if declare -f ufw_allow_from_caddy_net >/dev/null 2>&1; then
                        ufw_allow_from_caddy_net "${DASHBOARD_PORT}"
                    fi
                fi
            fi
        fi
    else
        log_info "Caddy not running — dashboard stays on http://localhost:$DASHBOARD_PORT until you set it up."
    fi

    write_readme "$APP_DIR" << README_MD
# Security Dashboard

Asterisk failed-connection log + CrowdSec ban management, one Authelia-
protected page. Runs natively on the host (systemd service \`security-dashboard\`),
not in Docker — it needs to call \`cscli\` and read Asterisk's log directly.

## Tabs
- **Security Log** — parses \`$ASTERISK_LOG_DIR/full\` for SIP auth failures
  (wrong password, unknown extension, etc.) with timestamp/account/remote IP.
- **CrowdSec** — current bans (\`cscli decisions list\`), a delete/unban button
  per entry, and a way to add/remove ASNs from the ASN-exempt Asterisk
  brute-force scenarios (see \`services/crowdsec.sh\`'s "Exempt specific carrier
  ASNs" option) without SSHing in.
- Link to the Asterisk web admin itself (doesn't embed it, just links out).

## Manage
\`\`\`
sudo systemctl status security-dashboard
sudo systemctl restart security-dashboard
sudo journalctl -u security-dashboard -f
\`\`\`

## Security notes
- Runs as a dedicated, unprivileged system user (\`secdash\`), not root.
- Sudo access is scoped to exactly three commands via
  \`/etc/sudoers.d/security-dashboard\`: \`cscli decisions delete --id <digits>\`,
  \`cscli decisions list -o json\`, and \`systemctl restart crowdsec\`. Nothing else.
- Listens on all interfaces (Caddy reaches it via \`host.docker.internal\`, a
  Docker bridge IP — a loopback-only bind refuses that). Access is scoped by
  UFW instead, allowed only from Caddy's internal network, not the internet.
- **This page can delete active security bans.** Don't run it without Authelia
  (or equivalent) in front of it.
README_MD

    echo ""
    echo "  Local access: http://localhost:$DASHBOARD_PORT"
    echo "  README:       $APP_DIR/README.md"
    echo ""
}

# Writes the Python app. Separate function so "update" mode (refresh code,
# keep config) and fresh installs share one copy instead of drifting apart.
_secdash_write_app() {
    local _app_dir="$1"
    mkdir -p "$_app_dir"
    cat > "$_app_dir/app.py" << 'PYAPP'
#!/usr/bin/env python3
"""Security dashboard: Asterisk failed-connection log + CrowdSec decisions.

Stdlib only, deliberately — this runs on a small droplet alongside Asterisk,
Caddy, and CrowdSec, and shouldn't add a framework's worth of RAM overhead.
"""
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASHBOARD_PORT", "8092"))
ASTERISK_LOG = os.environ.get("ASTERISK_LOG", "")
ASTERISK_ADMIN_URL = os.environ.get("ASTERISK_ADMIN_URL", "")
ASN_SCENARIO_FILES = [
    "/etc/crowdsec/scenarios/local-asterisk_bf.yaml",
    "/etc/crowdsec/scenarios/local-asterisk_user_enum.yaml",
]

TS_RE = re.compile(r"^\[([^\]]+)\]")
KV_RE = re.compile(r'(\w+)="([^"]*)"')
ASN_FILTER_RE = re.compile(r"ASNNumber in \[([^\]]*)\]\)")
ID_RE = re.compile(r"^\d+$")
ASN_RE = re.compile(r"^\d+$")


def parse_security_log(limit=200):
    """Tail ASTERISK_LOG and return the most recent SecurityEvent lines,
    newest first, as dicts. Missing file / no lines -> empty list, never an
    error — this is a convenience view, not load-bearing."""
    if not ASTERISK_LOG or not os.path.isfile(ASTERISK_LOG):
        return []
    events = []
    try:
        with open(ASTERISK_LOG, "r", errors="replace") as f:
            lines = f.readlines()[-5000:]  # cap how much we ever scan
    except OSError:
        return []
    for line in lines:
        if "SecurityEvent=" not in line:
            continue
        ts_match = TS_RE.match(line)
        fields = dict(KV_RE.findall(line))
        if not fields.get("SecurityEvent"):
            continue
        events.append({
            "timestamp": ts_match.group(1) if ts_match else "",
            "event": fields.get("SecurityEvent", ""),
            "severity": fields.get("Severity", ""),
            "account": fields.get("AccountID", ""),
            "remote": fields.get("RemoteAddress", ""),
            "reason": fields.get("SecurityEvent", ""),
        })
    events.reverse()
    return events[:limit]


def run_sudo(args, timeout=15):
    """Runs a whitelisted sudo command. Always list-form args, never
    shell=True — no shell metacharacter interpretation is possible regardless
    of what's in the arguments, on top of the sudoers-side restriction."""
    try:
        result = subprocess.run(
            ["sudo"] + args, capture_output=True, text=True, timeout=timeout
        )
        return result.returncode == 0, result.stdout, result.stderr
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, "", str(e)


def get_decisions():
    ok, out, err = run_sudo(["/usr/bin/cscli", "decisions", "list", "-o", "json"])
    if not ok or not out.strip():
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    decisions = []
    for alert in data or []:
        for d in alert.get("decisions") or []:
            decisions.append({
                "id": d.get("id"),
                "value": d.get("value"),
                "scenario": d.get("scenario"),
                "duration": d.get("duration"),
                "origin": d.get("origin"),
            })
    return decisions


def delete_decision(decision_id):
    if not ID_RE.match(str(decision_id)):
        return False, "Invalid decision ID"
    ok, out, err = run_sudo(["/usr/bin/cscli", "decisions", "delete", "--id", str(decision_id)])
    return ok, (err or out or ("deleted" if ok else "failed"))


def get_asn_exempt():
    asns = set()
    for path in ASN_SCENARIO_FILES:
        try:
            with open(path) as f:
                content = f.read()
        except OSError:
            continue
        m = ASN_FILTER_RE.search(content)
        if m:
            for tok in m.group(1).split(","):
                tok = tok.strip().strip("'").strip('"')
                if tok:
                    asns.add(tok)
    return sorted(asns, key=lambda x: int(x) if x.isdigit() else 0)


def set_asn_exempt(asn_list):
    clean = [a.strip() for a in asn_list if ASN_RE.match(a.strip())]
    if not clean:
        return False, "No valid (numeric) ASNs provided"
    expr = ", ".join("'%s'" % a for a in clean)
    for path in ASN_SCENARIO_FILES:
        try:
            with open(path) as f:
                content = f.read()
        except OSError:
            continue
        new_content = ASN_FILTER_RE.sub("ASNNumber in [%s])" % expr, content)
        try:
            with open(path, "w") as f:
                f.write(new_content)
        except OSError as e:
            return False, "Failed writing %s: %s" % (path, e)
    ok, out, err = run_sudo(["/usr/bin/systemctl", "restart", "crowdsec"])
    if not ok:
        return False, "Wrote ASN list but failed to restart CrowdSec: %s" % (err or out)
    return True, "Updated: %s" % ", ".join(clean)


INDEX_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<title>Security Dashboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  body { font-family: system-ui, sans-serif; margin: 0; background: #0f1115; color: #e6e6e6; }
  header { padding: 1rem 1.5rem; background: #171a21; border-bottom: 1px solid #2a2e38; display: flex; align-items: center; gap: 1rem; }
  header h1 { font-size: 1.1rem; margin: 0; flex: 1; }
  nav button { background: none; border: none; color: #9aa4b2; padding: 0.6rem 1rem; cursor: pointer; font-size: 0.95rem; border-bottom: 2px solid transparent; }
  nav button.active { color: #fff; border-bottom-color: #4f8cff; }
  main { padding: 1.5rem; max-width: 1100px; margin: 0 auto; }
  table { width: 100%; border-collapse: collapse; font-size: 0.85rem; }
  th, td { text-align: left; padding: 0.5rem 0.6rem; border-bottom: 1px solid #23262f; }
  th { color: #9aa4b2; font-weight: 600; }
  .sev-Error { color: #ff6b6b; }
  .sev-Warning { color: #f5b342; }
  .sev-Informational { color: #7fbf7f; }
  button.action { background: #2a2e38; color: #e6e6e6; border: 1px solid #3a3f4b; border-radius: 4px; padding: 0.3rem 0.7rem; cursor: pointer; }
  button.action:hover { background: #3a3f4b; }
  .card { background: #171a21; border: 1px solid #2a2e38; border-radius: 8px; padding: 1rem; margin-bottom: 1rem; }
  input[type=text] { background: #0f1115; border: 1px solid #3a3f4b; color: #e6e6e6; padding: 0.4rem 0.6rem; border-radius: 4px; width: 100%; box-sizing: border-box; }
  .row { display: flex; gap: 0.5rem; align-items: center; }
  .muted { color: #9aa4b2; font-size: 0.85rem; }
  a { color: #4f8cff; }
  #msg { margin-top: 0.5rem; font-size: 0.85rem; }
</style>
</head>
<body>
<header>
  <h1>Security Dashboard</h1>
  <nav>
    <button class="tab-btn active" data-tab="security">Security Log</button>
    <button class="tab-btn" data-tab="crowdsec">CrowdSec</button>
  </nav>
  <a id="admin-link" href="#" target="_blank" style="display:none">Asterisk Web Admin &#8599;</a>
</header>
<main>
  <div id="tab-security">
    <div class="card">
      <p class="muted">Recent Asterisk SIP security events, newest first. Errors/warnings are real auth failures; informational lines are normal registration traffic.</p>
      <table id="sec-table"><thead><tr><th>Time</th><th>Event</th><th>Account</th><th>Remote</th><th>Severity</th></tr></thead><tbody></tbody></table>
    </div>
  </div>
  <div id="tab-crowdsec" style="display:none">
    <div class="card">
      <h3 style="margin-top:0">Active bans</h3>
      <table id="dec-table"><thead><tr><th>IP/Range</th><th>Scenario</th><th>Duration</th><th>Origin</th><th></th></tr></thead><tbody></tbody></table>
    </div>
    <div class="card">
      <h3 style="margin-top:0">Asterisk brute-force ASN exemptions</h3>
      <p class="muted">Carrier ASNs exempted from the Asterisk brute-force scenarios only — SSH/web/geo protection is unaffected. See CLAUDE.md / services/crowdsec.sh for background.</p>
      <div class="row">
        <input type="text" id="asn-input" placeholder="e.g. 21928, 14593">
        <button class="action" id="asn-save">Save</button>
      </div>
      <div id="msg"></div>
    </div>
  </div>
</main>
<script>
function esc(s) { return (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    document.getElementById("tab-security").style.display = btn.dataset.tab === "security" ? "" : "none";
    document.getElementById("tab-crowdsec").style.display = btn.dataset.tab === "crowdsec" ? "" : "none";
  });
});

async function loadSecurity() {
  const res = await fetch("/api/security-events");
  const events = await res.json();
  const tbody = document.querySelector("#sec-table tbody");
  tbody.innerHTML = events.map(e => `<tr>
    <td>${esc(e.timestamp)}</td>
    <td>${esc(e.event)}</td>
    <td>${esc(e.account)}</td>
    <td>${esc(e.remote)}</td>
    <td class="sev-${esc(e.severity)}">${esc(e.severity)}</td>
  </tr>`).join("") || "<tr><td colspan=5 class=muted>No events found.</td></tr>";
}

async function loadDecisions() {
  const res = await fetch("/api/decisions");
  const decisions = await res.json();
  const tbody = document.querySelector("#dec-table tbody");
  tbody.innerHTML = decisions.map(d => `<tr>
    <td>${esc(d.value)}</td>
    <td>${esc(d.scenario)}</td>
    <td>${esc(d.duration)}</td>
    <td>${esc(d.origin)}</td>
    <td><button class="action" onclick="unban(${d.id})">Unban</button></td>
  </tr>`).join("") || "<tr><td colspan=5 class=muted>No active bans.</td></tr>";
}

async function unban(id) {
  if (!confirm("Unban decision #" + id + "?")) return;
  const res = await fetch("/api/decisions/delete", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id})});
  const data = await res.json();
  alert(data.message || (data.ok ? "Unbanned" : "Failed"));
  loadDecisions();
}

async function loadAsnExempt() {
  const res = await fetch("/api/asn-exempt");
  const data = await res.json();
  document.getElementById("asn-input").value = (data.asns || []).join(", ");
}

document.getElementById("asn-save").addEventListener("click", async () => {
  const raw = document.getElementById("asn-input").value;
  const asns = raw.split(",").map(s => s.trim()).filter(Boolean);
  const res = await fetch("/api/asn-exempt", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({asns: asns})});
  const data = await res.json();
  document.getElementById("msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
});

const adminUrl = "__ASTERISK_ADMIN_URL__";
if (adminUrl) {
  const link = document.getElementById("admin-link");
  link.href = adminUrl;
  link.style.display = "";
}

loadSecurity();
loadDecisions();
loadAsnExempt();
setInterval(loadSecurity, 30000);
setInterval(loadDecisions, 30000);
</script>
</body></html>
"""


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _html(self, html, status=200):
        body = html.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "":
            html = INDEX_HTML.replace("__ASTERISK_ADMIN_URL__", ASTERISK_ADMIN_URL)
            self._html(html)
        elif self.path == "/api/security-events":
            self._json(parse_security_log())
        elif self.path == "/api/decisions":
            self._json(get_decisions())
        elif self.path == "/api/asn-exempt":
            self._json({"asns": get_asn_exempt()})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            payload = {}

        if self.path == "/api/decisions/delete":
            ok, message = delete_decision(payload.get("id", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/asn-exempt":
            ok, message = set_asn_exempt(payload.get("asns", []))
            self._json({"ok": ok, "message": message})
        else:
            self._json({"error": "not found"}, 404)

    def log_message(self, fmt, *args):
        pass  # systemd journal captures stdout/stderr already; keep it quiet


def main():
    ThreadingHTTPServer.allow_reuse_address = True
    # 0.0.0.0, not 127.0.0.1: Caddy runs in a container and reaches this via
    # host.docker.internal (a Docker bridge gateway IP, not localhost) — a
    # loopback-only bind refuses that connection outright. Confirmed live:
    # "dial tcp 172.17.0.1:8092: connect: connection refused" even though
    # curl from the host itself worked fine on 127.0.0.1. Access is scoped by
    # UFW (see install_security-dashboard), not by which interface this binds
    # to — same pattern every other host-network service in this repo uses.
    with ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as httpd:
        print(f"Security dashboard running on 0.0.0.0:{PORT}")
        httpd.serve_forever()


if __name__ == "__main__":
    main()
PYAPP
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_security-dashboard
