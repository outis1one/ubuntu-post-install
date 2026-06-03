#!/bin/bash
# services/minecraft.sh — Minecraft server (Fabric/Quilt/Paper/Vanilla/Forge),
# multi-instance, mod & datapack pickers, playit.gg tunnel, client-mods page.
# Part of the modular post-install system (sourced by setup.sh).
#
# Ported from the standalone setupminecraft.sh. Converted to the per-service
# folder model: each instance lives in its OWN folder under $DOCKER_DIR with its
# OWN standalone docker-compose.yml (no shared compose, no python insert logic).
#
#   default / first instance id "minecraft" -> $DOCKER_DIR/minecraft/
#   any other instance id "<slug>"          -> $DOCKER_DIR/<slug>/
#
# Helpers (log_*, prompt_yn, prompt_text, ensure_docker_dir_ownership, …) and
# globals (DOCKER_DIR, ACTUAL_USER, ACTUAL_HOME, DRY_RUN, UNATTENDED) come from
# lib/common.sh — do NOT redefine them here. No `set -e`: this file is sourced
# into a long-running dispatcher, so we use explicit checks + `|| return 1`.

register_service minecraft gaming "Minecraft server (Fabric/Quilt/Paper, multi-instance)" 25565

install_minecraft() {
    require_docker || return 1

    # ── DRY-RUN: summarise and bail BEFORE any prompting / curl / docker ───────
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] Would set up a Minecraft server instance:"
        echo "  • Create an instance folder under $DOCKER_DIR (default: $DOCKER_DIR/minecraft)"
        echo "  • Write a standalone docker-compose.yml building the itzg/minecraft-server image"
        echo "  • Optionally download selected mods (Modrinth) and a client-mods web page"
        echo "  • Optionally add a playit.gg tunnel service to the instance compose"
        echo "  • Generate MINECRAFT_NETWORKING.md and CLIENT_MODS.md in the instance folder"
        return 0
    fi

    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║   Minecraft Server Setup                              ║"
    echo "║   Fabric · Mods · Vanilla Tweaks · Networking         ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo ""

    # ── Minecraft version ──────────────────────────────────────────────────────
    log_info "Fetching recent Minecraft versions..."
    local _MC_JSON
    _MC_JSON=$(curl -sf --max-time 10 "https://launchermeta.mojang.com/mc/game/version_manifest.json" 2>/dev/null)
    local RECENT_VERSIONS=()
    mapfile -t RECENT_VERSIONS < <(echo "$_MC_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
releases = [v['id'] for v in d['versions'] if v['type'] == 'release']
for v in releases[:3]:
    print(v)
" 2>/dev/null)
    local LATEST_SNAPSHOT
    LATEST_SNAPSHOT=$(echo "$_MC_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
snaps = [v['id'] for v in d['versions'] if v['type'] == 'snapshot']
print(snaps[0] if snaps else '')
" 2>/dev/null)

    if [ ${#RECENT_VERSIONS[@]} -eq 0 ]; then
        RECENT_VERSIONS=("1.21.4" "1.21.3" "1.21.1")
        log_warning "Could not fetch version list — using defaults"
    fi

    # ── Server flavour ─────────────────────────────────────────────────────────
    echo ""
    log_info "Server Flavour"
    echo ""
    echo "  1) Fabric (default) — Lightweight, best mod ecosystem, required for"
    echo "                        all mods in this setup. Recommended."
    echo ""
    echo "  2) Quilt            — Fabric fork, compatible with most Fabric mods."
    echo "                        More experimental; use if you need Quilt-only mods."
    echo ""
    echo "  3) Paper            — High-performance Spigot fork. Best for plugin-based"
    echo "                        servers. Does NOT support Fabric mods."
    echo ""
    echo "  4) Vanilla          — Pure Mojang server. No mods or plugins. Simplest"
    echo "                        setup but no mod support — mods below won't apply."
    echo ""
    echo "  5) Forge            — Heavy modpack loader (FTB, Technic etc). Needs a"
    echo "                        matching Forge client. Not compatible with Fabric mods."
    echo ""
    local FLAVOUR_CHOICE=""
    prompt_text "Flavour [1]:" "1" FLAVOUR_CHOICE

    local FLAVOUR FLAVOUR_NAME
    case $FLAVOUR_CHOICE in
        1) FLAVOUR="FABRIC";  FLAVOUR_NAME="Fabric"  ;;
        2) FLAVOUR="QUILT";   FLAVOUR_NAME="Quilt"   ;;
        3) FLAVOUR="PAPER";   FLAVOUR_NAME="Paper"   ;;
        4) FLAVOUR="VANILLA"; FLAVOUR_NAME="Vanilla" ;;
        5) FLAVOUR="FORGE";   FLAVOUR_NAME="Forge"   ;;
        *) FLAVOUR="FABRIC";  FLAVOUR_NAME="Fabric"  ;;
    esac
    log_success "$FLAVOUR_NAME selected"

    local SUPPORTS_FABRIC_MODS=false
    [[ "$FLAVOUR" == "FABRIC" || "$FLAVOUR" == "QUILT" ]] && SUPPORTS_FABRIC_MODS=true

    if [ "$SUPPORTS_FABRIC_MODS" = false ]; then
        log_warning "$FLAVOUR_NAME does not support Fabric mods — mod and datapack selection will be skipped."
    fi

    # ── Basic server config ────────────────────────────────────────────────────
    echo ""
    log_info "Server Configuration"
    local SERVER_NAME=""
    prompt_text "Server name [My Minecraft Server]:" "My Minecraft Server" SERVER_NAME

    # ── Instance id ────────────────────────────────────────────────────────────
    # Each instance gets its own folder, container name, compose service and port,
    # so you can run several servers side by side. The first server defaults to
    # 'minecraft'; pick a unique id for more.
    slugify() { echo "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-' | sed 's/--*/-/g; s/^-//; s/-$//'; }
    local _def_slug
    _def_slug="$(slugify "$SERVER_NAME")"; [ -z "$_def_slug" ] && _def_slug="minecraft"
    # If no minecraft instance folder exists yet, default to 'minecraft'.
    if [ ! -d "$DOCKER_DIR/minecraft" ]; then
        _def_slug="minecraft"
    fi
    local MC_NAME=""
    prompt_text "Instance id (folder + container name) [${_def_slug}]:" "$_def_slug" MC_NAME
    MC_NAME="$(slugify "${MC_NAME:-$_def_slug}")"; [ -z "$MC_NAME" ] && MC_NAME="minecraft"
    local MC_DIR="$DOCKER_DIR/$MC_NAME"
    if [ -d "$MC_DIR" ]; then
        log_warning "An instance folder '${MC_NAME}' already exists at ${MC_DIR}."
        log_warning "Re-running will update its files; the existing world data is left as-is."
    fi
    log_info "Instance: ${MC_NAME}  →  ${MC_DIR}"

    local MAX_PLAYERS=""
    prompt_text "Max players [20]:" "20" MAX_PLAYERS

    local DIFFICULTY=""
    prompt_text "Difficulty (peaceful/easy/normal/hard) [normal]:" "normal" DIFFICULTY

    local GAMEMODE=""
    prompt_text "Game mode (survival/creative/adventure) [survival]:" "survival" GAMEMODE

    local WHITELIST=""
    prompt_yn "Enable whitelist? (y/n) [n]:" "n" WHITELIST
    local WHITELIST_ENABLED=false
    [[ $WHITELIST =~ ^[Yy]$ ]] && WHITELIST_ENABLED=true || WHITELIST_ENABLED=false

    local WHITELIST_PLAYERS=()
    declare -A WHITELIST_PRELOADED   # name → uuid, already resolved from existing file
    if [ "$WHITELIST_ENABLED" = true ] && [ "$UNATTENDED" != true ]; then
        echo ""
        log_info "Whitelist Players"

        # Import from existing whitelist.json when re-running against an existing instance
        local _EXISTING_WL="$MC_DIR/data/whitelist.json"
        if [ -f "$_EXISTING_WL" ]; then
            local -a _EX_NAMES _EX_UUIDS
            mapfile -t _EX_NAMES < <(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for p in data:
        if p.get('name'): print(p['name'])
except: pass
" "$_EXISTING_WL" 2>/dev/null)
            mapfile -t _EX_UUIDS < <(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    for p in data:
        if p.get('uuid'): print(p['uuid'])
except: pass
" "$_EXISTING_WL" 2>/dev/null)
            if [ ${#_EX_NAMES[@]} -gt 0 ]; then
                echo ""
                echo "  Existing whitelist found (${#_EX_NAMES[@]} player(s)):"
                local _i
                for _i in "${!_EX_NAMES[@]}"; do
                    printf "    %d) %s\n" "$((_i+1))" "${_EX_NAMES[$_i]}"
                done
                echo ""
                echo "  Import from existing? Enter numbers (e.g. 1,3,4), 0=all, Enter=skip:"
                local _WL_IMPORT=""
                read -p "  Selection: " _WL_IMPORT
                if [ -n "$_WL_IMPORT" ]; then
                    if [ "$_WL_IMPORT" = "0" ]; then
                        for _i in "${!_EX_NAMES[@]}"; do
                            WHITELIST_PRELOADED["${_EX_NAMES[$_i]}"]="${_EX_UUIDS[$_i]}"
                        done
                        log_success "  Imported all ${#_EX_NAMES[@]} existing player(s)"
                    else
                        local -a _SEL_NUMS
                        IFS=',' read -ra _SEL_NUMS <<< "$_WL_IMPORT"
                        local _n
                        for _n in "${_SEL_NUMS[@]}"; do
                            _n="${_n// /}"
                            if [[ "$_n" =~ ^[0-9]+$ ]] && [ "$_n" -ge 1 ] && \
                               [ "$_n" -le "${#_EX_NAMES[@]}" ]; then
                                WHITELIST_PRELOADED["${_EX_NAMES[$((_n-1))]}"]="${_EX_UUIDS[$((_n-1))]}"
                                log_info "    Imported: ${_EX_NAMES[$((_n-1))]}"
                            fi
                        done
                    fi
                fi
            fi
        fi

        echo ""
        echo "  Enter additional gamertags to add. UUIDs looked up automatically."
        echo "  Press Enter alone when done."
        echo ""
        while true; do
            local _GT=""
            read -p "  Gamertag (Enter to finish): " _GT
            [ -z "$_GT" ] && break
            WHITELIST_PLAYERS+=("$_GT")
            log_info "    Added: $_GT"
        done
        local _WL_TOTAL=$(( ${#WHITELIST_PLAYERS[@]} + ${#WHITELIST_PRELOADED[@]} ))
        if [ "$_WL_TOTAL" -gt 0 ]; then
            log_success "  $_WL_TOTAL player(s) queued for whitelist"
        else
            log_info "  No players entered — whitelist will be empty until you add players manually"
        fi
    fi

    # Port auto-bump: default 25565; if an existing instance compose already
    # maps :25565 and this is not the default instance, default to 25566.
    local _def_port=25565
    if [ "$MC_NAME" != "minecraft" ] \
       && grep -qs ':25565"' "$DOCKER_DIR"/*/docker-compose.yml 2>/dev/null; then
        _def_port=25566
    fi
    local MC_PORT=""
    prompt_text "Minecraft server port [${_def_port}]:" "$_def_port" MC_PORT
    if grep -qs "\"${MC_PORT}:25565\"" "$DOCKER_DIR"/*/docker-compose.yml 2>/dev/null; then
        log_warning "Port ${MC_PORT} is already mapped by another instance — pick a unique host port."
    fi

    local MC_RAM=""
    prompt_text "Memory allocation in GB [4]:" "4" MC_RAM

    # ── Mod selection (Fabric/Quilt only) ──────────────────────────────────────
    local SELECTED_MODS=()
    local SELECTED_DATAPACKS=()
    local MC_VERSION=""

    declare -A MODS
    declare -A MOD_DESC
    declare -A MOD_DEFAULT
    declare -A MOD_MODRINTH_ID
    local MOD_ORDER=()

    if [ "$SUPPORTS_FABRIC_MODS" = true ]; then
        echo ""
        log_info "Mod Selection"
        echo "Toggle mods on/off. Performance mods are pre-selected (recommended)."
        echo ""

        MODS["nochatreports"]="NoChatReports"
        MOD_DESC["nochatreports"]="Removes Mojang's chat reporting system server-side."
        MOD_DEFAULT["nochatreports"]="y"
        MOD_MODRINTH_ID["nochatreports"]="qQyHxfxd"

        MODS["essentials"]="Essentials for Fabric"
        MOD_DESC["essentials"]="Homes, warps, TPA, /back, /spawn, /heal, /fly, admin tools."
        MOD_DEFAULT["essentials"]="y"
        MOD_MODRINTH_ID["essentials"]="fessentials"

        MODS["luckperms"]="LuckPerms"
        MOD_DESC["luckperms"]="Permissions system. Pre-configured with default/mod/admin groups."
        MOD_DEFAULT["luckperms"]="y"
        MOD_MODRINTH_ID["luckperms"]="luckperms"

        MODS["lithium"]="Lithium"
        MOD_DESC["lithium"]="Server performance — optimises mob AI, physics, block ticking. 30-50% faster TPS."
        MOD_DEFAULT["lithium"]="y"
        MOD_MODRINTH_ID["lithium"]="lithium"

        MODS["ferritecore"]="FerriteCore"
        MOD_DESC["ferritecore"]="Reduces server memory usage significantly."
        MOD_DEFAULT["ferritecore"]="y"
        MOD_MODRINTH_ID["ferritecore"]="ferritecore"

        MODS["starlight"]="Starlight"
        MOD_DESC["starlight"]="Rewrites the lighting engine — big reduction in lag spikes."
        MOD_DEFAULT["starlight"]="y"
        MOD_MODRINTH_ID["starlight"]="starlight"

        MODS["chunky"]="Chunky"
        MOD_DESC["chunky"]="Pre-generates chunks so players don't cause lag exploring new areas. Essential for elytra flyers."
        MOD_DEFAULT["chunky"]="y"
        MOD_MODRINTH_ID["chunky"]="chunky"

        MODS["c2me"]="C2ME (Concurrent Chunk Management)"
        MOD_DESC["c2me"]="Multithreads chunk generation. Alpha-quality — can crash on startup. Only enable if you need it."
        MOD_DEFAULT["c2me"]="n"
        MOD_MODRINTH_ID["c2me"]="c2me-fabric"

        MODS["spark"]="Spark"
        MOD_DESC["spark"]="Server profiler — diagnose lag, TPS drops, memory issues."
        MOD_DEFAULT["spark"]="y"
        MOD_MODRINTH_ID["spark"]="spark"

        MODS["carpet"]="Carpet"
        MOD_DESC["carpet"]="Technical Minecraft features, mob spawning tweaks, debug tools."
        MOD_DEFAULT["carpet"]="y"
        MOD_MODRINTH_ID["carpet"]="carpet"

        MODS["ledger"]="Ledger"
        MOD_DESC["ledger"]="Block change logging and grief tracking. Query who broke/placed what."
        MOD_DEFAULT["ledger"]="y"
        MOD_MODRINTH_ID["ledger"]="ledger"

        MODS["serverreplay"]="ServerReplay"
        MOD_DESC["serverreplay"]="Records server-side replays viewable with ReplayMod on client."
        MOD_DEFAULT["serverreplay"]="n"
        MOD_MODRINTH_ID["serverreplay"]="server-replay"

        MOD_ORDER=("nochatreports" "essentials" "luckperms" "lithium" "ferritecore"
                   "starlight" "chunky" "c2me" "spark" "carpet" "ledger" "serverreplay")

        # ── Version picker with mod availability table ─────────────────────────
        echo ""
        log_info "Checking mod availability across recent versions (this takes a few seconds)..."
        echo ""

        local COL_MOD=22
        local COL_VER=12

        printf "  %-${COL_MOD}s" "Mod"
        local ver
        for ver in "${RECENT_VERSIONS[@]}"; do
            printf "  %-${COL_VER}s" "$ver"
        done
        echo ""
        printf "  %-${COL_MOD}s" "$(printf '%0.s─' $(seq 1 $COL_MOD))"
        for ver in "${RECENT_VERSIONS[@]}"; do
            printf "  %-${COL_VER}s" "$(printf '%0.s─' $(seq 1 $COL_VER))"
        done
        echo ""

        declare -A MOD_AVAIL  # key: "mod:ver" → "yes"/"no"
        local mod slug label result
        for mod in "${MOD_ORDER[@]}"; do
            slug="${MOD_MODRINTH_ID[$mod]}"
            label="${MODS[$mod]}"
            printf "  %-${COL_MOD}s" "${label:0:$COL_MOD}"
            for ver in "${RECENT_VERSIONS[@]}"; do
                result=$(curl -sf --max-time 8 \
                    "https://api.modrinth.com/v2/project/${slug}/version?game_versions=%5B%22${ver}%22%5D&loaders=%5B%22fabric%22%5D" \
                    | python3 -c "import sys,json; v=json.load(sys.stdin); print('yes' if v else 'no')" 2>/dev/null || echo "?")
                MOD_AVAIL["${mod}:${ver}"]="$result"
                if [ "$result" = "yes" ]; then
                    printf "  \033[0;32m%-${COL_VER}s\033[0m" "✓"
                elif [ "$result" = "no" ]; then
                    printf "  \033[0;31m%-${COL_VER}s\033[0m" "✗ not yet"
                else
                    printf "  %-${COL_VER}s" "?"
                fi
            done
            echo ""
        done
        echo ""

        # Find the version with the best mod availability to use as the default.
        local _BEST_VER_IDX=0
        local _BEST_VER_COUNT=-1
        local i _count
        for i in "${!RECENT_VERSIONS[@]}"; do
            _count=0
            for mod in "${MOD_ORDER[@]}"; do
                [ "${MOD_AVAIL[${mod}:${RECENT_VERSIONS[$i]}]}" = "yes" ] && _count=$((_count+1))
            done
            if [ $_count -gt $_BEST_VER_COUNT ]; then
                _BEST_VER_COUNT=$_count
                _BEST_VER_IDX=$i
            fi
        done
        local _DEFAULT_VER_NUM=$((_BEST_VER_IDX+1))

        echo "  Which version do you want to use?"
        local _ver _suffix
        for i in "${!RECENT_VERSIONS[@]}"; do
            _ver="${RECENT_VERSIONS[$i]}"
            _count=0
            for mod in "${MOD_ORDER[@]}"; do
                [ "${MOD_AVAIL[${mod}:${_ver}]}" = "yes" ] && _count=$((_count+1))
            done
            _suffix="(${_count}/${#MOD_ORDER[@]} mods available)"
            [ "$i" -eq "$_BEST_VER_IDX" ] && _suffix="$_suffix  ← Recommended"
            if [[ "$_ver" =~ ^[2-9][0-9]\. ]] && [ "$_count" -eq 0 ]; then
                _suffix="$_suffix  ⚠ new versioning — mods not yet compatible"
            fi
            echo "  $((i+1))) $_ver  $_suffix"
        done
        local _SNAP_OPT="" _SNAP_NUM _MAN_NUM
        if [ -n "$LATEST_SNAPSHOT" ]; then
            _SNAP_NUM=$(( ${#RECENT_VERSIONS[@]} + 1 ))
            _MAN_NUM=$(( ${#RECENT_VERSIONS[@]} + 2 ))
            echo "  ${_SNAP_NUM}) ${LATEST_SNAPSHOT}  ⚠ snapshot — mods may not be available yet"
            _SNAP_OPT="$LATEST_SNAPSHOT"
        else
            _MAN_NUM=$(( ${#RECENT_VERSIONS[@]} + 1 ))
        fi
        echo "  ${_MAN_NUM}) Enter manually"
        echo ""
        local _VER_CHOICE=""
        read -p "Choice [${_DEFAULT_VER_NUM}]: " _VER_CHOICE
        _VER_CHOICE="${_VER_CHOICE:-${_DEFAULT_VER_NUM}}"

        if [ "$_VER_CHOICE" -le "${#RECENT_VERSIONS[@]}" ] 2>/dev/null; then
            MC_VERSION="${RECENT_VERSIONS[$((_VER_CHOICE-1))]}"
            local _picked_count=0
            for mod in "${MOD_ORDER[@]}"; do
                [ "${MOD_AVAIL[${mod}:${MC_VERSION}]}" = "yes" ] && _picked_count=$((_picked_count+1))
            done
            if [ "$_picked_count" -eq 0 ] && [ "$_BEST_VER_COUNT" -gt 0 ]; then
                echo ""
                log_warning "No mods are available for $MC_VERSION yet!"
                log_warning "Server will crash on startup — Fabric rejects mods built for a different version string."
                log_warning "Recommended: use ${RECENT_VERSIONS[$_BEST_VER_IDX]} where all mods are available."
                local _switch=""
                read -p "Switch to ${RECENT_VERSIONS[$_BEST_VER_IDX]} instead? (y/n) [y]: " -n 1 -r _switch; echo
                if [[ ${_switch:-y} =~ ^[Yy]$ ]]; then
                    MC_VERSION="${RECENT_VERSIONS[$_BEST_VER_IDX]}"
                    log_success "Switched to $MC_VERSION"
                else
                    log_warning "Continuing with $MC_VERSION — mods will be skipped (server runs vanilla)"
                    SELECTED_MODS=()
                fi
            fi
        elif [ -n "$_SNAP_OPT" ] && [ "$_VER_CHOICE" = "$_SNAP_NUM" ] 2>/dev/null; then
            MC_VERSION="$_SNAP_OPT"
            log_warning "Snapshot selected — Fabric and mods may not support this version yet"
        else
            read -p "Enter Minecraft version: " MC_VERSION
            if ! [[ "$MC_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
                MC_VERSION="${RECENT_VERSIONS[$_BEST_VER_IDX]}"
                log_warning "Invalid version — defaulting to $MC_VERSION"
            fi
        fi
        log_success "Using Minecraft $MC_VERSION"

        # Select defaults, auto-skipping only mods KNOWN to be incompatible.
        for mod in "${MOD_ORDER[@]}"; do
            if [[ "${MOD_DEFAULT[$mod]}" == "y" ]]; then
                if [[ "${MOD_AVAIL[${mod}:${MC_VERSION}]}" == "no" ]]; then
                    log_info "  Auto-skipping ${MODS[$mod]} (not available for $MC_VERSION)"
                else
                    SELECTED_MODS+=("$mod")
                fi
            fi
        done

        local choice key marker all_num done_num
        while true; do
            echo ""
            for i in "${!MOD_ORDER[@]}"; do
                key="${MOD_ORDER[$i]}"
                marker=" "
                [[ " ${SELECTED_MODS[*]} " =~ " ${key} " ]] && marker="✓"
                if [[ "${MOD_AVAIL[${key}:${MC_VERSION}]}" == "no" ]]; then
                    printf "  %2d) %s %-22s %s" \
                        "$((i+1))" "$marker" "${MODS[$key]}" "${MOD_DESC[$key]}"
                    echo -e " \033[0;31m[not available for $MC_VERSION]\033[0m"
                else
                    printf "  %2d) %s %-22s %s\n" \
                        "$((i+1))" "$marker" "${MODS[$key]}" "${MOD_DESC[$key]}"
                fi
            done
            echo ""
            echo "  $(( ${#MOD_ORDER[@]} + 1 ))) Select All"
            echo "  $(( ${#MOD_ORDER[@]} + 2 ))) Done"
            echo ""
            read -p "Selection: " choice

            all_num=$(( ${#MOD_ORDER[@]} + 1 ))
            done_num=$(( ${#MOD_ORDER[@]} + 2 ))

            if [ "$choice" = "$all_num" ]; then
                SELECTED_MODS=("${MOD_ORDER[@]}"); break
            elif [ "$choice" = "$done_num" ] || [ "$choice" = "done" ]; then
                break
            elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && \
                 [ "$choice" -le "${#MOD_ORDER[@]}" ]; then
                key="${MOD_ORDER[$((choice-1))]}"
                if [[ " ${SELECTED_MODS[*]} " =~ " ${key} " ]]; then
                    SELECTED_MODS=("${SELECTED_MODS[@]/$key}")
                    SELECTED_MODS=(${SELECTED_MODS[@]})
                else
                    SELECTED_MODS+=("$key")
                fi
            else
                log_warning "Invalid selection"
            fi
        done

        # ── Vanilla Tweaks datapacks ───────────────────────────────────────────
        echo ""
        log_info "Vanilla Tweaks Datapacks"
        echo "Toggle datapacks. Recommended defaults are pre-selected."
        echo ""

        declare -A DPACKS
        declare -A DPACK_DESC
        declare -A DPACK_DEFAULT
        declare -A DPACK_VT_ID
        declare -A DPACK_CAT

        # ── Decorative / Cosmetic ──────────────────────────────────────────────
        DPACKS["armor_statues"]="Armor Statues"
        DPACK_DESC["armor_statues"]="Book to pose and customise armor stands."
        DPACK_DEFAULT["armor_statues"]="y"; DPACK_CAT["armor_statues"]="Decorative/Cosmetic"
        DPACK_VT_ID["armor_statues"]="armorStatues"

        DPACKS["custom_nether_portals"]="Custom Nether Portals"
        DPACK_DESC["custom_nether_portals"]="Build nether portals in any shape using crying obsidian."
        DPACK_DEFAULT["custom_nether_portals"]="n"; DPACK_CAT["custom_nether_portals"]="Decorative/Cosmetic"
        DPACK_VT_ID["custom_nether_portals"]="customNetherPortals"

        DPACKS["mini_blocks"]="Mini Blocks"
        DPACK_DESC["mini_blocks"]="Craft 1/8-scale decorative versions of most blocks."
        DPACK_DEFAULT["mini_blocks"]="n"; DPACK_CAT["mini_blocks"]="Decorative/Cosmetic"
        DPACK_VT_ID["mini_blocks"]="miniBlocks"

        DPACKS["more_mob_heads"]="More Mob Heads"
        DPACK_DESC["more_mob_heads"]="Mobs have a chance to drop their head on death."
        DPACK_DEFAULT["more_mob_heads"]="y"; DPACK_CAT["more_mob_heads"]="Decorative/Cosmetic"
        DPACK_VT_ID["more_mob_heads"]="moreMobHeads"

        DPACKS["name_colors"]="Name Colors"
        DPACK_DESC["name_colors"]="Players set their own name color using a trigger."
        DPACK_DEFAULT["name_colors"]="n"; DPACK_CAT["name_colors"]="Decorative/Cosmetic"
        DPACK_VT_ID["name_colors"]="nameColors"

        DPACKS["player_head_drops"]="Player Head Drops"
        DPACK_DESC["player_head_drops"]="Players drop their head when killed by another player."
        DPACK_DEFAULT["player_head_drops"]="y"; DPACK_CAT["player_head_drops"]="Decorative/Cosmetic"
        DPACK_VT_ID["player_head_drops"]="playerHeadDrops"

        DPACKS["silence_mobs"]="Silence Mobs"
        DPACK_DESC["silence_mobs"]="Name a mob 'silence_me' to mute it permanently."
        DPACK_DEFAULT["silence_mobs"]="y"; DPACK_CAT["silence_mobs"]="Decorative/Cosmetic"
        DPACK_VT_ID["silence_mobs"]="silenceMobs"

        DPACKS["wandering_trades"]="Wandering Trades"
        DPACK_DESC["wandering_trades"]="Wandering trader sells mini blocks."
        DPACK_DEFAULT["wandering_trades"]="n"; DPACK_CAT["wandering_trades"]="Decorative/Cosmetic"
        DPACK_VT_ID["wandering_trades"]="wanderingTrades"

        DPACKS["wandering_trades_hermit"]="Wandering Trades (Hermit Edition)"
        DPACK_DESC["wandering_trades_hermit"]="Wandering trader sells Hermitcraft player heads."
        DPACK_DEFAULT["wandering_trades_hermit"]="n"; DPACK_CAT["wandering_trades_hermit"]="Decorative/Cosmetic"
        DPACK_VT_ID["wandering_trades_hermit"]="wanderingTradesHermitEdition"

        # ── Convenience ─────────────────────────────────────────────────────────
        DPACKS["cauldron_concrete"]="Cauldron Concrete"
        DPACK_DESC["cauldron_concrete"]="Dip concrete powder in a water cauldron to make concrete."
        DPACK_DEFAULT["cauldron_concrete"]="n"; DPACK_CAT["cauldron_concrete"]="Convenience"
        DPACK_VT_ID["cauldron_concrete"]="cauldronConcrete"

        DPACKS["cauldron_mud"]="Cauldron Mud"
        DPACK_DESC["cauldron_mud"]="Add water to a dirt-filled cauldron to make mud."
        DPACK_DEFAULT["cauldron_mud"]="n"; DPACK_CAT["cauldron_mud"]="Convenience"
        DPACK_VT_ID["cauldron_mud"]="cauldronMud"

        DPACKS["chunk_loaders"]="Chunk Loaders"
        DPACK_DESC["chunk_loaders"]="Craftable item that keeps chunks loaded when you're offline."
        DPACK_DEFAULT["chunk_loaders"]="n"; DPACK_CAT["chunk_loaders"]="Convenience"
        DPACK_VT_ID["chunk_loaders"]="chunkLoaders"

        DPACKS["double_shulker_shells"]="Double Shulker Shells"
        DPACK_DESC["double_shulker_shells"]="Shulkers always drop 2 shells."
        DPACK_DEFAULT["double_shulker_shells"]="y"; DPACK_CAT["double_shulker_shells"]="Convenience"
        DPACK_VT_ID["double_shulker_shells"]="doubleShulkerShells"

        DPACKS["dragon_drops"]="Dragon Drops"
        DPACK_DESC["dragon_drops"]="Ender Dragon drops an elytra and dragon egg on first kill."
        DPACK_DEFAULT["dragon_drops"]="y"; DPACK_CAT["dragon_drops"]="Convenience"
        DPACK_VT_ID["dragon_drops"]="dragonDrops"

        DPACKS["elevators"]="Elevators"
        DPACK_DESC["elevators"]="Craft elevator blocks that teleport players vertically."
        DPACK_DEFAULT["elevators"]="n"; DPACK_CAT["elevators"]="Convenience"
        DPACK_VT_ID["elevators"]="elevators"

        DPACKS["ender_chest_drops"]="Ender Chest Drops"
        DPACK_DESC["ender_chest_drops"]="Ender chest drops 8 obsidian + eye of ender when broken."
        DPACK_DEFAULT["ender_chest_drops"]="n"; DPACK_CAT["ender_chest_drops"]="Convenience"
        DPACK_VT_ID["ender_chest_drops"]="enderChestDrops"

        DPACKS["fast_leaf_decay"]="Fast Leaf Decay"
        DPACK_DESC["fast_leaf_decay"]="Leaves decay much faster after a tree is felled."
        DPACK_DEFAULT["fast_leaf_decay"]="y"; DPACK_CAT["fast_leaf_decay"]="Convenience"
        DPACK_VT_ID["fast_leaf_decay"]="fastLeafDecay"

        DPACKS["glass_always_drops"]="Glass Always Drops"
        DPACK_DESC["glass_always_drops"]="Breaking glass without Silk Touch still returns the block."
        DPACK_DEFAULT["glass_always_drops"]="n"; DPACK_CAT["glass_always_drops"]="Convenience"
        DPACK_VT_ID["glass_always_drops"]="glassAlwaysDrops"

        DPACKS["more_effective_tools"]="More Effective Tools"
        DPACK_DESC["more_effective_tools"]="Axes/pickaxes/shovels also break nearby matching blocks."
        DPACK_DEFAULT["more_effective_tools"]="n"; DPACK_CAT["more_effective_tools"]="Convenience"
        DPACK_VT_ID["more_effective_tools"]="moreEffectiveTools"

        DPACKS["multiplayer_sleep"]="Multiplayer Sleep"
        DPACK_DESC["multiplayer_sleep"]="Only one player needs to sleep to skip the night."
        DPACK_DEFAULT["multiplayer_sleep"]="y"; DPACK_CAT["multiplayer_sleep"]="Convenience"
        DPACK_VT_ID["multiplayer_sleep"]="multiplayerSleep"

        DPACKS["painting_picker"]="Painting Picker"
        DPACK_DESC["painting_picker"]="Cycle through painting variants when placing via a trigger."
        DPACK_DEFAULT["painting_picker"]="n"; DPACK_CAT["painting_picker"]="Convenience"
        DPACK_VT_ID["painting_picker"]="paintingPicker"

        DPACKS["redstone_rotation_wrench"]="Redstone Rotation Wrench"
        DPACK_DESC["redstone_rotation_wrench"]="Craft a wrench to rotate redstone components in place."
        DPACK_DEFAULT["redstone_rotation_wrench"]="n"; DPACK_CAT["redstone_rotation_wrench"]="Convenience"
        DPACK_VT_ID["redstone_rotation_wrench"]="redstoneRotationWrench"

        DPACKS["spectator_conduit_power"]="Spectator Conduit Power"
        DPACK_DESC["spectator_conduit_power"]="Spectators get conduit power effects (useful for builders)."
        DPACK_DEFAULT["spectator_conduit_power"]="n"; DPACK_CAT["spectator_conduit_power"]="Convenience"
        DPACK_VT_ID["spectator_conduit_power"]="spectatorConduitPower"

        DPACKS["spectator_night_vision"]="Spectator Night Vision"
        DPACK_DESC["spectator_night_vision"]="Night vision is automatically applied in spectator mode."
        DPACK_DEFAULT["spectator_night_vision"]="n"; DPACK_CAT["spectator_night_vision"]="Convenience"
        DPACK_VT_ID["spectator_night_vision"]="spectatorNightVision"

        DPACKS["storm_channeling"]="Storm Channeling"
        DPACK_DESC["storm_channeling"]="Trident Channeling works in rain, not just thunderstorms."
        DPACK_DEFAULT["storm_channeling"]="n"; DPACK_CAT["storm_channeling"]="Convenience"
        DPACK_VT_ID["storm_channeling"]="stormChanneling"

        DPACKS["terracotta_rotation_wrench"]="Terracotta Rotation Wrench"
        DPACK_DESC["terracotta_rotation_wrench"]="Craft a wrench to rotate glazed terracotta in place."
        DPACK_DEFAULT["terracotta_rotation_wrench"]="n"; DPACK_CAT["terracotta_rotation_wrench"]="Convenience"
        DPACK_VT_ID["terracotta_rotation_wrench"]="terracottaRotationWrench"

        DPACKS["timber"]="Timber"
        DPACK_DESC["timber"]="Chop the bottom log to fell an entire tree instantly."
        DPACK_DEFAULT["timber"]="n"; DPACK_CAT["timber"]="Convenience"
        DPACK_VT_ID["timber"]="timber"

        DPACKS["unlock_all_recipes"]="Unlock All Recipes"
        DPACK_DESC["unlock_all_recipes"]="All crafting recipes unlocked for all players from the start."
        DPACK_DEFAULT["unlock_all_recipes"]="n"; DPACK_CAT["unlock_all_recipes"]="Convenience"
        DPACK_VT_ID["unlock_all_recipes"]="unlockAllRecipes"

        DPACKS["weed_stripper"]="Weed Stripper"
        DPACK_DESC["weed_stripper"]="Hoe clears grass, flowers and shrubs in a wider area."
        DPACK_DEFAULT["weed_stripper"]="n"; DPACK_CAT["weed_stripper"]="Convenience"
        DPACK_VT_ID["weed_stripper"]="weedStripper"

        # ── Gameplay Changes ────────────────────────────────────────────────────
        DPACKS["anti_creeper_grief"]="Anti Creeper Grief"
        DPACK_DESC["anti_creeper_grief"]="Creeper explosions don't destroy blocks."
        DPACK_DEFAULT["anti_creeper_grief"]="n"; DPACK_CAT["anti_creeper_grief"]="Gameplay Changes"
        DPACK_VT_ID["anti_creeper_grief"]="antiCreeperGrief"

        DPACKS["anti_enderman_grief"]="Anti Enderman Grief"
        DPACK_DESC["anti_enderman_grief"]="Endermen can't pick up blocks — stops world griefing."
        DPACK_DEFAULT["anti_enderman_grief"]="y"; DPACK_CAT["anti_enderman_grief"]="Gameplay Changes"
        DPACK_VT_ID["anti_enderman_grief"]="antiEndermanGrief"

        DPACKS["anti_ghast_grief"]="Anti Ghast Grief"
        DPACK_DESC["anti_ghast_grief"]="Ghast fireballs don't destroy Nether blocks."
        DPACK_DEFAULT["anti_ghast_grief"]="n"; DPACK_CAT["anti_ghast_grief"]="Gameplay Changes"
        DPACK_VT_ID["anti_ghast_grief"]="antiGhastGrief"

        DPACKS["armored_elytra"]="Armored Elytra"
        DPACK_DESC["armored_elytra"]="Combine elytra and chestplate to wear both at once."
        DPACK_DEFAULT["armored_elytra"]="n"; DPACK_CAT["armored_elytra"]="Gameplay Changes"
        DPACK_VT_ID["armored_elytra"]="armoredElytra"

        DPACKS["bat_membranes"]="Bat Membranes"
        DPACK_DESC["bat_membranes"]="Bats drop membranes used to craft a gliding cape."
        DPACK_DEFAULT["bat_membranes"]="n"; DPACK_CAT["bat_membranes"]="Gameplay Changes"
        DPACK_VT_ID["bat_membranes"]="batMembranes"

        DPACKS["classic_fishing"]="Classic Fishing Lure"
        DPACK_DESC["classic_fishing"]="Restore pre-1.16 fishing — treasure loot in any open water."
        DPACK_DEFAULT["classic_fishing"]="n"; DPACK_CAT["classic_fishing"]="Gameplay Changes"
        DPACK_VT_ID["classic_fishing"]="classicFishingLure"

        DPACKS["confetti_creepers"]="Confetti Creepers"
        DPACK_DESC["confetti_creepers"]="Creepers explode into colourful fireworks — cosmetic only."
        DPACK_DEFAULT["confetti_creepers"]="n"; DPACK_CAT["confetti_creepers"]="Gameplay Changes"
        DPACK_VT_ID["confetti_creepers"]="confettiCreepers"

        DPACKS["graves"]="Graves"
        DPACK_DESC["graves"]="Creates a grave on death that stores your items."
        DPACK_DEFAULT["graves"]="y"; DPACK_CAT["graves"]="Gameplay Changes"
        DPACK_VT_ID["graves"]="graves"

        DPACKS["husks_drop_sand"]="Husks Drop Sand"
        DPACK_DESC["husks_drop_sand"]="Husks drop sand when killed — makes sand renewable."
        DPACK_DEFAULT["husks_drop_sand"]="n"; DPACK_CAT["husks_drop_sand"]="Gameplay Changes"
        DPACK_VT_ID["husks_drop_sand"]="husksDropSand"

        DPACKS["silk_touch_amethyst"]="Silk Touch Building Amethyst"
        DPACK_DESC["silk_touch_amethyst"]="Silk Touch lets you mine amethyst clusters as placeable blocks."
        DPACK_DEFAULT["silk_touch_amethyst"]="n"; DPACK_CAT["silk_touch_amethyst"]="Gameplay Changes"
        DPACK_VT_ID["silk_touch_amethyst"]="silkTouchBuildingAmethyst"

        DPACKS["xp_bottling"]="XP Bottling"
        DPACK_DESC["xp_bottling"]="Store your XP in bottles of enchanting at a grindstone."
        DPACK_DEFAULT["xp_bottling"]="n"; DPACK_CAT["xp_bottling"]="Gameplay Changes"
        DPACK_VT_ID["xp_bottling"]="xpBottling"

        # ── Informative ───────────────────────────────────────────────────────
        DPACKS["afk_display"]="AFK Display"
        DPACK_DESC["afk_display"]="Shows [AFK] next to player names when idle."
        DPACK_DEFAULT["afk_display"]="y"; DPACK_CAT["afk_display"]="Informative"
        DPACK_VT_ID["afk_display"]="afkDisplay"

        DPACKS["coords_hud"]="Coordinates HUD"
        DPACK_DESC["coords_hud"]="Players toggle coordinate display in the actionbar."
        DPACK_DEFAULT["coords_hud"]="y"; DPACK_CAT["coords_hud"]="Informative"
        DPACK_VT_ID["coords_hud"]="coordinatesHud"

        DPACKS["durability_ping"]="Durability Ping"
        DPACK_DESC["durability_ping"]="Sound + actionbar alert when tool/armor durability gets low."
        DPACK_DEFAULT["durability_ping"]="y"; DPACK_CAT["durability_ping"]="Informative"
        DPACK_VT_ID["durability_ping"]="durabilityPing"

        DPACKS["nether_portal_coords"]="Nether Portal Coords"
        DPACK_DESC["nether_portal_coords"]="Chat shows overworld↔nether coordinate conversion on entry."
        DPACK_DEFAULT["nether_portal_coords"]="y"; DPACK_CAT["nether_portal_coords"]="Informative"
        DPACK_VT_ID["nether_portal_coords"]="netherPortalCoords"

        DPACKS["real_time_clock"]="Real Time Clock"
        DPACK_DESC["real_time_clock"]="Shows real-world time in actionbar via a trigger."
        DPACK_DEFAULT["real_time_clock"]="n"; DPACK_CAT["real_time_clock"]="Informative"
        DPACK_VT_ID["real_time_clock"]="realTimeClock"

        DPACKS["spawning_spheres"]="Spawning Spheres"
        DPACK_DESC["spawning_spheres"]="Visualise the mob spawn radius around a block."
        DPACK_DEFAULT["spawning_spheres"]="n"; DPACK_CAT["spawning_spheres"]="Informative"
        DPACK_VT_ID["spawning_spheres"]="spawningSpheres"

        DPACKS["track_raw_statistics"]="Track Raw Statistics"
        DPACK_DESC["track_raw_statistics"]="Scoreboards tracking raw stat values (distance, damage, etc.)."
        DPACK_DEFAULT["track_raw_statistics"]="n"; DPACK_CAT["track_raw_statistics"]="Informative"
        DPACK_VT_ID["track_raw_statistics"]="trackRawStatistics"

        DPACKS["track_statistics"]="Track Statistics"
        DPACK_DESC["track_statistics"]="Scoreboards for deaths, mob kills, playtime."
        DPACK_DEFAULT["track_statistics"]="y"; DPACK_CAT["track_statistics"]="Informative"
        DPACK_VT_ID["track_statistics"]="trackStatistics"

        DPACKS["village_death_messages"]="Village Death Messages"
        DPACK_DESC["village_death_messages"]="Chat alert when a villager is killed nearby."
        DPACK_DEFAULT["village_death_messages"]="y"; DPACK_CAT["village_death_messages"]="Informative"
        DPACK_VT_ID["village_death_messages"]="villageDeathMessages"

        DPACKS["workstation_highlights"]="Workstation Highlights"
        DPACK_DESC["workstation_highlights"]="Particles show which workstation a villager is linked to."
        DPACK_DEFAULT["workstation_highlights"]="y"; DPACK_CAT["workstation_highlights"]="Informative"
        DPACK_VT_ID["workstation_highlights"]="workstationHighlights"

        DPACKS["wandering_trader_ann"]="Wandering Trader Announcements"
        DPACK_DESC["wandering_trader_ann"]="Chat message when a Wandering Trader appears near spawn."
        DPACK_DEFAULT["wandering_trader_ann"]="n"; DPACK_CAT["wandering_trader_ann"]="Informative"
        DPACK_VT_ID["wandering_trader_ann"]="wanderingTraderAnnouncements"

        # ── Teleport Commands ───────────────────────────────────────────────────
        DPACKS["tp_back"]="Back"
        DPACK_DESC["tp_back"]="Return to last death or teleport location via trigger."
        DPACK_DEFAULT["tp_back"]="n"; DPACK_CAT["tp_back"]="Teleport Commands"
        DPACK_VT_ID["tp_back"]="back"

        DPACKS["homes"]="Homes"
        DPACK_DESC["homes"]="Set and teleport to named home locations via trigger."
        DPACK_DEFAULT["homes"]="n"; DPACK_CAT["homes"]="Teleport Commands"
        DPACK_VT_ID["homes"]="homes"

        DPACKS["spawn"]="Spawn"
        DPACK_DESC["spawn"]="Set and return to a global spawn point via trigger."
        DPACK_DEFAULT["spawn"]="n"; DPACK_CAT["spawn"]="Teleport Commands"
        DPACK_VT_ID["spawn"]="spawn"

        DPACKS["tpa"]="TPA"
        DPACK_DESC["tpa"]="Teleport-request system via trigger."
        DPACK_DEFAULT["tpa"]="n"; DPACK_CAT["tpa"]="Teleport Commands"
        DPACK_VT_ID["tpa"]="tpa"

        # ── Admin Tools ─────────────────────────────────────────────────────────
        DPACKS["custom_villager_shops"]="Custom Villager Shops"
        DPACK_DESC["custom_villager_shops"]="Build custom villager trade shops using a book."
        DPACK_DEFAULT["custom_villager_shops"]="n"; DPACK_CAT["custom_villager_shops"]="Admin Tools"
        DPACK_VT_ID["custom_villager_shops"]="customVillagerShops"

        DPACKS["kill_empty_boats"]="Kill Empty Boats"
        DPACK_DESC["kill_empty_boats"]="Periodically removes riderless boats to cut entity lag."
        DPACK_DEFAULT["kill_empty_boats"]="n"; DPACK_CAT["kill_empty_boats"]="Admin Tools"
        DPACK_VT_ID["kill_empty_boats"]="killEmptyBoats"

        local DPACK_ORDER=(
            # Decorative / Cosmetic
            "armor_statues" "custom_nether_portals" "mini_blocks" "more_mob_heads"
            "name_colors" "player_head_drops" "silence_mobs"
            "wandering_trades" "wandering_trades_hermit"
            # Convenience
            "cauldron_concrete" "cauldron_mud" "chunk_loaders" "double_shulker_shells"
            "dragon_drops" "elevators" "ender_chest_drops" "fast_leaf_decay"
            "glass_always_drops" "more_effective_tools" "multiplayer_sleep"
            "painting_picker" "redstone_rotation_wrench" "spectator_conduit_power"
            "spectator_night_vision" "storm_channeling" "terracotta_rotation_wrench"
            "timber" "unlock_all_recipes" "weed_stripper"
            # Gameplay Changes
            "anti_creeper_grief" "anti_enderman_grief" "anti_ghast_grief"
            "armored_elytra" "bat_membranes" "classic_fishing" "confetti_creepers"
            "graves" "husks_drop_sand" "silk_touch_amethyst" "xp_bottling"
            # Informative
            "afk_display" "coords_hud" "durability_ping" "nether_portal_coords"
            "real_time_clock" "spawning_spheres" "track_raw_statistics"
            "track_statistics" "village_death_messages" "workstation_highlights"
            "wandering_trader_ann"
            # Teleport Commands
            "tp_back" "homes" "spawn" "tpa"
            # Admin Tools
            "custom_villager_shops" "kill_empty_boats"
        )

        local dp
        for dp in "${DPACK_ORDER[@]}"; do
            [[ "${DPACK_DEFAULT[$dp]}" == "y" ]] && SELECTED_DATAPACKS+=("$dp")
        done

        echo ""
        log_info "Vanilla Tweaks datapacks"
        echo "  ✓ = pre-selected (recommended defaults)"
        echo "  Only the recommended datapacks are shown — toggle numbers then press Done."
        echo "  Pick 'Show all datapacks' to browse the full Vanilla Tweaks catalogue."
        echo ""

        local SHOW_ALL=false
        local VISIBLE=() _LAST_CAT _cat _marker _n _dp_choice _dp_toggle _dp_all _dp_done _dp_key
        while true; do
            VISIBLE=()
            for dp in "${DPACK_ORDER[@]}"; do
                if [ "$SHOW_ALL" = true ] || [[ "${DPACK_DEFAULT[$dp]}" == "y" ]]; then
                    VISIBLE+=("$dp")
                fi
            done

            _LAST_CAT=""
            for i in "${!VISIBLE[@]}"; do
                dp="${VISIBLE[$i]}"
                _cat="${DPACK_CAT[$dp]}"
                if [ "$_cat" != "$_LAST_CAT" ]; then
                    echo ""
                    echo -e "  \033[1;33m── ${_cat}\033[0m"
                    _LAST_CAT="$_cat"
                fi
                _marker=" "
                [[ " ${SELECTED_DATAPACKS[*]} " =~ " ${dp} " ]] && _marker="✓"
                printf "  %2d) %s %-34s %s\n" "$((i+1))" "$_marker" "${DPACKS[$dp]}" "${DPACK_DESC[$dp]}"
            done
            echo ""
            _n=${#VISIBLE[@]}
            if [ "$SHOW_ALL" = true ]; then
                echo "  $(( _n + 1 ))) Show recommended only"
            else
                echo "  $(( _n + 1 ))) Show all datapacks (${#DPACK_ORDER[@]} total)"
            fi
            echo "  $(( _n + 2 ))) Select All"
            echo "  $(( _n + 3 ))) Done"
            echo ""
            read -p "Selection: " _dp_choice

            _dp_toggle=$(( _n + 1 ))
            _dp_all=$(( _n + 2 ))
            _dp_done=$(( _n + 3 ))

            if [ "$_dp_choice" = "$_dp_toggle" ]; then
                [ "$SHOW_ALL" = true ] && SHOW_ALL=false || SHOW_ALL=true
            elif [ "$_dp_choice" = "$_dp_all" ]; then
                for dp in "${VISIBLE[@]}"; do
                    [[ " ${SELECTED_DATAPACKS[*]} " =~ " ${dp} " ]] || SELECTED_DATAPACKS+=("$dp")
                done
                break
            elif [ "$_dp_choice" = "$_dp_done" ] || [ "$_dp_choice" = "done" ]; then
                break
            elif [[ "$_dp_choice" =~ ^[0-9]+$ ]] && [ "$_dp_choice" -ge 1 ] && \
                 [ "$_dp_choice" -le "$_n" ]; then
                _dp_key="${VISIBLE[$((_dp_choice-1))]}"
                if [[ " ${SELECTED_DATAPACKS[*]} " =~ " ${_dp_key} " ]]; then
                    SELECTED_DATAPACKS=("${SELECTED_DATAPACKS[@]/$_dp_key}")
                    SELECTED_DATAPACKS=(${SELECTED_DATAPACKS[@]})
                else
                    SELECTED_DATAPACKS+=("$_dp_key")
                fi
            else
                log_warning "Invalid selection"
            fi
        done
    fi

    # Vanilla/Paper/Forge: still need a concrete version (no picker ran above).
    if [ -z "$MC_VERSION" ]; then
        prompt_text "Minecraft version [${RECENT_VERSIONS[0]}]:" "${RECENT_VERSIONS[0]}" MC_VERSION
    fi

    # ── Chunky pre-generation config ────────────────────────────────────────────
    local PREGEN_RADIUS=5000
    local USE_BORDER=true
    local BORDER_SIZE=10000
    if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
        echo ""
        log_info "Chunky Pre-Generation"
        echo "Chunky pre-generates chunks around spawn so players exploring new areas"
        echo "won't cause lag spikes. Run once before opening the server to players."
        echo ""
        prompt_text "Pre-generation radius in blocks [5000]:" "5000" PREGEN_RADIUS
        BORDER_SIZE=$(( PREGEN_RADIUS * 2 ))
        echo ""
        local _border=""
        prompt_yn "Set world border at ${BORDER_SIZE} blocks (2× radius)? (y/n) [y]:" "y" _border
        [[ ${_border:-y} =~ ^[Yy]$ ]] && USE_BORDER=true || USE_BORDER=false
    fi

    # ── Networking ──────────────────────────────────────────────────────────────
    echo ""
    log_info "Networking / Remote Access"
    echo ""
    echo "How will players connect from outside your network?"
    echo ""
    echo "  1) Port forward + DNS (recommended)"
    echo "     Forward your Minecraft port on your router, add DNS records."
    echo "     Players connect to mc.yourdomain.com — no port number needed."
    echo "     Full step-by-step instructions generated in MINECRAFT_NETWORKING.md"
    echo ""
    echo "  2) playit.gg tunnel (fallback — use if you cannot port forward)"
    echo "     Free tunnel, no router access needed, works behind CGNAT."
    echo "     All player traffic routes through playit.gg's servers."
    echo "     See their privacy policy: https://playit.gg/privacy-policy/"
    echo ""
    echo "  3) Local only (no external access)"
    echo ""
    local NET_CHOICE=""
    prompt_text "Networking choice [1]:" "1" NET_CHOICE

    local USE_PLAYIT=false
    local USE_PORTFORWARD=false
    case $NET_CHOICE in
        1) USE_PORTFORWARD=true ;;
        2) USE_PLAYIT=true ;;
        3) ;;
    esac

    local MC_DOMAIN=""
    local BASE_DOMAIN=""
    [ -f "$DOCKER_DIR/.config" ] && BASE_DOMAIN=$(grep '^BASE_DOMAIN=' "$DOCKER_DIR/.config" 2>/dev/null | cut -d= -f2-)
    if [ "$USE_PLAYIT" = true ] || [ "$USE_PORTFORWARD" = true ]; then
        if [ -n "$BASE_DOMAIN" ]; then
            local _PREFIX=""
            prompt_text "Subdomain prefix for Minecraft [mc].${BASE_DOMAIN}:" "mc" _PREFIX
            MC_DOMAIN="${_PREFIX}.${BASE_DOMAIN}"
            echo "  → ${MC_DOMAIN}"
        else
            prompt_text "Domain for Minecraft (e.g. mc.yourdomain.com) [leave blank to skip]:" "" MC_DOMAIN
        fi
    fi

    # ── Create directory structure ──────────────────────────────────────────────
    mkdir -p "$MC_DIR"/{data,mods-download,datapacks-download,config}
    ensure_docker_dir_ownership "$MC_DIR"
    # The minecraft server runs as uid=1000; pre-create writable dirs so mods
    # (C2ME, Lithium) can write their config files on first start.
    chown -R 1000:1000 "$MC_DIR/data" "$MC_DIR/config" 2>/dev/null \
        || log_warning "Could not chown minecraft dirs to uid 1000 — if C2ME/Lithium crash on start, run: sudo chown -R 1000:1000 $MC_DIR/data $MC_DIR/config"
    cd "$MC_DIR" || return 1

    # ── Whitelist pre-population ────────────────────────────────────────────────
    local _WL_NEED_WRITE=false
    [ "$WHITELIST_ENABLED" = true ] && \
        [ $(( ${#WHITELIST_PLAYERS[@]} + ${#WHITELIST_PRELOADED[@]} )) -gt 0 ] && \
        _WL_NEED_WRITE=true

    if [ "$_WL_NEED_WRITE" = true ]; then
        log_info "Building whitelist.json..."
        local _WL_JSON="["
        local _WL_FIRST=true
        local _WL_COUNT=0

        # Preloaded entries — UUIDs already known, no API call needed
        local _wl_name _uuid
        for _wl_name in "${!WHITELIST_PRELOADED[@]}"; do
            _uuid="${WHITELIST_PRELOADED[$_wl_name]}"
            log_success "  $_wl_name → $_uuid (from existing whitelist)"
            [ "$_WL_FIRST" = true ] || _WL_JSON+=","
            _WL_FIRST=false
            _WL_COUNT=$((_WL_COUNT + 1))
            _WL_JSON+="
  {\"uuid\": \"$_uuid\", \"name\": \"$_wl_name\"}"
        done

        # New gamertags — look up via Mojang API
        if [ ${#WHITELIST_PLAYERS[@]} -gt 0 ]; then
            log_info "  Looking up UUIDs via Mojang API..."
            local _player _resp _name
            for _player in "${WHITELIST_PLAYERS[@]}"; do
                _resp=$(curl -sf --max-time 10 \
                    "https://api.mojang.com/users/profiles/minecraft/${_player}" 2>/dev/null || echo "")
                if [ -z "$_resp" ]; then
                    log_warning "  '$_player' not found — skipping (account may not exist)"
                    continue
                fi
                _uuid=$(echo "$_resp" | python3 -c "
import sys, json
d = json.load(sys.stdin)
uid = d['id']
print(f'{uid[:8]}-{uid[8:12]}-{uid[12:16]}-{uid[16:20]}-{uid[20:]}')
" 2>/dev/null || echo "")
                _name=$(echo "$_resp" | python3 -c "
import sys, json; d=json.load(sys.stdin); print(d.get('name',''))" 2>/dev/null || echo "$_player")
                if [ -z "$_uuid" ]; then
                    log_warning "  Could not parse UUID for '$_player' — skipping"
                    continue
                fi
                log_success "  $_name → $_uuid"
                [ "$_WL_FIRST" = true ] || _WL_JSON+=","
                _WL_FIRST=false
                _WL_COUNT=$((_WL_COUNT + 1))
                _WL_JSON+="
  {\"uuid\": \"$_uuid\", \"name\": \"$_name\"}"
            done
        fi

        _WL_JSON+="
]"
        echo "$_WL_JSON" > "$MC_DIR/data/whitelist.json"
        chown 1000:1000 "$MC_DIR/data/whitelist.json" 2>/dev/null || true
        log_success "whitelist.json written with $_WL_COUNT player(s)"
    fi

    # ── Fetch mod JARs from Modrinth ────────────────────────────────────────────
    download_modrinth_mod() {
        local slug="$1"
        local label="$2"
        local mc_ver="$3"
        local loader="${4:-fabric}"

        local api_url="https://api.modrinth.com/v2/project/${slug}/version"
        local query="?game_versions=%5B%22${mc_ver}%22%5D&loaders=%5B%22${loader}%22%5D"

        local jar_url
        jar_url=$(curl -sf "${api_url}${query}" \
            | python3 -c "
import sys, json
versions = json.load(sys.stdin)
for v in versions:
    for f in v.get('files', []):
        if f.get('primary'):
            print(f['url'])
            sys.exit(0)
" 2>/dev/null || echo "")

        if [ -z "$jar_url" ]; then
            log_warning "  $label not available for MC $mc_ver yet — skipping (check https://modrinth.com/mod/${slug} for updates)"
            return 1
        fi

        local fname
        fname=$(basename "$jar_url" | cut -d'?' -f1)
        curl -sfL "$jar_url" -o "mods-download/${fname}" \
            && log_success "  Downloaded: $fname" \
            || log_warning "  Failed to download $label"
    }

    if [ "$SUPPORTS_FABRIC_MODS" = true ] && [ ${#SELECTED_MODS[@]} -gt 0 ]; then
        log_info "Downloading mods from Modrinth..."
        local ALWAYS_DEPS=("fabric-api" "fabric-language-kotlin")
        local dep mid
        for dep in "${ALWAYS_DEPS[@]}"; do
            download_modrinth_mod "$dep" "$dep" "$MC_VERSION" || true
        done
        for mod in "${SELECTED_MODS[@]}"; do
            mid="${MOD_MODRINTH_ID[$mod]}"
            download_modrinth_mod "$mid" "${MODS[$mod]}" "$MC_VERSION" || true
        done
    fi

    # ── Vanilla Tweaks datapacks — manual download required ──────────────────────
    if [ "$SUPPORTS_FABRIC_MODS" = true ] && [ ${#SELECTED_DATAPACKS[@]} -gt 0 ]; then
        local VT_VERSION
        VT_VERSION=$(echo "$MC_VERSION" | awk -F. '{if ($1=="1") print $0; else print $1"."$2}')

        echo ""
        log_info "Vanilla Tweaks — download your selected packs manually:"
        echo ""
        echo "  ┌─ Quick start: pre-configured share links (opens VT pre-selected) ─┐"
        echo "  │  Datapacks:       https://vanillatweaks.net/share#B3QqSd           │"
        echo "  │  Crafting tweaks: https://vanillatweaks.net/share#SqzGkO           │"
        echo "  └───────────────────────────────────────────────────────────────────-┘"
        echo ""
        echo "  Or pick manually — go to https://vanillatweaks.net/picker/datapacks/"
        echo "  and select version ${VT_VERSION}, then enable your chosen packs:"
        echo ""
        local _LAST_CAT="" _cat dp
        for dp in "${DPACK_ORDER[@]}"; do
            [[ " ${SELECTED_DATAPACKS[*]} " =~ " ${dp} " ]] || continue
            _cat="${DPACK_CAT[$dp]}"
            if [ "$_cat" != "$_LAST_CAT" ]; then
                echo "       ── ${_cat}"
                _LAST_CAT="$_cat"
            fi
            echo "         • ${DPACKS[$dp]}"
        done
        echo ""
        echo "  ── How to install ────────────────────────────────────────────────────"
        echo "  1. Download the ZIP from vanillatweaks.net (use share link or pick)"
        echo "  2. SCP it to this server (run on your local machine):"
        echo "       scp ~/Downloads/VanillaTweaks*.zip $(whoami)@$(hostname -I | awk '{print $1}'):${MC_DIR}/datapacks-download/"
        echo "  3. On this server:"
        echo "       cd ${MC_DIR}/datapacks-download"
        echo "       unzip 'VanillaTweaks*.zip' && rm VanillaTweaks*.zip"
        echo "  4. Rebuild:  cd ${MC_DIR} && docker compose build"
        echo "  5. Restart:  cd ${MC_DIR} && docker compose up -d"
        echo "  ──────────────────────────────────────────────────────────────────────"
        echo "  The itzg image extracts .zip files from /datapacks/ on startup."
        echo "  Datapacks land in ${MC_NAME}/data/datapacks/ and persist across restarts."
        echo ""
        read -p "  Press Enter when datapacks are in datapacks-download/ (or Enter to skip): "
    fi

    # ── LuckPerms bootstrap script ──────────────────────────────────────────────
    if [[ " ${SELECTED_MODS[*]} " =~ " luckperms " ]]; then
        log_info "Generating LuckPerms bootstrap commands..."
        mkdir -p "$MC_DIR/luckperms-bootstrap"
        cat > "$MC_DIR/luckperms-bootstrap/bootstrap.txt" << 'LPEOF'
# LuckPerms bootstrap — runs once on first server start via startup script
# Groups: default (all players) → mod → admin

lp creategroup mod
lp creategroup admin

# Default player permissions
lp group default permission set essentials.home true
lp group default permission set essentials.sethome true
lp group default permission set essentials.delhome true
lp group default permission set essentials.back true
lp group default permission set essentials.spawn true
lp group default permission set essentials.tpa true
lp group default permission set essentials.tpaccept true
lp group default permission set essentials.tpdeny true
lp group default permission set essentials.warp true

# Mod inherits default
lp group mod parent set default
lp group mod permission set essentials.kick true
lp group mod permission set essentials.mute true
lp group mod permission set essentials.tp true
lp group mod permission set essentials.tphere true
lp group mod permission set ledger.query true

# Admin inherits mod
lp group admin parent set mod
lp group admin permission set luckperms.* true
lp group admin permission set essentials.* true
lp group admin permission set "*" true
LPEOF
        log_success "LuckPerms bootstrap written to ${MC_NAME}/luckperms-bootstrap/bootstrap.txt"
    fi

    # ── Dockerfile ────────────────────────────────────────────────────────────
    log_info "Generating Dockerfile..."
    cat > "$MC_DIR/Dockerfile" << 'MCEOF'
FROM itzg/minecraft-server:latest

# Mods and datapacks are copied in at build time
COPY mods-download/ /mods/
COPY datapacks-download/ /datapacks/
MCEOF

    if [[ " ${SELECTED_MODS[*]} " =~ " luckperms " ]]; then
        echo "COPY luckperms-bootstrap/bootstrap.txt /luckperms-bootstrap.txt" >> "$MC_DIR/Dockerfile"
    fi
    log_success "Dockerfile created"

    # ── pregen-startup.sh ───────────────────────────────────────────────────────
    # Lives inside data/ (bind-mounted to /data). itzg executes /data/*.sh on
    # startup; our guard exits 0 unless PREGEN=1 is set, so normal startup is
    # unaffected. Do NOT COPY into /data (it's a bind-mount) or add extra mounts.
    if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
        [ -e "$MC_DIR/pregen-startup.sh" ] && rm -rf "$MC_DIR/pregen-startup.sh"
        mkdir -p "$MC_DIR/data"
        [ -e "$MC_DIR/data/pregen-startup.sh" ] && [ ! -f "$MC_DIR/data/pregen-startup.sh" ] \
            && rm -rf "$MC_DIR/data/pregen-startup.sh"
        local BORDER_LINE=""
        [ "$USE_BORDER" = true ] && BORDER_LINE="mc-send-to-console \"worldborder set ${BORDER_SIZE}\""
        cat > "$MC_DIR/data/pregen-startup.sh" << PREGENEOF
#!/bin/bash
# Chunky pre-generation — run manually after the server has started:
#   docker exec -e PREGEN=1 -u 1000 ${MC_NAME} bash /data/pregen-startup.sh
[ "\${PREGEN:-0}" = "1" ] || exit 0
_PIPE=/tmp/minecraft-console-in
echo "Waiting for server to be ready (may take 1-2 minutes)..."
_WAIT=0
until [ -p "\$_PIPE" ]; do
    sleep 3
    _WAIT=\$((\$_WAIT + 3))
    if [ \$_WAIT -ge 180 ]; then
        echo "ERROR: Timed out waiting for server (3 min). Is CREATE_CONSOLE_IN_PIPE=true set?"
        exit 1
    fi
done
echo "Server ready. Sending pre-gen commands..."
${BORDER_LINE}
mc-send-to-console "chunky center 0 0"
mc-send-to-console "chunky radius ${PREGEN_RADIUS}"
mc-send-to-console "chunky start"
echo "Pre-gen started. Monitor progress:"
echo "  docker exec ${MC_NAME} mc-send-to-console 'chunky progress'"
PREGENEOF
        chmod +x "$MC_DIR/data/pregen-startup.sh"
        chown 1000:1000 "$MC_DIR/data/pregen-startup.sh" 2>/dev/null || true
        log_success "pregen-startup.sh written to ${MC_NAME}/data/"
    fi

    # ── Standalone docker-compose.yml (per-service folder) ──────────────────────
    log_info "Writing ${MC_NAME}/docker-compose.yml..."

    local MC_ENV=""
    MC_ENV+="      - TYPE=${FLAVOUR}"$'\n'
    MC_ENV+="      - VERSION=${MC_VERSION}"$'\n'
    MC_ENV+="      - EULA=TRUE"$'\n'
    MC_ENV+="      - SERVER_NAME=${SERVER_NAME}"$'\n'
    MC_ENV+="      - MAX_PLAYERS=${MAX_PLAYERS}"$'\n'
    MC_ENV+="      - DIFFICULTY=${DIFFICULTY}"$'\n'
    MC_ENV+="      - MODE=${GAMEMODE}"$'\n'
    MC_ENV+="      - WHITELIST=${WHITELIST_ENABLED}"$'\n'
    MC_ENV+="      - MEMORY=${MC_RAM}G"$'\n'
    MC_ENV+="      - ENABLE_RCON=false"$'\n'
    MC_ENV+="      - MOTD=${SERVER_NAME}"$'\n'
    MC_ENV+="      - CREATE_CONSOLE_IN_PIPE=true"$'\n'
    if [ "$SUPPORTS_FABRIC_MODS" = true ]; then
        MC_ENV+="      - MODS_DIR=/mods"$'\n'
    fi

    # Volumes: data always; config too when chunky is selected.
    local MC_VOLUMES="      - ./data:/data"
    if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
        MC_VOLUMES+="
      - ./config:/data/config"
    fi

    cat > "$MC_DIR/docker-compose.yml" << COMPOSEEOF
name: ${MC_NAME}

services:
  ${MC_NAME}:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${MC_NAME}
    environment:
${MC_ENV}    ports:
      - "${MC_PORT}:25565"
    volumes:
${MC_VOLUMES}
    restart: unless-stopped
COMPOSEEOF

    # Optional playit.gg service appended as a SECOND service into THIS
    # instance's compose (shares the minecraft container's network namespace).
    if [ "$USE_PLAYIT" = true ]; then
        cat >> "$MC_DIR/docker-compose.yml" << PLAYITEOF

  playit-${MC_NAME}:
    image: ghcr.io/playit-cloud/playit-agent:latest
    container_name: playit-${MC_NAME}
    network_mode: "service:${MC_NAME}"
    env_file:
      - ./.env.playit
    restart: unless-stopped
    depends_on:
      - ${MC_NAME}
PLAYITEOF
    fi
    log_success "Created ${MC_NAME}/docker-compose.yml"

    if [ "$USE_PLAYIT" = true ]; then
        cat > "$MC_DIR/.env.playit" << 'ENVEOF'
# Get your secret from https://playit.gg after creating a tunnel
# Then add it here:
PLAYIT_SECRET=your_secret_key_here
ENVEOF
        log_success "Created ${MC_NAME}/.env.playit — add your playit.gg secret after signing up"
    fi

    # ── Client mod download page (own folder + standalone compose) ──────────────
    echo ""
    log_info "Client Mod Download Page"
    echo ""
    echo "A local webpage where your players can download all client mods at once."
    echo ""
    local CM_ENABLE=""
    prompt_yn "Enable client mod download page? (y/n) [y]:" "y" CM_ENABLE
    if [[ ${CM_ENABLE:-y} =~ ^[Yy]$ ]]; then

        local MODS_PORT=""
        prompt_text "Port for download page [8091]:" "8091" MODS_PORT
        local MODS_DOMAIN=""
        if [ -n "$BASE_DOMAIN" ]; then
            local _PREFIX=""
            prompt_text "Subdomain prefix for mod download page [mods].${BASE_DOMAIN}:" "mods" _PREFIX
            MODS_DOMAIN="${_PREFIX}.${BASE_DOMAIN}"
            echo "  → ${MODS_DOMAIN}"
        else
            prompt_text "Subdomain for mod download page (e.g. mods.yourdomain.com) [leave blank to skip]:" "" MODS_DOMAIN
        fi

        # Per-instance folder so multiple servers don't share one mods page.
        local CM_NAME="client-mods"; [ "$MC_NAME" != "minecraft" ] && CM_NAME="client-mods-${MC_NAME}"
        local CLIENT_MODS_DIR="$DOCKER_DIR/$CM_NAME"
        mkdir -p "$CLIENT_MODS_DIR/files"
        ensure_docker_dir_ownership "$CLIENT_MODS_DIR"

        log_info "Downloading client mods from Modrinth..."

        declare -A CMODS
        declare -A CMOD_DESC
        declare -A CMOD_SLUG
        declare -A CMOD_URL

        CMODS["xaeros_minimap"]="Xaero's Minimap"
        CMOD_DESC["xaeros_minimap"]="Corner minimap with waypoints, entity radar, and cave mode."
        CMOD_SLUG["xaeros_minimap"]="xaeros-minimap"
        CMOD_URL["xaeros_minimap"]="https://modrinth.com/mod/xaeros-minimap"

        CMODS["xaeros_worldmap"]="Xaero's World Map"
        CMOD_DESC["xaeros_worldmap"]="Fullscreen map of everywhere you've explored."
        CMOD_SLUG["xaeros_worldmap"]="xaeros-world-map"
        CMOD_URL["xaeros_worldmap"]="https://modrinth.com/mod/xaeros-world-map"

        CMODS["replaymod"]="ReplayMod"
        CMOD_DESC["replaymod"]="Record and replay your game sessions. View replays in cinematic mode."
        CMOD_SLUG["replaymod"]="replaymod"
        CMOD_URL["replaymod"]="https://modrinth.com/mod/replaymod"

        CMODS["nochatreports"]="NoChatReports"
        CMOD_DESC["nochatreports"]="Disables Mojang's chat reporting on the client side."
        CMOD_SLUG["nochatreports"]="no-chat-reports"
        CMOD_URL["nochatreports"]="https://modrinth.com/mod/no-chat-reports"

        CMODS["sodium"]="Sodium"
        CMOD_DESC["sodium"]="Major FPS improvement — the most impactful performance mod available."
        CMOD_SLUG["sodium"]="sodium"
        CMOD_URL["sodium"]="https://modrinth.com/mod/sodium"

        CMODS["iris"]="Iris Shaders"
        CMOD_DESC["iris"]="Shader support that works alongside Sodium."
        CMOD_SLUG["iris"]="iris"
        CMOD_URL["iris"]="https://modrinth.com/mod/iris"

        CMODS["indium"]="Indium"
        CMOD_DESC["indium"]="Sodium compatibility layer — needed by some other mods."
        CMOD_SLUG["indium"]="indium"
        CMOD_URL["indium"]="https://modrinth.com/mod/indium"

        CMODS["fabric_api"]="Fabric API"
        CMOD_DESC["fabric_api"]="Required by almost all Fabric mods. Install this first."
        CMOD_SLUG["fabric_api"]="fabric-api"
        CMOD_URL["fabric_api"]="https://modrinth.com/mod/fabric-api"

        local CMOD_ORDER=("fabric_api" "nochatreports" "sodium" "iris" "indium"
                    "xaeros_minimap" "xaeros_worldmap" "replaymod")

        declare -A CMOD_FILENAME
        declare -A CMOD_FILESIZE

        local key slug name jar_url fname fpath
        for key in "${CMOD_ORDER[@]}"; do
            slug="${CMOD_SLUG[$key]}"
            name="${CMODS[$key]}"

            jar_url=$(curl -sf \
                "https://api.modrinth.com/v2/project/${slug}/version?game_versions=%5B%22${MC_VERSION}%22%5D&loaders=%5B%22fabric%22%5D" \
                | python3 -c "
import sys, json
versions = json.load(sys.stdin)
for v in versions:
    for f in v.get('files', []):
        if f.get('primary'):
            print(f['url'])
            sys.exit(0)
" 2>/dev/null || echo "")

            if [ -z "$jar_url" ]; then
                log_warning "  Could not find $name for MC $MC_VERSION — will link to Modrinth instead"
                CMOD_FILENAME[$key]=""
                CMOD_FILESIZE[$key]=""
                continue
            fi

            fname=$(basename "$jar_url" | cut -d'?' -f1)
            fpath="$CLIENT_MODS_DIR/files/$fname"

            if curl -sfL "$jar_url" -o "$fpath"; then
                log_success "  Downloaded: $fname"
                CMOD_FILENAME[$key]="$fname"
                CMOD_FILESIZE[$key]=$(du -h "$fpath" | cut -f1)
            else
                log_warning "  Failed: $name"
                CMOD_FILENAME[$key]=""
                CMOD_FILESIZE[$key]=""
            fi
        done

        # Essential Mod — not on Modrinth, link to official site
        CMODS["essential"]="Essential Mod"
        CMOD_DESC["essential"]="Invite friends to worlds, cosmetics, social features. Not on Modrinth."
        CMOD_SLUG["essential"]=""
        CMOD_URL["essential"]="https://essential.gg/download"
        CMOD_FILENAME["essential"]=""
        CMOD_FILESIZE["essential"]=""
        CMOD_ORDER+=("essential")

        log_info "Generating client mod download page..."

        local MOD_CARDS="" desc fsize modrinth_url btn
        for key in "${CMOD_ORDER[@]}"; do
            name="${CMODS[$key]}"
            desc="${CMOD_DESC[$key]}"
            fname="${CMOD_FILENAME[$key]}"
            fsize="${CMOD_FILESIZE[$key]}"
            modrinth_url="${CMOD_URL[$key]}"

            if [ -n "$fname" ]; then
                btn="<a class=\"btn\" href=\"/files/${fname}\" download>⬇ Download ${fsize}</a>"
            else
                btn="<a class=\"btn btn-ext\" href=\"${modrinth_url}\" target=\"_blank\">↗ Get from ${modrinth_url##*/}</a>"
            fi

            MOD_CARDS="${MOD_CARDS}
        <div class=\"card\">
            <div class=\"card-name\">${name}</div>
            <div class=\"card-desc\">${desc}</div>
            ${btn}
        </div>"
        done

        log_info "Creating all-mods ZIP..."
        ( cd "$CLIENT_MODS_DIR/files" && \
          zip -q "../all-client-mods-mc${MC_VERSION}.zip" *.jar 2>/dev/null ) \
            && log_success "Created all-client-mods-mc${MC_VERSION}.zip" \
            || log_warning "zip not found or no jars — skipping bundle (install zip: sudo apt install zip)"

        local ZIP_SIZE ZIP_BTN=""
        ZIP_SIZE=$(du -h "$CLIENT_MODS_DIR/all-client-mods-mc${MC_VERSION}.zip" 2>/dev/null | cut -f1 || echo "")
        if [ -n "$ZIP_SIZE" ]; then
            ZIP_BTN="<a class=\"btn btn-all\" href=\"/all-client-mods-mc${MC_VERSION}.zip\" download>⬇ Download All Mods (${ZIP_SIZE} ZIP)</a>"
        fi

        cat > "$CLIENT_MODS_DIR/index.html" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${SERVER_NAME} — Client Mods</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', sans-serif;
            background: #1a1a2e;
            color: #e0e0e0;
            min-height: 100vh;
        }
        header {
            background: #16213e;
            padding: 2rem;
            text-align: center;
            border-bottom: 3px solid #4ecca3;
        }
        header h1 { font-size: 2rem; color: #4ecca3; margin-bottom: 0.5rem; }
        header p  { opacity: 0.8; }
        .hero {
            text-align: center;
            padding: 2rem;
            background: #0f3460;
        }
        .hero p { margin-bottom: 1rem; opacity: 0.9; }
        .btn-all {
            display: inline-block;
            background: #4ecca3;
            color: #1a1a2e;
            font-weight: bold;
            padding: 0.9rem 2rem;
            border-radius: 8px;
            text-decoration: none;
            font-size: 1.1rem;
            transition: opacity 0.2s;
        }
        .btn-all:hover { opacity: 0.85; }
        .instructions {
            max-width: 800px;
            margin: 2rem auto;
            padding: 1.5rem 2rem;
            background: #16213e;
            border-radius: 12px;
            border-left: 4px solid #4ecca3;
        }
        .instructions h2 { color: #4ecca3; margin-bottom: 1rem; }
        .instructions ol  { padding-left: 1.5rem; line-height: 2; }
        .instructions code {
            background: #0f3460;
            padding: 2px 6px;
            border-radius: 4px;
            font-size: 0.9em;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1.5rem;
            max-width: 1200px;
            margin: 2rem auto;
            padding: 0 1.5rem 3rem;
        }
        .card {
            background: #16213e;
            border-radius: 12px;
            padding: 1.5rem;
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
            border: 1px solid #0f3460;
            transition: transform 0.2s, border-color 0.2s;
        }
        .card:hover { transform: translateY(-4px); border-color: #4ecca3; }
        .card-name { font-size: 1.1rem; font-weight: bold; color: #4ecca3; }
        .card-desc { font-size: 0.9rem; opacity: 0.8; flex: 1; }
        .btn {
            display: inline-block;
            background: #4ecca3;
            color: #1a1a2e;
            font-weight: bold;
            padding: 0.5rem 1rem;
            border-radius: 6px;
            text-decoration: none;
            text-align: center;
            font-size: 0.9rem;
            transition: opacity 0.2s;
        }
        .btn:hover { opacity: 0.85; }
        .btn-ext {
            background: #0f3460;
            color: #4ecca3;
            border: 1px solid #4ecca3;
        }
        footer {
            text-align: center;
            padding: 1.5rem;
            opacity: 0.5;
            font-size: 0.85rem;
            border-top: 1px solid #16213e;
        }
    </style>
</head>
<body>
    <header>
        <h1>⛏ ${SERVER_NAME}</h1>
        <p>Client Mods — Minecraft ${MC_VERSION} · Fabric</p>
    </header>

    <div class="hero">
        <p>Download all recommended mods in one click, or pick individually below.</p>
        ${ZIP_BTN}
    </div>

    <div class="instructions">
        <h2>📋 Install Instructions</h2>
        <ol>
            <li>Install <a href="https://fabricmc.net/use/" target="_blank" style="color:#4ecca3">Fabric Loader</a> for Minecraft ${MC_VERSION}</li>
            <li>Download <strong>Fabric API</strong> below (required by all mods)</li>
            <li>Download whichever other mods you want</li>
            <li>Place all <code>.jar</code> files into your <code>.minecraft/mods/</code> folder</li>
            <li>Launch Minecraft with the Fabric profile</li>
        </ol>
    </div>

    <div class="grid">
        ${MOD_CARDS}
    </div>

    <footer>Generated by ubuntu-post-install setup · ${SERVER_NAME}</footer>
</body>
</html>
HTMLEOF
        log_success "Download page created at ${CM_NAME}/index.html"

        mkdir -p "$CLIENT_MODS_DIR/nginx"
        cat > "$CLIENT_MODS_DIR/nginx/nginx.conf" << 'NGINXEOF'
server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;

    # Mod JARs and ZIPs — long cache, force download
    location /files/ {
        add_header Content-Disposition "attachment";
        add_header Cache-Control "public, max-age=86400";
    }
    location ~* \.zip$ {
        add_header Content-Disposition "attachment";
        add_header Cache-Control "public, max-age=86400";
    }

    location / {
        try_files $uri $uri/ /index.html;
        add_header Cache-Control "no-cache";
    }

    gzip on;
    gzip_types text/html text/css application/javascript;
}
NGINXEOF

        cat > "$CLIENT_MODS_DIR/Dockerfile" << 'CLIENTDOCKEREOF'
FROM nginx:alpine
COPY index.html /usr/share/nginx/html/index.html
COPY files/ /usr/share/nginx/html/files/
COPY all-client-mods-*.zip /usr/share/nginx/html/
COPY nginx/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
CLIENTDOCKEREOF

        # Standalone compose for the client-mods page (its own folder).
        cat > "$CLIENT_MODS_DIR/docker-compose.yml" << CMCOMPOSEEOF
name: ${CM_NAME}

services:
  ${CM_NAME}:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ${CM_NAME}
    ports:
      - "${MODS_PORT}:80"
    restart: unless-stopped
CMCOMPOSEEOF
        log_success "Created ${CM_NAME}/docker-compose.yml"

        chown -R "$ACTUAL_USER:$ACTUAL_USER" "$CLIENT_MODS_DIR" 2>/dev/null || true

        # Caddy snippet (the page is a normal HTTP service — Caddy can proxy it)
        if [ -n "$MODS_DOMAIN" ]; then
            local GAMING_SERVER_IP CADDY_IP=""
            GAMING_SERVER_IP=$(hostname -I | awk '{print $1}')
            prompt_text "Gaming server IP as seen from Caddy machine [$GAMING_SERVER_IP]:" "$GAMING_SERVER_IP" CADDY_IP
            echo ""
            log_info "Add to your Caddyfile on the Caddy machine:"
            echo ""
            echo "──────────────────────────────────────────────────"
            cat << CADDYEOF
${MODS_DOMAIN} {
    reverse_proxy ${CADDY_IP}:${MODS_PORT}
}
CADDYEOF
            echo "──────────────────────────────────────────────────"
            echo ""
            echo "Reload: docker exec caddy caddy reload --config /etc/caddy/Caddyfile"
            echo ""
        fi
    fi  # end client mod download page

    # ── Generate CLIENT_MODS.md (into the instance folder) ──────────────────────
    log_info "Generating CLIENT_MODS.md..."
    cat > "$MC_DIR/CLIENT_MODS.md" << 'CLIENTEOF'
# Client Mods for Players

These mods are installed on **your Minecraft client**, not the server.
All are optional but highly recommended for the best experience.

## Required loader
Install [Fabric Loader](https://fabricmc.net/use/) for your Minecraft version,
then install [Fabric API](https://modrinth.com/mod/fabric-api).

## Recommended client mods

| Mod | Download | Notes |
|-----|----------|-------|
| **Xaero's Minimap** | [Modrinth](https://modrinth.com/mod/xaeros-minimap) | Corner minimap with waypoints, entity radar |
| **Xaero's World Map** | [Modrinth](https://modrinth.com/mod/xaeros-world-map) | Fullscreen explored world map |
| **ReplayMod** | [Modrinth](https://modrinth.com/mod/replaymod) | Record and replay game sessions |
| **NoChatReports** | [Modrinth](https://modrinth.com/mod/no-chat-reports) | Disable chat reporting (also on server) |
| **Essential Mod** | [Modrinth](https://modrinth.com/mod/essential) | Invite friends, cosmetics, social features |
| **Sodium** | [Modrinth](https://modrinth.com/mod/sodium) | Major FPS improvement |
| **Iris Shaders** | [Modrinth](https://modrinth.com/mod/iris) | Shader support (works with Sodium) |
| **Indium** | [Modrinth](https://modrinth.com/mod/indium) | Sodium compatibility layer for other mods |

## Notes
- Xaero's Minimap and World Map are **client-only** — they work on any server
  automatically, nothing needed server-side.
- ReplayMod is **client-only** — the server runs ServerReplay to record
  server-side replays, but you view them with ReplayMod on your client.
- Essential Mod's world invite feature works peer-to-peer — both players need it.
- NoChatReports is optional on client when the server already has it, but
  installing it on both gives the strongest protection.
CLIENTEOF
    chown "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR/CLIENT_MODS.md" 2>/dev/null || true
    log_success "CLIENT_MODS.md written"

    # ── Generate MINECRAFT_NETWORKING.md (into the instance folder) ─────────────
    log_info "Generating MINECRAFT_NETWORKING.md..."

    local PORT_NOTE
    if [ "$MC_PORT" = "25565" ]; then
        PORT_NOTE="This server uses the **standard Minecraft port (25565)**."
    else
        PORT_NOTE="This server uses **port ${MC_PORT}** (non-standard)."
    fi

    cat > "$MC_DIR/MINECRAFT_NETWORKING.md" << NETEOF
# Minecraft Server Networking Guide

${PORT_NOTE}
$([ -n "$MC_DOMAIN" ] && echo "Intended domain: **${MC_DOMAIN}**")

---

## How Minecraft server addressing works

Minecraft Java Edition connects to servers using a **host:port** pair.
The default port is **25565**. If you use the default, players just type
your domain and the game connects automatically. If you use any other port,
players would normally have to type \`domain.com:PORT\` — unless you use a
**DNS SRV record**, which hides the port completely. Players always just type
your domain regardless of which port is actually in use.

This means:
- **One server, default port 25565** → simple A record, no SRV needed
- **One server, non-default port** → A record + SRV record
- **Multiple servers, same IP** → each gets its own port and its own SRV record
  Players type different subdomains, never see port numbers

---

## Step 1 — Choose your ports

Each Minecraft server needs its own unique port. Plan these before touching DNS.

| Server | Subdomain players type | Port to use | Notes |
|--------|----------------------|-------------|-------|
| First server | \`mc.yourdomain.com\` | 25565 | Standard port, simplest |
| Second server | \`survival.yourdomain.com\` | 25566 | Non-standard, needs SRV |
| Third server | \`creative.yourdomain.com\` | 25567 | Non-standard, needs SRV |

Your server is configured on port **${MC_PORT}**.

Ports 25565–25570 are the conventional range for multiple Minecraft servers.
Any port from 1024–65535 works as long as nothing else on your server uses it.

Check what's already in use on your server:
\`\`\`bash
sudo ss -tlnp | grep 255
\`\`\`

---

## Step 2 — Port forward on your router

You need one port forward rule per Minecraft server.

1. Find your server's **local IP**:
   \`\`\`bash
   hostname -I | awk '{print \$1}'
   \`\`\`
2. Log into your router — usually **http://192.168.1.1** or **http://192.168.0.1**
   (check the label on your router if unsure)
3. Find **Port Forwarding** — sometimes listed under NAT, Firewall, Virtual Servers,
   or Advanced depending on your router brand
4. Add a rule for each Minecraft server:

   | Field | Value |
   |-------|-------|
   | External port | ${MC_PORT} |
   | Internal IP | your server's local IP |
   | Internal port | ${MC_PORT} |
   | Protocol | TCP |

   For a second server on port 25566, add another rule with 25566 in both port fields.

5. Save and apply. No reboot needed on most routers.

### Common router brands — where to find port forwarding

| Router brand | Path |
|-------------|------|
| Netgear | Advanced → Advanced Setup → Port Forwarding |
| ASUS | WAN → Virtual Server / Port Forwarding |
| TP-Link | Advanced → NAT Forwarding → Port Forwarding |
| Linksys | Security → Apps and Gaming → Port Range Forwarding |
| Eero | (app only) Settings → Network Settings → Reservations & Port Forwarding |
| Google/Nest Wifi | (app only) Settings → Network & General → Advanced Networking → Port Management |
| ISP-provided router | Usually under Firewall or Advanced — check your ISP's support pages |

---

## Step 3 — Point your domain at your server

First find your **public IP**:
\`\`\`bash
curl -s https://api.ipify.org
\`\`\`

⚠️ **Dynamic IP warning:** Most home internet connections change IP occasionally.
If yours does, set up free DDNS (DuckDNS at duckdns.org or No-IP at noip.com)
and use their subdomain as your A record target instead of a raw IP.

### DNS records to add

#### Scenario A — One server on the standard port (25565)

Just an A record. No SRV needed. Players type \`mc.yourdomain.com\` and it works.

\`\`\`
Type:  A
Name:  mc
Value: your.public.ip
TTL:   1 hour (3600)
\`\`\`

Players connect to: \`mc.yourdomain.com\`

---

#### Scenario B — One server on a non-standard port (e.g. ${MC_PORT})

You need both an A record and a SRV record.
Without the SRV record, players would have to type \`mc.yourdomain.com:${MC_PORT}\`.
With the SRV record, they just type \`mc.yourdomain.com\` — the game resolves the port.

\`\`\`
# A record — points the hostname at your IP
Type:  A
Name:  mc
Value: your.public.ip
TTL:   1 hour

# SRV record — tells Minecraft clients which port to use
Type:     SRV
Name:     _minecraft._tcp.mc        (some providers want the full name:
                                     _minecraft._tcp.mc.yourdomain.com)
Priority: 0
Weight:   5
Port:     ${MC_PORT}
Target:   mc.yourdomain.com
TTL:      1 hour
\`\`\`

Players connect to: \`mc.yourdomain.com\`

---

#### Scenario C — Multiple servers on the same IP (most common setup)

One A record pointing to your server, then one SRV record per server.
Each SRV record maps a player-friendly subdomain to a specific port.

\`\`\`
# One A record for the host — all SRV records point here
Type:  A
Name:  mc
Value: your.public.ip
TTL:   1 hour

# Server 1 — survival on port 25565
Type:     SRV
Name:     _minecraft._tcp.survival
Priority: 0
Weight:   5
Port:     25565
Target:   mc.yourdomain.com
TTL:      1 hour

# Server 2 — creative on port 25566
Type:     SRV
Name:     _minecraft._tcp.creative
Priority: 0
Weight:   5
Port:     25566
Target:   mc.yourdomain.com
TTL:      1 hour

# Server 3 — minigames on port 25567
Type:     SRV
Name:     _minecraft._tcp.minigames
Priority: 0
Weight:   5
Port:     25567
Target:   mc.yourdomain.com
TTL:      1 hour
\`\`\`

Players connect to:
- \`survival.yourdomain.com\` → hits port 25565
- \`creative.yourdomain.com\` → hits port 25566
- \`minigames.yourdomain.com\` → hits port 25567

Nobody types a port number. Ever.

---

## Step 4 — Add records at your DNS provider

### GoDaddy

1. Log in → **My Products** → find your domain → click **DNS**
2. Click **Add New Record**

**A record:**
- Type: A
- Name: mc
- Value: your.public.ip
- TTL: 1 hour
- Click Save

**SRV record** (if needed):
- Type: SRV
- Name: \`_minecraft._tcp.mc\` (or whichever subdomain)
- Priority: 0
- Weight: 5
- Port: ${MC_PORT}
- Target: \`mc.yourdomain.com\`
- TTL: 1 hour
- Click Save

Changes propagate in minutes to a few hours.
Official SRV docs: https://uk.godaddy.com/help/add-an-srv-record-19234

---

### Namecheap

Namecheap splits the SRV record across fields in a non-obvious way.
For a subdomain like \`mc11111.yourdomain.com\`, the fields must be:

| Field | Value | |
|-------|-------|-|
| Service | \`_minecraft\` | Always this exact value |
| Protocol | \`_tcp.mc11111\` | ← **the subdomain goes here** |
| Priority | \`0\` | |
| Weight | \`5\` | |
| Port | \`${MC_PORT}\` | |
| Target | \`mc11111.yourdomain.com.\` | Trailing dot optional |
| TTL | Automatic | |

> ⚠️ **This is Namecheap-specific.** Every other registrar puts the subdomain in the
> Name/Host field. Namecheap is the exception — append the subdomain to the **Protocol**
> field instead. Using any other field makes the record look valid but return NXDOMAIN.

**Steps:**

1. Log in → **Domain List** → **Manage** → **Advanced DNS** → **Add New Record**

2. **A record** (always needed):

   | Field | Value |
   |-------|-------|
   | Type | A Record |
   | Host | \`mc11111\` (your chosen subdomain) |
   | Value | your.public.ip |
   | TTL | Automatic |

   Click the ✓ checkmark to save.

3. **SRV record** (needed when port is not 25565):

   Fill in the fields from the main table above, substituting your actual subdomain
   for \`mc11111\` and your port number for \`${MC_PORT}\`.

   Click **Save All Changes**, then wait ~30 minutes for propagation.

**Verify:**
\`\`\`bash
nslookup -type=SRV _minecraft._tcp.mc11111.yourdomain.com
\`\`\`

If it returns NXDOMAIN, recheck the Protocol field — it must read \`_tcp.mc11111\`, not just \`_tcp\`.

**For additional servers** (e.g. \`mc22222\` on a different port):
- A record Host: \`mc22222\`
- SRV Protocol: \`_tcp.mc22222\`
- Each server gets its own unique subdomain and port

Official docs: https://www.namecheap.com/support/knowledgebase/article.aspx/9776/2237/how-to-create-a-srv-record/

---

### Cloudflare

1. Log in → **dash.cloudflare.com** → select your domain → **DNS** → **Records**
2. Click **Add record**

**A record:**
- Type: A
- Name: mc
- IPv4 address: your.public.ip
- Proxy status: **DNS only (grey cloud)** ← critical
- TTL: Auto
- Click Save

⚠️ **Cloudflare proxy (orange cloud) does NOT work for Minecraft.**
Minecraft uses raw TCP on port 25565, not HTTP. The orange cloud only proxies
HTTP/HTTPS traffic. Always use the grey cloud (DNS only) for Minecraft records.

**SRV record** (if needed):
- Type: SRV
- Name: \`_minecraft._tcp.mc\`
- Priority: 0
- Weight: 5
- Port: ${MC_PORT}
- Target: \`mc.yourdomain.com\`
- TTL: Auto
- Click Save

Official docs: https://developers.cloudflare.com/dns/manage-dns-records/how-to/create-dns-records/

---

## Step 5 — Open the port on your server firewall

The router forwards the traffic, but your server's own firewall also needs to allow it.

\`\`\`bash
# Allow your Minecraft port
sudo ufw allow ${MC_PORT}/tcp comment "Minecraft"

# If running multiple servers, add each port
sudo ufw allow 25566/tcp comment "Minecraft server 2"
sudo ufw allow 25567/tcp comment "Minecraft server 3"

sudo ufw reload
sudo ufw status
\`\`\`

---

## Step 6 — Verify everything is working

\`\`\`bash
# Check your A record resolved
dig mc.yourdomain.com A +short

# Check your SRV record (if you added one)
dig _minecraft._tcp.mc.yourdomain.com SRV

# Test raw TCP connectivity to your port
nc -zv mc.yourdomain.com ${MC_PORT}

# Expected output from nc:
# Connection to mc.yourdomain.com ${MC_PORT} port [tcp/*] succeeded!
\`\`\`

If \`dig\` returns your IP but \`nc\` fails, the problem is port forwarding or firewall.
If \`dig\` returns nothing, the problem is the DNS record.
If both work but Minecraft can't connect, check the server is actually running:
\`\`\`bash
cd ${MC_DIR} && docker compose ps
docker logs ${MC_NAME}
\`\`\`

---

## Fallback — playit.gg (if you cannot port forward)

Some ISPs use CGNAT (you share a public IP with many customers) which makes
port forwarding impossible. If \`curl -s https://api.ipify.org\` returns a
different IP than your router's WAN IP, you are behind CGNAT.

In that case, use playit.gg as a free tunnel:

1. Sign up at **https://playit.gg**
2. Create a tunnel → Minecraft Java → set local port to ${MC_PORT}
3. Copy the secret key from your dashboard
4. Add to \`${MC_NAME}/.env.playit\`:
   \`\`\`
   PLAYIT_SECRET=your_secret_key_here
   \`\`\`
5. Restart: \`cd ${MC_DIR} && docker compose up -d\`
6. Players connect to the address shown in your playit.gg dashboard

To use your own domain with playit.gg, add a CNAME record pointing
\`mc.yourdomain.com\` to your playit.gg tunnel address.

Note: playit.gg routes all player traffic through their servers.
See their privacy policy at https://playit.gg/privacy-policy/ before using.

---

## Player Management

### Whitelist

If you enabled the whitelist during setup, only players you explicitly add can join.

**Add a player** (server must be running):
\`\`\`bash
docker exec ${MC_NAME} mc-send-to-console "whitelist add PlayerName"
\`\`\`

**View the whitelist:**
\`\`\`bash
docker exec ${MC_NAME} mc-send-to-console "whitelist list"
\`\`\`

**Remove a player:**
\`\`\`bash
docker exec ${MC_NAME} mc-send-to-console "whitelist remove PlayerName"
\`\`\`

Minecraft resolves the UUID from the username automatically. The whitelist is saved
to \`${MC_NAME}/data/whitelist.json\` and persists across container restarts.

### Get a player's UUID from their username

Only needed if you want to pre-populate \`whitelist.json\` before the server first starts:

\`\`\`bash
curl -s "https://api.mojang.com/users/profiles/minecraft/PLAYERNAME" | \\
  python3 -c "
import sys, json
d = json.load(sys.stdin)
uid = d['id']
print(f'{uid[:8]}-{uid[8:12]}-{uid[12:16]}-{uid[16:20]}-{uid[20:]}')
"
\`\`\`

Example output: \`69a79aa5-a4ef-4a5c-a61f-7ab0e52cdb6a\`

Then edit \`${MC_NAME}/data/whitelist.json\` (create it if missing):
\`\`\`json
[
  {
    "uuid": "69a79aa5-a4ef-4a5c-a61f-7ab0e52cdb6a",
    "name": "PlayerName"
  }
]
\`\`\`

Add one object per player. Start the server after saving — it reads the file on startup.

### Make a player an operator (admin)

\`\`\`bash
docker exec ${MC_NAME} mc-send-to-console "op PlayerName"
\`\`\`

Operators can use all game commands, kick/ban players, and edit server settings in-game.
Remove operator status with \`/deop PlayerName\` in-game or:
\`\`\`bash
docker exec ${MC_NAME} mc-send-to-console "deop PlayerName"
\`\`\`

NETEOF
    chown "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR/MINECRAFT_NETWORKING.md" 2>/dev/null || true
    log_success "MINECRAFT_NETWORKING.md written"

    # Make sure everything under the instance folder is owned correctly, but
    # keep data/config owned by uid 1000 (itzg runs as that user).
    chown -R "$ACTUAL_USER:$ACTUAL_USER" "$MC_DIR" 2>/dev/null || true
    chown -R 1000:1000 "$MC_DIR/data" "$MC_DIR/config" 2>/dev/null || true

    # ── Summary ─────────────────────────────────────────────────────────────────
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "          Minecraft Setup Complete"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    echo "  Instance:    $MC_NAME ($MC_DIR)"
    echo "  Flavour:     $FLAVOUR_NAME $MC_VERSION"
    echo "  Port:        $MC_PORT"
    echo "  Memory:      ${MC_RAM}GB"
    [ -n "$MC_DOMAIN" ] && echo "  Domain:      $MC_DOMAIN"
    if [ "$USE_PLAYIT" = true ]; then
        echo "  Networking:  playit.gg tunnel"
        echo "               → Add your secret to ${MC_NAME}/.env.playit"
    elif [ "$USE_PORTFORWARD" = true ]; then
        echo "  Networking:  Direct port forward"
        echo "               → See ${MC_NAME}/MINECRAFT_NETWORKING.md"
    else
        echo "  Networking:  Local only"
    fi
    echo ""
    echo "  Mods:        ${#SELECTED_MODS[@]} selected"
    if [ ${#SELECTED_DATAPACKS[@]} -gt 0 ]; then
        echo "  Datapacks:   Download from vanillatweaks.net/picker/datapacks/ → MC $MC_VERSION"
        echo "               Place .zip in ${MC_NAME}/datapacks-download/ then rebuild"
    else
        echo "  Datapacks:   none"
    fi
    if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
        echo "  Pre-gen:     ${PREGEN_RADIUS} block radius (~$(( PREGEN_RADIUS / 1000 * 8 ))GB per server)"
        echo "  World border: ${BORDER_SIZE} blocks $([ "$USE_BORDER" = true ] && echo "(enabled)" || echo "(disabled)")"
    fi
    echo ""
    echo "Files written under ${MC_DIR}:"
    echo "  data/ mods-download/ datapacks-download/   Server files and downloaded mods"
    echo "  docker-compose.yml                         Standalone compose (build itzg image)"
    echo "  CLIENT_MODS.md                             What players install on their client"
    echo "  MINECRAFT_NETWORKING.md                    DNS and port forward instructions"
    [ "$USE_PLAYIT" = true ] && echo "  .env.playit                                Add playit.gg secret here"
    echo ""
    echo "── BACKUPS ───────────────────────────────────────────"
    echo ""
    echo "  Protect your world: set up automatic backups of ${MC_NAME}/data with Kopia."
    echo "  Run:  sudo ./setup.sh backup"
    echo ""

    # ── Optional: start server and run pre-gen now ──────────────────────────────
    local START_MC=""
    prompt_yn "Start the Minecraft server now? (first build takes a few minutes) (y/n) [y]:" "y" START_MC
    if [[ ${START_MC:-y} =~ ^[Yy]$ ]]; then
        log_info "Building and starting ${MC_NAME}..."
        if ( cd "$MC_DIR" && docker compose up -d --build ); then
            log_success "${MC_NAME} started"
        else
            log_warning "Failed to build/start ${MC_NAME} — check: cd ${MC_DIR} && docker compose logs"
        fi

        if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
            log_info "Waiting for ${MC_NAME} container to be running..."
            local _WAIT=0
            until docker ps --filter "name=^${MC_NAME}$" --filter "status=running" \
                  --format "{{.Names}}" 2>/dev/null | grep -q "^${MC_NAME}$"; do
                sleep 3
                _WAIT=$((_WAIT + 3))
                if [ $_WAIT -ge 60 ]; then
                    log_warning "Container not yet showing as running — attempting pregen anyway"
                    break
                fi
            done

            echo ""
            log_info "Running chunk pre-generation..."
            log_info "(Waiting for server to finish loading — usually 1-2 minutes...)"
            docker exec -e PREGEN=1 -u 1000 "${MC_NAME}" bash /data/pregen-startup.sh
            echo ""
            log_success "Pre-generation started!"
            echo "  Monitor: docker exec ${MC_NAME} mc-send-to-console 'chunky progress'"
            echo "  Logs:    docker logs -f ${MC_NAME}"
        fi
    else
        echo ""
        log_info "When ready:"
        echo "  cd ${MC_DIR} && docker compose up -d --build"
        if [[ " ${SELECTED_MODS[*]} " =~ " chunky " ]]; then
            echo "  docker exec -e PREGEN=1 -u 1000 ${MC_NAME} bash /data/pregen-startup.sh"
        fi
    fi
    echo ""
}
