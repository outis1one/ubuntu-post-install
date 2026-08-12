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
WARN_MSGS=()
FAIL_MSGS=()

ok()   { printf '  [OK]   %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN + 1)); WARN_MSGS+=("$1"); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); FAIL_MSGS+=("$1"); }
section() { printf '\n== %s ==\n' "$1"; }

# One extension's softphone setup block — shared by the full run below and
# the "print again, one at a time" prompt at the end, so the two can't drift.
# Reads SIP_SERVER/TURN_SERVER/TURN_USERNAME/TURN_PASSWORD from the caller's
# scope (set once, further down, before either call site runs).
print_ext_info() {
    local ext="$1" pass="$2" transport="$3" ice="$4" port proto
    if [ "$transport" = "transport-tls" ]; then port=5061; proto="tls"; else port=5060; proto="udp"; fi
    echo "  Extension $ext:"
    echo "    SIP server:  $SIP_SERVER"
    echo "    Username:    $ext"
    echo "    Password:    $pass"
    echo "    Port:        $port"
    echo "    Transport:   $proto"
    if [ "$ice" = "yes" ] && [ -n "${TURN_SERVER:-}" ]; then
        echo "    TURN server: $TURN_SERVER"
        echo "    TURN user:   $TURN_USERNAME"
        echo "    TURN pass:   $TURN_PASSWORD"
    fi
}

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

# Fetched once, reused by both the softphone-setup and provider-checklist
# sections below.
PUBLIC_IP="$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || true)"

# ── Registration ─────────────────────────────────────────────────────────────
section "Extension registration"

ENDPOINTS_OUT="$(docker exec "$CONTAINER" asterisk -rx "pjsip show endpoints" 2>/dev/null)"
if [ -z "$ENDPOINTS_OUT" ]; then
    fail "Could not query pjsip endpoints — is Asterisk actually up inside the container?"
else
    # Endpoint lines look like " Endpoint:  101/101   Unavailable   0 of inf" —
    # skip the trunk itself (checked separately below) and the header/legend.
    # State is captured with a regex, not a fixed field number: it's one or
    # more words ("Unavailable", but also "Not in use" — a single $3 field
    # grab truncated that to just "Not").
    while IFS= read -r line; do
        ext="$(awk '{print $2}' <<< "$line" | cut -d/ -f1)"
        state="$(sed -E 's/^ Endpoint:[[:space:]]+[^[:space:]]+[[:space:]]+(.*[^[:space:]])[[:space:]]+[0-9]+ of inf[[:space:]]*$/\1/' <<< "$line")"
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

# ── coturn (TURN) — used for remote/NAT'd extensions' media relay, and by
# Anveo-style ICE-enabled endpoints. Asterisk caches its OWN TURN_* values
# in its .env at the point it was configured — testing with those (not
# re-deriving fresh credentials) proves what Asterisk is actually set up
# to use, not just that the shared coturn instance works in general (that
# broader, multi-consumer check is tools/coturn-test-check.sh's job). ─────────
section "coturn (TURN relay for Asterisk)"

ASTERISK_ENV="$EA_DIR/.env"
TURN_SERVER="" TURN_USERNAME="" TURN_PASSWORD="" TURN_PORT=""
if [ -f "$ASTERISK_ENV" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$ASTERISK_ENV"
    set -u
    TURN_SERVER="${TURN_SERVER:-}"
    TURN_USERNAME="${TURN_USERNAME:-}"
    TURN_PASSWORD="${TURN_PASSWORD:-}"
    TURN_PORT="${TURN_PORT:-}"
fi

if [ -z "$TURN_SERVER" ]; then
    warn "Asterisk has no TURN configured — fine for LAN-only extensions, but a phone on"
    warn "mobile data or behind restrictive NAT may get one-way or no audio without it."
    warn "Add it via: sudo ./setup.sh asterisk (update mode)"
else
    if grep -q '^  coturn:' "$EA_DIR/docker-compose.yml" 2>/dev/null; then
        COTURN_CONTAINER="easy-asterisk-coturn"
        [[ "$CONTAINER" == *-do ]] && COTURN_CONTAINER="easy-asterisk-do-coturn"
        ok "Using an embedded, per-Asterisk coturn ($COTURN_CONTAINER) — not the shared"
        ok "instance, so tools/coturn-test-check.sh won't see this one; tested separately below."
    else
        COTURN_CONTAINER="coturn"
        ok "Using the shared coturn instance (also covered by tools/coturn-test-check.sh)"
    fi

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$COTURN_CONTAINER"; then
        fail "Container '$COTURN_CONTAINER' not running — Asterisk's TURN config points at it but it's down"
    elif ! docker exec "$COTURN_CONTAINER" which turnutils_uclient &>/dev/null; then
        warn "turnutils_uclient not found in $COTURN_CONTAINER — skipping live allocation test"
    else
        # Plain UDP only — no -t/-T (TCP/TLS) flags. coturn is started with
        # --no-tls --no-dtls (services/coturn.sh), so requesting an
        # encrypted/TCP transport here just fails the allocation outright
        # against a server that never offered one, misreporting a config
        # problem that doesn't exist. Confirmed live: this was the actual
        # cause of a "Cannot complete Allocation" failure against an
        # otherwise fully working coturn instance.
        #
        # turnutils_uclient also refuses to run at all without either -e
        # <peer> or -y ("Either -e peer_address or -y must be specified",
        # confirmed live). -e needs an actual reachable, non-loopback peer
        # to relay through — services/coturn.sh never sets
        # --allow-loopback-peers, so -e 127.0.0.1 gets rejected with
        # "channel bind: error 403 (Forbidden IP)" (also confirmed live,
        # against a real local coturn instance built to test this exact
        # invocation). -y ("client-to-client") sidesteps this entirely: it
        # negotiates both ends of a real relay through the server itself,
        # no separate peer needed, and works fine over loopback since nothing
        # about it is treated as an external peer address. Confirmed against
        # a real coturn instance: -y correctly reports success (exit 0, real
        # packet-loss stats) with valid credentials and correctly fails
        # ("Cannot complete Allocation", exit 255) with a wrong password —
        # a real pass/fail signal, not just "didn't crash."
        OUT="$(docker exec "$COTURN_CONTAINER" timeout 10 turnutils_uclient -u "$TURN_USERNAME" -w "$TURN_PASSWORD" -y 127.0.0.1 -p "${TURN_PORT:-3478}" 2>&1)"
        if [ $? -eq 0 ]; then
            ok "Live TURN allocation succeeded with Asterisk's own configured credentials (user '$TURN_USERNAME')"
        else
            fail "Live TURN allocation FAILED with Asterisk's configured credentials — raw output:"
            echo "$OUT" | tail -n 15 | sed 's/^/         /'
        fi
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

# ── Softphone setup (Sipnetic or any SIP client) ──────────────────────────────
# Same data the Security Dashboard's per-extension "info" panel shows
# (showEaDeviceDetails in services/security-dashboard.sh), read directly from
# pjsip.conf here so this is useful even without the dashboard installed.
# Passwords are read from the live config on this box, not regenerated —
# printing them is exactly as sensitive as the dashboard's own info panel.
section "Softphone setup — one block per extension (password shown, handle accordingly)"

DOMAIN_NAME=""
[ -f "$EA_DIR/.env" ] && DOMAIN_NAME="$(grep -E '^DOMAIN_NAME=' "$EA_DIR/.env" | cut -d= -f2-)"
SIP_SERVER="${DOMAIN_NAME:-${PUBLIC_IP:-<could not auto-detect this box IP>}}"

PJSIP_CONF="$ASTERISK_DIR/pjsip.conf"
if [ ! -f "$PJSIP_CONF" ]; then
    warn "pjsip.conf not found at $PJSIP_CONF — can't print softphone settings"
else
    DEVICE_INFO="$(awk '
        /^\[[0-9]+\]$/ { ext = substr($0, 2, length($0)-2); cur_type=""; next }
        /^type=endpoint/ { cur_type="endpoint"; next }
        /^type=auth/ { cur_type="auth"; next }
        /^type=aor/ { cur_type="aor"; next }
        cur_type=="endpoint" && /^transport=/ { split($0,a,"="); transport[ext]=a[2] }
        cur_type=="endpoint" && /^ice_support=yes/ { ice[ext]="yes" }
        cur_type=="auth" && /^password=/ { split($0,a,"="); pass[ext]=a[2] }
        END {
            for (e in pass) printf "%s|%s|%s|%s\n", e, pass[e], transport[e], (ice[e] ? ice[e] : "no")
        }
    ' "$PJSIP_CONF" | sort)"

    if [ -z "$DEVICE_INFO" ]; then
        warn "No devices found in pjsip.conf"
    else
        while IFS='|' read -r ext pass transport ice; do
            [ -z "$ext" ] && continue
            print_ext_info "$ext" "$pass" "$transport" "$ice"
            echo ""
        done <<< "$DEVICE_INFO"
        ok "Printed setup info for $(wc -l <<< "$DEVICE_INFO") extension(s) — same values Sipnetic's"
        ok "'Add Account' screen (or the dashboard's QR code / Download settings) needs"
    fi
fi

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
        echo ""
        echo "  Once that's saved: text ${TRUNK_DID:-this DID} from any OTHER phone (not a"
        echo "  softphone registered to this Asterisk — an outside cell number), then watch:"
        echo "    journalctl -u sms-inbound -f"
        echo "  It should land in Sipnetic (or whichever softphone owns that DID/extension)"
        echo "  within a few seconds. See docs/pstn-sms-test-checklist.md §10 if it doesn't."
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

if [ "${#FAIL_MSGS[@]}" -gt 0 ] || [ "${#WARN_MSGS[@]}" -gt 0 ]; then
    echo ""
    echo "  Needs attention:"
    for m in "${FAIL_MSGS[@]:-}"; do
        [ -z "$m" ] && continue
        echo "   [FAIL] $m"
    done
    for m in "${WARN_MSGS[@]:-}"; do
        [ -z "$m" ] && continue
        echo "   [WARN] $m"
    done
fi

echo ""
echo "  This covers everything that can be checked without placing a real call"
echo "  or sending a real text, plus the provider-side values above that only a"
echo "  human can confirm inside the portal itself. For the call/SMS test steps"
echo "  and what each result means, see docs/pstn-sms-test-checklist.md."

# ── Optional: reprint softphone setup one extension at a time ────────────────
# The full setup block scrolled past earlier in a long run — offer to show
# it again, one extension per screen, instead of scrolling back for it.
if [ -n "${DEVICE_INFO:-}" ] && [ -t 0 ]; then
    echo ""
    REPRINT=""
    read -r -p "  Show softphone setup again, one extension at a time? (y/n): " REPRINT
    if [[ "$REPRINT" =~ ^[Yy]$ ]]; then
        while IFS='|' read -r ext pass transport ice; do
            [ -z "$ext" ] && continue
            echo ""
            print_ext_info "$ext" "$pass" "$transport" "$ice"
            read -r -p "  Press Enter for the next extension (Ctrl+C to stop)..." _ignored
        done <<< "$DEVICE_INFO"
    fi
fi

[ "$FAIL" -eq 0 ]
