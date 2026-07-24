#!/bin/bash
# services/asterisk-digital-ocean.sh — Easy Asterisk PBX + coturn, tuned for a
# public DigitalOcean droplet (public-IP FQDN by default, DO Cloud Firewall
# setup, no LAN/VLAN prompts). For a home/LAN box use services/asterisk.sh
# instead.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on a fresh droplet:
#   sudo bash asterisk-digital-ocean.sh
# (Docker must already be installed when run standalone)

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

        prompt_reinstall_mode() {
            local _var="$1" _r
            if [[ "${UNATTENDED:-false}" == "true" ]]; then
                eval "$_var='cancel'"
                echo "Existing install detected — leaving it as-is [auto: cancel, unattended mode]"
                return
            fi
            echo "  Existing install detected. Choose:"
            echo "    r) Reinstall in place — refresh vendor files/config, keep existing settings"
            echo "    f) Full install — re-run every prompt from scratch"
            echo "    c) Cancel — leave everything as-is [default]"
            read -r -p "  Choice [r/f/c, Enter=cancel]: " _r
            case "${_r,,}" in
                r) eval "$_var='update'" ;;
                f) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK
)"

            if [[ "$_mode" == "local" ]]; then
                if [[ -f "$_caddyfile" ]]; then
                    local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                    cp "$_caddyfile" "$_bk"
                    log_info "Backed up Caddyfile to $(basename "$_bk")"
                else
                    touch "$_caddyfile"
                fi

                if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                    log_warning "$_domain already in Caddyfile"
                    local _ow=""
                    read -r -p "  Overwrite? [y/N]: " _ow
                    [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                    sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
                fi

                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                # The template Caddyfile ships with "admin off", so `caddy
                # reload` (which needs that same admin API) never actually
                # works here. Try it anyway, fall back to a restart.
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                elif docker restart caddy &>/dev/null; then
                    log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                    log_success "$_name should be accessible at: https://$_domain"
                else
                    log_warning "Reload/restart failed — check: docker logs caddy"
                    log_info "Manual fix: docker restart caddy"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
        }

        write_readme() {
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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

register_service asterisk-digital-ocean homelab "Easy Asterisk PBX + coturn, tuned for a public DigitalOcean droplet" 5061

# ── Shared: vendor file refresh ────────────────────────────────────────────
# Called from both a fresh install and an "update in place" run, so a single
# copy of this logic stays current for both instead of drifting apart. Must
# be called with $PWD already at $EA_DIR.
_asterisk_do_refresh_vendor_files() {
    mkdir -p docker scripts

    local _SELF_DIR_LOCAL
    _SELF_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local VENDOR_DIR="$_SELF_DIR_LOCAL/../vendor/easy-asterisk"

    if [[ -d "$VENDOR_DIR" ]]; then
        log_info "Copying vendor files from $VENDOR_DIR ..."
        cp "$VENDOR_DIR/Dockerfile"                    ./Dockerfile
        cp "$VENDOR_DIR/docker/entrypoint.sh"          ./docker/entrypoint.sh
        cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"   ./docker/coturn-entrypoint.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk-v0.10.0.sh
        cp "$VENDOR_DIR/scripts/vpn-diagnostics.sh"    ./scripts/vpn-diagnostics.sh
        cp "$VENDOR_DIR/scripts/dns-whitelist.sh"      ./scripts/dns-whitelist.sh
    else
        log_info "Vendor directory not found — downloading from GitHub ..."
        local GH_RAW="https://raw.githubusercontent.com/DeadDork/easy-asterisk/main"
        curl -fsSL "$GH_RAW/Dockerfile"                        -o ./Dockerfile
        curl -fsSL "$GH_RAW/docker/entrypoint.sh"              -o ./docker/entrypoint.sh
        curl -fsSL "$GH_RAW/docker/coturn-entrypoint.sh"       -o ./docker/coturn-entrypoint.sh
        curl -fsSL "$GH_RAW/easy-asterisk-v0.10.0.sh"          -o ./easy-asterisk.sh
        curl -fsSL "$GH_RAW/scripts/vpn-diagnostics.sh"        -o ./scripts/vpn-diagnostics.sh
        curl -fsSL "$GH_RAW/scripts/dns-whitelist.sh"          -o ./scripts/dns-whitelist.sh
        cp ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh
    fi

    chmod 755 ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh \
              ./docker/entrypoint.sh ./docker/coturn-entrypoint.sh \
              ./scripts/vpn-diagnostics.sh ./scripts/dns-whitelist.sh

    # Persist security-level logging to a file — vendor's logger.conf only
    # sends the "security" level (auth failures, SIP brute-force attempts) to
    # the console (Docker stdout), not a file CrowdSec/fail2ban can tail.
    if grep -q '^console => notice,warning,error,security$' ./docker/entrypoint.sh; then
        sed -i '/^console => notice,warning,error,security$/a full => notice,warning,error,security' \
            ./docker/entrypoint.sh
    else
        log_warning "entrypoint.sh logger.conf template changed upstream — security events won't be logged to a file. Update the sed patch in this installer."
    fi
}

# ── Shared: log rotation for logs/full (unbounded otherwise) ──────────────
# Confirmed live: with no rotation, this file grew to 1.4GB in about 3 days
# on a busy box (SIP scanning noise is constant on the public internet) —
# a real disk-exhaustion risk on a small droplet, and separately made the
# Security Dashboard balloon to 600+MB RAM/GBs of swap reading it every 30s
# before that was fixed to only read a bounded tail (see
# services/security-dashboard.sh). copytruncate avoids needing to signal
# Asterisk to reopen its log file — it has a long-held file descriptor on
# this path and no reload mechanism this installer can reach from the host.
_asterisk_do_write_logrotate() {
    local _ea_dir="$1"
    cat > /etc/logrotate.d/asterisk-digital-ocean << LOGROTATE
$_ea_dir/logs/full {
    size 100M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE
}

# ── Shared: extension presence (online/offline) ntfy alerts ────────────────
# Polls PJSIP registration state and alerts only on a CHANGE from the last
# check (never on every poll) — same periodic-check shape as pstn-trunk.sh's
# usage-alert script, but purely informational, so a looser 2-minute
# interval is fine here (nothing enforces/blocks anything off the back of
# this one). UNVERIFIED: the `pjsip show contacts` column layout below is
# parsed defensively (grep for the Avail/Unavail keyword rather than a fixed
# column position) specifically because it hasn't been confirmed against a
# live install's actual output yet — run
# `docker exec easy-asterisk-do asterisk -rx "pjsip show contacts"` yourself
# after enabling this to confirm extensions/status actually show up as
# expected, same as any other not-yet-live-tested piece in this project.
_asterisk_do_write_presence_alert_script() {
    local FILE="$1" CONTAINER_NAME="$2" NTFY_URL="$3" STATE_FILE="$4"
    cat > "$FILE" << 'SCRIPT'
#!/bin/bash
# Auto-generated by services/asterisk-digital-ocean.sh — rerun the installer's
# presence-alert step to change settings instead of editing this directly.
CONTAINER_NAME="__PRESENCE_CONTAINER__"
NTFY_URL="__PRESENCE_NTFY_URL__"
STATE_FILE="__PRESENCE_STATE_FILE__"

[[ -z "$NTFY_URL" ]] && exit 0

send_ntfy() {
    curl -m 5 -s -d "$1" "$NTFY_URL" >/dev/null 2>&1
}

CURRENT="$(docker exec "$CONTAINER_NAME" asterisk -rx "pjsip show contacts" 2>/dev/null | grep '^ Contact:' | while read -r _ aor rest; do
    ext="${aor%%/*}"
    status="Unknown"
    case "$rest" in
        *Unavail*) status="Unavail" ;;
        *Avail*) status="Avail" ;;
    esac
    echo "${ext}:${status}"
done)"

[[ -z "$CURRENT" ]] && exit 0

touch "$STATE_FILE"
declare -A OLD_STATE
while IFS=: read -r ext status; do
    [[ -n "$ext" ]] && OLD_STATE["$ext"]="$status"
done < "$STATE_FILE"

: > "${STATE_FILE}.new"
while IFS=: read -r ext status; do
    [[ -z "$ext" ]] && continue
    echo "${ext}:${status}" >> "${STATE_FILE}.new"
    old="${OLD_STATE[$ext]:-}"
    if [[ -n "$old" && "$old" != "$status" && "$status" != "Unknown" ]]; then
        if [[ "$status" == "Avail" ]]; then
            send_ntfy "Extension $ext is back online."
        elif [[ "$old" == "Avail" ]]; then
            send_ntfy "Extension $ext went offline."
        fi
    fi
done <<< "$CURRENT"
mv "${STATE_FILE}.new" "$STATE_FILE"
SCRIPT
    sed -i "s#__PRESENCE_CONTAINER__#${CONTAINER_NAME}#g; s#__PRESENCE_NTFY_URL__#${NTFY_URL}#g; s#__PRESENCE_STATE_FILE__#${STATE_FILE}#g" "$FILE"
    chmod 755 "$FILE"
}

_asterisk_do_install_presence_timer() {
    local EA_DIR="$1"
    mkdir -p "$EA_DIR/logs"

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/asterisk-presence-alert.service << SVCEOF
[Unit]
Description=Asterisk extension presence (online/offline) check

[Service]
Type=oneshot
ExecStart=/bin/bash $EA_DIR/asterisk-presence-alert.sh
StandardOutput=append:$EA_DIR/logs/asterisk-presence-alert.log
StandardError=append:$EA_DIR/logs/asterisk-presence-alert.log
SVCEOF

        cat > /etc/systemd/system/asterisk-presence-alert.timer << SVCEOF
[Unit]
Description=Run the Asterisk presence check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
AccuracySec=10s

[Install]
WantedBy=timers.target
SVCEOF

        systemctl daemon-reload
        systemctl enable --now asterisk-presence-alert.timer
        log_success "Presence check installed (systemd timer, every 2 minutes)."
    elif command -v cron >/dev/null 2>&1 || [[ -d /etc/cron.d ]]; then
        cat > /etc/cron.d/asterisk-presence-alert << CRON
*/2 * * * * root /bin/bash $EA_DIR/asterisk-presence-alert.sh >> $EA_DIR/logs/asterisk-presence-alert.log 2>&1
CRON
        log_success "Presence check installed (cron.d fallback — systemd not detected)."
    else
        log_warning "Neither systemd nor cron available — run $EA_DIR/asterisk-presence-alert.sh manually/periodically."
    fi
}

# ── Shared: internal SIP MESSAGE routing/enforcement ────────────────────────
# Confirmed live against a real install's pjsip.conf/extensions.conf
# (2026-07-23): every endpoint sets context=intercom and leaves
# message_context blank, so PJSIP messaging falls back to context=intercom —
# and [intercom] already owns an exact-match `exten => <ext>,1,...` per
# device, freshly regenerated by the vendor's own rebuild_dialplan() on
# every dialplan rebuild. A competing priority-1 declaration for the same
# extension number in a #include'd file would race that (Asterisk doesn't
# merge two independent priority-1 declarations for the same context+exten —
# one silently wins) and risks breaking normal internal calling entirely.
# So this uses its own dedicated [sip-messaging] context instead, reached by
# explicitly setting message_context=sip-messaging on every endpoint, so
# there is never any overlap with [intercom]'s own per-device call routing.
#
# The vendor's device-creation code has exactly two independent code paths
# that write a fresh endpoint block (confirmed via grep — both contain the
# literal line "context=intercom" exactly once): the CLI menu's bash heredoc,
# and the web admin's Python add_device(). Patching the vendor's own
# generator source (same technique as _pstn_patch_vendor_files) makes every
# device added FROM NOW ON pick this up automatically, in either path.
# Devices that already existed before this was installed need one one-time
# migration pass over the live pjsip.conf (below) since they were written
# before the patch existed.
_asterisk_do_patch_messaging_vendor_files() {
    local EA_DIR="$1"
    local ENTRYPOINT="$EA_DIR/docker/entrypoint.sh"
    local EASY1="$EA_DIR/easy-asterisk.sh"
    local EASY2
    EASY2="$(find "$EA_DIR" -maxdepth 1 -name 'easy-asterisk-v*.sh' | head -1)"
    [[ -z "$EASY2" ]] && EASY2="$EA_DIR/easy-asterisk-v0.10.0.sh"
    local f

    for f in "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || { log_error "$f not found — is the base Asterisk install fully set up?"; return 1; }
    done

    # Device-creation templates: both occurrences of "context=intercom" in
    # these two files (identical vendor source, copied twice) are the CLI
    # and web-admin device-creation code paths — a single anchor on the bare
    # line patches both in one pass.
    for f in "$EASY1" "$EASY2"; do
        if ! grep -q '^message_context=sip-messaging$' "$f"; then
            if grep -q '^context=intercom$' "$f"; then
                sed -i '/^context=intercom$/a message_context=sip-messaging' "$f"
            else
                log_warning "$(basename "$f"): 'context=intercom' anchor not found — vendor template changed upstream."
                log_warning "  Add 'message_context=sip-messaging' manually after every 'context=intercom' line in this file's device-creation code."
            fi
        fi
    done

    # extensions.conf: same [intercom] anchor _pstn_patch_vendor_files uses,
    # a SEPARATE #include so this coexists whether or not pstn-trunk is
    # installed — messaging is independent of the PSTN trunk entirely.
    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || continue
        if ! grep -q 'messaging-dialplan.conf' "$f"; then
            if grep -q '^\[intercom\]$' "$f"; then
                sed -i '/^\[intercom\]$/a #include messaging-dialplan.conf' "$f"
            else
                log_warning "$(basename "$f"): '[intercom]' anchor not found — vendor template changed upstream."
                log_warning "  Add '#include messaging-dialplan.conf' manually after [intercom] in this file's extensions.conf heredoc."
            fi
        fi
    done

    log_success "Vendor generator functions patched for internal SIP messaging."
}

# Confirmed live (2026-07-23, via a real pstn-trunk.sh failure that hit this
# same mechanism): the vendor-generator patch above only takes effect on a
# FUTURE regeneration, and Easy Asterisk's own entrypoint only regenerates
# extensions.conf if it doesn't already exist (docker/entrypoint.sh guards
# it behind `[[ ! -f ... ]]`) — a box that already has devices configured,
# which is the normal case here, never regenerates it on a plain restart.
# Patches the LIVE file directly instead, so it takes effect immediately
# regardless of whether Easy Asterisk ever regenerates it on its own.
_asterisk_do_ensure_live_messaging_include() {
    local EA_DIR="$1"
    local EXT_LIVE="$EA_DIR/config/asterisk/extensions.conf"
    [[ -f "$EXT_LIVE" ]] || return 0
    if ! grep -q 'messaging-dialplan.conf' "$EXT_LIVE"; then
        if grep -q '^\[intercom\]$' "$EXT_LIVE"; then
            sed -i '/^\[intercom\]$/a #include messaging-dialplan.conf' "$EXT_LIVE"
            log_success "Patched the messaging #include directly into the live extensions.conf."
        else
            log_warning "Couldn't find '[intercom]' in the live extensions.conf — add"
            log_warning "'#include messaging-dialplan.conf' manually, then: docker exec easy-asterisk-do asterisk -rx \"dialplan reload\""
        fi
    fi
    docker exec easy-asterisk-do asterisk -rx "dialplan reload" &>/dev/null || true
}

# One-time migration for devices that already existed before the patch above
# — new devices pick up message_context=sip-messaging automatically from now
# on, but anything already in pjsip.conf was written before that existed.
# Idempotent: buffers the file and only inserts where the very next line
# isn't already the exact value, so reruns (every "update") never duplicate it.
_asterisk_do_migrate_existing_devices_message_context() {
    local PJSIP_FILE="$1"
    [[ -f "$PJSIP_FILE" ]] || return 0
    grep -q '^context=intercom$' "$PJSIP_FILE" || return 0

    local TMP_FILE
    TMP_FILE="$(mktemp)"
    awk '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                print lines[i]
                if (lines[i] == "context=intercom" && lines[i+1] != "message_context=sip-messaging") {
                    print "message_context=sip-messaging"
                }
            }
        }
    ' "$PJSIP_FILE" > "$TMP_FILE"

    if ! diff -q "$PJSIP_FILE" "$TMP_FILE" >/dev/null 2>&1; then
        cp "$PJSIP_FILE" "$PJSIP_FILE.backup.$(date +%Y%m%d-%H%M%S)"
        mv "$TMP_FILE" "$PJSIP_FILE"
        chown asterisk:asterisk "$PJSIP_FILE" 2>/dev/null || true
        log_success "Existing devices migrated to message_context=sip-messaging (backup saved alongside pjsip.conf)."
    else
        rm -f "$TMP_FILE"
    fi
}

# The actual enforcement — gated on the SENDER's own "messaging" flag in
# pstn-permissions.conf (the exact file/flag the Security Dashboard's
# "Internal SIP messaging" checkbox writes, independent of whether the PSTN
# trunk is installed), read live via AST_CONFIG() on every message, same
# mechanism pstn-trunk.sh's own dialplan already relies on for permission
# tiers — no restart needed to take effect. Off by default: an extension
# with no entry, or messaging=no, is denied. UNVERIFIED: MESSAGE(from)'s
# exact format hasn't been confirmed on a live install — the CUT()-based
# extraction below is written to tolerate a display name (e.g. this
# project's "name0" <999> callerid format) but if it ever fails to parse,
# FROM_EXT ends up empty/wrong and the AST_CONFIG() lookup simply finds no
# match, which denies by default (same fail-closed behavior as an
# unlisted extension) rather than silently allowing anything through.
_asterisk_do_write_messaging_dialplan() {
    local FILE="$1"
    cat > "$FILE" << 'EOF'
; Internal SIP MESSAGE routing/enforcement — services/asterisk-digital-ocean.sh.
; Regenerated on every install/update; edit there, not here directly.
;
; Reached via each endpoint's message_context=sip-messaging (patched into
; Easy Asterisk's own device-creation code — see
; _asterisk_do_patch_messaging_vendor_files) instead of falling back to
; [intercom], which already owns an exact-match "exten => <ext>,1,..." per
; device for CALLS, regenerated fresh on every dialplan rebuild — a
; competing priority-1 declaration for the same extension number here would
; race that and risk breaking normal internal calling. This context ONLY
; ever receives MESSAGE requests, never calls.
[sip-messaging]
exten => _X.,1,NoOp(SIP MESSAGE to ${EXTEN})
 same => n,Set(FROM_URI=${MESSAGE(from)})
 same => n,Set(FROM_PART=${CUT(FROM_URI,@,1)})
 same => n,Set(FROM_EXT=${CUT(FROM_PART,:,2)})
 same => n,Set(SENDER_OK=${AST_CONFIG(pstn-permissions.conf,${FROM_EXT},messaging)})
 same => n,GotoIf($["${SENDER_OK}" = "yes"]?deliver:deny)
 same => n(deliver),MessageSend(pjsip:${EXTEN},${FROM_URI})
 same => n,Hangup()
 same => n(deny),NoOp(Denied — extension ${FROM_EXT} is not messaging-enabled)
 same => n,Hangup()
EOF
}

_asterisk_do_remove_presence_timer() {
    systemctl disable --now asterisk-presence-alert.timer 2>/dev/null || true
    rm -f /etc/systemd/system/asterisk-presence-alert.timer /etc/systemd/system/asterisk-presence-alert.service
    rm -f /etc/cron.d/asterisk-presence-alert
    systemctl daemon-reload 2>/dev/null || true
}

# Interactive step — called from both the fresh-install flow and "update in
# place" (always asked either way, same reasoning as pstn-trunk.sh's
# international-calling step: this is a live-editable extra, not a
# structural setting, so it doesn't belong exclusively to one path).
_asterisk_do_run_presence_step() {
    local EA_DIR="$1"
    local SETTINGS_FILE="$EA_DIR/.presence-alert.env"
    local STATE_FILE="$EA_DIR/.presence-alert.state"

    echo ""
    local _CUR_ENABLED="n" _CUR_NTFY=""
    if [[ -f "$SETTINGS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$SETTINGS_FILE"
        _CUR_ENABLED="${PRESENCE_ENABLED:-n}"
        _CUR_NTFY="${PRESENCE_NTFY_URL:-}"
    fi

    if [[ "$_CUR_ENABLED" == "y" ]]; then
        echo "  Extension online/offline ntfy alerts are ON (topic: $_CUR_NTFY)."
        local _CHANGE=""
        prompt_yn "  Change or disable this? (y/n):" "n" _CHANGE
        [[ "$_CHANGE" =~ ^[Yy]$ ]] || return 0
        local _DISABLE=""
        prompt_yn "  Disable presence alerts entirely? (y/n):" "n" _DISABLE
        if [[ "$_DISABLE" =~ ^[Yy]$ ]]; then
            _asterisk_do_remove_presence_timer
            rm -f "$EA_DIR/asterisk-presence-alert.sh" "$STATE_FILE"
            cat > "$SETTINGS_FILE" << ENV
PRESENCE_ENABLED="n"
PRESENCE_NTFY_URL=""
ENV
            log_success "Presence alerts disabled."
            return 0
        fi
    else
        local _WANT=""
        prompt_yn "Send an ntfy alert when an extension's SIP registration goes offline / comes back online? (y/n):" "n" _WANT
        [[ "$_WANT" =~ ^[Yy]$ ]] || return 0
    fi

    local _ntfy_default="${_CUR_NTFY:-https://ntfy.sh/asterisk-presence}"
    if [[ -z "$_CUR_NTFY" ]] && [[ -f "$DOCKER_DIR/ntfy/config/server.yml" ]]; then
        local _local_base_url
        _local_base_url="$(grep -oP '(?<=base-url: ")[^"]+' "$DOCKER_DIR/ntfy/config/server.yml" 2>/dev/null || true)"
        if [[ -n "$_local_base_url" ]] && [[ "$_local_base_url" != "https://ntfy.example.com" ]]; then
            _ntfy_default="${_local_base_url}/asterisk-presence"
            log_info "Detected a configured local ntfy instance at $_local_base_url — using it as the default."
        fi
    fi
    local PRESENCE_NTFY_URL=""
    prompt_text "  ntfy topic URL:" "$_ntfy_default" PRESENCE_NTFY_URL
    if [[ -z "$PRESENCE_NTFY_URL" ]]; then
        log_warning "No topic entered — presence alerts not enabled."
        return 0
    fi

    _asterisk_do_write_presence_alert_script "$EA_DIR/asterisk-presence-alert.sh" "easy-asterisk-do" "$PRESENCE_NTFY_URL" "$STATE_FILE"
    _asterisk_do_install_presence_timer "$EA_DIR"

    cat > "$SETTINGS_FILE" << ENV
PRESENCE_ENABLED="y"
PRESENCE_NTFY_URL="${PRESENCE_NTFY_URL}"
ENV
    chown "$ACTUAL_USER:$ACTUAL_USER" "$SETTINGS_FILE" 2>/dev/null || true
    log_success "Presence alerts enabled (checked every 2 minutes) — topic: $PRESENCE_NTFY_URL"
    log_info "Fires only on a state CHANGE, never every check — the first check after enabling"
    log_info "never alerts by itself, since there's no prior state to compare against yet."
}

# ── Shared: docker-compose.yml ─────────────────────────────────────────────
# Same reasoning as above — one copy of the template used by both fresh
# installs and updates. Must be called with $PWD already at $EA_DIR.
_asterisk_do_write_compose() {
    cat > docker-compose.yml << 'EOF'
name: asterisk-do

services:
  asterisk:
    build: .
    container_name: easy-asterisk-do
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - ./config/asterisk:/etc/asterisk
      - ./config/easy-asterisk:/etc/easy-asterisk
      - ./logs:/var/log/asterisk
      - ./spool:/var/spool/asterisk
      - ./lib:/var/lib/asterisk
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
      - ./exports:/root
CADDY_VOLUME_PLACEHOLDER
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-do-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    env_file: .env
    command:
      - -n
      - --listening-port=${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=${TURN_USERNAME:-easyasterisk}:${TURN_PASSWORD}
      - --realm=${DOMAIN_NAME:-localhost}
      - --min-port=49152
      - --max-port=49252
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

EOF

    # Share Caddy's cert store (read-only) so the entrypoint can auto-sync a
    # real Let's Encrypt cert for DOMAIN_NAME instead of falling back to
    # self-signed. No-op if Caddy isn't installed on this box.
    if [[ -d "$DOCKER_DIR/caddy/data" ]]; then
        sed -i "s#CADDY_VOLUME_PLACEHOLDER#      - ${DOCKER_DIR}/caddy/data:/caddy-data:ro#" docker-compose.yml
    else
        sed -i "/CADDY_VOLUME_PLACEHOLDER/d" docker-compose.yml
    fi
}

install_asterisk-digital-ocean() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn (DigitalOcean droplet edition)..."

    local EA_DIR="$DOCKER_DIR/asterisk-digital-ocean"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would add a swapfile if RAM <= 2048MB and none exists"
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk"
        echo "[DRY-RUN] Would detect droplet public IP via DO metadata service"
        echo "[DRY-RUN] Would scan for a free web admin port starting at 8081 (avoids e.g. CrowdSec's 8080)"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, <web admin port>, 8088, 8089, 3478, 10000-20000, 49152-49252"
        echo "[DRY-RUN] Would offer to create a DigitalOcean Cloud Firewall via doctl"
        echo "[DRY-RUN] Would reverse-proxy the web admin on the SAME FQDN used for SIP if Caddy is already installed (needed for cert sync)"
        echo "[DRY-RUN] Would offer local OR remote Authelia to protect the web admin, if either is already available"
        echo "[DRY-RUN] Would offer 'update in place' instead of a fresh install if $EA_DIR already exists"
        echo "[DRY-RUN] Would offer optional ntfy alerts on extension registration going offline/online"
        echo "[DRY-RUN]   (checked every 2 minutes via systemd timer, cron.d fallback; always asked,"
        echo "[DRY-RUN]   update mode included)"
        echo "[DRY-RUN] Would patch vendor device-creation code + extensions.conf generator to route"
        echo "[DRY-RUN]   internal SIP MESSAGE through a dedicated [sip-messaging] dialplan context,"
        echo "[DRY-RUN]   gated live on each sender's 'messaging' flag in pstn-permissions.conf (the"
        echo "[DRY-RUN]   same file/flag the Security Dashboard's checkbox writes) — independent of"
        echo "[DRY-RUN]   whether the PSTN trunk is installed; migrates any already-existing devices too"
        return 0
    fi

    # ── Existing install? Offer update-in-place instead of a full reinstall ───
    # A fresh install re-runs every prompt (domain, extras, DO firewall,
    # Authelia). An update only refreshes vendor files + docker-compose.yml —
    # picking up fixes like this one — and rebuilds, without touching .env,
    # UFW, the Cloud Firewall, or the Caddy/Authelia config already in place.
    if [[ -f "$EA_DIR/docker-compose.yml" && -f "$EA_DIR/.env" ]]; then
        echo ""
        log_info "Existing install found at $EA_DIR."
        local REINSTALL_MODE=""
        prompt_reinstall_mode REINSTALL_MODE
        case "$REINSTALL_MODE" in
            update)
                mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
                         "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
                ensure_docker_dir_ownership "$EA_DIR"
                cd "$EA_DIR" || return 1

                _asterisk_do_refresh_vendor_files
                _asterisk_do_write_compose
                _asterisk_do_write_logrotate "$EA_DIR"
                _asterisk_do_patch_messaging_vendor_files "$EA_DIR"
                _asterisk_do_write_messaging_dialplan "$EA_DIR/config/asterisk/messaging-dialplan.conf"
                _asterisk_do_ensure_live_messaging_include "$EA_DIR"
                _asterisk_do_migrate_existing_devices_message_context "$EA_DIR/config/asterisk/pjsip.conf"
                ensure_docker_dir_ownership "$EA_DIR/config/asterisk"
                chmod 644 "$EA_DIR/config/asterisk/messaging-dialplan.conf"

                log_info "Rebuilding and restarting containers..."
                if docker compose up -d --build --force-recreate; then
                    log_success "Update complete — vendor files and docker-compose.yml refreshed."
                else
                    log_warning "docker compose up failed — check: docker compose -f $EA_DIR/docker-compose.yml logs"
                fi

                _asterisk_do_run_presence_step "$EA_DIR"

                local _EXISTING_DOMAIN _EXISTING_PORT
                _EXISTING_DOMAIN="$(grep -E '^DOMAIN_NAME=' .env | cut -d= -f2-)"
                _EXISTING_PORT="$(grep -E '^WEB_ADMIN_PORT=' .env | cut -d= -f2-)"
                echo ""
                log_success "Existing .env, UFW rules, Cloud Firewall, and Caddy/Authelia config were left untouched."
                if [[ -n "$_EXISTING_DOMAIN" ]]; then
                    echo "  Web admin: https://${_EXISTING_DOMAIN}/"
                else
                    echo "  Web admin: http://<droplet-ip>:${_EXISTING_PORT:-8081}"
                fi
                echo "  Logs:      docker compose -f $EA_DIR/docker-compose.yml logs -f"
                echo ""
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is — nothing changed."
                return 0
                ;;
            fresh)
                log_info "Proceeding with a full fresh reinstall — every prompt below runs from scratch."
                ;;
        esac
    fi

    # ── Swap file (insurance for low-RAM droplets, e.g. the $4/mo 512MB plan) ──
    # DigitalOcean doesn't provision swap by default. Docker + Asterisk + coturn
    # fit in 512MB-1GB at idle with little headroom; a swapfile absorbs spikes
    # (apt/image pulls, log bursts, a few concurrent calls) instead of the
    # kernel OOM-killing a container or the box going unresponsive over SSH.
    local TOTAL_RAM_MB
    TOTAL_RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)"
    if [[ "$TOTAL_RAM_MB" -gt 0 && "$TOTAL_RAM_MB" -le 2048 ]] && ! swapon --show | grep -q .; then
        local FREE_DISK_MB SWAP_MB=2048
        FREE_DISK_MB="$(df -Pm / | awk 'NR==2 {print $4}')"
        if [[ "$FREE_DISK_MB" -gt $((SWAP_MB + 2048)) ]]; then
            local ADD_SWAP=""
            prompt_yn "No swap detected on this ${TOTAL_RAM_MB}MB-RAM droplet — add a ${SWAP_MB}MB swapfile? (y/n):" "y" ADD_SWAP
            if [[ "$ADD_SWAP" =~ ^[Yy]$ ]]; then
                fallocate -l "${SWAP_MB}M" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=none
                chmod 600 /swapfile
                mkswap /swapfile >/dev/null
                swapon /swapfile
                grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
                grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
                sysctl -w vm.swappiness=10 >/dev/null 2>&1
                log_success "Swapfile enabled (${SWAP_MB}MB, swappiness=10, persists across reboots)."
            fi
        else
            log_warning "Not enough free disk for a safe swapfile (${FREE_DISK_MB}MB free) — skipping."
            log_warning "Consider a bigger droplet, or free up disk before installing."
        fi
    fi

    mkdir -p "$EA_DIR"
    mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
             "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib" "$EA_DIR/exports"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    _asterisk_do_refresh_vendor_files
    _asterisk_do_write_logrotate "$EA_DIR"
    _asterisk_do_patch_messaging_vendor_files "$EA_DIR"
    _asterisk_do_write_messaging_dialplan "$EA_DIR/config/asterisk/messaging-dialplan.conf"
    _asterisk_do_ensure_live_messaging_include "$EA_DIR"
    ensure_docker_dir_ownership "$EA_DIR/config/asterisk"
    chmod 644 "$EA_DIR/config/asterisk/messaging-dialplan.conf"

    # ── DigitalOcean droplet detection ────────────────────────────────────────
    # A droplet's own public IP/ID are readable, unauthenticated, from the
    # link-local metadata service — no API token needed for this part.
    echo ""
    log_info "Reading DigitalOcean droplet metadata..."
    local DO_META="http://169.254.169.254/metadata/v1"
    local DROPLET_ID PUBLIC_IP
    DROPLET_ID="$(curl -fsS --max-time 2 "$DO_META/id" 2>/dev/null || true)"
    PUBLIC_IP="$(curl -fsS --max-time 2 "$DO_META/interfaces/public/0/ipv4/address" 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [[ -n "$DROPLET_ID" ]]; then
        log_success "Detected DigitalOcean droplet id $DROPLET_ID, public IP ${PUBLIC_IP:-unknown}"
    else
        log_warning "DigitalOcean metadata service not reachable (not a droplet, or run in a container)."
        log_warning "Continuing anyway — Cloud Firewall automation will be skipped."
    fi

    # ── Domain (always public — this is a cloud box) ──────────────────────────
    echo ""
    echo "  Point a DNS A record at this droplet before continuing:"
    echo "    <subdomain>.${SITE_DOMAIN:-example.com}  A  ${PUBLIC_IP:-<droplet public IP>}"
    echo ""
    echo "  This one FQDN covers everything below — SIP registration, the web"
    echo "  admin, and (via Caddy) the TLS cert Asterisk needs for SIP. There's"
    echo "  no separate \"admin domain\" to pick later — whatever you enter here"
    echo "  is what your SIP client (e.g. Sipnetic) will register against."
    local DOMAIN_NAME=""
    prompt_text "FQDN for this PBX, e.g. sip.yourdomain.com [blank=self-signed cert, IP-only access]:" "" DOMAIN_NAME
    [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — using a self-signed cert; phones must trust it manually."

    # ── Secrets ───────────────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(generate_password 24)"

    # Unlike the LAN edition, a droplet is always reachable — TURN always has
    # a usable address (the FQDN if set, otherwise the droplet's public IP).
    local TURN_SERVER_VAL="${DOMAIN_NAME:-$PUBLIC_IP}:3478"

    _asterisk_do_write_compose

    # ── Pick a free port for the web admin ─────────────────────────────────────
    # Hardcoding a single number gets fragile fast once several services share
    # a host — CrowdSec's own LAPI already collides with 8080 by default (its
    # own upstream default, confirmed against its real config.yaml). Scan
    # instead: start at 8081 and take the first port nothing is listening on,
    # capped so a pathological box can't spin this forever.
    local WEB_ADMIN_PORT_VAL=8081
    local _port_scan_limit=$((WEB_ADMIN_PORT_VAL + 100))
    while ss -tlnH "sport = :${WEB_ADMIN_PORT_VAL}" 2>/dev/null | grep -q . \
          && [[ "$WEB_ADMIN_PORT_VAL" -lt "$_port_scan_limit" ]]; do
        WEB_ADMIN_PORT_VAL=$((WEB_ADMIN_PORT_VAL + 1))
    done
    if [[ "$WEB_ADMIN_PORT_VAL" -ge "$_port_scan_limit" ]]; then
        log_warning "No free port found in 8081-${_port_scan_limit} — falling back to 8081 anyway."
        WEB_ADMIN_PORT_VAL=8081
    elif [[ "$WEB_ADMIN_PORT_VAL" != 8081 ]]; then
        log_info "Port 8081 was already taken — web admin will use ${WEB_ADMIN_PORT_VAL} instead."
    fi

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# Public FQDN for this droplet. Leave empty to fall back to a self-signed
# cert reachable at the droplet's public IP (${PUBLIC_IP:-unknown}).
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
TURN_USERNAME=easyasterisk
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=3478
TURN_SERVER=${TURN_SERVER_VAL}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── VLAN/VPN subnets ──────────────────────────────────────────
# A droplet has one public NIC, so this is usually irrelevant. Only set it
# if you're bridging phones back in over a VPN (e.g. WireGuard/Tailscale)
# on a subnet the droplet isn't directly attached to.
HAS_VLANS=n
VLAN_SUBNETS=

# ── Web admin ─────────────────────────────────────────────────
# Picked automatically at install time (first free port starting at 8081) —
# see WEB_ADMIN_PORT_VAL in services/asterisk-digital-ocean.sh if this ever needs to
# change again; don't hand-edit without also updating Caddy's Caddyfile and
# both firewall layers to match.
WEB_ADMIN_PORT=${WEB_ADMIN_PORT_VAL}
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── Caddy: reverse-proxy the web admin on the SAME FQDN used for SIP ──────
    # Caddy only holds a cert for domains it's actively serving. If the web
    # admin were proxied on a different "admin" subdomain, Caddy would obtain
    # a cert for THAT domain instead — the sync earlier would never find one
    # matching $DOMAIN_NAME, and SIP TLS would silently stay self-signed. So
    # there's no separate domain prompt: this always targets $DOMAIN_NAME.
    #
    # Decided before the firewall rules below so they can be scoped
    # correctly: if Caddy ends up fronting the web admin locally, there's no
    # reason to also expose it directly to the internet — Caddy already
    # reaches it over the host's internal network (host.docker.internal),
    # and leaving the bare IP:port open would let anyone bypass Caddy/
    # Authelia entirely.
    local WEB_ADMIN_PUBLIC_ACCESS_NEEDED=true
    if [[ -z "$DOMAIN_NAME" ]]; then
        log_info "No FQDN set — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL} (nothing for Caddy to do)."
    elif [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -z "${CADDY_REMOTE_HOST:-}" ]]; then
        log_info "Caddy not installed — web admin stays on http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL}, SIP TLS stays self-signed."
    else
        local EXTRA_BLOCK=""
        if [ -d "$DOCKER_DIR/authelia" ]; then
            local _use_auth=""
            prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
            if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
                EXTRA_BLOCK="    import authelia"
                # Disable built-in auth since Authelia handles it
                sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
            fi
        else
            # No local Authelia — offer one running elsewhere (e.g. a homelab).
            # There's no shared "(authelia)" Caddy snippet to import in that
            # case (authelia.sh only writes one when installing locally), so
            # this builds the same forward_auth block inline, targeting the
            # remote instance directly instead of the local "authelia:9091"
            # container reference.
            local _use_remote_auth=""
            prompt_yn "Protect the web admin with a remote Authelia instance (e.g. on a homelab)? (y/n):" "n" _use_remote_auth
            if [[ "$_use_remote_auth" =~ ^[Yy]$ ]]; then
                local _remote_authelia=""
                prompt_text "  Remote Authelia address — a bare host:port over a private network (e.g. a NetBird mesh IP:9091), or a full https:// URL if it's on its own public domain+TLS:" "" _remote_authelia
                if [[ -n "$_remote_authelia" ]]; then
                    # header_up lines are required here (unlike the local
                    # "authelia:9091" snippet in services/authelia.sh) because
                    # this upstream is reached over a second Caddy hop when
                    # given as a scheme-qualified URL (https://auth.example.com).
                    # Caddy rewrites the outgoing request's Host header to that
                    # upstream host so the remote Caddy can route/SNI-match it —
                    # and without an explicit override, X-Forwarded-Host picks up
                    # that rewritten value instead of the original site's host.
                    # Confirmed live: Authelia was evaluating every request as
                    # if it were for auth.example.com itself (which has
                    # policy: bypass in access_control.rules), so every domain
                    # silently passed through with no 2FA prompt regardless of
                    # its own policy. Pinning these to the original request's
                    # values fixes it regardless of hop count.
                    #
                    # X-Forwarded-Host uses a literal domain, NOT the {host}
                    # placeholder. Confirmed live: {host} still evaluated to
                    # the upstream's own hostname (auth.example.com) rather
                    # than the original site's — Caddy appears to rewrite the
                    # outgoing request's Host to the upstream target before
                    # header_up placeholders are resolved for a scheme-
                    # qualified upstream, so {host} echoes back the already-
                    # rewritten value instead of the original client-facing
                    # host. Since this site block only ever serves one domain
                    # (DOMAIN_NAME), hardcoding it sidesteps the ambiguity
                    # entirely instead of depending on Caddy's internal
                    # header-mutation ordering.
                    EXTRA_BLOCK="    forward_auth ${_remote_authelia} {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
        header_up X-Forwarded-Method {method}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host ${DOMAIN_NAME}
        header_up X-Forwarded-Uri {uri}
    }"
                    sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
                    log_info "Using remote Authelia at ${_remote_authelia}."
                    log_info "Verify it's reachable from this droplet before relying on it — e.g.:"
                    log_info "  curl -I ${_remote_authelia}"
                else
                    log_info "No address entered — skipping Authelia protection."
                fi
            fi
        fi

        # Deliberately NOT using configure_caddy_for_service here. That helper
        # asks for its own domain, defaulting to "<subdomain>.${SITE_DOMAIN}" —
        # which only lands on $DOMAIN_NAME if SITE_DOMAIN happens to be set to
        # match, and silently shows a useless blank/wrong default otherwise
        # (real-world confirmed: SITE_DOMAIN is never set when this service is
        # run by name, e.g. `sudo ./setup.sh asterisk-digital-ocean`, since that skips
        # setup.sh's own site-defaults wizard entirely). There is exactly one
        # correct domain for this site block — $DOMAIN_NAME — so it's written
        # directly, with no domain prompt to get wrong.
        echo ""
        local WANT_CADDY_PROXY=""
        prompt_yn "Reverse-proxy the web admin at https://${DOMAIN_NAME}/ via Caddy? (also gets Asterisk a trusted TLS cert for SIP instead of self-signed) (y/n):" "y" WANT_CADDY_PROXY
        if [[ "$WANT_CADDY_PROXY" =~ ^[Yy]$ ]]; then
            local _CADDY_MODE="local"
            [[ ! -d "$DOCKER_DIR/caddy" ]] && [[ -n "${CADDY_REMOTE_HOST:-}" ]] && _CADDY_MODE="remote"

            # Asterisk runs with network_mode: host, so whatever proxies to it
            # needs a way to reach the host, not "localhost" (which resolves
            # to the proxying container's own netns). A local Caddy container
            # reaches the host via host.docker.internal (wired up in
            # services/caddy.sh's compose file); a remote Caddy machine needs
            # this droplet's actual public IP instead.
            local _PROXY_TARGET="host.docker.internal:${WEB_ADMIN_PORT_VAL}"
            [[ "$_CADDY_MODE" == "remote" ]] && _PROXY_TARGET="${PUBLIC_IP}:${WEB_ADMIN_PORT_VAL}"

            local _SITE_BLOCK
            _SITE_BLOCK="$(cat << CADDY_BLOCK

# Asterisk Web Admin
${DOMAIN_NAME} {
    # Auth (if any) must come before reverse_proxy — forward_auth is the
    # same directive family as reverse_proxy internally, and Caddy doesn't
    # reorder repeats of the same directive within a block; it runs them in
    # the order they're written. With reverse_proxy first, it would handle
    # and terminate every request immediately, so an auth check written
    # after it would be dead code that never runs — full bypass regardless
    # of what the auth server's own rules say.
${EXTRA_BLOCK}
    reverse_proxy ${_PROXY_TARGET}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${DOMAIN_NAME}.log
        format json
    }
}
CADDY_BLOCK
)"

            if [[ "$_CADDY_MODE" == "local" ]]; then
                # Caddy reaches this over the host's internal network — no
                # need to keep the port open to the public internet.
                WEB_ADMIN_PUBLIC_ACCESS_NEEDED=false
                local _CADDYFILE="$DOCKER_DIR/caddy/Caddyfile"
                local _CADDY_BACKUP="$_CADDYFILE.backup.$(date +%Y%m%d-%H%M%S)"
                if [[ -f "$_CADDYFILE" ]]; then
                    cp "$_CADDYFILE" "$_CADDY_BACKUP"
                else
                    touch "$_CADDYFILE"
                fi
                if grep -q "^${DOMAIN_NAME}" "$_CADDYFILE" 2>/dev/null; then
                    log_warning "${DOMAIN_NAME} already in Caddyfile — leaving the existing entry alone."
                else
                    printf '%s\n' "$_SITE_BLOCK" >> "$_CADDYFILE"
                    log_success "Added ${DOMAIN_NAME} to Caddyfile (backup: $(basename "$_CADDY_BACKUP"))"
                    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                    # The template Caddyfile ships with "admin off", so
                    # `caddy reload` (which needs that same admin API) never
                    # actually works here. Try it anyway, fall back to a
                    # restart — confirmed necessary on a real deployment.
                    if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                        log_success "Web admin accessible at: https://${DOMAIN_NAME}"
                    elif docker restart caddy &>/dev/null; then
                        log_success "Caddy restarted to apply changes (reload API is disabled by default)"
                        log_success "Web admin should be accessible at: https://${DOMAIN_NAME}"
                    else
                        log_warning "Reload/restart failed — check: docker logs caddy"
                        log_info "Manual fix: docker restart caddy"
                    fi
                fi
            else
                local _SNIPPET_DIR="$DOCKER_DIR/caddy-snippets"
                mkdir -p "$_SNIPPET_DIR"
                printf '%s\n' "$_SITE_BLOCK" > "$_SNIPPET_DIR/asterisk-digital-ocean.caddy"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_SNIPPET_DIR/asterisk-digital-ocean.caddy" 2>/dev/null || true
                log_success "Snippet saved: $_SNIPPET_DIR/asterisk-digital-ocean.caddy"
                log_info "Copy to your Caddy machine: scp $_SNIPPET_DIR/asterisk-digital-ocean.caddy caddy-host:~/caddy-snippets/"
                log_info "Remote Caddy reaches this droplet over its public IP, so the web admin port stays open below."
            fi
        fi
    fi

    # ── UFW firewall rules (host-level) ───────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        if [[ "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" == true ]]; then
            ufw allow "${WEB_ADMIN_PORT_VAL}/tcp"
        else
            ufw delete allow "${WEB_ADMIN_PORT_VAL}/tcp" 2>/dev/null || true
            ufw_allow_from_caddy_net "${WEB_ADMIN_PORT_VAL}"
        fi
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow 10000:20000/udp
        ufw allow 49152:49252/udp
        ensure_ufw_enabled
        log_success "UFW rules added."
    fi

    # ── DigitalOcean Cloud Firewall (network edge, in front of the droplet) ───
    local DO_FW_RULES=(
        "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5061,address:0.0.0.0/0,address:::/0"
    )
    if [[ "$WEB_ADMIN_PUBLIC_ACCESS_NEEDED" == true ]]; then
        DO_FW_RULES+=("protocol:tcp,ports:${WEB_ADMIN_PORT_VAL},address:0.0.0.0/0,address:::/0")
    fi
    DO_FW_RULES+=(
        "protocol:tcp,ports:8088-8089,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:10000-20000,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:49152-49252,address:0.0.0.0/0,address:::/0"
    )

    echo ""
    if [[ -n "$DROPLET_ID" ]] && command -v doctl &>/dev/null && doctl account get &>/dev/null; then
        local EXISTING_FW
        EXISTING_FW="$(doctl compute firewall list --format ID,DropletIDs --no-header 2>/dev/null \
            | grep -E "(^|[, ])${DROPLET_ID}([, ]|\$)" | awk '{print $1}' | head -1)"

        if [[ -n "$EXISTING_FW" ]]; then
            log_warning "A Cloud Firewall (id $EXISTING_FW) is already attached to this droplet — not touching it."
            log_warning "Add these inbound rules to it yourself (Networking → Firewalls in the DO console):"
            printf '    %s\n' "${DO_FW_RULES[@]}"
        else
            local DO_FW=""
            prompt_yn "Create a DigitalOcean Cloud Firewall for this droplet via doctl now? (y/n):" "y" DO_FW
            if [[ "$DO_FW" =~ ^[Yy]$ ]]; then
                if doctl compute firewall create \
                    --name "asterisk-digital-ocean" \
                    --droplet-ids "$DROPLET_ID" \
                    --inbound-rules "$(IFS=' '; echo "${DO_FW_RULES[*]}")" \
                    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,ports:0,address:0.0.0.0/0,address:::/0" \
                    &>/dev/null; then
                    log_success "Cloud Firewall 'asterisk-digital-ocean' created and attached (SSH/22 included so you don't get locked out)."
                    log_info "Verify it in the DO console — adjust the SSH rule if you use a non-default SSH port."
                else
                    log_warning "doctl firewall create failed — add the rules manually (see README)."
                fi
            fi
        fi
    else
        log_info "doctl not installed/authenticated — configure a DigitalOcean Cloud Firewall manually:"
        log_info "Control Panel → Networking → Firewalls → create, attach to this droplet, allow:"
        printf '    %s\n' "${DO_FW_RULES[@]}"
    fi

    # ── CrowdSec note ──────────────────────────────────────────────────────────
    # Not installed here — select it separately from the whiptail menu, or
    # `sudo ./setup.sh crowdsec`. Its own installer (services/crowdsec.sh)
    # auto-detects an asterisk-digital-ocean install and wires up SIP
    # brute-force protection on its own, in either install order.
    if command -v cscli &>/dev/null; then
        log_info "CrowdSec is already installed — rerun it to pick up SIP protection for this install:"
        log_info "  sudo ./setup.sh crowdsec"
    else
        log_info "CrowdSec not installed. Recommended for SSH + SIP intrusion prevention on a public"
        log_info "droplet — install it separately (whiptail menu, or 'sudo ./setup.sh crowdsec')."
        log_info "It auto-detects this asterisk-digital-ocean install and wires up SIP protection on its own."
    fi

    # ── Extension presence (online/offline) ntfy alerts ────────────────────────
    _asterisk_do_run_presence_step "$EA_DIR"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << MD
# Easy Asterisk PBX + coturn — DigitalOcean droplet edition

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal, sized and secured for a public DigitalOcean droplet. For a
home/LAN box with VLAN support, use \`~/docker/asterisk\` (services/asterisk.sh)
instead.

## Droplet sizing

Asterisk + coturn is light for a handful of SIP extensions and personal use.

| Plan                          | vCPU | RAM   | Good for                              |
|--------------------------------|------|-------|----------------------------------------|
| Basic (regular), \$4/mo          | 1    | 512 MB | Works — this installer adds a 2GB swapfile automatically to cover it. Fine for a couple of extensions and light personal use. |
| **Basic (regular), \$6/mo — recommended** | 1    | 1 GB  | More headroom, still gets an automatic swapfile |
| Basic (regular), \$12/mo         | 1    | 2 GB  | Comfortable — no swap needed, a handful of concurrent calls |
| Basic (regular), \$24/mo         | 2    | 4 GB  | Several simultaneous calls, conference bridges, transcoding |

10 GB SSD (the \$4/mo plan's disk) is enough — this stack isn't storage-heavy,
and the swapfile only takes 2GB of it. Any DO region close to where the
phones actually are is fine; SIP/RTP care about latency more than raw
bandwidth.

**Swap:** DigitalOcean doesn't provision swap by default, and Docker +
Asterisk + coturn leave little headroom at 512MB–1GB RAM. This installer
detects RAM ≤2GB with no existing swap and offers to add a 2GB swapfile
automatically (persisted in \`/etc/fstab\`) — it's what makes the \$4/mo plan
viable instead of risking an OOM kill under load.

**OS image:** Ubuntu 24.04 LTS (supported through April 2029) is the safe,
battle-tested choice for Docker + coturn. Ubuntu 26.04 LTS is also available
and supported longer (through 2031) if you'd rather track the newer LTS.

## DNS

Before running this installer, point an A record at the droplet's public IP:

\`\`\`
sip.yourdomain.com   A   <droplet public IP>
\`\`\`

The installer reads the droplet's public IP itself (via the DigitalOcean
metadata service) and shows it to you during setup. This one FQDN is used
for SIP, the web admin, and the TLS cert — there's no separate domain to
plan for the admin panel.

## Security

- **SSH:** key-based auth only, password login disabled — \`services/base.sh\`
  in this repo offers to do this for you on first run. Don't skip it; this
  box is public.
- **Two firewall layers, same rule set:**
  - **DigitalOcean Cloud Firewall** — filters at the network edge, before
    traffic reaches the droplet. This installer offers to create one
    automatically via \`doctl\` (only if none is already attached to this
    droplet — it never overwrites an existing one, to avoid clobbering a
    custom SSH allow-list). If \`doctl\` isn't set up, add the rules below
    manually in the DO console (Networking → Firewalls).
  - **UFW** — host-level, configured automatically by this installer as a
    second layer. Keep both in sync; don't let them contradict each other.
- **CrowdSec** — SIP brute-force/enumeration protection (\`crowdsecurity/asterisk\`
  collection). Not installed by this script — install it separately (whiptail
  menu, or \`sudo ./setup.sh crowdsec\`); its own installer auto-detects this
  asterisk-digital-ocean install and wires up SIP protection regardless of install order.
- DO's paid Droplet Backups, or \`services/borg-backup.sh\` installed
  separately, are both options for a rollback path.

### Ports (open on both the Cloud Firewall and UFW)

| Port          | Protocol | Purpose                          |
|---------------|----------|-----------------------------------|
| 22            | TCP      | SSH (keep this open or you're locked out) |
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| ${WEB_ADMIN_PORT_VAL}          | TCP      | Easy Asterisk web admin (auto-picked — see \`.env\`). Only opened publicly if Caddy isn't fronting it locally — otherwise it's reachable only via \`https://${DOMAIN_NAME:-your-domain}/\`, not the bare IP:port. |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| 49152–49252   | UDP      | TURN relay media ports           |

## Internal SIP messaging (no PSTN trunk needed)

Every extension can send/receive Asterisk's native SIP MESSAGE (no carrier
SMS, no PSTN, no cost) once its "messaging" flag is set to yes in
\`pstn-permissions.conf\` — via the Security Dashboard's "Internal SIP
messaging" card, or by hand. This works independent of \`pstn-trunk.sh\`
entirely. Under the hood: every device endpoint gets
\`message_context=sip-messaging\`, routing messages to a dedicated
\`config/asterisk/messaging-dialplan.conf\` context instead of \`[intercom]\`
(which already owns per-device call routing) — this install/update patches
both the device-creation code (so new extensions pick it up automatically)
and any devices that already existed. Confirmed against a live install's
\`pjsip.conf\`/\`extensions.conf\` on 2026-07-23 (message_context falls back to
context=intercom, one exact-match dialplan entry per device) — the MESSAGE
sender-extraction logic itself is still unconfirmed against real traffic;
if messages silently don't arrive, check
\`docker exec easy-asterisk-do asterisk -rx "core set verbose 3"\` while
sending one.

## Extension presence (online/offline) alerts

Optional ntfy alert when an extension's SIP registration changes state —
offered on both fresh install and "update in place". Checked every 2
minutes (systemd timer, cron.d fallback); fires only on a change, never on
every check.

## Other services (installed separately, not by this script)

This installer only sets up Asterisk + coturn. Everything else — Caddy,
CrowdSec, Authelia, ntfy, watchtower, wg-easy, NetBird, Borg backup — is a
normal service in this repo: pick it from the whiptail menu, or run
\`sudo ./setup.sh <name>\` directly. A few integrate automatically with this
install if already present, no extra config needed:

- **Caddy** — if installed (locally, or you're on a remote-Caddy setup), this
  installer reverse-proxies the web admin on \`DOMAIN_NAME\` and Asterisk syncs
  the resulting Let's Encrypt cert for SIP-TLS too. Not installed → self-signed
  cert, plain HTTP admin.
- **Authelia** — if installed locally (needs Caddy), or you point this
  installer at a remote instance (e.g. a homelab, via NetBird mesh IP or a
  public \`https://\` URL), the web admin gets SSO/2FA in front of it.
- **CrowdSec** — see Security above; wires up SIP protection automatically
  once installed, regardless of whether it went in before or after this.

## Manage

\`\`\`bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
\`\`\`

## Management script

\`\`\`bash
docker exec -it easy-asterisk-do easy-asterisk --help
\`\`\`

Use it to create SIP extensions (Server Settings → Extensions) before
connecting a phone.

## Connecting with Sipnetic (Android)

[Sipnetic](https://www.sipnetic.com/) is a free Android SIP client with
TLS/SRTP and STUN/TURN/ICE support — a good fit for this setup. (iPhone
users: Linphone or Zoiper cover the same ground.)

1. In the Easy Asterisk web admin, create an extension — note its
   username/number and password.
2. In Sipnetic, add an account with:

| Setting          | Value                                          |
|-------------------|------------------------------------------------|
| Username          | extension number/username from easy-asterisk   |
| Password          | extension password from easy-asterisk          |
| Domain            | \`${DOMAIN_NAME:-$PUBLIC_IP}\`                        |
| Transport         | TLS                                             |
| Port              | 5061                                            |
| SRTP              | Enabled (optional, for encrypted media)         |
| STUN/TURN server  | \`${DOMAIN_NAME:-$PUBLIC_IP}:3478\`                   |
| TURN username     | \`easyasterisk\` (see \`.env\` → \`TURN_USERNAME\`)    |
| TURN password     | see \`.env\` → \`TURN_PASSWORD\`                      |

3. Save and let it register. If it registers but calls connect with no
   audio, double-check the RTP/TURN port ranges are open on *both* firewall
   layers above.

## TLS certificate

Caddy is what actually talks to Let's Encrypt — Asterisk never does ACME
itself. The installer always reverse-proxies the web admin on the exact
same FQDN used for SIP (never a separate "admin" domain), specifically
because that's what makes Caddy hold a cert matching \`DOMAIN_NAME\`. The
container then mounts Caddy's cert store read-only and the entrypoint syncs
that cert in automatically on every start — and re-checks every 12h so
renewals get picked up without a restart. No Caddy on the box, or no FQDN
set at all, falls back to a self-signed cert (phones must be configured to
accept it manually).

## Web admin

Access the Easy Asterisk web interface at http://<droplet-ip>:${WEB_ADMIN_PORT_VAL}
or via your configured reverse-proxy domain.

## Data directories (all inside ~/docker/asterisk-digital-ocean/, included in backup)

| Directory            | Contents                        |
|-----------------------|----------------------------------|
| config/asterisk/      | /etc/asterisk — dialplan, SIP   |
| config/easy-asterisk/ | /etc/easy-asterisk — web config |
| logs/                 | /var/log/asterisk               |
| spool/                | /var/spool/asterisk             |
| lib/                  | /var/lib/asterisk               |
MD

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk (DO edition) started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Easy Asterisk (DigitalOcean edition) installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    else
        echo "  Mode:        IP-only (self-signed cert)"
        echo "  TURN server: ${PUBLIC_IP:-unknown}:3478"
    fi
    echo "  Public IP:   ${PUBLIC_IP:-unknown}"
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://${PUBLIC_IP:-localhost}:${WEB_ADMIN_PORT_VAL}"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it easy-asterisk-do easy-asterisk --help"
    if [[ -n "$DOMAIN_NAME" ]] && [[ -d "$DOCKER_DIR/caddy" ]]; then
        echo ""
        log_info "If Caddy was just installed in this same run, it may still be obtaining the"
        log_info "Let's Encrypt cert for ${DOMAIN_NAME} — Asterisk only checks for it at startup"
        log_info "and then every 12h. If SIP TLS still shows self-signed after a couple of"
        log_info "minutes, pick it up immediately with:"
        log_info "  docker compose -f $EA_DIR/docker-compose.yml restart asterisk"
    fi
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk-digital-ocean
