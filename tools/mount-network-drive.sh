#!/usr/bin/env bash
# mount-network-drive.sh — Mount a network share (SMB/CIFS or NFS) and add
# it to /etc/fstab so it survives reboots.
#
# Usage:
#   sudo bash mount-network-drive.sh
#
# Supports:
#   - SMB/CIFS (Windows shares, Samba, NAS)
#   - NFS (Linux/NAS exports)

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { printf '\033[0;34m[INFO]\033[0m  %s\n' "$*"; }
ok()      { printf '\033[0;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()     { printf '\033[0;31m[ERROR]\033[0m %s\n' "$*" >&2; }

[[ "$(id -u)" == "0" ]] || { err "Run with sudo: sudo bash $0"; exit 1; }

# Actual user who invoked sudo
ACTUAL_USER="${SUDO_USER:-$USER}"
ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" | cut -d: -f6)"
ACTUAL_UID="$(id -u "$ACTUAL_USER")"
ACTUAL_GID="$(id -g "$ACTUAL_USER")"

# ── Install packages ──────────────────────────────────────────────────────────
ensure_packages() {
    local pkgs=()
    case "$1" in
        smb) command -v mount.cifs &>/dev/null || pkgs+=(cifs-utils) ;;
        nfs) command -v mount.nfs  &>/dev/null || pkgs+=(nfs-common)  ;;
    esac
    if [[ ${#pkgs[@]} -gt 0 ]]; then
        info "Installing: ${pkgs[*]}"
        apt-get install -y "${pkgs[@]}" -qq
    fi
}

# ── Already in fstab? ─────────────────────────────────────────────────────────
fstab_has() {
    grep -qs "$1" /etc/fstab
}

# ── Show existing network mounts ──────────────────────────────────────────────
show_existing() {
    local entries
    entries=$(grep -E 'cifs|nfs' /etc/fstab 2>/dev/null || true)
    if [[ -n "$entries" ]]; then
        info "Existing network mounts in /etc/fstab:"
        echo "$entries" | sed 's/^/  /'
        echo ""
    fi
}

# ── SMB/CIFS ──────────────────────────────────────────────────────────────────
mount_smb() {
    ensure_packages smb

    echo ""
    echo "  Enter the share details."
    echo "  Format: //server/share  (e.g. //192.168.1.10/media  or  //nas/homes)"
    echo ""

    local share=""
    while [[ -z "$share" ]]; do
        read -r -p "  Share path (//server/share): " share
    done

    local default_mount
    default_mount="/mnt/$(echo "$share" | sed 's|//[^/]*/||; s|/|-|g')"
    local mount_point=""
    read -r -p "  Mount point [$default_mount]: " mount_point
    mount_point="${mount_point:-$default_mount}"

    # Credentials
    echo ""
    local use_creds=""
    read -r -p "  Does this share require a username/password? [Y/n]: " use_creds
    local creds_file="" creds_opt=""

    if [[ "${use_creds,,}" != "n" ]]; then
        local smb_user="" smb_pass="" smb_domain=""
        read -r -p "  Username: " smb_user
        read -r -s -p "  Password: " smb_pass; echo ""
        read -r -p "  Domain (leave blank if none): " smb_domain

        # Store credentials file — root-owned, root-readable only
        creds_file="/etc/samba/credentials.$(echo "$share" | sed 's|[^a-zA-Z0-9]|_|g')"
        mkdir -p /etc/samba
        cat > "$creds_file" << CREDS
username=${smb_user}
password=${smb_pass}
${smb_domain:+domain=${smb_domain}}
CREDS
        chmod 600 "$creds_file"
        chown root:root "$creds_file"
        ok "Credentials saved to $creds_file (root-only, 600)"
        creds_opt="credentials=${creds_file}"
    else
        creds_opt="guest"
    fi

    # SMB version
    echo ""
    echo "  SMB version (leave blank to let the system negotiate):"
    echo "    3.0  — modern NAS, Windows 2012+, Samba 4+"
    echo "    2.1  — older NAS, Windows 7/2008 R2"
    echo "    1.0  — legacy only (insecure, not recommended)"
    local smb_ver=""
    read -r -p "  SMB version [auto]: " smb_ver

    local ver_opt=""
    [[ -n "$smb_ver" ]] && ver_opt=",vers=${smb_ver}"

    local opts="uid=${ACTUAL_UID},gid=${ACTUAL_GID},${creds_opt}${ver_opt},iocharset=utf8,nofail,_netdev"

    _do_mount "cifs" "$share" "$mount_point" "$opts"
}

# ── NFS ───────────────────────────────────────────────────────────────────────
mount_nfs() {
    ensure_packages nfs

    echo ""
    echo "  Format: server:/export  (e.g. 192.168.1.10:/mnt/data  or  nas:/homes)"
    echo ""

    local share=""
    while [[ -z "$share" ]]; do
        read -r -p "  NFS export (server:/path): " share
    done

    local default_mount
    default_mount="/mnt/$(echo "$share" | sed 's|[:/]|-|g; s|^-||')"
    local mount_point=""
    read -r -p "  Mount point [$default_mount]: " mount_point
    mount_point="${mount_point:-$default_mount}"

    echo ""
    echo "  NFS version:"
    echo "    4  — recommended (NFSv4, supports Kerberos, ACLs)"
    echo "    3  — older servers/NAS"
    local nfs_ver=""
    read -r -p "  NFS version [4]: " nfs_ver
    nfs_ver="${nfs_ver:-4}"

    local opts="nfsvers=${nfs_ver},rw,soft,intr,nofail,_netdev"

    _do_mount "nfs" "$share" "$mount_point" "$opts"
}

# ── Common mount + fstab logic ────────────────────────────────────────────────
_do_mount() {
    local fstype="$1" share="$2" mount_point="$3" opts="$4"

    # Create mount point
    if [[ ! -d "$mount_point" ]]; then
        mkdir -p "$mount_point"
        ok "Created mount point: $mount_point"
    fi

    # Test mount
    echo ""
    info "Testing mount..."
    if mount -t "$fstype" -o "$opts" "$share" "$mount_point"; then
        ok "Mounted successfully at $mount_point"
    else
        err "Mount failed. Check the share path, credentials, and network connectivity."
        rmdir "$mount_point" 2>/dev/null || true
        return 1
    fi

    # Show what's there
    echo ""
    info "Contents of $mount_point:"
    ls "$mount_point" | head -20 | sed 's/^/  /' || true
    echo ""

    # fstab
    local add_fstab=""
    read -r -p "  Add to /etc/fstab so it mounts on boot? [Y/n]: " add_fstab
    if [[ "${add_fstab,,}" != "n" ]]; then
        if fstab_has "$mount_point"; then
            warn "$mount_point already in /etc/fstab — skipping."
        else
            # Backup fstab
            local bk="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
            cp /etc/fstab "$bk"
            info "Backed up /etc/fstab → $bk"

            printf '\n# %s — added by mount-network-drive.sh %s\n' \
                "$share" "$(date +%Y-%m-%d)" >> /etc/fstab
            printf '%-40s %-25s %-6s %s 0 0\n' \
                "$share" "$mount_point" "$fstype" "$opts" >> /etc/fstab

            ok "Added to /etc/fstab"
            info "Verify with: sudo mount -a"
        fi
    fi

    # Ownership hint
    echo ""
    info "To make this drive writable by $ACTUAL_USER:"
    echo "  sudo chown -R ${ACTUAL_USER}:${ACTUAL_USER} $mount_point"
    echo ""
    ok "Done. $share is mounted at $mount_point"
}

# ── Edit a mount ─────────────────────────────────────────────────────────────
edit_mount() {
    echo ""
    local entries=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        entries+=("$line")
    done < <(grep -E '\bcifs\b|\bnfs\b' /etc/fstab 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        warn "No network mounts found in /etc/fstab."
        return 0
    fi

    echo "  Network mounts in /etc/fstab:"
    echo ""
    local i=1
    for e in "${entries[@]}"; do
        local mp; mp=$(echo "$e" | awk '{print $2}')
        local src; src=$(echo "$e" | awk '{print $1}')
        printf "  %2d)  %-30s  %s\n" "$i" "$src" "$mp"
        i=$(( i + 1 ))
    done
    echo ""

    local choice=""
    read -r -p "  Edit entry number [cancel]: " choice
    [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && { info "Cancelled."; return 0; }

    local idx=$(( choice - 1 ))
    [[ "$idx" -lt 0 || "$idx" -ge ${#entries[@]} ]] && { warn "Invalid selection."; return 0; }

    local target_entry="${entries[$idx]}"
    local target_src;  target_src=$(echo  "$target_entry" | awk '{print $1}')
    local target_mp;   target_mp=$(echo   "$target_entry" | awk '{print $2}')
    local target_fs;   target_fs=$(echo   "$target_entry" | awk '{print $3}')
    local target_opts; target_opts=$(echo "$target_entry" | awk '{print $4}')

    echo ""
    echo "  Current values:"
    printf "    Share      : %s\n" "$target_src"
    printf "    Mount point: %s\n" "$target_mp"
    printf "    Type       : %s\n" "$target_fs"
    printf "    Options    : %s\n" "$target_opts"
    echo ""
    echo "  Press Enter to keep the current value."
    echo ""

    # Share path
    local new_src=""
    read -r -p "  Share path [$target_src]: " new_src
    new_src="${new_src:-$target_src}"

    # Mount point
    local new_mp=""
    read -r -p "  Mount point [$target_mp]: " new_mp
    new_mp="${new_mp:-$target_mp}"

    # Options — offer guided or raw edit
    echo ""
    echo "  Options — edit raw fstab options string, or press Enter to keep."
    local new_opts=""
    read -r -p "  Options [$target_opts]: " new_opts
    new_opts="${new_opts:-$target_opts}"

    # Credentials update (CIFS only)
    local creds_file="/etc/samba/credentials.$(echo "$target_src" | sed 's|[^a-zA-Z0-9]|_|g')"
    if [[ "$target_fs" == "cifs" && -f "$creds_file" ]]; then
        echo ""
        local update_creds=""
        read -r -p "  Update credentials (username/password)? [y/N]: " update_creds
        if [[ "${update_creds,,}" == "y" ]]; then
            local smb_user="" smb_pass="" smb_domain=""
            read -r -p "  Username: " smb_user
            read -r -s -p "  Password: " smb_pass; echo ""
            read -r -p "  Domain (leave blank if none): " smb_domain
            local bk_creds="${creds_file}.backup.$(date +%Y%m%d-%H%M%S)"
            cp "$creds_file" "$bk_creds"
            cat > "$creds_file" << CREDS
username=${smb_user}
password=${smb_pass}
${smb_domain:+domain=${smb_domain}}
CREDS
            chmod 600 "$creds_file"
            chown root:root "$creds_file"
            ok "Credentials updated (old saved to $(basename "$bk_creds"))"
        fi
    fi

    # Write changes
    local bk="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
    cp /etc/fstab "$bk"
    info "Backed up /etc/fstab → $bk"

    # Replace the old line with the new one
    local new_line
    new_line=$(printf '%-40s %-25s %-6s %s 0 0' "$new_src" "$new_mp" "$target_fs" "$new_opts")
    # Escape for sed
    local escaped_old escaped_new
    escaped_old=$(printf '%s\n' "$target_entry" | sed 's/[[\.*^$()+?{|]/\\&/g')
    escaped_new=$(printf '%s\n' "$new_line"     | sed 's/[[\.*^$()+?{|]/\\&/g; s|/|\\/|g')
    sed -i "s|${escaped_old}|${new_line}|" /etc/fstab
    ok "fstab updated"

    # Remount if mount point changed or options changed
    if mountpoint -q "$target_mp" 2>/dev/null; then
        echo ""
        local remount=""
        read -r -p "  Remount now to apply changes? [Y/n]: " remount
        if [[ "${remount,,}" != "n" ]]; then
            umount "$target_mp" 2>/dev/null || warn "Could not unmount cleanly — may still be in use"
            [[ "$new_mp" != "$target_mp" ]] && mkdir -p "$new_mp"
            if mount -t "$target_fs" -o "$new_opts" "$new_src" "$new_mp"; then
                ok "Remounted at $new_mp"
            else
                err "Remount failed — check options and connectivity."
                info "Manual retry: sudo mount -t $target_fs -o $new_opts $new_src $new_mp"
            fi
        fi
    fi
}

# ── Remove a mount ────────────────────────────────────────────────────────────
remove_mount() {
    echo ""
    local entries=()
    while IFS= read -r line; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        entries+=("$line")
    done < <(grep -E '\bcifs\b|\bnfs\b' /etc/fstab 2>/dev/null || true)

    if [[ ${#entries[@]} -eq 0 ]]; then
        warn "No network mounts found in /etc/fstab."
        return 0
    fi

    echo "  Network mounts in /etc/fstab:"
    echo ""
    local i=1
    for e in "${entries[@]}"; do
        local mp; mp=$(echo "$e" | awk '{print $2}')
        local src; src=$(echo "$e" | awk '{print $1}')
        printf "  %2d)  %-30s  %s\n" "$i" "$src" "$mp"
        i=$(( i + 1 ))
    done
    echo ""

    local choice=""
    read -r -p "  Remove entry number [cancel]: " choice
    [[ -z "$choice" || ! "$choice" =~ ^[0-9]+$ ]] && { info "Cancelled."; return 0; }

    local idx=$(( choice - 1 ))
    [[ "$idx" -lt 0 || "$idx" -ge ${#entries[@]} ]] && { warn "Invalid selection."; return 0; }

    local target_entry="${entries[$idx]}"
    local target_mp; target_mp=$(echo "$target_entry" | awk '{print $2}')
    local target_src; target_src=$(echo "$target_entry" | awk '{print $1}')

    warn "Will unmount $target_mp and remove from /etc/fstab."
    local confirm=""
    read -r -p "  Confirm? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Cancelled."; return 0; }

    # Unmount
    if mountpoint -q "$target_mp" 2>/dev/null; then
        umount "$target_mp" && ok "Unmounted $target_mp" || warn "umount failed — may still be in use"
    fi

    # Remove from fstab (match the mount point field)
    local bk="/etc/fstab.backup.$(date +%Y%m%d-%H%M%S)"
    cp /etc/fstab "$bk"
    info "Backed up /etc/fstab → $bk"
    # Remove the entry line and its preceding comment if added by this script
    sed -i "\|${target_src}|d" /etc/fstab
    sed -i "\|# ${target_src} — added by mount-network-drive.sh|d" /etc/fstab
    ok "Removed from /etc/fstab"

    # Remove credentials file if it exists
    local creds_file
    creds_file="/etc/samba/credentials.$(echo "$target_src" | sed 's|[^a-zA-Z0-9]|_|g')"
    if [[ -f "$creds_file" ]]; then
        local rm_creds=""
        read -r -p "  Remove credentials file $creds_file? [Y/n]: " rm_creds
        [[ "${rm_creds,,}" != "n" ]] && rm -f "$creds_file" && ok "Removed $creds_file"
    fi
}

# ── Show current mounts ───────────────────────────────────────────────────────
show_mounts() {
    echo ""
    echo "  Currently mounted network shares:"
    echo ""
    mount | grep -E 'type (cifs|nfs)' | awk '{print "  " $1 "  →  " $3}' || echo "  (none)"
    echo ""
    echo "  /etc/fstab network entries:"
    echo ""
    grep -E '\bcifs\b|\bnfs\b' /etc/fstab | sed 's/^/  /' || echo "  (none)"
    echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────┐"
    echo "│  Network Drive Mount Manager                             │"
    echo "│  SMB/CIFS (Windows/Samba) and NFS shares                │"
    echo "└──────────────────────────────────────────────────────────┘"
    echo ""

    show_existing

    while true; do
        echo "  What would you like to do?"
        echo "    1) Mount an SMB/CIFS share (Windows, Samba, NAS)"
        echo "    2) Mount an NFS share"
        echo "    3) Show current network mounts"
        echo "    4) Edit a mount"
        echo "    5) Remove a mount"
        echo "    0) Quit"
        echo ""
        read -r -p "  Choice [1]: " action
        action="${action:-1}"
        echo ""

        case "$action" in
            1) mount_smb ;;
            2) mount_nfs ;;
            3) show_mounts ;;
            4) edit_mount ;;
            5) remove_mount ;;
            0|q|Q) break ;;
            *) warn "Invalid choice." ;;
        esac
        echo ""
    done

    ok "Done."
}

main "$@"
