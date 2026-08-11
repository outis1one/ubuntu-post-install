# tools/setup-completion.bash — bash tab-completion for setup.sh.
#
# Enable it:
#   echo "source $(pwd)/tools/setup-completion.bash" >> ~/.bashrc
#   source ~/.bashrc
# (run that echo from the repo root, or swap $(pwd) for the actual path)
#
# Then: ./setup.sh mat<TAB>  ->  ./setup.sh mattermost
# Works with a leading `sudo` too (sudo ./setup.sh mat<TAB>) via the
# bash-completion package's standard sudo pass-through, already enabled by
# default on Ubuntu — nothing extra needed for that part.
#
# Service names are read fresh from services/*.sh every time you press
# <TAB> — never a hardcoded list baked in here. This repo's own rule is
# "adding a service = adding one file, nothing generated" (see CLAUDE.md);
# a completion script that needed regenerating every time a service got
# added would quietly break that promise the first time someone forgot.

_setup_sh_completions() {
    local cur repo_dir services flags
    cur="${COMP_WORDS[COMP_CWORD]}"

    # Self-locating from this file's own path, not a hardcoded install
    # location — survives the repo being cloned anywhere, or moved later.
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
    [ -d "$repo_dir/services" ] || return 0

    services="$(cd "$repo_dir/services" && for f in *.sh; do [ -f "$f" ] && printf '%s ' "${f%.sh}"; done)"
    flags="--list --status --dry-run --unattended --remove remove uninstall --version --help configure"

    COMPREPLY=( $(compgen -W "${services}${flags}" -- "$cur") )
}

complete -F _setup_sh_completions setup.sh ./setup.sh
