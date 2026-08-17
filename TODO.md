# TODO — scratch tracking doc

Not a permanent part of this repo's docs. This exists purely to hold the
state of a few in-flight/queued items across sessions until they're either
finished or turned into real issues/PRs — delete this file once that's done.

## 1. Asterisk DigitalOcean → IONOS migration

**State: resolved.** Migrated `talk.mydomain.com` from a DigitalOcean
droplet to an IONOS VPS, keeping the same domain (repointed the A record,
no Anveo trunk changes needed). Hit and fixed several real bugs surfaced
by the migration:

- Standalone backup/restore script now auto-corrects the baked-in external
  IP on a cross-box restore, and reconciles the two directory layouts
  (`asterisk` vs `asterisk-digital-ocean`) instead of leaving a stray
  second directory behind.
- `app_voicemail`/`app_voicemail_imap`/`app_voicemail_odbc` module-load
  collision, breaking voicemail on every install — fixed at its real
  source (vendor's `entrypoint.sh` regenerates `modules.conf` on every
  container start, so the fix has to live in the template, not a
  host-side file write).
- `DEVICE_MARKER_RE` in the Security Dashboard had two comment fields in
  the wrong order, so `list_extensions()` silently returned nothing for
  every device on every install — this, not anything migration-specific,
  was why Messaging/Voicemail toggles never stuck.
- Registration bounce on ext 201 traced to Sipnetic's non-standard "use
  TURN for registration" option, not to anything server-side (DNS,
  firewall, coturn, and CrowdSec were all individually confirmed clean).
  Turning that client-side toggle off resolved it; TURN itself is
  confirmed working correctly for its actual job (call media, verified
  with a real two-way test call).
- Restoring an Asterisk backup silently drops the Security Dashboard's
  file-read ACLs (new inodes from the extraction never had them) — now
  documented and the restore script prints a reminder to re-run
  `sudo ./setup.sh security-dashboard` afterward.
- All outbound (and ring-group inbound) PSTN calls silently denied, every
  time, with zero errors or warnings anywhere in the logs. Took an
  extended live debugging session working through firewalls (IONOS's
  separate Cloud Panel network firewall — a real, separate issue, but not
  this one), Anveo's IP allowlists, and IONOS-vs-DigitalOcean network
  theories before finding it: `asterisk.conf` needs `live_dangerously =
  yes` under `[options]` for `AST_CONFIG()` to actually work — without it,
  every `AST_CONFIG()` read (pstn-permissions.conf tiers, the PSTN
  kill-switch) silently returns an empty string instead of erroring, so a
  perfectly correct `tier_out = full` in pstn-permissions.conf still
  evaluates as no permission. Not IONOS-specific at all — Easy Asterisk's
  vendor default just ships without it, and the old DigitalOcean box
  apparently had it set by hand at some point with no record of why. Now
  fixed at the source: `_asterisk_ensure_live_dangerously()` in
  `services/asterisk.sh`, called after every fresh install and every
  "update" rebuild.

Loose end: no code fix pending, just keep an eye out in case the
registration bounce recurs (would point back at Sipnetic/coturn rather
than anything server-side, per the above).

## 2. Web-based extension messaging

**State: not started.** Explicitly deferred behind the Asterisk migration
and stability work above, which is now resolved — this is next up
whenever picked back up. No design decisions made yet.

## 3. Pi-hole service

**State: done.** `services/pihole.sh` exists, is registered
(`register_service pihole utilities ...`), and is documented in the
README's services table. Runs as a standalone DNS ad/tracker blocker —
its own description already flags the one thing it doesn't do yet:
"not wired into any VPN's DNS push." That gap is exactly item 4 below.

## 4. VPS as a VPN tunnel endpoint for privacy/security

**State: not started — idea stage.** Use the VPS as a VPN endpoint
(WireGuard, presumably via the existing `wg-easy` service already in this
repo) so a client's traffic, destination, and origin IP are all obscured
from its local network/ISP. Wants DNS resolution over the tunnel to go
through an encrypted upstream (NextDNS or ControlD, DoH/DoH3/DoT — exact
protocol TBD) rather than the VPS's own resolver or the client's ISP DNS,
so DNS queries aren't a side-channel leak of browsing activity even though
the tunnel itself hides traffic/destination.

Natural tie-in to item 3: point `wg-easy`'s pushed DNS at Pi-hole running
on the same box (Pi-hole already supports upstream DoH/DoT to something
like NextDNS/ControlD instead of plain DNS), rather than building a
separate DNS path — gives ad/tracker blocking *and* encrypted upstream
resolution for anything routed through the tunnel, closing the gap
Pi-hole's own description already calls out.

No design work done yet — open questions: which encrypted-DNS provider,
whether Pi-hole's own DoH/DoT upstream support is sufficient or a
separate proxy (e.g. cloudflared-style) is needed, and whether this is a
new service file or an enhancement to `wg-easy.sh`/`pihole.sh`.
