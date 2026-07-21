# PSTN Calling via VoIP.ms — Planning Notes

Research and decisions from a design discussion, saved here so the work can
be picked up in a fresh chat without re-deriving the background.

**Implemented** — see `services/pstn-trunk.sh` (run `sudo ./setup.sh
pstn-trunk` after `asterisk-digital-ocean` is installed). Generic SIP trunk
add-on that defaults to VoIP.ms but isn't hardcoded to it — any provider
supporting IP authentication works. Covers: IP-authenticated trunk,
US/NANP-only outbound dialplan, a configurable concurrent-call cap (default
3), **role-based outbound permission** (some extensions internal-only, some
PSTN-enabled — internal intercom dialing is never gated either way), a
configurable **inbound ring-group** (one extension or several), **ntfy
alerts** on denied/rejected calls (immediate) and spend/volume thresholds
(hourly check), and settings persisted to `.pstn-trunk.env` so "update in
place" reapplies everything without re-prompting. That file's own header
comment explains how it survives Easy Asterisk's config regeneration (an
architectural wrinkle discovered while implementing this — worth reading
before touching either file).

## Decision so far
- **Provider: VoIP.ms.** Chosen for its prepaid-balance model: turn off
  auto-recharge in the account's Finances settings and outbound calls simply
  fail once the balance hits $0 — that's the toll-fraud backstop if the
  droplet's Asterisk (`asterisk-digital-ocean`) is ever compromised. This
  behavior wasn't verified against a live account — confirm the
  auto-recharge toggle still works this way at sign-up time, since billing
  UX can change.
- **Scope: US calling only, for now.** No international, no premium-rate
  destinations. Enforce this twice — once via whatever dial-plan/prefix
  VoIP.ms requires for US routing, and again independently in Asterisk's own
  dialplan (see below), so a compromised extension can't reach anything
  outside the US even if the trunk itself would technically allow more later.
- **Inbound: wanted.** A DID is in scope, not outbound-only. Decide pay-per-minute
  vs. unlimited DID plan based on expected inbound volume (see cost estimate
  below), and decide E911 deliberately rather than skipping it by default —
  VoIP.ms doesn't require it, but without it 911 dialed from the line either
  fails or doesn't carry accurate address/location info.

## Cost estimate (100 min/month each direction, US-only)

Verified against VoIP.ms's public wiki/rate pages, not a live account — confirm
at sign-up since rates can change.

| Item | Rate | Monthly | Annual |
|---|---|---|---|
| DID (phone number), pay-per-minute plan | $0.85/mo flat | — | $10.20 |
| Inbound usage | $0.009/min | $0.90 | $10.80 |
| Outbound usage | $0.01/min | $1.00 | $12.00 |
| **Total** | | **~$2.75** | **~$33** |

- Skipping the DID (outbound-only) drops this to ~$12/year.
- Adding E911 adds a $1.50 one-time fee plus **$1.50/month** regulatory fee
  (~$18/year) — pushes the total above to ~$51/year.
- **Funding minimum:** VoIP.ms requires a **$15 minimum deposit** to activate
  calling — a one-time balance top-up, not a recurring charge. At ~$2.75/month
  usage that balance lasts ~5 months before a refill is needed (longer at
  lower volume). Leave auto-recharge **off** per the toll-fraud design above.

## Why this matters (toll fraud)
A compromised Asterisk box can dial premium-rate or international numbers
that cost real money fast (some destinations run several $/min) before
anyone notices. Two independent layers matter more than either alone:
1. **Trunk-side cap** — prepaid balance, auto-recharge off. Limits total
   possible loss to whatever the balance is topped up to, but a live
   compromise could still burn through that balance in minutes if nothing
   else restricts what can be dialed.
2. **Dialplan-side restriction** — Asterisk should refuse to route calls
   outside the US/NANP pattern at all, regardless of what the trunk allows.
   This is the first line of defense and should exist independent of the
   trunk's own capabilities.

**Important nuance: these two layers bound different things, and neither
alone bounds both.** NANP-only restriction bounds *cost-per-minute* (a
compromised box can only ever reach $0.01/min US numbers, never $2–5/min
international/premium destinations) — that risk is fully closed. It does
**not** bound *how fast* the prepaid balance gets burned: nothing stops a
compromised box from opening many concurrent US-destination calls in
parallel and draining the whole balance (e.g. $15 balance ÷ $0.01/min =
1,500 minutes total, which 20 concurrent legs could burn through in under
an hour). The prepaid-balance-off-auto-recharge layer bounds the *dollar*
ceiling; only a concurrent-call cap bounds the *speed* of a breach. Treat
the concurrent-call cap and spend/volume alert below as required before
funding a live trunk, not optional hardening.

**Implemented:** the concurrent-call cap in `services/pstn-trunk.sh` is a
*global* cap (configurable, default max 3 outbound legs total via the trunk,
via `GROUP()`/`GROUP_COUNT()` in the dialplan, shared across all extensions)
— not per-extension. That was the explicit ask when this got built. The
spend/volume alert is also implemented now: an hourly cron script reads a
call log the dialplan appends to directly (not Asterisk's CDR — see the
service file's own comments for why) and alerts via ntfy once per month when
estimated spend crosses a threshold, and every hour that call volume in the
last hour looks like a burst. Denied/rejected calls alert immediately,
separately from that hourly check.

## What it takes technically (asterisk-digital-ocean)
- A PJSIP trunk: `endpoint` / `aor` / `identify` sections in the pjsip
  config. **Implemented with IP authentication** (no `auth` section, no SIP
  password stored anywhere) — see `services/pstn-trunk.sh`. Provider name,
  server hostname, and DID are all prompted at install time (VoIP.ms is only
  the suggested default), so any provider supporting IP auth works.
- An outbound dialplan route matching US numbers only — **implemented**:
  `_1NXXNXXXXX` (11-digit NANP with leading 1) and `_NXXNXXXXX` (10-digit,
  auto-prefixed with 1), both routed to the trunk. No catch-all `_X.`
  pattern.
- **Role-based outbound permission — implemented.** A space-separated list
  of extensions allowed to dial PSTN, prompted at install (blank = every
  extension, the original default before roles existed). Baked into the
  dialplan as a `REGEX()` check against `${CHANNEL(peername)}` — no changes
  needed to Easy Asterisk's own per-device pjsip.conf sections, since the
  gate lives entirely in code this repo already owns. Internal
  extension-to-extension dialing is never gated by this, regardless of PSTN
  permission — only the two NANP patterns above are.
- **Inbound ring-group — implemented.** A space-separated list of
  extensions to ring for inbound calls (one, or several for a ring group via
  `Dial(PJSIP/a&PJSIP/b,20)`), prompted at install.
- Provider-specific setup that isn't scriptable (user does this manually):
  create the account, order a DID, decide pay-per-minute vs. unlimited DID
  plan and whether to add E911, pick a server/POP, fund the prepaid balance
  ($15 minimum for VoIP.ms), turn off auto-recharge. `services/pstn-trunk.sh`
  prompts for the server hostname, DID, allowed extensions, ring extensions,
  concurrency cap, ntfy topic, and spend-alert settings at install time.
- Defense-in-depth alongside the trunk:
  - **Implemented:** a global concurrent-call cap in the dialplan
    (`GROUP()`/`GROUP_COUNT()`, configurable, default max 3 outbound legs via
    the trunk at once) so an unauthorized or compromised extension can't
    open dozens of simultaneous outbound legs. Global, not per-extension —
    see the note above.
  - **Implemented:** an outbound call-count/spend alert via ntfy — a
    self-contained call log (not Asterisk's CDR) plus an hourly cron script.
    Denied/rejected calls also alert immediately. See
    `services/pstn-trunk.sh`'s "Spend/volume alerts" README section for the
    exact mechanics and why CDR wasn't used.
  - Worth being explicit that CrowdSec's existing `asterisk_bf` /
    `asterisk_user_enum` scenarios (see `services/crowdsec.sh`) cover
    registration brute-force, which is a *different* threat model from a
    legitimately-registered extension being used for toll fraud — nobody
    should assume CrowdSec alone already covers this.

## Provider landscape (for reference — not chosen)
- **SIP.US** — also prepaid, flat per-channel rate, built-in fraud
  detection. Considered, not chosen.
- Several providers (Nextiva, IDT Express) advertise AI/ML-based fraud
  monitoring as a second layer on top of normal billing — an extra net, not
  a substitute for a hard prepaid ceiling.
- Most providers don't market an explicit "spending cap" feature — the
  prepaid-balance + auto-recharge-off pattern is the de facto mechanism
  across the space, VoIP.ms included.

## Open items for whoever picks this up next
1. ~~Decide: new `services/pstn-trunk.sh`...~~ Done — separate service file,
   generalized to any IP-auth SIP provider (VoIP.ms is just the default).
2. ~~IP auth vs. registration~~ Done — IP authentication, no password stored.
3. ~~Exact NANP dial pattern(s)~~ Done — `_1NXXNXXXXX` / `_NXXNXXXXX`.
4. ~~Inbound~~ Done — rings a configurable list of extensions (ring-group
   supported), prompted at install time. ~~Role-based outbound permission~~
   Done — space-separated allow-list, blank = everyone. Still unresolved:
   pick pay-per-minute vs. unlimited DID plan on VoIP.ms's side based on
   real expected volume, and decide on E911 (see cost estimate).
5. ~~Concurrent-call cap~~ Done — configurable, default 3, global not
   per-extension. ~~Spend/volume alert~~ Done — ntfy, hourly threshold +
   burst check, plus immediate alerts on denied/rejected calls.
6. Verify against a live VoIP.ms account: auto-recharge-off behavior at
   sign-up, and that the chosen POP server's actual source IP for inbound
   calls matches what `services/pstn-trunk.sh` resolved via DNS at install
   time (VoIP.ms's docs mention some redundancy/failover between servers —
   if inbound calls ever stop matching the `identify` section, this is the
   first thing to check).
