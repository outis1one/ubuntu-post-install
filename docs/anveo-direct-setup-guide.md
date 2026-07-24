# Anveo Direct + Easy Asterisk — confirmed working setup guide

This is the exact sequence that got a real Anveo Direct DID working end to
end (both outbound and inbound) with `asterisk-digital-ocean.sh` +
`pstn-trunk.sh`, confirmed live on a real droplet. Follow it in order for
each additional number — steps 1–2 are one-time account setup; steps
3–7 repeat per DID.

## 0. Prerequisites

- `asterisk-digital-ocean.sh` (or `asterisk.sh` for a LAN box) already
  installed and running, with at least one extension configured.
- This box's public IP address (`curl -4 ifconfig.me`).

## 1. Anveo Direct account (one-time)

1. Create an account at `https://www.anveo.com/account.asp?account_type=direct`
   — this is what makes it a **Direct** account (trunk/DID product), not
   the hosted-PBX product.
2. Fund the account balance directly (not a subscription plan). Bank
   transfers can take several hours to clear.
3. **Known account-level caps as of this writing**, both separate from
   anything this installer enforces:
   - **Trial account limits**: 2 concurrent outbound calls (CPS: 2),
     $2/30-day spend limit, $2 minimum balance — shown on the Outbound
     Trunks page under "Account Limits." A "request higher limits" link
     sits next to the CallerID Policies section for asking Anveo to lift
     these once funded.
   - **Phone Numbers cap**: "You can manage up to 2 phone numbers. Please
     contact customer support to increase the limit" — a **separate** cap
     from the concurrent-call limit above, shown on the Phone Numbers
     summary page. Anveo indicated (not independently confirmed) that
     removing this requires providing a tax ID (EIN for a business, SSN
     for an individual) — decide for yourself whether that trade-off is
     worth it before planning on more than 2 DIDs.
4. CallerID policy: USA/Canada/international destinations all require
   CallerID **from a verified/Anveo-owned number** — any DID ordered
   through Anveo satisfies this automatically.

## 2. Order a DID

1. Go to the DID ordering tool ("Phone Numbers around the World" /
   similar), pick a number, and select the **Per Minute** rate plan — not
   Prime.
   - **Per Minute**: $0.004/min incoming, 10 dedicated incoming channels
     bundled in, no separate trunk product needed for inbound.
   - **Prime**: free incoming, but requires a separately-purchased "Anveo
     Trunk" (a *different* product — flat monthly fee, $6.50–$17/mo by
     zone, confirmed via the "Anveo Direct Trunk Price List" page). Per
     Minute avoids this fee entirely, which is why it's the one to use.
2. Confirm: $0.25 one-time setup, $0.15/month recurring (billed the 15th),
   3-month minimum term, pre-paid from account balance.

## 3. Create the Outbound Service (Call Termination) Trunk

This only needs to be done **once** — the same trunk carries outbound
calls for every DID/extension. Skip this step for DIDs 2+.

1. Outbound Trunks → **Add a new Call Termination Trunk**.
2. Fill in:
   - **Title**: any label (e.g. `asterisk-do`)
   - **Dialing Prefix**: leave **blank** — confirmed not required (no red
     "required" asterisk on this field, unlike Authorized IP Addresses and
     Call Routing Method). The dialplan here dials the bare number, no
     prefix.
   - **Authorized IP Addresses**: this box's public IP, one per line. This
     is the IP-authentication Anveo uses instead of a SIP password.
   - **Rate Cap**: optional safety ceiling — e.g. `Yes, $1/min` filters out
     any route pricier than that. Domestic US termination runs far below
     this, so it doesn't interfere with normal calls, just blocks getting
     routed onto an absurdly expensive carrier by accident.
   - **Concurrent Calls Limit**: whatever you want as an Anveo-side cap
     (e.g. `Yes, 6`) — note the account's Trial "Outbound Channels: 2"
     limit (see step 1) overrides this until lifted; whichever number is
     lower wins.
   - **Call Routing Method**: leave the default **Custom Least Cost
     Routing Model** and all of its sub-fields (All Prime Routes / cost
     lowest-to-highest / 5 routes / cost-ordered failover / 10 sec
     timeout) exactly as shown — sensible defaults, nothing to tune here.
3. Save.

### Finding the real outbound rate

The trunk's LCR pulls from **"All Prime Routes"** by default — meaning
your real per-minute cost is whatever's in the **Anveo Direct Prime** rate
card (Outbound Services/Call Termination page → "Download rates here"
under the **Prime** column, not Value/Standard/All). Confirmed from that
CSV: standard US-to-US domestic is a flat **`$0.00388/min`**, billed
per-second (not rounded to the minute) — this is the generic `USA.`
catch-all entry (prefix `1`); a few specific area codes have their own
slightly different override rates, and Virgin Islands is billed
separately/higher (~$0.02/min) despite looking like a normal US number.

## 4. Create the SIP Trunk (inbound forwarding) — once per DID

Anveo has **two unrelated "trunk" concepts** — don't confuse them:
- The **Outbound Service Trunk** from step 3 handles calls *out*.
- A separate **"SIP Trunk"** object (Account Options → wherever inbound
  routing objects live) handles calls *in* — this is what actually
  populates a DID's "Destination SIP Trunk" dropdown.

For **each DID**, create one of these:

1. **Trunk Name**: any label (e.g. `asterisk-do-inbound`) — can reuse the
   same one for multiple DIDs if you want them all forwarding the same
   way, or make one per DID for clarity.
2. **Primary**: type **SIP URI**, value:
   ```
   $[E164]$@<this box's public IP>:5060
   ```
   (port 5060 — Easy Asterisk's default SIP port, confirmed from its own
   vendor source `DEFAULT_SIP_PORT="5060"`). The `$[E164]$` placeholder is
   replaced by Anveo with the DID's own number, digits only, country code
   included, no `+` — e.g. DID `+15551234567` becomes `15551234567@IP:5060`
   in the actual INVITE Anveo sends.
3. **Failover**: leave blank.
4. Save.
5. Go to the DID's own **Call Options** tab → set **Destination SIP
   Trunk** to this new SIP Trunk object (not the Outbound Service Trunk)
   → Save.
6. **Optional, recommended once you're adding more DIDs**: Account
   Options → Service Defaults → set **Default Destination Trunk** to this
   SIP Trunk, so future DIDs auto-route here without repeating step 5.

## 5. Configure the droplet

```
sudo ./setup.sh pstn-trunk
```

- Existing install → choose **update** (`r`) if you're just changing the
  DID/server, or the CLI will walk fresh prompts if none exists yet.
- Provider quick-pick: **1) Anveo Direct** — pre-fills `sbc.anveo.com` and
  Anveo's 4 published signaling IPs (only one of which the hostname
  itself resolves to at any given moment; the others are entered as
  "additional known source IPs" so inbound is recognized regardless of
  which one a call actually arrives from).
- **DID**: 10 digits, no leading `1` (e.g. `5551234567`).
- **Outbound per-minute rate**: `0.00388` (see step 3's rate-lookup note)
  — pre-filled automatically when Anveo Direct is the selected provider.
- Concurrent-call caps, ring-group extensions, ntfy topic, spend-cap
  kill-switch thresholds: set to taste (all live-editable later without
  reinstalling).
- Who can call/be called (permission tiers, approved numbers), internal
  SIP messaging, and personal-number assignment are **not** prompted here
  — set them all in the Security Dashboard's **PSTN Trunk** tab instead
  (install it first if you haven't: `sudo ./setup.sh security-dashboard`).
  Every extension starts at `internal` (no PSTN access) until granted
  there.

## 6. Grant permissions and (optionally) a personal number

In the Security Dashboard's PSTN Trunk tab:
1. Set the tier for each extension that should get PSTN access (`full` or
   `restricted` — `restricted` also needs at least one approved number).
2. **Personal numbers** card: assign this DID to a specific extension if
   you want inbound calls to it to ring *only* that extension (instead of
   the whole shared ring-group) and its outbound Caller-ID to show this
   DID instead of the shared trunk DID. Enter the DID as **10 digits, no
   leading 1** (matches the same convention as the trunk DID above) —
   the dashboard's own input validates against exactly that format.
   You can assign the DID to a **group** instead of a single extension —
   pick `Group: <name>` in the owner dropdown (create the group first
   under Groups if it doesn't exist yet). Every current member whose own
   tier/approved-numbers authorize the caller rings, checked fresh on
   every call, so membership changes apply immediately with no reinstall.
   A group has no single extension to hang an outbound Caller-ID override
   on, so the Caller-ID-override part above only applies to
   single-extension assignments.

## 7. Test

- **Outbound**: from a full/restricted-tier extension in Sipnetic, dial
  `1` + area code + number (11 digits total — the dialplan matches the
  full NANP pattern, not a bare 10-digit number without the leading `1`).
- **Inbound**: from any outside phone, dial the DID's real number. If a
  personal number was assigned, only that extension should ring; if not,
  the whole configured ring-group rings simultaneously until someone
  answers or 20 seconds pass.
- Watch the live console while testing either direction:
  ```
  docker exec -it easy-asterisk-do asterisk -rvvv
  ```

## Bugs hit and fixed along the way (informational — already fixed)

These were all real, confirmed-live bugs in earlier versions of this
installer, not configuration mistakes — listed here for context on what
"just works" now that didn't before:

- **NANP dial pattern was one digit short** (`_1NXXNXXXXX` / `_NXXNXXXXX`,
  10/9 characters instead of the correct 11/10) — Asterisk's exact-length
  pattern matching never matched a real number at all.
- **`${CHANNEL(peername)}`** isn't a valid channel-function item on this
  Asterisk build — broke the caller-extension lookup used for every
  permission check.
- **`${EXTEN}` corruption after `Goto` to a named extension** — every
  `Goto(somelabel,1)` to a *different* extension (not a same-extension
  priority label) resets `${EXTEN}` to that label's own name, silently
  breaking the approved-numbers check, the international country check,
  and the final `Dial()` itself. Fixed by capturing the real dialed
  number into its own variable before any such jump.
- **Duplicate ring-group extensions** (the same extension listed twice in
  `RING_EXTS`) generated duplicate dialplan priority labels, causing an
  infinite loop that never reached the ring step at all. Now deduped
  automatically.
- **Personal-DID lookup format mismatch** — DIDs are stored 10-digit, but
  Anveo delivers the called number as 11-digit E.164 in `${EXTEN}`; the
  lookup now normalizes to 10 digits first.
- **Easy Asterisk only regenerates `pjsip.conf`/`extensions.conf` if they
  don't already exist** — a box that already has devices configured (the
  normal case) never picks up a vendor-script `#include` patch on a plain
  restart. Both the PSTN trunk and internal-messaging installers now also
  patch the live config files directly, not just the generator source.
- **A stale/malformed `.pstn-trunk.env`** could crash the entire installer
  under `setup.sh`'s `set -u` on `source`. Now guarded and falls back to
  safe defaults, erroring clearly only if genuinely required fields are
  missing.

## Still open

- The 2-phone-number account cap (see step 1) blocks getting all 4
  planned numbers until either Anveo lifts it or a tax ID is provided —
  tabled for now.
- The interactive CLI walkthrough (`pstn-trunk.sh` actually prompting
  through account setup step by step, not just this static doc) hasn't
  been built yet — this guide is the reference for building that once
  there's appetite for it.
