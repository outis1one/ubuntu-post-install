#!/bin/bash
# services/gitea.sh — Self-hosted Gitea (lightweight Git server), with an
# optional two-way GitHub mirror sync (gitea-github-sync.sh, vendored from
# the ai-stack bundle but genuinely standalone here — this does NOT pull in
# Ollama/ComfyUI/InvokeAI/any of the rest of that stack, just the one
# Gitea container + the sync script).
# Part of the modular post-install system (sourced by setup.sh).
#
# Can also be run standalone on any machine:
#   sudo bash gitea.sh
# (Docker must already be installed when run standalone)

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

        generate_password() {
            local _len="${1:-32}"
            tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$_len"
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

        configure_caddy_for_service() {
            local _name="$1" _upstream="$2" _subdomain="$3"
            local _display_port="${_upstream##*:}"
            log_info "Access $_name directly on port $_display_port (no Caddy in standalone mode)."
            CADDY_SERVICE_CONFIGURED=false
        }

        write_readme() {
            local _dir="$1"; shift
            mkdir -p "$_dir"
            cat > "$_dir/README.md"
        }
    fi

    ACTUAL_USER="${ACTUAL_USER:-${SUDO_USER:-$USER}}"
    ACTUAL_HOME="$(getent passwd "$ACTUAL_USER" 2>/dev/null | cut -d: -f6 || echo "${HOME:-/root}")"
    DOCKER_DIR="${DOCKER_DIR:-$ACTUAL_HOME/docker}"
    DRY_RUN="${DRY_RUN:-false}"
    UNATTENDED="${UNATTENDED:-false}"
    SITE_TZ="${SITE_TZ:-$(cat /etc/timezone 2>/dev/null || echo UTC)}"
    SITE_DOMAIN="${SITE_DOMAIN:-example.com}"

    register_service() { :; }
    _RUN_STANDALONE=1
fi
# ─────────────────────────────────────────────────────────────────────────────

register_service gitea utilities "Self-hosted Git server (Gitea) — raw local clones plus optional two-way GitHub mirror sync" 3001

_gitea_sync_vendor_src() {
    local _self_dir
    _self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    echo "$(cd "$_self_dir/.." && pwd)/vendor/ai-stack/gitea-github-sync.sh"
}

# Prompt for a token with retries — pasted tokens over SSH sometimes race the
# prompt (the terminal delivers the paste a beat after an already-submitted
# empty line, so the token shows up echoed on the *next* line instead of
# being read). A single empty answer used to be taken as "no token", silently
# — this gives it up to 3 tries before actually giving up, and strips
# whitespace in case the paste carried a stray leading/trailing newline.
_gitea_prompt_token() {
    local _question="$1" _varname="$2"
    local _max=1 _tries=0 _val=""
    [ "$UNATTENDED" != true ] && _max=3
    while [[ $_tries -lt $_max ]]; do
        prompt_text "$_question" "" _val
        _val="$(printf '%s' "$_val" | tr -d '[:space:]')"
        [[ -n "$_val" ]] && break
        _tries=$((_tries + 1))
        [[ $_tries -lt $_max ]] && log_warning "  Nothing came through — if you pasted it, try again (a paste can race the prompt over SSH)."
    done
    eval "$_varname='$_val'"
}

# Gitea's container always runs internally as UID 1000 (USER_UID/USER_GID in
# the compose file below are fixed, independent of whoever's running this
# installer) — the official image chowns /data to that UID on its own at
# startup. A plain ensure_docker_dir_ownership call fights that: it's a
# recursive chown of the whole service directory to $ACTUAL_USER, which on
# a box where the installer runs as root directly (ACTUAL_USER=root) resets
# the live data/ back to UID 0. If the container doesn't happen to restart
# right after (e.g. Update mode against an already-running container, which
# just no-ops), nothing ever re-fixes it, and every write to Gitea's own
# SQLite DB then fails with "attempt to write a readonly database" — the
# directory holding the DB file is owned by root, not the UID 1000 process
# trying to write it. Confirmed live. Chown everything else as normal in
# $DIR; leave data/ for the container to manage.
_gitea_fix_ownership() {
    local _dir="$1"
    [ "$DRY_RUN" = true ] && return 0
    chown "$ACTUAL_USER:$ACTUAL_USER" "$_dir" 2>/dev/null || true
    local _entry
    for _entry in "$_dir"/*; do
        [ -e "$_entry" ] || continue
        [ "$(basename "$_entry")" = "data" ] && continue
        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$_entry" 2>/dev/null || true
    done
}

# ── Own systemd timer, not gitea-github-sync.sh's built-in --install-timer ──
# The vendor script's own timer installer always runs the script bare (no
# --pull-only/--push-only), i.e. always both directions — there's no way to
# hand it a fixed sync direction. Since this installer asks up front which
# direction to run automatically, the timer's ExecStart bakes that flag in
# directly instead of delegating to the vendor script's own (less flexible)
# --install-timer/--remove-timer modes.
_gitea_write_sync_timer() {
    local DIR="$1" RUN_USER="$2" RUN_HOME="$3" FLAG="$4" INTERVAL="$5"
    local _service="/etc/systemd/system/gitea-github-sync.service"
    local _timer="/etc/systemd/system/gitea-github-sync.timer"

    cat > "$_service" << UNIT
[Unit]
Description=Gitea-GitHub Mirror Sync
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=${RUN_USER}
Environment=HOME=${RUN_HOME}
Environment=SYNC_ENV=${DIR}/.env
ExecStart=/bin/bash ${DIR}/gitea-github-sync.sh ${FLAG}
UNIT

    cat > "$_timer" << UNIT
[Unit]
Description=Gitea-GitHub Sync Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=${INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
UNIT

    systemctl daemon-reload
    systemctl enable --now gitea-github-sync.timer
}

_gitea_remove_sync_timer() {
    systemctl disable --now gitea-github-sync.timer 2>/dev/null || true
    rm -f /etc/systemd/system/gitea-github-sync.service /etc/systemd/system/gitea-github-sync.timer
    systemctl daemon-reload 2>/dev/null || true
}

# Ask sync direction + autosync, apply to either a fresh setup or a
# reconfigure of an existing one. Always asked (matches pstn-trunk.sh's
# international-calling step reasoning: a live-editable extra, not a
# structural setting tied exclusively to fresh installs).
_gitea_run_sync_direction_step() {
    local DIR="$1"

    echo ""
    echo "  Sync direction:"
    echo "    1) GitHub -> Gitea only  (cloud to local — backup your GitHub repos here)"
    echo "    2) Gitea -> GitHub only  (local to cloud — push repos created here up to GitHub)"
    echo "    3) Both directions"
    local _DIR_CHOICE=""
    prompt_text "  Choice [1]:" "1" _DIR_CHOICE
    local FLAG="" DIR_DESC=""
    case "$_DIR_CHOICE" in
        2) FLAG="--push-only"; DIR_DESC="Gitea -> GitHub only" ;;
        3) FLAG="";            DIR_DESC="both directions" ;;
        *) FLAG="--pull-only"; DIR_DESC="GitHub -> Gitea only" ;;
    esac
    log_info "Sync direction: $DIR_DESC"

    _gitea_remove_sync_timer

    echo ""
    local AUTOSYNC=""
    prompt_yn "Enable automatic sync on a schedule? (y/n):" "y" AUTOSYNC
    if [[ "$AUTOSYNC" =~ ^[Yy]$ ]]; then
        local INTERVAL=""
        prompt_text "  Sync interval (e.g. 1h, 6h, 1d) [6h]:" "6h" INTERVAL
        _gitea_write_sync_timer "$DIR" "$ACTUAL_USER" "$ACTUAL_HOME" "$FLAG" "$INTERVAL"
        log_success "Timer installed: syncs every $INTERVAL ($DIR_DESC)."
        log_info "Check status: systemctl status gitea-github-sync.timer"
        log_info "Run now:      sudo systemctl start gitea-github-sync.service"
        log_info "Logs:         ~/.config/gitea-github-sync/sync.log"
    else
        log_info "Automatic sync not enabled. Run it yourself whenever you want:"
        log_info "  cd $DIR && bash gitea-github-sync.sh $FLAG"
        [[ -z "$FLAG" ]] && log_info "  (no flag needed for both directions)"
    fi

    # ── Run it now, off the timer — lets you confirm tokens/config are
    # actually correct right here instead of waiting for the first
    # scheduled run (or a manual invocation later) to find out.
    echo ""
    echo "  Run a sync now?"
    echo "    1) Dry-run preview only (--list) — shows what would sync, no changes"
    echo "    2) Run for real now ($DIR_DESC)"
    echo "    3) Skip — don't run anything now"
    local _RUN_DEFAULT="1"
    [ "$UNATTENDED" = true ] && _RUN_DEFAULT="3"
    local _RUN_NOW=""
    prompt_text "  Choice [$_RUN_DEFAULT]:" "$_RUN_DEFAULT" _RUN_NOW
    case "$_RUN_NOW" in
        2)
            log_info "Running sync now ($DIR_DESC)..."
            sudo -u "$ACTUAL_USER" env HOME="$ACTUAL_HOME" SYNC_ENV="$DIR/.env" \
                bash "$DIR/gitea-github-sync.sh" $FLAG \
                && log_success "Sync run complete." \
                || log_warning "Sync run failed — check the output above, or ~/.config/gitea-github-sync/sync.log"
            ;;
        3) log_info "Skipped — run it later with the commands above." ;;
        *)
            log_info "Dry-run preview (--list)..."
            sudo -u "$ACTUAL_USER" env HOME="$ACTUAL_HOME" SYNC_ENV="$DIR/.env" \
                bash "$DIR/gitea-github-sync.sh" --list
            ;;
    esac
}

install_gitea() {
    log_info "Setting up self-hosted Gitea..."

    local DIR="$DOCKER_DIR/gitea"
    local SYNC_SRC
    SYNC_SRC="$(_gitea_sync_vendor_src)"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would create $DIR with docker-compose.yml (gitea/gitea:latest)"
        echo "[DRY-RUN] Would scan for free host ports (web + SSH) to avoid collisions"
        echo "[DRY-RUN] Would prompt for a Gitea admin username/password, then create that account"
        echo "[DRY-RUN]   and an API token once the container is ready (no manual web wizard)"
        echo "[DRY-RUN] Would prompt for a GitHub token and copy in gitea-github-sync.sh"
        echo "[DRY-RUN] Would ask sync direction (GitHub->Gitea / Gitea->GitHub / both) and whether"
        echo "[DRY-RUN]   to install a systemd timer for automatic sync, or print manual instructions"
        echo "[DRY-RUN] Would offer to run a sync now (dry-run preview or for real), off-schedule"
        echo "[DRY-RUN] Would write $DIR/README.md"
        return 0
    fi

    if [[ ! -f "$SYNC_SRC" ]]; then
        log_error "Vendored gitea-github-sync.sh not found at $SYNC_SRC"
        return 1
    fi

    require_docker || return 1

    # ── Existing install? ───────────────────────────────────────────────────
    if [[ -f "$DIR/docker-compose.yml" && -f "$DIR/.env" ]]; then
        echo ""
        log_info "Existing Gitea install found at $DIR."
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                cp -f "$SYNC_SRC" "$DIR/gitea-github-sync.sh"
                chmod +x "$DIR/gitea-github-sync.sh"
                _gitea_fix_ownership "$DIR"
                (cd "$DIR" && docker compose up -d) \
                    && log_success "Gitea refreshed and restarted." \
                    || log_warning "Restart failed — check: docker compose -f $DIR/docker-compose.yml logs"
                _gitea_run_sync_direction_step "$DIR"
                log_success "Existing .env (tokens) and web/SSH ports were left untouched."
                return 0
                ;;
            cancel)
                log_info "Leaving the existing install as-is."
                return 0
                ;;
            fresh) log_info "Reconfiguring from scratch — every prompt below runs again." ;;
        esac
    fi

    mkdir -p "$DIR"
    _gitea_fix_ownership "$DIR"
    cd "$DIR" || return 1

    # ── Port scan — web (default 3001->3000) and SSH (default 2222->22) ────
    local WEB_PORT=3001 SSH_PORT=2222
    find_free_port WEB_PORT "$WEB_PORT"
    find_free_port SSH_PORT "$SSH_PORT"
    [[ "$WEB_PORT" != 3001 ]] && log_info "Port 3001 was taken — Gitea's web UI will use ${WEB_PORT}."
    [[ "$SSH_PORT" != 2222 ]] && log_info "Port 2222 was taken — Gitea's SSH clone port will use ${SSH_PORT}."

    cat > docker-compose.yml << EOF
name: gitea
services:
  gitea:
    image: gitea/gitea:latest
    container_name: gitea
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:3000"
      - "${SSH_PORT}:22"
    volumes:
      - ./data:/data
      - /etc/timezone:/etc/timezone:ro
      - /etc/localtime:/etc/localtime:ro
    environment:
      - USER_UID=1000
      - USER_GID=1000
      - GITEA__database__DB_TYPE=sqlite3
      - GITEA__database__PATH=/data/gitea/gitea.db
      - GITEA__security__INSTALL_LOCK=true
EOF

    _gitea_fix_ownership "$DIR"
    docker compose up -d \
        && log_success "Gitea container started." \
        || { log_error "docker compose up failed — check: docker compose -f $DIR/docker-compose.yml logs"; return 1; }

    # ── Admin credentials — asked up front so a slow first boot doesn't need
    # a second manual pass; these get used the moment Gitea's CLI is ready.
    echo ""
    local GITEA_ADMIN_USER=""
    prompt_text "  Gitea admin username [$ACTUAL_USER]:" "$ACTUAL_USER" GITEA_ADMIN_USER
    local _GEN_PASS GITEA_ADMIN_PASS=""
    _GEN_PASS="$(generate_password 24)"
    prompt_text "  Gitea admin password [$_GEN_PASS]:" "$_GEN_PASS" GITEA_ADMIN_PASS

    # ── Wait for Gitea to actually be ready, then create the account. One
    # retry loop instead of a separate readiness probe: first boot (SQLite
    # init) can take well over a minute on slower disks, and folding account
    # creation into the same loop means a slow-but-eventually-successful boot
    # doesn't dead-end the install the way a fixed 60s probe used to.
    log_info "Waiting for Gitea to finish starting (first boot can take a minute or two)..."
    local _tries=0 _created=false _exists=false
    while [[ $_tries -lt 60 ]]; do
        if docker exec -u git gitea gitea admin user create --admin \
            --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASS" \
            --email "${GITEA_ADMIN_USER}@localhost" --must-change-password=false \
            &>/dev/null; then
            _created=true
            break
        fi
        # Gitea is up but this username already exists (e.g. retry after an
        # earlier partial run) — treat as success and sync the password to
        # what was just entered rather than failing the whole install.
        if docker exec -u git gitea gitea admin user list 2>/dev/null | awk '{print $2}' | grep -qx "$GITEA_ADMIN_USER"; then
            _exists=true
            # --must-change-password=false matters here: change-password
            # defaults to setting that flag TRUE, which then makes Gitea
            # reject every API call (including this script's own token-based
            # calls) with 403 "You must change your password" until someone
            # logs into the web UI and clears it by hand. Confirmed live —
            # this silently broke the sync script on every retry against an
            # already-existing account.
            docker exec -u git gitea gitea admin user change-password \
                --username "$GITEA_ADMIN_USER" --password "$GITEA_ADMIN_PASS" \
                --must-change-password=false &>/dev/null
            _created=true
            break
        fi
        sleep 2
        _tries=$((_tries + 1))
    done
    if [[ "$_created" != true ]]; then
        log_error "Gitea didn't come up in time — check: docker compose -f $DIR/docker-compose.yml logs"
        log_error "Once it's healthy, just re-run 'sudo ./setup.sh gitea' to pick up from here."
        return 1
    fi
    if [[ "$_exists" == true ]]; then
        log_success "Admin account already existed: $GITEA_ADMIN_USER (password updated to what you just entered)"
    else
        log_success "Admin account created: $GITEA_ADMIN_USER"
    fi

    # Token name includes a timestamp so a retry against an account that
    # already has a "sync" token from an earlier partial run (see the
    # already-exists branch above) never collides — Gitea rejects a second
    # token with a name that's already taken for that user, which used to
    # silently fall through to the manual-paste prompt below on every retry.
    local GITEA_TOKEN=""
    GITEA_TOKEN="$(docker exec -u git gitea gitea admin user generate-access-token \
        --username "$GITEA_ADMIN_USER" --token-name "sync-$(date +%s)" \
        --scopes write:repository,write:user --raw 2>/dev/null)"
    if [[ -z "$GITEA_TOKEN" ]]; then
        log_warning "Automatic token generation didn't work (older Gitea image?) — generate one"
        log_warning "by hand: log into http://localhost:${WEB_PORT} as $GITEA_ADMIN_USER, then"
        log_warning "Settings -> Applications -> Generate New Token (repo + user write access)."
        _gitea_prompt_token "  Paste the GITEA token here (not the GitHub one — that's next):" GITEA_TOKEN
    fi

    # ── GitHub token ─────────────────────────────────────────────────────────
    echo ""
    log_info "Needs a GitHub Personal Access Token (not an SSH key — this talks to GitHub's"
    log_info "REST API too, which SSH can't do). Generate one at https://github.com/settings/tokens"
    log_info "with 'repo' scope if you don't already have one handy."
    local GITHUB_TOKEN=""
    _gitea_prompt_token "  GitHub token:" GITHUB_TOKEN
    if [[ -z "$GITHUB_TOKEN" ]]; then
        log_warning "No GitHub token entered — Gitea itself is still up, but the sync script won't"
        log_warning "work until you add one to $DIR/.env and re-run this installer (update mode)."
    fi

    cp -f "$SYNC_SRC" "$DIR/gitea-github-sync.sh"
    chmod +x "$DIR/gitea-github-sync.sh"

    cat > "$DIR/.env" << ENV
# Written by services/gitea.sh — re-run that (update mode) to change any of this.
GITEA_URL='http://localhost:${WEB_PORT}'
GITEA_TOKEN='${GITEA_TOKEN}'
GITHUB_TOKEN='${GITHUB_TOKEN}'
ENV
    chmod 600 "$DIR/.env"
    chown "$ACTUAL_USER:$ACTUAL_USER" "$DIR/.env" "$DIR/gitea-github-sync.sh"

    # ── Discover GitHub/Gitea usernames + scope prefs (the sync script's own
    # first-time setup) — runs as the real user, not root, so its config
    # lands under the real user's home, not /root.
    if [[ -n "$GITHUB_TOKEN" && -n "$GITEA_TOKEN" ]]; then
        echo ""
        if [ "$UNATTENDED" = true ]; then
            log_info "Unattended mode — skipping the interactive sync setup. Run it yourself later:"
            log_info "  cd $DIR && sudo -u $ACTUAL_USER bash gitea-github-sync.sh --init"
        else
            sudo -u "$ACTUAL_USER" env HOME="$ACTUAL_HOME" SYNC_ENV="$DIR/.env" \
                bash "$DIR/gitea-github-sync.sh" --init
        fi
    fi

    _gitea_run_sync_direction_step "$DIR"

    # ── Caddy (Gitea has its own built-in login — no Authelia needed) ──────
    configure_caddy_for_service "Gitea" "host.docker.internal:${WEB_PORT}" "git"

    write_readme "$DIR" << MD
# Gitea

Self-hosted Git server. Raw, real working-copy clones are just normal
\`git clone\` commands against it (or against GitHub directly) — Gitea's own
storage is separate from that, used for the web UI and the mirror sync
below.

- Web UI: http://localhost:${WEB_PORT}
- Admin login: \`${GITEA_ADMIN_USER}\` / see \`.env\` if you need the generated
  password again (\`docker exec -u git gitea gitea admin user change-password\`
  to rotate it)
- SSH clone port: ${SSH_PORT} (e.g. \`git clone ssh://git@localhost:${SSH_PORT}/user/repo.git\`)

## GitHub mirror sync

\`gitea-github-sync.sh\` (in this directory) mirrors repos between this Gitea
and GitHub. Tokens live in \`.env\` (chmod 600) — treat them like passwords.

\`\`\`bash
cd $DIR
bash gitea-github-sync.sh --list          # preview what would sync, no changes
bash gitea-github-sync.sh --pull-only     # GitHub -> Gitea only
bash gitea-github-sync.sh --push-only     # Gitea -> GitHub only
bash gitea-github-sync.sh                 # both directions
\`\`\`

Config (which repos, private/forks handling) lives at
\`~/.config/gitea-github-sync/config\` — edit directly, or re-run
\`bash gitea-github-sync.sh --init\` to redo it interactively.

## Manage

\`\`\`bash
docker compose up -d
docker compose down
docker compose logs -f
docker compose pull && docker compose up -d
sudo ./setup.sh gitea       # re-run to change sync direction/schedule, or refresh
\`\`\`
MD

    echo ""
    log_success "Gitea installed at $DIR"
    echo "  Web UI: http://localhost:${WEB_PORT}  (login: ${GITEA_ADMIN_USER})"
    echo "  Details, sync commands: $DIR/README.md"
    echo ""
}

# Run immediately when executed directly (deferred until after function definition)
[[ "${_RUN_STANDALONE:-0}" == 1 ]] && install_gitea
