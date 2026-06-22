# Star Wars Battlefront II (2017) on Linux — How We Got Here

This document explains *why* the fix works, not just *what* to run. It traces
the actual discovery process: the wrong turns, the aha moments, and the
reasoning behind each step. If you want to understand what the setup scripts
are doing and why, read this first.

---

## Does it work out of the box?

No — not on any Linux Steam setup as of 2025. The game itself runs fine under
GE-Proton. The blocker is EA's launcher infrastructure, specifically the step
where Steam tries to install the EA App (formerly EA Desktop) into your Wine
prefix before the first launch. That installation silently fails, and the game
never gets past it.

This is true whether you're running native Linux Steam, or streaming through
Wolf/Games-on-Whales, or any other Proton setup. The root cause is in Wine,
not in the streaming layer.

---

## The architecture: why EA is involved at all

SWBF2 (2017) is a Steam game that also requires EA's launcher infrastructure.
This surprises people because it's a Steam purchase. The dependency exists
because EA's backend handles identity and entitlement checks separately from
Steam's payment and file delivery.

The game binary does not launch directly. Instead, Steam passes a `link2ea://`
URL as the "executable" to GE-Proton:

```
link2ea://launchgame/1237950?platform=steam&theme=swbfii
```

GE-Proton's internal `steam.exe` intercepts this URL, looks up the `link2ea://`
protocol handler in the Wine registry, finds `Link2EA.exe`, runs it, and
Link2EA.exe authenticates with EA's servers before handing off to the game.

If anything in that chain is missing — no protocol handler, no Link2EA.exe, no
EA services — the game exits silently and you're back at the Play button.

The first question was: *why is the protocol handler missing?*

---

## The installer: why it fails

Steam bundles `ea_app.msi` inside the game files. On first launch it runs this
MSI inside Wine to install EA Desktop. The installer runs, appears to do
something, and then... nothing. The game exits. No error message.

### Red herring: the wrong Proton version

The first instinct was to try different Proton versions. Vanilla Proton, various
GE-Proton releases. Some got further than others, but none completed the EA App
installation. GE-Proton is required — it contains patches specifically for EA's
launcher — but even with it the MSI fails.

### Finding the actual failure

The Wine logs showed the MSI starting, running custom actions, and then rolling
back. The key line buried in several hundred lines of output:

```
err:msi:HANDLE_CustomType1  ... JunoConfigureRegistry ... returned 0
```

The custom action returned 0 (success) but triggered a rollback anyway. That
seems contradictory. The reason: `JunoConfigureRegistry` is a .NET custom
action that calls `SetSecurityDescriptorSddlForm` to set ACLs on registry keys.
Wine's .NET implementation doesn't support that call. It returns 0 silently
(Wine's default for unimplemented functions) but the registry keys end up in
an invalid state, which the MSI detects and treats as a failure, rolling back
the entire installation.

The MSI was designed for Windows. On Windows, `SetSecurityDescriptorSddlForm`
works. On Wine, it silently no-ops, leaving the installation in a broken state
that triggers rollback.

### DISABLEROLLBACK was a dead end

The obvious next attempt: run the MSI with `DISABLEROLLBACK=1` so it can't
roll back even if something fails. This produced a 3-line log instead of
the usual hundreds of lines. The MSI thought the product was already registered
from the previous failed attempt and exited immediately without doing anything.
The partial state from the first failed run confused it.

### The actual fix: don't run the installer at all

MSI files are archives. They contain files, a database of what goes where, and
custom actions (executable code). The custom actions are what fail. If you skip
the installer entirely and just extract the files directly, you get everything
you need without running any of the broken .NET code.

`msiextract` (from the `msitools` package) extracts an MSI's file payload on
Linux without executing any custom actions. Run it on the host (outside Wine),
and it produces the full EA Desktop directory — `Link2EA.exe`, `EADesktop.exe`,
`EALocalHostSvc.exe`, all of it — without touching Wine at all.

```bash
msiextract -C /tmp/ea_app_extracted /tmp/ea_app.msi
```

This was the first major aha moment. The installer was never necessary. The
files were always there.

---

## The registry: why direct edits don't work

With EA Desktop files in place, the next problem: the `link2ea://` protocol
handler still wasn't registered in Wine's registry. Without it, GE-Proton's
`steam.exe` can't find `Link2EA.exe` and the URL goes nowhere.

The Wine registry for a prefix lives in plain text files:
- `pfx/system.reg` — HKEY_LOCAL_MACHINE
- `pfx/user.reg` — HKEY_CURRENT_USER

The obvious approach: edit `system.reg` directly, add the protocol handler
entries, done. This worked — once. On the next launch the entries were gone.

### Why: wineserver owns the registry

When Wine (or Proton) starts, `wineserver` loads the registry files into memory.
Any changes you make to the files on disk while wineserver is running are
ignored — wineserver's in-memory copy is authoritative. When wineserver shuts
down, it flushes its in-memory state back to disk, overwriting whatever you
wrote.

So: edit the file while wineserver is stopped → entries appear → Steam launches
the game → wineserver starts → your entries are still there → wineserver stops
at the end → your entries are overwritten with the original state.

One launch works. The second launch doesn't.

### The fix: go through the launch chain

The correct way to write registry entries that persist is to run `regedit`
*through Proton's own wine binary*, which writes into wineserver's live memory.
When wineserver then flushes to disk on shutdown, it writes the entries you
added — because they came from inside wineserver's own session.

The Steam launch option `%command%` expands to the full Proton/pressure-vessel
launch invocation. A wrapper script can intercept this, run regedit using the
same Proton binary before the game starts, then pass control through to the
game:

```bash
#!/bin/bash
# $1 through ${11} is the Proton launch wrapper
# running regedit with the same binary registers into the live wineserver session
"$1" "$2" "$3" ... "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" ... "${11}" regedit /S "C:\\ea_services.reg"
exec "$@"   # now launch the actual game
```

The `.reg` files live in `drive_c` (the Wine prefix's C: drive) so they survive
prefix wipes and container restarts. On every launch, the wrapper imports them
fresh. The entries are always current, always in wineserver's memory.

This was the second major aha moment. The registry isn't a file to edit — it's
a live service to talk to.

---

## The missing service: RPC_S_SERVER_UNAVAILABLE

With the protocol handler registered, `link2ea://` now fired correctly.
Link2EA.exe launched. Then it immediately crashed with:

```
RPC_S_SERVER_UNAVAILABLE (0x800706ba)
```

Link2EA.exe uses local RPC (inter-process communication) to talk to
`EALocalHostSvc` — a Windows service that runs in the background and provides
the local IPC socket Link2EA.exe expects to find. Without that service
registered, Link2EA.exe looks for the socket, finds nothing, and exits.

The fix was the same as the protocol handler: a `.reg` file imported on every
launch that registers `EALocalHostSvc` and `EABackgroundService` as Windows
services. Wine's service layer is a pale imitation of Windows Services, but it
provides enough of the IPC interface that Link2EA.exe is satisfied.

---

## The Wolf-specific problem: capabilities and bwrap

*(Skip this section if you're on native Linux Steam — it doesn't apply.)*

Wolf/Games-on-Whales runs Steam inside a Docker container. The obvious thing to
try was running Wine or Proton directly from outside the container using
`docker exec`. This failed consistently with:

```
setting up uid map: Permission denied
```

The reason is a Linux capabilities mismatch. Processes launched via `docker exec`
inherit elevated capabilities from the Docker daemon (roughly `CapEff ≈ 0xa80c35fb`).
Steam processes inside the container run with `CapEff=0` — no elevated
capabilities at all.

When a high-capability process tries to run `bwrap` (the bubblewrap sandbox that
Steam's pressure-vessel/sniper runtime uses), bwrap attempts a privileged uid
namespace map — and that path requires either no capabilities or full root, not
the partial set that `docker exec` provides. It fails.

The consequence: **only Steam itself can launch programs through the
sniper+GE-Proton runtime.** Any attempt to invoke Proton from outside Steam's
own process tree hits this wall. Every approach that tried to "just run wine"
from a terminal or docker exec hit this problem and was a dead end.

This is why the wrapper script approach works where direct invocation does not.
The wrapper is called *by* Steam as part of its own launch chain, so it inherits
Steam's `CapEff=0` context and bwrap succeeds.

---

## The localconfig.vdf problem

Steam stores per-game launch options in
`userdata/<uid>/config/localconfig.vdf`. The wrapper needs to be set as the
launch option for SWBF2, and that setting needs to survive Steam restarts.

The naive fix — `chmod 444` on the file — doesn't work. Steam writes
`localconfig.vdf` using an atomic rename: it writes to a temporary file in the
same directory, then renames the temp file over the original. `chmod 444` on
the destination file doesn't prevent a rename-over.

The fix is `chmod 555` on the *directory*. A rename-into requires write
permission on the destination directory. Lock the directory and Steam can't
complete the atomic rename — it fails silently and the original file is
preserved.

This is Linux filesystem semantics: file permissions control reads and writes to
the file's contents; directory permissions control the ability to create,
delete, or rename entries *within* the directory.

---

## What EA actually requires

After all of this, a reasonable question: *why does EA need to authenticate at
all for a game I bought on Steam?*

EA's position is that their games require EA account authentication regardless
of purchase platform. SWBF2 (2017) is in a middle state: it was originally an
Origin-only title, moved to Steam, but EA kept their authentication layer in
place. The game phones home to EA's servers on first launch and periodically
thereafter. The EA App caches credentials locally, so subsequent launches work
offline until the token expires (weeks to months).

The authentication cannot be bypassed without modifying game binaries — which
would be both a TOS violation and unnecessary, since the fix above gets the
legitimate authentication flow working correctly. The game still calls home to
EA. You still need a valid EA account linked to your Steam account. The scripts
here fix the *installation* of the authentication layer, not the authentication
itself.

If EA's servers shut down permanently: the community SWBF2 server project
(Kyber) would likely replace the authentication infrastructure, as has happened
with other abandoned EA titles. SWBF2 (2005, AppID 6060) has no EA dependency
and remains fully playable with no account required.

---

## Summary: why each piece is necessary

| Problem | Root cause | Fix |
|---------|-----------|-----|
| EA App install rolls back | `JunoConfigureRegistry` .NET call unsupported in Wine | `msiextract` on host, bypass installer entirely |
| `link2ea://` URL goes nowhere | Protocol handler not in Wine registry | `link2ea_fix.reg` imported via launch wrapper |
| Link2EA.exe crashes immediately | `EALocalHostSvc` IPC service not registered | `ea_services.reg` imported via launch wrapper |
| Registry fixes disappear after one launch | wineserver owns the registry; file edits are overwritten on shutdown | Import `.reg` files through Proton's own wine binary inside the launch chain |
| Launch wrapper setting gets overwritten | Steam uses atomic rename to write `localconfig.vdf` | `chmod 555` on the config directory blocks the rename |
| (Wolf only) Can't run Proton via `docker exec` | Capabilities mismatch breaks bwrap uid namespace mapping | Use Steam's own launch chain; only Steam can invoke the sniper runtime |

None of these problems are obvious. None of them produce useful error messages
by default. Each one looks like "the game just exits" until you find the right
log, add the right verbosity flag, or run the right diagnostic. The solutions
are individually small — a reg file here, a chmod there — but finding each one
required understanding a separate piece of Linux internals, Wine internals, or
Docker internals.

The scripts exist so no one else has to find them again.
