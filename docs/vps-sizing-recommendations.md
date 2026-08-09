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
- A swapfile is cheap insurance below ~2GB RAM. `services/asterisk.sh`
  already automates this for droplet installs ≤2GB — the same logic applies
  to any small box running more than one service.
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
  README section) — a swapfile is added automatically on droplets ≤2GB, and
  this plan is "fine for a couple of extensions and light personal use."
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
- `ntfy`, `wg-easy`, `homebox`, `actualbudget`, `mealie`

**Explicitly declined:** `vaultwarden`, `portainer`, `syncthing`

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

**Floated, not yet decided:** `lyrion` (music) doing the same
home-library-over-VPN thing — same pattern as `audiobookshelf` above,
architecturally sound, just not explicitly confirmed yet.

**Explicitly out of scope for this box** (wrong fit, not "can't run"):
- Local media servers storing media on the VPS (`emby`, `jellyfin`,
  `immich`, and `lyrion`/`audiobookshelf` *without* the home-library-over-VPN
  approach above) — disk-hungry, and transcoding CPU load risks contending
  with active calls.
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
