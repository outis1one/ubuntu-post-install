#!/bin/bash
# fix-wolf-webview2-userns.sh — Let WebView2 (and other Chromium sandboxes)
# initialize inside Wolf / Games-on-Whales app containers, so Kyber's EA OAuth
# login works WITHOUT leaving Wolf.
#
# ── The problem ────────────────────────────────────────────────────────────
#
# Kyber's login depends on its embedded Microsoft Edge WebView2. WebView2 (like
# all Chromium-based sandboxes) spawns a zygote/renderer in a NEW user namespace
# via clone(CLONE_NEWUSER). Inside the WolfSteam container that clone fails with
# EPERM, WebView2 cannot start, Kyber falls back to `cmd /c start <url>`, and the
# login flow dies (see setup-kyber-wolf.sh for the full autopsy).
#
# ── Why it is NOT the container's fault ────────────────────────────────────
#
# The WolfSteam app container ALREADY runs with:
#     security_opt = seccomp=unconfined, apparmor=unconfined
#     cap_add      = SYS_ADMIN, ...
# (see services/wolf.sh, the 'steam' entry in CATALOG). So Docker's own seccomp
# and AppArmor confinement are not the gate.
#
# The real gate is a HOST kernel setting that Ubuntu 23.10+ (and 24.04 / newer
# kernels) ship enabled by default:
#
#     kernel.apparmor_restrict_unprivileged_userns = 1
#
# When set to 1, the kernel's AppArmor LSM blocks creation of unprivileged user
# namespaces for processes under the (even "unconfined") profile — which is
# exactly what WebView2 needs. Because this is enforced at the host kernel level,
# passing apparmor=unconfined to the container does NOT bypass it. The sysctl
# must be relaxed on the host.
#
# Older kernels (Debian, pre-5.x Ubuntu) used a different toggle:
#     kernel.unprivileged_userns_clone = 0   (1 = allow)
# This script handles both.
#
# ── What this script does ──────────────────────────────────────────────────
#   1. Reports the current value of both sysctls.
#   2. Sets apparmor_restrict_unprivileged_userns=0 (and unprivileged_userns_clone=1
#      if present) for the running kernel AND persistently via /etc/sysctl.d/.
#   3. Probes whether unprivileged user namespaces now work, on the host and
#      inside the running WolfSteam container.
#   4. Tells you to relaunch the Steam app in Moonlight, then retry Kyber login.
#
# ── Security note ──────────────────────────────────────────────────────────
# Relaxing this sysctl re-enables unprivileged user namespaces host-wide. That
# is the pre-23.10 default and how most distros still ship. It widens the kernel
# attack surface slightly (some past CVEs were reachable via unprivileged
# userns). On a single-user home gaming box this is a reasonable trade; on a
# shared/multi-tenant host, weigh it before applying.
#
# ── Usage ──────────────────────────────────────────────────────────────────
#   sudo ./fix-wolf-webview2-userns.sh

set -euo pipefail

if [ "$(id -u)" != "0" ]; then
    echo "Run with sudo: sudo $0"
    exit 1
fi

SYSCTL_AA="kernel.apparmor_restrict_unprivileged_userns"
SYSCTL_CLONE="kernel.unprivileged_userns_clone"
SYSCTL_FILE="/etc/sysctl.d/99-wolf-webview2-userns.conf"

echo "=== Wolf WebView2 / unprivileged-userns fix ==="
echo ""

# ── 1. Report current state ────────────────────────────────────────────────
have_aa=0
have_clone=0
if [ -e "/proc/sys/${SYSCTL_AA//.//}" ]; then
    have_aa=1
    cur_aa=$(sysctl -n "$SYSCTL_AA")
    echo "  $SYSCTL_AA = $cur_aa  (1 = blocks WebView2, 0 = allows)"
else
    echo "  $SYSCTL_AA: not present on this kernel (fine — nothing to relax here)"
fi
if [ -e "/proc/sys/${SYSCTL_CLONE//.//}" ]; then
    have_clone=1
    cur_clone=$(sysctl -n "$SYSCTL_CLONE")
    echo "  $SYSCTL_CLONE = $cur_clone  (0 = blocks, 1 = allows)"
else
    echo "  $SYSCTL_CLONE: not present on this kernel (fine — newer kernels use the AppArmor gate)"
fi
echo ""

if [ "$have_aa" = 0 ] && [ "$have_clone" = 0 ]; then
    echo "Neither sysctl exists — unprivileged user namespaces are not gated by"
    echo "these knobs on your kernel. If WebView2 still fails, the cause is"
    echo "elsewhere (check 'dmesg' for apparmor/seccomp denials while launching"
    echo "Kyber, and confirm the WolfSteam container has seccomp=unconfined)."
fi

# ── 2. Apply the relaxation (runtime + persistent) ─────────────────────────
echo "[1/3] Applying sysctl changes..."
{
    echo "# Allow unprivileged user namespaces so Chromium/WebView2 sandboxes can"
    echo "# initialize inside Wolf app containers (Kyber EA OAuth login)."
    echo "# Written by fix-wolf-webview2-userns.sh"
} > "$SYSCTL_FILE"

if [ "$have_aa" = 1 ]; then
    echo "$SYSCTL_AA = 0" >> "$SYSCTL_FILE"
    sysctl -w "$SYSCTL_AA=0" >/dev/null
    echo "  set $SYSCTL_AA = 0 (runtime + $SYSCTL_FILE)"
fi
if [ "$have_clone" = 1 ]; then
    echo "$SYSCTL_CLONE = 1" >> "$SYSCTL_FILE"
    sysctl -w "$SYSCTL_CLONE=1" >/dev/null
    echo "  set $SYSCTL_CLONE = 1 (runtime + $SYSCTL_FILE)"
fi
echo "  persistent config: $SYSCTL_FILE"
echo ""

# ── 3. Probe that unprivileged userns now works ────────────────────────────
echo "[2/3] Probing unprivileged user-namespace creation..."

probe_host() {
    # unshare -U returns non-zero if the kernel refuses a new user namespace.
    if unshare -U --map-root-user true 2>/dev/null; then
        echo "  HOST: unprivileged user namespace OK"
        return 0
    else
        echo "  HOST: still BLOCKED — a reboot may be required for the AppArmor"
        echo "        policy change to fully take effect. Reboot and re-run."
        return 1
    fi
}
probe_host || true

WOLF_STEAM=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -i WolfSteam | head -1 || true)
if [ -n "$WOLF_STEAM" ]; then
    echo "  Testing inside running container: $WOLF_STEAM"
    if docker exec "$WOLF_STEAM" unshare -U --map-root-user true 2>/dev/null; then
        echo "  CONTAINER: unprivileged user namespace OK — WebView2 should start now"
    else
        echo "  CONTAINER: still blocked. Restart the Steam app in Moonlight"
        echo "  (stop + relaunch so the container is recreated), then re-run the probe:"
        echo "    docker exec <WolfSteam_*> unshare -U --map-root-user true && echo OK"
    fi
else
    echo "  No running WolfSteam container found — launch Steam in Moonlight,"
    echo "  then retest:  docker exec <WolfSteam_*> unshare -U --map-root-user true && echo OK"
fi
echo ""

# ── 4. Next steps ──────────────────────────────────────────────────────────
echo "[3/3] Done."
echo ""
echo "=== Next steps ==="
echo ""
echo "  1. If the HOST probe still showed BLOCKED, REBOOT now and re-run this"
echo "     script — some AppArmor policy changes only apply on a fresh boot."
echo "  2. In Moonlight: STOP the Steam app if it is running, then relaunch it"
echo "     so Wolf recreates the WolfSteam container with the new host policy."
echo "  3. Launch Kyber. Click Login. WebView2 should now initialize, open the"
echo "     EA login page inside Kyber, and — after you log in — catch the qrc://"
echo "     redirect INTERNALLY. No fake cmd.exe, no Firefox, no manual steps."
echo ""
echo "  If WebView2 STILL fails after a reboot + relaunch:"
echo "    - Watch for denials while launching Kyber:"
echo "        sudo dmesg -w | grep -i 'apparmor\\|userns\\|seccomp'"
echo "    - Confirm the container has the right opts:"
echo "        docker inspect $WOLF_STEAM --format '{{.HostConfig.SecurityOpt}}'"
echo "      Expected: [seccomp=unconfined apparmor=unconfined]"
echo "    - As a last resort, fall back to the native path:"
echo "        scripts/setup-kyber-linux.sh"
