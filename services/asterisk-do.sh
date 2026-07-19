#!/bin/bash
# services/asterisk-do.sh — Easy Asterisk PBX + coturn, tuned for a public
# DigitalOcean droplet (public-IP FQDN by default, DO Cloud Firewall setup,
# no LAN/VLAN prompts). For a home/LAN box use services/asterisk.sh instead.
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on a fresh droplet:
#   sudo bash asterisk-do.sh
# (Docker must already be installed when run standalone)

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

            local _default_domain=""
            if [[ -n "${SITE_DOMAIN:-}" ]] && [[ "$SITE_DOMAIN" != "example.com" ]]; then
                _default_domain="${_subdomain}.${SITE_DOMAIN}"
                log_info "Default: $_default_domain"
            fi
            local _domain=""
            read -r -p "  Domain [${_default_domain:-required}]: " _domain
            _domain="${_domain:-$_default_domain}"
            [[ -n "$_domain" ]] || { log_warning "No domain entered — skipping Caddy."; return 0; }

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
            local _dir="$1"
            mkdir -p "$_dir"
            [[ "${DRY_RUN:-false}" == "true" ]] && return 0
            cat > "$_dir/README.md"
        }

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
            echo
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
    CADDY_REMOTE_HOST="${CADDY_REMOTE_HOST:-}"

    register_service() { :; }   # no-op — no wizard to register into
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service asterisk-do homelab "Easy Asterisk PBX + coturn, tuned for a public DigitalOcean droplet" 5061

install_asterisk-do() {
    require_docker || return 1
    log_info "Installing Easy Asterisk PBX + coturn (DigitalOcean droplet edition)..."

    local EA_DIR="$DOCKER_DIR/asterisk-do"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $EA_DIR with Dockerfile, docker-compose.yml, .env"
        echo "[DRY-RUN] Would copy/download vendor files from easy-asterisk"
        echo "[DRY-RUN] Would detect droplet public IP via DO metadata service"
        echo "[DRY-RUN] Would open UFW ports: 5060, 5061, 8080, 8088, 8089, 3478, 10000-20000, 49152-49252"
        echo "[DRY-RUN] Would offer to create a DigitalOcean Cloud Firewall via doctl"
        return 0
    fi

    mkdir -p "$EA_DIR"
    mkdir -p "$EA_DIR/config/asterisk" "$EA_DIR/config/easy-asterisk" \
             "$EA_DIR/logs" "$EA_DIR/spool" "$EA_DIR/lib"
    ensure_docker_dir_ownership "$EA_DIR"
    cd "$EA_DIR" || return 1

    mkdir -p docker

    # ── Vendor files (shared with services/asterisk.sh — no duplication) ──────
    local _SELF_DIR_LOCAL
    _SELF_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local VENDOR_DIR="$_SELF_DIR_LOCAL/../vendor/easy-asterisk"

    if [[ -d "$VENDOR_DIR" ]]; then
        log_info "Copying vendor files from $VENDOR_DIR ..."
        cp "$VENDOR_DIR/Dockerfile"                    ./Dockerfile
        cp "$VENDOR_DIR/docker/entrypoint.sh"          ./docker/entrypoint.sh
        cp "$VENDOR_DIR/docker/coturn-entrypoint.sh"   ./docker/coturn-entrypoint.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk.sh
        cp "$VENDOR_DIR/easy-asterisk-v0.10.0.sh"      ./easy-asterisk-v0.10.0.sh
    else
        log_info "Vendor directory not found — downloading from GitHub ..."
        local GH_RAW="https://raw.githubusercontent.com/DeadDork/easy-asterisk/main"
        curl -fsSL "$GH_RAW/Dockerfile"                        -o ./Dockerfile
        curl -fsSL "$GH_RAW/docker/entrypoint.sh"              -o ./docker/entrypoint.sh
        curl -fsSL "$GH_RAW/docker/coturn-entrypoint.sh"       -o ./docker/coturn-entrypoint.sh
        curl -fsSL "$GH_RAW/easy-asterisk-v0.10.0.sh"          -o ./easy-asterisk.sh
        cp ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh
    fi

    chmod 755 ./easy-asterisk.sh ./easy-asterisk-v0.10.0.sh \
              ./docker/entrypoint.sh ./docker/coturn-entrypoint.sh

    # ── DigitalOcean droplet detection ────────────────────────────────────────
    # A droplet's own public IP/ID are readable, unauthenticated, from the
    # link-local metadata service — no API token needed for this part.
    echo ""
    log_info "Reading DigitalOcean droplet metadata..."
    local DO_META="http://169.254.169.254/metadata/v1"
    local DROPLET_ID PUBLIC_IP
    DROPLET_ID="$(curl -fsS --max-time 2 "$DO_META/id" 2>/dev/null || true)"
    PUBLIC_IP="$(curl -fsS --max-time 2 "$DO_META/interfaces/public/0/ipv4/address" 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

    if [[ -n "$DROPLET_ID" ]]; then
        log_success "Detected DigitalOcean droplet id $DROPLET_ID, public IP ${PUBLIC_IP:-unknown}"
    else
        log_warning "DigitalOcean metadata service not reachable (not a droplet, or run in a container)."
        log_warning "Continuing anyway — Cloud Firewall automation will be skipped."
    fi

    # ── Domain (always public — this is a cloud box) ──────────────────────────
    echo ""
    echo "  Point a DNS A record at this droplet before continuing:"
    echo "    <subdomain>.${SITE_DOMAIN:-example.com}  A  ${PUBLIC_IP:-<droplet public IP>}"
    local DOMAIN_NAME=""
    prompt_text "FQDN for this PBX [blank=self-signed cert, IP-only access]:" "" DOMAIN_NAME
    [[ -z "$DOMAIN_NAME" ]] && log_warning "No FQDN entered — using a self-signed cert; phones must trust it manually."

    # ── Secrets ───────────────────────────────────────────────────────────────
    local TURN_PASSWORD
    TURN_PASSWORD="$(generate_password 24)"

    # Unlike the LAN edition, a droplet is always reachable — TURN always has
    # a usable address (the FQDN if set, otherwise the droplet's public IP).
    local TURN_SERVER_VAL="${DOMAIN_NAME:-$PUBLIC_IP}:3478"

    # ── docker-compose.yml ────────────────────────────────────────────────────
    cat > docker-compose.yml << 'EOF'
name: asterisk-do

services:
  asterisk:
    build: .
    container_name: easy-asterisk-do
    network_mode: host
    depends_on:
      coturn:
        condition: service_started
    volumes:
      - ./config/asterisk:/etc/asterisk
      - ./config/easy-asterisk:/etc/easy-asterisk
      - ./logs:/var/log/asterisk
      - ./spool:/var/spool/asterisk
      - ./lib:/var/lib/asterisk
      - ./easy-asterisk.sh:/usr/local/bin/easy-asterisk:ro
CADDY_VOLUME_PLACEHOLDER
    env_file: .env
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "asterisk", "-rx", "core show version"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
    image: coturn/coturn:latest
    container_name: easy-asterisk-do-coturn
    network_mode: host
    user: root
    entrypoint: ["/coturn-entrypoint.sh"]
    volumes:
      - ./docker/coturn-entrypoint.sh:/coturn-entrypoint.sh:ro
    env_file: .env
    command:
      - -n
      - --listening-port=${TURN_PORT:-3478}
      - --listening-ip=0.0.0.0
      - --fingerprint
      - --lt-cred-mech
      - --user=${TURN_USERNAME:-easyasterisk}:${TURN_PASSWORD}
      - --realm=${DOMAIN_NAME:-localhost}
      - --min-port=49152
      - --max-port=49252
      - --no-tls
      - --no-dtls
      - --no-cli
      - --no-multicast-peers
      - --log-file=stdout
    restart: unless-stopped

EOF

    # Share Caddy's cert store (read-only) so the entrypoint can auto-sync a
    # real Let's Encrypt cert for DOMAIN_NAME instead of falling back to
    # self-signed. No-op if Caddy isn't installed on this box.
    if [[ -d "$DOCKER_DIR/caddy/data" ]]; then
        sed -i "s#CADDY_VOLUME_PLACEHOLDER#      - ${DOCKER_DIR}/caddy/data:/caddy-data:ro#" docker-compose.yml
    else
        sed -i "/CADDY_VOLUME_PLACEHOLDER/d" docker-compose.yml
    fi

    # ── .env ──────────────────────────────────────────────────────────────────
    cat > .env << ENV
# ── Domain ────────────────────────────────────────────────────
# Public FQDN for this droplet. Leave empty to fall back to a self-signed
# cert reachable at the droplet's public IP (${PUBLIC_IP:-unknown}).
DOMAIN_NAME=${DOMAIN_NAME}

# ── TURN/STUN ─────────────────────────────────────────────────
TURN_USERNAME=easyasterisk
TURN_PASSWORD=${TURN_PASSWORD}
TURN_PORT=3478
TURN_SERVER=${TURN_SERVER_VAL}

# ── RTP port range ────────────────────────────────────────────
RTP_START=10000
RTP_END=20000

# ── VLAN/VPN subnets ──────────────────────────────────────────
# A droplet has one public NIC, so this is usually irrelevant. Only set it
# if you're bridging phones back in over a VPN (e.g. WireGuard/Tailscale)
# on a subnet the droplet isn't directly attached to.
HAS_VLANS=n
VLAN_SUBNETS=

# ── Web admin ─────────────────────────────────────────────────
WEB_ADMIN_PORT=8080
WEB_ADMIN_AUTH_DISABLED=false
ENV
    chmod 600 .env

    # ── UFW firewall rules (host-level) ───────────────────────────────────────
    if command -v ufw &>/dev/null; then
        log_info "Opening UFW ports for Asterisk + coturn..."
        ufw allow 5060/udp
        ufw allow 5060/tcp
        ufw allow 5061/tcp
        ufw allow 8080/tcp
        ufw allow 8088/tcp
        ufw allow 8089/tcp
        ufw allow 3478/udp
        ufw allow 3478/tcp
        ufw allow 10000:20000/udp
        ufw allow 49152:49252/udp
        log_success "UFW rules added."
    fi

    # ── DigitalOcean Cloud Firewall (network edge, in front of the droplet) ───
    local DO_FW_RULES=(
        "protocol:tcp,ports:22,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:5060,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:5061,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:8080,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:8088-8089,address:0.0.0.0/0,address:::/0"
        "protocol:tcp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:3478,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:10000-20000,address:0.0.0.0/0,address:::/0"
        "protocol:udp,ports:49152-49252,address:0.0.0.0/0,address:::/0"
    )

    echo ""
    if [[ -n "$DROPLET_ID" ]] && command -v doctl &>/dev/null && doctl account get &>/dev/null; then
        local EXISTING_FW
        EXISTING_FW="$(doctl compute firewall list --format ID,DropletIDs --no-header 2>/dev/null \
            | grep -E "(^|[, ])${DROPLET_ID}([, ]|\$)" | awk '{print $1}' | head -1)"

        if [[ -n "$EXISTING_FW" ]]; then
            log_warning "A Cloud Firewall (id $EXISTING_FW) is already attached to this droplet — not touching it."
            log_warning "Add these inbound rules to it yourself (Networking → Firewalls in the DO console):"
            printf '    %s\n' "${DO_FW_RULES[@]}"
        else
            local DO_FW=""
            prompt_yn "Create a DigitalOcean Cloud Firewall for this droplet via doctl now? (y/n):" "y" DO_FW
            if [[ "$DO_FW" =~ ^[Yy]$ ]]; then
                if doctl compute firewall create \
                    --name "asterisk-do" \
                    --droplet-ids "$DROPLET_ID" \
                    --inbound-rules "$(IFS=' '; echo "${DO_FW_RULES[*]}")" \
                    --outbound-rules "protocol:tcp,ports:all,address:0.0.0.0/0,address:::/0 protocol:udp,ports:all,address:0.0.0.0/0,address:::/0 protocol:icmp,ports:0,address:0.0.0.0/0,address:::/0" \
                    &>/dev/null; then
                    log_success "Cloud Firewall 'asterisk-do' created and attached (SSH/22 included so you don't get locked out)."
                    log_info "Verify it in the DO console — adjust the SSH rule if you use a non-default SSH port."
                else
                    log_warning "doctl firewall create failed — add the rules manually (see README)."
                fi
            fi
        fi
    else
        log_info "doctl not installed/authenticated — configure a DigitalOcean Cloud Firewall manually:"
        log_info "Control Panel → Networking → Firewalls → create, attach to this droplet, allow:"
        printf '    %s\n' "${DO_FW_RULES[@]}"
    fi

    # ── Caddy reverse proxy for web admin ─────────────────────────────────────
    local EXTRA_BLOCK=""
    if [ -d "$DOCKER_DIR/authelia" ]; then
        local _use_auth=""
        prompt_yn "Protect Asterisk web admin with Authelia SSO? (y/n):" "y" _use_auth
        if [[ "$_use_auth" =~ ^[Yy]$ ]]; then
            EXTRA_BLOCK="    import authelia"
            # Disable built-in auth since Authelia handles it
            sed -i "s/^WEB_ADMIN_AUTH_DISABLED=.*/WEB_ADMIN_AUTH_DISABLED=true/" .env
        fi
    fi
    configure_caddy_for_service "Asterisk Web Admin" "8080" "asterisk" "$EXTRA_BLOCK"

    # ── README ────────────────────────────────────────────────────────────────
    write_readme "$EA_DIR" << MD
# Easy Asterisk PBX + coturn — DigitalOcean droplet edition

Self-hosted SIP PBX using Easy Asterisk with a coturn TURN/STUN server for
NAT traversal, sized and secured for a public DigitalOcean droplet. For a
home/LAN box with VLAN support, use \`~/docker/asterisk\` (services/asterisk.sh)
instead.

## Droplet sizing

Asterisk + coturn is light for a handful of SIP extensions and personal use.

| Plan                          | vCPU | RAM  | Good for                              |
|--------------------------------|------|------|----------------------------------------|
| Basic (regular), 1 GB           | 1    | 1 GB | Minimum — a few extensions, light use  |
| **Basic (regular), 2 GB — recommended** | 1    | 2 GB | Comfortable headroom for Docker + a handful of concurrent calls |
| Basic (regular), 4 GB           | 2    | 4 GB | Several simultaneous calls, conference bridges, transcoding |

25–50 GB SSD (the smallest included disk) is plenty — this stack is not
storage-heavy. Any DO region close to where the phones actually are is fine;
SIP/RTP care about latency more than raw bandwidth.

**OS image:** Ubuntu 24.04 LTS (supported through April 2029) is the safe,
battle-tested choice for Docker + coturn. Ubuntu 26.04 LTS is also available
and supported longer (through 2031) if you'd rather track the newer LTS.

## DNS

Before running this installer, point an A record at the droplet's public IP:

\`\`\`
asterisk.yourdomain.com   A   <droplet public IP>
\`\`\`

The installer reads the droplet's public IP itself (via the DigitalOcean
metadata service) and shows it to you during setup.

## Security

- **SSH:** key-based auth only, password login disabled — \`services/base.sh\`
  in this repo offers to do this for you on first run. Don't skip it; this
  box is public.
- **Two firewall layers, same rule set:**
  - **DigitalOcean Cloud Firewall** — filters at the network edge, before
    traffic reaches the droplet. This installer offers to create one
    automatically via \`doctl\` (only if none is already attached to this
    droplet — it never overwrites an existing one, to avoid clobbering a
    custom SSH allow-list). If \`doctl\` isn't set up, add the rules below
    manually in the DO console (Networking → Firewalls).
  - **UFW** — host-level, configured automatically by this installer as a
    second layer. Keep both in sync; don't let them contradict each other.
- Consider adding \`crowdsec\` (services/crowdsec.sh, also in this repo) for
  intrusion-prevention against SIP brute-force/scanning, which is constant
  background noise on any public SIP port.
- Consider DO's automated backups/snapshots for the droplet so a bad config
  change or compromise is a quick rollback.

### Ports (open on both the Cloud Firewall and UFW)

| Port          | Protocol | Purpose                          |
|---------------|----------|-----------------------------------|
| 22            | TCP      | SSH (keep this open or you're locked out) |
| 5060          | UDP/TCP  | SIP signalling (unencrypted)     |
| 5061          | TCP      | SIP over TLS                     |
| 8080          | TCP      | Easy Asterisk web admin          |
| 8088/8089     | TCP      | Asterisk HTTP/WS (ARI/AMI)       |
| 3478          | UDP/TCP  | TURN/STUN (coturn)               |
| 10000–20000   | UDP      | RTP media streams                |
| 49152–49252   | UDP      | TURN relay media ports           |

## Manage

\`\`\`bash
docker compose up -d --build   # build image and start
docker compose up -d           # start (after initial build)
docker compose down            # stop
docker compose logs -f         # follow logs
docker compose pull            # update coturn image
docker compose up -d --build   # rebuild asterisk image
\`\`\`

## Management script

\`\`\`bash
docker exec -it easy-asterisk-do easy-asterisk --help
\`\`\`

Use it to create SIP extensions (Server Settings → Extensions) before
connecting a phone.

## Connecting with Sipnetic (Android)

[Sipnetic](https://www.sipnetic.com/) is a free Android SIP client with
TLS/SRTP and STUN/TURN/ICE support — a good fit for this setup. (iPhone
users: Linphone or Zoiper cover the same ground.)

1. In the Easy Asterisk web admin, create an extension — note its
   username/number and password.
2. In Sipnetic, add an account with:

| Setting          | Value                                          |
|-------------------|------------------------------------------------|
| Username          | extension number/username from easy-asterisk   |
| Password          | extension password from easy-asterisk          |
| Domain            | \`${DOMAIN_NAME:-$PUBLIC_IP}\`                        |
| Transport         | TLS                                             |
| Port              | 5061                                            |
| SRTP              | Enabled (optional, for encrypted media)         |
| STUN/TURN server  | \`${DOMAIN_NAME:-$PUBLIC_IP}:3478\`                   |
| TURN username     | \`easyasterisk\` (see \`.env\` → \`TURN_USERNAME\`)    |
| TURN password     | see \`.env\` → \`TURN_PASSWORD\`                      |

3. Save and let it register. If it registers but calls connect with no
   audio, double-check the RTP/TURN port ranges are open on *both* firewall
   layers above.

## TLS certificate

If Caddy is installed and already holds a Let's Encrypt cert for
\`DOMAIN_NAME\` (i.e. there's a Caddyfile site block for that exact hostname),
the container mounts Caddy's cert store read-only and the entrypoint syncs
it in automatically on every start — and re-checks every 12h so renewals
get picked up without a restart. No Caddyfile block for the domain, or no
Caddy at all, falls back to a self-signed cert (phones must be configured
to accept it).

## Web admin

Access the Easy Asterisk web interface at http://<droplet-ip>:8080
or via your configured reverse-proxy domain.

## Data directories (all inside ~/docker/asterisk-do/, included in backup)

| Directory            | Contents                        |
|-----------------------|----------------------------------|
| config/asterisk/      | /etc/asterisk — dialplan, SIP   |
| config/easy-asterisk/ | /etc/easy-asterisk — web config |
| logs/                 | /var/log/asterisk               |
| spool/                | /var/spool/asterisk             |
| lib/                  | /var/lib/asterisk               |
MD

    # ── Start ─────────────────────────────────────────────────────────────────
    echo ""
    local START_NOW=""
    prompt_yn "Build and start Asterisk now? (y/n):" "y" START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        docker compose up -d --build \
            && log_success "Easy Asterisk (DO edition) started" \
            || log_warning "Start failed — check: docker compose logs"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    log_success "Easy Asterisk (DigitalOcean edition) installed at $EA_DIR"
    if [[ -n "$DOMAIN_NAME" ]]; then
        echo "  Mode:        FQDN ($DOMAIN_NAME)"
        echo "  TURN server: ${DOMAIN_NAME}:3478"
    else
        echo "  Mode:        IP-only (self-signed cert)"
        echo "  TURN server: ${PUBLIC_IP:-unknown}:3478"
    fi
    echo "  Public IP:   ${PUBLIC_IP:-unknown}"
    echo "  SIP port:    5061 (TLS) / 5060 (UDP)"
    echo "  Web admin:   http://${PUBLIC_IP:-localhost}:8080"
    echo "  Manage:      docker compose -f $EA_DIR/docker-compose.yml <up|down|logs>"
    echo "  Script:      docker exec -it easy-asterisk-do easy-asterisk --help"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_asterisk-do
