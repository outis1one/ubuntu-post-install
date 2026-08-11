# PSTN + DID + SMS — end-to-end test checklist

For verifying an **already-installed** Asterisk + PSTN trunk + SMS setup
(droplet or home/LAN) actually works, top to bottom. Not a setup guide —
see `docs/anveo-direct-setup-guide.md` for account/droplet setup from
scratch, and `docs/pstn-calling-voipms-plan.md` for the design/architecture
background. This doc assumes both are already done and just walks through
proving it all still works, in order, with what to check when a step fails.

Run through this after any of: first go-live, a provider/DID change, an
Asterisk or PSTN trunk reinstall, or just periodically to catch drift (a
provider-side change, an expired international allow-list, a forgotten
kill-switch trip).

## 0. Before you start

Confirm which layout this box uses — commands below need the right
container name and directory:

```bash
docker ps --format '{{.Names}}' | grep -i easy-asterisk
# easy-asterisk        -> ~/docker/asterisk
# easy-asterisk-do     -> ~/docker/asterisk-digital-ocean (pre-merge droplet)
```

Set these once and reuse them in every command below:

```bash
CONTAINER=easy-asterisk        # or easy-asterisk-do
EA_DIR=~/docker/asterisk        # or ~/docker/asterisk-digital-ocean
```

Check the three services this checklist covers are actually installed:

```bash
sudo ./setup.sh --list | grep -E "asterisk|pstn-trunk|sms-inbound|security-dashboard"
```

Read your box's own current settings before testing — this file has your
real DID, tiers reference, ring-group, and rate, regenerated on every
`pstn-trunk` install/update:

```bash
cat $EA_DIR/README-pstn-trunk.md
```

## 1. Registration sanity check

Every extension you're about to test with needs to actually be registered
before anything else will work.

```bash
docker exec -it $CONTAINER asterisk -rx "pjsip show endpoints"
```

Each extension you plan to test should show `Avail` (registered), not
`Unavail`. If a softphone shows registered in its own UI but Asterisk
disagrees, the extension's transport (UDP vs TLS) is the usual culprit —
check it via the Security Dashboard's Extensions tab **ⓘ** button on that
row before going further, not by re-entering credentials.

## 2. Trunk itself

```bash
docker exec -it $CONTAINER asterisk -rx "pjsip show endpoint pstn-trunk"
```

Look for `Contact` state, not just that the endpoint exists. An
IP-authenticated trunk has no registration to show — what matters here is
that Asterisk considers the endpoint reachable, and that the provider's own
portal doesn't report the account balance at $0 or the DID unassigned.

## 3. Permission tiers — set before testing calls

Every extension starts at **internal** (no PSTN at all) until granted a
tier. Before testing outbound/inbound, set at least one extension to
`full` via the Security Dashboard's Extensions tab (or `restricted` with an
approved number, if that's what you want to test). **Press "Commit Changes
(Restart Asterisk)"** after — tier/permission edits are written to disk
immediately but the dialplan has been observed not picking them up until a
full container restart, not just a reload (see "Dashboard changes may need
Commit Changes" in `docs/anveo-direct-setup-guide.md`). Skipping this step
is the single most common reason a "correctly configured" test call still
fails.

## 4. Outbound call test

From a **full**-tier extension's softphone, dial a real US number as
`1` + area code + number (11 digits — the dialplan matches the full NANP
pattern, not a bare 10-digit number).

Watch the live console while dialing:

```bash
docker exec -it $CONTAINER asterisk -rvvv
```

Expected: the call connects, and a line appears in the call log:

```bash
tail -f $EA_DIR/logs/pstn-trunk-calls.log
```

**If it fails**, check in this order (matches the actual bugs this system
has hit — see the "Bugs hit and fixed" section of
`docs/anveo-direct-setup-guide.md`):
- `restricted`/`internal` tier dialing a number not on its approved list —
  expected to fail with a busy signal, not a bug.
- Concurrency cap already hit — check `pstn-limits.conf` or the dashboard's
  displayed caps.
- Kill-switch tripped (see §7 below) — every PSTN call, in or out, blocked
  regardless of tier.
- `dialplan show intercom` and count digits by hand against what you
  dialed — a pattern-length mismatch has bitten this exact system before.

## 5. Inbound call test — shared DID / ring-group

From any outside phone, dial the trunk's main DID (shown in
`README-pstn-trunk.md`). Every `full`/`restricted`-tier member of the
configured ring-group should ring simultaneously for ~20 seconds unless a
personal DID routes it elsewhere (see §6).

```bash
docker exec -it $CONTAINER asterisk -rx "dialplan show from-pstn-trunk"
```

**If nothing rings**: confirm the calling number's actual Caller-ID is
reaching Asterisk correctly — a bare `Hangup()`/no ring with no ntfy denial
alert either usually means the inbound context isn't loading at all (check
`asterisk -rx "dialplan show from-pstn-trunk"` returns content, not
"No such context"). A `Busy(15)` + ntfy denial alert means it loaded fine
and the caller's number just isn't on a `restricted`-tier member's approved
list — expected behavior, not a bug.

## 6. Inbound call test — personal DID

If you've assigned a personal DID to a specific extension (Security
Dashboard → PSTN Trunk tab → Personal numbers), dial that number instead of
the shared trunk DID. Only the owning extension (or every current member,
if assigned to a Group) should ring — no ring-group fallback. Confirm the
owner's outbound Caller-ID also shows this DID instead of the shared trunk
DID when *they* place a call out.

## 7. Spend-cap kill-switch (only if enabled)

Don't trigger this for real — it force-hangs-up active calls and blocks
all PSTN traffic until manually cleared. To confirm it's wired up without
tripping it:

```bash
cat $EA_DIR/config/asterisk/pstn-trunk-killswitch.conf
systemctl status pstn-trunk-usage.timer 2>/dev/null || crontab -l | grep pstn-trunk-usage
```

The timer/cron entry should be active and recent (`journalctl -u
pstn-trunk-usage.service -n 20` shows it actually ran within the last
minute). If you do want to confirm the block itself works, lower
`MAX_MONTHLY_SPEND` temporarily via `sudo ./setup.sh pstn-trunk` (update
mode) to something you've already exceeded, confirm calling is blocked
with the priority=urgent ntfy alert, then re-run and clear it (this is
CLI-only by design — not on the dashboard).

## 8. International calling (only if you've allowed any countries)

```bash
cat $EA_DIR/config/asterisk/pstn-intl-allowed.conf
```

Only `full`-tier extensions can dial these regardless of the allow-list.
Dial `011` + country code + number. If an expiry was set, confirm the
allow-list actually clears itself after that date (the periodic
usage-alert script does this, not a separate cron job) — worth checking
once near the expiry date rather than assuming.

## 9. Internal SIP messaging (no PSTN/SMS involved)

From one extension enabled for `messaging=yes` (Security Dashboard →
Extensions tab → Messaging column) to another, send a native SIP message
in Sipnetic (or whichever softphone). Should land instantly, no carrier
involved. Check the log if it doesn't arrive:

```bash
tail -f $EA_DIR/logs/sip-messages.log
```

An extension with `messaging=no` should have its message silently denied
(fails closed) — confirm this too, not just the success path.

## 10. SMS inbound test

Prerequisite: `sudo ./setup.sh sms-inbound` already run, and the Anveo
portal's DID → SMS tab → "Forward to URL" configured with the exact string
the installer printed (see `docs/anveo-direct-setup-guide.md` §8 if this
hasn't been done yet).

Text the DID's number from any outside phone. Expected: it lands in
Sipnetic's message thread for whichever extension/group owns that DID
within a few seconds — not a push notification, a real message in the
softphone's own thread.

```bash
journalctl -u sms-inbound -f
```

Shows sender, recipient, message length, and the AMI exchange — never the
message body itself. If nothing arrives:
- Confirm the DID is a **mobile**-class number if you're testing a 2FA/verification
  code specifically — geographic DIDs get silently rejected by many
  services before a message is ever sent (see the setup guide's "Pick the
  right kind of number" section).
- Confirm short-code SMS is actually enabled on this specific DID (not
  every number in the pool has it by default).
- Check `pstn-personal-dids.conf`/`pstn-groups.conf` actually has an entry
  for the DID you texted — an unowned DID has nowhere to route to.

Outbound SMS from this box isn't a working path yet (see the setup guide's
"What about sending?" section) — don't test for it.

## 11. Dashboard cross-check

Open the Security Dashboard's **Calls & Texts** tab and confirm the calls
and messages from the tests above actually show up there — this is reading
the same log files tested above, so an empty tab after a successful test
call usually means the dashboard's `ASTERISK_LOG_DIR`/log paths have
drifted from where Asterisk is actually writing, not that logging is
broken. Also check the **Extensions** tab shows correct live status
(online/offline) for whichever device you tested with.

## Quick reference — verification commands

```bash
docker exec -it $CONTAINER asterisk -rx "pjsip show endpoints"
docker exec -it $CONTAINER asterisk -rx "pjsip show endpoint pstn-trunk"
docker exec -it $CONTAINER asterisk -rx "dialplan show intercom"
docker exec -it $CONTAINER asterisk -rx "dialplan show from-pstn-trunk"
tail -f $EA_DIR/logs/pstn-trunk-calls.log
tail -f $EA_DIR/logs/sip-messages.log
journalctl -u sms-inbound -f          # SMS via Anveo's HTTP webhook — the path §10 actually tests
tail -f $EA_DIR/logs/pstn-sms.log     # SMS-over-SIP dialplan path — confirmed NOT offered by Anveo;
                                       # only relevant if a future provider delivers texts over SIP
journalctl -u pstn-trunk-usage.service -n 20
```
