#!/usr/bin/env bash

set -o pipefail

# ============================================================
# ac-network.sh
#
# Standalone companion to ac-manager.sh. Views and changes the
# realmlist's public address and/or local address (the IPs
# players connect to and that the auth server hands out).
#
# Usage:
#   ./ac-network.sh          interactive menu
#   ./ac-network.sh show     show current realmlist entries
#   ./ac-network.sh set      change address / localAddress
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

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
    echo -e "${BOLD}AzerothCore Network${RESET}"
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
# Core / Docker / DB helpers
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

compose() {
    (
        cd "$CORE_DIR" || exit 1
        docker compose "$@"
    )
}

check_database_running() {

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        error "ac-database is not running."
        info "Start the server first."
        return 1
    fi

    return 0
}

get_db_password() {
    compose exec -T \
        ac-database \
        printenv MYSQL_ROOT_PASSWORD \
        2>/dev/null
}

show_realmlist() {

    local password="$1"

    compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -t \
        -e "SELECT id, name, address, localAddress, port FROM acore_auth.realmlist;" \
        2>/dev/null
}

# ============================================================
# Commands
# ============================================================

cmd_show() {

    header

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read the database password."
        pause
        return 1
    fi

    info "Current realmlist entries:"
    echo

    show_realmlist "$password"

    pause
}

cmd_set() {

    header

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read the database password."
        pause
        return 1
    fi

    info "Current realmlist entries:"
    echo

    show_realmlist "$password"

    echo

    # --------------------------------------------------------
    # Ask about each field independently -- only change what's asked for.
    # --------------------------------------------------------

    local new_address="" new_local_address=""

    if confirm "Change the public address (used by players connecting from outside)?"; then

        read -r -p "New public address: " new_address

        if [[ -n "$new_address" ]]; then

            new_address="${new_address//\'/}"

            if ! [[ "$new_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                warning "'$new_address' doesn't look like a plain IPv4 address."
                confirm "Use it anyway?" || new_address=""
            fi

        fi

    fi

    echo

    if confirm "Change the local address (used by players on the same LAN, default 127.0.0.1)?"; then

        read -r -p "New local address: " new_local_address

        if [[ -n "$new_local_address" ]]; then

            new_local_address="${new_local_address//\'/}"

            if ! [[ "$new_local_address" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                warning "'$new_local_address' doesn't look like a plain IPv4 address."
                confirm "Use it anyway?" || new_local_address=""
            fi

        fi

    fi

    if [[ -z "$new_address" ]] && [[ -z "$new_local_address" ]]; then
        echo
        warning "Nothing to change."
        pause
        return
    fi

    # --------------------------------------------------------
    # Build and run the UPDATE with only the chosen fields.
    # --------------------------------------------------------

    local set_clause=""

    [[ -n "$new_address" ]] && set_clause="address='${new_address}'"

    if [[ -n "$new_local_address" ]]; then
        [[ -n "$set_clause" ]] && set_clause="${set_clause}, "
        set_clause="${set_clause}localAddress='${new_local_address}'"
    fi

    echo
    confirm "Apply: UPDATE realmlist SET $set_clause (for every realm)?" || {
        pause
        return
    }

    if compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -e "UPDATE acore_auth.realmlist SET $set_clause;" \
        2>/dev/null; then

        success "realmlist updated."
        info "authserver refreshes the realmlist from the database periodically --"
        info "no restart needed, it should take effect within moments."

        echo
        info "Update the client realmlist.wtf (WoW Client/Data/<locale>/realmlist.wtf):"
        echo

        local client_address="${new_address:-$new_local_address}"

        echo "    set realmlist $client_address"

    else

        error "Failed to update realmlist."

    fi

    pause
}

# ============================================================
# Interactive menu
# ============================================================

menu() {

    while true; do

        header

        echo "  1  Show realmlist"
        echo "  2  Change address / localAddress"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) cmd_show ;;
            2) cmd_set ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [show|set]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  show           show current realmlist entries"
    echo "  set            change address and/or localAddress"
}

# ============================================================
# Entry point
# ============================================================

case "${1:-menu}" in
    menu) menu ;;
    show) cmd_show ;;
    set)  cmd_set ;;
    -h|--help) usage ;;
    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;
esac
