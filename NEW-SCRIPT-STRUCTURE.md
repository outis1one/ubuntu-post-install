# Ubuntu Post-Install Script - New Structure

## Current Problems

1. ❌ Services prompt individually even when not selected in whiptail
2. ❌ Too many things installed BEFORE whiptail menu (Samba, VPNs, fail2ban)
3. ❌ No clear explanation to user about script phases
4. ❌ No uninstall option
5. ❌ Confusing for re-running on existing servers

## New Structure

### PHASE 1: Essential System Setup (Before Whiptail)
**Purpose:** Install only what's REQUIRED for everything else to work

**What stays BEFORE whiptail:**
- ✅ System updates (apt update/upgrade)
- ✅ Essential packages (openssh-server, rsync, curl, wget, git, vim, htop, ncdu)
- ✅ SSH key generation (optional)
- ✅ SSH key import from GitHub/Launchpad (optional)
- ✅ Docker & Docker Compose installation
- ✅ Hard drive mounting/formatting

**What moves TO whiptail menu:**
- 🔄 Samba file sharing
- 🔄 fail2ban for SSH
- 🔄 VPN services (Tailscale, WireGuard, NetBird)
- 🔄 Remote desktop (RustDesk, TeamViewer)
- 🔄 MeshCentral agent

### PHASE 2: Service Selection (Whiptail Menu)
**Purpose:** Let user choose ALL optional services

**New whiptail menu structure:**

```
┌─────────────────── Select Services ────────────────────┐
│ ☐ INSTALL   ☑ UNINSTALL                                │
│                                                         │
│ === NETWORK & SECURITY ===                             │
│  [ ] SAMBA            File sharing (SMB/CIFS)          │
│  [ ] FAIL2BAN_SSH     Protect SSH from brute-force     │
│  [ ] TAILSCALE        Easy VPN mesh network            │
│  [ ] NETBIRD          Self-hosted VPN                  │
│  [ ] WIREGUARD        Manual VPN configuration         │
│                                                         │
│ === REMOTE ACCESS ===                                  │
│  [ ] RUSTDESK         Remote desktop (OSS)             │
│  [ ] TEAMVIEWER       Remote desktop (commercial)      │
│  [ ] MESHCENTRAL      Remote management agent          │
│                                                         │
│ === DOCKER SERVICES ===                                │
│  [ ] ACTUALBUDGET     Personal finance                 │
│  [ ] KEYCLOAK         Identity management              │
│  [ ] CADDY            Reverse proxy                    │
│  [ ] FAIL2BAN_CADDY   Protect Caddy services           │
│  [ ] JELLYFIN         Media server                     │
│  [ ] IMMICH           Photo backup                     │
│  [ ] AUDIOBOOKSHELF   Audiobook server                 │
│  [ ] MEALIE           Recipe manager                   │
│  [ ] UPTIMEKUMA       Service monitoring               │
│  [ ] PORTAINER        Docker management UI             │
│  [ ] WATCHTOWER       Auto-update containers           │
│  ... (all other services)                              │
│                                                         │
│ === MESHCENTRAL SERVER ===                             │
│  [ ] MESHCENTRAL_SRV  Self-hosted remote mgmt server   │
│                                                         │
│        <Install Selected>  <Uninstall Selected>        │
└─────────────────────────────────────────────────────────┘
```

### PHASE 3: Installation
**Purpose:** Install/uninstall selected services in correct order

**Dependency-aware installation order:**
1. Install Caddy first (if selected)
2. Install services that depend on Caddy (Keycloak, etc.)
3. Install fail2ban for Caddy (if selected + Caddy installed)
4. Install independent services in parallel where possible

### Re-Running The Script

**Behavior on already-configured server:**

**Phase 1 (Essential):**
- Detects existing installations
- Shows: "Docker is already installed: (version)"
- Prompts: "Reinstall Docker? (y/n): **n**" (defaults to NO)
- Skips if "n"

**Phase 2 (Services):**
- Whiptail menu shows ALL services
- Already-installed services could be marked with (installed)
- User can:
  - Select new services to add
  - Select installed services + click "Uninstall Selected"
  - Skip menu to make no changes

## Implementation Changes

### 1. Add Intro Text

```bash
# At beginning of script after argument parsing
if [ "$UNATTENDED" != true ]; then
    cat << 'EOF'
╔════════════════════════════════════════════════════════════════╗
║              Ubuntu Post-Install Setup Script                  ║
╚════════════════════════════════════════════════════════════════╝

This script installs and configures your Ubuntu server in TWO phases:

PHASE 1: ESSENTIAL SETUP (Required)
  • System updates & core packages
  • SSH configuration
  • Docker & Docker Compose
  • Hard drive mounting

PHASE 2: SERVICE SELECTION (Optional)
  • Interactive menu to select services
  • Install OR uninstall services
  • Safe to re-run on existing servers

Press ENTER to begin Phase 1...
EOF
    read -p ""
fi
```

### 2. Reorganize Script Sections

**NEW ORDER:**
1. Intro text
2. Essential system setup (Phase 1)
3. Whiptail menu with ALL services (Phase 2)
4. Service installations based on selections

**REMOVED FROM PRE-WHIPTAIL:**
- Lines 1709-1800: Samba installation → Move to whiptail
- Lines 1596-1625: fail2ban (SSH) → Move to whiptail
- Lines 1841-1888: NetBird → Move to whiptail
- Lines 1889-1945: WireGuard → Move to whiptail
- Lines 1947-1998: Tailscale → Move to whiptail
- Lines 2000-2044: RustDesk → Move to whiptail
- Lines 2046-2095: TeamViewer → Move to whiptail
- Lines 2097-2153: MeshCentral Agent → Move to whiptail

### 3. Update Whiptail Menu

**Add these to the checklist:**
```bash
"SAMBA" "File sharing (Windows, Mac, Linux)" OFF \
"FAIL2BAN_SSH" "Protect SSH from brute-force attacks" OFF \
"TAILSCALE" "Easy VPN mesh network" OFF \
"NETBIRD" "Self-hosted VPN alternative" OFF \
"WIREGUARD" "Manual VPN configuration" OFF \
"RUSTDESK" "Open-source remote desktop" OFF \
"TEAMVIEWER" "Commercial remote desktop" OFF \
"MESHCENTRAL_AGENT" "Remote management agent" OFF \
```

### 4. Add Uninstall Functionality

**New buttons in whiptail:**
```bash
--extra-button --extra-label "Uninstall" \
--ok-button "Install" --cancel-button "Skip"
```

**Check return code:**
- 0 = Install selected
- 1 = Skip/Cancel
- 3 = Uninstall selected

**Uninstall logic:**
```bash
if [ $WHIPTAIL_RETURN -eq 3 ]; then
    # Uninstall mode
    for service in $SELECTED_SERVICES; do
        uninstall_service "$service"
    done
fi
```

### 5. Fix Duplicate Prompts

**Current issue:**
```bash
if [ -z "$INSTALL_AUDIOBOOKSHELF" ]; then
    prompt_yn "Install Audiobookshelf? (y/n):" "n" INSTALL_AUDIOBOOKSHELF
fi
```

**Problem:** This runs even if user didn't select it in whiptail!

**Fix:** Only show prompt if whiptail wasn't used OR variable not set by whiptail

```bash
# After whiptail, set a flag
WHIPTAIL_USED=true

# In individual service sections
if [ "$WHIPTAIL_USED" != true ] && [ -z "$INSTALL_AUDIOBOOKSHELF" ]; then
    prompt_yn "Install Audiobookshelf? (y/n):" "n" INSTALL_AUDIOBOOKSHELF
fi
```

**Or simpler:** Just remove all individual prompts! If whiptail is available, use it. If not, show ALL services as prompts.

## Benefits

1. ✅ Clear two-phase structure
2. ✅ All optional services in ONE menu
3. ✅ No duplicate prompts
4. ✅ Uninstall functionality
5. ✅ Safe to re-run
6. ✅ User understands what's happening when
7. ✅ Faster for users who know what they want

## Migration Path

**For existing users:**
1. Script still works the same way
2. New intro text explains structure
3. Existing installations detected
4. Can use uninstall to remove unwanted services

## Testing Scenarios

1. **Fresh install:** All prompts flow correctly
2. **Re-run:** Detects existing, allows adding new services
3. **Uninstall:** Removes selected services cleanly
4. **Whiptail unavailable:** Falls back to individual prompts
5. **Cancel menu:** Skips all service installations

---

**Implementation Priority:**
1. ✅ Fix duplicate prompts (CRITICAL - doing now)
2. ⏳ Add intro text (HIGH)
3. ⏳ Move services to whiptail (HIGH)
4. ⏳ Add uninstall functionality (MEDIUM)
5. ⏳ Improve re-run detection (LOW - already works)
