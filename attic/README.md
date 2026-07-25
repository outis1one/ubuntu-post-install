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
