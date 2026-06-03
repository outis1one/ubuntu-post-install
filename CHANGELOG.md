# Changelog

All notable changes to this project. Versions follow `MAJOR.MINOR.PATCH`.
The project is pre-1.0 while the modular system reaches parity with the
monolithic `ubuntu-post-install-*.sh` scripts.

## [0.9.5] - 2026-06-03

### Added
- `services/minecraft.sh` *(gaming)* — full port of the standalone
  `setupminecraft.sh`, converted to the per-service-folder model. Each server
  is its own `~/docker/<instance>/` with a standalone compose, so multiple
  servers run side by side (port auto-bumps 25565→25566…). Preserves all the
  niceties: Fabric/Quilt/Paper/Vanilla/Forge flavours, the live Modrinth
  version/mod-availability picker, curated mods, Vanilla Tweaks datapacks,
  whitelist UUID pre-population, LuckPerms bootstrap, Chunky pre-gen, playit.gg
  tunnel, generated MINECRAFT_NETWORKING.md / CLIENT_MODS.md, and the
  client-mods download web page (its own folder + compose).

### Fixed
- Minecraft compose env-block emission (trailing-newline bug from the original
  that glued `ports:` onto the last env line — now valid YAML).

### Notes
- `gaming` group now: `js99er`, `minecraft`, `wolf`.
- Still pending: `whitelist` Minecraft helper; migrating the ~65 monolith
  services into `services/`.

## [0.9.4] - 2026-06-03

The first versioned release. Introduces the **modular post-install system** so
you can install the whole box at once *or* run a single service, with one
source of truth (no per-service script duplication, nothing generated).

### Added
- `setup.sh` dispatcher: interactive menu, run-one (`sudo ./setup.sh <name>`),
  `--list`, `--dry-run`, `--unattended`, `--version`.
- `lib/common.sh`: shared helpers (logging, prompts, ownership, Caddy wiring)
  and a self-registration service registry — one implementation of each.
- Service modules (each its own `~/docker/<name>/` folder + standalone compose):
  - `base` — essential CLI packages, now including **glow**.
  - `glow` — terminal markdown reader (charmbracelet), standalone too.
  - `homeassistant` — bridge/host networking choice, `trusted_proxies` pre-seed.
  - `js99er` *(gaming)* — self-hosted TI-99/4A emulator (Selkies launcher tie-in removed).
  - `wolf` *(gaming)* — Games-on-Whales Moonlight streaming (wolf-pair dropped; `pin` workflow kept).
  - `backup` — Kopia encrypted backups (paths adapted to `~/docker`).
- `MODULAR.md` documenting the architecture, how to add a module, migration status.
- Service groups: `base` / `homelab` / `gaming` / `backup`.
- `glow` also added to the live `-crowdsec` monolith scripts' essential packages.

### Known gaps / next (0.9.5)
- `minecraft` module (rich, multi-instance port of `setupminecraft.sh`) — not yet
  written; the background port hit a session limit.
- `whitelist` Minecraft helper not yet shipped.
- ~65 services still live only in the monolith, to migrate into `services/`.

### Earlier history (pre-versioning)
- Removed Keycloak; standardized on Authelia for SSO.
- Added `-no-keycloak` and `-crowdsec` script tiers (originals kept as the
  evolution record).
- CrowdSec replaces fail2ban in the `-crowdsec` tier (SSH + Caddy, geo + IP
  reputation, optional ntfy ban alerts).
- Home Assistant added to the `-crowdsec` tier.
