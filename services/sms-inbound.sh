#!/bin/bash
# services/sms-inbound.sh — Inbound SMS from a VoIP DID, delivered into
# Asterisk as a SIP MESSAGE so it lands in Sipnetic (or any softphone with
# the internal texting feature) like a real text thread.
# Part of the modular post-install system (sourced by setup.sh).
#
# Was originally "SMS -> ntfy push", built for one-off verification codes.
# Confirmed live this session that the DID's own "SMS over SIP" delivery
# (Anveo's MESSAGE/INVITE-over-SIP option) simply isn't offered on this
# account/DID — the SMS tab only ever showed the HTTP "Forward to URL"
# option. So this reuses that exact same HTTP-webhook mechanism (proven
# working already) but changes what happens on receipt: instead of a push
# notification, the relay looks up which extension(s) own the destination
# DID (services/pstn-trunk.sh's personal-DID/Ring-Group ownership data —
# the SAME mapping inbound voice calls already use) and delivers the text
# to them via Asterisk's Manager Interface (AMI), the same way
# services/asterisk.sh's internal SIP MESSAGE texting already works
# end-to-end. ntfy is gone from this path entirely — deliberate, not an
# oversight, since the point now is a real two-way texting experience, not
# a one-way notification.
#
# Sending (SMS out to a real number) is NOT handled here — that's a
# separate, still-pending piece (see docs/anveo-direct-setup-guide.md's SMS
# section) blocked on the provider activating API-based sending, unrelated
# to this file. This file is inbound-only, the same as it always was.
#
# No standalone bootstrap block here, matching services/pstn-trunk.sh — this
# is an add-on for a box the repo already set up (specifically: needs
# services/asterisk.sh AND services/pstn-trunk.sh already installed, since
# it reads pstn-trunk's DID-ownership files and needs a live Asterisk to
# talk to over AMI), not something you'd curl onto a bare machine on its own.

register_service sms-inbound homelab "Inbound SMS from a VoIP DID, delivered into Asterisk (Sipnetic) via AMI" 8093

SMS_APP_DIR="/opt/sms-inbound"
SMS_SETTINGS="$SMS_APP_DIR/settings.env"
SMS_SVC_USER="smsrelay"

# ── Asterisk detection — same layout probe as services/pstn-trunk.sh and
# services/security-dashboard.sh, duplicated here rather than shared since
# there's no cross-service helper for it yet. Prefers the droplet layout if
# both happen to exist, for the same reason those two files do.
_sms_detect_ea_dir() {
    if [[ -d "$DOCKER_DIR/asterisk-digital-ocean" ]]; then
        echo "$DOCKER_DIR/asterisk-digital-ocean"
    elif [[ -d "$DOCKER_DIR/asterisk" ]]; then
        echo "$DOCKER_DIR/asterisk"
    fi
}

_sms_detect_container_name() {
    local _ea_dir="$1"
    if [[ "$_ea_dir" == *asterisk-digital-ocean ]]; then
        echo "easy-asterisk-do"
    else
        echo "easy-asterisk"
    fi
}

# ── AMI: a scoped manager.conf user, MessageSend only ───────────────────────
# Localhost-only (bindaddr + permit below) since the relay runs on this same
# host, not over the network — no firewall port to open for this. "message"
# is the AMI permission class MessageSend needs; this hasn't been confirmed
# against a live MessageSend call yet (see the relay's own comment on
# ami_deliver) — if the very first real delivery attempt gets an AMI
# permission error in the journal, widen read/write here first before
# looking anywhere else.
#
# Idempotent: creates manager.conf fresh if absent, otherwise ensures
# enabled=yes and the [smsrelay] section exist without disturbing anything
# else already in the file (this box's manager.conf isn't vendor-managed/
# regenerated the way pjsip.conf and rooms.conf are, so there's no
# "overwrite unconditionally" contract to honor or fight here).
_sms_write_manager_conf() {
    local _asterisk_dir="$1" _secret="$2"
    local _mgr="$_asterisk_dir/manager.conf"

    if [[ ! -f "$_mgr" ]]; then
        cat > "$_mgr" << MGR
; Written by services/sms-inbound.sh — the [smsrelay] section below is
; managed there (re-run that installer to rotate the secret). Anything
; else you add here by hand is left alone on future runs.
[general]
enabled = yes
port = 5038
bindaddr = 127.0.0.1
displayconnects = no

[smsrelay]
secret = ${_secret}
read = message
write = message
deny = 0.0.0.0/0
permit = 127.0.0.1/255.255.255.255
MGR
        echo "fresh"
        return 0
    fi

    local _changed=false
    if ! grep -q '^enabled[[:space:]]*=[[:space:]]*yes' "$_mgr"; then
        if grep -q '^\[general\]' "$_mgr"; then
            sed -i '/^\[general\]/a enabled = yes' "$_mgr"
        else
            printf '[general]\nenabled = yes\nport = 5038\nbindaddr = 127.0.0.1\n\n%s' "$(cat "$_mgr")" > "$_mgr.tmp" \
                && mv "$_mgr.tmp" "$_mgr"
        fi
        _changed=true
    fi
    if grep -q '^\[smsrelay\]' "$_mgr"; then
        sed -i "/^\[smsrelay\]/,/^\[/{s/^secret[[:space:]]*=.*/secret = ${_secret}/}" "$_mgr"
    else
        cat >> "$_mgr" << MGR

[smsrelay]
secret = ${_secret}
read = message
write = message
deny = 0.0.0.0/0
permit = 127.0.0.1/255.255.255.255
MGR
        _changed=true
    fi
    [[ "$_changed" == true ]] && echo "changed" || echo "unchanged"
}

# ── ACL grant: read-only access to pstn-trunk's DID-ownership files ────────
# Same technique services/security-dashboard.sh's _secdash_grant_asterisk_
# access uses, and the same reason: the Asterisk container's own entrypoint
# re-chowns /etc/asterisk to asterisk:asterisk on every restart, which plain
# chmod/group-membership grants don't survive but POSIX ACLs do (chown
# doesn't touch ACL entries). Read + traversal only — smsrelay never writes
# anything in this directory.
_sms_grant_asterisk_read_access() {
    local _svc_user="$1" _asterisk_dir="$2"
    command -v setfacl >/dev/null 2>&1 || run_cmd apt-get install -y acl >/dev/null 2>&1
    if ! command -v setfacl >/dev/null 2>&1; then
        log_warning "Package 'acl' unavailable — falling back to a one-time chmod, which can"
        log_warning "silently break again the next time the Asterisk container restarts and"
        log_warning "re-chowns its config directory. Install 'acl' and re-run to fix properly."
        chmod 755 "$_asterisk_dir" 2>/dev/null || true
        return 0
    fi

    local _dir
    _dir="$(dirname "$_asterisk_dir")"
    while [[ "$_dir" != "/" && -n "$_dir" ]]; do
        sudo -u "$_svc_user" test -x "$_dir" 2>/dev/null && break
        setfacl -m "u:${_svc_user}:x" "$_dir" 2>/dev/null || true
        _dir="$(dirname "$_dir")"
    done
    setfacl -R -m "u:${_svc_user}:rX" "$_asterisk_dir" 2>/dev/null || true
    setfacl -R -d -m "u:${_svc_user}:rX" "$_asterisk_dir" 2>/dev/null || true
}

# ── The relay ──────────────────────────────────────────────────────────────
# Stdlib only, same reasoning as services/security-dashboard.sh: this shares
# a small droplet with Asterisk, Caddy and CrowdSec and shouldn't cost a
# framework's worth of RAM to forward a few dozen text messages a month.
_sms_write_relay_app() {
    local _dir="$1"
    mkdir -p "$_dir"
    cat > "$_dir/relay.py" << 'PYRELAY'
#!/usr/bin/env python3
"""Inbound SMS webhook -> delivered into Asterisk as a SIP MESSAGE via AMI.

Receives the HTTP request a DID provider makes when an SMS arrives (Anveo
issues a plain GET with the message interpolated into the query string),
looks up which extension(s) currently own the destination DID (same
pstn-personal-dids.conf / pstn-groups.conf data services/pstn-trunk.sh's
own inbound-voice ring logic reads), and asks Asterisk over its Manager
Interface to deliver the text to each of them.

Deliberately minimal: one path, one secret, no state, no database, no
non-stdlib dependencies (same reasoning as services/security-dashboard.sh).
"""
import configparser
import hmac
import os
import re
import socket
import time
import urllib.parse
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("SMS_RELAY_PORT", "8093"))
TOKEN = os.environ.get("SMS_RELAY_TOKEN", "")
ASTERISK_CONFIG_DIR = os.environ.get("SMS_ASTERISK_CONFIG_DIR", "")
AMI_HOST = os.environ.get("SMS_AMI_HOST", "127.0.0.1")
AMI_PORT = int(os.environ.get("SMS_AMI_PORT", "5038"))
AMI_USER = os.environ.get("SMS_AMI_USER", "smsrelay")
AMI_SECRET = os.environ.get("SMS_AMI_SECRET", "")
SMS_DOMAIN = os.environ.get("SMS_DOMAIN", "")

# The token is the only thing standing between the public internet and this
# box's Asterisk. Well above any real SMS volume; low enough that a leaked
# URL can't be used to spam extensions or hammer the AMI connection.
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


def _normalize_did(raw):
    """10 or 11(leading-1) digit US number -> bare 10-digit, matching
    pstn-personal-dids.conf's section-name convention (see
    services/security-dashboard.sh's _normalize_personal_did_input)."""
    digits = re.sub(r"\D", "", raw or "")
    if len(digits) == 11 and digits.startswith("1"):
        digits = digits[1:]
    return digits if len(digits) == 10 else None


def _read_conf(path):
    cp = configparser.ConfigParser(delimiters=("=",))
    if path and os.path.isfile(path):
        try:
            cp.read(path)
        except configparser.Error:
            pass
    return cp


def resolve_recipients(to_raw):
    """Destination DID -> list of extensions that should receive this text.

    Single-extension ownership -> that one extension. Ring-Group ownership
    ("@GroupName") -> every CURRENT member, read live from
    pstn-groups.conf — same mirror services/security-dashboard.sh's
    sync_room_group_mirror() keeps in step with actual Ring Group
    membership, so this always reflects who's in the group right now, not
    who was in it when the DID was assigned. Empty list = nobody currently
    owns this DID; the caller logs that and gives up rather than guessing
    where to deliver it."""
    if not ASTERISK_CONFIG_DIR:
        return []
    did = _normalize_did(to_raw)
    if not did:
        return []
    dids_cp = _read_conf(os.path.join(ASTERISK_CONFIG_DIR, "pstn-personal-dids.conf"))
    if not dids_cp.has_section(did):
        return []
    owner = dids_cp.get(did, "owner", fallback="").strip()
    if not owner:
        return []
    if owner.startswith("@"):
        groups_cp = _read_conf(os.path.join(ASTERISK_CONFIG_DIR, "pstn-groups.conf"))
        group_name = owner[1:]
        members_raw = groups_cp.get(group_name, "members", fallback="")
        return [m.strip() for m in members_raw.split(",") if m.strip()]
    return [owner]


class AMIError(Exception):
    pass


def _ami_read_response(sock_file):
    """One AMI message = lines up to a blank line. Returns {Key: Value}."""
    resp = {}
    while True:
        line = sock_file.readline()
        if not line:
            raise AMIError("connection closed while reading AMI response")
        line = line.decode("utf-8", errors="replace").rstrip("\r\n")
        if line == "":
            break
        if ":" in line:
            k, v = line.split(":", 1)
            resp[k.strip()] = v.strip()
    return resp


def ami_deliver(from_number, to_exts, body):
    """Logs into AMI once and sends one MessageSend action per recipient.

    UNVERIFIED against a real Asterisk instance as of this being written —
    "message" as the AMI permission class, and To/From/Body as MessageSend's
    exact parameter names, are both believed correct but haven't been
    confirmed live. Every AMI response is logged in full specifically so the
    first real delivery attempt shows exactly what Asterisk said if
    something here is wrong, rather than failing silently.

    Returns (delivered_count, total_count)."""
    if not AMI_SECRET:
        print("ami_deliver: SMS_AMI_SECRET not set, cannot deliver", flush=True)
        return 0, len(to_exts)

    delivered = 0
    with socket.create_connection((AMI_HOST, AMI_PORT), timeout=10) as sock:
        sock_file = sock.makefile("rb")
        banner = sock_file.readline()  # AMI sends a version banner first
        print("AMI banner: {}".format(banner.decode("utf-8", errors="replace").strip()), flush=True)

        def send_action(fields):
            payload = "".join("{}: {}\r\n".format(k, v) for k, v in fields) + "\r\n"
            sock.sendall(payload.encode("utf-8"))
            return _ami_read_response(sock_file)

        login_resp = send_action([
            ("Action", "Login"),
            ("Username", AMI_USER),
            ("Secret", AMI_SECRET),
        ])
        print("AMI login response: {}".format(login_resp), flush=True)
        if login_resp.get("Response") != "Success":
            raise AMIError("AMI login failed: {}".format(login_resp))

        from_uri = "<sip:{}@{}>".format(from_number or "unknown", SMS_DOMAIN or "localhost")
        for ext in to_exts:
            resp = send_action([
                ("Action", "MessageSend"),
                ("To", "pjsip:{}".format(ext)),
                ("From", from_uri),
                ("Body", body),
            ])
            print("AMI MessageSend to {}: {}".format(ext, resp), flush=True)
            if resp.get("Response") == "Success":
                delivered += 1

        send_action([("Action", "Logoff")])

    return delivered, len(to_exts)


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

        exts = resolve_recipients(recipient)
        if not exts:
            # Never log the body: could be a verification code or anything
            # else sensitive, and the journal is more widely readable than
            # this delivery path is supposed to be.
            print("sms from={} to={} chars={} -- no owner found for this DID, dropped".format(
                sender or "?", recipient or "?", len(message)), flush=True)
            self._respond(204)  # acknowledge to the provider either way — an unowned DID isn't its problem
            return

        try:
            delivered, total = ami_deliver(sender, exts, message)
        except Exception as exc:                      # noqa: BLE001
            print("ami_deliver failed: {}".format(exc), flush=True)
            self._respond(502)
            return

        print("sms from={} to={} chars={} delivered={}/{} recipients={}".format(
            sender or "?", recipient or "?", len(message), delivered, total, exts), flush=True)
        self._respond(204 if delivered else 502)

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
    if not TOKEN or not AMI_SECRET:
        raise SystemExit("SMS_RELAY_TOKEN and SMS_AMI_SECRET must both be set")
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
    local _port="$1" _token="$2" _asterisk_dir="$3" _ami_secret="$4" _domain="$5"
    cat > /etc/systemd/system/sms-inbound.service << SMSSVC
[Unit]
Description=Inbound SMS webhook, delivered into Asterisk via AMI
After=network.target

[Service]
Type=simple
User=$SMS_SVC_USER
Group=$SMS_SVC_USER
Environment=SMS_RELAY_PORT=$_port
Environment=SMS_RELAY_TOKEN=$_token
Environment=SMS_ASTERISK_CONFIG_DIR=$_asterisk_dir
Environment=SMS_AMI_HOST=127.0.0.1
Environment=SMS_AMI_PORT=5038
Environment=SMS_AMI_USER=smsrelay
Environment=SMS_AMI_SECRET=$_ami_secret
Environment=SMS_DOMAIN=$_domain
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
    local _url="$1" _relay_domain="$2"
    write_readme "$SMS_APP_DIR" << MD
# Inbound SMS → Sipnetic (via AMI)

Gets SMS sent to one of your PSTN DIDs delivered into Asterisk as a SIP
MESSAGE, landing in Sipnetic the same way internal texting already does —
not a push notification, a real message in the softphone.

## The URL to paste into your DID provider

In the provider portal, open the DID's SMS settings and paste this into the
"Forward to URL" field (on Anveo: Phone Numbers → the DID → SMS tab, tick
the checkbox, paste, press SAVE — RETURN discards):

\`\`\`
${_url}
\`\`\`

Keep the message placeholder **last** in that URL. Providers interpolate the
message text without escaping it, so a body containing \`&\` splits into extra
query parameters; with the message last, everything after it can be read back
verbatim.

Treat this URL like a password — anyone holding it can trigger a message
delivery into your Asterisk.

## How delivery is decided

The relay looks up who currently owns the destination DID, using the exact
same data the inbound-voice ring logic reads (\`pstn-personal-dids.conf\` /
\`pstn-groups.conf\`, managed from the Security Dashboard's Extensions tab —
see the Personal Numbers card and Ring Groups' own DID field there):

- **Owned by a single extension** — that extension gets the text.
- **Owned by a Ring Group** — every CURRENT member gets it, checked fresh on
  every delivery (not baked in at assignment time), same as inbound voice
  ring-group calls already work.
- **Not owned by anyone** — logged and dropped. Assign the DID to an
  extension or Ring Group first.

## What this does not do

- **Sending.** There's no outbound path here — that's a separate piece,
  still pending on Anveo activating API-based SMS sending for this account
  (see \`docs/anveo-direct-setup-guide.md\`).
- **MMS.** No VoIP provider delivers MMS over SIP, and MMS to a VoIP DID
  generally either drops or arrives as a media link through a separate API.
  US **group texts are MMS**, so expect to miss those entirely.

## Security

- **The relay token is a secret.** This installer generated a long random
  one; anyone holding the full URL can trigger a delivery into your
  Asterisk (though only to whichever DID they claim as \`to=\`, and only
  reaching whoever currently owns that DID).
- **AMI access is scoped and localhost-only.** The \`smsrelay\` manager.conf
  user can only run \`MessageSend\`, and can only connect from 127.0.0.1 —
  it has no path to originate calls, read call data, or touch configuration.

## Manage

\`\`\`bash
systemctl status sms-inbound
journalctl -u sms-inbound -f      # from/to, recipient count, and full AMI
                                   # responses — never the message body
sudo ./setup.sh sms-inbound       # re-run to change settings or rotate secrets
\`\`\`

$( [[ -n "$_relay_domain" ]] && printf 'Public endpoint: `https://%s` (Caddy → the relay on this box).\n' "$_relay_domain" )

## Testing it

Substitute a real message for the provider's placeholder and call the URL
yourself — no need to wait for a text (use a DID that's actually assigned to
an extension or Ring Group, or it'll just log "no owner found" and drop it):

\`\`\`bash
curl -s -o /dev/null -w '%{http_code}\\n' \\
  "$(printf '%s' "$_url" | sed 's/\$\[from\]\$/15555550123/; s/\$\[to\]\$/15555550199/; s/\$\[message\]\$/test+message/')"
\`\`\`

**204** means it was delivered (or, if nothing owns that DID, acknowledged
and dropped — check \`journalctl -u sms-inbound\` to tell which). **404**
means the token in the path is wrong. **429** means the rate limit tripped
(60 requests/minute). **502** means AMI delivery itself failed — check the
journal for the full AMI response before assuming which end is wrong.
MD
}

install_sms-inbound() {
    log_info "Setting up inbound SMS → Sipnetic (via Asterisk's Manager Interface)..."

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would detect the Asterisk install and its DID-ownership config"
        echo "[DRY-RUN]   (pstn-personal-dids.conf / pstn-groups.conf) — requires"
        echo "[DRY-RUN]   services/asterisk.sh and services/pstn-trunk.sh already installed"
        echo "[DRY-RUN] Would write a scoped AMI user (MessageSend only, localhost-only) into"
        echo "[DRY-RUN]   manager.conf, and grant the relay's system user read-only ACL access"
        echo "[DRY-RUN]   to Asterisk's config directory"
        echo "[DRY-RUN] Would install $SMS_APP_DIR/relay.py as a systemd service, front it with"
        echo "[DRY-RUN]   Caddy on a domain you'll be prompted for (no Authelia — the SMS"
        echo "[DRY-RUN]   provider can't log in; a random token in the path is the secret)"
        echo "[DRY-RUN] Would print the exact URL to paste into the DID provider's SMS settings"
        echo "[DRY-RUN] Would write $SMS_APP_DIR/README.md"
        return 0
    fi

    local EA_DIR="" CONTAINER_NAME=""
    EA_DIR="$(_sms_detect_ea_dir)"
    if [[ -z "$EA_DIR" ]]; then
        log_error "No Asterisk install detected (services/asterisk.sh) — this service delivers"
        log_error "into a running Asterisk over its Manager Interface, so there's nothing to"
        log_error "wire up without one. Run 'sudo ./setup.sh asterisk' first."
        return 1
    fi
    CONTAINER_NAME="$(_sms_detect_container_name "$EA_DIR")"
    local ASTERISK_DIR="$EA_DIR/config/asterisk"
    if [[ ! -f "$ASTERISK_DIR/pstn-personal-dids.conf" ]]; then
        log_warning "No pstn-personal-dids.conf found yet (services/pstn-trunk.sh) — this relay"
        log_warning "will run, but every inbound text will be logged as 'no owner found' and"
        log_warning "dropped until at least one DID is assigned to an extension or Ring Group"
        log_warning "from the Security Dashboard's Extensions tab."
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
                _sms_write_relay_app "$SMS_APP_DIR"
                chown -R "$SMS_SVC_USER:$SMS_SVC_USER" "$SMS_APP_DIR" 2>/dev/null || true
                _sms_write_systemd_unit "${SMS_RELAY_PORT}" "${SMS_RELAY_TOKEN}" "$ASTERISK_DIR" "${SMS_AMI_SECRET}" "${SMS_DOMAIN:-}"
                _sms_grant_asterisk_read_access "$SMS_SVC_USER" "$ASTERISK_DIR"
                systemctl restart sms-inbound \
                    && log_success "Relay refreshed and restarted." \
                    || log_warning "Restart failed — check: journalctl -u sms-inbound -n 50"
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

    # ── AMI + relay system user ─────────────────────────────────────────────
    id -u "$SMS_SVC_USER" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$SMS_SVC_USER"

    local AMI_SECRET
    AMI_SECRET="$(generate_password 32)"
    local MGR_STATE
    MGR_STATE="$(_sms_write_manager_conf "$ASTERISK_DIR" "$AMI_SECRET")"
    ensure_docker_dir_ownership "$ASTERISK_DIR"
    _sms_grant_asterisk_read_access "$SMS_SVC_USER" "$ASTERISK_DIR"

    if [[ "$MGR_STATE" != "unchanged" ]]; then
        echo ""
        log_warning "AMI was just enabled/changed on this box — Asterisk needs a restart to pick"
        log_warning "that up (confirmed elsewhere this session: a plain reload isn't reliable for"
        log_warning "config that's new to the running process). This drops any calls in progress"
        log_warning "right now."
        local _restart_ami=""
        prompt_yn "Restart Asterisk now to enable AMI? (y/n):" "y" _restart_ami
        if [[ "$_restart_ami" =~ ^[Yy]$ ]]; then
            docker restart "$CONTAINER_NAME" &>/dev/null \
                && log_success "Restarted." \
                || log_warning "Restart failed — check: docker logs $CONTAINER_NAME"
        else
            log_warning "Not restarted — the relay will run, but AMI logins will fail until"
            log_warning "you restart: docker restart $CONTAINER_NAME"
        fi
    fi

    # ── Relay service ─────────────────────────────────────────────────────────
    mkdir -p "$SMS_APP_DIR"
    local RELAY_PORT=8093
    local _limit=$((RELAY_PORT + 100))
    while ss -tlnH "sport = :${RELAY_PORT}" 2>/dev/null | grep -q . && [[ "$RELAY_PORT" -lt "$_limit" ]]; do
        RELAY_PORT=$((RELAY_PORT + 1))
    done
    [[ "$RELAY_PORT" != 8093 ]] && log_info "Port 8093 was taken — the relay will use ${RELAY_PORT}."

    local RELAY_TOKEN
    RELAY_TOKEN="$(generate_password 32)"

    local SMS_DOMAIN=""
    [[ -f "$EA_DIR/.env" ]] && SMS_DOMAIN="$(grep -E '^DOMAIN_NAME=' "$EA_DIR/.env" | cut -d= -f2-)"

    _sms_write_relay_app "$SMS_APP_DIR"
    chown -R "$SMS_SVC_USER:$SMS_SVC_USER" "$SMS_APP_DIR"
    _sms_write_systemd_unit "$RELAY_PORT" "$RELAY_TOKEN" "$ASTERISK_DIR" "$AMI_SECRET" "$SMS_DOMAIN"
    systemctl enable --now sms-inbound >/dev/null 2>&1 \
        && log_success "Relay service started on port ${RELAY_PORT}." \
        || log_warning "Relay failed to start — check: journalctl -u sms-inbound -n 50"

    # The provider calls this from the public internet, so it needs a real
    # certificate — providers generally refuse self-signed targets.
    echo ""
    local RELAY_DOMAIN=""
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

    local FORWARD_URL="https://${RELAY_DOMAIN:-<your-domain>}/sms/${RELAY_TOKEN}?from=\$[from]\$&to=\$[to]\$&message=\$[message]\$"

    # ── Persist settings ──────────────────────────────────────────────────────
    cat > "$SMS_SETTINGS" << ENV
# Written by services/sms-inbound.sh — re-run that to change any of this.
SMS_RELAY_PORT="${RELAY_PORT}"
SMS_RELAY_TOKEN="${RELAY_TOKEN}"
SMS_RELAY_DOMAIN="${RELAY_DOMAIN}"
SMS_AMI_SECRET="${AMI_SECRET}"
SMS_DOMAIN="${SMS_DOMAIN}"
# The exact string to paste into the DID provider's "forward SMS to URL" box.
# Secret: anyone holding it can trigger a delivery into your Asterisk.
SMS_FORWARD_URL="${FORWARD_URL}"
ENV
    chmod 600 "$SMS_SETTINGS"

    _sms_write_readme "$FORWARD_URL" "$RELAY_DOMAIN"

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Inbound SMS → Sipnetic configured."
    echo ""
    echo "  1. In your DID provider's portal, open the number's SMS settings and"
    echo "     paste this into the \"Forward to URL\" field, exactly:"
    echo ""
    echo "       ${FORWARD_URL}"
    echo ""
    echo "     On Anveo: Phone Numbers → the DID → SMS tab; tick the checkbox,"
    echo "     paste, then press SAVE (RETURN discards). Reopen the tab after"
    echo "     saving to confirm the whole URL came back — it is a long string."
    echo ""
    echo "  2. Make sure that DID is assigned to an extension or Ring Group on the"
    echo "     Security Dashboard's Extensions tab — an unassigned DID just gets"
    echo "     logged and dropped."
    echo ""
    echo "  3. Text the number from another phone, then check:"
    echo "       journalctl -u sms-inbound -f"
    echo "     for delivery status and the full AMI response — this is the first"
    echo "     real test of the AMI plumbing, so check here if it doesn't land in"
    echo "     Sipnetic even though the journal shows it as delivered."
    echo ""
    log_warning "That URL is a secret — anyone with it can trigger a delivery into your Asterisk."
    echo "  Details, caveats and testing: $SMS_APP_DIR/README.md"
    echo ""
}
