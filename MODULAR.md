# Modular Post-Install (`setup.sh` + `lib/` + `services/`)

This is the new structure that gives you **one source of truth** *and* the
ability to **run just the service you want** — without maintaining a pile of
near-duplicate standalone scripts.

## Why

The full `ubuntu-post-install-*.sh` scripts are great as a "run once, set up the
whole box" experience, but to add or update one service you edit a 300 KB file
(in two or three places). The separate `setup-*.sh` scripts are easy to run for
one service, but duplicate logic and drift apart.

The fix is **not** to generate per-service scripts from the monolith (that just
triples the maintenance surface). It's to have **one implementation per service**
in a module, shared helpers in a library, and a thin dispatcher with two entry
points.

## Layout

```
setup.sh              # dispatcher: menu, run-one, --list, --dry-run, --unattended
lib/common.sh         # shared helpers: logging, prompts, ownership, Caddy wiring,
                      #   the service registry. THE single source of truth.
services/
  base.sh             # essential CLI packages (incl. glow)
  homeassistant.sh    # Home Assistant
  ...                 # one file per service
```

## Usage

```bash
sudo ./setup.sh                  # interactive menu (whiptail or text)
sudo ./setup.sh homeassistant    # install one service
sudo ./setup.sh base glow        # install several
./setup.sh --list                # list services, grouped
sudo ./setup.sh --dry-run --unattended minecraft   # preview, no prompts
```

## Anatomy of a service module

Each `services/<name>.sh` does exactly two things: **register** itself and
define **install_<name>**.

```bash
#!/bin/bash
register_service myapp homelab "What it does" 1234   # name group description [port]

install_myapp() {
    require_docker || return 1
    local DIR="$DOCKER_DIR/myapp"
    [ "$DRY_RUN" = true ] && { echo "[DRY-RUN] Would create $DIR"; return 0; }
    mkdir -p "$DIR"; ensure_docker_dir_ownership "$DIR"; cd "$DIR" || return 1
    cat > docker-compose.yml << 'YAML'
    ...
YAML
    configure_caddy_for_service "MyApp" "1234" "myapp"   # optional reverse proxy
    prompt_yn "Start now? (y/n):" "y" START && docker compose up -d
}
```

Helpers available from `lib/common.sh`: `log_info/success/warning/error`,
`prompt_yn`, `prompt_text`, `run_cmd`, `ensure_docker_dir_ownership`,
`generate_password`, `validate_password`, `configure_caddy_for_service`,
`require_root`, `require_docker`. Globals: `DOCKER_DIR`, `ACTUAL_USER`,
`ACTUAL_HOME`, `DRY_RUN`, `UNATTENDED`.

Every service installs to its **own folder** `~/docker/<name>/` with its **own
`docker-compose.yml`** (the DoTheEvo `selfhosted-apps-docker` layout) — never a
single shared compose file.

## Groups

`base` · `homelab` · `gaming` · `backup`. The menu and `--list` are grouped by
these. The **gaming** group (Wolf, js99er, Minecraft) makes this script a
sensible base for either a homelab box or a gaming box — install only what that
machine needs.

## Migration status

This is an incremental migration. The big `ubuntu-post-install-*-crowdsec.sh`
script remains the current "install everything" entry point until the modules
reach parity, at which point it is retired (like the `original` and
`-no-keycloak` tiers, which stay frozen as the evolution record).

| Module | Status |
|--------|--------|
| `base` (incl. glow) | ✅ done |
| `homeassistant` | ✅ done |
| `minecraft` (multi-instance, rich) | ⏳ porting from `setupminecraft.sh` |
| `wolf` (gaming) | ⏳ porting from `setupwolf.sh` |
| `js99er` (gaming) | ⏳ porting from `setupjs99er.sh` |
| `backup` (Kopia, cross-cutting) | ⏳ porting from `setupbackup.sh` |
| remaining ~65 services | ⏳ migrate from the monolith incrementally |
