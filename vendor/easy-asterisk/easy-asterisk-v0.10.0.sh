#!/bin/bash
# ================================================================
# Easy Asterisk - Interactive Installer v0.10.0
#
# Copyright (C) 2025 Easy Asterisk Contributors
# Licensed under GNU General Public License v3.0
# See LICENSE file or https://www.gnu.org/licenses/gpl-3.0.html
#
# UPDATES in v0.10.0:
# - FIXED: Extension deletion now properly removes all sections (endpoint, auth, aor)
# - FIXED: Extension renaming now preserves AA tags correctly
# - FIXED: LAN/VPN devices now explicitly use UDP transport (prevents TLS fallback)
# - FIXED: LAN devices now have media_encryption=no to prevent SRTP issues
# - FIXED: VPN subnets now included as local_net in LAN mode (fixes VPN mobile offline)
# - FIXED: One-way audio on WiFi-to-mobile-data handoff (rtp_keepalive + timers)
# - ADDED: Web Admin interface for browser-based client management
#   - View device status (online/offline) in real-time
#   - Add/delete devices via web interface
#   - View rooms and categories
#   - HTTP Basic authentication with SHA256 password hashing
#   - Access at http://server:8080/clients
# - ADDED: VPN subnet auto-detection (Tailscale, WireGuard, OpenVPN)
# - ADDED: VPN STUN/ICE configuration for third-party VPNs
#   - Self-hosted coturn STUN (no external DNS dependencies)
#   - Custom STUN server support
#   - Per-device ICE for LAN/VPN mode endpoints
# - ADDED: Docker container support (Dockerfile + docker-compose)
# - ADDED: VPN diagnostics tool (vpn-diagnostics)
# - ADDED: DNS whitelist checker for filtered networks (dns-whitelist)
# - IMPROVED: Device deletion uses awk for reliable multi-section removal
# - IMPROVED: Device renaming uses awk to handle all edge cases
#
# PREVIOUS UPDATES (v0.9.9):
# - REMOVED: All COTURN/TURN relay server code (focus on direct connections)
# - ADDED: VLAN subnet configuration to prevent 30-second call drops
# - ADDED: Provisioning Manager (http.conf setup, symlinks, linphone.xml editor)
# - ADDED: Manual Update System for Asterisk with backup/rollback
# - ADDED: Room Directory (visual display of Ring Groups vs Page Groups)
# - ADDED: Split-horizon DNS documentation for VLAN environments
# - IMPROVED: Server IP address documented in transport configurations
# - IMPROVED: Multiple local_net entries for proper VLAN support
# ================================================================

set +e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Defaults
DEFAULT_SIP_PORT="5060"
DEFAULT_SIPS_PORT="5061"
CONFIG_DIR="/etc/easy-asterisk"
CONFIG_FILE="${CONFIG_DIR}/config"
PTT_CONFIG_FILE="${CONFIG_DIR}/ptt-device"
CATEGORIES_FILE="${CONFIG_DIR}/categories.conf"
ROOMS_FILE="${CONFIG_DIR}/rooms.conf"
PROVISIONING_DIR="/var/lib/asterisk/static-http"
SCRIPT_VERSION="0.10.0"

# ================================================================
# 1. CORE HELPER FUNCTIONS
# ================================================================

print_header() {
    echo -e "\n${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"
}

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_success() { echo -e "${GREEN}[OK]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# ── Docker / Container Detection ─────────────────────────────
# Returns 0 (true) if running inside a Docker/container environment

is_docker() {
    [[ -f /.dockerenv ]] || grep -qsE "docker|containerd|lxc" /proc/1/cgroup 2>/dev/null
}

# Check if Asterisk process is running (works in both Docker and bare metal)
asterisk_running() {
    if is_docker; then
        pgrep -x asterisk >/dev/null 2>&1
    else
        systemctl is-active asterisk >/dev/null 2>&1
    fi
}

# Start/restart Asterisk (Docker-aware)
restart_asterisk_safe() {
    print_info "Restarting Asterisk..."
    if is_docker; then
        # In Docker: use Asterisk CLI to restart, or restart the process
        if pgrep -x asterisk >/dev/null 2>&1; then
            asterisk -rx "core restart now" 2>/dev/null || true
            sleep 3
        fi
        # If not running, start it in the background
        if ! pgrep -x asterisk >/dev/null 2>&1; then
            rm -f /var/run/asterisk/asterisk.pid 2>/dev/null || true
            asterisk -U asterisk -G asterisk &
            sleep 3
        fi
        if pgrep -x asterisk >/dev/null 2>&1; then
            print_success "Asterisk running"
        else
            print_error "Asterisk failed to start"
        fi
    else
        systemctl stop asterisk 2>/dev/null || true
        sleep 2
        pkill -9 -x asterisk 2>/dev/null || true
        rm -f /var/run/asterisk/asterisk.pid 2>/dev/null || true
        rm -f /var/lib/asterisk/.asterisk_history 2>/dev/null || true
        systemctl start asterisk
        sleep 3
        if systemctl is-active asterisk >/dev/null; then
            print_success "Asterisk running"
        else
            print_error "Asterisk failed to start"
            journalctl -u asterisk -n 15 --no-pager
        fi
    fi
}

# Web admin process management (Docker-aware)
webadmin_running() {
    pgrep -f "easy-asterisk-webadmin" >/dev/null 2>&1
}

start_webadmin() {
    load_config
    if webadmin_running; then
        print_warn "Web admin already running"
        return
    fi
    create_web_admin_script
    if [[ ! -f "$WEB_ADMIN_HTPASSWD" ]] && [[ "${WEB_ADMIN_AUTH_DISABLED:-}" != "true" ]]; then
        setup_web_admin_auth
    fi
    WEBADMIN_PORT="${WEB_ADMIN_PORT:-8080}" \
    WEBADMIN_AUTH_DISABLED="${WEB_ADMIN_AUTH_DISABLED:-false}" \
    nohup python3 "$WEB_ADMIN_SCRIPT" >/dev/null 2>&1 &
    sleep 2
    if webadmin_running; then
        print_success "Web Admin started on port ${WEB_ADMIN_PORT}"
    else
        print_error "Web Admin failed to start"
    fi
}

stop_webadmin() {
    if webadmin_running; then
        pkill -f "easy-asterisk-webadmin" 2>/dev/null || true
        sleep 1
        # Force kill if still running
        if webadmin_running; then
            pkill -9 -f "easy-asterisk-webadmin" 2>/dev/null || true
            sleep 1
        fi
    fi
    # Also kill anything on the port
    local port_pids=$(lsof -ti ":${WEB_ADMIN_PORT}" 2>/dev/null)
    if [[ -n "$port_pids" ]]; then
        echo "$port_pids" | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
    if ! webadmin_running; then
        print_success "Web Admin stopped"
    else
        print_error "Web Admin could not be stopped"
    fi
}

restart_webadmin() {
    stop_webadmin 2>/dev/null
    start_webadmin
}

generate_password() {
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16
}

select_user() {
    # Scan /home for real users (exclude system accounts)
    local -a users=()
    local -a user_ids=()
    local count=0

    echo "Scanning for users..."
    echo ""

    # Get users from /home with valid shells
    while IFS=: read -r username _ uid _ _ homedir shell; do
        # Only include users with UID >= 1000 and valid shell
        if [[ $uid -ge 1000 && -d "$homedir" && "$shell" != "/usr/sbin/nologin" && "$shell" != "/bin/false" ]]; then
            ((count++))
            users+=("$username")
            user_ids+=("$uid")
            echo "  ${count}) ${username} (UID: ${uid}, Home: ${homedir})"
        fi
    done < /etc/passwd

    # Add option to manually enter username
    ((count++))
    echo "  ${count}) Enter username manually"
    echo ""

    # Suggest default based on SUDO_USER or first user found
    local default_choice=""
    local default_user="${SUDO_USER:-}"
    if [[ -z "$default_user" ]]; then
        default_user="${users[0]:-}"
        default_choice="1"
    else
        # Find index of SUDO_USER
        for i in "${!users[@]}"; do
            if [[ "${users[$i]}" == "$default_user" ]]; then
                default_choice=$((i + 1))
                break
            fi
        done
    fi

    if [[ -n "$default_choice" ]]; then
        read -p "Select user [${default_choice}]: " choice
        choice="${choice:-$default_choice}"
    else
        read -p "Select user: " choice
    fi

    # Validate choice
    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -le "${#users[@]}" && "$choice" -gt 0 ]]; then
        local idx=$((choice - 1))
        KIOSK_USER="${users[$idx]}"
        KIOSK_UID="${user_ids[$idx]}"
        echo ""
        print_success "Selected user: $KIOSK_USER (UID: $KIOSK_UID)"
        return 0
    elif [[ "$choice" == "$count" ]]; then
        # Manual entry
        echo ""
        read -p "Enter username: " KIOSK_USER
        if id "$KIOSK_USER" >/dev/null 2>&1; then
            KIOSK_UID=$(id -u "$KIOSK_USER")
            print_success "Selected user: $KIOSK_USER (UID: $KIOSK_UID)"
            return 0
        else
            print_error "User '$KIOSK_USER' not found"
            return 1
        fi
    else
        print_error "Invalid selection"
        return 1
    fi
}

load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE" 2>/dev/null || true
    fi
    INSTALLED_SERVER="${INSTALLED_SERVER:-n}"
    INSTALLED_CLIENT="${INSTALLED_CLIENT:-n}"
    KIOSK_USER="${KIOSK_USER:-}"
    KIOSK_UID="${KIOSK_UID:-}"
    HAS_VLANS="${HAS_VLANS:-n}"
    VLAN_SUBNETS="${VLAN_SUBNETS:-}"
    WEB_ADMIN_PORT="${WEB_ADMIN_PORT:-8080}"
    WEB_ADMIN_AUTH_DISABLED="${WEB_ADMIN_AUTH_DISABLED:-false}"
    VPN_ICE_ENABLED="${VPN_ICE_ENABLED:-n}"
    CUSTOM_STUN_SERVER="${CUSTOM_STUN_SERVER:-}"
    TURN_ENABLED="${TURN_ENABLED:-n}"
    TURN_SERVER="${TURN_SERVER:-}"
    TURN_USERNAME="${TURN_USERNAME:-}"
    TURN_PASSWORD="${TURN_PASSWORD:-}"
    return 0
}

backup_config() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.backup-$(date +%s)"
        ls -tp "${file}.backup-"* 2>/dev/null | tail -n +6 | xargs -I {} rm -- {} 2>/dev/null
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 755 "$CONFIG_DIR"

    cat > "$CONFIG_FILE" << EOF
# Easy Asterisk Configuration - $(date)
KIOSK_USER="$KIOSK_USER"
KIOSK_UID="$KIOSK_UID"
KIOSK_EXTENSION="$KIOSK_EXTENSION"
KIOSK_NAME="$KIOSK_NAME"
SIP_PASSWORD="$SIP_PASSWORD"
ASTERISK_HOST="$ASTERISK_HOST"
DOMAIN_NAME="$DOMAIN_NAME"
ENABLE_TLS="$ENABLE_TLS"
HAS_VLANS="$HAS_VLANS"
VLAN_SUBNETS="$VLAN_SUBNETS"
CERT_PATH="$CERT_PATH"
KEY_PATH="$KEY_PATH"
INSTALLED_SERVER="$INSTALLED_SERVER"
INSTALLED_CLIENT="$INSTALLED_CLIENT"
CURRENT_PUBLIC_IP="$CURRENT_PUBLIC_IP"
PTT_DEVICE="$PTT_DEVICE"
PTT_KEYCODE="$PTT_KEYCODE"
LOCAL_CIDR="$LOCAL_CIDR"
WEB_ADMIN_PORT="$WEB_ADMIN_PORT"
WEB_ADMIN_AUTH_DISABLED="$WEB_ADMIN_AUTH_DISABLED"
VPN_ICE_ENABLED="$VPN_ICE_ENABLED"
CUSTOM_STUN_SERVER="$CUSTOM_STUN_SERVER"
TURN_ENABLED="$TURN_ENABLED"
TURN_SERVER="$TURN_SERVER"
TURN_USERNAME="$TURN_USERNAME"
TURN_PASSWORD="$TURN_PASSWORD"
EOF
    chmod 644 "$CONFIG_FILE"

    # Save PTT config separately
    if [[ -n "$PTT_DEVICE" ]]; then
        cat > "$PTT_CONFIG_FILE" << EOF
PTT_DEVICE="$PTT_DEVICE"
PTT_KEYCODE="$PTT_KEYCODE"
EOF
        chmod 644 "$PTT_CONFIG_FILE"
    fi
}

open_firewall_ports() {
    if is_docker; then
        # In Docker, firewall is managed on the host, not inside the container
        # With network_mode: host, all ports are directly accessible
        print_info "Docker mode: firewall is managed on the host"
        return
    fi
    print_info "Configuring firewall ports..."
    if command -v ufw &>/dev/null; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then
            ufw allow 5060/udp comment "SIP UDP" 2>/dev/null || true
            ufw allow 5061/tcp comment "SIP TLS" 2>/dev/null || true
            ufw allow 10000:20000/udp comment "RTP Media" 2>/dev/null || true
            ufw allow 8088/tcp comment "HTTP Provisioning" 2>/dev/null || true
            ufw allow 8089/tcp comment "HTTPS Provisioning" 2>/dev/null || true
            ufw reload 2>/dev/null || true
            print_success "UFW firewall ports opened"
        fi
    fi
}

# ================================================================
# 2. UTILITY FUNCTIONS
# ================================================================

get_public_ip() {
    local ip=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || curl -s -4 --connect-timeout 5 icanhazip.com 2>/dev/null || echo "")
    echo "$ip"
}

# ================================================================
# 3. DEVICE MANAGEMENT
# ================================================================

initialize_default_categories() {
    mkdir -p "$CONFIG_DIR"
    if [[ ! -f "$CATEGORIES_FILE" ]]; then
        cat > "$CATEGORIES_FILE" << 'EOF'
# Format: id|name|auto_answer(yes/no)|description
kiosk|Kiosks|yes|Fixed auto-answer intercoms
mobile|Mobile Devices|no|Phones and mobile devices
EOF
        chmod 600 "$CATEGORIES_FILE"
    fi
    if [[ ! -f "$ROOMS_FILE" ]]; then
        cat > "$ROOMS_FILE" << 'EOF'
# Format: ext|name|members|timeout|type(ring/page)
199|All Kiosks|101,102,103,104,105|60|page
299|All Mobile|201,202,203,204,205|60|ring
EOF
        chmod 600 "$ROOMS_FILE"
    fi
}

list_categories() {
    initialize_default_categories
    local index=1
    while IFS='|' read -r cat_id cat_name auto_answer description; do
        [[ "$cat_id" =~ ^# ]] && continue
        [[ -z "$cat_id" ]] && continue
        local auto_text="${RED}Ring${NC}"
        [[ "$auto_answer" == "yes" ]] && auto_text="${GREEN}Auto-answer${NC}"
        echo -e "  ${CYAN}$index)${NC} ${BOLD}$cat_name${NC} ($cat_id) - $auto_text"
        ((index++))
    done < "$CATEGORIES_FILE"
}

get_category_by_index() {
    local target_index=$1
    local index=1
    while IFS='|' read -r cat_id cat_name auto_answer description; do
        [[ "$cat_id" =~ ^# ]] && continue
        [[ -z "$cat_id" ]] && continue
        if [[ $index -eq $target_index ]]; then
            echo "$cat_id|$cat_name|$auto_answer"
            return 0
        fi
        ((index++))
    done < "$CATEGORIES_FILE"
}

manage_categories() {
    print_header "Manage Categories"
    list_categories
    echo ""
    echo "  1) Add Category"
    echo "  2) Rename Category"
    echo "  3) Delete Category"
    echo "  0) Back"
    read -p "Select: " choice
    case $choice in
        1)
            read -p "ID (lowercase): " cid
            read -p "Display Name: " cname
            read -p "Auto Answer? [y/N]: " ca
            local ans="no"
            [[ "$ca" =~ ^[Yy]$ ]] && ans="yes"
            echo "${cid}|${cname}|${ans}|Custom category" >> "$CATEGORIES_FILE"
            print_success "Category added"
            rebuild_dialplan
            ;;
        2)
            read -p "Number to rename: " num
            local data=$(get_category_by_index "$num")
            if [[ -z "$data" ]]; then
                print_error "Invalid selection"
                return
            fi
            local old_id=$(echo "$data" | cut -d'|' -f1)
            local old_name=$(echo "$data" | cut -d'|' -f2)
            local auto_answer=$(echo "$data" | cut -d'|' -f3)
            
            echo "Current: $old_name (ID: $old_id)"
            read -p "New display name: " new_name
            
            if [[ -z "$new_name" ]]; then
                print_error "Name cannot be empty"
                return
            fi
            
            # Backup
            backup_config "$CATEGORIES_FILE"
            
            # Update category file
            sed -i "s/^${old_id}|${old_name}|/${old_id}|${new_name}|/" "$CATEGORIES_FILE"
            
            print_success "Category renamed: ${old_name} → ${new_name}"
            rebuild_dialplan
            ;;
        3)
            read -p "Number to delete: " num
            local data=$(get_category_by_index "$num")
            if [[ -z "$data" ]]; then
                print_error "Invalid selection"
                return
            fi
            local cid=$(echo "$data" | cut -d'|' -f1)
            local cname=$(echo "$data" | cut -d'|' -f2)
            
            # Count devices in this category
            local device_count=$(grep -c "; === Device:.* (${cid})" /etc/asterisk/pjsip.conf 2>/dev/null || echo "0")
            
            if [[ $device_count -gt 0 ]]; then
                echo ""
                echo -e "${YELLOW}Warning: This category has ${device_count} device(s)${NC}"
                echo ""
                echo "  1) Delete category only (reassign devices to 'uncategorized')"
                echo "  2) Delete category AND all devices in it"
                echo "  0) Cancel"
                read -p "Select: " del_choice
                
                case $del_choice in
                    1)
                        # Ensure uncategorized category exists
                        if ! grep -q "^uncategorized|" "$CATEGORIES_FILE" 2>/dev/null; then
                            echo "uncategorized|Uncategorized|no|Default category for orphaned devices" >> "$CATEGORIES_FILE"
                        fi
                        
                        # Reassign all devices to uncategorized
                        backup_config "/etc/asterisk/pjsip.conf"
                        sed -i "s/; === Device: \(.*\) (${cid})/; === Device: \1 (uncategorized)/" /etc/asterisk/pjsip.conf
                        
                        # Delete the category
                        sed -i "/^${cid}|/d" "$CATEGORIES_FILE"
                        
                        print_success "Category deleted, ${device_count} device(s) moved to 'uncategorized'"
                        rebuild_dialplan
                        ;;
                    2)
                        echo ""
                        echo -e "${RED}WARNING: This will DELETE ${device_count} device(s)!${NC}"
                        read -p "Type 'DELETE ALL' to confirm: " confirm
                        
                        if [[ "$confirm" == "DELETE ALL" ]]; then
                            backup_config "/etc/asterisk/pjsip.conf"
                            
                            # Get all extensions in this category
                            local exts_to_delete=""
                            local in_device=0
                            local current_ext=""
                            local current_cat=""
                            
                            while IFS= read -r line; do
                                if [[ "$line" == *"; === Device:"* ]]; then
                                    local temp="${line#*; === Device: }"
                                    temp="${temp% ===}"
                                    [[ "$temp" == *"[AA:"* ]] && temp="${temp% \[AA:*\]}"
                                    current_cat="${temp##* (}"; current_cat="${current_cat%)}"
                                fi
                                if [[ "$line" =~ ^\[([0-9]+)\] ]]; then
                                    current_ext="${BASH_REMATCH[1]}"
                                    if [[ "$current_cat" == "$cid" ]]; then
                                        exts_to_delete="${exts_to_delete} ${current_ext}"
                                    fi
                                fi
                            done < /etc/asterisk/pjsip.conf
                            
                            # Delete all device sections for this category
                            for ext in $exts_to_delete; do
                                sed -i "/^; === Device:.*${ext}.* (${cid})/,/^$/d" /etc/asterisk/pjsip.conf
                                sed -i "/^\[${ext}\]/,/^$/d" /etc/asterisk/pjsip.conf
                            done
                            
                            # Delete the category
                            sed -i "/^${cid}|/d" "$CATEGORIES_FILE"
                            
                            asterisk -rx "pjsip reload" 2>/dev/null
                            rebuild_dialplan
                            print_success "Category and ${device_count} device(s) deleted"
                        else
                            print_error "Cancelled"
                        fi
                        ;;
                    0)
                        print_error "Cancelled"
                        return
                        ;;
                esac
            else
                # No devices, just delete the category
                sed -i "/^${cid}|/d" "$CATEGORIES_FILE"
                print_success "Category deleted (no devices affected)"
                rebuild_dialplan
            fi
            ;;
    esac
}


manage_rooms() {
    print_header "Manage Rooms"
    initialize_default_categories
    echo "Current Rooms:"
    local index=1
    while IFS='|' read -r rext rname rmem rtime rtype; do
        [[ "$rext" =~ ^# ]] && continue
        [[ -z "$rext" ]] && continue
        local type_text="Ring Group"
        [[ "$rtype" == "page" ]] && type_text="${GREEN}PAGE/INTERCOM${NC}"
        echo -e "  ${CYAN}$index)${NC} ${BOLD}$rname${NC} ($rext) - $type_text"
        echo -e "      Members: $rmem"
        ((index++))
    done < "$ROOMS_FILE"
    echo ""
    echo "  1) Add Room"
    echo "  2) Rename Room"
    echo "  3) Edit Room Members"
    echo "  4) Delete Room"
    echo "  0) Back"
    read -p "Select: " choice
    case $choice in
        1)
            read -p "Room Extension: " new_ext
            read -p "Room Name: " new_name
            echo "  1) Ring Group (Phones ring)"
            echo "  2) Page/Intercom (Auto-answer)"
            read -p "Select [1]: " type_sel
            local rtype="ring"
            [[ "$type_sel" == "2" ]] && rtype="page"
            read -p "Members (e.g. 101,102): " members
            echo "${new_ext}|${new_name}|${members}|60|${rtype}" >> "$ROOMS_FILE"
            rebuild_dialplan
            print_success "Room Created"
            ;;
        2)
            read -p "Select Room #: " rnum
            local target_line=""
            local count=0
            while IFS= read -r line; do
                if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
                    ((count++))
                    if [[ $count -eq $rnum ]]; then target_line="$line"; break; fi
                fi
            done < "$ROOMS_FILE"
            if [[ -n "$target_line" ]]; then
                IFS='|' read -r rext old_name rmem rtime rtype <<< "$target_line"
                echo "Current name: $old_name"
                read -p "New name: " new_name
                
                if [[ -z "$new_name" ]]; then
                    print_error "Name cannot be empty"
                    return
                fi
                
                backup_config "$ROOMS_FILE"
                sed -i "/^${rext}|/d" "$ROOMS_FILE"
                echo "${rext}|${new_name}|${rmem}|${rtime}|${rtype}" >> "$ROOMS_FILE"
                rebuild_dialplan
                print_success "Room renamed: ${old_name} → ${new_name}"
            else
                print_error "Invalid selection"
            fi
            ;;
        3)
            read -p "Select Room #: " rnum
            local target_line=""
            local count=0
            while IFS= read -r line; do
                if [[ ! "$line" =~ ^# ]] && [[ -n "$line" ]]; then
                    ((count++))
                    if [[ $count -eq $rnum ]]; then target_line="$line"; break; fi
                fi
            done < "$ROOMS_FILE"
            if [[ -n "$target_line" ]]; then
                IFS='|' read -r rext rname rmem rtime rtype <<< "$target_line"
                echo "Current members: $rmem"
                read -p "New members: " new_mem
                sed -i "/^${rext}|/d" "$ROOMS_FILE"
                echo "${rext}|${rname}|${new_mem}|${rtime}|${rtype}" >> "$ROOMS_FILE"
                rebuild_dialplan
                print_success "Room Updated"
            fi
            ;;
        4)
            read -p "Select Room #: " rnum
            local count=0
            local target_ext=""
            local target_name=""
            while IFS='|' read -r rext rname rrest; do
                if [[ ! "$rext" =~ ^# ]] && [[ -n "$rext" ]]; then
                    ((count++))
                    if [[ $count -eq $rnum ]]; then 
                        target_ext="$rext"
                        target_name="$rname"
                        break
                    fi
                fi
            done < "$ROOMS_FILE"
            if [[ -n "$target_ext" ]]; then
                echo ""
                echo -e "${YELLOW}Note: Deleting a room only removes the group.${NC}"
                echo -e "${YELLOW}Individual devices in this room are NOT deleted.${NC}"
                echo ""
                read -p "Delete room '${target_name}' (${target_ext})? [y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    sed -i "/^${target_ext}|/d" "$ROOMS_FILE"
                    rebuild_dialplan
                    print_success "Room deleted (devices unaffected)"
                else
                    print_error "Cancelled"
                fi
            fi
            ;;
    esac
}

add_device_menu() {
    print_header "Add Device"
    load_config  # Load saved configuration to check ENABLE_TLS, DOMAIN_NAME, etc.
    list_categories
    read -p "Category number: " cat_num
    local cat_data=$(get_category_by_index "$cat_num")
    if [[ -z "$cat_data" ]]; then print_error "Invalid"; return; fi
    local cat_id=$(echo "$cat_data" | cut -d'|' -f1)
    local cat_name=$(echo "$cat_data" | cut -d'|' -f2)
    local auto_answer=$(echo "$cat_data" | cut -d'|' -f3)
    
    local start_range=101 end_range=199
    case "$cat_id" in
        kiosk)   start_range=101; end_range=199 ;;
        mobile)  start_range=201; end_range=299 ;;
        *)       start_range=301; end_range=399 ;;
    esac

    local suggested_ext=""
    for ext in $(seq $start_range $end_range); do
        if ! grep -q "^\[${ext}\]" /etc/asterisk/pjsip.conf 2>/dev/null; then
            suggested_ext=$ext; break
        fi
    done
    
    read -p "Extension [$suggested_ext]: " ext
    ext="${ext:-$suggested_ext}"
    
    if grep -q "^\[${ext}\]" /etc/asterisk/pjsip.conf 2>/dev/null; then
        print_error "Extension exists!"; return
    fi
    
    read -p "Name: " name
    name="${name:-Device $ext}"
    local pass=$(generate_password)
    
    local override_tag=""
    if [[ "$auto_answer" == "no" ]]; then
        read -p "Force AUTO-ANSWER? [y/N]: " force_aa
        [[ "$force_aa" =~ ^[Yy]$ ]] && override_tag="[AA:yes]" && auto_answer="yes"
    elif [[ "$auto_answer" == "yes" ]]; then
        read -p "Force RING? [y/N]: " force_ring
        [[ "$force_ring" =~ ^[Yy]$ ]] && override_tag="[AA:no]" && auto_answer="no"
    fi

    # CONNECTION TYPE SELECTION
    local conn_type="lan"
    local transport_block=""
    local encryption_block=""
    local ice_block=""
    local display_server=""
    local display_port="5060"
    local display_transport="UDP"
    local display_encryption="None"

    # In Docker with FQDN: default to FQDN mode for all devices
    if is_docker && [[ -n "$DOMAIN_NAME" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "  HOW WILL THIS DEVICE CONNECT?"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo -e "  1) ${CYAN}FQDN (recommended)${NC} - Via ${DOMAIN_NAME} (TLS) - works from any network"
        echo -e "  2) ${GREEN}LAN only${NC} - Same local network (UDP)"
        echo ""
        read -p "  Select [1]: " conn_choice
        conn_choice="${conn_choice:-1}"

        if [[ "$conn_choice" == "2" ]]; then
            transport_block="transport=transport-udp"
            encryption_block="media_encryption=no"
            display_server="$(hostname -I | awk '{print $1}')"
            display_port="5060"
            display_transport="UDP"
            display_encryption="None"
            ice_block="ice_support=yes"
        else
            conn_type="fqdn"
            transport_block="transport=transport-tls"
            encryption_block="media_encryption=sdes"
            ice_block="ice_support=yes"
            display_server="$DOMAIN_NAME"
            display_port="5061"
            display_transport="TLS"
            display_encryption="SRTP (SDES)"
        fi
    else
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo -e "  HOW WILL THIS DEVICE CONNECT?"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo -e "  1) ${GREEN}LAN/VPN${NC} - Same network or VPN tunnel (UDP)"
        if [[ "$ENABLE_TLS" == "y" && -n "$DOMAIN_NAME" ]]; then
            echo -e "  2) ${CYAN}FQDN${NC} - Internet or cross-VLAN via ${DOMAIN_NAME} (TLS)"
        else
            echo -e "  2) ${YELLOW}FQDN${NC} - Not configured (run 'Setup Internet Access' first)"
        fi
        echo ""
        read -p "  Select [1]: " conn_choice
        conn_choice="${conn_choice:-1}"

        if [[ "$conn_choice" == "1" ]]; then
            # LAN/VPN - UDP, no encryption (explicit transport prevents TLS fallback)
            transport_block="transport=transport-udp"
            encryption_block="media_encryption=no"
            display_server="$(hostname -I | awk '{print $1}')"
            display_port="5060"
            display_transport="UDP"
            display_encryption="None"
            # Enable ICE for VPN devices if VPN ICE mode is active
            if [[ "$VPN_ICE_ENABLED" == "y" ]]; then
                ice_block="ice_support=yes"
            fi
        elif [[ "$conn_choice" == "2" ]]; then
            if [[ "$ENABLE_TLS" != "y" || -z "$DOMAIN_NAME" ]]; then
                print_error "FQDN access not configured. Run 'Setup Internet Access' first."
                return
            fi
            conn_type="fqdn"
            transport_block="transport=transport-tls"
            encryption_block="media_encryption=sdes"
            ice_block="ice_support=yes"
            display_server="$DOMAIN_NAME"
            display_port="5061"
            display_transport="TLS"
            display_encryption="SRTP (SDES)"
        fi
    fi

    backup_config "/etc/asterisk/pjsip.conf"

    # Mobile devices benefit from keepalive to maintain NAT mappings
    # during WiFi/mobile data transitions
    local keepalive_block=""
    if [[ "$cat_id" == "mobile" ]]; then
        keepalive_block="rtp_keepalive=15
rtp_timeout=120
rtp_timeout_hold=120"
    fi

    cat >> /etc/asterisk/pjsip.conf << EOF

; === Device: $name ($cat_id) $override_tag ===
[${ext}]
type=endpoint
context=intercom
${transport_block}
disallow=all
allow=opus
allow=ulaw
allow=alaw
allow=g722
${encryption_block}
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
${keepalive_block}
${ice_block}
auth=${ext}
aors=${ext}
callerid="${name}" <${ext}>

[${ext}]
type=auth
auth_type=userpass
username=${ext}
password=${pass}

[${ext}]
type=aor
max_contacts=5
remove_existing=yes
qualify_frequency=30
EOF

    chown -R asterisk:asterisk /etc/asterisk 2>/dev/null || true
    asterisk -rx "pjsip reload" >/dev/null 2>&1
    rebuild_dialplan

    # Prepare provisioning URLs if HTTP server is configured
    local server_ip=$(hostname -I | awk '{print $1}')
    local prov_url_http=""
    local prov_url_https=""
    if [[ -f /etc/asterisk/http.conf ]] && grep -q "enabled=yes" /etc/asterisk/http.conf 2>/dev/null; then
        prov_url_http="http://${server_ip}:8088/static/linphone.xml"
        if [[ -n "$DOMAIN_NAME" ]]; then
            prov_url_https="https://${DOMAIN_NAME}:8089/static/linphone.xml"
        fi
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  DEVICE ADDED: $name (Extension $ext)"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo -e "  ${BOLD}Server Details:${NC}"
    echo "  Server:     ${display_server}"
    echo "  Port:       ${display_port}"
    echo "  Transport:  ${display_transport}"
    echo "  Extension:  $ext"
    echo "  Password:   $pass"
    echo "  Encryption: ${display_encryption}"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}LINPHONE SETUP${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    if [[ -n "$prov_url_http" ]]; then
        echo "  Remote Provisioning (Recommended):"
        echo "  1. In Linphone → Settings → Remote provisioning"
        echo "  2. Enter URL:"
        echo "     ${prov_url_http}"
        [[ -n "$prov_url_https" ]] && echo "     OR ${prov_url_https}"
        echo "  3. Tap 'Fetch' to apply configuration"
        echo ""
        echo "  OR Manual Setup:"
    else
        echo "  Manual Setup:"
    fi
    echo "  1. Add Account → Use SIP account"
    echo "  2. Username: $ext"
    echo "  3. Password: $pass"
    echo "  4. Domain: ${display_server}"
    echo "  5. Transport: ${display_transport}"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${BOLD}BARESIP SETUP (if Linphone has audio issues)${NC}"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "  Baresip often works better on privacy-focused Android ROMs."
    echo "  Two-step manual configuration required:"
    echo ""
    echo "  Step 1: Add Account"
    echo "    Menu (☰) → Accounts → Add (+)"
    echo "    SIP URI: ${ext}@${display_server}"
    echo "    Save (✓)"
    echo ""
    echo "  Step 2: Edit Account (Complete Config)"
    echo "    Tap account → Edit"
    echo "    Auth Username: $ext (JUST the number!)"
    echo "    Auth Password: $pass"
    echo "    Outbound Proxy: ${display_server} (JUST the domain!)"
    echo "    Media Encryption: srtp (select from dropdown)"
    echo "    Register: ✓ (check box)"
    echo "    Save (✓)"
    echo ""
    echo "  Verify: Look for green dot or 'Registered' status"
    echo "  To call: Just dial extension (101, 202, etc.)"
    echo ""
    echo "  For detailed Baresip instructions:"
    echo "  Server Settings → Provisioning Manager → Create Baresip Config"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"

    # Show TURN/STUN settings if enabled (for manual SIP app configuration)
    if [[ "$TURN_ENABLED" == "y" && -n "$TURN_SERVER" ]]; then
        echo ""
        echo -e "  ${BOLD}STUN/TURN SETTINGS (for NAT traversal)${NC}"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
        echo "  Configure these in your SIP app's Network/ICE settings:"
        echo "  ICE:            Enabled"
        echo "  STUN server:    ${TURN_SERVER}"
        echo "  TURN server:    ${TURN_SERVER}"
        echo "  TURN username:  ${TURN_USERNAME}"
        echo "  TURN password:  ${TURN_PASSWORD}"
        echo "  TURN transport: UDP"
        echo ""
        echo "  Linphone:  Auto-provisioned via XML (no manual setup needed)"
        echo "  Sipnetic:  Settings → Network → ICE/STUN/TURN"
        echo "  Olinuxino: Settings → Network → ICE/STUN/TURN"
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
    fi

    echo ""
    echo "  NOTE: These instructions work for most SIP apps (Zoiper,"
    echo "        sipnetic, etc.) - just use the same credentials."
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
}

remove_device() {
    print_header "Remove Device"
    declare -A REMOVE_MAP
    declare -A NAME_MAP
    local count=1
    local current_name=""
    echo "Select device to remove:"
    echo ""
    while IFS= read -r line; do
        if [[ "$line" == *"; === Device:"* ]]; then
            local temp="${line#*; === Device: }"
            temp="${temp% ===}"
            temp="${temp% \[AA:*\]}"
            current_name="${temp% (*)}"
        fi
        if [[ "$line" =~ ^\[([0-9]+)\]$ && "$current_name" != "" ]]; then
            local ext="${BASH_REMATCH[1]}"
            echo "  ${count}) Ext ${ext} - ${current_name}"
            REMOVE_MAP[$count]=$ext
            NAME_MAP[$count]="$current_name"
            ((count++))
            current_name=""
        fi
    done < /etc/asterisk/pjsip.conf
    echo ""
    echo "  98) DELETE ALL DEVICES"
    echo "  0) Cancel"
    echo ""
    read -p "Select: " choice

    if [[ "$choice" == "98" ]]; then
        echo ""
        print_warn "This will DELETE ALL DEVICES!"
        read -p "Type 'DELETE ALL' to confirm: " confirm
        if [[ "$confirm" == "DELETE ALL" ]]; then
            backup_config "/etc/asterisk/pjsip.conf"
            # Remove all device sections - use awk to properly handle all sections
            awk '
                /^; === Device:/ { skip = 1; next }
                /^\[[0-9]{3}\]$/ { if (skip) next }
                /^type=(endpoint|auth|aor)/ { if (skip) next }
                /^$/ { if (skip) { skip = 0; next } }
                !skip { print }
            ' /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.tmp
            mv /etc/asterisk/pjsip.conf.tmp /etc/asterisk/pjsip.conf
            chown asterisk:asterisk /etc/asterisk/pjsip.conf
            asterisk -rx "pjsip reload" 2>/dev/null
            rebuild_dialplan
            print_success "All devices deleted"
        else
            print_error "Cancelled"
        fi
        return
    fi

    [[ "$choice" == "0" || -z "${REMOVE_MAP[$choice]}" ]] && return

    local ext="${REMOVE_MAP[$choice]}"
    local name="${NAME_MAP[$choice]}"
    read -p "Confirm removal of $ext ($name)? [y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        backup_config "/etc/asterisk/pjsip.conf"
        # Use awk to remove the device comment and ALL three sections for this extension
        awk -v ext="$ext" '
            BEGIN { skip = 0; found_ext = 0 }
            # Match device comment line - start potential skip
            /^; === Device:/ { pending_comment = $0; next }
            # Check if this is the extension we want to delete
            $0 ~ "^\\[" ext "\\]$" {
                if (pending_comment != "") {
                    # This is our device - skip the comment and this section
                    skip = 1
                    found_ext = 1
                    pending_comment = ""
                    next
                } else if (found_ext) {
                    # Additional sections for same extension (auth, aor)
                    skip = 1
                    next
                }
            }
            # If we have a pending comment for a different extension, print it
            pending_comment != "" && $0 !~ "^\\[" ext "\\]$" {
                print pending_comment
                pending_comment = ""
            }
            # Skip lines until empty line
            skip && /^$/ { skip = 0; next }
            skip { next }
            { print }
        ' /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.tmp
        mv /etc/asterisk/pjsip.conf.tmp /etc/asterisk/pjsip.conf
        chown asterisk:asterisk /etc/asterisk/pjsip.conf
        asterisk -rx "pjsip reload" 2>/dev/null
        rebuild_dialplan
        print_success "Removed extension $ext ($name)"
    fi
}
 
rename_device() {
    print_header "Rename Device"
    declare -A DEVICE_MAP
    declare -A NAME_MAP
    declare -A AA_MAP
    local count=1
    echo "Select device to rename:"
    echo ""
    while IFS= read -r line; do
        if [[ "$line" == *"; === Device:"* ]]; then
            local temp="${line#*; === Device: }"
            temp="${temp% ===}"
            local aa_tag=""
            if [[ "$temp" == *"[AA:yes]"* ]]; then
                aa_tag="[AA:yes]"
                temp="${temp% \[AA:yes\]}"
            elif [[ "$temp" == *"[AA:no]"* ]]; then
                aa_tag="[AA:no]"
                temp="${temp% \[AA:no\]}"
            fi
            local name="${temp% (*)}"
            local cat="${temp##* (}"; cat="${cat%)}"
        fi
        if [[ "$line" =~ ^\[([0-9]+)\]$ && -n "$name" ]]; then
            local ext="${BASH_REMATCH[1]}"
            echo "  ${count}) Ext ${ext} - ${name} (${cat})"
            DEVICE_MAP[$count]=$ext
            NAME_MAP[$count]="${name}|${cat}"
            AA_MAP[$count]="${aa_tag}"
            ((count++))
            name=""
        fi
    done < /etc/asterisk/pjsip.conf
    echo ""
    echo "  0) Cancel"
    echo ""
    read -p "Select: " choice

    [[ "$choice" == "0" || -z "${DEVICE_MAP[$choice]}" ]] && return

    local ext="${DEVICE_MAP[$choice]}"
    local info="${NAME_MAP[$choice]}"
    local aa_tag="${AA_MAP[$choice]}"
    local old_name="${info%|*}"
    local cat="${info##*|}"

    echo ""
    echo "Current name: ${old_name}"
    read -p "New name: " new_name

    if [[ -z "$new_name" ]]; then
        print_error "Name cannot be empty"
        return
    fi

    # Backup config
    backup_config "/etc/asterisk/pjsip.conf"

    # Use awk to properly update both the comment line (preserving AA tag) and callerid
    awk -v ext="$ext" -v old_name="$old_name" -v new_name="$new_name" -v cat="$cat" -v aa_tag="$aa_tag" '
        # Update device comment line
        /^; === Device:/ && $0 ~ old_name && $0 ~ cat {
            if (aa_tag != "") {
                print "; === Device: " new_name " (" cat ") " aa_tag " ==="
            } else {
                print "; === Device: " new_name " (" cat ")  ==="
            }
            next
        }
        # Track when we are in the correct extension section
        $0 ~ "^\\[" ext "\\]$" { in_ext = 1 }
        /^$/ { in_ext = 0 }
        # Update callerid in the extension section
        in_ext && /^callerid=/ {
            print "callerid=\"" new_name "\" <" ext ">"
            next
        }
        { print }
    ' /etc/asterisk/pjsip.conf > /etc/asterisk/pjsip.conf.tmp
    mv /etc/asterisk/pjsip.conf.tmp /etc/asterisk/pjsip.conf
    chown asterisk:asterisk /etc/asterisk/pjsip.conf

    # Reload Asterisk
    asterisk -rx "pjsip reload" 2>/dev/null
    rebuild_dialplan quiet

    print_success "Device renamed: ${old_name} → ${new_name}"
} 


show_registered_devices() {
    # Collect all device data
    declare -A device_data
    local dev_name="" dev_cat=""
    while IFS= read -r line; do
        if [[ "$line" == *"; === Device:"* ]]; then
            # Remove the prefix and suffix, handling variable whitespace
            local temp="${line#*; === Device: }"
            temp="${temp%% ===}"  # Use %% to handle multiple spaces before ===
            temp="${temp## }"      # Trim leading spaces
            temp="${temp%% }"      # Trim trailing spaces
            
            [[ "$temp" == *"[AA:"* ]] && temp="${temp% \[AA:*\]}"
            
            # Extract category - everything inside the last (...)
            dev_cat="${temp##*\(}"
            dev_cat="${dev_cat%\)}"
            dev_cat="${dev_cat## }"  # Trim any leading spaces
            dev_cat="${dev_cat%% }"  # Trim any trailing spaces
            
            # Extract name - everything before the last (
            dev_name="${temp%% \(*}"
        fi
        if [[ "$line" =~ ^\[([0-9]+)\] ]]; then
            local ext="${BASH_REMATCH[1]}"
            if [[ -n "$dev_name" ]]; then
                device_data[$ext]="${dev_name}|${dev_cat}"
                dev_name=""
                dev_cat=""
            fi
        fi
    done < /etc/asterisk/pjsip.conf
    
    # Interactive loop
    while true; do
        # Group by category
        declare -A categories
        declare -A category_names
        for ext in "${!device_data[@]}"; do
            local info="${device_data[$ext]}"
            local cat="${info##*|}"
            categories[$cat]="${categories[$cat]} $ext"
        done
        
        # Get full category names from categories file
        while IFS='|' read -r cat_id cat_name auto_answer description; do
            [[ "$cat_id" =~ ^# ]] && continue
            [[ -z "$cat_id" ]] && continue
            category_names[$cat_id]="$cat_name"
        done < "$CATEGORIES_FILE"
        
        clear
        print_header "Device Status"
        
        echo "Select category to view:"
        echo "  1) All devices"
        local i=2
        declare -A cat_menu
        for cat in $(echo "${!categories[@]}" | tr ' ' '\n' | sort); do
            local display_name="${category_names[$cat]:-$cat}"
            echo "  ${i}) ${display_name}"
            cat_menu[$i]="$cat"
            ((i++))
        done
        echo "  0) Back to menu"
        echo ""
        read -p "Select [1]: " cat_choice
        
        [[ "$cat_choice" == "0" ]] && return
        cat_choice="${cat_choice:-1}"
        
        clear
        print_header "Device Status"
        printf "${CYAN}%-6s %-25s %-15s %-15s %-15s${NC}\n" "Ext" "Name" "Category" "Status" "Password"
        echo "--------------------------------------------------------------------------------------------"
        
        if [[ "$cat_choice" == "1" ]]; then
            # Show all devices
            for ext in $(echo "${!device_data[@]}" | tr ' ' '\n' | sort -n); do
                local info="${device_data[$ext]}"
                local name="${info%|*}"
                local cat="${info##*|}"
                local cat_display="${category_names[$cat]:-$cat}"
                local status="${RED}Offline${NC}"
                local avail=$(asterisk -rx "pjsip show endpoint ${ext}" 2>/dev/null | grep -E "Contact:.*(Avail|NonQual)" || true)
                [[ -n "$avail" ]] && status="${GREEN}Online${NC}"
                local password=$(grep -A 10 "^\[$ext\]" /etc/asterisk/pjsip.conf | grep "password=" | head -1 | cut -d= -f2)
                printf "%-6s %-25s %-15s %b %-15s\n" "$ext" "${name:0:23}" "${cat_display:0:13}" "$status" "$password"
            done
        else
            # Show specific category
            local selected_cat="${cat_menu[$cat_choice]}"
            if [[ -n "$selected_cat" ]]; then
                local cat_display="${category_names[$selected_cat]:-$selected_cat}"
                echo -e "${BOLD}Showing: ${cat_display}${NC}"
                echo ""
                for ext in $(echo "${categories[$selected_cat]}" | tr ' ' '\n' | sort -n); do
                    local info="${device_data[$ext]}"
                    local name="${info%|*}"
                    local cat="${info##*|}"
                    local cat_display="${category_names[$cat]:-$cat}"
                    local status="${RED}Offline${NC}"
                    local avail=$(asterisk -rx "pjsip show endpoint ${ext}" 2>/dev/null | grep -E "Contact:.*(Avail|NonQual)" || true)
                    [[ -n "$avail" ]] && status="${GREEN}Online${NC}"
                    local password=$(grep -A 10 "^\[$ext\]" /etc/asterisk/pjsip.conf | grep "password=" | head -1 | cut -d= -f2)
                    printf "%-6s %-25s %-15s %b %-15s\n" "$ext" "${name:0:23}" "${cat_display:0:13}" "$status" "$password"
                done
            fi
        fi
        
        echo ""
        echo "Connection Details:"
        echo "  Domain: ${DOMAIN_NAME:-$(hostname -I | awk '{print $1}')}"
        echo "  Port:   ${DEFAULT_SIP_PORT}/udp (LAN) or ${DEFAULT_SIPS_PORT}/tcp (TLS)"
        echo ""
        read -p "Press Enter to select another category (or 0 to exit)... "
    done
}


# ================================================================
# 4. PTT WIZARD (Fixed: Mute by default)
# ================================================================

configure_ptt_menu() {
    print_header "Configure PTT Button"
    detect_ptt_button
}

detect_ptt_button() {
    # Ensure evtest is installed
    if ! command -v evtest &>/dev/null; then
        apt install -y evtest >/dev/null 2>&1
    fi
    
    # Add user to input group
    [[ -n "$KIOSK_USER" ]] && usermod -aG input "$KIOSK_USER" 2>/dev/null || true
    
    print_info "Scanning input devices..."
    echo ""
    
    declare -a SUGGESTED_DEVICES SUGGESTED_NAMES OTHER_DEVICES OTHER_NAMES
    
    for dev in /dev/input/event*; do
        [[ -e "$dev" ]] || continue
        local name=$(cat "/sys/class/input/$(basename $dev)/device/name" 2>/dev/null || echo "Unknown")
        local lname=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        
        # Filter out system devices that aren't PTT candidates
        if [[ "$lname" =~ (power.button|sleep.button|lid.switch|virtual|video.bus|hdmi|dp,pcm|hotkey|touchpad|touchscreen) ]]; then
            OTHER_DEVICES+=("$dev")
            OTHER_NAMES+=("$name")
        # Prioritize keyboards, USB HID devices, pedals
        elif [[ "$lname" =~ (keyboard|sayo.*nano$|pedal|foot|^hid) ]]; then
            SUGGESTED_DEVICES+=("$dev")
            SUGGESTED_NAMES+=("$name")
        else
            OTHER_DEVICES+=("$dev")
            OTHER_NAMES+=("$name")
        fi
    done
    
    # Display suggested devices first
    if [[ ${#SUGGESTED_DEVICES[@]} -gt 0 ]]; then
        echo -e "${GREEN}Keyboards and USB buttons:${NC}"
        for i in "${!SUGGESTED_DEVICES[@]}"; do
            printf "  ${CYAN}%2d)${NC} %s - %s\n" "$((i+1))" "$(basename ${SUGGESTED_DEVICES[$i]})" "${SUGGESTED_NAMES[$i]}"
        done
        echo ""
    fi
    
    # Display other devices
    if [[ ${#OTHER_DEVICES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Other devices:${NC}"
        local offset=${#SUGGESTED_DEVICES[@]}
        for i in "${!OTHER_DEVICES[@]}"; do
            printf "  ${CYAN}%2d)${NC} %s - %s\n" "$((offset+i+1))" "$(basename ${OTHER_DEVICES[$i]})" "${OTHER_NAMES[$i]}"
        done
        echo ""
    fi
    
    local ALL_DEVICES=("${SUGGESTED_DEVICES[@]}" "${OTHER_DEVICES[@]}")
    local total=${#ALL_DEVICES[@]}
    
    if [[ $total -eq 0 ]]; then
        print_error "No input devices found"
        return 1
    fi
    
    echo "  0) Back"
    echo ""
    read -p "Select device [1]: " selection
    selection="${selection:-1}"
    
    [[ "$selection" == "0" ]] && return 0
    [[ "$selection" -lt 1 || "$selection" -gt "$total" ]] && { print_error "Invalid selection"; return 1; }
    
    PTT_DEVICE="${ALL_DEVICES[$((selection-1))]}"
    local dev_name=$(cat "/sys/class/input/$(basename $PTT_DEVICE)/device/name" 2>/dev/null || echo "Unknown")
    echo ""
    print_success "Selected: $dev_name"
    echo "          ($PTT_DEVICE)"
    echo ""
    
    # Key detection loop
    while true; do
        echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}  DO NOT PRESS YET - wait for countdown${NC}"
        echo -e "${YELLOW}══════════════════════════════════════════════════${NC}"
        
        for i in 5 4 3 2 1; do
            echo -ne "\r  Waiting... $i "
            sleep 1
        done
        echo ""
        echo ""
        echo -e "${GREEN}>>> NOW PRESS YOUR PTT BUTTON <<<${NC}"
        echo ""
        
        local detected_code=$(timeout 10 evtest "$PTT_DEVICE" 2>/dev/null | grep -m1 "value 1$" | grep -oP 'code \K[0-9]+' || echo "")
        
        if [[ -n "$detected_code" && "$detected_code" -gt 0 ]]; then
            # Map common key codes to friendly names
            local key_name="Key $detected_code"
            case "$detected_code" in
                1) key_name="Escape" ;;
                28) key_name="Enter" ;;
                57) key_name="Spacebar" ;;
                69) key_name="Num Lock" ;;
                113) key_name="Mute" ;;
                114) key_name="Volume Down" ;;
                115) key_name="Volume Up" ;;
                116) key_name="Power" ;;
                142) key_name="Sleep" ;;
                272) key_name="Left Click" ;;
                273) key_name="Right Click" ;;
            esac
            
            print_success "Detected: $key_name (code $detected_code)"
            echo ""
            read -p "Use this key? [Y/n]: " use_key
            
            if [[ ! "$use_key" =~ ^[Nn]$ ]]; then
                PTT_KEYCODE="$detected_code"
                PTT_KEYNAME="$key_name"
                break
            fi
        else
            print_warn "No button press detected"
        fi
        
        echo ""
        echo "  1) Try again"
        echo "  2) Enter key code manually"
        echo "  3) Cancel"
        read -p "Select [1]: " retry
        
        case "${retry:-1}" in
            2)
                read -p "Enter key code: " PTT_KEYCODE
                PTT_KEYNAME="Manual"
                break
                ;;
            3)
                return 1
                ;;
        esac
    done
    
    # Ensure user is in input group (critical for PTT device access)
    if [[ -n "$KIOSK_USER" ]]; then
        if ! id -nG "$KIOSK_USER" | grep -qw "input"; then
            print_info "Adding $KIOSK_USER to input group..."
            usermod -aG input "$KIOSK_USER"
            echo ""
            print_error "IMPORTANT: User added to 'input' group"
            echo "  User must log out and log back in (or reboot) for group change to take effect."
            echo "  PTT will NOT work until then!"
            echo ""
            read -p "Press Enter to acknowledge..."
        fi
    fi

    # Save configuration via save_config (will set proper permissions)
    save_config

    print_success "PTT configured: $PTT_KEYNAME on $(basename $PTT_DEVICE)"
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  PTT Configuration Complete"
    echo "═══════════════════════════════════════════════════════"
    echo "  Device:  $PTT_DEVICE"
    echo "  Button:  $PTT_KEYNAME"
    echo "  User:    ${KIOSK_USER:-not set}"
    echo ""
    echo "  Testing PTT:"
    echo "  1. Check logs: journalctl -t kiosk-ptt -f"
    echo "  2. Press PTT button"
    echo "  3. You should see: 'PTT pressed - mic unmuted'"
    echo ""
    echo "  If you see 'Permission denied' errors:"
    echo "  - User needs to be in 'input' group (already added above)"
    echo "  - Log out and log back in, or reboot"
    echo "═══════════════════════════════════════════════════════"

    # Restart PTT service if client is installed (bare metal only)
    if [[ "$INSTALLED_CLIENT" == "y" && -n "$KIOSK_USER" ]] && ! is_docker; then
        local user_dbus="XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}"
        echo ""
        print_info "Restarting PTT service..."
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user daemon-reload 2>/dev/null
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user restart kiosk-ptt 2>/dev/null || true
        sleep 2
        echo ""
        echo "Checking PTT status..."
        journalctl -t kiosk-ptt -n 5 --no-pager 2>/dev/null || echo "  No logs yet (check after logging out/in if needed)"
    fi

    return 0
}

create_ptt_handler() {
    cat > /usr/local/bin/kiosk-ptt << 'PTTSCRIPT'
#!/bin/bash
CONFIG="/etc/easy-asterisk/config"
PTT_CONFIG="/etc/easy-asterisk/ptt-device"
[[ -f "$CONFIG" ]] && source "$CONFIG"
[[ -f "$PTT_CONFIG" ]] && source "$PTT_CONFIG"

# Exit if no PTT device configured - leave audio unmuted for normal kiosk operation
[[ -z "$PTT_DEVICE" ]] && exit 0

# Ensure we have the user's runtime directory
if [[ -z "$XDG_RUNTIME_DIR" ]]; then
    # If running as systemd service, this should already be set
    # But if not, try to detect it
    if [[ -n "$KIOSK_UID" ]]; then
        export XDG_RUNTIME_DIR="/run/user/${KIOSK_UID}"
    else
        # Fall back to current user
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
fi

# Wait for PipeWire/PulseAudio to be ready
for i in {1..10}; do
    if pactl info >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# PTT mode: Mute audio source on start, unmute only when button pressed
pactl set-source-mute @DEFAULT_SOURCE@ 1 2>/dev/null || {
    logger -t kiosk-ptt "ERROR: Failed to mute audio source"
    exit 1
}

logger -t kiosk-ptt "PTT handler started, microphone muted, listening on $PTT_DEVICE"

# Unmute on press, mute on release
evtest --grab "$PTT_DEVICE" 2>/dev/null | while read -r line; do
    if [[ "$line" =~ "value 1" ]]; then
        pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null
        logger -t kiosk-ptt "PTT pressed - mic unmuted"
    fi
    if [[ "$line" =~ "value 0" ]]; then
        pactl set-source-mute @DEFAULT_SOURCE@ 1 2>/dev/null
        logger -t kiosk-ptt "PTT released - mic muted"
    fi
done
PTTSCRIPT
    chmod +x /usr/local/bin/kiosk-ptt
}

# ================================================================
# 5. AUDIO DUCKING
# ================================================================

configure_audio_ducking() {
    [[ -z "$KIOSK_USER" ]] && return
    local wp_dir="/home/${KIOSK_USER}/.config/wireplumber/wireplumber.conf.d"
    mkdir -p "$wp_dir"
    cat > "${wp_dir}/50-intercom-ducking.conf" << 'EOF'
wireplumber.settings = { linking.allow-moving-streams = true }
EOF
    chown -R ${KIOSK_USER}:${KIOSK_USER} "/home/${KIOSK_USER}/.config"
}

ensure_audio_unmuted() {
    [[ -z "$KIOSK_USER" ]] && return
    [[ -z "$KIOSK_UID" ]] && return

    # Only unmute if PTT is not configured
    if [[ ! -f /etc/easy-asterisk/ptt-device ]]; then
        local user_dbus="XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}"

        # Wait a moment for PipeWire to initialize
        sleep 2

        # Unmute all sources and sinks
        sudo -u "$KIOSK_USER" $user_dbus pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null || true
        sudo -u "$KIOSK_USER" $user_dbus pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true

        # Set reasonable volume levels if they're at 0
        local source_vol=$(sudo -u "$KIOSK_USER" $user_dbus pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null | grep -oP '\d+%' | head -1 | tr -d '%')
        local sink_vol=$(sudo -u "$KIOSK_USER" $user_dbus pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+%' | head -1 | tr -d '%')

        [[ -n "$source_vol" && "$source_vol" -lt 50 ]] && sudo -u "$KIOSK_USER" $user_dbus pactl set-source-volume @DEFAULT_SOURCE@ 75% 2>/dev/null || true
        [[ -n "$sink_vol" && "$sink_vol" -lt 50 ]] && sudo -u "$KIOSK_USER" $user_dbus pactl set-sink-volume @DEFAULT_SINK@ 75% 2>/dev/null || true
    fi
}

# ================================================================
# 6. DIAGNOSTICS & FIREWALL
# ================================================================

show_port_requirements() {
    print_header "Port / Firewall Requirements"
    echo "This server needs traffic to pass from your Clients (Kiosks/Phones)."
    echo ""
    echo "Does your Asterisk server have a PUBLIC IP (VPS/Cloud)?"
    echo "  -> YES: You must use 'Forwarding' (DNAT) rules on your router."
    echo "  -> NO:  You must use 'Allow/Pass' rules on your VLAN interfaces."
    echo ""
    echo "Required Ports:"
    echo "┌──────────────────┬──────────┬───────────────────────────────┐"
    echo "│ Port             │ Protocol │ Purpose                       │"
    echo "├──────────────────┼──────────┼───────────────────────────────┤"
    echo "│ 5060             │ UDP      │ SIP Signaling (Registration)  │"
    echo "│ 5061             │ TCP      │ SIP-TLS Signaling (Secure)    │"
    echo "│ 10000-20000      │ UDP      │ RTP Media (Audio/Video)       │"
    if [[ "$USE_COTURN" == "y" ]]; then
        echo "│ ${DEFAULT_TURN_PORT}             │ UDP/TCP  │ TURN Signaling (Handshake)    │"
        echo "│ 49152-65535      │ UDP      │ TURN Relay (Actual Media Path)│"
    fi
    echo "└──────────────────┴──────────┴───────────────────────────────┘"
    echo ""
    echo "NOTE: VPN Users"
    echo "If ALL clients and server are on a VPN (Tailscale/Wireguard), you DO NOT"
    echo "need port forwarding or COTURN. Just bind Asterisk to the VPN IP."
}

show_firewall_guide() {
    print_header "Interactive Firewall Guide (Hand-holding Mode)"
    echo "For: Routers with VLAN support"
    echo ""
    echo "=== SCENARIO A: INTERNAL ONLY (VLAN to VLAN) ==="
    echo "Example: Kiosks on VLAN 10, Server on VLAN 20"
    echo "GOAL: Allow Kiosks to talk to Server."
    echo ""
    echo "STEP 1: Log in to Router. Go to Firewall > Rules > VLAN 10 Interface."
    echo "        (Do NOT use 'Port Forwarding' for internal VLANs!)"
    echo ""
    echo "STEP 2: Create Rule 1 (Signaling)"
    echo "   - Action: Pass (Allow)"
    echo "   - Protocol: UDP/TCP"
    echo "   - Source: VLAN 10 Net"
    echo "   - Dest:   ${CURRENT_PUBLIC_IP:-Server_IP}"
    echo "   - Port:   3478 (or your TURN_PORT if changed)"
    echo ""
    echo "STEP 3: Create Rule 2 (The Relay Range - CRITICAL)"
    echo "   - Action: Pass (Allow)"
    echo "   - Protocol: UDP"
    echo "   - Source: VLAN 10 Net"
    echo "   - Dest:   ${CURRENT_PUBLIC_IP:-Server_IP}"
    echo "   - Port Range:"
    echo "       From: 49152"
    echo "       To:   65535"
    echo "     (Note: Type these numbers in the Start/End boxes)"
    echo ""
    echo "================================================"
    echo ""
    echo "=== SCENARIO B: EXTERNAL ACCESS (Internet to LAN) ==="
    echo "Example: Remote phone connecting from a hotel."
    echo "GOAL: Forward traffic from Internet to Server."
    echo ""
    echo "STEP 1: Go to Firewall > NAT > Port Forwarding."
    echo "STEP 2: Create Rule."
    echo "   - Interface: WAN"
    echo "   - Protocol: UDP"
    echo "   - Dest. Port: 3478 (or your TURN_PORT) and 49152-65535"
    echo "   - Redirect IP: ${CURRENT_PUBLIC_IP:-Server_IP}"
    echo ""
    read -p "Press Enter to return..."
}

show_preflight_check() {
    print_header "Pre-Flight Requirements Check"
    echo "Modern browsers (Chrome, Safari, Kiosk Mode) have strict security settings."
    echo ""
    echo "1. HTTPS / SSL Certificate (Required for Camera/Mic)"
    echo "   - Browsers block Mic/Cam on 'Insecure Origins' (HTTP)."
    echo "   - Exception: http://localhost is allowed."
    echo "   - Solution: You NEED a domain (FQDN) and SSL Cert (LetsEncrypt)."
    echo "   - Workaround: Use the 'Caddy Cert Sync' option in this script."
    echo ""
    echo "2. Static vs Dynamic IP"
    echo "   - If your Public IP changes, COTURN will break."
    echo "   - Solution: Use the 'Update IP manually' or auto-script in the menu."
    echo ""
    echo "3. VPN Alternative"
    echo "   - A VPN (Tailscale) negates the need for COTURN and Port Forwarding."
    echo "   - It treats all devices as if they are on the same flat network."
    echo ""
    read -p "Press Enter to return..."
}

test_sip_connectivity() {
    print_header "SIP Connectivity Test"
    if asterisk_running; then
        print_success "Asterisk Running"
    else
        print_error "Asterisk Down"
    fi
    echo ""
    echo "Listening ports:"
    ss -ulnp | grep 5060 || echo "  UDP 5060: Not listening"
    ss -tlnp | grep 5061 || echo "  TCP 5061: Not listening"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo ""
        echo "TLS Certificate check:"
        timeout 5 openssl s_client -connect localhost:5061 -servername "$DOMAIN_NAME" 2>/dev/null | grep "Verify return code" || echo "  TLS test failed"
    fi
}

verify_cidr_config() {
    print_header "CIDR Configuration"
    local my_ip=$(hostname -I | cut -d' ' -f1)
    echo "Server IP: $my_ip"
    echo ""
    echo "Current NAT settings in pjsip.conf:"
    grep -E "external_|local_net" /etc/asterisk/pjsip.conf 2>/dev/null || echo "  No NAT settings found"
}

configure_vlan_subnets() {
    print_header "VLAN / VPN Subnet Configuration"
    load_config

    echo "Additional Subnet Support for Easy Asterisk"
    echo "================================================"
    echo ""
    echo "If your network uses VLANs or VPNs, you need to tell"
    echo "Asterisk about all the local subnets so that:"
    echo "  - Calls don't drop after 30 seconds (VLAN issue)"
    echo "  - VPN-connected mobile devices can register"
    echo "  - Audio works correctly for VPN users"
    echo ""
    echo "Example subnets:"
    echo "  192.168.1.0/24    - Main network"
    echo "  192.168.10.0/24   - IoT VLAN"
    echo "  100.64.0.0/10     - Tailscale VPN"
    echo "  10.0.0.0/8        - WireGuard/OpenVPN"
    echo ""

    # Auto-detect VPN interfaces and their subnets
    local detected_vpn_subnets=""
    local vpn_info=""
    while IFS= read -r line; do
        local iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
        local addr=$(echo "$line" | awk '{print $4}')
        if [[ -n "$addr" && -n "$iface" ]]; then
            case "$iface" in
                tailscale*|ts*)
                    vpn_info="${vpn_info}  Detected: ${iface} -> ${addr} (Tailscale)\n"
                    detected_vpn_subnets="${detected_vpn_subnets} 100.64.0.0/10"
                    ;;
                wg*)
                    vpn_info="${vpn_info}  Detected: ${iface} -> ${addr} (WireGuard)\n"
                    detected_vpn_subnets="${detected_vpn_subnets} ${addr}"
                    ;;
                tun*|tap*)
                    vpn_info="${vpn_info}  Detected: ${iface} -> ${addr} (OpenVPN/VPN tunnel)\n"
                    detected_vpn_subnets="${detected_vpn_subnets} ${addr}"
                    ;;
                nordlynx*|proton*)
                    vpn_info="${vpn_info}  Detected: ${iface} -> ${addr} (VPN)\n"
                    detected_vpn_subnets="${detected_vpn_subnets} ${addr}"
                    ;;
            esac
        fi
    done < <(ip -o -f inet addr show 2>/dev/null | grep -vE 'lo |docker|br-|veth')
    detected_vpn_subnets=$(echo "$detected_vpn_subnets" | xargs -n1 2>/dev/null | sort -u | xargs 2>/dev/null)

    if [[ -n "$vpn_info" ]]; then
        echo -e "${GREEN}VPN interfaces detected on this server:${NC}"
        echo -e "$vpn_info"
        echo "  Suggested VPN subnets: ${detected_vpn_subnets}"
        echo ""
        echo "  NOTE: If mobile devices connect via VPN (e.g., Tailscale on phones),"
        echo "  you MUST add the VPN subnet here for them to reach Asterisk."
        echo ""
    fi

    read -p "Does your network use VLANs or VPNs? (y/n) [${HAS_VLANS}]: " has_vlans
    has_vlans=${has_vlans:-$HAS_VLANS}

    if [[ "$has_vlans" =~ ^[Yy] ]]; then
        HAS_VLANS="y"
        echo ""
        echo "Current Subnets: ${VLAN_SUBNETS:-none}"
        if [[ -n "$detected_vpn_subnets" ]]; then
            echo "Detected VPN Subnets: ${detected_vpn_subnets}"
        fi
        echo ""
        echo "Enter ALL additional subnets (VLAN + VPN) in CIDR notation, separated by spaces."
        echo "Example: 192.168.10.0/24 100.64.0.0/10"
        echo ""
        local default_subnets="${VLAN_SUBNETS:-$detected_vpn_subnets}"
        read -p "Subnets [${default_subnets}]: " vlan_input
        vlan_input="${vlan_input:-$default_subnets}"

        if [[ -n "$vlan_input" ]]; then
            VLAN_SUBNETS="$vlan_input"
            save_config
            print_success "VLAN configuration saved"
            echo ""
            echo "Rebuilding pjsip.conf to apply changes..."
            generate_pjsip_conf
            asterisk -rx "module reload res_pjsip.so" 2>/dev/null
            print_success "Asterisk configuration updated"

            echo ""
            echo "═══════════════════════════════════════════════════════════"
            echo "  VLAN DNS SETUP GUIDE (Split-Horizon)"
            echo "═══════════════════════════════════════════════════════════"
            echo ""
            echo "For proper VLAN operation with FQDNs, you need split-horizon DNS."
            echo ""
            read -p "Display DNS setup guide? (y/n) [y]: " show_dns
            show_dns=${show_dns:-y}

            if [[ "$show_dns" =~ ^[Yy]$ ]]; then
                cat << 'DNSGUIDE'

WHAT YOU'RE ACHIEVING:
• Devices on VLANs use router for DNS (ctrld)
• ctrld split-horizon rules send FQDNs to the right LAN servers
• Only ctrld (router) can talk to servers' DNS (protected by UFW)
• No inter-VLAN routing is opened, just DNS and service ports

1. CTRLD.TOML (on OPNSense/Router):

[listener.0]
  ip = '0.0.0.0'
  port = 53

  [listener.0.policy]
    networks = [
      { 'network.0' = ['upstream.0'] },
      { 'network.1' = ['upstream.1'] }
    ]
    rules = [
      { 'asterisk.mydomain.com' = ['upstream.4'] }
    ]

[network.0]
  cidrs = ['192.168.1.0/24']

[network.1]
  cidrs = ['192.168.200.0/24']

[upstream.0]
  type = 'doh'
  endpoint = 'https://dns.controld.com/your-profile'
  timeout = 5000

[upstream.4]
  type = 'legacy'
  endpoint = '192.168.1.11'   # This Asterisk server
  timeout = 3000

2. DNSMASQ ON THIS SERVER:

sudo apt-get install dnsmasq
echo "listen-address=127.0.0.1" >> /etc/dnsmasq.conf
echo "listen-address=$(hostname -I | cut -d' ' -f1)" >> /etc/dnsmasq.conf
echo "bind-interfaces" >> /etc/dnsmasq.conf
echo "address=/asterisk.mydomain.com/$(hostname -I | cut -d' ' -f1)" >> /etc/dnsmasq.conf
sudo systemctl restart dnsmasq

3. UFW RULES ON THIS SERVER:

sudo ufw allow from 192.168.1.1 to any port 53 proto udp
sudo ufw allow from 192.168.1.1 to any port 53 proto tcp
sudo ufw deny 53
sudo ufw reload

Replace 192.168.1.1 with your router's LAN IP.

4. OPNSENSE FIREWALL RULES (for each VLAN):

Rule 1 - Allow DNS from VLAN to Router:
  Action: Pass
  Source: VLANxx net
  Destination: This Firewall
  Port: 53 (DNS)
  Protocol: TCP/UDP

Rule 2 - Allow SIP/RTP from VLAN to Asterisk:
  Source: VLANxx net
  Destination: $(hostname -I | cut -d' ' -f1)
  Ports: 5060/udp, 5061/tcp, 10000-20000/udp

5. DHCP SETTINGS (OPNSense):

For each VLAN, set DNS Servers to ONLY the router's VLAN IP.
Do NOT enter this server's IP as DNS.

═══════════════════════════════════════════════════════════
DNSGUIDE
            fi
        else
            print_error "No subnets provided"
        fi
    else
        HAS_VLANS="n"
        VLAN_SUBNETS=""
        save_config
        print_success "VLAN support disabled"
    fi
}

# ================================================================
# PROVISIONING MANAGER
# ================================================================

setup_http_provisioning() {
    print_header "HTTP Provisioning Setup"

    echo "This will configure Asterisk's built-in HTTP server for"
    echo "client provisioning (Linphone, etc.)."
    echo ""
    echo "Ports:"
    echo "  HTTP:  8088"
    echo "  HTTPS: 8089"
    echo ""

    # Create http.conf
    backup_config "/etc/asterisk/http.conf" 2>/dev/null
    cat > /etc/asterisk/http.conf << 'EOF'
[general]
enabled=yes
bindaddr=0.0.0.0
bindport=8088

tlsenable=yes
tlsbindaddr=0.0.0.0:8089
tlscertfile=/etc/asterisk/certs/server.crt
tlsprivatekey=/etc/asterisk/certs/server.key

; Serve static files from /var/lib/asterisk/static-http
enablestatic=yes
redirect=/static /var/lib/asterisk/static-http

; Security
session_limit=100
session_inactivity=30000
session_keep_alive=15000
EOF

    chown asterisk:asterisk /etc/asterisk/http.conf

    # Create provisioning directory
    mkdir -p "$PROVISIONING_DIR"
    chown asterisk:asterisk "$PROVISIONING_DIR"

    # Create symlink if needed (Ubuntu/Debian fix)
    if [[ ! -L /usr/share/asterisk/static-http ]]; then
        mkdir -p /usr/share/asterisk
        ln -sf "$PROVISIONING_DIR" /usr/share/asterisk/static-http
        print_info "Created symlink: /usr/share/asterisk/static-http -> $PROVISIONING_DIR"
    fi

    # Reload Asterisk HTTP module
    asterisk -rx "module reload res_http_post.so" 2>/dev/null || true
    asterisk -rx "http show status" 2>/dev/null

    print_success "HTTP provisioning configured"
    echo ""
    echo "Access provisioning files at:"
    echo "  HTTP:  http://$(hostname -I | cut -d' ' -f1):8088/static/"
    echo "  HTTPS: https://$(hostname -I | cut -d' ' -f1):8089/static/"
}

create_linphone_xml() {
    print_header "Create/Edit Linphone Provisioning XML"
    load_config

    local xml_file="$PROVISIONING_DIR/linphone.xml"
    local server_ip=$(hostname -I | cut -d' ' -f1)
    local domain="${DOMAIN_NAME:-$server_ip}"
    local transport="tcp"

    if [[ "$ENABLE_TLS" == "y" && -n "$DOMAIN_NAME" ]]; then
        transport="tls"
    fi

    echo "Current Configuration:"
    echo "  Domain:    $domain"
    echo "  Transport: $transport"
    echo "  Server IP: $server_ip"
    echo ""

    read -p "Create/Update linphone.xml? (y/n) [y]: " create_xml
    create_xml=${create_xml:-y}

    if [[ "$create_xml" =~ ^[Yy]$ ]]; then
        mkdir -p "$PROVISIONING_DIR"

        cat > "$xml_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<config xmlns="http://www.linphone.org/xsds/lpconfig.xsd"
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
        xsi:schemaLocation="http://www.linphone.org/xsds/lpconfig.xsd lpconfig.xsd">

  <!-- Easy Asterisk Provisioning -->

  <section name="sip">
    <entry name="default_proxy">0</entry>
    <entry name="register_only_when_network_is_up">1</entry>
    <entry name="ping_with_options">0</entry>
  </section>

  <section name="proxy_0">
    <entry name="reg_proxy">&lt;sip:${domain};transport=${transport}&gt;</entry>
    <entry name="reg_identity">sip:USERNAME@${domain}</entry>
    <entry name="reg_expires">3600</entry>
    <entry name="publish">0</entry>
    <entry name="dial_escape_plus">0</entry>
  </section>

  <section name="auth_info_0">
    <entry name="username">USERNAME</entry>
    <entry name="passwd">PASSWORD</entry>
    <entry name="realm">${domain}</entry>
  </section>

  <section name="rtp">
    <entry name="audio_rtp_port">7078</entry>
    <entry name="audio_jitt_comp">60</entry>
  </section>

  <section name="sound">
    <entry name="playback_dev_id">ANDROID SND: Android Sound card</entry>
    <entry name="capture_dev_id">ANDROID SND: Android Sound card</entry>
    <entry name="media_dev_id">ANDROID SND: Android Sound card</entry>
  </section>

  <section name="video">
    <entry name="enabled">0</entry>
    <entry name="automatically_initiate">0</entry>
    <entry name="automatically_accept">0</entry>
  </section>

  <section name="app">
    <entry name="auto_start">1</entry>
    <entry name="show_contacts_emails_preference">0</entry>
    <entry name="android_app_use_opensl">1</entry>
    <entry name="android_push_notification">0</entry>
    <!-- CRITICAL: Prevent audio pause when screen turns off -->
    <entry name="android_pause_calls_when_audio_focus_lost">0</entry>
    <!-- /e/OS and privacy ROMs: Keep service alive -->
    <entry name="keep_service_alive">1</entry>
    <entry name="start_at_boot">1</entry>
  </section>

  <section name="audio">
    <!-- Force audio routing for background operation -->
    <entry name="audio_route_earpiece">0</entry>
    <entry name="audio_route_speaker">1</entry>
  </section>

  <section name="net">
    <entry name="mtu">1300</entry>
    <!-- ICE + STUN/TURN for NAT traversal -->
    <entry name="firewall_policy">3</entry>
    <entry name="stun_server">${TURN_SERVER:-${domain}:3478}</entry>
  </section>

</config>
EOF

    # Add TURN credentials section if TURN is enabled
    if [[ "$TURN_ENABLED" == "y" && -n "$TURN_SERVER" && -n "$TURN_USERNAME" && -n "$TURN_PASSWORD" ]]; then
        # Insert TURN credentials into the net section before </config>
        sed -i "s|<entry name=\"stun_server\">.*</entry>|<entry name=\"stun_server\">${TURN_SERVER}</entry>\n    <entry name=\"turn_enable\">1</entry>\n    <entry name=\"turn_username\">${TURN_USERNAME}</entry>\n    <entry name=\"turn_password\">${TURN_PASSWORD}</entry>|" "$xml_file"
    fi

        chown asterisk:asterisk "$xml_file"
        chmod 644 "$xml_file"

        print_success "Created: $xml_file"
        echo ""
        echo "Provisioning URL:"
        if [[ "$transport" == "tls" ]]; then
            echo "  https://${domain}:8089/static/linphone.xml"
        else
            echo "  http://${server_ip}:8088/static/linphone.xml"
        fi
        echo ""
        echo "IMPORTANT for Android:"
        echo "  1. Use the URL above in Linphone's 'Remote provisioning'"
        echo "  2. Replace USERNAME and PASSWORD in device-specific XML files"
        echo "  3. Set Battery Optimization to 'Unrestricted' manually on phone"
        echo "  4. The XML prevents audio pause when screen turns off"
        echo ""
        echo "FOR /e/OS (eFoundation) users:"
        echo "  See 'Troubleshoot /e/OS Audio' in Provisioning Manager menu"
    fi
}

edit_linphone_xml() {
    local xml_file="$PROVISIONING_DIR/linphone.xml"

    if [[ ! -f "$xml_file" ]]; then
        print_error "linphone.xml does not exist. Create it first."
        return 1
    fi

    print_header "Edit Linphone XML"
    echo "Opening in nano editor..."
    echo "Press Ctrl+X to save and exit"
    echo ""
    read -p "Press Enter to continue..."

    nano "$xml_file"

    print_success "Changes saved"
}

show_provisioning_status() {
    print_header "Provisioning Status"

    # Check HTTP configuration
    if [[ -f /etc/asterisk/http.conf ]] && grep -q "enabled=yes" /etc/asterisk/http.conf 2>/dev/null; then
        echo -e "HTTP Server: ${GREEN}Enabled${NC}"
        asterisk -rx "http show status" 2>/dev/null | head -10
    else
        echo -e "HTTP Server: ${RED}Disabled${NC}"
    fi

    echo ""

    # Check provisioning directory
    if [[ -d "$PROVISIONING_DIR" ]]; then
        echo -e "Provisioning Dir: ${GREEN}$PROVISIONING_DIR${NC}"
        echo "Files:"
        ls -lh "$PROVISIONING_DIR" 2>/dev/null | tail -n +2 || echo "  (empty)"
    else
        echo -e "Provisioning Dir: ${RED}Not created${NC}"
    fi

    echo ""

    # Check symlink
    if [[ -L /usr/share/asterisk/static-http ]]; then
        echo -e "Symlink: ${GREEN}OK${NC} (/usr/share/asterisk/static-http)"
    else
        echo -e "Symlink: ${YELLOW}Not created${NC}"
    fi

    echo ""
    local server_ip=$(hostname -I | cut -d' ' -f1)
    echo "Provisioning URLs:"
    echo "  HTTP:  http://${server_ip}:8088/static/"
    echo "  HTTPS: https://${server_ip}:8089/static/"
}

troubleshoot_eos_audio() {
    print_header "/e/OS Audio Troubleshooting"

    cat << 'EOSHELP'
PROBLEM: No audio sent by phone unless Linphone has focus
═══════════════════════════════════════════════════════════

This is a known issue with /e/OS (eFoundation OS) and privacy-focused
Android ROMs. /e/OS has stricter privacy controls that prevent apps
from accessing the microphone in the background.

SOLUTIONS (Try in order):

1. LINPHONE APP SETTINGS (In Linphone app itself):
   ────────────────────────────────────────────────────
   a) Open Linphone → ☰ Menu → Settings → Audio
   b) Change "Audio Route" to "Speaker" (not Earpiece)
   c) Enable "Use Speaker for calls"
   d) Disable "Echo Cancellation" (test if this helps)
   e) Go to Settings → Network
   f) Set "Media Encryption" to "None" (or match server)

2. /e/OS PRIVACY SETTINGS:
   ────────────────────────────────────────────────────
   a) Settings → Apps → Linphone
   b) Permissions → Microphone → "Allow all the time"
   c) Permissions → Camera → "Don't allow" (if not using video)
   d) "Remove permissions if app isn't used" → DISABLE

3. /e/OS ADVANCED PRIVACY SETTINGS:
   ────────────────────────────────────────────────────
   a) Settings → Privacy (Advanced Privacy / Privacy Central)
   b) Find Linphone in the list
   c) Disable "Hide my IP" for Linphone
   d) Set Location to "Real" (not fake location)
   e) Disable any "Manage trackers" restrictions for Linphone

4. /e/OS NETWORK PERMISSIONS:
   ────────────────────────────────────────────────────
   a) Settings → Apps → Linphone → Mobile data & Wi-Fi
   b) Enable "Background data"
   c) Enable "Unrestricted data usage"
   d) Make sure "Allow network access" is ON

5. /e/OS AUTOSTART:
   ────────────────────────────────────────────────────
   a) Settings → Apps → Linphone → Battery
   b) Battery optimization → "Don't optimize" or "Unrestricted"
   c) Settings → Apps → Linphone → Advanced
   d) Enable "Autostart" if available

6. LINPHONE XML PROVISIONING (Server-side fix):
   ────────────────────────────────────────────────────
   Your linphone.xml should already have these settings:
   • android_pause_calls_when_audio_focus_lost=0
   • keep_service_alive=1
   • start_at_boot=1
   • audio_route_speaker=1

   To verify, check: $PROVISIONING_DIR/linphone.xml

7. ALTERNATIVE: USE SPEAKER MODE DURING CALL:
   ────────────────────────────────────────────────────
   As a workaround, during an active call:
   • Tap the speaker icon to enable speakerphone
   • This often forces audio to work even in background
   • Not ideal but proves the audio path works

8. NUCLEAR OPTION - DISABLE PRIVACY FEATURES:
   ────────────────────────────────────────────────────
   If nothing works, temporarily disable /e/OS privacy features:
   a) Settings → Privacy → Advanced Privacy
   b) Toggle OFF "Advanced Privacy"
   c) Test if Linphone audio works
   d) If it works, re-enable and whitelist Linphone

9. ALTERNATIVE SIP APP:
   ────────────────────────────────────────────────────
   If Linphone continues to have issues on /e/OS, try:
   • Zoiper (better /e/OS compatibility)
   • CSipSimple (older but reliable)
   • Grandstream Wave (commercial but works well)

TESTING:
════════
1. Make a call with Linphone in foreground → audio works
2. Press Home button → does audio continue?
3. If audio stops, the issue is confirmed

WHAT'S HAPPENING:
═════════════════
/e/OS restricts background microphone access for privacy.
Even with permissions granted, the OS may suspend audio
capture when the app loses focus. The XML settings and
speaker mode help work around this limitation.

MORE HELP:
══════════
• /e/OS Community: https://community.e.foundation
• Linphone Forums: https://forum.linphone.org
• Issue: "Background microphone access on /e/OS"

═══════════════════════════════════════════════════════════
EOSHELP
}

create_baresip_config() {
    print_header "Create Baresip Setup Instructions"
    load_config

    local server_ip=$(hostname -I | cut -d' ' -f1)
    local domain="${DOMAIN_NAME:-$server_ip}"

    echo "Baresip Setup Guide Generator"
    echo "================================================"
    echo ""
    echo "Use Baresip if Linphone has audio issues (screen off, etc.)"
    echo "Baresip often works better on privacy-focused Android ROMs."
    echo ""
    echo "NOTE: Baresip does NOT support remote provisioning."
    echo "      Manual configuration required."
    echo ""
    echo "Current Configuration:"
    echo "  Domain:    $domain"
    echo "  Server IP: $server_ip"
    echo ""

    read -p "Enter extension number (e.g., 202): " extension
    [[ -z "$extension" ]] && { print_error "Extension required"; return 1; }

    read -p "Enter SIP password: " sip_password
    [[ -z "$sip_password" ]] && { print_error "Password required"; return 1; }

    read -p "Enter display name (e.g., Kitchen Phone): " display_name
    display_name=${display_name:-Extension $extension}

    local config_file="$PROVISIONING_DIR/baresip-${extension}.txt"

    mkdir -p "$PROVISIONING_DIR"

    cat > "$config_file" << BARESIPEOF
═══════════════════════════════════════════════════════════
BARESIP SETUP INSTRUCTIONS
Generated by Easy Asterisk v${SCRIPT_VERSION}
═══════════════════════════════════════════════════════════

IMPORTANT: Baresip does NOT support remote provisioning.
You must configure manually following these steps.

STEP 1: INSTALL BARESIP
════════════════════════════════════════════════════════════
• Download Baresip from F-Droid or Play Store
• Open the Baresip app

STEP 2: ADD ACCOUNT (Initial Entry)
════════════════════════════════════════════════════════════
1. Tap Menu (☰ hamburger icon) → Accounts
2. Tap the Add (+) button at the top
3. In "SIP URI" field, enter: BARESIPEOF
    echo "${extension}@${domain}" >> "$config_file"
    cat >> "$config_file" << 'BARESIPEOF'
4. Tap the Save (✓ checkmark) icon at the top

STEP 3: EDIT ACCOUNT (Complete Configuration)
════════════════════════════════════════════════════════════
Now go back and edit the account to add authentication:

1. Tap Menu (☰) → Accounts
2. Tap on the account you just created
3. Fill in the following fields:

BARESIPEOF
    cat >> "$config_file" << EOF
   Display Name: ${display_name}

   Authentication Username: ${extension}
   (CRITICAL: Just the extension number, NOT ${extension}@${domain})

   Authentication Password: ${sip_password}

   Outbound Proxy URI: ${domain}
   (CRITICAL: Just the domain, NOT sip:${server_ip}:5060)

   Media Encryption: srtp
   (Select from dropdown menu)

   Register: ✓ (Check this box)

4. Tap Save (✓ checkmark icon)

STEP 4: VERIFY REGISTRATION
════════════════════════════════════════════════════════════
• Wait a few seconds for registration
• You should see:
  - Green dot next to account, OR
  - "Registered" status text

If registration FAILS:
  ✗ Double-check "Authentication Username" is JUST "${extension}"
  ✗ Double-check "Outbound Proxy URI" is JUST "${domain}"
  ✗ Verify password is correct: ${sip_password}

STEP 5: SET CALLING AS DEFAULT (Optional)
════════════════════════════════════════════════════════════
To make tapping a contact initiate a call (not message):

1. Tap Menu (☰) → Settings (or Preferences)
2. Look for "Default Action" or "Contact Action"
3. If available, select: "Audio Call" or "Call"
4. Save

NOTE: This option may not exist in all Baresip versions.
      If not available, you can still call by:
      - Long-pressing a contact → Select "Call"
      - Or using the phone icon during selection

STEP 6: AUDIO SETTINGS (Recommended)
════════════════════════════════════════════════════════════
1. Tap Menu (☰) → Settings → Audio
2. Configure:
   Audio Module: opensles (or audiotrack if opensles doesn't work)
   Echo Cancellation: ✓ Enabled
   Noise Suppression: ✓ Enabled

STEP 7: ANDROID PERMISSIONS
════════════════════════════════════════════════════════════
Go to your phone's:
Settings → Apps → Baresip

Set the following:
• Permissions → Microphone: Allow while using app
• Permissions → Phone: Allow
• Battery: Unrestricted (or Not optimized)
• Mobile data & Wi-Fi → Background data: Enabled

DIALING EXTENSIONS
════════════════════════════════════════════════════════════
To call other extensions:

Method 1 (Try this first):
  Just dial the extension number: 101, 202, etc.

Method 2 (If method 1 doesn't work):
  Full format: 101@${domain}

Common Extensions:
• Individual devices: 101, 102, 201, 202, etc.
• Page groups (auto-answer broadcast): 199
• Ring groups (rings all phones): 299

TOP BAR ICONS IN BARESIP
════════════════════════════════════════════════════════════
☰ = Hamburger menu (Accounts, Settings, About, etc.)
✓ = Save/Confirm current action
⋮ = Additional options (context-dependent)
📞 = Answer incoming call / Place outgoing call
🔊 = Enable speakerphone (during active call)
🔇 = Mute microphone (during active call)
✕ = Hang up / End call

TROUBLESHOOTING
════════════════════════════════════════════════════════════

PROBLEM: Registration fails
SOLUTION:
  • Verify "Authentication Username" is JUST: ${extension}
  • Verify "Outbound Proxy URI" is JUST: ${domain}
  • Check password is correct
  • Check phone has network connectivity
  • Check firewall allows SIP traffic

PROBLEM: Can't dial extensions
SOLUTION:
  • Verify you're registered (green dot/status)
  • Try dialing full format: ${extension}@${domain}
  • Check extension exists on server

PROBLEM: No audio / Audio doesn't work
SOLUTION:
  • Menu → Settings → Audio → Try different "Audio Module"
  • Check microphone permissions in Android settings
  • During call, try tapping speaker icon

PROBLEM: Audio cuts when screen turns off
SOLUTION:
  • Settings → Apps → Baresip → Battery → Unrestricted
  • Baresip handles this much better than Linphone!
  • This issue is rare with Baresip

PROBLEM: Can't find "Default Action" setting
SOLUTION:
  • Not all Baresip versions have this option
  • Alternative: Long-press contact → Select "Call"
  • Or tap contact then tap phone icon

═══════════════════════════════════════════════════════════
QUICK REFERENCE
═══════════════════════════════════════════════════════════
Display Name: ${display_name}
SIP URI (initial): ${extension}@${domain}
Auth Username: ${extension}
Auth Password: ${sip_password}
Outbound Proxy: ${domain}
Media Encryption: srtp
Register: ✓
═══════════════════════════════════════════════════════════

EOF

    chown asterisk:asterisk "$config_file"
    chmod 644 "$config_file"

    print_success "Created: $config_file"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "BARESIP SETUP - Extension ${extension}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "Download instructions:"
    echo "  http://${server_ip}:8088/static/baresip-${extension}.txt"
    echo ""
    echo "QUICK SETUP SUMMARY:"
    echo ""
    echo "Step 1: Add Account"
    echo "  Menu → Accounts → Add (+)"
    echo "  SIP URI: ${extension}@${domain}"
    echo "  Save (✓)"
    echo ""
    echo "Step 2: Edit Account"
    echo "  Tap account → Edit"
    echo "  Auth Username: ${extension} (JUST the number!)"
    echo "  Auth Password: ${sip_password}"
    echo "  Outbound Proxy: ${domain} (JUST the domain!)"
    echo "  Media Encryption: srtp (select from dropdown)"
    echo "  Register: ✓"
    echo "  Save (✓)"
    echo ""
    echo "Step 3: Verify"
    echo "  Look for green dot or 'Registered' status"
    echo ""
    echo "Step 4: Dial Extensions"
    echo "  Just dial: 101, 202, etc."
    echo ""
    echo "Full details in the text file above."
    echo "═══════════════════════════════════════════════════════════"
}

provisioning_manager_menu() {
    while true; do
        clear
        print_header "Provisioning Manager"
        echo "  1) Setup HTTP Server (ports 8088/8089)"
        echo "  2) Create/Update linphone.xml"
        echo "  3) Edit linphone.xml"
        echo "  4) Create Baresip Config"
        echo "  5) Show Status"
        echo "  6) Open Provisioning Directory"
        echo "  7) Troubleshoot /e/OS Audio Issues"
        echo "  0) Back"
        read -p "  Select: " choice

        case $choice in
            1) setup_http_provisioning ;;
            2) create_linphone_xml ;;
            3) edit_linphone_xml ;;
            4) create_baresip_config ;;
            5) show_provisioning_status ;;
            6)
                if command -v mc &>/dev/null; then
                    mc "$PROVISIONING_DIR"
                else
                    print_info "Opening with ls..."
                    ls -lah "$PROVISIONING_DIR"
                fi
                ;;
            7) troubleshoot_eos_audio ;;
            0) return ;;
        esac

        [[ "$choice" != "0" ]] && read -p "Press Enter..."
    done
}

# ================================================================
# MANUAL UPDATE SYSTEM
# ================================================================

manual_update_asterisk() {
    if is_docker; then
        print_header "Update Asterisk (Docker)"
        echo "  In Docker, Asterisk is updated by rebuilding the container image."
        echo ""
        echo "  Steps:"
        echo "    1. docker compose down"
        echo "    2. docker compose build --no-cache"
        echo "    3. docker compose up -d"
        echo ""
        echo "  Your configuration is preserved in Docker volumes."
        echo "  Current version:"
        asterisk -V 2>/dev/null || echo "  Asterisk not running"
        return
    fi

    print_header "Manual Asterisk Update"
    echo "WARNING: This will update Asterisk from the repository."
    echo "A backup will be created automatically."
    echo ""
    asterisk -V 2>/dev/null || echo "Asterisk not currently running"
    echo ""
    read -p "Continue with update? (y/n) [n]: " confirm
    confirm=${confirm:-n}

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        return
    fi

    # Backup configurations
    local backup_dir="/root/asterisk-backup-$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo "Creating backup in $backup_dir..."
    cp -r /etc/asterisk "$backup_dir/"
    cp -r /var/lib/asterisk "$backup_dir/" 2>/dev/null || true

    print_success "Backup created: $backup_dir"

    # Update
    echo ""
    print_info "Updating Asterisk..."
    apt update
    apt install --only-upgrade asterisk asterisk-modules -y

    # Restart
    echo ""
    restart_asterisk_safe

    if asterisk_running; then
        print_success "Asterisk updated successfully"
        asterisk -V
        echo ""
        echo "Backup location: $backup_dir"
        echo ""
        echo "To rollback if needed:"
        echo "  systemctl stop asterisk"
        echo "  cp -r $backup_dir/asterisk/* /etc/asterisk/"
        echo "  systemctl start asterisk"
    else
        print_error "Asterisk failed to start after update!"
        echo ""
        echo "Rolling back..."
        cp -r "$backup_dir/asterisk/"* /etc/asterisk/
        restart_asterisk_safe
        print_info "Rollback complete"
    fi
}

# ================================================================
# ROOM DIRECTORY
# ================================================================

show_room_directory() {
    print_header "Room Directory"
    load_config

    if [[ ! -f "$ROOMS_FILE" ]]; then
        print_error "Rooms file not found: $ROOMS_FILE"
        return
    fi

    echo "Ring Groups vs Page Groups:"
    echo "  • Ring Groups: Rings all members until one answers"
    echo "  • Page Groups: Auto-answer broadcast to all members"
    echo ""
    echo "═══════════════════════════════════════════════════════════"

    local has_rooms=false
    while IFS='|' read -r ext name members timeout type; do
        # Skip comments and empty lines
        [[ "$ext" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$ext" ]] && continue

        has_rooms=true

        # Determine icon based on type
        local icon="📞"
        local type_label="Ring Group"
        if [[ "$type" == "page" ]]; then
            icon="📢"
            type_label="Page Group"
        fi

        echo ""
        echo "$icon Extension: $ext - $name"
        echo "   Type: $type_label"
        echo "   Members: $members"
        echo "   Timeout: ${timeout}s"
    done < "$ROOMS_FILE"

    if [[ "$has_rooms" == "false" ]]; then
        echo ""
        echo "No rooms configured yet."
        echo "Use 'Device Management → Manage rooms' to create rooms."
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"
}

watch_live_logs() {
    print_header "Live Debugging"
    echo "Enabling PJSIP Logger..."
    asterisk -rx "module load res_pjsip_logger.so" 2>/dev/null || true
    asterisk -rx "pjsip set logger on" 2>/dev/null
    echo ""
    echo "Options:"
    echo "  1) Asterisk Console (verbose)"
    echo "  2) Packet Capture (tcpdump)"
    read -p "Select [1]: " pcap
    if [[ "$pcap" == "2" ]]; then
        echo "Starting tcpdump. Press CTRL+C to stop."
        tcpdump -i any port 5060 or port 5061 -nn -v
    else
        echo "Starting Console. Press CTRL+C to exit."
        asterisk -rvvv
    fi
    asterisk -rx "pjsip set logger off" 2>/dev/null
}

router_doctor() {
    print_header "Router Traffic Doctor"
    if ! asterisk_running; then
        print_error "Asterisk is NOT RUNNING"
        restart_asterisk_safe
        return
    fi
    
    print_success "Asterisk is UP"
    echo ""
    echo "Server Listening IPs:"
    ip -o -4 addr show | awk '{print "  " $2 ": " $4}'
    echo ""
    echo "Instructions:"
    echo "  1. Take out your phone/laptop"
    echo "  2. Attempt to REGISTER or CALL"
    echo "  3. I will listen for 15 seconds"
    echo ""
    read -p "Press Enter to start listening..."
    
    if timeout 15 tcpdump -i any -c 1 "port 5060 or port 5061" 2>/dev/null; then
        echo ""
        print_success "PACKET RECEIVED! Router forwarding is working."
    else
        echo ""
        print_error "NO PACKETS RECEIVED."
        echo "Your router or firewall is blocking the connection."
    fi
}

configure_local_client() {
    if is_docker; then
        print_error "Local client not available in Docker. Use Sipnetic, Linphone, or Baresip on your phone/tablet."
        return
    fi
    print_header "Configure Local Client"
    load_config

    # If KIOSK_USER already set from config, show and ask if want to change
    if [[ -n "$KIOSK_USER" ]]; then
        echo "Current configured user: $KIOSK_USER"
        read -p "Change user? [y/N]: " change_user
        if [[ "$change_user" =~ ^[Yy]$ ]]; then
            KIOSK_USER=""
            KIOSK_UID=""
        fi
    fi

    # If still no user, select one
    if [[ -z "$KIOSK_USER" ]]; then
        echo ""
        echo "Select the user to configure:"
        echo ""
        if ! select_user; then
            print_error "User selection failed"
            return 1
        fi
    else
        # Ensure KIOSK_UID is set
        KIOSK_UID=$(id -u "$KIOSK_USER" 2>/dev/null)
    fi

    echo ""

    if [[ ! -d "/home/${KIOSK_USER}/.baresip" ]]; then
        print_error "Baresip not installed for $KIOSK_USER"
        echo ""
        read -p "Install Baresip client now? [Y/n]: " install_it
        if [[ ! "$install_it" =~ ^[Nn]$ ]]; then
            install_baresip_packages
            configure_baresip
            enable_client_services
            INSTALLED_CLIENT="y"
            save_config
            print_success "Baresip installed"
            echo ""
            echo "Audio configured for $KIOSK_USER"
            echo "If audio doesn't work, log out and back in or reboot."
            echo ""
        else
            return
        fi
    fi
    
    read -p "Extension: " ext
    read -p "Password: " pass
    read -p "Server Domain/IP: " server
    
    local transport_str="udp"
    local media_enc=""
    
    if [[ "$server" =~ [a-zA-Z] ]]; then 
        print_info "Domain detected. Using TLS."
        transport_str="tls"
        media_enc=";mediaenc=srtp"
    fi
    
    echo ""
    echo "Answer Mode:"
    echo "  1) Manual (ring on incoming)"
    echo "  2) Auto (auto-answer)"
    read -p "Select [1]: " amode
    local answermode="manual"
    [[ "$amode" == "2" ]] && answermode="auto"
    
    echo ""
    echo "Enable TURN? (Required if behind NAT/VLAN without VPN)"
    read -p "Use TURN server? [y/N]: " use_turn
    local turn_config=""
    if [[ "$use_turn" =~ ^[Yy]$ ]]; then
        read -p "TURN User [${TURN_USER}]: " t_user
        t_user="${t_user:-$TURN_USER}"
        read -p "TURN Pass [${TURN_PASS}]: " t_pass
        t_pass="${t_pass:-$TURN_PASS}"
        local turn_host="${server}"
        if [[ ! "$turn_host" =~ [a-zA-Z] ]]; then
             # If server is IP, ask if TURN host is different
             read -p "TURN Host [${server}]: " th
             turn_host="${th:-$server}"
        fi
        read -p "TURN Port [3478]: " t_port
        t_port="${t_port:-3478}"
        turn_config="turn_server turn:${t_user}:${t_pass}@${turn_host}:${t_port}"
    fi
    
    # Update config file for TURN
    local conf_file="/home/${KIOSK_USER}/.baresip/config"
    if [[ -f "$conf_file" ]]; then
        sed -i '/^turn_server/d' "$conf_file"
        if [[ -n "$turn_config" ]]; then
            echo "$turn_config" >> "$conf_file"
            print_success "TURN configuration added"
        fi
    fi
    
    cat > "/home/${KIOSK_USER}/.baresip/accounts" << EOF
<sip:${ext}@${server};transport=${transport_str}>;auth_pass=${pass};answermode=${answermode}${media_enc}
EOF
    chown ${KIOSK_USER}:${KIOSK_USER} "/home/${KIOSK_USER}/.baresip/accounts"
    chown ${KIOSK_USER}:${KIOSK_USER} "/home/${KIOSK_USER}/.baresip/config"

    # Update main config
    ASTERISK_HOST="$server"
    KIOSK_EXTENSION="$ext"
    CLIENT_ANSWERMODE="$answermode"
    save_config

    local user_dbus="XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}"

    # Reload systemd daemon in case services changed
    sudo -u "${KIOSK_USER}" $user_dbus systemctl --user daemon-reload 2>/dev/null

    # Restart audio and client services
    print_info "Restarting services..."
    sudo -u "${KIOSK_USER}" $user_dbus systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true
    sleep 2
    sudo -u "${KIOSK_USER}" $user_dbus systemctl --user restart baresip 2>/dev/null

    # Ensure audio is unmuted if not in PTT mode
    if [[ ! -f /etc/easy-asterisk/ptt-device ]]; then
        sleep 1
        ensure_audio_unmuted
    fi

    print_success "Client Reconfigured & Services Restarted"
    echo ""
    echo "Run Diagnostics to verify connection status."
}

run_client_diagnostics() {
    if is_docker; then
        print_error "Client diagnostics not available in Docker. Run vpn-diagnostics for server-side checks."
        return
    fi
    print_header "Client Diagnostics"
    load_config
    local t_user="${KIOSK_USER:-$SUDO_USER}"
    t_user="${t_user:-$USER}"
    local t_uid=$(id -u "$t_user" 2>/dev/null)

    echo -e "User: ${BOLD}$t_user${NC}"
    echo "---------------------------------------------------"
    if sudo -u "$t_user" XDG_RUNTIME_DIR=/run/user/$t_uid systemctl --user is-active baresip >/dev/null 2>&1; then
        print_success "Baresip RUNNING"
    else
        print_error "Baresip STOPPED/FAILED"
    fi
    echo "---------------------------------------------------"

    echo "Audio Services:"
    local user_dbus="XDG_RUNTIME_DIR=/run/user/$t_uid"
    if sudo -u "$t_user" $user_dbus systemctl --user is-active pipewire >/dev/null 2>&1; then
        print_success "PipeWire RUNNING"
    else
        print_error "PipeWire STOPPED"
    fi
    if sudo -u "$t_user" $user_dbus systemctl --user is-active pipewire-pulse >/dev/null 2>&1; then
        print_success "PipeWire-Pulse RUNNING"
    else
        print_error "PipeWire-Pulse STOPPED"
    fi

    echo ""
    echo "Audio Status:"
    local src_mute=$(sudo -u "$t_user" $user_dbus pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null | awk '{print $2}')
    local sink_mute=$(sudo -u "$t_user" $user_dbus pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')
    local src_vol=$(sudo -u "$t_user" $user_dbus pactl get-source-volume @DEFAULT_SOURCE@ 2>/dev/null | grep -oP '\d+%' | head -1)
    local sink_vol=$(sudo -u "$t_user" $user_dbus pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+%' | head -1)

    echo "  Microphone: ${src_mute:-unknown} (Volume: ${src_vol:-unknown})"
    echo "  Speaker:    ${sink_mute:-unknown} (Volume: ${sink_vol:-unknown})"

    if [[ "$src_mute" == "yes" ]]; then
        echo ""
        print_error "MICROPHONE IS MUTED - No audio will be sent!"
        echo "  To fix: pactl set-source-mute @DEFAULT_SOURCE@ 0"
    fi

    echo ""
    echo "PTT Configuration:"
    if [[ -f /etc/easy-asterisk/ptt-device ]]; then
        echo "  PTT Mode: ENABLED"
        source /etc/easy-asterisk/ptt-device 2>/dev/null
        echo "  Device: ${PTT_DEVICE:-not set}"
    else
        echo "  PTT Mode: DISABLED (normal intercom mode)"
    fi

    echo "---------------------------------------------------"
    
    echo "Network Interface:"
    grep "^net_interface" "/home/$t_user/.baresip/config" 2>/dev/null || echo "  Not set"
    
    echo "---------------------------------------------------"
    echo "Account Config:"
    cat "/home/$t_user/.baresip/accounts" 2>/dev/null | sed 's/auth_pass=[^;]*/auth_pass=***/' || echo "  Not found"
    
    echo "---------------------------------------------------"
    if [[ -n "$ASTERISK_HOST" ]]; then
        echo -n "Server ($ASTERISK_HOST): "
        if ping -c 1 -W 2 "$ASTERISK_HOST" >/dev/null 2>&1; then
            print_success "Reachable"
        else
            print_error "Unreachable"
        fi
    fi
    echo "---------------------------------------------------"
    echo "System Logs (launcher):"
    journalctl -t baresip-launcher -n 10 --no-pager 2>/dev/null | tail -10 || echo "  No launcher logs"
    echo ""
    echo "System Logs (PTT):"
    journalctl -t kiosk-ptt -n 5 --no-pager 2>/dev/null | tail -5 || echo "  No PTT logs"
    echo ""
    echo "Baresip Service Log:"
    sudo -u "$t_user" journalctl --user -u baresip -n 10 --no-pager 2>/dev/null || echo "  No logs"
    echo "---------------------------------------------------"
    echo ""
    echo "To see live logs, run:"
    echo "  journalctl -t baresip-launcher -f  # Launcher logs"
    echo "  journalctl -t kiosk-ptt -f         # PTT logs"
    echo "  sudo -u $t_user journalctl --user -u baresip -f  # Baresip logs"
    echo "---------------------------------------------------"
}

run_audio_test() {
    print_header "Audio Test"
    echo "Playing test tone..."
    speaker-test -t sine -f 440 -c 2 -l 1 >/dev/null 2>&1
    echo ""
    read -p "Did you hear audio? [y/N]: " res
    if [[ "$res" =~ ^[Yy]$ ]]; then
        print_success "Audio OK"
    else
        print_error "Check volume/connections"
    fi
}

verify_audio_setup() {
    print_header "Audio Verification"
    echo "=== Codecs ==="
    asterisk -rx "core show codecs" 2>/dev/null | grep -E "(opus|ulaw|alaw|g722)" || echo "  N/A"
    echo ""
    echo "=== PJSIP Modules ==="
    asterisk -rx "module show like pjsip" 2>/dev/null | head -10 || echo "  N/A"
    echo ""
    echo "=== Certificate ==="
    if [[ -f /etc/asterisk/certs/server.crt ]]; then
        openssl x509 -in /etc/asterisk/certs/server.crt -noout -subject -dates 2>/dev/null
    else
        echo "  None"
    fi
}

# ================================================================
# 7. ASTERISK CONFIG
# ================================================================

fix_asterisk_systemd() {
    if is_docker; then
        # No systemd in Docker - Asterisk runs as the main container process
        return
    fi
    print_info "Configuring systemd..."
    mkdir -p /etc/systemd/system/asterisk.service.d/
    cat > /etc/systemd/system/asterisk.service.d/override.conf << 'SVCEOF'
[Unit]
Wants=network-online.target
After=network-online.target

[Service]
ExecStart=
ExecStart=/usr/sbin/asterisk -f -U asterisk -G asterisk
RuntimeDirectory=asterisk
RuntimeDirectoryMode=0750
MemoryMax=infinity
TasksMax=infinity
KillMode=mixed
KillSignal=SIGTERM
TimeoutStartSec=60
TimeoutStopSec=30
SendSIGKILL=no
Restart=always
RestartSec=10
Type=simple
SVCEOF
    systemctl daemon-reload
}

recover_xml_docs() {
    mkdir -p /var/lib/asterisk/documentation/thirdparty
    chown -R asterisk:asterisk /var/lib/asterisk/documentation 2>/dev/null
}

repair_core_configs() {
    print_info "Repairing configs..."
    
    # Copy modules (not symlink - AppArmor blocks symlinks)
    if [[ -d "/usr/lib/x86_64-linux-gnu/asterisk/modules" ]]; then
        mkdir -p /usr/lib/asterisk/modules
        cp -rn /usr/lib/x86_64-linux-gnu/asterisk/modules/* /usr/lib/asterisk/modules/ 2>/dev/null || true
    fi

    mkdir -p /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk
    recover_xml_docs
    
    if [[ ! -f /etc/asterisk/asterisk.conf ]]; then
        cat > /etc/asterisk/asterisk.conf << EOF
[directories]
astetcdir => /etc/asterisk
astmoddir => /usr/lib/asterisk/modules
astvarlibdir => /var/lib/asterisk
astdbdir => /var/lib/asterisk
astkeydir => /var/lib/asterisk
astdatadir => /var/lib/asterisk
astagidir => /var/lib/asterisk/agi-bin
astspooldir => /var/spool/asterisk
astrundir => /var/run/asterisk
astlogdir => /var/log/asterisk
EOF
    fi

    cat > /etc/asterisk/modules.conf << EOF
[modules]
autoload=yes
noload => chan_sip.so
noload => chan_iax2.so
load => res_pjsip.so
load => res_pjsip_session.so
load => res_pjsip_logger.so
load => chan_pjsip.so
load => codec_ulaw.so
load => codec_alaw.so
load => codec_g722.so
load => codec_opus.so
load => res_rtp_asterisk.so
load => app_dial.so
load => app_page.so
load => pbx_config.so
EOF

    # Disable optional modules (NOT stasis - required in Asterisk 20.x)
    for conf in ari http manager geolocation; do
        cat > "/etc/asterisk/${conf}.conf" << EOF
[general]
enabled = no
EOF
    done

    # Configure Stasis properly (required core module)
    cat > /etc/asterisk/stasis.conf << EOF
[general]
; Stasis is required for Asterisk 20.x core functionality
EOF
    
    if [[ ! -f /etc/asterisk/sorcery.conf ]]; then
        cat > /etc/asterisk/sorcery.conf << EOF
[res_pjsip]
endpoint=config,pjsip.conf,criteria=type=endpoint
auth=config,pjsip.conf,criteria=type=auth
aor=config,pjsip.conf,criteria=type=aor
transport=config,pjsip.conf,criteria=type=transport
EOF
    fi

    # ICE configuration
    # ICE is enabled so Asterisk participates in ICE negotiation with clients.
    # stunaddr/turnaddr are NOT set because:
    #   - Asterisk knows its public IP via external_media_address in pjsip.conf
    #   - Its RTP ports are port-forwarded, so host candidates are sufficient
    #   - Setting stunaddr/turnaddr causes STUN/TURN gather timeouts (~27s delay)
    # coturn (if running) is for SIP clients behind strict NAT — they configure
    # TURN in their own app settings, independently of Asterisk's rtp.conf.
    load_config
    local ice_config=""
    if [[ -n "$DOMAIN_NAME" ]] || [[ "$VPN_ICE_ENABLED" == "y" ]] || [[ "$TURN_ENABLED" == "y" ]]; then
        ice_config="icesupport=yes"
    else
        ice_config="# icesupport disabled - LAN only mode"
    fi

    cat > /etc/asterisk/rtp.conf << EOF
[general]
rtpstart=${RTP_START:-10000}
rtpend=${RTP_END:-20000}
strictrtp=yes
${ice_config}
EOF
    
    cat > /etc/asterisk/logger.conf << EOF
[general]
[logfiles]
console => notice,warning,error
EOF

    rm -f /var/lib/asterisk/.asterisk_history
    chown -R asterisk:asterisk /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk 2>/dev/null || true
    chown -R asterisk:asterisk /usr/lib/asterisk/modules 2>/dev/null || true
}

generate_pjsip_conf() {
    print_info "Generating PJSIP..."
    load_config
    local conf_file="/etc/asterisk/pjsip.conf"
    backup_config "$conf_file"
    
    # Prioritize CURRENT_PUBLIC_IP from coturn/updater if available, else detect
    local public_ip="${CURRENT_PUBLIC_IP}"
    if [[ -z "$public_ip" ]]; then
        public_ip=$(curl -s -4 --connect-timeout 5 ifconfig.me 2>/dev/null || echo "")
    fi
    
    # Get server IP for transport binding info
    local server_ip=$(hostname -I | cut -d' ' -f1)

    local raw_cidr=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    local default_cidr="$raw_cidr"
    if [[ "$raw_cidr" =~ \.([0-9]+)/24$ ]]; then default_cidr="${raw_cidr%.*}.0/24"; fi

    # Use stored CIDR if available
    local local_net="${LOCAL_CIDR:-$default_cidr}"

    # Build local_net entries (main network + VLANs)
    local all_local_nets="local_net=$local_net"
    if [[ "$HAS_VLANS" == "y" && -n "$VLAN_SUBNETS" ]]; then
        for vlan_subnet in $VLAN_SUBNETS; do
            all_local_nets="${all_local_nets}
local_net=${vlan_subnet}"
        done
        print_info "VLAN subnets configured: $VLAN_SUBNETS"
    fi

    local nat_settings=""
    if [[ -n "$public_ip" && -n "$DOMAIN_NAME" ]]; then
        # FQDN mode: full NAT settings with external addresses
        nat_settings="external_media_address=$public_ip
external_signaling_address=$public_ip
${all_local_nets}"
        print_info "NAT: Public IP=$public_ip, Server IP=$server_ip"
    elif [[ "$HAS_VLANS" == "y" && -n "$VLAN_SUBNETS" ]]; then
        # LAN/VPN mode with VLAN/VPN subnets: include local_net entries
        # so Asterisk recognizes VPN traffic as local (prevents VPN devices
        # appearing offline and fixes media routing for VPN-connected mobiles)
        nat_settings="${all_local_nets}"
        print_info "LAN mode with additional subnets: $VLAN_SUBNETS"
    fi

    cat > "$conf_file" << EOF
; Easy Asterisk v${SCRIPT_VERSION}
[global]
type=global
user_agent=EasyAsterisk

[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:${DEFAULT_SIP_PORT}
; Server IP: ${server_ip}
${nat_settings}

[transport-tcp]
type=transport
protocol=tcp
bind=0.0.0.0:${DEFAULT_SIP_PORT}
; Server IP: ${server_ip}
${nat_settings}

[transport-tls]
type=transport
protocol=tls
bind=0.0.0.0:${DEFAULT_SIPS_PORT}
; Server IP: ${server_ip}
cert_file=/etc/asterisk/certs/server.crt
priv_key_file=/etc/asterisk/certs/server.key
ca_list_file=/etc/ssl/certs/ca-certificates.crt
method=tlsv1_2
${nat_settings}

EOF

    local backup_file=$(ls -t "${conf_file}.backup-"* 2>/dev/null | head -1)
    if [[ -f "$backup_file" ]]; then
        awk '/^; === Device:/{flag=1} flag' "$backup_file" >> "$conf_file"
        print_success "Restored devices from backup"
    fi
    chown asterisk:asterisk "$conf_file"
}

rebuild_dialplan() {
    local quiet=$1
    [[ "$quiet" != "quiet" ]] && print_info "Rebuilding dialplan..."
    local conf_file="/etc/asterisk/extensions.conf"
    backup_config "$conf_file"
    
    cat > "$conf_file" << EOF
[general]
static=yes
writeprotect=no
[default]
exten => _X.,1,Hangup()
[intercom]
EOF

    local dev_name="" dev_cat="" dev_auto="" dev_aa_override=""
    local -A device_extensions=()
    while IFS= read -r line; do
        if [[ "$line" == *"; === Device:"* ]]; then
            dev_aa_override=""
            local temp="${line#*; === Device: }"
            temp="${temp% ===}"
            if [[ "$temp" == *"[AA:yes]"* ]]; then
                dev_aa_override="yes"; temp="${temp% [AA:yes]}"
            elif [[ "$temp" == *"[AA:no]"* ]]; then
                dev_aa_override="no"; temp="${temp% [AA:no]}"
            fi
            dev_cat="${temp##* (}"; dev_cat="${dev_cat%)}"
            dev_name="${temp% (*)}"
            dev_auto="no"
            local cat_data=$(grep "^${dev_cat}|" "$CATEGORIES_FILE" 2>/dev/null || true)
            if [[ -n "$cat_data" ]]; then
                local is_auto=$(echo "$cat_data" | cut -d'|' -f3)
                [[ "$is_auto" == "yes" ]] && dev_auto="yes"
            fi
            [[ "$dev_aa_override" == "yes" ]] && dev_auto="yes"
            [[ "$dev_aa_override" == "no" ]] && dev_auto="no"
        fi
        if [[ "$line" =~ ^\[([0-9]+)\] ]]; then
            local ext="${BASH_REMATCH[1]}"
            if [[ -n "$dev_name" ]]; then
                device_extensions[$ext]=1
                if [[ "$dev_auto" == "yes" ]]; then
                    cat >> "$conf_file" << EOF
exten => ${ext},1,NoOp(Auto-Answer ${ext})
 same => n,Set(PJSIP_HEADER(add,Call-Info)=\;answer-after=0)
 same => n,Set(PJSIP_HEADER(add,Alert-Info)=auto-answer)
 same => n,Dial(PJSIP/${ext},60)
 same => n,Hangup()

EOF
                else
                    cat >> "$conf_file" << EOF
exten => ${ext},1,NoOp(Call ${ext})
 same => n,Dial(PJSIP/${ext},60)
 same => n,Hangup()

EOF
                fi
                dev_name=""
            fi
        fi
    done < /etc/asterisk/pjsip.conf

    # Add rooms (skip if extension already used by a device)
    if [[ -f "$ROOMS_FILE" ]]; then
        while IFS='|' read -r rext rname rmem rtime rtype; do
            [[ "$rext" =~ ^# ]] && continue
            [[ -z "$rext" ]] && continue
            if [[ -n "${device_extensions[$rext]:-}" ]]; then
                [[ "$quiet" != "quiet" ]] && print_warn "Room '$rname' ext $rext conflicts with device — skipping"
                continue
            fi
            local dial_list=""
            IFS=',' read -ra EXTS <<< "$rmem"
            for ext in "${EXTS[@]}"; do
                ext=$(echo "$ext" | tr -d ' ')
                [[ -n "$dial_list" ]] && dial_list="${dial_list}&"
                dial_list="${dial_list}PJSIP/${ext}"
            done
            if [[ "$rtype" == "page" ]]; then
                cat >> "$conf_file" << EOF
; Room: ${rname} (Page)
exten => ${rext},1,NoOp(Page ${rname})
 same => n,Set(PJSIP_HEADER(add,Call-Info)=\;answer-after=0)
 same => n,Page(${dial_list},i,${rtime})
 same => n,Hangup()

EOF
            else
                cat >> "$conf_file" << EOF
; Room: ${rname} (Ring)
exten => ${rext},1,NoOp(Call ${rname})
 same => n,Dial(${dial_list},${rtime})
 same => n,Hangup()

EOF
            fi
        done < "$ROOMS_FILE"
    fi
    
    chown -R asterisk:asterisk /etc/asterisk
    asterisk -rx "dialplan reload" &>/dev/null || true
}

configure_asterisk() {
    if ! id asterisk >/dev/null 2>&1; then
        useradd -r -s /bin/false -d /var/lib/asterisk asterisk 2>/dev/null || true
    fi

    print_info "Configuring Asterisk..."
    fix_asterisk_systemd
    initialize_default_categories
    repair_core_configs
    
    mkdir -p /etc/asterisk/certs
    if [[ ! -f /etc/asterisk/certs/server.crt ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout /etc/asterisk/certs/server.key \
            -out /etc/asterisk/certs/server.crt \
            -subj "/CN=asterisk-local" 2>/dev/null
    fi
    
    chown asterisk:asterisk /etc/asterisk/certs/server.* 2>/dev/null || true
    chmod 644 /etc/asterisk/certs/server.crt 2>/dev/null || true
    chmod 600 /etc/asterisk/certs/server.key 2>/dev/null || true
    
    generate_pjsip_conf
    rebuild_dialplan "quiet"
    
    restart_asterisk_safe
    if ! is_docker; then
        systemctl enable asterisk
    fi
}

# ================================================================
# 8. CLIENT CONFIG
# ================================================================

configure_baresip() {
    if is_docker; then return; fi
    local baresip_dir="/home/${KIOSK_USER}/.baresip"
    mkdir -p "$baresip_dir"
    
    # Detect network interface
    local found_iface=""
    for target in 8.8.8.8 1.1.1.1 9.9.9.9; do
        local iface=$(ip route get "$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1)
        if [[ -n "$iface" ]]; then
            found_iface="$iface"
            print_success "Network interface: $found_iface"
            break
        fi
    done

    cat > "${baresip_dir}/config" << EOF
poll_method epoll
audio_player pulse
audio_source pulse
audio_alert pulse
sip_autoanswer yes
sip_cafile /etc/ssl/certs/ca-certificates.crt
rtp_timeout 0
net_af ipv4
module_path /usr/lib/baresip/modules
module srtp.so
module stdio.so
module pulse.so
module g711.so
module opus.so
module account.so
module stun.so
module ice.so
module turn.so
EOF

    [[ -n "$found_iface" ]] && echo "net_interface $found_iface" >> "${baresip_dir}/config"
    
    local transport="udp"
    local mediaenc=""
    if [[ "$ENABLE_TLS" == "y" ]]; then 
        transport="tls"
        mediaenc=";mediaenc=srtp"
    fi
    
    local amode="${CLIENT_ANSWERMODE:-auto}"
    
    cat > "${baresip_dir}/accounts" << EOF
<sip:${KIOSK_EXTENSION}@${ASTERISK_HOST};transport=${transport}>;auth_pass=${SIP_PASSWORD};answermode=${amode}${mediaenc}
EOF
    chown -R ${KIOSK_USER}:${KIOSK_USER} "$baresip_dir"
    chmod 700 "$baresip_dir"
    
    configure_audio_ducking
    create_ptt_handler
    create_baresip_launcher
}

create_baresip_launcher() {
    local launcher_user="${KIOSK_USER}"
    cat > /usr/local/bin/easy-asterisk-launcher << LAUNCHER
#!/bin/bash
CONFIG_FILE="/home/${launcher_user}/.baresip/config"
ACCOUNTS_FILE="/home/${launcher_user}/.baresip/accounts"
TARGETS=("8.8.8.8" "1.1.1.1" "9.9.9.9")
FOUND_IFACE=""

logger -t baresip-launcher "Starting Baresip launcher for user ${launcher_user}"

# Wait for network
for i in {1..6}; do
    for target in "\${TARGETS[@]}"; do
        IFACE=\$(ip route get "\$target" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i=="dev") print \$(i+1)}' | head -1)
        if [[ -n "\$IFACE" ]]; then
            FOUND_IFACE="\$IFACE"
            logger -t baresip-launcher "Network found on interface: \$IFACE"
            break 2
        fi
    done
    logger -t baresip-launcher "Waiting for network... (attempt \$i/6)"
    sleep 5
done

if [[ -z "\$FOUND_IFACE" ]]; then
    logger -t baresip-launcher "ERROR: No network interface found after 30 seconds"
fi

# Update network interface in config
if [[ -f "\$CONFIG_FILE" && -n "\$FOUND_IFACE" ]]; then
    sed -i '/^#*net_interface/d' "\$CONFIG_FILE"
    echo "net_interface \${FOUND_IFACE}" >> "\$CONFIG_FILE"
    logger -t baresip-launcher "Updated config with interface: \$FOUND_IFACE"
fi

# Verify config files exist
if [[ ! -f "\$CONFIG_FILE" ]]; then
    logger -t baresip-launcher "ERROR: Config file not found: \$CONFIG_FILE"
    exit 1
fi

if [[ ! -f "\$ACCOUNTS_FILE" ]]; then
    logger -t baresip-launcher "ERROR: Accounts file not found: \$ACCOUNTS_FILE"
    exit 1
fi

logger -t baresip-launcher "Starting Baresip client..."
exec /usr/bin/baresip -f "/home/${launcher_user}/.baresip"
LAUNCHER
    chmod +x /usr/local/bin/easy-asterisk-launcher
}

enable_client_services() {
    if is_docker; then
        # No local audio client in Docker containers
        return
    fi
    local systemd_dir="/home/${KIOSK_USER}/.config/systemd/user"
    mkdir -p "$systemd_dir"

    # Ensure audio group membership
    if ! id -nG "$KIOSK_USER" | grep -qw "audio"; then
        usermod -aG audio "$KIOSK_USER"
    fi

    # Ensure input group membership (for PTT device access)
    if ! id -nG "$KIOSK_USER" | grep -qw "input"; then
        usermod -aG input "$KIOSK_USER"
    fi

    # Baresip service
    cat > "${systemd_dir}/baresip.service" << EOF
[Unit]
Description=Baresip SIP Client
After=pipewire.service pipewire-pulse.service network-online.target
Wants=network-online.target pipewire.service pipewire-pulse.service
Requires=pipewire-pulse.service

[Service]
Type=simple
ExecStartPre=/bin/sleep 5
ExecStart=/usr/local/bin/easy-asterisk-launcher
Restart=always
RestartSec=10
Environment=XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${KIOSK_UID}/bus
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    # PTT service - only create if PTT is configured
    cat > "${systemd_dir}/kiosk-ptt.service" << EOF
[Unit]
Description=PTT Button Handler
After=pipewire.service pipewire-pulse.service baresip.service
Requires=pipewire-pulse.service
ConditionPathExists=/etc/easy-asterisk/ptt-device

[Service]
Type=simple
ExecStartPre=/bin/sleep 8
ExecStart=/usr/local/bin/kiosk-ptt
Restart=always
RestartSec=10
Environment=XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}
Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${KIOSK_UID}/bus
Environment=KIOSK_UID=${KIOSK_UID}
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

    chown -R ${KIOSK_USER}:${KIOSK_USER} "/home/${KIOSK_USER}/.config"

    if [[ -n "$KIOSK_USER" ]]; then
        loginctl enable-linger $KIOSK_USER 2>/dev/null || true
        local user_dbus="XDG_RUNTIME_DIR=/run/user/${KIOSK_UID}"

        # Enable and start PipeWire services for the user
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user daemon-reload
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user enable pipewire pipewire-pulse 2>/dev/null || true
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true

        # Enable baresip
        sudo -u "$KIOSK_USER" $user_dbus systemctl --user enable baresip

        # Only enable PTT if configured
        if [[ -f /etc/easy-asterisk/ptt-device ]]; then
            sudo -u "$KIOSK_USER" $user_dbus systemctl --user enable kiosk-ptt
            sudo -u "$KIOSK_USER" $user_dbus systemctl --user restart baresip kiosk-ptt
        else
            sudo -u "$KIOSK_USER" $user_dbus systemctl --user restart baresip
            # Ensure audio is unmuted for normal kiosk operation
            ensure_audio_unmuted
        fi
    fi
}

# ================================================================
# 9. CERTIFICATE HANDLING
# ================================================================

check_cert_coverage() {
    local cert_file=$1 target_domain=$2 base_domain=$3
    [[ ! -f "$cert_file" ]] && return 1
    local sans=$(openssl x509 -in "$cert_file" -text -noout 2>/dev/null | grep -A1 "Subject Alternative Name" | tail -1)
    echo "$sans" | grep -q "DNS:${target_domain}" && return 0
    echo "$sans" | grep -q "DNS:\*.${base_domain}" && return 0
    return 1
}

setup_caddy_cert_sync() {
    local mode=$1
    [[ "$mode" == "force" ]] && print_header "Caddy Cert Sync"
    
    load_config
    local domain=${DOMAIN_NAME:-sip.example.com}
    if [[ "$mode" == "force" ]]; then
        read -p "Domain [$domain]: " input_domain
        domain="${input_domain:-$domain}"
    fi

    local actual_user="${SUDO_USER:-$USER}"
    local actual_home=$(eval echo ~"$actual_user")
    local base_domain=$(echo "$domain" | awk -F. '{print $(NF-1)"."$NF}')
    
    local search_paths=(
        "${actual_home}/docker/caddy/ssl"
        "${actual_home}/docker/caddy/caddy_data"
        "${actual_home}/docker/caddy/caddy_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
        "/var/lib/caddy"
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
        "/data/caddy"
        "/root/.local/share/caddy/certificates"
    )
    local caddy_cert="" caddy_key=""

    [[ "$mode" == "force" ]] && echo "Searching for certificates..."
    
    for base_path in "${search_paths[@]}"; do
        if ! sudo test -d "$base_path" 2>/dev/null; then continue; fi
        [[ "$mode" == "force" ]] && echo "  Checking: $base_path"
        
        local candidates=$(sudo find "$base_path" -maxdepth 5 -type f \( -name "fullchain.pem" -o -name "*.crt" \) 2>/dev/null)
        
        for cert in $candidates; do
            sudo cp "$cert" /tmp/cert_check.pem 2>/dev/null || continue
            if check_cert_coverage "/tmp/cert_check.pem" "$domain" "$base_domain"; then
                [[ "$mode" == "force" ]] && print_success "Found matching cert: $cert"
                caddy_cert="$cert"
                local dir=$(dirname "$cert")
                local name=$(basename "$cert")
                if [[ "$name" == "fullchain.pem" ]]; then
                    caddy_key="${dir}/privkey.pem"
                else
                    caddy_key=$(echo "$cert" | sed 's/\.crt/\.key/')
                fi
                if sudo test -f "$caddy_key"; then
                    rm -f /tmp/cert_check.pem
                    break 2
                fi
            fi
            rm -f /tmp/cert_check.pem
        done
    done
    
    if [[ -n "$caddy_cert" && -n "$caddy_key" ]]; then
        mkdir -p /etc/asterisk/certs
        sudo cat "$caddy_cert" > /etc/asterisk/certs/server.crt
        sudo cat "$caddy_key" > /etc/asterisk/certs/server.key
        
        chown asterisk:asterisk /etc/asterisk/certs/server.*
        chmod 644 /etc/asterisk/certs/server.crt
        chmod 600 /etc/asterisk/certs/server.key
        
        DOMAIN_NAME="$domain"
        ENABLE_TLS="y"
        ASTERISK_HOST="$domain"
        save_config
        
        generate_pjsip_conf
        restart_asterisk_safe
        
        [[ "$mode" == "force" ]] && print_success "Certificates installed for $domain"
        return 0
    else
        [[ "$mode" == "force" ]] && print_warn "No matching certificates found"
        return 1
    fi
}

setup_internet_access() {
    print_header "Setup Internet Access"
    
    echo "Select Certificate Source:"
    echo "  1) Auto-Sync from Caddy (Docker/Native)"
    echo "  2) Standalone Certbot (Requires Port 80 open)"
    echo "  3) Self-Signed (Internal testing only)"
    echo "  4) Manual Path"
    echo "  0) Cancel"
    read -p "Select: " cert_opt
    
    [[ "$cert_opt" == "0" ]] && return

    # Show port requirements
    show_preflight_check
    show_port_requirements
    echo ""
    read -p "Continue? [Y/n]: " cont
    [[ "$cont" =~ ^[Nn]$ ]] && return

    load_config
    read -p "FQDN [${DOMAIN_NAME:-sip.example.com}]: " fqdn
    DOMAIN_NAME="${fqdn:-${DOMAIN_NAME:-sip.example.com}}"
    ASTERISK_HOST="$DOMAIN_NAME"
    
    echo ""
    echo "Do you have a separate domain for TURN? (e.g., turn.example.com)"
    read -p "Enter TURN domain (leave empty to use $DOMAIN_NAME): " t_dom
    TURN_DOMAIN="${t_dom:-$DOMAIN_NAME}"
    
    # CIDR Prompt
    echo ""
    print_header "Local Network CIDR"
    local raw_cidr=$(ip -o -f inet addr show | awk '/scope global/ {print $4}' | head -1)
    local default_cidr="$raw_cidr"
    if [[ "$raw_cidr" =~ \.([0-9]+)/24$ ]]; then default_cidr="${raw_cidr%.*}.0/24"; fi
    echo "This helps Asterisk distinguish local vs external traffic."
    read -p "Local network CIDR [$default_cidr]: " local_net
    LOCAL_CIDR="${local_net:-$default_cidr}"
    
    save_config
    
    case "$cert_opt" in
        1) # Caddy
            # Show Caddy Helper text
            echo "---------------------------------------------------------"
            echo "CADDY HELPER: Ensure these are in your Caddyfile to get certs:"
            echo ""
            echo "${DOMAIN_NAME} {"
            echo "    respond \"Asterisk Cert Placeholder\" 200"
            echo "}"
            if [[ "$TURN_DOMAIN" != "$DOMAIN_NAME" ]]; then
                echo ""
                echo "${TURN_DOMAIN} {"
                echo "    respond \"TURN Cert Placeholder\" 200"
                echo "}"
            fi
            echo ""
            echo "Restart Caddy, wait 30s, then press Enter."
            echo "---------------------------------------------------------"
            read -p "Press Enter to sync..."
            if setup_caddy_cert_sync "auto"; then
                print_success "Setup complete using Caddy certificates!"
            else
                print_error "Caddy sync failed. Ensure Caddy is running."
                return
            fi
            ;;
        2) # Certbot
            print_info "Installing Certbot..."
            apt install -y certbot
            certbot certonly --standalone -d "$DOMAIN_NAME" --non-interactive --agree-tos --register-unsafely-without-email
            if [[ -f "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem" ]]; then
                mkdir -p /etc/asterisk/certs
                cat "/etc/letsencrypt/live/$DOMAIN_NAME/fullchain.pem" > /etc/asterisk/certs/server.crt
                cat "/etc/letsencrypt/live/$DOMAIN_NAME/privkey.pem" > /etc/asterisk/certs/server.key
                chown asterisk:asterisk /etc/asterisk/certs/server.*
                print_success "Certbot Success"
            else
                print_error "Certbot failed"
                return
            fi
            ;;
        3) # Self-Signed
            mkdir -p /etc/asterisk/certs
            openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
                -keyout /etc/asterisk/certs/server.key \
                -out /etc/asterisk/certs/server.crt \
                -subj "/CN=$DOMAIN_NAME" 2>/dev/null
            chown asterisk:asterisk /etc/asterisk/certs/server.*
            chmod 644 /etc/asterisk/certs/server.crt
            chmod 600 /etc/asterisk/certs/server.key
            print_success "Self-signed certificate generated"
            print_warn "Clients will need to trust this certificate"
            ;;
        4) # Manual
            read -p "Certificate Path: " cp
            read -p "Private Key Path: " kp
            if [[ -f "$cp" && -f "$kp" ]]; then
                mkdir -p /etc/asterisk/certs
                cat "$cp" > /etc/asterisk/certs/server.crt
                cat "$kp" > /etc/asterisk/certs/server.key
                chown asterisk:asterisk /etc/asterisk/certs/server.*
                print_success "Certificates installed"
            else
                print_error "Files not found!"
                return
            fi
            ;;
    esac
    
    ENABLE_TLS="y"
    save_config
    generate_pjsip_conf
    restart_asterisk_safe
    print_success "Internet access configuration complete"
}

# ================================================================
# 10. INSTALLATION
# ================================================================

install_full() {
    if is_docker; then
        # In Docker: server is pre-installed, just configure
        print_header "Server Configuration"
        install_asterisk_packages
        configure_asterisk
        INSTALLED_SERVER="y"
        ENABLE_TLS="n"
        save_config
        print_success "Server configured"
        return
    fi

    print_header "Full Installation"
    local default_user="${SUDO_USER:-$USER}"
    read -p "Client User [$default_user]: " target_user
    KIOSK_USER="${target_user:-$default_user}"
    KIOSK_UID=$(id -u "$KIOSK_USER")

    if ! collect_common_config; then return; fi
    collect_client_config
    install_dependencies
    INSTALLED_SERVER="y"
    INSTALLED_CLIENT="y"
    ENABLE_TLS="n"  # LAN-only by default, set to "y" only if internet/certs setup is run
    configure_asterisk
    configure_baresip
    enable_client_services
    open_firewall_ports
    save_config

    echo ""
    echo "════════════════════════════════════════════════════════"
    print_success "Local network install complete"
    echo ""
    echo "Server and devices are reachable over internal LAN network only."
    echo "To add internet calling capability, continue with the setup below."
    echo "════════════════════════════════════════════════════════"
    echo ""
    read -p "Run Internet/Certificate Setup wizard now? [Y/n]: " run_setup
    [[ ! "$run_setup" =~ ^[Nn]$ ]] && setup_internet_access

    print_success "Installation complete"
}

install_server_only() {
    if is_docker; then
        install_full
        return
    fi

    print_header "Server Installation"
    ASTERISK_HOST="127.0.0.1"
    ENABLE_TLS="n"  # LAN-only by default, set to "y" only if internet/certs setup is run
    install_asterisk_packages
    configure_asterisk
    open_firewall_ports
    INSTALLED_SERVER="y"
    save_config

    echo ""
    echo "════════════════════════════════════════════════════════"
    print_success "Local network install complete"
    echo ""
    echo "Server and devices are reachable over internal LAN network only."
    echo "To add internet calling capability, continue with the setup below."
    echo "════════════════════════════════════════════════════════"
    echo ""
    read -p "Run Internet/Certificate Setup wizard now? [Y/n]: " run_setup
    [[ ! "$run_setup" =~ ^[Nn]$ ]] && setup_internet_access

    print_success "Server installed"
}

install_client_only() {
    print_header "Client Installation"
    echo "Select the user to install the kiosk client for:"
    echo ""

    if ! select_user; then
        print_error "User selection failed"
        return 1
    fi

    echo ""
    read -p "Server (IP or domain): " ASTERISK_HOST
    read -p "SIP Password: " SIP_PASSWORD
    
    if [[ "$ASTERISK_HOST" =~ [a-zA-Z] ]]; then 
        ENABLE_TLS="y"
    else
        ENABLE_TLS="n"
    fi

    echo ""
    echo "Answer Mode:"
    echo "  1) Auto (auto-answer incoming calls)"
    echo "  2) Manual (ring on incoming)"
    read -p "Select [1]: " aa_sel
    CLIENT_ANSWERMODE="auto"
    [[ "$aa_sel" == "2" ]] && CLIENT_ANSWERMODE="manual"

    collect_client_config
    install_baresip_packages
    INSTALLED_CLIENT="y"
    configure_baresip
    enable_client_services
    save_config

    print_success "Client installed"
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo "  IMPORTANT: Audio Configuration"
    echo "════════════════════════════════════════════════════════"
    echo "  User: $KIOSK_USER"
    echo "  - Audio group: Added"
    echo "  - PipeWire services: Enabled"
    echo "  - Microphone: Unmuted (for intercom mode)"
    echo ""
    echo "  If audio doesn't work immediately:"
    echo "  1. Log out and log back in as '$KIOSK_USER'"
    echo "  2. Or reboot the system"
    echo "  3. Check audio with: pactl list sources short"
    echo ""
    echo "  PTT Mode: Not configured (normal intercom operation)"
    echo "  To configure PTT: Main Menu > Client Management > Configure PTT Button"
    echo "════════════════════════════════════════════════════════"
}

collect_common_config() {
    SIP_PASSWORD="${SIP_PASSWORD:-$(generate_password)}"
    ASTERISK_HOST="127.0.0.1"
    return 0
}

collect_client_config() {
    read -p "Extension [101]: " KIOSK_EXTENSION
    KIOSK_EXTENSION="${KIOSK_EXTENSION:-101}"
    KIOSK_NAME="kiosk-${KIOSK_EXTENSION}"
}

install_dependencies() {
    install_asterisk_packages
    if ! is_docker; then
        install_baresip_packages
    fi
}

install_asterisk_packages() {
    if is_docker; then
        # In Docker, packages are pre-installed via Dockerfile
        print_info "Docker mode: packages pre-installed"
        mkdir -p /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk
        return
    fi
    echo "exit 101" > /usr/sbin/policy-rc.d
    chmod +x /usr/sbin/policy-rc.d
    apt update
    # asterisk-opus removed (included in asterisk-modules on Ubuntu 24.04+)
    apt install -y asterisk asterisk-core-sounds-en-gsm asterisk-modules openssl curl tcpdump sngrep || true
    mkdir -p /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /var/run/asterisk
    ldconfig
    update-ca-certificates 2>/dev/null || true
    rm -f /usr/sbin/policy-rc.d
    fix_asterisk_systemd
}

install_baresip_packages() {
    if is_docker; then
        # Baresip (local SIP client) is not used inside the container
        print_info "Docker mode: Baresip not applicable (use mobile/desktop SIP clients)"
        return
    fi
    apt update
    apt install -y baresip baresip-core pipewire pipewire-alsa pipewire-pulse wireplumber alsa-utils evtest || true
}

uninstall_menu() {
    if is_docker; then
        print_header "Reset Configuration"
        echo "  In Docker, the container is ephemeral."
        echo "  To fully uninstall: docker compose down -v"
        echo ""
        echo "  1) Reset all configs (keep container)"
        echo "  2) Reset devices only"
        echo "  0) Cancel"
        read -p "Select: " ch
        case $ch in
            1)
                rm -rf /etc/easy-asterisk/*
                print_success "Configuration reset. Restart container to regenerate defaults."
                ;;
            2)
                if [[ -f /etc/asterisk/pjsip.conf ]]; then
                    # Remove device sections, keep transport config
                    local temp="/tmp/pjsip_base_$$.conf"
                    awk '/^; === Device:/{exit} {print}' /etc/asterisk/pjsip.conf > "$temp"
                    mv "$temp" /etc/asterisk/pjsip.conf
                    chown asterisk:asterisk /etc/asterisk/pjsip.conf
                    asterisk -rx "pjsip reload" >/dev/null 2>&1 || true
                fi
                print_success "All devices removed"
                ;;
        esac
        return
    fi

    print_header "Uninstall"
    echo "  1) Remove Everything"
    echo "  2) Asterisk Only"
    echo "  3) Baresip Only"
    echo "  0) Cancel"
    read -p "Select: " ch
    case $ch in
        1)
            systemctl stop asterisk 2>/dev/null || true
            apt purge -y asterisk* baresip baresip-core 2>/dev/null || true
            rm -rf /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk /usr/lib/asterisk
            rm -rf /etc/systemd/system/asterisk.service.d /etc/easy-asterisk
            [[ -n "$KIOSK_USER" ]] && rm -rf "/home/${KIOSK_USER}/.baresip"
            systemctl daemon-reload
            INSTALLED_SERVER="n"
            INSTALLED_CLIENT="n"
            rm -f "$CONFIG_FILE"
            print_success "Removed all"
            ;;
        2)
            systemctl stop asterisk 2>/dev/null || true
            apt purge -y asterisk* 2>/dev/null || true
            rm -rf /etc/asterisk /var/lib/asterisk
            INSTALLED_SERVER="n"
            save_config
            print_success "Removed Asterisk"
            ;;
        3)
            apt purge -y baresip baresip-core 2>/dev/null || true
            [[ -n "$KIOSK_USER" ]] && rm -rf "/home/${KIOSK_USER}/.baresip"
            INSTALLED_CLIENT="n"
            save_config
            print_success "Removed Baresip"
            ;;
    esac
}

# ================================================================
# 11. MENU SYSTEM (Reordered: Server #2, Devices #3)
# ================================================================

show_main_menu() {
    clear
    print_header "Easy Asterisk v${SCRIPT_VERSION}"

    load_config

    if is_docker; then
        # Docker status display
        echo "  Status:"
        echo -e "    Mode: ${CYAN}Docker Container${NC}"
        if asterisk_running; then
            echo -e "    Asterisk: ${GREEN}Running${NC}"
        else
            echo -e "    Asterisk: ${RED}Not running${NC}"
        fi
        if webadmin_running; then
            echo -e "    Web Admin: ${GREEN}Running${NC} (port ${WEB_ADMIN_PORT})"
        else
            echo -e "    Web Admin: ${YELLOW}Stopped${NC}"
        fi
        [[ -n "$DOMAIN_NAME" ]] && echo -e "    Domain: ${DOMAIN_NAME}"
        if [[ "$TURN_ENABLED" == "y" ]]; then
            echo -e "    TURN:       ${GREEN}Enabled${NC} (${TURN_SERVER:-auto})"
        elif [[ "$VPN_ICE_ENABLED" == "y" ]]; then
            echo -e "    STUN/ICE:   ${GREEN}Enabled${NC} (${CUSTOM_STUN_SERVER:-auto})"
        fi
        echo ""

        declare -A menu_map
        local count=1

        if [[ "$INSTALLED_SERVER" != "y" ]]; then
            echo "  ${count}) Configure Server"; menu_map[$count]="submenu_install"; ((count++))
        fi
        echo "  ${count}) Server Settings"; menu_map[$count]="submenu_server"; ((count++))
        echo "  ${count}) Device Management"; menu_map[$count]="submenu_devices"; ((count++))
        echo "  ${count}) Tools"; menu_map[$count]="submenu_tools"; ((count++))
        echo "  0) Exit"
    else
        # Bare metal status display
        echo "  Status:"
        if [[ -f "$CONFIG_FILE" ]]; then
            [[ "$INSTALLED_SERVER" == "y" ]] && echo -e "    Server: ${GREEN}Installed${NC}" || echo -e "    Server: ${YELLOW}Not installed${NC}"
            [[ "$INSTALLED_CLIENT" == "y" ]] && echo -e "    Client: ${GREEN}Installed${NC}" || echo -e "    Client: ${YELLOW}Not installed${NC}"
            [[ -n "$DOMAIN_NAME" ]] && echo -e "    Domain: ${DOMAIN_NAME}"
        else
            echo -e "    ${YELLOW}Not configured${NC}"
        fi
        echo ""

        declare -A menu_map
        local count=1

        echo "  ${count}) Install/Configure"; menu_map[$count]="submenu_install"; ((count++))
        if [[ "$INSTALLED_SERVER" == "y" ]]; then
            echo "  ${count}) Server Settings"; menu_map[$count]="submenu_server"; ((count++))
            echo "  ${count}) Device Management"; menu_map[$count]="submenu_devices"; ((count++))
        fi
        echo "  ${count}) Client Settings"; menu_map[$count]="submenu_client"; ((count++))
        echo "  ${count}) Tools"; menu_map[$count]="submenu_tools"; ((count++))
        echo "  0) Exit"
    fi
    echo ""

    read -p "  Select: " choice
    [[ "$choice" == "0" ]] && exit 0
    local action=${menu_map[$choice]}
    [[ -n "$action" ]] && $action
    show_main_menu
}

submenu_install() {
    if is_docker; then
        clear
        print_header "Configure Server"
        echo "  1) Configure/Reconfigure Server"
        echo "  2) Reset Configuration"
        echo "  0) Back"
        read -p "  Select: " choice
        case $choice in
            1) install_full; read -p "Press Enter..." ;;
            2) uninstall_menu; read -p "Press Enter..." ;;
        esac
        return
    fi

    clear
    print_header "Install"
    echo "  1) Full (server + client)"
    echo "  2) Server only"
    echo "  3) Client only"
    echo "  4) Uninstall"
    echo "  0) Back"
    read -p "  Select: " choice
    case $choice in
        1) install_full; read -p "Press Enter..." ;;
        2) install_server_only; read -p "Press Enter..." ;;
        3) install_client_only; read -p "Press Enter..." ;;
        4) uninstall_menu; read -p "Press Enter..." ;;
    esac
}

# ================================================================
# WEB ADMIN INTERFACE
# ================================================================

# WEB_ADMIN_PORT is set in load_config (default: 8080)
WEB_ADMIN_SCRIPT="/usr/local/bin/easy-asterisk-webadmin"
WEB_ADMIN_SERVICE="/etc/systemd/system/easy-asterisk-webadmin.service"
WEB_ADMIN_HTPASSWD="/etc/easy-asterisk/webadmin.htpasswd"

create_web_admin_script() {
    cat > "$WEB_ADMIN_SCRIPT" << 'WEBADMIN'
#!/usr/bin/env python3
"""
Easy Asterisk Web Admin - Simple web interface for client management
"""

import http.server
import socketserver
import json
import subprocess
import os
import re
import base64
import hashlib
import html
from urllib.parse import parse_qs, urlparse
from functools import partial

PORT = int(os.environ.get('WEBADMIN_PORT', 8080))
AUTH_DISABLED = os.environ.get('WEBADMIN_AUTH_DISABLED', 'false').lower() == 'true'
HTPASSWD_FILE = "/etc/easy-asterisk/webadmin.htpasswd"
PJSIP_CONF = "/etc/asterisk/pjsip.conf"
CATEGORIES_FILE = "/etc/easy-asterisk/categories.conf"
ROOMS_FILE = "/etc/easy-asterisk/rooms.conf"
CONFIG_FILE = "/etc/easy-asterisk/config"

def check_auth(headers):
    """Verify HTTP Basic Auth against htpasswd file"""
    if AUTH_DISABLED:
        return True  # Auth disabled for reverse proxy mode

    if not os.path.exists(HTPASSWD_FILE):
        return True  # No auth required if no htpasswd file

    auth_header = headers.get('Authorization', '')
    if not auth_header.startswith('Basic '):
        return False

    try:
        credentials = base64.b64decode(auth_header[6:]).decode('utf-8')
        username, password = credentials.split(':', 1)

        with open(HTPASSWD_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if ':' in line:
                    stored_user, stored_hash = line.split(':', 1)
                    if stored_user == username:
                        # Support plain text (for simplicity) or SHA256
                        if stored_hash.startswith('{SHA256}'):
                            expected = '{SHA256}' + hashlib.sha256(password.encode()).hexdigest()
                            return stored_hash == expected
                        else:
                            return stored_hash == password
        return False
    except:
        return False

def get_registered_endpoints():
    """Get list of registered endpoints from Asterisk - matches bash script logic"""
    try:
        # Get full endpoint details which shows Contact lines with Avail status
        result = subprocess.run(
            ['asterisk', '-rx', 'pjsip show endpoints'],
            capture_output=True, text=True, timeout=10
        )
        endpoints = {}
        current_endpoint = None

        for line in result.stdout.split('\n'):
            # Match endpoint header line: " Endpoint:  101/101"
            endpoint_match = re.match(r'\s*Endpoint:\s+(\d+)/', line)
            if endpoint_match:
                current_endpoint = endpoint_match.group(1)
                endpoints[current_endpoint] = 'offline'  # Default to offline

            # Match contact line with Avail status: "  Contact:  101/sip:...   Avail"
            if current_endpoint and 'Contact:' in line:
                if 'Avail' in line or 'NonQual' in line:
                    endpoints[current_endpoint] = 'online'

        return endpoints
    except:
        return {}

def get_devices():
    """Parse pjsip.conf to get device information - matches bash script logic"""
    devices = []
    if not os.path.exists(PJSIP_CONF):
        return devices

    with open(PJSIP_CONF, 'r') as f:
        lines = f.readlines()

    dev_name = None
    dev_cat = None
    dev_aa = None

    for line in lines:
        line = line.strip()

        # Match device comment line
        if '; === Device:' in line:
            # Parse: ; === Device: Name (category) [AA:yes/no] ===
            temp = line.split('; === Device:')[1] if '; === Device:' in line else ''
            temp = temp.split('===')[0].strip()  # Remove trailing ===

            # Check for AA tag
            dev_aa = None
            if '[AA:yes]' in temp:
                dev_aa = 'yes'
                temp = temp.replace('[AA:yes]', '').strip()
            elif '[AA:no]' in temp:
                dev_aa = 'no'
                temp = temp.replace('[AA:no]', '').strip()

            # Extract category from parentheses
            if '(' in temp and ')' in temp:
                dev_cat = temp[temp.rfind('(')+1:temp.rfind(')')]
                dev_name = temp[:temp.rfind('(')].strip()
            else:
                dev_name = temp
                dev_cat = 'unknown'

        # Match extension line [xxx]
        elif dev_name and re.match(r'^\[(\d+)\]$', line):
            ext = re.match(r'^\[(\d+)\]$', line).group(1)
            devices.append({
                'name': dev_name,
                'category': dev_cat,
                'extension': ext,
                'auto_answer': dev_aa,
                'transport': 'udp',  # Default, will check below
                'encryption': 'no'
            })
            dev_name = None
            dev_cat = None
            dev_aa = None

        # Update transport/encryption for last added device
        elif devices and line.startswith('transport=transport-'):
            devices[-1]['transport'] = line.split('transport-')[1]
        elif devices and line.startswith('media_encryption='):
            val = line.split('=')[1]
            if val == 'sdes' or val == 'dtls':
                devices[-1]['encryption'] = val
                # If encryption is set but no explicit transport, assume TLS
                if devices[-1]['transport'] == 'udp':
                    devices[-1]['transport'] = 'tls'
            elif val != 'no':
                devices[-1]['encryption'] = val

    return devices

def get_categories():
    """Get categories from config file"""
    categories = []
    if os.path.exists(CATEGORIES_FILE):
        with open(CATEGORIES_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split('|')
                    if len(parts) >= 3:
                        categories.append({
                            'id': parts[0],
                            'name': parts[1],
                            'auto_answer': parts[2],
                            'description': parts[3] if len(parts) > 3 else ''
                        })
    return categories

def get_rooms():
    """Get rooms from config file"""
    rooms = []
    if os.path.exists(ROOMS_FILE):
        with open(ROOMS_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split('|')
                    if len(parts) >= 5:
                        rooms.append({
                            'extension': parts[0],
                            'name': parts[1],
                            'members': parts[2],
                            'timeout': parts[3],
                            'type': parts[4]
                        })
    return rooms

def delete_device(extension):
    """Delete a device from pjsip.conf"""
    if not os.path.exists(PJSIP_CONF):
        return False, "Config file not found"

    with open(PJSIP_CONF, 'r') as f:
        lines = f.readlines()

    new_lines = []
    skip = False
    found = False
    pending_comment = None

    for line in lines:
        stripped = line.strip()

        if stripped.startswith('; === Device:'):
            pending_comment = line
            continue

        if re.match(rf'^\[{extension}\]$', stripped):
            if pending_comment:
                found = True
                skip = True
                pending_comment = None
                continue
            elif found:
                skip = True
                continue

        if pending_comment:
            new_lines.append(pending_comment)
            pending_comment = None

        if skip and stripped == '':
            skip = False
            continue

        if not skip:
            new_lines.append(line)

    if found:
        with open(PJSIP_CONF, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(['asterisk', '-rx', 'pjsip reload'], capture_output=True)
        return True, "Device deleted"
    return False, "Device not found"

def rename_device(extension, new_name):
    """Rename a device in pjsip.conf"""
    if not os.path.exists(PJSIP_CONF):
        return False, "Config file not found"

    with open(PJSIP_CONF, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    in_device = False
    device_ext = None

    for line in lines:
        stripped = line.strip()

        # Match device comment and update name
        if stripped.startswith('; === Device:'):
            # Parse the comment to get category and AA tag
            temp = stripped.split('; === Device:')[1].split('===')[0].strip()
            aa_tag = ''
            if '[AA:yes]' in temp:
                aa_tag = ' [AA:yes]'
                temp = temp.replace('[AA:yes]', '').strip()
            elif '[AA:no]' in temp:
                aa_tag = ' [AA:no]'
                temp = temp.replace('[AA:no]', '').strip()

            if '(' in temp:
                cat = temp[temp.rfind('(')+1:temp.rfind(')')]
            else:
                cat = 'unknown'

            # Store for next line check
            pending_comment = (line, cat, aa_tag)
            continue

        # Check if this is the extension we want
        if 'pending_comment' in dir() and pending_comment:
            match = re.match(r'^\[(\d+)\]$', stripped)
            if match and match.group(1) == extension:
                # This is our device - write updated comment
                old_line, cat, aa_tag = pending_comment
                new_lines.append(f'; === Device: {new_name} ({cat}){aa_tag} ===\n')
                new_lines.append(line)
                found = True
                in_device = True
                device_ext = extension
                pending_comment = None
                continue
            else:
                # Not our device, write original comment
                new_lines.append(pending_comment[0])
                pending_comment = None

        # Update callerid line
        if in_device and stripped.startswith('callerid='):
            new_lines.append(f'callerid="{new_name}" <{device_ext}>\n')
            continue

        # Reset on empty line after device
        if in_device and stripped == '':
            in_device = False

        new_lines.append(line)

    if found:
        with open(PJSIP_CONF, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(['asterisk', '-rx', 'pjsip reload'], capture_output=True)
        return True, "Device renamed"
    return False, "Device not found"

def update_room_members(room_ext, new_members):
    """Update room members"""
    if not os.path.exists(ROOMS_FILE):
        return False, "Rooms file not found"

    # Read all rooms
    rooms = []
    found = False
    with open(ROOMS_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                rooms.append(line)
                continue
            parts = line.split('|')
            if len(parts) >= 5 and parts[0] == room_ext:
                # Update this room's members
                parts[2] = new_members
                rooms.append('|'.join(parts))
                found = True
            else:
                rooms.append(line)

    if found:
        with open(ROOMS_FILE, 'w') as f:
            f.write('\n'.join(rooms) + '\n')
        # Rebuild dialplan
        subprocess.run(['/usr/local/bin/easy-asterisk', '--rebuild-dialplan'], capture_output=True)
        return True, "Room members updated"
    return False, "Room not found"

def add_device_to_room(room_ext, device_ext):
    """Add a device to a room"""
    if not os.path.exists(ROOMS_FILE):
        return False, "Rooms file not found"

    # Find the room and its current members
    with open(ROOMS_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) >= 5 and parts[0] == room_ext:
                current_members = parts[2].split(',') if parts[2] else []
                # Check if device is already a member
                if device_ext in current_members:
                    return False, "Device already in room"
                current_members.append(device_ext)
                new_members = ','.join(current_members)
                return update_room_members(room_ext, new_members)
    return False, "Room not found"

def remove_device_from_room(room_ext, device_ext):
    """Remove a device from a room"""
    if not os.path.exists(ROOMS_FILE):
        return False, "Rooms file not found"

    # Find the room and its current members
    with open(ROOMS_FILE, 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split('|')
            if len(parts) >= 5 and parts[0] == room_ext:
                current_members = parts[2].split(',') if parts[2] else []
                # Check if device is a member
                if device_ext not in current_members:
                    return False, "Device not in room"
                current_members.remove(device_ext)
                new_members = ','.join(current_members)
                return update_room_members(room_ext, new_members)
    return False, "Room not found"

def change_device_category(extension, new_category):
    """Change a device's category in pjsip.conf"""
    if not os.path.exists(PJSIP_CONF):
        return False, "Config file not found"

    with open(PJSIP_CONF, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    in_device = False

    for line in lines:
        stripped = line.strip()

        # Match device comment line: ; === Device: Name (category) ===
        if stripped.startswith('; === Device:') and f'[{extension}]' in ''.join(lines[lines.index(line):lines.index(line)+3]):
            # Parse and update category in comment
            match = re.match(r'^; === Device: (.+?) \(([^)]+)\)(.*?)===', stripped)
            if match:
                name = match.group(1)
                old_cat = match.group(2)
                rest = match.group(3)
                new_lines.append(f'; === Device: {name} ({new_category}){rest}===\n')
                found = True
                in_device = True
                continue

        new_lines.append(line)

    if found:
        with open(PJSIP_CONF, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(['asterisk', '-rx', 'pjsip reload'], capture_output=True)
        return True, "Category changed"
    return False, "Device not found"

def create_room(extension, name, room_type='ring', timeout='60'):
    """Create a new room in rooms.conf"""
    if not os.path.exists(ROOMS_FILE):
        with open(ROOMS_FILE, 'w') as f:
            f.write('# Format: ext|name|members|timeout|type(ring/page)\n')

    # Check if extension already exists
    with open(ROOMS_FILE, 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#'):
                parts = line.split('|')
                if len(parts) >= 1 and parts[0] == extension:
                    return False, "Room extension already exists"

    # Add new room
    with open(ROOMS_FILE, 'a') as f:
        f.write(f'{extension}|{name}||{timeout}|{room_type}\n')

    # Rebuild dialplan
    subprocess.run(['/usr/local/bin/easy-asterisk', '--rebuild-dialplan'], capture_output=True)
    return True, "Room created"

def delete_room(extension):
    """Delete a room from rooms.conf"""
    if not os.path.exists(ROOMS_FILE):
        return False, "Rooms file not found"

    with open(ROOMS_FILE, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.split('|')
            if len(parts) >= 1 and parts[0] == extension:
                found = True
                continue
        new_lines.append(line)

    if found:
        with open(ROOMS_FILE, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(['/usr/local/bin/easy-asterisk', '--rebuild-dialplan'], capture_output=True)
        return True, "Room deleted"
    return False, "Room not found"

def rename_room(extension, new_name):
    """Rename a room in rooms.conf"""
    if not os.path.exists(ROOMS_FILE):
        return False, "Rooms file not found"

    with open(ROOMS_FILE, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.split('|')
            if len(parts) >= 5 and parts[0] == extension:
                # Update name (parts[1])
                parts[1] = new_name
                new_lines.append('|'.join(parts) + '\n')
                found = True
                continue
        new_lines.append(line)

    if found:
        with open(ROOMS_FILE, 'w') as f:
            f.writelines(new_lines)
        subprocess.run(['/usr/local/bin/easy-asterisk', '--rebuild-dialplan'], capture_output=True)
        return True, "Room renamed"
    return False, "Room not found"

def create_category(cat_id, name, auto_answer='', description=''):
    """Create a new category in categories.conf"""
    if not os.path.exists(CATEGORIES_FILE):
        with open(CATEGORIES_FILE, 'w') as f:
            f.write('# Format: id|name|auto_answer|description\n')

    # Check if category already exists
    with open(CATEGORIES_FILE, 'r') as f:
        for line in f:
            if line.strip() and not line.startswith('#'):
                parts = line.split('|')
                if len(parts) >= 1 and parts[0] == cat_id:
                    return False, "Category ID already exists"

    # Add new category
    with open(CATEGORIES_FILE, 'a') as f:
        f.write(f'{cat_id}|{name}|{auto_answer}|{description}\n')

    return True, "Category created"

def delete_category(cat_id):
    """Delete a category from categories.conf"""
    if not os.path.exists(CATEGORIES_FILE):
        return False, "Categories file not found"

    with open(CATEGORIES_FILE, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.split('|')
            if len(parts) >= 1 and parts[0] == cat_id:
                found = True
                continue
        new_lines.append(line)

    if found:
        with open(CATEGORIES_FILE, 'w') as f:
            f.writelines(new_lines)
        return True, "Category deleted"
    return False, "Category not found"

def rename_category(cat_id, new_name):
    """Rename a category in categories.conf"""
    if not os.path.exists(CATEGORIES_FILE):
        return False, "Categories file not found"

    with open(CATEGORIES_FILE, 'r') as f:
        lines = f.readlines()

    new_lines = []
    found = False
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith('#'):
            parts = stripped.split('|')
            if len(parts) >= 2 and parts[0] == cat_id:
                # Update name (parts[1])
                parts[1] = new_name
                new_lines.append('|'.join(parts) + '\n')
                found = True
                continue
        new_lines.append(line)

    if found:
        with open(CATEGORIES_FILE, 'w') as f:
            f.writelines(new_lines)
        return True, "Category renamed"
    return False, "Category not found"

def generate_password(length=16):
    """Generate a random password"""
    import secrets
    import string
    chars = string.ascii_letters + string.digits
    return ''.join(secrets.choice(chars) for _ in range(length))

def add_device(name, category, extension, conn_type='lan', auto_answer=None):
    """Add a new device to pjsip.conf"""
    if not os.path.exists(PJSIP_CONF):
        return False, "Config file not found"

    # Check if extension exists
    with open(PJSIP_CONF, 'r') as f:
        if f'[{extension}]' in f.read():
            return False, "Extension already exists"

    password = generate_password()

    # Determine transport and encryption
    # Check if VPN ICE mode is enabled (for third-party VPNs)
    vpn_ice = 'n'
    turn_enabled = 'n'
    is_container = os.path.exists('/.dockerenv')
    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as cf:
            for cline in cf:
                if cline.startswith('VPN_ICE_ENABLED='):
                    vpn_ice = cline.strip().split('=', 1)[1].strip('"')
                elif cline.startswith('TURN_ENABLED='):
                    turn_enabled = cline.strip().split('=', 1)[1].strip('"')

    # In Docker: always use FQDN mode for web-created devices
    if is_container and conn_type == 'lan':
        conn_type = 'fqdn'

    if conn_type == 'fqdn':
        transport = 'transport=transport-tls'
        encryption = 'media_encryption=sdes'
        ice = 'ice_support=yes'
    else:
        transport = 'transport=transport-udp'
        encryption = 'media_encryption=no'
        ice = 'ice_support=yes' if (vpn_ice == 'y' or turn_enabled == 'y') else ''

    aa_tag = ''
    if auto_answer == 'yes':
        aa_tag = '[AA:yes] '
    elif auto_answer == 'no':
        aa_tag = '[AA:no] '

    # Mobile devices get keepalive settings for NAT traversal
    keepalive = ''
    if category == 'mobile':
        keepalive = 'rtp_keepalive=15\nrtp_timeout=120\nrtp_timeout_hold=120'

    device_config = f'''
; === Device: {name} ({category}) {aa_tag}===
[{extension}]
type=endpoint
context=intercom
{transport}
disallow=all
allow=opus
allow=ulaw
allow=alaw
allow=g722
{encryption}
direct_media=no
rtp_symmetric=yes
force_rport=yes
rewrite_contact=yes
{keepalive}
{ice}
auth={extension}
aors={extension}
callerid="{name}" <{extension}>

[{extension}]
type=auth
auth_type=userpass
username={extension}
password={password}

[{extension}]
type=aor
max_contacts=5
remove_existing=yes
qualify_frequency=30
'''

    with open(PJSIP_CONF, 'a') as f:
        f.write(device_config)

    subprocess.run(['asterisk', '-rx', 'pjsip reload'], capture_output=True)
    subprocess.run(['chown', 'asterisk:asterisk', PJSIP_CONF], capture_output=True)

    return True, {'extension': extension, 'password': password, 'name': name}

def get_server_info():
    """Get server configuration info including TURN/STUN details"""
    info = {
        'domain': '',
        'tls_enabled': False,
        'server_ip': '',
        'turn_enabled': False,
        'turn_server': '',
        'turn_username': '',
        'turn_password': ''
    }

    if os.path.exists(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('DOMAIN_NAME='):
                    info['domain'] = line.split('=', 1)[1].strip().strip('"')
                elif line.startswith('ENABLE_TLS='):
                    info['tls_enabled'] = 'y' in line.lower()
                elif line.startswith('TURN_ENABLED='):
                    info['turn_enabled'] = 'y' in line.split('=', 1)[1].lower()
                elif line.startswith('TURN_SERVER='):
                    info['turn_server'] = line.split('=', 1)[1].strip().strip('"')
                elif line.startswith('TURN_USERNAME='):
                    info['turn_username'] = line.split('=', 1)[1].strip().strip('"')
                elif line.startswith('TURN_PASSWORD='):
                    info['turn_password'] = line.split('=', 1)[1].strip().strip('"')

    try:
        result = subprocess.run(['hostname', '-I'], capture_output=True, text=True)
        info['server_ip'] = result.stdout.split()[0] if result.stdout else ''
    except:
        pass

    return info

HTML_TEMPLATE = '''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Easy Asterisk - Client Admin</title>
    <style>
        :root {
            --primary: #2563eb;
            --success: #16a34a;
            --danger: #dc2626;
            --warning: #d97706;
            --bg: #f8fafc;
            --card-bg: #ffffff;
            --text: #1e293b;
            --text-muted: #64748b;
            --border: #e2e8f0;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: var(--bg);
            color: var(--text);
            line-height: 1.6;
        }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        header {
            background: var(--primary);
            color: white;
            padding: 20px;
            margin-bottom: 20px;
            border-radius: 8px;
        }
        header h1 { font-size: 1.5rem; }
        header p { opacity: 0.9; font-size: 0.9rem; }
        .card {
            background: var(--card-bg);
            border-radius: 8px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            margin-bottom: 20px;
            overflow: hidden;
        }
        .card-header {
            background: #f1f5f9;
            padding: 15px 20px;
            border-bottom: 1px solid var(--border);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }
        .card-header h2 { font-size: 1.1rem; }
        .card-body { padding: 20px; }
        table { width: 100%; border-collapse: collapse; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid var(--border); }
        th { background: #f8fafc; font-weight: 600; }
        .status {
            display: inline-block;
            padding: 4px 12px;
            border-radius: 20px;
            font-size: 0.8rem;
            font-weight: 500;
        }
        .status-online { background: #dcfce7; color: #166534; }
        .status-offline { background: #fee2e2; color: #991b1b; }
        .btn {
            display: inline-block;
            padding: 8px 16px;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.9rem;
            text-decoration: none;
            transition: opacity 0.2s;
        }
        .btn:hover { opacity: 0.9; }
        .btn-primary { background: var(--primary); color: white; }
        .btn-danger { background: var(--danger); color: white; }
        .btn-sm { padding: 4px 10px; font-size: 0.8rem; }
        .action-select { width: 100px; padding: 5px 4px; font-size: 12px; border: 1px solid #ccc; border-radius: 4px; margin-right: 4px; }
        .action-btn { width: 100px; padding: 5px 4px; font-size: 12px; margin-right: 4px; }
        .sort-control { display: inline-flex; align-items: center; gap: 8px; margin-right: 15px; }
        .sort-control label { font-size: 13px; color: #666; white-space: nowrap; }
        .sort-control select { padding: 5px 8px; font-size: 13px; border: 1px solid #ccc; border-radius: 4px; }
        .form-group { margin-bottom: 15px; }
        .form-group label { display: block; margin-bottom: 5px; font-weight: 500; }
        .form-control {
            width: 100%;
            padding: 10px;
            border: 1px solid var(--border);
            border-radius: 6px;
            font-size: 1rem;
        }
        .form-row { display: flex; gap: 15px; flex-wrap: wrap; }
        .form-row .form-group { flex: 1; min-width: 200px; }
        .modal {
            display: none;
            position: fixed;
            top: 0; left: 0; right: 0; bottom: 0;
            background: rgba(0,0,0,0.5);
            align-items: center;
            justify-content: center;
            z-index: 1000;
        }
        .modal.active { display: flex; }
        .modal-content {
            background: white;
            padding: 25px;
            border-radius: 12px;
            max-width: 500px;
            width: 90%;
            max-height: 90vh;
            overflow-y: auto;
        }
        .modal-header { margin-bottom: 20px; }
        .modal-header h3 { margin-bottom: 5px; }
        .tabs { display: flex; border-bottom: 2px solid var(--border); margin-bottom: 20px; }
        .tab {
            padding: 10px 20px;
            cursor: pointer;
            border-bottom: 2px solid transparent;
            margin-bottom: -2px;
        }
        .tab.active { border-color: var(--primary); color: var(--primary); }
        .tab-content { display: none; }
        .tab-content.active { display: block; }
        .alert {
            padding: 12px 16px;
            border-radius: 6px;
            margin-bottom: 15px;
        }
        .alert-success { background: #dcfce7; color: #166534; }
        .alert-error { background: #fee2e2; color: #991b1b; }
        .credentials {
            background: #f1f5f9;
            padding: 15px;
            border-radius: 6px;
            font-family: monospace;
        }
        .credentials p { margin: 5px 0; }
        .refresh-btn { background: none; border: none; cursor: pointer; font-size: 1.2rem; }
        @media (max-width: 768px) {
            .form-row { flex-direction: column; }
            .form-row .form-group { min-width: 100%; }
            th, td { padding: 8px; font-size: 0.9rem; }
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>Easy Asterisk - Client Admin</h1>
            <p>Manage SIP clients and extensions</p>
        </header>

        <div id="alert-container"></div>

        <div class="tabs">
            <div class="tab active" data-tab="devices">Devices</div>
            <div class="tab" data-tab="rooms">Rooms</div>
            <div class="tab" data-tab="categories">Categories</div>
        </div>

        <div id="devices" class="tab-content active">
            <div class="card">
                <div class="card-header">
                    <h2>Registered Devices</h2>
                    <div style="display:flex;align-items:center;gap:15px">
                        <div class="sort-control">
                            <label>Sort by:</label>
                            <select id="sort-select" onchange="sortDevices(this.value)">
                                <option value="extension">Extension</option>
                                <option value="name">Name</option>
                                <option value="category">Category</option>
                                <option value="status">Status (Online first)</option>
                                <option value="transport">Transport</option>
                            </select>
                        </div>
                        <button class="refresh-btn" onclick="loadDevices()" title="Refresh">&#x21bb;</button>
                        <button class="btn btn-primary" onclick="showAddModal()">+ Add Device</button>
                    </div>
                </div>
                <div class="card-body">
                    <table>
                        <thead>
                            <tr>
                                <th>Extension</th>
                                <th>Name</th>
                                <th>Category</th>
                                <th>Transport</th>
                                <th>Status</th>
                                <th>Actions</th>
                            </tr>
                        </thead>
                        <tbody id="devices-table"></tbody>
                    </table>
                </div>
            </div>
        </div>

        <div id="rooms" class="tab-content">
            <div class="card">
                <div class="card-header">
                    <h2>Rooms (Ring/Page Groups)</h2>
                    <div>
                        <button class="refresh-btn" onclick="loadRooms()" title="Refresh">&#x21bb;</button>
                        <button class="btn btn-primary" onclick="showAddRoomModal()">+ Add Room</button>
                    </div>
                </div>
                <div class="card-body" id="rooms-container"></div>
            </div>
        </div>

        <div id="categories" class="tab-content">
            <div class="card">
                <div class="card-header">
                    <h2>Device Categories</h2>
                    <div>
                        <button class="refresh-btn" onclick="loadCategories()" title="Refresh">&#x21bb;</button>
                        <button class="btn btn-primary" onclick="showAddCategoryModal()">+ Add Category</button>
                    </div>
                </div>
                <div class="card-body" id="categories-container"></div>
            </div>
        </div>
    </div>

    <!-- Add Device Modal -->
    <div id="add-modal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Add New Device</h3>
                <p>Configure a new SIP client</p>
            </div>
            <form id="add-form" onsubmit="addDevice(event)">
                <div class="form-group">
                    <label>Device Name</label>
                    <input type="text" name="name" class="form-control" required placeholder="e.g., Kitchen Phone">
                </div>
                <div class="form-row">
                    <div class="form-group">
                        <label>Category</label>
                        <select name="category" class="form-control" id="category-select"></select>
                    </div>
                    <div class="form-group">
                        <label>Extension</label>
                        <input type="number" name="extension" class="form-control" required min="100" max="999">
                    </div>
                </div>
                <div class="form-row">
                    <div class="form-group">
                        <label>Connection Type</label>
                        <select name="conn_type" class="form-control">
                            <option value="lan">LAN/VPN (UDP)</option>
                            <option value="fqdn">FQDN/Internet (TLS)</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Auto-Answer Override</label>
                        <select name="auto_answer" class="form-control">
                            <option value="">Use Category Default</option>
                            <option value="yes">Force Auto-Answer</option>
                            <option value="no">Force Ring</option>
                        </select>
                    </div>
                </div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button type="button" class="btn" onclick="closeModal()" style="background: #e2e8f0;">Cancel</button>
                    <button type="submit" class="btn btn-primary">Add Device</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Credentials Modal -->
    <div id="credentials-modal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Device Created Successfully</h3>
                <p>Save these credentials - the password cannot be retrieved later</p>
            </div>
            <div class="credentials" id="credentials-display"></div>
            <div style="margin-top: 20px; text-align: right;">
                <button class="btn btn-primary" onclick="closeCredentialsModal()">Done</button>
            </div>
        </div>
    </div>

    <!-- Rename Modal -->
    <div id="rename-modal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Rename Device</h3>
                <p>Enter a new name for extension <span id="rename-ext"></span></p>
            </div>
            <form id="rename-form" onsubmit="renameDevice(event)">
                <input type="hidden" id="rename-extension" name="extension">
                <div class="form-group">
                    <label>New Name</label>
                    <input type="text" id="rename-name" name="name" class="form-control" required>
                </div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button type="button" class="btn" onclick="closeRenameModal()" style="background: #e2e8f0;">Cancel</button>
                    <button type="submit" class="btn btn-primary">Rename</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Add Room Modal -->
    <div id="add-room-modal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Add Room</h3>
                <p>Create a ring or page group</p>
            </div>
            <form id="add-room-form" onsubmit="addRoom(event)">
                <div class="form-group">
                    <label>Room Name</label>
                    <input type="text" name="name" class="form-control" required placeholder="e.g., All Phones">
                </div>
                <div class="form-row">
                    <div class="form-group">
                        <label>Extension</label>
                        <input type="number" name="extension" class="form-control" required min="100" max="999" placeholder="e.g., 199">
                    </div>
                    <div class="form-group">
                        <label>Type</label>
                        <select name="type" class="form-control">
                            <option value="ring">Ring (sequential)</option>
                            <option value="page">Page (all at once)</option>
                        </select>
                    </div>
                </div>
                <div class="form-group">
                    <label>Timeout (seconds)</label>
                    <input type="number" name="timeout" class="form-control" value="60" min="10" max="300">
                </div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button type="button" class="btn" onclick="closeAddRoomModal()" style="background: #e2e8f0;">Cancel</button>
                    <button type="submit" class="btn btn-primary">Create Room</button>
                </div>
            </form>
        </div>
    </div>

    <!-- Add Category Modal -->
    <div id="add-category-modal" class="modal">
        <div class="modal-content">
            <div class="modal-header">
                <h3>Add Category</h3>
                <p>Create a device category</p>
            </div>
            <form id="add-category-form" onsubmit="addCategory(event)">
                <div class="form-row">
                    <div class="form-group">
                        <label>Category ID (short)</label>
                        <input type="text" name="id" class="form-control" required placeholder="e.g., kiosk" pattern="[a-z0-9]+" title="Lowercase letters and numbers only">
                    </div>
                    <div class="form-group">
                        <label>Display Name</label>
                        <input type="text" name="name" class="form-control" required placeholder="e.g., Kiosk Phones">
                    </div>
                </div>
                <div class="form-row">
                    <div class="form-group">
                        <label>Auto-Answer (SIP header)</label>
                        <input type="text" name="auto_answer" class="form-control" placeholder="e.g., answer-after=0">
                    </div>
                    <div class="form-group">
                        <label>Description</label>
                        <input type="text" name="description" class="form-control" placeholder="Optional description">
                    </div>
                </div>
                <div style="display: flex; gap: 10px; justify-content: flex-end; margin-top: 20px;">
                    <button type="button" class="btn" onclick="closeAddCategoryModal()" style="background: #e2e8f0;">Cancel</button>
                    <button type="submit" class="btn btn-primary">Create Category</button>
                </div>
            </form>
        </div>
    </div>

    <script>
        const API_BASE = '/api';
        let roomsCache = [];
        let categoriesCache = [];
        let devicesCache = [];
        let statusCache = {};
        let currentSort = 'extension';

        // Tab switching
        document.querySelectorAll('.tab').forEach(tab => {
            tab.addEventListener('click', () => {
                document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.tab-content').forEach(c => c.classList.remove('active'));
                tab.classList.add('active');
                document.getElementById(tab.dataset.tab).classList.add('active');
            });
        });

        function showAlert(message, type = 'success') {
            const container = document.getElementById('alert-container');
            container.innerHTML = `<div class="alert alert-${type}">${message}</div>`;
            setTimeout(() => container.innerHTML = '', 5000);
        }

        function getRoomOptions(deviceExt) {
            return roomsCache.map(r => {
                const members = (r.members || '').split(',').map(m => m.trim()).filter(m => m);
                const inRoom = members.includes(deviceExt);
                return `<option value="${r.extension}" ${inRoom ? 'disabled' : ''}>${r.name}${inRoom ? ' (member)' : ''}</option>`;
            }).join('');
        }

        function getCategoryOptions(currentCat) {
            return categoriesCache.map(c =>
                `<option value="${c.id}" ${c.id === currentCat ? 'disabled' : ''}>${c.name}${c.id === currentCat ? ' (current)' : ''}</option>`
            ).join('');
        }

        function sortDevices(sortBy) {
            currentSort = sortBy;
            renderDevices();
        }

        function getSortedDevices() {
            const devices = [...devicesCache];
            switch (currentSort) {
                case 'extension':
                    return devices.sort((a, b) => parseInt(a.extension) - parseInt(b.extension));
                case 'name':
                    return devices.sort((a, b) => a.name.localeCompare(b.name));
                case 'category':
                    return devices.sort((a, b) => a.category.localeCompare(b.category));
                case 'status':
                    return devices.sort((a, b) => {
                        const aOnline = statusCache[a.extension] === 'online' ? 0 : 1;
                        const bOnline = statusCache[b.extension] === 'online' ? 0 : 1;
                        return aOnline - bOnline || parseInt(a.extension) - parseInt(b.extension);
                    });
                case 'transport':
                    return devices.sort((a, b) => a.transport.localeCompare(b.transport));
                default:
                    return devices;
            }
        }

        function renderDevices() {
            const devices = getSortedDevices();
            const tbody = document.getElementById('devices-table');
            tbody.innerHTML = devices.map(d => `
                <tr>
                    <td><strong>${d.extension}</strong></td>
                    <td>${d.name}</td>
                    <td>${d.category}</td>
                    <td>${d.transport.toUpperCase()}</td>
                    <td><span class="status status-${statusCache[d.extension] || 'offline'}">${statusCache[d.extension] || 'offline'}</span></td>
                    <td style="white-space:nowrap">
                        <select class="action-select" onchange="addToRoom('${d.extension}', this.value); this.selectedIndex=0;">
                            <option value="">Room...</option>
                            ${getRoomOptions(d.extension)}
                        </select>
                        <select class="action-select" onchange="changeCategory('${d.extension}', this.value); this.selectedIndex=0;">
                            <option value="">Category...</option>
                            ${getCategoryOptions(d.category)}
                        </select>
                        <button class="btn btn-primary action-btn" onclick="showRenameModal('${d.extension}', '${d.name}')">Rename</button>
                        <button class="btn btn-danger action-btn" onclick="deleteDevice('${d.extension}', '${d.name}')">Delete</button>
                    </td>
                </tr>
            `).join('');
        }

        async function loadDevices() {
            try {
                const [devicesRes, statusRes, roomsRes, catRes] = await Promise.all([
                    fetch(API_BASE + '/devices'),
                    fetch(API_BASE + '/status'),
                    fetch(API_BASE + '/rooms'),
                    fetch(API_BASE + '/categories')
                ]);
                const devices = await devicesRes.json();
                statusCache = await statusRes.json();
                roomsCache = await roomsRes.json();
                categoriesCache = await catRes.json();

                devicesCache = devices;
                renderDevices();

                // Update category select in add device form
                document.getElementById('category-select').innerHTML = categoriesCache.map(c =>
                    `<option value="${c.id}">${c.name}</option>`
                ).join('');
            } catch (e) {
                showAlert('Failed to load devices', 'error');
            }
        }

        async function addToRoom(deviceExt, roomExt) {
            if (!roomExt) return;
            try {
                const res = await fetch(API_BASE + '/rooms/' + roomExt + '/members', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({device: deviceExt})
                });
                const result = await res.json();
                if (result.success) {
                    showAlert('Device added to room');
                    loadDevices();
                    loadRooms();
                } else {
                    showAlert(result.message || 'Failed to add to room', 'error');
                }
            } catch (e) {
                showAlert('Failed to add device to room', 'error');
            }
        }

        async function removeFromRoom(roomExt, deviceExt) {
            if (!confirm('Remove device ' + deviceExt + ' from this room?')) return;
            try {
                const res = await fetch(API_BASE + '/rooms/' + roomExt + '/members/' + deviceExt, {
                    method: 'DELETE'
                });
                const result = await res.json();
                if (result.success) {
                    showAlert('Device removed from room');
                    loadRooms();
                    loadDevices();
                } else {
                    showAlert(result.message || 'Failed to remove from room', 'error');
                }
            } catch (e) {
                showAlert('Failed to remove device from room', 'error');
            }
        }

        async function changeCategory(deviceExt, newCat) {
            if (!newCat) return;
            try {
                const res = await fetch(API_BASE + '/devices/' + deviceExt + '/category', {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({category: newCat})
                });
                const result = await res.json();
                if (result.success) {
                    showAlert('Category changed');
                    loadDevices();
                    loadCategories();
                } else {
                    showAlert(result.message || 'Failed to change category', 'error');
                }
            } catch (e) {
                showAlert('Failed to change category', 'error');
            }
        }

        function renderDeviceRow(d, showRemove = false, removeAction = null) {
            return `
                <tr>
                    <td><strong>${d.extension}</strong></td>
                    <td>${d.name}</td>
                    <td>${d.category}</td>
                    <td>
                        ${showRemove ? `<button class="btn btn-danger btn-sm" onclick="${removeAction}">Remove</button>` : ''}
                    </td>
                </tr>
            `;
        }

        async function loadCategories() {
            try {
                const [catRes, devRes] = await Promise.all([
                    fetch(API_BASE + '/categories'),
                    fetch(API_BASE + '/devices')
                ]);
                const categories = await catRes.json();
                const devices = await devRes.json();
                devices.sort((a, b) => parseInt(a.extension) - parseInt(b.extension));
                categoriesCache = categories;

                const devicesByCategory = {};
                devices.forEach(d => {
                    if (!devicesByCategory[d.category]) devicesByCategory[d.category] = [];
                    devicesByCategory[d.category].push(d);
                });

                document.getElementById('categories-container').innerHTML = categories.map(c => {
                    const catDevices = devicesByCategory[c.id] || [];
                    const deviceRows = catDevices.length > 0
                        ? `<table style="width:100%;margin-top:10px">
                            <thead><tr><th>Ext</th><th>Name</th><th>Actions</th></tr></thead>
                            <tbody>
                            ${catDevices.map(d => `
                                <tr>
                                    <td><strong>${d.extension}</strong></td>
                                    <td>${d.name}</td>
                                    <td>
                                        <select onchange="changeCategory('${d.extension}', this.value); this.selectedIndex=0;" style="padding:4px;font-size:12px">
                                            <option value="">Move to...</option>
                                            ${categories.filter(cat => cat.id !== c.id).map(cat => `<option value="${cat.id}">${cat.name}</option>`).join('')}
                                        </select>
                                    </td>
                                </tr>
                            `).join('')}
                            </tbody>
                           </table>`
                        : '<p style="color:#888;margin-top:10px"><em>No devices in this category</em></p>';
                    return `
                        <div style="border:1px solid #e0e0e0;border-radius:8px;padding:15px;margin-bottom:15px">
                            <div style="display:flex;justify-content:space-between;align-items:center">
                                <div>
                                    <strong style="font-size:1.1em">${c.name}</strong>
                                    <span style="color:#666;margin-left:10px">(${c.id})</span>
                                    ${c.auto_answer ? `<span style="background:#e0e0e0;padding:2px 6px;border-radius:3px;margin-left:10px;font-size:12px">AA: ${c.auto_answer}</span>` : ''}
                                </div>
                                <div>
                                    <button class="btn btn-primary btn-sm" onclick="showRenameCategoryModal('${c.id}', '${c.name}')" style="margin-right:5px">Rename</button>
                                    <button class="btn btn-danger btn-sm" onclick="deleteCategory('${c.id}')" ${catDevices.length > 0 ? 'disabled title="Remove all devices first"' : ''}>Delete</button>
                                </div>
                            </div>
                            ${c.description ? `<p style="color:#666;margin:5px 0 0 0">${c.description}</p>` : ''}
                            ${deviceRows}
                        </div>
                    `;
                }).join('');

                document.getElementById('category-select').innerHTML = categories.map(c =>
                    `<option value="${c.id}">${c.name}</option>`
                ).join('');
            } catch (e) {
                showAlert('Failed to load categories', 'error');
            }
        }

        async function loadRooms() {
            try {
                const [roomsRes, devicesRes] = await Promise.all([
                    fetch(API_BASE + '/rooms'),
                    fetch(API_BASE + '/devices')
                ]);
                const rooms = await roomsRes.json();
                const devices = await devicesRes.json();
                roomsCache = rooms;

                const deviceMap = {};
                devices.forEach(d => deviceMap[d.extension] = d);

                document.getElementById('rooms-container').innerHTML = rooms.map(r => {
                    const members = (r.members || '').split(',').map(m => m.trim()).filter(m => m);
                    const memberRows = members.length > 0
                        ? `<table style="width:100%;margin-top:10px">
                            <thead><tr><th>Ext</th><th>Name</th><th>Actions</th></tr></thead>
                            <tbody>
                            ${members.map(ext => {
                                const dev = deviceMap[ext];
                                return `
                                    <tr>
                                        <td><strong>${ext}</strong></td>
                                        <td>${dev ? dev.name : '<em>Unknown</em>'}</td>
                                        <td><button class="btn btn-danger btn-sm" onclick="removeFromRoom('${r.extension}', '${ext}')">Remove</button></td>
                                    </tr>
                                `;
                            }).join('')}
                            </tbody>
                           </table>`
                        : '<p style="color:#888;margin-top:10px"><em>No members in this room</em></p>';
                    return `
                        <div style="border:1px solid #e0e0e0;border-radius:8px;padding:15px;margin-bottom:15px">
                            <div style="display:flex;justify-content:space-between;align-items:center">
                                <div>
                                    <strong style="font-size:1.1em">${r.name}</strong>
                                    <span style="color:#666;margin-left:10px">(ext ${r.extension})</span>
                                    <span style="background:${r.type === 'page' ? '#dcfce7' : '#dbeafe'};padding:2px 6px;border-radius:3px;margin-left:10px;font-size:12px">${r.type}</span>
                                    <span style="color:#666;margin-left:10px">${r.timeout}s timeout</span>
                                </div>
                                <div>
                                    <button class="btn btn-primary btn-sm" onclick="showRenameRoomModal('${r.extension}', '${r.name}')" style="margin-right:5px">Rename</button>
                                    <button class="btn btn-danger btn-sm" onclick="deleteRoom('${r.extension}')">Delete</button>
                                </div>
                            </div>
                            ${memberRows}
                        </div>
                    `;
                }).join('') || '<p style="color:#888"><em>No rooms configured</em></p>';
            } catch (e) {
                showAlert('Failed to load rooms', 'error');
            }
        }

        // Room modal functions
        function showAddRoomModal() { document.getElementById('add-room-modal').classList.add('active'); }
        function closeAddRoomModal() { document.getElementById('add-room-modal').classList.remove('active'); document.getElementById('add-room-form').reset(); }

        async function addRoom(e) {
            e.preventDefault();
            const form = e.target;
            const data = {
                extension: form.extension.value,
                name: form.name.value,
                type: form.type.value,
                timeout: form.timeout.value
            };
            try {
                const res = await fetch(API_BASE + '/rooms', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(data)
                });
                const result = await res.json();
                if (result.success) {
                    closeAddRoomModal();
                    showAlert('Room created');
                    loadRooms();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to create room', 'error');
                }
            } catch (e) {
                showAlert('Failed to create room', 'error');
            }
        }

        async function deleteRoom(ext) {
            if (!confirm('Delete this room? Devices will not be affected.')) return;
            try {
                const res = await fetch(API_BASE + '/rooms/' + ext, { method: 'DELETE' });
                const result = await res.json();
                if (result.success) {
                    showAlert('Room deleted');
                    loadRooms();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to delete room', 'error');
                }
            } catch (e) {
                showAlert('Failed to delete room', 'error');
            }
        }

        // Room rename
        let renameRoomExt = '';
        function showRenameRoomModal(ext, currentName) {
            renameRoomExt = ext;
            const name = prompt('Enter new name for room ' + ext + ':', currentName);
            if (name && name.trim()) {
                renameRoom(ext, name.trim());
            }
        }

        async function renameRoom(ext, newName) {
            try {
                const res = await fetch(API_BASE + '/rooms/' + ext, {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({ name: newName })
                });
                const result = await res.json();
                if (result.success) {
                    showAlert('Room renamed');
                    loadRooms();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to rename room', 'error');
                }
            } catch (e) {
                showAlert('Failed to rename room', 'error');
            }
        }

        // Category modal functions
        function showAddCategoryModal() { document.getElementById('add-category-modal').classList.add('active'); }
        function closeAddCategoryModal() { document.getElementById('add-category-modal').classList.remove('active'); document.getElementById('add-category-form').reset(); }

        async function addCategory(e) {
            e.preventDefault();
            const form = e.target;
            const data = {
                id: form.id.value,
                name: form.name.value,
                auto_answer: form.auto_answer.value,
                description: form.description.value
            };
            try {
                const res = await fetch(API_BASE + '/categories', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(data)
                });
                const result = await res.json();
                if (result.success) {
                    closeAddCategoryModal();
                    showAlert('Category created');
                    loadCategories();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to create category', 'error');
                }
            } catch (e) {
                showAlert('Failed to create category', 'error');
            }
        }

        async function deleteCategory(id) {
            if (!confirm('Delete this category?')) return;
            try {
                const res = await fetch(API_BASE + '/categories/' + id, { method: 'DELETE' });
                const result = await res.json();
                if (result.success) {
                    showAlert('Category deleted');
                    loadCategories();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to delete category', 'error');
                }
            } catch (e) {
                showAlert('Failed to delete category', 'error');
            }
        }

        // Category rename
        function showRenameCategoryModal(id, currentName) {
            const name = prompt('Enter new name for category ' + id + ':', currentName);
            if (name && name.trim()) {
                renameCategory(id, name.trim());
            }
        }

        async function renameCategory(id, newName) {
            try {
                const res = await fetch(API_BASE + '/categories/' + id, {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({ name: newName })
                });
                const result = await res.json();
                if (result.success) {
                    showAlert('Category renamed');
                    loadCategories();
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to rename category', 'error');
                }
            } catch (e) {
                showAlert('Failed to rename category', 'error');
            }
        }

        function showAddModal() {
            document.getElementById('add-modal').classList.add('active');
        }

        function closeModal() {
            document.getElementById('add-modal').classList.remove('active');
            document.getElementById('add-form').reset();
        }

        function closeCredentialsModal() {
            document.getElementById('credentials-modal').classList.remove('active');
            loadDevices();
        }

        async function addDevice(e) {
            e.preventDefault();
            const form = e.target;
            const data = {
                name: form.name.value,
                category: form.category.value,
                extension: form.extension.value,
                conn_type: form.conn_type.value,
                auto_answer: form.auto_answer.value || null
            };

            try {
                const res = await fetch(API_BASE + '/devices', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify(data)
                });
                const result = await res.json();

                if (result.success) {
                    closeModal();
                    let credHtml = `
                        <p><strong>Extension:</strong> ${result.data.extension}</p>
                        <p><strong>Password:</strong> ${result.data.password}</p>
                        <p><strong>Name:</strong> ${result.data.name}</p>
                    `;
                    // Fetch server info to show TURN details
                    try {
                        const srvRes = await fetch(API_BASE + '/server');
                        const srv = await srvRes.json();
                        if (srv.turn_enabled && srv.turn_server) {
                            credHtml += `<hr style="margin:12px 0;border-color:#e2e8f0">
                                <p style="font-size:13px;color:#64748b;margin-bottom:6px">STUN/TURN (configure in app Network settings)</p>
                                <p><strong>STUN/TURN server:</strong> ${srv.turn_server}</p>
                                <p><strong>TURN username:</strong> ${srv.turn_username}</p>
                                <p><strong>TURN password:</strong> ${srv.turn_password}</p>
                            `;
                        }
                    } catch(e) {}
                    document.getElementById('credentials-display').innerHTML = credHtml;
                    document.getElementById('credentials-modal').classList.add('active');
                } else {
                    showAlert(result.error || 'Failed to add device', 'error');
                }
            } catch (e) {
                showAlert('Failed to add device', 'error');
            }
        }

        async function deleteDevice(ext, name) {
            if (!confirm(`Delete device ${ext} (${name})?`)) return;

            try {
                const res = await fetch(API_BASE + '/devices/' + ext, { method: 'DELETE' });
                const result = await res.json();

                if (result.success) {
                    showAlert('Device deleted');
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to delete', 'error');
                }
            } catch (e) {
                showAlert('Failed to delete device', 'error');
            }
        }

        function showRenameModal(ext, currentName) {
            document.getElementById('rename-ext').textContent = ext;
            document.getElementById('rename-extension').value = ext;
            document.getElementById('rename-name').value = currentName;
            document.getElementById('rename-modal').classList.add('active');
        }

        function closeRenameModal() {
            document.getElementById('rename-modal').classList.remove('active');
            document.getElementById('rename-form').reset();
        }

        async function renameDevice(e) {
            e.preventDefault();
            const ext = document.getElementById('rename-extension').value;
            const newName = document.getElementById('rename-name').value;

            try {
                const res = await fetch(API_BASE + '/devices/' + ext, {
                    method: 'PUT',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({ name: newName })
                });
                const result = await res.json();

                if (result.success) {
                    closeRenameModal();
                    showAlert('Device renamed');
                    loadDevices();
                } else {
                    showAlert(result.error || 'Failed to rename', 'error');
                }
            } catch (e) {
                showAlert('Failed to rename device', 'error');
            }
        }

        // Initial load
        loadDevices();
        loadCategories();
        loadRooms();

        // Auto-refresh status every 30 seconds
        setInterval(loadDevices, 30000);
    </script>
</body>
</html>
'''

class WebAdminHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass  # Suppress default logging

    def send_auth_required(self):
        self.send_response(401)
        self.send_header('WWW-Authenticate', 'Basic realm="Easy Asterisk Admin"')
        self.send_header('Content-type', 'text/html')
        self.end_headers()
        self.wfile.write(b'<h1>Authentication Required</h1>')

    def do_GET(self):
        if not check_auth(self.headers):
            self.send_auth_required()
            return

        path = urlparse(self.path).path

        if path == '/' or path == '/clients':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(HTML_TEMPLATE.encode())

        elif path == '/api/devices':
            devices = get_devices()
            self.send_json(devices)

        elif path == '/api/status':
            status = get_registered_endpoints()
            self.send_json(status)

        elif path == '/api/categories':
            categories = get_categories()
            self.send_json(categories)

        elif path == '/api/rooms':
            rooms = get_rooms()
            self.send_json(rooms)

        elif path == '/api/server':
            info = get_server_info()
            self.send_json(info)

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if not check_auth(self.headers):
            self.send_auth_required()
            return

        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        if path == '/api/devices':
            try:
                data = json.loads(body)
                success, result = add_device(
                    data['name'],
                    data['category'],
                    data['extension'],
                    data.get('conn_type', 'lan'),
                    data.get('auto_answer')
                )
                if success:
                    self.send_json({'success': True, 'data': result})
                else:
                    self.send_json({'success': False, 'error': result}, 400)
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)

        elif path.startswith('/api/rooms/') and path.endswith('/members'):
            # Add device to room: POST /api/rooms/{room_ext}/members with {device: ext}
            room_match = re.match(r'/api/rooms/(\d+)/members', path)
            if room_match:
                try:
                    room_ext = room_match.group(1)
                    data = json.loads(body)
                    device_ext = data.get('device')
                    if not device_ext:
                        self.send_json({'success': False, 'error': 'Device extension required'}, 400)
                        return
                    success, msg = add_device_to_room(room_ext, device_ext)
                    self.send_json({'success': success, 'message': msg})
                except Exception as e:
                    self.send_json({'success': False, 'error': str(e)}, 400)
            else:
                self.send_response(404)
                self.end_headers()

        elif path == '/api/rooms':
            # Create room: POST /api/rooms
            try:
                data = json.loads(body)
                success, msg = create_room(
                    data['extension'],
                    data['name'],
                    data.get('type', 'ring'),
                    data.get('timeout', '60')
                )
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)

        elif path == '/api/categories':
            # Create category: POST /api/categories
            try:
                data = json.loads(body)
                success, msg = create_category(
                    data['id'],
                    data['name'],
                    data.get('auto_answer', ''),
                    data.get('description', '')
                )
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)

        else:
            self.send_response(404)
            self.end_headers()

    def do_DELETE(self):
        if not check_auth(self.headers):
            self.send_auth_required()
            return

        path = urlparse(self.path).path

        # Delete device
        device_match = re.match(r'/api/devices/(\d+)$', path)
        if device_match:
            ext = device_match.group(1)
            success, msg = delete_device(ext)
            self.send_json({'success': success, 'message': msg})
            return

        # Remove device from room: DELETE /api/rooms/{room_ext}/members/{device_ext}
        room_member_match = re.match(r'/api/rooms/(\d+)/members/(\d+)', path)
        if room_member_match:
            room_ext = room_member_match.group(1)
            device_ext = room_member_match.group(2)
            success, msg = remove_device_from_room(room_ext, device_ext)
            self.send_json({'success': success, 'message': msg})
            return

        # Delete room: DELETE /api/rooms/{ext}
        room_match = re.match(r'/api/rooms/(\d+)$', path)
        if room_match:
            ext = room_match.group(1)
            success, msg = delete_room(ext)
            self.send_json({'success': success, 'message': msg})
            return

        # Delete category: DELETE /api/categories/{id}
        cat_match = re.match(r'/api/categories/([a-z0-9]+)$', path)
        if cat_match:
            cat_id = cat_match.group(1)
            success, msg = delete_category(cat_id)
            self.send_json({'success': success, 'message': msg})
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        if not check_auth(self.headers):
            self.send_auth_required()
            return

        path = urlparse(self.path).path
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length).decode('utf-8')

        # Change device category: PUT /api/devices/{ext}/category
        cat_match = re.match(r'/api/devices/(\d+)/category$', path)
        if cat_match:
            ext = cat_match.group(1)
            try:
                data = json.loads(body)
                new_cat = data.get('category', '').strip()
                if not new_cat:
                    self.send_json({'success': False, 'error': 'Category required'}, 400)
                    return
                success, msg = change_device_category(ext, new_cat)
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        # Rename device: PUT /api/devices/{ext}
        rename_match = re.match(r'/api/devices/(\d+)$', path)
        if rename_match:
            ext = rename_match.group(1)
            try:
                data = json.loads(body)
                new_name = data.get('name', '').strip()
                if not new_name:
                    self.send_json({'success': False, 'error': 'Name required'}, 400)
                    return
                success, msg = rename_device(ext, new_name)
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        # Rename room: PUT /api/rooms/{ext}
        room_rename_match = re.match(r'/api/rooms/(\d+)$', path)
        if room_rename_match:
            ext = room_rename_match.group(1)
            try:
                data = json.loads(body)
                new_name = data.get('name', '').strip()
                if not new_name:
                    self.send_json({'success': False, 'error': 'Name required'}, 400)
                    return
                success, msg = rename_room(ext, new_name)
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        # Rename category: PUT /api/categories/{id}
        cat_rename_match = re.match(r'/api/categories/([a-z0-9]+)$', path)
        if cat_rename_match:
            cat_id = cat_rename_match.group(1)
            try:
                data = json.loads(body)
                new_name = data.get('name', '').strip()
                if not new_name:
                    self.send_json({'success': False, 'error': 'Name required'}, 400)
                    return
                success, msg = rename_category(cat_id, new_name)
                self.send_json({'success': success, 'message': msg})
            except Exception as e:
                self.send_json({'success': False, 'error': str(e)}, 400)
            return

        self.send_response(404)
        self.end_headers()

    def send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

def main():
    with socketserver.TCPServer(("", PORT), WebAdminHandler) as httpd:
        print(f"Easy Asterisk Web Admin running on port {PORT}")
        httpd.serve_forever()

if __name__ == "__main__":
    main()
WEBADMIN
    chmod +x "$WEB_ADMIN_SCRIPT"
    print_success "Web admin script created"
}

create_web_admin_service() {
    if is_docker; then
        # In Docker, web admin is managed as a background process, not a systemd service
        print_success "Web admin service configured (Docker process mode)"
        return
    fi
    cat > "$WEB_ADMIN_SERVICE" << EOF
[Unit]
Description=Easy Asterisk Web Admin
After=network.target asterisk.service

[Service]
Type=simple
Environment=WEBADMIN_PORT=${WEB_ADMIN_PORT}
Environment=WEBADMIN_AUTH_DISABLED=${WEB_ADMIN_AUTH_DISABLED:-false}
ExecStart=/usr/bin/python3 ${WEB_ADMIN_SCRIPT}
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    print_success "Web admin service created"
}

setup_web_admin_auth() {
    print_header "Web Admin Authentication"
    echo "Set up login credentials for the web admin interface."
    echo ""

    read -p "Username [admin]: " wa_user
    wa_user="${wa_user:-admin}"

    while true; do
        read -s -p "Password: " wa_pass
        echo ""
        if [[ ${#wa_pass} -lt 6 ]]; then
            print_error "Password must be at least 6 characters"
            continue
        fi
        read -s -p "Confirm password: " wa_pass2
        echo ""
        if [[ "$wa_pass" != "$wa_pass2" ]]; then
            print_error "Passwords don't match"
            continue
        fi
        break
    done

    # Store with SHA256 hash
    local hash=$(echo -n "$wa_pass" | sha256sum | awk '{print $1}')
    echo "${wa_user}:{SHA256}${hash}" > "$WEB_ADMIN_HTPASSWD"
    chmod 600 "$WEB_ADMIN_HTPASSWD"
    print_success "Authentication configured for user: $wa_user"
}

web_admin_menu() {
    load_config
    local server_ip=$(hostname -I | awk '{print $1}')

    print_header "Web Admin Management"

    # Check current status (Docker-aware)
    local status="stopped"
    if webadmin_running; then
        status="running"
    fi

    echo "  Status: ${status^^}"
    if [[ "$status" == "running" ]]; then
        echo "  URL: http://${server_ip}:${WEB_ADMIN_PORT}/clients"
        [[ -n "$DOMAIN_NAME" ]] && echo "  URL: http://${DOMAIN_NAME}:${WEB_ADMIN_PORT}/clients"
    fi
    if [[ "${WEB_ADMIN_AUTH_DISABLED:-}" == "true" ]]; then
        echo "  Auth: DISABLED (reverse proxy mode)"
    else
        echo "  Auth: Internal basic auth"
    fi
    echo ""
    echo "  1) Start Web Admin"
    echo "  2) Stop Web Admin"
    echo "  3) Restart Web Admin"
    echo "  4) Configure Authentication"
    echo "  5) Change Port (current: ${WEB_ADMIN_PORT})"
    echo "  6) View Logs"
    echo "  7) Reverse Proxy Setup (Caddy)"
    echo "  0) Back"
    echo ""
    read -p "  Select: " choice

    case $choice in
        1)
            # Stop any existing instance first
            stop_webadmin 2>/dev/null
            print_info "Installing/updating web admin..."
            start_webadmin
            if webadmin_running; then
                echo ""
                echo "  Access at: http://${server_ip}:${WEB_ADMIN_PORT}/clients"
                [[ -n "$DOMAIN_NAME" ]] && echo "  Or: http://${DOMAIN_NAME}:${WEB_ADMIN_PORT}/clients"
            fi
            ;;
        2)
            print_info "Stopping web admin..."
            stop_webadmin
            if ! is_docker; then
                systemctl disable easy-asterisk-webadmin 2>/dev/null || true
            fi
            ;;
        3)
            restart_webadmin
            ;;
        4)
            setup_web_admin_auth
            restart_webadmin
            ;;
        5)
            read -p "New port [${WEB_ADMIN_PORT}]: " new_port
            new_port="${new_port:-$WEB_ADMIN_PORT}"
            if [[ "$new_port" =~ ^[0-9]+$ ]] && [[ "$new_port" -ge 1024 ]] && [[ "$new_port" -le 65535 ]]; then
                WEB_ADMIN_PORT="$new_port"
                save_config
                restart_webadmin
                print_success "Port changed to $new_port"
            else
                print_error "Invalid port (must be 1024-65535)"
            fi
            ;;
        6)
            if is_docker; then
                echo "  In Docker, check logs with: docker logs easy-asterisk"
            else
                journalctl -u easy-asterisk-webadmin -n 50 --no-pager
            fi
            ;;
        7)
            print_header "Reverse Proxy Setup (Caddy)"
            echo ""
            echo "  When using a reverse proxy like Caddy with HTTPS and its own"
            echo "  basic auth, you can disable internal authentication."
            echo ""
            echo "  Current auth: $([[ "${WEB_ADMIN_AUTH_DISABLED:-}" == "true" ]] && echo "DISABLED" || echo "ENABLED")"
            echo ""
            echo "  1) Disable internal auth (for reverse proxy with its own auth)"
            echo "  2) Enable internal auth (standalone use)"
            echo "  3) Show Caddyfile example"
            echo "  0) Back"
            echo ""
            read -p "  Select: " rp_choice
            case $rp_choice in
                1)
                    WEB_ADMIN_AUTH_DISABLED="true"
                    save_config
                    create_web_admin_script
                    restart_webadmin
                    print_success "Internal auth disabled. Use Caddy basic_auth for security."
                    ;;
                2)
                    WEB_ADMIN_AUTH_DISABLED="false"
                    save_config
                    create_web_admin_script
                    if [[ ! -f "$WEB_ADMIN_HTPASSWD" ]]; then
                        setup_web_admin_auth
                    fi
                    restart_webadmin
                    print_success "Internal auth enabled"
                    ;;
                3)
                    echo ""
                    echo "  Add to your Caddyfile (docker-compose):"
                    echo ""
                    echo "  ─────────────────────────────────────────"
                    echo "  webadmin.yourdomain.com {"
                    echo "      basicauth /* {"
                    echo "          admin \$2a\$14\$... # use: caddy hash-password"
                    echo "      }"
                    echo "      reverse_proxy host.docker.internal:${WEB_ADMIN_PORT}"
                    echo "  }"
                    echo "  ─────────────────────────────────────────"
                    echo ""
                    echo "  Generate password hash: docker exec -it caddy caddy hash-password"
                    echo "  Then paste the hash after the username in Caddyfile."
                    echo ""
                    echo "  If Caddy can't reach host.docker.internal, use your server's"
                    echo "  LAN IP instead (e.g., 192.168.1.x:${WEB_ADMIN_PORT})"
                    echo ""
                    ;;
            esac
            ;;
        0) return ;;
    esac
}

configure_vpn_stun_ice() {
    load_config
    clear
    print_header "VPN STUN/ICE Configuration"

    echo "  This configures ICE (Interactive Connectivity Establishment) and"
    echo "  STUN (Session Traversal Utilities for NAT) for third-party VPNs."
    echo ""
    echo "  ─────────────────────────────────────────────────────────────"
    echo "  When do you need this?"
    echo ""
    echo "  • Your VPN does NAT between endpoints (audio fails or is one-way)"
    echo "  • Caller and receiver are on different VPN segments"
    echo "  • Direct VPN routing doesn't work for UDP/RTP traffic"
    echo ""
    echo "  When do you NOT need this?"
    echo ""
    echo "  • VPN gives both sides IPs on the same subnet (direct routing)"
    echo "  • Audio works fine without STUN"
    echo "  ─────────────────────────────────────────────────────────────"
    echo ""

    local current_stun="${CUSTOM_STUN_SERVER:-Not configured}"
    local current_ice="${VPN_ICE_ENABLED:-n}"
    echo -e "  Current Status:"
    echo -e "    VPN ICE: $([[ "$current_ice" == "y" ]] && echo "${GREEN}Enabled${NC}" || echo "${YELLOW}Disabled${NC}")"
    echo -e "    STUN Server: ${CYAN}${current_stun}${NC}"
    echo ""

    echo "  1) Enable VPN ICE + self-hosted STUN (recommended for DNS filtering)"
    echo "  2) Enable VPN ICE + Google STUN (requires DNS access)"
    echo "  3) Enable VPN ICE + custom STUN server"
    echo "  4) Disable VPN ICE (standard LAN mode)"
    echo "  5) Test current STUN server"
    echo "  6) Run VPN diagnostics"
    echo "  7) Check DNS whitelist"
    echo "  0) Back"
    echo ""
    read -p "  Select: " stun_choice

    case $stun_choice in
        1)
            # Self-hosted STUN via coturn
            local server_ip=$(hostname -I | awk '{print $1}')
            echo ""
            echo "  Self-hosted STUN uses coturn on this server (port 3478)."
            echo "  No external DNS dependencies - everything by IP."
            echo ""

            # Detect VPN IPs for suggestion
            local vpn_ip=""
            while IFS= read -r line; do
                local iface=$(echo "$line" | awk '{print $2}' | tr -d ':')
                local ip_addr=$(echo "$line" | awk '{print $4}' | cut -d'/' -f1)
                if [[ "$iface" =~ ^(tun|tap|wg|tailscale|utun|ppp|nordlynx) ]]; then
                    vpn_ip="$ip_addr"
                    break
                fi
            done < <(ip -o -f inet addr show scope global 2>/dev/null)

            local suggested_ip="${vpn_ip:-$server_ip}"
            read -p "  STUN server IP [${suggested_ip}]: " stun_ip
            stun_ip="${stun_ip:-$suggested_ip}"

            read -p "  STUN port [3478]: " stun_port
            stun_port="${stun_port:-3478}"

            VPN_ICE_ENABLED="y"
            CUSTOM_STUN_SERVER="${stun_ip}:${stun_port}"
            save_config
            repair_core_configs
            generate_pjsip_conf
            asterisk -rx "core reload" >/dev/null 2>&1 || true

            print_success "VPN ICE enabled with self-hosted STUN: ${CUSTOM_STUN_SERVER}"
            echo ""
            echo "  Make sure coturn is running on port ${stun_port}:"
            echo "    Docker: docker compose --profile stun up -d"
            echo "    Manual: apt install coturn && systemctl start coturn"
            echo ""
            echo "  Configure Sipnetic STUN server: ${CUSTOM_STUN_SERVER}"
            ;;
        2)
            # Google STUN
            echo ""
            echo -e "  ${YELLOW}Requires DNS access to: stun.l.google.com${NC}"
            echo "  Add this domain to your DNS whitelist on all networks"
            echo "  (server, caller, and receiver)."
            echo ""
            read -p "  Continue? [y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                VPN_ICE_ENABLED="y"
                CUSTOM_STUN_SERVER="stun.l.google.com:19302"
                save_config
                repair_core_configs
                generate_pjsip_conf
                asterisk -rx "core reload" >/dev/null 2>&1 || true
                print_success "VPN ICE enabled with Google STUN"
                echo ""
                echo "  DNS whitelist required: stun.l.google.com (UDP 19302)"
            fi
            ;;
        3)
            # Custom STUN
            echo ""
            read -p "  STUN server address (host:port): " custom_stun
            if [[ -n "$custom_stun" ]]; then
                VPN_ICE_ENABLED="y"
                CUSTOM_STUN_SERVER="$custom_stun"
                save_config
                repair_core_configs
                generate_pjsip_conf
                asterisk -rx "core reload" >/dev/null 2>&1 || true
                print_success "VPN ICE enabled with custom STUN: ${custom_stun}"
            else
                print_error "No STUN server specified"
            fi
            ;;
        4)
            # Disable
            VPN_ICE_ENABLED="n"
            CUSTOM_STUN_SERVER=""
            save_config
            repair_core_configs
            generate_pjsip_conf
            asterisk -rx "core reload" >/dev/null 2>&1 || true
            print_success "VPN ICE disabled (standard LAN mode)"
            ;;
        5)
            # Test STUN
            echo ""
            if [[ -n "$CUSTOM_STUN_SERVER" ]]; then
                local stun_host=$(echo "$CUSTOM_STUN_SERVER" | cut -d: -f1)
                local stun_port=$(echo "$CUSTOM_STUN_SERVER" | cut -d: -f2)
                stun_port="${stun_port:-3478}"

                echo "  Testing STUN server: ${CUSTOM_STUN_SERVER}"
                echo ""

                # DNS test
                if [[ "$stun_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    print_success "STUN server is an IP address (no DNS needed)"
                else
                    if nslookup "$stun_host" >/dev/null 2>&1; then
                        print_success "DNS resolves: ${stun_host}"
                    else
                        print_error "DNS BLOCKED: ${stun_host}"
                        echo "  Add to DNS whitelist or use IP address instead"
                    fi
                fi

                # Connectivity test
                if ping -c 2 -W 3 "$stun_host" >/dev/null 2>&1; then
                    print_success "STUN host reachable: ${stun_host}"
                else
                    print_warn "STUN host not pingable (may still work if ICMP blocked)"
                fi

                # Port test via Asterisk
                if command -v asterisk &>/dev/null; then
                    local rtp_check=$(asterisk -rx "rtp show settings" 2>/dev/null | grep -i "stun\|ice" || echo "")
                    if [[ -n "$rtp_check" ]]; then
                        echo ""
                        echo "  Asterisk RTP settings:"
                        echo "$rtp_check" | while IFS= read -r line; do
                            echo "    $line"
                        done
                    fi
                fi
            else
                print_warn "No STUN server configured"
                echo "  Configure one using options 1-3 above"
            fi
            ;;
        6)
            # VPN diagnostics
            if command -v vpn-diagnostics &>/dev/null; then
                vpn-diagnostics
            elif [[ -f /usr/local/bin/vpn-diagnostics ]]; then
                bash /usr/local/bin/vpn-diagnostics
            else
                print_error "vpn-diagnostics not found"
                echo "  Install: copy scripts/vpn-diagnostics.sh to /usr/local/bin/vpn-diagnostics"
            fi
            ;;
        7)
            # DNS whitelist
            if command -v dns-whitelist &>/dev/null; then
                dns-whitelist --check
            elif [[ -f /usr/local/bin/dns-whitelist ]]; then
                bash /usr/local/bin/dns-whitelist --check
            else
                print_error "dns-whitelist not found"
                echo "  Install: copy scripts/dns-whitelist.sh to /usr/local/bin/dns-whitelist"
            fi
            ;;
        0) return ;;
    esac
}

submenu_server() {
    clear
    print_header "Server Settings"
    echo "  1) Setup Internet Access (TLS/Certs/NAT)"
    echo "  2) Force re-sync Caddy certs"
    echo "  3) Show port/firewall requirements"
    echo "  4) Interactive Firewall Guide"
    echo "  5) Test SIP connectivity"
    echo "  6) Verify CIDR/NAT config"
    echo "  7) Watch Live Logs"
    echo "  8) Router Doctor"
    echo "  9) Configure VLAN/VPN Subnets"
    echo " 10) Provisioning Manager"
    echo " 11) Web Admin (Client Management)"
    echo " 12) VPN STUN/ICE Configuration"
    echo "  0) Back"
    read -p "  Select: " choice
    case $choice in
        1) setup_internet_access ;;
        2) setup_caddy_cert_sync "force" ;;
        3) show_port_requirements ;;
        4) show_firewall_guide ;;
        5) test_sip_connectivity ;;
        6) verify_cidr_config ;;
        7) watch_live_logs ;;
        8) router_doctor ;;
        9) configure_vlan_subnets ;;
        10) provisioning_manager_menu ;;
        11) web_admin_menu ;;
        12) configure_vpn_stun_ice ;;
        0) return ;;
    esac
    [[ "$choice" != "0" ]] && read -p "Press Enter..."
    [[ "$choice" != "0" ]] && submenu_server
}

submenu_devices() {
    clear
    print_header "Device Management"
    echo "  1) Add device"
    echo "  2) Remove device"
    echo "  3) Rename device"
    echo "  4) List devices"
    echo "  5) Manage categories"
    echo "  6) Manage rooms"
    echo "  7) Export Clients"
    echo "  8) Import Clients"
    echo "  0) Back"
    read -p "  Select: " choice
    case $choice in
        1) add_device_menu ;;
        2) remove_device ;;
        3) rename_device ;;
        4) show_registered_devices ;;
        5) manage_categories ;;
        6) manage_rooms ;;
        7) export_clients ;;
        8) import_clients ;;
        0) return ;;
    esac
    [[ "$choice" != "0" ]] && read -p "Press Enter..."
    [[ "$choice" != "0" ]] && submenu_devices
}

export_clients() {
    print_header "Export Client Configurations"
    load_config
    initialize_default_categories

    # Create export directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local export_dir="/tmp/asterisk_export_${timestamp}"
    local export_file="/root/asterisk-clients-${timestamp}.tar.gz"

    mkdir -p "$export_dir"

    # Check if there are any devices to export
    if ! grep -q "^; === Device:" /etc/asterisk/pjsip.conf 2>/dev/null; then
        print_error "No client devices found to export"
        rm -rf "$export_dir"
        return
    fi

    # Export devices from pjsip.conf (everything after transport definitions)
    echo "Extracting client devices..."
    awk '/^; === Device:/{flag=1} flag' /etc/asterisk/pjsip.conf > "$export_dir/devices.conf"

    # Count devices
    local device_count=$(grep -c "^; === Device:" "$export_dir/devices.conf")

    # Export categories
    if [[ -f "$CATEGORIES_FILE" ]]; then
        echo "Exporting categories..."
        cp "$CATEGORIES_FILE" "$export_dir/categories.conf"
    fi

    # Export rooms
    if [[ -f "$ROOMS_FILE" ]]; then
        echo "Exporting rooms..."
        cp "$ROOMS_FILE" "$export_dir/rooms.conf"
    fi

    # Create metadata file
    cat > "$export_dir/export_info.txt" << EOF
Easy Asterisk Client Export
Export Date: $(date)
Device Count: $device_count
Domain: ${DOMAIN_NAME:-Not configured}
TLS Enabled: ${ENABLE_TLS:-no}
Exported by: $(whoami)
Hostname: $(hostname)
EOF

    # Create tar.gz archive
    echo "Creating archive..."
    tar -czf "$export_file" -C /tmp "asterisk_export_${timestamp}" 2>/dev/null

    # Cleanup temp directory
    rm -rf "$export_dir"

    if [[ -f "$export_file" ]]; then
        print_success "Export completed successfully!"
        echo ""
        echo "  Exported: $device_count devices"
        echo "  File: $export_file"
        echo "  Size: $(du -h "$export_file" | cut -f1)"
        echo ""
        echo "  To import on another system:"
        echo "  1) Copy file to the target server"
        echo "  2) Run Easy Asterisk"
        echo "  3) Select 'Client Settings' -> 'Import Clients'"
    else
        print_error "Export failed"
    fi
}

import_clients() {
    print_header "Import Client Configurations"
    load_config
    initialize_default_categories

    echo "Available export files in /root:"
    local files=($(ls -t /root/asterisk-clients-*.tar.gz 2>/dev/null))

    if [[ ${#files[@]} -eq 0 ]]; then
        echo ""
        read -p "Enter full path to export file: " import_file
    else
        echo ""
        local i=1
        for f in "${files[@]}"; do
            echo "  $i) $(basename "$f") - $(du -h "$f" | cut -f1) - $(date -r "$f" '+%Y-%m-%d %H:%M')"
            ((i++))
        done
        echo "  0) Enter custom path"
        echo ""
        read -p "Select file [1]: " file_choice
        file_choice="${file_choice:-1}"

        if [[ "$file_choice" == "0" ]]; then
            read -p "Enter full path to export file: " import_file
        elif [[ "$file_choice" -ge 1 && "$file_choice" -le ${#files[@]} ]]; then
            import_file="${files[$((file_choice-1))]}"
        else
            print_error "Invalid selection"
            return
        fi
    fi

    if [[ ! -f "$import_file" ]]; then
        print_error "File not found: $import_file"
        return
    fi

    # Extract to temp directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local import_dir="/tmp/asterisk_import_${timestamp}"
    mkdir -p "$import_dir"

    echo "Extracting archive..."
    tar -xzf "$import_file" -C "$import_dir" 2>/dev/null

    # Find the extracted directory
    local extract_dir=$(find "$import_dir" -type d -name "asterisk_export_*" | head -1)
    if [[ ! -d "$extract_dir" ]]; then
        print_error "Invalid export file format"
        rm -rf "$import_dir"
        return
    fi

    # Show export info
    if [[ -f "$extract_dir/export_info.txt" ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        cat "$extract_dir/export_info.txt"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""
    fi

    # Count devices to import
    local device_count=0
    if [[ -f "$extract_dir/devices.conf" ]]; then
        device_count=$(grep -c "^; === Device:" "$extract_dir/devices.conf")
    fi

    if [[ $device_count -eq 0 ]]; then
        print_error "No devices found in export file"
        rm -rf "$import_dir"
        return
    fi

    echo "This will import $device_count device(s)."
    echo ""
    read -p "Import mode [1=Merge, 2=Replace All]: " import_mode
    import_mode="${import_mode:-1}"

    if [[ "$import_mode" == "2" ]]; then
        echo ""
        echo "${RED}WARNING: This will DELETE ALL existing devices!${NC}"
        read -p "Type 'DELETE ALL' to confirm: " confirm
        if [[ "$confirm" != "DELETE ALL" ]]; then
            print_error "Import cancelled"
            rm -rf "$import_dir"
            return
        fi
    fi

    # Backup existing configurations
    echo "Backing up current configuration..."
    backup_config "/etc/asterisk/pjsip.conf"
    backup_config "$CATEGORIES_FILE"
    backup_config "$ROOMS_FILE"

    # Import devices
    if [[ "$import_mode" == "2" ]]; then
        # Replace mode - remove all existing devices
        echo "Removing existing devices..."
        local temp_pjsip="/tmp/pjsip_base_${timestamp}.conf"
        awk '/^; === Device:/{exit} {print}' /etc/asterisk/pjsip.conf > "$temp_pjsip"
        cat "$temp_pjsip" "$extract_dir/devices.conf" > /etc/asterisk/pjsip.conf
        rm -f "$temp_pjsip"
        print_success "Replaced all devices with imported devices"
    else
        # Merge mode - check for conflicts
        echo "Checking for extension conflicts..."
        local conflicts=0
        local conflict_list=""

        while IFS= read -r line; do
            if [[ "$line" =~ ^\[([0-9]+)\]$ ]]; then
                local ext="${BASH_REMATCH[1]}"
                if grep -q "^\[${ext}\]" /etc/asterisk/pjsip.conf 2>/dev/null; then
                    conflicts=$((conflicts + 1))
                    conflict_list="${conflict_list}${ext} "
                fi
            fi
        done < "$extract_dir/devices.conf"

        if [[ $conflicts -gt 0 ]]; then
            echo ""
            echo "${YELLOW}Warning: Found $conflicts conflicting extension(s): $conflict_list${NC}"
            read -p "Skip conflicting devices? [Y/n]: " skip_conflicts
            skip_conflicts="${skip_conflicts:-Y}"

            if [[ ! "$skip_conflicts" =~ ^[Yy]$ ]]; then
                print_error "Import cancelled"
                rm -rf "$import_dir"
                return
            fi

            # Import only non-conflicting devices
            echo "Importing non-conflicting devices..."
            local temp_import="/tmp/import_filtered_${timestamp}.conf"
            local skip_device=0
            local pending_header=""

            while IFS= read -r line; do
                if [[ "$line" == "; === Device:"* ]]; then
                    skip_device=0
                    pending_header="$line"
                elif [[ "$line" =~ ^\[([0-9]+)\]$ ]]; then
                    local ext="${BASH_REMATCH[1]}"
                    if grep -q "^\[${ext}\]" /etc/asterisk/pjsip.conf 2>/dev/null; then
                        skip_device=1
                        if [[ -n "$pending_header" ]]; then
                            echo "  Skipping extension $ext (already exists)"
                            pending_header=""
                        fi
                    else
                        if [[ -n "$pending_header" ]]; then
                            echo "$pending_header" >> "$temp_import"
                            pending_header=""
                        fi
                        echo "$line" >> "$temp_import"
                    fi
                elif [[ $skip_device -eq 0 ]]; then
                    echo "$line" >> "$temp_import"
                fi
            done < "$extract_dir/devices.conf"

            cat "$temp_import" >> /etc/asterisk/pjsip.conf
            rm -f "$temp_import"
        else
            # No conflicts, import all
            echo "No conflicts found, importing all devices..."
            cat "$extract_dir/devices.conf" >> /etc/asterisk/pjsip.conf
        fi

        print_success "Devices imported successfully"
    fi

    # Import categories (merge, skip duplicates)
    if [[ -f "$extract_dir/categories.conf" ]]; then
        echo "Importing categories..."
        while IFS='|' read -r cat_id cat_name auto_answer description; do
            [[ "$cat_id" =~ ^# ]] && continue
            [[ -z "$cat_id" ]] && continue

            # Skip if already exists
            if grep -q "^${cat_id}|" "$CATEGORIES_FILE" 2>/dev/null; then
                echo "  Skipping category '$cat_id' (already exists)"
            else
                echo "${cat_id}|${cat_name}|${auto_answer}|${description}" >> "$CATEGORIES_FILE"
                echo "  Imported category: $cat_name"
            fi
        done < "$extract_dir/categories.conf"
    fi

    # Import rooms (merge, skip duplicates)
    if [[ -f "$extract_dir/rooms.conf" ]]; then
        echo "Importing rooms..."
        while IFS='|' read -r ext name members timeout type; do
            [[ "$ext" =~ ^# ]] && continue
            [[ -z "$ext" ]] && continue

            # Skip if already exists
            if grep -q "^${ext}|" "$ROOMS_FILE" 2>/dev/null; then
                echo "  Skipping room '$name' (extension $ext already exists)"
            else
                echo "${ext}|${name}|${members}|${timeout}|${type}" >> "$ROOMS_FILE"
                echo "  Imported room: $name (ext $ext)"
            fi
        done < "$extract_dir/rooms.conf"
    fi

    # Cleanup
    rm -rf "$import_dir"

    # Reload Asterisk
    echo ""
    echo "Reloading Asterisk configuration..."
    asterisk -rx "pjsip reload" >/dev/null 2>&1
    rebuild_dialplan quiet

    print_success "Import completed successfully!"
    echo ""
    echo "  Run 'List devices' to verify imported clients"
}

submenu_client() {
    clear
    print_header "Client Settings"
    echo "  1) Configure Local Client"
    echo "  2) Configure PTT Button"
    echo "  3) Run Diagnostics"
    echo "  0) Back"
    read -p "  Select: " choice
    case $choice in
        1) configure_local_client ;;
        2) configure_ptt_menu ;;
        3) run_client_diagnostics ;;
        0) return ;;
    esac
    [[ "$choice" != "0" ]] && read -p "Press Enter..."
    [[ "$choice" != "0" ]] && submenu_client
}

fix_audio_manually() {
    if is_docker; then
        print_error "Audio management not available in Docker (no local audio hardware)"
        return
    fi
    print_header "Manual Audio Fix"
    load_config
    local t_user="${KIOSK_USER:-$SUDO_USER}"
    t_user="${t_user:-$USER}"
    local t_uid=$(id -u "$t_user" 2>/dev/null)
    local user_dbus="XDG_RUNTIME_DIR=/run/user/$t_uid"

    echo "Fixing audio for user: $t_user"
    echo ""

    # Restart PipeWire services
    echo "Restarting PipeWire services..."
    sudo -u "$t_user" $user_dbus systemctl --user restart pipewire pipewire-pulse 2>/dev/null || true
    sleep 2

    # Unmute audio
    echo "Unmuting audio sources and sinks..."
    sudo -u "$t_user" $user_dbus pactl set-source-mute @DEFAULT_SOURCE@ 0 2>/dev/null && echo "  ✓ Microphone unmuted" || echo "  ✗ Failed to unmute microphone"
    sudo -u "$t_user" $user_dbus pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null && echo "  ✓ Speaker unmuted" || echo "  ✗ Failed to unmute speaker"

    # Set volume
    echo "Setting volume levels to 75%..."
    sudo -u "$t_user" $user_dbus pactl set-source-volume @DEFAULT_SOURCE@ 75% 2>/dev/null && echo "  ✓ Microphone volume set" || echo "  ✗ Failed to set microphone volume"
    sudo -u "$t_user" $user_dbus pactl set-sink-volume @DEFAULT_SINK@ 75% 2>/dev/null && echo "  ✓ Speaker volume set" || echo "  ✗ Failed to set speaker volume"

    echo ""
    echo "Current audio status:"
    local src_mute=$(sudo -u "$t_user" $user_dbus pactl get-source-mute @DEFAULT_SOURCE@ 2>/dev/null | awk '{print $2}')
    local sink_mute=$(sudo -u "$t_user" $user_dbus pactl get-sink-mute @DEFAULT_SINK@ 2>/dev/null | awk '{print $2}')
    echo "  Microphone: ${src_mute:-unknown}"
    echo "  Speaker:    ${sink_mute:-unknown}"

    echo ""
    echo "Restarting Baresip..."
    sudo -u "$t_user" $user_dbus systemctl --user restart baresip 2>/dev/null && echo "  ✓ Baresip restarted" || echo "  ✗ Failed to restart Baresip"
}

submenu_tools() {
    clear
    print_header "Tools"

    if is_docker; then
        echo "  1) Room Directory"
        echo "  2) Update Asterisk (Docker)"
        echo "  3) VPN Diagnostics"
        echo "  4) DNS Whitelist Check"
        echo "  0) Back"
        read -p "  Select: " choice
        case $choice in
            1) show_room_directory ;;
            2) manual_update_asterisk ;;
            3)
                if [[ -f /usr/local/bin/vpn-diagnostics ]]; then
                    bash /usr/local/bin/vpn-diagnostics
                else
                    print_error "vpn-diagnostics not found"
                fi
                ;;
            4)
                if [[ -f /usr/local/bin/dns-whitelist ]]; then
                    bash /usr/local/bin/dns-whitelist --check
                else
                    print_error "dns-whitelist not found"
                fi
                ;;
            0) return ;;
        esac
    else
        echo "  1) Audio Test"
        echo "  2) Verify Audio/Codec Setup"
        echo "  3) Fix Audio (Unmute & Restart)"
        echo "  4) Room Directory"
        echo "  5) Manual Update Asterisk"
        echo "  0) Back"
        read -p "  Select: " choice
        case $choice in
            1) run_audio_test ;;
            2) verify_audio_setup ;;
            3) fix_audio_manually ;;
            4) show_room_directory ;;
            5) manual_update_asterisk ;;
            0) return ;;
        esac
    fi
    [[ "$choice" != "0" ]] && read -p "Press Enter..."
    [[ "$choice" != "0" ]] && submenu_tools
}

main() {
    check_root
    load_config
    show_main_menu
}

main "$@"
