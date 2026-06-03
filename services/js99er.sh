#!/bin/bash
# services/js99er.sh — Self-hosted TI-99/4A emulator (js99er.net).
# Part of the modular post-install system (sourced by setup.sh).
#
# Builds the js99er-angular source into a static site (multi-stage Docker
# build) with an offline Google Fonts fix, served by nginx. Each service lives
# in its own folder with its own standalone docker-compose.yml.

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
COMPOSE
    log_success "Created js99er/docker-compose.yml"

    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$JS99ER_DIR"
    echo ""
    log_success "js99er configured at $JS99ER_DIR"

    # ── 5. Reverse proxy (no-ops if Caddy isn't installed locally) ───────────
    configure_caddy_for_service "js99er" "$JS99ER_PORT" "js99er"

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
