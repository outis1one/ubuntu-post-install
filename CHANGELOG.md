# Changelog

All notable changes to this project. Versions follow `MAJOR.MINOR.PATCH`.

## [0.9.5] - 2026-06-03

### Changed
- VERSION reset from 1.0.0 to 0.9.5 — versioning now tracks `setup_v<X.Y.Z>.sh`
  snapshot files. Each release creates a new numbered file (old files stay). The
  current `setup.sh` is always the live version; `setup_v0.9.5.sh` is the first
  named snapshot.

### Added
- `setup_v0.9.5.sh` — first versioned snapshot of `setup.sh`. Future changes
  produce `setup_v0.9.6.sh`, etc. Previous snapshots are never removed.

## [1.0.0] - 2026-06-03

### Milestone: full parity with the monolith

Every service from `ubuntu-post-install-24.04-crowdsec.sh` is now a module.
The modular system (`setup.sh` + `services/`) is the primary install path.
The monolith is retained as a frozen evolution record.

### Added
- `services/linux-to-sync.sh` *(extras)* — clones the private
  `outis1one/linux-to-sync` repository to `~/linux-to-sync` via SSH key or
  GitHub PAT (PAT is stripped from the remote URL after clone for security).
  `is_installed` marker checks `~/linux-to-sync/.git`.
- Updated `MODULAR.md` migration table to show the completed module inventory
  grouped by category.

## [0.9.11] - 2026-06-03

### Added
- **Utilities batch** — 8 service modules migrated from the monolith:
  - `services/mealie.sh` *(utilities)* — Recipe manager & meal planner. PUID/PGID baked;
    default creds noted (change immediately). Port 9925 → internal 9000.
  - `services/actualbudget.sh` *(utilities)* — Open-source personal finance (Actual Budget).
    Minimal container; bank sync via SimpleFIN optional. Port 5006.
  - `services/traccar.sh` *(utilities)* — GPS tracking server for phones, vehicles, assets.
    Ships a starter `config/traccar.xml` with H2 embedded DB. Port 8082 + 5000-5150 device
    protocols (TCP+UDP).
  - `services/fmd.sh` *(utilities)* — FindMyDevice server for Android. Generates a random
    admin password; mobile app from F-Droid (not Play Store). Port 8084.
  - `services/ddclient.sh` *(utilities)* — Dynamic DNS updater; no web UI. Ships a
    `config/ddclient.conf` template covering Cloudflare, DuckDNS, No-IP. Default start
    prompt is "n" — edit config first.
  - `services/wg-easy.sh` *(utilities)* — WireGuard VPN with web UI. Auto-detects public
    IP for `WG_HOST`; generates random password; requires `NET_ADMIN` + `SYS_MODULE` caps
    and `ip_forward` sysctl. Ports 51820/udp (VPN) + 51821/tcp (web).
  - `services/meshcentral.sh` *(utilities)* — Self-hosted remote device management server.
    Prompts for hostname (domain/IP for agent connections). Ports 4430 (HTTPS) + 4433 (agent).
  - `services/magicmirror.sh` *(utilities)* — Modular smart mirror / info dashboard.
    Multi-instance (1-3, ports 8081-8083); each instance in `~/docker/magicmirror/<N>/`.
    Optionally copies existing `config.js` and auto-clones `MMM-*` third-party modules
    from GitHub (tries MichMich → bugsounet → MagicMirrorOrg org order).
- **Cameras batch** — 2 service modules:
  - `services/frigate.sh` *(cameras)* — AI-powered NVR with object detection. Auto-enables
    `/dev/dri/renderD128` for hardware-accelerated detection when present; ships a starter
    `config/config.yml` with camera examples. `privileged: true` + 1 GB tmpfs cache.
    Ports 5000 (web), 8554 (RTSP restream), 8555 (WebRTC). Default start prompt is "n" —
    edit config first.
  - `services/frigate-notify.sh` *(cameras)* — Push notification sidecar for Frigate events.
    Auto-detects local Frigate and ntfy installs to pre-fill config defaults. Supports ntfy,
    Pushover, Discord, Gotify, Telegram, and more. No web UI.

## [0.9.10] - 2026-06-03

### Added
- **Media batch** — 6 service modules migrated from the monolith:
  - `services/jellyfin.sh` *(media)* — Free media server (movies, TV, music). Auto-detects
    `/dev/dri/renderD128` and enables VAAPI hardware transcoding with the render GID when
    present; falls back to CPU transcoding otherwise. Ports 8096, 1900/udp (DLNA),
    7359/udp (discovery).
  - `services/emby.sh` *(media)* — Emby media server. UID/GID baked from the install-time
    user; HW transcoding block left commented (uncomment `/dev/dri` once GPU confirmed).
    Ports 8096 (web) and 8920 (HTTPS).
  - `services/audiobookshelf.sh` *(media)* — Audiobook & podcast server. Separate audiobooks
    and podcasts paths; podcasts folder defaults to `./podcasts` inside the service dir.
    Port 13378.
  - `services/arm.sh` *(media)* — Automatic Ripping Machine for DVDs, Blu-rays, CDs.
    Detects optical drives at install time (`/dev/sr*`); runs with `privileged: true`.
    Ripped output split into movies/ and music/. Port 8080.
  - `services/lyrion.sh` *(media)* — Lyrion Music Server (formerly LMS) for Squeezebox
    devices, the Squeezer app, and Chromecast. Uses `network_mode: host` so UDP discovery
    works without manual port mapping. Port 9000.
  - `services/immich.sh` *(media)* — Self-hosted photo & video backup (like Google Photos).
    Full multi-container stack (immich-server, immich-machine-learning, valkey/redis,
    postgres). Two library strategies: (1) unified — all photos in one place with an
    auto-generated `import-photos.sh` helper that handles admin account creation, API key
    generation, storage template config, and CLI upload; (2) external — existing photos
    indexed read-only, new uploads separate. Port 2283.

## [0.9.9] - 2026-06-03

### Added
- **New `extras` category** for non-Docker add-ons sourced from other repos —
  things that build/install on the host instead of running as a container.
  Inserted into `CATEGORY_ORDER` between `gaming` and `backup`.
- `services/silent-send.sh` *(extras)* — installs the **Silent Send** browser
  extension (redacts PII before it's sent to AI chatbots). Installs the build
  toolchain (git, Node.js ≥18 via NodeSource, npm), clones
  `outis1one/silent-send` to `~/silent-send`, runs `npm install` so the Firefox
  build/sign tooling (`web-ext`) is ready, optionally builds a signed Firefox
  `.xpi` (with Mozilla API creds), and prints load-unpacked / build instructions
  per browser. README written to the checkout. No server/container.
- `is_installed` marker for `silent-send` (checks `~/silent-send/.git`).

## [0.9.8] - 2026-06-03

### Added
- `services/wolf-pair.sh` *(gaming)* — browser-based Moonlight pairing UI for
  Wolf. Builds a tiny Python HTTP container (`python:3.12-alpine` + `docker-cli`)
  that watches `docker logs wolf` for the current pairing secret and serves a
  PIN entry form on port 8090. Eliminates the `./manage.sh pin` CLI workflow —
  open `http://<server>:8090`, type the 4-digit PIN, done. Runs with
  `network_mode: host` so it can reach Wolf's `/pin/` API at `localhost:47989`;
  mounts the Docker socket read-only for log access. Optional Caddy subdomain.

## [0.9.7] - 2026-06-03

### Added
- `services/caddy.sh` *(homelab)* — Caddy reverse proxy + automatic HTTPS, own
  `~/docker/caddy/` folder (compose + starter Caddyfile + README). Services add
  their site blocks to its Caddyfile.
- `services/crowdsec.sh` *(homelab)* — system-level intrusion prevention
  (agent + firewall bouncer + Caddy log acquisition + optional ntfy ban alerts);
  README in `~/docker/crowdsec/`.
- **Guided menu redesign** in `setup.sh`:
  - Prints the **required** set (essential packages incl. glow + a Docker check)
    up front and lets you **cancel** before anything changes.
  - Offers **Caddy first** (most services depend on it).
  - **Category menu loop**: pick a category → checklist (already-installed shown
    as `[installed]`) → install → back to the menu for the next category, until
    you choose Done. whiptail UI with a plain-text fallback.

### Changed
- **Categories** reorganized: `base · homelab · utilities · media · cameras ·
  gaming · backup`. Moved ntfy, filebrowser, portainer, uptimekuma, watchtower
  to `utilities`. Within `homelab`, Caddy → CrowdSec → Authelia sort first.

## [0.9.6] - 2026-06-03

### Added
- **Per-service README generation.** New `write_readme` helper in
  `lib/common.sh`; every module now writes a `README.md` into its
  `~/docker/<service>/` folder (what it is, access URL, start/stop, data
  location, reverse-proxy notes) — so each service folder is self-documenting.
- Migrated 6 services from the monolith into modules (all in the `homelab`
  group, each with a README):
  - `authelia` — SSO + 2FA portal, ported from the `authelia-setup` repo + the
    monolith's working block: prompts for domain/SMTP, generates
    jwt/session/storage secrets + the admin Argon2 hash, writes
    compose/config/users, creates `caddy_net`, and injects the forward-auth
    snippet + portal block into the Caddyfile. Won't clobber an existing install.
  - `filebrowser` (8085), `ntfy` (8090), `uptimekuma` (3001),
    `portainer` (9443), `watchtower` (no web port).

### Notes
- `homelab` group now: authelia, filebrowser, homeassistant, ntfy, portainer,
  uptimekuma, watchtower.
- Remaining monolith services still to migrate: ActualBudget, ARM,
  AudioBookshelf, Caddy, CrowdSec, Emby, FindMyDevice, Frigate, Frigate-Notify,
  Immich, Jellyfin, Lyrion, MagicMirror, Mealie, MeshCentral, Traccar, ddclient,
  wg-easy.

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
