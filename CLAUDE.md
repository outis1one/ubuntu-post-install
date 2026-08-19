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
`filebrowser`, `wg-easy`, `ntfy` (configurable), `gitea`

**Native OIDC login as an addition, not a Caddy gate — `gitea`'s pattern.**
Some apps with their own built-in login *also* have their own "add an
OAuth2/OIDC provider" setting — a genuinely different integration from
both the forward_auth gate above and the "Enable OpenID" client-registration
flow below. `services/gitea.sh`'s `_gitea_offer_authelia_sso()` is the
reference: if Authelia is installed, offers to register Gitea as an OIDC
client (via `services/authelia.sh`'s `_authelia_provision_oidc_client()` —
the same non-interactive, out-param-returning core that
`_authelia_add_oidc_client()`'s menu flow uses) and then runs `gitea admin
auth add-oauth` itself to add Authelia as an authentication source — no
manual web-UI copy-paste on either side, matching this repo's "no manual
wizard" philosophy elsewhere in gitea.sh (admin account/token creation).
Local login keeps working unchanged; this only adds an extra button on the
existing login page. Reuse `_authelia_provision_oidc_client()` (guarded by
`declare -F`, same convention as chaining into another service's
`install_<name>()`) for any future service with its own native OIDC field,
instead of duplicating Authelia's client-secret-generation/config-patching
logic again.

**Scoping a domain to specific users instead of every Authelia user.**
By default, any domain with an `access_control` rule at all is reachable by
every Authelia user (the existing catch-all `*.${AUTHELIA_DOMAIN}` rule).
`services/authelia.sh`'s `_authelia_scope_access(SERVICE_ID, DOMAIN)` is a
generic, reusable opt-in on top of that — call it right after *any* service
finishes being protected by Authelia, forward_auth gate or native OIDC
alike (it only cares about the domain, not the gating mechanism; see
`_gitea_offer_authelia_sso()` for the reference caller). Asks whether
access should stay universal or be scoped to specific usernames; if scoped,
creates a dedicated `<service_id>-only` group, adds every listed username
to it (creating accounts on the fly via
`_authelia_create_user_noninteractive()` for names that don't exist yet,
printing their temp password), and inserts two rules *above* the general
catch-all — allow that group on this domain, deny that group on every
other protected domain. Idempotent: reruns against an already-scoped
domain just report the existing group instead of duplicating rules.
Guard every cross-file call with `declare -F`, same convention as the OIDC
helper above — a service can run standalone with authelia.sh never sourced.

`_authelia_report_access_scope()` (menu option 6 on an existing Authelia
install) is the read side: lists who has universal access versus who's
scoped to which service(s), and offers to promote a scoped user back to
universal by removing them from their `-only` group(s) — a pure users.yml
edit, since universal access is just the *absence* of a restricting group,
not a rule of its own.

`services/gitea.sh`, `services/mealie.sh`, and `services/actualbudget.sh`
call `_authelia_scope_access()` so far. The other services that already
offer a plain "Protect X with Authelia SSO?" prompt (`magicmirror`,
`wolf-pair`, `js99er`, `drum-rhythm-game`, `iopaint`, `paintplus`,
`stirling-pdf`, `wolf`) are natural, mechanical follow-ups — each just
needs one added call to `_authelia_scope_access` after its existing
`configure_caddy_for_service` step, once Gitea's integration has been
confirmed working live.

**Native OIDC support across the "has built-in auth" list — checked
against each app's real docs (2026-08), not assumed.** Don't extend this
pattern to a service without checking its own current settings first —
two of the ones below turned out to need actual verification to get
right (Portainer, ntfy), not general familiarity with the product:

| Service | Native OIDC? | Notes |
|---|---|---|
| `mealie` | Yes — wired up | Pure env vars (`OIDC_AUTH_ENABLED`, `OIDC_CLIENT_ID/SECRET`, `OIDC_CONFIGURATION_URL`), see `_mealie_offer_authelia_oidc()`. Redirect URI is `<BASE_URL>/login`. Needs a `--forwarded-allow-ips` entrypoint override when Caddy-fronted, or the generated redirect URI comes out `http://` even when actually served over `https://` — see the function's own comment. |
| `actualbudget` | Yes — wired up | Pure env vars (`ACTUAL_OPENID_DISCOVERY_URL`, `ACTUAL_OPENID_CLIENT_ID/SECRET`, `ACTUAL_OPENID_SERVER_HOSTNAME`), see `_actualbudget_offer_authelia_oidc()`. Redirect path `/openid/callback` (matches the existing preset in `_authelia_add_oidc_client()`'s menu). First OIDC login becomes the server owner if none is set yet — Actual's own behavior. |
| `immich` | Yes, not yet wired up | Real OAuth2/OIDC settings under Administration → Settings, backed by a `system-config` API (GET/PUT) — confirmed the API exists, but didn't confirm the exact request payload shape needed to set OAuth fields specifically. Needs one more verification pass against the live OpenAPI spec before automating; don't guess the payload. |
| `jellyfin` | Only via a third-party plugin | No official native OIDC. Community plugins exist (`jellyfin-plugin-sso`, `jellyfin-plugin-oidc`) but are web-UI-only — native mobile/desktop Jellyfin clients can't use them. A bigger lift than an env-var toggle (plugin install via Jellyfin's own plugin repo system); hold off until that's worth doing deliberately. |
| `homeassistant` | Only via a third-party HACS integration | No native core OIDC as of 2026 (open community discussion asking for it, not shipped). `hass-oidc-auth`/`hass-openid` exist as HACS-installed integrations — same "bigger lift" caveat as Jellyfin. |
| `portainer` | No (CE) | OAuth/OIDC is a **Business Edition** feature — this repo installs `portainer-ce` (confirmed in `services/portainer.sh`), which doesn't have it. CE's documented path is fronting it with `oauth2-proxy`, i.e. no different from the forward_auth pattern any no-built-in-auth service already uses — not "native OIDC" in the sense this section means. |
| `ntfy` | No | Checked ntfy's own config docs directly — no `auth-oauth2-*` keys exist. Only basic auth + access tokens + ACLs. (Worth a re-check on a future ntfy release if this matters to you — this class of feature does get added to self-hosted tools over time.) |
| `emby`, `audiobookshelf`, `meshcentral`, `traccar`, `uptimekuma`, `filebrowser`, `wg-easy` | Not individually re-verified | High-confidence no, based on general familiarity with each product rather than a fresh doc check this pass (unlike everything above, which was actually checked and in two cases contradicted assumption). Verify before wiring any of these in, the same way the checked ones were — don't extrapolate from this table's pattern.

**No built-in auth — should be protected:**
`magicmirror`, `wolf-pair`, `js99er`, `drum-rhythm-game`, `iopaint`,
`paintplus`, `stirling-pdf`, `wolf` (web UI). Each of these prompts
"Protect X with Authelia SSO? (y/n)" and passes `import authelia` as
`configure_caddy_for_service`'s extra block when accepted.

`security-dashboard` is Authelia-protected unconditionally (not asked —
baked into its own Caddy block, since it exposes Asterisk/CrowdSec
data). `asterisk` offers the same protection for its web admin, with a
choice between a local `import authelia` and a remote `forward_auth` (see
the remote-Authelia note earlier in this file).

`sky-cam` was previously listed here but has no Caddy integration or web
login of any kind — it's a non-Docker batch/cron script that renders
timelapse videos and posts them to Mattermost, so there's nothing on it
for Authelia to protect. Removed from this list; if it grows a web UI in
the future, add it back and wire up the same prompt other services here
use.

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

## Port collision avoidance

With 70+ services in this repo, several ship the same default port —
`emby` and `jellyfin` both default to 8096, `changedetection` and `frigate`
both default to 5000, `arm` and `nextcloud` both default to 8080. Nothing
enforced those defaults were actually free on the host: whichever service
started its container second would fail to bind ("port is already
allocated") instead of landing on the next free port. Confirmed live:
installing `jellyfin` after `emby` (or vice versa) writes a
`docker-compose.yml` claiming a port the other service's container already
holds, and it only fails at `docker compose up` time — not at install time,
and not with any warning from the installer itself.

**Every service that publishes a fixed host port must scan for a free one
before writing `docker-compose.yml` — on every install, not only when
adding an explicit additional instance of itself.** Two shared helpers in
`lib/common.sh` do the work:

```bash
port_in_use PORT [PROTO]        # true if something's already listening; PROTO defaults to tcp, pass "udp" for UDP-only ports
find_free_port VARNAME START [PROTO]   # scans upward from START, writes the free port back into VARNAME
```

Single-port services just call `find_free_port`:

```bash
local WEB_PORT="8080"
find_free_port WEB_PORT "$WEB_PORT"
...
      - "${WEB_PORT}:8080"     # host side scanned; container-internal side stays literal
```

Services with multiple ports that must move together (a web port + an
agent/RTSP/MQTT port, etc.) loop over `port_in_use` directly instead, the
same pattern `services/meshcentral.sh` and `services/unifi.sh` use:

```bash
while port_in_use "$WEB_PORT" || port_in_use "$AGENT_PORT"; do
    WEB_PORT=$((WEB_PORT + 1))
    AGENT_PORT=$((AGENT_PORT + 1))
done
```

On a normal single-install host this is a silent no-op — the default port
is free, so the variable comes back unchanged and nothing about the
install looks any different. It only changes behavior when something else
already holds the port, which is exactly the case that used to fail at
container-startup instead of being handled at install time.

**Standalone-mode stub.** Every service also carries a standalone
bootstrap fallback (`if [[ -f "$_COMMON" ]]; then source it; else <stubs>
fi`, for `sudo bash services/<name>.sh` with no sibling files sourced) that
duplicates the helpers it needs. `port_in_use`/`find_free_port` get the
same treatment — copy the same two function bodies into that `else` block,
matching how `log_info`, `prompt_text`, `configure_caddy_for_service`, etc.
are already duplicated there.

**Only the host side of a `"HOST:CONTAINER"` port mapping changes.** The
container-internal port is fixed by the application itself and stays a
literal number; only the host-published side becomes `${WEB_PORT}` (or
whatever the variable is named). Watch for the same literal number showing
up elsewhere in the file needing the same treatment: `configure_caddy_for_service`
calls (container-internal side stays literal; a *bare*-port host-networking
upstream, like `services/lyrion.sh`'s first instance, does need the
variable), generated companion scripts (`services/koha.sh`'s
`post-setup.sh`, `services/rustdesk.sh`'s relay-host messaging), `.env`
values baked into client-facing config (`services/wg-easy.sh`'s `WG_PORT`
env — WireGuard bakes the port into every generated peer config's
`Endpoint =` line, so it must track the *actual* published port, not just
the host-side compose mapping), and every `echo`/README line that prints
`http://localhost:<port>`.

**Quoted (`<< 'MD'`) README heredocs don't interpolate — check before
editing.** A `write_readme ... << MD` (unquoted) heredoc already
interpolates `${WEB_PORT}` directly. A quoted `<< 'MD'` heredoc doesn't,
and converting it means escaping *every* backtick used for inline-code
formatting (`` \`...\` ``) — miss one and bash tries to execute it as a
command substitution the next time the heredoc is read, the same class of
bug the coturn.sh backtick incident was (see `attic/coturn.sh`'s
`write_readme` call). For a README with only one or two backticks,
escaping them is fine. For one with many (`services/iopaint.sh`'s model
reference table), it's safer to leave the heredoc quoted and patch the
port into the *written* `README.md` afterward instead:
```bash
[ "$WEB_PORT" != "8100" ] && sed -i "s/localhost:8100/localhost:${WEB_PORT}/g" "$IOPAINT_DIR/README.md"
```

**`network_mode: host` services can only scan what the app itself lets you
override.** Host networking has no port *remapping* — whatever the app
binds to on its fixed internal port is what's exposed, so `find_free_port`
only helps for ports the app takes as configurable env vars.
`services/lyrion.sh`'s `HTTP_PORT` env is genuinely configurable (LMS
honors it as the actual bind port under host networking too — see its
`_HTTP_PORT_INTERNAL` handling, which must track the scanned port rather
than assuming bridge-mode's fixed `9000`), but its CLI (9090) and player
(3483) ports are hardcoded in the image with no override — a collision
there can only be warned about with `port_in_use`, not silently fixed.
`services/homeassistant.sh` is the same shape: bridge mode (the default)
scans freely; host mode (opt-in, for LAN device discovery) can only warn.

**Caddy is the one deliberate exception — never auto-scanned.**
`services/caddy.sh` keeps 80/443 fixed and only warns via `port_in_use` if
they're already taken. Every other service either points HTTPS clients at
Caddy implicitly (browsers assume 443) or gets routed through it by
domain; silently moving Caddy itself to a random port would leave nothing
listening at the address any client actually tries, which is strictly
worse than the collision it would be "fixing." If 80/443 are already
bound, that's a real conflict (another web server on the host) the user
needs to resolve directly.

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

## coturn (TURN/STUN) relay — dedicated per service, not shared

Any service that needs a TURN server for WebRTC/SIP NAT traversal runs its
**own dedicated** coturn container. There is no shared coturn service to
install or point at — `services/coturn.sh` was tried and retired; it's
parked at `attic/coturn.sh` (outside `services/*.sh`'s glob, so it never
registers or appears in the menu — see `attic/README.md`). Sharing one
instance saved a container per consumer (~40MB) but was a single point of
failure every consumer depended on, and needing a dedicated per-consumer
long-term-credential user added real setup complexity for a small RAM win.
Don't reintroduce it — give every new WebRTC/SIP-capable service its own
coturn, following the pattern below.

**The collision this pattern has to avoid:** `asterisk` and `mattermost`
each embed a dedicated coturn container (`network_mode: host`, each with
its own relay port range) — confirmed live, two independent coturns'
default ranges used to overlap by ~100 UDP ports, so running both on one
box meant a coin-flip over which service's active call lost its media
relay. Static default ranges alone don't solve this; something has to pick
non-overlapping ranges per box.

**Use `find_free_coturn_range` (`lib/common.sh`) to size the range, not a
hardcoded default:**

```bash
local MY_COTURN_MIN_PORT=49152 MY_COTURN_MAX_PORT=49252
find_free_coturn_range MY_COTURN_MIN_PORT MY_COTURN_MAX_PORT 100 49152
[[ "$MY_COTURN_MIN_PORT" != 49152 ]] && \
    log_info "Dedicated coturn relay range shifted to ${MY_COTURN_MIN_PORT}-${MY_COTURN_MAX_PORT} to stay clear of another coturn already on this box."
```

Unlike a single fixed host port (`find_free_port`'s job — coturn's relay
range isn't a statically bound listening socket you can detect with a live
`ss`/socket scan), `find_free_coturn_range` scans every `$DOCKER_DIR/*/.env`
for a `TURN_MAX_PORT=` line and starts the new range 50 ports past the
highest one found — so it works across every coturn-owning service on the
box (Asterisk, each Mattermost instance, yours), regardless of install
order. Persist the chosen range as `TURN_MIN_PORT=`/`TURN_MAX_PORT=` in your
own `.env` so later installs' scans see it, and on an `update` rerun read
those same keys back from the existing `.env` instead of re-scanning — a
live coturn container must never silently move to a different port range
(breaks in-flight/repeat sessions on whatever client already has the old
range's ports allowed through its own firewall/NAT). See
`services/asterisk.sh`'s and `services/mattermost.sh`'s `EMBEDDED_COTURN_MIN_PORT`/
`MM_COTURN_MIN_PORT` handling for the reference pattern, including the
`MODE != "update"` gate that scans only on a fresh install.

**Auth mode — long-term credentials (`--lt-cred-mech`) or HMAC
(`--use-auth-secret`), your choice per instance:** coturn doesn't support
running both on one instance at once, but since each service now owns its
instance outright, this is a free per-service choice — no shared-instance
constraint forcing one mode across every consumer. `services/asterisk.sh`
uses `--lt-cred-mech` (fixed username/password, simplest to bake into a SIP
device's config); `services/mattermost.sh` uses `--use-auth-secret` (HMAC),
matching the Calls plugin's own "TURN Static Auth Secret" field. Check the
consuming app's own TURN settings UI for which fields it actually exposes
before picking.

**Legacy installs still on the old shared coturn:** an `update` rerun on an
install that predates this repo's dedicated-coturn-only model (no `coturn:`
block in its `docker-compose.yml`) must not try to silently migrate or
"heal" it — there's no shared coturn service left in this repo to heal it
against. Leave it running exactly as-is (an `update` never touches `.env`
anyway) and point at a full/fresh reinstall as the migration path, which
generates a new dedicated coturn container with fresh credentials. See the
`_HAD_EMBEDDED_COTURN` handling in `services/asterisk.sh` and
`services/mattermost.sh` for the reference pattern — detect via `grep -q
'^  coturn:' docker-compose.yml` before regenerating it, same as any other
non-destructive `update` path in this file.
