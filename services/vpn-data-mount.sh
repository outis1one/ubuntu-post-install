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
# Each share gets a dedicated Samba account (same username as the SSH user,
# since that Unix account already exists on the home box — no extra remote
# user to create) with its own generated password, stored locally in a
# root-only credentials file, same convention tools/mount-network-drive.sh
# already uses. An earlier version of this made the share guest-accessible
# instead, reasoning the VPN itself was enough access control — reversed
# per direct request (real per-share accounts, not root/guest) and because
# it incidentally fixes a real bug: plain `guest` CIFS mounts with no
# explicit `sec=` can hit "mount error(79): Can not access a needed shared
# library" — a misleadingly-worded cifs-utils message for errno 79
# (ENOKEY), a known rough edge in the kernel cifs.ko keyring/upcall path
# for anonymous sessions specifically, not an actual missing library.
# Credentialed mounts with an explicit sec= take the normal NTLMSSP auth
# path instead and don't hit it.

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

# ── Name a raw IP so it can be used everywhere instead of typing it again ──
# Deliberately /etc/hosts, not ~/.ssh/config: an SSH Host alias only helps
# the `ssh` command itself resolve a name — mount.cifs (and everything
# else) never consults ~/.ssh/config at all, so an alias alone wouldn't let
# the actual CIFS mount address use a name. /etc/hosts is the one mechanism
# that makes a name resolve for both, which is what "use a name instead of
# the IP" actually needs end to end.
# Sets RESOLVED_HOST (not local — same out-param convention as elsewhere).
_vdm_resolve_host() {
    local input="$1" default_name="$2"
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

    # prompt_text always falls back to the given default on blank input
    # (same convention every other prompt in this repo relies on) — so this
    # always ends up naming the host to something, never truly "blank" for
    # "keep using the IP". That's fine: $default_name is already a sensible
    # suggestion (the mount's own label), so Enter alone gives a reasonable
    # name rather than requiring the extra step of confirming one.
    local NAME=""
    prompt_text "  Name for this home box (used instead of the IP from now on):" "$default_name" NAME
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

# ── Detect an existing share exporting this exact path already ────────────
# Prints the share name (bare, no brackets) if found, nothing otherwise.
# No log_* calls in here — this runs inside a caller's $(...) capture, and
# log_info/log_warning/etc. all write to stdout, which would corrupt it.
_vdm_find_remote_share() {
    local user="$1" host="$2" remote_path="$3"
    local awk_prog='
        /^\[/ { cur = $0; gsub(/[][]/, "", cur) }
        /^[[:space:]]*path[[:space:]]*=/ {
            val = $0
            sub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*/, "", val)
            gsub(/[[:space:]]+$/, "", val)
            if (val == target) { print cur; exit }
        }
    '
    sudo -u "$ACTUAL_USER" ssh "${user}@${host}" \
        "awk -v target='${remote_path}' '${awk_prog}' /etc/samba/smb.conf 2>/dev/null"
}

# ── Reuse a password this tool already set for the same user+host ─────────
# A Samba account's password is shared across every share it can access —
# resetting it for a second mount from the same home box would silently
# break the first mount's already-saved credentials file. Prints the
# password if a prior mount from this host used the same Samba username,
# nothing otherwise. No log_* calls — same reason as above.
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

# ── Remote Samba setup, driven entirely over the SSH trust above ──────────
# Sets SMB_PASS/SMB_USER/SMB_SHARE_NAME (not local — read by the caller),
# same out-param convention as lib/common.sh's
# ensure_coturn_user/configure_caddy_for_service.
_vdm_setup_remote_samba() {
    local user="$1" host="$2" remote_path="$3" share_name="$4"
    SMB_PASS="" SMB_USER="$user" SMB_SHARE_NAME="$share_name"

    log_info "Checking Samba on the home box..."
    # Every ssh call below runs as $ACTUAL_USER, same reason as _vdm_ssh_works.
    if ! sudo -u "$ACTUAL_USER" ssh "${user}@${host}" 'command -v smbd >/dev/null 2>&1'; then
        log_info "Installing Samba on the home box (may prompt for the sudo password there)..."
        sudo -u "$ACTUAL_USER" ssh -t "${user}@${host}" 'sudo apt-get update -y && sudo apt-get install -y samba' \
            || { log_error "Remote Samba install failed."; return 1; }
    else
        log_success "Samba already installed on the home box."
    fi

    # Don't blindly overwrite a share that's already exporting this exact
    # path — the home box may already have this configured by hand.
    local existing_share
    existing_share="$(_vdm_find_remote_share "$user" "$host" "$remote_path")"
    if [ -n "$existing_share" ]; then
        log_info "Found an existing Samba share '[$existing_share]' already exporting $remote_path on the home box."
        local REUSE=""
        prompt_yn "  Use it as-is instead of creating a new one? (y/n):" "y" REUSE
        if [[ "$REUSE" =~ ^[Yy]$ ]]; then
            SMB_SHARE_NAME="$existing_share"
            prompt_text "  Samba username for that share:" "$user" SMB_USER
            SMB_PASS="$(_vdm_prompt_password "Samba password for '$SMB_USER'")"
            log_success "Reusing existing share [$SMB_SHARE_NAME] — nothing changed on the home box."
            return 0
        fi
        log_info "Creating a separate new share instead."
    fi

    # Reuse this account's password if another mount from the same home
    # box already set one up (see _vdm_find_existing_smb_password), rather
    # than resetting an account that other saved credentials still depend on.
    local reset_needed=true
    SMB_PASS="$(_vdm_find_existing_smb_password "$host" "$user")"
    if [ -n "$SMB_PASS" ]; then
        log_info "Reusing the Samba password already set up for '$user' on $host (from another mount) — not resetting it."
        reset_needed=false
    elif sudo -u "$ACTUAL_USER" ssh "${user}@${host}" "sudo pdbedit -L 2>/dev/null | grep -q '^${user}:'"; then
        log_warning "Samba account '$user' already exists on the home box with a password this tool doesn't know."
        local RESET_PW=""
        prompt_yn "  Reset it to a newly generated password? (Anything already using the old one — other mounts, manual clients — will need updating.) (y/n):" "n" RESET_PW
        if [[ "$RESET_PW" =~ ^[Yy]$ ]]; then
            SMB_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"
        else
            SMB_PASS="$(_vdm_prompt_password "Existing Samba password for '$user'")"
            reset_needed=false
        fi
    else
        SMB_PASS="$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)"
    fi

    log_info "Configuring the share on the home box..."
    # Idempotent: drop any prior block for this exact share name, then
    # append a fresh one. Dedicated account (not guest) — see the file
    # header for why, and for the errno-79 connection.
    #
    # The Samba account reuses $user — that Unix account already exists on
    # the home box (it's who we're SSH'd in as), so no extra remote user
    # needs creating. When reset_needed, the new password ends up briefly
    # visible in the home box's own `ps` output for this one remote
    # command's duration (embedded in the command string, not piped —
    # piping through a `-t` pty session for a command that may also need
    # an interactive sudo password gets stdin-ordering-fragile fast).
    # Accepted tradeoff, same spirit as this whole feature already trusting
    # the VPN's reachability boundary — see file header.
    local pw_cmd=""
    if [ "$reset_needed" = true ]; then
        pw_cmd="printf '%s\n%s\n' '${SMB_PASS}' '${SMB_PASS}' | sudo smbpasswd -a -s '${user}'
sudo smbpasswd -e '${user}'"
    fi

    # Builds the new config in a scratch file and validates it with
    # testparm BEFORE it ever touches the live smb.conf — confirmed live:
    # the previous approach here (sed range-deleting from the [share_name]
    # header through the next BLANK line) silently deleted straight through
    # to end of file on a home box whose smb.conf had no blank line
    # separating sections, taking unrelated shares down with it. Section
    # removal now stops at the next `[section]` header (or EOF) instead of
    # a blank line, which is the actual boundary of an INI-style section
    # regardless of how the file happens to be formatted.
    local remote_cmd
    remote_cmd=$(cat << REMOTECMD
set -e
sudo mkdir -p '${remote_path}'
BACKUP="/etc/samba/smb.conf.backup.\$(date +%Y%m%d-%H%M%S)"
sudo cp /etc/samba/smb.conf "\$BACKUP"
sudo awk -v target='[${share_name}]' '
  /^\\[/ { skip = (\$0 == target) }
  !skip { print }
' /etc/samba/smb.conf > /tmp/smb.conf.vdm.new
{
  echo ""
  echo "[${share_name}]"
  echo "   path = ${remote_path}"
  echo "   browseable = yes"
  echo "   read only = no"
  echo "   guest ok = no"
  echo "   valid users = ${user}"
  echo "   force user = ${user}"
} >> /tmp/smb.conf.vdm.new
if sudo testparm -s /tmp/smb.conf.vdm.new >/dev/null 2>&1; then
  sudo cp /tmp/smb.conf.vdm.new /etc/samba/smb.conf
  rm -f /tmp/smb.conf.vdm.new
else
  echo "New smb.conf failed testparm validation — leaving the existing config untouched. Backup at \$BACKUP, rejected draft at /tmp/smb.conf.vdm.new for inspection." >&2
  exit 1
fi
${pw_cmd}
sudo systemctl restart smbd
command -v ufw >/dev/null 2>&1 && sudo ufw allow samba >/dev/null 2>&1 || true
REMOTECMD
)
    if sudo -u "$ACTUAL_USER" ssh -t "${user}@${host}" "$remote_cmd"; then
        log_success "Remote share [$share_name] -> $remote_path configured, smbd restarted."
    else
        log_error "Remote Samba configuration failed — check the output above."
        return 1
    fi
}

# ── Local mount + fstab ─────────────────────────────────────────────────────
_vdm_mount_local() {
    local host="$1" share_name="$2" mount_point="$3" label="$4" smb_user="$5" smb_pass="$6"

    command -v mount.cifs >/dev/null 2>&1 || apt-get install -y cifs-utils -qq

    mkdir -p "$mount_point"

    # Credentials file, not a guest/inline password — root-only, matching
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
    # Modern default and what a credentialed mount should use anyway.
    local opts="credentials=${creds_file},sec=ntlmssp,uid=$(id -u "$ACTUAL_USER"),gid=$(id -g "$ACTUAL_USER"),iocharset=utf8,nofail,_netdev"
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

    local HOST_INPUT="" HOST="" SSH_USER=""
    prompt_text "  Home box's NetBird IP or an already-named host (check 'netbird status' on that box):" "" HOST_INPUT
    if [ -z "$HOST_INPUT" ]; then
        log_warning "No host entered — cancelling this mount."
        return 1
    fi
    _vdm_resolve_host "$HOST_INPUT" "$LABEL"
    HOST="$RESOLVED_HOST"

    prompt_text "  SSH username on the home box:" "$ACTUAL_USER" SSH_USER

    _vdm_ensure_ssh_trust "$SSH_USER" "$HOST" || return 1

    # Pure convenience on top of the /etc/hosts naming above (which is what
    # actually makes the mount itself usable by name) — an SSH Host alias
    # additionally skips typing the username for interactive `ssh` use.
    # Only offered for a genuinely new name, not every time this mount (or
    # another one on the same host) is set up.
    if [[ ! "$HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        && declare -F add_ssh_host_alias >/dev/null 2>&1 \
        && declare -F ssh_host_alias_exists >/dev/null 2>&1 \
        && ! ssh_host_alias_exists "$HOST"; then
        local ADD_ALIAS=""
        prompt_yn "  Also add '$HOST' as an SSH alias (ssh $HOST, no username needed)? (y/n):" "y" ADD_ALIAS
        [[ "$ADD_ALIAS" =~ ^[Yy]$ ]] && add_ssh_host_alias "$HOST" "$HOST_INPUT" "$SSH_USER" "22"
    fi

    local REMOTE_PATH="" MOUNT_POINT=""
    prompt_text "  Path on the home box to share (e.g. /home/${SSH_USER}/media):" "" REMOTE_PATH
    if [ -z "$REMOTE_PATH" ]; then
        log_warning "No path entered — cancelling this mount."
        return 1
    fi
    prompt_text "  Local mount point:" "/mnt/${LABEL}" MOUNT_POINT

    # SMB_USER/SMB_SHARE_NAME may differ from SSH_USER/LABEL if an existing
    # remote share for this exact path was found and reused as-is.
    _vdm_setup_remote_samba "$SSH_USER" "$HOST" "$REMOTE_PATH" "$LABEL" || return 1
    _vdm_mount_local "$HOST" "$SMB_SHARE_NAME" "$MOUNT_POINT" "$LABEL" "$SMB_USER" "$SMB_PASS" || return 1

    # Read by callers like services/filebrowser.sh/audiobookshelf.sh/emby.sh
    # that chain into this service and want to default their own "which
    # directory" prompt to whatever was just mounted, without needing to
    # know or guess the path themselves.
    VDM_LAST_MOUNT_POINT="$MOUNT_POINT"

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
        echo "[DRY-RUN] Would offer to name a raw IP in /etc/hosts for reuse (SSH + this mount)"
        echo "[DRY-RUN] Would test/set up passwordless SSH to a home box over its NetBird IP"
        echo "[DRY-RUN] Would check for an existing Samba share/account first and offer to reuse it, not overwrite it"
        echo "[DRY-RUN] Otherwise would remotely install Samba + configure a new share and dedicated account"
        echo "[DRY-RUN] Would mount it locally over CIFS (credentials file, not guest) and add it to /etc/fstab"
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
