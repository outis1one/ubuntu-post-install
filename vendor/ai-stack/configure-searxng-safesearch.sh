#!/usr/bin/env bash
# configure-searxng-safesearch.sh
# Set SearXNG safe-search level; optionally disable categories or engines.
#
# Usage:
#   ./configure-searxng-safesearch.sh [strict|moderate|none] [OPTIONS]
#
# Options:
#   --disable-categories  cat1,cat2   videos  images  news  science  social
#   --disable-engines     eng1,eng2   e.g. duckduckgo,bing,yandex
#   --enable-engines      eng1,eng2   re-enable engines auto-disabled by level
#
# Examples:
#   ./configure-searxng-safesearch.sh strict
#   ./configure-searxng-safesearch.sh moderate --disable-categories videos,images
#   ./configure-searxng-safesearch.sh none --disable-engines bing,duckduckgo
#   ./configure-searxng-safesearch.sh strict --disable-categories videos \
#       --disable-engines bing --enable-engines yandex

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────
red()  { printf '\e[31m%s\e[0m\n' "$*"; }
grn()  { printf '\e[32m%s\e[0m\n' "$*"; }
blu()  { printf '\e[34m%s\e[0m\n' "$*"; }
yel()  { printf '\e[33m%s\e[0m\n' "$*"; }
die()  { red "ERROR: $*"; exit 1; }
ok()   { grn "  ✓  $*"; }
info() { blu "  →  $*"; }
warn() { yel "  !  $*"; }

# ── Defaults ──────────────────────────────────────────────────────────────────
LEVEL="moderate"
DISABLE_CATS=""
DISABLE_ENGINES_EXTRA=""
ENABLE_ENGINES_EXTRA=""
BASE="${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# ── Parse arguments ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    strict|moderate|none)   LEVEL="$1";                         shift ;;
    --disable-categories)   DISABLE_CATS="$2";                  shift 2 ;;
    --disable-engines)      DISABLE_ENGINES_EXTRA="$2";         shift 2 ;;
    --enable-engines)       ENABLE_ENGINES_EXTRA="$2";          shift 2 ;;
    --base)                 BASE="$2";                          shift 2 ;;
    -h|--help)
      sed -n '2,20p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) die "Unknown argument: $1  (run with --help)" ;;
  esac
done

SETTINGS="$BASE/searxng/settings.yml"
COMPOSE="$BASE/docker-compose.yml"

# Ensure settings directory exists (fix ownership if Docker created it as root)
mkdir -p "$(dirname "$SETTINGS")" 2>/dev/null || \
  sudo mkdir -p "$(dirname "$SETTINGS")"
if [[ -e "$SETTINGS" ]] && [[ ! -w "$SETTINGS" ]]; then
  warn "settings.yml not writable — fixing ownership"
  sudo chown "$(id -u):$(id -g)" "$SETTINGS" || \
    die "Cannot write to $SETTINGS — run: sudo chown $USER $SETTINGS"
fi

# ── Level → integer ───────────────────────────────────────────────────────────
case "$LEVEL" in
  none)     SAFE_INT=0 ;;
  moderate) SAFE_INT=1 ;;
  strict)   SAFE_INT=2 ;;
esac

info "Safe search: $LEVEL (${SAFE_INT})"

# ── Engines with no safe-search support ───────────────────────────────────────
# Auto-disabled when level is moderate or strict.
NO_SAFESEARCH_ENGINES=(
  # Torrent / P2P — no filtering possible
  "1337x" "piratebay" "nyaa" "torrentz" "kickass torrents"
  # Web engines without safe-search API
  "mojeek" "naver" "baidu"
  # Yandex: parameter exists but not reliably enforced for non-Russian queries
  "yandex" "yandex images"
  # Video frontends — no safe-search passthrough
  "invidious" "piped" "peertube" "sepiasearch"
)

# ── Category → engine lists ───────────────────────────────────────────────────
VIDEOS_ENGINES=(
  "youtube" "bing videos" "brave videos" "duckduckgo videos" "google videos" "qwant videos"
  "dailymotion" "media.ccc.de" "wikcommons.videos"
  "vimeo" "odysee" "rumble" "bitchute"
  "invidious" "piped" "peertube" "sepiasearch"
)
IMAGES_ENGINES=(
  "google images" "bing images" "duckduckgo images" "brave images" "qwant images"
  "startpage images" "mojeek images" "presearch images"
  "openverse" "unsplash" "pexels" "pixabay images" "pinterest" "flickr"
  "wikcommons.images" "artic" "yandex images"
  "imgur" "deviantart" "artstation" "adobe stock"
)
NEWS_ENGINES=(
  "google news" "bing news" "duckduckgo news" "brave news" "qwant news"
  "startpage news" "presearch news" "mojeek news"
  "reuters" "yahoo news" "wikinews" "yep news"
)
SCIENCE_ENGINES=(
  "arxiv" "semantic scholar" "pubmed" "crossref" "base"
)
SOCIAL_ENGINES=(
  "reddit" "lemmy" "mastodon"
)

# ── Build disable/enable maps ─────────────────────────────────────────────────
declare -A DISABLE_MAP   # engine → 1
declare -A ENABLE_MAP    # engine → 1  (overrides everything)

# Parse --enable-engines
if [[ -n "$ENABLE_ENGINES_EXTRA" ]]; then
  IFS=',' read -ra _engs <<< "$ENABLE_ENGINES_EXTRA"
  for e in "${_engs[@]}"; do
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"   # trim
    [[ -n "$e" ]] && ENABLE_MAP["$e"]=1
  done
fi

# Helper: add to DISABLE_MAP unless explicitly re-enabled
mark_disabled() {
  local eng="$1"
  # Use set +u to safely check array key existence on bash < 4.4 (set -u quirk)
  set +u; local _chk="${ENABLE_MAP[$eng]+x}"; set -u
  [[ -n "$_chk" ]] && return   # user said keep it
  DISABLE_MAP["$eng"]=1
}

# Auto-disable no-safesearch engines for moderate/strict
if [[ "$LEVEL" != "none" ]]; then
  for eng in "${NO_SAFESEARCH_ENGINES[@]}"; do
    mark_disabled "$eng"
  done
fi

# Category disables
if [[ -n "$DISABLE_CATS" ]]; then
  IFS=',' read -ra _cats <<< "$DISABLE_CATS"
  for cat in "${_cats[@]}"; do
    cat="${cat#"${cat%%[![:space:]]*}"}"; cat="${cat%"${cat##*[![:space:]]}"}"
    cat="${cat,,}"
    case "$cat" in
      videos)  for e in "${VIDEOS_ENGINES[@]}";  do mark_disabled "$e"; done ;;
      images)  for e in "${IMAGES_ENGINES[@]}";  do mark_disabled "$e"; done ;;
      news)    for e in "${NEWS_ENGINES[@]}";     do mark_disabled "$e"; done ;;
      science) for e in "${SCIENCE_ENGINES[@]}";  do mark_disabled "$e"; done ;;
      social)  for e in "${SOCIAL_ENGINES[@]}";   do mark_disabled "$e"; done ;;
      "")      ;;
      *)       warn "Unknown category '$cat' — valid: videos images news science social" ;;
    esac
  done
fi

# Extra engine disables
if [[ -n "$DISABLE_ENGINES_EXTRA" ]]; then
  IFS=',' read -ra _engs <<< "$DISABLE_ENGINES_EXTRA"
  for e in "${_engs[@]}"; do
    e="${e#"${e%%[![:space:]]*}"}"; e="${e%"${e##*[![:space:]]}"}"
    [[ -n "$e" ]] && mark_disabled "$e"
  done
fi

# ── Preserve existing secret key ─────────────────────────────────────────────
SECRET_KEY=$(grep -oP '(?<=secret_key: ")[^"]+' "$SETTINGS" 2>/dev/null || true)
[[ -z "$SECRET_KEY" ]] && SECRET_KEY=$(openssl rand -hex 32)

# ── Build engine override block ───────────────────────────────────────────────
ENGINE_BLOCK=""
# set +u: iterating empty associative arrays throws "unbound variable" on bash <4.4
set +u
for eng in "${!DISABLE_MAP[@]}"; do
  ENGINE_BLOCK+="  - name: ${eng}\n    disabled: true\n"
done
for eng in "${!ENABLE_MAP[@]}"; do
  ENGINE_BLOCK+="  - name: ${eng}\n    disabled: false\n"
done
set -u

# ── Write settings.yml ────────────────────────────────────────────────────────
{
  printf 'use_default_settings: true\n'
  printf 'general:\n  instance_name: "Local Search"\n'
  printf 'server:\n  secret_key: "%s"\n  limiter: false\n' "$SECRET_KEY"
  printf 'search:\n  safe_search: %d\n  default_lang: "en"\n  formats: [html, json]\n' "$SAFE_INT"
  # Lock the safe-search preference so users cannot override it via the UI
  if [[ "$LEVEL" != "none" ]]; then
    printf 'preferences:\n  lock:\n    - safesearch\n'
  fi
  if [[ -n "$ENGINE_BLOCK" ]]; then
    printf 'engines:\n'
    printf '%b' "$ENGINE_BLOCK"
  fi
} > "$SETTINGS"

ok "Updated settings.yml  (safe_search: $SAFE_INT)"
# bash < 4.4: ${#assoc[@]} on an empty declared array throws "unbound variable"
# under set -u — disable nounset for the rest of the reporting section
set +u
if [[ ${#DISABLE_MAP[@]} -gt 0 ]]; then
  info "Disabled (${#DISABLE_MAP[@]}): $(printf '%s, ' "${!DISABLE_MAP[@]}" | sed 's/, $//')"
fi
if [[ ${#ENABLE_MAP[@]} -gt 0 ]]; then
  info "Re-enabled: $(printf '%s, ' "${!ENABLE_MAP[@]}" | sed 's/, $//')"
fi

# ── Update &safesearch= in SEARXNG_QUERY_URL inside docker-compose.yml ────────
if [[ -f "$COMPOSE" ]]; then
  sed -i -E \
    "s|(SEARXNG_QUERY_URL=http://searxng:[0-9]+/search\?[^&[:space:]]*)(&safesearch=[0-9])?|\1\&safesearch=${SAFE_INT}|g" \
    "$COMPOSE"
  ok "Updated SEARXNG_QUERY_URL  (&safesearch=${SAFE_INT})"
fi

# ── Restart SearXNG ───────────────────────────────────────────────────────────
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^searxng$'; then
  info "Restarting SearXNG..."
  docker restart searxng
  ok "SearXNG restarted"
else
  info "SearXNG not running — changes take effect on next start"
fi

echo
grn "Done — safe search: $LEVEL"
[[ "$LEVEL" != "none" ]] && \
  info "Engines skipped (can't enforce '$LEVEL'): ${#DISABLE_MAP[@]} total"
