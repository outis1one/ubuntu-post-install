#!/bin/bash
# services/pstn-trunk.sh — SIP PSTN trunk add-on for asterisk-digital-ocean
# (or the home/LAN asterisk install): US-only outbound (NANP dialplan
# restriction), independent outbound/inbound concurrent-call caps, a 3-tier
# permission model per extension (internal-only / restricted to pre-approved
# numbers / full US calling), a configurable inbound ring-group,
# IP-authenticated trunk (no SIP password stored), ntfy alerts on
# denied/rejected calls, and a periodic spend/volume check.
#
# Internal extension-to-extension calling (and internal ring groups) is
# never gated by any of the above, regardless of tier — the trunk is purely
# an additional path out to/in from the real phone network.
#
# Defaults to VoIP.ms (see docs/pstn-calling-voipms-plan.md for the design/
# cost background this is built from) but isn't hardcoded to it — any SIP
# trunk provider that supports IP authentication works the same way.
#
# Requires an existing services/asterisk-digital-ocean.sh OR services/asterisk.sh
# install — this adds a PSTN trunk on top of one of them and does not stand
# alone. Permission tiers AND concurrency caps are managed live (no restart
# needed) via pstn-permissions.conf / pstn-limits.conf — editable by hand, or
# from services/security-dashboard.sh's "PSTN Trunk" tab if that's installed.
#
# Part of the modular post-install system (sourced by setup.sh).

register_service pstn-trunk homelab "SIP PSTN trunk for asterisk-digital-ocean/asterisk — US-only, per-extension permission tiers, spend/volume alerts (defaults to VoIP.ms)"

# ── Surviving Easy Asterisk's regeneration ──────────────────────────────────
# Easy Asterisk (the vendor project asterisk-digital-ocean.sh/asterisk.sh
# build on) fully OVERWRITES both pjsip.conf and extensions.conf from its own
# internal state:
#   - extensions.conf: rebuilt by rebuild_dialplan() on every container start,
#     and whenever a device/room is added or removed via the web admin.
#   - pjsip.conf: rewritten by generate_pjsip_conf() whenever VLAN/domain/TLS
#     settings are changed via the CLI menu (docker exec ... easy-asterisk).
#     It restores only its own "; === Device:"-marked sections from backup —
#     a hand-appended trunk section would be silently wiped the next time
#     that runs.
# So the trunk/dialplan content below lives in its own files and is
# #include'd from the generated files instead of appended directly. To make
# the #include itself survive regeneration too, _pstn_patch_vendor_files
# (below) patches it into the vendor's *generator functions* — the same
# technique this repo already uses for the logger.conf security-logging fix
# in _asterisk_do_refresh_vendor_files (see services/asterisk-digital-ocean.sh).
#
# Caveat: if the base asterisk-digital-ocean/asterisk install is later
# refreshed ("update in place", which re-copies fresh vendor files)
# independently of this service, the patch is wiped along with it and needs
# reapplying — run this service again (fresh or update mode both reapply it)
# after any base install update.
#
# ── Why permissions are a separate live file, not baked into the dialplan ──
# pstn-permissions.conf holds each extension's tier (internal/restricted/full)
# and, for restricted, its pipe-separated approved-number list. The dialplan
# reads it via Asterisk's AST_CONFIG() function, which re-reads the file from
# disk on every call — so editing this file (by hand, or via the Security
# Dashboard web UI) takes effect on the very next call, no Asterisk restart
# and no re-running this installer needed. "update in place" (below) never
# touches this file once it exists, for the same reason CLAUDE.md's
# update-mode convention protects .env/firewall/Caddy config — only "fresh"
# reinstall or the web UI change it. This is also why numbers are stored
# pipe-separated, not comma-separated: they're used directly as a regex
# alternation pattern in the dialplan, and the caller-supplied number being
# checked against them must never itself be interpolated into the PATTERN
# side of a REGEX() call (that would let a crafted Caller-ID/dialed-string
# forge a match) — this file's contents are always the pattern, the
# live call data is always the string being tested, never the reverse.

# ── Shared: patch vendor generator functions to #include our config ────────
# Anchors on "user_agent=EasyAsterisk" (pjsip.conf's [global] section) and
# "[intercom]" (extensions.conf) — each confirmed to appear exactly once per
# file in the vendor source, so this is safe regardless of what else changes
# around it upstream. Idempotent: skips files that already have the include.
_pstn_patch_vendor_files() {
    local EA_DIR="$1"
    local ENTRYPOINT="$EA_DIR/docker/entrypoint.sh"
    local EASY1="$EA_DIR/easy-asterisk.sh"
    local EASY2
    EASY2="$(find "$EA_DIR" -maxdepth 1 -name 'easy-asterisk-v*.sh' | head -1)"
    [[ -z "$EASY2" ]] && EASY2="$EA_DIR/easy-asterisk-v0.10.0.sh"
    local f

    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        [[ -f "$f" ]] || { log_error "$f not found — is the base Asterisk install fully set up?"; return 1; }
    done

    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        if ! grep -q 'pstn-trunk-pjsip.conf' "$f"; then
            if grep -q '^user_agent=EasyAsterisk$' "$f"; then
                sed -i '/^user_agent=EasyAsterisk$/a #include pstn-trunk-pjsip.conf' "$f"
            else
                log_warning "$(basename "$f"): 'user_agent=EasyAsterisk' anchor not found — vendor template changed upstream."
                log_warning "  Add '#include pstn-trunk-pjsip.conf' manually after [global] in this file's pjsip.conf heredoc."
            fi
        fi
    done

    for f in "$ENTRYPOINT" "$EASY1" "$EASY2"; do
        if ! grep -q 'pstn-trunk-dialplan.conf' "$f"; then
            if grep -q '^\[intercom\]$' "$f"; then
                sed -i '/^\[intercom\]$/a #include pstn-trunk-dialplan.conf' "$f"
            else
                log_warning "$(basename "$f"): '[intercom]' anchor not found — vendor template changed upstream."
                log_warning "  Add '#include pstn-trunk-dialplan.conf' manually after [intercom] in this file's extensions.conf heredoc."
            fi
        fi
    done

    log_success "Vendor generator functions patched to include the PSTN trunk config."
}

# ── Shared: pjsip trunk config (aor/identify/endpoint, IP-authenticated) ───
_pstn_write_pjsip_include() {
    local FILE="$1" SERVER="$2" SERVER_IP="$3" DID="$4"
    cat > "$FILE" << 'EOF'
; SIP PSTN trunk — IP authentication, no password stored (see
; docs/pstn-calling-voipms-plan.md). Regenerated by services/pstn-trunk.sh —
; edit there, not here directly, or a reinstall/update will overwrite this.
;
; match= below is the resolved IP of the server hostname at install time.
; Providers sometimes send inbound INVITEs from a different IP than the one
; their hostname resolves to (load balancing / multiple servers per POP) —
; if inbound calls stop matching after a provider-side change, re-run this
; service to re-resolve and rewrite it, or add extra "type=identify" /
; "match=" lines here by hand for additional known source IPs.

[pstn-trunk]
type=aor
contact=sip:__PSTN_SERVER__
qualify_frequency=60

[pstn-trunk]
type=identify
endpoint=pstn-trunk
match=__PSTN_SERVER_IP__

[pstn-trunk]
type=endpoint
context=from-pstn-trunk
disallow=all
allow=ulaw,alaw
aors=pstn-trunk
from_user=__PSTN_DID__
from_domain=__PSTN_SERVER__
callerid=__PSTN_DID__
direct_media=no
EOF
    sed -i "s/__PSTN_SERVER_IP__/${SERVER_IP}/g; s/__PSTN_SERVER__/${SERVER}/g; s/__PSTN_DID__/${DID}/g" "$FILE"
}

# ── Shared: one inbound ring-group member's live permission check ─────────
# Emits a block that only adds this extension to PSTN_RING_LIST if it's
# "full" tier, or "restricted" tier AND the inbound Caller-ID is on its
# approved list. Uses a single-quoted heredoc (fully literal — no bash
# expansion) captured into a variable, then a pure bash string replace for
# the extension number placeholder — safer than sed here since it needs no
# escaping at all (the extension is plain digits, but this avoids relying on
# that fact staying true).
_pstn_ring_member_block() {
    local EXT="$1"
    local block
    # ring__EXT__/skip__EXT__ are named priorities WITHIN this same extension
    # (declared below via "same => n(label),..."), not separate exten =>
    # entries — Goto/GotoIf must use the single-argument label form here
    # (bare "?label" / "Goto(label)"), not "label,1" (which addresses a
    # different, nonexistent extension named "label" instead).
    block=$(cat << 'MEMBER'
 same => n,Set(PSTN_M_TIER=${AST_CONFIG(pstn-permissions.conf,__EXT__,tier)})
 same => n,GotoIf($["${PSTN_M_TIER}" = "full"]?ring__EXT__)
 same => n,Set(PSTN_M_ALLOWED=${AST_CONFIG(pstn-permissions.conf,__EXT__,allowed_numbers)})
 same => n,GotoIf($["${PSTN_M_TIER}" = "restricted" & ${REGEX("^(${PSTN_M_ALLOWED})$" ${CALLERID(num)})}=1]?ring__EXT__)
 same => n,Goto(skip__EXT__)
 same => n(ring__EXT__),Set(PSTN_RING_LIST=${PSTN_RING_LIST}${PSTN_RING_SEP}PJSIP/__EXT__)
 same => n,Set(PSTN_RING_SEP=&)
 same => n(skip__EXT__),NoOp()
MEMBER
)
    echo "${block//__EXT__/$EXT}"
}

# ── Shared: outbound/inbound dialplan ───────────────────────────────────────
# Continues in the [intercom] context established just above this include
# (rebuild_dialplan() writes "[intercom]" then this #include right after it),
# so existing extensions can dial out through it directly. [from-pstn-trunk]
# below is a separate context, for calls arriving from the trunk.
#
# Role model: internal intercom dialing (extension-to-extension) is NEVER
# gated here — everyone keeps that, regardless of PSTN tier. Only the two
# NANP patterns (the trunk route) and the inbound ring-group are gated, both
# via a LIVE read of pstn-permissions.conf (see the file-level comment above
# for why that's a separate file rather than baked in here).
#
# Calls are logged to pstn-trunk-calls.log (epoch|direction|who|what|seconds)
# for the usage-alert script — not Asterisk's own CDR, to avoid depending on
# whether cdr_csv is enabled/configured on a given image, and to sidestep
# CDR CSV's comma-quoting entirely (our own pipe-delimited format has no
# embedded-delimiter risk since every field here is digits/hostnames).
_pstn_write_dialplan_include() {
    local FILE="$1" DID="$2" RING_EXTS="$3" NTFY_URL="$4"
    cat > "$FILE" << 'EOF'
; PSTN outbound/inbound — US-only (NANP). Concurrent-call caps (both
; directions) AND tiered permissions (internal / restricted / full) are read
; LIVE from pstn-limits.conf / pstn-permissions.conf via AST_CONFIG() — edit
; either there, or via the Security Dashboard web UI, with no restart
; needed. Regenerated by services/pstn-trunk.sh — edit there, not here
; directly, or a reinstall/update will overwrite this file (pstn-limits.conf
; and pstn-permissions.conf are NOT touched by "update", only by a "fresh"
; reinstall or the web UI).
;
; No catch-all pattern here on purpose: only these two NANP patterns route
; to the trunk, so an unauthorized or compromised extension can't reach
; anything else even if the trunk itself would technically allow more. See
; docs/pstn-calling-voipms-plan.md for the toll-fraud reasoning.

exten => _1NXXNXXXXX,1,NoOp(PSTN outbound call attempt from ${CHANNEL(peername)} to ${EXTEN})
 same => n,Set(PSTN_CALLER=${CHANNEL(peername)})
 same => n,Set(PSTN_TIER=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},tier)})
 same => n,GotoIf($["${PSTN_TIER}" = "full"]?pstn_check_busy,1)
 same => n,GotoIf($["${PSTN_TIER}" = "restricted"]?pstn_check_allow_out,1)
 same => n,NoOp(Denied - ${PSTN_CALLER} has no PSTN permission, tier: ${PSTN_TIER})
__ALERT_DENY_TIER_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => _NXXNXXXXX,1,NoOp(Assuming NANP - adding leading 1)
 same => n,Goto(1${EXTEN},1)

exten => pstn_check_allow_out,1,Set(PSTN_ALLOWED=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},allowed_numbers)})
 same => n,GotoIf($[${REGEX("^(${PSTN_ALLOWED})$" ${EXTEN})} = 1]?pstn_check_busy,1)
 same => n,NoOp(Denied - ${EXTEN} not on ${PSTN_CALLER}'s approved number list)
__ALERT_DENY_NUMBER_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => pstn_check_busy,1,Set(PSTN_MAX_OUT=${AST_CONFIG(pstn-limits.conf,limits,max_outbound)})
 same => n,Set(PSTN_MAX_OUT=${IF($["${PSTN_MAX_OUT}" = ""]?10:${PSTN_MAX_OUT})})
 same => n,GotoIf($[${GROUP_COUNT(pstn-out)} >= ${PSTN_MAX_OUT}]?pstn_busy,1)
 same => n,Set(GROUP()=pstn-out)
 same => n,Set(CALLERID(num)=__PSTN_DID__)
 same => n,Set(PSTN_START=${EPOCH})
 same => n,Dial(PJSIP/${EXTEN}@pstn-trunk,60)
 same => n,Set(PSTN_DUR=$[${EPOCH} - ${PSTN_START}])
 same => n,System(printf '%s|out|%s|%s|%s\n' "${PSTN_START}" "${PSTN_CALLER}" "${EXTEN}" "${PSTN_DUR}" >> /var/log/asterisk/pstn-trunk-calls.log)
 same => n,Hangup()

exten => pstn_busy,1,NoOp(PSTN trunk - outbound concurrent-call cap reached, rejecting)
__ALERT_BUSY_LINE__
 same => n,Busy(15)
 same => n,Hangup()
EOF
    sed -i "s/__PSTN_DID__/${DID}/g" "$FILE"

    if [[ -n "$NTFY_URL" ]]; then
        local _esc_url="${NTFY_URL//&/\\&}"
        sed -i "s#__ALERT_DENY_TIER_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound call denied - no PSTN permission.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_DENY_NUMBER_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound call denied - number not pre-approved.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_BUSY_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound concurrent-call cap reached - a call was rejected.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
    else
        sed -i "/__ALERT_DENY_TIER_LINE__/d; /__ALERT_DENY_NUMBER_LINE__/d; /__ALERT_BUSY_LINE__/d" "$FILE"
    fi

    # ── Inbound: [from-pstn-trunk], one unrolled block per ring-group member.
    # Permission check (is anyone in the ring group authorized for this
    # caller) happens before the concurrency check, mirroring outbound's
    # own ordering (permission gate, then busy gate).
    cat >> "$FILE" << 'EOF'

[from-pstn-trunk]
exten => _X.,1,NoOp(Inbound PSTN call from ${CALLERID(num)})
 same => n,Set(PSTN_RING_LIST=)
 same => n,Set(PSTN_RING_SEP=)
EOF

    local _ext
    for _ext in $RING_EXTS; do
        _pstn_ring_member_block "$_ext" >> "$FILE"
    done

    cat >> "$FILE" << 'EOF'
 same => n,GotoIf($["${PSTN_RING_LIST}" = ""]?pstn_in_denied,1)
 same => n,Set(PSTN_MAX_IN=${AST_CONFIG(pstn-limits.conf,limits,max_inbound)})
 same => n,Set(PSTN_MAX_IN=${IF($["${PSTN_MAX_IN}" = ""]?10:${PSTN_MAX_IN})})
 same => n,GotoIf($[${GROUP_COUNT(pstn-in)} >= ${PSTN_MAX_IN}]?pstn_in_busy,1)
 same => n,Set(GROUP()=pstn-in)
 same => n,Set(PSTN_START=${EPOCH})
 same => n,Dial(${PSTN_RING_LIST},20)
 same => n,Set(PSTN_DUR=$[${EPOCH} - ${PSTN_START}])
 same => n,System(printf '%s|in|%s|ring-group|%s\n' "${PSTN_START}" "${CALLERID(num)}" "${PSTN_DUR}" >> /var/log/asterisk/pstn-trunk-calls.log)
 same => n,Hangup()

exten => pstn_in_denied,1,NoOp(Inbound PSTN call from ${CALLERID(num)} - no ring target authorized for this caller)
__ALERT_DENY_INBOUND_LINE__
 same => n,Hangup()

exten => pstn_in_busy,1,NoOp(PSTN trunk - inbound concurrent-call cap reached, rejecting)
__ALERT_BUSY_IN_LINE__
 same => n,Busy(15)
 same => n,Hangup()
EOF

    if [[ -n "$NTFY_URL" ]]; then
        local _esc_url2="${NTFY_URL//&/\\&}"
        sed -i "s#__ALERT_DENY_INBOUND_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: inbound call rejected - caller not approved for any ring target.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_BUSY_IN_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: inbound concurrent-call cap reached - a call was rejected.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
    else
        sed -i "/__ALERT_DENY_INBOUND_LINE__/d; /__ALERT_BUSY_IN_LINE__/d" "$FILE"
    fi
}

# ── Shared: initial concurrency limits (fresh install / explicit reset only
# — same "update never touches it" protection as pstn-permissions.conf, see
# the file-level comment above) ─────────────────────────────────────────────
_pstn_write_limits_file() {
    local FILE="$1" MAX_OUT="$2" MAX_IN="$3"
    {
        echo "; PSTN concurrent-call caps, both directions."
        echo "; Read LIVE by the dialplan on every call (AST_CONFIG()) — no Asterisk"
        echo "; restart needed when this changes. Edit here directly, via the Security"
        echo "; Dashboard web UI's \"PSTN Trunk\" tab (if installed), or by re-running"
        echo "; 'sudo ./setup.sh pstn-trunk' and choosing a FRESH reinstall (\"update in"
        echo "; place\" leaves this file alone on purpose)."
        echo ""
        echo "[limits]"
        echo "max_outbound=${MAX_OUT}"
        echo "max_inbound=${MAX_IN}"
    } > "$FILE"
    chmod 664 "$FILE"
}

# ── Shared: initial permission tiers (fresh install / explicit reset only —
# "update in place" never calls this, matching how .env/firewall/Caddy config
# are protected elsewhere in this repo; see file-level comment above) ──────
# Args: FILE, space-separated FULL_EXTS, then "ext" "pipe|separated|numbers"
# pairs for each restricted extension.
_pstn_write_permissions_file() {
    local FILE="$1" FULL_EXTS="$2"
    shift 2
    {
        echo "; PSTN permission tiers — internal / restricted / full."
        echo "; Read LIVE by the dialplan on every call (AST_CONFIG()) — no Asterisk"
        echo "; restart needed when this changes. Edit here directly, via the Security"
        echo "; Dashboard web UI's \"PSTN Trunk\" tab (if installed), or by re-running"
        echo "; 'sudo ./setup.sh pstn-trunk' and choosing a FRESH reinstall (\"update in"
        echo "; place\" leaves this file alone on purpose)."
        echo "; Any extension not listed here is internal-only (no PSTN) by default —"
        echo "; it can still call/receive other Asterisk extensions and join internal"
        echo "; ring groups, just not the PSTN trunk."
        echo ""
        local _ext
        for _ext in $FULL_EXTS; do
            echo "[$_ext]"
            echo "tier=full"
            echo ""
        done
        while [[ $# -gt 0 ]]; do
            _ext="$1"; local _nums="$2"
            shift 2
            echo "[$_ext]"
            echo "tier=restricted"
            echo "allowed_numbers=${_nums}"
            echo ""
        done
    } > "$FILE"
    chmod 664 "$FILE"
}

# ── Shared: periodic spend/volume checker (run hourly via cron) ────────────
_pstn_write_usage_alert_script() {
    local FILE="$1" EA_DIR="$2" RATE="$3" MONTH_THRESHOLD="$4" BURST_THRESHOLD="$5" NTFY_URL="$6"
    cat > "$FILE" << 'EOF'
#!/bin/bash
# Auto-generated by services/pstn-trunk.sh — do not edit directly, re-run
# the installer instead. Run hourly via /etc/cron.d/pstn-trunk-usage.
# Reads the call log pstn-trunk-dialplan.conf appends to and alerts via
# ntfy when month-to-date estimated spend crosses a threshold (alerted once
# per month) or when call volume in the last hour looks like a burst.

LOG_FILE="__EA_DIR__/logs/pstn-trunk-calls.log"
STATE_FILE="__EA_DIR__/.pstn-trunk-alert-state"
RATE="__PSTN_RATE__"
MONTH_THRESHOLD="__PSTN_MONTH_THRESHOLD__"
BURST_THRESHOLD="__PSTN_BURST_THRESHOLD__"
NTFY_URL="__PSTN_NTFY_URL__"

[[ -f "$LOG_FILE" ]] || exit 0

now_epoch=$(date +%s)
current_month=$(date +%Y-%m)
one_hour_ago=$((now_epoch - 3600))
month_start_epoch=$(date -d "$(date +%Y-%m-01)" +%s)

month_seconds=$(awk -F'|' -v start="$month_start_epoch" '$2=="out" && $1+0>=start {sum+=$5} END{print sum+0}' "$LOG_FILE")
month_minutes=$(awk -v s="$month_seconds" 'BEGIN{printf "%.1f", s/60}')
month_cost=$(awk -v m="$month_minutes" -v r="$RATE" 'BEGIN{printf "%.2f", m*r}')
hour_calls=$(awk -F'|' -v start="$one_hour_ago" '$2=="out" && $1+0>=start {c++} END{print c+0}' "$LOG_FILE")

send_ntfy() {
    [[ -n "$NTFY_URL" ]] && curl -m 5 -s -d "$1" "$NTFY_URL" >/dev/null 2>&1
}

last_alert_month=""
[[ -f "$STATE_FILE" ]] && last_alert_month=$(cat "$STATE_FILE")

if awk -v c="$month_cost" -v t="$MONTH_THRESHOLD" 'BEGIN{exit !(c>=t)}'; then
    if [[ "$last_alert_month" != "$current_month" ]]; then
        send_ntfy "PSTN trunk: estimated spend this month (\$${month_cost}) has crossed the \$${MONTH_THRESHOLD} threshold. ${month_minutes} minutes so far."
        echo "$current_month" > "$STATE_FILE"
    fi
fi

if [[ "$hour_calls" -ge "$BURST_THRESHOLD" ]]; then
    send_ntfy "PSTN trunk: $hour_calls outbound calls placed in the last hour - check for unusual activity."
fi
EOF
    sed -i "s#__EA_DIR__#${EA_DIR}#g; s/__PSTN_RATE__/${RATE}/g; s/__PSTN_MONTH_THRESHOLD__/${MONTH_THRESHOLD}/g; s/__PSTN_BURST_THRESHOLD__/${BURST_THRESHOLD}/g" "$FILE"
    sed -i "s#__PSTN_NTFY_URL__#${NTFY_URL}#g" "$FILE"
    chmod 755 "$FILE"
}

# ── Shared: structural settings only (used by fresh install AND update) ────
# Does NOT touch pstn-permissions.conf — see the file-level comment above
# for why that file is managed separately.
_pstn_apply_settings() {
    local EA_DIR="$1" ASTERISK_DIR="$2"
    local SERVER="$3" SERVER_IP="$4" DID="$5"
    local RING_EXTS="$6" NTFY_URL="$7" RATE="$8" MONTH_THRESHOLD="$9" BURST_THRESHOLD="${10}"
    local PROVIDER_NAME="${11}"

    _pstn_patch_vendor_files "$EA_DIR" || return 1

    mkdir -p "$ASTERISK_DIR"
    _pstn_write_pjsip_include "$ASTERISK_DIR/pstn-trunk-pjsip.conf" "$SERVER" "$SERVER_IP" "$DID"
    _pstn_write_dialplan_include "$ASTERISK_DIR/pstn-trunk-dialplan.conf" "$DID" "$RING_EXTS" "$NTFY_URL"
    _pstn_write_usage_alert_script "$EA_DIR/pstn-trunk-usage-alert.sh" "$EA_DIR" "$RATE" "$MONTH_THRESHOLD" "$BURST_THRESHOLD" "$NTFY_URL"
    ensure_docker_dir_ownership "$ASTERISK_DIR"
    chmod 644 "$ASTERISK_DIR/pstn-trunk-pjsip.conf" "$ASTERISK_DIR/pstn-trunk-dialplan.conf"

    cat > "$EA_DIR/.pstn-trunk.env" << ENV
PROVIDER_NAME=${PROVIDER_NAME}
TRUNK_SERVER=${SERVER}
TRUNK_SERVER_IP=${SERVER_IP}
TRUNK_DID=${DID}
RING_EXTS=${RING_EXTS}
NTFY_URL=${NTFY_URL}
RATE_PER_MIN=${RATE}
MONTH_THRESHOLD=${MONTH_THRESHOLD}
BURST_THRESHOLD=${BURST_THRESHOLD}
ENV
    chown "$ACTUAL_USER:$ACTUAL_USER" "$EA_DIR/.pstn-trunk.env" 2>/dev/null || true

    if command -v cron >/dev/null 2>&1 || [[ -d /etc/cron.d ]]; then
        cat > /etc/cron.d/pstn-trunk-usage << CRON
0 * * * * root /bin/bash $EA_DIR/pstn-trunk-usage-alert.sh >> $EA_DIR/logs/pstn-trunk-usage-alert.log 2>&1
CRON
        log_success "Hourly spend/volume check installed (cron.d)."
    else
        log_warning "cron not available — run $EA_DIR/pstn-trunk-usage-alert.sh manually/periodically for spend/volume alerts."
    fi
}

install_pstn-trunk() {
    require_docker || return 1

    local EA_DIR="" ASTERISK_KIND=""
    if [[ -f "$DOCKER_DIR/asterisk-digital-ocean/docker-compose.yml" ]]; then
        EA_DIR="$DOCKER_DIR/asterisk-digital-ocean"
        ASTERISK_KIND="asterisk-digital-ocean"
    elif [[ -f "$DOCKER_DIR/asterisk/docker-compose.yml" ]]; then
        EA_DIR="$DOCKER_DIR/asterisk"
        ASTERISK_KIND="asterisk"
    fi

    local ASTERISK_DIR="$EA_DIR/config/asterisk"
    local PJSIP_INCLUDE="$ASTERISK_DIR/pstn-trunk-pjsip.conf"
    local DIALPLAN_INCLUDE="$ASTERISK_DIR/pstn-trunk-dialplan.conf"
    local PERMISSIONS_FILE="$ASTERISK_DIR/pstn-permissions.conf"
    local LIMITS_FILE="$ASTERISK_DIR/pstn-limits.conf"
    local SETTINGS_FILE="$EA_DIR/.pstn-trunk.env"
    local CONTAINER_NAME="easy-asterisk"
    [[ "$ASTERISK_KIND" == "asterisk-digital-ocean" ]] && CONTAINER_NAME="easy-asterisk-do"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would require an existing asterisk-digital-ocean OR asterisk (LAN) install"
        echo "[DRY-RUN] Would prompt for: SIP provider name (default VoIP.ms), server/POP hostname, DID,"
        echo "[DRY-RUN]   full-PSTN extensions, restricted-PSTN extensions + their approved numbers,"
        echo "[DRY-RUN]   max concurrent outbound/inbound calls (default 10/10), inbound ring-group extensions,"
        echo "[DRY-RUN]   ntfy alert topic (optional), per-minute rate + monthly/hourly alert thresholds"
        echo "[DRY-RUN] Would resolve the server hostname to an IP for inbound call matching"
        echo "[DRY-RUN] Would patch vendor generator functions to #include the trunk config"
        echo "[DRY-RUN] Would write pjsip/dialplan includes, pstn-permissions.conf + pstn-limits.conf"
        echo "[DRY-RUN]   (fresh install only), and an hourly usage-alert script + cron.d entry"
        echo "[DRY-RUN] Would offer 'update in place' (structural settings only — never touches"
        echo "[DRY-RUN]   pstn-permissions.conf or pstn-limits.conf) instead of a fresh install if"
        echo "[DRY-RUN]   already configured"
        echo "[DRY-RUN] Would restart the asterisk container to apply"
        return 0
    fi

    if [[ -z "$EA_DIR" ]]; then
        log_error "Neither asterisk-digital-ocean nor asterisk (LAN) is installed — install one first:"
        log_error "  sudo ./setup.sh asterisk-digital-ocean     (recommended — public droplet, static IP)"
        log_error "  sudo ./setup.sh asterisk                   (home/LAN — see the static-IP caveat below)"
        log_error "This service adds a PSTN trunk on top of one of them; it doesn't stand alone."
        return 1
    fi

    if [[ "$ASTERISK_KIND" == "asterisk" ]]; then
        echo ""
        log_warning "Using the home/LAN asterisk install. IP authentication needs a STABLE public IP —"
        log_warning "if this box is behind a dynamic home IP, your provider's IP allow-list goes stale"
        log_warning "whenever your ISP rotates it, breaking calls until you update it there yourself."
        log_warning "A static IP from your ISP avoids that; asterisk-digital-ocean sidesteps it entirely."
    fi

    log_info "Configuring a SIP PSTN trunk for $ASTERISK_KIND (defaults to VoIP.ms)."
    log_info "US-only outbound (NANP dialplan), a concurrent-call cap, per-extension permission"
    log_info "tiers, an inbound ring-group, and ntfy alerts on denied/rejected calls plus"
    log_info "spend/volume checks."
    echo ""
    log_warning "Before continuing, on your provider's side you should already have: created an"
    log_warning "account, funded and set up prepaid billing with auto-recharge OFF (VoIP.ms: Client"
    log_warning "Area -> Balance Management), ordered a DID with IP authentication pointed at this"
    log_warning "box's public IP, and picked a server/POP. Also restrict outbound routing to"
    log_warning "US/NANP on the provider's own side if it offers that — this dialplan is the second,"
    log_warning "independent layer, not a substitute for the first."
    log_warning "See docs/pstn-calling-voipms-plan.md for the full background."
    echo ""

    # ── Existing install? Offer update-in-place instead of a full reinstall ──
    if [[ -f "$PJSIP_INCLUDE" && -f "$DIALPLAN_INCLUDE" ]]; then
        log_info "Existing PSTN trunk config found."
        local REINSTALL_MODE=""
        prompt_reinstall_mode REINSTALL_MODE
        case "$REINSTALL_MODE" in
            update)
                if [[ -f "$SETTINGS_FILE" ]]; then
                    # shellcheck disable=SC1090
                    source "$SETTINGS_FILE"
                    _pstn_apply_settings "$EA_DIR" "$ASTERISK_DIR" \
                        "$TRUNK_SERVER" "$TRUNK_SERVER_IP" "$TRUNK_DID" \
                        "$RING_EXTS" "$NTFY_URL" "$RATE_PER_MIN" \
                        "$MONTH_THRESHOLD" "$BURST_THRESHOLD" "$PROVIDER_NAME" || return 1
                    ( cd "$EA_DIR" && docker compose restart asterisk ) \
                        && log_success "Updated — settings unchanged (server $TRUNK_SERVER, DID $TRUNK_DID, ring exts: $RING_EXTS)." \
                        || log_warning "Restart failed — check: docker compose -f $EA_DIR/docker-compose.yml logs asterisk"
                    log_info "pstn-permissions.conf and pstn-limits.conf were NOT touched — edit them"
                    log_info "directly, via the Security Dashboard, or choose FRESH reinstall to reset them."
                    return 0
                else
                    log_warning "No $SETTINGS_FILE found (pre-dates this settings-file version) — falling back to a fresh install (every prompt below)."
                fi
                ;;
            cancel)
                log_info "Leaving the existing PSTN trunk config as-is."
                return 0
                ;;
            fresh)
                if [[ -f "$PERMISSIONS_FILE" || -f "$LIMITS_FILE" ]]; then
                    log_warning "pstn-permissions.conf and/or pstn-limits.conf already exist and may have"
                    log_warning "been edited since (directly, or via the Security Dashboard). A fresh"
                    log_warning "reinstall OVERWRITES both with whatever you enter below."
                    local _confirm_reset=""
                    prompt_yn "Continue and reset permission tiers + concurrency caps? (y/n):" "n" _confirm_reset
                    if [[ ! "$_confirm_reset" =~ ^[Yy]$ ]]; then
                        log_info "Cancelled — nothing changed."
                        return 0
                    fi
                fi
                log_info "Proceeding with a full fresh reinstall — every prompt below runs from scratch."
                ;;
        esac
    fi

    # ── Prompts — provider account details aren't scriptable, set up manually
    # on the provider's own site first (see warning above) ───────────────────
    local PROVIDER_NAME=""
    prompt_text "SIP trunk provider name (for your reference/docs only):" "VoIP.ms" PROVIDER_NAME

    local TRUNK_SERVER=""
    prompt_text "Server/POP hostname (e.g. atlanta2.voip.ms for VoIP.ms — pick the one closest to this box from your provider's server list):" "" TRUNK_SERVER
    if [[ -z "$TRUNK_SERVER" ]]; then
        log_error "A server hostname is required — aborting."
        return 1
    fi

    local TRUNK_SERVER_IP=""
    TRUNK_SERVER_IP="$(getent ahostsv4 "$TRUNK_SERVER" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -z "$TRUNK_SERVER_IP" ]]; then
        log_warning "Couldn't resolve $TRUNK_SERVER — the identify section needs an IP to match inbound calls against."
        prompt_text "Enter its IP manually (check your provider's server list page):" "" TRUNK_SERVER_IP
        if [[ -z "$TRUNK_SERVER_IP" ]]; then
            log_error "No IP available — aborting."
            return 1
        fi
    else
        log_success "Resolved $TRUNK_SERVER -> $TRUNK_SERVER_IP"
    fi

    local TRUNK_DID=""
    prompt_text "DID (the 10-digit US phone number assigned to this trunk, digits only):" "" TRUNK_DID
    if [[ ! "$TRUNK_DID" =~ ^[0-9]{10}$ ]]; then
        log_error "That doesn't look like a 10-digit US number — aborting."
        return 1
    fi

    # ── Permission tiers ───────────────────────────────────────────────────
    echo ""
    echo "  Three tiers, per extension:"
    echo "    internal   — call/receive other Asterisk extensions + internal ring"
    echo "                 groups only. No PSTN at all. Default for anything not"
    echo "                 listed below."
    echo "    restricted — internal, PLUS call/receive ONLY pre-approved US numbers."
    echo "    full       — internal, PLUS call/receive ANY US number."
    echo "  These are managed LIVE after install (pstn-permissions.conf) — via the"
    echo "  Security Dashboard web UI if installed, or by hand — with no restart or"
    echo "  reinstall needed to change them later."
    local FULL_EXTS=""
    prompt_text "Full-PSTN extensions (space-separated, blank = none):" "" FULL_EXTS

    local RESTRICTED_EXTS=""
    prompt_text "Restricted-PSTN extensions (space-separated, blank = none):" "" RESTRICTED_EXTS

    local RESTRICTED_ARGS=()
    if [[ -n "$RESTRICTED_EXTS" ]]; then
        local _ext _raw_nums _clean_nums
        for _ext in $RESTRICTED_EXTS; do
            prompt_text "  Approved numbers for extension $_ext (comma/space-separated, 11-digit US numbers, e.g. 15551234567):" "" _raw_nums
            _clean_nums="$(echo "$_raw_nums" | tr ', ' '\n\n' | grep -E '^[0-9]{11}$' | paste -sd'|' - 2>/dev/null)"
            if [[ -z "$_clean_nums" ]]; then
                log_warning "No valid 11-digit numbers entered for $_ext — it will be restricted with an EMPTY"
                log_warning "approved list, meaning no PSTN number can currently reach/be reached by it until"
                log_warning "you add some (via the Security Dashboard or by editing pstn-permissions.conf)."
            fi
            RESTRICTED_ARGS+=("$_ext" "$_clean_nums")
        done
    fi

    echo ""
    echo "  Concurrent-call caps (both directions) are also live — changeable later via"
    echo "  the Security Dashboard or by hand, no restart needed."
    local MAX_OUTBOUND=""
    prompt_text "Max simultaneous outbound PSTN calls allowed:" "10" MAX_OUTBOUND
    if [[ ! "$MAX_OUTBOUND" =~ ^[0-9]+$ ]]; then
        log_warning "Not a number — defaulting to 10."
        MAX_OUTBOUND=10
    fi
    local MAX_INBOUND=""
    prompt_text "Max simultaneous inbound PSTN calls allowed:" "10" MAX_INBOUND
    if [[ ! "$MAX_INBOUND" =~ ^[0-9]+$ ]]; then
        log_warning "Not a number — defaulting to 10."
        MAX_INBOUND=10
    fi

    local _suggested_ring
    _suggested_ring="$(echo "$FULL_EXTS $RESTRICTED_EXTS" | xargs)"
    local RING_EXTS=""
    prompt_text "Extensions to ring for inbound PSTN calls (space-separated — one, or several for a ring group; only full/restricted-tier members will actually ring):" "$_suggested_ring" RING_EXTS
    if [[ -z "$RING_EXTS" ]]; then
        log_error "At least one extension is required for inbound routing — aborting."
        return 1
    fi

    echo ""
    local WANT_NTFY=""
    prompt_yn "Send an ntfy alert when a call is denied (permission tier/approved-number check failed) or rejected (concurrency cap hit)? (y/n):" "y" WANT_NTFY
    local NTFY_URL=""
    if [[ "$WANT_NTFY" =~ ^[Yy]$ ]]; then
        # Prefer a locally-installed ntfy's own base-url as the default, same
        # detection pattern services/crowdsec.sh uses for its own ntfy alerts.
        local _ntfy_default="https://ntfy.sh/pstn-trunk-alerts"
        if [ -f "$DOCKER_DIR/ntfy/config/server.yml" ]; then
            local _local_base_url
            _local_base_url="$(grep -oP '(?<=base-url: ")[^"]+' "$DOCKER_DIR/ntfy/config/server.yml" 2>/dev/null || true)"
            if [ -n "$_local_base_url" ] && [ "$_local_base_url" != "https://ntfy.example.com" ]; then
                _ntfy_default="${_local_base_url}/pstn-trunk-alerts"
                log_info "Detected a configured local ntfy instance at $_local_base_url — using it as the default."
            fi
        fi
        if [ "$_ntfy_default" = "https://ntfy.sh/pstn-trunk-alerts" ]; then
            log_info "No configured local ntfy instance detected — defaulting to the public ntfy.sh."
            log_info "If you have one hosted elsewhere, enter its topic URL instead."
        fi
        prompt_text "  ntfy topic URL:" "$_ntfy_default" NTFY_URL
    fi

    echo ""
    log_info "Spend/volume alert settings (used only to estimate cost and flag unusual usage —"
    log_info "not billing-accurate, just a safety net)."
    local RATE_PER_MIN=""
    prompt_text "  Outbound per-minute rate in USD (VoIP.ms US rate is 0.01):" "0.01" RATE_PER_MIN
    local MONTH_THRESHOLD=""
    prompt_text "  Alert once when estimated spend this month reaches (USD):" "10" MONTH_THRESHOLD
    local BURST_THRESHOLD=""
    prompt_text "  Alert if more than this many outbound calls happen in one hour:" "10" BURST_THRESHOLD

    _pstn_apply_settings "$EA_DIR" "$ASTERISK_DIR" \
        "$TRUNK_SERVER" "$TRUNK_SERVER_IP" "$TRUNK_DID" \
        "$RING_EXTS" "$NTFY_URL" "$RATE_PER_MIN" \
        "$MONTH_THRESHOLD" "$BURST_THRESHOLD" "$PROVIDER_NAME" || return 1

    _pstn_write_permissions_file "$PERMISSIONS_FILE" "$FULL_EXTS" "${RESTRICTED_ARGS[@]}"
    _pstn_write_limits_file "$LIMITS_FILE" "$MAX_OUTBOUND" "$MAX_INBOUND"
    ensure_docker_dir_ownership "$ASTERISK_DIR"

    # No new firewall rules: the base install already opens SIP (5060/5061)
    # and RTP (10000-20000) to the internet, and providers' source IPs vary
    # by POP/redundancy, so there's no single IP to scope this to even if
    # narrowing it were otherwise worthwhile.

    # ── Docs (separate file — the base install already owns README.md in
    # this same directory via write_readme, so don't overwrite it) ─────────
    local DOC_FILE="$EA_DIR/README-pstn-trunk.md"
    cat > "$DOC_FILE" << MD
# SIP PSTN trunk (add-on to $ASTERISK_KIND)

US-only outbound PSTN calling over a SIP trunk (defaults to VoIP.ms, works
with any IP-authenticated provider), per-extension permission tiers, a
configurable concurrent-call cap, and an inbound ring-group. See
\`docs/pstn-calling-voipms-plan.md\` in the repo for the full design
background, cost estimate, and toll-fraud reasoning.

## Current settings

| Setting | Value |
|---|---|
| Provider | ${PROVIDER_NAME} |
| Server/POP | ${TRUNK_SERVER} (${TRUNK_SERVER_IP}) |
| DID | ${TRUNK_DID} |
| Outbound scope | US/NANP only — \`_1NXXNXXXXX\` / \`_NXXNXXXXX\` patterns, no catch-all |
| Full-PSTN extensions | ${FULL_EXTS:-none} |
| Restricted-PSTN extensions | ${RESTRICTED_EXTS:-none} |
| Concurrency caps | ${MAX_OUTBOUND} outbound / ${MAX_INBOUND} inbound simultaneous calls (live — see \`pstn-limits.conf\` below) |
| Inbound ring-group | ${RING_EXTS} |
| ntfy alerts | ${NTFY_URL:-disabled} |
| Estimated rate | \$${RATE_PER_MIN}/min |
| Monthly spend alert threshold | \$${MONTH_THRESHOLD} |
| Hourly burst alert threshold | ${BURST_THRESHOLD} calls/hour |

## Permission tiers

Every extension can always call and receive calls from other Asterisk
extensions, and join internal ring groups — that's unchanged and never
gated by anything below. Three tiers control PSTN (real phone number)
access specifically:

- **internal** (default — anything not listed as full/restricted): no PSTN
  at all, in or out.
- **restricted**: can only call and be called by numbers on its own
  pre-approved list.
- **full**: can call/receive any US number.

Stored in \`config/asterisk/pstn-permissions.conf\`, read **live** by the
dialplan via Asterisk's \`AST_CONFIG()\` on every call — editing this file
(by hand, or via the Security Dashboard's "PSTN Trunk" tab, if that service
is installed) takes effect on the next call, no restart needed. Re-running
this installer in "update" mode never touches this file — only a "fresh"
reinstall (with confirmation) or the web UI change it, the same protection
CLAUDE.md's update-mode convention gives \`.env\`/firewall/Caddy config
elsewhere in this repo.

## Concurrent-call caps

Two independent caps, one per direction — outbound (\`${MAX_OUTBOUND}\`) and
inbound (\`${MAX_INBOUND}\`), tracked separately (\`GROUP()\`/\`GROUP_COUNT()\`
on \`pstn-out\`/\`pstn-in\`). A cap being hit rejects the *next* call over the
limit with a busy signal (and an ntfy alert, if enabled) — existing calls
are never affected.

Stored in \`config/asterisk/pstn-limits.conf\`, read **live** the same way as
permission tiers — editable by hand, via the Security Dashboard, with no
restart needed, and likewise untouched by "update in place" (only "fresh"
reinstall or the web UI change it).

## How this survives Easy Asterisk's own regeneration

Easy Asterisk rewrites \`pjsip.conf\` and \`extensions.conf\` from its own
internal state (device list, network settings) rather than treating them as
hand-edited files. Trunk/dialplan config here lives in files of its own,
\`#include\`'d from the generated files:

- \`config/asterisk/pstn-trunk-pjsip.conf\` — the trunk's \`aor\`/\`identify\`/
  \`endpoint\` sections (IP-authenticated, no password stored).
- \`config/asterisk/pstn-trunk-dialplan.conf\` — NANP-only outbound routing,
  ntfy alert hooks, and the \`[from-pstn-trunk]\` inbound context. Reads
  permission tiers from \`pstn-permissions.conf\` and concurrency caps from
  \`pstn-limits.conf\` (both above) live, rather than baking either in,
  specifically so they can change without touching this file.

The \`#include\` lines themselves are patched into Easy Asterisk's *generator
functions* (\`docker/entrypoint.sh\`, \`easy-asterisk.sh\`, and its versioned
copy) so they get re-emitted every time those functions regenerate the
config, instead of being wiped.

**Caveat:** if the base $ASTERISK_KIND service is ever updated independently
(\`sudo ./setup.sh $ASTERISK_KIND\`, choosing "update in place" — that path
re-copies fresh vendor files), this patch is wiped along with it. Re-run
\`sudo ./setup.sh pstn-trunk\` afterward (update mode reapplies the patch and
rewrites structural settings from \`.pstn-trunk.env\`, no re-prompting, and
without touching \`pstn-permissions.conf\` or \`pstn-limits.conf\`).

## Spend/volume alerts

\`pstn-trunk-usage-alert.sh\` runs hourly (\`/etc/cron.d/pstn-trunk-usage\`) and
reads \`logs/pstn-trunk-calls.log\` (appended to directly by the dialplan, not
Asterisk's own CDR — a deliberate choice to avoid depending on whether this
image's CDR modules are enabled/configured, and to sidestep CDR CSV's
comma-quoting). It sends an ntfy alert:

- **Once per calendar month** the first time estimated spend crosses
  \$${MONTH_THRESHOLD} (state tracked in \`.pstn-trunk-alert-state\` so it
  doesn't repeat every hour).
- **Every hour** that outbound call volume exceeds ${BURST_THRESHOLD}
  calls/hour — this is the faster tripwire for a burst/abuse scenario,
  independent of whether it's crossed the monthly dollar threshold yet.

Separately, denied calls (no permission / number not pre-approved) and
rejected calls (either concurrency cap hit) alert **immediately**, not on
the hourly schedule.

These are cost *estimates* (call count/duration × your entered rate), not
real billing data — treat them as a safety net, not a substitute for
checking your provider's own balance/usage dashboard.

## Managing this from a web UI

If \`services/security-dashboard.sh\` is installed, its "PSTN Trunk" tab
shows both the per-extension permission tiers and the outbound/inbound
concurrency caps, all editable live — no restart, no reinstall. Install/
update it any time with \`sudo ./setup.sh security-dashboard\`; it
auto-detects this install.

## Manual edits

Don't hand-edit \`pstn-trunk-pjsip.conf\` / \`pstn-trunk-dialplan.conf\` /
\`pstn-trunk-usage-alert.sh\` directly if you plan to re-run this installer
later — it overwrites all three unconditionally from \`.pstn-trunk.env\` on
both fresh and update. \`pstn-permissions.conf\` and \`pstn-limits.conf\` are
different — see "Permission tiers" / "Concurrent-call caps" above, both are
safe to hand-edit any time. For one-off testing, restart the container
instead of running the installer:

\`\`\`bash
docker compose -f $EA_DIR/docker-compose.yml restart asterisk
\`\`\`

## Verifying it's working

\`\`\`bash
docker exec -it $CONTAINER_NAME asterisk -rx "pjsip show endpoint pstn-trunk"
docker exec -it $CONTAINER_NAME asterisk -rx "dialplan show intercom"
docker exec -it $CONTAINER_NAME asterisk -rx "dialplan show from-pstn-trunk"
tail -f $EA_DIR/logs/pstn-trunk-calls.log
\`\`\`

A full-tier device should be able to dial a 10-digit or 11-digit US number
and reach the trunk; a restricted-tier device should only reach numbers on
its approved list; an internal-tier device should get a busy signal (and an
ntfy alert, if enabled). A call to \`${TRUNK_DID}\` from an approved/any US
number (depending on tier) should ring: ${RING_EXTS}.
MD
    chown "$ACTUAL_USER:$ACTUAL_USER" "$DOC_FILE" 2>/dev/null || true

    # ── Apply ──────────────────────────────────────────────────────────────
    echo ""
    local RESTART_NOW=""
    prompt_yn "Restart the asterisk container now to apply the trunk config? (y/n):" "y" RESTART_NOW
    if [[ "$RESTART_NOW" =~ ^[Yy]$ ]]; then
        if ( cd "$EA_DIR" && docker compose restart asterisk ); then
            log_success "Asterisk restarted — trunk config applied."
        else
            log_warning "Restart failed — check: docker compose -f $EA_DIR/docker-compose.yml logs asterisk"
        fi
    else
        log_info "Apply later with: docker compose -f $EA_DIR/docker-compose.yml restart asterisk"
    fi

    echo ""
    log_success "PSTN trunk configured."
    echo "  Provider:              $PROVIDER_NAME ($TRUNK_SERVER / $TRUNK_SERVER_IP)"
    echo "  DID:                   $TRUNK_DID"
    echo "  Outbound:              US/NANP only, max $MAX_OUTBOUND concurrent calls"
    echo "  Inbound:               max $MAX_INBOUND concurrent calls"
    echo "  Full-PSTN extensions:  ${FULL_EXTS:-none}"
    echo "  Restricted extensions: ${RESTRICTED_EXTS:-none}"
    echo "  Inbound ring-group:    $RING_EXTS"
    echo "  ntfy alerts:           ${NTFY_URL:-disabled}"
    echo "  Docs:                  $DOC_FILE"
    echo ""
}
