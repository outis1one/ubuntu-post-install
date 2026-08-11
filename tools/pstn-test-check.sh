#!/usr/bin/env bash
# tools/pstn-test-check.sh — Automated half of docs/pstn-sms-test-checklist.md.
# Runs every check that doesn't require an actual phone call or text message
# (container/dir detection, registration, trunk reachability, dialplan
# contexts, kill-switch state, usage-alert timer health, recent call/message
# log activity) and reports PASS/WARN/FAIL for each. What's left after this —
# actually placing a call, texting the DID — needs a second phone and can't
# be scripted; this gets you to that point without re-typing commands or
# re-deriving the container name by hand each time (see the "no such
# container: asterisk" class of failure this script's detection step avoids).
#
# Usage:
#   sudo bash tools/pstn-test-check.sh
#
# Safe to run any time — read-only except for the two "asterisk -rx" queries
# below, neither of which changes any state.

set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '  [OK]   %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s ==\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo — needs docker exec and (on some boxes) systemctl/journalctl." >&2
    exec sudo bash "$0" "$@"
fi

# ── Container + directory detection ─────────────────────────────────────────
section "Detecting install"

CONTAINER="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -E '^easy-asterisk(-do)?$' || true)"
if [ -z "$CONTAINER" ]; then
    fail "No running easy-asterisk / easy-asterisk-do container found — is asterisk installed and started?"
    echo ""
    echo "  $PASS passed, $WARN warnings, $FAIL failed. Stopping — nothing else can be checked without a running container."
    exit 1
fi
ok "Container running: $CONTAINER"

EA_DIR=""
ACTUAL_USER="${SUDO_USER:-${USER:-root}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/root")"
if [ -d "$ACTUAL_HOME/docker/asterisk-digital-ocean" ]; then
    EA_DIR="$ACTUAL_HOME/docker/asterisk-digital-ocean"
elif [ -d "$ACTUAL_HOME/docker/asterisk" ]; then
    EA_DIR="$ACTUAL_HOME/docker/asterisk"
fi
if [ -z "$EA_DIR" ]; then
    fail "No ~/docker/asterisk or ~/docker/asterisk-digital-ocean found for user $ACTUAL_USER."
    exit 1
fi
ok "Directory: $EA_DIR"

ASTERISK_DIR="$EA_DIR/config/asterisk"
LOGS_DIR="$EA_DIR/logs"

# ── Registration ─────────────────────────────────────────────────────────────
section "Extension registration"

ENDPOINTS_OUT="$(docker exec "$CONTAINER" asterisk -rx "pjsip show endpoints" 2>/dev/null)"
if [ -z "$ENDPOINTS_OUT" ]; then
    fail "Could not query pjsip endpoints — is Asterisk actually up inside the container?"
else
    # Endpoint lines look like " Endpoint:  101/101   Unavailable   0 of inf" —
    # skip the trunk itself (checked separately below) and the header/legend.
    while IFS= read -r line; do
        ext="$(awk '{print $2}' <<< "$line" | cut -d/ -f1)"
        state="$(awk '{print $3}' <<< "$line")"
        # Skip the column-header/legend line ("<Endpoint/CID...>  <State...>")
        # printed once at the top of real output — it matches the same
        # "^ Endpoint:" grep as an actual endpoint row.
        [[ "$ext" == "pstn-trunk" || "$ext" == "<Endpoint"* ]] && continue
        if [ "$state" = "Unavailable" ]; then
            warn "Extension $ext: Unavailable (not registered right now — fine if nobody's logged in, a problem if you expect this device online)"
        else
            ok "Extension $ext: $state"
        fi
    done < <(grep -E '^ Endpoint:' <<< "$ENDPOINTS_OUT")
fi

# ── Trunk ─────────────────────────────────────────────────────────────────────
section "PSTN trunk"

if [ ! -f "$ASTERISK_DIR/pstn-trunk-pjsip.conf" ]; then
    warn "pstn-trunk not installed (no pstn-trunk-pjsip.conf) — skipping trunk/dialplan/kill-switch checks."
else
    TRUNK_OUT="$(docker exec "$CONTAINER" asterisk -rx "pjsip show endpoint pstn-trunk" 2>/dev/null)"
    if grep -q "Contact:.*Avail" <<< "$TRUNK_OUT"; then
        ok "Trunk contact reachable (Avail)"
    else
        fail "Trunk contact not Avail — provider unreachable, or the trunk config didn't load. Full output:"
        echo "$TRUNK_OUT" | sed 's/^/         /'
    fi

    match_count="$(grep -c '^        Match:' <<< "$TRUNK_OUT")"
    if [ "$match_count" -gt 0 ]; then
        ok "$match_count inbound match IP(s) configured"
    else
        fail "No inbound match IPs on the trunk identify — inbound calls will never match this trunk"
    fi

    for ctx in intercom from-pstn-trunk; do
        if docker exec "$CONTAINER" asterisk -rx "dialplan show $ctx" 2>/dev/null | grep -q "not found\|No such context"; then
            fail "Dialplan context [$ctx] failed to load"
        else
            ok "Dialplan context [$ctx] loaded"
        fi
    done

    # ── Kill-switch ────────────────────────────────────────────────────────────
    section "Spend-cap kill-switch"
    KS_FILE="$ASTERISK_DIR/pstn-trunk-killswitch.conf"
    if [ -f "$KS_FILE" ]; then
        if grep -q '^tripped=1' "$KS_FILE" 2>/dev/null; then
            fail "TRIPPED — all PSTN calling is currently blocked. Clear via: sudo ./setup.sh pstn-trunk (update mode)"
        else
            ok "Not tripped"
        fi
    else
        warn "No pstn-trunk-killswitch.conf found — kill-switch may be disabled (MAX_MONTHLY_SPEND=0)"
    fi

    # ── Usage-alert timer ────────────────────────────────────────────────────────
    section "Usage-alert timer (spend/burst checks + kill-switch enforcement)"
    if systemctl is-active --quiet pstn-trunk-usage.timer 2>/dev/null; then
        ok "systemd timer active"
        LAST_RUN="$(systemctl show pstn-trunk-usage.service -p ActiveEnterTimestamp --value 2>/dev/null)"
        [ -n "$LAST_RUN" ] && [ "$LAST_RUN" != "n/a" ] && ok "Last ran: $LAST_RUN" || warn "Timer active but hasn't run yet (or timestamp unavailable) — check again in a minute"
    elif crontab -l 2>/dev/null | grep -q pstn-trunk-usage; then
        ok "cron.d fallback entry present (systemd timer not used on this box)"
    else
        fail "Neither the systemd timer nor a cron.d entry for pstn-trunk-usage was found — spend alerts and kill-switch enforcement are NOT running"
    fi
fi

# ── SMS inbound ───────────────────────────────────────────────────────────────
section "SMS inbound"
if systemctl list-unit-files sms-inbound.service &>/dev/null; then
    if systemctl is-active --quiet sms-inbound; then
        ok "sms-inbound service active"
    else
        fail "sms-inbound installed but not running — check: journalctl -u sms-inbound -n 50"
    fi
else
    warn "sms-inbound not installed"
fi

# ── Recent activity ───────────────────────────────────────────────────────────
section "Recent activity (last 5 lines per log, if present)"
for log in pstn-trunk-calls.log sip-messages.log; do
    f="$LOGS_DIR/$log"
    if [ -f "$f" ]; then
        echo "  -- $log --"
        tail -n 5 "$f" 2>/dev/null | sed 's/^/     /'
    else
        warn "$log not found yet (no activity logged, or the relevant service isn't installed)"
    fi
done

# ── Provider portal checklist ─────────────────────────────────────────────────
# Everything above is server-side and this script's own checks; the provider
# account/portal side (authorized IPs, DID routing, the SMS forward URL) is
# configured entirely outside this box and can't be queried from here. What
# CAN be done is computing the exact values Anveo's portal fields need to
# match, so you're checking against real numbers instead of hunting for them
# across two docs while tabbed into the portal.
section "Provider portal checklist — values to verify in Anveo (or your provider's portal)"

PSTN_ENV="$EA_DIR/.pstn-trunk.env"
TRUNK_DID="" PROVIDER_NAME=""
if [ -f "$PSTN_ENV" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$PSTN_ENV"
    set -u
    TRUNK_DID="${TRUNK_DID:-}"
    PROVIDER_NAME="${PROVIDER_NAME:-}"
fi

PUBLIC_IP="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)"

if [ -n "$TRUNK_DID" ]; then
    echo "  This box's DID:        $TRUNK_DID"
else
    echo "  This box's DID:        (not found — is pstn-trunk installed?)"
fi
if [ -n "$PUBLIC_IP" ]; then
    echo "  This box's public IP:  $PUBLIC_IP"
else
    echo "  This box's public IP:  (couldn't reach ifconfig.me — check manually: curl -4 ifconfig.me)"
fi
echo ""

if [[ "$PROVIDER_NAME" == *Anveo* ]]; then
    echo "  Confirm in the Anveo portal (docs/anveo-direct-setup-guide.md has the full walkthrough):"
    echo ""
    echo "   1. Outbound Trunks -> your Call Termination Trunk -> Authorized IP Addresses"
    echo "      includes: $PUBLIC_IP"
    echo "   2. Account Options -> SIP Trunk (inbound) -> Primary SIP URI is exactly:"
    echo "        \$[E164]\$@${PUBLIC_IP}:5060"
    echo "   3. Phone Numbers -> $TRUNK_DID -> Call Options -> Destination SIP Trunk"
    echo "      is set to that SIP Trunk object (or Account Options -> Service Defaults ->"
    echo "      Default Destination Trunk is set, which covers every DID automatically)"
    echo "   4. Account balance is funded and NOT at \$0 (calls silently block at \$0 balance)"
    echo "   5. Phone Numbers -> $TRUNK_DID -> SMS tab -> \"Forward to URL\" is ticked and"
    echo "      set to exactly the string below (see 'SMS webhook' just below if it's blank)"
else
    echo "  Provider not detected as Anveo Direct (PROVIDER_NAME='${PROVIDER_NAME:-unset}') —"
    echo "  generic checklist, check your provider's own portal for the equivalents:"
    echo ""
    echo "   1. This box's public IP ($PUBLIC_IP) is on the trunk's authorized/allowed IP list"
    echo "   2. The DID ($TRUNK_DID) routes inbound SIP to ${PUBLIC_IP}:5060"
    echo "   3. Account balance isn't at \$0 or suspended"
    echo "   4. SMS forwarding (if used) points at the URL below"
fi

echo ""
echo "  SMS webhook (from /opt/sms-inbound/settings.env, if installed):"
SMS_SETTINGS="/opt/sms-inbound/settings.env"
if [ -f "$SMS_SETTINGS" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$SMS_SETTINGS"
    set -u
    if [ -n "${SMS_FORWARD_URL:-}" ]; then
        echo "    ${SMS_FORWARD_URL}"
        echo "    (paste exactly as shown — press SAVE not RETURN on Anveo's SMS tab, then"
        echo "    reopen it to confirm the whole string came back, it's long)"
    else
        echo "    sms-inbound is installed but no SMS_FORWARD_URL found in $SMS_SETTINGS"
        echo "    — re-run: sudo ./setup.sh sms-inbound"
    fi
else
    echo "    sms-inbound not installed — nothing to configure on the SMS tab yet."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
echo "  $PASS passed, $WARN warnings, $FAIL failed."
echo ""
echo "  This covers everything that can be checked without placing a real call"
echo "  or sending a real text, plus the provider-side values above that only a"
echo "  human can confirm inside the portal itself. For the call/SMS test steps"
echo "  and what each result means, see docs/pstn-sms-test-checklist.md."

[ "$FAIL" -eq 0 ]
