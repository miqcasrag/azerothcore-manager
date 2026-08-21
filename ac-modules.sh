#!/usr/bin/env bash

set -o pipefail

# ============================================================
# ac-modules.sh
#
# Standalone companion to ac-manager.sh. Installs, removes, and
# updates optional AzerothCore modules (anything other than
# mod-playerbots, which is required for the install and stays
# managed entirely by ac-manager.sh itself).
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
# mod-playerbots is NOT here on purpose -- it's required for the
# install and is cloned/updated by ac-manager.sh itself.
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

module_status() {

    local module name

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name _ _ <<< "$module"

        printf "  %-30s " "$name"

        if [[ -d "$CORE_DIR/modules/$name" ]]; then
            echo -e "${GREEN}● installed${RESET}"
        else
            echo -e "${DIM}○ not installed${RESET}"
        fi

    done
}

# ============================================================
# Interactive menu
# ============================================================

module_install_menu() {

    header
    echo "Install module"
    echo "────────────────────────────────────────"
    echo

    local number=1 module name

    for module in "${MODULES[@]}"; do
        IFS="|" read -r name _ _ <<< "$module"
        echo "  $number  $name"
        number=$((number + 1))
    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice < 1 || choice > ${#MODULES[@]} )); then
        error "Invalid selection."
        pause
        return
    fi

    local repo branch
    IFS="|" read -r name repo branch <<< "${MODULES[$((choice - 1))]}"

    echo

    confirm "Install $name?" && do_install "$name" "$repo" "$branch"

    pause
}

module_remove_menu() {

    header
    echo "Remove module"
    echo "────────────────────────────────────────"
    echo

    local number=1 module name

    for module in "${MODULES[@]}"; do
        IFS="|" read -r name _ _ <<< "$module"
        echo "  $number  $name"
        number=$((number + 1))
    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[1-9][0-9]*$ ]] || (( choice < 1 || choice > ${#MODULES[@]} )); then
        error "Invalid selection."
        pause
        return
    fi

    IFS="|" read -r name _ _ <<< "${MODULES[$((choice - 1))]}"

    local target="$CORE_DIR/modules/$name"

    if [[ ! -d "$target" ]]; then
        warning "$name is not installed."
        pause
        return
    fi

    echo
    warning "This will remove:"
    echo "  $target"
    echo

    confirm "Continue?" && do_remove "$name"

    pause
}

module_update_menu() {

    header
    echo "Update modules"
    echo "────────────────────────────────────────"
    echo

    do_update_all

    pause
}

menu() {

    while true; do

        header

        check_core || { pause; return; }

        module_status

        echo
        echo "  1  Install module"
        echo "  2  Remove module"
        echo "  3  Update all installed modules"
        echo "  4  Configure mod-ah-bot-plus (auction house bot)"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) module_install_menu ;;
            2) module_remove_menu ;;
            3) module_update_menu ;;
            4) cmd_ahbot_setup ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# mod-ah-bot-plus setup
#
# Creates (or reuses) a dedicated account + character to act as
# the auction house seller, then writes its GUID into
# mod_ahbot.conf and enables the seller.
#
# EXPERIMENTAL: the account is created the fully-supported way
# (direct SQL with a real SRP6 verifier -- this is how every
# AzerothCore web account panel does it, perfectly safe).
#
# The CHARACTER, however, is created by inserting directly into
# the characters table instead of the officially documented way
# (log in with the client and create it normally). This is NOT
# how AzerothCore's own docs recommend doing it -- every official
# source (AzerothCore, TrinityCore, the module's own README) says
# to create the character via the client. Direct insertion is
# used here because it was explicitly requested; if the
# worldserver misbehaves after this, the safe fix is:
#   DELETE FROM acore_characters.characters WHERE name = 'Ahbot';
#   DELETE FROM acore_characters.character_homebind WHERE guid = <that guid>;
# and create the character normally instead.
# ============================================================

AHBOT_ACCOUNT_NAME="AHBOT"
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
        "SELECT id FROM acore_auth.account WHERE username = '${AHBOT_ACCOUNT_NAME}';")"

    if [[ "$existing_id" =~ ^[0-9]+$ ]]; then
        success "Account '${AHBOT_ACCOUNT_NAME}' already exists (id ${existing_id}) -- reusing it." >&2
        echo "$existing_id"
        return 0
    fi

    check_python || return 1

    local login_password srp salt_hex verifier_hex
    login_password="$(openssl rand -hex 16 2>/dev/null || date +%s%N)"

    srp="$(generate_srp6 "$AHBOT_ACCOUNT_NAME" "$login_password")"
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
        "SELECT id FROM acore_auth.account WHERE username = '${AHBOT_ACCOUNT_NAME}';")"

    if [[ ! "$existing_id" =~ ^[0-9]+$ ]]; then
        error "Failed to create account." >&2
        return 1
    fi

    success "Account '${AHBOT_ACCOUNT_NAME}' created (id ${existing_id})." >&2
    echo "$existing_id"

    return 0
}

ensure_ahbot_character() {

    # $1 = account id. Prints the character guid on success.

    local password="$1"
    local account_id="$2"
    local existing_guid

    existing_guid="$(db_query "$password" \
        "SELECT guid FROM acore_characters.characters WHERE name = '${AHBOT_CHARACTER_NAME}';")"

    if [[ "$existing_guid" =~ ^[0-9]+$ ]]; then
        success "Character '${AHBOT_CHARACTER_NAME}' already exists (guid ${existing_guid}) -- reusing it." >&2
        echo "$existing_guid"
        return 0
    fi

    warning "Creating '${AHBOT_CHARACTER_NAME}' directly in the database (experimental)." >&2

    # Human Warrior, positioned at Northshire Abbey (Elwynn Forest).
    # Never meant to log in -- this is purely an identity for the
    # auction house bot to post/bid under.
    db_query "$password" "
        START TRANSACTION;
        SET @newguid = (SELECT COALESCE(MAX(guid),0)+1 FROM acore_characters.characters);
        INSERT INTO acore_characters.characters (
            guid, account, name, race, class, gender, level, xp, money,
            skin, face, hairStyle, hairColor, facialStyle,
            bankSlots, restState, playerflags,
            position_x, position_y, position_z, map, instance_id, instance_mode_mask, orientation,
            taximask, online, cinematic, totaltime, leveltime, logout_time, is_logout_resting,
            rest_bonus, resettalents_cost, resettalents_time,
            trans_x, trans_y, trans_z, trans_o, transguid,
            extra_flags, stable_slots, at_login, zone, death_expire_time,
            arenaPoints, totalHonorPoints, todayHonorPoints, yesterdayHonorPoints,
            totalKills, todayKills, yesterdayKills, chosenTitle, knownCurrencies,
            watchedFaction, drunk, health, power1, power2, power3, power4, power5, power6, power7,
            latency, talentGroupsCount, activeTalentGroup, ammoId, actionBars,
            grantableLevels, creation_date, innTriggerId, extraBonusTalentCount
        ) VALUES (
            @newguid, ${account_id}, '${AHBOT_CHARACTER_NAME}', 1, 1, 0, 1, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0,
            -8949.95, -132.493, 83.5312, 0, 0, 0, 0,
            '0', 0, 1, 0, 0, 0, 0,
            0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 0, 12, 0,
            0, 0, 0, 0,
            0, 0, 0, 0, 0,
            0, 0, 50, 0, 0, 0, 0, 0, 0, 0,
            0, 1, 0, 0, 1,
            0, NOW(), 0, 0
        );
        INSERT INTO acore_characters.character_homebind (guid, mapId, zoneId, posX, posY, posZ)
        VALUES (@newguid, 0, 12, -8949.95, -132.493, 83.5312);
        COMMIT;
    " >/dev/null

    existing_guid="$(db_query "$password" \
        "SELECT guid FROM acore_characters.characters WHERE name = '${AHBOT_CHARACTER_NAME}';")"

    if [[ ! "$existing_guid" =~ ^[0-9]+$ ]]; then
        error "Failed to create character." >&2
        return 1
    fi

    success "Character '${AHBOT_CHARACTER_NAME}' created (guid ${existing_guid})." >&2
    echo "$existing_guid"

    return 0
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

    warning "This creates the '${AHBOT_CHARACTER_NAME}' character by inserting"
    warning "directly into the database, NOT via the officially documented"
    warning "method (logging in with the client). If already created, the"
    warning "existing account/character are reused as-is."
    echo

    confirm "Continue?" || return

    echo

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read the database password."
        pause
        return 1
    fi

    local account_id guid

    account_id="$(ensure_ahbot_account "$password")" || { pause; return 1; }
    guid="$(ensure_ahbot_character "$password" "$account_id")" || { pause; return 1; }

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
