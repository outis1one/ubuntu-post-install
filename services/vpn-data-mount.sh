#!/bin/bash
# services/vpn-data-mount.sh — mount SMB data from a NetBird-connected home
# box, with SSH-key bootstrap and remote Samba setup automated over SSH.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash vpn-data-mount.sh
# (No Docker needed — this only touches SSH, Samba, and /etc/fstab)
#
# Unlike most services here, this is repeatable by design: different
# services can have data on different home boxes, so this asks for a home
# box IP every time and can be re-run any number of times, once per
# home-box/share you want mounted. It's the multi-instance pattern from
# CLAUDE.md generalized from "N instances of one app" to "N independent
# mounts" — there's no single install directory to gate on, so state lives
# in /etc/fstab itself (tagged entries), same as tools/mount-network-drive.sh.
#
# Assumes the home box is Linux and reachable over a NetBird IP — this repo
# doesn't set up the home box's side of NetBird (that's a separate machine,
# possibly not running this repo at all); it only automates the VPS side:
# SSH trust, then using that SSH access to configure Samba on the home box
# remotely, then mounting it here.
#
# SMB chosen over NFS/SSHFS deliberately: NFS is marginally faster for
# Linux-to-Linux but SMB isn't a "huge" difference for normal use (media,
# docs, moderate datasets — the gap shows up mainly on many-small-files
# workloads). SSHFS was ruled out because the VPN tunnel already encrypts
# everything — SSHFS's own SSH-layer encryption on top of that is pure
# redundant overhead for no added security, and it's the slowest and least
# robust (FUSE reconnect quirks) of the three for an always-on mount.
#
# The share is guest-accessible (no separate Samba username/password to
# manage) because the VPN is the actual access control here — only
# NetBird-connected peers can reach the home box's NetBird IP at all, so a
# second credential layer on top of that doesn't add real security, just
# more secrets to lose track of.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        prompt_text() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        prompt_yn() {
            local _q="$1" _def="$2" _var="$3" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='$_def'"; return; }
            read -r -p "  $_q " _r
            eval "$_var='${_r:-$_def}'"
        }

        register_service() { :; }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"

    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service vpn-data-mount homelab "Mount SMB data from a NetBird-connected home box (SSH-automated remote setup)"

# ── fstab tagging — the durable record of what this tool has set up ────────
# Same philosophy as tools/mount-network-drive.sh: /etc/fstab is the single
# source of truth, no separate state file to drift out of sync with it.
_VDM_TAG_PREFIX="# vpn-data-mount:"

_vdm_list_existing() {
    local entries
    entries="$(grep "^${_VDM_TAG_PREFIX}" /etc/fstab 2>/dev/null || true)"
    if [ -n "$entries" ]; then
        echo ""
        log_info "Already-configured VPN data mounts:"
        echo "$entries" | sed "s|^${_VDM_TAG_PREFIX}|  •|"
        echo ""
    fi
}

# ── SSH trust: test first, only bootstrap if actually needed ──────────────
# Covers "the home box and VPS already share a key via GitHub import (or any
# other means)" for free — if it already works, nothing below runs at all.
_vdm_ssh_works() {
    local user="$1" host="$2"
    # Runs as $ACTUAL_USER, not root (this whole script runs as root) — the
    # SSH key lives in $ACTUAL_HOME/.ssh, so root's own bare `ssh` would look
    # in the wrong home directory entirely and never find it.
    sudo -u "$ACTUAL_USER" ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
        "${user}@${host}" true 2>/dev/null
}

_vdm_ensure_ssh_trust() {
    local user="$1" host="$2"

    if _vdm_ssh_works "$user" "$host"; then
        log_success "Passwordless SSH to ${user}@${host} already works — nothing to set up."
        return 0
    fi

    log_info "No passwordless SSH to ${user}@${host} yet — setting it up."

    local keyfile="$ACTUAL_HOME/.ssh/id_ed25519"
    if [ ! -f "$keyfile" ]; then
        log_info "No SSH key found at $keyfile — generating one."
        sudo -u "$ACTUAL_USER" mkdir -p "$ACTUAL_HOME/.ssh"
        sudo -u "$ACTUAL_USER" ssh-keygen -t ed25519 -N "" -f "$keyfile" -C "${ACTUAL_USER}@$(hostname)-vpn-data-mount" \
            || { log_error "Key generation failed."; return 1; }
        chmod 700 "$ACTUAL_HOME/.ssh"
        chmod 600 "$keyfile"
        chmod 644 "${keyfile}.pub"
    fi

    echo ""
    echo "  This box's public key (needs to end up in ${user}'s authorized_keys"
    echo "  on the home box, one way or another):"
    echo ""
    sed 's/^/    /' "${keyfile}.pub"
    echo ""

    while true; do
        echo "  How do you want to get it there?"
        echo "    1) Try now with ssh-copy-id (needs password login enabled on the home box)"
        echo "    2) I'll add it myself — paste it into ~/.ssh/authorized_keys there, or add it"
        echo "       to your GitHub account and run 'ssh-import-id gh:<user>' on the home box"
        echo "       (same mechanism this repo's own base.sh setup uses)"
        echo "    3) Cancel this mount"
        echo ""
        local CHOICE=""
        prompt_text "  Choice [1/2/3]:" "1" CHOICE
        case "$CHOICE" in
            1)
                sudo -u "$ACTUAL_USER" ssh-copy-id -i "${keyfile}.pub" "${user}@${host}" \
                    || log_warning "ssh-copy-id failed — password auth may be disabled on the home box. Try option 2."
                ;;
            2)
                echo ""
                read -r -p "  Press Enter once the key is in place on the home box: " _
                ;;
            3|c|C)
                log_info "Cancelled."
                return 1
                ;;
            *)
                log_warning "Invalid choice."
                continue
                ;;
        esac

        if _vdm_ssh_works "$user" "$host"; then
            log_success "Passwordless SSH to ${user}@${host} confirmed."
            return 0
        fi
        log_warning "Still can't connect without a password — try again, or cancel."
    done
}

# ── Remote Samba setup, driven entirely over the SSH trust above ──────────
_vdm_setup_remote_samba() {
    local user="$1" host="$2" remote_path="$3" share_name="$4"

    log_info "Checking Samba on the home box..."
    # Every ssh call below runs as $ACTUAL_USER, same reason as _vdm_ssh_works.
    if ! sudo -u "$ACTUAL_USER" ssh "${user}@${host}" 'command -v smbd >/dev/null 2>&1'; then
        log_info "Installing Samba on the home box (may prompt for the sudo password there)..."
        sudo -u "$ACTUAL_USER" ssh -t "${user}@${host}" 'sudo apt-get update -y && sudo apt-get install -y samba' \
            || { log_error "Remote Samba install failed."; return 1; }
    else
        log_success "Samba already installed on the home box."
    fi

    log_info "Configuring the share on the home box..."
    # Idempotent: drop any prior block for this exact share name, then
    # append a fresh one. Guest-accessible — see the file header for why.
    local remote_cmd
    remote_cmd=$(cat << REMOTECMD
set -e
sudo mkdir -p '${remote_path}'
sudo cp /etc/samba/smb.conf /etc/samba/smb.conf.backup.\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true
sudo sed -i "/^\\[${share_name}\\]\$/,/^\$/d" /etc/samba/smb.conf
{
  echo ""
  echo "[${share_name}]"
  echo "   path = ${remote_path}"
  echo "   browseable = yes"
  echo "   read only = no"
  echo "   guest ok = yes"
  echo "   force user = \$(whoami)"
} | sudo tee -a /etc/samba/smb.conf >/dev/null
sudo systemctl restart smbd
command -v ufw >/dev/null 2>&1 && sudo ufw allow samba >/dev/null 2>&1 || true
REMOTECMD
)
    if sudo -u "$ACTUAL_USER" ssh -t "${user}@${host}" "$remote_cmd"; then
        log_success "Remote share [$share_name] -> $remote_path configured and smbd restarted."
    else
        log_error "Remote Samba configuration failed — check the output above."
        return 1
    fi
}

# ── Local mount + fstab ─────────────────────────────────────────────────────
_vdm_mount_local() {
    local host="$1" share_name="$2" mount_point="$3" label="$4"

    command -v mount.cifs >/dev/null 2>&1 || apt-get install -y cifs-utils -qq

    mkdir -p "$mount_point"

    local opts="guest,uid=$(id -u "$ACTUAL_USER"),gid=$(id -g "$ACTUAL_USER"),iocharset=utf8,nofail,_netdev"
    local share="//${host}/${share_name}"

    log_info "Testing mount..."
    if mount -t cifs -o "$opts" "$share" "$mount_point"; then
        log_success "Mounted at $mount_point"
    else
        log_error "Mount failed — check connectivity to $host and the remote share config."
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi

    if grep -qs "$mount_point" /etc/fstab; then
        log_warning "$mount_point already in /etc/fstab — skipping fstab entry."
        return 0
    fi
    local bk="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
    cp /etc/fstab "$bk"
    {
        echo ""
        echo "${_VDM_TAG_PREFIX} ${label} — ${host}:${share_name} -> ${mount_point}"
        printf '%-40s %-25s %-6s %s 0 0\n' "$share" "$mount_point" "cifs" "$opts"
    } >> /etc/fstab
    log_success "Added to /etc/fstab (backup: $(basename "$bk"))"
}

# ── One mount, start to finish ──────────────────────────────────────────────
_vdm_add_mount() {
    echo ""
    local LABEL=""
    while true; do
        prompt_text "  Short label for this mount (e.g. 'media', 'nas-docs'):" "" LABEL
        LABEL="$(echo "$LABEL" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
        if [ -z "$LABEL" ]; then
            log_warning "Label can't be empty."; continue
        fi
        if grep -q "^${_VDM_TAG_PREFIX} ${LABEL} " /etc/fstab 2>/dev/null; then
            log_warning "Label '$LABEL' is already used — pick another."; continue
        fi
        break
    done

    local HOST="" SSH_USER=""
    prompt_text "  Home box's NetBird IP (or hostname — check 'netbird status' on that box):" "" HOST
    if [ -z "$HOST" ]; then
        log_warning "No host entered — cancelling this mount."
        return 1
    fi
    prompt_text "  SSH username on the home box:" "$ACTUAL_USER" SSH_USER

    _vdm_ensure_ssh_trust "$SSH_USER" "$HOST" || return 1

    local REMOTE_PATH="" MOUNT_POINT=""
    prompt_text "  Path on the home box to share (e.g. /home/${SSH_USER}/media):" "" REMOTE_PATH
    if [ -z "$REMOTE_PATH" ]; then
        log_warning "No path entered — cancelling this mount."
        return 1
    fi
    prompt_text "  Local mount point:" "/mnt/${LABEL}" MOUNT_POINT

    _vdm_setup_remote_samba "$SSH_USER" "$HOST" "$REMOTE_PATH" "$LABEL" || return 1
    _vdm_mount_local "$HOST" "$LABEL" "$MOUNT_POINT" "$LABEL" || return 1

    echo ""
    log_success "Done: $HOST:$REMOTE_PATH is now mounted at $MOUNT_POINT"
    echo "  Manage this and other network mounts anytime with:"
    echo "    sudo bash tools/mount-network-drive.sh"
}

install_vpn-data-mount() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  VPN Data Mount — SMB share from a NetBird-connected box  ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would test/set up passwordless SSH to a home box over its NetBird IP"
        echo "[DRY-RUN] Would remotely install+configure Samba there for a chosen path"
        echo "[DRY-RUN] Would mount it locally over CIFS and add it to /etc/fstab"
        echo "[DRY-RUN] Repeatable — can be run again for additional home boxes/shares"
        return 0
    fi

    # Every prompt below (home box IP, remote path, ...) has no sane
    # unattended default — unlike most services here, there's no reasonable
    # value to fall back to. Skip outright rather than let prompt_text's
    # always-blank UNATTENDED behavior spin the label-validation loop below
    # forever.
    if [ "$UNATTENDED" = true ]; then
        log_info "Skipping — needs interactive input (home box IP, path, ...). Run 'sudo ./setup.sh vpn-data-mount' without --unattended."
        return 0
    fi

    _vdm_list_existing

    while true; do
        local ADD=""
        prompt_yn "Add a VPN data mount now? (y/n):" "y" ADD
        [[ "$ADD" =~ ^[Yy]$ ]] || break

        _vdm_add_mount

        local AGAIN=""
        prompt_yn "Add another mount (can be from a different home box)? (y/n):" "n" AGAIN
        [[ "$AGAIN" =~ ^[Yy]$ ]] || break
    done
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_vpn-data-mount
