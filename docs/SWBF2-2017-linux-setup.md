# Star Wars Battlefront II (2017) — Linux Setup Guide

**AppID:** 1237950  
**Proton:** GE-Proton10-34 or later (required)

This guide covers two setups:
- [Native Linux Steam](#native-linux-steam)
- [Wolf / Games-on-Whales + Moonlight streaming](#wolf--moonlight)

The underlying fix is the same for both. The EA App MSI bundled with the game
fails to install in Wine due to a .NET custom action (`JunoConfigureRegistry`)
that Wine does not support, causing the installer to silently roll back. The
fix is to extract the EA Desktop files directly from the MSI on the Linux host
using `msiextract`, bypassing the installer entirely, then wire up a launch
wrapper to import the necessary registry entries on every launch.

---

## Prerequisites (both setups)

- SWBF2 (AppID 1237950) installed via Steam and fully downloaded
- GE-Proton10-34 — installed automatically by the setup scripts if not present
- `msitools` — installed automatically by the setup scripts if not present
- An EA account created at ea.com and linked to your Steam account

### EA account requirement

SWBF2 (2017) requires EA account authentication on first launch. Steam handles
the game files; EA App handles identity. First launch requires an internet
connection and a valid EA account linked to your Steam account. After
authenticating, EA App caches credentials locally and subsequent launches work
without re-login until the token expires (typically weeks to months).

To link accounts: log in at ea.com, go to Connections, and link your Steam
account. This is a one-time step that persists across reinstalls.

---

## Native Linux Steam

### Prerequisites (native)

- In Steam: SWBF2 → Properties → Compatibility → Force GE-Proton10-34
  (the setup script installs GE-Proton10-34 automatically if not present)

### Automated setup

```bash
chmod +x setup-swbf2-linux.sh
./setup-swbf2-linux.sh
```

Run after completing step 1 below.

### Manual steps

#### 1. Trigger Wine prefix creation

Launch SWBF2 from Steam. Wait approximately 10 seconds. You will see an
"Origin is not installed" error — this is expected. Close it.

Verify the MSI appeared:

```bash
ls -lh ~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi
```

Expected: approximately 227 MB.

#### 2. Extract EA Desktop files

```bash
mkdir -p /tmp/ea_app_extracted
msiextract -C /tmp/ea_app_extracted \
    ~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi
```

#### 3. Copy EA Desktop files into the Wine prefix

```bash
PFX_C=~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c
EA_DEST_BASE="$PFX_C/Program Files/Electronic Arts/EA Desktop"

SYMLINK_TARGET=$(readlink "$EA_DEST_BASE/EA Desktop" 2>/dev/null || echo "14.2.0.3345")

mkdir -p "$EA_DEST_BASE/$SYMLINK_TARGET"
cp -r "/tmp/ea_app_extracted/Electronic Arts/EA Desktop/EA Desktop/." \
    "$EA_DEST_BASE/$SYMLINK_TARGET/"

rm -f "$EA_DEST_BASE/EA Desktop"
ln -sf "$SYMLINK_TARGET" "$EA_DEST_BASE/EA Desktop"

# Verify
find "$EA_DEST_BASE" -name "Link2EA.exe"
```

#### 4. Write registry fix files to drive_c

```bash
PFX_C=~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c

cat > "$PFX_C/link2ea_fix.reg" << 'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea]
@="URL:link2ea Protocol"
"URL Protocol"=""

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea\shell\open\command]
@="\"C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\Link2EA.exe\" \"%1\""
EOF

cat > "$PFX_C/ea_services.reg" << 'EOF'
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
```

#### 5. Write the launch wrapper

```bash
mkdir -p ~/.local/bin

cat > ~/.local/bin/ea_install.sh << 'EOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\ea_services.reg"
exec "$@"
EOF

chmod +x ~/.local/bin/ea_install.sh
```

#### 6. Set Steam launch options

In Steam: right-click SWBF2 → Properties → Launch Options, enter:

```
~/.local/bin/ea_install.sh %command%
```

Alternatively, set it from the terminal. Close Steam first, then:

```bash
STEAM_UID=$(ls ~/.steam/steam/userdata/ | head -1)
CFG=~/.steam/steam/userdata/$STEAM_UID/config/localconfig.vdf

python3 - "$CFG" << 'PYEOF'
import sys, re, os
path = sys.argv[1]
opt = os.path.expanduser('~/.local/bin/ea_install.sh') + ' %command%'
with open(path) as f:
    content = f.read()
new = re.sub(r'("1237950".*?"LaunchOptions"\s*)"[^"]*"', rf'\1"{opt}"', content, flags=re.DOTALL)
if new == content:
    new = re.sub(r'("1237950"\s*\n\s*\{)', rf'\1\n\t\t\t\t"LaunchOptions"\t\t"{opt}"', content)
with open(path, 'w') as f:
    f.write(new)
print("Done")
PYEOF
```

#### 7. Launch the game

1. Launch SWBF2 from Steam
2. Let Vulkan shaders compile on first run — do not skip
3. EA App authenticates via your linked Steam/EA account
4. Game loads

---

## Wolf / Games-on-Whales + Moonlight

### Prerequisites (Wolf)

- Wolf is running and Steam is open in a Moonlight session
- In Steam (via Moonlight): SWBF2 → Properties → Compatibility →
  Force GE-Proton10-34
  (the setup script installs GE-Proton10-34 into the container automatically if not present)

### Automated setup

If you are using the ubuntu-post-install framework:

```bash
cd ~/docker/wolf
./manage.sh setup-swbf2
```

Run this after completing step 1 below. The script handles steps 2–6
automatically.

### Manual steps

#### 1. Trigger Wine prefix creation

Launch SWBF2 from Moonlight. Wait approximately 10 seconds. You will see an
"Origin is not installed" error — this is expected. Close it and return to
the terminal.

Verify the MSI appeared in the Wine prefix:

```bash
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep WolfSteam | head -1)
docker exec "$WOLF_CONTAINER" ls -lh \
    /home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi
```

Expected: approximately 227 MB.

#### 2. Extract EA Desktop files on the host

```bash
WOLF_CONTAINER=$(docker ps --format '{{.Names}}' | grep WolfSteam | head -1)

docker cp \
    "$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi" \
    /tmp/ea_app.msi

mkdir -p /tmp/ea_app_extracted
msiextract -C /tmp/ea_app_extracted /tmp/ea_app.msi
```

#### 3. Copy EA Desktop files into the Wine prefix

```bash
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

#### 4. Write registry fix files to drive_c

These files are imported into the Wine registry on every launch by the wrapper
script. Storing them in drive_c ensures they survive wineserver restarts.

```bash
PFXC="$WOLF_CONTAINER:/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c"

cat > /tmp/link2ea_fix.reg << 'EOF'
Windows Registry Editor Version 5.00

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea]
@="URL:link2ea Protocol"
"URL Protocol"=""

[HKEY_LOCAL_MACHINE\SOFTWARE\Classes\link2ea\shell\open\command]
@="\"C:\\Program Files\\Electronic Arts\\EA Desktop\\EA Desktop\\Link2EA.exe\" \"%1\""
EOF

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

#### 5. Write the launch wrapper

```bash
cat > /tmp/ea_install.sh << 'EOF'
#!/bin/bash
echo "=== launch $(date) ===" >> /tmp/ea_install.log
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\link2ea_fix.reg"
"$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" regedit /S "C:\\ea_services.reg"
exec "$@"
EOF
chmod +x /tmp/ea_install.sh
docker cp /tmp/ea_install.sh "$WOLF_CONTAINER":/home/retro/ea_install.sh
```

#### 6. Set Steam launch options

Stop Steam so it flushes its current state before editing:

```bash
STEAM_UID=$(docker exec "$WOLF_CONTAINER" ls /home/retro/.steam/steam/userdata/)
CONFIG_DIR="/home/retro/.steam/steam/userdata/$STEAM_UID/config"
CONFIG_FILE="$CONFIG_DIR/localconfig.vdf"

docker exec "$WOLF_CONTAINER" pkill -f steam.sh || true
sleep 5
```

Edit localconfig.vdf to add the launch option for AppID 1237950:

```bash
docker exec "$WOLF_CONTAINER" python3 - "$CONFIG_FILE" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
opt = 'STEAM_UNIX_SOCKET=/tmp/steam.sock /home/retro/ea_install.sh %command%'
new = re.sub(r'("1237950".*?"LaunchOptions"\s*)"[^"]*"', rf'\1"{opt}"', content, flags=re.DOTALL)
if new == content:
    new = re.sub(r'("1237950"\s*\n\s*\{)', rf'\1\n\t\t\t\t"LaunchOptions"\t\t"{opt}"', content)
with open(path, 'w') as f:
    f.write(new)
print("Done")
PYEOF
```

Lock the config directory so Steam cannot overwrite localconfig.vdf on shutdown:

```bash
docker exec "$WOLF_CONTAINER" chmod 555 "$CONFIG_DIR"
```

Verify:

```bash
docker exec "$WOLF_CONTAINER" grep -A3 '"1237950"' "$CONFIG_FILE" | grep -i launch
```

#### 7. Launch the game

1. Reconnect to Moonlight and launch SWBF2
2. Let Vulkan shaders compile — do not skip; takes several minutes on first run only
3. EA App authenticates via your linked Steam/EA account
4. Game loads

### Fresh install behaviour (Wolf)

| Component | Survives reinstall? | Notes |
|-----------|-------------------|-------|
| EA Desktop files in Wine prefix | No | Re-run setup after prefix is recreated |
| Registry fix files in drive_c | No | Re-run setup after prefix is recreated |
| Launch options in localconfig.vdf | No | Re-run setup after prefix is recreated |
| Config dir lock | No | Re-run setup after prefix is recreated |
| ea_app.msi | No | Requires one launch to reappear |
| EA account link | Yes | Stored on EA's servers |
| EA auth token | No | Requires one re-login after prefix deletion |

If the Wine prefix (`compatdata/1237950/`) is deleted, run the setup again from
step 1. To preserve credentials when moving to a new machine, back up the prefix:

```bash
tar -czf swbf2-prefix-backup.tar.gz \
    /path/to/wolf-state/Steam/.steam/steam/steamapps/compatdata/1237950/
```

---

## Troubleshooting

### "Origin is not installed" popup

The wrapper did not run, or ran but regedit failed.

- Verify launch options are set: Steam → SWBF2 → Properties → Launch Options
- Check the wrapper log:
  ```bash
  tail /tmp/ea_install.log
  ```

### `link2ea://` fails — game exits silently after a moment

`link2ea_fix.reg` was not imported. Confirm `link2ea_fix.reg` exists in drive_c
and the wrapper ran both regedit commands.

### RPC_S_SERVER_UNAVAILABLE (0x800706ba) in Proton log

`ea_services.reg` was not imported or the service entries were not written
correctly. Check the wrapper log and confirm `ea_services.reg` exists in drive_c.

### Game exits immediately, no popup, no log entry

The wrapper is not being called at all.

**Wolf:**
```bash
docker exec "$WOLF_CONTAINER" stat "$CONFIG_DIR" | grep Access
docker exec "$WOLF_CONTAINER" grep -A5 '"1237950"' "$CONFIG_FILE" | grep -i launch
```

**Native:**
```bash
stat ~/.steam/steam/userdata/*/config | grep Access
grep -A5 '"1237950"' ~/.steam/steam/userdata/*/config/localconfig.vdf | grep -i launch
```

### Collecting logs after a failure

**Wolf:**
```bash
docker exec "$WOLF_CONTAINER" bash -c "
    tail -20 /tmp/ea_install.log
    echo '---'
    grep -E '(err:|link2ea|origin|RPC)' /home/retro/steam-1237950.log | tail -20
"
```

**Native:**
```bash
tail /tmp/ea_install.log
grep -E '(err:|link2ea|origin|RPC)' ~/.steam/steam/logs/steam_1237950.log 2>/dev/null | tail -20
```

---

## Key paths

### Wolf (inside WolfSteam container)

| Path | Description |
|------|-------------|
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/` | SWBF2 Wine prefix |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi` | EA App MSI (~227 MB) |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/link2ea_fix.reg` | link2ea protocol handler |
| `/home/retro/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_services.reg` | EA service registrations |
| `/home/retro/.steam/steam/userdata/<uid>/config/localconfig.vdf` | Steam launch options |
| `/home/retro/ea_install.sh` | Launch wrapper |
| `/tmp/ea_install.log` | Wrapper log (resets on container restart) |

### Native Linux Steam

| Path | Description |
|------|-------------|
| `~/.steam/steam/steamapps/compatdata/1237950/pfx/` | SWBF2 Wine prefix |
| `~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_app.msi` | EA App MSI (~227 MB) |
| `~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/link2ea_fix.reg` | link2ea protocol handler |
| `~/.steam/steam/steamapps/compatdata/1237950/pfx/drive_c/ea_services.reg` | EA service registrations |
| `~/.steam/steam/userdata/<uid>/config/localconfig.vdf` | Steam launch options |
| `~/.local/bin/ea_install.sh` | Launch wrapper |
| `/tmp/ea_install.log` | Wrapper log |
