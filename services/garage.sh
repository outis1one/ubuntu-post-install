#!/bin/bash
# services/garage.sh — Garage: lightweight self-hosted S3-compatible object
# storage, single-node.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash garage.sh
# (Docker must already be installed when run standalone)
#
# Why Garage and not MinIO: MinIO's open-source community edition is dead —
# console GUI stripped May 2025, Docker images stopped publishing October
# 2025, repo formally archived April 2026, with MinIO redirecting everyone
# to their paid AIStor product. Garage (Deuxfleurs) is the small-scale
# self-hoster's actively-maintained replacement: single Rust binary, built
# specifically for this "one lightweight node, S3-compatible" use case
# rather than large-scale clusters (that's SeaweedFS's niche instead).
#
# Typical use in this repo: a local S3-compatible target for services/
# backup.sh's offsite/additional-mirror Kopia sync-to s3, so a local mirror
# can reuse the exact same, already-proven sync-to s3 code path the
# Backblaze B2 mirror uses — instead of Kopia's separate, less-exercised
# SFTP backend.

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

        port_in_use() {
            local _port="$1" _proto="${2:-tcp}"
            local _flag="-tlnH"
            [ "$_proto" = "udp" ] && _flag="-ulnH"
            ss "$_flag" "sport = :${_port}" 2>/dev/null | grep -q .
        }

        find_free_port() {
            local _varname="$1" _port="$2" _proto="${3:-tcp}"
            while port_in_use "$_port" "$_proto"; do
                _port=$((_port + 1))
            done
            eval "$_varname='$_port'"
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

        prompt_reinstall_mode() {
            local _var="$1" _r
            [[ "${UNATTENDED:-false}" == "true" ]] && { eval "$_var='cancel'"; return; }
            echo ""
            echo "  1) Update   — refresh the image only, leave config/data as-is"
            echo "  2) Full reinstall — wipe and reconfigure from scratch"
            echo "  3) Cancel   — leave the existing install untouched"
            read -r -p "  Choice [3]: " _r
            case "$_r" in
                1) eval "$_var='update'" ;;
                2) eval "$_var='fresh'" ;;
                *) eval "$_var='cancel'" ;;
            esac
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

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service garage utilities "Self-hosted S3-compatible object storage, single node (Garage — MinIO CE's actively-maintained replacement)" 3900

install_garage() {
    require_docker || return 1

    local DIR="$DOCKER_DIR/garage"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with garage.toml + docker-compose.yml + .env"
        echo "[DRY-RUN] Would auto-scan for free S3 API / RPC / admin ports"
        echo "[DRY-RUN] Would generate an RPC secret and persist it (never regenerated on update)"
        echo "[DRY-RUN] Would run the one-time cluster init: layout assign/apply, bucket create, key create"
        echo "[DRY-RUN] Would print the endpoint/bucket/access-key/secret for Kopia's sync-to s3"
        return 0
    fi

    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing the Garage image only — existing data, config, and keys are left as-is."
                ( cd "$DIR" && docker compose pull && docker compose up -d ) \
                    && log_success "Garage image refreshed" \
                    || log_warning "Refresh failed — check: docker compose -f $DIR/docker-compose.yml logs"
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) ;;  # fall through to the full install flow below
        esac
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  GARAGE — self-hosted S3-compatible object storage"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Single-node setup — good fit for a local Kopia backup mirror target"
    echo "  (services/backup.sh) so a local mirror can use Kopia's S3 backend"
    echo "  instead of its less-exercised SFTP backend."
    echo ""

    local S3_API_PORT="3900" RPC_PORT="3901" ADMIN_PORT="3903"
    find_free_port S3_API_PORT "$S3_API_PORT"
    find_free_port RPC_PORT "$RPC_PORT"
    find_free_port ADMIN_PORT "$ADMIN_PORT"

    # Suggested defaults are generated fresh at runtime, not fixed strings
    # baked into this script — same reasoning as not hardcoding what a
    # remote reader (services/backup.sh) should expect the name to be:
    # this is the operator's name to pick, not this repo's.
    local BUCKET_NAME="" KEY_NAME=""
    local _default_bucket="kopia-$(date +%s)" _default_key="key-$(date +%s)"
    prompt_text "  Bucket name:" "$_default_bucket" BUCKET_NAME
    BUCKET_NAME="${BUCKET_NAME:-$_default_bucket}"
    prompt_text "  Access key name:" "$_default_key" KEY_NAME
    KEY_NAME="${KEY_NAME:-$_default_key}"

    mkdir -p "$DIR"/{data,meta}
    ensure_docker_dir_ownership "$DIR"
    cd "$DIR" || return 1

    # 32-byte hex secret used for inter-node RPC auth — a single-node
    # cluster still requires one, since Garage's admin/layout CLI talks to
    # the node over this same RPC channel.
    local RPC_SECRET
    RPC_SECRET="$(openssl rand -hex 32)"

    cat > garage.toml << TOML
metadata_dir = "/meta"
data_dir = "/data"
db_engine = "lmdb"

replication_factor = 1

rpc_bind_addr = "[::]:${RPC_PORT}"
rpc_public_addr = "127.0.0.1:${RPC_PORT}"
rpc_secret = "${RPC_SECRET}"

[s3_api]
s3_region = "garage"
api_bind_addr = "[::]:${S3_API_PORT}"
root_domain = ".s3.garage.localhost"

[admin]
api_bind_addr = "[::]:${ADMIN_PORT}"
TOML

    cat > docker-compose.yml << COMPOSE
name: garage

services:
  garage:
    image: dxflrs/garage:v2.3.0
    container_name: garage
    hostname: garage
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./garage.toml:/etc/garage.toml:ro
      - ./data:/data
      - ./meta:/meta
    ports:
      - "${S3_API_PORT}:${S3_API_PORT}"
      - "${RPC_PORT}:${RPC_PORT}"
      - "${ADMIN_PORT}:${ADMIN_PORT}"
COMPOSE

    cat > .env << ENV
TZ=${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}

# Read directly (over SSH) by another box's services/backup.sh when adding
# this instance as a Kopia sync-to s3 mirror target — keep this key name
# stable, other scripts depend on it.
GARAGE_S3_API_PORT=${S3_API_PORT}
ENV
    chmod 600 .env

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$DIR"

    log_info "Starting Garage..."
    docker compose up -d || { log_error "Failed to start Garage — check: docker compose logs"; return 1; }

    # ── One-time cluster init ────────────────────────────────────────────────
    # A brand-new Garage node has no layout yet — S3 API calls fail until
    # one is assigned and applied, even for a single node. Only ever run
    # once: re-running layout assign/apply against an already-initialized
    # cluster is unnecessary and risks fighting the layout version counter.
    log_info "Waiting for Garage to become ready..."
    local _tries=0
    until docker exec garage /garage status >/dev/null 2>&1 || [ "$_tries" -ge 30 ]; do
        sleep 1; _tries=$((_tries + 1))
    done

    if ! docker exec garage /garage status >/dev/null 2>&1; then
        log_error "Garage didn't come up in time — check: docker compose logs"
        return 1
    fi

    local NODE_ID
    # `garage status` output is a title line, then a column-header line
    # ("ID Hostname Address ..."), then the actual node row — NR==3, not
    # NR==2 (which would just grab the literal string "ID" off the header).
    NODE_ID="$(docker exec garage /garage status 2>/dev/null | awk 'NR==3{print $1}')"
    if [ -z "$NODE_ID" ]; then
        log_error "Couldn't read this node's ID from 'garage status' — check: docker exec garage /garage status"
        return 1
    fi

    log_info "Assigning single-node cluster layout..."
    docker exec garage /garage layout assign -z dc1 -c 1G "$NODE_ID" >/dev/null \
        && docker exec garage /garage layout apply --version 1 >/dev/null \
        || { log_error "Cluster layout init failed — check: docker exec garage /garage layout show"; return 1; }

    log_info "Creating bucket and access key..."
    docker exec garage /garage bucket create "$BUCKET_NAME" >/dev/null 2>&1

    local _key_out
    _key_out="$(docker exec garage /garage key create "$KEY_NAME" 2>&1)"
    local ACCESS_KEY_ID ACCESS_KEY_SECRET
    # Garage's real CLI output pads labels with extra spaces for column
    # alignment (e.g. "Key ID:              GKxxxx", not just "Key ID: GKxxxx")
    # — a fixed ": " separator leaves that padding stuck to the value.
    # ':[[:space:]]+' as a regex field separator consumes ALL of it,
    # however many spaces there actually are. Confirmed live: the fixed
    # single-space version left leading spaces baked into .env, which
    # would have broken S3 auth (access keys have to match exactly).
    ACCESS_KEY_ID="$(echo "$_key_out" | awk -F':[[:space:]]+' '/^Key ID:/{print $2}')"
    ACCESS_KEY_SECRET="$(echo "$_key_out" | awk -F':[[:space:]]+' '/^Secret key:/{print $2}')"

    if [ -z "$ACCESS_KEY_ID" ] || [ -z "$ACCESS_KEY_SECRET" ]; then
        log_error "Couldn't parse the access key from 'garage key create' output:"
        echo "$_key_out"
        return 1
    fi

    docker exec garage /garage bucket allow --read --write --owner "$BUCKET_NAME" --key "$KEY_NAME" >/dev/null

    # Persisted so a later "Update" run never re-runs any of the above —
    # this presence check is exactly what gates that.
    {
        echo ""
        echo "# Written once, at first install — never touched again by an Update run."
        echo "GARAGE_BUCKET='$BUCKET_NAME'"
        echo "GARAGE_ACCESS_KEY_ID='$ACCESS_KEY_ID'"
        echo "GARAGE_ACCESS_KEY_SECRET='$ACCESS_KEY_SECRET'"
    } >> .env
    chmod 600 .env

    log_success "Garage ready — bucket '$BUCKET_NAME', key '$KEY_NAME'"

    local PUBLIC_IP
    PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="<this-box's-IP>"

    if command -v ufw &>/dev/null; then
        ufw allow "${S3_API_PORT}/tcp" comment "Garage S3 API"
    fi

    write_readme "$DIR" << MD
# Garage

Self-hosted, S3-compatible object storage — single node. MinIO's open-source
community edition is dead (archived April 2026); Garage is the actively
maintained small-scale replacement.

## Credentials (see \`.env\` for the actual values)
- Bucket: \`$BUCKET_NAME\`
- Access Key ID: \`GARAGE_ACCESS_KEY_ID\` in \`.env\`
- Secret Access Key: \`GARAGE_ACCESS_KEY_SECRET\` in \`.env\`
- Endpoint: \`${PUBLIC_IP}:${S3_API_PORT}\` (plain HTTP — no TLS on this node)

## Using this as a Kopia backup mirror target
On the box running \`services/backup.sh\`, when adding an additional mirror,
this is an \`s3\`-type destination rather than \`sftp\` — point Kopia at it with:
\`\`\`bash
kopia repository sync-to s3 \\
    --bucket=$BUCKET_NAME \\
    --endpoint=${PUBLIC_IP}:${S3_API_PORT} \\
    --access-key=<GARAGE_ACCESS_KEY_ID from .env> \\
    --secret-access-key=<GARAGE_ACCESS_KEY_SECRET from .env> \\
    --disable-tls
\`\`\`
\`--disable-tls\` matters — this node serves plain HTTP, not HTTPS, unlike
Backblaze B2's endpoint.

## Adding another bucket or key later
\`\`\`bash
docker exec garage /garage bucket create another-bucket
docker exec garage /garage key create another-key
docker exec garage /garage bucket allow --read --write --owner another-bucket --key another-key
\`\`\`

## Manage
\`\`\`bash
cd $DIR
docker compose up -d      # start
docker compose down       # stop
docker compose logs -f    # logs
docker exec garage /garage status   # cluster/node status
\`\`\`
MD

    echo ""
    echo "  S3 endpoint:  ${PUBLIC_IP}:${S3_API_PORT}  (plain HTTP, no TLS)"
    echo "  Bucket:       $BUCKET_NAME"
    echo "  Credentials:  see $DIR/.env"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_garage
