#!/usr/bin/env bash

set -o pipefail

# ============================================================
# ac-account.sh
#
# Standalone companion to ac-manager.sh. Manages AzerothCore
# accounts: create, list, inspect, delete, change password, and
# set GM security level.
#
# Account creation and password changes are done with direct SQL
# using a real SRP6 verifier -- this is the same technique every
# AzerothCore web account panel uses, and is fully safe (it's how
# the "account" table is designed to be written to). GM level is
# also plain SQL against account_access, which AzerothCore's own
# documentation itself recommends direct SQL for reaching level 4
# (SEC_CONSOLE), since the console command caps at level 3.
#
# Deletion is deliberately conservative: an account with any
# characters on it is refused, rather than silently leaving
# orphaned characters, mail, guild memberships, etc. behind.
# Delete the characters first (in-game, or via the worldserver
# console), then the account.
#
# Usage:
#   ./ac-account.sh                      interactive menu
#   ./ac-account.sh create <user> [pass] create an account
#   ./ac-account.sh list                 list every account
#   ./ac-account.sh info <user>          show one account's details
#   ./ac-account.sh setgm <user> <lvl>   set GM level (0-4, all realms)
#   ./ac-account.sh setpass <user> [pw]  change an account's password
#   ./ac-account.sh delete <user>        delete an account (blocked if it has characters)
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
    echo -e "${BOLD}AzerothCore Account${RESET}"
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

    if ! docker info >/dev/null 2>&1; then

        if docker info 2>&1 | grep -qi "permission denied"; then

            error "Docker is installed, but this user can't talk to it."
            info "Fix it once (no sudo needed for this script afterwards):"
            echo
            echo "  sudo usermod -aG docker \$USER"
            echo "  newgrp docker   # or just log out and back in"
            echo

        else

            error "The Docker daemon isn't running or isn't reachable."
            info "Try: sudo systemctl start docker"

        fi

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

# Cached across calls within the same run -- the root password
# doesn't change while ac-database keeps running.
CACHED_DB_PASSWORD=""

db_password() {

    if [[ -z "$CACHED_DB_PASSWORD" ]]; then
        CACHED_DB_PASSWORD="$(get_db_password)"
    fi

    echo "$CACHED_DB_PASSWORD"
}

db_query() {
    # $1 = SQL. Prints tab-separated result rows, no headers.
    local password
    password="$(db_password)"
    [[ -z "$password" ]] && return 1

    compose exec -T ac-database \
        mysql -uroot -p"$password" -Nse "$1" \
        2>/dev/null
}

db_table() {
    # $1 = SQL. Prints a pretty ASCII table (with headers).
    local password
    password="$(db_password)"
    [[ -z "$password" ]] && return 1

    compose exec -T ac-database \
        mysql -uroot -p"$password" -t -e "$1" \
        2>/dev/null
}

db_exec() {
    # $1 = SQL. Runs it, discarding output. Returns mysql's exit code.
    local password
    password="$(db_password)"
    [[ -z "$password" ]] && return 1

    compose exec -T ac-database \
        mysql -uroot -p"$password" -e "$1" \
        >/dev/null 2>&1
}

# ============================================================
# SRP6 (AzerothCore's account password verifier)
# ============================================================

generate_srp6() {

    # $1 = username, $2 = password. Prints "<salt_hex> <verifier_hex>".
    # https://www.azerothcore.org/wiki/account#verifier
    #   h1 = SHA1("USERNAME:PASSWORD")
    #   h2 = SHA1(salt || h1)
    #   verifier = (g ^ h2) % N        (h2 as little-endian integer)

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

read_password() {

    # $1 = prompt. Prints the entered password (asked twice, must match).

    local p1 p2

    while true; do

        read -r -s -p "$1: " p1
        echo >&2
        read -r -s -p "Confirm password: " p2
        echo >&2

        if [[ -z "$p1" ]]; then
            error "Password can't be empty." >&2
            continue
        fi

        if [[ "$p1" != "$p2" ]]; then
            error "Passwords don't match, try again." >&2
            continue
        fi

        echo "$p1"
        return 0

    done
}

# ============================================================
# Account lookups
# ============================================================

account_id() {
    # $1 = username (case-insensitive). Prints the id, or nothing.
    db_query "SELECT id FROM acore_auth.account WHERE UPPER(username) = UPPER('${1//\'/}');"
}

account_gmlevel() {
    # $1 = account id. Prints the all-realms (RealmID=-1) gmlevel, or 0.
    local level
    level="$(db_query "SELECT gmlevel FROM acore_auth.account_access WHERE id = ${1} AND RealmID = -1;")"
    echo "${level:-0}"
}

character_count() {
    # $1 = account id.
    db_query "SELECT COUNT(*) FROM acore_characters.characters WHERE account = ${1};"
}

# ============================================================
# Commands
# ============================================================

cmd_create() {

    header
    echo "Create Account"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_python || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local username="$1" password="$2"

    if [[ -z "$username" ]]; then
        read -r -p "Username: " username
    fi

    if [[ -z "$username" ]]; then
        error "No username entered."
        pause
        return 1
    fi

    username="${username//\'/}"

    if [[ -n "$(account_id "$username")" ]]; then
        error "An account named '$username' already exists."
        pause
        return 1
    fi

    if [[ -z "$password" ]]; then
        password="$(read_password "Password for $username")"
    fi

    local srp salt_hex verifier_hex
    srp="$(generate_srp6 "$username" "$password")"
    salt_hex="${srp%% *}"
    verifier_hex="${srp##* }"

    if [[ -z "$salt_hex" ]] || [[ -z "$verifier_hex" ]] || [[ "$salt_hex" == "$verifier_hex" ]]; then
        error "Failed to generate account credentials."
        pause
        return 1
    fi

    if ! db_exec "INSERT INTO acore_auth.account (username, salt, verifier, reg_mail, email, joindate)
         VALUES ('${username^^}', UNHEX('${salt_hex}'), UNHEX('${verifier_hex}'), '', '', NOW());"; then
        error "Failed to create account."
        pause
        return 1
    fi

    local new_id
    new_id="$(account_id "$username")"

    if [[ -z "$new_id" ]]; then
        error "Account creation didn't take -- check the database manually."
        pause
        return 1
    fi

    success "Account '${username^^}' created (id $new_id)."

    echo
    if confirm "Set a GM level for this account now?"; then
        _do_setgm "$new_id" "${username^^}"
    fi

    pause
}

_do_setgm() {

    # $1 = account id, $2 = username (for messages)

    local account="$1" name="$2" level

    echo
    echo "  0  SEC_PLAYER"
    echo "  1  SEC_MODERATOR"
    echo "  2  SEC_GAMEMASTER"
    echo "  3  SEC_ADMINISTRATOR"
    echo "  4  SEC_CONSOLE (full access -- only for accounts you trust completely)"
    echo

    read -r -p "GM level [0-4]: " level

    if ! [[ "$level" =~ ^[0-4]$ ]]; then
        error "Level must be a number from 0 to 4."
        return 1
    fi

    if db_exec "INSERT INTO acore_auth.account_access (id, gmlevel, RealmID)
         VALUES (${account}, ${level}, -1)
         ON DUPLICATE KEY UPDATE gmlevel = ${level};"; then

        success "$name is now GM level $level (all realms)."
        info "If $name is currently logged in, they need to relog for it to apply."

    else
        error "Failed to set GM level."
        return 1
    fi
}

cmd_setgm() {

    header
    echo "Set GM Level"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local username="$1"

    if [[ -z "$username" ]]; then
        read -r -p "Username: " username
    fi

    local account
    account="$(account_id "$username")"

    if [[ -z "$account" ]]; then
        error "No account named '$username'."
        pause
        return 1
    fi

    local current
    current="$(account_gmlevel "$account")"
    info "Current GM level for ${username^^}: $current"

    if [[ -n "$2" ]]; then

        if ! [[ "$2" =~ ^[0-4]$ ]]; then
            error "Level must be a number from 0 to 4."
            pause
            return 1
        fi

        if db_exec "INSERT INTO acore_auth.account_access (id, gmlevel, RealmID)
             VALUES (${account}, ${2}, -1)
             ON DUPLICATE KEY UPDATE gmlevel = ${2};"; then
            success "${username^^} is now GM level $2 (all realms)."
        else
            error "Failed to set GM level."
        fi

    else

        _do_setgm "$account" "${username^^}"

    fi

    pause
}

cmd_setpass() {

    header
    echo "Change Password"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_python || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local username="$1" password="$2"

    if [[ -z "$username" ]]; then
        read -r -p "Username: " username
    fi

    local account
    account="$(account_id "$username")"

    if [[ -z "$account" ]]; then
        error "No account named '$username'."
        pause
        return 1
    fi

    if [[ -z "$password" ]]; then
        password="$(read_password "New password for ${username^^}")"
    fi

    local srp salt_hex verifier_hex
    srp="$(generate_srp6 "$username" "$password")"
    salt_hex="${srp%% *}"
    verifier_hex="${srp##* }"

    if db_exec "UPDATE acore_auth.account
         SET salt = UNHEX('${salt_hex}'), verifier = UNHEX('${verifier_hex}')
         WHERE id = ${account};"; then

        success "Password updated for ${username^^}."

    else
        error "Failed to update password."
    fi

    pause
}

cmd_list() {

    header
    echo "Accounts"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    db_table "
        SELECT
            a.id AS id,
            a.username AS username,
            COALESCE(aa.gmlevel, 0) AS gmlevel,
            a.online AS online,
            a.locked AS locked,
            a.last_login AS last_login
        FROM acore_auth.account a
        LEFT JOIN acore_auth.account_access aa
            ON aa.id = a.id AND aa.RealmID = -1
        ORDER BY a.username;
    "

    pause
}

cmd_info() {

    header
    echo "Account Info"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local username="$1"

    if [[ -z "$username" ]]; then
        read -r -p "Username: " username
    fi

    local account
    account="$(account_id "$username")"

    if [[ -z "$account" ]]; then
        error "No account named '$username'."
        pause
        return 1
    fi

    db_table "SELECT id, username, email, online, locked, last_login, last_ip, expansion
              FROM acore_auth.account WHERE id = ${account};"

    echo
    info "GM access (per realm, -1 = all realms):"
    db_table "SELECT RealmID, gmlevel FROM acore_auth.account_access WHERE id = ${account};"

    echo
    local count
    count="$(character_count "$account")"
    info "Characters: ${count:-0}"

    if [[ "${count:-0}" -gt 0 ]]; then
        db_table "SELECT guid, name, race, class, level FROM acore_characters.characters WHERE account = ${account};"
    fi

    pause
}

cmd_delete() {

    header
    echo "Delete Account"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_database_running || { pause; return 1; }

    local username="$1"

    if [[ -z "$username" ]]; then
        read -r -p "Username: " username
    fi

    local account
    account="$(account_id "$username")"

    if [[ -z "$account" ]]; then
        error "No account named '$username'."
        pause
        return 1
    fi

    local count
    count="$(character_count "$account")"

    if [[ "${count:-0}" -gt 0 ]]; then

        error "${username^^} still has ${count} character(s) -- refusing to delete."
        info "Deleting the account directly would orphan those characters"
        info "(mail, guild membership, etc. would be left behind too)."
        info "Delete the characters first (in-game, or via the worldserver"
        info "console: '.character erase <name>' or 'character erase <name>'"
        info "from the account management console commands), then retry."
        pause
        return 1

    fi

    echo
    warning "This will permanently delete account '${username^^}' (id $account)."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    if db_exec "DELETE FROM acore_auth.account_access WHERE id = ${account};
                DELETE FROM acore_auth.account WHERE id = ${account};"; then

        success "Account '${username^^}' deleted."

    else
        error "Failed to delete account."
    fi

    pause
}

# ============================================================
# Interactive menu
# ============================================================

menu() {

    while true; do

        header

        echo "  1  Create account"
        echo
        echo "  2  List accounts"
        echo "  3  Account info"
        echo
        echo "  4  Set GM level"
        echo "  5  Change password"
        echo
        echo "  6  Delete account"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) cmd_create ;;
            2) cmd_list ;;
            3) cmd_info ;;
            4) cmd_setgm ;;
            5) cmd_setpass ;;
            6) cmd_delete ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [create|list|info|setgm|setpass|delete] [args]"
    echo
    echo "  (no argument)          interactive menu"
    echo "  create <user> [pass]   create an account (prompts for password if omitted)"
    echo "  list                   list every account with its GM level"
    echo "  info <user>            show one account's details + characters"
    echo "  setgm <user> <0-4>     set GM level (all realms)"
    echo "  setpass <user> [pass]  change an account's password"
    echo "  delete <user>          delete an account (refused if it has characters)"
}

# ============================================================
# Entry point
# ============================================================

case "${1:-menu}" in
    menu)     menu ;;
    create)   cmd_create "$2" "$3" ;;
    list)     cmd_list ;;
    info)     cmd_info "$2" ;;
    setgm)    cmd_setgm "$2" "$3" ;;
    setpass)  cmd_setpass "$2" "$3" ;;
    delete)   cmd_delete "$2" ;;
    -h|--help) usage ;;
    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;
esac
