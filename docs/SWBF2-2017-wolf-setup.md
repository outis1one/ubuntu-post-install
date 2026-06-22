# Star Wars Battlefront II (2017) — Wolf/Moonlight Setup

**AppID:** 1237950  
**Proton:** GE-Proton10-34 (required — stock Proton does not work with EA App)  
**Platform:** Wolf (Games-on-Whales) — WolfSteam Docker container  

---

## Why this is hard

SWBF2 (2017) is an EA game. EA mandated their **EA App** launcher for all EA Steam titles.
On launch, Steam passes `link2ea://launchgame/1237950?platform=steam&theme=swbfii` as the
"executable" to GE-Proton. The game binary itself also checks for Origin/EA App in the
registry before starting.

EA App requires an EA account login, and ea.com/signup has been unreliable. The workaround
here **bypasses EA App entirely**: launch the game executable directly and spoof the Origin
registry entries so the game thinks its launcher is installed.

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

## Solution overview

1. Intercept the Steam launch with a wrapper script (via launch options)
2. Spoof Origin registry entries so SWBF2 thinks its launcher is present
3. Skip link2ea:// entirely — launch `starwarsbattlefrontii.exe` directly

No EA account needed. No EA App login needed.

---

## Step-by-step

### 1. Find the WolfSteam container name and Steam user ID

```bash
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep Wolf)
echo "$WOLF_CONTAINER"

STEAM_UID=$(docker exec "$WOLF_CONTAINER" ls /home/retro/.steam/steam/userdata/)
echo "$STEAM_UID"

CONFIG_DIR="/home/retro/.steam/steam/userdata/$STEAM_UID/config"
```

### 2. Lock localconfig.vdf against Steam overwriting it

Steam uses atomic rename (write temp + rename) when saving config.
`chmod 444` on the file is bypassed by the rename. Lock the **directory** instead:

```bash
docker exec "$WOLF_CONTAINER" chmod 555 "$CONFIG_DIR"
```

### 3. Set SWBF2 launch options in localconfig.vdf

Kill Steam first so it flushes and releases the file, then edit:

```bash
docker exec "$WOLF_CONTAINER" pkill -f steam.sh || true
sleep 3

CONFIG_FILE="$CONFIG_DIR/localconfig.vdf"

# The file needs a LaunchOptions entry under AppID 1237950.
# Find the block and add/replace LaunchOptions:
docker exec "$WOLF_CONTAINER" grep -A5 '"1237950"' "$CONFIG_FILE"
# If LaunchOptions is missing, add it manually to the 1237950 block:
#   "LaunchOptions"   "STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%"
```

The launch option value must be:
```
STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%
```

### 4. Write the Origin registry spoof

SWBF2's binary checks for Origin in the registry before starting. Spoof it by writing
directly to Wine's system.reg (plain text file — no Wine needed):

```bash
SYSREG="/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/system.reg"
TIMESTAMP=$(date +%s)

docker exec "$WOLF_CONTAINER" bash -c "cat >> '$SYSREG' << 'REGEOF'

[Software\\\\Origin] $TIMESTAMP
\"ClientPath\"=\"C:\\\\\\\\Program Files\\\\\\\\Electronic Arts\\\\\\\\EA Desktop\\\\\\\\EA Desktop\\\\\\\\EADesktop.exe\"
\"InstallDir\"=\"C:\\\\\\\\Program Files\\\\\\\\Electronic Arts\\\\\\\\EA Desktop\\\\\\\\EA Desktop\\\\\\\\\"

[Software\\\\Wow6432Node\\\\Origin] $TIMESTAMP
\"ClientPath\"=\"C:\\\\\\\\Program Files\\\\\\\\Electronic Arts\\\\\\\\EA Desktop\\\\\\\\EA Desktop\\\\\\\\EADesktop.exe\"
\"InstallDir\"=\"C:\\\\\\\\Program Files\\\\\\\\Electronic Arts\\\\\\\\EA Desktop\\\\\\\\EA Desktop\\\\\\\\\"
REGEOF"

# Verify
docker exec "$WOLF_CONTAINER" grep -A3 'Software\\\\Origin' "$SYSREG"
```

### 5. Write the launch wrapper

The wrapper receives Steam's full launch chain as `$@` (args 1–11 are the
sniper+GE-Proton preamble, arg 12 is normally `link2ea://...`). Replace the last
arg with the actual game executable:

```bash
cat > /tmp/ea_install.sh << 'EOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
GAME_EXE="/home/retro/.steam/steam/steamapps/common/STAR WARS Battlefront II/starwarsbattlefrontii.exe"
exec "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "$GAME_EXE"
EOF
chmod +x /tmp/ea_install.sh
docker cp /tmp/ea_install.sh "$WOLF_CONTAINER":/home/retro/ea_install.sh
```

### 6. Launch SWBF2 in Moonlight

Steam → wrapper → `starwarsbattlefrontii.exe` runs directly inside sniper+GE-Proton.
The game checks Origin registry, finds the spoofed entries, and starts.

You may see Vulkan shader compilation prompts on first launch — these can be skipped;
the game will still proceed (shaders compile lazily or are skipped).

### 7. Restore clean state (after confirmed working)

```bash
# Restore directory to writable so Steam can save normally
docker exec "$WOLF_CONTAINER" chmod 755 "$CONFIG_DIR"

# Remove LaunchOptions for 1237950 from localconfig.vdf while Steam is stopped
```

---

## Background: what Steam actually passes to the wrapper

```
$1  = /path/to/steam-launch-wrapper
$2  = --
$3  = /path/to/reaper
$4  = SteamLaunch
$5  = AppId=1237950
$6  = --
$7  = /path/to/SteamLinuxRuntime_sniper/_v2-entry-point
$8  = --verb=waitforexitandrun
$9  = --
$10 = /path/to/GE-Proton10-34/proton
$11 = waitforexitandrun
$12 = link2ea://launchgame/1237950?platform=steam&theme=swbfii  ← we replace this
```

---

## What doesn't work (and why)

### Running msiexec / Wine via docker exec
`docker exec` carries Linux capabilities that break bwrap. Any attempt to run
Proton/wine64 outside Steam's own launch chain gets:
```
setting up uid map: Permission denied
```

### Running the EA App MSI through Wine (INST-14-1603)
The MSI's `JunoConfigureRegistry` .NET custom action uses `SetSecurityDescriptorSddlForm`
to set registry ACLs. Wine doesn't support this — the action returns 0 (failure),
causing the entire install to roll back. `DISABLEROLLBACK=1` doesn't help because
MSI logs the product as already-registered from the first attempt, causing subsequent
runs to produce an empty log and exit.

### link2ea:// approach with EA account
EA App requires an EA account linked to your Steam account. `ea.com/signup` is
unreliable. Even with an account, EA Desktop must be installed in the Wine prefix
(see msiextract bypass below if needed). Bypassing the game exe directly is simpler.

### msiextract bypass (if EA App files are needed for something else)
If you need EA Desktop files in the prefix for another reason:
```bash
# Copy MSI out of container (appears in drive_c after first launch attempt)
docker cp "$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi" \
    /tmp/ea_app.msi

# Extract on host (bypasses JunoConfigureRegistry entirely)
sudo apt-get install -y msitools
mkdir -p /tmp/ea_app_extracted
msiextract -C /tmp/ea_app_extracted /tmp/ea_app.msi

PFXBASE="/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop"
docker exec "$WOLF_CONTAINER" bash -c "
  [ -L '$PFXBASE/EA Desktop' ] && rm '$PFXBASE/EA Desktop'
  mkdir -p '$PFXBASE/14.2.0.3345'
  ln -s 14.2.0.3345 '$PFXBASE/EA Desktop'
"
docker cp "/tmp/ea_app_extracted/Electronic Arts/EA Desktop/EA Desktop/." \
    "$WOLF_CONTAINER:$PFXBASE/14.2.0.3345/"
```

---

## Troubleshooting

### Game exits in ~6 seconds, no popup
Check wrapper log inside container:
```bash
docker exec "$WOLF_CONTAINER" bash -c "
  cat /tmp/ea_install.log | tail -20
  find /home/retro/.steam/steam/steamapps/compatdata/1237950/ -name '*.log' \
    -newer /tmp/ea_install.log 2>/dev/null | xargs tail -20 2>/dev/null
"
```

### "Origin is not installed" popup
Origin registry entries missing. Repeat step 4 and verify:
```bash
docker exec "$WOLF_CONTAINER" grep -A3 'Software\\\\Origin' \
  '/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/system.reg'
```

### Wrapper never runs (Steam ignores launch options)
Steam wrote config before chmod 555 was applied. Kill Steam, verify chmod 555 is set
on the config directory, edit localconfig.vdf, then start Steam again.

### localconfig.vdf gets overwritten on Steam shutdown
`chmod 555` on the directory (not the file) prevents the atomic rename Steam uses.

### wine64 segfaults outside Steam (exit 139)
GE-Proton10's wine64 requires the sniper runtime. Never call it via `docker exec`.

---

## Key paths (inside WolfSteam container)

| Path | Description |
|------|-------------|
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/` | SWBF2 Wine prefix |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/system.reg` | Wine HKLM registry (plain text) |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi` | EA App MSI (~227 MB, appears after first launch) |
| `/home/retro/.steam/steam/steamapps/common/STAR WARS Battlefront II/starwarsbattlefrontii.exe` | Actual game binary |
| `/home/retro/.steam/steam/userdata/<uid>/config/localconfig.vdf` | Steam per-user config (launch options) |
| `/home/retro/ea_install.sh` | Launch wrapper script |
| `/tmp/ea_install.log` | Wrapper log (inside container, resets on container restart) |
