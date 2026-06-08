#!/bin/bash
# services/js99er.sh — Self-hosted TI-99/4A emulator (js99er.net).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash js99er.sh
# (Docker must already be installed when run standalone)
#
# Builds the js99er-angular source into a static site (multi-stage Docker
# build) with an offline Google Fonts fix, served by nginx. Each service lives
# in its own folder with its own standalone docker-compose.yml.

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

register_service js99er gaming "Self-hosted TI-99/4A emulator (js99er.net)" 8099

install_js99er() {
    require_docker || return 1
    log_info "Installing js99er (TI-99/4A emulator)..."
    local JS99ER_DIR="$DOCKER_DIR/js99er"

    # Port: default 8099 (8090 clashes with wolf-pair on a shared gaming box).
    local JS99ER_PORT=""
    prompt_text "Local port to expose js99er on [8099]:" "8099" JS99ER_PORT

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $JS99ER_DIR (with nginx/ subdir)"
        echo "[DRY-RUN] Would clone/update https://github.com/Rasmus-M/js99er-angular.git into $JS99ER_DIR/src"
        echo "[DRY-RUN] Would write Dockerfile, nginx/nginx.conf and a standalone docker-compose.yml"
        echo "[DRY-RUN] Would build the js99er image and start the container on port $JS99ER_PORT"
        return 0
    fi

    mkdir -p "$JS99ER_DIR/nginx"
    ensure_docker_dir_ownership "$JS99ER_DIR"
    cd "$JS99ER_DIR" || return 1

    # ── 1. Clone / update js99er source ──────────────────────────────────────
    log_info "Fetching js99er source..."
    if [ -d "$JS99ER_DIR/src/.git" ]; then
        git -C "$JS99ER_DIR/src" pull --ff-only || { log_error "Failed to update js99er source"; return 1; }
    else
        git clone --depth 1 https://github.com/Rasmus-M/js99er-angular.git "$JS99ER_DIR/src" \
            || { log_error "Failed to clone js99er source"; return 1; }
    fi
    log_success "Source ready"

    # ── 2. Dockerfile ────────────────────────────────────────────────────────
    # Strategy:
    #   • Disable Angular CLI's font-inlining optimisation (it fetches from
    #     fonts.googleapis.com at BUILD time and fails offline).
    #   • After the build, patch the output index.html to remove any remaining
    #     Google Fonts <link> tags that were in the source index.html.
    #   • Download the actual font files from Google's CDN during the Docker
    #     build (we still have internet at build time) and serve them locally.
    #   • Inject a local fonts.css that references those local files.
    log_info "Creating Dockerfile..."
    cat > "$JS99ER_DIR/Dockerfile" << 'DOCKERFILE'
# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

# git needed if package.json has git deps; python3/make/g++ for native modules
RUN apk add --no-cache git python3 make g++

WORKDIR /app
COPY src/package*.json ./

# Use --legacy-peer-deps because js99er-angular has some older peer dep chains
RUN npm ci --legacy-peer-deps

COPY src/ ./

# Disable Angular's build-time font inlining so it doesn't call out to
# fonts.googleapis.com (which would break in an air-gapped build).
# The jq approach is cleanest; fall back to sed if jq isn't present.
RUN if command -v jq >/dev/null 2>&1; then \
      jq '.projects["js99er"].architect.build.options.optimization = {"scripts":true,"styles":{"minify":true,"inlineCritical":true},"fonts":false}' \
        angular.json > angular.json.tmp && mv angular.json.tmp angular.json; \
    else \
      sed -i 's/"optimization": true/"optimization": {"scripts":true,"styles":{"minify":true,"inlineCritical":true},"fonts":false}/' angular.json || true; \
    fi

RUN npx ng build --configuration production --output-path /dist 2>&1

# Find where index.html actually landed (Angular may nest under /dist/browser
# or /dist/js99er depending on the project name in angular.json)
RUN find /dist -name "index.html" | head -5

# Resolve the actual index.html path and patch it
RUN INDEX=$(find /dist -name "index.html" | head -1) \
  && echo "Patching: $INDEX" \
  && sed -i \
       -e 's|<link[^>]*fonts\.googleapis\.com[^>]*/>||g' \
       -e 's|<link[^>]*fonts\.googleapis\.com[^>]*>||g' \
       -e 's|<link[^>]*fonts\.gstatic\.com[^>]*/>||g' \
       -e 's|<link[^>]*fonts\.gstatic\.com[^>]*>||g' \
       "$INDEX" \
  && sed -i 's|</head>|<link rel="stylesheet" href="/fonts/fonts.css"></head>|' "$INDEX" \
  && echo "Patched index.html OK" \
  && grep -i "fonts" "$INDEX" || true

# ── Stage 2: download fonts ───────────────────────────────────────────────────
# Do this in a separate stage so the font files are fetched fresh at build time
# using a known-good mechanism, and are not baked into the source tree.
FROM alpine AS fontfetcher

RUN apk add --no-cache curl xxd bash

WORKDIR /fonts

# We use the google-webfonts-helper ZIP download API — one request, all variants.
# This is more reliable than trying to parse the JSON API and extract individual URLs.
# Double-quotes around the URL are required because of the & in query params.
RUN curl -fsSL \
    "https://gwfh.mranftl.com/api/fonts/roboto?download=zip&subsets=latin&variants=300,regular,500,700&formats=woff2" \
    -o roboto.zip \
  && unzip roboto.zip \
  && rm roboto.zip \
  && ls -la

# Material Icons — download the woff2 directly from Google's CDN.
# This URL is stable; Material Icons has not changed its CDN path in years.
# We verify the file is actually a woff2 (starts with wOF2 magic bytes).
RUN curl -fsSL \
    "https://fonts.gstatic.com/s/materialicons/v140/flUhRq6tzZclQEJ-Vdg-IuiaDsNc.woff2" \
    -o material-icons.woff2 \
  && MAGIC=$(xxd -p -l 4 material-icons.woff2) \
  && echo "Magic bytes: $MAGIC" \
  && [ "$MAGIC" = "774f4632" ] \
  && echo "Material Icons OK (valid wOF2)" \
  || (echo "ERROR: Not a valid woff2 file. Got magic: $MAGIC"; exit 1)

# Generate the CSS that maps font-family names to the local files.
# File names come from what gwfh actually produces (roboto-v{N}-latin-{variant}.woff2).
RUN ls *.woff2 | sort && echo "--- files above ---"

# Generate fonts.css in pure shell — no python3 needed
RUN <<'GENCSS'
#!/bin/bash
set -e

CSS="/* ================================================================
   Local fonts — replaces fonts.googleapis.com CDN references
   Generated at Docker build time
   ================================================================ */

"

for f in $(ls roboto-*.woff2 2>/dev/null | sort); do
    # filename pattern: roboto-v{N}-latin-{variant}.woff2
    variant=$(echo "$f" | sed 's/roboto-v[0-9]*-latin-\(.*\)\.woff2/\1/')
    case "$variant" in
        300)     weight="300" ;;
        regular) weight="400" ;;
        500)     weight="500" ;;
        700)     weight="700" ;;
        *)       weight="400" ;;
    esac
    CSS="${CSS}@font-face {
    font-family: 'Roboto';
    font-style: normal;
    font-weight: ${weight};
    font-display: swap;
    src: url('/fonts/${f}') format('woff2');
    unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA,
                   U+02DC, U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193,
                   U+2212, U+2215, U+FEFF, U+FFFD;
}

"
done

MATERIAL=$(ls material-icons.woff2 2>/dev/null || true)
if [ -n "$MATERIAL" ]; then
    CSS="${CSS}@font-face {
    font-family: 'Material Icons';
    font-style: normal;
    font-weight: 400;
    font-display: block;
    src: url('/fonts/material-icons.woff2') format('woff2');
}

.material-icons {
    font-family: 'Material Icons';
    font-weight: normal;
    font-style: normal;
    font-size: 24px;
    line-height: 1;
    letter-spacing: normal;
    text-transform: none;
    display: inline-block;
    white-space: nowrap;
    word-wrap: normal;
    direction: ltr;
    -webkit-font-feature-settings: 'liga';
    -webkit-font-smoothing: antialiased;
}
"
fi

printf '%s' "$CSS" > fonts.css
echo "fonts.css written — first 400 chars:"
head -c 400 fonts.css
GENCSS

# ── Stage 3: serve ────────────────────────────────────────────────────────────
FROM nginx:alpine

# Copy whichever subdirectory contains index.html
RUN mkdir -p /usr/share/nginx/html
COPY --from=builder /dist /dist-tmp
RUN INDEX=$(find /dist-tmp -name "index.html" | head -1) \
  && DIST_DIR=$(dirname "$INDEX") \
  && cp -r "$DIST_DIR"/. /usr/share/nginx/html/ \
  && rm -rf /dist-tmp
COPY --from=fontfetcher /fonts        /usr/share/nginx/html/fonts
COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80
DOCKERFILE
    log_success "Dockerfile created"

    # ── 3. nginx config ──────────────────────────────────────────────────────
    cat > "$JS99ER_DIR/nginx/nginx.conf" << 'NGINXCONF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Fonts — long cache, CORS open (woff2 needs it in some browsers)
    location /fonts/ {
        add_header Cache-Control "public, max-age=31536000, immutable";
        add_header Access-Control-Allow-Origin "*";
    }

    # Static assets — JS, CSS, images, fonts
    location ~* \.(js|css|ico|png|svg|woff2|woff|webp)$ {
        expires 1y;
        add_header Cache-Control "public, immutable";
    }

    # Angular router — unknown paths serve index.html
    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache";
    }

    gzip on;
    gzip_types text/plain text/css application/javascript application/json image/svg+xml;
    gzip_min_length 1024;
}
NGINXCONF
    log_success "nginx config created"

    # ── 4. Standalone docker-compose.yml (per-service folder) ────────────────
    cat > "$JS99ER_DIR/docker-compose.yml" << COMPOSE
name: js99er

services:
  js99er:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: js99er
    ports:
      - "${JS99ER_PORT}:80"
    restart: unless-stopped
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: \${CADDY_NET:-caddy_net}
COMPOSE
    log_success "Created js99er/docker-compose.yml"

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JS99ER_DIR"
    echo ""
    log_success "js99er configured at $JS99ER_DIR"

    # ── 5. Reverse proxy (no-ops if Caddy isn't installed locally) ───────────
    configure_caddy_for_service "js99er" "js99er:80" "js99er"

    # ── 6. Build & start ─────────────────────────────────────────────────────
    local START_JS99ER=""
    prompt_yn "Build and start js99er now? (first build takes a few minutes) (y/n):" "y" START_JS99ER
    if [ "$START_JS99ER" = "y" ] || [ "$START_JS99ER" = "Y" ]; then
        log_info "Building and starting js99er..."
        if docker compose up -d --build; then
            log_success "js99er started"
            log_info "Verifying fonts are served correctly..."
            local HTTP_STATUS
            HTTP_STATUS=$(curl -so /dev/null -w "%{http_code}" "http://localhost:${JS99ER_PORT}/fonts/fonts.css" 2>/dev/null || echo "000")
            if [ "$HTTP_STATUS" = "200" ]; then
                log_success "fonts.css is being served (HTTP 200)"
            else
                log_warning "fonts.css returned HTTP $HTTP_STATUS — check: docker logs js99er"
            fi
        else
            log_warning "Failed to build/start js99er — check: docker compose logs"
        fi
    fi

    # ── 7. Access summary ────────────────────────────────────────────────────
    echo ""
    echo "  Access at:  http://localhost:${JS99ER_PORT}"
    echo "  If you set a domain above, it is also reachable via that domain (HTTPS)."
    echo "  Online alternative (no install needed): https://js99er.net"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_js99er
