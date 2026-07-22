# PSTN Calling via VoIP.ms — Planning Notes

Research and decisions from a design discussion, saved here so the work can
be picked up in a fresh chat without re-deriving the background.

**Implemented** — see `services/pstn-trunk.sh` (run `sudo ./setup.sh
pstn-trunk` after `asterisk-digital-ocean` **or** `asterisk` (home/LAN) is
installed — both are supported, see the file for the static-IP caveat on the
LAN variant). Generic SIP trunk add-on that defaults to VoIP.ms but isn't
hardcoded to it — any provider supporting IP authentication works. Covers:

- IP-authenticated trunk, US/NANP-only outbound dialplan, no catch-all.
- **Two independent concurrent-call caps**, one per direction (default 10
  outbound / 10 inbound — bumped up from an initial default of 3 once roles
  existed to gate who can even reach the trunk; "ability creep is real," so
  the two caps stay the hard backstop regardless). Global per direction, not
  per-extension.
- **Three-tier per-extension permission model**: `internal` (default — no
  PSTN at all, but can always call/receive other extensions and internal
  ring groups), `restricted` (also only pre-approved US numbers, both
  directions), `full` (also any US number). Internal extension-to-extension
  dialing is *never* gated by any tier — deliberately, even though VoIP.ms
  itself offers free SIP-to-SIP calling, to avoid routing purely-internal
  calls through an extra external hop for no benefit.
- **Permissions AND concurrency caps are both live, not baked into the
  dialplan.** Stored in `pstn-permissions.conf` / `pstn-limits.conf`, read
  by the dialplan via Asterisk's `AST_CONFIG()` on every call — editing
  either file takes effect on the next call, no restart, no reinstall.
  `services/pstn-trunk.sh`'s "update in place" mode deliberately never
  touches either (same protection this repo's update-mode convention
  already gives `.env`/firewall/Caddy config
  elsewhere) — only a "fresh" reinstall (with confirmation) or the web UI
  below change it.
- A configurable **inbound ring-group** (one extension or several), each
  member's live tier/approved-numbers checked per inbound call via an
  unrolled per-member dialplan block (no AGI needed).
- **`services/security-dashboard.sh` integration** — a "PSTN Trunk" tab
  shows both concurrency caps and every extension (parsed from
  `pjsip.conf`) with its live tier and approved numbers, all editable with
  no restart. This is what makes the tier model and caps actually
  manageable day-to-day instead of needing a reinstall for every change.
- **ntfy alerts** on denied/rejected calls (immediate — permission denied,
  number not approved, or either concurrency cap hit) and spend/volume
  thresholds (hourly check: once/month on a spend threshold, every hour on
  a call-burst threshold).
- Structural settings (server, DID, ring-group *membership*, ntfy,
  rate/thresholds) persist to `.pstn-trunk.env` so "update in place"
  reapplies them without re-prompting — the concurrency cap *numbers*
  themselves are not structural, they live in `pstn-limits.conf` instead
  (see above).

`services/pstn-trunk.sh`'s own header comment explains how the trunk/dialplan
config survives Easy Asterisk's regeneration, and why permissions are a
separate live file rather than baked in — both architectural wrinkles
discovered while implementing this, worth reading before touching either
file.

## Decision so far
- **Provider: VoIP.ms.** Chosen for its prepaid-balance model: turn off
  auto-recharge in the account's Finances settings and outbound calls simply
  fail once the balance hits $0 — that's the toll-fraud backstop if the
  droplet's Asterisk (`asterisk-digital-ocean`) is ever compromised.

  **Update — read VoIP.ms's actual ToS (not just the wiki) on this.** The
  wiki says plainly "only accounts with a balance over $0 are able to send
  and receive calls" — new call attempts should be blocked in real time at
  $0, and that's still the core assumption this design leans on. But the
  ToS separately says the account "may run on a negative balance," that any
  negative balance is "immediately due and payable," that VoIP.ms may
  suspend an account below a $5 minimum balance (30-day notice first), and
  may permanently close it after 30 *consecutive* days negative. Read
  together, not a contradiction — two different things:
  - **Can new calls start** — real-time balance check, blocked at $0. Core
    assumption holds.
  - **Can the balance ever read negative** — yes, most plausibly from
    recurring fees (DID monthly, E911) landing when the balance is already
    near zero, or edge-case settlement of an in-progress call ticking
    slightly negative before teardown. Neither is a runaway toll-fraud
    scenario; both mean liability isn't cleanly capped at the funded amount
    to the exact penny, and the account needs topping up within the 30-day
    windows or it gets suspended/closed (an account-status consequence, not
    "30 free days of unblocked calling while negative").
  - Still not verified against an actual live account — this is a read of
    their published wiki + ToS text, not a test. Watch the real balance for
    the first month or two after go-live, and don't panic at a small
    negative reading — check whether it's a recurring fee or an actual call
    spike before assuming the block failed.
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
alone bounds both.** NANP-only restriction bounds *cost-per-minute* — but
**NANP-only alone was not actually sufficient**, and this design carried
that gap for a while before it was caught. NANP includes Caribbean/Atlantic
nations and several US territories (Bahamas, Puerto Rico, Dominican
Republic, and 24 others) that dial exactly like a normal 10-digit US number
but bill at international/premium rates — a well-known toll-fraud/
"one-ring scam" vector specifically because the format looks domestic. The
NANP pattern match alone would have let a compromised extension reach every
one of these. **Fixed**: `services/pstn-trunk.sh` now blocks those 27 area
codes explicitly, checked before permission tier, for every extension
regardless of tier — see the dialplan file's own comment and
"Non-US NANP area codes are blocked" in its generated README for the full
list. With that fix in place, cost-per-minute risk actually is closed (a
compromised box can only ever reach genuine US-rate destinations). It does
**not** bound *how fast* the prepaid balance gets burned: nothing stops a
compromised box from opening many concurrent US-destination calls in
parallel and draining the whole balance (e.g. $15 balance ÷ $0.01/min =
1,500 minutes total, which 20 concurrent legs could burn through in under
an hour). The prepaid-balance-off-auto-recharge layer bounds the *dollar*
ceiling; only a concurrent-call cap bounds the *speed* of a breach. Treat
the concurrent-call cap and spend/volume alert below as required before
funding a live trunk, not optional hardening.

**Implemented:** the concurrent-call caps in `services/pstn-trunk.sh` are
*global* per direction (default 10 outbound / 10 inbound, each tracked via
its own `GROUP()`/`GROUP_COUNT()` in the dialplan, shared across all
extensions) — not per-extension. Inbound didn't have a cap at all until
this was pointed out as a gap (outbound's cap doesn't protect against an
inbound call-flood, which also costs money per-minute on VoIP.ms) — both
directions are covered symmetrically now. The spend/volume alert is also
implemented: an hourly cron script reads a
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
  pattern. **Also implemented**: an explicit block on the 27 NANP area
  codes that aren't actually US (Caribbean/Atlantic nations + US
  territories — see the toll-fraud nuance above for why this matters),
  checked via `REGEX()` against the extracted area code before permission
  tier, ahead of every other check.
- **Three-tier permission model — implemented**, superseding an earlier flat
  allow-list design. `internal` / `restricted` / `full` per extension, read
  live from `pstn-permissions.conf` via `AST_CONFIG()` rather than baked
  into the dialplan text — no changes needed to Easy Asterisk's own
  per-device pjsip.conf sections, since the gate lives entirely in files
  this repo already owns. Internal extension-to-extension dialing is never
  gated by any tier — only the two NANP patterns (outbound) and the
  ring-group (inbound) are. Numbers are stored pipe-separated specifically
  because they're used as a `REGEX()` alternation pattern in the dialplan —
  see the security note below on why the untrusted call-time value must
  never be interpolated into the *pattern* side of that check.
- **Inbound ring-group — implemented.** A space-separated list of
  extensions to ring for inbound calls (one, or several for a ring group via
  `Dial(PJSIP/a&PJSIP/b,20)`), prompted at install. Each member's tier is
  checked live per inbound call (an unrolled dialplan block per member —
  full always rings, restricted only rings if the caller's number is on
  that member's approved list, internal never rings).
- **Security note on the REGEX() checks**: an inbound Caller-ID (or an
  outbound dialed number) is attacker-influenced data and must never be
  interpolated into the *pattern* argument of `REGEX()` — only ever the
  string being tested. Doing it backwards would let a crafted Caller-ID
  (e.g. containing regex metacharacters) forge a match against an unrelated
  approved-numbers entry. Both checks in `services/pstn-trunk.sh` put the
  admin-controlled approved-list in the pattern position and the live call
  data in the tested-string position — worth keeping that direction if this
  is ever refactored.
- **Web UI — implemented.** `services/security-dashboard.sh`'s "PSTN Trunk"
  tab lists every extension (parsed from `pjsip.conf`, the same marker
  format Easy Asterisk's own `rebuild_dialplan()` uses) with a tier dropdown
  and approved-numbers field, saving straight to `pstn-permissions.conf`.
  Tested end-to-end with a real running instance of the (stdlib-only)
  Python app: extension parsing, tier changes, number normalization/
  validation, and persistence all verified with actual HTTP requests against
  a live server in a sandboxed test — not just read through.
- Provider-specific setup that isn't scriptable (user does this manually):
  create the account, order a DID, decide pay-per-minute vs. unlimited DID
  plan and whether to add E911, pick a server/POP, fund the prepaid balance
  ($15 minimum for VoIP.ms), turn off auto-recharge. `services/pstn-trunk.sh`
  prompts for the server hostname, DID, allowed extensions, ring extensions,
  both concurrency caps, ntfy topic, and spend-alert settings at install
  time (the cap *numbers* are then live/web-editable afterward — see above).
- Defense-in-depth alongside the trunk:
  - **Implemented:** independent outbound/inbound concurrent-call caps in
    the dialplan (`GROUP()`/`GROUP_COUNT()`, default 10/10) so an
    unauthorized or compromised extension can't open dozens of simultaneous
    legs in either direction. Global per direction, not per-extension —
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

## Provider landscape (for reference)
Looked at as alternatives to VoIP.ms specifically because VoIP.ms's own ToS
confirms it *selectively* requires a government ID scan at signup (VPN/proxy
use, certain number types, internal risk scoring — not universal, but real).
None of these were verified to *never* require ID either; KYC requirements
are trending industry-wide (FCC STIR/SHAKEN, Robocall Mitigation Database),
so treat "no ID requirement found" as exactly that, not confirmation.

- **DIDLogic** — **ruled out**: has a $20/month minimum, confirmed directly
  by checking their portal (not something search results surfaced). Would
  otherwise have needed zero code changes — same IP-auth model and
  single-IP-per-regional-POP hostname pattern this service already handles.
- **Anveo Direct** (anveodirect.com — a *different product* from plain
  Anveo/anveo.com, its hosted-PBX sibling with monthly subscription tiers;
  don't confuse the two, their pricing models aren't comparable) — leading
  candidate. ~$0.001/min outbound, no minimum commitment, $25 minimum to
  fund the account (close to VoIP.ms's $15). Confirmed via their current
  official FAQ (fetched directly, not via search — search results had gone
  stale on this exact point):
  - IP authentication, no SIP registration — matches this service's
    architecture with zero changes needed to the auth model.
  - **No dial-prefix requirement** — a stale/outdated forum claim (found via
    search) suggested one was needed; the *current* official FAQ's own
    sample config shows plain number dialing, nothing prepended. Don't
    trust that claim if it resurfaces.
  - **Sends inbound signaling from multiple fixed IPs**, not one:
    `169.48.232.158`, `204.216.109.55`, `176.9.39.206`, `72.9.149.25` (per
    their FAQ as of this writing — confirmed different from what web search
    surfaced independently, which was a different, apparently stale set of
    5 IPs). This is what prompted the multi-IP `identify` support below.
    **Re-confirmed directly with Anveo Direct support** (ticket reply from
    MFonk, 7/22/2026): these 4 IPs are still current/accurate.
  - STIR/SHAKEN signing is handled by Anveo as intermediate provider for
    personal use (originating your own calls, not reselling to customers) —
    no FCC registration/certificate needed on our side.
  - ~~Still open: does Anveo actually block new outbound calls in real time
    at $0 balance~~ **Resolved** — asked their support directly (same
    ticket, 7/22/2026): "all calls (incoming and outgoing) will be blocked"
    at $0 balance, in real time, not just via the recurring-fee
    grace-period mechanism. This also answers the inbound question that
    hadn't been asked of VoIP.ms either (see item 6 below): **inbound is
    blocked at $0 the same as outbound**, not billed-through unconditionally.
    This closes the crux assumption behind the toll-fraud backstop layering
    for Anveo Direct specifically — VoIP.ms's own equivalent behavior is
    still unverified against a live account (see item 6).
- **SIP.US** — prepaid, but a flat ~$24.95/mo per-channel (unlimited minutes
  on that channel) model, not pay-per-minute — **not actually
  similarly-priced** at this project's volume (100 min/month costs ~$1-3/mo
  pay-per-minute vs. $24.95/mo flat). Notable anyway for automated real-time
  fraud detection (kills in-progress unauthorized calls, auto-disables
  international calling on suspicious activity) — a provider-side version of
  what this repo hand-built in the dialplan, if that trade-off (higher
  price, less to maintain yourself) ever appeals.
- Several providers (Nextiva, IDT Express) advertise AI/ML-based fraud
  monitoring as a second layer on top of normal billing — an extra net, not
  a substitute for a hard prepaid ceiling.
- Most providers don't market an explicit "spending cap" feature — the
  prepaid-balance + auto-recharge-off pattern is the de facto mechanism
  across the space, VoIP.ms included.

## Multi-provider support beyond VoIP.ms — implemented
`services/pstn-trunk.sh` now generalizes two things that were originally
built VoIP.ms-shaped, driven directly by researching Anveo Direct as an
alternative:
- **Multiple inbound `identify` match IPs**, not just one. The install
  prompt still auto-resolves the server hostname to an IP (VoIP.ms's
  one-POP-one-hostname model), but now also asks for any *additional* known
  source IPs a provider might publish (Anveo Direct's case) — PJSIP allows
  repeating `match=` within a single `identify` object to build one match
  set against the trunk endpoint, so this needed no new config objects, just
  a loop emitting one `match=` line per IP.
- No dial-prefix support was added — turned out not to be needed for Anveo
  Direct once verified against their current official FAQ rather than a
  stale search result. If a future provider genuinely needs one, that's the
  next generalization point (a prefix prepended to `${EXTEN}` before
  `Dial()`).

**Bug caught while testing this**: `.pstn-trunk.env` (the structural
settings file "update in place" reapplies) was being written with unquoted
values. Harmless as long as every value happened to be a single word, but a
multi-IP list (always space-separated once there's more than one) or a
multi-word provider name (e.g. "Anveo Direct") broke `source`-ing it
entirely — bash treats the second word as a command to run ("Direct:
command not found"). This was a latent bug that predates the multi-IP work
(a multi-extension ring group has the same shape), only surfaced by
actually exercising the update-mode round trip instead of just inspecting
generator output. Fixed by quoting every value in that heredoc.

## Open items for whoever picks this up next
1. ~~Decide: new `services/pstn-trunk.sh`...~~ Done — separate service file,
   generalized to any IP-auth SIP provider (VoIP.ms is just the default).
2. ~~IP auth vs. registration~~ Done — IP authentication, no password stored.
3. ~~Exact NANP dial pattern(s)~~ Done — `_1NXXNXXXXX` / `_NXXNXXXXX`. ~~NANP
   ≠ US gap~~ Done — 27 Caribbean/territory area codes explicitly blocked
   (see toll-fraud nuance above); this was a real, live gap in the design
   for a while, not a hypothetical.
4. ~~Inbound~~ Done — rings a configurable list of extensions (ring-group
   supported), each checked live per-call against its own tier. ~~Permission
   model~~ Done — superseded the original flat allow-list with a 3-tier
   model (internal/restricted/full) managed live via
   `pstn-permissions.conf` + the Security Dashboard web UI, no reinstall
   needed to change. ~~Generic Asterisk target~~ Done —
   `services/pstn-trunk.sh` now supports either `asterisk-digital-ocean` or
   the home/LAN `asterisk` install (the latter with a static-IP caveat for
   the provider's IP authentication). Still unresolved: pick pay-per-minute
   vs. unlimited DID plan on VoIP.ms's side based on real expected volume,
   and decide on E911 (see cost estimate).
5. ~~Concurrent-call cap~~ Done — both directions now (inbound was a real
   gap, since it also costs money per-minute and outbound's cap doesn't
   cover it), default 10/10, global not per-extension, live-editable via
   `pstn-limits.conf`/web UI. ~~Spend/volume alert~~ Done — ntfy, monthly
   threshold + hourly burst check, run **every minute** (systemd timer, not
   hourly cron — see item 8), plus immediate alerts on denied/rejected
   calls.
6. Verify against a live VoIP.ms account (still not done — only their wiki
   + ToS text has been read, see "Decision so far" above for what that
   turned up): confirm new outbound calls actually get blocked at $0
   balance as documented; watch whether/when the balance goes slightly
   negative in normal operation (expected from recurring fees, not
   necessarily a sign of a problem) and top up within the 30-day windows
   the ToS describes so the account/DID doesn't get suspended or closed.
   Also confirm the chosen POP server's actual source IP for inbound calls
   matches what `services/pstn-trunk.sh` resolved via DNS at install time
   (VoIP.ms's docs mention some redundancy/failover between servers — if
   inbound calls ever stop matching the `identify` section, this is the
   first thing to check).
7. Anveo Direct specifically has a provider-side "Call Security" setting
   (account portal, not exposed through SIP config) — a per-minute rate
   cap ("block calls with rate more than $X/min, 0 = block all") and a
   maximum call duration. Worth setting on any Anveo Direct account as a
   provider-side backstop independent of this repo's own dialplan code —
   not automatable from here since it's their web UI, not a config file.
8. ~~Spend-cap kill-switch~~ Done — a genuinely hard stop, not just an
   alert: once `pstn-trunk-usage-alert.sh` estimates month-to-date spend
   has reached an admin-set cap (prompted at install/update, `0` = disabled),
   it writes `tripped=1` to `pstn-trunk-killswitch.conf`, read live by the
   dialplan on *every* PSTN call attempt (both directions — internal
   Asterisk-to-Asterisk calling is untouched) and blocked immediately with a
   loud (`Priority: urgent`) ntfy alert. A separate loud warning fires once
   spend reaches 80% of the cap, before it trips. **Does not auto-reset** —
   requires manually clearing it via the CLI installer (update mode), by
   design, so a compromised/careless web session can't quietly re-enable
   spend after a trip. Honesty caveat carried over from the original spend
   estimate: this is estimate-based (call count/duration × an entered
   rate), not real billing data, and only as fresh as the last check — now
   every minute (see item 9) rather than hourly, shrinking but not
   eliminating the reaction-time gap between an overage happening and
   calling actually getting blocked.
9. ~~Hourly cron → per-minute systemd timer~~ Done —
   `pstn-trunk-usage.timer`/`.service` (falls back to a cron.d entry if
   systemd isn't available), running the same usage-alert script every
   minute instead of hourly. Directly motivated by item 8: the periodic
   check is now also the kill-switch's enforcement point, so the interval
   between checks is the exposure window, and a tighter interval shrinks it.
10. ~~International calling (beyond NANP/US)~~ Done — CLI-only (never the
    Security Dashboard web UI, on purpose: this widens which countries can
    be dialed/billed to at all, a more security-sensitive control than
    who's already allowed to use an already-fixed scope), continent →
    country menu (`_pstn_manage_international` in `services/pstn-trunk.sh`),
    always asked every run with no way to skip the *question* itself
    (though answering "no" leaves the existing allow-list untouched), with
    the resulting allow-list printed exactly once right after — not
    repeated during the spend-cap prompts, a correction from an earlier
    draft of this design. Optional auto-expiry with two ntfy notices (day
    of, and at the moment of expiry) and active re-blocking (the periodic
    script clears the allow-list once past `expires`, it doesn't just
    notify). Dialing uses the US `011` prefix convention (`_011X.` dialplan
    pattern); allowed country codes are the REGEX() *pattern* side (admin-
    controlled), dialed digits are always the *string* being tested — same
    safe direction as every other permission check in this file. Only
    `full`-tier extensions can use it regardless of which countries are
    allowed.
11. Internal SIP `MESSAGE` (native Asterisk texting, no carrier SMS/cost) —
    **partially done**. The permission layer is real and live-editable: a
    `messaging=yes` flag per extension in `pstn-permissions.conf`,
    independent of the PSTN calling tiers (an extension can be
    internal-tier for calling and still messaging-enabled, or vice versa),
    prompted at install time. **Not done**: the actual dialplan wiring that
    would make Asterisk *enforce* this flag on inbound `MESSAGE` requests.
    Reasoned through but deliberately not shipped: Easy Asterisk dispatches
    messages through the same `[intercom]` context calls use (no
    `message_context` override), and whether a hand-written pattern there
    would take precedence over — or conflict with — Easy Asterisk's own
    generated per-device dial patterns in that same context isn't something
    that can be safely determined without a live install to test against.
    Shipping a guessed pattern risked either silently not working or, worse,
    interfering with call-routing precedence for the same extensions.
    Treat this the same way as the VoIP.ms live-account verification in
    item 6 above: a real gap, flagged rather than papered over, not a
    hypothetical. Next step for whoever picks this up: verify message
    routing behavior against a live Easy Asterisk container, then wire the
    dialplan gate using the existing flag.
