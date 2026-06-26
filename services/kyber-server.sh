#!/bin/bash
# services/kyber-server.sh — Kyber dedicated server for SWBF2 (2017), headless Docker container.
# Part of the modular post-install system (sourced by setup.sh).
#
# Kyber is a community multiplayer replacement for Star Wars Battlefront II (2017)
# after EA shut down official servers in 2022. This installs the headless dedicated
# server via the official Armchair Developers Docker image — no GPU required for the
# server itself (GPU passthrough is added automatically if detected, for future use).
#
# Prerequisites:
#   - SWBF2 (Steam AppID 1237950) installed via Steam on this machine
#   - Docker CE + Compose plugin
#   - EA account that owns SWBF2
#   - Internet access to pull the Docker image and authenticate with Kyber
#
# The Kyber token is obtained via kyber_cli (extracted from the Linux port AppImage)
# which opens a browser for EA OAuth. One-time step — the token never expires.
#
# Map rotation is left blank by default; edit ~/docker/kyber-server/.env after install
# and set KYBER_MAP_ROTATION to a base64-encoded rotation string (use the Kyber client
# HOST tab to build a rotation, then base64-encode it).
# ── Registration ──────────────────────────────────────────────────────────────
command -v register_service &>/dev/null && \
    register_service kyber-server gaming "Kyber dedicated server for SWBF2 (2017) — headless, no GPU required"

# ── Helpers ───────────────────────────────────────────────────────────────────

_kyber_find_swbf2() {
    # Check standard Steam paths first
    local candidates=(
        "$ACTUAL_HOME/.local/share/Steam/steamapps/common/STAR WARS Battlefront II"
        "$ACTUAL_HOME/.steam/steam/steamapps/common/STAR WARS Battlefront II"
        "/home/$ACTUAL_USER/.local/share/Steam/steamapps/common/STAR WARS Battlefront II"
    )
    for p in "${candidates[@]}"; do
        if [[ -f "$p/starwarsbattlefrontii.exe" ]]; then
            echo "$p"
            return 0
        fi
    done

    # Search Steam library folders on mounted drives (libraryfolders.vdf lists them)
    local vdf="$ACTUAL_HOME/.local/share/Steam/steamapps/libraryfolders.vdf"
    if [[ -f "$vdf" ]]; then
        while IFS= read -r line; do
            local libpath
            libpath=$(echo "$line" | grep -oP '"path"\s+"\K[^"]+')
            [[ -z "$libpath" ]] && continue
            local candidate="$libpath/steamapps/common/STAR WARS Battlefront II"
            if [[ -f "$candidate/starwarsbattlefrontii.exe" ]]; then
                echo "$candidate"
                return 0
            fi
        done < "$vdf"
    fi

    # Last resort: find across /home and common mount points
    local found
    found=$(find "$ACTUAL_HOME" /mnt /media /run/media 2>/dev/null \
        -name "starwarsbattlefrontii.exe" -not -path "*/wolf-state/*" \
        -print -quit 2>/dev/null)
    if [[ -n "$found" ]]; then
        echo "$(dirname "$found")"
        return 0
    fi

    return 1
}

_kyber_detect_gpu() {
    # Returns: nvidia | intel | amd | none
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        echo "nvidia"
    elif [[ -e /dev/dri/renderD128 ]]; then
        if lspci 2>/dev/null | grep -qi "Intel.*VGA\|VGA.*Intel"; then
            echo "intel"
        else
            echo "amd"
        fi
    else
        echo "none"
    fi
}

_kyber_get_token() {
    local appimage_path="$1"
    local extract_dir="/tmp/kyber-cli-extract"

    log_info "Extracting kyber_cli from AppImage..."
    rm -rf "$extract_dir"
    mkdir -p "$extract_dir"

    # Run extraction as the actual user (AppImage needs user context)
    sudo -u "$ACTUAL_USER" "$appimage_path" --appimage-extract-and-run \
        squashfs-root 2>/dev/null || true
    sudo -u "$ACTUAL_USER" bash -c \
        "cd '$extract_dir' && '$appimage_path' --appimage-extract" \
        2>/dev/null || true

    local cli_bin
    cli_bin=$(find "$extract_dir/squashfs-root" /tmp/squashfs-root \
        -name "kyber_cli" -type f 2>/dev/null | head -1)

    if [[ -z "$cli_bin" ]]; then
        # Try running kyber_cli directly if AppImage mounts itself
        cli_bin=$(find /tmp/.mount_Kyber* -name "kyber_cli" -type f 2>/dev/null | head -1)
    fi

    if [[ -z "$cli_bin" ]]; then
        log_error "Could not extract kyber_cli from AppImage."
        log_error "Run the Kyber AppImage manually, log in, then find your token in:"
        log_error "  ~/.local/share/maxima/auth.toml"
        return 1
    fi

    log_info "Found kyber_cli at: $cli_bin"
    echo ""
    log_info "A browser will open for EA login. Log in, then return here."
    echo ""

    local token
    token=$(sudo -u "$ACTUAL_USER" "$cli_bin" get_token 2>/dev/null | tr -d '[:space:]')

    if [[ -z "$token" ]]; then
        log_error "kyber_cli get_token returned nothing."
        log_error "Try running manually:  $cli_bin get_token"
        return 1
    fi

    echo "$token"
}

# ── Install function ───────────────────────────────────────────────────────────
install_kyber_server() {
    require_docker || return 1

    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║     Kyber Dedicated Server — SWBF2 (2017)           ║"
    echo "║     Headless Docker container, no GPU required       ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    # ── DRY RUN ───────────────────────────────────────────────────────────────
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would auto-detect SWBF2 install path"
        echo "[DRY-RUN] Would download Kyber AppImage and extract kyber_cli"
        echo "[DRY-RUN] Would run kyber_cli get_token (opens browser)"
        echo "[DRY-RUN] Would prompt for EA credentials and server name"
        echo "[DRY-RUN] Would detect GPU and add passthrough if found"
        echo "[DRY-RUN] Would write ~/docker/kyber-server/docker-compose.yml"
        echo "[DRY-RUN] Would write ~/docker/kyber-server/.env (chmod 600)"
        return 0
    fi

    # ── Detect SWBF2 ──────────────────────────────────────────────────────────
    log_info "Locating SWBF2 installation..."
    local SWBF2_PATH
    SWBF2_PATH=$(_kyber_find_swbf2)

    if [[ -z "$SWBF2_PATH" ]]; then
        log_warning "SWBF2 not found in standard Steam paths."
        echo ""
        echo "  The dedicated server mounts the game files read-only — no Steam or"
        echo "  EA authentication needed at runtime. You can rsync the game folder"
        echo "  from another machine that has SWBF2 installed via Steam."
        echo ""

        local _do_rsync=""
        prompt_yn "Rsync SWBF2 files from a remote machine now? (y/n):" "y" _do_rsync
        if [[ "$_do_rsync" =~ ^[Yy]$ ]]; then
            local _remote_host _remote_user _remote_path _local_dest
            prompt_text "Remote host (IP or hostname):" "" _remote_host
            prompt_text "Remote username:" "$ACTUAL_USER" _remote_user
            # Default Steam path on Linux
            local _default_remote_path="/home/${_remote_user}/.local/share/Steam/steamapps/common/STAR WARS Battlefront II"
            prompt_text "Remote SWBF2 path [${_default_remote_path}]:" "$_default_remote_path" _remote_path

            _local_dest="$DOCKER_DIR/kyber-server/swbf2"
            mkdir -p "$_local_dest"
            ensure_docker_dir_ownership "$_local_dest"

            log_info "Rsyncing from ${_remote_user}@${_remote_host}:${_remote_path}/ ..."
            log_info "Destination: $_local_dest"
            echo ""
            rsync -av --progress \
                "${_remote_user}@${_remote_host}:${_remote_path}/" \
                "$_local_dest/" \
                || { log_error "rsync failed — check SSH access and remote path."; return 1; }

            SWBF2_PATH="$_local_dest"
        else
            echo ""
            prompt_text "Enter the full local path to the SWBF2 folder (or leave blank to abort):" "" SWBF2_PATH
            if [[ -z "$SWBF2_PATH" ]]; then
                log_error "No path provided — cannot continue without game files."
                return 1
            fi
        fi

        if [[ ! -f "$SWBF2_PATH/starwarsbattlefrontii.exe" ]]; then
            log_error "starwarsbattlefrontii.exe not found in: $SWBF2_PATH"
            log_error "Make sure you pointed to the root of the SWBF2 install folder."
            return 1
        fi
    fi
    log_success "Found SWBF2 at: $SWBF2_PATH"

    # ── Detect GPU ────────────────────────────────────────────────────────────
    local GPU_TYPE
    GPU_TYPE=$(_kyber_detect_gpu)
    case "$GPU_TYPE" in
        nvidia) log_info "GPU detected: NVIDIA (will add GPU passthrough)" ;;
        intel)  log_info "GPU detected: Intel (will add DRI device passthrough)" ;;
        amd)    log_info "GPU detected: AMD (will add DRI device passthrough)" ;;
        none)   log_info "No GPU detected — running CPU-only (fine for dedicated server)" ;;
    esac

    # ── Kyber AppImage / CLI ──────────────────────────────────────────────────
    local KYBER_REPO="simonlinuxcraft/kyber-linuxport-unofficial"
    local APPIMAGE_DIR="$ACTUAL_HOME/.local/share/kyber"
    local APPIMAGE_PATH="$APPIMAGE_DIR/KyberLinuxPort.AppImage"

    if [[ ! -f "$APPIMAGE_PATH" ]]; then
        log_info "Kyber AppImage not found — downloading latest release..."
        local APPIMAGE_URL
        APPIMAGE_URL=$(curl -fsSL \
            "https://api.github.com/repos/${KYBER_REPO}/releases/latest" \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for a in data.get('assets', []):
    if a['browser_download_url'].endswith('.AppImage'):
        print(a['browser_download_url'])
        break
" 2>/dev/null)

        if [[ -z "$APPIMAGE_URL" ]]; then
            log_error "Could not fetch Kyber AppImage URL from GitHub."
            log_error "Check: https://github.com/${KYBER_REPO}/releases"
            return 1
        fi

        sudo -u "$ACTUAL_USER" mkdir -p "$APPIMAGE_DIR"
        log_info "Downloading: $APPIMAGE_URL"
        sudo -u "$ACTUAL_USER" curl -L --progress-bar \
            -o "$APPIMAGE_PATH" "$APPIMAGE_URL"
        sudo -u "$ACTUAL_USER" chmod +x "$APPIMAGE_PATH"
        log_success "Kyber AppImage downloaded."
    else
        log_info "Kyber AppImage already present: $APPIMAGE_PATH"
    fi

    # ── Get Kyber token ───────────────────────────────────────────────────────
    echo ""
    log_info "Getting your Kyber server token..."
    log_info "This opens a browser for EA login — log in, then return here."
    echo ""

    local KYBER_TOKEN=""
    KYBER_TOKEN=$(_kyber_get_token "$APPIMAGE_PATH")
    if [[ -z "$KYBER_TOKEN" ]]; then
        log_warning "Could not retrieve token automatically."
        prompt_text "Paste your KYBER_TOKEN manually (or press Enter to skip):" "" KYBER_TOKEN
    fi

    if [[ -z "$KYBER_TOKEN" ]]; then
        log_error "No Kyber token provided. Cannot continue."
        log_error "Get it manually: run the Kyber AppImage, log in, then check"
        log_error "  ~/.local/share/maxima/auth.toml"
        return 1
    fi
    log_success "Kyber token obtained."

    # ── EA credentials ────────────────────────────────────────────────────────
    echo ""
    local EA_EMAIL EA_PASSWORD
    prompt_text "EA account email:" "" EA_EMAIL
    if [[ -z "$EA_EMAIL" ]]; then
        log_error "EA email is required."
        return 1
    fi

    # Read password without echo
    local _pw_prompt="  EA account password: "
    if [[ "${UNATTENDED:-false}" == "true" ]]; then
        EA_PASSWORD=""
    else
        read -r -s -p "$_pw_prompt" EA_PASSWORD
        echo ""
    fi

    if [[ -z "$EA_PASSWORD" ]]; then
        log_error "EA password is required."
        return 1
    fi

    # ── Server config ─────────────────────────────────────────────────────────
    local SERVER_NAME MAX_PLAYERS
    prompt_text "Server name [Kyber Server]:" "Kyber Server" SERVER_NAME
    prompt_text "Max players [40]:" "40" MAX_PLAYERS
    prompt_text "Server password (leave blank for public):" "" SERVER_PASSWORD

    # ── Write files ───────────────────────────────────────────────────────────
    local DIR="$DOCKER_DIR/kyber-server"
    mkdir -p "$DIR"
    ensure_docker_dir_ownership "$DIR"

    # Build GPU section for docker-compose
    local GPU_SECTION=""
    local DEVICES_SECTION=""
    local GROUP_ADD_SECTION=""

    case "$GPU_TYPE" in
        nvidia)
            GPU_SECTION="
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]"
            ;;
        intel|amd)
            DEVICES_SECTION="
    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128"
            GROUP_ADD_SECTION="
    group_add:
      - video
      - render"
            ;;
    esac

    cat > "$DIR/docker-compose.yml" << EOF
name: kyber-server
services:
  kyber-server:
    image: ghcr.io/armchairdevelopers/kyber-server:latest
    container_name: kyber-swbf2
    restart: unless-stopped
    env_file: .env
    volumes:
      - ${SWBF2_PATH}:/mnt/battlefront:ro
      - ./logs:/logs${GPU_SECTION}${DEVICES_SECTION}${GROUP_ADD_SECTION}
EOF

    # Write .env with restricted permissions
    cat > "$DIR/.env" << EOF
MAXIMA_CREDENTIALS=${EA_EMAIL}:${EA_PASSWORD}
KYBER_TOKEN=${KYBER_TOKEN}
KYBER_SERVER_NAME=${SERVER_NAME}
KYBER_SERVER_MAX_PLAYERS=${MAX_PLAYERS}
# Leave blank for a public server, or set a password to make it private
KYBER_SERVER_PASSWORD=${SERVER_PASSWORD}
# Leave blank until you have a base64-encoded map rotation string.
# Build one in the Kyber client HOST tab, then base64-encode it:
#   echo -n '<rotation-json>' | base64
KYBER_MAP_ROTATION=
EOF
    chmod 600 "$DIR/.env"
    ensure_docker_dir_ownership "$DIR"

    mkdir -p "$DIR/logs"

    write_readme "$DIR" << 'MD'
# Kyber Dedicated Server (SWBF2 2017)

Headless community multiplayer server via the Armchair Developers Docker image.
No GPU required for the server itself.

## Manage
```bash
docker compose up -d        # start
docker compose down         # stop
docker compose logs -f      # live logs
docker compose pull && docker compose up -d   # update
```

## Map rotation
Edit `.env` and set `KYBER_MAP_ROTATION` to a base64-encoded rotation string.
Build the rotation JSON in the Kyber client (HOST tab), then:
```bash
echo -n '<rotation-json>' | base64
```

## Token refresh
If the Kyber token stops working, re-run the installer or:
```bash
~/.local/share/kyber/KyberLinuxPort.AppImage  # log in, get new token
# update KYBER_TOKEN in .env, then:
docker compose up -d
```
MD

    log_success "Written: $DIR/docker-compose.yml"
    log_success "Written: $DIR/.env (permissions: 600)"
    echo ""

    # ── Offer to start ────────────────────────────────────────────────────────
    local START=""
    prompt_yn "Pull latest image and start the server now? (y/n):" "y" START
    if [[ "$START" =~ ^[Yy]$ ]]; then
        cd "$DIR" || return 1
        docker compose pull
        docker compose up -d \
            && log_success "Kyber server started. Check logs: docker compose logs -f" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    echo ""
    echo "Server directory: $DIR"
    echo "Edit $DIR/.env to set map rotation or update credentials."
    echo "Token refresh: re-run this installer or update KYBER_TOKEN in .env manually."
}

# ── Standalone bootstrap ──────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ "$(id -u)" == "0" ]] || { echo "Run with sudo: sudo bash $0"; exit 1; }

    _SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _COMMON="$_SELF_DIR/../lib/common.sh"

    if [[ -f "$_COMMON" ]]; then
        source "$_COMMON"
    else
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

        generate_password() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }

        ACTUAL_USER="${SUDO_USER:-$USER}"
        ACTUAL_HOME=$(eval echo "~$ACTUAL_USER")
        DOCKER_DIR="$ACTUAL_HOME/docker"
        DRY_RUN="${DRY_RUN:-false}"
        UNATTENDED="${UNATTENDED:-false}"
    fi

    install_kyber_server
    exit $?
fi
