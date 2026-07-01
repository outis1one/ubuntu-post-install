#!/bin/bash
# services/frigate.sh — AI-powered NVR for security cameras (Frigate).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash frigate.sh
# (Docker must already be installed when run standalone)
#
# Ported from ubuntu-post-install-24.04-crowdsec.sh (# ---- FRIGATE NVR ----).
# Own ~/docker/frigate/ with a standalone docker-compose.yml + .env + config.yml.
# Auto-enables /dev/dri/renderD128 for hardware detection (Intel/AMD) when present.
# Interactively prompts for cameras — RTSP user/pass/IP go in .env as
# FRIGATE_* vars, which config.yml references via Frigate's {FRIGATE_VAR}
# substitution syntax so credentials never appear in the YAML directly.
# Skip the camera prompts to get a starter config.yml to edit by hand.

# ── Standalone bootstrap ──────────────────────────────────────────────────────
# Detected when the script is executed directly rather than sourced by setup.sh.
# Sets up helpers and globals, then defers execution until after the function
# definition at the bottom of this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        # Full repo present — use the real helpers (picks up ~/docker/.config too)
        # shellcheck source=../lib/common.sh
        source "$_COMMON"
    else
        # One-off copy — inline minimal stubs so the script works without the repo
        log_info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
        log_success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
        log_warning() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
        log_error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

        require_docker() {
            command -v docker &>/dev/null || {
                log_error "Docker not found. Install it first:"
                log_error "  curl -fsSL https://get.docker.com | sudo sh"
                return 1
            }
            docker compose version &>/dev/null || {
                log_error "Docker Compose plugin missing:"
                log_error "  sudo apt-get install -y docker-compose-plugin"
                return 1
            }
        }

        ensure_docker_dir_ownership() {
            chown -R "$ACTUAL_USER:$ACTUAL_USER" "$@" 2>/dev/null || true
        }

        # Match common.sh's eval-based pattern so local vars in install_* are set correctly
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

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3" _extra="${4:-}"
            local _caddy_dir="$DOCKER_DIR/caddy"
            local _caddyfile="$_caddy_dir/Caddyfile"
            local _display_port="${_upstream##*:}"

            # Determine mode: local Caddy, remote Caddy, or none
            local _mode="none"
            [[ -d "$_caddy_dir" ]] && _mode="local"
            [[ -n "${CADDY_REMOTE_HOST:-}" ]] && [[ "$_mode" != "local" ]] && _mode="remote"
            [[ "$_mode" == "none" ]] && {
                log_info "Access $_name directly on port $_display_port."
                return 0
            }

            echo ""
            local _do_caddy=""
            if [[ "$_mode" == "remote" ]]; then
                log_info "Remote Caddy configured (${CADDY_REMOTE_HOST})."
                log_info "A snippet file will be saved to ~/docker/caddy-snippets/."
            fi
            read -r -p "  Configure Caddy reverse proxy for $_name? [y/N]: " _do_caddy
            [[ "${_do_caddy,,}" == "y" ]] || {
                log_info "Skipping — access at: http://localhost:$_display_port"
                return 0
            }

            # Domain prompt — pre-fill from SITE_DOMAIN when available
            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

            # Build upstream — remote Caddy uses host IP:port, not container name
            local _block_upstream="$_upstream"
            if [[ "$_mode" == "remote" ]]; then
                _block_upstream="${CADDY_REMOTE_HOST}:${_display_port}"
            fi

            local _site_block
            _site_block="$(cat << CBLOCK

# $_name
${_domain} {
    reverse_proxy ${_block_upstream}

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "SAMEORIGIN"
        Referrer-Policy "strict-origin-when-cross-origin"
    }

    log {
        output file /var/log/caddy/${_domain}.log
        format json
    }
${_extra}
}
CBLOCK
)"

            if [[ "$_mode" == "local" ]]; then
                if [[ -f "$_caddyfile" ]]; then
                    local _bk="$_caddy_dir/Caddyfile.backup.$(date +%Y%m%d-%H%M%S)"
                    cp "$_caddyfile" "$_bk"
                    log_info "Backed up Caddyfile to $(basename "$_bk")"
                else
                    touch "$_caddyfile"
                fi

                if grep -q "^${_domain}" "$_caddyfile" 2>/dev/null; then
                    log_warning "$_domain already in Caddyfile"
                    local _ow=""
                    read -r -p "  Overwrite? [y/N]: " _ow
                    [[ "${_ow,,}" == "y" ]] || { log_info "Keeping existing entry."; return 0; }
                    sed -i "/^${_domain}/,/^}/d" "$_caddyfile"
                fi

                printf '%s\n' "$_site_block" >> "$_caddyfile"
                log_success "Added $_domain to Caddyfile"
                docker exec caddy caddy fmt --overwrite /etc/caddy/Caddyfile 2>/dev/null || true
                if docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null; then
                    log_success "$_name accessible at: https://$_domain"
                else
                    log_warning "Reload failed — check: docker logs caddy"
                    log_info "Manual reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
                fi
            else
                local _snippet_dir="$DOCKER_DIR/caddy-snippets"
                local _snippet_file="$_snippet_dir/${_subdomain}.caddy"
                mkdir -p "$_snippet_dir"
                printf '%s\n' "$_site_block" > "$_snippet_file"
                chown "$ACTUAL_USER:$ACTUAL_USER" "$_snippet_file" 2>/dev/null || true
                log_success "Snippet saved: $_snippet_file"
                log_info "Copy to Caddy machine:"
                log_info "  scp $_snippet_file caddy-host:~/caddy-snippets/"
                log_info "  rsync -av $_snippet_dir/ caddy-host:~/caddy-snippets/  (all at once)"
            fi
        }
        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    # Globals — ACTUAL_USER/ACTUAL_HOME must come before DOCKER_DIR
    # ($HOME under sudo is /root, not the real user's home)
    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"
    SITE_CADDY_NET="${SITE_CADDY_NET:-caddy_net}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service frigate cameras "AI-powered NVR — object detection on security cameras (Frigate)" 5000

# ── Existing-config parsing (best-effort) ────────────────────────────────────
# Populates the CAM_* arrays (declared by install_frigate) plus ENV_MAP by
# reading an already-generated config.yml + .env. Only understands the shape
# this installer itself writes; heavily hand-edited files may not parse
# cleanly — the caller always offers a backup-and-fresh option as a fallback.
_frigate_parse_existing() {
    local cfg="$1" env="$2"
    declare -gA ENV_MAP=()
    local k v
    while IFS='=' read -r k v; do
        [[ "$k" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${k// /}" ]] && continue
        ENV_MAP["$k"]="$v"
    done < "$env"

    local re_stream_key='^[[:space:]]{4}([a-z0-9_]+):[[:space:]]*$'
    local re_rtsp_line='rtsp://\{([A-Za-z0-9_]+)\}:\{([A-Za-z0-9_]+)\}@\{([A-Za-z0-9_]+)\}:([0-9]+)(.*)$'
    local re_cam_key='^[[:space:]]{2}([a-z0-9_]+):[[:space:]]*$'
    local re_enabled='^[[:space:]]{4}enabled:[[:space:]]*(true|false)'
    local re_notify_key='^[[:space:]]{4}notifications:'
    local re_notify_val='^[[:space:]]{6}enabled:[[:space:]]*(true|false)'

    declare -A _MAIN_OF=() _SUB_OF=() _PORT_OF=() _VU_OF=() _VP_OF=() _VI_OF=()
    local _order=() _stream="" in_go2rtc=false line

    while IFS= read -r line; do
        if [[ "$line" =~ ^go2rtc: ]]; then in_go2rtc=true; continue; fi
        if $in_go2rtc && [[ "$line" =~ ^[a-zA-Z] ]]; then in_go2rtc=false; fi
        $in_go2rtc || continue
        if [[ "$line" =~ $re_stream_key ]]; then _stream="${BASH_REMATCH[1]}"; continue; fi
        if [[ -n "$_stream" ]] && [[ "$line" =~ $re_rtsp_line ]]; then
            local vu="${BASH_REMATCH[1]}" vp="${BASH_REMATCH[2]}" vi="${BASH_REMATCH[3]}"
            local port="${BASH_REMATCH[4]}" suffix="${BASH_REMATCH[5]}"
            if [[ "$_stream" == *_sub ]]; then
                _SUB_OF["${_stream%_sub}"]="$suffix"
            else
                _MAIN_OF["$_stream"]="$suffix"; _PORT_OF["$_stream"]="$port"
                _VU_OF["$_stream"]="$vu"; _VP_OF["$_stream"]="$vp"; _VI_OF["$_stream"]="$vi"
                _order+=("$_stream")
            fi
            _stream=""
        fi
    done < "$cfg"

    declare -A _ENABLED_OF=() _NOTIFY_OF=()
    local cam="" in_cameras=false in_notify=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^cameras: ]]; then in_cameras=true; continue; fi
        if $in_cameras && [[ "$line" =~ ^[a-zA-Z] ]]; then in_cameras=false; fi
        $in_cameras || continue
        if [[ "$line" =~ $re_cam_key ]]; then cam="${BASH_REMATCH[1]}"; in_notify=false; continue; fi
        [[ -z "$cam" ]] && continue
        if [[ "$line" =~ $re_notify_key ]]; then in_notify=true; continue; fi
        if $in_notify && [[ "$line" =~ $re_notify_val ]]; then
            _NOTIFY_OF["$cam"]="${BASH_REMATCH[1]}"; in_notify=false; continue
        fi
        if [[ "$line" =~ $re_enabled ]]; then _ENABLED_OF["$cam"]="${BASH_REMATCH[1]}"; fi
    done < "$cfg"

    CAM_NAME=() CAM_PORT=() CAM_VARUSER=() CAM_VARPASS=() CAM_VARIP=()
    CAM_HASSUB=() CAM_MAIN_SUFFIX=() CAM_SUB_SUFFIX=() CAM_ENABLED=() CAM_NOTIFY=()
    CAM_CRED_USER=() CAM_CRED_PASS=() CAM_CRED_IP=()
    local name
    for name in "${_order[@]}"; do
        CAM_NAME+=("$name")
        CAM_PORT+=("${_PORT_OF[$name]}")
        CAM_VARUSER+=("${_VU_OF[$name]}")
        CAM_VARPASS+=("${_VP_OF[$name]}")
        CAM_VARIP+=("${_VI_OF[$name]}")
        CAM_MAIN_SUFFIX+=("${_MAIN_OF[$name]}")
        if [[ -n "${_SUB_OF[$name]:-}" ]]; then
            CAM_HASSUB+=("true"); CAM_SUB_SUFFIX+=("${_SUB_OF[$name]}")
        else
            CAM_HASSUB+=("false"); CAM_SUB_SUFFIX+=("")
        fi
        CAM_ENABLED+=("${_ENABLED_OF[$name]:-false}")
        CAM_NOTIFY+=("${_NOTIFY_OF[$name]:-false}")
        CAM_CRED_USER+=("${ENV_MAP[${_VU_OF[$name]}]:-}")
        CAM_CRED_PASS+=("${ENV_MAP[${_VP_OF[$name]}]:-}")
        CAM_CRED_IP+=("${ENV_MAP[${_VI_OF[$name]}]:-}")
    done
}

_frigate_backup_existing() {
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local bdir="$FRIGATE_DIR/backup-$ts"
    mkdir -p "$bdir"
    [ -f config/config.yml ] && cp config/config.yml "$bdir/config.yml"
    [ -f .env ] && cp .env "$bdir/.env"
    [ -f docker-compose.yml ] && cp docker-compose.yml "$bdir/docker-compose.yml"
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$bdir" 2>/dev/null || true
    log_success "Backed up existing config to $bdir"
}

_frigate_clear_cameras() {
    CAM_NAME=() CAM_PORT=() CAM_VARUSER=() CAM_VARPASS=() CAM_VARIP=()
    CAM_HASSUB=() CAM_MAIN_SUFFIX=() CAM_SUB_SUFFIX=() CAM_ENABLED=() CAM_NOTIFY=()
    CAM_CRED_USER=() CAM_CRED_PASS=() CAM_CRED_IP=()
}

_frigate_remove_by_index() {
    local nums="$1"
    declare -A to_remove=()
    local n
    for n in $nums; do to_remove["$((n-1))"]=1; done
    local _NAME=() _PORT=() _VU=() _VP=() _VI=() _HS=() _MS=() _SS=() _EN=() _NO=() _CU=() _CP=() _CI=()
    local i removed=0
    for i in "${!CAM_NAME[@]}"; do
        if [[ -n "${to_remove[$i]:-}" ]]; then removed=$((removed+1)); continue; fi
        _NAME+=("${CAM_NAME[$i]}"); _PORT+=("${CAM_PORT[$i]}")
        _VU+=("${CAM_VARUSER[$i]}"); _VP+=("${CAM_VARPASS[$i]}"); _VI+=("${CAM_VARIP[$i]}")
        _HS+=("${CAM_HASSUB[$i]}"); _MS+=("${CAM_MAIN_SUFFIX[$i]}"); _SS+=("${CAM_SUB_SUFFIX[$i]}")
        _EN+=("${CAM_ENABLED[$i]}"); _NO+=("${CAM_NOTIFY[$i]}")
        _CU+=("${CAM_CRED_USER[$i]}"); _CP+=("${CAM_CRED_PASS[$i]}"); _CI+=("${CAM_CRED_IP[$i]}")
    done
    CAM_NAME=("${_NAME[@]}"); CAM_PORT=("${_PORT[@]}"); CAM_VARUSER=("${_VU[@]}"); CAM_VARPASS=("${_VP[@]}")
    CAM_VARIP=("${_VI[@]}"); CAM_HASSUB=("${_HS[@]}"); CAM_MAIN_SUFFIX=("${_MS[@]}"); CAM_SUB_SUFFIX=("${_SS[@]}")
    CAM_ENABLED=("${_EN[@]}"); CAM_NOTIFY=("${_NO[@]}"); CAM_CRED_USER=("${_CU[@]}")
    CAM_CRED_PASS=("${_CP[@]}"); CAM_CRED_IP=("${_CI[@]}")
    log_success "Removed $removed camera(s)."
}

# Presents the numbered menu once existing cameras were parsed. Sets
# FRIGATE_SKIP_WIZARD=true when the operator chooses to leave everything
# untouched; mutates the CAM_* arrays in place for backup/remove/add.
_frigate_review_existing() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Existing Frigate cameras found                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    local i
    for i in "${!CAM_NAME[@]}"; do
        printf "  %d) %-16s enabled=%-5s substream=%-5s ip=%s\n" \
            "$((i+1))" "${CAM_NAME[$i]}" "${CAM_ENABLED[$i]}" "${CAM_HASSUB[$i]}" "${CAM_CRED_IP[$i]:-<unknown>}"
    done
    echo ""
    echo "  [1] Keep everything as-is (no changes)"
    echo "  [2] Backup existing config and start fresh"
    echo "  [3] Add more cameras (keep these)"
    echo "  [4] Remove cameras (choose numbers, or 'all'), then optionally add more"
    echo ""
    local CHOICE=""
    prompt_text "  Choice [1]:" "1" CHOICE
    case "$CHOICE" in
        2)
            _frigate_backup_existing
            _frigate_clear_cameras
            FRIGATE_SKIP_WIZARD=false
            ;;
        4)
            local REMOVE=""
            prompt_text "  Remove which numbers (space-separated) or 'all':" "" REMOVE
            if [ "$REMOVE" = "all" ]; then
                _frigate_clear_cameras
            elif [ -n "$REMOVE" ]; then
                _frigate_remove_by_index "$REMOVE"
            fi
            FRIGATE_SKIP_WIZARD=false
            ;;
        3)
            FRIGATE_SKIP_WIZARD=false
            ;;
        *)
            FRIGATE_SKIP_WIZARD=true
            ;;
    esac
}

# Next unused credential-var suffix, treating "no suffix" as 0. Kept cameras
# retain their existing var names untouched; new cameras never reuse one.
_frigate_next_suffix_int() {
    local max=-1 re='^FRIGATE_RTSP_USER([0-9]*)$' v n i
    for i in "${!CAM_VARUSER[@]}"; do
        v="${CAM_VARUSER[$i]}"
        [[ "$v" =~ $re ]] || continue
        n="${BASH_REMATCH[1]}"; [ -z "$n" ] && n=0
        [ "$n" -gt "$max" ] && max="$n"
    done
    echo "$((max+1))"
}

# Prompts to add cameras one at a time, appending to the CAM_* arrays.
_frigate_camera_wizard() {
    while true; do
        local ADD_CAM=""
        if [ "${#CAM_NAME[@]}" -eq 0 ]; then
            prompt_yn "Add a camera now? (y/n):" "y" ADD_CAM
        else
            prompt_yn "Add another camera? (y/n):" "n" ADD_CAM
        fi
        [[ "$ADD_CAM" =~ ^[Yy]$ ]] || break

        local NC_NAME=""
        prompt_text "  Camera name (e.g. front_door):" "camera$((${#CAM_NAME[@]}+1))" NC_NAME
        NC_NAME="$(echo "$NC_NAME" | tr '[:upper:] ' '[:lower:]_' | tr -cd 'a-z0-9_')"
        NC_NAME="${NC_NAME:-camera$((${#CAM_NAME[@]}+1))}"
        local NC_UPPER="${NC_NAME^^}"

        local NC_IP=""
        prompt_text "  ${NC_NAME} RTSP IP address:" "" NC_IP
        local NC_PORT=""
        prompt_text "  ${NC_NAME} RTSP port [554]:" "554" NC_PORT
        local NC_USER=""
        prompt_text "  ${NC_NAME} RTSP username:" "admin" NC_USER
        local NC_PASS=""
        prompt_text "  ${NC_NAME} RTSP password (blank = generate one):" "" NC_PASS
        [ -z "$NC_PASS" ] && NC_PASS="$(generate_password 20)"

        local NC_PATH=""
        prompt_text "  ${NC_NAME} RTSP path (use {sub} for main/sub-stream marker) [/cam/realmonitor?channel=1&subtype={sub}#backchannel=0]:" \
            "/cam/realmonitor?channel=1&subtype={sub}#backchannel=0" NC_PATH

        local NC_SUBSTREAM=""
        prompt_yn "  Add a lower-res sub-stream for detection? (y/n):" "y" NC_SUBSTREAM

        local NC_ENABLED=""
        prompt_yn "  Enable ${NC_NAME} immediately? (y/n):" "y" NC_ENABLED
        local NC_NOTIFY=""
        prompt_yn "  Enable notifications for ${NC_NAME}? (y/n):" "n" NC_NOTIFY

        local _suffix_int; _suffix_int="$(_frigate_next_suffix_int)"
        local IDX_SUFFIX=""; [ "$_suffix_int" -gt 0 ] && IDX_SUFFIX="$_suffix_int"

        CAM_NAME+=("$NC_NAME")
        CAM_PORT+=("$NC_PORT")
        CAM_VARUSER+=("FRIGATE_RTSP_USER${IDX_SUFFIX}")
        CAM_VARPASS+=("FRIGATE_RTSP_PASSWORD${IDX_SUFFIX}")
        CAM_VARIP+=("FRIGATE_${NC_UPPER}_IP")
        if [[ "$NC_SUBSTREAM" =~ ^[Yy]$ ]]; then CAM_HASSUB+=("true"); else CAM_HASSUB+=("false"); fi
        CAM_MAIN_SUFFIX+=("${NC_PATH//\{sub\}/0}")
        CAM_SUB_SUFFIX+=("${NC_PATH//\{sub\}/1}")
        if [[ "$NC_ENABLED" =~ ^[Yy]$ ]]; then CAM_ENABLED+=("true"); else CAM_ENABLED+=("false"); fi
        if [[ "$NC_NOTIFY" =~ ^[Yy]$ ]]; then CAM_NOTIFY+=("true"); else CAM_NOTIFY+=("false"); fi
        CAM_CRED_USER+=("$NC_USER")
        CAM_CRED_PASS+=("$NC_PASS")
        CAM_CRED_IP+=("$NC_IP")
    done
}

# Builds GO2RTC_BLOCK / CAMERAS_BLOCK / ENV_CAM_VARS from the CAM_* arrays.
_frigate_render_config() {
    GO2RTC_BLOCK=""; CAMERAS_BLOCK=""; ENV_CAM_VARS=""
    local i
    for i in "${!CAM_NAME[@]}"; do
        local nm="${CAM_NAME[$i]}" port="${CAM_PORT[$i]}"
        local vu="${CAM_VARUSER[$i]}" vp="${CAM_VARPASS[$i]}" vi="${CAM_VARIP[$i]}"
        local hassub="${CAM_HASSUB[$i]}" mainsuf="${CAM_MAIN_SUFFIX[$i]}" subsuf="${CAM_SUB_SUFFIX[$i]}"
        local enabled="${CAM_ENABLED[$i]}" notify="${CAM_NOTIFY[$i]}"
        local cu="${CAM_CRED_USER[$i]}" cp="${CAM_CRED_PASS[$i]}" ci="${CAM_CRED_IP[$i]}"

        ENV_CAM_VARS="${ENV_CAM_VARS}${vu}=${cu}
${vp}=${cp}
${vi}=${ci}
"
        GO2RTC_BLOCK="${GO2RTC_BLOCK}    ${nm}:
      - rtsp://{${vu}}:{${vp}}@{${vi}}:${port}${mainsuf}
"
        local inputs_block
        if [ "$hassub" = true ]; then
            GO2RTC_BLOCK="${GO2RTC_BLOCK}    ${nm}_sub:
      - rtsp://{${vu}}:{${vp}}@{${vi}}:${port}${subsuf}
"
            inputs_block="        - path: rtsp://127.0.0.1:8554/${nm}
          input_args: preset-rtsp-restream
          roles:
            - record
        - path: rtsp://127.0.0.1:8554/${nm}_sub
          input_args: preset-rtsp-restream
          roles:
            - detect"
        else
            inputs_block="        - path: rtsp://127.0.0.1:8554/${nm}
          input_args: preset-rtsp-restream
          roles:
            - detect
            - record"
        fi
        GO2RTC_BLOCK="${GO2RTC_BLOCK}
"
        CAMERAS_BLOCK="${CAMERAS_BLOCK}  ${nm}:
    enabled: ${enabled}
    ffmpeg:
      inputs:
${inputs_block}
    detect:
      enabled: true
      width: 640
      height: 480
      fps: 5
    notifications:
      enabled: ${notify}

"
    done
}

install_frigate() {
    require_docker || return 1

    local FRIGATE_DIR="$DOCKER_DIR/frigate"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Frigate would:"
        echo "  - Create $FRIGATE_DIR with docker-compose.yml + .env + config/config.yml"
        echo "  - Auto-enable /dev/dri/renderD128 for GPU-assisted detection if present"
        echo "  - Expose ports 5000 (web), 8554 (RTSP restream), 8555 (WebRTC)"
        echo "  - If already configured: show existing cameras and offer to keep,"
        echo "    back up + start fresh, add more, or remove some"
        echo "  - Prompt to add cameras interactively (RTSP creds go in .env)"
        echo "    or write a starter config.yml if none are added"
        echo "  - Offer a Caddy reverse proxy and to start the container"
        return 0
    fi

    mkdir -p "$FRIGATE_DIR"
    ensure_docker_dir_ownership "$FRIGATE_DIR"
    cd "$FRIGATE_DIR" || return 1

    local CAM_NAME=() CAM_PORT=() CAM_VARUSER=() CAM_VARPASS=() CAM_VARIP=()
    local CAM_HASSUB=() CAM_MAIN_SUFFIX=() CAM_SUB_SUFFIX=() CAM_ENABLED=() CAM_NOTIFY=()
    local CAM_CRED_USER=() CAM_CRED_PASS=() CAM_CRED_IP=()
    local FRIGATE_SKIP_WIZARD=false
    declare -A ENV_MAP=()

    if [ -f config/config.yml ] && [ -f .env ]; then
        _frigate_parse_existing config/config.yml .env
        if [ "${#CAM_NAME[@]}" -gt 0 ]; then
            _frigate_review_existing
        else
            log_warning "Existing config.yml found but no cameras could be parsed from it."
            local PROCEED_ANYWAY=""
            prompt_yn "  Back up existing config and continue with the wizard? (y/n):" "y" PROCEED_ANYWAY
            if [[ "$PROCEED_ANYWAY" =~ ^[Yy]$ ]]; then
                _frigate_backup_existing
            else
                log_info "Leaving existing config untouched."
                return 0
            fi
        fi
    fi

    if [ "$FRIGATE_SKIP_WIZARD" = true ]; then
        log_success "Keeping existing Frigate configuration unchanged ($DOCKER_DIR/frigate)."
    else
        local DEFAULT_MEDIA="${ENV_MAP[FRIGATE_MEDIA]:-$ACTUAL_HOME/frigate}"
        local FRIGATE_MEDIA=""
        prompt_text "Path for recordings/snapshots [$DEFAULT_MEDIA]:" "$DEFAULT_MEDIA" FRIGATE_MEDIA
        FRIGATE_MEDIA="${FRIGATE_MEDIA/#\~/$ACTUAL_HOME}"; FRIGATE_MEDIA="${FRIGATE_MEDIA%/}"

        local TZ_VAL; TZ_VAL="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"

        # Hardware detection: include /dev/dri only when a render node exists
        local DEVICE_BLOCK=""
        if [ -e /dev/dri/renderD128 ]; then
            DEVICE_BLOCK="    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
            log_success "Render node found — enabling hardware-accelerated detection"
        else
            log_warning "No /dev/dri/renderD128 — Frigate will use CPU detection."
        fi

        local _CADDY_NET_BLOCK=""
        if [ -d "$DOCKER_DIR/caddy" ]; then
            _CADDY_NET_BLOCK="    networks:
      - caddy_net
"
        fi

        local _CADDY_NET_SECTION=""
        if [ -d "$DOCKER_DIR/caddy" ]; then
            _CADDY_NET_SECTION="
networks:
  caddy_net:
    external: true
    name: ${SITE_CADDY_NET:-caddy_net}
"
        fi

        cat > docker-compose.yml << FRIGATE_COMPOSE
name: frigate

services:
  frigate:
    image: ghcr.io/blakeblackshear/frigate:stable
    container_name: frigate
    hostname: frigate
    restart: unless-stopped
    privileged: true
    shm_size: "256mb"
    env_file:
      - .env
    environment:
      - TZ=$TZ_VAL
$DEVICE_BLOCK
    volumes:
      - ./config:/config
      - \${FRIGATE_MEDIA}:/media/frigate
      - type: tmpfs
        target: /tmp/cache
        tmpfs:
          size: 1000000000
    ports:
      - "5000:5000"
      - "8554:8554"
      - "8555:8555/tcp"
      - "8555:8555/udp"
${_CADDY_NET_BLOCK}${_CADDY_NET_SECTION}
FRIGATE_COMPOSE

        mkdir -p config
        mkdir -p "$FRIGATE_MEDIA"

        # Credentials/IPs go in .env as FRIGATE_* variables; Frigate substitutes
        # any {FRIGATE_VAR} placeholder in config.yml from its container env at
        # startup, so RTSP secrets never need to be typed into the YAML directly.
        _frigate_camera_wizard
        _frigate_render_config

        if [ "${#CAM_NAME[@]}" -eq 0 ]; then
            # No cameras entered — write a starter config the operator edits by hand.
            cat > config/config.yml << 'FRIGATE_CONFIG'
# Frigate Configuration — Docs: https://docs.frigate.video
#
# ⚠️  YOU MUST EDIT THIS FILE to add your cameras before starting Frigate.

mqtt:
  enabled: false   # Set to true and configure if you use Home Assistant

cameras:
  # Example — replace with your camera details:
  # front_door:
  #   ffmpeg:
  #     inputs:
  #       - path: rtsp://user:pass@192.168.1.100:554/stream
  #         roles: [detect, record]
  #   detect:
  #     width: 1280
  #     height: 720
  #     fps: 5

detectors:
  default:
    type: cpu   # Change to 'edgetpu' for Coral TPU or 'openvino' for Intel GPU

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 7
FRIGATE_CONFIG
        else
            cat > config/config.yml << FRIGATE_CONFIG
# Frigate Configuration — Docs: https://docs.frigate.video
#
# RTSP credentials/IPs come from .env — Frigate substitutes {FRIGATE_VAR}
# placeholders below from the container's environment at startup.

mqtt:
  enabled: false   # Set to true and configure if you use Home Assistant

go2rtc:
  streams:
${GO2RTC_BLOCK}
cameras:
${CAMERAS_BLOCK}
detectors:
  default:
    type: cpu   # Change to 'edgetpu' for Coral TPU or 'openvino' for Intel GPU

record:
  enabled: true
  retain:
    days: 7
    mode: motion

snapshots:
  enabled: true
  retain:
    default: 7
FRIGATE_CONFIG
        fi

        cat > .env << FRIGATE_ENV
FRIGATE_MEDIA=$FRIGATE_MEDIA
CADDY_NET=$SITE_CADDY_NET
${ENV_CAM_VARS}
FRIGATE_ENV
        chmod 600 .env

        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FRIGATE_DIR"
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$FRIGATE_MEDIA" 2>/dev/null || true
        log_success "Frigate configured at $FRIGATE_DIR"

        configure_caddy_for_service "Frigate" "frigate:5000" "frigate"

        write_readme "$FRIGATE_DIR" << MD
# Frigate NVR

AI-powered network video recorder with real-time object detection for
security cameras. Detects people, cars, animals, and more.

- Web UI: http://localhost:5000
- RTSP restream: port 8554
- WebRTC: port 8555
- Recordings: \`$FRIGATE_MEDIA\`
- Config: \`config/config.yml\` — cameras configured during install (${#CAM_NAME[@]} total)
- Credentials: \`.env\` — RTSP user/pass/IP per camera as FRIGATE_* variables

## Manage
\`\`\`bash
cd $FRIGATE_DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker compose pull && docker compose up -d   # update
\`\`\`

## Adding/editing cameras later
Re-run the installer (\`sudo ./setup.sh frigate\`) — it detects your existing
config.yml/.env and lets you keep everything as-is, back up and start fresh,
add more cameras, or remove specific ones by number. Or edit
\`config/config.yml\` and \`.env\` by hand — camera credentials in config.yml
use Frigate's \`{FRIGATE_VAR}\` substitution syntax, resolved from \`.env\` at
container startup.

## First steps
1. Review \`config/config.yml\` — adjust detection zones, masks, retention
2. Start Frigate: \`docker compose up -d\`
3. Open http://localhost:5000 to view cameras and configure detection zones

## Hardware acceleration
- Intel/AMD GPU: uncomment the \`devices: [/dev/dri/renderD128]\` block
- Google Coral TPU: set \`detectors.default.type: edgetpu\` + add USB device
- Docs: https://docs.frigate.video/configuration/hardware_acceleration
MD
    fi

    echo ""
    local START_DEFAULT="n"
    if [ "${#CAM_NAME[@]}" -eq 0 ]; then
        log_warning "No cameras added — edit config/config.yml to add camera RTSP streams before starting."
    else
        log_success "${#CAM_NAME[@]} camera(s) configured."
        START_DEFAULT="y"
    fi
    echo ""
    local START_FRIGATE=""
    prompt_yn "Start Frigate now? (y/n):" "$START_DEFAULT" START_FRIGATE
    if [ "$START_FRIGATE" = "y" ] || [ "$START_FRIGATE" = "Y" ]; then
        docker compose up -d && log_success "Frigate started" || log_warning "Failed to start — check: docker compose logs"
    fi

    echo ""
    echo "  Access at:  http://localhost:5000"
    echo "  Config:     $FRIGATE_DIR/config/config.yml"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_frigate
