#!/bin/bash
# services/sms-inbound.sh — Inbound SMS from a VoIP DID → ntfy push notification.
# Part of the modular post-install system (sourced by setup.sh).
#
# Built for one specific job: getting SMS **verification codes** sent to a
# VoIP number onto a phone that has no SIM. It deliberately does not try to be
# a texting app. Sending is not handled here at all (see the README this
# writes for why), and inbound messages arrive as push notifications rather
# than being routed into Asterisk as SIP MESSAGE — a code you need to read and
# type is better served by a notification than by a chat thread buried in a
# softphone.
#
# Two modes, both configured entirely from the DID provider's own "forward
# incoming SMS to a URL" setting:
#
#   direct — the provider calls ntfy itself. No server component at all; the
#            installer just prints the URL to paste into the provider portal.
#   relay  — a small systemd HTTP service on this box receives the provider's
#            request and re-publishes to ntfy properly. Costs one more moving
#            part, and buys correct handling of messages containing "&", a
#            secret that isn't your ntfy token, and no ntfy credentials stored
#            in a third party's web portal.
#
# No standalone bootstrap block here, matching services/pstn-trunk.sh — this
# is an add-on for a box the repo already set up, not something you'd curl
# onto a bare machine on its own.

register_service sms-inbound homelab "Inbound SMS (verification codes) from a VoIP DID → ntfy push" 8093

SMS_APP_DIR="/opt/sms-inbound"
SMS_SETTINGS="$SMS_APP_DIR/settings.env"
SMS_SVC_USER="smsrelay"

# ── ntfy target discovery ──────────────────────────────────────────────────
# A locally-installed ntfy (services/ntfy.sh) is the right default: it keeps
# verification codes on hardware you control instead of a public relay. Its
# base-url is the one authoritative place to read the reachable hostname from,
# since that's what ntfy itself uses to build notification links.
_sms_detect_ntfy_base() {
    local _cfg="$DOCKER_DIR/ntfy/config/server.yml"
    [[ -f "$_cfg" ]] || return 1
    local _url
    _url="$(grep -oP '(?<=base-url: ")[^"]+' "$_cfg" 2>/dev/null || true)"
    [[ -n "$_url" && "$_url" != "https://ntfy.example.com" ]] || return 1
    echo "$_url"
}

# ── The relay ──────────────────────────────────────────────────────────────
# Stdlib only, same reasoning as services/security-dashboard.sh: this shares a
# small droplet with Asterisk, Caddy and CrowdSec and shouldn't cost a
# framework's worth of RAM to forward a few dozen text messages a month.
_sms_write_relay_app() {
    local _dir="$1"
    mkdir -p "$_dir"
    cat > "$_dir/relay.py" << 'PYRELAY'
#!/usr/bin/env python3
"""Inbound SMS webhook -> ntfy push.

Receives the HTTP request a DID provider makes when an SMS arrives (Anveo
issues a plain GET with the message interpolated into the query string) and
re-publishes it to ntfy as a POST, which is the part the provider can't do
itself.

Deliberately minimal: one path, one secret, no state, no database.
"""
import hmac
import os
import time
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SMS_RELAY_PORT", "8093"))
TOKEN = os.environ.get("SMS_RELAY_TOKEN", "")
NTFY_URL = os.environ.get("SMS_NTFY_URL", "")
NTFY_TOKEN = os.environ.get("SMS_NTFY_TOKEN", "")
NTFY_PRIORITY = os.environ.get("SMS_NTFY_PRIORITY", "high")

# The token is the only thing standing between the public internet and your
# push topic, so cap how fast anyone can hammer it. Well above any real SMS
# volume; low enough that a leaked URL can't be used to spam the phone.
RATE_LIMIT = 60          # requests
RATE_WINDOW = 60         # seconds
_hits = deque()


def rate_limited():
    now = time.monotonic()
    while _hits and now - _hits[0] > RATE_WINDOW:
        _hits.popleft()
    if len(_hits) >= RATE_LIMIT:
        return True
    _hits.append(now)
    return False


def extract_message(query):
    """Pull the message body out of the raw query string.

    Not parse_qs: providers interpolate the message text into the URL without
    escaping it, so a body containing "&" (very common in marketing footers —
    "Reply STOP & we'll remove you") splits into extra parameters and the
    message silently truncates at the ampersand. Taking everything after the
    LAST "message=" verbatim sidesteps that entirely, which is why the URL
    this installer prints always puts the message parameter last.
    """
    for key in ("message=", "text=", "body="):
        idx = query.rfind(key)
        if idx != -1:
            return urllib.parse.unquote_plus(query[idx + len(key):])
    return ""


def extract_param(query, name):
    """Ordinary parse for the numeric fields, which never contain '&'."""
    # Stop at the message so its contents can't be mistaken for parameters.
    head = query
    for key in ("message=", "text=", "body="):
        idx = head.rfind(key)
        if idx != -1:
            head = head[:idx]
    values = urllib.parse.parse_qs(head).get(name, [])
    return values[0] if values else ""


def publish(sender, recipient, message):
    title = "SMS from {}".format(sender or "unknown")
    if recipient:
        title += " to {}".format(recipient)
    req = urllib.request.Request(
        NTFY_URL,
        data=message.encode("utf-8"),
        method="POST",
        headers={
            "Title": title,
            "Priority": NTFY_PRIORITY,
            "Tags": "incoming_envelope",
            "Content-Type": "text/plain; charset=utf-8",
        },
    )
    if NTFY_TOKEN:
        req.add_header("Authorization", "Bearer " + NTFY_TOKEN)
    with urllib.request.urlopen(req, timeout=10) as resp:
        return 200 <= resp.status < 300


class Handler(BaseHTTPRequestHandler):
    def _respond(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _handle(self):
        path, _, query = self.path.partition("?")
        # Constant-time compare: the token is a secret, and a naive ==
        # leaks its prefix to anyone willing to time enough requests.
        if not TOKEN or not hmac.compare_digest(path.rstrip("/"), "/sms/" + TOKEN):
            self._respond(404)
            return
        if rate_limited():
            self._respond(429)
            return

        message = extract_message(query)
        sender = extract_param(query, "from")
        recipient = extract_param(query, "to")
        if not message:
            self._respond(400)
            return

        try:
            ok = publish(sender, recipient, message)
        except Exception as exc:                      # noqa: BLE001
            print("publish failed: {}".format(exc), flush=True)
            self._respond(502)
            return

        # Never log the body: these are one-time passcodes, and the journal is
        # readable by more people than the push notification is.
        print("sms from={} to={} chars={} published={}".format(
            sender or "?", recipient or "?", len(message), ok), flush=True)
        self._respond(204 if ok else 502)

    def do_GET(self):
        self._handle()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        if length:
            self.rfile.read(length)
        self._handle()

    def log_message(self, fmt, *args):
        pass  # the journal already has what we print above


def main():
    if not NTFY_URL or not TOKEN:
        raise SystemExit("SMS_NTFY_URL and SMS_RELAY_TOKEN must both be set")
    ThreadingHTTPServer.allow_reuse_address = True
    # 0.0.0.0, not loopback: Caddy runs in a container and reaches this over
    # the Docker bridge gateway, which a loopback-only bind refuses. Access is
    # scoped by UFW and by the token in the path, not by the bind address —
    # same pattern services/security-dashboard.sh uses.
    with ThreadingHTTPServer(("0.0.0.0", PORT), Handler) as httpd:
        print("sms-inbound relay listening on 0.0.0.0:{}".format(PORT), flush=True)
        httpd.serve_forever()


if __name__ == "__main__":
    main()
PYRELAY
    chmod 755 "$_dir/relay.py"
}

_sms_write_systemd_unit() {
    local _port="$1" _token="$2" _ntfy_url="$3" _ntfy_token="$4"
    cat > /etc/systemd/system/sms-inbound.service << SMSSVC
[Unit]
Description=Inbound SMS webhook to ntfy relay
After=network.target

[Service]
Type=simple
User=$SMS_SVC_USER
Group=$SMS_SVC_USER
Environment=SMS_RELAY_PORT=$_port
Environment=SMS_RELAY_TOKEN=$_token
Environment=SMS_NTFY_URL=$_ntfy_url
Environment=SMS_NTFY_TOKEN=$_ntfy_token
ExecStart=/usr/bin/python3 $SMS_APP_DIR/relay.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
SMSSVC
    systemctl daemon-reload
}

# Own site block rather than configure_caddy_for_service, for two reasons the
# helper can't accommodate: this endpoint must NOT sit behind Authelia (the
# SMS provider can't log in), and the installer has to know the exact final
# URL to print for the provider portal, which the helper doesn't hand back.
# Everything else — HSTS/nosniff headers, JSON access log, reload-then-restart
# fallback — matches what the helper would have written.
_sms_configure_caddy() {
    local _domain="$1" _port="$2"
    local _caddyfile="$DOCKER_DIR/caddy/Caddyfile"

    local _site_block
    _site_block="$(cat << CBLOCK

# Inbound SMS webhook (sms-inbound) — deliberately NOT behind Authelia:
# the SMS provider calls this unauthenticated. The secret is the token in
# the request path, checked by the relay itself.
${_domain} {
    reverse_proxy host.docker.internal:${_port}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "no-referrer"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
}
CBLOCK
)"

    if [[ -f "$_caddyfile" ]]; then
        cp "$_caddyfile" "$_caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
    else
        touch "$_caddyfile"
    fi
    if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
        log_warning "${_domain} already in the Caddyfile — leaving the existing entry alone."
        return 0
    fi
    printf '%s\n' "$_site_block" >> "$_caddyfile"
    log_success "Added ${_domain} to the Caddyfile"
    docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
    if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
        :
    elif docker restart caddy &>/dev/null; then
        log_success "Caddy restarted to apply changes (the reload API is disabled by default)"
    else
        log_warning "Caddy reload/restart failed — check: docker logs caddy"
    fi
}

_sms_write_readme() {
    local _mode="$1" _url="$2" _ntfy_url="$3" _relay_domain="$4"
    write_readme "$SMS_APP_DIR" << MD
# Inbound SMS → ntfy

Gets SMS sent to a VoIP DID onto a phone as a push notification. Built for
**verification codes**, not for conversations.

Mode: **${_mode}**

## The URL to paste into your DID provider

In the provider portal, open the DID's SMS settings, choose "forward to URL"
and paste this:

\`\`\`
${_url}
\`\`\`

Keep the message placeholder **last** in that URL. Providers interpolate the
message text without escaping it, so a body containing \`&\` splits into extra
query parameters; with the message last, everything after it can be read back
verbatim.

Treat this URL like a password — anyone holding it can push notifications to
your phone.

## What this does not do

- **Sending.** There's no outbound path here. On Anveo, outbound SMS needs an
  Anveo *Retail* account rather than Anveo Direct; a free texting app covers
  the sending side without involving this box at all.
- **MMS.** No VoIP provider delivers MMS over SIP, and MMS to a VoIP DID
  generally either drops or arrives as a media link through a separate API.
  US **group texts are MMS**, so expect to miss those entirely.
- **Native Messages integration.** Android's Messages app reads the telephony
  SMS provider, which only the cellular radio (or the default SMS app) writes
  to; iOS lets nothing write to Messages. Codes arrive as ntfy notifications,
  which for a passcode you're about to type is the more useful place anyway.

## Will verification codes actually arrive?

Two separate hurdles, both outside this box:

1. **Short codes.** Most codes come from short codes (262966, 32665...).
   Anveo supports short-code SMS to its DIDs, which is unusual — VoIP.ms, for
   example, does not except for Google. Check that short codes are enabled on
   your specific DID; not every number in the pool has it.
2. **VoIP rejection at signup.** Many services refuse a number their lookup
   flags as VoIP, before any SMS is sent. Anveo also sells **mobile** DIDs,
   sourced from wireless carriers, which are classified as mobile in the
   industry databases those checks use — a much better bet for this purpose
   than a geographic landline-class DID, at a higher monthly price. If codes
   are the whole reason for the number, order a mobile one.

## Security

Verification codes are bearer credentials for your accounts. Two things
matter:

- **The ntfy topic is a secret.** This installer generated a long random topic
  name, which makes it unguessable, but the repo's ntfy defaults to
  \`auth-default-access: read-write\` — anyone who *learns* the name can read
  it. Adding an ntfy access token and restricting the topic is worthwhile:
  \`\`\`bash
  docker exec -it ntfy ntfy access                   # show current rules
  docker exec -it ntfy ntfy user add --role=user reader
  docker exec -it ntfy ntfy access reader '<topic>' read-only
  docker exec -it ntfy ntfy access '*' '<topic>' deny
  \`\`\`
- **Don't publish to a public relay.** \`ntfy.sh\` topics are readable by
  anyone who knows the name; a self-hosted instance keeps codes on your own
  hardware.

Current ntfy target: \`${_ntfy_url}\`

## Manage

\`\`\`bash
systemctl status sms-inbound       # relay mode only
journalctl -u sms-inbound -f       # from/to and length, never the message body
sudo ./setup.sh sms-inbound        # re-run to change settings
\`\`\`

The relay logs who sent what and how long it was, deliberately never the
message itself — the journal has a wider audience than the notification does.

$( [[ -n "$_relay_domain" ]] && printf 'Public endpoint: `https://%s` (Caddy → the relay on this box).\n' "$_relay_domain" )

## Testing it

Substitute a real message for the provider's placeholder and call the URL
yourself — no need to wait for a text:

\`\`\`bash
curl -s -o /dev/null -w '%{http_code}\\n' \\
  "$(printf '%s' "$_url" | sed 's/\$\[from\]\$/15555550123/; s/\$\[to\]\$/15555550199/; s/\$\[message\]\$/test+code+123456/')"
\`\`\`

$( if [[ "$_mode" == "relay" ]]; then cat << 'RELAYTEST'
**204** means the relay accepted it and ntfy took the message — your phone
should buzz. **404** means the token in the path is wrong, **502** means ntfy
rejected the publish (check the ntfy token and topic), **429** means the rate
limit tripped (60 requests/minute).
RELAYTEST
else cat << 'DIRECTTEST'
**200** means ntfy accepted the publish and your phone should buzz. **401**
or **403** means the `auth=` parameter is wrong or the topic is restricted;
**404** means the topic URL is malformed.
DIRECTTEST
fi )
MD
}

install_sms-inbound() {
    log_info "Setting up inbound SMS → ntfy..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would detect a local ntfy install and reuse its base-url, or prompt for one"
        echo "[DRY-RUN] Would generate a long random ntfy topic (verification codes must not land"
        echo "[DRY-RUN]   on a guessable topic — the repo's ntfy defaults to read-write access)"
        echo "[DRY-RUN] Would offer two modes:"
        echo "[DRY-RUN]   direct — print a provider 'forward SMS to URL' string pointing straight"
        echo "[DRY-RUN]            at ntfy; no server component installed"
        echo "[DRY-RUN]   relay  — install $SMS_APP_DIR/relay.py as a systemd service, front it with"
        echo "[DRY-RUN]            Caddy on a domain you'll be prompted for (no Authelia — the SMS"
        echo "[DRY-RUN]            provider can't log in; a random token in the path is the secret),"
        echo "[DRY-RUN]            and open the port to caddy_net only"
        echo "[DRY-RUN] Would print the exact URL to paste into the DID provider's SMS settings"
        echo "[DRY-RUN] Would write $SMS_APP_DIR/README.md covering short codes, mobile DIDs, MMS"
        echo "[DRY-RUN]   and why the native Messages app never sees these"
        return 0
    fi

    # ── Existing install? ─────────────────────────────────────────────────────
    if [[ -f "$SMS_SETTINGS" ]]; then
        echo ""
        log_info "Existing sms-inbound configuration found at $SMS_SETTINGS."
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                # shellcheck disable=SC1090
                source "$SMS_SETTINGS"
                if [[ "${SMS_MODE:-}" == "relay" ]]; then
                    _sms_write_relay_app "$SMS_APP_DIR"
                    chown -R "$SMS_SVC_USER:$SMS_SVC_USER" "$SMS_APP_DIR" 2>/dev/null || true
                    _sms_write_systemd_unit "${SMS_RELAY_PORT}" "${SMS_RELAY_TOKEN}" "${SMS_NTFY_URL}" "${SMS_NTFY_TOKEN:-}"
                    systemctl restart sms-inbound \
                        && log_success "Relay refreshed and restarted." \
                        || log_warning "Restart failed — check: journalctl -u sms-inbound -n 50"
                else
                    log_info "Direct mode — nothing to refresh on this box."
                fi
                echo ""
                log_success "Settings, Caddy and firewall rules were left untouched."
                echo "  Provider URL: ${SMS_FORWARD_URL}"
                echo ""
                return 0
                ;;
            cancel)
                log_info "Leaving the existing setup as-is — nothing changed."
                return 0
                ;;
            fresh) log_info "Reconfiguring from scratch — every prompt below runs again." ;;
        esac
    fi

    # ── ntfy target ───────────────────────────────────────────────────────────
    echo ""
    local NTFY_BASE=""
    if NTFY_BASE="$(_sms_detect_ntfy_base)"; then
        log_success "Found a configured local ntfy at $NTFY_BASE — using it."
        log_info "Self-hosted is the right answer here: these are verification codes."
    else
        log_warning "No configured local ntfy found (services/ntfy.sh installs one)."
        log_warning "A public relay like ntfy.sh works, but its topics are readable by anyone"
        log_warning "who learns the name — a poor place for one-time passcodes."
        prompt_text "ntfy base URL [https://ntfy.sh]:" "https://ntfy.sh" NTFY_BASE
    fi
    NTFY_BASE="${NTFY_BASE%/}"

    # A long random topic, not "sms": with ntfy's default read-write access the
    # topic name IS the read credential, so it needs real entropy rather than
    # something guessable.
    local NTFY_TOPIC=""
    NTFY_TOPIC="sms-$(generate_password 24)"
    log_info "Generated ntfy topic: $NTFY_TOPIC"
    log_info "Subscribe to it in the ntfy app — that's where codes will appear."

    local NTFY_TOKEN_VAL=""
    prompt_text "ntfy access token, if your instance requires one for publishing [blank=none]:" "" NTFY_TOKEN_VAL

    local NTFY_TOPIC_URL="${NTFY_BASE}/${NTFY_TOPIC}"

    # ── Mode ──────────────────────────────────────────────────────────────────
    echo ""
    echo "  How should the provider reach ntfy?"
    echo "    1) Relay (recommended) — a small service here receives the provider's"
    echo "                             request and republishes properly. Handles '&' in"
    echo "                             message bodies, and your ntfy token never gets"
    echo "                             stored in the provider's web portal."
    echo "    2) Direct               — the provider calls ntfy itself. Nothing installed"
    echo "                             on this box, but the URL you paste into the portal"
    echo "                             carries your ntfy credentials, and a message"
    echo "                             containing '&' truncates."
    local MODE_CHOICE=""
    prompt_text "Choose [1]:" "1" MODE_CHOICE

    mkdir -p "$SMS_APP_DIR"
    local SMS_MODE="relay" FORWARD_URL="" RELAY_DOMAIN="" RELAY_PORT="" RELAY_TOKEN=""

    if [[ "$MODE_CHOICE" == "2" ]]; then
        SMS_MODE="direct"
        # ntfy accepts publishing over GET at /{topic}/(publish|send|trigger),
        # reading message/title from the query string — which is exactly the
        # shape a provider's "forward to URL" feature can produce. Auth, when
        # needed, rides in ?auth= as base64url (no padding) of the literal
        # Authorization header value.
        local _auth_q=""
        if [[ -n "$NTFY_TOKEN_VAL" ]]; then
            _auth_q="&auth=$(printf 'Bearer %s' "$NTFY_TOKEN_VAL" | basenc --base64url 2>/dev/null | tr -d '=' \
                || printf 'Bearer %s' "$NTFY_TOKEN_VAL" | base64 | tr '+/' '-_' | tr -d '=\n')"
        fi
        # Message placeholder LAST, so a body containing '&' loses only the
        # tail rather than corrupting the title or the auth parameter.
        FORWARD_URL="${NTFY_BASE}/${NTFY_TOPIC}/trigger?title=SMS+from+\$[from]\$&priority=high${_auth_q}&message=\$[message]\$"
    else
        # ── Relay ─────────────────────────────────────────────────────────────
        id -u "$SMS_SVC_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$SMS_SVC_USER"

        RELAY_PORT=8093
        local _limit=$((RELAY_PORT + 100))
        while ss -tlnH "sport = :${RELAY_PORT}" 2>/dev/null | grep -q . && [[ "$RELAY_PORT" -lt "$_limit" ]]; do
            RELAY_PORT=$((RELAY_PORT + 1))
        done
        [[ "$RELAY_PORT" != 8093 ]] && log_info "Port 8093 was taken — the relay will use ${RELAY_PORT}."

        RELAY_TOKEN="$(generate_password 32)"

        _sms_write_relay_app "$SMS_APP_DIR"
        chown -R "$SMS_SVC_USER:$SMS_SVC_USER" "$SMS_APP_DIR"
        _sms_write_systemd_unit "$RELAY_PORT" "$RELAY_TOKEN" "$NTFY_TOPIC_URL" "$NTFY_TOKEN_VAL"
        systemctl enable --now sms-inbound >/dev/null 2>&1 \
            && log_success "Relay service started on port ${RELAY_PORT}." \
            || log_warning "Relay failed to start — check: journalctl -u sms-inbound -n 50"

        # The provider calls this from the public internet, so it needs a real
        # certificate — providers generally refuse self-signed targets.
        echo ""
        local _default_domain=""
        [[ -n "${SITE_DOMAIN:-}" && "$SITE_DOMAIN" != "example.com" ]] && _default_domain="sms.${SITE_DOMAIN}"
        prompt_text "Public domain for the webhook (A record must point here) [${_default_domain:-required}]:" "$_default_domain" RELAY_DOMAIN

        if [[ -z "$RELAY_DOMAIN" ]]; then
            log_warning "No domain entered — the relay is running but nothing can reach it yet."
            log_warning "Re-run this service once DNS is ready, or front it with Caddy by hand."
        elif [[ -d "$DOCKER_DIR/caddy" ]]; then
            _sms_configure_caddy "$RELAY_DOMAIN" "$RELAY_PORT"
        else
            log_warning "Caddy isn't installed here — proxy https://${RELAY_DOMAIN} to"
            log_warning "127.0.0.1:${RELAY_PORT} yourself, with a real certificate."
        fi

        if command -v ufw &>/dev/null; then
            if [[ -d "$DOCKER_DIR/caddy" ]]; then
                # Caddy reaches this over the caddy_net bridge, so the port has
                # no business being open to the internet — but a bare `ufw
                # delete allow` would block Caddy too (see CLAUDE.md).
                ufw delete allow "${RELAY_PORT}/tcp" 2>/dev/null || true
                ufw_allow_from_caddy_net "${RELAY_PORT}"
            else
                ufw allow "${RELAY_PORT}/tcp"
            fi
            ensure_ufw_enabled
        fi

        FORWARD_URL="https://${RELAY_DOMAIN:-<your-domain>}/sms/${RELAY_TOKEN}?from=\$[from]\$&to=\$[to]\$&message=\$[message]\$"
    fi

    # ── Persist settings ──────────────────────────────────────────────────────
    cat > "$SMS_SETTINGS" << ENV
# Written by services/sms-inbound.sh — re-run that to change any of this.
SMS_MODE="${SMS_MODE}"
SMS_NTFY_URL="${NTFY_TOPIC_URL}"
SMS_NTFY_TOKEN="${NTFY_TOKEN_VAL}"
SMS_RELAY_PORT="${RELAY_PORT}"
SMS_RELAY_TOKEN="${RELAY_TOKEN}"
SMS_RELAY_DOMAIN="${RELAY_DOMAIN}"
# The exact string to paste into the DID provider's "forward SMS to URL" box.
# Secret: anyone holding it can push notifications to your phone.
SMS_FORWARD_URL="${FORWARD_URL}"
ENV
    chmod 600 "$SMS_SETTINGS"

    _sms_write_readme "$SMS_MODE" "$FORWARD_URL" "$NTFY_TOPIC_URL" "$RELAY_DOMAIN"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Inbound SMS → ntfy configured (${SMS_MODE} mode)."
    echo ""
    echo "  1. Subscribe to this topic in the ntfy app:"
    echo "       ${NTFY_TOPIC_URL}"
    echo ""
    echo "  2. In your DID provider's portal, open the number's SMS settings,"
    echo "     choose \"forward to URL\", and paste exactly:"
    echo ""
    echo "       ${FORWARD_URL}"
    echo ""
    echo "     Keep the message placeholder last — see the README for why."
    echo ""
    echo "  3. Text the number from another phone. The notification should"
    echo "     arrive within a few seconds."
    echo ""
    log_warning "That URL is a secret — anyone with it can push to your phone."
    if [[ "$SMS_MODE" == "direct" ]]; then
        log_warning "It also carries your ntfy credentials, because the provider talks to ntfy"
        log_warning "directly in this mode. Relay mode avoids that if you'd rather it didn't."
    fi
    echo "  Details, caveats and testing: $SMS_APP_DIR/README.md"
    echo ""
}
