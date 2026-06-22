# Star Wars Battlefront II (2017) — Wolf/Moonlight Setup

**AppID:** 1237950  
**Proton:** GE-Proton10-34 (required)  
**Platform:** Wolf (Games-on-Whales) — WolfSteam Docker container  

---

## Prerequisites

- SWBF2 installed via Steam in the WolfSteam session
- GE-Proton10-34 installed (Steam → Settings → Compatibility → Enable Steam Play)
- EA account created at ea.com and linked to your Steam account
- `msitools` on the Docker host: `sudo apt-get install -y msitools`

---

## The EA dependency problem

SWBF2 (2017) requires EA's launcher infrastructure — even for single-player offline:

- **Steam** handles payment, library, and game files
- **EA App** handles identity and authentication

First launch requires internet + EA account. After that, EA App caches credentials
locally and subsequent launches work offline — until the token expires or EA's servers
shut down permanently.

**If/when EA shuts down:**
- Community private server projects (like Kyber) may replace EA's infrastructure
- SWBF2 (2005, AppID 6060) is the zero-dependency alternative — no accounts, no
  launchers, active community servers, runs perfectly through Proton

**Migrating to another machine:**
```bash
# Back up the Wine prefix — EA credentials travel with it
tar -czf swbf2-prefix-backup.tar.gz \
    /home/retro/.steam/steam/steamapps/compatdata/1237950/
```
Tokens last weeks to months before requiring re-login.

---

## Why docker exec can't run Wine/Proton

`docker exec` carries high Linux capabilities (`CapEff ≈ 0xa8ac35fb`).
Steam processes run with `CapEff=0`. When a high-cap process tries to run bwrap
(Steam's sniper/pressure-vessel sandbox), bwrap tries a privileged uid-map path:

```
setting up uid map: Permission denied
```

**Only Steam itself can launch programs through sniper+GE-Proton.** All Wine
operations must go through Steam's launch chain — hence the wrapper approach.

---

## How it works

Steam passes a `link2ea://` URL as the "game executable" to GE-Proton. The wrapper
intercepts this, imports registry fixes, then passes the original URL through.
GE-Proton's `steam.exe` handles `link2ea://`, finds `Link2EA.exe` via the registry,
runs it, and EA Desktop authenticates the session before launching the game.

```
Steam → wrapper → regedit (registry fixes) → exec original args
      → GE-Proton steam.exe → link2ea:// → Link2EA.exe → EA Desktop → SWBF2
```

---

## Step-by-step

### 1. Trigger Wine prefix creation

SWBF2 must be launched at least once so Steam creates the Wine prefix and drops
`ea_app.msi` into it. Launch SWBF2 from Moonlight, wait ~10 seconds, then close it
(the "Origin is not installed" error is expected at this point).

Verify the MSI appeared:
```bash
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep Wolf)
docker exec "$WOLF_CONTAINER" ls -lh \
    /home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi
```
Expected: ~227 MB file.

### 2. Extract EA Desktop files on the host

The MSI's `JunoConfigureRegistry` .NET custom action fails in Wine (it uses
`SetSecurityDescriptorSddlForm` for registry ACLs — unsupported in Wine). This
causes the entire install to roll back. Extract files on the host instead:

```bash
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep Wolf)

docker cp "$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi" \
    /tmp/ea_app.msi

sudo apt-get install -y msitools
mkdir -p /tmp/ea_app_extracted
msiextract -C /tmp/ea_app_extracted /tmp/ea_app.msi
```

### 3. Copy EA Desktop files into the Wine prefix

The MSI installs EA Desktop under a versioned directory with a symlink.
The version (e.g. `14.2.0.3345`) is whatever the extracted MSI contains:

```bash
EA_VERSION=$(ls /tmp/ea_app_extracted/Electronic\ Arts/EA\ Desktop/ | head -1)
# Usually "EA Desktop" — this is the versioned dir, renamed during real install
# Use the version from the failed-install symlink if present:
SYMLINK_TARGET=$(docker exec "$WOLF_CONTAINER" readlink \
    "/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop/EA Desktop" \
    2>/dev/null || echo "14.2.0.3345")

PFXBASE="/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/Program Files/Electronic Arts/EA Desktop"

docker exec "$WOLF_CONTAINER" bash -c "
    rm -f '$PFXBASE/EA Desktop'
    mkdir -p '$PFXBASE/$SYMLINK_TARGET'
    ln -s '$SYMLINK_TARGET' '$PFXBASE/EA Desktop'
"

docker cp "/tmp/ea_app_extracted/Electronic Arts/EA Desktop/EA Desktop/." \
    "$WOLF_CONTAINER:$PFXBASE/$SYMLINK_TARGET/"

# Verify
docker exec "$WOLF_CONTAINER" find "$PFXBASE" -name "Link2EA.exe"
```

### 4. Write registry fix files to drive_c

These are imported into the Wine registry on each launch via the wrapper.
Writing to drive_c ensures they survive wineserver restarts (unlike direct
system.reg edits which get overwritten).

```bash
PFXC="$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c"

# link2ea:// protocol handler — tells Wine how to run Link2EA.exe
cat > /tmp/link2ea_fix.reg << 'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea]
@="URL:link2ea Protocol"
"URL Protocol"=""

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea\shell\open\command]
@="\"C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\Link2EA.exe\" \"%1\""
EOF

# EA Desktop Windows services — EALocalHostSvc provides local IPC that
# Link2EA.exe needs; without it launch fails with RPC_S_SERVER_UNAVAILABLE
cat > /tmp/ea_services.reg << 'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EALocalHostSvc]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EALocalHostSvc.exe"
"DisplayName"="EA Local Host Service"
"ObjectName"="LocalSystem"

[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\EABackgroundService]
"Type"=dword:00000010
"Start"=dword:00000002
"ErrorControl"=dword:00000001
"ImagePath"="C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\EABackgroundService.exe"
"DisplayName"="EA Background Service"
"ObjectName"="LocalSystem"
EOF

docker cp /tmp/link2ea_fix.reg "$PFXC/link2ea_fix.reg"
docker cp /tmp/ea_services.reg "$PFXC/ea_services.reg"
```

### 5. Lock localconfig.vdf and set launch options

Steam overwrites localconfig.vdf on shutdown via atomic rename (temp file +
rename). `chmod 444` on the file is bypassed. Lock the **directory** instead:

```bash
STEAM_UID=$(docker exec "$WOLF_CONTAINER" ls /home/retro/.steam/steam/userdata/)
CONFIG_DIR="/home/retro/.steam/steam/userdata/$STEAM_UID/config"
CONFIG_FILE="$CONFIG_DIR/localconfig.vdf"

# Stop Steam so it flushes before we edit
docker exec "$WOLF_CONTAINER" pkill -f steam.sh || true
sleep 5

# Lock directory
docker exec "$WOLF_CONTAINER" chmod 555 "$CONFIG_DIR"

# Add launch options for AppID 1237950
# Find the 1237950 block and insert/replace LaunchOptions
docker exec "$WOLF_CONTAINER" python3 - "$CONFIG_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path, 'r') as f:
    content = f.read()

launch_opt = 'STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%'

# Replace existing LaunchOptions in 1237950 block if present
new = re.sub(
    r'("1237950".*?"LaunchOptions"\s*)"[^"]*"',
    rf'\1"{launch_opt}"',
    content, flags=re.DOTALL
)

if new == content:
    # LaunchOptions key missing — add it after the "1237950" line
    new = re.sub(
        r'("1237950"\s*\n\s*\{)',
        rf'\1\n\t\t\t\t"LaunchOptions"\t\t"{launch_opt}"',
        content
    )

with open(path, 'w') as f:
    f.write(new)
print("Done")
PYEOF

# Verify
docker exec "$WOLF_CONTAINER" grep -A3 '"1237950"' "$CONFIG_FILE" | grep -i launch
```

### 6. Write the wrapper script

```bash
cat > /tmp/ea_install.sh << 'EOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
# Import registry fixes on every launch (survives wineserver restarts)
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\ea_services.reg"
# Pass original args through — Steam's link2ea:// URL goes to GE-Proton → Link2EA.exe
exec "$@"
EOF
chmod +x /tmp/ea_install.sh
docker cp /tmp/ea_install.sh "$WOLF_CONTAINER":/home/retro/ea_install.sh
```

### 7. First launch

1. Reconnect to Moonlight and launch SWBF2
2. **Let Vulkan shaders compile** — do not skip, takes several minutes, only happens once
3. EA App authenticates via your linked Steam/EA account (no manual login if accounts are linked)
4. Game loads

---

## Is this fragile? Will it work on a fresh install?

**Honest assessment:**

| Component | Fresh install safe? | Notes |
|-----------|-------------------|-------|
| EA Desktop files in Wine prefix | ✅ | Extracted from MSI in game files |
| Registry fixes (.reg files) | ✅ | Imported on every launch via wrapper |
| Launch options in localconfig.vdf | ✅ | Set by script |
| Config dir lock (chmod 555) | ✅ | Set by script |
| ea_app.msi in drive_c | ⚠️ | Requires one failed launch first to appear |
| EA account link | ⚠️ | One-time manual step |
| Vulkan shader cache | ⚠️ | Recompiles on fresh prefix — takes minutes |
| EA token in Wine prefix | ⚠️ | Requires login if prefix deleted or token expired |

**The catch:** The Wine prefix (`compatdata/1237950/`) is recreated from scratch if deleted.
All file copies and registry entries live inside it. A fresh install needs all steps run again
— but the automation handles that.

**The one irreducible manual step:** Linking your EA account to Steam (done once at ea.com,
persists across reinstalls via EA's servers).

---

## Troubleshooting

### "Origin is not installed" popup
The game binary checks for Origin before calling link2ea://. This happens when:
- The wrapper didn't run (check launch options are set)
- The wrapper ran but regedit failed (check `tail /tmp/ea_install.log`)

### `link2ea://` fails with ret 31 (SE_ERR_NOASSOC)
`link2ea_fix.reg` wasn't imported. Check drive_c has the file and wrapper ran both regedits.

### RPC_S_SERVER_UNAVAILABLE (0x800706ba) in wine log
`ea_services.reg` wasn't imported or EALocalHostSvc failed to register. Check wrapper log.

### Game exits immediately, no popup, no log
Wrapper isn't being called. Config dir may not be chmod 555 or launch options missing.
```bash
docker exec "$WOLF_CONTAINER" stat "$CONFIG_DIR" | grep Access
docker exec "$WOLF_CONTAINER" grep -A5 '"1237950"' "$CONFIG_FILE" | grep -i launch
```

### Collecting logs after a failure
```bash
docker exec "$WOLF_CONTAINER" bash -c "
    tail -20 /tmp/ea_install.log
    echo '---'
    grep -E '(err:|link2ea|origin|RPC)' /home/retro/steam-1237950.log | tail -20
"
```

---

## Key paths (inside WolfSteam container)

| Path | Description |
|------|-------------|
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/` | SWBF2 Wine prefix |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/system.reg` | Wine HKLM registry |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi` | EA App MSI (~227 MB) |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/link2ea_fix.reg` | link2ea protocol handler reg |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_services.reg` | EA service registrations |
| `/home/retro/.steam/steam/steamapps/common/STAR WARS Battlefront II/` | Game files |
| `/home/retro/.steam/steam/userdata/<uid>/config/localconfig.vdf` | Steam launch options |
| `/home/retro/ea_install.sh` | Launch wrapper |
| `/tmp/ea_install.log` | Wrapper log (resets on container restart) |
