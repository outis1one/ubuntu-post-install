# HANDOFF — modular migration status

**Version:** 0.9.7  ·  **Branch:** `claude/happy-volta-RPhbD`
**Read also:** `CHANGELOG.md` (per-version detail), `MODULAR.md` (architecture).

## Where we are

We're migrating a giant monolithic installer into a **modular system**:
- `setup.sh` — the one dispatcher (menu + run-one). `lib/common.sh` — shared
  helpers + the service registry. `services/<name>.sh` — one file per service.
- Run all: `sudo ./setup.sh` (required gate → Caddy offer → category menu loop).
  Run one: `sudo ./setup.sh <name>`. List: `./setup.sh --list`. `--version`.
- Every service installs to its own `~/docker/<name>/` with its own
  `docker-compose.yml` **and a generated `README.md`** (via `write_readme`).
- Nothing is generated/duplicated: a service = one committed file in `services/`.

The three monolith tiers still exist, frozen as history:
`ubuntu-post-install-{24.04,26.04}.sh` (original, w/ Keycloak),
`*-no-keycloak.sh`, `*-crowdsec.sh` (current "install everything" + glow).
The `-crowdsec.sh` tier is the migration source of truth.

## Module status

**Done (16 modules in `services/`):**
| Group | Modules |
|-------|---------|
| base | base, glow |
| homelab | caddy, crowdsec, authelia, homeassistant |
| utilities | filebrowser, ntfy, portainer, uptimekuma, watchtower |
| gaming | wolf, minecraft, js99er |
| backup | backup |

**Pending — migrate from `ubuntu-post-install-24.04-crowdsec.sh` (find by `# ---- NAME ----`):**
| Target group | Services to migrate |
|------|---------|
| media | jellyfin, emby, audiobookshelf, immich, arm, lyrion |
| cameras | frigate, frigate-notify |
| utilities | actualbudget, mealie, traccar, findmydevice, magicmirror, wg-easy, ddclient |
| (misc) | meshcentral (remote-mgmt server) |

Also still monolith-only (Phase-1 / system, not yet modularized): SSH config,
Docker install, Samba, VPNs (Tailscale/NetBird/WireGuard), RustDesk, TeamViewer,
MeshCentral agent, UFW. Decide later whether these become `required`/system
modules.

## Final taxonomy (categories)

`base` (required) · `homelab` · `utilities` · `media` · `cameras` · `gaming` ·
`backup`. Menu order is set in `setup.sh:CATEGORY_ORDER`. Within `homelab`,
`SERVICE_PRIORITY` puts caddy → crowdsec → authelia first. `media`/`cameras`
won't appear in the menu until they have ≥1 module (no empty categories).

Note: filebrowser/portainer/uptimekuma/watchtower were placed in `utilities`
(weren't in the original taxonomy list) — move if desired by editing their
`register_service ... <group> ...` line.

## OPEN ITEM — wolf-pair (action needed from you)

`wolf-pair` (the FQDN device-pairing page for Wolf/Moonlight) was **dropped**
when Wolf was ported, because its source wasn't available. You said you worked
hard on it and will **upload `wolf-pair/server.py` + `wolf-pair/Dockerfile`
(and anything else it needs) in the next chat.**

To re-add it: create `services/wolf-pair.sh` (group `gaming`) that builds the
wolf-pair container in `~/docker/wolf-pair/`, wires it to reach Wolf, opens its
port, and offers a Caddy block for the pairing FQDN. Wolf's `manage.sh pin` is
the current stopgap.

## Module contract (for consistency when adding/migrating)

```bash
#!/bin/bash
register_service <name> <group> "Description" [port]   # one line → appears in menu
install_<name>() {
    require_docker || return 1                          # docker services only
    local DIR="$DOCKER_DIR/<name>"
    [ "$DRY_RUN" = true ] && { echo "[DRY-RUN] Would create $DIR ..."; return 0; }
    mkdir -p "$DIR"; ensure_docker_dir_ownership "$DIR"; cd "$DIR" || return 1
    cat > docker-compose.yml << 'YAML'
    ...
YAML
    configure_caddy_for_service "Name" "PORT" "subdomain"   # optional
    write_readme "$DIR" <<MD
    # Name
    ...how to start/stop, access URL, data location...
    MD
    prompt_yn "Start now? (y/n):" "y" S && docker compose up -d
}
```
Rules: **no `set -e`**; don't redefine `log_*`/colors (in common.sh); drop the
monolith's `WHIPTAIL_USED`/`INSTALL_*`/`check_service_exists` wrappers; use
`prompt_yn`/`prompt_text`; honor `DRY_RUN` with an early return before any
prompt/curl/apt/docker. System (non-docker) modules: see `crowdsec`/`backup`.

Verify each: `bash -n services/<name>.sh`, `./setup.sh --list`,
`sudo ./setup.sh --dry-run --unattended <name>` (must exit 0).

## Workflow reminders
- Per-version: bump `VERSION`, add a `CHANGELOG.md` entry, commit, push to
  `claude/happy-volta-RPhbD`.
- Your loop: build nice standalone `setup-*.sh` elsewhere → upload here → it gets
  "massaged" into a `services/<name>.sh` module (wrap in `install_`, use shared
  helpers, per-folder + README, register).

## Suggested next steps
1. Add `wolf-pair` once you upload its files.
2. Migrate **media** batch (jellyfin, emby, audiobookshelf, immich, arm, lyrion) → v0.9.8.
3. Migrate **cameras** (frigate, frigate-notify) → v0.9.9.
4. Migrate remaining **utilities** (actualbudget, mealie, traccar, findmydevice,
   magicmirror, wg-easy, ddclient).
5. Decide how Phase-1/system items (VPNs, Samba, remote-access) fit (required vs
   their own category).
