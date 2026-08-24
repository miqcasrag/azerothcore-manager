#!/usr/bin/env bash

set -o pipefail

# ============================================================
# ac-modules.sh
#
# Standalone companion to ac-manager.sh. Installs, removes, and
# updates optional AzerothCore modules.
#
# mod-playerbots is also listed here (it's shown first, since
# it's required for the install), but only for its status and a
# "Configure" action that applies the same performance-tuned bot
# settings ac-manager.sh offers during install -- its actual
# install/remove/update lifecycle stays entirely owned by
# ac-manager.sh, since it's a required dependency, not optional.
#
# Installed/removed modules still get picked up automatically by
# ac-manager.sh's existing docker-compose.override.yml (it mounts
# the whole modules/ directory into ac-worldserver, regardless of
# what's inside it) -- this script only manages what's on disk
# under modules/. A rebuild via ac-manager.sh is still required
# after installing, removing, or updating a module.
#
# Usage:
#   ./ac-modules.sh                interactive menu
#   ./ac-modules.sh list           show install status of every module
#   ./ac-modules.sh install <name> clone a module
#   ./ac-modules.sh remove <name>  remove a module
#   ./ac-modules.sh update [name]  update one module, or all installed ones
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

# ============================================================
# Modules
#
# mod-playerbots is NOT in this array on purpose -- it's required
# for the install and is cloned/updated by ac-manager.sh itself.
# It's handled separately (see "mod-playerbots" section below)
# and listed first in the menu, but only for status + Configure.
# ============================================================

MODULES=(
    "mod-ah-bot-plus|https://github.com/NathanHandley/mod-ah-bot-plus.git|master"
    "mod-autobalance|https://github.com/azerothcore/mod-autobalance.git|master"
    "mod-challenge-modes|https://github.com/ZhengPeiRu21/mod-challenge-modes.git|master"
    "mod-individual-progression|https://github.com/ZhengPeiRu21/mod-individual-progression.git|master"
    "mod-dungeon-clear|https://github.com/jrad7/mod-dungeon-clear.git|master"
)

# ============================================================
# Colours / UI (matches ac-manager.sh's look and feel)
# ============================================================

if [[ -t 1 ]]; then
    RESET="\033[0m"
    BOLD="\033[1m"
    DIM="\033[2m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
else
    RESET=""
    BOLD=""
    DIM=""
    GREEN=""
    RED=""
    YELLOW=""
    CYAN=""
fi

clear_screen() {
    clear 2>/dev/null || true
}

header() {
    clear_screen
    echo
    echo -e "${BOLD}AzerothCore Modules${RESET}"
    echo "────────────────────────────────────────"
    echo
}

success() { echo -e "${GREEN}✓${RESET} $1"; }
error()   { echo -e "${RED}✗${RESET} $1"; }
warning() { echo -e "${YELLOW}!${RESET} $1"; }
info()    { echo -e "${CYAN}›${RESET} $1"; }

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ============================================================
# Core validation
# ============================================================

check_core() {

    if [[ ! -d "$CORE_DIR" ]] || [[ ! -f "$CORE_DIR/docker-compose.yml" ]]; then
        error "AzerothCore installation not found at: $CORE_DIR"
        info "Run ac-manager.sh > Install first."
        return 1
    fi

    return 0
}

check_docker() {

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed."
        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose is not installed."
        return 1
    fi

    return 0
}

check_python() {

    if ! command -v python3 >/dev/null 2>&1; then
        error "python3 is required for this but not installed."
        echo
        echo "  sudo apt install python3"
        echo
        return 1
    fi

    return 0
}

compose() {
    (
        cd "$CORE_DIR" || exit 1
        docker compose "$@"
    )
}

get_db_password() {
    compose exec -T \
        ac-database \
        printenv MYSQL_ROOT_PASSWORD \
        2>/dev/null
}

db_query() {
    # $1 = db root password, $2 = SQL (can be multiple ;-separated
    # statements). Prints tab-separated result rows, no headers.
    local password="$1"
    local sql="$2"

    compose exec -T ac-database \
        mysql -uroot -p"$password" -Nse "$sql" \
        2>/dev/null
}

find_module() {

    # Prints "name|repo|branch" for an exact name match, empty if
    # not found. Never matches mod-playerbots -- that one isn't in
    # the array and is out of scope for this script on purpose.
    local wanted="$1"
    local module name

    for module in "${MODULES[@]}"; do
        IFS="|" read -r name _ _ <<< "$module"
        if [[ "$name" == "$wanted" ]]; then
            echo "$module"
            return 0
        fi
    done

    return 1
}

# ============================================================
# SQL duplicate cleanup
#
# AzerothCore's dbimport fails with "Duplicate filename" if the
# same SQL file exists both inside a module's own directory AND
# in data/sql/custom/. This removes any such duplicates so a
# rebuild via ac-manager.sh doesn't choke on it.
# ============================================================

clean_module_sql_duplicates() {

    check_core || return 1

    [[ -d "$CORE_DIR/modules" ]] || return 0

    local module_dir db base file dest cleaned=0

    for module_dir in "$CORE_DIR"/modules/*/; do

        [[ -d "$module_dir" ]] || continue

        for db in auth characters world; do

            for base in \
                "${module_dir}data/sql/${db}/base" \
                "${module_dir}sql/${db}/base"; do

                [[ -d "$base" ]] || continue

                for file in "$base"/*.sql; do

                    [[ -f "$file" ]] || continue

                    dest="$CORE_DIR/data/sql/custom/db_${db}/$(basename "$file")"

                    if [[ -f "$dest" ]]; then
                        rm -f -- "$dest"
                        cleaned=1
                    fi

                done

            done

        done

    done

    if [[ "$cleaned" -eq 1 ]]; then
        success "Removed custom/ SQL files that duplicate module-provided SQL."
        info "Modules are auto-imported by AzerothCore from their own directory."
    fi

    return 0
}

# ============================================================
# Install / remove / update
# ============================================================

do_install() {

    local name="$1" repo="$2" branch="$3"
    local target="$CORE_DIR/modules/$name"

    if [[ -d "$target" ]]; then
        warning "$name is already installed."
        return 0
    fi

    mkdir -p "$CORE_DIR/modules"

    info "Installing $name..."

    if git clone --branch "$branch" "$repo" "$target"; then

        success "$name installed."

        clean_module_sql_duplicates

        local key
        key="$(module_enable_key "$name")"

        if [[ -n "$key" ]]; then

            local conf
            conf="$(ensure_module_conf_containing_key "$target" "$key")"

            if [[ -n "$conf" ]]; then

                sed -i -E "s|^${key//./\\.}[[:space:]]*=.*\$|${key} = 0|" "$conf"

                info "Installed disabled by default ($key = 0)."
                info "Enable it from this module's menu (Enable / Disable) when ready."

            fi

        fi

        warning "A rebuild is required (ac-manager.sh > Rebuild)."

        return 0

    fi

    error "Failed to install $name."

    return 1
}

do_remove() {

    local name="$1"
    local target="$CORE_DIR/modules/$name"

    if [[ ! -d "$target" ]]; then
        warning "$name is not installed."
        return 1
    fi

    rm -rf -- "$target"

    success "$name removed."
    warning "A rebuild is required (ac-manager.sh > Rebuild)."

    return 0
}

do_update_one() {

    local name="$1"
    local target="$CORE_DIR/modules/$name"

    if [[ ! -d "$target/.git" ]]; then
        warning "$name is not installed."
        return 1
    fi

    info "Updating $name..."

    if git -C "$target" pull --ff-only; then
        success "$name updated."
        return 0
    fi

    error "Failed to update $name."

    return 1
}

do_update_all() {

    local module name updated=0

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name _ _ <<< "$module"

        if [[ -d "$CORE_DIR/modules/$name/.git" ]]; then
            do_update_one "$name"
            updated=1
            echo
        fi

    done

    if [[ "$updated" -eq 0 ]]; then
        warning "No modules are installed."
        return 0
    fi

    clean_module_sql_duplicates

    success "Module update completed."
    warning "A rebuild is required (ac-manager.sh > Rebuild)."

    return 0
}

# ============================================================
# mod-playerbots (required -- listed for status/Configure only;
# install/remove/update stay owned by ac-manager.sh)
# ============================================================

PLAYERBOTS_TUNING_KEYS=(
    "AiPlayerbot.DisabledWithoutRealPlayer|1"
    "AiPlayerbot.DisableMoveSplinePath|1"
    "AiPlayerbot.MaxMovementSearchTime|5"
    "AiPlayerbot.AutoGearQualityLimit|4"
    "AiPlayerbot.RandomGearLoweringChance|0.75"
)

playerbots_conf_path() {
    echo "$CORE_DIR/env/dist/etc/modules/playerbots.conf"
}

playerbots_tuning_applied() {

    local conf="$1"
    local entry key target current

    for entry in "${PLAYERBOTS_TUNING_KEYS[@]}"; do

        IFS="|" read -r key target <<< "$entry"

        current="$(
            grep -E "^${key}[[:space:]]*=" "$conf" 2>/dev/null |
            tail -n1 |
            sed -E 's/^[^=]+=[[:space:]]*//'
        )"

        [[ "$current" != "$target" ]] && return 1

    done

    return 0
}

apply_playerbots_tuning() {

    local conf="$1"

    sed -i \
        -e 's|^AiPlayerbot.DisabledWithoutRealPlayer[[:space:]]*=.*$|AiPlayerbot.DisabledWithoutRealPlayer = 1|' \
        -e 's|^AiPlayerbot.DisableMoveSplinePath[[:space:]]*=.*$|AiPlayerbot.DisableMoveSplinePath = 1|' \
        -e 's|^AiPlayerbot.MaxMovementSearchTime[[:space:]]*=.*$|AiPlayerbot.MaxMovementSearchTime = 5|' \
        -e 's|^AiPlayerbot.AutoGearQualityLimit[[:space:]]*=.*$|AiPlayerbot.AutoGearQualityLimit = 4|' \
        -e 's|^AiPlayerbot.RandomGearLoweringChance[[:space:]]*=.*$|AiPlayerbot.RandomGearLoweringChance = 0.75|' \
        "$conf"
}

cmd_playerbots_configure() {

    header
    echo "Performance-Tuned Bot Settings (mod-playerbots)"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }

    if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        error "mod-playerbots is not installed."
        info "It's installed automatically by ac-manager.sh > Install."
        pause
        return 1
    fi

    local conf
    conf="$(playerbots_conf_path)"

    if [[ ! -f "$conf" ]]; then
        error "playerbots.conf not found at: $conf"
        info "Run ac-manager.sh > Install (or Update) first."
        pause
        return 1
    fi

    if playerbots_tuning_applied "$conf"; then
        success "Recommended performance-tuned bot settings are already applied."
        pause
        return 0
    fi

    info "These recommended settings are not applied yet:"
    echo
    echo "    AiPlayerbot.DisabledWithoutRealPlayer = 1"
    echo "    AiPlayerbot.DisableMoveSplinePath     = 1"
    echo "    AiPlayerbot.MaxMovementSearchTime     = 5"
    echo "    AiPlayerbot.AutoGearQualityLimit      = 4"
    echo "    AiPlayerbot.RandomGearLoweringChance  = 0.75"
    echo

    if confirm "Apply them now?"; then

        apply_playerbots_tuning "$conf"

        success "Performance-tuned bot settings applied."
        warning "Restart ac-worldserver for the change to take effect."

    fi

    pause
}

cmd_playerbots_randombots() {

    header
    echo "Random Bot Count (mod-playerbots)"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }

    if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        error "mod-playerbots is not installed."
        info "It's installed automatically by ac-manager.sh > Install."
        pause
        return 1
    fi

    local conf
    conf="$(playerbots_conf_path)"

    if [[ ! -f "$conf" ]]; then
        error "playerbots.conf not found at: $conf"
        info "Run ac-manager.sh > Install (or Update) first."
        pause
        return 1
    fi

    local current_min current_max
    current_min="$(grep -E '^AiPlayerbot\.MinRandomBots[[:space:]]*=' "$conf" | tail -n1 | sed -E 's/^[^=]+=[[:space:]]*//; s/[[:space:]]+$//')"
    current_max="$(grep -E '^AiPlayerbot\.MaxRandomBots[[:space:]]*=' "$conf" | tail -n1 | sed -E 's/^[^=]+=[[:space:]]*//; s/[[:space:]]+$//')"

    info "Current: MinRandomBots = ${current_min:-?}, MaxRandomBots = ${current_max:-?}"
    echo

    local new_min new_max

    read -r -p "New MinRandomBots (blank to keep ${current_min:-?}): " new_min
    read -r -p "New MaxRandomBots (blank to keep ${current_max:-?}): " new_max

    [[ -z "$new_min" ]] && new_min="$current_min"
    [[ -z "$new_max" ]] && new_max="$current_max"

    if ! [[ "$new_min" =~ ^[0-9]+$ ]] || ! [[ "$new_max" =~ ^[0-9]+$ ]]; then
        error "Both values must be plain numbers."
        pause
        return 1
    fi

    if (( new_min > new_max )); then
        error "MinRandomBots ($new_min) can't be greater than MaxRandomBots ($new_max)."
        pause
        return 1
    fi

    echo
    confirm "Set MinRandomBots = $new_min, MaxRandomBots = $new_max?" || {
        pause
        return
    }

    sed -i \
        -e "s|^AiPlayerbot.MinRandomBots[[:space:]]*=.*\$|AiPlayerbot.MinRandomBots = ${new_min}|" \
        -e "s|^AiPlayerbot.MaxRandomBots[[:space:]]*=.*\$|AiPlayerbot.MaxRandomBots = ${new_max}|" \
        "$conf"

    success "MinRandomBots = $new_min, MaxRandomBots = $new_max."
    warning "Restart ac-worldserver for the change to take effect."

    pause
}

playerbots_configure_menu() {

    while true; do

        header
        echo "Configure mod-playerbots"
        echo "────────────────────────────────────────"
        echo

        echo "  1  Performance-tuned bot settings"
        echo "  2  Random bot count (Min/MaxRandomBots)"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) cmd_playerbots_configure ;;
            2) cmd_playerbots_randombots ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

playerbots_detail_menu() {

    while true; do

        header
        echo "mod-playerbots"
        echo "────────────────────────────────────────"
        echo

        if [[ -d "$CORE_DIR/modules/mod-playerbots" ]]; then
            echo -e "Status   ${GREEN}● installed${RESET} (required, managed by ac-manager.sh)"
        else
            echo -e "Status   ${RED}○ not installed${RESET} (run ac-manager.sh > Install)"
        fi

        echo
        echo "  1  Enable / Disable"
        echo "  2  Configure"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1)
                local conf
                conf="$(playerbots_conf_path)"
                if [[ ! -f "$conf" ]]; then
                    error "playerbots.conf not found at: $conf"
                    info "Run ac-manager.sh > Install (or Update) first."
                    pause
                else
                    toggle_single_key "mod-playerbots" "$conf" "AiPlayerbot.Enabled"
                fi
                ;;
            2) playerbots_configure_menu ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

module_status() {

    printf "  %-2s %-30s " "1" "mod-playerbots"

    if [[ -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        echo -e "${GREEN}● installed${RESET} (required)"
    else
        echo -e "${RED}○ not installed${RESET}"
    fi

    local number=2 module name

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name _ _ <<< "$module"

        printf "  %-2s %-30s " "$number" "$name"

        if [[ -d "$CORE_DIR/modules/$name" ]]; then
            echo -e "${GREEN}● installed${RESET}"
        else
            echo -e "${DIM}○ not installed${RESET}"
        fi

        number=$((number + 1))

    done
}

# ============================================================
# Interactive menu
# ============================================================

# ============================================================
# Enable / Disable
#
# Only these modules actually have a working Enable/Enabled
# setting in their config -- the rest are always on once
# installed and can't be toggled via their .conf. mod-playerbots
# isn't in this map: it's handled separately (see the
# mod-playerbots section above), since its lifecycle stays with
# ac-manager.sh.
# ============================================================

module_enable_key() {
    # Prints the module's Enable key, or nothing if it doesn't
    # support one.
    case "$1" in
        mod-autobalance)             echo "AutoBalance.Enable.Global" ;;
        mod-challenge-modes)         echo "ChallengeModes.Enable" ;;
        mod-individual-progression)  echo "IndividualProgression.Enable" ;;
        *)                           echo "" ;;
    esac
}

find_dist_files() {
    # $1 = module directory. Prints every *.conf.dist found under it.
    find "$1" -maxdepth 3 -type f -name '*.conf.dist' 2>/dev/null
}

ensure_conf_for_dist() {

    # $1 = path to a *.conf.dist file. Ensures the matching .conf
    # exists under env/dist/etc/modules/ (copied from .dist if
    # missing, existing one left untouched) and prints its path.

    local dist_file="$1"
    local config_dir="$CORE_DIR/env/dist/etc/modules"
    local base
    base="$(basename "$dist_file" .dist)"

    mkdir -p "$config_dir"

    [[ -f "$config_dir/$base" ]] || cp -f "$dist_file" "$config_dir/$base"

    echo "$config_dir/$base"
}

ensure_module_conf_containing_key() {

    # $1 = module directory, $2 = key to look for. Prints the path
    # of the .conf (already ensured to exist) that contains it.

    local module_dir="$1" key="$2"
    local dist conf

    while IFS= read -r dist; do

        [[ -z "$dist" ]] && continue

        conf="$(ensure_conf_for_dist "$dist")"

        if grep -qE "^${key//./\\.}[[:space:]]*=" "$conf" 2>/dev/null; then
            echo "$conf"
            return 0
        fi

    done < <(find_dist_files "$module_dir")

    return 1
}

toggle_single_key() {

    # $1 = title (for display), $2 = conf path, $3 = key.

    local title="$1" conf="$2" key="$3"
    local current

    current="$(
        grep -E "^${key//./\\.}[[:space:]]*=" "$conf" 2>/dev/null |
        tail -n1 |
        sed -E 's/^[^=]+=[[:space:]]*//; s/[[:space:]]+$//'
    )"

    header
    echo "Enable / Disable: $title"
    echo "────────────────────────────────────────"
    echo
    echo "  $key = $current"
    echo

    local new_value

    if [[ "$current" == "1" ]]; then
        new_value="0"
    elif [[ "$current" == "0" ]]; then
        new_value="1"
    else
        read -r -p "Current value is '$current'. New value: " new_value
        if [[ -z "$new_value" ]]; then
            warning "No change made."
            pause
            return
        fi
    fi

    if confirm "Set $key = $new_value?"; then

        sed -i -E "s|^${key//./\\.}[[:space:]]*=.*\$|${key} = ${new_value}|" "$conf"

        success "$key set to $new_value."
        warning "Restart ac-worldserver for the change to take effect."

    fi

    pause
}

module_toggle_menu() {

    local name="$1"
    local key
    key="$(module_enable_key "$name")"

    if [[ -z "$key" ]]; then
        warning "$name doesn't support Enable/Disable via its config --"
        info "it's always on once installed."
        pause
        return
    fi

    if [[ ! -d "$CORE_DIR/modules/$name" ]]; then
        warning "$name is not installed."
        pause
        return
    fi

    local conf
    conf="$(ensure_module_conf_containing_key "$CORE_DIR/modules/$name" "$key")"

    if [[ -z "$conf" ]]; then
        error "Could not find '$key' in $name's config."
        pause
        return
    fi

    toggle_single_key "$name" "$conf" "$key"
}

module_detail_menu() {

    local name="$1" repo="$2" branch="$3"

    while true; do

        header
        echo "$name"
        echo "────────────────────────────────────────"
        echo

        if [[ -d "$CORE_DIR/modules/$name" ]]; then
            echo -e "Status   ${GREEN}● installed${RESET}"
        else
            echo -e "Status   ${DIM}○ not installed${RESET}"
        fi

        echo

        local next=1 enable_num="" install_num="" remove_num="" update_num="" configure_num="" key
        key="$(module_enable_key "$name")"

        if [[ -n "$key" ]]; then
            enable_num=$next
            echo "  $next  Enable / Disable"
            next=$((next + 1))
        fi

        install_num=$next
        echo "  $next  Install"
        next=$((next + 1))

        remove_num=$next
        echo "  $next  Remove"
        next=$((next + 1))

        update_num=$next
        echo "  $next  Update"
        next=$((next + 1))

        if [[ "$name" == "mod-ah-bot-plus" ]]; then
            configure_num=$next
            echo "  $next  Configure (auction house bot account/character)"
            next=$((next + 1))
        fi

        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice

        if [[ "$choice" == "0" ]]; then

            return

        elif [[ -n "$enable_num" ]] && [[ "$choice" == "$enable_num" ]]; then

            module_toggle_menu "$name"

        elif [[ "$choice" == "$install_num" ]]; then

            echo
            confirm "Install $name?" && do_install "$name" "$repo" "$branch"
            pause

        elif [[ "$choice" == "$remove_num" ]]; then

            if [[ ! -d "$CORE_DIR/modules/$name" ]]; then
                warning "$name is not installed."
                pause
                continue
            fi
            echo
            warning "This will remove:"
            echo "  $CORE_DIR/modules/$name"
            echo
            confirm "Continue?" && do_remove "$name"
            pause

        elif [[ "$choice" == "$update_num" ]]; then

            echo
            do_update_one "$name"
            clean_module_sql_duplicates
            pause

        elif [[ -n "$configure_num" ]] && [[ "$choice" == "$configure_num" ]]; then

            cmd_ahbot_setup

        else

            error "Invalid selection."
            sleep 1

        fi

    done
}

menu() {

    while true; do

        header

        check_core || { pause; return; }

        module_status

        local update_all_num=$(( ${#MODULES[@]} + 2 ))

        echo
        echo "  $update_all_num  Update all installed modules"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        if [[ "$choice" == "0" ]]; then

            return

        elif [[ "$choice" == "1" ]]; then

            playerbots_detail_menu

        elif [[ "$choice" == "$update_all_num" ]]; then

            header
            echo "Update modules"
            echo "────────────────────────────────────────"
            echo
            do_update_all
            pause

        elif [[ "$choice" =~ ^[1-9][0-9]*$ ]] && (( choice >= 2 && choice <= ${#MODULES[@]} + 1 )); then

            local name repo branch
            IFS="|" read -r name repo branch <<< "${MODULES[$((choice - 2))]}"

            module_detail_menu "$name" "$repo" "$branch"

        else

            error "Invalid selection."
            sleep 1

        fi

    done
}

# ============================================================
# mod-ah-bot-plus setup
#
# Creates (or reuses) a dedicated account to act as the auction
# house seller, then -- once you've created a character named
# "Ahbot" on that account yourself, using the WoW client -- looks
# up its GUID and writes it into mod_ahbot.conf.
#
# Two steps, on purpose:
#   1. The account ("ahbot" / "ahbot") is created with direct SQL
#      using a real SRP6 verifier -- this is how every AzerothCore
#      web account panel does it, perfectly safe.
#   2. The CHARACTER is never created via SQL. Inserting a
#      character directly into the characters table was tried and
#      crashed the worldserver, so this script only searches for
#      one you've already created normally (log in with the
#      client, account "ahbot" / password "ahbot", create a
#      character named "Ahbot"). If it's not there yet, this just
#      tells you so and stops -- run it again after you've made it.
# ============================================================

AHBOT_ACCOUNT_NAME="ahbot"
AHBOT_ACCOUNT_PASSWORD="ahbot"
AHBOT_CHARACTER_NAME="Ahbot"

generate_srp6() {

    # $1 = username, $2 = password. Prints "<salt_hex> <verifier_hex>".
    # Implements AzerothCore's documented SRP6 verifier algorithm
    # (https://www.azerothcore.org/wiki/account#verifier):
    #   h1 = SHA1("USERNAME:PASSWORD")
    #   h2 = SHA1(salt || h1)          (salt, h1 as raw bytes)
    #   verifier = (g ^ h2) % N        (h2 as little-endian integer)
    # g and N are WoW's fixed SRP6 parameters.

    python3 - "$1" "$2" << 'PY'
import hashlib
import os
import sys

username = sys.argv[1].upper()
password = sys.argv[2].upper()

N = int("894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7", 16)
g = 7

salt = os.urandom(32)
h1 = hashlib.sha1(f"{username}:{password}".encode()).digest()
h2 = hashlib.sha1(salt + h1).digest()
h2_int = int.from_bytes(h2, byteorder="little")
verifier_int = pow(g, h2_int, N)
verifier = verifier_int.to_bytes(32, byteorder="little")

print(salt.hex(), verifier.hex())
PY
}

ensure_ahbot_account() {

    # Prints the account id on success (stdout), nothing on failure.

    local password="$1"
    local existing_id

    existing_id="$(db_query "$password" \
        "SELECT id FROM acore_auth.account WHERE UPPER(username) = UPPER('${AHBOT_ACCOUNT_NAME}');")"

    if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
        success "Account '${AHBOT_ACCOUNT_NAME}' already exists (id ${existing_id}) -- reusing it." >&2
        echo "$existing_id"
        return 0
    fi

    check_python || return 1

    local srp salt_hex verifier_hex
    srp="$(generate_srp6 "$AHBOT_ACCOUNT_NAME" "$AHBOT_ACCOUNT_PASSWORD")"
    salt_hex="${srp%% *}"
    verifier_hex="${srp##* }"

    if [[ -z "$salt_hex" ]] || [[ -z "$verifier_hex" ]] || [[ "$salt_hex" == "$verifier_hex" ]]; then
        error "Failed to generate account credentials." >&2
        return 1
    fi

    db_query "$password" \
        "INSERT INTO acore_auth.account (username, salt, verifier, reg_mail, email, joindate)
         VALUES ('${AHBOT_ACCOUNT_NAME}', UNHEX('${salt_hex}'), UNHEX('${verifier_hex}'), '', '', NOW());" \
        >/dev/null

    existing_id="$(db_query "$password" \
        "SELECT id FROM acore_auth.account WHERE UPPER(username) = UPPER('${AHBOT_ACCOUNT_NAME}');")"

    if [[ ! "$existing_id" =~ ^[0-9]+$ ]]; then
        error "Failed to create account." >&2
        return 1
    fi

    success "Account '${AHBOT_ACCOUNT_NAME}' created (id ${existing_id})." >&2
    echo "$existing_id"

    return 0
}

find_ahbot_character() {

    # $1 = account id. Prints the character guid, or nothing if it
    # doesn't exist yet. Never creates anything.

    local password="$1"
    local account_id="$2"

    db_query "$password" \
        "SELECT guid FROM acore_characters.characters
         WHERE UPPER(name) = UPPER('${AHBOT_CHARACTER_NAME}') AND account = ${account_id};"
}

write_ahbot_config() {

    local guid="$1"
    local source="$CORE_DIR/modules/mod-ah-bot-plus"
    local config_dir="$CORE_DIR/env/dist/etc/modules"
    local dist_file="$source/conf/mod_ahbot.conf.dist"

    if [[ ! -f "$dist_file" ]]; then
        error "mod_ahbot.conf.dist not found at: $dist_file"
        return 1
    fi

    mkdir -p "$config_dir"

    cp -f "$dist_file" "$config_dir/mod_ahbot.conf.dist"

    if [[ ! -f "$config_dir/mod_ahbot.conf" ]]; then
        cp -f "$dist_file" "$config_dir/mod_ahbot.conf"
    fi

    local conf="$config_dir/mod_ahbot.conf"

    if grep -q '^AuctionHouseBot.GUIDs' "$conf"; then
        sed -i "s|^AuctionHouseBot.GUIDs.*\$|AuctionHouseBot.GUIDs = ${guid}|" "$conf"
    else
        echo "AuctionHouseBot.GUIDs = ${guid}" >> "$conf"
    fi

    if grep -q '^AuctionHouseBot.EnableSeller' "$conf"; then
        sed -i "s|^AuctionHouseBot.EnableSeller.*\$|AuctionHouseBot.EnableSeller = true|" "$conf"
    else
        echo "AuctionHouseBot.EnableSeller = true" >> "$conf"
    fi

    success "mod_ahbot.conf updated: GUIDs = ${guid}, EnableSeller = true"

    return 0
}

cmd_ahbot_setup() {

    header

    echo "Configure mod-ah-bot-plus"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }

    if [[ ! -d "$CORE_DIR/modules/mod-ah-bot-plus" ]]; then
        error "mod-ah-bot-plus is not installed."
        info "Install it first: Install module > mod-ah-bot-plus."
        pause
        return 1
    fi

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read the database password."
        pause
        return 1
    fi

    local account_id
    account_id="$(ensure_ahbot_account "$password")" || { pause; return 1; }

    echo

    local guid
    guid="$(find_ahbot_character "$password" "$account_id")"

    if [[ ! "$guid" =~ ^[0-9]+$ ]]; then

        warning "Character '${AHBOT_CHARACTER_NAME}' doesn't exist yet on account '${AHBOT_ACCOUNT_NAME}'."
        echo
        info "Next step (one-time, done manually):"
        info "  1. Log into the WoW client with:"
        info "       account:  ${AHBOT_ACCOUNT_NAME}"
        info "       password: ${AHBOT_ACCOUNT_PASSWORD}"
        info "  2. Create a character named '${AHBOT_CHARACTER_NAME}' (any race/class)."
        info "  3. Log out, then run Configure again to finish."
        pause
        return 0

    fi

    success "Character '${AHBOT_CHARACTER_NAME}' found (guid ${guid})."
    echo

    write_ahbot_config "$guid" || { pause; return 1; }

    echo
    success "mod-ah-bot-plus is configured."
    warning "A rebuild + restart is required (ac-manager.sh > Rebuild)."

    pause
}

usage() {
    echo "Usage: $(basename "$0") [list|install <name>|remove <name>|update [name]|ahbot]"
    echo
    echo "  (no argument)   interactive menu"
    echo "  list            show install status of every module"
    echo "  install <name>  clone a module"
    echo "  remove <name>   remove a module"
    echo "  update [name]   update one module, or every installed module if omitted"
    echo "  ahbot           configure mod-ah-bot-plus (creates/reuses its account + character)"
    echo
    echo "Available modules:"

    local module name
    for module in "${MODULES[@]}"; do
        IFS="|" read -r name _ _ <<< "$module"
        echo "  - $name"
    done
}

# ============================================================
# Entry point
# ============================================================

case "${1:-menu}" in

    menu)
        menu
        ;;

    ahbot)
        cmd_ahbot_setup
        ;;

    list)
        check_core || exit 1
        header
        module_status
        ;;

    install)

        check_core || exit 1

        if [[ -z "${2:-}" ]]; then
            error "Usage: $(basename "$0") install <name>"
            exit 1
        fi

        module="$(find_module "$2")" || {
            error "Unknown module: $2"
            exit 1
        }

        IFS="|" read -r name repo branch <<< "$module"
        do_install "$name" "$repo" "$branch"
        ;;

    remove)

        check_core || exit 1

        if [[ -z "${2:-}" ]]; then
            error "Usage: $(basename "$0") remove <name>"
            exit 1
        fi

        find_module "$2" >/dev/null || {
            error "Unknown module: $2"
            exit 1
        }

        do_remove "$2"
        ;;

    update)

        check_core || exit 1

        if [[ -n "${2:-}" ]]; then

            find_module "$2" >/dev/null || {
                error "Unknown module: $2"
                exit 1
            }

            do_update_one "$2"

        else

            do_update_all

        fi
        ;;

    -h|--help)
        usage
        ;;

    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;

esac
