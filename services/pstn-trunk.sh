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
# Provider-agnostic — any SIP trunk provider that supports IP authentication
# works the same way. VoIP.ms and Anveo Direct are both confirmed working;
# see docs/pstn-calling-voipms-plan.md for the design/cost background.
#
# Requires an existing services/asterisk-digital-ocean.sh OR services/asterisk.sh
# install — this adds a PSTN trunk on top of one of them and does not stand
# alone. Permission tiers AND concurrency caps are managed live (no restart
# needed) via pstn-permissions.conf / pstn-limits.conf — editable by hand, or
# from services/security-dashboard.sh's "PSTN Trunk" tab if that's installed.
#
# Part of the modular post-install system (sourced by setup.sh).

register_service pstn-trunk homelab "SIP PSTN trunk for asterisk-digital-ocean/asterisk — US-only, per-extension permission tiers, spend/volume alerts (any IP-authenticated provider — VoIP.ms and Anveo Direct both confirmed)"

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

# ── Shared: force the #include lines into the LIVE config files ────────────
# Confirmed live (2026-07-23): _pstn_patch_vendor_files above patches the
# *generator functions* so a FUTURE full regeneration includes the trunk
# config — but Easy Asterisk's entrypoint only calls generate_pjsip_conf()/
# rebuild_dialplan() when pjsip.conf/extensions.conf DON'T ALREADY EXIST
# (docker/entrypoint.sh guards both behind `[[ ! -f ... ]]`). Any box that
# already has devices configured — which is the common case, since this
# service is added on top of an existing Asterisk install — never
# regenerates either file on a plain `docker compose restart`, so the
# #include lines patched into the generator never actually reach the live
# files. Confirmed by a real failure: an outbound call got "extension not
# found in context 'intercom'" because pstn-trunk-dialplan.conf was never
# actually #include'd, despite the generator patch having succeeded.
# This directly patches the LIVE files too (idempotent, same anchors), so
# it takes effect immediately regardless of whether Easy Asterisk ever
# regenerates them on its own.
_pstn_ensure_live_includes() {
    local ASTERISK_DIR="$1" CONTAINER_NAME="$2"
    local PJSIP_LIVE="$ASTERISK_DIR/pjsip.conf"
    local EXT_LIVE="$ASTERISK_DIR/extensions.conf"

    if [[ -f "$PJSIP_LIVE" ]] && ! grep -q 'pstn-trunk-pjsip.conf' "$PJSIP_LIVE"; then
        if grep -q '^user_agent=EasyAsterisk$' "$PJSIP_LIVE"; then
            sed -i '/^user_agent=EasyAsterisk$/a #include pstn-trunk-pjsip.conf' "$PJSIP_LIVE"
            log_success "Patched the trunk's #include directly into the live pjsip.conf."
        else
            log_warning "Couldn't find 'user_agent=EasyAsterisk' in the live pjsip.conf — add"
            log_warning "'#include pstn-trunk-pjsip.conf' manually after [global], then reload."
        fi
    fi

    if [[ -f "$EXT_LIVE" ]] && ! grep -q 'pstn-trunk-dialplan.conf' "$EXT_LIVE"; then
        if grep -q '^\[intercom\]$' "$EXT_LIVE"; then
            sed -i '/^\[intercom\]$/a #include pstn-trunk-dialplan.conf' "$EXT_LIVE"
            log_success "Patched the trunk's #include directly into the live extensions.conf."
        else
            log_warning "Couldn't find '[intercom]' in the live extensions.conf — add"
            log_warning "'#include pstn-trunk-dialplan.conf' manually, then reload."
        fi
    fi

    docker exec "$CONTAINER_NAME" asterisk -rx "module reload res_pjsip.so" &>/dev/null || true
    docker exec "$CONTAINER_NAME" asterisk -rx "dialplan reload" &>/dev/null || true
}

# ── Shared: pjsip trunk config (aor/identify/endpoint, IP-authenticated) ───
# SERVER_IPS is space-separated — one IP is the common case (one POP, one
# hostname resolution, e.g. VoIP.ms), but some providers (e.g. Anveo Direct)
# send inbound signaling from a fixed set of published IPs regardless of
# which hostname you dial out to. PJSIP's identify object allows repeating
# match= to build one match set against a single endpoint — no separate
# identify/endpoint objects needed per IP, unlike the older chan_sip
# peer-per-source-IP pattern some providers' sample configs still show.
_pstn_write_pjsip_include() {
    local FILE="$1" SERVER="$2" SERVER_IPS="$3" DID="$4"
    cat > "$FILE" << 'EOF'
; SIP PSTN trunk — IP authentication, no password stored (see
; docs/pstn-calling-voipms-plan.md). Regenerated by services/pstn-trunk.sh —
; edit there, not here directly, or a reinstall/update will overwrite this.
;
; match= lines below are the known/resolved source IP(s) for inbound calls.
; If inbound calls stop matching after a provider-side change, re-run this
; service to re-resolve/re-enter them, or add extra match= lines here by
; hand for additional known source IPs.

[pstn-trunk]
type=aor
contact=sip:__PSTN_SERVER__
qualify_frequency=60

[pstn-trunk]
type=identify
endpoint=pstn-trunk
EOF
    local _ip
    for _ip in $SERVER_IPS; do
        echo "match=${_ip}" >> "$FILE"
    done
    cat >> "$FILE" << 'EOF'

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
    sed -i "s/__PSTN_SERVER__/${SERVER}/g; s/__PSTN_DID__/${DID}/g" "$FILE"
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
 same => n,GotoIf($["${PSTN_M_TIER}" = "restricted" & ${REGEX("^(${PSTN_M_ALLOWED})$" ${PSTN_CALLERID_NORM})}=1]?ring__EXT__)
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
    # Dedupe: a repeated extension (typo, copy-paste, or a settings file
    # edited by hand) would otherwise generate two identical ring<ext>/
    # skip<ext> priority labels in the same [from-pstn-trunk] extension.
    # Confirmed live: Asterisk doesn't error on the duplicate labels, it
    # silently resolves Goto() to the wrong one and loops between the two
    # blocks forever — the call never reaches the actual Dial(), and no
    # ring/notification ever happens, with no error anywhere to point at it.
    RING_EXTS="$(echo "$RING_EXTS" | xargs -n1 | awk '!seen[$0]++' | xargs)"
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
;
; NANP is NOT the same thing as "US" — it also covers Caribbean/Atlantic
; nations and several US territories, all of which dial exactly like a
; normal 10-digit US number but get billed by most providers at
; international/premium rates (a well-known toll-fraud/"one-ring scam"
; vector precisely because the number format looks domestic). Blocked by
; area code below, checked before tier permission — this is a hard "never
; reachable" rule, not something even a "full" tier extension can override,
; since "full" means "any US number," not "any NANP-shaped number."

exten => _1NXXNXXXXXX,1,NoOp(PSTN outbound call attempt from ${CHANNEL} to ${EXTEN})
 same => n,Set(PSTN_DIALED=${EXTEN})
 same => n,Set(PSTN_KILLED=${AST_CONFIG(pstn-trunk-killswitch.conf,state,tripped)})
 same => n,GotoIf($["${PSTN_KILLED}" = "1"]?pstn_killed,1)
 same => n,Set(PSTN_AREA_CODE=${EXTEN:1:3})
 same => n,GotoIf($[${REGEX("^(242|246|264|268|284|340|345|441|473|649|658|664|670|671|684|721|758|767|784|787|809|829|849|868|869|876|939)$" ${PSTN_AREA_CODE})} = 1]?pstn_intl_blocked,1)
 same => n,Set(PSTN_CALLER=${CUT(CHANNEL,/,2)})
 same => n,Set(PSTN_CALLER=${CUT(PSTN_CALLER,-,1)})
 same => n,Set(PSTN_TIER=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},tier)})
 same => n,GotoIf($["${PSTN_TIER}" = "full"]?pstn_check_busy,1)
 same => n,GotoIf($["${PSTN_TIER}" = "restricted"]?pstn_check_allow_out,1)
 same => n,NoOp(Denied - ${PSTN_CALLER} has no PSTN permission, tier: ${PSTN_TIER})
__ALERT_DENY_TIER_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => _NXXNXXXXXX,1,NoOp(Assuming NANP - adding leading 1)
 same => n,Goto(1${EXTEN},1)

exten => pstn_intl_blocked,1,NoOp(PSTN outbound call to ${PSTN_DIALED} blocked - non-US/premium NANP area code ${PSTN_AREA_CODE})
__ALERT_DENY_INTL_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => pstn_killed,1,NoOp(PSTN trunk - spend-cap kill-switch is tripped, rejecting outbound call)
__ALERT_KILLED_LINE__
 same => n,Busy(15)
 same => n,Hangup()

; International (non-NANP) dialing — US "011" prefix convention. Gated on
; BOTH full tier (same as domestic) AND the live international allow-list
; (pstn-intl-allowed.conf), managed ONLY via the CLI installer, never the
; Security Dashboard web UI — see _pstn_run_international_step. The
; allow-list holds admin-entered country calling codes (the PATTERN side of
; the REGEX() below); the caller-dialed digits are always the STRING being
; tested, never the reverse, same safe direction as every other permission
; check in this file. Reuses pstn_check_busy for the actual dial once a
; country check passes — same concurrency cap and call-log accounting as
; domestic calls. pstn-trunk-usage-alert.sh's cost estimate buckets logged
; calls into domestic vs. per-country international (by the dialed digits
; after "011", longest-code-first match) and applies each country's own
; admin-entered rate (pstn-intl-allowed.conf's allowed_rates), not the flat
; domestic RATE — still an estimate (rates you entered, not fetched live),
; but no longer blended across two very different rate scales.
exten => _011X.,1,NoOp(PSTN international outbound call attempt from ${CHANNEL} to ${EXTEN})
 same => n,Set(PSTN_DIALED=${EXTEN})
 same => n,Set(PSTN_KILLED=${AST_CONFIG(pstn-trunk-killswitch.conf,state,tripped)})
 same => n,GotoIf($["${PSTN_KILLED}" = "1"]?pstn_killed,1)
 same => n,Set(PSTN_CALLER=${CUT(CHANNEL,/,2)})
 same => n,Set(PSTN_CALLER=${CUT(PSTN_CALLER,-,1)})
 same => n,Set(PSTN_TIER=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},tier)})
 same => n,GotoIf($["${PSTN_TIER}" = "full"]?pstn_intl_check_country,1)
 same => n,NoOp(Denied intl - ${PSTN_CALLER} tier ${PSTN_TIER} not eligible for international calling)
__ALERT_DENY_INTL_TIER_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => pstn_intl_check_country,1,Set(PSTN_INTL_ALLOWED=${AST_CONFIG(pstn-intl-allowed.conf,countries,allowed_codes)})
 same => n,Set(PSTN_INTL_DIGITS=${PSTN_DIALED:3})
 same => n,GotoIf($["${PSTN_INTL_ALLOWED}" = ""]?pstn_intl_country_denied,1)
 same => n,GotoIf($[${REGEX("^(${PSTN_INTL_ALLOWED})" ${PSTN_INTL_DIGITS})} = 1]?pstn_check_busy,1)
 same => n,Goto(pstn_intl_country_denied,1)

exten => pstn_intl_country_denied,1,NoOp(Denied intl - ${PSTN_DIALED} not on the current international allow-list)
__ALERT_DENY_INTL_COUNTRY_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => pstn_check_allow_out,1,Set(PSTN_ALLOWED=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},allowed_numbers)})
 same => n,GotoIf($[${REGEX("^(${PSTN_ALLOWED})$" ${PSTN_DIALED})} = 1]?pstn_check_busy,1)
 same => n,NoOp(Denied - ${PSTN_DIALED} not on ${PSTN_CALLER}'s approved number list)
__ALERT_DENY_NUMBER_LINE__
 same => n,Busy(15)
 same => n,Hangup()

exten => pstn_check_busy,1,Set(PSTN_MAX_OUT=${AST_CONFIG(pstn-limits.conf,limits,max_outbound)})
 same => n,Set(PSTN_MAX_OUT=${IF($["${PSTN_MAX_OUT}" = ""]?10:${PSTN_MAX_OUT})})
 same => n,GotoIf($[${GROUP_COUNT(pstn-out)} >= ${PSTN_MAX_OUT}]?pstn_busy,1)
 same => n,Set(GROUP()=pstn-out)
 same => n,Set(PSTN_PERSONAL_CID=${AST_CONFIG(pstn-permissions.conf,${PSTN_CALLER},personal_did)})
 same => n,Set(CALLERID(num)=${IF($["${PSTN_PERSONAL_CID}" = ""]?__PSTN_DID__:${PSTN_PERSONAL_CID})})
 same => n,Set(PSTN_START=${EPOCH})
 same => n,Dial(PJSIP/${PSTN_DIALED}@pstn-trunk,60)
 same => n,Set(PSTN_DUR=$[${EPOCH} - ${PSTN_START}])
 same => n,System(printf '%s|out|%s|%s|%s\n' "${PSTN_START}" "${PSTN_CALLER}" "${PSTN_DIALED}" "${PSTN_DUR}" >> /var/log/asterisk/pstn-trunk-calls.log)
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
        sed -i "s#__ALERT_DENY_INTL_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound call blocked - non-US/premium NANP area code.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_DENY_NUMBER_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound call denied - number not pre-approved.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_BUSY_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: outbound concurrent-call cap reached - a call was rejected.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_KILLED_LINE__# same => n,System(curl -m 5 -s -H 'Priority: urgent' -d 'PSTN trunk: outbound call rejected - spend-cap kill-switch is tripped.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_DENY_INTL_TIER_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: international call denied - extension is not full-tier.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_DENY_INTL_COUNTRY_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: international call denied - country not on the current allow-list.' '${_esc_url}' >/dev/null 2>\\&1 \\&)#" "$FILE"
    else
        sed -i "/__ALERT_DENY_TIER_LINE__/d; /__ALERT_DENY_INTL_LINE__/d; /__ALERT_DENY_NUMBER_LINE__/d; /__ALERT_BUSY_LINE__/d; /__ALERT_KILLED_LINE__/d; /__ALERT_DENY_INTL_TIER_LINE__/d; /__ALERT_DENY_INTL_COUNTRY_LINE__/d" "$FILE"
    fi

    # ── Inbound: [from-pstn-trunk], one unrolled block per ring-group member.
    # Permission check (is anyone in the ring group authorized for this
    # caller) happens before the concurrency check, mirroring outbound's
    # own ordering (permission gate, then busy gate).
    #
    # PSTN_CALLERID_NORM below mirrors what outbound's _NXXNXXXXXX pattern
    # already does (Goto 1${EXTEN} to add a leading "1" before any tier/
    # allowed_numbers check) but for the inbound direction: allowed_numbers
    # is always stored 11-digit (dashboard's NUMBER_RE requires exactly 11
    # digits), but a provider's inbound Caller-ID isn't guaranteed to include
    # the leading "1" — confirmed live: Anveo delivered a bare 10-digit
    # CALLERID(num), so every restricted-tier check against it failed on
    # a plain digit-count mismatch (11-digit pattern vs. 10-digit string),
    # regardless of whether the number itself was genuinely on the list.
    # Every restricted-tier comparison below (ring-group members, personal-
    # DID owner, group-owned personal DID) uses this normalized value
    # instead of raw ${CALLERID(num)}.
    cat >> "$FILE" << 'EOF'

[from-pstn-trunk]
exten => _X.,1,NoOp(Inbound PSTN call from ${CALLERID(num)} to ${EXTEN})
 same => n,Set(PSTN_DID_CALLED=${EXTEN})
 same => n,Set(PSTN_KILLED=${AST_CONFIG(pstn-trunk-killswitch.conf,state,tripped)})
 same => n,GotoIf($["${PSTN_KILLED}" = "1"]?pstn_in_killed,1)
 same => n,Set(PSTN_DID_10=${IF($[${LEN(${EXTEN})} = 11]?${EXTEN:1}:${EXTEN})})
 same => n,Set(PSTN_CALLERID_NORM=${IF($[${LEN(${CALLERID(num)})} = 10]?1${CALLERID(num)}:${CALLERID(num)})})
 same => n,Set(PSTN_PERSONAL_OWNER=${AST_CONFIG(pstn-personal-dids.conf,${PSTN_DID_10},owner)})
 same => n,GotoIf($["${PSTN_PERSONAL_OWNER}" != ""]?pstn_personal_inbound,1)
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

exten => pstn_in_killed,1,NoOp(PSTN trunk - spend-cap kill-switch is tripped, rejecting inbound call)
__ALERT_KILLED_IN_LINE__
 same => n,Hangup()

; Personal DID inbound routing — rings the assigned owner, gated by the
; owner's own tier/approved-numbers (same check every ring-group member
; gets, just for a single specific target instead of a list, and with no
; fallback to the shared ring-group if the owner can't take this call —
; it's their own number, not the shared line). The owner may also be a
; GROUP, written "@GroupName" by the Security Dashboard (the '@' keeps it
; unambiguous against a same-named numeric extension) — routed to a
; separate branch below since a group needs the SAME per-member check as
; every individual owner does, but for a variable number of members. That
; can't be unrolled at install time the way the shared ring-group above
; is (RING_EXTS is fixed then; a group's membership can change any time
; via the dashboard with no reinstall) — so it's computed fresh on every
; call by pstn-personal-group-ring.sh instead, which reads the same two
; live config files and applies the identical tier/allowed_numbers logic
; in a plain shell loop. UNVERIFIED: SHELL() invoking that script hasn't
; been confirmed against a live call yet — test a group-assigned personal
; number before relying on it.
exten => pstn_personal_inbound,1,GotoIf($["${PSTN_PERSONAL_OWNER:0:1}" = "@"]?pstn_personal_group_ring,1)
 same => n,Set(PSTN_OWNER_TIER=${AST_CONFIG(pstn-permissions.conf,${PSTN_PERSONAL_OWNER},tier)})
 same => n,GotoIf($["${PSTN_OWNER_TIER}" = "full"]?pstn_personal_ring,1)
 same => n,Set(PSTN_OWNER_ALLOWED=${AST_CONFIG(pstn-permissions.conf,${PSTN_PERSONAL_OWNER},allowed_numbers)})
 same => n,GotoIf($["${PSTN_OWNER_TIER}" = "restricted" & ${REGEX("^(${PSTN_OWNER_ALLOWED})$" ${PSTN_CALLERID_NORM})}=1]?pstn_personal_ring,1)
 same => n,NoOp(Denied - personal DID ${PSTN_DID_CALLED}'s owner ${PSTN_PERSONAL_OWNER} not authorized for this caller)
__ALERT_DENY_PERSONAL_LINE__
 same => n,Hangup()

exten => pstn_personal_group_ring,1,Set(PSTN_GROUP_NAME=${CUT(PSTN_PERSONAL_OWNER,@,2)})
 same => n,Set(PSTN_RING_LIST=${SHELL(/etc/asterisk/pstn-personal-group-ring.sh "${PSTN_CALLERID_NORM}" "${PSTN_GROUP_NAME}")})
 same => n,GotoIf($["${PSTN_RING_LIST}" = ""]?pstn_personal_denied_group,1)
 same => n,Set(PSTN_MAX_IN=${AST_CONFIG(pstn-limits.conf,limits,max_inbound)})
 same => n,Set(PSTN_MAX_IN=${IF($["${PSTN_MAX_IN}" = ""]?10:${PSTN_MAX_IN})})
 same => n,GotoIf($[${GROUP_COUNT(pstn-in)} >= ${PSTN_MAX_IN}]?pstn_in_busy,1)
 same => n,Set(GROUP()=pstn-in)
 same => n,Set(PSTN_START=${EPOCH})
 same => n,Dial(${PSTN_RING_LIST},20)
 same => n,Set(PSTN_DUR=$[${EPOCH} - ${PSTN_START}])
 same => n,System(printf '%s|in|%s|%s|%s\n' "${PSTN_START}" "${CALLERID(num)}" "${PSTN_DID_CALLED}" "${PSTN_DUR}" >> /var/log/asterisk/pstn-trunk-calls.log)
 same => n,Hangup()

exten => pstn_personal_denied_group,1,NoOp(Denied - personal DID ${PSTN_DID_CALLED}'s group ${PSTN_GROUP_NAME} has no member authorized for this caller)
__ALERT_DENY_PERSONAL_LINE__
 same => n,Hangup()

exten => pstn_personal_ring,1,Set(PSTN_MAX_IN=${AST_CONFIG(pstn-limits.conf,limits,max_inbound)})
 same => n,Set(PSTN_MAX_IN=${IF($["${PSTN_MAX_IN}" = ""]?10:${PSTN_MAX_IN})})
 same => n,GotoIf($[${GROUP_COUNT(pstn-in)} >= ${PSTN_MAX_IN}]?pstn_in_busy,1)
 same => n,Set(GROUP()=pstn-in)
 same => n,Set(PSTN_START=${EPOCH})
 same => n,Dial(PJSIP/${PSTN_PERSONAL_OWNER},20)
 same => n,Set(PSTN_DUR=$[${EPOCH} - ${PSTN_START}])
 same => n,System(printf '%s|in|%s|%s|%s\n' "${PSTN_START}" "${CALLERID(num)}" "${PSTN_DID_CALLED}" "${PSTN_DUR}" >> /var/log/asterisk/pstn-trunk-calls.log)
 same => n,Hangup()
EOF

    if [[ -n "$NTFY_URL" ]]; then
        local _esc_url2="${NTFY_URL//&/\\&}"
        sed -i "s#__ALERT_DENY_INBOUND_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: inbound call rejected - caller not approved for any ring target.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_BUSY_IN_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: inbound concurrent-call cap reached - a call was rejected.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_KILLED_IN_LINE__# same => n,System(curl -m 5 -s -H 'Priority: urgent' -d 'PSTN trunk: inbound call rejected - spend-cap kill-switch is tripped.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
        sed -i "s#__ALERT_DENY_PERSONAL_LINE__# same => n,System(curl -m 5 -s -d 'PSTN trunk: inbound call to a personal DID rejected - owner not authorized for this caller.' '${_esc_url2}' >/dev/null 2>\\&1 \\&)#" "$FILE"
    else
        sed -i "/__ALERT_DENY_INBOUND_LINE__/d; /__ALERT_BUSY_IN_LINE__/d; /__ALERT_KILLED_IN_LINE__/d; /__ALERT_DENY_PERSONAL_LINE__/d" "$FILE"
    fi
}

# ── Shared: per-member permission check for a group-owned personal DID ─────
# Invoked fresh on every inbound call via the dialplan's ${SHELL()} function
# (see pstn_personal_group_ring above) rather than unrolled at install time
# — a group's membership can change any time via the Security Dashboard,
# with no reinstall, unlike the shared ring-group's fixed RING_EXTS. Applies
# the IDENTICAL tier/allowed_numbers logic _pstn_ring_member_block bakes
# into the dialplan for the shared ring-group, just in plain shell against
# the same two live config files, so a member who's internal-tier (or
# restricted without this caller on their approved list) never rings here
# either — group ownership doesn't bypass the permission model, same as
# every other path into this trunk.
# Safe REGEX direction: $allowed is admin-entered (pstn-permissions.conf),
# $caller is the incoming Caller-ID — pattern is always the admin data,
# string is always the caller-controlled data, never the reverse.
_pstn_write_personal_group_ring_script() {
    local FILE="$1"
    cat > "$FILE" << 'SCRIPT'
#!/bin/bash
# Auto-generated by services/pstn-trunk.sh — rerun the installer to refresh,
# don't edit directly. Usage: pstn-personal-group-ring.sh <caller_num> <group_name>
# Prints a &-joined PJSIP dial string for every group member whose own
# tier/approved-numbers authorize this caller; empty output = nobody
# authorized (the dialplan treats that as "deny").
CALLER="$1"
GROUP="$2"
CONF_DIR="/etc/asterisk"

# allowed_numbers is always stored 11-digit (dashboard's NUMBER_RE requires
# it); the dialplan already passes a normalized caller ID in here
# (PSTN_CALLERID_NORM), but normalize again defensively — this script is
# also useful to invoke by hand for testing, and a bare 10-digit caller ID
# would otherwise never match any 11-digit allowed_numbers entry.
[[ ${#CALLER} -eq 10 ]] && CALLER="1${CALLER}"

_ini_get() {
    # _ini_get <file> <section> <key>
    # configparser.write() (used by every .conf writer in this project) pads
    # '=' with spaces by default, so keys/values must be trimmed before
    # comparing — a bare $1 == key here never matches and silently returns
    # empty for every lookup, including the group's own members= line.
    awk -F'=' -v want="[$2]" -v key="$3" '
        $0 == want { found=1; next }
        /^\[/ { found=0 }
        found {
            eq = index($0, "=")
            if (eq > 0) {
                k = substr($0, 1, eq-1)
                gsub(/^[ \t]+|[ \t]+$/, "", k)
                if (k == key) {
                    v = substr($0, eq+1)
                    gsub(/^[ \t]+|[ \t]+$/, "", v)
                    print v
                    exit
                }
            }
        }
    ' "$1" 2>/dev/null
}

[[ -z "$CALLER" || -z "$GROUP" ]] && exit 0

MEMBERS_RAW="$(_ini_get "$CONF_DIR/pstn-groups.conf" "$GROUP" "members")"
RING_LIST=""
IFS=',' read -ra MEMBERS <<< "$MEMBERS_RAW"
for _ext in "${MEMBERS[@]}"; do
    _ext="$(echo "$_ext" | xargs)"
    [[ -z "$_ext" ]] && continue
    _tier="$(_ini_get "$CONF_DIR/pstn-permissions.conf" "$_ext" "tier")"
    if [[ "$_tier" == "full" ]]; then
        RING_LIST="${RING_LIST}${RING_LIST:+&}PJSIP/${_ext}"
    elif [[ "$_tier" == "restricted" ]]; then
        _allowed="$(_ini_get "$CONF_DIR/pstn-permissions.conf" "$_ext" "allowed_numbers")"
        if [[ -n "$_allowed" ]] && [[ "$CALLER" =~ ^(${_allowed})$ ]]; then
            RING_LIST="${RING_LIST}${RING_LIST:+&}PJSIP/${_ext}"
        fi
    fi
done
printf '%s' "$RING_LIST"
SCRIPT
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
# Args: FILE, space-separated FULL_EXTS, space-separated MESSAGING_EXTS,
# space-separated "ext=did" PERSONAL_DID_ASSIGNMENTS, then "ext"
# "pipe|separated|numbers" pairs for each restricted extension.
_pstn_write_permissions_file() {
    local FILE="$1" FULL_EXTS="$2" MESSAGING_EXTS="$3" PERSONAL_DID_ASSIGNMENTS="$4"
    shift 4
    local -A _personal_did_map=()
    local _pd_token
    for _pd_token in $PERSONAL_DID_ASSIGNMENTS; do
        _personal_did_map["${_pd_token%%=*}"]="${_pd_token#*=}"
    done
    local _written_exts=""
    {
        echo "; PSTN permission tiers — internal / restricted / full — PLUS two independent"
        echo "; axes per extension:"
        echo "; - 'messaging' for Asterisk's native internal SIP MESSAGE texting (no carrier"
        echo "; SMS, no PSTN, no cost — a separate axis from PSTN calling, since the risk"
        echo "; profile is different: an extension can be internal-tier for calling and"
        echo "; still messaging-enabled, or vice versa)."
        echo "; - 'personal_did' assigns this extension its own DID (see"
        echo "; pstn-personal-dids.conf, which the dialplan reads for inbound routing —"
        echo "; this key here is only the OUTBOUND Caller-ID override). A personal DID"
        echo "; only actually rings anyone if its owner is also full or restricted tier —"
        echo "; internal tier means no PSTN either way, personal DID or not."
        echo "; Read LIVE by the dialplan on every call (AST_CONFIG()) — no Asterisk"
        echo "; restart needed when this changes. Edit here directly, via the Security"
        echo "; Dashboard web UI's \"PSTN Trunk\" tab (if installed), or by re-running"
        echo "; 'sudo ./setup.sh pstn-trunk' and choosing a FRESH reinstall (\"update in"
        echo "; place\" leaves this file alone on purpose)."
        echo "; Any extension not listed here is internal-only (no PSTN) AND"
        echo "; messaging-disabled by default — it can still call/receive other Asterisk"
        echo "; extensions and join internal ring groups, just not the PSTN trunk or"
        echo "; internal texting."
        echo ""
        local _ext
        for _ext in $FULL_EXTS; do
            echo "[$_ext]"
            echo "tier=full"
            [[ " $MESSAGING_EXTS " == *" $_ext "* ]] && echo "messaging=yes"
            [[ -n "${_personal_did_map[$_ext]:-}" ]] && echo "personal_did=${_personal_did_map[$_ext]}"
            echo ""
            _written_exts="$_written_exts $_ext"
        done
        while [[ $# -gt 0 ]]; do
            _ext="$1"; local _nums="$2"
            shift 2
            echo "[$_ext]"
            echo "tier=restricted"
            echo "allowed_numbers=${_nums}"
            [[ " $MESSAGING_EXTS " == *" $_ext "* ]] && echo "messaging=yes"
            [[ -n "${_personal_did_map[$_ext]:-}" ]] && echo "personal_did=${_personal_did_map[$_ext]}"
            echo ""
            _written_exts="$_written_exts $_ext"
        done
        for _ext in $MESSAGING_EXTS; do
            if [[ " $_written_exts " != *" $_ext "* ]]; then
                echo "[$_ext]"
                echo "messaging=yes"
                [[ -n "${_personal_did_map[$_ext]:-}" ]] && echo "personal_did=${_personal_did_map[$_ext]}"
                echo ""
                _written_exts="$_written_exts $_ext"
            fi
        done
        for _ext in "${!_personal_did_map[@]}"; do
            if [[ " $_written_exts " != *" $_ext "* ]]; then
                echo "[$_ext]"
                echo "personal_did=${_personal_did_map[$_ext]}"
                echo ""
            fi
        done
    } > "$FILE"
    chmod 664 "$FILE"
}

# ── Shared: personal DID -> owner-extension mapping (fresh install / explicit
# reset only — same "update never touches it" protection as
# pstn-permissions.conf). Args: FILE, then "did" "owner" pairs.
_pstn_write_personal_dids_file() {
    local FILE="$1"
    shift
    {
        echo "; Personal DID -> owner-extension mapping. Read LIVE by the dialplan"
        echo "; (AST_CONFIG()) on every inbound call — no restart needed. An inbound call"
        echo "; to a DID listed here routes directly to its owner, checked against the"
        echo "; owner's OWN tier/approved-numbers in pstn-permissions.conf — no ring-group"
        echo "; fallback, since this is that extension's own number, not the shared line."
        echo "; The matching outbound Caller-ID override lives in pstn-permissions.conf"
        echo "; ('personal_did=' per extension) — kept in sync automatically whenever a"
        echo "; DID is assigned/removed via the CLI installer or the Security Dashboard's"
        echo "; PSTN Trunk tab, rather than hand-editing both files separately."
        echo "; The shared trunk DID keeps working as the main/ring-group line regardless"
        echo "; of anything assigned here."
        echo ""
        while [[ $# -gt 0 ]]; do
            local _did="$1" _owner="$2"
            shift 2
            echo "[$_did]"
            echo "owner=$_owner"
            echo ""
        done
    } > "$FILE"
    chmod 664 "$FILE"
}

# ── Shared: kill-switch state (fresh install / explicit reset only — same
# "update never touches it" protection as pstn-permissions.conf/
# pstn-limits.conf) ─────────────────────────────────────────────────────────
_pstn_write_killswitch_file() {
    local FILE="$1"
    {
        echo "; PSTN spend-cap kill-switch state. 'tripped=1' blocks ALL PSTN calling"
        echo "; (in and out — internal Asterisk-to-Asterisk calling is unaffected), read"
        echo "; LIVE by the dialplan (AST_CONFIG()) on every call attempt. Written"
        echo "; automatically by pstn-trunk-usage-alert.sh once estimated monthly spend"
        echo "; reaches the cap set during install/update — it does NOT reset on its own."
        echo "; To clear a trip: re-run 'sudo ./setup.sh pstn-trunk', choose update mode,"
        echo "; and answer yes when asked, or hand-edit this file back to tripped=0 (same"
        echo "; 'safe to edit by hand' convention as pstn-permissions.conf/pstn-limits.conf)."
        echo "; Deliberately NOT exposed on the Security Dashboard web UI — clearing a"
        echo "; kill-switch is a CLI-only action, consistent with the international-"
        echo "; calling toggle below, so a compromised/careless web session can't quietly"
        echo "; re-enable spend after a trip."
        echo ""
        echo "[state]"
        echo "tripped=0"
    } > "$FILE"
    chmod 664 "$FILE"
}

# ── Shared: international-calling allow-list (CLI-managed only — see
# _pstn_manage_international/_pstn_run_international_step below) ───────────
_pstn_write_intl_allowed_file() {
    local FILE="$1" CODES="$2" NAMES="$3" EXPIRES="$4" RATES="$5"
    {
        echo "; International-calling allow-list (country calling codes, beyond NANP/US),"
        echo "; each with its own admin-entered per-minute rate (allowed_rates, parallel to"
        echo "; allowed_codes/allowed_names — NOT fetched live from the provider; no"
        echo "; confirmed rates API exists for either supported provider as of this"
        echo "; writing, see docs/pstn-calling-voipms-plan.md). pstn-trunk-usage-alert.sh"
        echo "; uses these per-country rates instead of the single flat domestic RATE when"
        echo "; estimating spend for international minutes, since a blended rate badly"
        echo "; under/over-estimates international cost otherwise."
        echo "; Read LIVE by the dialplan (AST_CONFIG()) on every _011 international call —"
        echo "; no Asterisk restart needed. Managed ONLY from the CLI installer"
        echo "; ('sudo ./setup.sh pstn-trunk' -> 'Review/change allowed international-"
        echo "; calling countries now?'), deliberately NOT exposed on the Security"
        echo "; Dashboard web UI — this widens which countries can be dialed/billed to at"
        echo "; all, a more security-sensitive control than who's already allowed to use"
        echo "; an already-fixed scope. pstn-trunk-usage-alert.sh actively clears this"
        echo "; (re-blocking) once 'expires' has passed, and sends ntfy notices both the"
        echo "; day of and at the moment of expiry."
        echo ""
        echo "[countries]"
        echo "allowed_codes=${CODES}"
        echo "allowed_names=${NAMES}"
        echo "allowed_rates=${RATES}"
        echo "expires=${EXPIRES}"
    } > "$FILE"
    chmod 664 "$FILE"
}

_pstn_read_intl_current() {
    local FILE="$1"
    _PSTN_CUR_CODES=""
    _PSTN_CUR_NAMES=""
    _PSTN_CUR_RATES=""
    _PSTN_CUR_EXPIRES=""
    if [[ -f "$FILE" ]]; then
        _PSTN_CUR_CODES="$(grep '^allowed_codes=' "$FILE" | head -1 | cut -d= -f2-)"
        _PSTN_CUR_NAMES="$(grep '^allowed_names=' "$FILE" | head -1 | cut -d= -f2-)"
        _PSTN_CUR_RATES="$(grep '^allowed_rates=' "$FILE" | head -1 | cut -d= -f2-)"
        _PSTN_CUR_EXPIRES="$(grep '^expires=' "$FILE" | head -1 | cut -d= -f2-)"
    fi
}

_pstn_print_intl_allowed() {
    local FILE="$1"
    _pstn_read_intl_current "$FILE"
    echo ""
    if [[ -n "$_PSTN_CUR_CODES" ]]; then
        local -a _p_codes _p_names _p_rates
        IFS='|' read -ra _p_codes <<< "$_PSTN_CUR_CODES"
        IFS='|' read -ra _p_names <<< "$_PSTN_CUR_NAMES"
        IFS='|' read -ra _p_rates <<< "$_PSTN_CUR_RATES"
        log_info "International calling currently ALLOWED to:"
        local _pi
        for _pi in "${!_p_codes[@]}"; do
            log_info "  ${_p_names[$_pi]:-+${_p_codes[$_pi]}} — \$${_p_rates[$_pi]:-0}/min"
        done
        if [[ -n "$_PSTN_CUR_EXPIRES" ]]; then
            log_info "  Expires: $_PSTN_CUR_EXPIRES (auto-revoked and re-blocked after this date)."
        else
            log_info "  No expiry set — stays allowed until you change it here again."
        fi
    else
        log_info "International calling: no countries currently allowed (US/NANP only, per the tiers above)."
    fi
}

# Continent -> country menu. Only reachable from the CLI (never the web
# dashboard) and only ever invoked via _pstn_run_international_step, which
# always asks the y/n gate first and always prints the resulting allow-list
# exactly once afterward, regardless of the answer.
_pstn_manage_international() {
    local ASTERISK_DIR="$1"
    local FILE="$ASTERISK_DIR/pstn-intl-allowed.conf"
    mkdir -p "$ASTERISK_DIR"

    _pstn_read_intl_current "$FILE"

    # SELECTED[code] = "name|rate" — carries both through add/remove/list so
    # the per-country rate survives re-running this menu without re-asking
    # for it on every country that's already allowed.
    local -A SELECTED=()
    if [[ -n "$_PSTN_CUR_CODES" ]]; then
        local -a _cur_codes_arr _cur_names_arr _cur_rates_arr
        IFS='|' read -ra _cur_codes_arr <<< "$_PSTN_CUR_CODES"
        IFS='|' read -ra _cur_names_arr <<< "$_PSTN_CUR_NAMES"
        IFS='|' read -ra _cur_rates_arr <<< "$_PSTN_CUR_RATES"
        local _k
        for _k in "${!_cur_codes_arr[@]}"; do
            SELECTED["${_cur_codes_arr[$_k]}"]="${_cur_names_arr[$_k]}|${_cur_rates_arr[$_k]:-0}"
        done
    fi

    local -a NA=("Mexico|52" "Greenland|299")
    local -a SA=("Brazil|55" "Argentina|54" "Colombia|57" "Chile|56" "Peru|51" "Ecuador|593" "Venezuela|58")
    local -a EU=("United Kingdom|44" "Germany|49" "France|33" "Spain|34" "Italy|39" "Netherlands|31" "Ireland|353" "Portugal|351" "Poland|48" "Switzerland|41")
    local -a ASIA=("India|91" "China|86" "Japan|81" "South Korea|82" "Philippines|63" "Israel|972" "United Arab Emirates|971" "Thailand|66" "Vietnam|84")
    local -a AF=("Nigeria|234" "South Africa|27" "Egypt|20" "Kenya|254" "Morocco|212")
    local -a OC=("Australia|61" "New Zealand|64")

    echo ""
    echo "  Select countries to allow international (non-NANP) calling to/from —"
    echo "  nested by continent so the less-common calling codes stay out of the way"
    echo "  until you need them. Only 'full'-tier extensions can use this regardless"
    echo "  of which countries are allowed here."

    local DONE=""
    while [[ "$DONE" != "y" && "$DONE" != "Y" ]]; do
        echo ""
        echo "  Continents:"
        echo "    1) North America (non-NANP)   2) South America   3) Europe"
        echo "    4) Asia                       5) Africa           6) Oceania"
        echo "    0) Enter a country/code manually (not listed above)"
        local _cur_list="" _cc _cc_name
        for _cc in "${!SELECTED[@]}"; do
            _cc_name="${SELECTED[$_cc]%%|*}"
            _cur_list="${_cur_list}${_cur_list:+, }${_cc_name} (\$${SELECTED[$_cc]##*|}/min)"
        done
        echo "  Currently selected: ${_cur_list:-none}"
        local _choice=""
        prompt_text "  Continent number, 0, or 'd' when done:" "d" _choice
        local -a _countries=()
        local _cname=""
        case "$_choice" in
            d|D) DONE=y; continue ;;
            0)
                local _manual_name="" _manual_code="" _manual_rate=""
                prompt_text "    Country name (for your reference):" "" _manual_name
                prompt_text "    Country calling code (digits only, e.g. 44):" "" _manual_code
                if [[ "$_manual_code" =~ ^[0-9]{1,4}$ ]]; then
                    prompt_text "    Per-minute rate in USD for ${_manual_name:-this country} (used in the spend estimate, not fetched live):" "0.05" _manual_rate
                    [[ "$_manual_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _manual_rate="0.05"
                    SELECTED["$_manual_code"]="${_manual_name:-Unnamed} (+$_manual_code)|${_manual_rate}"
                    log_success "Added ${_manual_name:-Unnamed} (+$_manual_code) at \$${_manual_rate}/min."
                else
                    log_warning "Not a valid calling code — skipped."
                fi
                continue
                ;;
            1) _countries=("${NA[@]}"); _cname="North America" ;;
            2) _countries=("${SA[@]}"); _cname="South America" ;;
            3) _countries=("${EU[@]}"); _cname="Europe" ;;
            4) _countries=("${ASIA[@]}"); _cname="Asia" ;;
            5) _countries=("${AF[@]}"); _cname="Africa" ;;
            6) _countries=("${OC[@]}"); _cname="Oceania" ;;
            *) log_warning "Invalid choice."; continue ;;
        esac

        local _sub_done=""
        while [[ "$_sub_done" != "y" && "$_sub_done" != "Y" ]]; do
            echo ""
            echo "  $_cname:"
            local _j _entry _name _code _mark _rate_suffix
            for _j in "${!_countries[@]}"; do
                _entry="${_countries[$_j]}"
                _name="${_entry%%|*}"; _code="${_entry##*|}"
                _mark=" "
                _rate_suffix=""
                if [[ -n "${SELECTED[$_code]+x}" ]]; then
                    _mark="x"
                    _rate_suffix=" — \$${SELECTED[$_code]##*|}/min"
                fi
                echo "    $((_j+1))) [$_mark] $_name (+$_code)${_rate_suffix}"
            done
            local _pick=""
            prompt_text "    Toggle a number, or 'b' for back:" "b" _pick
            if [[ "$_pick" == "b" || "$_pick" == "B" ]]; then
                _sub_done=y
            elif [[ "$_pick" =~ ^[0-9]+$ ]] && (( _pick >= 1 && _pick <= ${#_countries[@]} )); then
                _entry="${_countries[$((_pick-1))]}"
                _name="${_entry%%|*}"; _code="${_entry##*|}"
                if [[ -n "${SELECTED[$_code]+x}" ]]; then
                    unset 'SELECTED[$_code]'
                    log_info "Removed $_name."
                else
                    local _new_rate=""
                    prompt_text "    Per-minute rate in USD for $_name (used in the spend estimate, not fetched live):" "0.05" _new_rate
                    [[ "$_new_rate" =~ ^[0-9]+(\.[0-9]+)?$ ]] || _new_rate="0.05"
                    SELECTED["$_code"]="$_name (+$_code)|${_new_rate}"
                    log_info "Added $_name at \$${_new_rate}/min."
                fi
            else
                log_warning "Invalid choice."
            fi
        done
    done

    local NEW_CODES="" NEW_NAMES="" NEW_RATES="" _sep="" _code
    for _code in "${!SELECTED[@]}"; do
        NEW_CODES="${NEW_CODES}${_sep}${_code}"
        NEW_NAMES="${NEW_NAMES}${_sep}${SELECTED[$_code]%%|*}"
        NEW_RATES="${NEW_RATES}${_sep}${SELECTED[$_code]##*|}"
        _sep="|"
    done

    local NEW_EXPIRES=""
    if [[ -n "$NEW_CODES" ]]; then
        local WANT_EXPIRY=""
        prompt_yn "  Auto-expire this international access? (y/n):" "y" WANT_EXPIRY
        if [[ "$WANT_EXPIRY" =~ ^[Yy]$ ]]; then
            local _days=""
            prompt_text "    Expire after how many days:" "30" _days
            [[ "$_days" =~ ^[0-9]+$ ]] || _days=30
            NEW_EXPIRES="$(date -d "+${_days} days" +%Y-%m-%d)"
            log_info "  Will auto-expire on $NEW_EXPIRES — you'll get an ntfy notice that day and again when it actually revokes."
        fi
    fi

    _pstn_write_intl_allowed_file "$FILE" "$NEW_CODES" "$NEW_NAMES" "$NEW_EXPIRES" "$NEW_RATES"
    chmod 664 "$FILE"
}

# Always asked, never skippable ("no bypassing the option" per design) —
# both on fresh install AND on "update in place", unlike every other
# structural prompt. Prints the resulting allow-list exactly once,
# immediately after, regardless of the y/n answer — NOT repeated later
# during the spend-cap prompts.
_pstn_run_international_step() {
    local ASTERISK_DIR="$1"
    local FILE="$ASTERISK_DIR/pstn-intl-allowed.conf"
    echo ""
    log_info "International calling (beyond NANP/US) is OFF by default and can ONLY be"
    log_info "managed from here (this CLI) — never from the Security Dashboard web UI."
    log_info "It's a more security-sensitive control (widens which countries can be"
    log_info "dialed/billed to at all) than anything already exposed there (which only"
    log_info "governs who can use a scope that's already fixed)."
    local WANT_INTL_CHANGE=""
    prompt_yn "Review/change allowed international-calling countries now? (y/n):" "n" WANT_INTL_CHANGE
    if [[ "$WANT_INTL_CHANGE" =~ ^[Yy]$ ]]; then
        _pstn_manage_international "$ASTERISK_DIR"
    fi
    _pstn_print_intl_allowed "$FILE"
}

# Update-mode-only: pstn-trunk-killswitch.conf is never touched by "update"
# (same protection as pstn-permissions.conf/pstn-limits.conf), so a trip
# persists across settings updates on purpose — this is the CLI-only path to
# clear it back out again once you've confirmed the overage was expected/
# resolved.
_pstn_check_killswitch_clear() {
    local ASTERISK_DIR="$1"
    local FILE="$ASTERISK_DIR/pstn-trunk-killswitch.conf"
    [[ -f "$FILE" ]] || return 0
    if grep -q '^tripped=1' "$FILE" 2>/dev/null; then
        echo ""
        log_warning "The spend-cap kill-switch is currently TRIPPED — ALL PSTN calling (in and"
        log_warning "out) is blocked. It does not reset automatically."
        local CLEAR=""
        prompt_yn "Clear it now and resume PSTN calling? (y/n):" "n" CLEAR
        if [[ "$CLEAR" =~ ^[Yy]$ ]]; then
            sed -i 's/^tripped=.*/tripped=0/' "$FILE"
            log_success "Kill-switch cleared — PSTN calling resumes immediately (live, no restart needed)."
        else
            log_info "Leaving the kill-switch tripped."
        fi
    fi
}

# ── Shared: periodic spend/volume/kill-switch/international-expiry checker
# (run every minute via systemd timer, cron.d fallback — see
# _pstn_install_periodic_timer above) ───────────────────────────────────────
_pstn_write_usage_alert_script() {
    local FILE="$1" EA_DIR="$2" ASTERISK_DIR="$3" RATE="$4" MONTH_THRESHOLD="$5" \
          BURST_THRESHOLD="$6" MAX_MONTHLY_SPEND="$7" NTFY_URL="$8" CONTAINER_NAME="${9:-easy-asterisk}"
    cat > "$FILE" << 'EOF'
#!/bin/bash
# Auto-generated by services/pstn-trunk.sh — do not edit directly, re-run
# the installer instead. Run every minute via a systemd timer
# (pstn-trunk-usage.timer; cron.d fallback if systemd isn't available — see
# _pstn_install_periodic_timer). Reads the call log pstn-trunk-dialplan.conf
# appends to and:
#   - alerts via ntfy when month-to-date estimated spend crosses
#     MONTH_THRESHOLD (once per month), or call volume in the last hour
#     looks like a burst;
#   - estimates outbound spend as DOMESTIC minutes x RATE, PLUS each
#     international destination's own minutes x its own admin-entered rate
#     (pstn-intl-allowed.conf's allowed_rates) — a single blended rate badly
#     under/over-estimates international cost, which is usually far from
#     the domestic rate. Still an estimate (rates you entered, not fetched
#     live from the provider — no confirmed rates API exists for either
#     supported provider as of this writing).
#   - trips the spend-cap kill-switch (pstn-trunk-killswitch.conf) once
#     estimated spend reaches MAX_MONTHLY_SPEND — read LIVE by the dialplan
#     on every call, blocking ALL PSTN calling (in and out) until manually
#     cleared (does NOT reset automatically — see CLAUDE.md/README for how);
#   - sends a loud (priority=urgent) ntfy warning once spend reaches 80% of
#     that cap, distinct from and in addition to the trip alert itself;
#   - while tripped, actively hangs up any PSTN calls already in progress
#     (docker exec + Asterisk's "channel request hangup") instead of only
#     blocking new ones — otherwise a call already connected when the cap
#     is crossed just keeps running (and costing) until whoever's on it
#     hangs up naturally, since the dialplan only gates the START of a call;
#   - actively re-blocks (clears) the international-calling allow-list once
#     its expiry date has passed, with ntfy notices both the day of and at
#     the moment it actually revokes.
# These are estimates (call count/duration x entered rates), not real
# billing data, and only as fresh as the last run of this script (every
# minute) — a safety net, not a substitute for the provider's own billing.

LOG_FILE="__EA_DIR__/logs/pstn-trunk-calls.log"
STATE_FILE="__EA_DIR__/.pstn-trunk-alert-state"
WARN_STATE_FILE="__EA_DIR__/.pstn-trunk-warn-state"
INTL_STATE_FILE="__EA_DIR__/.pstn-trunk-intl-state"
KILLSWITCH_FILE="__ASTERISK_DIR__/pstn-trunk-killswitch.conf"
INTL_FILE="__ASTERISK_DIR__/pstn-intl-allowed.conf"
RATE="__PSTN_RATE__"
MONTH_THRESHOLD="__PSTN_MONTH_THRESHOLD__"
BURST_THRESHOLD="__PSTN_BURST_THRESHOLD__"
MAX_MONTHLY_SPEND="__PSTN_MAX_MONTHLY_SPEND__"
NTFY_URL="__PSTN_NTFY_URL__"
CONTAINER_NAME="__PSTN_CONTAINER_NAME__"

send_ntfy() {
    [[ -n "$NTFY_URL" ]] && curl -m 5 -s -d "$1" "$NTFY_URL" >/dev/null 2>&1
}
send_ntfy_loud() {
    [[ -n "$NTFY_URL" ]] && curl -m 5 -s -H "Priority: urgent" -H "Title: PSTN trunk alert" -d "$1" "$NTFY_URL" >/dev/null 2>&1
}

# Hangs up every currently-active channel on the pstn-trunk PJSIP endpoint —
# used only once the kill-switch is tripped, as a backstop against a call
# that was already in progress when the cap was crossed. "core show channels
# concise" is Asterisk's long-documented machine-parsable channel listing
# (bang-delimited, channel name always first field); hanging up the
# trunk-side leg of a bridged call tears down both legs.
_pstn_hangup_active_trunk_calls() {
    docker exec "$CONTAINER_NAME" asterisk -rx "core show channels concise" 2>/dev/null \
        | awk -F'!' '$1 ~ /^PJSIP\/pstn-trunk-/ {print $1}' \
        | while read -r ch; do
            [[ -n "$ch" ]] && docker exec "$CONTAINER_NAME" asterisk -rx "channel request hangup ${ch}" >/dev/null 2>&1
        done
}

current_month=$(date +%Y-%m)

# ── International allow-list: read once, used both for cost bucketing
# below and for the expiry check further down ─────────────────────────────
intl_codes=""
intl_rates_raw=""
if [[ -f "$INTL_FILE" ]]; then
    intl_codes=$(grep '^allowed_codes=' "$INTL_FILE" | head -1 | cut -d= -f2-)
    intl_rates_raw=$(grep '^allowed_rates=' "$INTL_FILE" | head -1 | cut -d= -f2-)
fi
declare -A INTL_RATE_MAP=()
INTL_CODES_SORTED=""
if [[ -n "$intl_codes" ]]; then
    IFS='|' read -ra _codes_arr <<< "$intl_codes"
    IFS='|' read -ra _rates_arr <<< "$intl_rates_raw"
    for _i in "${!_codes_arr[@]}"; do
        INTL_RATE_MAP["${_codes_arr[$_i]}"]="${_rates_arr[$_i]:-0}"
    done
    # Longest code first, so e.g. a 4-digit code is tried before a 2-digit
    # code that happens to be its prefix.
    INTL_CODES_SORTED=$(printf '%s\n' "${_codes_arr[@]}" | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- | xargs)
fi

month_cost="0.00"
hour_calls=0

if [[ -f "$LOG_FILE" ]]; then
    now_epoch=$(date +%s)
    one_hour_ago=$((now_epoch - 3600))
    month_start_epoch=$(date -d "$(date +%Y-%m-01)" +%s)

    # ── Bucket this month's outbound seconds: domestic vs. per-country
    # international, by longest-prefix match on the dialed digits (after the
    # "011" prefix). Domestic entries never start with "011" (NANP dialing
    # is always "1" + 10 digits), so the two are unambiguous. An
    # international call whose destination code isn't (or is no longer) on
    # the allow-list is excluded from the cost estimate entirely — a known
    # undercount if the allow-list changed after the call was placed, since
    # there's no other rate to charge it at.
    domestic_seconds=0
    declare -A INTL_SECONDS=()
    while IFS='|' read -r ep dir who what secs; do
        [[ "$dir" != "out" ]] && continue
        (( ep < month_start_epoch )) && continue
        if [[ "$what" == 011* ]]; then
            digits="${what:3}"
            matched=""
            for code in $INTL_CODES_SORTED; do
                if [[ "$digits" == "$code"* ]]; then
                    matched="$code"
                    break
                fi
            done
            [[ -n "$matched" ]] && INTL_SECONDS["$matched"]=$(( ${INTL_SECONDS["$matched"]:-0} + secs ))
        else
            domestic_seconds=$(( domestic_seconds + secs ))
        fi
    done < "$LOG_FILE"

    domestic_minutes=$(awk -v s="$domestic_seconds" 'BEGIN{printf "%.2f", s/60}')
    domestic_cost=$(awk -v m="$domestic_minutes" -v r="$RATE" 'BEGIN{printf "%.2f", m*r}')

    intl_cost="0.00"
    intl_total_seconds=0
    for code in "${!INTL_SECONDS[@]}"; do
        secs="${INTL_SECONDS[$code]}"
        intl_total_seconds=$(( intl_total_seconds + secs ))
        rate="${INTL_RATE_MAP[$code]:-0}"
        mins=$(awk -v s="$secs" 'BEGIN{printf "%.2f", s/60}')
        c=$(awk -v m="$mins" -v r="$rate" 'BEGIN{printf "%.2f", m*r}')
        intl_cost=$(awk -v a="$intl_cost" -v b="$c" 'BEGIN{printf "%.2f", a+b}')
    done

    month_cost=$(awk -v a="$domestic_cost" -v b="$intl_cost" 'BEGIN{printf "%.2f", a+b}')
    month_minutes=$(awk -v d="$domestic_seconds" -v i="$intl_total_seconds" 'BEGIN{printf "%.1f", (d+i)/60}')
    hour_calls=$(awk -F'|' -v start="$one_hour_ago" '$2=="out" && $1+0>=start {c++} END{print c+0}' "$LOG_FILE")

    last_alert_month=""
    [[ -f "$STATE_FILE" ]] && last_alert_month=$(cat "$STATE_FILE")

    if awk -v c="$month_cost" -v t="$MONTH_THRESHOLD" 'BEGIN{exit !(c>=t)}'; then
        if [[ "$last_alert_month" != "$current_month" ]]; then
            send_ntfy "PSTN trunk: estimated spend this month (\$${month_cost} - \$${domestic_cost} domestic + \$${intl_cost} international) has crossed the \$${MONTH_THRESHOLD} threshold. ${month_minutes} minutes so far."
            echo "$current_month" > "$STATE_FILE"
        fi
    fi

    if [[ "$hour_calls" -ge "$BURST_THRESHOLD" ]]; then
        send_ntfy "PSTN trunk: $hour_calls outbound calls placed in the last hour - check for unusual activity."
    fi
fi

# ── Spend-cap kill-switch: trip, or warn once approaching it. Deliberately
# OUTSIDE the "if log file exists" block above — the hangup sweep below
# must still run every minute while tripped even if the call log is
# missing/rotated, otherwise a missing log file would silently stop the
# active-hangup backstop entirely. month_cost/hour_calls default to 0/0
# when there's no log file (set before that block), so this still can't
# falsely trip on no data. ─────────────────────────────────────────────────
# MAX_MONTHLY_SPEND=0 means the kill-switch is disabled (not configured).
if awk -v m="$MAX_MONTHLY_SPEND" 'BEGIN{exit !(m+0>0)}'; then
    already_tripped="0"
    [[ -f "$KILLSWITCH_FILE" ]] && grep -q '^tripped=1' "$KILLSWITCH_FILE" && already_tripped="1"

    if [[ "$already_tripped" != "1" ]] && awk -v c="$month_cost" -v m="$MAX_MONTHLY_SPEND" 'BEGIN{exit !(c>=m)}'; then
        cat > "$KILLSWITCH_FILE" << KS
[state]
tripped=1
KS
        send_ntfy_loud "PSTN trunk: SPEND-CAP KILL-SWITCH TRIPPED. Estimated spend this month (\$${month_cost}) reached the \$${MAX_MONTHLY_SPEND} cap. ALL PSTN calling (in and out) is now blocked - internal Asterisk calling is unaffected. This does NOT reset automatically - clear it with 'sudo ./setup.sh pstn-trunk' (update mode)."
        already_tripped="1"
    elif [[ "$already_tripped" != "1" ]]; then
        warn_threshold=$(awk -v m="$MAX_MONTHLY_SPEND" 'BEGIN{printf "%.2f", m*0.8}')
        if awk -v c="$month_cost" -v t="$warn_threshold" 'BEGIN{exit !(c>=t)}'; then
            last_warn_month=""
            [[ -f "$WARN_STATE_FILE" ]] && last_warn_month=$(cat "$WARN_STATE_FILE")
            if [[ "$last_warn_month" != "$current_month" ]]; then
                send_ntfy_loud "PSTN trunk: approaching the spend cap - estimated spend this month (\$${month_cost}) is at 80%+ of the \$${MAX_MONTHLY_SPEND} kill-switch cap. PSTN calling will be BLOCKED automatically if it reaches \$${MAX_MONTHLY_SPEND}."
                echo "$current_month" > "$WARN_STATE_FILE"
            fi
        fi
    fi

    # Every run while tripped, not just the run that trips it — closes
    # the race where a call started just before the flag went live.
    [[ "$already_tripped" == "1" ]] && _pstn_hangup_active_trunk_calls
fi

# ── International allow-list: expiry notices + active re-block ────────────
if [[ -n "$intl_codes" ]]; then
    intl_expires=$(grep '^expires=' "$INTL_FILE" | head -1 | cut -d= -f2-)
    today=$(date +%Y-%m-%d)
    if [[ -n "$intl_expires" ]]; then
        last_intl_notice=""
        [[ -f "$INTL_STATE_FILE" ]] && last_intl_notice=$(cat "$INTL_STATE_FILE")
        if [[ "$today" == "$intl_expires" && "$last_intl_notice" != "day-of:$intl_expires" ]]; then
            send_ntfy "PSTN trunk: international calling access expires TODAY ($intl_expires)."
            echo "day-of:$intl_expires" > "$INTL_STATE_FILE"
        fi
        if [[ "$today" > "$intl_expires" ]]; then
            sed -i 's/^allowed_codes=.*/allowed_codes=/; s/^allowed_names=.*/allowed_names=/; s/^allowed_rates=.*/allowed_rates=/; s/^expires=.*/expires=/' "$INTL_FILE"
            send_ntfy "PSTN trunk: international calling access EXPIRED ($intl_expires) and has been revoked/re-blocked automatically."
            echo "expired:$intl_expires" > "$INTL_STATE_FILE"
        fi
    fi
fi
EOF
    sed -i "s#__EA_DIR__#${EA_DIR}#g; s#__ASTERISK_DIR__#${ASTERISK_DIR}#g; s/__PSTN_RATE__/${RATE}/g; s/__PSTN_MONTH_THRESHOLD__/${MONTH_THRESHOLD}/g; s/__PSTN_BURST_THRESHOLD__/${BURST_THRESHOLD}/g; s/__PSTN_MAX_MONTHLY_SPEND__/${MAX_MONTHLY_SPEND}/g; s/__PSTN_CONTAINER_NAME__/${CONTAINER_NAME}/g" "$FILE"
    sed -i "s#__PSTN_NTFY_URL__#${NTFY_URL}#g" "$FILE"
    chmod 755 "$FILE"
}

# ── Shared: per-minute periodic check (systemd timer, cron.d fallback) ─────
# Runs pstn-trunk-usage-alert.sh far more often than the old hourly cron.d
# job — every minute — since it's also the enforcement point for the
# spend-cap kill-switch (see _pstn_write_usage_alert_script below): the
# gap between a check and the next one is the window where an overage
# could still happen before calling actually gets blocked, so a tighter
# interval directly shrinks that exposure. Idempotent: safe to call again
# on "update in place" to migrate an older install off the old cron.d job.
_pstn_install_periodic_timer() {
    local EA_DIR="$1"
    mkdir -p "$EA_DIR/logs"

    # Older versions of this service installed an hourly cron.d job under
    # this same name — remove it so there's only ever one scheduler.
    [[ -f /etc/cron.d/pstn-trunk-usage ]] && rm -f /etc/cron.d/pstn-trunk-usage

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        cat > /etc/systemd/system/pstn-trunk-usage.service << SVCEOF
[Unit]
Description=PSTN trunk spend/volume/kill-switch/international-expiry check

[Service]
Type=oneshot
ExecStart=/bin/bash $EA_DIR/pstn-trunk-usage-alert.sh
StandardOutput=append:$EA_DIR/logs/pstn-trunk-usage-alert.log
StandardError=append:$EA_DIR/logs/pstn-trunk-usage-alert.log
SVCEOF

        cat > /etc/systemd/system/pstn-trunk-usage.timer << SVCEOF
[Unit]
Description=Run the PSTN trunk usage check every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
SVCEOF

        systemctl daemon-reload
        systemctl enable --now pstn-trunk-usage.timer
        log_success "Per-minute spend/volume/kill-switch check installed (systemd timer)."
    elif command -v cron >/dev/null 2>&1 || [[ -d /etc/cron.d ]]; then
        cat > /etc/cron.d/pstn-trunk-usage << CRON
* * * * * root /bin/bash $EA_DIR/pstn-trunk-usage-alert.sh >> $EA_DIR/logs/pstn-trunk-usage-alert.log 2>&1
CRON
        log_success "Per-minute spend/volume/kill-switch check installed (cron.d fallback — systemd not detected)."
    else
        log_warning "Neither systemd nor cron available — run $EA_DIR/pstn-trunk-usage-alert.sh manually/periodically for spend/volume/kill-switch checks."
    fi
}

# ── Shared: structural settings only (used by fresh install AND update) ────
# Does NOT touch pstn-permissions.conf — see the file-level comment above
# for why that file is managed separately.
_pstn_apply_settings() {
    local EA_DIR="$1" ASTERISK_DIR="$2"
    local SERVER="$3" SERVER_IPS="$4" DID="$5"
    local RING_EXTS="$6" NTFY_URL="$7" RATE="$8" MONTH_THRESHOLD="$9" BURST_THRESHOLD="${10}"
    local PROVIDER_NAME="${11}" MAX_MONTHLY_SPEND="${12:-0}" CONTAINER_NAME="${13:-easy-asterisk}"

    _pstn_patch_vendor_files "$EA_DIR" || return 1

    mkdir -p "$ASTERISK_DIR"
    _pstn_write_pjsip_include "$ASTERISK_DIR/pstn-trunk-pjsip.conf" "$SERVER" "$SERVER_IPS" "$DID"
    _pstn_write_dialplan_include "$ASTERISK_DIR/pstn-trunk-dialplan.conf" "$DID" "$RING_EXTS" "$NTFY_URL"
    _pstn_write_personal_group_ring_script "$ASTERISK_DIR/pstn-personal-group-ring.sh"
    _pstn_write_usage_alert_script "$EA_DIR/pstn-trunk-usage-alert.sh" "$EA_DIR" "$ASTERISK_DIR" \
        "$RATE" "$MONTH_THRESHOLD" "$BURST_THRESHOLD" "$MAX_MONTHLY_SPEND" "$NTFY_URL" "$CONTAINER_NAME"
    ensure_docker_dir_ownership "$ASTERISK_DIR"
    chmod 644 "$ASTERISK_DIR/pstn-trunk-pjsip.conf" "$ASTERISK_DIR/pstn-trunk-dialplan.conf"
    chmod 755 "$ASTERISK_DIR/pstn-personal-group-ring.sh"

    # Values are double-quoted: this file is `source`d back in on "update"
    # (and RING_EXTS/TRUNK_SERVER_IPS are space-separated whenever there's
    # more than one entry, and PROVIDER_NAME can be multi-word, e.g. "Anveo
    # Direct") — unquoted, bash's `source` would treat the second word of
    # any such value as a command to run ("Direct: command not found"),
    # confirmed live while testing the multi-IP change.
    cat > "$EA_DIR/.pstn-trunk.env" << ENV
PROVIDER_NAME="${PROVIDER_NAME}"
TRUNK_SERVER="${SERVER}"
TRUNK_SERVER_IPS="${SERVER_IPS}"
TRUNK_DID="${DID}"
RING_EXTS="${RING_EXTS}"
NTFY_URL="${NTFY_URL}"
RATE_PER_MIN="${RATE}"
MONTH_THRESHOLD="${MONTH_THRESHOLD}"
BURST_THRESHOLD="${BURST_THRESHOLD}"
MAX_MONTHLY_SPEND="${MAX_MONTHLY_SPEND}"
CONTAINER_NAME="${CONTAINER_NAME}"
ENV
    chown "$ACTUAL_USER:$ACTUAL_USER" "$EA_DIR/.pstn-trunk.env" 2>/dev/null || true

    _pstn_install_periodic_timer "$EA_DIR"
}

# Simple "press Enter to continue" pause — the portal steps below happen in
# a browser, not this terminal, so there's nothing to validate; this just
# gates pacing. Auto-skips under UNATTENDED (prompt_text's own behavior).
_pstn_wait_continue() {
    local _msg="$1" _ignored=""
    prompt_text "  $_msg" "" _ignored
}

# ── Anveo Direct walkthrough ────────────────────────────────────────────────
# Every value/field below is confirmed working end-to-end against a real
# account and a real call (both directions) — see
# docs/anveo-direct-setup-guide.md for the full narrative this was built
# from, including every bug that was hit and fixed along the way to get
# here. Nothing here is automatable (it's a real account behind a browser),
# so this walks the account-side steps with a pause between each, then lets
# the rest of this installer's existing prompts (DID, ring group, etc.)
# handle the Asterisk side as normal.
_pstn_anveo_walkthrough() {
    local _pub_ip=""
    _pub_ip="$(curl -fsS -4 --max-time 3 ifconfig.me 2>/dev/null || true)"
    [[ -z "$_pub_ip" ]] && _pub_ip="<this box's public IP — run: curl -4 ifconfig.me>"

    echo ""
    log_info "Anveo Direct walkthrough — each step below happens in Anveo's own portal,"
    log_info "not this terminal. Press Enter after each one to move to the next. Every"
    log_info "value given here is confirmed to work, not a guess."

    echo ""
    echo "  Step 1/5 — Account"
    echo "    https://www.anveo.com/account.asp?account_type=direct"
    echo "  Create/verify your account, then fund the balance directly (NOT a"
    echo "  subscription plan) — \$25 is plenty to start. Bank transfers can take a"
    echo "  few hours to clear. Two account-level caps to know about, both separate"
    echo "  from anything this installer enforces:"
    echo "    - Trial limits: 2 concurrent outbound calls, \$2/30-day spend cap, \$2"
    echo "      minimum balance — a 'request higher limits' link sits next to"
    echo "      CallerID Policies once you're funded."
    echo "    - Phone-numbers cap: most new accounts can manage up to 2 DIDs;"
    echo "      raising it means contacting Anveo support (they may ask for a tax"
    echo "      ID — your call whether that trade-off is worth it)."
    echo "  CallerID policy: outbound Caller-ID must be a verified/Anveo-owned"
    echo "  number — any DID you order through them satisfies this automatically."
    _pstn_wait_continue "Press Enter once your account is created and funded:"

    echo ""
    echo "  Step 2/5 — Order a DID"
    echo "  Order a phone number choosing the 'Per Minute' rate plan — NOT Prime."
    echo "  Per Minute bundles 10 dedicated incoming channels at \$0.004/min with no"
    echo "  separate trunk fee; Prime is free incoming but requires a separate,"
    echo "  flat monthly-fee trunk product you don't need."
    _pstn_wait_continue "Press Enter once you've ordered a DID:"

    echo ""
    echo "  Step 3/5 — Outbound Service (Call Termination) Trunk"
    echo "  Skip this step if you already have one from a previous number — one"
    echo "  trunk serves every DID on the account, this only needs doing once."
    echo "  Outbound Trunks -> Add a new Call Termination Trunk:"
    echo "    Title:                   any label"
    echo "    Dialing Prefix:          leave BLANK (confirmed not required)"
    echo "    Authorized IP Addresses: ${_pub_ip}"
    echo "    Rate Cap:                optional, e.g. \$1/min (a safety ceiling only —"
    echo "                             domestic calls run far below this)"
    echo "    Concurrent Calls Limit:  your choice (the Trial account's own 2-call"
    echo "                             cap from Step 1 overrides this until lifted)"
    echo "    Call Routing Method:     leave 'Custom Least Cost Routing Model' and"
    echo "                             all its sub-fields exactly as defaulted"
    _pstn_wait_continue "Press Enter once the trunk is created:"

    echo ""
    echo "  Step 4/5 — SIP Trunk (inbound forwarding) — one per DID"
    echo "  A SEPARATE object from the Outbound trunk above — don't confuse them;"
    echo "  this is what actually makes inbound calls to THIS DID ring anywhere."
    echo "    Trunk Name: any label"
    echo "    Primary:    SIP URI -> \$[E164]\$@${_pub_ip}:5060"
    echo "    Failover:   leave blank"
    echo "  Then open this DID's own Call Options tab -> Destination SIP Trunk ->"
    echo "  select the SIP Trunk you just created -> Save."
    _pstn_wait_continue "Press Enter once done:"

    echo ""
    echo "  Step 5/5 — Confirmed rate"
    echo "  Standard US-to-US domestic on the Prime rate card (the route set this"
    echo "  trunk's Custom LCR pulls from by default) is \$0.00388/min, billed"
    echo "  per-second — already the default a few prompts from now, no need to"
    echo "  look it up yourself unless you want to double-check it."
    _pstn_wait_continue "Press Enter to continue:"

    echo ""
    log_success "Portal setup done. The rest of this installer configures the Asterisk side."
    log_info "One more thing for after this finishes: grant PSTN access (and, if you"
    log_info "want, this DID as a personal number) to the right extension via the"
    log_info "Security Dashboard's PSTN Trunk tab — every extension starts at 'internal'"
    log_info "(no PSTN access) until you do."
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
    local KILLSWITCH_FILE="$ASTERISK_DIR/pstn-trunk-killswitch.conf"
    local PERSONAL_DIDS_FILE="$ASTERISK_DIR/pstn-personal-dids.conf"
    local SETTINGS_FILE="$EA_DIR/.pstn-trunk.env"
    local CONTAINER_NAME="easy-asterisk"
    [[ "$ASTERISK_KIND" == "asterisk-digital-ocean" ]] && CONTAINER_NAME="easy-asterisk-do"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would require an existing asterisk-digital-ocean OR asterisk (LAN) install"
        echo "[DRY-RUN] Would prompt for: known-provider quick-pick (Anveo Direct runs a full 5-step"
        echo "[DRY-RUN]   interactive portal walkthrough — account/funding, DID ordering, both trunk"
        echo "[DRY-RUN]   objects, confirmed rate — pausing for Enter between each; VoIP.ms pre-fills known"
        echo "[DRY-RUN]   server/signaling-IP values; still editable) or manual entry, SIP provider name, DID,"
        echo "[DRY-RUN]   max concurrent outbound/inbound calls (default 10/10), inbound ring-group extensions,"
        echo "[DRY-RUN]   ntfy alert topic (optional), international-calling allow-list (CLI-only,"
        echo "[DRY-RUN]   always asked, never on the web dashboard), per-minute rate + monthly/hourly"
        echo "[DRY-RUN]   alert thresholds, and an optional hard monthly spend-cap kill-switch"
        echo "[DRY-RUN] Would NOT prompt for who can call/be called, messaging, or personal numbers —"
        echo "[DRY-RUN]   all managed live via the Security Dashboard's PSTN Trunk tab instead; every"
        echo "[DRY-RUN]   extension defaults to 'internal' (no PSTN, no messaging) until granted there"
        echo "[DRY-RUN] Would resolve the server hostname to an IP, plus prompt for any additional"
        echo "[DRY-RUN]   known source IPs (some providers publish a fixed list), for inbound call matching"
        echo "[DRY-RUN] Would patch vendor generator functions to #include the trunk config"
        echo "[DRY-RUN] Would write pjsip/dialplan includes, pstn-permissions.conf, pstn-limits.conf,"
        echo "[DRY-RUN]   and pstn-trunk-killswitch.conf (fresh install only), plus a per-minute"
        echo "[DRY-RUN]   usage-alert script installed via a systemd timer (cron.d fallback)"
        echo "[DRY-RUN] Would offer 'update in place' (structural settings only — never touches"
        echo "[DRY-RUN]   pstn-permissions.conf, pstn-limits.conf, or the kill-switch trip state)"
        echo "[DRY-RUN]   instead of a fresh install if already configured; the international-calling"
        echo "[DRY-RUN]   review/change question is still asked every run either way"
        echo "[DRY-RUN] Fresh install: would prompt to restart the asterisk container to apply."
        echo "[DRY-RUN] Update in place: applies live instead — no restart, no dropped calls."
        echo "[DRY-RUN] Either way, directly patches the live pjsip.conf/extensions.conf with the"
        echo "[DRY-RUN]   #include lines and reloads res_pjsip/dialplan — Easy Asterisk only"
        echo "[DRY-RUN]   regenerates those files if they don't already exist, so an existing"
        echo "[DRY-RUN]   install (the common case) would otherwise never actually load the trunk config"
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

    log_info "Configuring a SIP PSTN trunk for $ASTERISK_KIND (any IP-authenticated provider —"
    log_info "VoIP.ms and Anveo Direct are both confirmed working; see docs/pstn-calling-voipms-plan.md"
    log_info "and, for Anveo Direct specifically, docs/anveo-direct-setup-guide.md)."
    log_info "US-only outbound (NANP dialplan), a concurrent-call cap, per-extension permission"
    log_info "tiers, an inbound ring-group, and ntfy alerts on denied/rejected calls plus"
    log_info "spend/volume checks."
    echo ""
    log_warning "Before continuing, on your provider's side you should already have: created an"
    log_warning "account, funded and set up prepaid billing with auto-recharge OFF (VoIP.ms: Client"
    log_warning "Area -> Balance Management; Anveo Direct: fund the account balance directly),"
    log_warning "ordered a DID with IP authentication pointed at this box's public IP, and picked"
    log_warning "a server/POP. Also restrict outbound routing to"
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
                    # Guard against a malformed/legacy settings file crashing the
                    # whole install under setup.sh's `set -u` — this file is
                    # machine-generated and should only ever hold plain
                    # KEY="value" assignments, but confirmed live: an older/
                    # partially-written copy can leave a stray unexpanded
                    # reference behind, and nounset treats any unset-variable
                    # reference on `source` as fatal, killing the entire script.
                    set +u
                    # shellcheck disable=SC1090
                    source "$SETTINGS_FILE"
                    set -u
                    if [[ -z "${TRUNK_SERVER:-}" || -z "${TRUNK_DID:-}" ]]; then
                        log_error "$SETTINGS_FILE is missing required values (TRUNK_SERVER/TRUNK_DID) —"
                        log_error "it may be from an older or corrupted version. Re-run and choose FRESH"
                        log_error "reinstall, or fix $SETTINGS_FILE by hand first."
                        return 1
                    fi
                    _pstn_check_killswitch_clear "$ASTERISK_DIR"
                    _pstn_apply_settings "$EA_DIR" "$ASTERISK_DIR" \
                        "$TRUNK_SERVER" "${TRUNK_SERVER_IPS:-}" "$TRUNK_DID" \
                        "${RING_EXTS:-}" "${NTFY_URL:-}" "${RATE_PER_MIN:-0.01}" \
                        "${MONTH_THRESHOLD:-10}" "${BURST_THRESHOLD:-10}" "${PROVIDER_NAME:-unknown}" "${MAX_MONTHLY_SPEND:-0}" "${CONTAINER_NAME:-easy-asterisk-do}" || return 1
                    # No container restart here — _pstn_ensure_live_includes's
                    # module/dialplan reload below already applies everything
                    # _pstn_apply_settings just wrote (trunk pjsip/dialplan
                    # includes, the group-ring script) live, without dropping
                    # any calls already in progress. A full restart doesn't
                    # accomplish anything the reload doesn't, and this is the
                    # "update in place" path — it shouldn't be more disruptive
                    # than it has to be. Confirmed live: this used to restart
                    # unconditionally here, redundant with (and disruptive on
                    # top of) the rebuild+restart asterisk[-digital-ocean].sh
                    # already just ran when this runs chained from there.
                    _pstn_ensure_live_includes "$ASTERISK_DIR" "$CONTAINER_NAME"
                    log_success "Updated — settings unchanged (server $TRUNK_SERVER, DID $TRUNK_DID, ring exts: $RING_EXTS)."
                    log_info "pstn-permissions.conf and pstn-limits.conf were NOT touched — edit them"
                    log_info "directly, via the Security Dashboard, or choose FRESH reinstall to reset them."
                    # Always asked, every run, update mode included — see
                    # _pstn_run_international_step's own comment for why.
                    _pstn_run_international_step "$ASTERISK_DIR"
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
                    log_warning "reinstall OVERWRITES both with whatever you enter below, and also resets"
                    log_warning "the spend-cap kill-switch back to untripped."
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
    # Known-provider quick-path: only pre-fills the defaults below (still
    # fully editable at each prompt) — doesn't change any dialplan/auth
    # behavior, which stays provider-generic either way.
    echo "  Known/tested providers — this only pre-fills the defaults below (server"
    echo "  hostname, signaling IPs, account-setup reminders); every value is still"
    echo "  editable at each prompt."
    echo "    1) Anveo Direct"
    echo "    2) VoIP.ms"
    echo "    3) Something else / manual entry"
    local _provider_choice=""
    prompt_text "Choice (1/2/3):" "3" _provider_choice

    local _default_provider_name="" _default_server="" _default_extra_ips=""
    case "$_provider_choice" in
        1)
            _default_provider_name="Anveo Direct"
            _default_server="sbc.anveo.com"
            _default_extra_ips="169.48.232.158 204.216.109.55 176.9.39.206 72.9.149.25"
            _pstn_anveo_walkthrough
            ;;
        2)
            _default_provider_name="VoIP.ms"
            ;;
    esac

    local PROVIDER_NAME=""
    prompt_text "SIP trunk provider name (for your reference/docs only — e.g. VoIP.ms, Anveo Direct):" "$_default_provider_name" PROVIDER_NAME

    local TRUNK_SERVER=""
    prompt_text "Server/POP hostname (e.g. atlanta2.voip.ms for VoIP.ms, sbc.anveo.com for Anveo Direct — pick the one closest to this box from your provider's server list):" "$_default_server" TRUNK_SERVER
    if [[ -z "$TRUNK_SERVER" ]]; then
        log_error "A server hostname is required — aborting."
        return 1
    fi

    local TRUNK_SERVER_IP=""
    TRUNK_SERVER_IP="$(getent ahostsv4 "$TRUNK_SERVER" 2>/dev/null | awk '{print $1}' | head -1)"
    if [[ -z "$TRUNK_SERVER_IP" ]]; then
        log_warning "Couldn't resolve $TRUNK_SERVER — the identify section needs at least one IP to match inbound calls against."
        prompt_text "Enter its IP manually (check your provider's server list page):" "" TRUNK_SERVER_IP
        if [[ -z "$TRUNK_SERVER_IP" ]]; then
            log_error "No IP available — aborting."
            return 1
        fi
    else
        log_success "Resolved $TRUNK_SERVER -> $TRUNK_SERVER_IP"
    fi

    # Some providers send inbound signaling from a fixed set of published IPs
    # that don't necessarily match what the server hostname resolves to (e.g.
    # Anveo Direct publishes 4 signaling IPs regardless of which hostname you
    # dial out to) — the resolved IP above always gets included, this just
    # adds any others the provider documents.
    local EXTRA_IPS=""
    prompt_text "Any additional known source IPs for inbound calls, space-separated (check your provider's docs — e.g. a firewall/signaling IP list; blank if the resolved IP above is the only one):" "$_default_extra_ips" EXTRA_IPS
    local _octet='(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)'
    local _ip_re="^${_octet}\\.${_octet}\\.${_octet}\\.${_octet}\$"
    local TRUNK_SERVER_IPS="$TRUNK_SERVER_IP" _ip
    for _ip in $EXTRA_IPS; do
        if [[ "$_ip" =~ $_ip_re ]]; then
            TRUNK_SERVER_IPS="${TRUNK_SERVER_IPS} ${_ip}"
        else
            log_warning "Skipping '$_ip' — doesn't look like an IPv4 address."
        fi
    done

    local TRUNK_DID=""
    prompt_text "DID (the 10-digit US phone number assigned to this trunk, digits only):" "" TRUNK_DID
    if [[ ! "$TRUNK_DID" =~ ^[0-9]{10}$ ]]; then
        log_error "That doesn't look like a 10-digit US number — aborting."
        return 1
    fi

    # ── Permission tiers, messaging, personal numbers — all managed via the
    # Security Dashboard, not prompted here ────────────────────────────────
    # This used to prompt for full/restricted extensions, approved numbers,
    # messaging extensions, and personal-DID assignments right here at
    # install time. All four are live-editable, no-restart-needed settings
    # in pstn-permissions.conf / pstn-personal-dids.conf that the Security
    # Dashboard's PSTN Trunk tab already manages end to end — duplicating
    # that as a wall of CLI prompts (that you'd then have to redo via a full
    # reinstall to change) added friction the dashboard already solves
    # better. Every extension defaults to "internal" (no PSTN, no
    # messaging, no personal number) until granted otherwise there.
    echo ""
    log_info "Who can call/be called, internal SIP messaging, and personal numbers are"
    log_info "all managed from the Security Dashboard's PSTN Trunk tab (not here) — install"
    log_info "it if you haven't: sudo ./setup.sh security-dashboard. Every extension starts"
    log_info "at 'internal' (no PSTN, no messaging) until you grant it there; changes apply"
    log_info "live, no restart or reinstall needed."
    local FULL_EXTS="" RESTRICTED_EXTS="" RESTRICTED_ARGS=()
    local MESSAGING_EXTS="" PERSONAL_DID_PAIRS=() PERSONAL_DID_ASSIGNMENTS=""

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

    local RING_EXTS=""
    prompt_text "Extensions to ring for inbound PSTN calls (space-separated — one, or several for a ring group; only full/restricted-tier members will actually ring, once granted via the dashboard):" "" RING_EXTS
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

    # Always asked, every run, no exceptions — see _pstn_run_international_step's
    # own comment for why this can't be skipped like everything else here.
    _pstn_run_international_step "$ASTERISK_DIR"

    echo ""
    log_info "Spend/volume alert settings (used only to estimate cost and flag unusual usage —"
    log_info "not billing-accurate, just a safety net)."
    # Confirmed live (2026-07-23) against Anveo Direct's own "Prime" rate card
    # (the route set selected on the outbound trunk's Custom LCR config,
    # "Get Routes/Carriers from: All Prime Routes"): standard US-to-US
    # domestic is $0.00388/min, billed per-second — that CSV is the actual
    # rate an Anveo Direct Prime trunk pays, not an estimate. VoIP.ms's own
    # rate is still an unconfirmed ballpark.
    local _default_rate="0.01"
    [[ "$_provider_choice" == "1" ]] && _default_rate="0.00388"
    local RATE_PER_MIN=""
    prompt_text "  Outbound per-minute rate in USD (check your provider's published rate — e.g. VoIP.ms US is ~0.01, Anveo Direct US Prime rate is 0.00388 confirmed):" "$_default_rate" RATE_PER_MIN
    local MONTH_THRESHOLD=""
    prompt_text "  Alert once when estimated spend this month reaches (USD):" "10" MONTH_THRESHOLD
    local BURST_THRESHOLD=""
    prompt_text "  Alert if more than this many outbound calls happen in one hour:" "10" BURST_THRESHOLD

    echo ""
    log_warning "Spend-cap kill-switch: a HARD stop, not just an alert. Once estimated spend"
    log_warning "this month reaches the cap below, ALL PSTN calling (in and out) is blocked"
    log_warning "until you manually clear it by re-running this installer (update mode) — it"
    log_warning "does NOT reset automatically next month. Internal Asterisk-to-Asterisk"
    log_warning "calling is never affected."
    log_warning "Based on estimated cost (call count/duration x the rate above), not your"
    log_warning "provider's real billing data, and checked every minute, not instantly — a"
    log_warning "strong safety net, not an absolute guarantee against any overage."
    local WANT_KILLSWITCH=""
    prompt_yn "Enable a hard monthly spend-cap kill-switch? (y/n):" "y" WANT_KILLSWITCH
    local MAX_MONTHLY_SPEND="0"
    if [[ "$WANT_KILLSWITCH" =~ ^[Yy]$ ]]; then
        prompt_text "  Monthly spend cap in USD (ALL PSTN calling blocked once reached):" "15" MAX_MONTHLY_SPEND
        if [[ ! "$MAX_MONTHLY_SPEND" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_warning "Not a number — defaulting to 15."
            MAX_MONTHLY_SPEND="15"
        fi
        log_info "You'll get a loud ntfy alert at 80% of this cap, and another (also loud) when it trips."
    else
        MAX_MONTHLY_SPEND="0"
        log_info "Kill-switch disabled — the spend alerts above still notify you, but calling won't be auto-blocked."
    fi

    _pstn_apply_settings "$EA_DIR" "$ASTERISK_DIR" \
        "$TRUNK_SERVER" "$TRUNK_SERVER_IPS" "$TRUNK_DID" \
        "$RING_EXTS" "$NTFY_URL" "$RATE_PER_MIN" \
        "$MONTH_THRESHOLD" "$BURST_THRESHOLD" "$PROVIDER_NAME" "$MAX_MONTHLY_SPEND" "$CONTAINER_NAME" || return 1

    _pstn_write_permissions_file "$PERMISSIONS_FILE" "$FULL_EXTS" "$MESSAGING_EXTS" "$PERSONAL_DID_ASSIGNMENTS" "${RESTRICTED_ARGS[@]}"
    _pstn_write_limits_file "$LIMITS_FILE" "$MAX_OUTBOUND" "$MAX_INBOUND"
    _pstn_write_killswitch_file "$KILLSWITCH_FILE"
    _pstn_write_personal_dids_file "$PERSONAL_DIDS_FILE" "${PERSONAL_DID_PAIRS[@]}"
    ensure_docker_dir_ownership "$ASTERISK_DIR"

    # No new firewall rules: the base install already opens SIP (5060/5061)
    # and RTP (10000-20000) to the internet, and providers' source IPs vary
    # by POP/redundancy, so there's no single IP to scope this to even if
    # narrowing it were otherwise worthwhile.

    # ── Docs (separate file — the base install already owns README.md in
    # this same directory via write_readme, so don't overwrite it) ─────────
    # Kill-switch/international-allowlist blurbs are built into plain
    # variables first, not inline $(...) inside the heredoc below — a
    # heredoc nested inside a command substitution that's itself inside
    # another heredoc doesn't parse in bash (confirmed: "syntax error near
    # unexpected token `||'" when tried directly).
    local KILLSWITCH_DOC=""
    if [[ "$MAX_MONTHLY_SPEND" != "0" ]]; then
        KILLSWITCH_DOC="**Enabled — \$${MAX_MONTHLY_SPEND}/month.** Once \`pstn-trunk-usage-alert.sh\`
estimates month-to-date spend has reached this cap, it writes
\`tripped=1\` to \`config/asterisk/pstn-trunk-killswitch.conf\` — read
**live** by the dialplan on every PSTN call attempt (in AND out; internal
Asterisk-to-Asterisk calling is never affected) and blocks it immediately
with a loud (priority=urgent) ntfy alert. You also get a separate loud ntfy
warning once spend reaches 80% of this cap, before it actually trips.

While tripped, every run of \`pstn-trunk-usage-alert.sh\` (every minute) also
force-hangs-up any PSTN call already in progress (via \`docker exec ... asterisk
-rx \"channel request hangup ...\"\` against the trunk's active channels) —
not just new calls. Otherwise a call already connected when the cap is
crossed would just keep running (and costing) until it ends naturally,
since the dialplan only gates the *start* of a call. This bounds worst-case
overage to roughly one check interval's cost across whatever's active,
rather than open-ended.

**This does NOT reset automatically** — once tripped, it stays tripped
until you clear it yourself: re-run \`sudo ./setup.sh pstn-trunk\`, choose
update mode, and answer yes when asked. This is deliberately a CLI-only
action, not exposed on the Security Dashboard web UI, so a compromised or
careless web session can't quietly re-enable spend after a trip.

Based on estimated cost, not real billing data, and checked once a minute —
a strong safety net, not an absolute guarantee against any overage. See
\"How bulletproof is this?\" below."
    else
        KILLSWITCH_DOC="**Disabled.** The spend alerts above still notify you, but PSTN calling won't be auto-blocked. Enable it by re-running \`sudo ./setup.sh pstn-trunk\` (update mode)."
    fi

    _pstn_read_intl_current "$ASTERISK_DIR/pstn-intl-allowed.conf"
    local INTL_DOC=""
    if [[ -n "$_PSTN_CUR_CODES" ]]; then
        local -a _doc_codes _doc_names _doc_rates
        IFS='|' read -ra _doc_codes <<< "$_PSTN_CUR_CODES"
        IFS='|' read -ra _doc_names <<< "$_PSTN_CUR_NAMES"
        IFS='|' read -ra _doc_rates <<< "$_PSTN_CUR_RATES"
        INTL_DOC="**Currently allowed:**
"
        local _di
        for _di in "${!_doc_codes[@]}"; do
            INTL_DOC="${INTL_DOC}- ${_doc_names[$_di]:-+${_doc_codes[$_di]}} — \$${_doc_rates[$_di]:-0}/min
"
        done
        if [[ -n "$_PSTN_CUR_EXPIRES" ]]; then
            INTL_DOC="${INTL_DOC}
**Expires:** $_PSTN_CUR_EXPIRES — auto-revoked and re-blocked after this date (with an ntfy notice both the day of and at the moment it expires)."
        else
            INTL_DOC="${INTL_DOC}
**No expiry set** — stays allowed until changed again from the CLI."
        fi
    else
        INTL_DOC="**No countries currently allowed** — outbound/inbound PSTN calling is US/NANP-only."
    fi

    local DOC_FILE="$EA_DIR/README-pstn-trunk.md"
    cat > "$DOC_FILE" << MD
# SIP PSTN trunk (add-on to $ASTERISK_KIND)

US-only outbound PSTN calling over a SIP trunk (any IP-authenticated
provider — VoIP.ms and Anveo Direct both confirmed working), per-extension
permission tiers, a configurable concurrent-call cap, and an inbound
ring-group. See
\`docs/pstn-calling-voipms-plan.md\` in the repo for the full design
background, cost estimate, and toll-fraud reasoning.

## Current settings

| Setting | Value |
|---|---|
| Provider | ${PROVIDER_NAME} |
| Server/POP | ${TRUNK_SERVER} (inbound match IPs: ${TRUNK_SERVER_IPS}) |
| DID | ${TRUNK_DID} |
| Outbound scope | US/NANP only — \`_1NXXNXXXXXX\` / \`_NXXNXXXXXX\` patterns, no catch-all, minus 27 non-US/premium NANP area codes (see below) |
| Permission tiers, messaging, personal numbers | Managed live via the Security Dashboard's PSTN Trunk tab — not set at install, so not shown here (this file isn't regenerated when you change them there). Everyone starts at \`internal\` (no PSTN, no messaging) until granted. |
| Concurrency caps | ${MAX_OUTBOUND} outbound / ${MAX_INBOUND} inbound simultaneous calls (live — see \`pstn-limits.conf\` below) |
| Inbound ring-group | ${RING_EXTS} |
| ntfy alerts | ${NTFY_URL:-disabled} |
| Estimated rate | \$${RATE_PER_MIN}/min |
| Monthly spend alert threshold | \$${MONTH_THRESHOLD} |
| Hourly burst alert threshold | ${BURST_THRESHOLD} calls/hour |
| Spend-cap kill-switch | $([ "$MAX_MONTHLY_SPEND" != "0" ] && echo "\$${MAX_MONTHLY_SPEND}/month — blocks ALL PSTN calling once reached" || echo "disabled") |

## Non-US NANP area codes are blocked, not just "anything outside NANP"

NANP (the North American Numbering Plan) isn't the same thing as "US" — it
also covers several Caribbean/Atlantic nations and US territories, all of
which dial exactly like a normal 10-digit US number but get billed by most
providers at international/premium rates. This is a well-known toll-fraud/
"one-ring scam" vector specifically because the number *looks* domestic.
27 area codes are blocked explicitly, checked before permission tier — this
applies to **every** extension regardless of tier, since "full" means "any
US number," not "any NANP-shaped number":

Bahamas (242), Barbados (246), Anguilla (264), Antigua & Barbuda (268),
British Virgin Islands (284), US Virgin Islands (340), Cayman Islands
(345), Bermuda (441), Grenada (473), Turks & Caicos (649), Jamaica
(658/876), Montserrat (664), Northern Mariana Islands (670), Guam (671),
American Samoa (684), Sint Maarten (721), Saint Lucia (758), Dominica
(767), Saint Vincent (784), Puerto Rico (787/939), Dominican Republic
(809/829/849), Trinidad & Tobago (868), Saint Kitts & Nevis (869).

If you have a legitimate reason to call one of these (e.g. family in Puerto
Rico), remove that entry from the `REGEX()` pattern in
`pstn-trunk-dialplan.conf`'s `_1NXXNXXXXXX` extension — it'll be
regenerated exactly the same way on the next reinstall/update, so note the
change somewhere you'll remember it, or keep a local diff.

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

\`pstn-trunk-usage-alert.sh\` runs **every minute** (\`pstn-trunk-usage.timer\`,
a systemd timer — falls back to a cron.d entry if systemd isn't available)
and reads \`logs/pstn-trunk-calls.log\` (appended to directly by the
dialplan, not Asterisk's own CDR — a deliberate choice to avoid depending on
whether this image's CDR modules are enabled/configured, and to sidestep CDR
CSV's comma-quoting). It sends an ntfy alert:

- **Once per calendar month** the first time estimated spend crosses
  \$${MONTH_THRESHOLD} (state tracked in \`.pstn-trunk-alert-state\` so it
  doesn't repeat every minute).
- **Every run** that outbound call volume in the last hour exceeds
  ${BURST_THRESHOLD} calls — the faster tripwire for a burst/abuse scenario,
  independent of whether it's crossed the monthly dollar threshold yet.

Separately, denied calls (no permission / number not pre-approved) and
rejected calls (either concurrency cap or the kill-switch) alert
**immediately** from the dialplan itself, not on the periodic schedule.

These are cost *estimates* (call count/duration × your entered rate), not
real billing data, and only as fresh as the last check (every minute) — a
safety net, not a substitute for checking your provider's own balance/usage
dashboard.

## Spend-cap kill-switch

$KILLSWITCH_DOC

### How bulletproof is this?

Not fully — be clear-eyed about what's actually guaranteed vs. estimated:

- **Genuinely hard:** your provider's own prepaid-balance block (confirmed
  in writing for Anveo Direct: all calls, in and out, blocked in real time
  at \$0 balance — ask the same question of any other provider before
  trusting it). That's a real ceiling enforced outside this repo's code
  entirely.
- **Not hard:** the kill-switch above only enforces *the dollar figure you
  typed in here* — a separate, smaller number than your actual account
  balance. It's estimate-based (call count/duration × rates you entered,
  not the provider's real billing), checked once a minute, and a call
  already in progress is only invisible to the estimator until it either
  ends or gets force-hung-up on the next check (see the active-hangup
  behavior above — that closes most, not all, of the gap).
- The one setup that's actually bulletproof against losing more than \$X:
  fund the prepaid account with exactly \$X (top it up manually, no
  auto-recharge) and let the provider's own \$0 block be the real ceiling.
  Treat this kill-switch as a fast early-warning/second layer on top of
  that, not the guarantee itself.

## International calling (beyond NANP/US)

$INTL_DOC

Managed **only** from the CLI (\`sudo ./setup.sh pstn-trunk\` — asked on every
run, fresh install or update, with no way to skip the question, though you
can always answer no to leave things unchanged), deliberately never exposed
on the Security Dashboard web UI: this widens which countries can be
dialed/billed to at all, a more security-sensitive control than who's
already allowed to use an already-fixed scope. Only \`full\`-tier extensions
can place these calls regardless of which countries are allowed. Stored in
\`config/asterisk/pstn-intl-allowed.conf\`, read live the same way as
permission tiers.

## Internal SIP messaging

Asterisk's native SIP \`MESSAGE\` support (extension-to-extension texting —
no carrier SMS, no PSTN, no cost) is gated by a \`messaging=yes\` flag per
extension in \`pstn-permissions.conf\`, independent of the PSTN calling
tiers above — off by default, same "opt in" posture. Live-editable any
time via the Security Dashboard's "PSTN Trunk" tab, in its own
always-available "Internal SIP messaging" card — no dependency on this
trunk (or any PSTN trunk at all) being installed.

Actually enforced, not just a flag — \`services/asterisk-digital-ocean.sh\`
(and \`services/asterisk.sh\` for the LAN edition) routes messages through a
dedicated \`[sip-messaging]\` dialplan context (separate from \`[intercom]\`'s
own per-device call routing, so there's no collision risk) and checks this
same flag via \`AST_CONFIG()\` before delivering. One caveat still flagged
rather than papered over: the \`MESSAGE(from)\` sender-extraction hasn't
been confirmed against real MESSAGE traffic on a live install — it fails
closed (denies) if it ever parses wrong, but worth a live test.

## Personal numbers

Multiple DIDs can share this one trunk/account — assign one to a specific
extension and inbound calls to it route straight to that owner, still
gated by the owner's own tier/approved-numbers (no ring-group fallback,
since it's that extension's own line, not the shared one), while that
extension's outbound calls show its own DID as Caller-ID instead of the
shared trunk DID above. Entirely additive: the shared DID/ring-group keeps
working for everyone regardless of what's assigned here.

$([ "${#PERSONAL_DID_PAIRS[@]}" -gt 0 ] && { local _i; for ((_i=0; _i<${#PERSONAL_DID_PAIRS[@]}; _i+=2)); do echo "- \`${PERSONAL_DID_PAIRS[$_i]}\` -> extension ${PERSONAL_DID_PAIRS[$_i+1]}"; done; } || echo "None assigned yet.")

Stored in \`config/asterisk/pstn-personal-dids.conf\` (DID -> owner, read live
by the dialplan for inbound routing) and a \`personal_did=\` field per
extension in \`pstn-permissions.conf\` (the outbound Caller-ID override) —
both kept in sync automatically by the CLI installer and the Security
Dashboard's "PSTN Trunk" tab, live, no restart needed.

## Managing this from a web UI

If \`services/security-dashboard.sh\` is installed, its "PSTN Trunk" tab
shows the per-extension permission tiers, the outbound/inbound concurrency
caps, and personal-number assignments, all editable live — no restart, no
reinstall. Install/update it any time with \`sudo ./setup.sh
security-dashboard\`; it auto-detects this install.

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
    # Patches the live config files directly regardless of the restart choice
    # above — see _pstn_ensure_live_includes's own comment for why this is
    # necessary even after a restart, on a box that already had devices
    # configured. Its final reload commands just no-op harmlessly if
    # Asterisk isn't up yet (e.g. restart declined above).
    _pstn_ensure_live_includes "$ASTERISK_DIR" "$CONTAINER_NAME"

    echo ""
    log_success "PSTN trunk configured."
    echo "  Provider:              $PROVIDER_NAME ($TRUNK_SERVER)"
    echo "  Inbound match IPs:     $TRUNK_SERVER_IPS"
    echo "  DID:                   $TRUNK_DID"
    echo "  Outbound:              US/NANP only, max $MAX_OUTBOUND concurrent calls"
    echo "  Inbound:               max $MAX_INBOUND concurrent calls"
    echo "  Inbound ring-group:    $RING_EXTS"
    echo "  ntfy alerts:           ${NTFY_URL:-disabled}"
    echo "  Docs:                  $DOC_FILE"
    echo ""
    log_info "Everyone's at 'internal' tier (no PSTN, no messaging) until you grant access"
    log_info "via the Security Dashboard's PSTN Trunk tab — sudo ./setup.sh security-dashboard"
    log_info "if it isn't installed yet."
    echo ""
}
