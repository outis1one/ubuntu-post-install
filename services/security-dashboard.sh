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
    local SVC_USER="secdash"

    # Either Asterisk flavor works — prefer asterisk-digital-ocean if both
    # happen to be installed, matching services/pstn-trunk.sh's own
    # preference order for consistency.
    local ASTERISK_EA_DIR=""
    if [ -d "$DOCKER_DIR/asterisk-digital-ocean" ]; then
        ASTERISK_EA_DIR="$DOCKER_DIR/asterisk-digital-ocean"
    elif [ -d "$DOCKER_DIR/asterisk" ]; then
        ASTERISK_EA_DIR="$DOCKER_DIR/asterisk"
    fi
    local ASTERISK_LOG_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/logs}"
    local ASTERISK_CONFIG_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/config/asterisk}"

    local ASTERISK_ADMIN_URL=""
    if [ -n "$ASTERISK_EA_DIR" ] && [ -f "$ASTERISK_EA_DIR/.env" ]; then
        local _ea_domain
        _ea_domain="$(grep -E '^DOMAIN_NAME=' "$ASTERISK_EA_DIR/.env" | cut -d= -f2-)"
        [ -n "$_ea_domain" ] && ASTERISK_ADMIN_URL="https://${_ea_domain}"
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ SECURITY DASHBOARD                                               │"
    echo "│ Asterisk failed-connection log + CrowdSec decisions + PSTN      │"
    echo "│ trunk permissions, one page. Runs natively on the host (not     │"
    echo "│ Docker) so it can call cscli and read Asterisk's files          │"
    echo "│ directly. Authelia-protected.                                   │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [ -z "$ASTERISK_EA_DIR" ]; then
        log_warning "No asterisk-digital-ocean or asterisk install detected."
        log_warning "The Security Log and PSTN Trunk tabs will just be empty — CrowdSec's tab still works fine."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create system user $SVC_USER"
        echo "[DRY-RUN] Would write $APP_DIR/app.py"
        echo "[DRY-RUN] Would write /etc/sudoers.d/security-dashboard (scoped cscli/systemctl only)"
        echo "[DRY-RUN] Would write a systemd unit and start it on 0.0.0.0:$DASHBOARD_PORT (firewalled via UFW, not interface binding)"
        echo "[DRY-RUN] Would grant read/write access to the detected Asterisk config dir (for the PSTN Trunk tab)"
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
                log_info "Refreshing app code + sudoers rule + systemd unit (no Caddy/domain changes)..."
                _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR"
                _secdash_write_app "$APP_DIR"
                _secdash_write_sudoers "$SVC_USER"
                _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_ADMIN_URL"
                systemctl restart security-dashboard 2>/dev/null \
                    && log_success "security-dashboard restarted" \
                    || log_warning "Restart failed — check: systemctl status security-dashboard"

                echo ""
                local _reconf=""
                prompt_yn "Reconfigure this dashboard's Caddy protection (Authelia domain, or add/rotate an independent Basic Auth layer)? (y/n):" "n" _reconf
                if [[ "$_reconf" =~ ^[Yy]$ ]]; then
                    _secdash_remove_caddy_block "$DASHBOARD_PORT"
                    _secdash_configure_caddy "$DASHBOARD_PORT"
                fi
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

    _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR"

    mkdir -p "$APP_DIR"
    _secdash_write_app "$APP_DIR"
    chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"

    _secdash_write_sudoers "$SVC_USER"
    _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_ADMIN_URL"

    systemctl daemon-reload
    systemctl enable security-dashboard >/dev/null 2>&1
    if systemctl restart security-dashboard; then
        log_success "security-dashboard started on port $DASHBOARD_PORT (all interfaces — UFW scopes actual access)"
    else
        log_warning "Failed to start — check: systemctl status security-dashboard"
    fi

    # ── Caddy + Authelia (+ optional independent Basic Auth) ────────────────
    # This is deliberately more insistent about auth than most services — it
    # can delete active CrowdSec bans, so an unauthenticated exposure here is
    # a real security hole, not just an inconvenience. Factored into
    # _secdash_configure_caddy so "update" mode can also offer to reconfigure
    # it later (e.g. to add Basic Auth to an already-deployed dashboard)
    # without duplicating this logic — see that function for the rest.
    _secdash_configure_caddy "$DASHBOARD_PORT"

    write_readme "$APP_DIR" << README_MD
# Security Dashboard

Asterisk failed-connection log + CrowdSec ban management, one Authelia-
protected page. Runs natively on the host (systemd service \`security-dashboard\`),
not in Docker — it needs to call \`cscli\` and read Asterisk's log directly.

## Tabs
- **Security Log** — parses \`$ASTERISK_LOG_DIR/full\` for SIP auth failures
  (wrong password, unknown extension, etc.) with timestamp/account/remote IP.
- **CrowdSec** — current bans (\`cscli decisions list\`), a delete/unban button
  per entry, carrier/ASN + country columns, and management of the ASN-exempt
  Asterisk brute-force scenarios (see \`services/crowdsec.sh\`'s "Exempt
  specific carrier ASNs" option) without SSHing in:
  - **Currently-exempt ASNs** are listed with carrier name (resolved from
    current bans, falling back to alert history for ASNs with no active ban
    right now) regardless of when they were added.
  - **Unwhitelist** removes an ASN from the exemption list — future Asterisk
    auth failures from it are evaluated normally again.
  - **Unwhitelist + Ban** does that *and* immediately bans (24h) every IP
    CrowdSec has ever recorded for that ASN, for accidental-whitelist cases
    where you don't want to wait for it to misbehave again.
- **PSTN Trunk** (only if \`services/pstn-trunk.sh\` is installed) — the
  outbound/inbound concurrent-call caps, and every known extension (parsed
  from \`pjsip.conf\`) with its current permission tier (internal /
  restricted / full) and, for restricted, its approved numbers — all
  editable live, no Asterisk restart, no reinstall. Writes directly to
  \`pstn-limits.conf\` / \`pstn-permissions.conf\`, which the dialplan reads
  fresh on every call.
- Link to the Asterisk web admin itself (doesn't embed it, just links out).

## Manage
\`\`\`
sudo systemctl status security-dashboard
sudo systemctl restart security-dashboard
sudo journalctl -u security-dashboard -f
\`\`\`

## Security notes
- Runs as a dedicated, unprivileged system user (\`secdash\`), not root.
- Sudo access is scoped to exactly five commands via
  \`/etc/sudoers.d/security-dashboard\`: \`cscli decisions delete --id <digits>\`,
  \`cscli decisions list -o json\`, \`cscli alerts list -o json\` (read-only,
  used to label ASN exemptions with a carrier name from past alerts and to
  find known offending IPs for the "Ban" action), \`cscli decisions add --ip
  <ip> --duration <dur> --type ban --reason <text>\` (used only by "Ban"),
  and \`systemctl restart crowdsec\`. Nothing else.
- Listens on all interfaces (Caddy reaches it via \`host.docker.internal\`, a
  Docker bridge IP — a loopback-only bind refuses that). Access is scoped by
  UFW instead, allowed only from Caddy's internal network, not the internet.
- **This page can delete active security bans.** It's protected by Authelia
  (or a remote instance) by default, and the installer offers a second,
  independent HTTP Basic Auth layer in front of that — a request must pass
  Basic Auth *and* Authelia before it ever reaches the app, so an Authelia
  bug or misconfiguration alone isn't enough to expose this page. Re-run the
  installer ("update" mode → reconfigure Caddy protection) to add, rotate, or
  remove that Basic Auth layer later.
README_MD

    echo ""
    echo "  Local access: http://localhost:$DASHBOARD_PORT"
    echo "  README:       $APP_DIR/README.md"
    echo ""
}

# Grants secdash read/write access to wherever Asterisk's config lives
# without running the dashboard as root or the actual user — added to the
# group that already owns those directories (ensure_docker_dir_ownership
# elsewhere in this repo sets both owner AND group to ACTUAL_USER, so the log
# dir and config dir normally share one group already; handled separately
# anyway in case that ever changes). Separate function, called from both
# "update" and fresh-install, so a PSTN trunk installed *after* this
# dashboard (or an asterisk-digital-ocean/asterisk swap) reaches an existing
# install on its next update instead of silently only applying to new ones.
_secdash_grant_asterisk_access() {
    local _svc_user="$1" _log_dir="$2" _config_dir="$3"
    local _dir
    for _dir in "$_log_dir" "$_config_dir"; do
        [ -n "$_dir" ] && [ -d "$_dir" ] || continue
        local _group
        _group="$(stat -c '%G' "$_dir" 2>/dev/null || echo "$ACTUAL_USER")"
        usermod -aG "$_group" "$_svc_user" 2>/dev/null || true
        chmod 750 "$_dir" 2>/dev/null || true
    done
    # pstn-permissions.conf specifically needs group WRITE (750 above is
    # read+execute for the group, not write) — the file itself is written
    # group-writable (664) by services/pstn-trunk.sh, but the containing
    # directory also needs the group execute+write bit for a new file save
    # (configparser writes a fresh temp file then renames it into place) to
    # succeed. 770 only on the config dir, not the log dir (no reason for
    # secdash to ever create files in the log dir).
    if [ -n "$_config_dir" ] && [ -d "$_config_dir" ]; then
        chmod 770 "$_config_dir" 2>/dev/null || true
    fi
}

# Systemd unit — separate function so "update" mode can refresh it too
# (Environment= vars and ReadWritePaths depend on which Asterisk flavor is
# detected, which can change between installs — e.g. a PSTN trunk or a
# different Asterisk flavor installed after this dashboard's first setup).
# ProtectSystem=strict makes the whole filesystem read-only for this unit
# except the paths explicitly listed below, regardless of Unix permissions —
# both layers (this AND the group access above) need to agree, or writes
# fail even when Unix permissions alone would have allowed them.
_secdash_write_systemd_unit() {
    local _app_dir="$1" _svc_user="$2" _port="$3" _log_dir="$4" _config_dir="$5" _admin_url="$6"
    local _read_only_paths="" _read_write_paths="/etc/crowdsec/scenarios"
    [ -n "$_log_dir" ] && _read_only_paths="$_log_dir"
    [ -n "$_config_dir" ] && _read_write_paths="$_read_write_paths $_config_dir"

    cat > /etc/systemd/system/security-dashboard.service << SDSVC
[Unit]
Description=Security dashboard (Asterisk security log + CrowdSec decisions + PSTN trunk permissions)
After=network.target

[Service]
Type=simple
User=$_svc_user
Group=$_svc_user
Environment=DASHBOARD_PORT=$_port
Environment=ASTERISK_LOG=${_log_dir:+$_log_dir/full}
Environment=ASTERISK_CONFIG_DIR=$_config_dir
Environment=ASTERISK_ADMIN_URL=$_admin_url
ExecStart=/usr/bin/python3 $_app_dir/app.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=false
ProtectSystem=strict
ReadOnlyPaths=$_read_only_paths
ReadWritePaths=$_read_write_paths

[Install]
WantedBy=multi-user.target
SDSVC
}

# Scoped sudo — only the exact commands the app needs, nothing else. Numeric-
# only glob on the decision ID; Python subprocess calls always pass args as a
# list (no shell=True anywhere), so there's no shell-metachar injection
# surface even before sudoers' own pattern match kicks in — the server-side
# ID validation (must be all-digits) happens before this is ever reached,
# this is defense in depth, not the only check. Separate function, called
# from both "update" and fresh-install, so adding a new permission later
# (like alerts list, added after ASN-exempt entries with no currently-active
# ban had no carrier name to show) reaches existing installs on their next
# update instead of silently only applying to new ones.
_secdash_write_sudoers() {
    local _svc_user="$1"
    cat > /etc/sudoers.d/security-dashboard << SUDOERS
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions delete --id [0-9]*
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions list -o json
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli alerts list -o json
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions add --ip * --duration * --type ban --reason *
$_svc_user ALL=(root) NOPASSWD: /usr/bin/systemctl restart crowdsec
SUDOERS
    chmod 440 /etc/sudoers.d/security-dashboard
    visudo -c -f /etc/sudoers.d/security-dashboard >/dev/null 2>&1 \
        && log_success "Sudoers rule installed and validated" \
        || { log_error "Sudoers rule failed validation — removing it (dashboard's CrowdSec tab won't work until fixed)"; rm -f /etc/sudoers.d/security-dashboard; }
}

# Caddy + Authelia (+ optional independent Basic Auth) for the dashboard.
# Separate function so "update" mode can call _secdash_remove_caddy_block +
# this to reconfigure an already-deployed dashboard (e.g. to add Basic Auth
# retroactively) using the exact same code path as a fresh install, instead
# of hand-patching a live Caddyfile block in place.
_secdash_configure_caddy() {
    local DASHBOARD_PORT="$1"

    echo ""
    if ! command -v docker &>/dev/null || ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^caddy$"; then
        log_info "Caddy not running — dashboard stays on http://localhost:$DASHBOARD_PORT until you set it up."
        return 0
    fi

    local _default_domain=""
    if [ -n "${SITE_DOMAIN:-}" ] && [ "$SITE_DOMAIN" != "example.com" ]; then
        _default_domain="security.${SITE_DOMAIN}"
    fi
    local SD_DOMAIN=""
    prompt_text "  Domain for the dashboard (e.g. security.yourdomain.com), you'll need to point DNS at this droplet yourself [${_default_domain:-required}]:" "$_default_domain" SD_DOMAIN

    if [ -z "$SD_DOMAIN" ]; then
        log_warning "No domain entered — dashboard stays on http://localhost:$DASHBOARD_PORT only (not reachable from outside this box)."
        return 0
    fi

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

    # ── Independent Basic Auth layer (defense-in-depth on top of Authelia) ──
    # Authelia already gates this page, but it's still one piece of software
    # this dashboard trusts completely — this repo already hit one real
    # Authelia forward_auth header bypass (see services/authelia.sh's
    # header_up X-Forwarded-Host fix). This dashboard can delete active
    # security bans, so it's worth a second, genuinely independent gate that
    # doesn't depend on Authelia (or its session store, or its config) at
    # all. basicauth is written before EXTRA_BLOCK below, so a request must
    # clear it before ever reaching Authelia's forward_auth call.
    local BASICAUTH_BLOCK=""
    local _use_basicauth=""
    prompt_yn "  Add an independent Basic Auth login in front of Authelia, as a second, separate layer? (y/n):" "y" _use_basicauth
    if [[ "$_use_basicauth" =~ ^[Yy]$ ]]; then
        local BA_USER="" BA_PASS="" BA_HASH=""
        prompt_text "  Basic Auth username [admin]:" "admin" BA_USER
        BA_PASS="$(generate_password 20)"
        log_info "Generating Basic Auth password hash (via the running Caddy container)..."
        BA_HASH="$(docker exec caddy caddy hash-password --plaintext "$BA_PASS" 2>/dev/null)"
        if [ -z "$BA_HASH" ]; then
            log_warning "Could not generate the Basic Auth hash — skipping this layer. Authelia alone will protect the dashboard."
        else
            BASICAUTH_BLOCK="    basicauth {
        ${BA_USER} ${BA_HASH}
    }
"
            log_success "Basic Auth username: ${BA_USER}"
            log_success "Basic Auth password: ${BA_PASS}"
            log_warning "Save that password now — only the bcrypt hash is written to the Caddyfile, it is not stored anywhere in plaintext."
        fi
    fi

    if [ -z "$EXTRA_BLOCK" ] && [ -z "$BASICAUTH_BLOCK" ]; then
        log_error "Proceeding WITHOUT any auth protection — anyone who finds this domain"
        log_error "can view and delete active security bans. Strongly reconsider."
        local _confirm_unsafe=""
        prompt_yn "  Really continue without auth protection? (y/n):" "n" _confirm_unsafe
        if [[ ! "$_confirm_unsafe" =~ ^[Yy]$ ]]; then
            log_info "Skipping Caddy setup. Re-run this installer once Authelia is available."
            return 0
        fi
    fi

    local CADDY_FILE="$DOCKER_DIR/caddy/Caddyfile"
    if [ -f "$CADDY_FILE" ] && ! grep -q "^${SD_DOMAIN} {" "$CADDY_FILE"; then
        cat >> "$CADDY_FILE" << CADDYBLOCK

# Security Dashboard
${SD_DOMAIN} {
${BASICAUTH_BLOCK}${EXTRA_BLOCK}
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

    # This port never needs to be open to the internet — only Caddy (local,
    # via host.docker.internal) ever needs to reach it.
    if command -v ufw &>/dev/null; then
        ufw delete allow "${DASHBOARD_PORT}/tcp" 2>/dev/null || true
        if declare -f ufw_allow_from_caddy_net >/dev/null 2>&1; then
            ufw_allow_from_caddy_net "${DASHBOARD_PORT}"
        fi
    fi
}

# Removes the dashboard's existing Caddyfile site block (found via its
# unique reverse_proxy line, walking backward to the nearest "<domain> {"
# open and forward to the matching unindented "}" close) so
# _secdash_configure_caddy can regenerate it fresh on "update" mode's
# reconfigure path, rather than trying to surgically patch a live Caddyfile
# in place — a whole-block delete-and-regenerate is much harder to get
# subtly wrong than in-place editing of a file this security-critical.
_secdash_remove_caddy_block() {
    local port="$1"
    local caddy_file="$DOCKER_DIR/caddy/Caddyfile"
    [ -f "$caddy_file" ] || return 0

    local marker="    reverse_proxy host.docker.internal:${port}"
    local marker_line domain_line end_line
    marker_line="$(grep -nF "$marker" "$caddy_file" | head -1 | cut -d: -f1)"
    if [ -z "$marker_line" ]; then
        return 0  # nothing deployed yet — fine, the fresh flow will just append
    fi

    domain_line="$(head -n "$marker_line" "$caddy_file" | grep -nE '^[^[:space:]#].* \{$' | tail -1 | cut -d: -f1)"
    if [ -z "$domain_line" ]; then
        log_warning "Could not find the start of the existing dashboard Caddy block — leaving it as-is."
        return 1
    fi
    # Pull in the "# Security Dashboard" comment line right above it too, if present
    if [ "$domain_line" -gt 1 ] && sed -n "$((domain_line - 1))p" "$caddy_file" | grep -qx '# Security Dashboard'; then
        domain_line=$((domain_line - 1))
    fi

    end_line="$(tail -n "+$marker_line" "$caddy_file" | grep -nx '}' | head -1 | cut -d: -f1)"
    if [ -z "$end_line" ]; then
        log_warning "Could not find the end of the existing dashboard Caddy block — leaving it as-is."
        return 1
    fi
    end_line=$((marker_line + end_line - 1))

    sed -i "${domain_line},${end_line}d" "$caddy_file"
    log_info "Removed the existing dashboard Caddy block (regenerating it fresh)."
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
import configparser
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASHBOARD_PORT", "8092"))
ASTERISK_LOG = os.environ.get("ASTERISK_LOG", "")
ASTERISK_ADMIN_URL = os.environ.get("ASTERISK_ADMIN_URL", "")
ASTERISK_CONFIG_DIR = os.environ.get("ASTERISK_CONFIG_DIR", "")
ASN_SCENARIO_FILES = [
    "/etc/crowdsec/scenarios/local-asterisk_bf.yaml",
    "/etc/crowdsec/scenarios/local-asterisk_user_enum.yaml",
]

TS_RE = re.compile(r"^\[([^\]]+)\]")
KV_RE = re.compile(r'(\w+)="([^"]*)"')
ASN_FILTER_RE = re.compile(r"ASNNumber in \[([^\]]*)\]\)")
ID_RE = re.compile(r"^\d+$")
ASN_RE = re.compile(r"^\d+$")
IP_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
DEVICE_MARKER_RE = re.compile(r"^; === Device: (.+?)(?:\s*\[AA:(?:yes|no)\])?\s*\((.+?)\)\s*===\s*$")
EXT_HEADER_RE = re.compile(r"^\[(\d+)\]")
EXTEN_RE = re.compile(r"^\d+$")
TIER_RE = re.compile(r"^(internal|restricted|full)$")
NUMBER_RE = re.compile(r"^\d{11}$")


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
        # AS number/name and country live on the parent alert's "source"
        # object, not on the individual decision — confirmed against real
        # output (source.as_number, source.as_name, source.cn) rather than
        # guessed, after getting evt.Enriched.ASNNumber's type wrong earlier
        # tonight for the same underlying data.
        source = alert.get("source") or {}
        for d in alert.get("decisions") or []:
            decisions.append({
                "id": d.get("id"),
                "value": d.get("value"),
                "scenario": d.get("scenario"),
                "duration": d.get("duration"),
                "origin": d.get("origin"),
                "as_number": source.get("as_number", ""),
                "as_name": source.get("as_name", ""),
                "country": source.get("cn", ""),
            })
    return decisions


def delete_decision(decision_id):
    if not ID_RE.match(str(decision_id)):
        return False, "Invalid decision ID"
    ok, out, err = run_sudo(["/usr/bin/cscli", "decisions", "delete", "--id", str(decision_id)])
    return ok, (err or out or ("deleted" if ok else "failed"))


def get_alert_history_names():
    """ASN -> as_name map built from historical alerts (cscli alerts list,
    unlike decisions list, includes expired/resolved ones). A successfully
    exempted ASN (e.g. T-Mobile once its bans stop firing) has no *active*
    decision left to source a name from — this is the fallback that still
    finds one, from the alert that was raised before the exemption took
    effect."""
    ok, out, err = run_sudo(["/usr/bin/cscli", "alerts", "list", "-o", "json"])
    if not ok or not out.strip():
        return {}
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return {}
    names = {}
    for alert in data or []:
        source = alert.get("source") or {}
        asn = source.get("as_number")
        name = source.get("as_name")
        if asn and name:
            names.setdefault(str(asn), name)
    return names


def get_asn_exempt(known_names=None):
    """known_names: optional {asn: as_name} lookup, built from current
    decisions, to label already-exempt ASNs that aren't actively generating
    bans right now (and so wouldn't otherwise have a name available)."""
    known_names = known_names or {}
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
    ordered = sorted(asns, key=lambda x: int(x) if x.isdigit() else 0)
    return [{"asn": a, "name": known_names.get(a, "")} for a in ordered]


def set_asn_exempt(asn_list):
    # Empty is valid and means "no ASNs exempted" — ASNNumber in [] is valid
    # expr-language and always evaluates false, so the exclusion filter
    # !(... in []) is always true and every Asterisk auth failure is
    # evaluated normally again. Needed so removing the last remaining
    # exempt ASN (the "unwhitelist" action) can actually reach zero instead
    # of being stuck refusing an empty save.
    clean = sorted(set(a.strip() for a in asn_list if ASN_RE.match(a.strip())))
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
    if not clean:
        return True, "Cleared — no ASNs exempted, all Asterisk traffic is evaluated normally again."
    return True, "Updated: %s" % ", ".join(clean)


def get_asn_source_ips(asn):
    """Every source IP CrowdSec has ever recorded for a given ASN, from alert
    history (includes expired/resolved alerts) — used so "ban" can act on
    previously-seen offenders immediately, not just future ones."""
    ok, out, err = run_sudo(["/usr/bin/cscli", "alerts", "list", "-o", "json"])
    if not ok or not out.strip():
        return []
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    ips = set()
    for alert in data or []:
        source = alert.get("source") or {}
        if str(source.get("as_number", "")) == str(asn):
            ip = source.get("ip")
            if ip and IP_RE.match(ip):
                ips.add(ip)
    return sorted(ips)


def ban_ip(ip, reason, duration="24h"):
    if not IP_RE.match(ip):
        return False, "Invalid IP"
    ok, out, err = run_sudo([
        "/usr/bin/cscli", "decisions", "add",
        "--ip", ip, "--duration", duration, "--type", "ban", "--reason", reason,
    ])
    return ok, (err or out or ("banned" if ok else "failed"))


def ban_asn(asn):
    """For an accidental whitelist: drop the ASN from the exempt list (so
    future traffic from it is evaluated normally again) and immediately ban
    every IP CrowdSec has on record for it, so the response isn't limited to
    "wait for it to misbehave again."""
    asn = str(asn).strip()
    if not ASN_RE.match(asn):
        return {"ok": False, "message": "Invalid ASN"}

    current = [d["asn"] for d in get_asn_exempt()]
    if asn in current:
        remaining = [a for a in current if a != asn]
        unexempt_ok, unexempt_message = set_asn_exempt(remaining)
    else:
        unexempt_ok, unexempt_message = True, "ASN was not currently exempt"

    banned, failed = [], []
    for ip in get_asn_source_ips(asn):
        ok, _msg = ban_ip(ip, "manual: AS%s exemption removed, known offender re-banned" % asn)
        (banned if ok else failed).append(ip)

    return {
        "ok": unexempt_ok,
        "unexempt_message": unexempt_message,
        "banned_ips": banned,
        "failed_ips": failed,
    }


def list_extensions():
    """Extension numbers + display names, parsed from pjsip.conf the same
    way Easy Asterisk's own rebuild_dialplan() finds them: a
    "; === Device: NAME (category) ===" comment immediately followed (once
    other lines are skipped) by that device's "[extnum]" section header.
    Read-only, best-effort — an unparseable/missing file just means an empty
    list, not an error, same convention as parse_security_log."""
    if not ASTERISK_CONFIG_DIR:
        return []
    path = os.path.join(ASTERISK_CONFIG_DIR, "pjsip.conf")
    if not os.path.isfile(path):
        return []
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        return []
    extensions = []
    pending_name = None
    for line in lines:
        line = line.rstrip("\n")
        m = DEVICE_MARKER_RE.match(line)
        if m:
            pending_name = m.group(1).strip()
            continue
        m = EXT_HEADER_RE.match(line)
        if m and pending_name is not None:
            extensions.append({"ext": m.group(1), "name": pending_name})
            pending_name = None
    return extensions


def _permissions_path():
    return os.path.join(ASTERISK_CONFIG_DIR, "pstn-permissions.conf") if ASTERISK_CONFIG_DIR else None


def _read_permissions_cp():
    cp = configparser.ConfigParser(delimiters=("=",))
    path = _permissions_path()
    if path and os.path.isfile(path):
        try:
            cp.read(path)
        except configparser.Error:
            pass
    return cp


def get_all_permissions():
    """{ext: {"tier": ..., "allowed_numbers": "num|num|..."}} for every
    extension with a non-internal tier on record. Extensions with no section
    are implicitly "internal" — the dialplan's AST_CONFIG() lookup treats a
    missing section as empty/denied the same way, so there's nothing to
    return for them here; the UI fills in "internal" as the default for any
    known extension (from list_extensions()) not present in this dict."""
    cp = _read_permissions_cp()
    result = {}
    for section in cp.sections():
        if not EXTEN_RE.match(section):
            continue
        result[section] = {
            "tier": cp.get(section, "tier", fallback="internal"),
            "allowed_numbers": cp.get(section, "allowed_numbers", fallback=""),
        }
    return result


def write_permission(ext, tier, numbers_raw):
    """Saves one extension's tier + (for restricted) approved-number list.
    Numbers are normalized to a pipe-separated list of 11-digit US numbers —
    pipe, not comma, because the dialplan uses this value directly as a
    REGEX() alternation pattern (see services/pstn-trunk.sh's file-level
    comment on why the untrusted call data is always the string being
    tested, never interpolated into the pattern side)."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    ext = str(ext).strip()
    if not EXTEN_RE.match(ext):
        return False, "Invalid extension"
    if not TIER_RE.match(tier):
        return False, "Invalid tier"

    tokens = re.split(r"[,\s|]+", (numbers_raw or "").strip())
    clean_numbers = [t for t in tokens if NUMBER_RE.match(t)]
    numbers = "|".join(clean_numbers)

    cp = _read_permissions_cp()
    if tier == "internal":
        if cp.has_section(ext):
            cp.remove_section(ext)
    else:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "tier", tier)
        if tier == "restricted":
            cp.set(ext, "allowed_numbers", numbers)
        elif cp.has_option(ext, "allowed_numbers"):
            cp.remove_option(ext, "allowed_numbers")

    path = _permissions_path()
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            f.write(
                "; PSTN permission tiers - internal / restricted / full.\n"
                "; Read LIVE by the dialplan on every call (AST_CONFIG()) - no\n"
                "; Asterisk restart needed. Managed here (Security Dashboard); also\n"
                "; safe to edit by hand. 'sudo ./setup.sh pstn-trunk' update mode\n"
                "; never touches this file, only a fresh reinstall does.\n"
                "; Any extension not listed here is internal-only (no PSTN) by default.\n\n"
            )
            cp.write(f)
        os.replace(tmp_path, path)
    except OSError as e:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return False, "Failed writing %s: %s" % (path, e)

    if tier == "restricted" and not clean_numbers:
        return True, "Saved as restricted with an EMPTY approved list — no PSTN number can reach/be reached by it yet."
    return True, "Saved"


LIMIT_RE = re.compile(r"^\d+$")


def get_limits():
    """Current outbound/inbound concurrent-call caps. Defaults (10/10) match
    what the dialplan itself falls back to (via AST_CONFIG()+IF()) if this
    file is missing or a key is absent, so a display here is never wrong
    even before pstn-limits.conf exists."""
    if not ASTERISK_CONFIG_DIR:
        return {"max_outbound": 10, "max_inbound": 10}
    path = os.path.join(ASTERISK_CONFIG_DIR, "pstn-limits.conf")
    cp = configparser.ConfigParser(delimiters=("=",))
    if os.path.isfile(path):
        try:
            cp.read(path)
        except configparser.Error:
            pass
    return {
        "max_outbound": cp.getint("limits", "max_outbound", fallback=10),
        "max_inbound": cp.getint("limits", "max_inbound", fallback=10),
    }


def write_limits(max_outbound, max_inbound):
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    max_outbound, max_inbound = str(max_outbound).strip(), str(max_inbound).strip()
    if not LIMIT_RE.match(max_outbound) or not LIMIT_RE.match(max_inbound):
        return False, "Both caps must be whole numbers"

    path = os.path.join(ASTERISK_CONFIG_DIR, "pstn-limits.conf")
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            f.write(
                "; PSTN concurrent-call caps, both directions.\n"
                "; Read LIVE by the dialplan on every call (AST_CONFIG()) - no Asterisk\n"
                "; restart needed. Managed here (Security Dashboard); also safe to edit\n"
                "; by hand. 'sudo ./setup.sh pstn-trunk' update mode never touches this\n"
                "; file, only a fresh reinstall does.\n\n"
                "[limits]\n"
                "max_outbound=%s\n"
                "max_inbound=%s\n" % (max_outbound, max_inbound)
            )
        os.replace(tmp_path, path)
    except OSError as e:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return False, "Failed writing %s: %s" % (path, e)
    return True, "Saved"


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
    <button class="tab-btn" data-tab="pstn">PSTN Trunk</button>
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
      <table id="dec-table"><thead><tr><th>IP/Range</th><th>Scenario</th><th>Network / Carrier</th><th>Country</th><th>Duration</th><th>Origin</th><th></th></tr></thead><tbody></tbody></table>
    </div>
    <div class="card">
      <h3 style="margin-top:0">Asterisk brute-force ASN exemptions</h3>
      <p class="muted">Carrier ASNs exempted from the Asterisk brute-force scenarios only — SSH/web/geo protection is unaffected. See CLAUDE.md / services/crowdsec.sh for background.</p>
      <div class="row">
        <input type="text" id="asn-input" placeholder="e.g. 21928, 14593">
        <button class="action" id="asn-save">Save</button>
      </div>
      <table id="asn-table" style="margin-top:0.75rem"><thead><tr><th>ASN</th><th>Carrier</th><th></th></tr></thead><tbody></tbody></table>
      <div id="msg"></div>
    </div>
  </div>
  <div id="tab-pstn" style="display:none">
    <div class="card">
      <h3 style="margin-top:0">Concurrent-call caps</h3>
      <p class="muted">A call over either cap gets a busy signal (and an ntfy alert, if enabled) — existing calls are never affected. Changes apply live, on the next call.</p>
      <div class="row">
        <label class="muted" style="white-space:nowrap">Max outbound<br><input type="text" id="limit-out" style="width:5rem"></label>
        <label class="muted" style="white-space:nowrap">Max inbound<br><input type="text" id="limit-in" style="width:5rem"></label>
        <button class="action" id="limits-save" style="align-self:flex-end">Save</button>
      </div>
      <div id="limits-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
    <div class="card">
      <h3 style="margin-top:0">PSTN permission tiers</h3>
      <p class="muted">
        <b>internal</b> — no PSTN, can still call/receive other extensions and internal ring groups.
        <b>restricted</b> — internal, plus only pre-approved US numbers.
        <b>full</b> — internal, plus any US number.
        Changes apply live, on the next call — no Asterisk restart needed.
      </p>
      <table id="pstn-table"><thead><tr><th>Ext</th><th>Name</th><th>Tier</th><th>Approved numbers (restricted only)</th><th></th></tr></thead><tbody></tbody></table>
      <div id="pstn-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
  </div>
</main>
<script>
function esc(s) { return (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

const TABS = ["security", "crowdsec", "pstn"];
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    TABS.forEach(t => { document.getElementById("tab-" + t).style.display = btn.dataset.tab === t ? "" : "none"; });
    if (btn.dataset.tab === "pstn") { loadPstnLimits(); loadPstnPermissions(); }
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

let lastDecisions = [];

async function loadDecisions() {
  const res = await fetch("/api/decisions");
  lastDecisions = await res.json();
  const tbody = document.querySelector("#dec-table tbody");
  tbody.innerHTML = lastDecisions.map(d => `<tr>
    <td>${esc(d.value)}</td>
    <td>${esc(d.scenario)}</td>
    <td>${d.as_number ? esc(d.as_number) + (d.as_name ? " — " + esc(d.as_name) : "") : ""}</td>
    <td>${esc(d.country)}</td>
    <td>${esc(d.duration)}</td>
    <td>${esc(d.origin)}</td>
    <td>
      <button class="action" onclick="unban(${d.id})">Unban</button>
      ${d.as_number ? `<button class="action" onclick="exemptAsn('${esc(d.as_number)}')">Exempt ASN</button>` : ""}
    </td>
  </tr>`).join("") || "<tr><td colspan=7 class=muted>No active bans.</td></tr>";
}

async function unban(id) {
  if (!confirm("Unban decision #" + id + "?")) return;
  const res = await fetch("/api/decisions/delete", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({id: id})});
  const data = await res.json();
  alert(data.message || (data.ok ? "Unbanned" : "Failed"));
  loadDecisions();
}

async function exemptAsn(asn) {
  const current = document.getElementById("asn-input").value.split(",").map(s => s.trim()).filter(Boolean);
  if (current.includes(asn)) { alert("ASN " + asn + " is already exempt."); return; }
  if (!confirm("Add ASN " + asn + " to the Asterisk brute-force exemption list? This only affects Asterisk auth-failure detection — SSH/web/geo protection is unaffected.")) return;
  current.push(asn);
  document.getElementById("asn-input").value = current.join(", ");
  document.getElementById("asn-save").click();
}

async function loadAsnExempt() {
  const res = await fetch("/api/asn-exempt");
  const data = await res.json();
  const asns = data.asns || [];
  document.getElementById("asn-input").value = asns.map(a => a.asn).join(", ");
  const tbody = document.querySelector("#asn-table tbody");
  tbody.innerHTML = asns.map(a => `<tr>
    <td>${esc(a.asn)}</td>
    <td>${esc(a.name) || '<span class="muted">(unknown)</span>'}</td>
    <td>
      <button class="action" onclick="unexemptAsn('${esc(a.asn)}')">Unwhitelist</button>
      <button class="action" onclick="banAsn('${esc(a.asn)}')">Unwhitelist + Ban</button>
    </td>
  </tr>`).join("") || "<tr><td colspan=3 class=muted>No ASNs currently exempted.</td></tr>";
}

document.getElementById("asn-save").addEventListener("click", async () => {
  const raw = document.getElementById("asn-input").value;
  const asns = raw.split(",").map(s => s.trim()).filter(Boolean);
  const res = await fetch("/api/asn-exempt", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({asns: asns})});
  const data = await res.json();
  document.getElementById("msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
  loadAsnExempt();
});

async function unexemptAsn(asn) {
  if (!confirm("Remove ASN " + asn + " from the exemption list? Future Asterisk auth failures from it will be evaluated normally again (no immediate ban of past offenders).")) return;
  const current = (document.getElementById("asn-input").value || "").split(",").map(s => s.trim()).filter(s => s && s !== asn);
  const res = await fetch("/api/asn-exempt", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({asns: current})});
  const data = await res.json();
  document.getElementById("msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
  loadAsnExempt();
}

async function banAsn(asn) {
  if (!confirm("Remove ASN " + asn + " from the exemption list AND immediately ban (24h) every IP CrowdSec has ever recorded for it? Use this for an accidental whitelist.")) return;
  const res = await fetch("/api/asn-exempt/ban", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({asn: asn})});
  const data = await res.json();
  const parts = [data.unexempt_message || (data.ok ? "Unwhitelisted" : "Unwhitelist failed")];
  if (data.banned_ips && data.banned_ips.length) parts.push("Banned: " + data.banned_ips.join(", "));
  if (data.failed_ips && data.failed_ips.length) parts.push("Failed to ban: " + data.failed_ips.join(", "));
  if (!data.banned_ips || !data.banned_ips.length) parts.push("No previously-recorded IPs found for this ASN to ban.");
  document.getElementById("msg").textContent = parts.join(" — ");
  loadAsnExempt();
  loadDecisions();
}

async function loadPstnLimits() {
  const res = await fetch("/api/pstn-limits");
  const data = await res.json();
  document.getElementById("limit-out").value = data.max_outbound;
  document.getElementById("limit-in").value = data.max_inbound;
}

document.getElementById("limits-save").addEventListener("click", async () => {
  const maxOut = document.getElementById("limit-out").value;
  const maxIn = document.getElementById("limit-in").value;
  const res = await fetch("/api/pstn-limits", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({max_outbound: maxOut, max_inbound: maxIn}),
  });
  const data = await res.json();
  document.getElementById("limits-msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
  loadPstnLimits();
});

async function loadPstnPermissions() {
  const res = await fetch("/api/pstn-permissions");
  const data = await res.json();
  const exts = data.extensions || [];
  const tbody = document.querySelector("#pstn-table tbody");
  if (!exts.length) {
    tbody.innerHTML = '<tr><td colspan=5 class=muted>No extensions found (no Asterisk install detected, or pjsip.conf has no devices yet).</td></tr>';
    return;
  }
  tbody.innerHTML = exts.map(e => `<tr data-ext="${esc(e.ext)}">
    <td>${esc(e.ext)}</td>
    <td>${esc(e.name)}</td>
    <td>
      <select class="pstn-tier">
        <option value="internal" ${e.tier === "internal" ? "selected" : ""}>internal</option>
        <option value="restricted" ${e.tier === "restricted" ? "selected" : ""}>restricted</option>
        <option value="full" ${e.tier === "full" ? "selected" : ""}>full</option>
      </select>
    </td>
    <td><input type="text" class="pstn-numbers" value="${esc(e.allowed_numbers)}" placeholder="15551234567,15559876543" ${e.tier === "restricted" ? "" : "disabled"}></td>
    <td><button class="action" onclick="savePstnPermission('${esc(e.ext)}')">Save</button></td>
  </tr>`).join("");

  tbody.querySelectorAll("tr").forEach(row => {
    const tierSel = row.querySelector(".pstn-tier");
    const numsInput = row.querySelector(".pstn-numbers");
    tierSel.addEventListener("change", () => { numsInput.disabled = tierSel.value !== "restricted"; });
  });
}

async function savePstnPermission(ext) {
  const row = document.querySelector(`#pstn-table tr[data-ext="${ext}"]`);
  const tier = row.querySelector(".pstn-tier").value;
  const numbers = row.querySelector(".pstn-numbers").value;
  const res = await fetch("/api/pstn-permissions", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ext: ext, tier: tier, allowed_numbers: numbers}),
  });
  const data = await res.json();
  document.getElementById("pstn-msg").textContent = (data.message || (data.ok ? "Saved" : "Failed")) + " (extension " + ext + ")";
  loadPstnPermissions();
}

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
            decisions = get_decisions()
            known_names = {d["as_number"]: d["as_name"] for d in decisions if d.get("as_number")}
            for asn, name in get_alert_history_names().items():
                known_names.setdefault(asn, name)
            self._json({"asns": get_asn_exempt(known_names)})
        elif self.path == "/api/pstn-permissions":
            perms = get_all_permissions()
            extensions = []
            for e in list_extensions():
                p = perms.get(e["ext"], {"tier": "internal", "allowed_numbers": ""})
                extensions.append({"ext": e["ext"], "name": e["name"],
                                    "tier": p["tier"], "allowed_numbers": p["allowed_numbers"]})
            self._json({"extensions": extensions})
        elif self.path == "/api/pstn-limits":
            self._json(get_limits())
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
        elif self.path == "/api/asn-exempt/ban":
            self._json(ban_asn(payload.get("asn", "")))
        elif self.path == "/api/pstn-permissions":
            ok, message = write_permission(
                payload.get("ext", ""), payload.get("tier", ""), payload.get("allowed_numbers", "")
            )
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-limits":
            ok, message = write_limits(payload.get("max_outbound", ""), payload.get("max_inbound", ""))
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
