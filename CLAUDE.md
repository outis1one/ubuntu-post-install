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
   (`install_pstn-trunk`, not `install_pstn_trunk`).
   `setup.sh`'s dispatcher calls `install_${name}` with no hyphen→underscore
   conversion, so the function name must match the service name exactly.
   Confirmed live: a mismatched underscore here produces
   `Service 'x' has no install_x` at runtime, not a load-time error.

That's it. The menu picks it up on the next run.

Also update the **Services table in `README.md`** — add the service name to the
appropriate group row so the README stays current.

## Retiring a service name (merging two services)

Deleting `services/<name>.sh` removes it from the menu, but `sudo ./setup.sh
<name>` then fails outright for anyone with that name in their notes, docs, or
shell history. Add the old name to `SERVICE_ALIAS` in `setup.sh` instead —
`run_service` resolves it to the surviving service, says so once, and runs
that. The alias never gets its own menu entry, which is the whole point.

`services/asterisk-digital-ocean.sh` was merged into `services/asterisk.sh`
this way: one installer that detects a DigitalOcean droplet (metadata service,
with a y/n either way) and applies the droplet-only extras — swapfile,
public-FQDN-only flow, hand-built Caddy site block, remote Authelia, Cloud
Firewall — behind that one answer. Two lessons worth reusing:

- **Don't rename a live install's directory or containers.** New installs
  land in `~/docker/asterisk` with `easy-asterisk`; a pre-merge droplet keeps
  `~/docker/asterisk-digital-ocean` and `easy-asterisk-do`, because its
  Caddyfile block, UFW rules, Cloud Firewall, CrowdSec acquisition and PSTN
  trunk all name those exact paths. `_asterisk_resolve_layout()` picks
  whichever exists, and every sibling service probes both.
- **Check whether a "flavor-specific" behavior was actually flavor-specific.**
  The Asterisk security-logging patch and the `logs/full` logrotate config
  were droplet-only purely because that's where they got written first — the
  Security Dashboard's Security Log and CrowdSec's Asterisk acquisition were
  silently empty on every home/LAN install as a result. Both now apply
  everywhere.

The pre-merge installer is parked at `attic/asterisk-digital-ocean.sh` as a
rollback path until the unified one is confirmed on real hardware. `attic/`
is outside `setup.sh`'s `services/*.sh` glob, so nothing there registers or
runs on its own — see `attic/README.md`, including why it's a way to get the
old script back rather than an undo button. Delete it once the merge is
proven; a second copy of the same logic is what the merge existed to remove,
and fixes are deliberately not backported into it.

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
`services/asterisk.sh` does in droplet mode, deliberately — see
`_asterisk_configure_caddy_public`'s comment for why), put its auth block
first there too.

**`forward_auth` to a remote Authelia over a scheme-qualified URL needs
explicit `header_up` pins.** A bare `forward_auth authelia:9091` (Authelia on
the same Docker network, one hop) is fine relying on Caddy's default
`X-Forwarded-*` headers. But `forward_auth https://auth.example.com { ... }`
(Authelia on a *different* machine, reached over its own public domain+TLS —
see `services/asterisk.sh`'s droplet-mode remote-Authelia prompt) is a
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
instead. See `services/asterisk.sh` for the reference pattern: it decides
the Caddy question *before* building firewall rules, not after, so the
answer is known in time (in droplet mode it hand-builds its own site block
and sets the same flag itself, for the reasons noted above).

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
internet. See `services/asterisk.sh` for the pattern.

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

**Companion doc files.** If `services/<name>.md` exists next to
`services/<name>.sh`, `write_readme` appends its contents automatically —
no per-service code needed to opt in, just add the file. It's outside
`setup.sh`'s `services/*.sh` glob so it never registers or runs on its own;
it's purely markdown that gets tacked onto the generated README. Use it for
walkthroughs that don't depend on anything chosen at install time (linking
steps in a third-party UI, multi-account setup, troubleshooting notes) —
content like that bloats the heredoc without adding anything install-specific.
Keep the heredoc for content that *does* depend on install-time values (the
actual port chosen, generated credentials, etc.); use `services/<name>.md`
for everything else. See `services/traccar.md` for the reference example.

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
`asterisk.sh` already auto-detects a local install (`if [ -d
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
`_asterisk_refresh_vendor_files`/`_asterisk_write_compose` in
`services/asterisk.sh` for the reference pattern.

`cancel` must leave the install completely untouched — it's the default for
a reason (a stray Enter on a service you're just checking on shouldn't
trigger anything). `fresh` runs the exact same flow a first-time install
would, prompts included.

## Multi-instance services

Any service where running two genuinely separate copies is a real use case
(two Mattermost teams, two WordPress sites, two Traccar fleets, a
music-only Emby alongside a movies one) should support it — this isn't
opt-in per service, it's the default shape for anything that stores its
own data and isn't inherently single-tenant (skip it for things like
`caddy` or `crowdsec`, where a second instance wouldn't mean anything).

**The pattern** (see `services/mattermost.sh` for the original, and
`services/audiobookshelf.sh`/`services/emby.sh`/`services/mealie.sh`/
`services/traccar.sh`/`services/wordpress.sh` for more examples): the first
instance keeps the plain name/directory/container/ports exactly as they'd
be without any of this — zero behavior change for anyone with a single
instance already installed. Only *choosing* to add a second introduces
suffixed naming. `services/wordpress.sh` is the one exception that requires
a name from every instance including the first — reasonable for a
brand-new service with no existing single-instance installs to stay
compatible with, but not the default choice for an established service.

```bash
local DIR="$DOCKER_DIR/myservice"
local INSTANCE_SUFFIX="" CONTAINER="myservice"
local WEB_PORT="9000"

if [ -d "$DIR" ]; then
    echo ""
    echo "  MyService is already installed at $DIR."
    echo "    1) Manage that install (update / full reinstall / cancel)"
    echo "    2) Add a NEW, separate MyService instance alongside it (its own"
    echo "       server and data — full isolation)"
    echo ""
    local _TOP_CHOICE=""
    prompt_text "  Choice [1/2]:" "1" _TOP_CHOICE
    if [ "$_TOP_CHOICE" = "2" ]; then
        local _suffix=""
        while true; do
            prompt_text "  Short name for the new instance (letters/numbers/hyphens):" "" _suffix
            _suffix="$(echo "$_suffix" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
            [ -z "$_suffix" ] && { log_warning "Name can't be empty."; continue; }
            [ -d "$DOCKER_DIR/myservice-$_suffix" ] && { log_warning "myservice-$_suffix already exists — pick another name."; continue; }
            break
        done
        INSTANCE_SUFFIX="$_suffix"
        DIR="$DOCKER_DIR/myservice-$_suffix"
        CONTAINER="myservice-$_suffix"
        while ss -tlnH "sport = :${WEB_PORT}" 2>/dev/null | grep -q .; do
            WEB_PORT=$((WEB_PORT + 1))
        done
        log_info "New instance: $DIR (port $WEB_PORT)"
    fi
fi
```

Everything downstream — `container_name`, `hostname`, published ports, the
Caddy subdomain default passed to `configure_caddy_for_service`, log/prompt
text, the generated README's title — reads from `$CONTAINER`/`$WEB_PORT`/
`$INSTANCE_SUFFIX` instead of the literal service name, so it's already
correct for either the first instance or a named one with no further
branching.

**Databases: dedicated per instance, not shared.** `services/wordpress.sh`
started as one shared MariaDB container with a separate database per site
(same resource-sharing idea as the shared `coturn` below), and was
deliberately changed away from that. The reason generalizes: Kopia's
generic backup (`services/backup.sh`) stops a service's *container* to get
a consistent snapshot, so a shared database instance backs up — and would
have to be restored — as one unit covering every instance's data at once,
not one instance independently. A dedicated database container per
instance costs more RAM (a full container each instead of one instance
split across several) in exchange for real backup/restore isolation. Data
is typically isolated either way (separate database + user regardless), so
the shared-vs-dedicated choice is about the container/process and its
backup blast radius, not about the data being mixed. Default to dedicated
per instance; only share if a service's own architecture makes that
awkward and the resource savings are worth the backup-coupling tradeoff.

**Ports beyond a single one need more than one `ss` scan, but never
port-by-port for a large range.** A service publishing two or three fixed
ports (`services/emby.sh`, `services/mattermost.sh`'s web+Calls-UDP ports)
just runs the same `ss` scan once per port. A service publishing a large
*range* (`services/traccar.sh`'s ~150-port device-protocol range) can't be
scanned port-by-port — instead shift the whole range by a fixed offset per
instance, sized off how many `$DOCKER_DIR/<name>*` directories already
exist (`find "$DOCKER_DIR" -mindepth 1 -maxdepth 1 -name '<name>*' -type d
| wc -l` — the `-mindepth 1` matters, since without it `find` also matches
`$DOCKER_DIR` itself if its own basename happens to start with the service
name). Check whether the *first* instance's range carves out exclusions for
another service's fixed ports (traccar's does, for Asterisk's AMI/SIP
ports) — a large enough offset on additional instances usually clears those
same fixed ports automatically, so the exclusions typically don't need to
be repeated for instance 2+.

**Docker labels used by sidecar tooling need per-instance scoping too, not
just container names.** `services/traccar.sh`'s `autoheal` sidecar watches
containers by a Docker label that's visible host-wide, not scoped to a
compose project — two instances both using the literal `autoheal` label
would each try to restart the *other* instance's container too. Give the
label itself a per-instance value (`autoheal-<name>-<suffix>`) and point
that instance's `autoheal` container at the same value via
`AUTOHEAL_CONTAINER_LABEL`, the same way container names get suffixed.

**Verify port/count logic by actually running it, not just by reading it.**
Both real bugs caught while building this pattern into
`services/traccar.sh` — the `find` matching `$DOCKER_DIR` itself, and the
port-scan needing a genuinely free-vs-taken state to prove it increments —
were things code review alone would have missed. Install two instances in
sequence (a fake `docker`/`ss` shim standing in for a live daemon is fine)
and confirm the second one's directory, container names, and ports are
actually distinct before trusting the logic.

## Chaining into another service from within your own

A service can call another service's `install_<name>()` directly as a
convenience step at the end of its own flow, instead of making the user
remember to separately run `sudo ./setup.sh <other-name>` afterward.
`services/asterisk.sh` does this for
`services/security-dashboard.sh` and `services/pstn-trunk.sh` — after
Asterisk itself is installed/updated, it asks once whether to also set up
the dashboard and/or a PSTN trunk (or, if either is already installed,
silently re-invokes it so it gets refreshed as part of the same run — its
own `prompt_reinstall_mode` gate decides update vs. skip, so this never
re-asks the target service's detailed prompts unless the user is actually
setting it up fresh).

The target service **keeps its own `register_service` call** — it stays
independently selectable/invocable exactly as before (`sudo ./setup.sh
pstn-trunk` still works standalone). Chaining is purely additive, not a
replacement for the target's own entry point, so nothing breaks for anyone
already relying on running it directly.

Guard every cross-file call with `declare -F`, since a service can also run
completely standalone (`sudo bash asterisk.sh`, no `setup.sh`, no sibling
`services/*.sh` files sourced at all):

```bash
if declare -F install_security-dashboard >/dev/null 2>&1; then
    install_security-dashboard
fi
```

Only chain in one direction, and only when the relationship is genuinely
one-way (the target is meaningless without the caller already installed —
`pstn-trunk.sh` itself says so in its own error message when Asterisk isn't
present). Don't have both sides call each other.

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

**`network_mode: host` services (e.g. `asterisk`) don't join
`caddy_net` at all** — Caddy reaching them (or anything else on the host
network) needs `host.docker.internal:PORT` in the Caddyfile, not
`localhost:PORT` or a container name. Caddy's own compose file
(`services/caddy.sh`) sets `extra_hosts: host.docker.internal:host-gateway`
so that hostname resolves; `configure_caddy_for_service`'s bare-port upstream
case already does this for you — don't hand-roll `localhost:PORT` in a
Caddy site block.

## Shared coturn (TURN/STUN) relay

Any service that needs a TURN server for WebRTC/SIP NAT traversal shares
**one** coturn instance (`services/coturn.sh`) instead of running its own.
This exists because it didn't always: `asterisk` and `mattermost` used to
each embed a dedicated coturn container (`network_mode: host`, each with its
own relay port range) — confirmed live, their default ranges overlapped by
~100 UDP ports, so running both on one box meant a coin-flip over which
service's active call lost its media relay. One shared instance with one
port range removes the collision instead of just moving it around.

**Use `ensure_coturn_user` (`lib/common.sh`), not your own coturn container:**

```bash
ensure_coturn_user "my-service"
if [ -n "$COTURN_HOST" ]; then
    # Out-params (not `local` — read them after the call returns, same
    # convention as configure_caddy_for_service's CADDY_SERVICE_*):
    #   COTURN_HOST COTURN_PORT COTURN_USERNAME COTURN_PASSWORD
else
    # coturn unavailable (not installed and services/coturn.sh isn't loaded
    # to chain-install it — e.g. this file run fully standalone) — degrade
    # gracefully. Don't block the rest of your install on this.
fi
```

`ensure_coturn_user` chain-installs `services/coturn.sh` the first time
*any* service needs one (guarded with `declare -F install_coturn`, same
pattern as the asterisk → security-dashboard chaining below), then
registers a dedicated long-term-credential username/password for your
consumer name. The credential is cached in
`~/docker/coturn/users/<consumer>.env`, so calling this again on a rerun
reuses the same credential instead of minting a new one and silently
orphaning whatever client already has the old one configured.

**Why long-term credentials (`--lt-cred-mech`), not the REST-API/HMAC mode
(`--use-auth-secret`) some WebRTC apps default to:** coturn does not support
running both auth mechanisms on one instance at once — enabling
`--use-auth-secret` silently overrides `--lt-cred-mech` server-wide, which
would break every static-credential consumer. `--lt-cred-mech` supports any
number of named users out of the box, which is the actual shape a
shared-multi-consumer coturn needs. If the service you're adding only
exposes an HMAC-secret TURN setting in its own UI (no plain
username/password option), check its docs for an alternative field first —
Mattermost's Calls plugin looked HMAC-only at a glance but also accepts a
fixed username/credential pair via its "ICE Servers Configurations" JSON
field (see `services/mattermost.sh` for the exact format). Don't fall back
to a second coturn instance just because the first field you found expects
a shared secret.

**Migrating an existing service from its own embedded coturn:** don't do it
silently. An `update` rerun must keep whatever coturn shape a service
already has — detect the existing embedded container (e.g. `grep -q '^
coturn:' docker-compose.yml` before regenerating it) and preserve it
exactly, the same non-destructive rule as every other `update` path in this
file. Only switch to the shared coturn on an explicit `fresh` reinstall, and
warn before doing it — the TURN username/password changes, and any
already-configured client (a SIP phone, a browser session) keeps the old
credentials until it's reconfigured. See `services/asterisk.sh`'s
`USE_EMBEDDED_COTURN` handling for the reference pattern.
