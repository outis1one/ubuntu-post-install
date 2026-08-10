#!/bin/bash
# services/vpn-data-mount.sh — mount existing SMB shares from a
# NetBird-connected home box, with SSH-key bootstrap automated.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash vpn-data-mount.sh
# (No Docker needed — this only touches SSH and /etc/fstab)
#
# Unlike most services here, this is repeatable by design: different
# services can have data on different home boxes, so this asks for a home
# box IP every time and can be re-run any number of times, once per
# home-box you want to pull shares from. It's the multi-instance pattern
# from CLAUDE.md generalized from "N instances of one app" to "N
# independent mounts" — there's no single install directory to gate on, so
# state lives in /etc/fstab itself (tagged entries), same as
# tools/mount-network-drive.sh.
#
# Deliberately READ-ONLY on the home box's Samba config — this tool never
# writes to smb.conf, never installs Samba, never creates or resets a
# Samba account there. It only (a) bootstraps passwordless SSH if needed,
# then (b) reads the home box's existing smb.conf over that SSH connection
# to list whatever shares are already configured there, so you can pick
# one or more to mount. Set up the actual share(s) on the home box
# yourself, the normal way (or with tools/mount-network-drive.sh's own
# guided flow, run there). An earlier version of this tried to fully
# provision Samba remotely too — reversed per direct request, and it had
# also caused real damage in practice (a section-removal bug that deleted
# unrelated shares on a real box) that a read-only tool can't repeat.
#
# Assumes the home box is Linux and reachable over a NetBird IP — this repo
# doesn't set up the home box's side of NetBird (that's a separate machine,
# possibly not running this repo at all).
#
# SMB chosen over NFS/SSHFS deliberately: NFS is marginally faster for
# Linux-to-Linux but SMB isn't a "huge" difference for normal use (media,
# docs, moderate datasets — the gap shows up mainly on many-small-files
# workloads). SSHFS was ruled out because the VPN tunnel already encrypts
# everything — SSHFS's own SSH-layer encryption on top of that is pure
# redundant overhead for no added security, and it's the slowest and least
# robust (FUSE reconnect quirks) of the three for an always-on mount.
#
# Mounts use real Samba credentials (a username/password you provide for
# an account that already exists on the home box), stored locally in a
# root-only credentials file, same convention tools/mount-network-drive.sh
# already uses — never guest access. A CIFS guest mount with no explicit
# security mode can hit "mount error(79): Can not access a needed shared
# library" — a misleadingly-worded cifs-utils message for errno 79
# (ENOKEY), a known rough edge in the kernel cifs.ko keyring/upcall path
# for anonymous sessions. Credentialed mounts with an explicit sec=ntlmssp
# take the normal NTLMSSP auth path instead and don't hit it.

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

register_service vpn-data-mount homelab "Mount existing SMB shares from a NetBird-connected home box (read-only discovery, SSH-automated key setup)"

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

# ── Name a raw IP so it can be used everywhere instead of typing it again ──
# Deliberately /etc/hosts, not ~/.ssh/config: an SSH Host alias only helps
# the `ssh` command itself resolve a name — mount.cifs (and everything
# else) never consults ~/.ssh/config at all, so an alias alone wouldn't let
# the actual CIFS mount address use a name. /etc/hosts is the one mechanism
# that makes a name resolve for both, which is what "use a name instead of
# the IP" actually needs end to end.
# Sets RESOLVED_HOST (not local — same out-param convention as elsewhere).
_vdm_resolve_host() {
    local input="$1"
    RESOLVED_HOST="$input"

    # Not a raw IP (already a name, whether from /etc/hosts, real DNS, or
    # just typed that way) — nothing to do.
    [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 0

    # Already named from an earlier vpn-data-mount run against this same IP?
    local existing
    existing="$(awk -v ip="$input" '$1==ip && /# vpn-data-mount/ {print $2; exit}' /etc/hosts 2>/dev/null)"
    if [ -n "$existing" ]; then
        log_info "Already named '$existing' in /etc/hosts from an earlier mount — using that."
        RESOLVED_HOST="$existing"
        return 0
    fi

    local NAME=""
    prompt_text "  Name this home box (blank to keep using the IP):" "" NAME
    [ -z "$NAME" ] && return 0
    NAME="$(echo "$NAME" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
    [ -z "$NAME" ] && return 0

    if grep -qE "^\S+[[:space:]]+${NAME}([[:space:]]|\$)" /etc/hosts 2>/dev/null; then
        log_warning "'$NAME' is already used for a different address in /etc/hosts — keeping the IP instead."
        return 0
    fi

    echo "${input}    ${NAME}    # vpn-data-mount" >> /etc/hosts
    log_success "Added to /etc/hosts: $NAME -> $input (works for SSH, this mount, and anything else on this box)"
    RESOLVED_HOST="$NAME"
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

# ── Read-only share discovery ───────────────────────────────────────────────
# Prints "share_name|path" one per line for every real data share found in
# the home box's smb.conf (skips [global]/[homes]/[printers]/[print$] —
# not actual browsable directories). Never writes anything, on either
# side — see the file header. Tries a plain read first (smb.conf is
# world-readable on a stock Samba install); falls back to a sudo'd read
# only if that comes back empty, still read-only either way.
_vdm_list_remote_shares() {
    local user="$1" host="$2"
    local conf
    conf="$(sudo -u "$ACTUAL_USER" ssh "${user}@${host}" 'cat /etc/samba/smb.conf 2>/dev/null')"
    if [ -z "$conf" ]; then
        conf="$(sudo -u "$ACTUAL_USER" ssh -t "${user}@${host}" 'sudo cat /etc/samba/smb.conf 2>/dev/null' 2>/dev/null)"
    fi
    [ -z "$conf" ] && return 1

    echo "$conf" | awk '
        function flush() {
            if (sect != "" && path != "" && sect != "global" && sect != "printers" && sect != "print$" && sect != "homes") {
                print sect "|" path
            }
        }
        /^\[/ {
            flush()
            sect = $0
            gsub(/[][]/, "", sect)
            path = ""
            next
        }
        /^[[:space:]]*path[[:space:]]*=/ {
            path = $0
            sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", path)
            gsub(/[[:space:]]+$/, "", path)
        }
        END { flush() }
    '
}

# ── Reuse a password already entered for the same user+host ───────────────
# Prints the password if an earlier mount from this host used the same
# Samba username, nothing otherwise. No log_* calls in here — this runs
# inside a caller's $(...) capture, and log_info/log_warning/etc. all
# write to stdout, which would corrupt it.
_vdm_find_existing_smb_password() {
    local host="$1" user="$2" label creds_file found_user found_pass
    while IFS= read -r label; do
        [ -z "$label" ] && continue
        creds_file="/etc/samba/credentials.vpn-data-mount-${label}"
        [ -f "$creds_file" ] || continue
        found_user="$(grep '^username=' "$creds_file" | cut -d= -f2-)"
        [ "$found_user" = "$user" ] || continue
        found_pass="$(grep '^password=' "$creds_file" | cut -d= -f2-)"
        [ -n "$found_pass" ] && { printf '%s' "$found_pass"; return 0; }
    done < <(grep -E "^${_VDM_TAG_PREFIX} [^ ]+ — ${host}:" /etc/fstab 2>/dev/null \
        | sed -E "s/^${_VDM_TAG_PREFIX} ([^ ]+) .*/\1/")
    return 1
}

# ── Prompt for a password twice, hidden, matching ──────────────────────────
# Prints the password on success. No log_* calls — same reason as above;
# uses plain stderr output instead so it's visible without corrupting a
# caller's $(...) capture.
_vdm_prompt_password() {
    local prompt="$1" pw1="" pw2=""
    while true; do
        echo -n "  ${prompt}: " >&2
        read -r -s pw1; echo "" >&2
        echo -n "  Confirm: " >&2
        read -r -s pw2; echo "" >&2
        if [ -n "$pw1" ] && [ "$pw1" = "$pw2" ]; then
            printf '%s' "$pw1"
            return 0
        fi
        echo "  Passwords didn't match or were empty — try again." >&2
    done
}

# ── Local mount + fstab ─────────────────────────────────────────────────────
_vdm_mount_local() {
    local host="$1" share_name="$2" mount_point="$3" label="$4" smb_user="$5" smb_pass="$6"

    command -v mount.cifs >/dev/null 2>&1 || apt-get install -y cifs-utils -qq

    mkdir -p "$mount_point"

    # Credentials file, not guest/inline password — root-only, matching
    # tools/mount-network-drive.sh's existing convention for SMB creds.
    local creds_file="/etc/samba/credentials.vpn-data-mount-${label}"
    mkdir -p /etc/samba
    cat > "$creds_file" << CREDS
username=${smb_user}
password=${smb_pass}
CREDS
    chmod 600 "$creds_file"
    chown root:root "$creds_file"

    # sec=ntlmssp explicitly — see the file header on errno 79/ENOKEY.
    local opts="credentials=${creds_file},sec=ntlmssp,uid=$(id -u "$ACTUAL_USER"),gid=$(id -g "$ACTUAL_USER"),iocharset=utf8,nofail,_netdev"
    local share="//${host}/${share_name}"

    log_info "Testing mount..."
    if mount -t cifs -o "$opts" "$share" "$mount_point"; then
        log_success "Mounted at $mount_point"
    else
        log_error "Mount failed for [$share_name] — check the username/password and that the home box's share actually allows this account."
        rmdir "$mount_point" 2>/dev/null || true
        rm -f "$creds_file"
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

# ── Parse a selection like "1", "1,3", "1-3", "1 3 5" into 1-based indices ──
# Prints one index per line. Silently drops anything that doesn't look like
# a number or a range — the caller validates indices against the actual
# list length.
_vdm_parse_selection() {
    local input="$1" token start end i
    for token in $(echo "$input" | tr ',' ' '); do
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
            for ((i = start; i <= end; i++)); do echo "$i"; done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            echo "$token"
        fi
    done
}

# ── One home box, one or more shares from it ────────────────────────────────
_vdm_add_mount() {
    echo ""
    local HOST_INPUT="" HOST="" SSH_USER=""
    prompt_text "  Home box's NetBird IP or an already-named host (check 'netbird status' on that box):" "" HOST_INPUT
    if [ -z "$HOST_INPUT" ]; then
        log_warning "No host entered — cancelling."
        return 1
    fi
    _vdm_resolve_host "$HOST_INPUT"
    HOST="$RESOLVED_HOST"

    prompt_text "  SSH username on the home box:" "$ACTUAL_USER" SSH_USER

    _vdm_ensure_ssh_trust "$SSH_USER" "$HOST" || return 1

    # Pure convenience on top of the /etc/hosts naming above (which is what
    # actually makes the mount itself usable by name) — an SSH Host alias
    # additionally skips typing the username for interactive `ssh` use.
    if [[ ! "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        && declare -F add_ssh_host_alias >/dev/null 2>&1 \
        && declare -F ssh_host_alias_exists >/dev/null 2>&1 \
        && ! ssh_host_alias_exists "$HOST"; then
        local ADD_ALIAS=""
        prompt_yn "  Also add '$HOST' as an SSH alias (ssh $HOST, no username needed)? (y/n):" "y" ADD_ALIAS
        [[ "$ADD_ALIAS" =~ ^[Yy]$ ]] && add_ssh_host_alias "$HOST" "$HOST_INPUT" "$SSH_USER" "22"
    fi

    log_info "Reading Samba shares already configured on $HOST (read-only)..."
    local shares_raw
    shares_raw="$(_vdm_list_remote_shares "$SSH_USER" "$HOST")"
    if [ -z "$shares_raw" ]; then
        log_warning "No Samba shares found on $HOST (or /etc/samba/smb.conf couldn't be read). Set up a share there first, the normal way, then re-run this."
        return 1
    fi

    local share_names=() share_paths=()
    while IFS='|' read -r sname spath; do
        [ -z "$sname" ] && continue
        share_names+=("$sname")
        share_paths+=("$spath")
    done <<< "$shares_raw"

    echo ""
    echo "  Samba shares found on $HOST:"
    local i
    for i in "${!share_names[@]}"; do
        printf "    %d) %-20s %s\n" "$((i + 1))" "${share_names[$i]}" "${share_paths[$i]}"
    done
    echo ""
    local SELECTION=""
    prompt_text "  Which one(s)? e.g. '1' or '1,3' or '1-3' or '1 3 5':" "" SELECTION
    if [ -z "$SELECTION" ]; then
        log_warning "Nothing selected — cancelling."
        return 1
    fi

    local indices=()
    while IFS= read -r i; do indices+=("$i"); done < <(_vdm_parse_selection "$SELECTION")
    if [ "${#indices[@]}" -eq 0 ]; then
        log_warning "Couldn't parse a selection from '$SELECTION' — cancelling."
        return 1
    fi

    # Credentials asked once, reused for every share picked here — the
    # common case is one personal account with access to several shares.
    # Re-run this for a share needing a different account.
    local SMB_USER=""
    prompt_text "  Samba username to connect with:" "$SSH_USER" SMB_USER
    local SMB_PASS=""
    SMB_PASS="$(_vdm_find_existing_smb_password "$HOST" "$SMB_USER")"
    if [ -n "$SMB_PASS" ]; then
        log_info "Reusing the Samba password already saved for '$SMB_USER' on $HOST from an earlier mount."
    else
        SMB_PASS="$(_vdm_prompt_password "Samba password for '$SMB_USER'")"
    fi

    local picked_any=false idx arr_i this_share this_path LABEL MOUNT_POINT
    for idx in "${indices[@]}"; do
        arr_i=$((idx - 1))
        if [ "$arr_i" -lt 0 ] || [ "$arr_i" -ge "${#share_names[@]}" ]; then
            log_warning "$idx isn't one of the listed shares — skipping."
            continue
        fi
        this_share="${share_names[$arr_i]}"
        this_path="${share_paths[$arr_i]}"

        echo ""
        log_info "Setting up: [$this_share] -> $this_path"

        LABEL=""
        while true; do
            prompt_text "  Local label for this mount:" "$this_share" LABEL
            LABEL="$(echo "$LABEL" | tr -cs 'a-zA-Z0-9-' '-' | sed 's/^-*//;s/-*$//')"
            if [ -z "$LABEL" ]; then
                log_warning "Label can't be empty."; continue
            fi
            if grep -q "^${_VDM_TAG_PREFIX} ${LABEL} " /etc/fstab 2>/dev/null; then
                log_warning "Label '$LABEL' is already used — pick another."; continue
            fi
            break
        done

        MOUNT_POINT=""
        prompt_text "  Local mount point:" "/mnt/${LABEL}" MOUNT_POINT

        if _vdm_mount_local "$HOST" "$this_share" "$MOUNT_POINT" "$LABEL" "$SMB_USER" "$SMB_PASS"; then
            # Read by callers like services/filebrowser.sh/audiobookshelf.sh/
            # emby.sh that chain into this service and want to default
            # their own "which directory" prompt to whatever was just
            # mounted. Last one wins if several were picked in this run.
            VDM_LAST_MOUNT_POINT="$MOUNT_POINT"
            picked_any=true
        fi
    done

    if [ "$picked_any" = true ]; then
        echo ""
        log_success "Done."
        echo "  Manage this and other network mounts anytime with:"
        echo "    sudo bash tools/mount-network-drive.sh"
    fi
}

install_vpn-data-mount() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  VPN Data Mount — mount existing SMB shares from a home   ║"
    echo "║  box over NetBird (read-only — nothing changes there)     ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would offer to name a raw IP in /etc/hosts for reuse (SSH + this mount)"
        echo "[DRY-RUN] Would test/set up passwordless SSH to a home box over its NetBird IP"
        echo "[DRY-RUN] Would read-only list the home box's existing Samba shares (never writes there)"
        echo "[DRY-RUN] Would let you pick one or more by number and mount them locally over CIFS"
        echo "[DRY-RUN] Would add each to /etc/fstab with a root-only credentials file (not guest)"
        echo "[DRY-RUN] Repeatable — can be run again for additional home boxes"
        return 0
    fi

    # Every prompt below (home box IP, share selection, ...) has no sane
    # unattended default — unlike most services here, there's no reasonable
    # value to fall back to. Skip outright rather than let prompt_text's
    # always-blank UNATTENDED behavior spin something forever.
    if [ "$UNATTENDED" = true ]; then
        log_info "Skipping — needs interactive input (home box IP, share selection, ...). Run 'sudo ./setup.sh vpn-data-mount' without --unattended."
        return 0
    fi

    _vdm_list_existing

    while true; do
        local ADD=""
        prompt_yn "Connect to a home box and mount some of its shares now? (y/n):" "y" ADD
        [[ "$ADD" =~ ^[Yy]$ ]] || break

        _vdm_add_mount

        local AGAIN=""
        prompt_yn "Connect to another (different) home box? (y/n):" "n" AGAIN
        [[ "$AGAIN" =~ ^[Yy]$ ]] || break
    done
}

[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_vpn-data-mount
