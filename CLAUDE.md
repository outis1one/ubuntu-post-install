# CLAUDE.md — ubuntu-post-install contributor guide

Context for adding or modifying services. Read this before touching any
service file so the result matches what's already here.

## How the system works

`setup.sh` sources `lib/common.sh` then globs every `services/*.sh` file.
Each service file self-registers and defines its install function. Nothing
in `setup.sh` needs to change when you add a service — just add the file.

The wizard groups services by category (from `register_service`), shows a
checklist per group, and calls `install_<name>()` for each selected item.
`--list`, `--dry-run`, and `--unattended` all work automatically.

## Adding a service — the three-step rule

1. Create `services/<name>.sh` (kebab-case filename)
2. Call `register_service` at the top of the file
3. Define `install_<name>()` — keep hyphens **literal** in the function name
   (`install_asterisk-digital-ocean`, not `install_asterisk_digital_ocean`).
   `setup.sh`'s dispatcher calls `install_${name}` with no hyphen→underscore
   conversion, so the function name must match the service name exactly.
   Confirmed live: a mismatched underscore here produces
   `Service 'x' has no install_x` at runtime, not a load-time error.

That's it. The menu picks it up on the next run.

Also update the **Services table in `README.md`** — add the service name to the
appropriate group row so the README stays current.

## Minimal Docker service template

```bash
#!/bin/bash
# services/my-tool.sh — One-line description.
# Part of the modular post-install system (sourced by setup.sh).

register_service my-tool utilities "What it does (My Tool)" 8080

install_my_tool() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/my-tool"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml"
        return 0
    fi

    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    cat > docker-compose.yml << 'EOF'
name: my-tool
services:
  my-tool:
    image: vendor/my-tool:latest
    container_name: my-tool
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - ./data:/data
EOF

    configure_caddy_for_service "My Tool" "8080" "my-tool"

    write_readme "$DIR" << 'MD'
# My Tool
Brief description.

## Manage
```bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
```
MD

    local START=""
    prompt_yn "Start My Tool now? (y/n):" "y" START
    if [ "$START" = "y" ] || [ "$START" = "Y" ]; then
        docker compose up -d \
            && log_success "My Tool started" \
            || log_warning "Start failed — check: docker compose logs"
    fi
}
```

## register_service signature

```bash
register_service <name> <group> "<description>" [port]
```

- `name` — kebab-case, matches the filename and the `install_` function
- `group` — one of the categories below; determines which menu it appears in
- `description` — shown in `--list` and the menu checklist
- `port` — optional; informational only (not used by the framework)

## Available globals

| Variable | Value |
|----------|-------|
| `DOCKER_DIR` | `~/docker` — parent for all Docker service directories |
| `ACTUAL_USER` | The non-root user that invoked sudo |
| `ACTUAL_HOME` | Home directory of `ACTUAL_USER` |
| `SITE_TZ` | Timezone from site config, e.g. `America/New_York` |
| `SITE_DOMAIN` | Base domain from site config, e.g. `example.com` |
| `SITE_CADDY_NET` | Docker network name for Caddy (default: `caddy_net`) |
| `DRY_RUN` | `true`/`false` — set by `--dry-run` flag |
| `UNATTENDED` | `true`/`false` — set by `--unattended` flag |

## Available helpers (lib/common.sh)

### Logging

```bash
log_info    "message"   # blue   [INFO]
log_success "message"   # green  [OK]
log_warning "message"   # yellow [WARN]
log_error   "message"   # red    [ERROR]
```

### Prompts — honor `UNATTENDED` automatically

```bash
prompt_yn   "Question? (y/n):" "default_y_or_n" VARNAME
prompt_text "Question? [default]:" "default" VARNAME
prompt_reinstall_mode VARNAME   # sets VARNAME to: update | fresh | cancel
```

When `UNATTENDED=true` all three skip the prompt; `prompt_yn`/`prompt_text` use
their given default, `prompt_reinstall_mode` always resolves to `cancel`. See
**Update vs. fresh reinstall on rerun** below for how to use the latter.

### Pre-flight

```bash
require_root    # exits with an error if not running as root
require_docker  # installs Docker CE + Compose plugin if missing, then returns
```

### Execution and ownership

```bash
run_cmd COMMAND [args...]           # no-ops in DRY_RUN, executes otherwise
ensure_docker_dir_ownership DIR...  # chown -R ACTUAL_USER:ACTUAL_USER (skips in DRY_RUN)
generate_password [length]          # alphanumeric random string, default 32 chars
pip_user_install PACKAGE...         # pip3 --user with --break-system-packages on 24.04+
```

### Caddy reverse proxy

```bash
configure_caddy_for_service "Display Name" "PORT" "default-subdomain" ["extra-block"]
```

Prompts the user for a domain, appends a site block to the Caddyfile, and
reloads Caddy. No-ops silently if Caddy isn't installed. The fourth argument
is an optional string inserted verbatim inside the Caddy site block (use it
for `import authelia` or custom matchers).

The function places that block **before** `reverse_proxy` in the generated
site block — don't reorder this. `forward_auth` (what `import authelia`
expands to) is the same directive family as `reverse_proxy` internally, and
Caddy doesn't reorder repeats of the same directive within a block; it runs
them in the order they're written. `reverse_proxy` written first would
handle and terminate every request immediately, making an auth check
written after it dead code that never runs — full bypass regardless of what
the auth server's own access-control rules say. Confirmed live: this was
the actual cause of a "Caddy proxies fine but Authelia never prompts for
login" bug, on a site block that otherwise looked completely correct. If a
service builds its own site block instead of using this helper (e.g.
`services/asterisk-digital-ocean.sh` does, deliberately, see its own
comment for why), put its auth block first there too.

**`forward_auth` to a remote Authelia over a scheme-qualified URL needs
explicit `header_up` pins.** A bare `forward_auth authelia:9091` (Authelia on
the same Docker network, one hop) is fine relying on Caddy's default
`X-Forwarded-*` headers. But `forward_auth https://auth.example.com { ... }`
(Authelia on a *different* machine, reached over its own public domain+TLS —
see `services/asterisk-digital-ocean.sh`'s remote-Authelia prompt) is a
second Caddy hop: Caddy rewrites the outgoing request's `Host` header to
`auth.example.com` so the remote Caddy can route/SNI-match it, and without an
override `X-Forwarded-Host` picks up that rewritten value instead of the
original site's host. Confirmed live: Authelia evaluated *every* protected
domain as if the request were for `auth.example.com` itself (which typically
has `policy: bypass` in `access_control.rules` so its own login portal isn't
gated behind itself) — so every domain behind the remote instance silently
passed through with no 2FA prompt, regardless of that domain's own policy.
Fix: pin the forwarded headers to the original request explicitly instead of
trusting Caddy's default derivation:

```
forward_auth https://auth.example.com {
    uri /api/authz/forward-auth
    copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
    header_up X-Forwarded-Method {method}
    header_up X-Forwarded-Proto {scheme}
    header_up X-Forwarded-Host {host}
    header_up X-Forwarded-Uri {uri}
}
```

This only affects the remote-Authelia path — same-machine `authelia:9091`
snippets (`services/authelia.sh`) are a single hop and don't need it.

Sets two out-params (not `local` — read them after the call returns) so the
caller can tell whether Caddy actually ended up fronting the service:

```bash
CADDY_SERVICE_CONFIGURED   # true/false
CADDY_SERVICE_MODE         # "local" or "remote" (only meaningful if configured)
```

Use this to skip opening a host firewall port for a service Caddy already
fronts *locally* (it reaches the service over `host.docker.internal`, not
the network) — but still open it when `CADDY_SERVICE_MODE` is `"remote"`,
since a remote Caddy machine needs to reach this host over the network
instead. See `services/asterisk.sh` and `services/asterisk-digital-ocean.sh`
for the reference pattern: call `configure_caddy_for_service` *before*
building firewall rules, not after, so the decision is known in time.

### UFW enable

```bash
ensure_ufw_enabled
```

Call this **after** your service has already added its own `ufw allow`
rules — it only flips UFW from inactive to active, it doesn't add rules for
you. No-ops if UFW is already active or not installed. Always allows SSH
first (reading the real port from `sshd_config` in case it's non-default)
before enabling, so this can't lock out the session running the installer.

### Closing a port to the internet without also closing it to Caddy

```bash
ufw_allow_from_caddy_net PORT [PROTO]   # PROTO defaults to tcp
```

When `CADDY_SERVICE_MODE` is `"local"` (see above) and you `ufw delete
allow` a port because Caddy fronts it now, don't stop there — UFW rules
apply to *all* interfaces unless scoped, and Caddy's own request to
`host.docker.internal:PORT` is ordinary INPUT-chain traffic arriving over
the `caddy_net` bridge, not the public internet. A bare `ufw delete allow`
blocks that too and silently breaks the service (confirmed live: closing
the web admin port outright took Caddy down with it). Call
`ufw_allow_from_caddy_net` right after the `delete` to re-open the port
scoped to just `caddy_net`'s subnet — reachable from Caddy, not from the
internet. See `services/asterisk-digital-ocean.sh` and
`services/asterisk.sh` for the pattern.

### README generation

```bash
write_readme "$DIR" << 'MD'
# Title
Content
MD
```

Writes `$DIR/README.md` (creates the directory if needed). No-ops in DRY_RUN.
Every Docker service should call this so `~/docker/<name>/README.md` is
self-documenting on the deployed box.

## Categories

| Group | Purpose |
|-------|---------|
| `base` | CLI packages installed on every box |
| `homelab` | Core infrastructure — reverse proxy, auth, intrusion prevention |
| `utilities` | Self-hosted web apps — budget, DNS, files, monitoring, VPN, etc. |
| `media` | Media servers, photo backup, disc ripping |
| `cameras` | NVR and camera tooling (Frigate) |
| `gaming` | Game servers, cloud gaming (Wolf), emulation |
| `extras` | Non-Docker tools and scripts |
| `backup` | Backup solutions |

## Authelia SSO — which services need it

Some services have their own login screens; others have none and need Caddy to
gate them via Authelia.

**Protecting more than one apex domain from the same box — same instance, not a second
one.** `services/authelia.sh`, re-run against an existing install, offers "Add another
protected domain to this instance": it appends a new `access_control.rules` entry and a new
`session.cookies` entry (both are YAML lists — Authelia natively supports multiple
independent cookie scopes) plus a Caddy `auth.<domain>` portal block for the new domain, all
on the **same** Authelia + Redis container. Each domain gets its own login/session (no
cross-domain SSO between them) and shares one user database, without the RAM cost of a
second full Authelia+Redis stack — the right choice whenever the domains are going to live
on the same machine anyway. See `add_authelia_domain()` in `services/authelia.sh`.

**Running a genuinely separate instance (e.g. one per machine).** `services/authelia.sh`
runs standalone on any box (`sudo bash authelia.sh`, same pattern as `crowdsec.sh`) and
`asterisk-digital-ocean.sh` already auto-detects a local install (`if [ -d
"$DOCKER_DIR/authelia" ]`), switching from the remote-Authelia `forward_auth` flow to the
local `import authelia` snippet automatically — so a second, fully independent instance on
another machine (e.g. a droplet, for resilience if the first machine goes down) works with
no code changes. Use this instead of the same-instance approach above when the two domains
are on different machines, not just different domains on one machine.

The one real constraint for genuinely separate instances: Authelia's session cookie is
scoped to `AUTHELIA_DOMAIN` (the apex domain entered at install time) with
`includeSubDomains`-style matching, and the portal itself lives at `auth.${AUTHELIA_DOMAIN}`.
**Two independent instances must not share the same `AUTHELIA_DOMAIN`.** If they did, both
would try to claim the same `auth.<domain>` hostname (DNS can only point that at one
machine) and the same cookie scope with completely separate session stores — users bouncing
between subdomains fronted by different instances would see confusing repeated logins as
each instance's cookie gets overwritten/rejected by the other's. Give each instance either a
genuinely separate apex domain, or a distinct subdomain tree the other instance doesn't also
claim. (This constraint doesn't apply to the same-instance, multiple-domains approach above —
each domain there gets its own cookie entry by design, which is exactly what avoids the
collision.)

**Has built-in auth — no Authelia needed:**
`emby`, `jellyfin`, `audiobookshelf`, `immich`, `mealie`, `actualbudget`,
`homeassistant`, `portainer`, `meshcentral`, `traccar`, `uptimekuma`,
`filebrowser`, `wg-easy`, `ntfy` (configurable)

**No built-in auth — should be protected:**
`magicmirror`, `wolf-pair`, `js99er`, `sky-cam`

For services without built-in auth, prompt the user before calling
`configure_caddy_for_service` and pass `import authelia` as the extra block
if Authelia is installed and the user wants SSO protection:

```bash
local EXTRA_BLOCK=""
if [ -d "$DOCKER_DIR/authelia" ]; then
    local _use_auth=""
    prompt_yn "Protect MagicMirror with Authelia SSO? (y/n):" "y" _use_auth
    [[ "$_use_auth" =~ ^[Yy]$ ]] && EXTRA_BLOCK="    import authelia"
fi
configure_caddy_for_service "MagicMirror" "8081" "mirror" "$EXTRA_BLOCK"
```

**Authelia "stay logged in" / kiosk mode:**
Edit `~/docker/authelia/config/configuration.yml` and set a long
`remember_me_duration`. Users then check "Remember me" once on login and
the session persists through reboots (Redis stores the session in a volume):

```yaml
session:
  secret: 'your-existing-secret'
  remember_me_duration: 1y     # add or update this line
  expiration: 1h
  inactivity: 5m
  cookies:
    - domain: 'example.com'
      authelia_url: 'https://auth.example.com'
```

After editing: `docker compose -f ~/docker/authelia/docker-compose.yml restart`

## Non-Docker services

Not everything is a container. For apt-based or git-clone–based services,
skip `require_docker` and the Docker helpers. See `services/base.sh` (apt
packages + Charm repo) and `services/crowdsec.sh` (official apt repo) as
reference patterns.

For non-Docker services the default `is_installed` check in `setup.sh`
looks for `$DOCKER_DIR/$name`, which won't exist. Add a case to the
`is_installed()` function in `setup.sh` so the `[installed]` marker appears
correctly in the menu:

```bash
# In setup.sh → is_installed()
my-tool) command -v my-tool >/dev/null 2>&1 ;;
```

Docker services use the default case and don't need an entry.

## DRY_RUN convention

Every `install_*` function must check `$DRY_RUN` before touching the
filesystem, installing packages, or starting containers. The pattern is:

```bash
if [ "$DRY_RUN" = true ]; then
    echo "[DRY-RUN] Would do X"
    echo "[DRY-RUN] Would do Y"
    return 0
fi
```

Put the check early — after any pure-display output (banners, info text)
but before the first write.

## Update vs. fresh reinstall on rerun

Every service should detect an existing install at the top of its
`install_<name>()` — after the `DRY_RUN` check, before any prompts — and
offer `prompt_reinstall_mode` instead of silently re-running every prompt
(domain, secrets, firewall, Authelia, extras...) from scratch. What counts
as "already installed" is service-specific: usually `docker-compose.yml` and
`.env` both existing in the service's `$DOCKER_DIR/<name>` directory.

```bash
if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
    local MODE=""
    prompt_reinstall_mode MODE
    case "$MODE" in
        update)
            # Refresh vendor files / config templates, rebuild, done.
            # Do NOT touch .env, firewall rules, or Caddy/Authelia config.
            ...
            return 0
            ;;
        cancel)
            log_info "Leaving the existing install as-is."
            return 0
            ;;
        fresh) ;;  # fall through to the full install flow below
    esac
fi
```

`update` should be genuinely non-destructive: refresh whatever the service
vendors or templates (Docker image sources, config templates,
`docker-compose.yml`) and rebuild/restart, but never touch `.env`, firewall
rules, or reverse-proxy/SSO config that's already in place. If the
vendor-copy or `docker-compose.yml`-generation logic is more than a few
lines, factor it into a helper function so the fresh-install path and the
update path share one copy instead of drifting apart — see
`_asterisk_do_refresh_vendor_files`/`_asterisk_do_write_compose` in
`services/asterisk-digital-ocean.sh` (and their `_asterisk_*` counterparts in
`services/asterisk.sh`) for the reference pattern.

`cancel` must leave the install completely untouched — it's the default for
a reason (a stray Enter on a service you're just checking on shouldn't
trigger anything). `fresh` runs the exact same flow a first-time install
would, prompts included.

## .env files and secrets

Generate passwords with `generate_password` (never hardcode them).
Write secrets to `.env` files in the service directory, owned by
`ACTUAL_USER`, permissions 600. Document every variable with a comment
in the `.env` heredoc so the user knows what to change later.

## Caddy network wiring

Services that need to reach Caddy (or each other) over Docker networking
should join the `$SITE_CADDY_NET` network. Add to `docker-compose.yml`:

```yaml
networks:
  caddy_net:
    external: true
    name: ${CADDY_NET:-caddy_net}
```

And read the network name from `.env` using `CADDY_NET=$SITE_CADDY_NET`.

`external: true` means *this* service expects the network to already exist —
it doesn't create it. `require_docker` creates it for you (via
`ensure_caddy_network` in `lib/common.sh`) the first time any service calls
it, so as long as your `install_<name>()` calls `require_docker` before
`docker compose up` (it always should), the network is guaranteed to exist
regardless of whether Caddy itself has been installed yet.

**`network_mode: host` services (e.g. `asterisk`/`asterisk-digital-ocean`) don't join
`caddy_net` at all** — Caddy reaching them (or anything else on the host
network) needs `host.docker.internal:PORT` in the Caddyfile, not
`localhost:PORT` or a container name. Caddy's own compose file
(`services/caddy.sh`) sets `extra_hosts: host.docker.internal:host-gateway`
so that hostname resolves; `configure_caddy_for_service`'s bare-port upstream
case already does this for you — don't hand-roll `localhost:PORT` in a
Caddy site block.
