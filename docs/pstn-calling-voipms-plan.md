# PSTN Calling via VoIP.ms — Planning Notes

Research and decisions from a design discussion, saved here so the work can
be picked up in a fresh chat without re-deriving the background. **Nothing
has been implemented yet** — this is prep for a future `services/*.sh`
addition on top of `asterisk-digital-ocean`.

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
the per-extension concurrent-call cap and spend/volume alert below as
required before funding a live trunk, not optional hardening.

## What it takes technically (asterisk-digital-ocean)
- A PJSIP trunk to VoIP.ms: `endpoint` / `aor` / `auth` / `identify`
  sections in the pjsip config, using either IP authentication or SIP
  registration — VoIP.ms supports both. IP auth is simpler for a droplet
  (it has a static IP already) and avoids storing a SIP password in the
  config at all — worth confirming with VoIP.ms which they actually
  recommend before choosing.
- An outbound dialplan route matching US numbers only, e.g. `_1NXXNXXXXX`
  (11-digit NANP with leading 1) or `_NXXNXXXXX`, depending on how numbers
  get dialed from the existing extensions, routed to the VoIP.ms trunk. No
  catch-all `_X.` pattern — an explicit NANP pattern is itself a hard block
  on non-US destinations at the dialplan level.
- VoIP.ms-specific setup that isn't scriptable (user does this manually):
  create the account, order a DID (inbound is wanted — see above), decide
  pay-per-minute vs. unlimited DID plan and whether to add E911, pick a
  VoIP.ms POP/server (affects the trunk hostname), fund the prepaid balance
  ($15 minimum), turn off auto-recharge.
- Defense-in-depth to design alongside the trunk (not yet designed):
  - Per-extension concurrent-call cap in the dialplan (`GROUP()` /
    `GROUP_COUNT()`) so one compromised extension can't open dozens of
    simultaneous outbound legs at once.
  - A simple outbound call-count/spend alert — could live in the existing
    `security-dashboard` service (see `services/security-dashboard.sh`) or
    as a separate CDR-based check. Not designed yet.
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
1. Decide: new `services/voipms-trunk.sh`, or an optional trunk section
   added directly to `services/asterisk-digital-ocean.sh`? Leaning toward a
   separate service file so trunk config isn't forced on installs that
   don't want PSTN calling, matching this repo's one-feature-per-file
   convention (see CLAUDE.md).
2. IP auth vs. registration — confirm which VoIP.ms recommends for a single
   fixed-IP droplet.
3. Exact NANP dial pattern(s) and any prefix-stripping VoIP.ms requires.
4. Inbound is decided (wanted) — still need to pick pay-per-minute vs.
   unlimited DID plan based on real expected volume, and decide on E911.
5. Design the concurrent-call cap and any spend/volume alerting mentioned
   above — treat as required before funding a live trunk, not optional
   (see toll-fraud nuance above: NANP-only bounds cost/min, not burn speed).
