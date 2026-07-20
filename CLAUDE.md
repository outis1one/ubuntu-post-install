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
3. Define `install_<name>()` (hyphens → underscores in function name)

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
`services/asterisk-do.sh` (and their `_asterisk_*` counterparts in
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

**`network_mode: host` services (e.g. `asterisk`/`asterisk-do`) don't join
`caddy_net` at all** — Caddy reaching them (or anything else on the host
network) needs `host.docker.internal:PORT` in the Caddyfile, not
`localhost:PORT` or a container name. Caddy's own compose file
(`services/caddy.sh`) sets `extra_hosts: host.docker.internal:host-gateway`
so that hostname resolves; `configure_caddy_for_service`'s bare-port upstream
case already does this for you — don't hand-roll `localhost:PORT` in a
Caddy site block.
