#!/usr/bin/env bash
# =============================================================================
# Gitea ↔ GitHub Mirror Sync
#
# Mirrors repos between your local Gitea and GitHub in both directions:
#   GitHub → Gitea:  Pulls repos you own on GitHub into Gitea (backup/offline use)
#   Gitea → GitHub:  Pushes Gitea repos to GitHub (remote backup)
#
# Usage:
#   ./gitea-github-sync.sh                     — sync all configured repos
#   ./gitea-github-sync.sh --pull-only         — GitHub → Gitea only
#   ./gitea-github-sync.sh --push-only         — Gitea → GitHub only
#   ./gitea-github-sync.sh --repo owner/name   — sync one specific repo
#   ./gitea-github-sync.sh --list              — list what would sync (dry run)
#   ./gitea-github-sync.sh --init              — interactive first-time setup
#
# Config:  ~/.config/gitea-github-sync/config
# Tokens:  reads from .env in the same directory as this script (or $SYNC_ENV)
#
# Schedule: install the systemd timer with --install-timer
#   ./gitea-github-sync.sh --install-timer     — every 6 hours (default)
#   ./gitea-github-sync.sh --install-timer 1h  — custom interval
#   ./gitea-github-sync.sh --remove-timer      — remove the timer
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[sync]${NC}  $*"; }
ok()    { echo -e "${GREEN}[ ok ]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[warn]${NC}  $*"; }
err()   { echo -e "${RED}[err ]${NC}  $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/gitea-github-sync"
CONFIG_FILE="$CONFIG_DIR/config"
WORK_DIR="$CONFIG_DIR/repos"
LOG_FILE="$CONFIG_DIR/sync.log"

# ── load tokens from .env ───────────────────────────────────────────────────
ENV_FILE="${SYNC_ENV:-$SCRIPT_DIR/.env}"
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source <(grep -E '^(GITEA_TOKEN|GITHUB_TOKEN|GITEA_URL)=' "$ENV_FILE" | sed 's/ *#.*//'); set +a
fi

GITEA_URL="${GITEA_URL:-http://localhost:3001}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# ── parse args ──────────────────────────────────────────────────────────────
MODE="all"         # all | pull | push | list | init | install-timer | remove-timer
SINGLE_REPO=""
TIMER_INTERVAL="6h"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pull-only)      MODE="pull"; shift ;;
        --push-only)      MODE="push"; shift ;;
        --list)           MODE="list"; shift ;;
        --init)           MODE="init"; shift ;;
        --install-timer)  MODE="install-timer"; shift; [[ "${1:-}" =~ ^[0-9]+[smhd]$ ]] && { TIMER_INTERVAL="$1"; shift; } ;;
        --remove-timer)   MODE="remove-timer"; shift ;;
        --repo)           shift; SINGLE_REPO="${1:-}"; shift ;;
        -h|--help)
            sed -n '2,/^# =====/{ /^# =====/d; s/^# \?//p; }' "$0"; exit 0 ;;
        *) err "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── helpers ─────────────────────────────────────────────────────────────────
_gitea_api() {
    local method="$1" path="$2"; shift 2
    curl -sfL -X "$method" \
        -H "Authorization: token $GITEA_TOKEN" \
        -H "Content-Type: application/json" \
        "$GITEA_URL/api/v1$path" "$@"
}

_github_api() {
    local method="$1" path="$2"; shift 2
    curl -sfL -X "$method" \
        -H "Authorization: Bearer $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com$path" "$@"
}

_log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# ── config management ──────────────────────────────────────────────────────
load_config() {
    mkdir -p "$CONFIG_DIR" "$WORK_DIR"
    GITHUB_USER=""
    GITEA_USER=""
    SYNC_REPOS=()           # explicit list (empty = auto-discover)
    EXCLUDE_REPOS=()        # repos to skip
    PUSH_PRIVATE=false      # push private Gitea repos to GitHub?
    PULL_PRIVATE=true       # pull private GitHub repos to Gitea?
    PULL_FORKS=false        # pull forked repos from GitHub?

    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# Gitea-GitHub Sync — configuration
# Generated $(date '+%Y-%m-%d %H:%M:%S')

# GitHub username (for discovering repos to pull)
GITHUB_USER="$GITHUB_USER"

# Gitea username (for discovering repos to push)
GITEA_USER="$GITEA_USER"

# Explicit repo list — if set, only these sync. Format: owner/repo
# Leave empty () to auto-discover from both platforms.
SYNC_REPOS=($(printf '"%s" ' "${SYNC_REPOS[@]}"))

# Repos to skip (pattern matched against owner/repo)
EXCLUDE_REPOS=($(printf '"%s" ' "${EXCLUDE_REPOS[@]}"))

# Push private Gitea repos to GitHub as private repos?
PUSH_PRIVATE=$PUSH_PRIVATE

# Pull private GitHub repos to Gitea?
PULL_PRIVATE=$PULL_PRIVATE

# Pull forked repos from GitHub?
PULL_FORKS=$PULL_FORKS
EOF
    ok "Config saved: $CONFIG_FILE"
}

# ── init (first-time setup) ────────────────────────────────────────────────
do_init() {
    echo -e "\n${BOLD}Gitea ↔ GitHub Sync — First-Time Setup${NC}\n"

    # Check tokens
    if [[ -z "$GITEA_TOKEN" || "$GITEA_TOKEN" == "your-gitea-token-here" ]]; then
        err "GITEA_TOKEN not set. Add it to $ENV_FILE first."
        echo "  Generate at: $GITEA_URL/user/settings/applications"
        exit 1
    fi
    if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "your-github-token-here" ]]; then
        err "GITHUB_TOKEN not set. Add it to $ENV_FILE first."
        echo "  Generate at: https://github.com/settings/tokens"
        echo "  Scopes needed: repo (full control)"
        exit 1
    fi

    # Discover usernames
    info "Detecting GitHub user..."
    GITHUB_USER=$(_github_api GET /user | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])" 2>/dev/null) \
        || { err "Failed to reach GitHub API. Check GITHUB_TOKEN."; exit 1; }
    ok "GitHub user: $GITHUB_USER"

    info "Detecting Gitea user..."
    GITEA_USER=$(_gitea_api GET /user | python3 -c "import sys,json; print(json.load(sys.stdin)['login'])" 2>/dev/null) \
        || { err "Failed to reach Gitea API. Check GITEA_TOKEN and GITEA_URL ($GITEA_URL)."; exit 1; }
    ok "Gitea user: $GITEA_USER"

    # Ask about sync scope
    echo ""
    read -rp "Pull private GitHub repos to Gitea? [Y/n] " ans
    PULL_PRIVATE=true; [[ "${ans,,}" == "n" ]] && PULL_PRIVATE=false

    read -rp "Pull forked repos from GitHub? [y/N] " ans
    PULL_FORKS=false; [[ "${ans,,}" == "y" ]] && PULL_FORKS=true

    read -rp "Push private Gitea repos to GitHub? [y/N] " ans
    PUSH_PRIVATE=false; [[ "${ans,,}" == "y" ]] && PUSH_PRIVATE=true

    save_config

    echo ""
    info "Run '$(basename "$0") --list' to preview what would sync."
    info "Run '$(basename "$0")' to sync now."
    info "Run '$(basename "$0") --install-timer' to sync automatically."
}

# ── discover repos ─────────────────────────────────────────────────────────
get_github_repos() {
    local page=1 repos=()
    while true; do
        local batch
        batch=$(_github_api GET "/user/repos?per_page=100&page=$page&affiliation=owner" \
            | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r.get('fork') and not $($PULL_FORKS && echo True || echo False):
        continue
    if r.get('private') and not $($PULL_PRIVATE && echo True || echo False):
        continue
    print(r['full_name'] + '|' + r['clone_url'] + '|' + str(r.get('private',False)).lower())
" 2>/dev/null) || break
        [[ -z "$batch" ]] && break
        while IFS= read -r line; do repos+=("$line"); done <<< "$batch"
        ((page++))
    done
    printf '%s\n' "${repos[@]}"
}

get_gitea_repos() {
    local page=1 repos=()
    while true; do
        local batch
        batch=$(_gitea_api GET "/repos/search?limit=50&page=$page" \
            | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('data', []):
    if r.get('private') and not $($PUSH_PRIVATE && echo True || echo False):
        continue
    print(r['full_name'] + '|' + r['clone_url'] + '|' + str(r.get('private',False)).lower())
" 2>/dev/null) || break
        [[ -z "$batch" ]] && break
        while IFS= read -r line; do repos+=("$line"); done <<< "$batch"
        ((page++))
    done
    printf '%s\n' "${repos[@]}"
}

is_excluded() {
    local repo="$1"
    for pat in "${EXCLUDE_REPOS[@]}"; do
        [[ "$repo" == $pat ]] && return 0
    done
    return 1
}

# ── sync: GitHub → Gitea (pull) ───────────────────────────────────────────
sync_github_to_gitea() {
    local full_name="$1" clone_url="$2" is_private="$3"
    local repo_name="${full_name#*/}"
    local local_path="$WORK_DIR/$full_name"

    # Clone or fetch from GitHub
    if [[ -d "$local_path" ]]; then
        info "Fetching $full_name from GitHub..."
        git -C "$local_path" fetch --all --prune --quiet 2>/dev/null || {
            err "Failed to fetch $full_name"; return 1; }
    else
        info "Cloning $full_name from GitHub..."
        mkdir -p "$(dirname "$local_path")"
        local auth_url="${clone_url/https:\/\//https:\/\/$GITHUB_TOKEN@}"
        git clone --bare --quiet "$auth_url" "$local_path" 2>/dev/null || {
            err "Failed to clone $full_name"; return 1; }
    fi

    # Ensure repo exists on Gitea
    local gitea_check
    gitea_check=$(_gitea_api GET "/repos/$GITEA_USER/$repo_name" 2>/dev/null) || true
    if ! echo "$gitea_check" | python3 -c "import sys,json; json.load(sys.stdin)['id']" &>/dev/null; then
        info "Creating $repo_name on Gitea..."
        _gitea_api POST "/user/repos" \
            -d "{\"name\":\"$repo_name\",\"private\":$is_private,\"description\":\"Mirror of $full_name from GitHub\"}" \
            >/dev/null || { err "Failed to create $repo_name on Gitea"; return 1; }
    fi

    # Push to Gitea
    local gitea_push_url="${GITEA_URL/https:\/\//https:\/\/$GITEA_USER:$GITEA_TOKEN@}"
    gitea_push_url="${gitea_push_url/http:\/\//http:\/\/$GITEA_USER:$GITEA_TOKEN@}"
    gitea_push_url="$gitea_push_url/$GITEA_USER/$repo_name.git"

    git -C "$local_path" push --mirror "$gitea_push_url" --quiet 2>/dev/null || {
        err "Failed to push $full_name to Gitea"; return 1; }
    ok "GitHub → Gitea: $full_name"
    _log "PULL $full_name OK"
}

# ── sync: Gitea → GitHub (push) ───────────────────────────────────────────
sync_gitea_to_github() {
    local full_name="$1" clone_url="$2" is_private="$3"
    local repo_name="${full_name#*/}"
    local local_path="$WORK_DIR/gitea/$full_name"

    # Clone or fetch from Gitea
    local gitea_auth_url="${clone_url/https:\/\//https:\/\/$GITEA_USER:$GITEA_TOKEN@}"
    gitea_auth_url="${gitea_auth_url/http:\/\//http:\/\/$GITEA_USER:$GITEA_TOKEN@}"

    if [[ -d "$local_path" ]]; then
        info "Fetching $full_name from Gitea..."
        git -C "$local_path" fetch --all --prune --quiet 2>/dev/null || {
            err "Failed to fetch $full_name from Gitea"; return 1; }
    else
        info "Cloning $full_name from Gitea..."
        mkdir -p "$(dirname "$local_path")"
        git clone --bare --quiet "$gitea_auth_url" "$local_path" 2>/dev/null || {
            err "Failed to clone $full_name from Gitea"; return 1; }
    fi

    # Ensure repo exists on GitHub
    local gh_check
    gh_check=$(_github_api GET "/repos/$GITHUB_USER/$repo_name" 2>/dev/null) || true
    if ! echo "$gh_check" | python3 -c "import sys,json; json.load(sys.stdin)['id']" &>/dev/null; then
        info "Creating $repo_name on GitHub..."
        _github_api POST "/user/repos" \
            -d "{\"name\":\"$repo_name\",\"private\":$is_private,\"description\":\"Mirror from Gitea\"}" \
            >/dev/null || { err "Failed to create $repo_name on GitHub"; return 1; }
    fi

    # Push to GitHub
    local github_push_url="https://$GITHUB_TOKEN@github.com/$GITHUB_USER/$repo_name.git"
    git -C "$local_path" push --mirror "$github_push_url" --quiet 2>/dev/null || {
        err "Failed to push $full_name to GitHub"; return 1; }
    ok "Gitea → GitHub: $full_name"
    _log "PUSH $full_name OK"
}

# ── list (dry run) ─────────────────────────────────────────────────────────
do_list() {
    echo -e "\n${BOLD}Repos that would sync:${NC}\n"

    if [[ ${#SYNC_REPOS[@]} -gt 0 ]]; then
        echo -e "${CYAN}Explicit list:${NC}"
        printf '  %s\n' "${SYNC_REPOS[@]}"
    else
        if [[ "$MODE" != "push" ]]; then
            echo -e "${CYAN}GitHub → Gitea (pull):${NC}"
            get_github_repos | while IFS='|' read -r name url priv; do
                is_excluded "$name" && echo "  $name (excluded)" && continue
                echo "  $name $([ "$priv" = "true" ] && echo "[private]")"
            done
        fi
        echo ""
        if [[ "$MODE" != "pull" ]]; then
            echo -e "${CYAN}Gitea → GitHub (push):${NC}"
            get_gitea_repos | while IFS='|' read -r name url priv; do
                is_excluded "$name" && echo "  $name (excluded)" && continue
                echo "  $name $([ "$priv" = "true" ] && echo "[private]")"
            done
        fi
    fi
    echo ""
}

# ── main sync ──────────────────────────────────────────────────────────────
do_sync() {
    local pull_count=0 push_count=0 fail_count=0

    _log "=== Sync started (mode=$MODE) ==="

    # GitHub → Gitea
    if [[ "$MODE" == "all" || "$MODE" == "pull" ]]; then
        info "Discovering GitHub repos..."
        while IFS='|' read -r name url priv; do
            [[ -z "$name" ]] && continue
            [[ -n "$SINGLE_REPO" && "$name" != "$SINGLE_REPO" ]] && continue
            is_excluded "$name" && continue
            if sync_github_to_gitea "$name" "$url" "$priv"; then
                ((pull_count++))
            else
                ((fail_count++))
            fi
        done < <(get_github_repos)
    fi

    # Gitea → GitHub
    if [[ "$MODE" == "all" || "$MODE" == "push" ]]; then
        info "Discovering Gitea repos..."
        while IFS='|' read -r name url priv; do
            [[ -z "$name" ]] && continue
            [[ -n "$SINGLE_REPO" && "${name#*/}" != "${SINGLE_REPO#*/}" ]] && continue
            is_excluded "$name" && continue
            # Skip repos that came from GitHub (already mirrored)
            local repo_name="${name#*/}"
            if [[ -d "$WORK_DIR/$GITHUB_USER/$repo_name" ]]; then
                info "Skipping $name (already a GitHub mirror)"
                continue
            fi
            if sync_gitea_to_github "$name" "$url" "$priv"; then
                ((push_count++))
            else
                ((fail_count++))
            fi
        done < <(get_gitea_repos)
    fi

    echo ""
    ok "Sync complete: ${pull_count} pulled, ${push_count} pushed, ${fail_count} failed"
    _log "=== Sync complete: pull=$pull_count push=$push_count fail=$fail_count ==="
}

# ── systemd timer ──────────────────────────────────────────────────────────
install_timer() {
    local service_file="/etc/systemd/system/gitea-github-sync.service"
    local timer_file="/etc/systemd/system/gitea-github-sync.timer"
    local script_path
    script_path="$(readlink -f "$0")"

    info "Installing systemd timer (interval: $TIMER_INTERVAL)..."

    sudo tee "$service_file" > /dev/null << EOF
[Unit]
Description=Gitea-GitHub Mirror Sync
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
User=$USER
ExecStart=$script_path
Environment=HOME=$HOME
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
EOF

    sudo tee "$timer_file" > /dev/null << EOF
[Unit]
Description=Gitea-GitHub Sync Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=$TIMER_INTERVAL
Persistent=true

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now gitea-github-sync.timer
    ok "Timer installed: every $TIMER_INTERVAL"
    ok "Check status: systemctl status gitea-github-sync.timer"
    ok "Run now: sudo systemctl start gitea-github-sync.service"
    ok "Logs: $LOG_FILE"
}

remove_timer() {
    info "Removing systemd timer..."
    sudo systemctl disable --now gitea-github-sync.timer 2>/dev/null || true
    sudo rm -f /etc/systemd/system/gitea-github-sync.{service,timer}
    sudo systemctl daemon-reload
    ok "Timer removed"
}

# ── preflight checks ──────────────────────────────────────────────────────
preflight() {
    local ok=true
    if [[ -z "$GITEA_TOKEN" || "$GITEA_TOKEN" == "your-gitea-token-here" ]]; then
        err "GITEA_TOKEN not set. Edit $ENV_FILE"; ok=false
    fi
    if [[ -z "$GITHUB_TOKEN" || "$GITHUB_TOKEN" == "your-github-token-here" ]]; then
        err "GITHUB_TOKEN not set. Edit $ENV_FILE"; ok=false
    fi
    if [[ -z "$GITEA_USER" || -z "$GITHUB_USER" ]]; then
        err "Run --init first to configure usernames"; ok=false
    fi
    $ok || exit 1
}

# ── main ───────────────────────────────────────────────────────────────────
load_config

case "$MODE" in
    init)           do_init ;;
    install-timer)  install_timer ;;
    remove-timer)   remove_timer ;;
    list)           preflight; do_list ;;
    *)              preflight; do_sync ;;
esac
