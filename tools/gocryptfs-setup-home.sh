#!/usr/bin/env bash
# gocryptfs-setup-home.sh — Set up a gocryptfs-encrypted directory on this
# box (the "home box" in vpn-data-mount.sh's terms) so a remote VPS can
# mount it over SMB and only ever handle ciphertext.
#
# Usage:
#   sudo bash gocryptfs-setup-home.sh
#
# What this buys you: files placed in the encrypted store below are
# encrypted on THIS box, before they ever cross the network. Your existing
# Samba share, if its `path =` points at the encrypted store (a manual
# smb.conf edit — see "Next steps" at the end of this script; this tool
# doesn't touch smb.conf, matching vpn-data-mount.sh's own read-only stance
# on remote Samba config), only ever transmits ciphertext over SMB. The
# VPS's CIFS mount, and its own disk/page cache, only ever hold ciphertext
# too. services/vpn-data-mount.sh's optional decrypt-layer step then fetches
# the passphrase file this script creates below, fresh, over the same SSH
# trust already used for share discovery — never storing it on the VPS's
# disk — and decrypts on the fly into a second mountpoint there.
#
# What this does NOT buy you: privacy from whatever's actively reading
# through that decrypted view on the VPS while it's mounted there — if a
# service on the VPS needs to read the plaintext to do its job (serve a
# file, transcode video, whatever), that service (and root on that VPS)
# sees plaintext for as long as it's mounted, same as any live-in-use data
# anywhere. What changes is everything else: a disk image, backup, or
# provider-side look at the VPS while the passphrase isn't actively loaded
# shows only ciphertext, instead of showing your actual files.
#
# This also does NOT migrate any existing plainly-shared data into the new
# encrypted store automatically — that's a real "am I about to overwrite/
# lose something" decision this script shouldn't make for you. If you have
# an existing share you want to convert, mount the plaintext view this
# script offers to create, move your files into it yourself (they land
# encrypted in the cipherdir as you do), then repoint your Samba share's
# `path =` at the cipherdir once you're done.

set -euo pipefail

info() { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()   { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()  { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

[[ "$(id -u)" == "0" ]] || { err "Run with sudo: sudo bash $0"; exit 1; }

ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"

# Prompts twice, hidden, matching — prints the password on success. IFS=
# matters, not just -s/-r: a plain `read -r pw1` silently strips leading/
# trailing whitespace even into a single variable, which would make the
# passphrase saved to the passfile different from the one actually set on
# the store — see services/vpn-data-mount.sh's own note on this, same bug.
prompt_password_confirm() {
    local prompt="$1" pw1="" pw2=""
    while true; do
        echo -n "  ${prompt}: " >&2
        IFS= read -r -s pw1; echo "" >&2
        echo -n "  Confirm: " >&2
        IFS= read -r -s pw2; echo "" >&2
        if [ -n "$pw1" ] && [ "$pw1" = "$pw2" ]; then
            echo "  Captured (${#pw1} characters)." >&2
            printf '%s' "$pw1"
            return 0
        fi
        echo "  Passwords didn't match or were empty — try again." >&2
    done
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  gocryptfs setup — client-side encryption for a vpn-data-mount share"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  This creates an encrypted directory (a 'cipherdir') on this box."
echo "  Point your Samba share's 'path =' at the cipherdir itself, not the"
echo "  plaintext view — the VPS should only ever receive ciphertext."
echo ""

command -v gocryptfs >/dev/null 2>&1 || {
    info "Installing gocryptfs..."
    apt-get update -qq
    apt-get install -y gocryptfs -qq
}

CIPHERDIR=""
read -r -p "  Directory to create as the encrypted store [${ACTUAL_HOME}/encrypted-share]: " CIPHERDIR
CIPHERDIR="${CIPHERDIR:-${ACTUAL_HOME}/encrypted-share}"

DEFAULT_PASSFILE="${ACTUAL_HOME}/.gocryptfs-$(basename "$CIPHERDIR").pass"
PASSFILE=""
read -r -p "  Where to save the passphrase file for the VPS to fetch [${DEFAULT_PASSFILE}]: " PASSFILE
PASSFILE="${PASSFILE:-$DEFAULT_PASSFILE}"

if [[ -f "${CIPHERDIR}/gocryptfs.conf" ]]; then
    warn "${CIPHERDIR} is already a gocryptfs store — leaving it as-is."
    [[ -f "$PASSFILE" ]] || warn "But $PASSFILE doesn't exist — the VPS-side decrypt step needs it. Re-run and use the same passphrase you set this store up with, or create $PASSFILE by hand with 'username=...' replaced by just the passphrase on one line."
else
    if [[ -f "$PASSFILE" ]]; then
        err "$PASSFILE already exists but $CIPHERDIR isn't an initialized store — refusing to guess whether they're supposed to match. Remove one or point at a different path and re-run."
        exit 1
    fi

    echo ""
    echo "  Set a passphrase for this store now. This is the ONE thing that"
    echo "  decrypts it — write it down somewhere safe. There is no recovery"
    echo "  if it's lost; everything inside becomes permanently unreadable."
    echo ""
    PASSPHRASE="$(prompt_password_confirm "Passphrase for the new encrypted store")"

    mkdir -p "$(dirname "$PASSFILE")"
    printf '%s\n' "$PASSPHRASE" > "$PASSFILE"
    chmod 600 "$PASSFILE"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$PASSFILE"

    mkdir -p "$CIPHERDIR"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$CIPHERDIR"
    sudo -u "$ACTUAL_USER" gocryptfs -passfile "$PASSFILE" -init "$CIPHERDIR"
    ok "Encrypted store created at $CIPHERDIR"
    ok "Passphrase saved to $PASSFILE (owner-only, 600)"
    warn "Anyone who can read $PASSFILE can decrypt everything in $CIPHERDIR — it's exactly as sensitive as the data itself. It only needs to be readable by $ACTUAL_USER and root; treat SSH access to this account accordingly, since that's how the VPS fetches it."
fi

echo ""
MOUNTPOINT=""
read -r -p "  Also mount the plaintext view locally now, so you can use it here? Enter a mount point, or leave blank to skip: " MOUNTPOINT
if [[ -n "$MOUNTPOINT" ]]; then
    mkdir -p "$MOUNTPOINT"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$MOUNTPOINT"
    if sudo -u "$ACTUAL_USER" gocryptfs -passfile "$PASSFILE" "$CIPHERDIR" "$MOUNTPOINT"; then
        ok "Mounted plaintext view at $MOUNTPOINT (unmount later with: fusermount -u $MOUNTPOINT)"
    else
        warn "Mount failed — the store and passfile are still set up correctly, this just means you'll need to mount it yourself: gocryptfs -passfile $PASSFILE $CIPHERDIR $MOUNTPOINT"
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Next steps"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  1. Point your Samba share's 'path =' at the cipherdir itself:"
echo "       $CIPHERDIR"
echo "     (not the plaintext mount point above, if you made one) — this"
echo "     tool doesn't edit smb.conf for you, same as vpn-data-mount.sh's"
echo "     own read-only stance on the VPS side. If this share doesn't"
echo "     exist yet, tools/mount-network-drive.sh has no share-creation"
echo "     flow either — use Samba's own tools (smb.conf + smbpasswd)."
echo ""
echo "  2. On the VPS, run (or re-run) 'sudo ./setup.sh vpn-data-mount'."
echo "     After it mounts this share over CIFS as usual, say yes when it"
echo "     asks whether to layer gocryptfs decryption on top, and give it"
echo "     this path when asked for the passphrase file:"
echo "       $PASSFILE"
echo ""
