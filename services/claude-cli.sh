#!/bin/bash
# services/claude-cli.sh — Claude Code CLI: dual-account setup, model/effort
# defaults, and a shared global CLAUDE.md.
#
# Non-Docker (see CLAUDE.md's "Non-Docker services" section). Installs the
# official Claude Code CLI if missing, then wires up:
#   - two independent account config directories (work/personal), each its
#     own CLAUDE_CONFIG_DIR behind a shell alias, so `claude-work` and
#     `claude-personal` are two fully separate logins on one machine
#   - one shared, imported global CLAUDE.md (durable personal conventions —
#     modular/reuse code, numbered CLI menus with 0=always-exit, verify web
#     UI changes with Playwright) that both accounts pull in via `@import`,
#     so there's exactly one copy to edit, not two that can drift
#   - settings.json defaults applied to both accounts: model pinned to
#     claude-sonnet-5, effort level medium, and ENABLE_PROMPT_CACHING_1H=1
#     (keeps the 1h prompt-cache lifetime even after usage credits kick in,
#     instead of dropping to 5 minutes — see services/ai-stack.md's hybrid
#     workflow section for why this pairs with a local-GPU + Claude Code split)
#
# The Anthropic login itself (browser OAuth) can't be scripted — this only
# prepares the directories/aliases/config. Run `claude-work` and
# `claude-personal` once each afterward to actually log each one in.
# Part of the modular post-install system (sourced by setup.sh).

register_service claude-cli extras "Claude Code CLI — dual-account setup (work/personal), model/effort defaults, shared global CLAUDE.md"

install_claude-cli() {
    local WORK_DIR="$ACTUAL_HOME/.claude-work"
    local PERSONAL_DIR="$ACTUAL_HOME/.claude-personal"
    local SHARED_DIR="$ACTUAL_HOME/.claude-shared"
    local SHARED_CLAUDE_MD="$SHARED_DIR/CLAUDE.md"
    local BASHRC="$ACTUAL_HOME/.bashrc"

    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would install the Claude Code CLI (official installer) if missing"
        echo "[DRY-RUN] Would create $WORK_DIR and $PERSONAL_DIR config dirs"
        echo "[DRY-RUN] Would write $SHARED_CLAUDE_MD (shared conventions) and import it from each account's CLAUDE.md"
        echo "[DRY-RUN] Would write settings.json (model=claude-sonnet-5, effortLevel=medium, ENABLE_PROMPT_CACHING_1H=1) into each account dir"
        echo "[DRY-RUN] Would add claude-work/claude-personal aliases to $BASHRC (idempotent)"
        return 0
    fi

    if [ -f "$SHARED_CLAUDE_MD" ]; then
        local MODE=""
        prompt_reinstall_mode MODE
        case "$MODE" in
            update)
                log_info "Refreshing shared CLAUDE.md and settings.json only — account dirs/credentials untouched."
                _claude_cli_write_shared_claude_md "$SHARED_CLAUDE_MD"
                _claude_cli_write_settings "$WORK_DIR/settings.json"
                _claude_cli_write_settings "$PERSONAL_DIR/settings.json"
                ensure_docker_dir_ownership "$SHARED_DIR" "$WORK_DIR" "$PERSONAL_DIR"
                log_success "claude-cli config refreshed"
                return 0
                ;;
            cancel)
                log_info "Leaving the existing claude-cli setup as-is."
                return 0
                ;;
            fresh) ;;  # fall through to the full setup below
        esac
    fi

    # ── Install the CLI itself ──────────────────────────────────────────────
    if ! command -v claude >/dev/null 2>&1; then
        log_info "Installing Claude Code CLI..."
        if curl -fsSL https://claude.ai/install.sh | bash; then
            log_success "Claude Code CLI installed"
        else
            log_error "Claude Code CLI install failed — see https://code.claude.com/docs/en/setup"
            return 1
        fi
    else
        log_info "Claude Code CLI already installed ($(command -v claude))"
    fi

    # ── Account config dirs + shared conventions ────────────────────────────
    mkdir -p "$WORK_DIR" "$PERSONAL_DIR" "$SHARED_DIR"
    _claude_cli_write_shared_claude_md "$SHARED_CLAUDE_MD"

    local _dir
    for _dir in "$WORK_DIR" "$PERSONAL_DIR"; do
        # @import pulls the shared file in at session start (see Claude
        # Code's memory docs) — one canonical copy, not two that can drift.
        [ -f "$_dir/CLAUDE.md" ] || printf '@%s\n' "$SHARED_CLAUDE_MD" > "$_dir/CLAUDE.md"
        _claude_cli_write_settings "$_dir/settings.json"
    done

    # ── Shell aliases — idempotent, same append-once pattern base.sh uses
    # for tab completion (grep-before-append, chown after) ──────────────────
    if [ -f "$BASHRC" ] && ! grep -qF "CLAUDE_CONFIG_DIR=$WORK_DIR" "$BASHRC" 2>/dev/null; then
        {
            echo ""
            echo "# ubuntu-post-install: claude-cli dual-account aliases"
            echo "alias claude-work='CLAUDE_CONFIG_DIR=$WORK_DIR claude'"
            echo "alias claude-personal='CLAUDE_CONFIG_DIR=$PERSONAL_DIR claude'"
        } >> "$BASHRC"
        chown "$ACTUAL_USER:$ACTUAL_USER" "$BASHRC" 2>/dev/null || true
        log_success "Added claude-work / claude-personal aliases to $BASHRC (new shells, or: source $BASHRC)"
    fi

    ensure_docker_dir_ownership "$SHARED_DIR" "$WORK_DIR" "$PERSONAL_DIR"

    echo ""
    log_warning "Login still needs a one-time browser step per account — this only prepared the plumbing:"
    echo "    claude-work        # first run: browser OAuth login for your work account"
    echo "    claude-personal    # first run: browser OAuth login for your personal account"
    echo ""
    echo "  Shared conventions : $SHARED_CLAUDE_MD  (edit once, both accounts see it)"
    echo "  Work config        : $WORK_DIR"
    echo "  Personal config    : $PERSONAL_DIR"
    echo ""
}

# Writes/refreshes the three keys this service owns via jq (preserves any
# other hand-added settings, e.g. permissions); falls back to a fresh file
# if jq is missing (base.sh installs it, but this service can run standalone)
# or the existing file isn't valid JSON.
_claude_cli_write_settings() {
    local dest="$1"
    local patch='{"model":"claude-sonnet-5","effortLevel":"medium","env":{"ENABLE_PROMPT_CACHING_1H":"1"}}'

    if [ -f "$dest" ] && command -v jq >/dev/null 2>&1; then
        local merged
        merged="$(jq -s '.[0] * .[1]' "$dest" <(echo "$patch") 2>/dev/null)" \
            && [ -n "$merged" ] \
            && printf '%s\n' "$merged" > "$dest" \
            && return 0
        log_warning "$dest wasn't valid JSON — leaving it untouched. Merge manually: $patch"
        return 0
    fi

    [ -f "$dest" ] && return 0
    echo "$patch" | (command -v jq >/dev/null 2>&1 && jq . || cat) > "$dest"
}

_claude_cli_write_shared_claude_md() {
    cat > "$1" << 'EOF'
# Personal conventions (all projects, both accounts)

## Code reuse
Write shared logic once, in one place. Before adding a new function, check
whether an existing one already does it — extend/parameterize rather than
duplicate.

## CLI menus
Every interactive menu is numbered. `0` is always "exit" / "back" — never
reused for another action, and always present, even on a submenu.

## Verifying web UI changes
After any frontend change, drive it with Playwright before calling it done —
navigate the real page, exercise the changed flow, screenshot if the result
is visual. Don't declare a UI task complete from reading the code alone.
EOF
}
