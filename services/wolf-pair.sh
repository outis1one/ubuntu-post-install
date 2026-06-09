#!/bin/bash
# services/wolf-pair.sh — Moonlight pairing web UI for Wolf.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash wolf-pair.sh
# (Docker must already be installed when run standalone)
#
# Builds a tiny Python HTTP container (server.py + Dockerfile baked below)
# that watches Wolf's docker logs for pairing secrets and serves a PIN entry
# form on port 8090.  No command line needed: visit the URL, type the PIN.
#
# The container runs with network_mode: host so that server.py can reach
# Wolf's pairing API at http://localhost:47989 and tail `docker logs wolf`
# via the mounted docker socket.

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

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            # Determine mode: local Caddy, remote Caddy, or none
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

            # Domain prompt — pre-fill from SITE_DOMAIN when available
            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Build upstream — remote Caddy uses host IP:port, not container name
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
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
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
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
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

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service wolf-pair gaming "Moonlight pairing web UI for Wolf" 8090

install_wolf-pair() {
    require_docker || return 1

    local WOLFPAIR_DIR="$DOCKER_DIR/wolf-pair"
    local WOLFPAIR_PORT=8090

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] wolf-pair install would:"
        echo "  - Create $WOLFPAIR_DIR with server.py, Dockerfile, docker-compose.yml"
        echo "  - Build the wolf-pair image (python:3.12-alpine + docker-cli)"
        echo "  - Run the container with network_mode: host (for localhost:47989 access)"
        echo "  - Mount /var/run/docker.sock:ro (for docker logs wolf)"
        echo "  - Open port $WOLFPAIR_PORT in UFW"
        echo "  - Optionally configure a Caddy reverse proxy"
        return 0
    fi

    mkdir -p "$WOLFPAIR_DIR"
    ensure_docker_dir_ownership "$WOLFPAIR_DIR"
    cd "$WOLFPAIR_DIR" || return 1

    # ── 1. server.py ──────────────────────────────────────────────────────────
    log_info "Writing server.py..."
    cat > "$WOLFPAIR_DIR/server.py" << 'PYEOF'
#!/usr/bin/env python3
"""
wolf-pair — single-backend pairing helper for Wolf/Moonlight.

GET /   → if a fresh pairing secret is pending: serve a PIN form.
          if none: serve a waiting page that auto-refreshes.
POST /  → take the PIN from the form, attach the freshest secret read from
          Wolf's logs, and proxy {pin, secret} to Wolf's /pin/ endpoint.

Wolf's pairing secrets are SINGLE-USE: Wolf erases a secret from its map the
instant any PIN is submitted for it (correct or not). Because the secret stays
in `docker logs` forever, we must never re-offer a secret we've already
submitted — otherwise the user resubmits a dead secret and Wolf returns
"key not found". We track submitted secrets and fall back to the waiting page
until Moonlight initiates a brand-new pairing (which mints a new secret).
"""
import json, subprocess, re, urllib.request, urllib.error
from http.server import HTTPServer, BaseHTTPRequestHandler

WOLF_HTTP = "http://localhost:47989"

# Secrets already submitted to Wolf. Wolf erases a secret on first submit, so a
# secret in here is dead — show the waiting page instead of re-offering it.
_submitted_hashes: set = set()

PIN_LOG_RE = re.compile(r'Insert pin at http://\S+/pin/#([0-9A-Fa-f]+)')

HTML_WAITING = b"""<!DOCTYPE html>
<html><head>
<meta http-equiv="refresh" content="3">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wolf Pairing</title>
<style>
  body{font-family:sans-serif;display:flex;flex-direction:column;align-items:center;
       justify-content:center;min-height:100vh;margin:0;
       background:linear-gradient(132deg,#720082,#3f00c3,#0047ff);color:#fff}
  h2{font-size:1.6rem;margin-bottom:.5rem}p{opacity:.85;margin:.3rem 0;text-align:center}
</style>
</head><body>
<h2>No pairing request yet</h2>
<p>In Moonlight, add this server, then return here.<br>
This page refreshes automatically every 3 seconds.</p>
</body></html>"""


def parse_latest_hash(log_text):
    """Return the most recent pairing secret found in log text, or None."""
    matches = PIN_LOG_RE.findall(log_text)
    return matches[-1] if matches else None


def latest_hash():
    """Freshest pairing secret that hasn't been submitted yet, or None."""
    try:
        r = subprocess.run(
            ['docker', 'logs', '--tail', '200', 'wolf'],
            capture_output=True, text=True, timeout=5)
        h = parse_latest_hash(r.stdout + r.stderr)
        return h if (h and h not in _submitted_hashes) else None
    except Exception:
        return None


def build_pin_form(secret):
    """Self-contained PIN form. Submits only the PIN; the server attaches the
    secret at POST time so a stale page can't send an already-used secret."""
    body = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Wolf Pairing</title>
<style>
  body{{font-family:sans-serif;display:flex;flex-direction:column;align-items:center;
       justify-content:center;min-height:100vh;margin:0;
       background:linear-gradient(132deg,#720082,#3f00c3,#0047ff);color:#fff}}
  h2{{font-size:1.6rem;margin-bottom:.5rem}}
  p{{opacity:.85;margin:.3rem 0;text-align:center}}
  input{{font-size:2rem;width:5.5rem;text-align:center;padding:.4rem;
         border:none;border-radius:.4rem;letter-spacing:.3rem}}
  button{{margin-top:1rem;font-size:1.1rem;padding:.5rem 1.8rem;border:none;
          border-radius:.4rem;cursor:pointer;background:#fff;color:#3f00c3;font-weight:bold}}
  #msg{{margin-top:1rem;min-height:1.4em;max-width:22rem;text-align:center}}
</style>
</head><body>
<h2>Moonlight Pairing</h2>
<p>Enter the 4-digit PIN shown in Moonlight</p>
<input id="pin" type="text" inputmode="numeric" maxlength="4" autofocus autocomplete="off">
<button onclick="submitPin()">Pair</button>
<div id="msg"></div>
<script>
function submitPin() {{
  var pin = document.getElementById('pin').value.trim();
  var msg = document.getElementById('msg');
  if (!/^\\d{{4}}$/.test(pin)) {{ msg.textContent = 'Enter the 4-digit PIN from Moonlight'; return; }}
  msg.textContent = 'Pairing…';
  fetch('/', {{method:'POST',
    headers:{{'Content-Type':'application/json'}},
    body:JSON.stringify({{pin:pin}})
  }}).then(function(r){{return r.text().then(function(t){{return {{ok:r.ok,body:t}}}});}})
    .then(function(r){{msg.textContent = r.ok ? 'Paired! You can close this page.' : r.body;}})
    .catch(function(){{msg.textContent='Network error — try again.';}});
}}
document.getElementById('pin').addEventListener('keydown',function(e){{if(e.key==='Enter')submitPin();}});
</script>
</body></html>"""
    return body.encode('utf-8')


def send_response_body(handler, status, content_type, body):
    handler.send_response(status)
    handler.send_header('Content-Type', content_type)
    handler.send_header('Content-Length', str(len(body)))
    handler.send_header('Connection', 'close')
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        secret = latest_hash()
        if secret:
            send_response_body(self, 200, 'text/html; charset=utf-8', build_pin_form(secret))
            return
        send_response_body(self, 200, 'text/html; charset=utf-8', HTML_WAITING)

    def do_POST(self):
        # Read the freshest secret NOW (not whatever a stale page baked in).
        secret = latest_hash()
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length) if length else b''

        if not secret:
            send_response_body(self, 409, 'text/plain; charset=utf-8',
                ('No active pairing request. In Moonlight, add this host again '
                 'to start a fresh pairing, then enter the new PIN here.').encode())
            return

        try:
            pin = str(json.loads(raw).get('pin', '')).strip()
        except Exception:
            pin = ''

        payload = json.dumps({'pin': pin, 'secret': secret}).encode()
        req = urllib.request.Request(WOLF_HTTP + '/pin/', data=payload,
                                     headers={'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = resp.read()
            _submitted_hashes.add(secret)  # consumed by Wolf — never reuse
            send_response_body(self, resp.status,
                               resp.headers.get('Content-Type', 'text/plain'), data)
        except urllib.error.HTTPError as e:
            if e.code == 400:
                # Secret wasn't in Wolf's map (expired/already used) — retire it.
                _submitted_hashes.add(secret)
                send_response_body(self, 400, 'text/plain; charset=utf-8',
                    ('This pairing request expired or was already used. '
                     'Re-add the host in Moonlight and enter the new PIN.').encode())
            else:
                send_response_body(self, e.code, 'text/plain; charset=utf-8',
                    ('Wolf returned an error (%s). Try again.' % e.code).encode())
        except Exception:
            send_response_body(self, 502, 'text/plain; charset=utf-8',
                               b'Could not reach Wolf. Is the wolf container running?')

    def log_message(self, *a): pass


if __name__ == '__main__':
    HTTPServer(('0.0.0.0', 8090), Handler).serve_forever()
PYEOF
    log_success "server.py written"

    # ── 2. Dockerfile ─────────────────────────────────────────────────────────
    log_info "Writing Dockerfile..."
    cat > "$WOLFPAIR_DIR/Dockerfile" << 'DOCKERFILE'
FROM python:3.12-alpine
RUN apk add --no-cache docker-cli
WORKDIR /app
COPY server.py .
CMD ["python3", "server.py"]
DOCKERFILE
    log_success "Dockerfile written"

    # ── 3. docker-compose.yml ─────────────────────────────────────────────────
    # network_mode: host — server.py reaches Wolf at localhost:47989 directly.
    # Docker socket (ro) — server.py calls `docker logs wolf` to read secrets.
    log_info "Writing docker-compose.yml..."
    cat > "$WOLFPAIR_DIR/docker-compose.yml" << 'COMPOSE'
name: wolf-pair

services:
  wolf-pair:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: wolf-pair
    network_mode: host
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped

networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
COMPOSE
    log_success "docker-compose.yml written"

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$WOLFPAIR_DIR"

    # ── 4. Firewall ───────────────────────────────────────────────────────────
    if command -v ufw &>/dev/null; then
        ufw allow "${WOLFPAIR_PORT}/tcp" comment "wolf-pair pairing UI" >/dev/null 2>&1 || true
        log_success "UFW: opened port $WOLFPAIR_PORT/tcp"
    fi

    # ── 5. Caddy (optional) ───────────────────────────────────────────────────
    local WOLFPAIR_EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect wolf-pair with Authelia SSO? (y/n):" "y" _use_auth
        [[ "$_use_auth" =~ ^[Yy]$ ]] && WOLFPAIR_EXTRA_BLOCK="    import authelia"
    fi
    configure_caddy_for_service "wolf-pair" "$WOLFPAIR_PORT" "wolf-pair" "$WOLFPAIR_EXTRA_BLOCK"

    # ── 6. README ─────────────────────────────────────────────────────────────
    write_readme "$WOLFPAIR_DIR" << 'MD'
# wolf-pair

Browser-based Moonlight pairing helper for Wolf.

Visit `http://<server-ip>:8090` when Moonlight shows a pairing PIN — the page
detects the pending request automatically (auto-refreshes every 3 s while
waiting) and lets you type the PIN without running any CLI commands.

## How it works

1. In Moonlight, add this server → a 4-digit PIN appears.
2. Open `http://<server-ip>:8090` in any browser.
3. The page shows a PIN form — type the PIN and press **Pair**.

The server reads Wolf's docker logs for the current pairing secret, submits
`{pin, secret}` to Wolf's `/pin/` API, and marks the secret as used so a
stale browser tab can never re-submit a dead secret.

## Manage

```bash
cd ~/docker/wolf-pair
docker compose up -d          # start
docker compose down           # stop
docker compose up -d --build  # rebuild after source changes
docker compose logs -f        # follow logs
```

## Notes

- Requires the Wolf container (`wolf`) to be running.
- Moonlight's actual video/audio stream is direct UDP/TCP to the server IP
  and cannot be proxied — only the pairing page goes through wolf-pair.
- If you set up a Caddy subdomain (e.g. `wolf-pair.yourdomain.com`), that
  subdomain is for the PIN form only.
MD

    # ── 7. Build & start ──────────────────────────────────────────────────────
    echo ""
    log_success "wolf-pair configured at $WOLFPAIR_DIR"
    echo ""
    local START_WOLFPAIR=""
    prompt_yn "Build and start wolf-pair now? (y/n):" "y" START_WOLFPAIR
    if [ "$START_WOLFPAIR" = "y" ] || [ "$START_WOLFPAIR" = "Y" ]; then
        log_info "Building wolf-pair (python:3.12-alpine + docker-cli)..."
        if docker compose up -d --build; then
            log_success "wolf-pair started"
        else
            log_warning "Build failed — check: docker compose logs"
            return 1
        fi
    fi

    echo ""
    echo "  Pairing UI: http://localhost:${WOLFPAIR_PORT}"
    echo "  When Moonlight shows a PIN, open that URL and enter it."
    echo ""
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_wolf-pair
