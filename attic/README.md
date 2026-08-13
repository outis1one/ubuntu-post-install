# attic — frozen copies, kept deliberately out of the way

Nothing in here is part of the normal system. `setup.sh` globs
`services/*.sh`, so files parked here never self-register, never appear in the
menu, and never run unless you invoke them by hand.

## `asterisk-digital-ocean.sh`

The pre-merge droplet installer, exactly as it was before
`services/asterisk-digital-ocean.sh` was folded into `services/asterisk.sh`.
It is here as a rollback path while the unified installer is still unproven on
real hardware — not as a supported second service.

It keeps its own standalone bootstrap, so it runs on its own:

```bash
sudo bash attic/asterisk-digital-ocean.sh
```

It still targets `~/docker/asterisk-digital-ocean` and the
`easy-asterisk-do` / `easy-asterisk-do-coturn` containers, which is exactly
the layout the merged `services/asterisk.sh` detects and preserves — so the
two agree about where an existing droplet install lives, and switching back
and forth does not move anything.

**What this copy does and does not protect against.** It is a way to get the
old installer back, not an undo button. If the unified script ever makes a
change you don't want, re-running this one does not reverse it — a
droplet snapshot does. The things that actually keep an existing install safe
are, in order: running `--dry-run` first, choosing `update` (or `cancel`)
rather than `fresh` at the reinstall prompt, and having a snapshot.

**Delete this once the unified installer has been confirmed on the droplet.**
Two copies of the same logic is the exact problem the merge existed to fix,
and this one will drift the moment `services/asterisk.sh` gets a fix that
isn't backported here — which it deliberately won't be.

## `coturn.sh` / `coturn-test-check.sh`

The shared-coturn service (`services/coturn.sh`, moved here unchanged from
`services/`) and its standalone health-check tool (`tools/coturn-test-check.sh`,
moved from `tools/`). This model — every WebRTC/SIP-capable service
(`asterisk`, `mattermost`) sharing one coturn instance via `ensure_coturn_user`
— is no longer offered anywhere in this repo. Every service now runs its own
dedicated coturn instead, with `lib/common.sh`'s `find_free_coturn_range()`
avoiding the relay-port collisions a shared instance used to prevent by
scanning every coturn-owning service's own `.env` on the box. See
`CLAUDE.md`'s "coturn (TURN/STUN) relay" section for the current pattern.

Sharing one instance only ever saved ~40MB RAM per additional consumer
beyond the first — real, but small — against being a single point of
failure every consumer depended on. Parked here, not deleted, since the
code is still correct and someone could resurrect it if a future need for
it shows up. Both files still run standalone if invoked directly:

```bash
sudo bash attic/coturn.sh
sudo bash attic/coturn-test-check.sh
```

Nothing in this repo calls `ensure_coturn_user()` anymore (the function
itself was removed from `lib/common.sh`), so resurrecting this only makes
sense if you're deliberately reintroducing the shared-coturn pattern
yourself — a new consumer service would need its own call to whatever
takes `ensure_coturn_user`'s place, since that helper no longer exists to
call.
