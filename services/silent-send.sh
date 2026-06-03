#!/bin/bash
# services/silent-send.sh — Silent Send browser extension (PII redaction for AI chat).
# Part of the modular post-install system (sourced by setup.sh).
#
# NON-DOCKER module. Silent Send is a browser extension (Chrome/Brave/Firefox/
# Safari) that intercepts personal info before it's sent to AI chatbots and
# swaps in user-defined substitutes — entirely client-side, no server/container.
#
# Because it ships as source you load into a browser, this module:
#   1. installs the build toolchain (git, Node.js >= 18, npm),
#   2. clones the repo to ~/silent-send (or a path you choose),
#   3. runs `npm install` so the Firefox build/sign tooling (web-ext) is ready,
#   4. optionally builds a signed Firefox .xpi (needs free Mozilla API creds),
#   5. prints exactly how to load/build it in each browser.
#
# Source: https://github.com/outis1one/silent-send

register_service silent-send extras "Browser extension: redact PII before it reaches AI chatbots"

install_silent-send() {
    # Non-docker — no require_docker.
    local SS_REPO="https://github.com/outis1one/silent-send.git"
    local SS_DIR="$ACTUAL_HOME/silent-send"

    cat << "EOF"
╔═══════════════════════════════════════════════════════╗
║                                                       ║
║   SILENT SEND                                         ║
║   Redact PII before it reaches AI chatbots           ║
║   (browser extension — Chrome / Brave / Firefox)     ║
║                                                       ║
╚═══════════════════════════════════════════════════════╝
EOF
    echo ""
    echo "  A browser extension that intercepts names, emails, secrets and other"
    echo "  personal data before it's sent to AI services, swapping in your own"
    echo "  substitutes. All client-side — there is no server or container."
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] silent-send install would:"
        echo "  - Install build deps: git, Node.js >= 18 (NodeSource 22.x), npm"
        echo "  - Clone $SS_REPO into $SS_DIR (or update if already present)"
        echo "  - Run 'npm install' in $SS_DIR (Firefox build/sign tooling: web-ext)"
        echo "  - Optionally build a signed Firefox .xpi (needs Mozilla API creds)"
        echo "  - Print load-unpacked + build/sign instructions for each browser"
        return 0
    fi

    # ── Clone location ────────────────────────────────────────────────────────
    prompt_text "  Clone location [$SS_DIR]:" "$SS_DIR" SS_DIR
    SS_DIR="${SS_DIR/#\~/$ACTUAL_HOME}"
    SS_DIR="${SS_DIR%/}"

    # ── 1. git ─────────────────────────────────────────────────────────────────
    if ! command -v git >/dev/null 2>&1; then
        log_info "Installing git..."
        apt-get install -y git >/dev/null 2>&1 || { log_error "Failed to install git."; return 1; }
    fi
    log_success "git: $(git --version | awk '{print $3}')"

    # ── 2. Node.js >= 18 + npm (needed to build/sign for Firefox & Safari) ──────
    local NODE_MAJOR=0
    command -v node >/dev/null 2>&1 && NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
    if ! [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
        log_warning "Node.js >= 18 required for building/signing (found: $(node -v 2>/dev/null || echo none))."
        local INSTALL_NODE=""
        prompt_yn "  Install Node.js 22 LTS from NodeSource now? (y/n):" "y" INSTALL_NODE
        if [ "$INSTALL_NODE" = "y" ] || [ "$INSTALL_NODE" = "Y" ]; then
            log_info "Installing Node.js 22 LTS..."
            curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
            apt-get install -y nodejs >/dev/null 2>&1
            NODE_MAJOR=$(node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1)
        fi
    fi
    if [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
        log_success "Node.js: $(node -v)  npm: $(npm -v 2>/dev/null || echo '?')"
    else
        log_warning "Node.js < 18 — Chrome 'load unpacked' still works, but the Firefox"
        log_warning "signed build won't. Install Node 18+ later, then run 'npm install' in $SS_DIR."
    fi

    # ── 3. Clone / update the repo ──────────────────────────────────────────────
    if [ -d "$SS_DIR/.git" ]; then
        log_info "Updating existing checkout in $SS_DIR..."
        git -C "$SS_DIR" pull --ff-only || log_warning "Could not fast-forward — keeping current checkout."
    else
        log_info "Cloning $SS_REPO → $SS_DIR..."
        git clone --depth 1 "$SS_REPO" "$SS_DIR" || { log_error "Clone failed."; return 1; }
    fi
    log_success "Source ready at $SS_DIR"

    # ── 4. npm install (build/sign tooling: web-ext) ────────────────────────────
    if command -v npm >/dev/null 2>&1; then
        log_info "Installing npm dependencies (this readies the Firefox build/sign tooling)..."
        ( cd "$SS_DIR" && npm install ) \
            || log_warning "npm install reported errors — Chrome 'load unpacked' still works without it."
    fi

    # ── 5. Optional: build a signed Firefox .xpi ────────────────────────────────
    # Needs free Mozilla API credentials. Skipped in unattended mode.
    if [ "$UNATTENDED" != true ] && [ "$NODE_MAJOR" -ge 18 ] 2>/dev/null; then
        echo ""
        local DO_FF=""
        prompt_yn "  Build a signed Firefox .xpi now? (needs free Mozilla API creds) (y/n):" "n" DO_FF
        if [ "$DO_FF" = "y" ] || [ "$DO_FF" = "Y" ]; then
            echo ""
            echo "  Get credentials (free) at:"
            echo "    https://addons.mozilla.org/developers/addon/api/key/"
            echo ""
            local FF_KEY="" FF_SECRET=""
            prompt_text "  WEB_EXT_API_KEY (e.g. user:12345678:901), blank to skip:" "" FF_KEY
            prompt_text "  WEB_EXT_API_SECRET, blank to skip:" "" FF_SECRET
            if [ -n "$FF_KEY" ] && [ -n "$FF_SECRET" ]; then
                cat > "$SS_DIR/.env" << ENVEOF
WEB_EXT_API_KEY="$FF_KEY"
WEB_EXT_API_SECRET="$FF_SECRET"
ENVEOF
                chmod 600 "$SS_DIR/.env"
                log_info "Signing (first run takes 1-5 min)..."
                if ( cd "$SS_DIR" && npm run sign:firefox ); then
                    log_success "Signed .xpi written to $SS_DIR/dist/firefox-signed/"
                else
                    log_warning "Signing failed — check the output above. You can retry: (cd $SS_DIR && npm run sign:firefox)"
                fi
            else
                echo "  Skipping Firefox signing (no credentials entered)."
            fi
        fi
    fi

    # ── 6. Hand the checkout back to the user ───────────────────────────────────
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$SS_DIR" 2>/dev/null || true

    # ── 7. README ───────────────────────────────────────────────────────────────
    write_readme "$SS_DIR" << MD
# Silent Send

Browser extension that intercepts personal information (names, emails,
usernames, hostnames, phone numbers, API keys, tokens, SSNs, credit cards…)
before it's sent to AI chatbots, swapping in your own substitutes. Everything
runs client-side in the browser — there is no server or container.

Source checkout: \`$SS_DIR\`  ·  Upstream: https://github.com/outis1one/silent-send

## Load it in your browser

### Chrome / Brave (no build needed)
1. Open \`chrome://extensions/\` (or \`brave://extensions/\`)
2. Turn on **Developer mode** (top-right)
3. **Load unpacked** → select \`$SS_DIR\`
4. Refresh any open AI chat tabs after code updates

### Firefox (signed, persistent)
A signed \`.xpi\` is required for a permanent install:
\`\`\`bash
cd $SS_DIR
cp .env.example .env      # then add your Mozilla API key/secret
npm run sign:firefox      # → dist/firefox-signed/*.xpi
\`\`\`
Open the \`.xpi\` in Firefox (File → Open File) to install.
Temporary test session (no signing): \`npm run run:firefox\`.

### Safari (macOS only)
\`\`\`bash
npm install && ./build-safari.sh
open "safari-build/Silent Send.xcodeproj"   # then Product → Run in Xcode
\`\`\`

## Updating
\`\`\`bash
cd $SS_DIR && git pull && npm install
\`\`\`
Then reload the extension (Chrome/Brave: the reload icon on the extensions
page; Firefox: re-sign and re-open the new .xpi).

## Configure
Use the extension's popup/options UI to set your identity, substitution
mappings, custom domains, and to import/export your config.
MD

    # ── 8. Summary ──────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "          SILENT SEND — READY"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Source checkout: $SS_DIR"
    echo ""

    # Note which browsers are present to point the user at the right steps.
    local _found=()
    command -v google-chrome >/dev/null 2>&1 || command -v google-chrome-stable >/dev/null 2>&1 && _found+=("Chrome")
    command -v brave-browser  >/dev/null 2>&1 && _found+=("Brave")
    command -v chromium       >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1 && _found+=("Chromium")
    command -v firefox        >/dev/null 2>&1 && _found+=("Firefox")
    if [ "${#_found[@]}" -gt 0 ]; then
        echo "  Browsers detected on this machine: ${_found[*]}"
    else
        echo "  No browser detected here — load the extension on whichever machine"
        echo "  has your browser (the checkout above is what you point it at)."
    fi
    echo ""
    echo "  Chrome / Brave  →  chrome://extensions → Developer mode → Load unpacked"
    echo "                     → select  $SS_DIR"
    echo "  Firefox         →  cd $SS_DIR && cp .env.example .env  (add Mozilla creds)"
    echo "                     → npm run sign:firefox  → open dist/firefox-signed/*.xpi"
    echo ""
    echo "  Full instructions: $SS_DIR/README.md"
    echo ""
    log_success "Silent Send installed. Load it in your browser to start redacting."
}
