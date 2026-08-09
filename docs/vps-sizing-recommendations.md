# VPS sizing & recommended services

Reference notes from sizing this repo's services against real VPS plans.
Not project documentation for contributors — a planning record for picking
services against a given vCPU/RAM/disk budget.

## How to size a VPS for this repo's services

For this class of self-hosted workload (web apps, a PBX, a few Docker
containers — no video transcoding, no ML inference), **RAM is almost always
the binding constraint, not CPU or disk.** CPU only matters once something is
transcoding video, mixing many conference audio streams, or running local
AI inference — none of which apply to most services in this repo. Disk only
matters once local media storage is involved.

Rough per-service RAM budget, idle:

| Kind of service | ~RAM |
|---|---|
| OS + Docker daemon baseline | 300-500MB |
| JVM apps (Traccar, UniFi) | 350-500MB |
| App with its own Postgres/MariaDB (Mattermost, Nextcloud, Immich) | +150-250MB for the DB alone, on top of the app |
| Lightweight single-binary apps (Go/Rust — ntfy, vaultwarden, wg-easy, homebox, actualbudget, syncthing, portainer, coturn) | 20-150MB each |
| Headless-Chrome-backed apps (archivebox, changedetection's JS mode) | 300-500MB+ |

Rules of thumb:
- Keep at least 25-30% of total RAM free at idle for burst load (image
  pulls, log bursts, concurrent call/session spikes).
- A swapfile is cheap insurance and is now a **default for every install**,
  not just Asterisk droplets — `base.sh` calls `lib/common.sh`'s
  `ensure_swapfile()` unconditionally, which offers a 2GB swapfile any time
  RAM is ≤4096MB and none exists yet (`services/asterisk.sh` also calls it
  directly for the standalone-run case, so it's covered either way).
- Sharing one `coturn` instance (`services/coturn.sh`) instead of letting
  each WebRTC-capable service (Asterisk, Mattermost) embed its own saves a
  container per consumer and — more importantly — avoids relay-port
  collisions between them.

## Tier 1 — ~1 vCPU / 1GB RAM / 25GB SSD

Example: DigitalOcean Basic, $6/mo.

This is tight enough that Docker's own daemon overhead is already a
meaningful fraction of the box. **Pick one purpose, not a stack:**

- **Option A — Asterisk only.** Asterisk + the shared coturn service fits
  comfortably per this repo's own droplet-sizing notes (`services/asterisk.sh`
  README section) — a swapfile is added automatically (RAM ≤4GB, see above),
  and this plan is "fine for a couple of extensions and light personal use."
- **Option B — a lightweight utility box.** Caddy + CrowdSec + NetBird
  (all near-zero RAM) plus at most one or two of the smallest apps (`ntfy`,
  `vaultwarden`, `wg-easy`) — total comfortably under 500MB.

**Avoid on this tier:** anything with its own database (Mattermost,
Traccar, Nextcloud), more than one substantial app, media/AI/gaming
services. There's no headroom for a second heavy thing once the first one
is running.

## Tier 2 — 4 vCores / 4GB RAM / 120GB NVMe

Example: IONOS VPS M+, $11/mo. **This is the tier actually planned out in
detail** — see the recap below.

## What I was planning for the IONOS 4 vCPU / 4GB / 120GB box

Reconstructed from the sizing conversation, in the order decisions were made:

**Core stack (the original ask):**
- `caddy` — reverse proxy / HTTPS
- `crowdsec` — intrusion prevention
- `asterisk` — PBX, using the **shared** `coturn` service (not embedded)
- `mattermost` × 2 — genuinely isolated instances (separate dir/containers/DB
  per instance), both sharing the one `coturn` service — this required
  merging PR #265 (`claude/droplet-capacity-assessment-s2voix`), which
  extracted `coturn` into `services/coturn.sh` and added real multi-instance
  support to `services/mattermost.sh`; merged into `main` at commit `6151ede`
- `traccar` — GPS tracking

**Validated call load:** up to 9 concurrent Asterisk calls, at most 1
Mattermost call at a time, 0 screen share. Comfortably within budget —
no transcoding/conferencing/heavy-video load in this profile, so CPU has
large margin and RAM sits around 2.0-2.7GB idle with the core stack alone.

**Utility adds, agreed:**
- `ntfy`, `wg-easy`, `homebox`, `mealie`

**Explicitly declined:** `vaultwarden`, `portainer`, `syncthing`, `actualbudget`
(dropped to make room for WordPress — see below)

**Remote / cross-VLAN access:** NetBird — hosted control plane (not
self-hosted), client-only, with its embedded SSH server enabled
(`--allow-server-ssh`, JWT/OIDC-based user auth, no user SSH keypair to
manage). Already implemented in `services/base.sh` (`_base_setup_netbird()`)
as part of every box's base install — nothing further to build for this.
Chosen over self-hosting a WireGuard mesh once it was clear that (a) a
hub-routed WireGuard design makes the VPS a single point of failure for
*inter-peer* connectivity specifically, not just VPS access, and (b) a
different person ever needing access means hand-editing `authorized_keys`
on every box instead of revoking centrally — NetBird's actual value here is
solving both, not just being "zero-config."

**`wg-easy`'s role, narrowed:** kept in the utility-add list, but as a
**local-VLAN WireGuard testing ground**, not the primary remote-access path
— that's NetBird's job. The hub-routed peer mesh (`WG_ALLOWED_IPS=0.0.0.0/0`
by default, so any two enrolled peers already reach each other through the
VPS with no per-pair config) plus a `sync-ssh-aliases.sh` companion script
(reads peers straight off the live WireGuard interface via `wg show`,
generates `~/.ssh/config` Host aliases) is already built and pushed
(`claude/vps-capacity-assessment-r57vw3`, commit `4a0ec63`).

**Confirmed:** `audiobookshelf` on the VPS with HTTPS via Caddy, but
pointing it at a home-hosted library over a VPN tunnel (NetBird or wg-easy,
whichever link reaches that box) instead of storing audiobooks locally —
`services/audiobookshelf.sh` already just bind-mounts a host path, so this
means mounting a network share from that tunnel at the mount point instead
of a local directory. Avoids the disk/CPU tradeoffs of a local media
library; real bandwidth depends on home upload speed, which wasn't checked.

**Music: `emby`, music-only — not `lyrion`.** `lyrion` (LMS/Squeezebox) was
floated first since it's a purpose-built, well-regarded music server, but
ruled out for two protocol-level reasons neither Caddy nor Authelia can
paper over: its own web-UI auth is one shared server-wide password (no
per-user accounts), and its player protocol (SlimProto, port 3483) is raw
TCP with no authentication of its own, so Authelia's HTTP-only
`forward_auth` can't gate it at all. `emby` (already registered in this
repo, `media` category) solves both — real per-user accounts with
per-library access restriction, and every client protocol it uses is HTTP,
so Caddy fronts all of it cleanly. `services/emby.sh` now has a music-only
mode (prompts for this, defaults the folder to `~/music`, and the generated
README walks through adding only a Music library plus the
Dashboard → Users → Access per-user restriction steps in Emby's own setup
wizard). Tradeoff accepted knowingly: Emby is a generalist media server, not
a purpose-built one — it lacks LMS's music-specific depth (its lyrics
fetching, its many audio-focused plugins). Since there's no hardware
Squeezebox tie-in to preserve, that tradeoff was fine to make.

**Emby subsequently dropped from the near-term plan** — traded off for
WordPress capacity (below) rather than run alongside it. `services/emby.sh`'s
music-only mode is still there and ready whenever there's headroom for it
again; it just isn't part of the current baseline.

**WordPress — confirmed, 2 sites (settled), light traffic, ecommerce-capable.**
`services/wordpress.sh` (new): multi-site from the start, every site named,
each with its own **dedicated** MariaDB container (same pattern as
`services/nextcloud.sh`) — not a shared instance. Started as a shared-MariaDB
design (same resource-sharing idea as `coturn`) but switched to dedicated
per-site after weighing it against backup/restore: Kopia's generic backup
(`services/backup.sh`) stops a service's container to snapshot it, so a
shared instance would back up — and would have to be restored — as one unit
covering every site at once, not one site independently. Dedicated per-site
costs more RAM (a full MariaDB container each, ~100-150MB, instead of one
instance amortized across sites) in exchange for real isolation: each
site's database backs up and restores completely independently. Separate
databases were always required regardless of which model — WordPress's
schema uses generic table names (`wp_posts`, `wp_options`, etc.), so two
installs sharing one database with the same table prefix would collide —
the shared-vs-dedicated choice was only ever about the container/process,
never about the data being mixed. wp-cli automates the initial install
(title, admin account) so there's no per-site browser setup wizard, and PHP
limits are pre-tuned (256M memory, 64M uploads) for WooCommerce
specifically since "possible ecommerce" was part of the ask.

**Explicitly out of scope for this box** (wrong fit, not "can't run"):
- Local media servers storing media on the VPS (`jellyfin`, `immich`,
  `lyrion`, and `emby`/`audiobookshelf` *without* the home-library-over-VPN
  approach used above) — disk-hungry, and transcoding CPU load risks
  contending with active calls.
- AI stacks (`ai-stack`, `ai-gpu`, `iopaint`, `paintplus`) — need real
  VRAM/RAM most VPS plans don't have.
- Gaming (`minecraft`, `wolf`, `wolf-pair`, `sunshine`, `kyber-*`) — CPU/RAM
  heavy; cloud-gaming ones need GPU passthrough.
- Cameras/NVR (`frigate*`, `sky-cam`) — needs real camera feeds; doesn't
  make sense geographically on a VPS.
- `nextcloud` + `onlyoffice` — the combined PHP+DB+office-suite stack alone
  would likely eat most of the remaining headroom.
- `unifi` — only worth ~300-500MB of Java if actually managing Ubiquiti
  gear from this box.
- SSH `ProxyJump`/bastion-hop chaining for reaching genuinely isolated
  (CGNAT, no local peer) boxes — a good idea in principle, parked for later
  since NetBird already covers the current need.

## Final RAM budget for the IONOS box (settled baseline, no Emby, no actualbudget, idle)

| Service | ~RAM |
|---|---|
| OS + Docker baseline | ~400MB |
| Caddy | ~30MB |
| CrowdSec | ~150MB |
| coturn (shared) | ~40MB |
| Asterisk | ~100MB |
| Mattermost × 2 (app+Postgres each) | ~1200MB |
| Traccar (JVM) | ~425MB |
| NetBird client | ~35MB |
| ntfy, mealie | ~225MB combined |
| WordPress × 2 sites (app ~80MB + dedicated MariaDB ~120MB each) | ~400MB |
| **Total** | **~3.00GB** |

Leaves roughly **~1.09GB headroom (~27%)** out of 4GB — back into the ideal
25-30% range, between dropping `actualbudget` (~115MB) and settling on 2
sites instead of 4 (dedicated-per-site MariaDB's cost scales with site
count, so this was the single biggest lever). With the swapfile now
automatic (`ensure_swapfile`, see above) there's real insurance on top of
that margin, not instead of it. `wg-easy`,
`homebox`, and `audiobookshelf` from earlier in this doc aren't included in
this specific table — add them back in at ~25MB, ~125MB, and ~200MB
respectively if/when they're actually deployed alongside this baseline.
Deploy incrementally and check `free -h` / `docker stats` against this table
rather than trusting it blindly — each line carries real estimate
uncertainty, and they're stacked
close enough to the ceiling that it's worth confirming. If real usage runs
higher than estimated, the two Mattermost instances (~1.2GB combined) are
the single biggest lever to reconsider.
