# Star Wars Battlefront II (2017) — Wolf/Moonlight Setup

**AppID:** 1237950  
**Proton:** GE-Proton10-34 (required — stock Proton does not work with EA App)  
**Platform:** Wolf (Games-on-Whales) — WolfSteam Docker container  

---

## Why this is hard

SWBF2 (2017) is an EA game. EA mandated their **EA App** launcher for all EA Steam titles.
On launch, SWBF2 calls `ShellExecuteW("link2ea://launchgame/1237950?platform=steam&theme=swbfii")`.
GE-Proton's `steam.exe` intercepts that URL, finds `Link2EA.exe` from the EA Desktop install, and
hands off to the EA App which then launches the actual game.

Without EA Desktop installed in the Wine prefix, the game exits immediately.

---

## The bwrap problem (why you can't just docker exec)

The WolfSteam container runs Steam as uid 1000 (`retro` inside container).
`docker exec` carries high Linux capabilities (`CapEff ≈ 0xa8ac35fb`).
Steam processes have `CapEff=0`.

When a high-cap shell tries to run bwrap (used by Steam's sniper/pressure-vessel runtime),
bwrap attempts a privileged uid-map path that fails:

```
setting up uid map: Permission denied
```

This means you **cannot** run Proton or wine64 via `docker exec` — bwrap always fails.
Only Steam itself can properly launch programs through sniper+GE-Proton.

---

## Solution: Steam launch wrapper

Use SWBF2's **Steam launch options** to intercept the launch, run a helper script,
then pass control back to Steam's real launch chain.

Steam passes all its args to the wrapper as `$@`:
```
steam-launch-wrapper -- reaper SteamLaunch AppId=1237950 -- <sniper> --verb=waitforexitandrun -- <proton> waitforexitandrun <game>
```

The wrapper runs msiexec (or anything else) inside the full sniper+GE-Proton environment
that Steam set up, then `exec "$@"` to hand off to the game.

---

## Step-by-step

### 1. Lock localconfig.vdf against Steam overwriting it

Steam uses atomic rename (write temp + rename) when saving config.
`chmod 444` on the file is bypassed. Lock the **directory** instead:

```bash
WOLF_CONTAINER="WolfSteam_XXXXXXXXXXXXXXXX"   # docker ps to find exact name
CONFIG_DIR="/home/retro/.steam/steam/userdata/XXXXXXXXX/config"

# Find container name
docker ps --format '{{.Names}}' | grep Wolf

# Find Steam user ID
docker exec "$WOLF_CONTAINER" ls /home/retro/.steam/steam/userdata/

docker exec "$WOLF_CONTAINER" chmod 555 "$CONFIG_DIR"
```

### 2. Set SWBF2 launch options

Edit localconfig.vdf **while Steam is not running** (or kill Steam first):

```bash
CONFIG_FILE="$CONFIG_DIR/localconfig.vdf"

# Kill Steam so it flushes and stops watching
docker exec "$WOLF_CONTAINER" pkill -f steam.sh || true
sleep 3

# Edit — find the LaunchOptions line for AppID 1237950
# Add before it if missing:
docker exec "$WOLF_CONTAINER" bash -c "
  sed -i '/\"1237950\"/,/}/ s/\"LaunchOptions\"\s*\"[^\"]*\"/\"LaunchOptions\"\t\t\"STEAM_UNIX_SOCKET=\/tmp\/steam.sock \/home\/retro\/ea_install.sh %command%\"/' '$CONFIG_FILE'
"
# Or if LaunchOptions key doesn't exist yet, add it manually.
# Verify:
docker exec "$WOLF_CONTAINER" grep -A5 '"1237950"' "$CONFIG_FILE" | grep LaunchOptions
```

### 3. Write the EA install wrapper

The wrapper runs `msiexec /a` (administrative install — no custom actions) to extract
EA Desktop files, then execs the real game:

```bash
cat > /tmp/ea_install.sh << 'EOF'
#!/bin/bash
echo "=== ea_install.sh called $(date) ===" >> /tmp/ea_install.log
echo "Args: $@" >> /tmp/ea_install.log
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" \
    msiexec /i "C:\\ea_app.msi" /qn \
    TARGETDIR="C:\\Program Files\\Electronic Arts" \
    /l*v "C:\\msi_admin.log" \
    >> /tmp/ea_install.log 2>&1
echo "MSI exit: $?" >> /tmp/ea_install.log
exec "$@"
EOF
chmod +x /tmp/ea_install.sh
docker cp /tmp/ea_install.sh "$WOLF_CONTAINER":/home/retro/ea_install.sh
```

### 4. Get the EA App MSI

The MSI ships inside SWBF2's game files. Copy it into the Wine prefix:

```bash
MSI_SRC="/home/retro/.steam/steam/steamapps/common/STAR WARS Battlefront II/__Installer/Origin/redist/internal/EAappInstaller.exe"
# EAappInstaller.exe is a WiX Burn bootstrapper — the real MSI is buried inside.
# Easier: use the MSI that gets extracted to the Wine prefix during a first launch attempt:
MSI_IN_PREFIX="/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi"
```

The MSI appears in the Wine prefix (`drive_c/ea_app.msi`, ~227 MB) after SWBF2 is launched
once — GE-Proton's protonfixes or steam.exe drops it there.

### 5. Extract EA Desktop files on the host (bypassing Wine custom actions)

The MSI's `JunoConfigureRegistry` custom action fails in Wine (it tries to set registry
ACLs via `SetSecurityDescriptorSddlForm` which Wine doesn't support). This causes
MSI rollback and removes all installed files. Bypass it by extracting on Linux:

```bash
# Copy MSI out of container
docker cp "$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi" \
    /tmp/ea_app.msi

# Extract (msitools package)
sudo apt-get install -y msitools
mkdir -p /tmp/ea_app_extracted
msiextract -C /tmp/ea_app_extracted /tmp/ea_app.msi
```

### 6. Copy EA Desktop into the Wine prefix

The MSI installs to `C:\Program Files\Electronic Arts\EA Desktop\` with a versioned
subdirectory (`14.2.0.3345`) and a symlink `EA Desktop -> 14.2.0.3345`.

The normal MSI install creates that symlink via `JunoSetupSymlinkMode`. After a
failed install + rollback, the symlink may remain but the versioned dir is gone.

```bash
PFXBASE="/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop"

# Remove any broken symlink
docker exec "$WOLF_CONTAINER" bash -c "
  [ -L '$PFXBASE/EA Desktop' ] && rm '$PFXBASE/EA Desktop'
  mkdir -p '$PFXBASE/14.2.0.3345'
  ln -s 14.2.0.3345 '$PFXBASE/EA Desktop'
"

# Copy extracted files into versioned directory
docker cp "/tmp/ea_app_extracted/Electronic Arts/EA Desktop/EA Desktop/." \
    "$WOLF_CONTAINER:$PFXBASE/14.2.0.3345/"

# Verify
docker exec "$WOLF_CONTAINER" find "$PFXBASE" -name "Link2EA.exe"
```

Expected output:
```
/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop/14.2.0.3345/Link2EA.exe
```

### 7. Switch wrapper to pass-through and launch

Once EA Desktop files are in place, update the wrapper to just exec the game:

```bash
cat > /tmp/ea_passthrough.sh << 'EOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
exec "$@"
EOF
chmod +x /tmp/ea_passthrough.sh
docker cp /tmp/ea_passthrough.sh "$WOLF_CONTAINER":/home/retro/ea_install.sh
```

Launch SWBF2 in Moonlight. Steam → GE-Proton → SWBF2 → link2ea:// → steam.exe
finds Link2EA.exe → EA App launches → SWBF2 loads.

### 8. EA account login (one-time)

On first launch, EA Desktop will show a login screen. Log in with your EA account.
Credentials are cached; subsequent launches skip login.

### 9. Restore clean state

After EA Desktop is confirmed working, remove the launch wrapper:

```bash
# Restore directory to writable
docker exec "$WOLF_CONTAINER" chmod 755 "$CONFIG_DIR"

# Remove LaunchOptions from localconfig.vdf
# (edit the file while Steam is stopped, remove the LaunchOptions line for 1237950)
```

---

## Troubleshooting

### "link2ea not found" / game exits in ~6 seconds
EA Desktop files are missing or in wrong path. Check:
```bash
docker exec "$WOLF_CONTAINER" find \
  "/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts" \
  -name "Link2EA.exe"
```

### Wrapper never runs (Steam ignores launch options)
Steam wrote config before chmod 555 was applied. Kill Steam, chmod 555 the directory,
then edit localconfig.vdf. Steam reads config fresh on startup.

### INST-14-1603 error in EA App installer
`JunoConfigureRegistry` .NET custom action returns 0 in Wine. This is a Wine limitation
with registry ACL operations. Use the `msiextract` bypass (Step 5–6) instead of
running the MSI through Wine.

### msiexec DISABLEROLLBACK=1 produces empty log
MSI detected a stale product registration from a previous failed install.
Check: `grep -i C2622085 /home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/system.reg`
If present, delete those registry keys then retry.

### wine64 segfaults outside Steam (exit 139)
GE-Proton10's wine64 requires the sniper runtime. Never call it directly from
`docker exec` — always use Steam's launch chain via the wrapper approach.

### localconfig.vdf gets overwritten on Steam shutdown
Steam uses atomic rename (temp file + rename into place). `chmod 444` on the file
is bypassed by the rename. Solution: `chmod 555` on the **directory** containing
localconfig.vdf — this prevents new files being renamed into the directory.

---

## Key paths (inside WolfSteam container)

| Path | Description |
|------|-------------|
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/` | SWBF2 Wine prefix |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi` | EA App MSI (~227 MB) |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop/14.2.0.3345/` | EA Desktop files |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop` | Symlink → `14.2.0.3345` |
| `/home/retro/.steam/steam/userdata/<uid>/config/localconfig.vdf` | Steam per-user config (launch options) |
| `/home/retro/ea_install.sh` | Launch wrapper script |
| `/tmp/ea_install.log` | Wrapper log (inside container) |
