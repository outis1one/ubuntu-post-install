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

register_service security-dashboard homelab "Security dashboard: Asterisk failed-connections + extension/trunk management + CrowdSec bans (Authelia-protected)" 8092

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
    local ASTERISK_EA_CONTAINER=""
    if [[ "$ASTERISK_EA_DIR" == *asterisk-digital-ocean ]]; then
        ASTERISK_EA_CONTAINER="easy-asterisk-do"
    elif [ -n "$ASTERISK_EA_DIR" ]; then
        ASTERISK_EA_CONTAINER="easy-asterisk"
    fi

    echo ""
    echo "┌─────────────────────────────────────────────────────────────────┐"
    echo "│ SECURITY DASHBOARD                                               │"
    echo "│ Asterisk failed-connection log + one Extensions tab (devices,   │"
    echo "│ ring groups, PSTN tiers, personal DIDs) + CrowdSec bans,        │"
    echo "│ one page. Runs natively on the host (not Docker) so it can call │"
    echo "│ cscli and read Asterisk's files directly. Authelia-protected.   │"
    echo "└─────────────────────────────────────────────────────────────────┘"
    echo ""

    if [ -z "$ASTERISK_EA_DIR" ]; then
        log_warning "No Asterisk install detected."
        log_warning "The Security Log and Extensions tabs will just be empty — CrowdSec's tab"
        log_warning "still works fine."
    fi

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create system user $SVC_USER"
        echo "[DRY-RUN] Would write $APP_DIR/app.py"
        echo "[DRY-RUN] Would write /etc/sudoers.d/security-dashboard (scoped cscli/systemctl/set-asn-exempt.sh only)"
        echo "[DRY-RUN] Would write a systemd unit and start it on 0.0.0.0:$DASHBOARD_PORT (firewalled via UFW, not interface binding)"
        echo "[DRY-RUN] Would grant read/write access to the detected Asterisk config dir (for the Extensions tab)"
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
                _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR"
                _secdash_write_app "$APP_DIR"
                _secdash_write_asn_helper "$APP_DIR"
                _secdash_write_sudoers "$SVC_USER" "$ASTERISK_EA_CONTAINER"
                _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_EA_CONTAINER"
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

    _secdash_grant_asterisk_access "$SVC_USER" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR"

    mkdir -p "$APP_DIR"
    _secdash_write_app "$APP_DIR"
    chown -R "$SVC_USER:$SVC_USER" "$APP_DIR"
    _secdash_write_asn_helper "$APP_DIR"

    _secdash_write_sudoers "$SVC_USER" "$ASTERISK_EA_CONTAINER"
    _secdash_write_systemd_unit "$APP_DIR" "$SVC_USER" "$DASHBOARD_PORT" "$ASTERISK_LOG_DIR" "$ASTERISK_CONFIG_DIR" "$ASTERISK_EA_CONFIG_DIR" "$ASTERISK_EA_CONTAINER"

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

Three tabs: **Security Log**, **Extensions**, **CrowdSec**. The first two are
always there (they only need Asterisk itself, detected once at install time);
CrowdSec checks its own live install state on every page load and hides its
nav button if \`cscli\` isn't found.

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
- **Extensions** — one row per extension, merged from \`pjsip.conf\` (which
  always works) and, when the Easy Asterisk container is reachable, its own
  device list. Columns: Ext, Name, then Category/Status/Transport if that
  container is present, then **PSTN** + **Whitelist** if a trunk dialplan is
  installed, then Messaging (always: internal SIP texting has no PSTN
  dependency at all — no cost, no carrier, no DID).

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
    local _svc_user="$1" _log_dir="$2" _config_dir="$3" _ea_config_dir="${4:-}"

    command -v setfacl >/dev/null 2>&1 || run_cmd apt-get install -y acl >/dev/null 2>&1
    local _have_acl=false
    command -v setfacl >/dev/null 2>&1 && _have_acl=true
    [ "$_have_acl" = true ] || log_warning "Package 'acl' unavailable — falling back to group-based access, which can silently break again whenever the Asterisk container re-chowns its own config directory. Install 'acl' and re-run to fix that properly."

    local _dir
    for _dir in "$_log_dir" "$_config_dir" "$_ea_config_dir"; do
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
    local _app_dir="$1" _svc_user="$2" _port="$3" _log_dir="$4" _config_dir="$5" _ea_config_dir="${6:-}" _ea_container="${7:-}"
    local _read_only_paths="" _read_write_paths="/etc/crowdsec/scenarios"
    [ -n "$_log_dir" ] && _read_only_paths="$_log_dir"
    [ -n "$_ea_config_dir" ] && _read_only_paths="$_read_only_paths $_ea_config_dir"
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
Environment=ASTERISK_CONFIG_DIR=$_config_dir
Environment=ASTERISK_EA_CONFIG_DIR=$_ea_config_dir
Environment=ASTERISK_EA_CONTAINER=$_ea_container
Environment=ASTERISK_EA_ENV=${_config_dir%/config/asterisk}/.env
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
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("DASHBOARD_PORT", "8092"))
ASTERISK_LOG = os.environ.get("ASTERISK_LOG", "")
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
    "; PLUS two\n"
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


def write_permission(ext, restrict, numbers_raw, messaging_enabled=False):
    """Saves one extension's PSTN restriction mode, its single whitelist, and
    its messaging flag in one action.

    One list, not two: the whitelist is "the numbers this extension deals
    with", and the mode says whether that constrains dialling out, being
    called, or both. Modes are internal / restricted / full (the original
    tiers) plus restricted-in and restricted-out.

    Writes three layers, all derived from those two authored values:
      restrict, allowed_numbers      what a human edits (and what this reads back)
      tier_out/allowed_out,
      tier_in/allowed_in             what the dialplan reads
      tier, allowed_numbers          rollback mirror for a pre-split installer

    Messaging is an independent axis (see pstn-trunk.sh's file-level comment:
    an extension can have no PSTN at all and still be messaging-enabled, or
    vice versa), so it's set/cleared regardless of the mode.

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

    # Drop the section entirely once nothing is left in it — only reachable
    # when the mode is internal, messaging is off, and no personal_did was
    # ever assigned.
    if cp.has_section(ext) and not cp.options(ext):
        cp.remove_section(ext)

    ok, err = _write_ini_cp(_permissions_path(), PERMISSIONS_HEADER, cp)
    if not ok:
        return False, err

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


def _read_ea_env():
    """DOMAIN_NAME / TURN_* out of the Asterisk install's .env.

    Everything a softphone needs beyond the extension itself lives here, and
    it is the single reason the dashboard is granted read on that file (see
    _secdash_grant_asterisk_access). Missing or unreadable is not an error —
    the UI just shows what it can and says the rest is unavailable."""
    values = {}
    if not ASTERISK_EA_ENV or not os.path.isfile(ASTERISK_EA_ENV):
        return values
    try:
        with open(ASTERISK_EA_ENV, errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                values[key.strip()] = val.strip().strip('"').strip("'")
    except OSError:
        pass
    return values


def _ea_env_problem():
    """Why .env couldn't be read, in words, or "" if it was fine.

    "not configured" is the wrong message when the truth is "this service was
    never told where the file is" or "permission denied" — both of which
    happened in practice and both of which look identical from the UI unless
    the reason is carried through."""
    if not ASTERISK_EA_ENV:
        return ("This service doesn't know where Asterisk's .env is "
                "(ASTERISK_EA_ENV unset). Re-run: sudo ./setup.sh security-dashboard")
    if not os.path.isfile(ASTERISK_EA_ENV):
        return "Asterisk's .env not found at %s" % ASTERISK_EA_ENV
    if not os.access(ASTERISK_EA_ENV, os.R_OK):
        return ("No permission to read %s. Re-run: sudo ./setup.sh security-dashboard"
                % ASTERISK_EA_ENV)
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
    # A readable .env with an empty TURN_SERVER is its own distinct case: the
    # install simply never set one (LAN-only with no FQDN), which is not an
    # error and shouldn't read like one.
    if not problem and not turn_server:
        problem = ("TURN_SERVER is empty in %s — set it there and restart Asterisk "
                   "if this phone needs a relay." % ASTERISK_EA_ENV)
    return {
        "domain": domain,
        "default_conn_type": "fqdn" if domain else "lan",
        "turn_server": turn_server,
        "turn_username": env.get("TURN_USERNAME", ""),
        "turn_password": env.get("TURN_PASSWORD", ""),
        "env_readable": not _ea_env_problem(),
        "env_error": problem,
    }


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
        "server": conn["domain"] or "",
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
    <button class="tab-btn active" data-tab="extensions">Extensions</button>
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
</main>
<div id="toasts"></div>
<script>
function esc(s) { return (s || "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }

const TABS = ["security", "extensions", "crowdsec"];
document.querySelectorAll(".tab-btn").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab-btn").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    TABS.forEach(t => { document.getElementById("tab-" + t).style.display = btn.dataset.tab === t ? "" : "none"; });
    if (btn.dataset.tab === "extensions") refreshExtensionsTab();
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
    messaging: e.messaging, ea: false, category: "", status: "", transport: "", encryption: "",
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
  const edits = {};
  if (nameEl && !nameEl.disabled && nameEl.value.trim() !== (model.name || "").trim()) edits.name = nameEl.value.trim();
  if (mobileEl && mobileEl.checked !== (model.category === "mobile")) edits.category = mobileEl.checked ? "mobile" : "standard";
  if (modeEl && modeEl.value !== model.restrict) edits.restrict = modeEl.value;
  if (numsEl && numsEl.value !== model.allowed_numbers) edits.allowed_numbers = numsEl.value;
  if (msgEl && msgEl.checked !== !!model.messaging) edits.messaging = msgEl.checked;
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
      if (permKeys.some(k => k in edits)) {
        const messaging = "messaging" in edits ? edits.messaging : !!model.messaging;
        let r;
        if (pstnInstalled) {
          // Send the whole permission record, not just the changed fields —
          // the endpoint rewrites all of it, so omitting an unchanged value
          // would silently reset it.
          r = await postJSON("/api/pstn-permissions", {
            ext: ext,
            restrict: "restrict" in edits ? edits.restrict : model.restrict,
            allowed_numbers: "allowed_numbers" in edits ? edits.allowed_numbers : model.allowed_numbers,
            messaging: messaging,
          });
        } else {
          r = await postJSON("/api/pstn-messaging", {ext: ext, enabled: messaging});
        }
        if (!r.ok) throw new Error(r.message || "permission save failed");
        if (pstnInstalled) { markPstnDirty(); touchedPstn = true; }
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
  const server = d.server
    || "(no domain in Asterisk's .env — use this box's public IP)";
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
        <tr><th style="width:10rem">SIP server</th><td><code>${esc(server)}</code></td></tr>
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
        <button class="action" onclick="closeEaDeviceDetails()">Close</button>
      </div>
      ${d.env_error ? `<p class="muted" style="margin:var(--sp-2) 0 0; color:var(--warn)">${esc(d.env_error)}</p>` : ""}
      <p class="muted" style="margin:var(--sp-2) 0 0">A phone that never registers is most often the transport above: an extension
      written LAN-only while the phone dials in over TLS from outside. If the Security Log shows nothing at all for it, the traffic
      isn't reaching Asterisk — check the firewall and the TLS certificate before the extension itself.</p>
    </div>
  </td>`;
  anchor.insertAdjacentElement("afterend", tr);
  tr.scrollIntoView({ block: "nearest", behavior: "smooth" });
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
      <td>${esc(r.timeout)}</td>
      <td>${esc(r.type)}</td>
      <td class="pstn-only">${didCell}</td>
      <td class="actions">
        <button class="action" onclick="renameEaRoom('${esc(r.extension)}')">Rename</button>
        <button class="action danger" onclick="deleteEaRoom('${esc(r.extension)}')">Delete</button>
      </td>
    </tr>`;
  }).join("") || '<tr><td colspan=7 class=empty>No rooms yet.</td></tr>';
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
loadDecisions();
loadAsnExempt();
loadCrowdsecStatus();
initExtensionsTab();
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
                p = perms.get(e["ext"], {"restrict": "internal", "allowed_numbers": "", "messaging": False})
                extensions.append({"ext": e["ext"], "name": e["name"],
                                    "restrict": p["restrict"],
                                    "allowed_numbers": p["allowed_numbers"],
                                    "messaging": p["messaging"]})
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
