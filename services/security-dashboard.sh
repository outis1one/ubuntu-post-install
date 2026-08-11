#!/bin/bash
# services/security-dashboard.sh — Security dashboard: Asterisk failed-connection
# log + PSTN call/text history + CrowdSec decisions (view/unban/ASN-exempt
# management), Authelia-protected.
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

register_service security-dashboard homelab "Security dashboard: Asterisk failed-connections + call/text history + extension/trunk management + CrowdSec bans (Authelia-protected)" 8092

install_security-dashboard() {
    local APP_DIR="/opt/security-dashboard"
    local DASHBOARD_PORT=8092
    local SVC_USER="secdash"

    # Either install layout works — prefer ~/docker/asterisk-digital-ocean
    # (a droplet from before that service was merged into `asterisk`) if both
    # happen to exist, matching services/pstn-trunk.sh's own preference order
    # for consistency.
    local ASTERISK_EA_DIR=""
    if [ -d "$DOCKER_DIR/asterisk-digital-ocean" ]; then
        ASTERISK_EA_DIR="$DOCKER_DIR/asterisk-digital-ocean"
    elif [ -d "$DOCKER_DIR/asterisk" ]; then
        ASTERISK_EA_DIR="$DOCKER_DIR/asterisk"
    fi
    local ASTERISK_LOG_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/logs}"
    local ASTERISK_CONFIG_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/config/asterisk}"
    # categories.conf/rooms.conf live in a SEPARATE directory from
    # pjsip.conf — see vendor/easy-asterisk/easy-asterisk-v0.10.0.sh's own
    # CATEGORIES_FILE/ROOMS_FILE constants (/etc/easy-asterisk/*, not
    # /etc/asterisk/*). ASTERISK_EA_CONTAINER names the actual container to
    # `docker exec` into for the Extensions tab's device writes/CLI calls
    # (ea_* functions) — "easy-asterisk", or "easy-asterisk-do" for a droplet
    # set up before the two Asterisk services merged, matching whichever
    # container_name services/asterisk.sh actually used there.
    local ASTERISK_EA_CONFIG_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/config/easy-asterisk}"
    # Voicemail messages land here (Asterisk's own default spool layout:
    # spool/voicemail/<context>/<mailbox>/INBOX/msgNNNN.{wav,txt}) — the
    # ./spool:/var/spool/asterisk bind mount in services/asterisk.sh's
    # compose file has always existed, voicemail is just the first feature
    # that reads it from the host side. Read-only grant (see
    # _secdash_grant_asterisk_access) — the Voicemail tab only ever lists
    # and streams messages, never deletes or writes them.
    local ASTERISK_SPOOL_DIR="${ASTERISK_EA_DIR:+$ASTERISK_EA_DIR/spool}"
    local ASTERISK_EA_CONTAINER=""
    if [[ "$ASTERISK_EA_DIR" == *asterisk-digital-ocean ]]; then
        ASTERISK_EA_CONTAINER="easy-asterisk-do"
    elif [ -n "$ASTERISK_EA_DIR" ]; then
        ASTERISK_EA_CONTAINER="easy-asterisk"
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ SECURITY DASHBOARD                                               │"
    echo "│ Asterisk failed-connection log + call/text history + one        │"
    echo "│ Extensions tab (devices, ring groups, PSTN tiers, personal      │"
    echo "│ DIDs) + CrowdSec bans,                                          │"
    echo "│ one page. Runs natively on the host (not Docker) so it can call │"
    echo "│ cscli and read Asterisk's files directly. Authelia-protected.   │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [ -z "$ASTERISK_EA_DIR" ]; then
        log_warning "No Asterisk install detected."
        log_warning "The Security Log, Calls & Texts, and Extensions tabs will just be empty —"
        log_warning "CrowdSec's tab still works fine."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create system user $SVC_USER"
        echo "[DRY-RUN] Would write $APP_DIR/app.py"
        echo "[DRY-RUN] Would write /etc/sudoers.d/security-dashboard (scoped cscli/systemctl/set-asn-exempt.sh only)"
        echo "[DRY-RUN] Would write a systemd unit and start it on 0.0.0.0:$DASHBOARD_PORT (firewalled via UFW, not interface binding)"
        echo "[DRY-RUN] Would grant read/write access to the detected Asterisk config dir (for the Extensions tab)"
        echo "[DRY-RUN] Would grant read-only access to the Asterisk voicemail spool dir (for the Voicemail tab)"
        echo "[DRY-RUN] Would configure Caddy + Authelia for a domain you'll be prompted for"
        echo "[DRY-RUN] Would optionally prompt for per-admin extension scoping (Calls & Texts / Voicemail)"
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
                _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_SPOOL_DIR"
                _secdash_write_app "$APP_DIR"
                _secdash_write_asn_helper "$APP_DIR"
                _secdash_copy_kiosk_installer "$APP_DIR"
                _secdash_write_sudoers "$SVC_USER" "$ASTERISK_EA_CONTAINER"
                _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_EA_CONTAINER" "$ASTERISK_SPOOL_DIR"
                # systemd caches unit files; a plain restart re-runs the OLD
                # one. Without this, any Environment= or ReadOnlyPaths line
                # added since the last FRESH install is written to disk and
                # then silently ignored — which is exactly how the Extensions
                # tab ended up reporting "no domain set" and "TURN not
                # configured" on a box whose .env had both.
                systemctl daemon-reload
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

                echo ""
                local _reconf_admins=""
                prompt_yn "Reconfigure per-admin extension scoping (Calls & Texts / Voicemail)? (y/n):" "n" _reconf_admins
                [[ "$_reconf_admins" =~ ^[Yy]$ ]] && _secdash_configure_admin_scoping "$APP_DIR" "$SVC_USER"
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

    _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_SPOOL_DIR"

    mkdir -p "$APP_DIR"
    _secdash_write_app "$APP_DIR"
    chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"
    _secdash_write_asn_helper "$APP_DIR"
    _secdash_copy_kiosk_installer "$APP_DIR"

    _secdash_write_sudoers "$SVC_USER" "$ASTERISK_EA_CONTAINER"
    _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_EA_CONTAINER" "$ASTERISK_SPOOL_DIR"

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
    _secdash_configure_admin_scoping "$APP_DIR" "$SVC_USER"

    write_readme "$APP_DIR" << README_MD
# Security Dashboard

Asterisk failed-connection log + call/text history + CrowdSec ban
management, one Authelia-protected page. Runs natively on the host
(systemd service \`security-dashboard\`),
not in Docker — it needs to call \`cscli\` and read Asterisk's log directly.

## Tabs

Five tabs: **Security Log**, **Calls & Texts**, **Extensions**, **Voicemail**,
**CrowdSec**. The first four are always there (they only need Asterisk
itself, detected once at install time); CrowdSec checks its own live install
state on every page load and hides its nav button if \`cscli\` isn't found.

Extensions used to be three separate tabs — *Asterisk Admin*, *Extensions*
and *PSTN Trunk* — which between them listed the same extensions three times:
once as devices with a category/status, once as a row of messaging
checkboxes, and once as permission tiers. They're now one tab with one
extensions table, and each capability adds columns and cards to it instead of
a nav button of its own. That means the page still scales from a bare LAN
Asterisk box up to a full droplet with a trunk, without ever showing a
control for something that isn't set up — you just don't have to remember
which tab a given extension's settings live on.

- **Security Log** — parses \`$ASTERISK_LOG_DIR/full\` for SIP auth failures
  (wrong password, unknown extension, etc.) with timestamp/account/remote IP,
  sortable per column (click a header to sort, click again to reverse).
- **Calls & Texts** — who called/texted whom, not just failed logins.
  - **PSTN Calls** reads \`logs/pstn-trunk-calls.log\`, appended to directly
    by \`pstn-trunk.sh\`'s own dialplan (not Asterisk's CDR — see that
    script's comment on \`_pstn_write_dialplan_include\` for why). Time,
    direction, from, to, duration. Empty until a PSTN trunk is installed and
    has logged at least one call.
  - **Texts** merges two sources, both metadata-only — no message body is
    ever written to either log: internal SIP \`MESSAGE\`s between extensions
    (\`logs/sip-messages.log\`, written by \`services/asterisk.sh\`'s
    \`[sip-messaging]\` context, delivered or denied), and SMS-over-SIP
    arrivals on the trunk DID (\`logs/pstn-sms.log\`, written by
    \`pstn-trunk.sh\`'s \`[pstn-sms-inbound]\` context — Anveo-specific, and
    diagnostic until its field-parsing is confirmed against a real text, see
    that context's own comment).
- **Extensions** — one row per extension, merged from \`pjsip.conf\` (which
  always works) and, when the Easy Asterisk container is reachable, its own
  device list. Columns: Ext, Name, then Category/Status/Transport if that
  container is present, then **PSTN** + **Whitelist** if a trunk dialplan is
  installed, then Messaging and Voicemail (always: neither has a PSTN
  dependency at all — no cost, no carrier, no DID). Enabling Voicemail
  generates a 4-digit PIN, shown in that column, for checking messages by
  phone (\`*97\`); \`*98<ext>\` leaves a message directly without ringing.

  Each extension has one whitelist and a mode saying which direction(s) it
  applies to: **No PSTN**, **Unrestricted**, **Restrict outbound** (may only
  dial the list, anyone can call in), **Restrict inbound** (may dial
  anywhere, only the list can call in), or **Restrict both**. The whitelist
  field greys out for the two modes that don't use one. Internal
  extension-to-extension calling and ring groups are never gated by any of
  this.

  Name and Category are edited **in place**; every cell feeds one batched
  save. Rows you've touched get a highlight and a left rail, a sticky bar
  reports how many are edited, and **Save changes** commits just those rows —
  routing each change to the endpoint it needs (rename/category through the
  container; tier + approved numbers + messaging through the permissions
  file, or the messaging-only endpoint when there's no trunk). **Discard**
  reverts to what's on disk, and closing the page with edits pending warns
  first. Delete keeps its own control per row, since it's destructive and
  must not ride along with a batch.

  Everything below the table — Ring Groups, Personal numbers — is a
  collapsed section with an item count in its header, so the tab opens on
  the extensions table rather than on several expanded cards. Long
  explanations sit behind "what this means" disclosures for the same
  reason. The table scrolls horizontally inside its own card, so the page
  never scrolls sideways on a phone.
  - **Extensions** — add/rename/delete a SIP extension, tag it as a mobile
    device (enables RTP NAT-keepalive tuning); live registered/unregistered
    status per device. The **ⓘ** button on each row opens everything a
    softphone needs — SIP server, username, password (read back from
    \`pjsip.conf\`, not regenerated, so re-pairing a handset doesn't mean
    recreating the extension), transport and port, and the TURN
    server/credentials from Asterisk's \`.env\`. From there you can also
    switch an extension between LAN (UDP 5060) and Remote/FQDN (TLS 5061),
    or reset its password without losing its room membership or PSTN
    permissions.

    New extensions are created Remote/FQDN (TLS 5061) without asking, with
    transport and auto-answer behind an **Advanced…** disclosure. That
    choice is the usual reason a phone which looks correctly configured
    never registers: an endpoint written \`transport=transport-udp\` does
    not refuse a TLS registration, it ignores it, so the phone times out
    and nothing is logged anywhere. With no \`DOMAIN_NAME\` set that TLS
    certificate can only be self-signed and the phone has to be told to
    accept it, which the disclosure says where the choice is rather than
    silently picking UDP for you. This is a native reimplementation of Easy Asterisk's
    own vendored web admin (\`vendor/easy-asterisk/easy-asterisk-v0.10.0.sh\`'s
    device/room management), not a link or an iframe to that separate
    process — one page, one login. Reads \`pjsip.conf\`/\`rooms.conf\`
    directly (same formats the vendor's own \`easy-asterisk
    --rebuild-dialplan\` CLI still generates the dialplan from); writes go
    through \`docker exec ... tee\` (root, sudo-gated) instead of a direct
    host-side file write, since Easy Asterisk's container writes these as
    its own internal user and a host-side write would just be fighting that
    ownership again on the next restart. Every write reloads PJSIP and/or
    rebuilds the dialplan automatically, the same way the vendored admin's
    own actions do.
  - **Ring Groups** — pick extensions, name them, and they ring or page
    together as one real, dialable Easy Asterisk extension (the vendor's
    own "rooms" concept, renamed here since that's clearer about what it
    does). Can also be assigned a personal DID below instead of a single
    extension — every current member whose own tier/approved-numbers
    authorize the caller rings, checked fresh on every call. A hidden
    \`pstn-groups.conf\` mirror of current membership (see
    \`sync_room_group_mirror()\` in app.py) is what actually makes that
    live-checked lookup possible without teaching \`pstn-trunk.sh\`
    anything about \`rooms.conf\`'s format — there's no separate UI for it,
    editing a Ring Group's membership here keeps it in step automatically.
  - **Personal numbers** appears only once \`services/pstn-trunk.sh\`'s
    dialplan is actually installed (\`pstn-trunk-dialplan.conf\` present),
    so the page never shows a real-looking-but-unenforced editor. Maps a
    DID to an owner extension or Ring Group, additive to the shared trunk
    DID. Writes go directly to \`pstn-permissions.conf\` /
    \`pstn-personal-dids.conf\`, which the dialplan reads fresh on every
    call. Concurrent-call caps, the spend-cap kill-switch, and the
    international-calling allow-list are deliberately **not** managed here
    — CLI-only, via \`sudo ./setup.sh pstn-trunk\` — since all three are
    more security-sensitive than what this tab already exposes.
- **Voicemail** — every message across every mailbox's spool, newest first,
  with an inline player per row (click-to-play, no download). Read-only —
  delete a message by dialing in with the PIN and using the phone menu.
- **CrowdSec** — its nav button only appears once \`cscli\` is detected on
  this host. Current bans (\`cscli decisions list\`), a delete/unban button
  per entry, carrier/ASN + country columns (sortable per column), and
  management of the ASN-exempt Asterisk brute-force scenarios (see
  \`services/crowdsec.sh\`'s "Exempt specific carrier ASNs" option) without
  SSHing in:
  - **Currently-exempt ASNs** are listed with carrier name (resolved from
    current bans, falling back to alert history for ASNs with no active ban
    right now) regardless of when they were added.
  - **Unwhitelist** removes an ASN from the exemption list — future Asterisk
    auth failures from it are evaluated normally again.
  - **Unwhitelist + Ban** does that *and* immediately bans (24h) every IP
    CrowdSec has ever recorded for that ASN, for accidental-whitelist cases
    where you don't want to wait for it to misbehave again.

## Per-admin extension scoping (optional)

For a dashboard shared by more than one admin: **Calls & Texts** and
**Voicemail** can be restricted so each admin only sees their own
extensions' history and messages — everyone still sees the full **Security
Log**, **CrowdSec**, and **Extensions** tabs regardless. Configured via
\`sudo ./setup.sh security-dashboard\` (offered at install, and on every
"reconfigure" of an existing one) — writes \`dashboard-admins.conf\` in this
directory, matching admin usernames to their Authelia login exactly (read
off the \`Remote-User\` header Caddy already injects once Authelia protects
this domain).

**Fail-closed**: with no \`dashboard-admins.conf\` at all, both tabs are
unrestricted for everyone (the default). The moment ONE admin is added,
every other identity — an admin not yet listed, a typo'd username, or a
request with no Authelia identity at all — sees nothing on those two tabs
until they're added too. Edits take effect immediately, no restart needed.

## Manage
\`\`\`
sudo systemctl status security-dashboard
sudo systemctl restart security-dashboard
sudo journalctl -u security-dashboard -f
\`\`\`

## Security notes
- Runs as a dedicated, unprivileged system user (\`secdash\`), not root.
- Sudo access is scoped to exact commands via
  \`/etc/sudoers.d/security-dashboard\` — nothing else. CrowdSec:
  \`cscli decisions delete --id <digits>\`,
  \`cscli decisions list -o json\`, \`cscli alerts list -o json\` (read-only,
  used to label ASN exemptions with a carrier name from past alerts and to
  find known offending IPs for the "Ban" action), \`cscli decisions add --ip
  <ip> --duration <dur> --type ban --reason <text>\` (used only by "Ban"),
  \`systemctl restart crowdsec\`, and \`set-asn-exempt.sh\` (root:root, mode
  700, installed alongside \`app.py\` — the one thing that edits CrowdSec's
  Asterisk-scenario YAMLs, since \`secdash\` has no write access to those
  root-owned files directly and shouldn't). Extension/device management (only
  added if an Asterisk install is detected): \`docker exec -i <container> tee\` against
  exactly \`pjsip.conf\`/\`rooms.conf\`, plus
  \`asterisk -rx "module reload res_pjsip.so"\`,
  \`asterisk -rx "pjsip show endpoints"\`, and
  \`easy-asterisk --rebuild-dialplan\` — all scoped to the one Asterisk
  container actually installed on this box, none of it a wildcard.
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

# Grants secdash execute-only traversal (via a POSIX ACL, not chmod) on
# every ancestor directory between the filesystem root and _leaf, stopping
# early once an ancestor is already reachable. Needed because DOCKER_DIR can
# be /root/docker (any root-run droplet — a fully supported setup, not a
# mistake) and some cloud images ship /root at a bare 700: no matter what
# access the LEAF directory itself grants, secdash (a non-root system user)
# can never reach through a blocking ancestor to get there. setfacl here
# grants ONLY the ability to pass through a path already known in advance —
# it does not grant listing that directory's contents or reading anything
# else inside it.
_secdash_grant_ancestor_traversal() {
    local _svc_user="$1" _leaf="$2"
    command -v setfacl >/dev/null 2>&1 || return 0
    local _dir
    _dir="$(dirname "$_leaf")"
    while [[ "$_dir" != "/" && -n "$_dir" ]]; do
        sudo -u "$_svc_user" test -x "$_dir" 2>/dev/null && break
        setfacl -m "u:${_svc_user}:x" "$_dir" 2>/dev/null || true
        _dir="$(dirname "$_dir")"
    done
}

# Grants secdash read/write access to wherever Asterisk's config lives
# without running the dashboard as root or the actual user. Separate
# function, called from both "update" and fresh-install, so a PSTN trunk
# installed *after* this dashboard (or an asterisk-digital-ocean/asterisk
# swap) reaches an existing install on its next update instead of silently
# only applying to new ones.
#
# Uses POSIX ACLs (setfacl), not chmod + group membership. Confirmed live:
# the Asterisk container's own entrypoint runs `chown -R asterisk:asterisk
# /etc/asterisk` on every container start/restart — and the numeric UID/GID
# that resolves to inside the container can coincidentally collide with
# unrelated system accounts on the host (observed: config/asterisk ending up
# owned by messagebus:uuidd, neither of which secdash has any relationship
# to), silently reverting whatever group grant was applied at install time.
# `chown` does not touch ACL entries (only `chmod` recalculates the ACL
# mask, and nothing in this flow calls chmod after install) — so an
# ACL-based grant survives that reset instead of quietly breaking again on
# the next container restart. `-d` (default ACL) makes new files/directories
# created later (a regenerated dialplan file, a fresh personal-DID entry)
# inherit the same grant automatically. Falls back to the old chmod/group
# approach with a warning if the `acl` package isn't installed for some
# reason (should always be present — installed below).
_secdash_grant_asterisk_access() {
    local _svc_user="$1" _log_dir="$2" _config_dir="$3" _ea_config_dir="${4:-}" _spool_dir="${5:-}"

    command -v setfacl >/dev/null 2>&1 || run_cmd apt-get install -y acl >/dev/null 2>&1
    local _have_acl=false
    command -v setfacl >/dev/null 2>&1 && _have_acl=true
    [ "$_have_acl" = true ] || log_warning "Package 'acl' unavailable — falling back to group-based access, which can silently break again whenever the Asterisk container re-chowns its own config directory. Install 'acl' and re-run to fix that properly."

    local _dir
    for _dir in "$_log_dir" "$_config_dir" "$_ea_config_dir" "$_spool_dir"; do
        [ -n "$_dir" ] && [ -d "$_dir" ] || continue
        _secdash_grant_ancestor_traversal "$_svc_user" "$_dir"
        if [ "$_have_acl" = true ]; then
            setfacl -R -m "u:${_svc_user}:rX" "$_dir" 2>/dev/null || true
            setfacl -R -d -m "u:${_svc_user}:rX" "$_dir" 2>/dev/null || true
        else
            local _group
            _group="$(stat -c '%G' "$_dir" 2>/dev/null || echo "$ACTUAL_USER")"
            usermod -aG "$_group" "$_svc_user" 2>/dev/null || true
            chmod 750 "$_dir" 2>/dev/null || true
        fi
    done

    # pstn-permissions.conf/pstn-limits.conf/pstn-personal-dids.conf need
    # WRITE access on the containing directory too (configparser writes a
    # fresh temp file then renames it into place) — only on the config dir,
    # not the log dir (no reason for secdash to ever create files there).
    # _ea_config_dir (categories.conf/rooms.conf) deliberately stays
    # read-only — the Extensions tab writes those through
    # `docker exec ... tee` instead (see the ea_* functions), not a direct
    # host-side write, so there's no reason to grant it write access at all.
    if [ -n "$_config_dir" ] && [ -d "$_config_dir" ]; then
        if [ "$_have_acl" = true ]; then
            setfacl -m "u:${_svc_user}:rwx" "$_config_dir" 2>/dev/null || true
            setfacl -d -m "u:${_svc_user}:rwx" "$_config_dir" 2>/dev/null || true
        else
            chmod 770 "$_config_dir" 2>/dev/null || true
        fi
    fi

    # Asterisk's .env (chmod 600, owned by the real user) holds DOMAIN_NAME and
    # the TURN server/credentials. The Extensions tab needs them to show what
    # to type into a softphone — without this the dashboard can create an
    # extension but can't tell you how to connect it, which is exactly the gap
    # that made a new extension look broken rather than misconfigured. Read
    # only, and only this one file. It is not a meaningful escalation: the
    # dashboard already reads every extension's SIP password out of
    # pjsip.conf.
    local _ea_root="${_config_dir%/config/asterisk}"
    if [ -n "$_ea_root" ] && [ -f "$_ea_root/.env" ]; then
        _secdash_grant_ancestor_traversal "$_svc_user" "$_ea_root"
        if [ "$_have_acl" = true ]; then
            setfacl -m "u:${_svc_user}:r" "$_ea_root/.env" 2>/dev/null \
                && log_success "Granted the dashboard read access to Asterisk's .env (TURN/domain details)." \
                || log_warning "Couldn't grant read on $_ea_root/.env — the Extensions tab won't be able to show TURN details."
        fi
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
    local _app_dir="$1" _svc_user="$2" _port="$3" _log_dir="$4" _config_dir="$5" _ea_config_dir="${6:-}" _ea_container="${7:-}" _spool_dir="${8:-}"
    local _read_only_paths="" _read_write_paths="/etc/crowdsec/scenarios"
    [ -n "$_log_dir" ] && _read_only_paths="$_log_dir"
    [ -n "$_ea_config_dir" ] && _read_only_paths="$_read_only_paths $_ea_config_dir"
    [ -n "$_spool_dir" ] && _read_only_paths="$_read_only_paths $_spool_dir"
    # ProtectSystem=strict hides everything not listed, so the .env grant above
    # is only half the story — the unit has to be told it may read the file too.
    [ -n "$_config_dir" ] && _read_only_paths="$_read_only_paths ${_config_dir%/config/asterisk}/.env"
    [ -n "$_config_dir" ] && _read_write_paths="$_read_write_paths $_config_dir"

    cat > /etc/systemd/system/security-dashboard.service << SDSVC
[Unit]
Description=Security dashboard (Asterisk security log + CrowdSec decisions + PSTN trunk permissions + Asterisk admin)
After=network.target

[Service]
Type=simple
User=$_svc_user
Group=$_svc_user
Environment=DASHBOARD_PORT=$_port
Environment=ASTERISK_LOG=${_log_dir:+$_log_dir/full}
Environment=ASTERISK_LOG_DIR=$_log_dir
Environment=ASTERISK_CONFIG_DIR=$_config_dir
Environment=ASTERISK_EA_CONFIG_DIR=$_ea_config_dir
Environment=ASTERISK_EA_CONTAINER=$_ea_container
Environment=ASTERISK_EA_ENV=${_config_dir%/config/asterisk}/.env
Environment=ASTERISK_SPOOL_DIR=$_spool_dir
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
    local _svc_user="$1" _ea_container="${2:-}"
    local _ea_lines=""
    # Extensions tab device management (ea_* functions) — every write goes through
    # `docker exec -i <container> tee <exact path>` instead of a direct
    # host-side file write (see _secdash_grant_asterisk_access's comment on
    # why), plus the two Asterisk CLI calls needed after a change and the
    # live registration-status check. All seven are exact commands, no
    # wildcards, scoped to the one container actually installed on this box.
    # The last line (docker restart) backs the Extensions tab's "Commit
    # Changes" button — see restart_asterisk_container()'s comment for why
    # that exists (AST_CONFIG() live-reads not always picking up dashboard
    # edits without a full container restart).
    if [ -n "$_ea_container" ]; then
        _ea_lines="$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec -i $_ea_container tee /etc/asterisk/pjsip.conf
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec -i $_ea_container tee /etc/easy-asterisk/rooms.conf
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container chown asterisk\:asterisk /etc/asterisk/pjsip.conf
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container chown asterisk\:asterisk /etc/easy-asterisk/rooms.conf
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container asterisk -rx module\ reload\ res_pjsip.so
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container asterisk -rx pjsip\ show\ endpoints
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container asterisk -rx module\ reload\ app_voicemail.so
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker exec $_ea_container /usr/local/bin/easy-asterisk --rebuild-dialplan
$_svc_user ALL=(root) NOPASSWD: /usr/bin/docker restart $_ea_container"
    fi
    cat > /etc/sudoers.d/security-dashboard << SUDOERS
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions delete --id [0-9]*
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions list -o json
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli alerts list -o json
$_svc_user ALL=(root) NOPASSWD: /usr/bin/cscli decisions add --ip * --duration * --type ban --reason *
$_svc_user ALL=(root) NOPASSWD: /usr/bin/systemctl restart crowdsec
$_svc_user ALL=(root) NOPASSWD: /opt/security-dashboard/set-asn-exempt.sh *
${_ea_lines}
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

# Per-admin extension scoping for the Calls & Texts and Voicemail tabs only
# — Security Log, CrowdSec, and Extensions stay open to every admin who gets
# past Caddy/Authelia at all, unaffected by this. Writes
# $APP_DIR/dashboard-admins.conf, read (never written) by app.py — see
# DASHBOARD_ADMINS_FILE/allowed_extensions_for_user() in _secdash_write_app.
# No service restart needed after this: app.py re-reads the file on every
# request, the same live-config convention pstn-permissions.conf already
# uses.
#
# Full-replace, not incremental patch — same shape as
# _secdash_configure_caddy's own reconfigure flow (existing entries are
# shown first so nothing is silently lost, but the operator re-enters
# everyone they want kept). Reasonable for the two-or-three-admin case this
# exists for; not built to scale past that.
_secdash_configure_admin_scoping() {
    local APP_DIR="$1" SVC_USER="$2"
    local ADMINS_FILE="$APP_DIR/dashboard-admins.conf"

    echo ""
    if [[ -f "$ADMINS_FILE" ]]; then
        echo "  Current per-admin scoping (Calls & Texts + Voicemail):"
        awk -F'=' '
            /^\[/ { gsub(/[][]/, ""); user=$0; next }
            /^extensions/ { gsub(/^[ \t]+|[ \t]+$/, "", $2); print "    " user ": " $2 }
        ' "$ADMINS_FILE"
    fi

    local _WANT=""
    prompt_yn "  Restrict Calls & Texts and Voicemail to specific admins by extension? (y/n):" "n" _WANT
    if [[ ! "$_WANT" =~ ^[Yy]$ ]]; then
        if [[ -f "$ADMINS_FILE" ]]; then
            local _DISABLE=""
            prompt_yn "  Remove the existing scoping (everyone sees everything on those two tabs again)? (y/n):" "n" _DISABLE
            if [[ "$_DISABLE" =~ ^[Yy]$ ]]; then
                rm -f "$ADMINS_FILE"
                log_success "Scoping removed — Calls & Texts and Voicemail are unrestricted again."
            fi
        fi
        return 0
    fi

    log_warning "Fail-closed: once the first admin is added below, every OTHER identity —"
    log_warning "including an admin you forget to list, or a request with no Authelia"
    log_warning "identity at all — sees NOTHING on Calls & Texts or Voicemail. Security"
    log_warning "Log, CrowdSec, and Extensions stay open to everyone either way."

    local TMP_FILE
    TMP_FILE="$(mktemp)"
    cat > "$TMP_FILE" << 'HDR'
; Per-admin extension scoping for the Calls & Texts and Voicemail tabs.
; Managed by 'sudo ./setup.sh security-dashboard' (reconfigure on an
; existing install) - safe to edit by hand too, one [username] section per
; admin with an extensions= list, username must match that admin's Authelia
; login exactly (this dashboard reads it off the Remote-User header Caddy's
; forward_auth/import authelia already injects).
;
; Empty or missing file = scoping disabled, everyone sees everything on both
; tabs (the default). Once ANY [username] section exists here, every OTHER
; identity - including an unlisted admin, or a request with no Remote-User
; at all - sees NOTHING on those two tabs. Fail closed, not fail open.

HDR

    local _added=0
    while true; do
        echo ""
        local _USER="" _EXTS=""
        prompt_text "  Admin username (must match their Authelia login exactly, blank to finish):" "" _USER
        [[ -z "$_USER" ]] && break
        if ! [[ "$_USER" =~ ^[A-Za-z0-9_.@-]+$ ]]; then
            log_warning "  Invalid username — letters, numbers, and . _ @ - only. Skipped."
            continue
        fi
        prompt_text "  Extensions for $_USER (comma-separated, e.g. 101,102):" "" _EXTS
        _EXTS="$(echo "$_EXTS" | tr -d ' ')"
        local -a _EXT_ARR=() _VALID=()
        IFS=',' read -ra _EXT_ARR <<< "$_EXTS"
        local e
        for e in "${_EXT_ARR[@]}"; do
            [[ "$e" =~ ^[0-9]+$ ]] && _VALID+=("$e")
        done
        if [[ ${#_VALID[@]} -eq 0 ]]; then
            log_warning "  No valid extensions entered for $_USER — skipped."
            continue
        fi
        {
            echo "[$_USER]"
            echo "extensions = $(IFS=,; echo "${_VALID[*]}")"
            echo ""
        } >> "$TMP_FILE"
        _added=$((_added + 1))
        log_success "  Added $_USER -> $(IFS=,; echo "${_VALID[*]}")"
    done

    if [[ $_added -eq 0 ]]; then
        rm -f "$TMP_FILE"
        log_info "No admins added — leaving scoping as it was."
        return 0
    fi

    mv "$TMP_FILE" "$ADMINS_FILE"
    chown "$SVC_USER:$SVC_USER" "$ADMINS_FILE"
    chmod 640 "$ADMINS_FILE"
    log_success "Wrote $ADMINS_FILE with $_added admin(s) — takes effect immediately, no restart needed."
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

# Copies the vendored Easy Asterisk installer alongside the app so the
# dashboard's "Download kiosk client installer" link (Ring Groups card ->
# "How this works") has a real file to serve -- see docs/kiosk-paging-setup.md
# for what it's for. Copied at install time, not read live from vendor/ at
# request time, since a standalone run of this one file (`sudo bash
# security-dashboard.sh`, no full repo clone -- this file supports that mode,
# see the _RUN_STANDALONE stub above) has no vendor/ directory to read from at
# all. Missing source is a soft failure: the rest of the dashboard installs
# fine either way, only that one download link won't work.
_secdash_copy_kiosk_installer() {
    local _app_dir="$1"
    local _self_dir
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _vendor_script="$_self_dir/../vendor/easy-asterisk/easy-asterisk-v0.10.0.sh"
    if [[ -f "$_vendor_script" ]]; then
        cp "$_vendor_script" "$_app_dir/kiosk-client-installer.sh"
        chmod 644 "$_app_dir/kiosk-client-installer.sh"
    else
        log_warning "vendor/easy-asterisk/easy-asterisk-v0.10.0.sh not found (standalone run without"
        log_warning "the full repo?) -- the dashboard's kiosk installer download link will 404 until"
        log_warning "this exists. Re-run from a full 'ubuntu-post-install' checkout to fix."
    fi
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
import random
import re
import subprocess
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASHBOARD_PORT", "8092"))
ASTERISK_LOG = os.environ.get("ASTERISK_LOG", "")
ASTERISK_LOG_DIR = os.environ.get("ASTERISK_LOG_DIR", "")
# Written directly by the dialplan (pstn-trunk.sh / asterisk.sh's System()
# calls), not read from Asterisk's own CDR — see those files' comments on
# pstn-trunk-calls.log for why. All three share ASTERISK_LOG_DIR since
# they live alongside logs/full in the same ./logs volume mount.
PSTN_CALLS_LOG = os.path.join(ASTERISK_LOG_DIR, "pstn-trunk-calls.log") if ASTERISK_LOG_DIR else ""
SIP_MESSAGES_LOG = os.path.join(ASTERISK_LOG_DIR, "sip-messages.log") if ASTERISK_LOG_DIR else ""
SMS_LOG = os.path.join(ASTERISK_LOG_DIR, "pstn-sms.log") if ASTERISK_LOG_DIR else ""
ASTERISK_CONFIG_DIR = os.environ.get("ASTERISK_CONFIG_DIR", "")
# Voicemail spool root — see the comment above ASTERISK_SPOOL_DIR's
# declaration in install_security-dashboard() for the on-disk layout.
# Read-only (ReadOnlyPaths in the systemd unit + a read-only ACL grant), the
# Voicemail tab only ever lists/streams, never writes or deletes.
ASTERISK_SPOOL_DIR = os.environ.get("ASTERISK_SPOOL_DIR", "")
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

# Copied in by _secdash_copy_kiosk_installer at install time (see that
# function's own comment for why this reads a local copy, not vendor/ live).
# May not exist on a standalone run without the full repo -- the download
# route below 404s cleanly in that case rather than erroring.
KIOSK_INSTALLER_SCRIPT = "/opt/security-dashboard/kiosk-client-installer.sh"

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
NUMBER_RE_10 = re.compile(r"^\d{10}$")


def _normalize_nanp_number(token):
    """Accepts a bare 10-digit NANP number (the natural way to type a US
    number), an already-11-digit one (leading "1" country code), or either
    of those with a leading "+" (the natural way to paste a number straight
    out of a phone's call log) and returns the canonical 11-digit,
    digits-only form allowed_numbers is always stored in - REGEX()
    comparisons against CALLERID(num) require an exact digit-count match,
    and this used to silently DROP a plain 10-digit entry instead of
    normalizing it, the admin-input-side twin of the bug that was also
    failing inbound calls whose Caller-ID itself arrived without a leading
    "1", or arrived "+E.164" style with a leading "+" Asterisk never
    stripped (see PSTN_CALLERID_NORM / PSTN_CID_RAW in pstn-trunk.sh)."""
    token = token.lstrip("+")
    if NUMBER_RE_10.match(token):
        return "1" + token
    if NUMBER_RE.match(token):
        return token
    return None


LOG_TAIL_BYTES = 2 * 1024 * 1024  # comfortably enough for 5000 lines


def _tail_lines(path, max_lines=5000):
    """Reads only a bounded byte window from the END of a file, not the whole
    thing, and returns its lines oldest-first within that window. Shared by
    every log-backed tab (Security Log, PSTN Calls, Texts) — Asterisk's own
    logs/full is unrotated console output that can grow to multiple GB, and
    these tabs poll every 30 seconds from the browser. Confirmed live: on a
    1GB-RAM droplet with a 1.4GB log file, an earlier version that did
    f.readlines() (loads the ENTIRE file into memory) ballooned this "stdlib
    only, deliberately lightweight" process to 677MB RSS / 1.8GB peak swap,
    which left CrowdSec unable to even start (boot timeout) and contributed
    directly to the droplet becoming unresponsive. Bounding this to a fixed
    ~2MB window keeps memory use constant regardless of how large the log
    file grows. Missing file -> empty list, never an error — every caller is
    a convenience view, not load-bearing.
    """
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            start = max(0, size - LOG_TAIL_BYTES)
            f.seek(start)
            data = f.read()
    except OSError:
        return []
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start > 0 and lines:
        lines = lines[1:]  # first line is likely truncated mid-line
    return lines[-max_lines:]


def parse_security_log(limit=200):
    """Return the most recent SecurityEvent lines from ASTERISK_LOG, newest
    first, as dicts."""
    events = []
    for line in _tail_lines(ASTERISK_LOG):
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


def _fmt_epoch(raw):
    try:
        return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(int(raw)))
    except (ValueError, OSError):
        return raw


def parse_pstn_calls(limit=200):
    """Reads pstn-trunk-calls.log (epoch|direction|who|what|seconds),
    written directly by pstn-trunk.sh's dialplan — see that file's comment
    on _pstn_write_dialplan_include for the format and why it isn't
    Asterisk's own CDR. 'who'/'what' are direction-dependent: an outbound
    row's who/what are the calling extension / dialed PSTN number, an
    inbound row's are the caller's number / the DID (or "ring-group") that
    was called — normalized to plain from/to here so the UI doesn't need to
    know the difference."""
    events = []
    for line in _tail_lines(PSTN_CALLS_LOG):
        parts = line.split("|")
        if len(parts) != 5:
            continue
        epoch, direction, who, what, seconds = parts
        events.append({
            "epoch": epoch,
            "timestamp": _fmt_epoch(epoch),
            "direction": direction,
            "from": who,
            "to": what,
            "duration": seconds,
        })
    events.reverse()
    return events[:limit]


def parse_texts(limit=200):
    """Merges internal SIP-messaging deliveries/denials (sip-messages.log,
    written by services/asterisk.sh's [sip-messaging] context) with
    SMS-over-SIP arrivals (pstn-sms.log, written by pstn-trunk.sh's
    [pstn-sms-inbound] context) into one newest-first list. Neither log ever
    contains message bodies — metadata only (who/when), by design."""
    events = []
    for line in _tail_lines(SIP_MESSAGES_LOG):
        parts = line.split("|")
        if len(parts) != 4:
            continue
        epoch, status, from_ext, to_ext = parts
        events.append({
            "epoch": epoch,
            "timestamp": _fmt_epoch(epoch),
            "type": "internal",
            "direction": "internal",
            "from": from_ext,
            "to": to_ext,
            "status": "delivered" if status == "deliver" else "denied",
        })
    for line in _tail_lines(SMS_LOG):
        parts = line.split("|")
        if len(parts) != 4:
            continue
        epoch, direction, from_num, to_num = parts
        events.append({
            "epoch": epoch,
            "timestamp": _fmt_epoch(epoch),
            "type": "sms",
            "direction": direction,
            "from": from_num,
            "to": to_num,
            "status": "received" if direction == "in" else "sent",
        })
    def _epoch_key(e):
        try:
            return int(e["epoch"])
        except ValueError:
            return 0
    events.sort(key=_epoch_key, reverse=True)
    return events[:limit]


def run_sudo(args, timeout=15, input_text=None):
    """Runs a whitelisted sudo command. Always list-form args, never
    shell=True — no shell metacharacter interpretation is possible regardless
    of what's in the arguments, on top of the sudoers-side restriction.
    input_text feeds stdin (e.g. for `docker exec -i ... tee <file>` writes —
    see the ea_* Easy Asterisk admin functions) instead of a command-line
    argument, so file content never has to survive sudoers pattern matching."""
    try:
        result = subprocess.run(
            ["sudo"] + args, capture_output=True, text=True, timeout=timeout,
            input=input_text
        )
        return result.returncode == 0, result.stdout, result.stderr
    except (subprocess.TimeoutExpired, OSError) as e:
        return False, "", str(e)


def crowdsec_installed():
    """True if cscli is actually present on this host — mirrors
    pstn_installed()'s approach of checking for the real thing rather than a
    stored flag, so the CrowdSec tab tracks live state without needing this
    dashboard reinstalled after CrowdSec is added or removed."""
    return os.path.isfile("/usr/bin/cscli")


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
    "; PSTN permissions. Each extension has ONE whitelist (allowed_numbers)\n"
    "; and a 'restrict' mode saying which direction(s) it applies to:\n"
    ";   full / restricted (both ways) / internal - the original tiers - plus\n"
    ";   restricted-in (whitelist gates incoming only) and restricted-out\n"
    ";   (whitelist gates outgoing only).\n"
    "; restrict + allowed_numbers are the authored pair; tier_out/allowed_out\n"
    "; and tier_in/allowed_in are DERIVED from them and are what the dialplan\n"
    "; reads; 'tier' is a rollback mirror for a pre-split pstn-trunk.sh.\n"
    "; PLUS three\n"
    "; independent per-extension axes: messaging (internal SIP MESSAGE\n"
    "; texting), personal_did (outbound Caller-ID override; inbound\n"
    "; routing for personal DIDs lives in pstn-personal-dids.conf), and\n"
    "; voicemail (mailbox enabled; voicemail_pin is generated once and kept\n"
    "; even if voicemail is later disabled, so re-enabling doesn't change it\n"
    "; on the user - see write_voicemail()/regenerate_voicemail_conf()).\n"
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


RESTRICT_RE = re.compile(r"^(internal|restricted|full|restricted-in|restricted-out)$")


def _derive_restrict(tier_out, tier_in):
    """Infer the authored mode from the derived per-direction tiers.

    Only needed for a config written before 'restrict' existed. Fails toward
    the more restrictive reading: anything that isn't clearly open in a
    direction is treated as restricted or none, never widened."""
    if tier_out == "full" and tier_in == "full":
        return "full"
    if tier_out == "restricted" and tier_in == "restricted":
        return "restricted"
    if tier_out == "restricted":
        return "restricted-out"
    if tier_in == "restricted":
        return "restricted-in"
    return "internal"


def get_all_permissions():
    """{ext: {"restrict", "allowed_numbers", "messaging"}} for every extension
    with a non-default record.

    Each extension has ONE whitelist and a mode saying which direction(s) it
    applies to: the original internal / restricted / full, plus restricted-in
    (whitelist gates incoming, dials anywhere) and restricted-out (whitelist
    gates outgoing, anyone may call in). That authored pair is
    what this returns and what the UI edits; the dialplan reads the derived
    tier_out/allowed_out/tier_in/allowed_in that write_permission keeps in
    step with it.

    Older configs are read by deriving the mode from whatever they do have —
    the per-direction tiers, or the pre-split single 'tier' — so the UI is
    correct even on a box where services/pstn-trunk.sh hasn't been re-run.

    Extensions with no section are implicitly no-PSTN/messaging-disabled: the
    dialplan's AST_CONFIG() lookup treats a missing section as denied the same
    way, so there's nothing to return for them; the UI fills in defaults for
    any known extension not present here."""
    cp = _read_permissions_cp()
    result = {}
    for section in cp.sections():
        if not EXTEN_RE.match(section):
            continue
        legacy_tier = cp.get(section, "tier", fallback="internal")
        legacy_nums = cp.get(section, "allowed_numbers", fallback="")
        restrict = cp.get(section, "restrict", fallback="")
        if not RESTRICT_RE.match(restrict):
            restrict = _derive_restrict(
                cp.get(section, "tier_out", fallback=legacy_tier),
                cp.get(section, "tier_in", fallback=legacy_tier),
            )
        numbers = legacy_nums
        if not numbers:
            numbers = (cp.get(section, "allowed_out", fallback="")
                       or cp.get(section, "allowed_in", fallback=""))
        result[section] = {
            "restrict": restrict,
            "allowed_numbers": numbers,
            "messaging": cp.getboolean(section, "messaging", fallback=False),
            "voicemail": cp.getboolean(section, "voicemail", fallback=False),
            "voicemail_pin": cp.get(section, "voicemail_pin", fallback=""),
        }
    return result


# Which per-direction tiers each authored mode compiles down to. The dialplan
# only ever reads the compiled keys; this table is the single place the
# mapping is defined.
# The first three are the original tiers, unchanged. restricted-in and
# restricted-out are the halves: the whitelist gates one direction while the
# other stays wide open.
_RESTRICT_TIERS = {
    "internal":       ("internal", "internal"),
    "full":           ("full", "full"),
    "restricted":     ("restricted", "restricted"),
    "restricted-in":  ("full", "restricted"),
    "restricted-out": ("restricted", "full"),
}


def _set_or_clear(cp, ext, key, value):
    if value:
        cp.set(ext, key, value)
    elif cp.has_option(ext, key):
        cp.remove_option(ext, key)


def _apply_voicemail_flag(cp, ext, enabled):
    """Shared by write_permission() (the combined-save endpoint, used when a
    PSTN trunk is installed) and write_voicemail() (the standalone endpoint,
    used when it isn't) — same PIN-preservation behavior either way, see
    write_voicemail()'s docstring."""
    if enabled:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "voicemail", "yes")
        if not cp.get(ext, "voicemail_pin", fallback=""):
            cp.set(ext, "voicemail_pin", _generate_voicemail_pin())
    elif cp.has_section(ext) and cp.has_option(ext, "voicemail"):
        cp.remove_option(ext, "voicemail")


def _sync_voicemail_conf_if_present():
    """Regenerates voicemail.conf + reloads app_voicemail, but only if
    voicemail has actually been set up on this box (asterisk.sh writes the
    skeleton at install/update time) — silently a no-op otherwise, so boxes
    that never touched voicemail don't get a spurious error surfaced from
    every combined permissions save."""
    path = _voicemail_conf_path()
    if path and os.path.isfile(path):
        regenerate_voicemail_conf()
        ea_reload_voicemail()


def write_permission(ext, restrict, numbers_raw, messaging_enabled=False, voicemail_enabled=False):
    """Saves one extension's PSTN restriction mode, its single whitelist, and
    its messaging/voicemail flags in one action.

    One list, not two: the whitelist is "the numbers this extension deals
    with", and the mode says whether that constrains dialling out, being
    called, or both. Modes are internal / restricted / full (the original
    tiers) plus restricted-in and restricted-out.

    Writes three layers, all derived from those two authored values:
      restrict, allowed_numbers      what a human edits (and what this reads back)
      tier_out/allowed_out,
      tier_in/allowed_in             what the dialplan reads
      tier, allowed_numbers          rollback mirror for a pre-split installer

    Messaging and voicemail are both independent axes (see pstn-trunk.sh's
    file-level comment: an extension can have no PSTN at all and still be
    messaging/voicemail-enabled, or vice versa), so both are set/cleared
    regardless of the mode.

    Numbers normalize to a pipe-separated list of 11-digit US numbers (a bare
    10-digit entry gains a leading "1" rather than being dropped — see
    _normalize_nanp_number). Pipe, not comma, because the dialplan uses the
    value directly as a REGEX() alternation — see services/pstn-trunk.sh on
    why untrusted call data is always the string being tested, never
    interpolated into the pattern side."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    ext = str(ext).strip()
    if not EXTEN_RE.match(ext):
        return False, "Invalid extension"
    if not RESTRICT_RE.match(restrict or ""):
        return False, "Invalid restriction mode"

    tokens = re.split(r"[,\s|]+", (numbers_raw or "").strip())
    clean = [n for n in (_normalize_nanp_number(t) for t in tokens if t) if n]
    numbers = "|".join(clean)
    tier_out, tier_in = _RESTRICT_TIERS[restrict]

    cp = _read_permissions_cp()
    if restrict == "internal":
        # Clear the PSTN keys only, never the whole section — messaging and
        # personal_did are independent and must survive. (Removing the
        # section here was a real, confirmed bug in an earlier version.)
        if cp.has_section(ext):
            for key in ("restrict", "allowed_numbers", "tier_out", "allowed_out",
                        "tier_in", "allowed_in", "tier"):
                if cp.has_option(ext, key):
                    cp.remove_option(ext, key)
    else:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "restrict", restrict)
        _set_or_clear(cp, ext, "allowed_numbers", numbers if restrict != "full" else "")
        cp.set(ext, "tier_out", tier_out)
        cp.set(ext, "tier_in", tier_in)
        _set_or_clear(cp, ext, "allowed_out", numbers if tier_out == "restricted" else "")
        _set_or_clear(cp, ext, "allowed_in", numbers if tier_in == "restricted" else "")
        cp.set(ext, "tier", tier_out)

    if messaging_enabled:
        if not cp.has_section(ext):
            cp.add_section(ext)
        cp.set(ext, "messaging", "yes")
    elif cp.has_section(ext) and cp.has_option(ext, "messaging"):
        cp.remove_option(ext, "messaging")

    _apply_voicemail_flag(cp, ext, voicemail_enabled)

    # Drop the section entirely once nothing is left in it — only reachable
    # when the mode is internal, messaging and voicemail are both off, and
    # no personal_did/voicemail_pin was ever assigned.
    if cp.has_section(ext) and not cp.options(ext):
        cp.remove_section(ext)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, cp)
    if not ok:
        return False, err

    _sync_voicemail_conf_if_present()

    if restrict not in ("internal", "full") and not clean:
        return True, ("Saved, but the whitelist is EMPTY — with this mode that means no PSTN "
                      "number is permitted in the restricted direction yet.")
    return True, "Saved"


def write_messaging(ext, enabled):
    """Sets/clears just the messaging flag for one extension, leaving any
    tier/allowed_numbers/personal_did untouched. This is the write path for
    the Extensions tab's Messaging column when there's no PSTN trunk to
    save alongside — messaging works whether or not one has been installed — messaging has no dependency
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


def _voicemail_conf_path():
    return os.path.join(ASTERISK_CONFIG_DIR, "voicemail.conf") if ASTERISK_CONFIG_DIR else None


def _generate_voicemail_pin():
    return "%04d" % random.randint(0, 9999)


def regenerate_voicemail_conf():
    """Rewrites voicemail.conf's [default] mailbox list from every extension
    currently voicemail=yes in pstn-permissions.conf. [general] (and
    anything else above [default]) is preserved verbatim — this only ever
    replaces [default] onward, mirroring _asterisk_write_voicemail_conf's
    skeleton in services/asterisk.sh, which always writes [default] as the
    file's last section.

    Mailbox lines can't be a live AST_CONFIG() lookup the way the messaging/
    voicemail permission flags are — app_voicemail reads mailbox
    definitions from its own module config, not the dialplan, so this file
    has to actually list them. That's also why a module reload is needed
    after this (see write_voicemail()), unlike a plain permission-flag
    toggle."""
    path = _voicemail_conf_path()
    if not path or not os.path.isfile(path):
        return False, "No voicemail.conf found — is voicemail set up? (re-run: sudo ./setup.sh asterisk)"

    with open(path, "r") as f:
        content = f.read()

    idx = content.find("\n[default]")
    if idx == -1:
        return False, "voicemail.conf has no [default] section — was it hand-edited? Re-run: sudo ./setup.sh asterisk"
    preamble = content[:idx]

    cp = _read_permissions_cp()
    mailbox_lines = []
    for section in cp.sections():
        if not EXTEN_RE.match(section):
            continue
        if not cp.getboolean(section, "voicemail", fallback=False):
            continue
        pin = cp.get(section, "voicemail_pin", fallback="")
        if pin:
            mailbox_lines.append("%s => %s,Extension %s" % (section, pin, section))

    new_content = preamble.rstrip("\n") + "\n\n[default]\n" + "\n".join(mailbox_lines)
    new_content += "\n" if mailbox_lines else ""

    tmp = path + ".tmp"
    try:
        with open(tmp, "w") as f:
            f.write(new_content)
        os.replace(tmp, path)
    except OSError as e:
        return False, str(e)
    return True, ""


def ea_reload_voicemail():
    if not ASTERISK_EA_CONTAINER:
        return
    run_sudo(["docker", "exec", ASTERISK_EA_CONTAINER, "asterisk", "-rx", "module reload app_voicemail.so"])


def write_voicemail(ext, enabled):
    """Sets/clears the voicemail flag for one extension, then regenerates
    voicemail.conf and reloads app_voicemail so the change takes effect
    without a full Asterisk restart (unlike the messaging/PSTN permission
    flags, which the dialplan reads live via AST_CONFIG() with no reload of
    any kind needed — voicemail.conf is Asterisk's own module config, not
    something AST_CONFIG() can substitute for).

    A PIN is generated the first time voicemail is enabled and then left in
    pstn-permissions.conf even after disabling — toggling it off and back on
    later reuses the same PIN instead of silently changing it on the user.
    Independent of pstn_installed() the same way messaging is: voicemail has
    no PSTN/trunk dependency."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    ext = str(ext).strip()
    if not EXTEN_RE.match(ext):
        return False, "Invalid extension"

    cp = _read_permissions_cp()
    _apply_voicemail_flag(cp, ext, enabled)

    if cp.has_section(ext) and not cp.options(ext):
        cp.remove_section(ext)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, cp)
    if not ok:
        return False, err

    ok, err = regenerate_voicemail_conf()
    if not ok:
        return True, "Saved, but voicemail.conf couldn't be regenerated: %s" % err

    ea_reload_voicemail()
    return True, "Saved"


# "default" here is the voicemail.conf CONTEXT name (the [default] section
# _asterisk_write_voicemail_conf writes in services/asterisk.sh, matching
# the "@default" suffix voicemail-dialplan.conf's VoiceMailMain()/VoiceMail()
# calls use) — not a placeholder, Asterisk's own spool layout is
# spool/voicemail/<context>/<mailbox>/<folder>/msgNNNN.{wav,txt}.
VOICEMAIL_CONTEXT = "default"
VOICEMAIL_MSG_RE = re.compile(r"^msg\d+$")


def list_voicemail_messages():
    """Every message across every mailbox's INBOX folder, newest first.
    Reads each msgNNNN.txt sidecar app_voicemail writes alongside the .wav
    (INI-style, a [message] section with callerid/origtime/duration) — this
    dashboard never writes these files, only reads them."""
    if not ASTERISK_SPOOL_DIR:
        return []
    base = os.path.join(ASTERISK_SPOOL_DIR, "voicemail", VOICEMAIL_CONTEXT)
    if not os.path.isdir(base):
        return []
    messages = []
    try:
        mailboxes = os.listdir(base)
    except OSError:
        return []
    for mailbox in mailboxes:
        if not EXTEN_RE.match(mailbox):
            continue
        inbox = os.path.join(base, mailbox, "INBOX")
        if not os.path.isdir(inbox):
            continue
        try:
            files = os.listdir(inbox)
        except OSError:
            continue
        for fname in files:
            if not fname.endswith(".wav"):
                continue
            msg_id = fname[:-4]
            if not VOICEMAIL_MSG_RE.match(msg_id):
                continue
            callerid, origtime, duration = "", "", ""
            txt_path = os.path.join(inbox, msg_id + ".txt")
            if os.path.isfile(txt_path):
                cp = configparser.ConfigParser(delimiters=("=",))
                try:
                    cp.read(txt_path)
                    if cp.has_section("message"):
                        callerid = cp.get("message", "callerid", fallback="")
                        origtime = cp.get("message", "origtime", fallback="")
                        duration = cp.get("message", "duration", fallback="")
                except configparser.Error:
                    pass
            messages.append({
                "ext": mailbox, "msg": msg_id,
                "callerid": callerid, "origtime": origtime, "duration": duration,
            })
    messages.sort(key=lambda m: int(m["origtime"]) if m["origtime"].isdigit() else 0, reverse=True)
    return messages


def voicemail_audio_path(ext, msg):
    """Resolves a mailbox+message ID to an on-disk .wav path, or None if
    anything about the request doesn't check out. Two independent checks,
    not one: EXTEN_RE/VOICEMAIL_MSG_RE already forbid any path-traversal
    character (only digits, and "msg"+digits, are accepted at all — no "/",
    "..", or similar can ever reach os.path.join), and the resolved
    realpath is then confirmed to still land inside the mailbox's own INBOX
    before this is ever handed to open()."""
    ext = str(ext or "").strip()
    msg = str(msg or "").strip()
    if not ASTERISK_SPOOL_DIR or not EXTEN_RE.match(ext) or not VOICEMAIL_MSG_RE.match(msg):
        return None
    inbox = os.path.join(ASTERISK_SPOOL_DIR, "voicemail", VOICEMAIL_CONTEXT, ext, "INBOX")
    path = os.path.join(inbox, msg + ".wav")
    real_inbox = os.path.realpath(inbox)
    real_path = os.path.realpath(path)
    if not real_path.startswith(real_inbox + os.sep) or not os.path.isfile(real_path):
        return None
    return real_path


# ── Per-admin extension scoping (Calls & Texts + Voicemail only) ───────────
# Managed by services/security-dashboard.sh's CLI prompts (see
# _secdash_configure_admin_scoping), not by this app — this file is written
# by root at install/update time and only ever READ here, matching the
# read-only-from-the-app-side treatment ea_config_dir already gets and for
# the same reason: no code path in app.py needs to write it, so it never
# gets write access.
#
# Security Log, CrowdSec, and Extensions are deliberately never touched by
# this — those stay gated purely on "did you get past Caddy/Authelia at
# all," same as before this existed. Only Calls & Texts and Voicemail are
# scoped, per the split the dashboard's actual admins asked for: both admins
# need the full Extensions list and Security Log to do their job, but each
# should only see the call/text history and voicemail of their own numbers.
DASHBOARD_ADMINS_FILE = "/opt/security-dashboard/dashboard-admins.conf"
DASHBOARD_ADMINS_HEADER = (
    "; Per-admin extension scoping for the Calls & Texts and Voicemail tabs.\n"
    "; Managed by 'sudo ./setup.sh security-dashboard' (reconfigure on an\n"
    "; existing install) - safe to edit by hand too, one [username] section\n"
    "; per admin with an extensions= list, username must match that admin's\n"
    "; Authelia login exactly (this dashboard reads it off the Remote-User\n"
    "; header Caddy's forward_auth/import authelia already injects).\n"
    ";\n"
    "; Empty or missing file = scoping disabled, everyone sees everything on\n"
    "; both tabs (today's default, unchanged). Once ANY [username] section\n"
    "; exists here, every OTHER identity - including an unlisted admin, or a\n"
    "; request with no Remote-User at all - sees NOTHING on those two tabs.\n"
    "; Fail closed, not fail open: a typo'd or forgotten admin loses access\n"
    "; rather than silently gaining everyone else's.\n\n"
)


def _dashboard_admins_cp():
    cp = configparser.ConfigParser(delimiters=("=",))
    if os.path.isfile(DASHBOARD_ADMINS_FILE):
        try:
            cp.read(DASHBOARD_ADMINS_FILE)
        except configparser.Error:
            pass
    return cp


def allowed_extensions_for_user(username):
    """None means "no restriction" - ONLY when scoping is disabled
    entirely (no [username] sections configured at all). Once any admin IS
    configured, every other identity (unrecognized username, or no
    Remote-User header at all) gets an EMPTY set back, never None, so a
    caller can't mistake "not found" for "unrestricted" — see the fail-
    closed reasoning in DASHBOARD_ADMINS_HEADER."""
    cp = _dashboard_admins_cp()
    if not cp.sections():
        return None
    username = (username or "").strip()
    if not username or not cp.has_section(username):
        return set()
    raw = cp.get(username, "extensions", fallback="")
    return {e.strip() for e in raw.split(",") if e.strip()}


def _admin_scope_for_request(handler):
    """The requesting identity's allowed-extensions set, resolved once per
    request from the Remote-User header Caddy's Authelia integration
    already injects (see services/authelia.sh's copy_headers). Every scoped
    route calls this exactly once."""
    return allowed_extensions_for_user(handler.headers.get("Remote-User", ""))


def filter_calls_by_scope(events, allowed):
    """events is the parse_pstn_calls()/parse_texts() shape - both
    normalize to from/to fields regardless of direction, so one filter
    covers both routes. Keeps a row if EITHER side is one of the caller's
    extensions (an outbound row's "from" is the extension, an inbound row's
    "to" is - covering both without needing to know direction here)."""
    if allowed is None:
        return events
    return [e for e in events if e.get("from") in allowed or e.get("to") in allowed]


def filter_voicemail_by_scope(messages, allowed):
    if allowed is None:
        return messages
    return [m for m in messages if m.get("ext") in allowed]


GROUP_NAME_RE = re.compile(r"^[A-Za-z0-9_ -]{1,40}$")

GROUPS_HEADER = (
    "; Auto-generated mirror of Ring Groups' membership (see sync_room_group_\n"
    "; mirror() in app.py) - NOT a user-facing feature of its own. There is no\n"
    "; dashboard UI for this file; edit Ring Group membership on the\n"
    "; Extensions tab instead and this file follows automatically. Its only\n"
    "; reader is pstn-personal-group-ring.sh (services/pstn-trunk.sh), which\n"
    "; looks up a Ring Group's members by name when a personal DID is owned\n"
    "; by that group rather than a single extension.\n\n"
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


def sync_room_group_mirror(room_name, members, old_name=None):
    """Keeps pstn-groups.conf in step with a Ring Group's (Easy Asterisk
    Room's) membership, so pstn-trunk.sh's existing group-owned-personal-DID
    machinery (pstn-personal-group-ring.sh, unchanged) can point at a Ring
    Group by name without pstn-trunk.sh ever needing to know rooms.conf's
    format. Ring Groups are now the only UI for building a named extension
    set — this mirror, silent to the admin, is the only reason
    pstn-groups.conf still exists on disk at all.

    old_name is passed on rename/delete so the STALE section (under the
    previous name) gets removed rather than left orphaned alongside the
    new one — pstn-personal-group-ring.sh looks sections up by exact name,
    so a leftover old-name section is inert, just clutter, not a routing
    risk; still, no reason to leave it.

    room_name=None means the room itself was deleted; only the old_name
    cleanup runs in that case."""
    if old_name and old_name != room_name:
        delete_group(old_name)
    if room_name is not None:
        write_group(room_name, members)


LIMIT_RE = re.compile(r"^\d+$")


def pstn_installed():
    """True only once services/pstn-trunk.sh has actually wired the dialplan
    in (pstn-trunk-dialplan.conf existing), not just because base Asterisk is
    present — pjsip.conf/extensions.conf exist either way, so extension names
    alone can't tell us this. Without this check the Extensions tab would
    show tier columns and a default-but-unenforced 10/10 cap even when there
    is no PSTN trunk at all."""
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
PERSONAL_DID_RE_11 = re.compile(r"^1\d{10}$")


def _normalize_personal_did_input(did):
    """write_personal_did()'s DID field is hand-typed, same footgun as
    allowed_numbers - accept the canonical bare 10-digit form, an 11-digit
    one with the NANP "1" prefix, or either with a leading "+" (pasted
    straight from a call log), returning the canonical 10-digit form either
    way instead of rejecting a plainly-valid entry."""
    did = did.lstrip("+")
    if PERSONAL_DID_RE.match(did):
        return did
    if PERSONAL_DID_RE_11.match(did):
        return did[1:]
    return None


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


def _group_current_did(group_name):
    """The DID currently owned by "@group_name", or None. Personal DIDs are
    keyed by DID number, not by owner, so finding "this group's DID" means
    scanning for the matching owner value."""
    for d in list_personal_dids():
        if d["owner"] == "@" + group_name:
            return d["did"]
    return None


def _reconcile_group_cid_members(members, old_did=None, new_did=None):
    """Makes a Ring Group's DID double as its members' outbound Caller-ID
    override, without a Groups-card-style bulk action and without a new
    field to track "individually assigned" vs "inherited from the group".

    Boundary used instead of a tracking field: a member's existing
    personal_did is only ever touched here if it's currently EMPTY (safe
    to fill in) or if it currently equals old_did (safe to assume it came
    from this same group, so safe to clear/replace). Anything else —
    an individually-assigned number, or one inherited from a DIFFERENT
    group — is left alone.

    Known, accepted gap: if a member is individually assigned a number
    that happens to exactly equal a group's DID, then later leaves that
    group (or the group's DID changes), this can't tell the difference
    and clears/replaces it anyway. Rare, and low-stakes — the member
    just falls back to the shared trunk DID for Caller-ID, not a loss of
    access — preferred here over the bookkeeping a fully precise version
    would need. Called with the group's CURRENT DID as new_did (and
    whatever it used to be, if anything, as old_did) any time either the
    group's DID assignment or its membership changes."""
    if old_did == new_did:
        return
    perms_cp = _read_permissions_cp()
    changed = False
    for ext in members:
        if not perms_cp.has_section(ext):
            if new_did:
                perms_cp.add_section(ext)
                perms_cp.set(ext, "personal_did", new_did)
                changed = True
            continue
        existing = perms_cp.get(ext, "personal_did", fallback="")
        if new_did and not existing:
            perms_cp.set(ext, "personal_did", new_did)
            changed = True
        elif old_did and existing == old_did:
            if new_did:
                perms_cp.set(ext, "personal_did", new_did)
            else:
                perms_cp.remove_option(ext, "personal_did")
                if not perms_cp.options(ext):
                    perms_cp.remove_section(ext)
            changed = True
    if changed:
        _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, perms_cp)


def write_personal_did(did, owner):
    """Assigns did -> owner, keeping pstn-personal-dids.conf (inbound
    routing, read by the dialplan) and pstn-permissions.conf's
    personal_did= (outbound Caller-ID override) in sync. One owner has at
    most one personal_did (AST_CONFIG() returns a single value per key), so
    reassigning a DID to a new owner drops the previous owner's claim on
    it, and giving an extension a new personal DID drops whichever one it
    had before — this always leaves a clean 1:1 mapping in both files,
    rather than requiring the caller to clean up the old assignment
    itself.

    owner may also be a Ring Group reference, written as "@GroupName" (the
    '@' makes it unambiguous against a same-named numeric extension - Ring
    Group names are free text and could otherwise collide, e.g. a group
    literally named "201"). A group-owned DID rings every CURRENT member
    whose own tier/approved-numbers authorize the caller, computed fresh on
    every call (see pstn-personal-group-ring.sh) rather than baked in at
    assignment time - membership changes take effect immediately. It also
    becomes every current member's outbound Caller-ID override, the same
    field a single-extension owner gets, via _reconcile_group_cid_members()
    below - see that function's own comment for the exact rule (an
    individual assignment always wins over the group's)."""
    if not ASTERISK_CONFIG_DIR:
        return False, "No Asterisk install detected on this box"
    did = str(did).strip()
    owner = str(owner).strip()
    norm_did = _normalize_personal_did_input(did)
    if norm_did is None:
        return False, "DID must be a 10-digit US number (11-digit with a leading 1 also accepted)"
    did = norm_did

    is_group = owner.startswith("@")
    group_name = owner[1:] if is_group else ""
    if is_group:
        if not group_name or not _read_groups_cp().has_section(group_name):
            return False, "Group '%s' not found" % group_name
    elif not EXTEN_RE.match(owner):
        return False, "Invalid owner extension"

    dids_cp = _read_personal_dids_cp()
    perms_cp = _read_permissions_cp()
    old_group_did = _group_current_did(group_name) if is_group else None

    if not is_group:
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

    ok, err = _write_ini_cp(_personal_dids_path(), PERSONAL_DIDS_HEADER, dids_cp)
    if not ok:
        return False, err

    if is_group:
        members = [m.strip() for m in _read_groups_cp().get(group_name, "members", fallback="").split(",") if m.strip()]
        _reconcile_group_cid_members(members, old_did=old_group_did, new_did=did)
        return True, "Assigned %s to group %s" % (did, group_name)

    if not perms_cp.has_section(owner):
        perms_cp.add_section(owner)
    perms_cp.set(owner, "personal_did", did)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, perms_cp)
    if not ok:
        return False, err

    owner_tier = perms_cp.get(owner, "tier", fallback="internal")
    if owner_tier not in ("full", "restricted"):
        return True, "Assigned %s to extension %s - note: %s is internal-tier, so it won't actually receive calls on this DID until you also grant it full or restricted tier." % (did, owner, owner)
    return True, "Assigned %s to extension %s" % (did, owner)


def remove_personal_did(did):
    """Unassigns a DID entirely. The personal_did= cleanup loop below is a
    plain value match, not owner-type-aware, so it already correctly clears
    it from every Ring Group member who'd inherited this exact DID as their
    outbound Caller-ID (see _reconcile_group_cid_members) as well as a
    single extension's own direct assignment - no separate group-aware path
    needed here."""
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


# ── Easy Asterisk device management (devices, rooms/ring-groups) ──────────
# Full reimplementation of vendor/easy-asterisk/easy-asterisk-v0.10.0.sh's
# vendored web admin (its own separate process, normally reached via its own
# port/domain) as native code here instead — one tab, one process, no
# separate app to proxy or embed. Keeps writing the EXACT same file formats
# (pjsip.conf's "; === Device: Name (category) [AA:yes/no] ===" comment +
# bracket-section convention, rooms.conf's pipe-delimited rows) the vendor's
# own `easy-asterisk --rebuild-dialplan` CLI still reads
# to generate the dialplan — this is a new front door onto the same
# underlying config, not a fork of dialplan generation itself.
#
# Reads go straight through the host-side bind-mounted files (same as
# list_extensions() already does for pjsip.conf) — cheap, and this dashboard
# already has working read access there. WRITES go through `docker exec ...
# tee` instead of writing the host-side file directly: Easy Asterisk's own
# container writes these files as ITS OWN internal user, and a host-side
# write here would be fighting that ownership — liable to silently break
# again the next time the container restarts and re-asserts it. Routing
# through docker exec (root, via a narrowly scoped sudoers entry — see
# _secdash_write_sudoers) sidesteps the host/container UID mismatch
# entirely, the same way this file already does for CrowdSec's cscli.
ASTERISK_EA_CONFIG_DIR = os.environ.get("ASTERISK_EA_CONFIG_DIR", "")
ASTERISK_EA_CONTAINER = os.environ.get("ASTERISK_EA_CONTAINER", "")

EA_PJSIP_CONTAINER_PATH = "/etc/asterisk/pjsip.conf"
ASTERISK_EA_ENV = os.environ.get("ASTERISK_EA_ENV", "")


def _parse_env_file(path):
    """KEY=value pairs out of a shell-style config file, quotes stripped."""
    values = {}
    if not path or not os.path.isfile(path):
        return values
    try:
        with open(path, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        return {}
    return values


def _ea_server_config_path():
    """Easy Asterisk's own runtime config — /etc/easy-asterisk/config inside
    the container, which is this directory on the host.

    This, not the host .env, is what the vendored web admin reads for domain
    and TURN details (see get_server_info() in
    vendor/easy-asterisk/easy-asterisk-v0.10.0.sh), and it's the reason that
    page shows them correctly. It's also written by the container's own
    entrypoint, so it reflects what Asterisk is actually running with rather
    than what .env asked for — and it sits in a directory this dashboard is
    already granted read access to for rooms.conf, so it needs no extra
    permissions, no ACL on a 600 file, and no ProtectSystem exception."""
    return os.path.join(ASTERISK_EA_CONFIG_DIR, "config") if ASTERISK_EA_CONFIG_DIR else ""


def _read_ea_env():
    """Domain/TURN settings, preferring Easy Asterisk's own config over .env.

    Three sources, in order of how much they reflect reality:
      1. /etc/easy-asterisk/config  — what the running Asterisk was configured with
      2. the host .env              — what the installer asked for
      3. `docker exec cat`          — same file as (1), for when host-side
                                      permissions get in the way anyway
    Later sources only fill gaps; they never override a value already found."""
    values = _parse_env_file(_ea_server_config_path())
    for key, val in _parse_env_file(ASTERISK_EA_ENV).items():
        values.setdefault(key, val)
    if not values.get("TURN_SERVER") or not values.get("DOMAIN_NAME"):
        ok, out, _err = run_sudo(
            ["docker", "exec", ASTERISK_EA_CONTAINER, "cat", "/etc/easy-asterisk/config"]
        ) if ASTERISK_EA_CONTAINER else (False, "", "")
        if ok and out:
            for line in out.splitlines():
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                val = val.strip().strip('"').strip("'")
                if val and not values.get(key):
                    values[key] = val
    return values


def _ea_env_problem():
    """Why domain/TURN couldn't be found, in words, or "" if they were.

    "not configured" is the wrong message when the truth is "no source was
    readable" — and it was, in practice, for a reason no one could see from
    the page."""
    sources = [p for p in (_ea_server_config_path(), ASTERISK_EA_ENV) if p]
    if not sources:
        return ("This service doesn't know where Asterisk's config lives. "
                "Re-run: sudo ./setup.sh security-dashboard")
    existing = [p for p in sources if os.path.isfile(p)]
    if not existing:
        return "No Asterisk config found at: " + " or ".join(sources)
    unreadable = [p for p in existing if not os.access(p, os.R_OK)]
    if len(unreadable) == len(existing):
        return ("No permission to read " + " or ".join(unreadable) +
                ". Re-run: sudo ./setup.sh security-dashboard")
    return ""


def ea_connection_defaults():
    """Server/transport guidance for the add form and the per-extension panel.

    A box with DOMAIN_NAME set is reachable from anywhere and its phones
    should register over TLS on 5061; without one there's only the LAN path.
    Getting this default wrong is not cosmetic — an endpoint written with
    transport=transport-udp simply will not answer a TLS registration, and
    the phone reports nothing more useful than a timeout."""
    env = _read_ea_env()
    domain = env.get("DOMAIN_NAME", "")
    problem = _ea_env_problem()
    turn_server = env.get("TURN_SERVER", "")
    # TURN_SERVER may be bare host:port or just a host; the port defaults to
    # whatever coturn was given.
    if turn_server and ":" not in turn_server:
        turn_server = "%s:%s" % (turn_server, env.get("TURN_PORT", "3478"))
    if not problem and not turn_server:
        problem = ("No TURN_SERVER in %s — this install was set up without one, so "
                   "phones have no relay to fall back on for NAT traversal."
                   % (_ea_server_config_path() or ASTERISK_EA_ENV))
    return {
        "domain": domain,
        "server_ip": _host_ip(),
        "default_conn_type": "fqdn" if domain else "lan",
        "turn_server": turn_server,
        "turn_username": env.get("TURN_USERNAME", ""),
        "turn_password": env.get("TURN_PASSWORD", ""),
        "env_readable": not _ea_env_problem(),
        "env_error": problem,
    }


def _host_ip():
    """This box's own address, for when no domain is configured — the vendored
    admin shows the same thing via `hostname -I`."""
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=5).stdout
        return out.split()[0] if out.split() else ""
    except Exception:                                  # noqa: BLE001
        return ""


def ea_device_details(extension):
    """Everything needed to configure a softphone for one extension.

    Includes the SIP password, read back from pjsip.conf rather than
    regenerated: a password shown only once at creation is lost the moment
    the page is closed, which in practice means deleting and recreating the
    extension just to re-pair a handset. The dashboard already holds this
    file, so surfacing it behind an explicit click adds no access it didn't
    have — and it sits behind whatever auth fronts the dashboard."""
    extension = str(extension).strip()
    if not EA_EXT_RE.match(extension):
        return None
    device = next((d for d in ea_list_devices() if d["extension"] == extension), None)
    if not device:
        return None

    password = ""
    path = _ea_pjsip_host_path()
    if path and os.path.isfile(path):
        try:
            with open(path, errors="replace") as f:
                in_auth = False
                for line in f:
                    stripped = line.strip()
                    if stripped.startswith("["):
                        in_auth = stripped == "[%s]" % extension
                        continue
                    if in_auth and stripped.startswith("password="):
                        password = stripped.split("=", 1)[1]
        except OSError:
            pass

    conn = ea_connection_defaults()
    tls = device.get("transport") == "tls"
    return {
        "extension": extension,
        "name": device.get("name", ""),
        "mobile": device.get("category") == "mobile",
        "env_error": conn.get("env_error", ""),
        "password": password,
        "transport": "TLS" if tls else "UDP",
        "port": 5061 if tls else 5060,
        "encryption": device.get("encryption", "no"),
        "server": conn["domain"] or conn.get("server_ip", ""),
        "server_is_ip": not conn["domain"],
        "turn_server": conn["turn_server"],
        "turn_username": conn["turn_username"],
        "turn_password": conn["turn_password"],
        "status": ea_get_status().get(extension, "unknown"),
    }
EA_ROOMS_CONTAINER_PATH = "/etc/easy-asterisk/rooms.conf"
EA_EXT_RE = re.compile(r"^\d{1,10}$")


def ea_installed():
    return bool(ASTERISK_EA_CONTAINER)


def _ea_pjsip_host_path():
    return os.path.join(ASTERISK_CONFIG_DIR, "pjsip.conf") if ASTERISK_CONFIG_DIR else None


def _ea_rooms_host_path():
    return os.path.join(ASTERISK_EA_CONFIG_DIR, "rooms.conf") if ASTERISK_EA_CONFIG_DIR else None


def ea_docker_write(container_path, content):
    """Writes content to a file INSIDE the Easy Asterisk container via
    `docker exec -i <container> tee <path>` (root, sudo-gated) — see the
    module-level comment above for why this isn't a direct host-side write.

    Then hands ownership back to asterisk:asterisk. `tee` runs as root inside
    the container, so every write silently re-owned the file to root; Asterisk
    itself runs as `asterisk` and expects to own its config. The vendored
    admin's own add_device() does this same chown immediately after writing
    pjsip.conf, and services/asterisk.sh's device migration does it too — this
    was the one writer in the project that didn't, which is a strong candidate
    for extensions created here behaving differently from ones created in the
    vendored admin."""
    ok, _out, err = run_sudo(
        ["docker", "exec", "-i", ASTERISK_EA_CONTAINER, "tee", container_path],
        input_text=content,
    )
    if not ok:
        return False, (err or "Write failed")
    chowned, _o, cerr = run_sudo(
        ["docker", "exec", ASTERISK_EA_CONTAINER, "chown", "asterisk:asterisk", container_path]
    )
    if not chowned:
        print("WARNING: wrote %s but could not chown it to asterisk:asterisk: %s"
              % (container_path, cerr), flush=True)
    return True, ""


def ea_reload_pjsip():
    run_sudo(["docker", "exec", ASTERISK_EA_CONTAINER, "asterisk", "-rx", "module reload res_pjsip.so"])


def ea_rebuild_dialplan():
    run_sudo(["docker", "exec", ASTERISK_EA_CONTAINER, "/usr/local/bin/easy-asterisk", "--rebuild-dialplan"])


def restart_asterisk_container():
    """Restarts the Easy Asterisk container - the "Commit Changes" button on
    the Extensions tab. Confirmed live: dashboard writes to
    pstn-permissions.conf/pstn-groups.conf/pstn-personal-dids.conf land on
    disk immediately (readable via a plain `cat` right after saving), but
    AST_CONFIG() in the dialplan sometimes kept returning a stale value
    until the container was fully restarted - not just a `dialplan reload`
    or `module reload`, an actual container restart. Root cause not fully
    understood (contradicts AST_CONFIG's whole "reads fresh every call, no
    restart needed" design premise, which this codebase otherwise relies on
    throughout), but the restart reliably clears it, so this button exists
    instead of requiring every admin to rediscover "just restart it" the
    hard way. Uses the same ASTERISK_EA_CONTAINER/run_sudo mechanism as the
    Extensions tab's own docker exec calls - no new sudoers scope
    needed beyond the one line added for this."""
    if not ASTERISK_EA_CONTAINER:
        return False, "No Asterisk container detected on this box"
    ok, _out, err = run_sudo(["docker", "restart", ASTERISK_EA_CONTAINER], timeout=30)
    return ok, ("" if ok else (err or "Restart failed"))


def ea_get_status():
    """Registered/unregistered per extension — same 'pjsip show endpoints'
    parsing as the vendored get_registered_endpoints()."""
    ok, out, _err = run_sudo(["docker", "exec", ASTERISK_EA_CONTAINER, "asterisk", "-rx", "pjsip show endpoints"])
    if not ok:
        return {}
    endpoints = {}
    current = None
    for line in out.split("\n"):
        m = re.match(r"\s*Endpoint:\s+(\d+)/", line)
        if m:
            current = m.group(1)
            endpoints[current] = "offline"
        if current and "Contact:" in line and ("Avail" in line or "NonQual" in line):
            endpoints[current] = "online"
    return endpoints


def ea_list_devices():
    """Same comment+bracket parsing as the vendored get_devices() so this
    reads pjsip.conf identically regardless of which admin wrote it."""
    path = _ea_pjsip_host_path()
    devices = []
    if not path or not os.path.isfile(path):
        return devices
    with open(path) as f:
        lines = f.readlines()
    dev_name = dev_cat = dev_aa = None
    for line in lines:
        line = line.strip()
        if "; === Device:" in line:
            temp = line.split("; === Device:")[1].split("===")[0].strip()
            dev_aa = None
            if "[AA:yes]" in temp:
                dev_aa = "yes"
                temp = temp.replace("[AA:yes]", "").strip()
            elif "[AA:no]" in temp:
                dev_aa = "no"
                temp = temp.replace("[AA:no]", "").strip()
            if "(" in temp and ")" in temp:
                dev_cat = temp[temp.rfind("(") + 1:temp.rfind(")")]
                dev_name = temp[:temp.rfind("(")].strip()
            else:
                dev_name = temp
                dev_cat = "unknown"
        elif dev_name and re.match(r"^\[(\d+)\]$", line):
            ext = re.match(r"^\[(\d+)\]$", line).group(1)
            devices.append({"name": dev_name, "category": dev_cat, "extension": ext,
                             "auto_answer": dev_aa, "transport": "udp", "encryption": "no"})
            dev_name = dev_cat = dev_aa = None
        elif devices and line.startswith("transport=transport-"):
            devices[-1]["transport"] = line.split("transport-")[1]
        elif devices and line.startswith("media_encryption="):
            val = line.split("=")[1]
            if val in ("sdes", "dtls"):
                devices[-1]["encryption"] = val
                if devices[-1]["transport"] == "udp":
                    devices[-1]["transport"] = "tls"
            elif val != "no":
                devices[-1]["encryption"] = val
    return devices


def _ea_generate_password(length=16):
    import secrets
    import string
    chars = string.ascii_letters + string.digits
    return "".join(secrets.choice(chars) for _ in range(length))


def ea_add_device(name, category, extension, conn_type="lan", auto_answer=None):
    path = _ea_pjsip_host_path()
    if not path:
        return False, "No Asterisk install detected on this box"
    extension = str(extension).strip()
    if not EA_EXT_RE.match(extension):
        return False, "Invalid extension"
    name = (name or "").strip()
    if not name:
        return False, "Name required"
    if not os.path.isfile(path):
        return False, "Config file not found"

    with open(path) as f:
        current = f.read()
    if "[%s]" % extension in current:
        return False, "Extension already exists"

    password = _ea_generate_password(16)

    if conn_type == "fqdn":
        transport = "transport=transport-tls"
        encryption = "media_encryption=sdes"
        ice = "ice_support=yes"
    else:
        transport = "transport=transport-udp"
        encryption = "media_encryption=no"
        # The vendored admin also turns ICE on for LAN devices whenever a TURN
        # server or VPN-ICE mode is configured — without it such a device has
        # no way to use the relay it was given credentials for. Keyed off the
        # same TURN_SERVER this dashboard already reads for the details panel.
        ice = "ice_support=yes" if ea_connection_defaults().get("turn_server") else ""

    aa_tag = ""
    if auto_answer == "yes":
        aa_tag = "[AA:yes] "
    elif auto_answer == "no":
        aa_tag = "[AA:no] "

    keepalive = ""
    if category == "mobile":
        keepalive = "rtp_keepalive=15\nrtp_timeout=120\nrtp_timeout_hold=120"

    # Built as a filtered line list, not positional %s blanks — keepalive and
    # ice are both empty for a plain non-mobile LAN device, and leaving them
    # as literal blank template lines produces TWO consecutive blank lines
    # inside the endpoint stanza instead of one. ea_delete_device/
    # ea_rename_device/ea_change_device_category all use "blank line ends
    # this device's block" as their boundary heuristic (matching the
    # vendored admin's own logic) — an extra internal blank line there is a
    # latent bug inherited from the vendor template, confirmed live against
    # a synthetic fixture (delete_device left an orphaned tail of lines
    # behind). Filtering empty lines out entirely avoids it regardless of
    # which optional pieces are present.
    endpoint_lines = [
        "type=endpoint",
        "context=intercom",
        # services/asterisk.sh patches the VENDOR's two device-creation paths
        # to add this, but this function is a third, independent writer — so
        # without it here, an extension created from this dashboard silently
        # had no internal SIP messaging while one created from the vendor
        # admin did. See _asterisk_write_messaging_dialplan for what the
        # context does.
        "message_context=sip-messaging",
        transport,
        "disallow=all",
        "allow=opus",
        "allow=ulaw",
        "allow=alaw",
        "allow=g722",
        encryption,
        "direct_media=no",
        "rtp_symmetric=yes",
        "force_rport=yes",
        "rewrite_contact=yes",
    ]
    if keepalive:
        endpoint_lines.append(keepalive)
    if ice:
        endpoint_lines.append(ice)
    endpoint_lines += [
        "auth=%s" % extension,
        "aors=%s" % extension,
        'callerid="%s" <%s>' % (name, extension),
    ]

    device_config = "\n; === Device: %s (%s) %s===\n[%s]\n%s\n\n[%s]\ntype=auth\nauth_type=userpass\nusername=%s\npassword=%s\n\n[%s]\ntype=aor\nmax_contacts=5\nremove_existing=yes\nqualify_frequency=30\n" % (
        name, category, aa_tag, extension, "\n".join(endpoint_lines),
        extension, extension, password, extension,
    )

    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, current + device_config)
    if not ok:
        return False, err
    ea_reload_pjsip()
    ea_rebuild_dialplan()
    return True, {
        "extension": extension, "password": password, "name": name,
        "transport": "tls" if conn_type == "fqdn" else "udp",
        "port": 5061 if conn_type == "fqdn" else 5060,
    }


def ea_device_provisioning(extension):
    """Every setting needed to configure a softphone, as a plain text file.

    Deliberately not a vendor-specific provisioning format: Sipnetic, Linphone,
    Zoiper and Groundwire each want a different one, none of which could be
    verified from here, and a confidently-wrong .xml is worse than a file you
    can read. This is the same data the panel shows, in a form that survives
    being emailed to yourself and opened on the phone."""
    d = ea_device_details(extension)
    if not d:
        return None, None
    host = d["server"] or "<this box's IP>"
    lines = [
        "Easy Asterisk — SIP account details",
        "Extension %s (%s)" % (d["extension"], d["name"] or "unnamed"),
        "Generated %s" % time.strftime("%Y-%m-%d %H:%M:%S %Z"),
        "",
        "ACCOUNT",
        "  SIP server / domain : %s" % host,
        "  Username            : %s" % d["extension"],
        "  Auth username       : %s" % d["extension"],
        "  Password            : %s" % (d["password"] or "(not found in pjsip.conf)"),
        "  Display name        : %s" % (d["name"] or d["extension"]),
        "",
        "TRANSPORT",
        "  Transport           : %s" % d["transport"],
        "  Port                : %s" % d["port"],
        "  Media encryption    : %s" % ("SRTP (%s)" % d["encryption"] if d["encryption"] and d["encryption"] != "no" else "none"),
        "  SIP URI             : sip:%s@%s:%s;transport=%s" % (
            d["extension"], host, d["port"], d["transport"].lower()),
        "",
        "NAT TRAVERSAL (TURN/STUN)",
    ]
    if d["turn_server"]:
        lines += [
            "  TURN/STUN server    : %s" % d["turn_server"],
            "  TURN username       : %s" % d["turn_username"],
            "  TURN password       : %s" % d["turn_password"],
            "  ICE                 : enable",
        ]
    else:
        lines += ["  Not configured on this install — leave TURN/STUN off."]
    lines += [
        "",
        "NOTES",
        "  * This file contains a password. Delete it once the phone is set up.",
    ]
    if d.get("server_is_ip"):
        lines.append("  * No domain is configured, so the address above is this box's IP "
                     "and the TLS certificate is self-signed — the phone must be told to accept it.")
    if d["transport"] == "UDP":
        lines.append("  * This extension is UDP-only. A phone configured for TLS on 5061 "
                     "will not register against it.")
    if d.get("mobile"):
        lines.append("  * Tagged as a mobile/cellular device: RTP keepalive is on to hold "
                     "the NAT binding open.")
    return "%s-extension-%s.txt" % (
        re.sub(r"[^A-Za-z0-9._-]", "-", host), d["extension"]), "\n".join(lines) + "\n"


def ea_device_sipnetic_string(extension):
    """Sipnetic's own documented "account string" QR-scan format
    (https://www.sipnetic.com/qr-codes): semicolon-separated key=value pairs,
    n=display name, u=username, d=domain/IP (no port), p=password,
    dt=default transport (0=UDP, 1=TCP, 2=TLS). Unlike
    ea_device_provisioning()'s deliberately generic plain-text file, this one
    IS a verified, documented format for one specific app, built from the
    exact same ea_device_details() data.

    A literal ';' in any field must be doubled per that same doc page --
    generated passwords are alnum-only (_ea_generate_password) so this only
    matters for a hand-typed device name, but escaping costs nothing."""
    d = ea_device_details(extension)
    if not d:
        return None

    def esc_field(v):
        return str(v or "").replace(";", ";;")

    host = d["server"] or ""
    dt = "2" if d["transport"] == "TLS" else "0"
    return "n=%s;u=%s;d=%s;p=%s;dt=%s;" % (
        esc_field(d["name"] or d["extension"]), esc_field(d["extension"]),
        esc_field(host), esc_field(d["password"]), dt,
    )


def _ea_edit_device_block(extension, mutate):
    """Rewrite one device's endpoint stanza in place.

    Block boundary is the same heuristic the vendored admin uses and that
    ea_delete_device relies on: the "; === Device:" comment starts it and the
    first blank line ends it. mutate() receives the endpoint body as a list of
    lines and returns the replacement."""
    path = _ea_pjsip_host_path()
    if not path or not os.path.isfile(path):
        return False, "Config file not found"
    with open(path, errors="replace") as f:
        lines = f.readlines()

    out, body, state, found = [], [], "before", False
    for line in lines:
        stripped = line.strip()
        if state == "before":
            if stripped == "[%s]" % extension and out and out[-1].strip().startswith("; === Device:"):
                found = True
                state = "in"
                out.append(line)
                continue
            out.append(line)
        elif state == "in":
            if stripped == "":
                out.extend(l if l.endswith("\n") else l + "\n" for l in mutate(body))
                out.append(line)
                state = "after"
                continue
            body.append(stripped)
        else:
            out.append(line)
    if state == "in":                      # block ran to EOF with no blank line
        out.extend(l if l.endswith("\n") else l + "\n" for l in mutate(body))
    if not found:
        return False, "Device not found"

    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, "".join(out))
    if not ok:
        return False, err
    ea_reload_pjsip()
    return True, "ok"


def ea_set_device_transport(extension, conn_type):
    """Switch an extension between LAN (UDP/5060) and Remote (TLS/5061).

    The single most common reason a phone that looks correctly configured
    never registers: the endpoint was created LAN-only and the phone is
    dialling in over TLS from outside. Changing it used to mean deleting and
    recreating the extension, which also changed its password."""
    extension = str(extension).strip()
    if not EA_EXT_RE.match(extension):
        return False, "Invalid extension"
    if conn_type not in ("lan", "fqdn"):
        return False, "Invalid connection type"

    tls = conn_type == "fqdn"

    def mutate(body):
        kept = [l for l in body
                if not l.startswith(("transport=", "media_encryption=", "ice_support="))]
        new = []
        for line in kept:
            new.append(line)
            if line.startswith("context="):
                new.append("transport=transport-tls" if tls else "transport=transport-udp")
                new.append("media_encryption=sdes" if tls else "media_encryption=no")
                if tls:
                    new.append("ice_support=yes")
        return new

    ok, err = _ea_edit_device_block(extension, mutate)
    if not ok:
        return False, err
    return True, "Now %s on port %d" % ("TLS" if tls else "UDP", 5061 if tls else 5060)


def ea_reset_device_password(extension):
    """New random SIP password for an existing extension, keeping everything
    else — the alternative being delete-and-recreate, which loses the
    extension's category, room membership and PSTN permissions."""
    extension = str(extension).strip()
    if not EA_EXT_RE.match(extension):
        return False, "Invalid extension"
    path = _ea_pjsip_host_path()
    if not path or not os.path.isfile(path):
        return False, "Config file not found"

    password = _ea_generate_password(16)
    with open(path, errors="replace") as f:
        lines = f.readlines()

    out, in_auth, changed = [], False, False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("["):
            in_auth = stripped == "[%s]" % extension
            out.append(line)
            continue
        if in_auth and stripped.startswith("password="):
            out.append("password=%s\n" % password)
            changed = True
            continue
        out.append(line)

    if not changed:
        return False, "No auth section found for that extension"
    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, "".join(out))
    if not ok:
        return False, err
    ea_reload_pjsip()
    return True, password


def ea_delete_device(extension):
    """Same block-removal logic as the vendored delete_device()."""
    path = _ea_pjsip_host_path()
    if not path or not os.path.isfile(path):
        return False, "Config file not found"
    with open(path) as f:
        lines = f.readlines()

    new_lines = []
    found = False
    skip = False
    pending_comment = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("; === Device:"):
            pending_comment = line
            continue
        if re.match(r"^\[%s\]$" % re.escape(extension), stripped):
            if pending_comment:
                found = True
                skip = True
                pending_comment = None
                continue
            elif found:
                skip = True
                continue
        if pending_comment:
            new_lines.append(pending_comment)
            pending_comment = None
        if skip and stripped == "":
            skip = False
            continue
        if not skip:
            new_lines.append(line)

    if not found:
        return False, "Device not found"
    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_reload_pjsip()
    ea_rebuild_dialplan()
    return True, "Device deleted"


def ea_rename_device(extension, new_name):
    """Same comment+callerid rewrite as the vendored rename_device()."""
    path = _ea_pjsip_host_path()
    if not path or not os.path.isfile(path):
        return False, "Config file not found"
    new_name = (new_name or "").strip()
    if not new_name:
        return False, "Name required"
    with open(path) as f:
        lines = f.readlines()

    new_lines = []
    found = False
    in_device = False
    pending_comment = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("; === Device:"):
            temp = stripped.split("; === Device:")[1].split("===")[0].strip()
            aa_tag = ""
            if "[AA:yes]" in temp:
                aa_tag = " [AA:yes]"
                temp = temp.replace("[AA:yes]", "").strip()
            elif "[AA:no]" in temp:
                aa_tag = " [AA:no]"
                temp = temp.replace("[AA:no]", "").strip()
            cat = temp[temp.rfind("(") + 1:temp.rfind(")")] if "(" in temp else "unknown"
            pending_comment = (line, cat, aa_tag)
            continue
        if pending_comment:
            m = re.match(r"^\[(\d+)\]$", stripped)
            if m and m.group(1) == extension:
                _old_line, cat, aa_tag = pending_comment
                new_lines.append("; === Device: %s (%s)%s ===\n" % (new_name, cat, aa_tag))
                new_lines.append(line)
                found = True
                in_device = True
                pending_comment = None
                continue
            else:
                new_lines.append(pending_comment[0])
                pending_comment = None
        if in_device and stripped.startswith("callerid="):
            new_lines.append('callerid="%s" <%s>\n' % (new_name, extension))
            continue
        if in_device and stripped == "":
            in_device = False
        new_lines.append(line)

    if not found:
        return False, "Device not found"
    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_reload_pjsip()
    ea_rebuild_dialplan()
    return True, "Device renamed"


def ea_change_device_category(extension, new_category):
    """Same comment-line category rewrite as the vendored
    change_device_category()."""
    path = _ea_pjsip_host_path()
    if not path or not os.path.isfile(path):
        return False, "Config file not found"
    new_category = (new_category or "").strip()
    if not new_category:
        return False, "Category required"
    with open(path) as f:
        lines = f.readlines()

    new_lines = []
    found = False
    pending_comment = None
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("; === Device:"):
            pending_comment = (line, stripped)
            continue
        if pending_comment:
            m = re.match(r"^\[(\d+)\]$", stripped)
            if m and m.group(1) == extension:
                cm = re.match(r"^; === Device: (.+?) \(([^)]+)\)(.*?)===", pending_comment[1])
                if cm:
                    dev_name, _old_cat, rest = cm.group(1), cm.group(2), cm.group(3)
                    new_lines.append("; === Device: %s (%s)%s===\n" % (dev_name, new_category, rest))
                    found = True
                else:
                    new_lines.append(pending_comment[0])
                new_lines.append(line)
                pending_comment = None
                continue
            else:
                new_lines.append(pending_comment[0])
                pending_comment = None
        new_lines.append(line)

    if not found:
        return False, "Device not found"
    ok, err = ea_docker_write(EA_PJSIP_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_reload_pjsip()
    ea_rebuild_dialplan()
    return True, "Category changed"


def ea_list_rooms():
    path = _ea_rooms_host_path()
    rooms = []
    if not path or not os.path.isfile(path):
        return rooms
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                parts = line.split("|")
                if len(parts) >= 5:
                    rooms.append({"extension": parts[0], "name": parts[1], "members": parts[2],
                                  "timeout": parts[3], "type": parts[4]})
    return rooms


def ea_create_room(extension, name, room_type="ring", timeout="60", members=None):
    path = _ea_rooms_host_path()
    if not path:
        return False, "No Asterisk install detected on this box"
    extension = str(extension).strip()
    name = (name or "").strip()
    if not EA_EXT_RE.match(extension):
        return False, "Invalid extension"
    if not name:
        return False, "Name required"
    # Same pattern write_group() requires — a Ring Group's name doubles as
    # its pstn-groups.conf mirror section name (see sync_room_group_mirror),
    # so anything not valid there would silently fail to sync the moment
    # this room gets assigned a personal number.
    if not GROUP_NAME_RE.match(name):
        return False, "Name must be 1-40 characters (letters, digits, spaces, - or _)"
    clean_members = [str(m).strip() for m in (members or []) if EA_EXT_RE.match(str(m).strip())]

    current = ""
    if os.path.isfile(path):
        with open(path) as f:
            current = f.read()
    else:
        current = "# Format: ext|name|members|timeout|type(ring/page)\n"

    for line in current.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and line.split("|")[0] == extension:
            return False, "Room extension already exists"

    if not current.endswith("\n"):
        current += "\n"
    new_content = current + "%s|%s|%s|%s|%s\n" % (extension, name, ",".join(clean_members), timeout, room_type)
    ok, err = ea_docker_write(EA_ROOMS_CONTAINER_PATH, new_content)
    if not ok:
        return False, err
    ea_rebuild_dialplan()
    sync_room_group_mirror(name, clean_members)
    # Normally a no-op for a brand-new group (nothing owns this name yet),
    # but defensive against a same-named room having existed before and
    # left a personal-DID assignment behind.
    _reconcile_group_cid_members(clean_members, old_did=None, new_did=_group_current_did(name))
    return True, "Room created"


def ea_delete_room(extension):
    path = _ea_rooms_host_path()
    if not path or not os.path.isfile(path):
        return False, "Rooms file not found"
    old_room = next((r for r in ea_list_rooms() if r["extension"] == extension), None)
    with open(path) as f:
        lines = f.readlines()
    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and stripped.split("|")[0] == extension:
            found = True
            continue
        new_lines.append(line)
    if not found:
        return False, "Room not found"
    ok, err = ea_docker_write(EA_ROOMS_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_rebuild_dialplan()
    if old_room:
        # Unassign the DID first (this also clears it from every member's
        # personal_did — see remove_personal_did's own comment), THEN
        # clean up the pstn-groups.conf mirror — a deleted group can't
        # meaningfully still own a personal number.
        old_did = _group_current_did(old_room["name"])
        if old_did:
            remove_personal_did(old_did)
        sync_room_group_mirror(None, [], old_name=old_room["name"])
    return True, "Room deleted"


def ea_rename_room(extension, new_name):
    path = _ea_rooms_host_path()
    if not path or not os.path.isfile(path):
        return False, "Rooms file not found"
    new_name = (new_name or "").strip()
    if not new_name:
        return False, "Name required"
    if not GROUP_NAME_RE.match(new_name):
        return False, "Name must be 1-40 characters (letters, digits, spaces, - or _)"
    old_room = next((r for r in ea_list_rooms() if r["extension"] == extension), None)
    with open(path) as f:
        lines = f.readlines()
    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            parts = stripped.split("|")
            if len(parts) >= 5 and parts[0] == extension:
                parts[1] = new_name
                new_lines.append("|".join(parts) + "\n")
                found = True
                continue
        new_lines.append(line)
    if not found:
        return False, "Room not found"
    ok, err = ea_docker_write(EA_ROOMS_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_rebuild_dialplan()
    old_members = [m for m in (old_room["members"] if old_room else "").split(",") if m]
    old_did = _group_current_did(old_room["name"]) if old_room else None
    sync_room_group_mirror(new_name, old_members, old_name=old_room["name"] if old_room else None)
    if old_did:
        # Membership and the DID itself haven't changed, just the label —
        # repoint pstn-personal-dids.conf's owner at the new name instead of
        # leaving it referencing one that no longer has a mirror section
        # (which would silently break that DID's inbound ring-fan-out).
        dids_cp = _read_personal_dids_cp()
        if dids_cp.has_section(old_did):
            dids_cp.set(old_did, "owner", "@" + new_name)
            _write_ini_cp(_personal_dids_path(), PERSONAL_DIDS_HEADER, dids_cp)
    return True, "Room renamed"


def ea_update_room_settings(extension, room_type, timeout):
    """Changes an existing room's type (ring/page) and timeout without
    touching its name, members, or any DID assignment — the one thing
    creating or renaming a room couldn't already do: change these two
    fields after the room exists, rather than only at creation time."""
    path = _ea_rooms_host_path()
    if not path or not os.path.isfile(path):
        return False, "Rooms file not found"
    room_type = (room_type or "").strip()
    if room_type not in ("ring", "page"):
        return False, "Type must be 'ring' or 'page'"
    timeout = str(timeout or "").strip()
    if not timeout.isdigit() or int(timeout) <= 0:
        return False, "Timeout must be a positive number of seconds"
    with open(path) as f:
        lines = f.readlines()
    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            parts = stripped.split("|")
            if len(parts) >= 5 and parts[0] == extension:
                parts[3] = timeout
                parts[4] = room_type
                new_lines.append("|".join(parts) + "\n")
                found = True
                continue
        new_lines.append(line)
    if not found:
        return False, "Room not found"
    ok, err = ea_docker_write(EA_ROOMS_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_rebuild_dialplan()
    return True, "Room settings updated"


def _ea_update_room_members(extension, new_members):
    path = _ea_rooms_host_path()
    if not path or not os.path.isfile(path):
        return False, "Rooms file not found"
    old_room = next((r for r in ea_list_rooms() if r["extension"] == extension), None)
    room_name = old_room["name"] if old_room else None
    old_members = set(m for m in (old_room["members"] if old_room else "").split(",") if m)
    with open(path) as f:
        lines = f.readlines()
    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            parts = stripped.split("|")
            if len(parts) >= 5 and parts[0] == extension:
                parts[2] = new_members
                new_lines.append("|".join(parts) + "\n")
                found = True
                continue
        new_lines.append(line)
    if not found:
        return False, "Room not found"
    ok, err = ea_docker_write(EA_ROOMS_CONTAINER_PATH, "".join(new_lines))
    if not ok:
        return False, err
    ea_rebuild_dialplan()
    if room_name:
        new_members_set = set(m for m in new_members.split(",") if m)
        sync_room_group_mirror(room_name, list(new_members_set))
        current_did = _group_current_did(room_name)
        if current_did:
            _reconcile_group_cid_members(old_members - new_members_set, old_did=current_did, new_did=None)
            _reconcile_group_cid_members(new_members_set - old_members, old_did=None, new_did=current_did)
    return True, "Room members updated"


def ea_add_room_member(room_ext, device_ext):
    for room in ea_list_rooms():
        if room["extension"] == room_ext:
            members = [m for m in room["members"].split(",") if m]
            if device_ext in members:
                return False, "Device already in room"
            members.append(device_ext)
            return _ea_update_room_members(room_ext, ",".join(members))
    return False, "Room not found"


def ea_remove_room_member(room_ext, device_ext):
    for room in ea_list_rooms():
        if room["extension"] == room_ext:
            members = [m for m in room["members"].split(",") if m]
            if device_ext not in members:
                return False, "Device not in room"
            members.remove(device_ext)
            return _ea_update_room_members(room_ext, ",".join(members))
    return False, "Room not found"


INDEX_HTML = """<!doctype html>
<html><head><meta charset="utf-8">
<title>Security Dashboard</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  /* ── Design tokens ────────────────────────────────────────────────────────
     One scale for spacing/radius/colour so cards, tables and controls line up
     without per-element nudging. Dark-only on purpose: this is an admin panel
     that lives next to terminal windows. */
  :root {
    --bg: #0c0e13;
    --surface: #14171f;
    --surface-2: #1b1f29;
    --line: #262b37;
    --line-soft: #1e222c;
    --text: #e8eaed;
    --text-dim: #9aa4b2;
    --text-faint: #6b7484;
    --accent: #4f8cff;
    --accent-dim: #1e3a6b;
    --ok: #46c07a;
    --warn: #f5b342;
    --danger: #ff6b6b;
    --radius: 10px;
    --radius-sm: 6px;
    --sp-1: 0.25rem; --sp-2: 0.5rem; --sp-3: 0.75rem; --sp-4: 1rem; --sp-6: 1.5rem;
  }
  * { box-sizing: border-box; }
  body {
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif;
    margin: 0; background: var(--bg); color: var(--text);
    font-size: 15px; line-height: 1.5; -webkit-font-smoothing: antialiased;
  }

  /* ── Header / nav ─────────────────────────────────────────────────────── */
  header {
    position: sticky; top: 0; z-index: 30;
    padding: 0 var(--sp-6); background: rgba(20,23,31,0.85);
    backdrop-filter: blur(8px); border-bottom: 1px solid var(--line);
    display: flex; align-items: center; gap: var(--sp-6); flex-wrap: wrap;
  }
  header h1 { font-size: 0.95rem; margin: 0; padding: var(--sp-4) 0; font-weight: 650; letter-spacing: -0.01em; }
  nav { display: flex; gap: var(--sp-1); }
  nav button {
    background: none; border: none; color: var(--text-dim); font: inherit;
    padding: var(--sp-4) var(--sp-3); cursor: pointer;
    border-bottom: 2px solid transparent; margin-bottom: -1px;
  }
  nav button:hover { color: var(--text); }
  nav button.active { color: var(--text); border-bottom-color: var(--accent); }
  main { padding: var(--sp-6); max-width: 1180px; margin: 0 auto; }

  /* ── Cards ────────────────────────────────────────────────────────────── */
  .card {
    background: var(--surface); border: 1px solid var(--line);
    border-radius: var(--radius); margin-bottom: var(--sp-4);
  }
  .card > .card-head {
    display: flex; align-items: center; gap: var(--sp-3);
    padding: var(--sp-4) var(--sp-4) 0;
  }
  .card > .card-head h3 { font-size: 0.95rem; margin: 0; flex: 1; font-weight: 650; }
  .card > .card-body { padding: var(--sp-4); }

  /* Secondary sections collapse by default so the tab opens on the one table
     that matters. <details> keeps this keyboard-accessible with no JS. */
  details.card > summary {
    padding: var(--sp-4); cursor: pointer; list-style: none;
    display: flex; align-items: center; gap: var(--sp-2);
    font-size: 0.95rem; font-weight: 650; user-select: none;
  }
  details.card > summary::-webkit-details-marker { display: none; }
  details.card > summary::before {
    content: "›"; color: var(--text-faint); font-size: 1.2em; line-height: 1;
    transition: transform 0.15s ease; display: inline-block;
  }
  details.card[open] > summary::before { transform: rotate(90deg); }
  details.card > summary:hover { color: #fff; }
  details.card > summary .count {
    color: var(--text-faint); font-weight: 400; font-size: 0.85rem;
  }
  details.card > .card-body { padding: 0 var(--sp-4) var(--sp-4); }

  /* Groups cards that belong to the same underlying system (Easy Asterisk
     device provisioning vs. PSTN-trunk permissions) under one label, so the
     page itself explains why e.g. "Rooms" and "Groups" both exist instead
     of reading as duplicates. */
  .section-head {
    margin: var(--sp-6) 0 var(--sp-2); padding-top: var(--sp-4);
    border-top: 1px solid var(--line);
    color: var(--text-faint); font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.04em;
  }

  /* Inline "what does this mean" disclosure — keeps the explanation one click
     away instead of pushing every control below three paragraphs of prose. */
  details.help { margin: 0 0 var(--sp-3); }
  details.help > summary {
    cursor: pointer; color: var(--text-dim); font-size: 0.85rem;
    list-style: none; display: inline-flex; align-items: center; gap: var(--sp-1);
  }
  details.help > summary::-webkit-details-marker { display: none; }
  details.help > summary::before { content: "ⓘ"; opacity: 0.7; }
  details.help > summary:hover { color: var(--text); }
  details.help[open] > summary { margin-bottom: var(--sp-2); }
  details.help p { margin: 0 0 var(--sp-2); }

  /* ── Tables ───────────────────────────────────────────────────────────── */
  /* Wrapper, not the table, owns horizontal overflow — a nine-column table on
     a phone scrolls inside the card instead of blowing out the page. */
  .table-wrap { overflow-x: auto; margin: 0 calc(-1 * var(--sp-4)); padding: 0 var(--sp-4); }
  table { width: 100%; border-collapse: collapse; font-size: 0.875rem; }
  th, td { text-align: left; padding: var(--sp-2) var(--sp-3); border-bottom: 1px solid var(--line-soft); }
  th {
    color: var(--text-faint); font-weight: 600; font-size: 0.75rem;
    text-transform: uppercase; letter-spacing: 0.04em; white-space: nowrap;
    position: sticky; top: 0; background: var(--surface); z-index: 1;
  }
  tbody tr:last-child td { border-bottom: none; }
  tbody tr:hover { background: rgba(255,255,255,0.015); }
  th.sortable { cursor: pointer; user-select: none; }
  th.sortable:hover { color: var(--text); }
  th.sortable .arrow { opacity: 0.6; font-size: 0.85em; margin-left: var(--sp-1); }
  td.actions { text-align: right; white-space: nowrap; }

  /* A row with unsaved edits is marked, not just remembered — the old design
     had eight Save buttons and no way to see which rows you'd touched. */
  tr.dirty > td { background: rgba(79,140,255,0.07); }
  tr.dirty > td:first-child { box-shadow: inset 2px 0 0 var(--accent); }

  /* ── Status pill ──────────────────────────────────────────────────────── */
  .pill {
    display: inline-flex; align-items: center; gap: var(--sp-1);
    font-size: 0.8rem; color: var(--text-dim); white-space: nowrap;
  }
  .pill::before {
    content: ""; width: 7px; height: 7px; border-radius: 50%;
    background: var(--text-faint); flex: none;
  }
  .pill.online { color: var(--ok); }
  .pill.online::before { background: var(--ok); box-shadow: 0 0 0 3px rgba(70,192,122,0.15); }
  .pill.offline::before { background: var(--text-faint); }

  /* ── Controls ─────────────────────────────────────────────────────────── */
  input[type=text], select {
    background: var(--bg); border: 1px solid var(--line); color: var(--text);
    padding: 0.35rem 0.55rem; border-radius: var(--radius-sm);
    font: inherit; font-size: 0.875rem; max-width: 100%;
  }
  input[type=text]:focus, select:focus, button:focus-visible, summary:focus-visible {
    outline: 2px solid var(--accent); outline-offset: 1px;
  }
  input[type=text]:disabled { opacity: 0.4; cursor: not-allowed; }
  input[type=checkbox] { accent-color: var(--accent); width: 16px; height: 16px; cursor: pointer; }

  /* Name cell reads as text until you focus it — editing in place beats a
     Rename button that opens a browser prompt() dialog. */
  input.inline-edit {
    background: transparent; border: 1px solid transparent; color: var(--text);
    padding: 0.2rem 0.35rem; width: 100%; min-width: 7rem;
  }
  input.inline-edit:hover:not(:disabled) { border-color: var(--line); }
  input.inline-edit:focus { background: var(--bg); border-color: var(--accent); }
  input.inline-edit:disabled { opacity: 1; }

  button.action, button.primary, button.danger {
    font: inherit; font-size: 0.85rem; border-radius: var(--radius-sm);
    padding: 0.35rem 0.7rem; cursor: pointer; white-space: nowrap;
    border: 1px solid var(--line); background: var(--surface-2); color: var(--text);
  }
  button.action:hover { background: #232834; border-color: #333a49; }
  button.primary { background: var(--accent); border-color: var(--accent); color: #fff; font-weight: 600; }
  button.primary:hover { background: #3f7bee; }
  button.danger { color: var(--danger); }
  button.danger:hover { background: rgba(255,107,107,0.1); border-color: rgba(255,107,107,0.4); }
  button:disabled { opacity: 0.45; cursor: not-allowed; }
  button.icon {
    background: none; border: none; color: var(--text-faint); cursor: pointer;
    padding: 0.2rem 0.4rem; border-radius: var(--radius-sm); font-size: 1rem; line-height: 1;
  }
  button.icon:hover { color: var(--danger); background: rgba(255,107,107,0.1); }

  .row { display: flex; gap: var(--sp-2); align-items: center; flex-wrap: wrap; }
  .chip-row { display: flex; flex-wrap: wrap; gap: var(--sp-2) var(--sp-4); }
  .chip-row label { white-space: nowrap; font-size: 0.85rem; color: var(--text-dim); display: inline-flex; align-items: center; gap: var(--sp-1); }

  /* Add-extension form starts hidden — the table is what you came for. */
  .add-form {
    display: none; gap: var(--sp-2); flex-wrap: wrap; align-items: center;
    padding: var(--sp-3); margin-bottom: var(--sp-3);
    background: var(--surface-2); border: 1px solid var(--line); border-radius: var(--radius-sm);
  }
  .add-form.open { display: flex; }
  /* Transport and auto-answer are answers most people never need to change;
     they stay out of the way until asked for. */
  .add-advanced { display: none; width: 100%; gap: var(--sp-2); align-items: center; flex-wrap: wrap; }
  .add-advanced.open { display: flex; }
  /* Connection details expand under their own row, so they stay next to the
     extension being asked about however far down the table it is. */
  tr.detail-row > td { background: rgba(79,140,255,0.06); padding: 0; }
  .detail-panel {
    border-left: 3px solid var(--accent); padding: var(--sp-3) var(--sp-4);
  }
  .detail-panel table { font-size: 0.85rem; }
  .detail-panel th { text-transform: none; letter-spacing: 0; position: static; }
  .detail-panel td, .detail-panel th { border-bottom: none; padding: 0.2rem 0.6rem 0.2rem 0; }
  .detail-panel code { background: rgba(0,0,0,0.35); padding: 0.1rem 0.35rem; border-radius: 4px; user-select: all; }
  button.link {
    background: none; border: none; color: var(--accent); font: inherit;
    font-size: 0.85rem; cursor: pointer; padding: 0.2rem 0;
    text-decoration: underline dotted; text-underline-offset: 3px;
  }
  button.link:hover { color: #7aa9ff; }

  /* ── Save bar ─────────────────────────────────────────────────────────── */
  /* One commit point for the whole table, pinned to the bottom of the viewport
     so it stays reachable however far you've scrolled. */
  #ext-savebar {
    position: sticky; bottom: var(--sp-4); z-index: 20;
    display: none; align-items: center; gap: var(--sp-3);
    margin-top: var(--sp-3); padding: var(--sp-3) var(--sp-4);
    background: var(--surface-2); border: 1px solid var(--accent-dim);
    border-radius: var(--radius); box-shadow: 0 8px 24px rgba(0,0,0,0.45);
  }
  #ext-savebar.show { display: flex; }
  #ext-savebar .grow { flex: 1; font-size: 0.875rem; }

  /* ── Toasts ───────────────────────────────────────────────────────────── */
  #toasts {
    position: fixed; right: var(--sp-4); bottom: var(--sp-4); z-index: 60;
    display: flex; flex-direction: column; gap: var(--sp-2); max-width: min(28rem, calc(100vw - 2rem));
  }
  .toast {
    background: var(--surface-2); border: 1px solid var(--line); border-left: 3px solid var(--accent);
    border-radius: var(--radius-sm); padding: var(--sp-2) var(--sp-3);
    font-size: 0.85rem; box-shadow: 0 8px 24px rgba(0,0,0,0.45);
    animation: toast-in 0.15s ease;
  }
  .toast.err { border-left-color: var(--danger); }
  .toast.ok { border-left-color: var(--ok); }
  @keyframes toast-in { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: none; } }

  /* The one-time device password must not auto-dismiss like a toast does. */
  .callout {
    display: none; align-items: flex-start; gap: var(--sp-3);
    margin-bottom: var(--sp-3); padding: var(--sp-3);
    background: rgba(70,192,122,0.08); border: 1px solid rgba(70,192,122,0.35);
    border-radius: var(--radius-sm); font-size: 0.875rem;
  }
  .callout.show { display: flex; }
  .callout code { background: rgba(0,0,0,0.35); padding: 0.1rem 0.35rem; border-radius: 4px; user-select: all; }

  /* ── Misc ─────────────────────────────────────────────────────────────── */
  .banner { border-left: 3px solid var(--warn); }
  .sev-Error { color: var(--danger); }
  .sev-Warning { color: var(--warn); }
  .sev-Informational { color: var(--ok); }
  .muted { color: var(--text-dim); font-size: 0.85rem; }
  .empty { color: var(--text-faint); font-style: italic; }
  a { color: var(--accent); }
  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 0.85em; }
  #msg { margin-top: var(--sp-2); font-size: 0.85rem; }

  /* Capability gating for the Extensions tab. Everything that needs the Easy
     Asterisk container (device/room writes) is .ea-only; everything
     that needs a PSTN trunk dialplan is .pstn-only. Both classes start ON the
     body so nothing flashes before /api/ea-status and /api/pstn-status answer,
     and they're removed once those confirm. Marking cells rather than juggling
     column indices keeps the one extensions table honest as columns come and
     go. */
  body.no-ea .ea-only { display: none !important; }
  body.no-pstn .pstn-only { display: none !important; }

  @media (max-width: 640px) {
    main { padding: var(--sp-3); }
    header { padding: 0 var(--sp-3); gap: var(--sp-3); }
    .table-wrap { margin: 0 calc(-1 * var(--sp-3)); padding: 0 var(--sp-3); }
  }
</style>
</head>
<body class="no-ea no-pstn">
<header>
  <h1>Security Dashboard</h1>
  <nav>
    <button class="tab-btn" data-tab="security">Security Log</button>
    <button class="tab-btn" data-tab="comms">Calls &amp; Texts</button>
    <button class="tab-btn active" data-tab="extensions">Extensions</button>
    <button class="tab-btn" data-tab="voicemail">Voicemail</button>
    <button class="tab-btn" id="crowdsec-tab-btn" data-tab="crowdsec" style="display:none">CrowdSec</button>
  </nav>
</header>
<main>
  <div id="tab-security" style="display:none">
    <div class="card">
      <div class="card-body">
        <p class="muted" style="margin-top:0">Recent Asterisk SIP security events, newest first. Errors/warnings are real auth failures; informational lines are normal registration traffic.</p>
        <div class="table-wrap">
          <table id="sec-table"><thead><tr>
            <th class="sortable" data-sort="timestamp">Time</th>
            <th class="sortable" data-sort="event">Event</th>
            <th class="sortable" data-sort="account">Account</th>
            <th class="sortable" data-sort="remote">Remote</th>
            <th class="sortable" data-sort="severity">Severity</th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </div>
  </div>
  <div id="tab-comms" style="display:none">
    <div class="card">
      <div class="card-head"><h3>PSTN Calls</h3></div>
      <div class="card-body">
        <p class="muted" style="margin-top:0">Calls placed or received through the PSTN trunk, newest first. Numbers and duration only — no recordings, no call content. Empty until <code>pstn-trunk</code> is installed and has logged at least one call.</p>
        <div class="table-wrap">
          <table id="calls-table"><thead><tr>
            <th class="sortable" data-sort="timestamp">Time</th>
            <th class="sortable" data-sort="direction">Direction</th>
            <th class="sortable" data-sort="from">From</th>
            <th class="sortable" data-sort="to">To</th>
            <th class="sortable" data-sort="duration">Duration</th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </div>
    <div class="card">
      <div class="card-head"><h3>Texts</h3></div>
      <div class="card-body">
        <p class="muted" style="margin-top:0">Internal SIP messages between extensions, and SMS-over-SIP messages arriving on the trunk DID (Anveo-specific, diagnostic until routing is confirmed against real traffic — see PSTN Trunk docs). Metadata only (sender/recipient/time) — message bodies are never logged.</p>
        <div class="table-wrap">
          <table id="texts-table"><thead><tr>
            <th class="sortable" data-sort="timestamp">Time</th>
            <th class="sortable" data-sort="type">Type</th>
            <th class="sortable" data-sort="direction">Direction</th>
            <th class="sortable" data-sort="from">From</th>
            <th class="sortable" data-sort="to">To</th>
            <th class="sortable" data-sort="status">Status</th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </div>
  </div>
  <div id="tab-crowdsec" style="display:none">
    <div class="card">
      <div class="card-head"><h3>Active bans</h3></div>
      <div class="card-body">
        <div class="table-wrap">
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
      </div>
    </div>
    <div class="card">
      <div class="card-head"><h3>Asterisk brute-force ASN exemptions</h3></div>
      <div class="card-body">
        <p class="muted" style="margin-top:0">Carrier ASNs exempted from the Asterisk brute-force scenarios only — SSH/web/geo protection is unaffected. See CLAUDE.md / services/crowdsec.sh for background.</p>
        <div class="row" style="margin-bottom:var(--sp-3)">
          <input type="text" id="asn-input" placeholder="e.g. 21928, 14593" style="width:16rem">
          <button class="action" id="asn-save">Save</button>
        </div>
        <div class="table-wrap">
          <table id="asn-table"><thead><tr><th>ASN</th><th>Carrier</th><th></th></tr></thead><tbody></tbody></table>
        </div>
        <div id="msg"></div>
      </div>
    </div>
  </div>
  <div id="tab-extensions">
    <div class="card pstn-only banner" id="pstn-restart-banner" style="display:none">
      <div class="card-body">
        <b>Changes may not be live yet.</b>
        <p class="muted" style="margin:var(--sp-1) 0 var(--sp-2)">
          Edits are written to disk immediately, but Asterisk doesn't always pick them up without a restart. Saving never disturbs an active call by itself — but restarting does, so it isn't automatic; click below (or answer "Restart now?" right after a save) once it's a good time.
        </p>
        <button class="action" id="pstn-restart-btn">Commit changes (restart Asterisk)</button>
        <span id="pstn-restart-msg" class="muted" style="margin-left:var(--sp-2)"></span>
      </div>
    </div>

    <details class="card" id="card-extensions" open>
      <summary>Extensions <span class="count muted" id="ext-count"></span></summary>
      <div class="card-body">
        <div class="row" style="justify-content:flex-end; margin-bottom:var(--sp-2)">
          <button class="action ea-only" id="ext-add-toggle">+ Add extension</button>
        </div>
        <div class="callout" id="ext-password-callout">
          <div class="grow" id="ext-password-text" style="flex:1"></div>
          <button class="icon" id="ext-password-dismiss" title="Dismiss">&times;</button>
        </div>

        <div class="add-form ea-only" id="ext-add-form">
          <input type="text" id="ea-dev-name" placeholder="Name, e.g. Front Desk" style="width:11rem">
          <input type="text" id="ea-dev-ext" placeholder="Extension, e.g. 202" style="width:9rem">
          <label class="muted" style="white-space:nowrap"><input type="checkbox" id="ea-dev-mobile"> Mobile/cellular device</label>
          <button class="primary" id="ea-dev-save">Add</button>
          <button class="action" id="ext-add-cancel">Cancel</button>
          <button class="link" id="ext-add-advanced-toggle" type="button">Advanced…</button>
          <!-- TLS is listed first so it is the selected default before any
               script runs. A phone registering over TLS against a UDP-only
               endpoint just times out with nothing logged, which is the
               single most confusing way for a new extension to fail, so the
               safe transport is the one you get without choosing. -->
          <div class="add-advanced" id="ext-add-advanced">
            <select id="ea-dev-conn">
              <option value="fqdn">Remote/FQDN (TLS 5061) — default</option>
              <option value="lan">LAN only (UDP 5060)</option>
            </select>
            <select id="ea-dev-aa">
              <option value="no">Auto-answer: no</option>
              <option value="yes">Auto-answer: yes</option>
            </select>
            <span class="muted" id="ext-add-conn-hint"></span>
          </div>
        </div>

        <details class="help">
          <summary>What these columns mean</summary>
          <p class="muted"><b>Name</b> is editable in place — click, type, then Save. Adding an extension generates a random password and reloads PJSIP + rebuilds the dialplan automatically; the password is shown once, at the top of this card. <b>Mobile</b> tags a device as a cellular/off-LAN softphone (like a phone app over wifi/data) so Asterisk sends RTP NAT-keepalive traffic to keep it reachable — leave it off for anything on the LAN.</p>
            <p class="muted pstn-only"><b>PSTN</b> sets how the outside phone network reaches this extension, and the <b>Whitelist</b> beside it is the one list of numbers that mode applies to:</p>
          <ul class="muted pstn-only" style="margin:0 0 var(--sp-2); padding-left:1.2rem">
            <li><b>full</b> — dial anyone, anyone can call. No whitelist.</li>
            <li><b>restricted (both ways)</b> — the whitelist applies to outgoing <i>and</i> incoming.</li>
            <li><b>restricted incoming</b> — dials anywhere; only whitelisted numbers can call in.</li>
            <li><b>restricted outgoing</b> — anyone can call in; may only dial the whitelist.</li>
            <li><b>internal</b> — no PSTN at all, either direction.</li>
          </ul>
          <p class="muted pstn-only">Internal extension-to-extension calling and ring groups are never gated by any of this. Changes are usually live on the next call; if one doesn't seem to take effect, use "Commit changes" above.</p>
          <p class="muted"><b>Messaging</b> — Asterisk's native SIP texting between extensions: no carrier SMS, no PSTN, no cost, and no dependency on a PSTN trunk at all (which is why this column is here even with no trunk installed). Independent of the calling tier. Enforced live by a dedicated dialplan context — see <code>services/asterisk.sh</code>'s README, including its caveat that the sender-extraction logic still needs real-traffic confirmation. If this box predates that wiring, rerun <code>sudo ./setup.sh asterisk</code>.</p>
          <p class="muted"><b>Voicemail</b> — enables a mailbox for the extension. Dial <code>*97</code> to check your own messages, or <code>*98&lt;ext&gt;</code> to leave one directly without ringing it. A 4-digit PIN is generated the first time you enable it (shown in this column) and kept even if you later disable and re-enable voicemail. Also independent of the calling tier and PSTN trunk. Play messages back on the <b>Voicemail</b> tab. If this box predates voicemail support, rerun <code>sudo ./setup.sh asterisk</code>.</p>
        </details>

        <div class="table-wrap">
          <table id="ext-table"><thead><tr>
            <th class="sortable" data-sort="ext">Ext</th>
            <th class="sortable" data-sort="name">Name</th>
            <th class="ea-only">Mobile</th>
            <th class="sortable ea-only" data-sort="status">Status</th>
            <th class="ea-only">Transport</th>
            <th class="sortable pstn-only" data-sort="restrict">PSTN</th>
            <th class="pstn-only">Whitelist</th>
            <th class="sortable" data-sort="messaging">Messaging</th>
            <th class="sortable" data-sort="voicemail">Voicemail</th>
            <th></th>
          </tr></thead><tbody></tbody></table>
        </div>

        <div id="ext-savebar">
          <span class="grow" id="ext-dirty-label"></span>
          <button class="action" id="ext-discard">Discard</button>
          <button class="primary" id="ext-save-all">Save changes</button>
        </div>
      </div>
    </details>

    <div class="section-head ea-only">Easy Asterisk device setup</div>

    <details class="card ea-only" id="card-rooms">
      <summary>Ring Groups <span class="count" id="room-count"></span></summary>
      <div class="card-body">
        <p class="muted">Pick extensions, give them a name, and they ring (or page/auto-answer) together as one dialable extension — and can optionally be assigned a personal number below, so an inbound call to that number rings every current member.</p>
        <details class="help">
          <summary>Ring vs Page, and mixing auto-answer devices in one group</summary>
          <p class="muted"><b>Ring</b> dials every member at once — first to answer gets the call, everyone else stops ringing. <b>Page</b> tells Asterisk to signal auto-answer to every member via SIP headers, for devices that honor it, turning the same simultaneous dial into a one-way intercom-style broadcast instead.</p>
          <p class="muted">You don't need <b>Page</b> just to mix an auto-answering device with normally-ringing phones in the same group, though — auto-answer is really a property of the device's own SIP client configuration, not something Asterisk enforces per member. Confirmed against baresip's own source: it decides purely from its account's local <code>answermode</code> setting and never looks at any auto-answer signal on the incoming call, so a device configured to auto-answer (e.g. a dedicated intercom/kiosk running <code>baresip</code> in Answer Mode: Auto) picks up <i>everything</i> routed to it instantly and unconditionally, while ordinary phones in the same plain <b>Ring</b> group just keep ringing until a person answers — no extra setting needed here for that mix.</p>
          <p class="muted">For a dedicated always-on auto-answer device (a wall-mounted intercom, a paging station), Easy Asterisk — the vendor project this installer builds on — has a built-in <code>baresip</code>-based kiosk client for exactly that. It installs on a separate small Linux machine (an old PC, a Raspberry Pi), not this Asterisk server itself: <a href="/download/kiosk-client-installer.sh" download>download the installer script</a>, then see <code>docs/kiosk-paging-setup.md</code> in this repo for the full walkthrough.</p>
          <p class="muted">For a phone or tablet running Sipnetic instead, each extension's own detail panel below (Extensions tab → click a row → "Sipnetic QR code") can generate a scan-to-configure code — no dedicated kiosk hardware needed for that one.</p>
        </details>
        <div class="row" style="margin-bottom:var(--sp-2)">
          <input type="text" id="ea-room-ext" placeholder="Extension, e.g. 500" style="width:9rem">
          <input type="text" id="ea-room-name" placeholder="Name, e.g. Sales" style="width:10rem">
          <select id="ea-room-type">
            <option value="ring">Ring (members answer normally)</option>
            <option value="page">Page (auto-answer/intercom)</option>
          </select>
          <input type="text" id="ea-room-timeout" placeholder="Timeout (s)" value="60" style="width:7rem">
          <button class="action" id="ea-room-save">Add ring group</button>
        </div>
        <div class="muted" style="margin-bottom:var(--sp-1)">Members:</div>
        <div id="ea-room-members" class="chip-row" style="margin-bottom:var(--sp-3)"></div>
        <div class="table-wrap">
          <table id="ea-room-table"><thead><tr>
            <th class="sortable" data-sort="extension">Ext</th>
            <th class="sortable" data-sort="name">Name</th>
            <th>Members</th>
            <th>Timeout</th>
            <th>Type</th>
            <th class="pstn-only">Personal number</th>
            <th></th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </details>

    <div class="section-head">Personal numbers (PSTN permissions)</div>

    <details class="card pstn-only" id="card-dids">
      <summary>Personal numbers <span class="count" id="pd-count"></span></summary>
      <div class="card-body">
        <details class="help">
          <summary>How personal numbers route</summary>
          <p class="muted">Multiple DIDs can share this one trunk. Assigning a DID to an extension routes inbound calls to that DID straight to its owner (still gated by the owner's own tier/approved-numbers above — no ring-group fallback), and makes that extension's outbound calls show this DID as Caller-ID instead of the shared trunk DID.</p>
          <p class="muted">You can also assign a DID to a <b>Ring Group</b> above instead of a single extension — every current member whose own tier/approved-numbers authorize the caller rings, checked fresh against the group's current membership on every call. A Ring Group has no single extension to hang the outbound Caller-ID override on, so that part only applies to single-extension assignments. The shared DID/ring-group keeps working regardless.</p>
          <p class="muted">Reassigning a DID's owner has been confirmed to sometimes need "Commit changes" (at the top) before Asterisk actually uses the new owner.</p>
        </details>
        <div class="row" style="margin-bottom:var(--sp-3)">
          <input type="text" id="pd-did" placeholder="DID, e.g. 5551234567 (10 digits)" style="width:14rem">
          <select id="pd-owner"></select>
          <button class="action" id="pd-save">Assign</button>
        </div>
        <div class="table-wrap">
          <table id="pd-table"><thead><tr>
            <th class="sortable" data-sort="did">DID</th>
            <th class="sortable" data-sort="owner">Owner</th>
            <th></th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </details>
  </div>

  <div id="tab-voicemail" style="display:none">
    <div class="card">
      <div class="card-body">
        <p class="muted" style="margin-top:0">Messages left across every mailbox, newest first. Enable voicemail for an extension on the <b>Extensions</b> tab — that also generates the PIN shown there for checking messages by phone (<code>*97</code>). Read-only here — to delete a message, dial in with the PIN (<code>*97</code>) and delete it from the phone menu.</p>
        <div class="table-wrap">
          <table id="vm-table"><thead><tr>
            <th class="sortable" data-sort="origtime">Time</th>
            <th class="sortable" data-sort="ext">Mailbox</th>
            <th class="sortable" data-sort="callerid">Caller ID</th>
            <th class="sortable" data-sort="duration">Duration</th>
            <th>Play</th>
          </tr></thead><tbody></tbody></table>
        </div>
      </div>
    </div>
  </div>
</main>
<div id="toasts"></div>
<script>
// Embedded verbatim (license header preserved below) for the Sipnetic
// QR-provisioning feature -- self-contained, no CDN dependency, same
// reasoning as everything else on this page: davidshimjs/qrcodejs
// (MIT), wrapping Kazuhiko Arase's original QRCode for JavaScript.
/**
 * @fileoverview
 * - Using the 'QRCode for Javascript library'
 * - Fixed dataset of 'QRCode for Javascript library' for support full-spec.
 * - this library has no dependencies.
 * 
 * @author davidshimjs
 * @see <a href="http://www.d-project.com/" target="_blank">http://www.d-project.com/</a>
 * @see <a href="http://jeromeetienne.github.com/jquery-qrcode/" target="_blank">http://jeromeetienne.github.com/jquery-qrcode/</a>
 */
var QRCode;

(function () {
	//---------------------------------------------------------------------
	// QRCode for JavaScript
	//
	// Copyright (c) 2009 Kazuhiko Arase
	//
	// URL: http://www.d-project.com/
	//
	// Licensed under the MIT license:
	//   http://www.opensource.org/licenses/mit-license.php
	//
	// The word "QR Code" is registered trademark of 
	// DENSO WAVE INCORPORATED
	//   http://www.denso-wave.com/qrcode/faqpatent-e.html
	//
	//---------------------------------------------------------------------
	function QR8bitByte(data) {
		this.mode = QRMode.MODE_8BIT_BYTE;
		this.data = data;
		this.parsedData = [];

		// Added to support UTF-8 Characters
		for (var i = 0, l = this.data.length; i < l; i++) {
			var byteArray = [];
			var code = this.data.charCodeAt(i);

			if (code > 0x10000) {
				byteArray[0] = 0xF0 | ((code & 0x1C0000) >>> 18);
				byteArray[1] = 0x80 | ((code & 0x3F000) >>> 12);
				byteArray[2] = 0x80 | ((code & 0xFC0) >>> 6);
				byteArray[3] = 0x80 | (code & 0x3F);
			} else if (code > 0x800) {
				byteArray[0] = 0xE0 | ((code & 0xF000) >>> 12);
				byteArray[1] = 0x80 | ((code & 0xFC0) >>> 6);
				byteArray[2] = 0x80 | (code & 0x3F);
			} else if (code > 0x80) {
				byteArray[0] = 0xC0 | ((code & 0x7C0) >>> 6);
				byteArray[1] = 0x80 | (code & 0x3F);
			} else {
				byteArray[0] = code;
			}

			this.parsedData.push(byteArray);
		}

		this.parsedData = Array.prototype.concat.apply([], this.parsedData);

		if (this.parsedData.length != this.data.length) {
			this.parsedData.unshift(191);
			this.parsedData.unshift(187);
			this.parsedData.unshift(239);
		}
	}

	QR8bitByte.prototype = {
		getLength: function (buffer) {
			return this.parsedData.length;
		},
		write: function (buffer) {
			for (var i = 0, l = this.parsedData.length; i < l; i++) {
				buffer.put(this.parsedData[i], 8);
			}
		}
	};

	function QRCodeModel(typeNumber, errorCorrectLevel) {
		this.typeNumber = typeNumber;
		this.errorCorrectLevel = errorCorrectLevel;
		this.modules = null;
		this.moduleCount = 0;
		this.dataCache = null;
		this.dataList = [];
	}

	QRCodeModel.prototype={addData:function(data){var newData=new QR8bitByte(data);this.dataList.push(newData);this.dataCache=null;},isDark:function(row,col){if(row<0||this.moduleCount<=row||col<0||this.moduleCount<=col){throw new Error(row+","+col);}
	return this.modules[row][col];},getModuleCount:function(){return this.moduleCount;},make:function(){this.makeImpl(false,this.getBestMaskPattern());},makeImpl:function(test,maskPattern){this.moduleCount=this.typeNumber*4+17;this.modules=new Array(this.moduleCount);for(var row=0;row<this.moduleCount;row++){this.modules[row]=new Array(this.moduleCount);for(var col=0;col<this.moduleCount;col++){this.modules[row][col]=null;}}
	this.setupPositionProbePattern(0,0);this.setupPositionProbePattern(this.moduleCount-7,0);this.setupPositionProbePattern(0,this.moduleCount-7);this.setupPositionAdjustPattern();this.setupTimingPattern();this.setupTypeInfo(test,maskPattern);if(this.typeNumber>=7){this.setupTypeNumber(test);}
	if(this.dataCache==null){this.dataCache=QRCodeModel.createData(this.typeNumber,this.errorCorrectLevel,this.dataList);}
	this.mapData(this.dataCache,maskPattern);},setupPositionProbePattern:function(row,col){for(var r=-1;r<=7;r++){if(row+r<=-1||this.moduleCount<=row+r)continue;for(var c=-1;c<=7;c++){if(col+c<=-1||this.moduleCount<=col+c)continue;if((0<=r&&r<=6&&(c==0||c==6))||(0<=c&&c<=6&&(r==0||r==6))||(2<=r&&r<=4&&2<=c&&c<=4)){this.modules[row+r][col+c]=true;}else{this.modules[row+r][col+c]=false;}}}},getBestMaskPattern:function(){var minLostPoint=0;var pattern=0;for(var i=0;i<8;i++){this.makeImpl(true,i);var lostPoint=QRUtil.getLostPoint(this);if(i==0||minLostPoint>lostPoint){minLostPoint=lostPoint;pattern=i;}}
	return pattern;},createMovieClip:function(target_mc,instance_name,depth){var qr_mc=target_mc.createEmptyMovieClip(instance_name,depth);var cs=1;this.make();for(var row=0;row<this.modules.length;row++){var y=row*cs;for(var col=0;col<this.modules[row].length;col++){var x=col*cs;var dark=this.modules[row][col];if(dark){qr_mc.beginFill(0,100);qr_mc.moveTo(x,y);qr_mc.lineTo(x+cs,y);qr_mc.lineTo(x+cs,y+cs);qr_mc.lineTo(x,y+cs);qr_mc.endFill();}}}
	return qr_mc;},setupTimingPattern:function(){for(var r=8;r<this.moduleCount-8;r++){if(this.modules[r][6]!=null){continue;}
	this.modules[r][6]=(r%2==0);}
	for(var c=8;c<this.moduleCount-8;c++){if(this.modules[6][c]!=null){continue;}
	this.modules[6][c]=(c%2==0);}},setupPositionAdjustPattern:function(){var pos=QRUtil.getPatternPosition(this.typeNumber);for(var i=0;i<pos.length;i++){for(var j=0;j<pos.length;j++){var row=pos[i];var col=pos[j];if(this.modules[row][col]!=null){continue;}
	for(var r=-2;r<=2;r++){for(var c=-2;c<=2;c++){if(r==-2||r==2||c==-2||c==2||(r==0&&c==0)){this.modules[row+r][col+c]=true;}else{this.modules[row+r][col+c]=false;}}}}}},setupTypeNumber:function(test){var bits=QRUtil.getBCHTypeNumber(this.typeNumber);for(var i=0;i<18;i++){var mod=(!test&&((bits>>i)&1)==1);this.modules[Math.floor(i/3)][i%3+this.moduleCount-8-3]=mod;}
	for(var i=0;i<18;i++){var mod=(!test&&((bits>>i)&1)==1);this.modules[i%3+this.moduleCount-8-3][Math.floor(i/3)]=mod;}},setupTypeInfo:function(test,maskPattern){var data=(this.errorCorrectLevel<<3)|maskPattern;var bits=QRUtil.getBCHTypeInfo(data);for(var i=0;i<15;i++){var mod=(!test&&((bits>>i)&1)==1);if(i<6){this.modules[i][8]=mod;}else if(i<8){this.modules[i+1][8]=mod;}else{this.modules[this.moduleCount-15+i][8]=mod;}}
	for(var i=0;i<15;i++){var mod=(!test&&((bits>>i)&1)==1);if(i<8){this.modules[8][this.moduleCount-i-1]=mod;}else if(i<9){this.modules[8][15-i-1+1]=mod;}else{this.modules[8][15-i-1]=mod;}}
	this.modules[this.moduleCount-8][8]=(!test);},mapData:function(data,maskPattern){var inc=-1;var row=this.moduleCount-1;var bitIndex=7;var byteIndex=0;for(var col=this.moduleCount-1;col>0;col-=2){if(col==6)col--;while(true){for(var c=0;c<2;c++){if(this.modules[row][col-c]==null){var dark=false;if(byteIndex<data.length){dark=(((data[byteIndex]>>>bitIndex)&1)==1);}
	var mask=QRUtil.getMask(maskPattern,row,col-c);if(mask){dark=!dark;}
	this.modules[row][col-c]=dark;bitIndex--;if(bitIndex==-1){byteIndex++;bitIndex=7;}}}
	row+=inc;if(row<0||this.moduleCount<=row){row-=inc;inc=-inc;break;}}}}};QRCodeModel.PAD0=0xEC;QRCodeModel.PAD1=0x11;QRCodeModel.createData=function(typeNumber,errorCorrectLevel,dataList){var rsBlocks=QRRSBlock.getRSBlocks(typeNumber,errorCorrectLevel);var buffer=new QRBitBuffer();for(var i=0;i<dataList.length;i++){var data=dataList[i];buffer.put(data.mode,4);buffer.put(data.getLength(),QRUtil.getLengthInBits(data.mode,typeNumber));data.write(buffer);}
	var totalDataCount=0;for(var i=0;i<rsBlocks.length;i++){totalDataCount+=rsBlocks[i].dataCount;}
	if(buffer.getLengthInBits()>totalDataCount*8){throw new Error("code length overflow. ("
	+buffer.getLengthInBits()
	+">"
	+totalDataCount*8
	+")");}
	if(buffer.getLengthInBits()+4<=totalDataCount*8){buffer.put(0,4);}
	while(buffer.getLengthInBits()%8!=0){buffer.putBit(false);}
	while(true){if(buffer.getLengthInBits()>=totalDataCount*8){break;}
	buffer.put(QRCodeModel.PAD0,8);if(buffer.getLengthInBits()>=totalDataCount*8){break;}
	buffer.put(QRCodeModel.PAD1,8);}
	return QRCodeModel.createBytes(buffer,rsBlocks);};QRCodeModel.createBytes=function(buffer,rsBlocks){var offset=0;var maxDcCount=0;var maxEcCount=0;var dcdata=new Array(rsBlocks.length);var ecdata=new Array(rsBlocks.length);for(var r=0;r<rsBlocks.length;r++){var dcCount=rsBlocks[r].dataCount;var ecCount=rsBlocks[r].totalCount-dcCount;maxDcCount=Math.max(maxDcCount,dcCount);maxEcCount=Math.max(maxEcCount,ecCount);dcdata[r]=new Array(dcCount);for(var i=0;i<dcdata[r].length;i++){dcdata[r][i]=0xff&buffer.buffer[i+offset];}
	offset+=dcCount;var rsPoly=QRUtil.getErrorCorrectPolynomial(ecCount);var rawPoly=new QRPolynomial(dcdata[r],rsPoly.getLength()-1);var modPoly=rawPoly.mod(rsPoly);ecdata[r]=new Array(rsPoly.getLength()-1);for(var i=0;i<ecdata[r].length;i++){var modIndex=i+modPoly.getLength()-ecdata[r].length;ecdata[r][i]=(modIndex>=0)?modPoly.get(modIndex):0;}}
	var totalCodeCount=0;for(var i=0;i<rsBlocks.length;i++){totalCodeCount+=rsBlocks[i].totalCount;}
	var data=new Array(totalCodeCount);var index=0;for(var i=0;i<maxDcCount;i++){for(var r=0;r<rsBlocks.length;r++){if(i<dcdata[r].length){data[index++]=dcdata[r][i];}}}
	for(var i=0;i<maxEcCount;i++){for(var r=0;r<rsBlocks.length;r++){if(i<ecdata[r].length){data[index++]=ecdata[r][i];}}}
	return data;};var QRMode={MODE_NUMBER:1<<0,MODE_ALPHA_NUM:1<<1,MODE_8BIT_BYTE:1<<2,MODE_KANJI:1<<3};var QRErrorCorrectLevel={L:1,M:0,Q:3,H:2};var QRMaskPattern={PATTERN000:0,PATTERN001:1,PATTERN010:2,PATTERN011:3,PATTERN100:4,PATTERN101:5,PATTERN110:6,PATTERN111:7};var QRUtil={PATTERN_POSITION_TABLE:[[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170]],G15:(1<<10)|(1<<8)|(1<<5)|(1<<4)|(1<<2)|(1<<1)|(1<<0),G18:(1<<12)|(1<<11)|(1<<10)|(1<<9)|(1<<8)|(1<<5)|(1<<2)|(1<<0),G15_MASK:(1<<14)|(1<<12)|(1<<10)|(1<<4)|(1<<1),getBCHTypeInfo:function(data){var d=data<<10;while(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(QRUtil.G15)>=0){d^=(QRUtil.G15<<(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(QRUtil.G15)));}
	return((data<<10)|d)^QRUtil.G15_MASK;},getBCHTypeNumber:function(data){var d=data<<12;while(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(QRUtil.G18)>=0){d^=(QRUtil.G18<<(QRUtil.getBCHDigit(d)-QRUtil.getBCHDigit(QRUtil.G18)));}
	return(data<<12)|d;},getBCHDigit:function(data){var digit=0;while(data!=0){digit++;data>>>=1;}
	return digit;},getPatternPosition:function(typeNumber){return QRUtil.PATTERN_POSITION_TABLE[typeNumber-1];},getMask:function(maskPattern,i,j){switch(maskPattern){case QRMaskPattern.PATTERN000:return(i+j)%2==0;case QRMaskPattern.PATTERN001:return i%2==0;case QRMaskPattern.PATTERN010:return j%3==0;case QRMaskPattern.PATTERN011:return(i+j)%3==0;case QRMaskPattern.PATTERN100:return(Math.floor(i/2)+Math.floor(j/3))%2==0;case QRMaskPattern.PATTERN101:return(i*j)%2+(i*j)%3==0;case QRMaskPattern.PATTERN110:return((i*j)%2+(i*j)%3)%2==0;case QRMaskPattern.PATTERN111:return((i*j)%3+(i+j)%2)%2==0;default:throw new Error("bad maskPattern:"+maskPattern);}},getErrorCorrectPolynomial:function(errorCorrectLength){var a=new QRPolynomial([1],0);for(var i=0;i<errorCorrectLength;i++){a=a.multiply(new QRPolynomial([1,QRMath.gexp(i)],0));}
	return a;},getLengthInBits:function(mode,type){if(1<=type&&type<10){switch(mode){case QRMode.MODE_NUMBER:return 10;case QRMode.MODE_ALPHA_NUM:return 9;case QRMode.MODE_8BIT_BYTE:return 8;case QRMode.MODE_KANJI:return 8;default:throw new Error("mode:"+mode);}}else if(type<27){switch(mode){case QRMode.MODE_NUMBER:return 12;case QRMode.MODE_ALPHA_NUM:return 11;case QRMode.MODE_8BIT_BYTE:return 16;case QRMode.MODE_KANJI:return 10;default:throw new Error("mode:"+mode);}}else if(type<41){switch(mode){case QRMode.MODE_NUMBER:return 14;case QRMode.MODE_ALPHA_NUM:return 13;case QRMode.MODE_8BIT_BYTE:return 16;case QRMode.MODE_KANJI:return 12;default:throw new Error("mode:"+mode);}}else{throw new Error("type:"+type);}},getLostPoint:function(qrCode){var moduleCount=qrCode.getModuleCount();var lostPoint=0;for(var row=0;row<moduleCount;row++){for(var col=0;col<moduleCount;col++){var sameCount=0;var dark=qrCode.isDark(row,col);for(var r=-1;r<=1;r++){if(row+r<0||moduleCount<=row+r){continue;}
	for(var c=-1;c<=1;c++){if(col+c<0||moduleCount<=col+c){continue;}
	if(r==0&&c==0){continue;}
	if(dark==qrCode.isDark(row+r,col+c)){sameCount++;}}}
	if(sameCount>5){lostPoint+=(3+sameCount-5);}}}
	for(var row=0;row<moduleCount-1;row++){for(var col=0;col<moduleCount-1;col++){var count=0;if(qrCode.isDark(row,col))count++;if(qrCode.isDark(row+1,col))count++;if(qrCode.isDark(row,col+1))count++;if(qrCode.isDark(row+1,col+1))count++;if(count==0||count==4){lostPoint+=3;}}}
	for(var row=0;row<moduleCount;row++){for(var col=0;col<moduleCount-6;col++){if(qrCode.isDark(row,col)&&!qrCode.isDark(row,col+1)&&qrCode.isDark(row,col+2)&&qrCode.isDark(row,col+3)&&qrCode.isDark(row,col+4)&&!qrCode.isDark(row,col+5)&&qrCode.isDark(row,col+6)){lostPoint+=40;}}}
	for(var col=0;col<moduleCount;col++){for(var row=0;row<moduleCount-6;row++){if(qrCode.isDark(row,col)&&!qrCode.isDark(row+1,col)&&qrCode.isDark(row+2,col)&&qrCode.isDark(row+3,col)&&qrCode.isDark(row+4,col)&&!qrCode.isDark(row+5,col)&&qrCode.isDark(row+6,col)){lostPoint+=40;}}}
	var darkCount=0;for(var col=0;col<moduleCount;col++){for(var row=0;row<moduleCount;row++){if(qrCode.isDark(row,col)){darkCount++;}}}
	var ratio=Math.abs(100*darkCount/moduleCount/moduleCount-50)/5;lostPoint+=ratio*10;return lostPoint;}};var QRMath={glog:function(n){if(n<1){throw new Error("glog("+n+")");}
	return QRMath.LOG_TABLE[n];},gexp:function(n){while(n<0){n+=255;}
	while(n>=256){n-=255;}
	return QRMath.EXP_TABLE[n];},EXP_TABLE:new Array(256),LOG_TABLE:new Array(256)};for(var i=0;i<8;i++){QRMath.EXP_TABLE[i]=1<<i;}
	for(var i=8;i<256;i++){QRMath.EXP_TABLE[i]=QRMath.EXP_TABLE[i-4]^QRMath.EXP_TABLE[i-5]^QRMath.EXP_TABLE[i-6]^QRMath.EXP_TABLE[i-8];}
	for(var i=0;i<255;i++){QRMath.LOG_TABLE[QRMath.EXP_TABLE[i]]=i;}
	function QRPolynomial(num,shift){if(num.length==undefined){throw new Error(num.length+"/"+shift);}
	var offset=0;while(offset<num.length&&num[offset]==0){offset++;}
	this.num=new Array(num.length-offset+shift);for(var i=0;i<num.length-offset;i++){this.num[i]=num[i+offset];}}
	QRPolynomial.prototype={get:function(index){return this.num[index];},getLength:function(){return this.num.length;},multiply:function(e){var num=new Array(this.getLength()+e.getLength()-1);for(var i=0;i<this.getLength();i++){for(var j=0;j<e.getLength();j++){num[i+j]^=QRMath.gexp(QRMath.glog(this.get(i))+QRMath.glog(e.get(j)));}}
	return new QRPolynomial(num,0);},mod:function(e){if(this.getLength()-e.getLength()<0){return this;}
	var ratio=QRMath.glog(this.get(0))-QRMath.glog(e.get(0));var num=new Array(this.getLength());for(var i=0;i<this.getLength();i++){num[i]=this.get(i);}
	for(var i=0;i<e.getLength();i++){num[i]^=QRMath.gexp(QRMath.glog(e.get(i))+ratio);}
	return new QRPolynomial(num,0).mod(e);}};function QRRSBlock(totalCount,dataCount){this.totalCount=totalCount;this.dataCount=dataCount;}
	QRRSBlock.RS_BLOCK_TABLE=[[1,26,19],[1,26,16],[1,26,13],[1,26,9],[1,44,34],[1,44,28],[1,44,22],[1,44,16],[1,70,55],[1,70,44],[2,35,17],[2,35,13],[1,100,80],[2,50,32],[2,50,24],[4,25,9],[1,134,108],[2,67,43],[2,33,15,2,34,16],[2,33,11,2,34,12],[2,86,68],[4,43,27],[4,43,19],[4,43,15],[2,98,78],[4,49,31],[2,32,14,4,33,15],[4,39,13,1,40,14],[2,121,97],[2,60,38,2,61,39],[4,40,18,2,41,19],[4,40,14,2,41,15],[2,146,116],[3,58,36,2,59,37],[4,36,16,4,37,17],[4,36,12,4,37,13],[2,86,68,2,87,69],[4,69,43,1,70,44],[6,43,19,2,44,20],[6,43,15,2,44,16],[4,101,81],[1,80,50,4,81,51],[4,50,22,4,51,23],[3,36,12,8,37,13],[2,116,92,2,117,93],[6,58,36,2,59,37],[4,46,20,6,47,21],[7,42,14,4,43,15],[4,133,107],[8,59,37,1,60,38],[8,44,20,4,45,21],[12,33,11,4,34,12],[3,145,115,1,146,116],[4,64,40,5,65,41],[11,36,16,5,37,17],[11,36,12,5,37,13],[5,109,87,1,110,88],[5,65,41,5,66,42],[5,54,24,7,55,25],[11,36,12],[5,122,98,1,123,99],[7,73,45,3,74,46],[15,43,19,2,44,20],[3,45,15,13,46,16],[1,135,107,5,136,108],[10,74,46,1,75,47],[1,50,22,15,51,23],[2,42,14,17,43,15],[5,150,120,1,151,121],[9,69,43,4,70,44],[17,50,22,1,51,23],[2,42,14,19,43,15],[3,141,113,4,142,114],[3,70,44,11,71,45],[17,47,21,4,48,22],[9,39,13,16,40,14],[3,135,107,5,136,108],[3,67,41,13,68,42],[15,54,24,5,55,25],[15,43,15,10,44,16],[4,144,116,4,145,117],[17,68,42],[17,50,22,6,51,23],[19,46,16,6,47,17],[2,139,111,7,140,112],[17,74,46],[7,54,24,16,55,25],[34,37,13],[4,151,121,5,152,122],[4,75,47,14,76,48],[11,54,24,14,55,25],[16,45,15,14,46,16],[6,147,117,4,148,118],[6,73,45,14,74,46],[11,54,24,16,55,25],[30,46,16,2,47,17],[8,132,106,4,133,107],[8,75,47,13,76,48],[7,54,24,22,55,25],[22,45,15,13,46,16],[10,142,114,2,143,115],[19,74,46,4,75,47],[28,50,22,6,51,23],[33,46,16,4,47,17],[8,152,122,4,153,123],[22,73,45,3,74,46],[8,53,23,26,54,24],[12,45,15,28,46,16],[3,147,117,10,148,118],[3,73,45,23,74,46],[4,54,24,31,55,25],[11,45,15,31,46,16],[7,146,116,7,147,117],[21,73,45,7,74,46],[1,53,23,37,54,24],[19,45,15,26,46,16],[5,145,115,10,146,116],[19,75,47,10,76,48],[15,54,24,25,55,25],[23,45,15,25,46,16],[13,145,115,3,146,116],[2,74,46,29,75,47],[42,54,24,1,55,25],[23,45,15,28,46,16],[17,145,115],[10,74,46,23,75,47],[10,54,24,35,55,25],[19,45,15,35,46,16],[17,145,115,1,146,116],[14,74,46,21,75,47],[29,54,24,19,55,25],[11,45,15,46,46,16],[13,145,115,6,146,116],[14,74,46,23,75,47],[44,54,24,7,55,25],[59,46,16,1,47,17],[12,151,121,7,152,122],[12,75,47,26,76,48],[39,54,24,14,55,25],[22,45,15,41,46,16],[6,151,121,14,152,122],[6,75,47,34,76,48],[46,54,24,10,55,25],[2,45,15,64,46,16],[17,152,122,4,153,123],[29,74,46,14,75,47],[49,54,24,10,55,25],[24,45,15,46,46,16],[4,152,122,18,153,123],[13,74,46,32,75,47],[48,54,24,14,55,25],[42,45,15,32,46,16],[20,147,117,4,148,118],[40,75,47,7,76,48],[43,54,24,22,55,25],[10,45,15,67,46,16],[19,148,118,6,149,119],[18,75,47,31,76,48],[34,54,24,34,55,25],[20,45,15,61,46,16]];QRRSBlock.getRSBlocks=function(typeNumber,errorCorrectLevel){var rsBlock=QRRSBlock.getRsBlockTable(typeNumber,errorCorrectLevel);if(rsBlock==undefined){throw new Error("bad rs block @ typeNumber:"+typeNumber+"/errorCorrectLevel:"+errorCorrectLevel);}
	var length=rsBlock.length/3;var list=[];for(var i=0;i<length;i++){var count=rsBlock[i*3+0];var totalCount=rsBlock[i*3+1];var dataCount=rsBlock[i*3+2];for(var j=0;j<count;j++){list.push(new QRRSBlock(totalCount,dataCount));}}
	return list;};QRRSBlock.getRsBlockTable=function(typeNumber,errorCorrectLevel){switch(errorCorrectLevel){case QRErrorCorrectLevel.L:return QRRSBlock.RS_BLOCK_TABLE[(typeNumber-1)*4+0];case QRErrorCorrectLevel.M:return QRRSBlock.RS_BLOCK_TABLE[(typeNumber-1)*4+1];case QRErrorCorrectLevel.Q:return QRRSBlock.RS_BLOCK_TABLE[(typeNumber-1)*4+2];case QRErrorCorrectLevel.H:return QRRSBlock.RS_BLOCK_TABLE[(typeNumber-1)*4+3];default:return undefined;}};function QRBitBuffer(){this.buffer=[];this.length=0;}
	QRBitBuffer.prototype={get:function(index){var bufIndex=Math.floor(index/8);return((this.buffer[bufIndex]>>>(7-index%8))&1)==1;},put:function(num,length){for(var i=0;i<length;i++){this.putBit(((num>>>(length-i-1))&1)==1);}},getLengthInBits:function(){return this.length;},putBit:function(bit){var bufIndex=Math.floor(this.length/8);if(this.buffer.length<=bufIndex){this.buffer.push(0);}
	if(bit){this.buffer[bufIndex]|=(0x80>>>(this.length%8));}
	this.length++;}};var QRCodeLimitLength=[[17,14,11,7],[32,26,20,14],[53,42,32,24],[78,62,46,34],[106,84,60,44],[134,106,74,58],[154,122,86,64],[192,152,108,84],[230,180,130,98],[271,213,151,119],[321,251,177,137],[367,287,203,155],[425,331,241,177],[458,362,258,194],[520,412,292,220],[586,450,322,250],[644,504,364,280],[718,560,394,310],[792,624,442,338],[858,666,482,382],[929,711,509,403],[1003,779,565,439],[1091,857,611,461],[1171,911,661,511],[1273,997,715,535],[1367,1059,751,593],[1465,1125,805,625],[1528,1190,868,658],[1628,1264,908,698],[1732,1370,982,742],[1840,1452,1030,790],[1952,1538,1112,842],[2068,1628,1168,898],[2188,1722,1228,958],[2303,1809,1283,983],[2431,1911,1351,1051],[2563,1989,1423,1093],[2699,2099,1499,1139],[2809,2213,1579,1219],[2953,2331,1663,1273]];
	
	function _isSupportCanvas() {
		return typeof CanvasRenderingContext2D != "undefined";
	}
	
	// android 2.x doesn't support Data-URI spec
	function _getAndroid() {
		var android = false;
		var sAgent = navigator.userAgent;
		
		if (/android/i.test(sAgent)) { // android
			android = true;
			var aMat = sAgent.toString().match(/android ([0-9]\.[0-9])/i);
			
			if (aMat && aMat[1]) {
				android = parseFloat(aMat[1]);
			}
		}
		
		return android;
	}
	
	var svgDrawer = (function() {

		var Drawing = function (el, htOption) {
			this._el = el;
			this._htOption = htOption;
		};

		Drawing.prototype.draw = function (oQRCode) {
			var _htOption = this._htOption;
			var _el = this._el;
			var nCount = oQRCode.getModuleCount();
			var nWidth = Math.floor(_htOption.width / nCount);
			var nHeight = Math.floor(_htOption.height / nCount);

			this.clear();

			function makeSVG(tag, attrs) {
				var el = document.createElementNS('http://www.w3.org/2000/svg', tag);
				for (var k in attrs)
					if (attrs.hasOwnProperty(k)) el.setAttribute(k, attrs[k]);
				return el;
			}

			var svg = makeSVG("svg" , {'viewBox': '0 0 ' + String(nCount) + " " + String(nCount), 'width': '100%', 'height': '100%', 'fill': _htOption.colorLight});
			svg.setAttributeNS("http://www.w3.org/2000/xmlns/", "xmlns:xlink", "http://www.w3.org/1999/xlink");
			_el.appendChild(svg);

			svg.appendChild(makeSVG("rect", {"fill": _htOption.colorLight, "width": "100%", "height": "100%"}));
			svg.appendChild(makeSVG("rect", {"fill": _htOption.colorDark, "width": "1", "height": "1", "id": "template"}));

			for (var row = 0; row < nCount; row++) {
				for (var col = 0; col < nCount; col++) {
					if (oQRCode.isDark(row, col)) {
						var child = makeSVG("use", {"x": String(col), "y": String(row)});
						child.setAttributeNS("http://www.w3.org/1999/xlink", "href", "#template")
						svg.appendChild(child);
					}
				}
			}
		};
		Drawing.prototype.clear = function () {
			while (this._el.hasChildNodes())
				this._el.removeChild(this._el.lastChild);
		};
		return Drawing;
	})();

	var useSVG = document.documentElement.tagName.toLowerCase() === "svg";

	// Drawing in DOM by using Table tag
	var Drawing = useSVG ? svgDrawer : !_isSupportCanvas() ? (function () {
		var Drawing = function (el, htOption) {
			this._el = el;
			this._htOption = htOption;
		};
			
		/**
		 * Draw the QRCode
		 * 
		 * @param {QRCode} oQRCode
		 */
		Drawing.prototype.draw = function (oQRCode) {
            var _htOption = this._htOption;
            var _el = this._el;
			var nCount = oQRCode.getModuleCount();
			var nWidth = Math.floor(_htOption.width / nCount);
			var nHeight = Math.floor(_htOption.height / nCount);
			var aHTML = ['<table style="border:0;border-collapse:collapse;">'];
			
			for (var row = 0; row < nCount; row++) {
				aHTML.push('<tr>');
				
				for (var col = 0; col < nCount; col++) {
					aHTML.push('<td style="border:0;border-collapse:collapse;padding:0;margin:0;width:' + nWidth + 'px;height:' + nHeight + 'px;background-color:' + (oQRCode.isDark(row, col) ? _htOption.colorDark : _htOption.colorLight) + ';"></td>');
				}
				
				aHTML.push('</tr>');
			}
			
			aHTML.push('</table>');
			_el.innerHTML = aHTML.join('');
			
			// Fix the margin values as real size.
			var elTable = _el.childNodes[0];
			var nLeftMarginTable = (_htOption.width - elTable.offsetWidth) / 2;
			var nTopMarginTable = (_htOption.height - elTable.offsetHeight) / 2;
			
			if (nLeftMarginTable > 0 && nTopMarginTable > 0) {
				elTable.style.margin = nTopMarginTable + "px " + nLeftMarginTable + "px";	
			}
		};
		
		/**
		 * Clear the QRCode
		 */
		Drawing.prototype.clear = function () {
			this._el.innerHTML = '';
		};
		
		return Drawing;
	})() : (function () { // Drawing in Canvas
		function _onMakeImage() {
			this._elImage.src = this._elCanvas.toDataURL("image/png");
			this._elImage.style.display = "block";
			this._elCanvas.style.display = "none";			
		}
		
		// Android 2.1 bug workaround
		// http://code.google.com/p/android/issues/detail?id=5141
		if (this._android && this._android <= 2.1) {
	    	var factor = 1 / window.devicePixelRatio;
	        var drawImage = CanvasRenderingContext2D.prototype.drawImage; 
	    	CanvasRenderingContext2D.prototype.drawImage = function (image, sx, sy, sw, sh, dx, dy, dw, dh) {
	    		if (("nodeName" in image) && /img/i.test(image.nodeName)) {
		        	for (var i = arguments.length - 1; i >= 1; i--) {
		            	arguments[i] = arguments[i] * factor;
		        	}
	    		} else if (typeof dw == "undefined") {
	    			arguments[1] *= factor;
	    			arguments[2] *= factor;
	    			arguments[3] *= factor;
	    			arguments[4] *= factor;
	    		}
	    		
	        	drawImage.apply(this, arguments); 
	    	};
		}
		
		/**
		 * Check whether the user's browser supports Data URI or not
		 * 
		 * @private
		 * @param {Function} fSuccess Occurs if it supports Data URI
		 * @param {Function} fFail Occurs if it doesn't support Data URI
		 */
		function _safeSetDataURI(fSuccess, fFail) {
            var self = this;
            self._fFail = fFail;
            self._fSuccess = fSuccess;

            // Check it just once
            if (self._bSupportDataURI === null) {
                var el = document.createElement("img");
                var fOnError = function() {
                    self._bSupportDataURI = false;

                    if (self._fFail) {
                        self._fFail.call(self);
                    }
                };
                var fOnSuccess = function() {
                    self._bSupportDataURI = true;

                    if (self._fSuccess) {
                        self._fSuccess.call(self);
                    }
                };

                el.onabort = fOnError;
                el.onerror = fOnError;
                el.onload = fOnSuccess;
                el.src = "data:image/gif;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg=="; // the Image contains 1px data.
                return;
            } else if (self._bSupportDataURI === true && self._fSuccess) {
                self._fSuccess.call(self);
            } else if (self._bSupportDataURI === false && self._fFail) {
                self._fFail.call(self);
            }
		};
		
		/**
		 * Drawing QRCode by using canvas
		 * 
		 * @constructor
		 * @param {HTMLElement} el
		 * @param {Object} htOption QRCode Options 
		 */
		var Drawing = function (el, htOption) {
    		this._bIsPainted = false;
    		this._android = _getAndroid();
		
			this._htOption = htOption;
			this._elCanvas = document.createElement("canvas");
			this._elCanvas.width = htOption.width;
			this._elCanvas.height = htOption.height;
			el.appendChild(this._elCanvas);
			this._el = el;
			this._oContext = this._elCanvas.getContext("2d");
			this._bIsPainted = false;
			this._elImage = document.createElement("img");
			this._elImage.alt = "Scan me!";
			this._elImage.style.display = "none";
			this._el.appendChild(this._elImage);
			this._bSupportDataURI = null;
		};
			
		/**
		 * Draw the QRCode
		 * 
		 * @param {QRCode} oQRCode 
		 */
		Drawing.prototype.draw = function (oQRCode) {
            var _elImage = this._elImage;
            var _oContext = this._oContext;
            var _htOption = this._htOption;
            
			var nCount = oQRCode.getModuleCount();
			var nWidth = _htOption.width / nCount;
			var nHeight = _htOption.height / nCount;
			var nRoundedWidth = Math.round(nWidth);
			var nRoundedHeight = Math.round(nHeight);

			_elImage.style.display = "none";
			this.clear();
			
			for (var row = 0; row < nCount; row++) {
				for (var col = 0; col < nCount; col++) {
					var bIsDark = oQRCode.isDark(row, col);
					var nLeft = col * nWidth;
					var nTop = row * nHeight;
					_oContext.strokeStyle = bIsDark ? _htOption.colorDark : _htOption.colorLight;
					_oContext.lineWidth = 1;
					_oContext.fillStyle = bIsDark ? _htOption.colorDark : _htOption.colorLight;					
					_oContext.fillRect(nLeft, nTop, nWidth, nHeight);
					
					// 안티 앨리어싱 방지 처리
					_oContext.strokeRect(
						Math.floor(nLeft) + 0.5,
						Math.floor(nTop) + 0.5,
						nRoundedWidth,
						nRoundedHeight
					);
					
					_oContext.strokeRect(
						Math.ceil(nLeft) - 0.5,
						Math.ceil(nTop) - 0.5,
						nRoundedWidth,
						nRoundedHeight
					);
				}
			}
			
			this._bIsPainted = true;
		};
			
		/**
		 * Make the image from Canvas if the browser supports Data URI.
		 */
		Drawing.prototype.makeImage = function () {
			if (this._bIsPainted) {
				_safeSetDataURI.call(this, _onMakeImage);
			}
		};
			
		/**
		 * Return whether the QRCode is painted or not
		 * 
		 * @return {Boolean}
		 */
		Drawing.prototype.isPainted = function () {
			return this._bIsPainted;
		};
		
		/**
		 * Clear the QRCode
		 */
		Drawing.prototype.clear = function () {
			this._oContext.clearRect(0, 0, this._elCanvas.width, this._elCanvas.height);
			this._bIsPainted = false;
		};
		
		/**
		 * @private
		 * @param {Number} nNumber
		 */
		Drawing.prototype.round = function (nNumber) {
			if (!nNumber) {
				return nNumber;
			}
			
			return Math.floor(nNumber * 1000) / 1000;
		};
		
		return Drawing;
	})();
	
	/**
	 * Get the type by string length
	 * 
	 * @private
	 * @param {String} sText
	 * @param {Number} nCorrectLevel
	 * @return {Number} type
	 */
	function _getTypeNumber(sText, nCorrectLevel) {			
		var nType = 1;
		var length = _getUTF8Length(sText);
		
		for (var i = 0, len = QRCodeLimitLength.length; i <= len; i++) {
			var nLimit = 0;
			
			switch (nCorrectLevel) {
				case QRErrorCorrectLevel.L :
					nLimit = QRCodeLimitLength[i][0];
					break;
				case QRErrorCorrectLevel.M :
					nLimit = QRCodeLimitLength[i][1];
					break;
				case QRErrorCorrectLevel.Q :
					nLimit = QRCodeLimitLength[i][2];
					break;
				case QRErrorCorrectLevel.H :
					nLimit = QRCodeLimitLength[i][3];
					break;
			}
			
			if (length <= nLimit) {
				break;
			} else {
				nType++;
			}
		}
		
		if (nType > QRCodeLimitLength.length) {
			throw new Error("Too long data");
		}
		
		return nType;
	}

	function _getUTF8Length(sText) {
		var replacedText = encodeURI(sText).toString().replace(/\%[0-9a-fA-F]{2}/g, 'a');
		return replacedText.length + (replacedText.length != sText ? 3 : 0);
	}
	
	/**
	 * @class QRCode
	 * @constructor
	 * @example 
	 * new QRCode(document.getElementById("test"), "http://jindo.dev.naver.com/collie");
	 *
	 * @example
	 * var oQRCode = new QRCode("test", {
	 *    text : "http://naver.com",
	 *    width : 128,
	 *    height : 128
	 * });
	 * 
	 * oQRCode.clear(); // Clear the QRCode.
	 * oQRCode.makeCode("http://map.naver.com"); // Re-create the QRCode.
	 *
	 * @param {HTMLElement|String} el target element or 'id' attribute of element.
	 * @param {Object|String} vOption
	 * @param {String} vOption.text QRCode link data
	 * @param {Number} [vOption.width=256]
	 * @param {Number} [vOption.height=256]
	 * @param {String} [vOption.colorDark="#000000"]
	 * @param {String} [vOption.colorLight="#ffffff"]
	 * @param {QRCode.CorrectLevel} [vOption.correctLevel=QRCode.CorrectLevel.H] [L|M|Q|H] 
	 */
	QRCode = function (el, vOption) {
		this._htOption = {
			width : 256, 
			height : 256,
			typeNumber : 4,
			colorDark : "#000000",
			colorLight : "#ffffff",
			correctLevel : QRErrorCorrectLevel.H
		};
		
		if (typeof vOption === 'string') {
			vOption	= {
				text : vOption
			};
		}
		
		// Overwrites options
		if (vOption) {
			for (var i in vOption) {
				this._htOption[i] = vOption[i];
			}
		}
		
		if (typeof el == "string") {
			el = document.getElementById(el);
		}

		if (this._htOption.useSVG) {
			Drawing = svgDrawer;
		}
		
		this._android = _getAndroid();
		this._el = el;
		this._oQRCode = null;
		this._oDrawing = new Drawing(this._el, this._htOption);
		
		if (this._htOption.text) {
			this.makeCode(this._htOption.text);	
		}
	};
	
	/**
	 * Make the QRCode
	 * 
	 * @param {String} sText link data
	 */
	QRCode.prototype.makeCode = function (sText) {
		this._oQRCode = new QRCodeModel(_getTypeNumber(sText, this._htOption.correctLevel), this._htOption.correctLevel);
		this._oQRCode.addData(sText);
		this._oQRCode.make();
		this._el.title = sText;
		this._oDrawing.draw(this._oQRCode);			
		this.makeImage();
	};
	
	/**
	 * Make the Image from Canvas element
	 * - It occurs automatically
	 * - Android below 3 doesn't support Data-URI spec.
	 * 
	 * @private
	 */
	QRCode.prototype.makeImage = function () {
		if (typeof this._oDrawing.makeImage == "function" && (!this._android || this._android >= 3)) {
			this._oDrawing.makeImage();
		}
	};
	
	/**
	 * Clear the QRCode
	 */
	QRCode.prototype.clear = function () {
		this._oDrawing.clear();
	};
	
	/**
	 * @name QRCode.CorrectLevel
	 */
	QRCode.CorrectLevel = QRErrorCorrectLevel;
})();

function esc(s) { return (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

const TABS = ["security", "comms", "extensions", "voicemail", "crowdsec"];
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    TABS.forEach(t => { document.getElementById("tab-" + t).style.display = btn.dataset.tab === t ? "" : "none"; });
    if (btn.dataset.tab === "extensions") refreshExtensionsTab();
    if (btn.dataset.tab === "voicemail") loadVoicemail();
  });
});

// What this box can actually do, resolved once per page load. Everything the
// Extensions tab shows is gated on these two rather than on separate nav
// buttons: the extension list itself only needs pjsip.conf, so it's always
// worth showing, while device/room editing needs a reachable Easy
// Asterisk container and tier/DID editing needs a PSTN trunk dialplan. One
// tab that grows columns and cards as those appear beats three tabs that
// each list the same extensions from a different angle.
let eaInstalled = false, pstnInstalled = false;

let lastSecurityEvents = [];
let secSort = { key: null, dir: 1 };

function renderSecurity() {
  let rows = lastSecurityEvents.slice();
  if (secSort.key) {
    rows.sort((a, b) => {
      const av = (a[secSort.key] || "").toLowerCase(), bv = (b[secSort.key] || "").toLowerCase();
      if (av < bv) return -1 * secSort.dir;
      if (av > bv) return 1 * secSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#sec-table th.sortable .arrow").forEach(a => a.remove());
  if (secSort.key) {
    const th = document.querySelector(`#sec-table th[data-sort="${secSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${secSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  const tbody = document.querySelector("#sec-table tbody");
  tbody.innerHTML = rows.map(e => `<tr>
    <td>${esc(e.timestamp)}</td>
    <td>${esc(e.event)}</td>
    <td>${esc(e.account)}</td>
    <td>${esc(e.remote)}</td>
    <td class="sev-${esc(e.severity)}">${esc(e.severity)}</td>
  </tr>`).join("") || `<tr><td colspan=5 class=muted>No events found.</td></tr>`;
}

document.querySelectorAll("#sec-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    secSort.dir = (secSort.key === key) ? -secSort.dir : 1;
    secSort.key = key;
    renderSecurity();
  });
});

async function loadSecurity() {
  const res = await fetch("/api/security-events");
  lastSecurityEvents = await res.json();
  renderSecurity();
}

// ── Voicemail tab ────────────────────────────────────────────────────────
let lastVoicemail = [];
let vmSort = { key: "origtime", dir: -1 };

function fmtVmTime(origtime) {
  if (!origtime || !/^\d+$/.test(origtime)) return "";
  return new Date(parseInt(origtime, 10) * 1000).toLocaleString();
}

function fmtVmDuration(seconds) {
  const s = parseInt(seconds, 10);
  if (!Number.isFinite(s) || s < 0) return "";
  const m = Math.floor(s / 60), r = s % 60;
  return m + ":" + String(r).padStart(2, "0");
}

function renderVoicemail() {
  let rows = lastVoicemail.slice();
  if (vmSort.key) {
    rows.sort((a, b) => {
      let av = a[vmSort.key], bv = b[vmSort.key];
      if (vmSort.key === "origtime" || vmSort.key === "duration") { av = parseInt(av, 10) || 0; bv = parseInt(bv, 10) || 0; }
      else { av = (av || "").toString().toLowerCase(); bv = (bv || "").toString().toLowerCase(); }
      if (av < bv) return -1 * vmSort.dir;
      if (av > bv) return 1 * vmSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#vm-table th.sortable .arrow").forEach(a => a.remove());
  if (vmSort.key) {
    const th = document.querySelector(`#vm-table th[data-sort="${vmSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${vmSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  const tbody = document.querySelector("#vm-table tbody");
  tbody.innerHTML = rows.map(m => `<tr>
    <td>${esc(fmtVmTime(m.origtime))}</td>
    <td>${esc(m.ext)}</td>
    <td>${esc(m.callerid || "Unknown")}</td>
    <td>${esc(fmtVmDuration(m.duration))}</td>
    <td><audio controls preload="none" style="height:2rem" src="/voicemail/audio?ext=${encodeURIComponent(m.ext)}&msg=${encodeURIComponent(m.msg)}"></audio></td>
  </tr>`).join("") || `<tr><td colspan=5 class=muted>No voicemail messages. Enable voicemail for an extension on the Extensions tab.</td></tr>`;
}

document.querySelectorAll("#vm-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    vmSort.dir = (vmSort.key === key) ? -vmSort.dir : 1;
    vmSort.key = key;
    renderVoicemail();
  });
});

async function loadVoicemail() {
  const res = await fetch("/api/voicemail");
  const data = await res.json();
  lastVoicemail = data.messages || [];
  renderVoicemail();
}

// ── Calls & Texts tab ───────────────────────────────────────────────────────
let lastCalls = [];
let callsSort = { key: null, dir: 1 };

function renderCalls() {
  let rows = lastCalls.slice();
  if (callsSort.key) {
    rows.sort((a, b) => {
      const av = (a[callsSort.key] || "").toString().toLowerCase(), bv = (b[callsSort.key] || "").toString().toLowerCase();
      if (av < bv) return -1 * callsSort.dir;
      if (av > bv) return 1 * callsSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#calls-table th.sortable .arrow").forEach(a => a.remove());
  if (callsSort.key) {
    const th = document.querySelector(`#calls-table th[data-sort="${callsSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${callsSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  const tbody = document.querySelector("#calls-table tbody");
  tbody.innerHTML = rows.map(c => `<tr>
    <td>${esc(c.timestamp)}</td>
    <td>${esc(c.direction)}</td>
    <td>${esc(c.from)}</td>
    <td>${esc(c.to)}</td>
    <td>${esc(c.duration)}s</td>
  </tr>`).join("") || `<tr><td colspan=5 class=muted>No calls found.</td></tr>`;
}

document.querySelectorAll("#calls-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    callsSort.dir = (callsSort.key === key) ? -callsSort.dir : 1;
    callsSort.key = key;
    renderCalls();
  });
});

async function loadCalls() {
  const res = await fetch("/api/pstn-calls");
  lastCalls = await res.json();
  renderCalls();
}

let lastTexts = [];
let textsSort = { key: null, dir: 1 };

function renderTexts() {
  let rows = lastTexts.slice();
  if (textsSort.key) {
    rows.sort((a, b) => {
      const av = (a[textsSort.key] || "").toString().toLowerCase(), bv = (b[textsSort.key] || "").toString().toLowerCase();
      if (av < bv) return -1 * textsSort.dir;
      if (av > bv) return 1 * textsSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#texts-table th.sortable .arrow").forEach(a => a.remove());
  if (textsSort.key) {
    const th = document.querySelector(`#texts-table th[data-sort="${textsSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${textsSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  const tbody = document.querySelector("#texts-table tbody");
  tbody.innerHTML = rows.map(t => `<tr>
    <td>${esc(t.timestamp)}</td>
    <td>${esc(t.type)}</td>
    <td>${esc(t.direction)}</td>
    <td>${esc(t.from)}</td>
    <td>${esc(t.to)}</td>
    <td>${esc(t.status)}</td>
  </tr>`).join("") || `<tr><td colspan=6 class=muted>No texts found.</td></tr>`;
}

document.querySelectorAll("#texts-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    textsSort.dir = (textsSort.key === key) ? -textsSort.dir : 1;
    textsSort.key = key;
    renderTexts();
  });
});

async function loadTexts() {
  const res = await fetch("/api/comms-texts");
  lastTexts = await res.json();
  renderTexts();
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

// CrowdSec is the one thing still worth its own tab — it's about banned IPs,
// not the phone system — so its nav button is still gated the old way.
async function loadCrowdsecStatus() {
  const res = await fetch("/api/crowdsec-status");
  const data = await res.json();
  document.getElementById("crowdsec-tab-btn").style.display = data.installed ? "" : "none";
}

// ── Extensions tab (extensions + rooms + groups + trunk) ───────────────────
let eaDevices = [], eaRooms = [], eaStatusMap = {};
let eaRoomSort = { key: null, dir: 1 };

async function initExtensionsTab() {
  const [ea, pstn] = await Promise.all([
    fetch("/api/ea-status").then(r => r.json()),
    fetch("/api/pstn-status").then(r => r.json()),
  ]);
  eaInstalled = !!ea.installed;
  pstnInstalled = !!pstn.installed;
  // The form defaults to TLS in the markup and stays there — no box is worse
  // off for it, and the failure mode of the other default (a UDP-only
  // endpoint silently refusing TLS registrations) is far harder to diagnose
  // than a phone being told to trust a self-signed certificate. Without a
  // domain configured that certificate can only be self-signed, so say so
  // where the choice is rather than quietly switching it.
  const connHint = document.getElementById("ext-add-conn-hint");
  if (connHint) {
    connHint.textContent = ea.env_error
      ? ea.env_error
      : (ea.domain
          ? "Phones register against " + ea.domain + ":5061."
          : "No DOMAIN_NAME set in Asterisk's .env — TLS will use a self-signed certificate the phone must be told to accept. LAN only (UDP) avoids that on a local network.");
  }
  if (ea.installed && ea.env_readable === false) {
    toast(ea.env_error || "Can't read Asterisk's .env — connection details will be incomplete.", "err");
  }
  document.body.classList.toggle("no-ea", !eaInstalled);
  document.body.classList.toggle("no-pstn", !pstnInstalled);
  await refreshExtensionsTab();
}

// Sequenced (not parallel) — room rows render a member-add picker that needs
// eaDevices (populated by loadExtensions), and the personal-DID owner picker
// needs both extensions and rooms.
async function refreshExtensionsTab() {
  await loadExtensions();
  if (eaInstalled) await loadEaRooms();
  if (pstnInstalled) await loadPersonalDids();
}

// ── Toasts ────────────────────────────────────────────────────────────────
// Transient feedback that doesn't push layout around. Anything the user must
// keep (a one-time device password) uses the persistent callout instead.
function toast(text, kind) {
  const el = document.createElement("div");
  el.className = "toast" + (kind ? " " + kind : "");
  el.textContent = text;
  document.getElementById("toasts").appendChild(el);
  setTimeout(() => el.remove(), 5000);
}

// One row per extension, merged from two sources that used to drive two
// separate tables (plus a third card of checkboxes): pjsip.conf via
// /api/pstn-permissions — which always works, with or without the Easy
// Asterisk container — and /api/ea-devices for category/status/transport.
// Keyed by extension number, so an extension known to only one of them still
// gets a row rather than silently vanishing.
async function loadExtensions() {
  const permData = await fetch("/api/pstn-permissions").then(r => r.json());
  const byExt = new Map();
  (permData.extensions || []).forEach(e => byExt.set(e.ext, {
    ext: e.ext, name: e.name,
    restrict: e.restrict, allowed_numbers: e.allowed_numbers,
    messaging: e.messaging, voicemail: e.voicemail, voicemail_pin: e.voicemail_pin,
    ea: false, category: "", status: "", transport: "", encryption: "",
  }));

  if (eaInstalled) {
    const devData = await fetch("/api/ea-devices").then(r => r.json());
    eaDevices = devData.devices || [];
    eaStatusMap = devData.status || {};
    eaDevices.forEach(d => {
      const row = byExt.get(d.extension) || {
        ext: d.extension, name: d.name,
        restrict: "internal", allowed_numbers: "",
        messaging: false,
      };
      row.ea = true;
      row.name = row.name || d.name;
      row.category = d.category;
      row.transport = d.transport;
      row.encryption = d.encryption;
      row.status = eaStatusMap[d.extension] || "unknown";
      byExt.set(d.extension, row);
    });
  }

  extRows = Array.from(byExt.values());
  renderExtensions();
  renderRoomMemberPicker();
  renderPersonalDidOwnerOptions();
}

// The new-ring-group form's member checkboxes — driven by the same merged
// extension list the table above renders, so it can never offer an
// extension the table doesn't show (or miss one it does). Existing rooms'
// membership is edited via the per-row add/remove control in the table
// instead — this picker is only for building a group's initial membership
// at creation time.
function renderRoomMemberPicker() {
  const el = document.getElementById("ea-room-members");
  if (!el) return;
  el.innerHTML = extRows.map(e => `
    <label class="muted" style="white-space:nowrap">
      <input type="checkbox" class="ea-room-member-cb" value="${esc(e.ext)}"> ${esc(e.ext)} — ${esc(e.name)}
    </label>
  `).join("") || '<span class="muted">No extensions found</span>';
}

let extRows = [];
let extSort = { key: null, dir: 1 };
let openDetailsExt = null;

// Sort by how much reach the mode grants, not alphabetically — "full" would
// otherwise land between "internal" and "restricted".
const RESTRICT_ORDER = {
  "internal": 0, "restricted": 1, "restricted-in": 2, "restricted-out": 3, "full": 4,
};
// Order as offered in the dropdown: the original three tiers still read the
// same, with the two half-restrictions slotted in between.
const RESTRICT_LABELS = [
  ["full", "full"],
  ["restricted", "restricted (both ways)"],
  ["restricted-in", "restricted incoming"],
  ["restricted-out", "restricted outgoing"],
  ["internal", "internal"],
];

function extSortValue(e, key) {
  if (key === "ext") return parseInt(e.ext, 10);
  if (key === "messaging") return e.messaging ? 1 : 0;
  if (key === "voicemail") return e.voicemail ? 1 : 0;
  if (key === "restrict") return RESTRICT_ORDER[e[key]] ?? -1;
  return (e[key] || "").toString().toLowerCase();
}

function setCount(id, n) {
  const el = document.getElementById(id);
  if (el) el.textContent = n ? "(" + n + ")" : "";
}

function restrictSelect(value) {
  return '<select class="ext-restrict">' +
    RESTRICT_LABELS.map(([v, label]) =>
      `<option value="${v}" ${value === v ? "selected" : ""}>${esc(label)}</option>`).join("") +
    "</select>";
}

// The whitelist is meaningless for "no PSTN" and "unrestricted".
function restrictUsesList(mode) { return mode.indexOf("restricted") === 0; }

function renderExtensions() {
  const tbody = document.querySelector("#ext-table tbody");
  setCount("ext-count", extRows.length);
  if (!extRows.length) {
    tbody.innerHTML = '<tr><td colspan=9 class=empty>No extensions found — no Asterisk install detected, or pjsip.conf has no devices yet.</td></tr>';
    updateDirtyState();
    return;
  }
  let rows = extRows.slice();
  if (extSort.key) {
    rows.sort((a, b) => {
      const av = extSortValue(a, extSort.key), bv = extSortValue(b, extSort.key);
      if (av < bv) return -1 * extSort.dir;
      if (av > bv) return 1 * extSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#ext-table th.sortable .arrow").forEach(a => a.remove());
  if (extSort.key) {
    const th = document.querySelector(`#ext-table th[data-sort="${extSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${extSort.dir === 1 ? "▲" : "▼"}</span>`);
  }

  // Re-rendering the body discards any injected detail row, so the toggle's
  // idea of what's open has to go with it — otherwise the next click on that
  // extension's button toggles "closed" against a row that isn't there.
  openDetailsExt = null;
  tbody.innerHTML = rows.map(e => {
    const status = e.status || "unknown";
    // Rows for an extension the Easy Asterisk container doesn't know about
    // (in pjsip.conf but not its device list) still get tier/messaging —
    // only the container-backed controls are inert, since every one of them
    // writes through `docker exec` into that container.
    const mobileCell = e.ea
      ? `<input type="checkbox" class="ext-mobile" ${e.category === "mobile" ? "checked" : ""} aria-label="Mobile/cellular device for extension ${esc(e.ext)}">`
      : '<span class="empty">—</span>';
    const statusCell = e.ea
      ? `<span class="pill ${status === "online" ? "online" : "offline"}">${esc(status)}</span>`
      : '<span class="empty">—</span>';
    return `<tr data-ext="${esc(e.ext)}">
      <td>${esc(e.ext)}</td>
      <td><input type="text" class="inline-edit ext-name" value="${esc(e.name)}" ${e.ea ? "" : "disabled"} aria-label="Name for extension ${esc(e.ext)}"></td>
      <td class="ea-only" style="text-align:center">${mobileCell}</td>
      <td class="ea-only">${statusCell}</td>
      <td class="ea-only muted">${esc(e.transport)}${e.encryption && e.encryption !== "no" ? " / " + esc(e.encryption) : ""}</td>
      <td class="pstn-only">${restrictSelect(e.restrict)}</td>
      <td class="pstn-only"><input type="text" class="ext-numbers" value="${esc(e.allowed_numbers)}" placeholder="5551234567,5559876543" ${restrictUsesList(e.restrict) ? "" : "disabled"} style="width:16rem" aria-label="Whitelist for extension ${esc(e.ext)}"></td>
      <td style="text-align:center"><input type="checkbox" class="ext-messaging" ${e.messaging ? "checked" : ""} aria-label="Messaging for extension ${esc(e.ext)}"></td>
      <td style="text-align:center">
        <input type="checkbox" class="ext-voicemail" ${e.voicemail ? "checked" : ""} aria-label="Voicemail for extension ${esc(e.ext)}">
        ${e.voicemail_pin ? `<span class="muted" style="font-size:0.85em" title="Voicemail PIN">PIN ${esc(e.voicemail_pin)}</span>` : ""}
      </td>
      <td class="actions">
        <button class="icon ea-only" title="Connection details for ${esc(e.ext)}" onclick="toggleEaDeviceDetails('${esc(e.ext)}')">&#9432;</button>
        <button class="icon ea-only" title="Delete extension ${esc(e.ext)}" onclick="deleteEaDevice('${esc(e.ext)}')">&times;</button>
      </td>
    </tr>`;
  }).join("");

  tbody.querySelectorAll("tr").forEach(row => {
    const modeSel = row.querySelector(".ext-restrict");
    const numsInput = row.querySelector(".ext-numbers");
    if (modeSel && numsInput) {
      modeSel.addEventListener("change", () => { numsInput.disabled = !restrictUsesList(modeSel.value); });
    }
    row.querySelectorAll("input, select").forEach(ctl => {
      ctl.addEventListener("input", updateDirtyState);
      ctl.addEventListener("change", updateDirtyState);
    });
  });
  updateDirtyState();
}

// ── Dirty tracking ────────────────────────────────────────────────────────
// Every editable cell is compared against the loaded model, so the table can
// mark exactly which rows changed and commit them in one go. The previous
// design put a Save button on every row with no indication of which ones you
// had actually touched.
function rowEdits(tr) {
  const ext = tr.dataset.ext;
  const model = extRows.find(e => e.ext === ext);
  if (!model) return null;
  const nameEl = tr.querySelector(".ext-name");
  const mobileEl = tr.querySelector(".ext-mobile");
  const modeEl = tr.querySelector(".ext-restrict");
  const numsEl = tr.querySelector(".ext-numbers");
  const msgEl = tr.querySelector(".ext-messaging");
  const vmEl = tr.querySelector(".ext-voicemail");
  const edits = {};
  if (nameEl && !nameEl.disabled && nameEl.value.trim() !== (model.name || "").trim()) edits.name = nameEl.value.trim();
  if (mobileEl && mobileEl.checked !== (model.category === "mobile")) edits.category = mobileEl.checked ? "mobile" : "standard";
  if (modeEl && modeEl.value !== model.restrict) edits.restrict = modeEl.value;
  if (numsEl && numsEl.value !== model.allowed_numbers) edits.allowed_numbers = numsEl.value;
  if (msgEl && msgEl.checked !== !!model.messaging) edits.messaging = msgEl.checked;
  if (vmEl && vmEl.checked !== !!model.voicemail) edits.voicemail = vmEl.checked;
  return {ext, model, edits, tr, count: Object.keys(edits).length};
}

function collectDirtyRows() {
  return Array.from(document.querySelectorAll("#ext-table tbody tr[data-ext]"))
    .map(rowEdits).filter(r => r && r.count > 0);
}

function updateDirtyState() {
  const dirty = collectDirtyRows();
  const dirtyExts = new Set(dirty.map(d => d.ext));
  document.querySelectorAll("#ext-table tbody tr[data-ext]").forEach(tr => {
    tr.classList.toggle("dirty", dirtyExts.has(tr.dataset.ext));
  });
  const bar = document.getElementById("ext-savebar");
  bar.classList.toggle("show", dirty.length > 0);
  document.getElementById("ext-dirty-label").textContent =
    dirty.length === 1 ? "1 extension edited" : dirty.length + " extensions edited";
}

document.getElementById("ext-discard").addEventListener("click", () => { renderExtensions(); });

// Saves only the rows that changed, and only the endpoints each change needs.
// Name and category go through the Easy Asterisk container; tier/numbers/
// messaging go through the permissions file — or, with no trunk installed,
// the messaging-only endpoint, which exists precisely because messaging has
// no PSTN dependency.
document.getElementById("ext-save-all").addEventListener("click", async () => {
  const dirty = collectDirtyRows();
  if (!dirty.length) return;
  const btn = document.getElementById("ext-save-all");
  btn.disabled = true;
  btn.textContent = "Saving…";

  let saved = 0;
  let touchedPstn = false;
  const failures = [];
  for (const row of dirty) {
    const {ext, model, edits} = row;
    try {
      if ("name" in edits) {
        const r = await postJSON("/api/ea-devices/rename", {extension: ext, name: edits.name});
        if (!r.ok) throw new Error(r.message || "rename failed");
      }
      if ("category" in edits) {
        const r = await postJSON("/api/ea-devices/category", {extension: ext, category: edits.category});
        if (!r.ok) throw new Error(r.message || "category change failed");
      }
      const permKeys = ["restrict", "allowed_numbers", "messaging"];
      if (pstnInstalled) {
        if (permKeys.some(k => k in edits) || "voicemail" in edits) {
          const messaging = "messaging" in edits ? edits.messaging : !!model.messaging;
          const voicemail = "voicemail" in edits ? edits.voicemail : !!model.voicemail;
          // Send the whole permission record, not just the changed fields —
          // the endpoint rewrites all of it, so omitting an unchanged value
          // would silently reset it.
          const r = await postJSON("/api/pstn-permissions", {
            ext: ext,
            restrict: "restrict" in edits ? edits.restrict : model.restrict,
            allowed_numbers: "allowed_numbers" in edits ? edits.allowed_numbers : model.allowed_numbers,
            messaging: messaging,
            voicemail: voicemail,
          });
          if (!r.ok) throw new Error(r.message || "permission save failed");
          markPstnDirty(); touchedPstn = true;
        }
      } else {
        // No PSTN trunk — messaging and voicemail are each independent of
        // it, so they go through their own standalone endpoints instead of
        // the combined one above.
        if (permKeys.some(k => k in edits)) {
          const messaging = "messaging" in edits ? edits.messaging : !!model.messaging;
          const r = await postJSON("/api/pstn-messaging", {ext: ext, enabled: messaging});
          if (!r.ok) throw new Error(r.message || "permission save failed");
        }
        if ("voicemail" in edits) {
          const r = await postJSON("/api/pstn-voicemail", {ext: ext, enabled: edits.voicemail});
          if (!r.ok) throw new Error(r.message || "voicemail save failed");
        }
      }
      saved++;
    } catch (err) {
      failures.push(ext + ": " + err.message);
    }
  }

  btn.disabled = false;
  btn.textContent = "Save changes";
  if (failures.length) {
    toast(`Saved ${saved}, failed ${failures.length} — ` + failures.join("; "), "err");
  } else {
    toast(`Saved ${saved} extension${saved === 1 ? "" : "s"}`, "ok");
  }
  await loadExtensions();
  if (touchedPstn) await offerPstnRestart();
});

function postJSON(url, body) {
  return fetch(url, {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify(body),
  }).then(r => r.json());
}

document.querySelectorAll("#ext-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    // Re-rendering drops uncommitted edits, so don't silently throw them away.
    if (collectDirtyRows().length &&
        !confirm("Sorting reloads the table and discards your unsaved edits. Continue?")) return;
    const key = th.dataset.sort;
    extSort.dir = (extSort.key === key) ? -extSort.dir : 1;
    extSort.key = key;
    renderExtensions();
  });
});

// ── Add extension ─────────────────────────────────────────────────────────
const extAddForm = document.getElementById("ext-add-form");
document.getElementById("ext-add-toggle").addEventListener("click", () => {
  extAddForm.classList.toggle("open");
  if (extAddForm.classList.contains("open")) document.getElementById("ea-dev-name").focus();
});
document.getElementById("ext-add-cancel").addEventListener("click", () => {
  extAddForm.classList.remove("open");
  document.getElementById("ext-add-advanced").classList.remove("open");
  document.getElementById("ext-add-advanced-toggle").textContent = "Advanced…";
});
document.getElementById("ext-add-advanced-toggle").addEventListener("click", () => {
  const adv = document.getElementById("ext-add-advanced");
  adv.classList.toggle("open");
  document.getElementById("ext-add-advanced-toggle").textContent =
    adv.classList.contains("open") ? "Hide advanced" : "Advanced…";
});
document.getElementById("ext-password-dismiss").addEventListener("click", () => {
  document.getElementById("ext-password-callout").classList.remove("show");
});
// Everything needed to configure a softphone, in one place. Previously the
// dashboard could create an extension but never tell you the server, the
// transport it had actually been written with, or the TURN credentials — so
// a correctly-created extension and a misconfigured one looked identical.
// Rendered as an extra table row immediately under the extension it
// describes, not as a panel at the top of the card. The panel version was
// genuinely missed on a long list — you clicked a row near the bottom and the
// answer appeared off-screen above you.
async function toggleEaDeviceDetails(ext) {
  if (openDetailsExt === ext) {
    closeEaDeviceDetails();
    return;
  }
  await showEaDeviceDetails(ext);
}

function closeEaDeviceDetails() {
  openDetailsExt = null;
  document.querySelectorAll("#ext-table tr.detail-row").forEach(r => r.remove());
}

async function showEaDeviceDetails(ext) {
  const res = await fetch("/api/ea-device-details?ext=" + encodeURIComponent(ext));
  if (!res.ok) { toast("No details for extension " + ext, "err"); return; }
  const d = await res.json();
  closeEaDeviceDetails();
  const anchor = document.querySelector(`#ext-table tr[data-ext="${ext}"]`);
  if (!anchor) return;
  openDetailsExt = ext;

  const colspan = anchor.children.length;
  const server = d.server || "(unknown — no domain or IP found)";
  const serverNote = d.server_is_ip
    ? ' <span class="muted">(no domain configured — using this host address; TLS cert is self-signed)</span>'
    : "";
  const turn = d.turn_server
    ? `<tr><th>TURN server</th><td><code>${esc(d.turn_server)}</code></td></tr>
       <tr><th>TURN user</th><td><code>${esc(d.turn_username)}</code></td></tr>
       <tr><th>TURN password</th><td><code>${esc(d.turn_password)}</code></td></tr>`
    : `<tr><th>TURN</th><td class="empty">${esc(d.env_error || "not set in Asterisk's .env")}</td></tr>`;

  const tr = document.createElement("tr");
  tr.className = "detail-row";
  tr.innerHTML = `<td colspan="${colspan}">
    <div class="detail-panel">
      <div class="row" style="justify-content:space-between; align-items:flex-start">
        <b>Extension ${esc(d.extension)} — ${esc(d.name)}</b>
        <span class="pill ${d.status === "online" ? "online" : "offline"}">${esc(d.status)}</span>
      </div>
      <table style="margin-top:var(--sp-2)">
        <tr><th style="width:10rem">SIP server</th><td><code>${esc(server)}</code>${serverNote}</td></tr>
        <tr><th>SIP URI</th><td><code>sip:${esc(d.extension)}@${esc(server)}:${esc(String(d.port))};transport=${esc(d.transport.toLowerCase())}</code></td></tr>
        <tr><th>Username</th><td><code>${esc(d.extension)}</code></td></tr>
        <tr><th>Password</th><td><code>${esc(d.password || "(not found)")}</code></td></tr>
        <tr><th>Transport</th><td><code>${esc(d.transport)}</code> on port <code>${esc(String(d.port))}</code>${d.encryption && d.encryption !== "no" ? " · SRTP " + esc(d.encryption) : ""}</td></tr>
        <tr><th>Device type</th><td>${d.mobile ? "mobile / cellular (RTP keepalive on)" : "standard"}</td></tr>
        ${turn}
      </table>
      <div class="row" style="margin-top:var(--sp-3)">
        <button class="action" onclick="setEaTransport('${esc(d.extension)}','${d.transport === "TLS" ? "lan" : "fqdn"}')">
          Switch to ${d.transport === "TLS" ? "LAN (UDP 5060)" : "Remote/FQDN (TLS 5061)"}
        </button>
        <button class="action" onclick="resetEaPassword('${esc(d.extension)}')">Reset password</button>
        <a class="action" style="text-decoration:none" href="/api/ea-device-provisioning?ext=${encodeURIComponent(d.extension)}" download>Download settings</a>
        <button class="action" onclick="toggleSipneticQr('${esc(d.extension)}')">Sipnetic QR code</button>
        <button class="action" onclick="closeEaDeviceDetails()">Close</button>
      </div>
      <div id="sipnetic-qr-box" style="display:none"></div>
      ${d.env_error ? `<p class="muted" style="margin:var(--sp-2) 0 0; color:var(--warn)">${esc(d.env_error)}</p>` : ""}
      <p class="muted" style="margin:var(--sp-2) 0 0">A phone that never registers is most often the transport above: an extension
      written LAN-only while the phone dials in over TLS from outside. If the Security Log shows nothing at all for it, the traffic
      isn't reaching Asterisk — check the firewall and the TLS certificate before the extension itself.</p>
    </div>
  </td>`;
  anchor.insertAdjacentElement("afterend", tr);
  tr.scrollIntoView({ block: "nearest", behavior: "smooth" });
}

// Sipnetic's documented QR account-string format (https://www.sipnetic.com/
// qr-codes) -- scan-to-configure, built server-side from the same data the
// details panel already shows. Rendered client-side with the embedded
// qrcode.js at the top of this script block so nothing here needs a CDN or
// a new Python dependency.
async function toggleSipneticQr(ext) {
  const box = document.getElementById("sipnetic-qr-box");
  if (!box) return;
  if (box.style.display !== "none" && box.dataset.ext === ext) {
    box.style.display = "none";
    box.innerHTML = "";
    return;
  }
  const res = await fetch("/api/ea-device-qr?ext=" + encodeURIComponent(ext));
  if (!res.ok) { toast("No QR data for extension " + ext, "err"); return; }
  const data = await res.json();
  box.dataset.ext = ext;
  box.innerHTML = `
    <div class="row" style="align-items:flex-start; gap:var(--sp-3); margin-top:var(--sp-3)">
      <div id="sipnetic-qr-canvas"></div>
      <div style="flex:1">
        <p class="muted" style="margin-top:0">Scan with Sipnetic (Add Account → Scan QR Code) to auto-fill this extension's SIP settings.</p>
        <p class="muted">Contains this extension's password in plain text — treat the image like the password itself.</p>
        <code style="word-break:break-all; display:block; margin-top:var(--sp-1)">${esc(data.account_string)}</code>
      </div>
    </div>`;
  box.style.display = "";
  new QRCode(document.getElementById("sipnetic-qr-canvas"), {
    text: data.account_string, width: 180, height: 180,
    correctLevel: QRCode.CorrectLevel.M,
  });
}

async function setEaTransport(ext, connType) {
  const data = await postJSON("/api/ea-devices/transport", {extension: ext, conn_type: connType});
  toast(data.message || (data.ok ? "Transport changed" : "Failed"), data.ok ? "ok" : "err");
  if (data.ok) { await loadExtensions(); await showEaDeviceDetails(ext); }
}

async function resetEaPassword(ext) {
  if (!confirm("Reset the SIP password for extension " + ext + "? The phone will stop registering until you enter the new one.")) return;
  const data = await postJSON("/api/ea-devices/password", {extension: ext});
  if (data.ok) { toast("Password reset for " + ext, "ok"); showEaDeviceDetails(ext); }
  else toast(data.message || "Failed", "err");
}

document.getElementById("ea-dev-save").addEventListener("click", async () => {
  const name = document.getElementById("ea-dev-name").value.trim();
  const extension = document.getElementById("ea-dev-ext").value.trim();
  const data = await postJSON("/api/ea-devices", {
    name,
    extension,
    category: document.getElementById("ea-dev-mobile").checked ? "mobile" : "standard",
    conn_type: document.getElementById("ea-dev-conn").value,
    auto_answer: document.getElementById("ea-dev-aa").value || null,
  });
  if (data.ok) {
    // Persistent, not a toast: this password is shown exactly once.
    document.getElementById("ext-password-text").innerHTML =
      `Added extension <b>${esc(data.data.extension)}</b> — password <code>${esc(data.data.password)}</code> ` +
      `(shown once, save it now). SIP ${esc(data.data.transport)} on port ${esc(String(data.data.port))}.`;
    document.getElementById("ext-password-callout").classList.add("show");
    document.getElementById("ea-dev-name").value = "";
    document.getElementById("ea-dev-ext").value = "";
    document.getElementById("ea-dev-mobile").checked = false;
    extAddForm.classList.remove("open");
    document.getElementById("ext-add-advanced").classList.remove("open");
    document.getElementById("ext-add-advanced-toggle").textContent = "Advanced…";
    // The password alone isn't enough to configure a phone — open the full
    // details (server, transport, TURN) immediately rather than making the
    // user hunt for them.
    showEaDeviceDetails(data.data.extension);
  } else {
    toast(data.message || "Failed to add extension", "err");
  }
  loadExtensions();
});

// Delete keeps its own control — it's destructive, so it must not ride along
// with the batched Save. Rename and category changes are part of that batch
// now, which is why their standalone handlers are gone.
async function deleteEaDevice(ext) {
  if (!confirm("Delete extension " + ext + "? This cannot be undone.")) return;
  const data = await postJSON("/api/ea-devices/delete", {extension: ext});
  toast(data.message || (data.ok ? "Deleted extension " + ext : "Delete failed"), data.ok ? "ok" : "err");
  loadExtensions();
  loadEaRooms();
}

async function loadEaRooms() {
  const res = await fetch("/api/ea-rooms");
  const data = await res.json();
  eaRooms = data.rooms || [];
  renderEaRooms();
  renderPersonalDidOwnerOptions();
  suggestRoomExtension();
}

// Fills the ring group extension field with the next number not already
// used by a device or another ring group, starting at 500 (the range the
// field's own placeholder has always suggested) — only when the field is
// currently empty, so it never clobbers something the admin is mid-typing
// or deliberately cleared. One less thing to have to think up by hand.
function suggestRoomExtension() {
  const field = document.getElementById("ea-room-ext");
  if (!field || field.value.trim()) return;
  const taken = new Set([...extRows.map(e => e.ext), ...eaRooms.map(r => r.extension)]);
  let n = 500;
  while (taken.has(String(n))) n++;
  field.value = String(n);
}

function eaRoomSortValue(r, key) {
  if (key === "extension") return parseInt(r.extension, 10);
  return (r[key] || "").toString().toLowerCase();
}

function renderEaRooms() {
  let rows = eaRooms.slice();
  if (eaRoomSort.key) {
    rows.sort((a, b) => {
      const av = eaRoomSortValue(a, eaRoomSort.key), bv = eaRoomSortValue(b, eaRoomSort.key);
      if (av < bv) return -1 * eaRoomSort.dir;
      if (av > bv) return 1 * eaRoomSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#ea-room-table th.sortable .arrow").forEach(a => a.remove());
  if (eaRoomSort.key) {
    const th = document.querySelector(`#ea-room-table th[data-sort="${eaRoomSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${eaRoomSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  setCount("room-count", eaRooms.length);
  const tbody = document.querySelector("#ea-room-table tbody");
  tbody.innerHTML = rows.map(r => {
    const memberExts = (r.members || "").split(",").filter(Boolean);
    const memberChips = memberExts.map(ext => {
      const dev = eaDevices.find(d => d.extension === ext);
      const label = dev ? `${esc(ext)} — ${esc(dev.name)}` : esc(ext);
      return `<span style="display:inline-flex;gap:0.25rem;align-items:center;margin:0.1rem;padding:0.1rem 0.4rem;background:#0f1115;border:1px solid #2a2e38;border-radius:4px;font-size:0.8rem">
        ${label}
        <button class="action" style="padding:0 0.3rem" onclick="removeEaRoomMember('${esc(r.extension)}','${esc(ext)}')">&times;</button>
      </span>`;
    }).join("");
    const available = eaDevices.filter(d => !memberExts.includes(d.extension));
    const addPicker = available.length
      ? `<select style="width:auto">${available.map(d => `<option value="${esc(d.extension)}">${esc(d.extension)} — ${esc(d.name)}</option>`).join("")}</select>
         <button class="action" onclick="addEaRoomMemberFromRow('${esc(r.extension)}', this)">+</button>`
      : '<span class="muted">no more devices</span>';
    const didRecord = lastPersonalDids.find(d => d.owner === "@" + r.name);
    const didCell = didRecord
      ? `${esc(didRecord.did)} <button class="action" onclick="removeRoomDid('${esc(didRecord.did)}')">Remove</button>`
      : `<input type="text" class="room-did-input" placeholder="10-digit DID" style="width:9rem">
         <button class="action" onclick="assignRoomDid('${esc(r.name)}', this)">Assign</button>`;
    return `<tr data-ext="${esc(r.extension)}">
      <td>${esc(r.extension)}</td>
      <td>${esc(r.name)}</td>
      <td>${memberChips || '<span class="muted">none</span>'}<br>${addPicker}</td>
      <td><input type="text" class="room-timeout-input" value="${esc(r.timeout)}" style="width:5rem"></td>
      <td><select class="room-type-select">
        <option value="ring" ${r.type === "ring" ? "selected" : ""}>Ring</option>
        <option value="page" ${r.type === "page" ? "selected" : ""}>Page</option>
      </select></td>
      <td class="pstn-only">${didCell}</td>
      <td class="actions">
        <button class="action" onclick="saveEaRoomSettings('${esc(r.extension)}', this)">Save</button>
        <button class="action" onclick="renameEaRoom('${esc(r.extension)}')">Rename</button>
        <button class="action danger" onclick="deleteEaRoom('${esc(r.extension)}')">Delete</button>
      </td>
    </tr>`;
  }).join("") || '<tr><td colspan=7 class=empty>No rooms yet.</td></tr>';
}

async function saveEaRoomSettings(ext, btn) {
  const row = btn.closest("tr");
  const type = row.querySelector(".room-type-select").value;
  const timeout = row.querySelector(".room-timeout-input").value.trim() || "60";
  const res = await fetch("/api/ea-rooms/settings", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({extension: ext, type, timeout}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Room settings saved" : "Failed"), data.ok ? "ok" : "err");
  loadEaRooms();
}

document.querySelectorAll("#ea-room-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    eaRoomSort.dir = (eaRoomSort.key === key) ? -eaRoomSort.dir : 1;
    eaRoomSort.key = key;
    renderEaRooms();
  });
});

document.getElementById("ea-room-save").addEventListener("click", async () => {
  const extension = document.getElementById("ea-room-ext").value.trim();
  const name = document.getElementById("ea-room-name").value.trim();
  const type = document.getElementById("ea-room-type").value;
  const timeout = document.getElementById("ea-room-timeout").value.trim() || "60";
  const members = Array.from(document.querySelectorAll(".ea-room-member-cb:checked")).map(cb => cb.value);
  const res = await fetch("/api/ea-rooms", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({extension, name, type, timeout, members}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Ring group added" : "Failed"), data.ok ? "ok" : "err");
  if (data.ok) {
    document.getElementById("ea-room-ext").value = "";
    document.getElementById("ea-room-name").value = "";
    document.querySelectorAll(".ea-room-member-cb:checked").forEach(cb => { cb.checked = false; });
  }
  loadEaRooms();
});

// Whether a Ring Group's membership change is PSTN-relevant right now — only
// true once it's actually assigned as a personal number's owner (see
// sync_room_group_mirror() in app.py). Most Ring Groups never are, and
// prompting a restart on every ordinary membership tweak would be noise;
// this keeps the restart nudge scoped to edits that can actually go stale.
function roomOwnsPersonalDid(roomName) {
  return lastPersonalDids.some(d => d.owner === "@" + roomName);
}

async function renameEaRoom(ext) {
  const cur = eaRooms.find(r => r.extension === ext);
  const name = prompt("New name for room " + ext + ":", cur ? cur.name : "");
  if (name === null || !name.trim()) return;
  const wasPstnRelevant = cur && pstnInstalled && roomOwnsPersonalDid(cur.name);
  const res = await fetch("/api/ea-rooms/rename", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({extension: ext, name: name.trim()}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Room renamed" : "Failed"), data.ok ? "ok" : "err");
  loadEaRooms();
  if (data.ok && wasPstnRelevant) { markPstnDirty(); await offerPstnRestart(); }
}

async function deleteEaRoom(ext) {
  if (!confirm("Delete room " + ext + "? This cannot be undone.")) return;
  const cur = eaRooms.find(r => r.extension === ext);
  const wasPstnRelevant = cur && pstnInstalled && roomOwnsPersonalDid(cur.name);
  const res = await fetch("/api/ea-rooms/delete", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({extension: ext}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Room deleted" : "Failed"), data.ok ? "ok" : "err");
  loadEaRooms();
  if (data.ok && wasPstnRelevant) { markPstnDirty(); await offerPstnRestart(); }
}

async function addEaRoomMemberFromRow(roomExt, btn) {
  const select = btn.previousElementSibling;
  const device = select.value;
  if (!device) return;
  const cur = eaRooms.find(r => r.extension === roomExt);
  const pstnRelevant = cur && pstnInstalled && roomOwnsPersonalDid(cur.name);
  const res = await fetch("/api/ea-rooms/members/add", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({room: roomExt, device}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Member added" : "Failed"), data.ok ? "ok" : "err");
  loadEaRooms();
  if (data.ok && pstnRelevant) { markPstnDirty(); await offerPstnRestart(); }
}

async function removeEaRoomMember(roomExt, device) {
  const cur = eaRooms.find(r => r.extension === roomExt);
  const pstnRelevant = cur && pstnInstalled && roomOwnsPersonalDid(cur.name);
  const res = await fetch("/api/ea-rooms/members/remove", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({room: roomExt, device}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Member removed" : "Failed"), data.ok ? "ok" : "err");
  loadEaRooms();
  if (data.ok && pstnRelevant) { markPstnDirty(); await offerPstnRestart(); }
}

// Assign/remove a Ring Group's personal number right from its own row —
// same underlying write as the Personal Numbers card's owner picker
// ("@name"), just surfaced here too so a group's DID doesn't require a
// separate trip to that card.
async function assignRoomDid(roomName, btn) {
  const input = btn.previousElementSibling;
  const did = input.value.trim();
  if (!did) return;
  const res = await fetch("/api/pstn-personal-dids", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did, owner: "@" + roomName}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Number assigned" : "Failed"), data.ok ? "ok" : "err");
  await loadPersonalDids();
  loadEaRooms();
  if (data.ok) { markPstnDirty(); await offerPstnRestart(); }
}

async function removeRoomDid(did) {
  if (!confirm("Remove personal number " + did + " from this ring group? Members lose it as their outbound Caller-ID and stop ringing on inbound calls to it.")) return;
  const res = await fetch("/api/pstn-personal-dids/delete", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Number removed" : "Failed"), data.ok ? "ok" : "err");
  await loadPersonalDids();
  loadEaRooms();
  if (data.ok) { markPstnDirty(); await offerPstnRestart(); }
}

// "Commit Changes" — see restart_asterisk_container()'s comment in app.py
// for why this button exists: AST_CONFIG() live-reads of these PSTN config
// files have been confirmed to sometimes stay stale (returning what was on
// disk at last container start, not the freshly-saved value) until a full
// container restart, contradicting the "no restart needed" premise the
// rest of this tab's copy otherwise relies on. pstnDirty tracks whether
// ANY save on this tab succeeded since the last restart (or page load),
// shows a persistent banner, and warns on tab-close/navigation so a change
// doesn't silently sit uncommitted.
let pstnDirty = false;
function markPstnDirty() {
  pstnDirty = true;
  document.getElementById("pstn-restart-banner").style.display = "";
}
window.addEventListener("beforeunload", (e) => {
  // Two independent kinds of "unsaved": edits still sitting in the table, and
  // saved-but-not-yet-committed PSTN config the dialplan may still be stale on.
  const tableDirty = typeof collectDirtyRows === "function" && collectDirtyRows().length > 0;
  if (!pstnDirty && !tableDirty) return;
  e.preventDefault();
  e.returnValue = "";
});
async function commitPstnRestart() {
  const msg = document.getElementById("pstn-restart-msg");
  msg.textContent = "Restarting Asterisk…";
  const res = await fetch("/api/asterisk-restart", { method: "POST" });
  const data = await res.json();
  msg.textContent = data.message || (data.ok ? "Restarted" : "Failed");
  if (data.ok) {
    pstnDirty = false;
    document.getElementById("pstn-restart-banner").style.display = "none";
  }
  return data.ok;
}
document.getElementById("pstn-restart-btn").addEventListener("click", commitPstnRestart);

// The banner above is easy to miss (confirmed live — the actual "phantom"
// this was built for: an admin saves a permission change, tests a call
// minutes later against Asterisk's still-stale read, and has no reason to
// suspect the save itself). Ask right at the moment of save instead of only
// leaving a passive banner — restart is still opt-in per prompt (not
// automatic) since it drops any calls in progress right now, which a save
// action alone never does. Call this once per logical user action (a
// single save/delete, or one whole batch), never inside a per-row loop, or
// multiple saves in one batch would each pop their own dialog.
async function offerPstnRestart() {
  if (confirm("Saved. Asterisk won't use this change until it restarts, which will hang up any calls in progress right now. Restart Asterisk now?")) {
    await commitPstnRestart();
  }
}

// The personal-DID owner picker spans both lists, so it re-renders from
// whichever of the two finished last rather than being owned by either.
// "@name" mirrors what sync_room_group_mirror()/pstn-personal-group-ring.sh
// expect — a Ring Group's NAME, not its extension, is the join key.
function renderPersonalDidOwnerOptions() {
  const ownerSel = document.getElementById("pd-owner");
  if (!ownerSel) return;
  const extOptions = extRows.map(e => `<option value="${esc(e.ext)}">${esc(e.ext)} — ${esc(e.name)}</option>`).join("");
  const roomOptions = eaRooms.map(r => `<option value="@${esc(r.name)}">Ring Group: ${esc(r.name)}</option>`).join("");
  ownerSel.innerHTML = (extOptions + roomOptions) || '<option value="">No extensions found</option>';
}

let lastPersonalDids = [];
let pdSort = { key: null, dir: 1 };

function pdSortValue(d, key) {
  if (key === "did") return parseInt(d.did, 10);
  if (key === "owner") return d.owner.startsWith("@") ? d.owner.slice(1).toLowerCase() : d.owner.toLowerCase();
  return "";
}

function renderPersonalDids() {
  let rows = lastPersonalDids.slice();
  if (pdSort.key) {
    rows.sort((a, b) => {
      const av = pdSortValue(a, pdSort.key), bv = pdSortValue(b, pdSort.key);
      if (av < bv) return -1 * pdSort.dir;
      if (av > bv) return 1 * pdSort.dir;
      return 0;
    });
  }
  document.querySelectorAll("#pd-table th.sortable .arrow").forEach(a => a.remove());
  if (pdSort.key) {
    const th = document.querySelector(`#pd-table th[data-sort="${pdSort.key}"]`);
    if (th) th.insertAdjacentHTML("beforeend", `<span class="arrow">${pdSort.dir === 1 ? "▲" : "▼"}</span>`);
  }
  setCount("pd-count", lastPersonalDids.length);
  const tbody = document.querySelector("#pd-table tbody");
  tbody.innerHTML = rows.map(d => {
    const ownerDisplay = d.owner.startsWith("@")
      ? "Group: " + esc(d.owner.slice(1))
      : esc(d.owner) + (d.owner_name ? " — " + esc(d.owner_name) : "");
    return `<tr>
    <td>${esc(d.did)}</td>
    <td>${ownerDisplay}</td>
    <td class="actions"><button class="action danger" onclick="removePersonalDid('${esc(d.did)}')">Remove</button></td>
  </tr>`;
  }).join("") || "<tr><td colspan=3 class=empty>No personal numbers assigned — every extension shares the main trunk DID.</td></tr>";
}

document.querySelectorAll("#pd-table th.sortable").forEach(th => {
  th.addEventListener("click", () => {
    const key = th.dataset.sort;
    pdSort.dir = (pdSort.key === key) ? -pdSort.dir : 1;
    pdSort.key = key;
    renderPersonalDids();
  });
});

async function loadPersonalDids() {
  const res = await fetch("/api/pstn-personal-dids");
  const data = await res.json();
  lastPersonalDids = data.dids || [];
  renderPersonalDids();
  // Ring Groups' own Personal number column reads this same data — re-render
  // it too so a group's assigned DID shows up even though rooms load first.
  renderEaRooms();
}

document.getElementById("pd-save").addEventListener("click", async () => {
  const did = document.getElementById("pd-did").value.trim();
  const owner = document.getElementById("pd-owner").value;
  const res = await fetch("/api/pstn-personal-dids", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did, owner: owner}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Number assigned" : "Failed"), data.ok ? "ok" : "err");
  if (data.ok) {
    document.getElementById("pd-did").value = "";
    markPstnDirty();
  }
  loadPersonalDids();
  if (data.ok) await offerPstnRestart();
});

async function removePersonalDid(did) {
  if (!confirm("Remove personal number " + did + "? Its owner falls back to the shared trunk DID for outbound Caller-ID, and this DID stops routing anywhere until reassigned.")) return;
  const res = await fetch("/api/pstn-personal-dids/delete", {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify({did: did}),
  });
  const data = await res.json();
  toast(data.message || (data.ok ? "Number removed" : "Failed"), data.ok ? "ok" : "err");
  if (data.ok) { markPstnDirty(); await offerPstnRestart(); }
  loadPersonalDids();
}

loadSecurity();
loadCalls();
loadTexts();
loadDecisions();
loadAsnExempt();
loadCrowdsecStatus();
initExtensionsTab();
loadVoicemail();
setInterval(loadSecurity, 30000);
setInterval(loadCalls, 30000);
setInterval(loadTexts, 30000);
setInterval(loadDecisions, 30000);
// No setInterval for voicemail (unlike the tabs above) — re-rendering the
// table while a message is mid-playback would yank the <audio> element out
// from under the user. Refreshed on tab click instead (see the .tab-btn
// listener above) and once here at page load.
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
        # The page is inlined into this file, so a dashboard update changes
        # the HTML at a URL that never changes. Without this a browser can
        # keep serving the previous UI after an upgrade, which looks exactly
        # like the upgrade having silently failed.
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/" or self.path == "":
            html = INDEX_HTML
            self._html(html)
        elif self.path == "/api/security-events":
            self._json(parse_security_log())
        elif self.path == "/api/pstn-calls":
            self._json(filter_calls_by_scope(parse_pstn_calls(), _admin_scope_for_request(self)))
        elif self.path == "/api/comms-texts":
            self._json(filter_calls_by_scope(parse_texts(), _admin_scope_for_request(self)))
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
                p = perms.get(e["ext"], {"restrict": "internal", "allowed_numbers": "",
                                          "messaging": False, "voicemail": False, "voicemail_pin": ""})
                extensions.append({"ext": e["ext"], "name": e["name"],
                                    "restrict": p["restrict"],
                                    "allowed_numbers": p["allowed_numbers"],
                                    "messaging": p["messaging"],
                                    "voicemail": p["voicemail"],
                                    "voicemail_pin": p["voicemail_pin"]})
            self._json({"extensions": extensions})
        elif self.path == "/api/pstn-limits":
            self._json(get_limits())
        elif self.path == "/api/pstn-personal-dids":
            names = {e["ext"]: e["name"] for e in list_extensions()}
            dids = [dict(d, owner_name=names.get(d["owner"], "")) for d in list_personal_dids()]
            self._json({"dids": dids})
        elif self.path == "/api/pstn-status":
            self._json({"installed": pstn_installed()})
        elif self.path == "/api/crowdsec-status":
            self._json({"installed": crowdsec_installed()})
        elif self.path == "/api/ea-status":
            payload = {"installed": ea_installed()}
            if payload["installed"]:
                payload.update(ea_connection_defaults())
                payload.pop("turn_password", None)   # not needed until a row asks
            self._json(payload)
        elif self.path == "/download/kiosk-client-installer.sh":
            if not os.path.isfile(KIOSK_INSTALLER_SCRIPT):
                self._json({"error": "not found"}, 404)
            else:
                with open(KIOSK_INSTALLER_SCRIPT, "rb") as f:
                    raw = f.read()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Disposition",
                                 'attachment; filename="easy-asterisk-kiosk-client-installer.sh"')
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(raw)
        elif self.path.startswith("/api/ea-device-qr?"):
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1])
            account_string = ea_device_sipnetic_string((qs.get("ext") or [""])[0])
            if account_string is None:
                self._json({"error": "not found"}, 404)
            else:
                self._json({"account_string": account_string})
        elif self.path.startswith("/api/ea-device-provisioning?"):
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1])
            filename, body = ea_device_provisioning((qs.get("ext") or [""])[0])
            if not body:
                self._json({"error": "not found"}, 404)
            else:
                raw = body.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/plain; charset=utf-8")
                self.send_header("Content-Disposition",
                                 'attachment; filename="%s"' % filename)
                self.send_header("Content-Length", str(len(raw)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(raw)
        elif self.path.startswith("/api/ea-device-details?"):
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1])
            details = ea_device_details((qs.get("ext") or [""])[0])
            if details:
                self._json(details)
            else:
                self._json({"error": "not found"}, 404)
        elif self.path == "/api/ea-devices":
            self._json({"devices": ea_list_devices(), "status": ea_get_status()})
        elif self.path == "/api/ea-rooms":
            self._json({"rooms": ea_list_rooms()})
        elif self.path == "/api/voicemail":
            self._json({"messages": filter_voicemail_by_scope(list_voicemail_messages(), _admin_scope_for_request(self))})
        elif self.path.startswith("/voicemail/audio?"):
            qs = urllib.parse.parse_qs(self.path.split("?", 1)[1])
            ext = (qs.get("ext") or [""])[0]
            allowed = _admin_scope_for_request(self)
            # Scoping isn't just a list filter — a URL with a bare ext/msg
            # guessed or copy-pasted from elsewhere must not bypass it, so
            # this checks the SAME scope directly before ever resolving the
            # file, not just before it appears in /api/voicemail's list.
            if allowed is not None and ext not in allowed:
                self._json({"error": "not found"}, 404)
            else:
                path = voicemail_audio_path(ext, (qs.get("msg") or [""])[0])
                if not path:
                    self._json({"error": "not found"}, 404)
                else:
                    with open(path, "rb") as f:
                        raw = f.read()
                    self.send_response(200)
                    self.send_header("Content-Type", "audio/wav")
                    self.send_header("Content-Length", str(len(raw)))
                    self.send_header("Cache-Control", "no-store")
                    self.end_headers()
                    self.wfile.write(raw)
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
                payload.get("ext", ""),
                payload.get("restrict", ""), payload.get("allowed_numbers", ""),
                bool(payload.get("messaging", False)),
                bool(payload.get("voicemail", False)),
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
        elif self.path == "/api/pstn-voicemail":
            ok, message = write_voicemail(payload.get("ext", ""), bool(payload.get("enabled", False)))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/asterisk-restart":
            ok, message = restart_asterisk_container()
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-devices":
            ok, result = ea_add_device(
                payload.get("name", ""), payload.get("category", ""), payload.get("extension", ""),
                payload.get("conn_type", "lan"), payload.get("auto_answer")
            )
            if ok:
                self._json({"ok": True, "data": result})
            else:
                self._json({"ok": False, "message": result})
        elif self.path == "/api/ea-devices/delete":
            ok, message = ea_delete_device(payload.get("extension", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-devices/rename":
            ok, message = ea_rename_device(payload.get("extension", ""), payload.get("name", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-devices/transport":
            ok, message = ea_set_device_transport(payload.get("extension", ""), payload.get("conn_type", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-devices/password":
            ok, result = ea_reset_device_password(payload.get("extension", ""))
            if ok:
                self._json({"ok": True, "password": result})
            else:
                self._json({"ok": False, "message": result})
        elif self.path == "/api/ea-devices/category":
            ok, message = ea_change_device_category(payload.get("extension", ""), payload.get("category", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms":
            ok, message = ea_create_room(
                payload.get("extension", ""), payload.get("name", ""),
                payload.get("type", "ring"), payload.get("timeout", "60"),
                payload.get("members", [])
            )
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms/delete":
            ok, message = ea_delete_room(payload.get("extension", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms/rename":
            ok, message = ea_rename_room(payload.get("extension", ""), payload.get("name", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms/settings":
            ok, message = ea_update_room_settings(
                payload.get("extension", ""), payload.get("type", ""), payload.get("timeout", "")
            )
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms/members/add":
            ok, message = ea_add_room_member(payload.get("room", ""), payload.get("device", ""))
            self._json({"ok": ok, "message": message})
        elif self.path == "/api/ea-rooms/members/remove":
            ok, message = ea_remove_room_member(payload.get("room", ""), payload.get("device", ""))
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
