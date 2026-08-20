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
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) module_install_menu ;;
            2) module_remove_menu ;;
            3) module_update_menu ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [list|install <name>|remove <name>|update [name]]"
    echo
    echo "  (no argument)   interactive menu"
    echo "  list            show install status of every module"
    echo "  install <name>  clone a module"
    echo "  remove <name>   remove a module"
    echo "  update [name]   update one module, or every installed module if omitted"
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
