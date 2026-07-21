# PSTN Calling via VoIP.ms — Planning Notes

Research and decisions from a design discussion, saved here so the work can
be picked up in a fresh chat without re-deriving the background.

**Implemented** — see `services/voipms-trunk.sh` (run `sudo ./setup.sh
voipms-trunk` after `asterisk-digital-ocean` is installed). IP-authenticated
trunk, US/NANP-only outbound dialplan, 3-concurrent-call cap, inbound to one
extension. That file's own header comment explains how it survives Easy
Asterisk's config regeneration (an architectural wrinkle discovered while
implementing this — worth reading before touching either file). The
outbound spend/volume alert mentioned below is still not implemented.

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

**Implemented:** the concurrent-call cap in `services/voipms-trunk.sh` is a
*global* cap (max 3 outbound legs total via the trunk, via
`GROUP()`/`GROUP_COUNT()` in the dialplan, shared across all extensions) —
not per-extension. That was the explicit ask when this got built; a
per-extension cap layered on top is still a possible future refinement, not
done. The spend/volume alert is still not implemented.

## What it takes technically (asterisk-digital-ocean)
- A PJSIP trunk to VoIP.ms: `endpoint` / `aor` / `identify` sections in the
  pjsip config. **Implemented with IP authentication** (no `auth` section,
  no SIP password stored anywhere) — see `services/voipms-trunk.sh`.
- An outbound dialplan route matching US numbers only — **implemented**:
  `_1NXXNXXXXX` (11-digit NANP with leading 1) and `_NXXNXXXXX` (10-digit,
  auto-prefixed with 1), both routed to the VoIP.ms trunk. No catch-all
  `_X.` pattern.
- VoIP.ms-specific setup that isn't scriptable (user does this manually):
  create the account, order a DID (inbound is wanted — see above), decide
  pay-per-minute vs. unlimited DID plan and whether to add E911, pick a
  VoIP.ms POP/server (affects the trunk hostname), fund the prepaid balance
  ($15 minimum), turn off auto-recharge. `services/voipms-trunk.sh` prompts
  for the POP hostname, DID, and a ring extension for inbound at install time.
- Defense-in-depth alongside the trunk:
  - **Implemented:** a global concurrent-call cap in the dialplan
    (`GROUP()`/`GROUP_COUNT()`, max 3 outbound legs via the trunk at once)
    so a compromised extension can't open dozens of simultaneous outbound
    legs. Global, not per-extension — see the note above.
  - **Not implemented:** a simple outbound call-count/spend alert — could
    live in the existing `security-dashboard` service (see
    `services/security-dashboard.sh`) or as a separate CDR-based check.
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
1. ~~Decide: new `services/voipms-trunk.sh`...~~ Done — separate service file.
2. ~~IP auth vs. registration~~ Done — IP authentication, no password stored.
3. ~~Exact NANP dial pattern(s)~~ Done — `_1NXXNXXXXX` / `_NXXNXXXXX`.
4. ~~Inbound~~ Done — rings one extension, prompted at install time. Still
   unresolved: pick pay-per-minute vs. unlimited DID plan on VoIP.ms's side
   based on real expected volume, and decide on E911 (see cost estimate).
5. ~~Concurrent-call cap~~ Done — global 3-call cap. Still not implemented:
   the spend/volume alert (security-dashboard integration or CDR-based
   check) — treat as still-required before fully trusting this against a
   sustained breach, not optional (see toll-fraud nuance above: the NANP
   restriction + call cap bound cost/min and burn speed, but nothing here
   yet notices a breach in progress or alerts on unusual volume).
6. Verify against a live VoIP.ms account: auto-recharge-off behavior at
   sign-up, and that the chosen POP server's actual source IP for inbound
   calls matches what `services/voipms-trunk.sh` resolved via DNS at install
   time (VoIP.ms's docs mention some redundancy/failover between servers —
   if inbound calls ever stop matching the `identify` section, this is the
   first thing to check).
