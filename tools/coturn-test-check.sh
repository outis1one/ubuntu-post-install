#!/usr/bin/env bash
# tools/coturn-test-check.sh — Health-check for the shared coturn (TURN/STUN)
# instance services/coturn.sh sets up, and every consumer registered against
# it (Asterisk, one or more Mattermost instances, anything else added via
# ensure_coturn_user() in lib/common.sh).
#
# Checks: container up, identity/.env readable, every registered consumer
# actually exists in coturn's own user database (not just a cached
# users/<name>.env file — the two can drift, e.g. a container recreated from
# an older image/db), UFW has the TURN port + relay range open, and — the
# part nothing else in this repo does — a REAL TURN allocation test per
# consumer via turnutils_uclient (bundled in the coturn/coturn image), which
# is the only way to prove credentials + port range + firewall all actually
# work together end to end, not just that each piece looks right in isolation.
#
# Does NOT attempt a concurrent load test (e.g. opening dozens of allocations
# at once) — that would consume real relay ports on a server other services
# may be actively using. See "Capacity" in the output for how the port range
# bounds concurrent capacity, reasoned from the numbers instead of guessed at.
#
# Usage:
#   sudo bash tools/coturn-test-check.sh
#
# Safe to run any time — the one allocation test per consumer opens and
# immediately releases a single relay port, the same as a single real call
# briefly would.

set -uo pipefail

PASS=0
WARN=0
FAIL=0

ok()   { printf '  [OK]   %s\n' "$1"; PASS=$((PASS + 1)); }
warn() { printf '  [WARN] %s\n' "$1"; WARN=$((WARN + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s ==\n' "$1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo — needs docker exec." >&2
    exec sudo bash "$0" "$@"
fi

ACTUAL_USER="${SUDO_USER:-${USER:-root}}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "/root")"
DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
COTURN_DIR="$DOCKER_DIR/coturn"

# ── Container + identity ──────────────────────────────────────────────────────
section "Detecting install"

if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx coturn; then
    fail "No running 'coturn' container found — is services/coturn.sh installed and started?"
    echo ""
    echo "  $PASS passed, $WARN warnings, $FAIL failed. Stopping."
    exit 1
fi
ok "Container running: coturn"

if [ ! -f "$COTURN_DIR/.env" ]; then
    fail "$COTURN_DIR/.env not found — can't read realm/host/port range."
    exit 1
fi
set +u
# shellcheck disable=SC1090
source "$COTURN_DIR/.env"
set -u
COTURN_REALM="${COTURN_REALM:-}"
COTURN_HOST="${COTURN_HOST:-}"
COTURN_PORT="${COTURN_PORT:-3478}"
COTURN_MIN_PORT="${COTURN_MIN_PORT:-49152}"
COTURN_MAX_PORT="${COTURN_MAX_PORT:-49452}"
ok "Realm: ${COTURN_REALM:-<unset>}   Host: ${COTURN_HOST:-<unset>}   Port: $COTURN_PORT"
ok "Relay port range: ${COTURN_MIN_PORT}-${COTURN_MAX_PORT}"

# ── Registered consumers ──────────────────────────────────────────────────────
section "Registered consumers"

DB_USERS="$(docker exec coturn turnadmin -l -b /var/lib/coturn/turndb 2>/dev/null | sed -E 's/\[.*//' | awk 'NF' | sort -u)"
if [ -z "$DB_USERS" ]; then
    warn "No users found in coturn's own database — nothing has actually registered yet, or turnadmin -l's output format changed. Raw:"
    docker exec coturn turnadmin -l -b /var/lib/coturn/turndb 2>&1 | sed 's/^/         /'
fi

CACHED_CONSUMERS=()
if [ -d "$COTURN_DIR/users" ]; then
    while IFS= read -r f; do
        CACHED_CONSUMERS+=("$(basename "$f" .env)")
    done < <(find "$COTURN_DIR/users" -maxdepth 1 -name '*.env' -type f 2>/dev/null | sort)
fi

if [ "${#CACHED_CONSUMERS[@]}" -eq 0 ]; then
    warn "No cached consumer credentials in $COTURN_DIR/users — nothing has registered via ensure_coturn_user() yet."
else
    for c in "${CACHED_CONSUMERS[@]}"; do
        if grep -qx "$c" <<< "$DB_USERS"; then
            ok "Consumer '$c' — cached credentials present AND found in coturn's live database"
        else
            fail "Consumer '$c' has a cached users/${c}.env but is NOT in coturn's database — its calls will fail 401 Unauthorized. Likely cause: the coturn container/volume was recreated without preserving ./db. Fix: sudo docker exec coturn turnadmin -a -u $c -p <password from users/${c}.env> -r $COTURN_REALM -b /var/lib/coturn/turndb"
        fi
    done
fi

# Flag anything in the live DB with no cached file too — orphaned/manually
# added users aren't wrong, just worth knowing about.
while IFS= read -r u; do
    [ -z "$u" ] && continue
    found=false
    for c in "${CACHED_CONSUMERS[@]:-}"; do [ "$c" = "$u" ] && found=true && break; done
    [ "$found" = false ] && warn "Database has user '$u' with no matching users/${u}.env — added manually, or a leftover from a removed service."
done <<< "$DB_USERS"

# ── Firewall ───────────────────────────────────────────────────────────────────
section "Firewall (UFW)"
if command -v ufw &>/dev/null; then
    UFW_STATUS="$(ufw status 2>/dev/null)"
    if grep -qE "^${COTURN_PORT}(/udp|/tcp)?\b.*ALLOW" <<< "$UFW_STATUS"; then
        ok "TURN listening port ${COTURN_PORT} allowed"
    else
        fail "TURN listening port ${COTURN_PORT} not found in 'ufw status' — clients may not reach it"
    fi
    if grep -qE "^${COTURN_MIN_PORT}:${COTURN_MAX_PORT}/udp\b.*ALLOW" <<< "$UFW_STATUS"; then
        ok "Relay port range ${COTURN_MIN_PORT}-${COTURN_MAX_PORT}/udp allowed"
    else
        fail "Relay port range ${COTURN_MIN_PORT}-${COTURN_MAX_PORT}/udp not found in 'ufw status' — allocated relay ports would be unreachable, breaking media even after a successful TURN allocation"
    fi
else
    warn "ufw not installed — can't confirm the relay range is actually open (may be fine if this box has no firewall, or one outside UFW)"
fi

# ── Capacity ───────────────────────────────────────────────────────────────────
section "Capacity"
RANGE_SIZE=$((COTURN_MAX_PORT - COTURN_MIN_PORT + 1))
CONSUMER_COUNT="${#CACHED_CONSUMERS[@]}"
echo "  Relay range holds ${RANGE_SIZE} ports. Each concurrent relayed call/leg typically"
echo "  uses one allocation (roughly one port) for its lifetime — released when the call"
echo "  ends, not held permanently. With ${CONSUMER_COUNT} registered consumer(s), the range"
echo "  would need all of them to have ~$((RANGE_SIZE / (CONSUMER_COUNT > 0 ? CONSUMER_COUNT : 1))) simultaneous relayed calls each, at the same"
echo "  moment, before it runs out — for Asterisk + a handful of Mattermost instances at"
echo "  personal/small-team scale, that ceiling is not realistically reachable in normal"
echo "  use. If you ever DO expect that much simultaneous WebRTC/SIP relay traffic, raise"
echo "  COTURN_MIN_PORT/COTURN_MAX_PORT in $COTURN_DIR/.env, update the matching UFW rule,"
echo "  and restart coturn — no consumer reconfiguration needed, they don't cache the range."
echo ""
echo "  Note: not every call needs a TURN relay at all — TURN is the FALLBACK when two"
echo "  peers can't reach each other directly (STUN/ICE finds a direct path first when"
echo "  possible). Real relay usage is usually well below \"every concurrent call.\""

# ── Real allocation test per consumer ─────────────────────────────────────────
section "Live allocation test (one real TURN allocation per registered consumer)"
if ! docker exec coturn which turnutils_uclient &>/dev/null; then
    warn "turnutils_uclient not found in the coturn image — skipping live allocation tests."
else
    TEST_HOST="${COTURN_HOST:-127.0.0.1}"
    for c in "${CACHED_CONSUMERS[@]:-}"; do
        [ -z "$c" ] && continue
        _u="$(grep '^COTURN_USER=' "$COTURN_DIR/users/${c}.env" 2>/dev/null | cut -d= -f2-)"
        _p="$(grep '^COTURN_PASS=' "$COTURN_DIR/users/${c}.env" 2>/dev/null | cut -d= -f2-)"
        if [ -z "$_u" ] || [ -z "$_p" ]; then
            warn "$c: couldn't read cached credentials, skipping live test"
            continue
        fi
        # Plain UDP only — no -t/-T (TCP/TLS) flags; coturn runs with
        # --no-tls --no-dtls (services/coturn.sh), so requesting an
        # encrypted/TCP transport here fails the allocation against a
        # server that never offered one. See tools/pstn-test-check.sh's
        # matching comment — confirmed live this was the actual cause of a
        # "Cannot complete Allocation" failure, not a real coturn problem.
        #
        # -y ("client-to-client"), not -e <peer>: turnutils_uclient refuses
        # to run at all without one of the two ("Either -e peer_address or
        # -y must be specified", confirmed live), but -e needs an actual
        # reachable, non-loopback peer — services/coturn.sh never sets
        # --allow-loopback-peers, so -e 127.0.0.1 gets rejected with
        # "channel bind: error 403 (Forbidden IP)" (confirmed live against
        # a real local coturn instance built specifically to test this).
        # -y negotiates both ends of a real relay through the server
        # itself, no separate peer needed, and works over loopback —
        # confirmed correctly reporting success (exit 0, real packet-loss
        # stats) with valid credentials and failure ("Cannot complete
        # Allocation", exit 255) with a wrong password.
        OUT="$(docker exec coturn timeout 10 turnutils_uclient -u "$_u" -w "$_p" -y "$TEST_HOST" -p "$COTURN_PORT" 2>&1)"
        RC=$?
        if [ "$RC" -eq 0 ]; then
            ok "$c: TURN allocation succeeded (credentials + relay range + reachability all confirmed working)"
        else
            fail "$c: TURN allocation failed (exit $RC) — raw output:"
            echo "$OUT" | tail -n 15 | sed 's/^/         /'
        fi
    done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary"
echo "  $PASS passed, $WARN warnings, $FAIL failed."
echo ""
echo "  A passing allocation test here proves TURN works end to end for that consumer."
echo "  It does NOT by itself prove Asterisk or Mattermost are actually configured to USE"
echo "  it — check each service's own .env for TURN_HOST/TURN_USERNAME (asterisk.sh) or"
echo "  the Calls plugin's ICE Servers Configurations (mattermost.sh) matches what's"
echo "  printed above, then place a real call from outside the LAN (the case TURN"
echo "  actually exists for — two peers on the same LAN usually connect directly and never"
echo "  touch the relay at all, so a same-LAN test call proves nothing about TURN)."

[ "$FAIL" -eq 0 ]
