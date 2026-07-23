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
        echo "[DRY-RUN] Would write /etc/sudoers.d/security-dashboard (scoped cscli/systemctl/set-asn-exempt.sh only)"
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
                _secdash_write_asn_helper "$APP_DIR"
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
                    _secdash_configure_caddy "$DASHBOARD_PORT" "$ASTERISK_ADMIN_URL"
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
    _secdash_write_asn_helper "$APP_DIR"

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
    _secdash_configure_caddy "$DASHBOARD_PORT" "$ASTERISK_ADMIN_URL"

    write_readme "$APP_DIR" << README_MD
# Security Dashboard

Asterisk failed-connection log + CrowdSec ban management, one Authelia-
protected page. Runs natively on the host (systemd service \`security-dashboard\`),
not in Docker — it needs to call \`cscli\` and read Asterisk's log directly.

## Tabs
- **Security Log** — parses \`$ASTERISK_LOG_DIR/full\` for SIP auth failures
  (wrong password, unknown extension, etc.) with timestamp/account/remote IP,
  filterable per column (each header has its own text filter, live as you type).
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
- **PSTN Trunk** — an "Internal SIP messaging" card at the top is always
  available, whether or not a PSTN trunk has ever been installed: a
  checkbox per known extension (parsed from \`pjsip.conf\`) for
  Asterisk's native SIP texting, independent of PSTN calling entirely (no
  cost, no carrier, no DID, no dependency on \`services/pstn-trunk.sh\`
  having been run — see its "Known gap" note on messaging for what this
  flag does and doesn't do yet at the Asterisk level). Right below it, a
  **Groups** card (also always available) lets you name a set of
  extensions and bulk-enable/disable messaging for all of them at once —
  a management convenience only, not a runtime concept: applying an action
  just writes the same per-extension \`pstn-permissions.conf\` key each
  member's own checkbox would, and membership changes never retroactively
  affect anything already applied. Below that, the rest of the tab detects
  whether \`services/pstn-trunk.sh\`'s dialplan is
  actually installed (\`pstn-trunk-dialplan.conf\` present) and shows a
  clear "not installed" message instead of the calling-permissions editor
  if not, so it never shows real-looking-but-unenforced defaults. When
  installed: the outbound/inbound concurrent-call caps, and every known
  extension's permission tier (internal / restricted / full) and, for
  restricted, its approved numbers — all editable live, no Asterisk
  restart, no reinstall. Also manages personal-number assignments (DID ->
  owner extension), additive to the shared trunk DID. Writes directly to
  \`pstn-limits.conf\` / \`pstn-permissions.conf\` / \`pstn-personal-dids.conf\`,
  which the dialplan reads fresh on every call. The spend-cap kill-switch
  and international-calling allow-list are deliberately **not** managed
  here — CLI-only, via \`sudo ./setup.sh pstn-trunk\` — since both are more
  security-sensitive than what this tab already exposes.
- **Asterisk Admin** — an embedded, lazy-loaded iframe of the real Asterisk
  web admin (only fetched the first time you open the tab), plus an
  "open in a new tab" fallback link that's always there regardless. Only
  shows up once an Asterisk install is detected. If a local Caddy install is
  found for both this dashboard and the Asterisk admin's own domain, install
  automatically patches the admin's Caddy site block from
  `X-Frame-Options` to a `Content-Security-Policy: frame-ancestors` entry
  naming only this dashboard's domain, so the browser actually allows the
  frame — every other site is still refused framing exactly as before. This
  is best-effort (it depends on matching the exact header line
  `services/asterisk-digital-ocean.sh` itself writes, and hasn't been
  confirmed against Authelia's own portal-framing behavior on a live
  install) — if the tab shows a blank frame, use the fallback link and check
  this service's own log output from install time for a manual one-line fix.

## Manage
\`\`\`
sudo systemctl status security-dashboard
sudo systemctl restart security-dashboard
sudo journalctl -u security-dashboard -f
\`\`\`

## Security notes
- Runs as a dedicated, unprivileged system user (\`secdash\`), not root.
- Sudo access is scoped to exactly six commands via
  \`/etc/sudoers.d/security-dashboard\`: \`cscli decisions delete --id <digits>\`,
  \`cscli decisions list -o json\`, \`cscli alerts list -o json\` (read-only,
  used to label ASN exemptions with a carrier name from past alerts and to
  find known offending IPs for the "Ban" action), \`cscli decisions add --ip
  <ip> --duration <dur> --type ban --reason <text>\` (used only by "Ban"),
  \`systemctl restart crowdsec\`, and \`set-asn-exempt.sh\` (root:root, mode
  700, installed alongside \`app.py\` — the one thing that edits CrowdSec's
  Asterisk-scenario YAMLs, since \`secdash\` has no write access to those
  root-owned files directly and shouldn't). Nothing else.
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
$_svc_user ALL=(root) NOPASSWD: /opt/security-dashboard/set-asn-exempt.sh *
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
    local DASHBOARD_PORT="$1" ADMIN_URL="${2:-}"

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

    _secdash_allow_asterisk_admin_iframe "$ADMIN_URL" "$SD_DOMAIN"
}

# Best-effort: lets the dashboard's "Asterisk Admin" tab iframe-embed the
# real Asterisk web admin, by swapping that domain's own Caddy site block
# from X-Frame-Options to a CSP frame-ancestors entry naming ONLY this
# dashboard's domain — every other site is still refused framing exactly as
# before, this just relaxes it for the one origin that's supposed to embed
# it. Best-effort because it depends on finding the exact
# X-Frame-Options line services/asterisk-digital-ocean.sh itself generates,
# inside a live Caddyfile it doesn't own — if that block was hand-edited
# since, or doesn't exist yet (Asterisk installed after this dashboard, or
# no local Caddy at all), this silently does nothing and the tab's "open in
# a new tab" fallback link still works either way.
_secdash_allow_asterisk_admin_iframe() {
    local ADMIN_URL="$1" SD_DOMAIN="$2"
    [ -n "$ADMIN_URL" ] || return 0
    [ -n "$SD_DOMAIN" ] || return 0
    command -v docker &>/dev/null || return 0
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^caddy$" || return 0

    local ADMIN_DOMAIN="${ADMIN_URL#https://}"
    ADMIN_DOMAIN="${ADMIN_DOMAIN#http://}"
    local CADDY_FILE="$DOCKER_DIR/caddy/Caddyfile"
    [ -f "$CADDY_FILE" ] || return 0
    grep -q "^${ADMIN_DOMAIN} {" "$CADDY_FILE" || return 0

    if grep -qF "frame-ancestors 'self' https://${SD_DOMAIN};" "$CADDY_FILE"; then
        return 0   # already patched for this exact dashboard domain
    fi

    local CSP_LINE="        Content-Security-Policy \"frame-ancestors 'self' https://${SD_DOMAIN};\""
    local TMP_FILE
    TMP_FILE="$(mktemp)"
    awk -v domain="${ADMIN_DOMAIN} {" -v csp="$CSP_LINE" '
        BEGIN { in_block = 0; patched = 0 }
        index($0, domain) == 1 { in_block = 1 }
        in_block && !patched && /X-Frame-Options/ { print csp; patched = 1; next }
        { print }
        in_block && /^}/ { in_block = 0 }
    ' "$CADDY_FILE" > "$TMP_FILE"

    if grep -qF "frame-ancestors 'self' https://${SD_DOMAIN};" "$TMP_FILE"; then
        cp "$CADDY_FILE" "$CADDY_FILE.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$TMP_FILE" "$CADDY_FILE"
        docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
        if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || docker restart caddy &>/dev/null; then
            log_success "Asterisk web admin (${ADMIN_DOMAIN}) now allows embedding from https://${SD_DOMAIN} — the dashboard's Asterisk Admin tab should load it."
        else
            log_warning "Caddyfile patched, but reload/restart failed — check: docker logs caddy"
        fi
    else
        rm -f "$TMP_FILE"
        log_warning "Couldn't find an X-Frame-Options line in ${ADMIN_DOMAIN}'s Caddy block to patch —"
        log_warning "the dashboard's Asterisk Admin tab will show a blank frame. Add this line yourself"
        log_warning "inside that domain's 'header { }' block in $CADDY_FILE, replacing X-Frame-Options:"
        log_warning "  Content-Security-Policy \"frame-ancestors 'self' https://${SD_DOMAIN};\""
        log_warning "then: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
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

# Root-owned helper for editing CrowdSec's Asterisk-scenario YAMLs — the
# secdash service user (--shell /usr/sbin/nologin, no special file grants)
# cannot write /etc/crowdsec/scenarios/*.yaml directly (root:root, mode
# 644): confirmed live, a direct write from app.py failed with "[Errno 13]
# Permission denied". Rather than loosen those files' own permissions,
# route the edit through this one whitelisted root helper via sudo — same
# pattern every other CrowdSec-touching action here already uses (cscli via
# run_sudo), just for a plain file edit instead of a cscli subcommand.
# Mode 700 root:root: secdash can still invoke it (sudoers grants running
# it AS root regardless of the file's own permission bits), but nothing
# else on the box can execute it directly.
_secdash_write_asn_helper() {
    local _app_dir="$1"
    cat > "$_app_dir/set-asn-exempt.sh" << 'ASNHELPER'
#!/bin/bash
# Auto-generated by services/security-dashboard.sh — do not edit directly,
# re-run the installer instead. Invoked ONLY via sudo, by app.py's
# set_asn_exempt() (see /etc/sudoers.d/security-dashboard for the exact
# grant). Args are ASN numbers (already validated by the caller, but
# re-validated here too since this runs as root — never trust the caller
# alone for a root-executed script).
set -uo pipefail

SCENARIO_FILES=(
    /etc/crowdsec/scenarios/local-asterisk_bf.yaml
    /etc/crowdsec/scenarios/local-asterisk_user_enum.yaml
)

clean_asns=()
for a in "$@"; do
    [[ "$a" =~ ^[0-9]+$ ]] && clean_asns+=("$a")
done

expr="" sep=""
for a in "${clean_asns[@]}"; do
    expr="${expr}${sep}'${a}'"
    sep=", "
done

found=0
for f in "${SCENARIO_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        found=1
        sed -i "s/ASNNumber in \[[^]]*\])/ASNNumber in [${expr}])/" "$f" || exit 1
    fi
done

if [[ "$found" != "1" ]]; then
    echo "No CrowdSec scenario files found to update" >&2
    exit 1
fi

# Self-healing: the hub-original crowdsecurity/asterisk_bf /
# asterisk_user_enum scenarios have no ASN awareness at all, so if they're
# still enabled alongside the exempt forks above, they independently ban
# the same traffic regardless of anything just written — the exemption
# above would silently do nothing. crowdsec.sh's original install is
# supposed to disable them (--force, since they're crowdsecurity/asterisk
# collection members), but an install from before that fix shipped (or one
# where that step failed silently) would still have them active. Re-assert
# it on every save rather than trusting it was ever done correctly once —
# confirmed live: an install where this step had silently failed kept
# banning an exempted ASN under the hub-original scenario name.
cscli scenarios remove crowdsecurity/asterisk_bf crowdsecurity/asterisk_user_enum --force 2>/dev/null || true

if ! systemctl restart crowdsec; then
    echo "Wrote ASN list but failed to restart CrowdSec" >&2
    exit 2
fi

echo "OK"
ASNHELPER
    chown root:root "$_app_dir/set-asn-exempt.sh"
    chmod 700 "$_app_dir/set-asn-exempt.sh"
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
# Root-owned helper for the one write (edit + crowdsec restart) — this
# service user (--shell /usr/sbin/nologin) has no write access to
# ASN_SCENARIO_FILES (root:root, mode 644) and shouldn't; see
# _secdash_write_asn_helper in services/security-dashboard.sh for why this
# goes through sudo instead of loosening those files' permissions.
ASN_HELPER_SCRIPT = "/opt/security-dashboard/set-asn-exempt.sh"

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


SECURITY_LOG_TAIL_BYTES = 2 * 1024 * 1024  # comfortably enough for 5000 lines


def parse_security_log(limit=200):
    """Tail ASTERISK_LOG and return the most recent SecurityEvent lines,
    newest first, as dicts. Missing file / no lines -> empty list, never an
    error — this is a convenience view, not load-bearing.

    Reads only a bounded byte window from the END of the file, not the whole
    thing — this log is Asterisk's unrotated console/security output and can
    grow to multiple GB. The previous version did f.readlines() (loads the
    ENTIRE file into memory) before slicing the last 5000 lines, and this
    tab polls every 30 seconds from the browser. Confirmed live: on a 1GB-RAM
    droplet with a 1.4GB log file, that ballooned this "stdlib only,
    deliberately lightweight" process to 677MB RSS / 1.8GB peak swap, which
    left CrowdSec unable to even start (boot timeout) and contributed
    directly to the droplet becoming unresponsive. Bounding this to a fixed
    ~2MB window keeps memory use constant regardless of how large the log
    file grows.
    """
    if not ASTERISK_LOG or not os.path.isfile(ASTERISK_LOG):
        return []
    events = []
    try:
        with open(ASTERISK_LOG, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = max(0, size - SECURITY_LOG_TAIL_BYTES)
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # first line is likely truncated mid-line
    lines = lines[-5000:]
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
    # Editing ASN_SCENARIO_FILES directly from this process used to fail
    # with "[Errno 13] Permission denied" (root:root, mode 644, this
    # service user has no write grant) — every ASN whitelist attempt was
    # silently a no-op as far as CrowdSec was concerned. Routed through the
    # sudoers-whitelisted root helper instead, same pattern every other
    # CrowdSec-touching action here already uses.
    ok, out, err = run_sudo([ASN_HELPER_SCRIPT] + clean)
    if not ok:
        return False, "Failed updating ASN exemption: %s" % (err or out or "unknown error")
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


def _write_ini_cp(path, header, cp):
    """Shared temp-write-then-rename for every live-editable PSTN conf file —
    one copy of the atomic-write/error-handling logic instead of repeating
    it per file. Returns (ok, error_message_or_None)."""
    if not path:
        return False, "No Asterisk install detected on this box"
    tmp_path = path + ".tmp"
    try:
        with open(tmp_path, "w") as f:
            f.write(header)
            cp.write(f)
        os.replace(tmp_path, path)
    except OSError as e:
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return False, "Failed writing %s: %s" % (path, e)
    return True, None


PERMISSIONS_HEADER = (
    "; PSTN permission tiers - internal / restricted / full - PLUS two\n"
    "; independent per-extension axes: messaging (internal SIP MESSAGE\n"
    "; texting) and personal_did (outbound Caller-ID override; inbound\n"
    "; routing for personal DIDs lives in pstn-personal-dids.conf).\n"
    "; Read LIVE by the dialplan on every call (AST_CONFIG()) - no\n"
    "; Asterisk restart needed. Managed here (Security Dashboard); also\n"
    "; safe to edit by hand. 'sudo ./setup.sh pstn-trunk' update mode\n"
    "; never touches this file, only a fresh reinstall does.\n"
    "; Any extension not listed here is internal-only (no PSTN) by default.\n\n"
)

PERSONAL_DIDS_HEADER = (
    "; Personal DID -> owner-extension mapping. Read LIVE by the dialplan\n"
    "; (AST_CONFIG()) on every inbound call - no restart needed. Managed here\n"
    "; (Security Dashboard); also safe to edit by hand. Kept in sync with\n"
    "; pstn-permissions.conf's personal_did= field automatically by\n"
    "; write_personal_did()/remove_personal_did() below - editing this file\n"
    "; by hand also requires updating that field yourself to match.\n"
    "; 'sudo ./setup.sh pstn-trunk' update mode never touches this file, only\n"
    "; a fresh reinstall does.\n\n"
)


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
    """{ext: {"tier": ..., "allowed_numbers": "num|num|...", "messaging":
    bool}} for every extension with a non-default record. Extensions with
    no section are implicitly "internal"/messaging-disabled — the
    dialplan's AST_CONFIG() lookup treats a missing section/key as empty/
    denied the same way, so there's nothing to return for them here; the
    UI fills in the defaults for any known extension (from
    list_extensions()) not present in this dict."""
    cp = _read_permissions_cp()
    result = {}
    for section in cp.sections():
        if not EXTEN_RE.match(section):
            continue
        result[section] = {
            "tier": cp.get(section, "tier", fallback="internal"),
            "allowed_numbers": cp.get(section, "allowed_numbers", fallback=""),
            "messaging": cp.getboolean(section, "messaging", fallback=False),
        }
    return result


def write_permission(ext, tier, numbers_raw, messaging_enabled=False):
    """Saves one extension's tier + (for restricted) approved-number list +
    messaging flag in one action — messaging is an independent axis from
    the calling tier (see pstn-trunk.sh's file-level comment: an extension
    can be internal-tier for calling and still messaging-enabled, or vice
    versa), so it's set/cleared regardless of which tier branch runs below.
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
        # Only drop the tier/allowed_numbers keys, NOT the whole section —
        # an extension can independently have messaging=yes and/or a
        # personal_did assigned, and those must survive a tier change back
        # to internal. Confirmed live as a real bug: cp.remove_section(ext)
        # here used to silently discard both whenever tier was set to
        # internal.
        if cp.has_section(ext):
            if cp.has_option(ext, "tier"):
                cp.remove_option(ext, "tier")
            if cp.has_option(ext, "allowed_numbers"):
                cp.remove_option(ext, "allowed_numbers")
    else:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "tier", tier)
        if tier == "restricted":
            cp.set(ext, "allowed_numbers", numbers)
        elif cp.has_option(ext, "allowed_numbers"):
            cp.remove_option(ext, "allowed_numbers")

    if messaging_enabled:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "messaging", "yes")
    elif cp.has_section(ext) and cp.has_option(ext, "messaging"):
        cp.remove_option(ext, "messaging")

    # Drop the section entirely once nothing (tier, numbers, messaging,
    # personal_did) is left in it — only reached this way when tier is
    # internal, messaging is off, and no personal_did was ever assigned.
    if cp.has_section(ext) and not cp.options(ext):
        cp.remove_section(ext)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, cp)
    if not ok:
        return False, err

    if tier == "restricted" and not clean_numbers:
        return True, "Saved as restricted with an EMPTY approved list — no PSTN number can reach/be reached by it yet."
    return True, "Saved"


def write_messaging(ext, enabled):
    """Sets/clears just the messaging flag for one extension, leaving any
    tier/allowed_numbers/personal_did untouched. This is the write path for
    the standalone "Internal SIP messaging" card, which works whether or
    not a PSTN trunk has ever been installed — messaging has no dependency
    on one (no cost, no carrier, no DID), unlike the calling-permissions
    table this dashboard otherwise gates behind pstn_installed(). Creates
    pstn-permissions.conf from scratch if it doesn't exist yet."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    ext = str(ext).strip()
    if not EXTEN_RE.match(ext):
        return False, "Invalid extension"

    cp = _read_permissions_cp()
    if enabled:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "messaging", "yes")
    elif cp.has_section(ext) and cp.has_option(ext, "messaging"):
        cp.remove_option(ext, "messaging")

    if cp.has_section(ext) and not cp.options(ext):
        cp.remove_section(ext)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, cp)
    if not ok:
        return False, err
    return True, "Saved"


GROUP_NAME_RE = re.compile(r"^[A-Za-z0-9_ -]{1,40}$")

GROUPS_HEADER = (
    "; Named extension groups - a management convenience only, NEVER read by\n"
    "; the dialplan itself (which only ever looks at per-extension keys in\n"
    "; pstn-permissions.conf - see that file). Applying a group action (e.g.\n"
    "; \"enable messaging\") writes those same per-extension keys for every\n"
    "; CURRENT member, exactly as if each had been checked individually - it's\n"
    "; a one-time bulk write, not an ongoing binding. Editing membership here\n"
    "; does not retroactively change anything already applied to former\n"
    "; members, and adding someone to a group does not automatically apply\n"
    "; the group's settings - use the dashboard's \"Enable/Disable\" actions\n"
    "; for that, any time membership changes.\n\n"
)


def _groups_path():
    return os.path.join(ASTERISK_CONFIG_DIR, "pstn-groups.conf") if ASTERISK_CONFIG_DIR else None


def _read_groups_cp():
    cp = configparser.ConfigParser(delimiters=("=",))
    path = _groups_path()
    if path and os.path.isfile(path):
        try:
            cp.read(path)
        except configparser.Error:
            pass
    return cp


def list_groups():
    """[{"name": ..., "members": [ext, ...]}], sorted by name."""
    cp = _read_groups_cp()
    result = []
    for section in cp.sections():
        members_raw = cp.get(section, "members", fallback="")
        members = [m.strip() for m in members_raw.split(",") if m.strip()]
        result.append({"name": section, "members": members})
    result.sort(key=lambda g: g["name"].lower())
    return result


def write_group(name, members):
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    name = str(name).strip()
    if not GROUP_NAME_RE.match(name):
        return False, "Group name must be 1-40 characters (letters, digits, spaces, - or _)"
    clean_members = sorted(set(str(m).strip() for m in members if EXTEN_RE.match(str(m).strip())))

    cp = _read_groups_cp()
    if not cp.has_section(name):
        cp.add_section(name)
    cp.set(name, "members", ",".join(clean_members))

    ok, err = _write_ini_cp(_groups_path(), GROUPS_HEADER, cp)
    if not ok:
        return False, err
    return True, "Saved group '%s' with %d member(s)" % (name, len(clean_members))


def delete_group(name):
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    name = str(name).strip()
    cp = _read_groups_cp()
    if cp.has_section(name):
        cp.remove_section(name)
    ok, err = _write_ini_cp(_groups_path(), GROUPS_HEADER, cp)
    if not ok:
        return False, err
    return True, "Deleted group '%s' (members' own settings were not changed)" % name


def apply_group_messaging(name, enabled):
    """Sets messaging=<enabled> for every CURRENT member of the group, one
    at a time via write_messaging() - the exact same write path an
    individual checkbox uses. Returns a summary of how many succeeded."""
    groups = {g["name"]: g["members"] for g in list_groups()}
    if name not in groups:
        return False, "Group not found"
    members = groups[name]
    if not members:
        return True, "Group '%s' has no members - nothing to change" % name
    failed = []
    for ext in members:
        ok, _msg = write_messaging(ext, enabled)
        if not ok:
            failed.append(ext)
    if failed:
        return False, "Applied to %d/%d member(s) - failed: %s" % (
            len(members) - len(failed), len(members), ", ".join(failed))
    return True, "Messaging %s for all %d member(s) of '%s'" % (
        "enabled" if enabled else "disabled", len(members), name)


LIMIT_RE = re.compile(r"^\d+$")


def pstn_installed():
    """True only once services/pstn-trunk.sh has actually wired the dialplan
    in (pstn-trunk-dialplan.conf existing), not just because base Asterisk is
    present — pjsip.conf/extensions.conf exist either way, so extension names
    alone can't tell us this. Without this check the tab would show a real
    extension list and a default-but-unenforced 10/10 cap even when there is
    no PSTN trunk at all."""
    if not ASTERISK_CONFIG_DIR:
        return False
    return os.path.isfile(os.path.join(ASTERISK_CONFIG_DIR, "pstn-trunk-dialplan.conf"))


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


PERSONAL_DID_RE = re.compile(r"^\d{10}$")


def _personal_dids_path():
    return os.path.join(ASTERISK_CONFIG_DIR, "pstn-personal-dids.conf") if ASTERISK_CONFIG_DIR else None


def _read_personal_dids_cp():
    cp = configparser.ConfigParser(delimiters=("=",))
    path = _personal_dids_path()
    if path and os.path.isfile(path):
        try:
            cp.read(path)
        except configparser.Error:
            pass
    return cp


def list_personal_dids():
    """[{"did": ..., "owner": ...}] for every currently-assigned personal
    DID, sorted by DID."""
    cp = _read_personal_dids_cp()
    result = []
    for section in cp.sections():
        if not PERSONAL_DID_RE.match(section):
            continue
        result.append({"did": section, "owner": cp.get(section, "owner", fallback="")})
    result.sort(key=lambda d: d["did"])
    return result


def write_personal_did(did, owner):
    """Assigns did -> owner, keeping pstn-personal-dids.conf (inbound
    routing, read by the dialplan) and pstn-permissions.conf's
    personal_did= (outbound Caller-ID override) in sync. One owner has at
    most one personal_did (AST_CONFIG() returns a single value per key), so
    reassigning a DID to a new owner drops the previous owner's claim on
    it, and giving an extension a new personal DID drops whichever one it
    had before — this always leaves a clean 1:1 mapping in both files,
    rather than requiring the caller to clean up the old assignment
    itself."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    did = str(did).strip()
    owner = str(owner).strip()
    if not PERSONAL_DID_RE.match(did):
        return False, "DID must be a 10-digit US number"
    if not EXTEN_RE.match(owner):
        return False, "Invalid owner extension"

    dids_cp = _read_personal_dids_cp()
    perms_cp = _read_permissions_cp()

    for section in perms_cp.sections():
        if section != owner and perms_cp.get(section, "personal_did", fallback="") == did:
            perms_cp.remove_option(section, "personal_did")
            if not perms_cp.options(section):
                perms_cp.remove_section(section)

    for section in list(dids_cp.sections()):
        if section != did and dids_cp.get(section, "owner", fallback="") == owner:
            dids_cp.remove_section(section)

    if not dids_cp.has_section(did):
        dids_cp.add_section(did)
    dids_cp.set(did, "owner", owner)

    if not perms_cp.has_section(owner):
        perms_cp.add_section(owner)
    perms_cp.set(owner, "personal_did", did)

    ok, err = _write_ini_cp(_personal_dids_path(), PERSONAL_DIDS_HEADER, dids_cp)
    if not ok:
        return False, err
    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, perms_cp)
    if not ok:
        return False, err

    owner_tier = perms_cp.get(owner, "tier", fallback="internal")
    if owner_tier not in ("full", "restricted"):
        return True, "Assigned %s to extension %s - note: %s is internal-tier, so it won't actually receive calls on this DID until you also grant it full or restricted tier." % (did, owner, owner)
    return True, "Assigned %s to extension %s" % (did, owner)


def remove_personal_did(did):
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    did = str(did).strip()
    if not PERSONAL_DID_RE.match(did):
        return False, "Invalid DID"

    dids_cp = _read_personal_dids_cp()
    perms_cp = _read_permissions_cp()

    if dids_cp.has_section(did):
        dids_cp.remove_section(did)

    for section in perms_cp.sections():
        if perms_cp.get(section, "personal_did", fallback="") == did:
            perms_cp.remove_option(section, "personal_did")
            if not perms_cp.options(section):
                perms_cp.remove_section(section)

    ok, err = _write_ini_cp(_personal_dids_path(), PERSONAL_DIDS_HEADER, dids_cp)
    if not ok:
        return False, err
    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, perms_cp)
    if not ok:
        return False, err
    return True, "Removed %s" % did


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
  th.sortable { cursor: pointer; user-select: none; }
  th.sortable:hover { color: #e6e6e6; }
  th.sortable .arrow { opacity: 0.5; font-size: 0.75em; margin-left: 0.25em; }
  .filter-row th { padding-top: 0; padding-bottom: 0.5rem; font-weight: normal; }
  .filter-row input { width: 100%; box-sizing: border-box; background: #0f1115; border: 1px solid #2a2e38; color: #e6e6e6; border-radius: 4px; padding: 0.25rem 0.4rem; font-size: 0.8rem; }
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
    <button class="tab-btn" id="asterisk-tab-btn" data-tab="asterisk" style="display:none">Asterisk Admin</button>
  </nav>
</header>
<main>
  <div id="tab-security">
    <div class="card">
      <p class="muted">Recent Asterisk SIP security events, newest first. Errors/warnings are real auth failures; informational lines are normal registration traffic.</p>
      <table id="sec-table"><thead>
        <tr><th>Time</th><th>Event</th><th>Account</th><th>Remote</th><th>Severity</th></tr>
        <tr class="filter-row">
          <th><input type="text" class="sec-filter" data-field="timestamp" placeholder="filter…"></th>
          <th><input type="text" class="sec-filter" data-field="event" placeholder="filter…"></th>
          <th><input type="text" class="sec-filter" data-field="account" placeholder="filter…"></th>
          <th><input type="text" class="sec-filter" data-field="remote" placeholder="filter…"></th>
          <th><input type="text" class="sec-filter" data-field="severity" placeholder="filter…"></th>
        </tr>
      </thead><tbody></tbody></table>
    </div>
  </div>
  <div id="tab-crowdsec" style="display:none">
    <div class="card">
      <h3 style="margin-top:0">Active bans</h3>
      <table id="dec-table"><thead><tr>
        <th class="sortable" data-sort="value">IP/Range</th>
        <th class="sortable" data-sort="scenario">Scenario</th>
        <th class="sortable" data-sort="carrier">Network / Carrier</th>
        <th class="sortable" data-sort="country">Country</th>
        <th class="sortable" data-sort="duration">Duration</th>
        <th class="sortable" data-sort="origin">Origin</th>
        <th></th>
      </tr></thead><tbody></tbody></table>
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
      <h3 style="margin-top:0">Internal SIP messaging</h3>
      <p class="muted">
        Asterisk's native SIP texting between extensions — no carrier SMS, no PSTN, no cost, and no dependency on a PSTN trunk being installed at all. Independent of the calling permissions below. Enforced live by a dedicated dialplan context (see services/asterisk-digital-ocean.sh's README) — install/rerun that service to pick up the dialplan wiring if this box predates it.
      </p>
      <table id="msg-table"><thead><tr><th>Ext</th><th>Name</th><th>Enabled</th><th></th></tr></thead><tbody></tbody></table>
      <div id="msg-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
    <div class="card">
      <h3 style="margin-top:0">Groups</h3>
      <p class="muted">
        Named sets of extensions for bulk actions — e.g. enable messaging for everyone in "Sales" at once. A management convenience only: applying an action writes the same per-extension setting each member's own checkbox above would, one time — it isn't a runtime concept the dialplan knows about, and membership changes never retroactively affect anything already applied.
      </p>
      <div class="row">
        <input type="text" id="grp-name" placeholder="Group name, e.g. Sales" style="width:12rem">
        <button class="action" id="grp-save">Save group</button>
      </div>
      <div id="grp-members" class="row" style="flex-wrap:wrap;margin-top:0.5rem"></div>
      <table id="grp-table" style="margin-top:0.75rem"><thead><tr><th>Group</th><th>Members</th><th></th></tr></thead><tbody></tbody></table>
      <div id="grp-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
    <div class="card" id="pstn-not-installed" style="display:none">
      <h3 style="margin-top:0">PSTN trunk not installed</h3>
      <p class="muted">No PSTN trunk dialplan was found on this box — <code>sudo ./setup.sh pstn-trunk</code> hasn't been run (or its config was removed). The calling permissions/caps/personal-numbers below aren't enforced yet; install it first to use them. Internal SIP messaging above works independently of this.</p>
    </div>
    <div id="pstn-installed-cards" style="display:none">
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
      <p class="muted">
        <b>Messaging</b> — Asterisk's native internal SIP texting (no carrier SMS, no PSTN, no cost), independent of the calling tier. Enforced live by a dedicated dialplan context — see services/asterisk-digital-ocean.sh's README for how, and its caveat on the sender-extraction logic still needing real-traffic confirmation.
      </p>
      <table id="pstn-table"><thead><tr><th>Ext</th><th>Name</th><th>Tier</th><th>Approved numbers (restricted only)</th><th>Messaging</th><th></th></tr></thead><tbody></tbody></table>
      <div id="pstn-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
    <div class="card">
      <h3 style="margin-top:0">Personal numbers</h3>
      <p class="muted">
        Multiple DIDs can share this one trunk. Assigning a DID to an extension routes inbound calls to that DID straight to its owner (still gated by the owner's own tier/approved-numbers above — no ring-group fallback), and makes that extension's outbound calls show this DID as Caller-ID instead of the shared trunk DID. The shared DID/ring-group keeps working regardless.
      </p>
      <div class="row">
        <input type="text" id="pd-did" placeholder="DID, e.g. 15551234567" style="width:12rem">
        <select id="pd-owner"></select>
        <button class="action" id="pd-save">Assign</button>
      </div>
      <table id="pd-table" style="margin-top:0.75rem"><thead><tr><th>DID</th><th>Owner</th><th></th></tr></thead><tbody></tbody></table>
      <div id="pd-msg" class="muted" style="margin-top:0.5rem"></div>
    </div>
    </div>
  </div>
  <div id="tab-asterisk" style="display:none">
    <div class="card">
      <p class="muted">
        Embedded — not a copy, this is the real Asterisk web admin loaded live in a frame.
        If it logs you in separately (its own Authelia domain, or Basic Auth), that's expected —
        it's still a genuinely separate site under the hood.
        <a id="admin-link-fallback" href="#" target="_blank">Open in a new tab instead &#8599;</a>
      </p>
      <iframe id="admin-iframe" style="width:100%;height:80vh;border:1px solid #2a2e38;border-radius:8px;background:#0f1115"></iframe>
    </div>
  </div>
</main>
<script>
function esc(s) { return (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

const TABS = ["security", "crowdsec", "pstn", "asterisk"];
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    TABS.forEach(t => { document.getElementById("tab-" + t).style.display = btn.dataset.tab === t ? "" : "none"; });
    if (btn.dataset.tab === "pstn") { loadPstnStatus(); loadMessaging(); loadGroups(); }
    if (btn.dataset.tab === "asterisk") {
      // Lazy-loaded — only fetched the first time this tab is opened, not
      // on every dashboard page load (avoids an extra login prompt/request
      // to a separate site for people who never open this tab).
      const frame = document.getElementById("admin-iframe");
      if (!frame.src && adminUrl) frame.src = adminUrl;
    }
  });
});

let lastSecurityEvents = [];

function renderSecurity() {
  const filters = {};
  document.querySelectorAll(".sec-filter").forEach(inp => {
    const v = inp.value.trim().toLowerCase();
    if (v) filters[inp.dataset.field] = v;
  });
  const rows = lastSecurityEvents.filter(e =>
    Object.entries(filters).every(([field, v]) => (e[field] || "").toLowerCase().includes(v))
  );
  const tbody = document.querySelector("#sec-table tbody");
  tbody.innerHTML = rows.map(e => `<tr>
    <td>${esc(e.timestamp)}</td>
    <td>${esc(e.event)}</td>
    <td>${esc(e.account)}</td>
    <td>${esc(e.remote)}</td>
    <td class="sev-${esc(e.severity)}">${esc(e.severity)}</td>
  </tr>`).join("") || `<tr><td colspan=5 class=muted>${lastSecurityEvents.length ? "No events match the current filters." : "No events found."}</td></tr>`;
}

document.querySelectorAll(".sec-filter").forEach(inp => {
  inp.addEventListener("input", renderSecurity);
});

async function loadSecurity() {
  const res = await fetch("/api/security-events");
  lastSecurityEvents = await res.json();
  renderSecurity();
}

let lastDecisions = [];
let decSort = { key: null, dir: 1 };

// Go-style duration strings ("3h59m59.62s", "-1" for permanent) don't sort
// correctly as text, so parse to seconds for the Duration column; permanent
// bans (-1 or unparseable) sort as Infinity, i.e. last in ascending order.
function durationSeconds(s) {
  if (!s || s === "-1") return Infinity;
  const m = String(s).match(/^(-?\d+h)?(\d+m)?(\d+(?:\.\d+)?s)?$/);
  if (!m || !(m[1] || m[2] || m[3])) return Infinity;
  const h = parseFloat(m[1]) || 0, mi = parseFloat(m[2]) || 0, se = parseFloat(m[3]) || 0;
  return h * 3600 + mi * 60 + se;
}

function decSortValue(d, key) {
  switch (key) {
    case "carrier": return (d.as_name || d.as_number || "").toLowerCase();
    case "duration": return durationSeconds(d.duration);
    default: return (d[key] || "").toString().toLowerCase();
  }
}

function renderDecisions() {
  let rows = lastDecisions.slice();
  if (decSort.key) {
    rows.sort((a, b) => {
      const av = decSortValue(a, decSort.key), bv = decSortValue(b, decSort.key);
      if (av < bv) return -1 * decSort.dir;
      if (av > bv) return 1 * decSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#dec-table th.sortable .arrow").forEach(a => a.remove());
  if (decSort.key) {
    const th = document.querySelector(`#dec-table th[data-sort="${decSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${decSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  const tbody = document.querySelector("#dec-table tbody");
  tbody.innerHTML = rows.map(d => `<tr>
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

document.querySelectorAll("#dec-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    decSort.dir = (decSort.key === key) ? -decSort.dir : 1;
    decSort.key = key;
    renderDecisions();
  });
});

async function loadDecisions() {
  const res = await fetch("/api/decisions");
  lastDecisions = await res.json();
  renderDecisions();
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

async function loadPstnStatus() {
  const res = await fetch("/api/pstn-status");
  const data = await res.json();
  document.getElementById("pstn-not-installed").style.display = data.installed ? "none" : "";
  document.getElementById("pstn-installed-cards").style.display = data.installed ? "" : "none";
  if (data.installed) { loadPstnLimits(); loadPstnPermissions(); loadPersonalDids(); }
}

async function loadPstnLimits() {
  const res = await fetch("/api/pstn-limits");
  const data = await res.json();
  document.getElementById("limit-out").value = data.max_outbound;
  document.getElementById("limit-in").value = data.max_inbound;
}

// Independent of pstn_installed() — messaging has no dependency on a PSTN
// trunk existing, unlike everything else in this tab, so this loads/saves
// regardless of whether services/pstn-trunk.sh has ever been run.
async function loadMessaging() {
  const res = await fetch("/api/pstn-permissions");
  const data = await res.json();
  const exts = data.extensions || [];

  const grpMembers = document.getElementById("grp-members");
  grpMembers.innerHTML = exts.map(e => `
    <label class="muted" style="white-space:nowrap">
      <input type="checkbox" class="grp-member-cb" value="${esc(e.ext)}"> ${esc(e.ext)} — ${esc(e.name)}
    </label>
  `).join("") || '<span class="muted">No extensions found</span>';

  const tbody = document.querySelector("#msg-table tbody");
  if (!exts.length) {
    tbody.innerHTML = '<tr><td colspan=4 class=muted>No extensions found (no Asterisk install detected, or pjsip.conf has no devices yet).</td></tr>';
    return;
  }
  tbody.innerHTML = exts.map(e => `<tr data-ext="${esc(e.ext)}">
    <td>${esc(e.ext)}</td>
    <td>${esc(e.name)}</td>
    <td style="text-align:center"><input type="checkbox" class="msg-enabled" ${e.messaging ? "checked" : ""}></td>
    <td><button class="action" onclick="saveMessagingRow('${esc(e.ext)}')">Save</button></td>
  </tr>`).join("");
}

async function saveMessagingRow(ext) {
  const row = document.querySelector(`#msg-table tr[data-ext="${ext}"]`);
  const enabled = row.querySelector(".msg-enabled").checked;
  const res = await fetch("/api/pstn-messaging", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ext: ext, enabled: enabled}),
  });
  const data = await res.json();
  document.getElementById("msg-msg").textContent = (data.message || (data.ok ? "Saved" : "Failed")) + " (extension " + ext + ")";
  loadMessaging();
}

let lastGroups = [];

async function loadGroups() {
  const res = await fetch("/api/pstn-groups");
  const data = await res.json();
  lastGroups = data.groups || [];
  const tbody = document.querySelector("#grp-table tbody");
  tbody.innerHTML = lastGroups.map(g => `<tr data-group="${esc(g.name)}">
    <td>${esc(g.name)}</td>
    <td>${g.members.map(esc).join(", ") || '<span class="muted">none</span>'}</td>
    <td>
      <button class="action" onclick="editGroup('${esc(g.name)}')">Edit</button>
      <button class="action" onclick="applyGroupMessaging('${esc(g.name)}', true)">Enable messaging</button>
      <button class="action" onclick="applyGroupMessaging('${esc(g.name)}', false)">Disable messaging</button>
      <button class="action" onclick="deleteGroup('${esc(g.name)}')">Delete</button>
    </td>
  </tr>`).join("") || '<tr><td colspan=3 class=muted>No groups yet.</td></tr>';
}

function editGroup(name) {
  const g = lastGroups.find(x => x.name === name);
  if (!g) return;
  document.getElementById("grp-name").value = g.name;
  document.querySelectorAll(".grp-member-cb").forEach(cb => { cb.checked = g.members.includes(cb.value); });
}

document.getElementById("grp-save").addEventListener("click", async () => {
  const name = document.getElementById("grp-name").value.trim();
  const members = Array.from(document.querySelectorAll(".grp-member-cb:checked")).map(cb => cb.value);
  const res = await fetch("/api/pstn-groups", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({name: name, members: members}),
  });
  const data = await res.json();
  document.getElementById("grp-msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
  loadGroups();
});

async function applyGroupMessaging(name, enabled) {
  if (!confirm(`${enabled ? "Enable" : "Disable"} messaging for every current member of "${name}"?`)) return;
  const res = await fetch("/api/pstn-groups/apply-messaging", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({name: name, enabled: enabled}),
  });
  const data = await res.json();
  document.getElementById("grp-msg").textContent = data.message || (data.ok ? "Applied" : "Failed");
  loadMessaging();
}

async function deleteGroup(name) {
  if (!confirm(`Delete group "${name}"? This does not change any member's current settings.`)) return;
  const res = await fetch("/api/pstn-groups/delete", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({name: name}),
  });
  const data = await res.json();
  document.getElementById("grp-msg").textContent = data.message || (data.ok ? "Deleted" : "Failed");
  loadGroups();
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

  const ownerSel = document.getElementById("pd-owner");
  ownerSel.innerHTML = exts.map(e => `<option value="${esc(e.ext)}">${esc(e.ext)} — ${esc(e.name)}</option>`).join("")
    || '<option value="">No extensions found</option>';

  const tbody = document.querySelector("#pstn-table tbody");
  if (!exts.length) {
    tbody.innerHTML = '<tr><td colspan=6 class=muted>No extensions found (no Asterisk install detected, or pjsip.conf has no devices yet).</td></tr>';
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
    <td style="text-align:center"><input type="checkbox" class="pstn-messaging" ${e.messaging ? "checked" : ""}></td>
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
  const messaging = row.querySelector(".pstn-messaging").checked;
  const res = await fetch("/api/pstn-permissions", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({ext: ext, tier: tier, allowed_numbers: numbers, messaging: messaging}),
  });
  const data = await res.json();
  document.getElementById("pstn-msg").textContent = (data.message || (data.ok ? "Saved" : "Failed")) + " (extension " + ext + ")";
  loadPstnPermissions();
}

async function loadPersonalDids() {
  const res = await fetch("/api/pstn-personal-dids");
  const data = await res.json();
  const dids = data.dids || [];
  const tbody = document.querySelector("#pd-table tbody");
  tbody.innerHTML = dids.map(d => `<tr>
    <td>${esc(d.did)}</td>
    <td>${esc(d.owner)}${d.owner_name ? " — " + esc(d.owner_name) : ""}</td>
    <td><button class="action" onclick="removePersonalDid('${esc(d.did)}')">Remove</button></td>
  </tr>`).join("") || "<tr><td colspan=3 class=muted>No personal numbers assigned — every extension shares the main trunk DID.</td></tr>";
}

document.getElementById("pd-save").addEventListener("click", async () => {
  const did = document.getElementById("pd-did").value.trim();
  const owner = document.getElementById("pd-owner").value;
  const res = await fetch("/api/pstn-personal-dids", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did, owner: owner}),
  });
  const data = await res.json();
  document.getElementById("pd-msg").textContent = data.message || (data.ok ? "Saved" : "Failed");
  if (data.ok) document.getElementById("pd-did").value = "";
  loadPersonalDids();
});

async function removePersonalDid(did) {
  if (!confirm("Remove personal number " + did + "? Its owner falls back to the shared trunk DID for outbound Caller-ID, and this DID stops routing anywhere until reassigned.")) return;
  const res = await fetch("/api/pstn-personal-dids/delete", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did}),
  });
  const data = await res.json();
  document.getElementById("pd-msg").textContent = data.message || (data.ok ? "Removed" : "Failed");
  loadPersonalDids();
}

const adminUrl = "__ASTERISK_ADMIN_URL__";
if (adminUrl) {
  document.getElementById("asterisk-tab-btn").style.display = "";
  document.getElementById("admin-link-fallback").href = adminUrl;
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
                p = perms.get(e["ext"], {"tier": "internal", "allowed_numbers": "", "messaging": False})
                extensions.append({"ext": e["ext"], "name": e["name"], "tier": p["tier"],
                                    "allowed_numbers": p["allowed_numbers"], "messaging": p["messaging"]})
            self._json({"extensions": extensions})
        elif self.path == "/api/pstn-limits":
            self._json(get_limits())
        elif self.path == "/api/pstn-personal-dids":
            names = {e["ext"]: e["name"] for e in list_extensions()}
            dids = [dict(d, owner_name=names.get(d["owner"], "")) for d in list_personal_dids()]
            self._json({"dids": dids})
        elif self.path == "/api/pstn-status":
            self._json({"installed": pstn_installed()})
        elif self.path == "/api/pstn-groups":
            self._json({"groups": list_groups()})
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
                payload.get("ext", ""), payload.get("tier", ""), payload.get("allowed_numbers", ""),
                bool(payload.get("messaging", False))
            )
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-limits":
            ok, message = write_limits(payload.get("max_outbound", ""), payload.get("max_inbound", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-personal-dids":
            ok, message = write_personal_did(payload.get("did", ""), payload.get("owner", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-personal-dids/delete":
            ok, message = remove_personal_did(payload.get("did", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-messaging":
            ok, message = write_messaging(payload.get("ext", ""), bool(payload.get("enabled", False)))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-groups":
            ok, message = write_group(payload.get("name", ""), payload.get("members", []))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-groups/delete":
            ok, message = delete_group(payload.get("name", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/pstn-groups/apply-messaging":
            ok, message = apply_group_messaging(payload.get("name", ""), bool(payload.get("enabled", False)))
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
