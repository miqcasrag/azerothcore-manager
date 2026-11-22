#!/usr/bin/env bash

set -o pipefail

# ============================================================
# azerothcore-manager.sh
#
# A single-file, all-in-one tool for running an AzerothCore WotLK
# server with Playerbots on Docker, organized into seven sections:
#   server    start/stop/restart, status/logs, backup/restore, configure
#   modules   optional modules + Playerbots/AH Bot config
#   sleep     idle-pause monitor + instant-wake proxy
#   backup    scheduled automatic backups + rclone remote copy
#   account   account creation, GM levels
#   network   realmlist address configuration
#   setup     install, update, rebuild and uninstall AzerothCore
#
# Everything lives in this one file, name-spaced into sections to
# avoid collisions (see the section markers below), sharing one
# copy of the common helper functions (colours,
# header/success/error/warning/info, pause/confirm, check_core,
# check_docker, compose, get_db_password, etc.) that each section
# uses.
#
# Usage:
#   ./azerothcore-manager.sh                     interactive top-level menu
#   ./azerothcore-manager.sh server  [args...]   -> the server section's own commands
#   ./azerothcore-manager.sh modules [args...]   -> the modules section's own commands
#   ./azerothcore-manager.sh sleep   [args...]   -> the sleep section's own commands
#   ./azerothcore-manager.sh backup  [args...]   -> the backup section's own commands
#   ./azerothcore-manager.sh account [args...]   -> the account section's own commands
#   ./azerothcore-manager.sh network [args...]   -> the network section's own commands
#   ./azerothcore-manager.sh setup   [args...]   -> the setup section's own commands
#
# Each section takes its own subcommands -- e.g.:
#   ./azerothcore-manager.sh sleep enable
#   ./azerothcore-manager.sh backup run --quiet
#   ./azerothcore-manager.sh account create Someone
#   ./azerothcore-manager.sh network show
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

# ============================================================
# Colours
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

# ============================================================
# Shared helpers (one copy, used by every section)
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

header() {
    clear_screen

    echo
    echo -e "${BOLD}${1:-AzerothCore Server}${RESET}"
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

check_core() {

    if [[ ! -d "$CORE_DIR" ]]; then
        error "AzerothCore is not installed."
        return 1
    fi

    if [[ ! -d "$CORE_DIR/.git" ]]; then
        error "AzerothCore directory is not a Git repository."
        return 1
    fi

    if [[ ! -f "$CORE_DIR/docker-compose.yml" ]]; then
        error "docker-compose.yml not found."
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

env_get_value() {
    # $1 = key. Prints its value from the core's .env, or nothing.
    [[ -f "$CORE_DIR/.env" ]] || return 0
    grep -E "^$1=" "$CORE_DIR/.env" 2>/dev/null | tail -n1 | cut -d= -f2-
}

env_set_value() {
    # $1 = key, $2 = value (no | or newlines). Replaces or appends.
    local env="$CORE_DIR/.env"
    touch "$env"
    if grep -qE "^$1=" "$env"; then
        sed -i "s|^$1=.*\$|$1=$2|" "$env"
    else
        echo "$1=$2" >> "$env"
    fi
}

env_db_password() {
    # The root password the compose file gives the database: the one
    # in .env, or AzerothCore's built-in default.
    local pw
    pw="$(env_get_value DOCKER_DB_ROOT_PASSWORD)"
    echo "${pw:-password}"
}

sql_clean() {
    # Strips ' and \ so a value can't break out of a SQL string.
    local v="${1//\'/}"
    echo "${v//\\/}"
}

sleep_mark_activity() {
    # Resets the AutoSleep idle timer (used when the server is
    # (re)started so it isn't paused mid-startup).
    date +%s > "$SCRIPT_DIR/.sleep-last-activity" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/.sleep-since" 2>/dev/null || true
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

check_database_running() {

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        error "ac-database is not running."
        info "Start the server first."
        return 1
    fi

    return 0
}

generate_srp6() {

    # $1 = username, $2 = password. Prints "<salt_hex> <verifier_hex>".
    # Implements AzerothCore's documented SRP6 verifier algorithm
    # (https://www.azerothcore.org/wiki/account#verifier):
    #   h1 = SHA1("USERNAME:PASSWORD")
    #   h2 = SHA1(salt || h1)          (salt, h1 as raw bytes)
    #   verifier = (g ^ h2) % N        (h2 as little-endian integer)
    # g and N are WoW's fixed SRP6 parameters.

    SRP_USER="$1" SRP_PASS="$2" python3 - << 'PY'
import hashlib
import os

username = os.environ["SRP_USER"].upper()
password = os.environ["SRP_PASS"].upper()

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

clean_module_sql_duplicates() {

    check_core || return 1

    [[ -d "$CORE_DIR/modules" ]] || return 0

    local module_dir
    local db
    local base
    local file
    local dest
    local cleaned=0

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
# SECTION: server
# ============================================================

# ============================================================
# AzerothCore Server
# ============================================================

BACKUP_DIR="$SCRIPT_DIR/backups"

CORE_REPO="https://github.com/mod-playerbots/azerothcore-wotlk.git"
CORE_BRANCH="Playerbot"

PLAYERBOTS_REPO="https://github.com/mod-playerbots/mod-playerbots.git"
PLAYERBOTS_BRANCH="master"

DOCKER_UID="1000"
DOCKER_GID="1000"


# ============================================================
# UI
# ============================================================

















# ============================================================
# Docker
# ============================================================





is_container_paused() {

    local service="$1"

    compose ps \
        --status paused \
        --services 2>/dev/null |
    grep -qx "$service"
}

# ============================================================
# Core validation
# ============================================================



# ============================================================
# Timezone
# ============================================================

get_timezone() {

    local timezone=""

    if command -v timedatectl >/dev/null 2>&1; then

        timezone="$(
            timedatectl show \
                --value \
                --property=Timezone \
                2>/dev/null
        )"

    fi

    if [[ -z "$timezone" ]] && [[ -f /etc/timezone ]]; then
        timezone="$(cat /etc/timezone)"
    fi

    [[ -z "$timezone" ]] && timezone="UTC"

    echo "$timezone"
}

configure_timezone() {

    local timezone

    timezone="$(get_timezone)"

    touch "$CORE_DIR/.env"

    if grep -q '^TZ=' "$CORE_DIR/.env"; then

        sed -i \
            "s|^TZ=.*$|TZ=$timezone|" \
            "$CORE_DIR/.env"

    else

        echo "TZ=$timezone" >> "$CORE_DIR/.env"

    fi

    success "Timezone: $timezone"
}

# ============================================================
# Directories
# ============================================================

prepare_directories() {

    check_core || return 1

    mkdir -p \
        "$CORE_DIR/data/sql/custom/db_auth" \
        "$CORE_DIR/data/sql/custom/db_characters" \
        "$CORE_DIR/data/sql/custom/db_world" \
        "$CORE_DIR/data/sql/custom/db_playerbots" \
        "$CORE_DIR/env/dist/etc/modules" \
        "$CORE_DIR/env/dist/logs" \
        "$CORE_DIR/volumes/database" \
        "$CORE_DIR/volumes/client-data" \
        "$BACKUP_DIR"

    # volumes/ isn't in AzerothCore's .gitignore: keep git from seeing
    # it as local changes (that would block Setup > Update).
    if [[ -d "$CORE_DIR/.git/info" ]] && ! grep -qx '/volumes/' "$CORE_DIR/.git/info/exclude" 2>/dev/null; then
        echo '/volumes/' >> "$CORE_DIR/.git/info/exclude"
    fi

    success "Directories ready."
}

configure_database_env() {

    # The database and SOAP ports are published on 127.0.0.1 only (the
    # script reaches the database through docker, never that port).
    # Values already in .env are kept.

    [[ -n "$(env_get_value DOCKER_DB_EXTERNAL_PORT)" ]] || env_set_value DOCKER_DB_EXTERNAL_PORT "127.0.0.1:3306"
    [[ -n "$(env_get_value DOCKER_SOAP_EXTERNAL_PORT)" ]] || env_set_value DOCKER_SOAP_EXTERNAL_PORT "127.0.0.1:7878"

    chmod 600 "$CORE_DIR/.env" 2>/dev/null

    success "Database ports 3306/7878 published on 127.0.0.1 only."

}

# ============================================================
# Permissions
#
# Docker AzerothCore containers use UID:GID 1000:1000.
#
# IMPORTANT:
# Run chown from INSIDE azerothcore-wotlk.
# ============================================================

fix_permissions() {

    check_core || return 1

    info "Fixing AzerothCore permissions..."
    echo

    # volumes/database is left alone: it belongs to the MySQL user
    # inside ac-database, and changing it under a running database
    # breaks it.
    (
        cd "$CORE_DIR" || exit 1

        sudo chown "${DOCKER_UID}:${DOCKER_GID}" . &&
        sudo find . -mindepth 1 -path ./volumes/database -prune -o \
            -exec chown -h "${DOCKER_UID}:${DOCKER_GID}" {} +
    )

    local result=$?

    if [[ "$result" -eq 0 ]]; then
        success "Permissions fixed: ${DOCKER_UID}:${DOCKER_GID}"
    else
        error "Failed to fix permissions."
    fi

    return "$result"
}

# ============================================================
# Playerbots module
# ============================================================

get_playerbots_dir() {
    echo "$CORE_DIR/modules/mod-playerbots"
}

check_playerbots_module() {

    local module

    module="$(get_playerbots_dir)"

    if [[ ! -d "$module" ]]; then
        error "mod-playerbots is not installed."
        return 1
    fi

    if [[ ! -d "$module/.git" ]]; then
        error "mod-playerbots is not a Git repository."
        return 1
    fi

    return 0
}

# ============================================================
# Playerbots SQL discovery
#
# Current mod-playerbots layout:
#
# data/sql/playerbots/base/
#
# This is the SQL used by the Playerbots database.
# ============================================================

get_playerbots_sql_dir() {

    local module

    module="$(get_playerbots_dir)"

    if [[ -d "$module/data/sql/playerbots/base" ]]; then
        echo "$module/data/sql/playerbots/base"
        return 0
    fi

    return 1
}

check_playerbots_sql() {

    local sql_dir

    sql_dir="$(get_playerbots_sql_dir 2>/dev/null || true)"

    if [[ -z "$sql_dir" ]]; then

        error "Playerbots database SQL directory not found."
        echo
        echo "Expected:"
        echo
        echo "  $CORE_DIR/modules/mod-playerbots/data/sql/playerbots/base/"
        echo

        return 1
    fi

    local count

    count="$(
        find "$sql_dir" \
            -maxdepth 1 \
            -type f \
            -name '*.sql' \
            2>/dev/null |
        wc -l
    )"

    if [[ "$count" -eq 0 ]]; then
        error "Playerbots SQL directory is empty."
        return 1
    fi

    success "Playerbots SQL found: $count files."

    return 0
}

# ============================================================
# Module SQL duplicate cleanup
#
# AzerothCore's dbimport already auto-discovers and applies
# module SQL directly from each module's own directory:
#
#   modules/<name>/data/sql/<db>/base   (current layout)
#   modules/<name>/sql/<db>/base        (legacy layout)
#
# It is NOT necessary, and actively harmful, to also copy
# those files into data/sql/custom/db_<db>/, because dbimport
# orders/keys updates by filename only, regardless of which
# directory they come from. The same filename existing in both
# the module dir AND custom/ triggers:
#
#   "Duplicate filename ... occurred. Because updates are
#    ordered by their filenames, every name needs to be
#    unique!"
#
# This function cleans up any such duplicates for EVERY module
# directory found under modules/ (Playerbots, plus anything
# installed there by the Modules section), since the same bug can hit
# any module that follows this layout. It only removes a custom/
# file when a module directory provides a file with the exact
# same name, so genuine custom SQL you placed yourself is left
# untouched -- unlike a blanket "wipe custom/" approach.
# ============================================================



# ============================================================
# Playerbots SQL for standard AC databases
#
# Kept as a thin wrapper (same name/interface used throughout
# the script) around the generic duplicate cleanup above, so
# every existing call site keeps working unchanged.
# ============================================================

install_playerbots_standard_sql() {

    check_core || return 1
    check_playerbots_module || return 1

    clean_module_sql_duplicates

    return 0
}

# ============================================================
# Playerbots database
# ============================================================



wait_for_database() {

    local password
    local tries=0

    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read MYSQL_ROOT_PASSWORD."
        return 1
    fi

    info "Waiting for database..."

    while true; do

        if compose exec -T \
            ac-database \
            mysql \
            -uroot \
            -p"$password" \
            -e "SELECT 1;" \
            >/dev/null 2>&1; then

            success "Database is ready."
            return 0

        fi

        sleep 2

        tries=$((tries + 1))

        if [[ "$tries" -ge 60 ]]; then
            error "Database did not become ready in time."
            return 1
        fi

    done
}


database_has_tables() {

    local database="$1"
    local password

    password="$(get_db_password)"

    [[ -z "$password" ]] && return 1

    local count

    count="$(
        compose exec -T \
            ac-database \
            mysql \
            -uroot \
            -p"$password" \
            -Nse \
            "SELECT COUNT(*) FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$database';" \
            2>/dev/null
    )"

    [[ "$count" =~ ^[0-9]+$ ]] || return 1

    (( count > 0 ))
}

create_playerbots_database() {

    check_core || return 1
    check_docker || return 1

    local password

    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read database root password."
        return 1
    fi

    info "Ensuring acore_playerbots exists..."

    if ! compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -e "CREATE DATABASE IF NOT EXISTS acore_playerbots CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then

        error "Failed to create acore_playerbots."
        return 1
    fi

    success "acore_playerbots database exists."

    return 0
}

# ============================================================
# Direct Playerbots database import
#
# This is the important fallback/fix.
#
# The worldserver expects:
#
# /azerothcore/modules/mod-playerbots/data/sql/playerbots/base/
#
# If the Docker auto-updater does not see that directory,
# we populate acore_playerbots ourselves BEFORE starting
# ac-worldserver.
# ============================================================

import_playerbots_database() {

    check_core || return 1
    check_docker || return 1
    check_playerbots_module || return 1
    check_playerbots_sql || return 1

    create_playerbots_database || return 1
    wait_for_database || return 1

    local sql_dir
    sql_dir="$(get_playerbots_sql_dir)"

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read database password."
        return 1
    fi

    # --------------------------------------------------------
    # If the database already has tables, do not destroy it.
    # The AzerothCore updater can handle future updates.
    # --------------------------------------------------------

    if database_has_tables "acore_playerbots"; then

        success "acore_playerbots already contains tables."
        return 0

    fi

    echo
    warning "acore_playerbots is empty."
    info "Importing Playerbots base SQL..."
    echo

    local count=0
    local file
    local filename

    # --------------------------------------------------------
    # Import every base SQL file in deterministic order.
    # --------------------------------------------------------

    while IFS= read -r file; do

        [[ -f "$file" ]] || continue

        filename="$(basename "$file")"

        printf "  %-55s " "$filename"

        if compose exec -T \
            ac-database \
            mysql \
            -uroot \
            -p"$password" \
            acore_playerbots \
            < "$file" \
            >/dev/null 2>&1; then

            echo -e "${GREEN}OK${RESET}"
            count=$((count + 1))

        else

            echo -e "${RED}FAILED${RESET}"
            echo
            error "Playerbots SQL import failed:"
            echo "  $file"
            echo

            return 1

        fi

    done < <(
        find "$sql_dir" \
            -maxdepth 1 \
            -type f \
            -name '*.sql' \
            -print |
        sort
    )

    echo

    if [[ "$count" -eq 0 ]]; then
        error "No Playerbots SQL files were imported."
        return 1
    fi

    if ! database_has_tables "acore_playerbots"; then
        error "acore_playerbots is still empty after import."
        return 1
    fi

    success "Playerbots database populated: $count SQL files."

    return 0
}

prepare_playerbots_database() {

    check_core || return 1
    check_docker || return 1

    create_playerbots_database || return 1

    # The direct import is deliberately done before worldserver.
    import_playerbots_database || return 1

    return 0
}

# ============================================================
# Playerbots configuration
# ============================================================

update_conf_from_dist() {

    # $1 = fresh .conf.dist, $2 = existing .conf to update.
    #
    # Rebuilds the .conf using the fresh .conf.dist as the
    # structural base -- its layout, comments, option order, and
    # any new options the repo added all come through -- then
    # walks every key the .dist defines and, wherever the admin's
    # existing .conf also has that key, puts the admin's current
    # value in place of the .dist's default. A key the repo removed
    # is simply absent from the result; a key the repo added keeps
    # the .dist's default, ready to tune. A backup of the previous
    # .conf is kept alongside it as .conf.bak before the rewrite.
    #
    # Done with awk on purpose: config values can hold any text
    # (prompt templates with | & \ and quotes), and awk prints
    # them back verbatim, whereas a sed substitution would choke
    # on or mangle them. The result is written into the existing
    # file (not moved over it) so its permissions/owner survive.
    #
    # Known limitation: if a key was renamed upstream (not just
    # added/removed), its old value isn't carried over to the new
    # name automatically -- there's no reliable way to detect
    # "X became Y" from the files alone. Check the changelog after
    # an update that changes many keys, just in case.

    local dist_file="$1"
    local conf_file="$2"

    [[ -f "$dist_file" ]] || return 1

    if [[ ! -f "$conf_file" ]]; then
        cp "$dist_file" "$conf_file"
        echo 0
        return 0
    fi

    cp -f "$conf_file" "${conf_file}.bak"

    local tmp_file count_file
    tmp_file="$(mktemp)"
    count_file="$(mktemp)"

    awk -v count_file="$count_file" '
        NR == FNR {
            if ($0 ~ /^[A-Za-z0-9_.]+[[:space:]]*=/) {
                key = $0
                sub(/[[:space:]]*=.*/, "", key)
                val = $0
                sub(/^[A-Za-z0-9_.]+[[:space:]]*=[[:space:]]*/, "", val)
                old[key] = val
                # mod-playerbots renamed AiPlayerbot.* to Playerbots.*
                # (Oct 2026): carry the old values over to the new names.
                if (key ~ /^AiPlayerbot\./) {
                    nk = key
                    sub(/^AiPlayerbot\./, "Playerbots.", nk)
                    ren[nk] = val
                }
            }
            next
        }
        {
            if ($0 ~ /^[A-Za-z0-9_.]+[[:space:]]*=/) {
                key = $0
                sub(/[[:space:]]*=.*/, "", key)
                if (key in old) {
                    print key " = " old[key]
                    restored++
                    next
                }
                if (key in ren) {
                    print key " = " ren[key]
                    restored++
                    next
                }
            }
            print
        }
        END { print restored + 0 > count_file }
    ' "$conf_file" "$dist_file" > "$tmp_file"

    cat "$tmp_file" > "$conf_file"
    cat "$count_file"

    rm -f "$tmp_file" "$count_file"

    report_conf_key_changes "${conf_file}.bak" "$dist_file" "$conf_file" >&2

    return 0
}

report_conf_key_changes() {

    # $1 = previous .conf (the .bak), $2 = fresh .conf.dist,
    # $3 = .conf name (for display). Informational only: lists the
    # keys the update added and the ones it dropped, so a renamed
    # key (one gone + one new) is easy to spot. Names only, capped
    # so long files don't flood the screen.

    local old_file="$1" dist_file="$2" conf_file="$3"
    local limit=10 line kind key
    local -a added=() removed=()

    while IFS= read -r line; do
        kind="${line%% *}"
        key="${line#* }"
        if [[ "$kind" == "+" ]]; then
            added+=("$key")
        else
            removed+=("$key")
        fi
    done < <(
        awk '
            NR == FNR {
                if ($0 ~ /^[A-Za-z0-9_.]+[[:space:]]*=/) {
                    k = $0; sub(/[[:space:]]*=.*/, "", k)
                    sub(/^AiPlayerbot\./, "Playerbots.", k)
                    if (!(k in a)) { a[k] = 1; ao[++an] = k }
                }
                next
            }
            {
                if ($0 ~ /^[A-Za-z0-9_.]+[[:space:]]*=/) {
                    k = $0; sub(/[[:space:]]*=.*/, "", k)
                    if (!(k in b)) { b[k] = 1; bo[++bn] = k }
                }
            }
            END {
                for (i = 1; i <= bn; i++) if (!(bo[i] in a)) print "+ " bo[i]
                for (i = 1; i <= an; i++) if (!(ao[i] in b)) print "- " ao[i]
            }
        ' "$old_file" "$dist_file"
    )

    [[ ${#added[@]} -eq 0 && ${#removed[@]} -eq 0 ]] && return 0

    local name i n
    name="$(basename "$conf_file")"

    if [[ ${#added[@]} -gt 0 ]]; then
        info "$name: ${#added[@]} new option(s) (default value kept):"
        n=${#added[@]}
        for ((i = 0; i < n && i < limit; i++)); do
            echo "      + ${added[$i]}"
        done
        [[ $n -gt $limit ]] && echo "      ... and $((n - limit)) more"
    fi

    if [[ ${#removed[@]} -gt 0 ]]; then
        warning "$name: ${#removed[@]} option(s) no longer in the repo (dropped):"
        n=${#removed[@]}
        for ((i = 0; i < n && i < limit; i++)); do
            echo "      - ${removed[$i]}"
        done
        [[ $n -gt $limit ]] && echo "      ... and $((n - limit)) more"
    fi

    if [[ ${#added[@]} -gt 0 && ${#removed[@]} -gt 0 ]]; then
        info "A dropped option plus a new one with a similar name may be a rename --"
        info "if so, copy the old value over. Previous file: $(basename "$old_file")"
    fi

    return 0
}

playerbots_prefix() {

    # $1 = playerbots.conf. mod-playerbots renamed every setting from
    # AiPlayerbot.* to Playerbots.* (October 2026). Prints the prefix
    # this file uses: the old one only if the file still has old keys
    # and no new ones; the new one otherwise (fresh installs included).

    local conf="$1"

    if grep -qE '^AiPlayerbot\.' "$conf" 2>/dev/null &&
       ! grep -qE '^Playerbots\.' "$conf" 2>/dev/null; then
        echo "AiPlayerbot"
    else
        echo "Playerbots"
    fi
}

prepare_playerbots_config() {

    check_core || return 1
    check_playerbots_module || return 1

    local config_dir="$CORE_DIR/env/dist/etc/modules"
    local source="$CORE_DIR/modules/mod-playerbots"

    mkdir -p "$config_dir"

    local dist_file=""

    if [[ -f "$source/conf/playerbots.conf.dist" ]]; then

        dist_file="$source/conf/playerbots.conf.dist"

    elif [[ -f "$source/playerbots.conf.dist" ]]; then

        dist_file="$source/playerbots.conf.dist"

    elif [[ -f "$source/etc/modules/playerbots.conf.dist" ]]; then

        dist_file="$source/etc/modules/playerbots.conf.dist"

    fi

    if [[ -z "$dist_file" ]]; then

        warning "playerbots.conf.dist not found."
        warning "The module may generate/use its configuration automatically."

        return 0
    fi

    cp -f \
        "$dist_file" \
        "$config_dir/playerbots.conf.dist"

    if [[ ! -f "$config_dir/playerbots.conf" ]]; then

        cp -f \
            "$dist_file" \
            "$config_dir/playerbots.conf"

        # Installed disabled by default -- the admin turns it on
        # deliberately (edit playerbots.conf: Playerbots.Enabled = 1)
        # once ready, instead of 500 random bots populating the
        # world right after the first start.
        local pb_prefix
        pb_prefix="$(playerbots_prefix "$config_dir/playerbots.conf")"

        sed -i \
            "s|^${pb_prefix}\.Enabled[[:space:]]*=.*\$|${pb_prefix}.Enabled = 0|" \
            "$config_dir/playerbots.conf"

        success "Playerbots configuration created (disabled by default)."
        info "Enable it in: $config_dir/playerbots.conf (${pb_prefix}.Enabled = 1)"

    else

        local restored
        restored="$(update_conf_from_dist "$dist_file" "$config_dir/playerbots.conf")"

        success "Playerbots configuration rebuilt from the updated template ($restored existing option(s) restored)."
        info "Previous version backed up to: $config_dir/playerbots.conf.bak"

    fi

    return 0
}

# ============================================================
# Docker Compose override (Playerbots)
#
# ac-worldserver needs the host "modules/" directory mounted
# inside the container at runtime so it can read the module's
# SQL/config/data files that are NOT baked into the compiled
# binary during "docker compose build":
#
#   services:
#     ac-worldserver:
#       volumes:
#         - ./modules:/azerothcore/modules:ro
#
# Docker Compose merges any docker-compose.override.yml placed
# next to docker-compose.yml automatically -- no extra flags
# needed. This is the official mod-playerbots setup step:
# https://github.com/mod-playerbots/mod-playerbots/wiki/Installation-Guide
# ============================================================

PLAYERBOTS_OVERRIDE_MARKER="# managed-by: azerothcore-manager.sh (playerbots modules mount + TZ)"

write_playerbots_docker_override() {

    check_core || return 1

    local override_file="$CORE_DIR/docker-compose.override.yml"
    local timezone

    timezone="$(get_timezone)"

    if [[ -f "$override_file" ]]; then

        if grep -q "azerothcore/modules" "$override_file" &&
           grep -q "TZ=" "$override_file" &&
           grep -q "volumes/database" "$override_file"; then
            return 0
        fi

        warning "docker-compose.override.yml already exists but is incomplete."
        echo
        echo "  $override_file"
        echo

        if ! grep -q "azerothcore/modules" "$override_file"; then

            warning "Add this manually under services > ac-worldserver > volumes:"
            echo
            echo "      - ./modules:/azerothcore/modules:ro"
            echo

        fi

        if ! grep -q "TZ=" "$override_file"; then

            warning "Add this manually under environment for ac-worldserver, ac-authserver and ac-database:"
            echo
            echo "      - TZ=$timezone"
            echo

        fi

        if ! grep -q "volumes/database" "$override_file"; then

            warning "Add this manually so the database and client data live under this"
            warning "folder instead of a Docker-managed volume elsewhere:"
            echo
            echo "  services:"
            echo "    ac-database:"
            echo "      volumes:"
            echo "        - ./volumes/database:/var/lib/mysql"
            echo "    ac-worldserver:"
            echo "      volumes:"
            echo "        - ./volumes/client-data:/azerothcore/env/dist/data/:ro"
            echo "    ac-client-data-init:"
            echo "      volumes:"
            echo "        - ./volumes/client-data:/azerothcore/env/dist/data"
            echo

        fi

        return 1

    fi

    cat > "$override_file" << EOF
$PLAYERBOTS_OVERRIDE_MARKER
services:
  ac-worldserver:
    volumes:
      - ./modules:/azerothcore/modules:ro
      - ./volumes/client-data:/azerothcore/env/dist/data/:ro
    environment:
      - TZ=$timezone
  ac-authserver:
    environment:
      - TZ=$timezone
  ac-database:
    volumes:
      - ./volumes/database:/var/lib/mysql
    environment:
      - TZ=$timezone
  ac-client-data-init:
    volumes:
      - ./volumes/client-data:/azerothcore/env/dist/data
EOF

    success "docker-compose.override.yml created (mounts modules/, sets TZ=$timezone,"
    info "and keeps the database + client data under this folder's volumes/)."

    return 0
}

# ============================================================
# Docker module visibility
# ============================================================

check_playerbots_docker_visibility() {

    check_core || return 1
    check_docker || return 1

    if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        error "mod-playerbots does not exist on the host."
        return 1
    fi

    # Auto-create/repair the override before checking, so a
    # missing file never blocks the start on its own.
    write_playerbots_docker_override

    info "Checking Playerbots visibility inside Docker..."

    local result

    result="$(
        compose run \
            --rm \
            --no-deps \
            --entrypoint /bin/sh \
            ac-worldserver \
            -c 'test -d /azerothcore/modules/mod-playerbots/data/sql/playerbots/base && echo OK' \
            2>/dev/null
    )"

    if echo "$result" | grep -q "OK"; then

        success "Playerbots SQL is visible inside ac-worldserver."
        return 0

    fi

    echo
    error "Playerbots SQL is NOT visible inside ac-worldserver."
    echo

    warning "Docker must mount the host modules directory into:"
    echo
    echo "  /azerothcore/modules"
    echo

    warning "Your docker-compose.override.yml should contain:"
    echo
    echo "services:"
    echo "  ac-worldserver:"
    echo "    volumes:"
    echo "      - ./modules:/azerothcore/modules:ro"
    echo "    environment:"
    echo "      - TZ=$(get_timezone)"
    echo

    return 1
}

# ============================================================
# Build / Rebuild
# ============================================================

run_build() {

    local operation="$1"

    local start_time
    local ticker_pid
    local result

    start_time="$(date +%s)"

    echo
    echo -e "${BOLD}${operation}${RESET}"
    echo "────────────────────────────────────────"
    echo

    (
        while true; do

            sleep 10

            local now
            local elapsed
            local minutes
            local seconds

            now="$(date +%s)"

            elapsed=$((now - start_time))

            minutes=$((elapsed / 60))
            seconds=$((elapsed % 60))

            echo -e \
                "${DIM}── ${CYAN}$(printf '%02d:%02d' "$minutes" "$seconds")${RESET}${DIM} elapsed ──${RESET}"

        done

    ) &

    ticker_pid=$!

    (
        cd "$CORE_DIR" || exit 1

        docker compose build
    )

    result=$?

    kill "$ticker_pid" 2>/dev/null
    wait "$ticker_pid" 2>/dev/null

    local end_time
    local total
    local total_minutes
    local total_seconds

    end_time="$(date +%s)"

    total=$((end_time - start_time))

    total_minutes=$((total / 60))
    total_seconds=$((total % 60))

    echo
    echo "────────────────────────────────────────"

    if [[ "$result" -eq 0 ]]; then
        success "$operation completed."
    else
        error "$operation failed."
    fi

    echo
    echo "Time: $(printf '%02d:%02d' "$total_minutes" "$total_seconds")"

    return "$result"
}


rebuild_server() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Rebuild"
    echo "────────────────────────────────────────"
    echo
    echo "Only the Docker images will be rebuilt."
    echo "Containers will NOT be started."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    echo

    info "Synchronizing Playerbots SQL..."

    if ! install_playerbots_standard_sql; then
        error "Playerbots SQL preparation failed."
        pause
        return
    fi

    echo

    fix_permissions

    run_build "Rebuild"

    pause
}

# ============================================================
# ac-db-import status
# ============================================================

get_container_status() {

    local service="$1"

    compose ps -a \
        --format '{{.Service}}|{{.State}}|{{.Status}}' \
        2>/dev/null |
    grep "^${service}|" |
    head -n 1
}


wait_for_db_import() {

    local tries=0

    info "Waiting for database import..."

    while true; do

        local status

        status="$(get_container_status "ac-db-import")"

        if [[ -z "$status" ]]; then
            warning "ac-db-import is not present."
            return 0
        fi

        # Running
        if echo "$status" | grep -q '|running|'; then

            sleep 2

            tries=$((tries + 1))

            if [[ "$tries" -ge 180 ]]; then

                error "ac-db-import did not finish in time."
                echo

                compose logs --tail=100 ac-db-import

                return 1

            fi

            continue

        fi

        # Exited successfully
        if echo "$status" |
            grep -qE '\|exited\|.*\(0\)'; then

            success "ac-db-import completed."
            return 0

        fi

        # Failed
        if echo "$status" |
            grep -qE '\|exited\|.*\([1-9][0-9]*\)'; then

            error "ac-db-import failed."
            echo

            compose logs --tail=150 ac-db-import

            return 1

        fi

        sleep 2

        tries=$((tries + 1))

        if [[ "$tries" -ge 180 ]]; then

            error "Could not determine ac-db-import status."

            compose logs --tail=100 ac-db-import

            return 1

        fi

    done
}

# ============================================================
# Server startup
# ============================================================

start_server() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Start"
    echo "────────────────────────────────────────"
    echo

    # Paused by AutoSleep? Wake it first, and reset the idle timer so
    # it isn't put back to sleep in the middle of starting up.
    if is_container_paused "ac-worldserver" || is_container_paused "ac-authserver"; then
        compose unpause ac-worldserver ac-authserver >/dev/null 2>&1 || true
        compose unpause ac-llm-chatter-bridge >/dev/null 2>&1 || true
    fi
    sleep_mark_activity

    # --------------------------------------------------------
    # Permissions
    # --------------------------------------------------------

    info "Checking Docker permissions..."

    if ! fix_permissions; then

        error "Could not fix permissions."
        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Playerbots module
    # --------------------------------------------------------

    if ! check_playerbots_module; then
        pause
        return
    fi

    # --------------------------------------------------------
    # Playerbots SQL
    # --------------------------------------------------------

    if ! check_playerbots_sql; then
        pause
        return
    fi

    echo

    info "Preparing Playerbots SQL for standard databases..."

    if ! install_playerbots_standard_sql; then

        error "Playerbots standard SQL preparation failed."
        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Playerbots config
    # --------------------------------------------------------

    info "Preparing Playerbots configuration..."

    if ! prepare_playerbots_config; then

        error "Playerbots configuration preparation failed."
        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Database
    # --------------------------------------------------------

    info "Starting database..."

    if ! compose up -d ac-database; then

        error "Failed to start ac-database."
        pause
        return

    fi

    echo

    if ! wait_for_database; then

        error "Database is not ready."
        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Official AC database import
    # --------------------------------------------------------

    # Safety net: no matter which flow got us here, make sure
    # custom/ doesn't contain a stale copy of any module's SQL
    # (Playerbots or otherwise), or dbimport aborts with
    # "Duplicate filename ... occurred".
    clean_module_sql_duplicates

    info "Starting AzerothCore database import..."

    if ! compose up -d ac-db-import; then

        error "Failed to start ac-db-import."
        pause
        return

    fi

    echo

    if ! wait_for_db_import; then

        echo
        warning "The database import failed."
        echo

        warning "Run:"
        echo
        echo "  cd \"$CORE_DIR\""
        echo "  docker compose logs ac-db-import"
        echo

        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Playerbots database
    #
    # THIS MUST HAPPEN BEFORE WORLDserver.
    # --------------------------------------------------------

    info "Preparing acore_playerbots..."

    if ! prepare_playerbots_database; then

        error "Playerbots database preparation failed."
        echo

        warning "The worldserver will NOT be started."

        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Check Docker module visibility.
    #
    # This catches the exact:
    #
    # Directory "/azerothcore/modules/mod-playerbots/..."
    # not exist
    #
    # problem before worldserver is started.
    # --------------------------------------------------------

    if ! check_playerbots_docker_visibility; then

        error "Docker cannot see the Playerbots SQL directory."
        echo
        warning "The worldserver will NOT be started."

        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Start remaining services
    # --------------------------------------------------------

    info "Starting AzerothCore..."

    if ! compose up -d \
        ac-client-data-init \
        ac-authserver \
        ac-worldserver; then

        error "Docker Compose failed."
        pause
        return

    fi

    start_llm_chatter_bridge

    echo

    sleep 5

    # --------------------------------------------------------
    # Detect worldserver crash
    # --------------------------------------------------------

    if ! compose ps \
        --status running \
        --services 2>/dev/null |
        grep -qx "ac-worldserver"; then

        echo
        error "ac-worldserver is not running."
        echo

        warning "Last worldserver log:"
        echo

        compose logs --tail=150 ac-worldserver

        echo
        pause
        return

    fi

    echo

    success "Server started."

    pause
}

# ============================================================
# Stop
# ============================================================

stop_server() {

    header

    check_core || {
        pause
        return
    }

    info "Stopping server..."

    if compose stop; then

        success "Server stopped."

    else

        error "Failed to stop server."

    fi

    pause
}

# ============================================================
# Restart
# ============================================================

restart_server() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    # Stop + the normal start (not "docker compose restart"): that
    # recreates the containers when a rebuild produced new images and
    # runs the database import, so new module SQL gets applied too.

    info "Restarting server..."

    compose unpause ac-worldserver ac-authserver >/dev/null 2>&1 || true

    if ! compose stop ac-llm-chatter-bridge ac-worldserver ac-authserver >/dev/null 2>&1; then
        compose stop ac-worldserver ac-authserver || {
            error "Failed to stop the server."
            pause
            return
        }
    fi

    start_server
}

# ============================================================
# Status
# ============================================================

status_server() {

    header

    check_core || {
        pause
        return
    }

    compose ps

    echo

    if database_has_tables "acore_playerbots"; then
        success "acore_playerbots: populated"
    else
        warning "acore_playerbots: empty or unavailable"
    fi

    pause
}

# ============================================================
# Logs
# ============================================================

logs_server() {

    check_core || return 1

    (
        cd "$CORE_DIR" || exit 1
        docker compose logs -f --tail=100
    )
}

# ============================================================
# Playerbots (required module -- other, optional modules are
# managed separately in the Modules section)
# ============================================================

install_playerbots() {

    check_core || return 1

    local target="$CORE_DIR/modules/mod-playerbots"

    if [[ -d "$target" ]]; then

        warning "mod-playerbots is already installed."
        return 0

    fi

    mkdir -p "$CORE_DIR/modules"

    info "Installing mod-playerbots..."
    echo

    git clone \
        --branch "$PLAYERBOTS_BRANCH" \
        "$PLAYERBOTS_REPO" \
        "$target"

    if [[ $? -eq 0 ]]; then

        success "mod-playerbots installed."
        return 0

    fi

    error "Failed to install mod-playerbots."

    return 1
}

# ============================================================
# Backup
# ============================================================

# ============================================================
# Configuration backup
#
# A small archive saved next to each database backup:
#   azerothcore-config-<timestamp>.tar.gz
# It holds the server/module .conf files, the list of installed
# modules with their exact commits (and whether each was enabled),
# docker-compose.override.yml (for reference) and the AutoSleep /
# AutoBackup settings. Game data stays in the .sql backup.
# Setup > Install can restore it (see restore_config_choose).
# Contains secrets (database password, API keys): mode 600.
# ============================================================

CONFIG_BACKUP_FORMAT=1

config_git() {
    # $1 = repo dir, rest = git arguments. safe.directory so it also
    # works when the backup runs as root against a user-owned repo.
    local dir="$1"
    shift
    git -c safe.directory='*' -C "$dir" "$@"
}

config_module_state() {

    # $1 = module name. Prints 1 / 0 (its Enable flag) or "-" when the
    # module has none or it can't be read.

    local name="$1" key conf f value
    local etc="$CORE_DIR/env/dist/etc/modules"

    if [[ "$name" == "mod-playerbots" ]]; then
        conf="$etc/playerbots.conf"
        [[ -f "$conf" ]] || { echo "-"; return; }
        key="$(playerbots_prefix "$conf").Enabled"
    else
        key="$(module_enable_key "$name")"
        [[ -n "$key" ]] || { echo "-"; return; }
        conf=""
        for f in "$etc"/*.conf; do
            [[ -f "$f" ]] || continue
            if grep -qE "^${key//./\\.}[[:space:]]*=" "$f" 2>/dev/null; then
                conf="$f"
                break
            fi
        done
        [[ -n "$conf" ]] || { echo "-"; return; }
    fi

    value="$(read_key_value "$conf" "$key")"
    echo "${value:--}"
}

create_config_backup() {

    # $1 = timestamp (the same one as the matching .sql), $2 = 1 for
    # quiet. Returns 0 on success.

    local timestamp="$1" quiet="${2:-0}"
    local archive="$BACKUP_DIR/azerothcore-config-$timestamp.tar.gz"
    local stage etc="$CORE_DIR/env/dist/etc"

    [[ -d "$CORE_DIR" ]] || return 1

    mkdir -p "$BACKUP_DIR"
    stage="$(mktemp -d)"

    local db_backup="-"
    [[ -s "$BACKUP_DIR/azerothcore-players-$timestamp.sql" ]] && db_backup="azerothcore-players-$timestamp.sql"

    {
        echo "format=$CONFIG_BACKUP_FORMAT"
        echo "created=$(date '+%F %T')"
        echo "timezone=$(get_timezone)"
        echo "db_backup=$db_backup"
        echo "core=$(config_git "$CORE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)|$(config_git "$CORE_DIR" rev-parse HEAD 2>/dev/null)"

        local d name repo branch commit
        for d in "$CORE_DIR"/modules/*/; do
            [[ -d "$d/.git" ]] || continue
            name="$(basename "$d")"
            repo="$(config_git "$d" remote get-url origin 2>/dev/null | sed -E 's#//[^/@]*@#//#')"
            branch="$(config_git "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
            commit="$(config_git "$d" rev-parse HEAD 2>/dev/null)"
            echo "module=$name|$repo|$branch|$commit|$(config_module_state "$name")"
        done
    } > "$stage/manifest.txt"

    # .conf files (worldserver, authserver, modules/*), keeping their paths.
    mkdir -p "$stage/etc"
    if [[ -d "$etc" ]]; then
        (
            cd "$etc" &&
            find . -type f -name '*.conf' -print0 |
                xargs -0 -r cp --parents -t "$stage/etc"
        )
    fi

    [[ -f "$CORE_DIR/docker-compose.override.yml" ]] &&
        cp "$CORE_DIR/docker-compose.override.yml" "$stage/docker-compose.override.yml"

    mkdir -p "$stage/script"
    [[ -f "$SLEEP_CONFIG_FILE" ]] && cp "$SLEEP_CONFIG_FILE" "$stage/script/.ac-sleep.conf"
    [[ -f "$BACKUP_CONFIG_FILE" ]] && cp "$BACKUP_CONFIG_FILE" "$stage/script/.ac-backup.conf"

    if (umask 077; tar -czf "$archive" -C "$stage" .) 2>/dev/null && [[ -s "$archive" ]]; then

        chmod 600 "$archive" 2>/dev/null
        rm -rf "$stage"

        if declare -F backup_log_message >/dev/null && [[ "$quiet" == "1" ]]; then
            backup_log_message "Config backup created: $(basename "$archive") ($(du -h "$archive" | cut -f1))"
        fi

        [[ "$quiet" == "1" ]] || success "Configuration backup: $(basename "$archive") ($(du -h "$archive" | cut -f1))"
        return 0

    fi

    rm -rf "$stage"
    rm -f "$archive"

    if declare -F backup_log_message >/dev/null && [[ "$quiet" == "1" ]]; then
        backup_log_message "Config backup FAILED."
    fi

    [[ "$quiet" == "1" ]] || warning "Configuration backup failed (the database backup is fine)."
    return 1
}

backup_databases() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    if ! compose ps \
        --status running \
        --services 2>/dev/null |
        grep -qx "ac-database"; then

        error "Database container is not running."
        pause
        return

    fi

    local password

    password="$(get_db_password)"

    if [[ -z "$password" ]]; then

        error "Could not read database password."
        pause
        return

    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp
    local backup_file

    timestamp="$(date +%F_%H-%M-%S)"

    backup_file="$BACKUP_DIR/azerothcore-players-$timestamp.sql"

    info "Creating database backup..."
    echo

    compose exec -T \
        ac-database \
        mysqldump \
        --databases acore_auth acore_characters acore_playerbots \
        --single-transaction \
        --routines \
        --triggers \
        -uroot \
        -p"$password" \
        > "$backup_file"

    local result=$?
    chmod 600 "$backup_file" 2>/dev/null

    if [[ "$result" -eq 0 ]]; then

        success "Backup completed."

        echo
        echo "  $backup_file"

        echo
        create_config_backup "$timestamp"

    else

        error "Backup failed."

        rm -f "$backup_file"

    fi

    pause
}

# ============================================================
# Restore
# ============================================================

restore_databases() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    local backup_dir="$BACKUP_DIR"

    if [[ ! -d "$backup_dir" ]]; then

        error "No backup directory found."
        pause
        return

    fi

    mapfile -t backups < <(
        find "$backup_dir" \
            -maxdepth 1 \
            -type f \
            -name 'azerothcore-*.sql' \
            -printf '%f\n' |
        sort -r
    )

    if [[ ${#backups[@]} -eq 0 ]]; then

        error "No backups found."
        pause
        return

    fi

    echo "Restore"
    echo "────────────────────────────────────────"
    echo

    local i=1

    for backup in "${backups[@]}"; do

        echo "  $i  $backup"

        i=$((i + 1))

    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select backup: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then

        error "Invalid selection."
        pause
        return

    fi

    local index=$((choice - 1))

    if (( index < 0 || index >= ${#backups[@]} )); then

        error "Invalid selection."
        pause
        return

    fi

    local selected="$backup_dir/${backups[$index]}"

    echo
    warning "This will overwrite the current databases."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        error "ac-database is not running. Start the server (or the database) first."
        pause
        return
    fi

    local password

    password="$(get_db_password)"

    if [[ -z "$password" ]]; then

        error "Could not read database password."
        pause
        return

    fi

    # The worldserver keeps characters in memory and would write them
    # back over the restored data: stop it (and authserver) first.
    local was_running=0

    if compose ps --status running --services 2>/dev/null | grep -qxE "ac-worldserver|ac-authserver" ||
       is_container_paused "ac-worldserver"; then
        was_running=1
        info "Stopping ac-worldserver and ac-authserver during the restore..."
        compose unpause ac-worldserver ac-authserver >/dev/null 2>&1 || true
        compose stop ac-llm-chatter-bridge >/dev/null 2>&1 || true
        compose stop ac-worldserver ac-authserver >/dev/null 2>&1
    fi

    info "Restoring database..."

    compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        < "$selected"

    local result=$?

    if [[ "$result" -eq 0 ]]; then
        success "Restore completed."
    else
        error "Restore failed."
    fi

    if [[ "$was_running" -eq 1 ]]; then
        info "The server was stopped for the restore -- use Start to bring it back."
    fi

    pause
}

# ============================================================
# Update Core
# ============================================================

update_core() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Update"
    echo "────────────────────────────────────────"
    echo

    info "Checking for AzerothCore updates..."

    if ! git -C "$CORE_DIR" fetch origin "$CORE_BRANCH"; then

        error "Failed to fetch updates."
        pause
        return

    fi

    local current_commit
    local latest_commit

    current_commit="$(
        git -C "$CORE_DIR" rev-parse HEAD
    )"

    latest_commit="$(
        git -C "$CORE_DIR" rev-parse "origin/$CORE_BRANCH"
    )"

    # Anything that changes code means a rebuild at the end.
    local code_changed=0

    local update_core_now=0

    if [[ "$current_commit" == "$latest_commit" ]]; then
        success "AzerothCore is already up to date."
    else
        echo
        info "New AzerothCore commits are available."
        echo
        if confirm "Update AzerothCore?"; then
            update_core_now=1
        else
            info "Core update skipped -- continuing with the modules."
        fi
    fi

    if [[ "$update_core_now" -eq 1 ]]; then

        echo

        # ----------------------------------------------------
        # Safety: require clean working tree (tracked files only;
        # volumes/, .env and the override aren't part of the repo).
        # ----------------------------------------------------

        if [[ -n "$(git -C "$CORE_DIR" status --porcelain --untracked-files=no)" ]]; then

            warning "AzerothCore working tree contains local changes."
            echo
            git -C "$CORE_DIR" status --short --untracked-files=no
            echo

            error "Update cancelled to avoid overwriting local changes."

            pause
            return

        fi

        info "Updating AzerothCore..."

        if ! git -C "$CORE_DIR" merge --ff-only \
            "origin/$CORE_BRANCH"; then

            error "Failed to update AzerothCore."
            pause
            return

        fi

        success "AzerothCore updated."
        code_changed=1

    fi

    # --------------------------------------------------------
    # Playerbots
    # --------------------------------------------------------

    if [[ -d "$CORE_DIR/modules/mod-playerbots/.git" ]]; then

        echo
        info "Updating mod-playerbots..."

        local pb_before
        pb_before="$(git -C "$CORE_DIR/modules/mod-playerbots" rev-parse HEAD 2>/dev/null)"

        if ! git -C \
            "$CORE_DIR/modules/mod-playerbots" \
            pull --ff-only; then

            error "Failed to update mod-playerbots."
            pause
            return

        fi

        [[ "$(git -C "$CORE_DIR/modules/mod-playerbots" rev-parse HEAD 2>/dev/null)" != "$pb_before" ]] && code_changed=1

        success "mod-playerbots updated."

    fi

    # --------------------------------------------------------
    # Other modules (core -> mod-playerbots -> the rest)
    # --------------------------------------------------------

    echo
    info "Updating the other installed modules..."
    echo

    do_update_all

    # --------------------------------------------------------
    # Synchronize SQL/config
    # --------------------------------------------------------

    echo
    info "Synchronizing Playerbots SQL..."

    if ! install_playerbots_standard_sql; then

        error "Failed to synchronize Playerbots SQL."
        pause
        return

    fi

    prepare_playerbots_config

    # --------------------------------------------------------
    # Permissions
    # --------------------------------------------------------

    echo
    fix_permissions

    # --------------------------------------------------------
    # Rebuild
    # --------------------------------------------------------

    [[ "$MODULES_CHANGED" -eq 1 ]] && code_changed=1

    if [[ "$code_changed" -eq 0 ]]; then
        echo
        success "Everything was already up to date -- no rebuild needed."
        pause
        return
    fi

    echo
    info "Rebuilding..."

    run_build "Rebuild"

    local result=$?
    MODULES_CHANGED=0

    echo

    if [[ "$result" -eq 0 ]]; then

        success "Update completed successfully."

        if compose ps --status running --services 2>/dev/null | grep -qx "ac-worldserver" ||
           is_container_paused "ac-worldserver"; then
            info "The server is still running the previous build -- Restart it to use the new one."
        else
            info "Start the server to use the new build."
        fi

    else

        error "Update completed, but rebuild failed."
        warning "The server keeps the previous build until a rebuild succeeds."

    fi

    pause
}

# ============================================================
# Dependencies
# ============================================================

install_dependencies() {

    if command -v git >/dev/null 2>&1 &&
       command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then

        success "Dependencies ready."
        return 0

    fi

    info "Installing dependencies..."

    sudo apt update

    # --------------------------------------------------------
    # Git
    # --------------------------------------------------------

    if ! command -v git >/dev/null 2>&1; then

        sudo apt install -y git

    fi

    # --------------------------------------------------------
    # Docker
    # --------------------------------------------------------

    if ! command -v docker >/dev/null 2>&1; then

        sudo apt install -y \
            ca-certificates \
            curl

        sudo install \
            -m 0755 \
            -d \
            /etc/apt/keyrings

        # Docker's repository per distro (Raspberry Pi OS 64-bit
        # reports "debian"); anything unknown falls back to debian.
        local docker_os
        docker_os="$(. /etc/os-release && echo "$ID")"
        case "$docker_os" in
            debian|ubuntu|raspbian) ;;
            *) docker_os="debian" ;;
        esac

        sudo curl -fsSL \
            "https://download.docker.com/linux/${docker_os}/gpg" \
            -o /etc/apt/keyrings/docker.asc

        sudo chmod a+r \
            /etc/apt/keyrings/docker.asc

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_os} \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
            sudo tee /etc/apt/sources.list.d/docker.list \
            >/dev/null

        sudo apt update

        sudo apt install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        sudo usermod -aG docker "$USER"

        warning "Your user was added to the docker group."
        warning "Log out and back in before using Docker without sudo."

        return 1

    fi

    # --------------------------------------------------------
    # Docker Compose
    # --------------------------------------------------------

    if ! docker compose version >/dev/null 2>&1; then

        sudo apt update

        sudo apt install -y \
            docker-compose-plugin

    fi

    success "Dependencies ready."
}

# ============================================================
# Install
# ============================================================

# ============================================================
# Configuration restore (used by Setup > Install)
#
# Flow: restore_config_choose (pick a saved configuration from a
# local file or from the cloud, review it) -> the install pins the
# core/Playerbots to the saved commits -> restore_config_apply
# (modules + .conf files + bridge service) -> restore_config_notes.
# ============================================================

RESTORE_DIR=""
RESTORE_ARCHIVE=""
RESTORE_DB_FILE=""
RESTORE_REMOTE=""
RESTORE_MODE="exact"
RESTORE_SKIP=" "
RESTORE_FAILED=()
RESTORE_INSTALLED=()

manifest_get() {
    grep -m1 "^$1=" "$RESTORE_DIR/manifest.txt" 2>/dev/null | cut -d= -f2-
}

manifest_modules() {
    grep '^module=' "$RESTORE_DIR/manifest.txt" 2>/dev/null | cut -d= -f2-
}

valid_manifest_module() {
    # $1 name  $2 repo  $3 branch  $4 commit
    [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] &&
    [[ "$2" =~ ^(https://|git@)[A-Za-z0-9._/:@-]+$ ]] &&
    [[ "$3" =~ ^[A-Za-z0-9._/-]+$ ]] &&
    [[ "$4" =~ ^[0-9a-f]{7,40}$ ]]
}

pin_repo_to_commit() {

    # $1 = repo dir, $2 = branch, $3 = commit. Puts the branch at the
    # commit (not a detached HEAD, so a later Update can still fast-
    # forward it). Returns 1 if the commit isn't in the repo.

    local dir="$1" branch="$2" commit="$3"

    config_git "$dir" cat-file -e "${commit}^{commit}" 2>/dev/null || return 1

    if [[ "$branch" == "HEAD" ]] || [[ -z "$branch" ]]; then
        config_git "$dir" checkout -q "$commit" 2>/dev/null
        return $?
    fi

    config_git "$dir" checkout -q -B "$branch" "$commit" 2>/dev/null || return 1
    config_git "$dir" branch -q --set-upstream-to="origin/$branch" "$branch" 2>/dev/null || true
    return 0
}

restore_config_pick_local() {

    local archives name size

    while true; do

        echo
        mapfile -t archives < <(
            find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-config-*.tar.gz' \
                -printf '%f\n' 2>/dev/null | sort -r
        )

        if [[ ${#archives[@]} -eq 0 ]]; then

            warning "No configuration backups found in:"
            echo "  $BACKUP_DIR"
            echo
            info "Copy a file named azerothcore-config-<date>.tar.gz into that folder,"
            info "then refresh."
            echo
            echo "  1  Refresh"
            echo
            echo "  0  Back"
            echo

            read -r -p "Select: " choice || exit 0
            case "$choice" in
                1) continue ;;
                0) return 1 ;;
                *) error "Invalid selection." ;;
            esac
            continue

        fi

        local i=1
        for name in "${archives[@]}"; do
            size="$(du -h "$BACKUP_DIR/$name" | cut -f1)"
            echo "  $i  $name  ($size)"
            i=$((i + 1))
        done

        echo
        echo "  r  Refresh"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        if [[ "$choice" == "0" ]]; then
            return 1
        elif [[ "$choice" == "r" ]] || [[ "$choice" == "R" ]]; then
            continue
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#archives[@]} )); then
            RESTORE_ARCHIVE="$BACKUP_DIR/${archives[$((choice - 1))]}"
            RESTORE_REMOTE=""
            return 0
        else
            error "Invalid selection."
        fi

    done
}

restore_config_pick_cloud() {

    if ! command -v rclone >/dev/null 2>&1; then

        warning "rclone is not installed."

        if confirm "Install it now?"; then
            install_rclone
        fi

        command -v rclone >/dev/null 2>&1 || { error "rclone is still not available."; return 1; }

    fi

    if [[ -z "$(rclone listremotes 2>/dev/null)" ]]; then

        warning "rclone has no remotes configured yet."

        if confirm "Run rclone's setup wizard now?"; then
            rclone config
        fi

        [[ -n "$(rclone listremotes 2>/dev/null)" ]] || { error "No rclone remote available."; return 1; }

    fi

    echo
    info "Configured remotes:"
    rclone listremotes 2>/dev/null | sed 's/^/    /'
    echo

    local remote
    read -r -p "Remote folder (e.g. gdrive:AzerothCore-Backups)${RCLONE_REMOTE:+ [$RCLONE_REMOTE]}: " remote
    remote="${remote:-$RCLONE_REMOTE}"

    if [[ -z "$remote" ]]; then
        error "No remote entered."
        return 1
    fi

    info "Looking for configuration backups in $remote ..."

    local raw
    raw="$(timeout 60 rclone lsf "$remote" --files-only --format "tsp" --separator "|" 2>/dev/null)" || {
        error "Could not list $remote (wrong name, offline or not authorized)."
        return 1
    }

    local -a items
    mapfile -t items < <(
        awk -F'|' '$3 ~ /^azerothcore-config-.*\.tar\.gz$/' <<< "$raw" | sort -t'|' -k3 -r
    )

    if [[ ${#items[@]} -eq 0 ]]; then
        warning "No azerothcore-config-*.tar.gz files in $remote."
        return 1
    fi

    local i=1 item t s n
    echo
    for item in "${items[@]}"; do
        IFS="|" read -r t s n <<< "$item"
        echo "  $i  $n  ($(numfmt --to=iec "$s" 2>/dev/null || echo "$s B"), $t)"
        i=$((i + 1))
    done

    echo
    echo "  0  Back"
    echo

    local choice
    read -r -p "Select: " choice || exit 0

    [[ "$choice" == "0" ]] && return 1

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#items[@]} )); then
        error "Invalid selection."
        return 1
    fi

    IFS="|" read -r t s n <<< "${items[$((choice - 1))]}"

    mkdir -p "$BACKUP_DIR"

    info "Downloading $n ..."

    if ! rclone copyto "${remote%/}/$n" "$BACKUP_DIR/$n" 2>/dev/null || [[ ! -s "$BACKUP_DIR/$n" ]]; then
        error "Download failed."
        rm -f "$BACKUP_DIR/$n"
        return 1
    fi

    chmod 600 "$BACKUP_DIR/$n" 2>/dev/null
    success "Saved to $BACKUP_DIR/$n"

    RESTORE_ARCHIVE="$BACKUP_DIR/$n"
    RESTORE_REMOTE="$remote"
    return 0
}

restore_config_load() {

    # $1 = archive. Extracts it, shows what it contains and asks how to
    # restore it. Leaves RESTORE_DIR set on success, empty otherwise.

    local archive="$1" stage

    RESTORE_DIR=""
    RESTORE_MODE="exact"
    RESTORE_SKIP=" "

    if tar -tzf "$archive" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))'; then
        error "That archive contains unsafe paths -- not using it."
        return 1
    fi

    stage="$(mktemp -d)"

    if ! (umask 077; tar -xzf "$archive" -C "$stage" --no-same-owner) 2>/dev/null ||
       [[ ! -f "$stage/manifest.txt" ]]; then
        error "Not a valid configuration backup (manifest.txt missing)."
        rm -rf "$stage"
        return 1
    fi

    RESTORE_DIR="$stage"

    local fmt
    fmt="$(manifest_get format)"

    if ! [[ "$fmt" =~ ^[0-9]+$ ]] || (( fmt > CONFIG_BACKUP_FORMAT )); then
        error "This backup was made by a newer version of the script (format ${fmt:-?}) -- can't read it."
        rm -rf "$stage"
        RESTORE_DIR=""
        return 1
    fi

    echo
    echo "Configuration backup"
    echo "────────────────────────────────────────"
    info "Created      : $(manifest_get created)"
    info "Database file: $(manifest_get db_backup)"

    local core_branch core_commit
    IFS="|" read -r core_branch core_commit <<< "$(manifest_get core)"
    info "Core         : $core_branch @ ${core_commit:0:9}"
    echo

    local -a names=()
    local line name repo branch commit state label n=0

    echo "  Modules"
    while IFS= read -r line; do

        [[ -z "$line" ]] && continue
        IFS="|" read -r name repo branch commit state <<< "$line"

        if ! valid_manifest_module "$name" "$repo" "$branch" "$commit"; then
            warning "Ignoring a module entry with unexpected values: ${name:-?}"
            continue
        fi

        case "$state" in
            1) label="enabled" ;;
            0) label="disabled" ;;
            *) label="no enable flag" ;;
        esac

        if [[ "$name" == "mod-playerbots" ]]; then
            echo "     -  $name  (required)  ${commit:0:9}  $label"
        else
            n=$((n + 1))
            names+=("$name")
            local note=""
            find_module "$name" >/dev/null 2>&1 || note="  (not in this script's module list)"
            echo "    $n  $name  ${commit:0:9}  $label${note}"
            echo "         $repo"
        fi

    done < <(manifest_modules)

    echo
    info "The repositories above will be cloned and compiled -- check they're yours."
    echo

    echo "  Versions"
    echo "    1  Exact versions from the backup (recommended)"
    echo "    2  Latest versions"
    echo

    local choice
    read -r -p "Select [1]: " choice

    case "$choice" in
        2) RESTORE_MODE="latest" ;;
        *) RESTORE_MODE="exact" ;;
    esac

    if [[ ${#names[@]} -gt 0 ]]; then

        local skip_input skip_n
        read -r -p "Modules to NOT reinstall (numbers separated by spaces, Enter = none): " skip_input

        for skip_n in $skip_input; do
            if [[ "$skip_n" =~ ^[0-9]+$ ]] && (( skip_n >= 1 && skip_n <= ${#names[@]} )); then
                RESTORE_SKIP+="${names[$((skip_n - 1))]} "
            fi
        done

    fi

    echo

    if ! confirm "Use this backup (${RESTORE_MODE} versions) for the restore?"; then
        rm -rf "$stage"
        RESTORE_DIR=""
        return 1
    fi

    # Fetch the matching database backup if it's in the cloud but not here.
    local db
    db="$(manifest_get db_backup)"
    RESTORE_DB_FILE="$db"

    if [[ -n "$RESTORE_REMOTE" ]] && [[ "$db" != "-" ]] && [[ ! -s "$BACKUP_DIR/$db" ]]; then

        if rclone lsf "$RESTORE_REMOTE" --files-only 2>/dev/null | grep -qx "$db"; then

            info "Downloading its database backup ($db)..."
            if rclone copyto "${RESTORE_REMOTE%/}/$db" "$BACKUP_DIR/$db" 2>/dev/null && [[ -s "$BACKUP_DIR/$db" ]]; then
                chmod 600 "$BACKUP_DIR/$db" 2>/dev/null
                success "Saved to $BACKUP_DIR/$db"
            else
                rm -f "$BACKUP_DIR/$db"
                warning "Download failed -- copy it into $BACKUP_DIR yourself before the database step."
            fi

        else
            warning "The matching database backup ($db) isn't on that remote."
        fi

    fi

    return 0
}

restore_config_choose() {

    # Restore mode of Install: a backup MUST be chosen (no skip).
    # Returns 1 only if the user goes Back to the Install menu.

    RESTORE_DIR=""
    RESTORE_FAILED=()
    RESTORE_INSTALLED=()

    local choice

    while true; do

        echo
        echo "Where is the backup?"
        echo
        echo "  1  A file in the backups folder"
        echo "  2  The cloud (rclone)"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) restore_config_pick_local || continue ;;
            2) restore_config_pick_cloud || continue ;;
            0) return 1 ;;
            *) error "Invalid selection."; continue ;;
        esac

        # Loaded and confirmed, and its database backup is here ->
        # done. Otherwise pick again: nothing is installed without both.
        restore_config_load "$RESTORE_ARCHIVE" && [[ -n "$RESTORE_DIR" ]] || continue
        restore_database_select && return 0

        rm -rf "$RESTORE_DIR"
        RESTORE_DIR=""

    done
}

restore_database_select() {

    # Restore mode, before anything is installed: makes sure the
    # database backup is in the backups folder. Uses the .sql the
    # configuration backup names, or one picked from the folder.
    # Sets RESTORE_DB_FILE. Returns 1 on Back (pick another backup).

    local db="${RESTORE_DB_FILE:-}"
    local -a sqls
    local choice

    while true; do

        if [[ -n "$db" ]] && [[ "$db" != "-" ]] && [[ -s "$BACKUP_DIR/$db" ]]; then
            RESTORE_DB_FILE="$db"
            success "Database backup: $db"
            return 0
        fi

        mapfile -t sqls < <(
            find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' -size +0 \
                -printf '%f\n' 2>/dev/null | sort -r
        )

        echo
        if [[ -n "$RESTORE_DB_FILE" ]] && [[ "$RESTORE_DB_FILE" != "-" ]]; then
            warning "Its database backup is not in $BACKUP_DIR:"
            echo "  $RESTORE_DB_FILE"
        else
            warning "This configuration backup has no database backup linked to it."
        fi
        info "Copy it into that folder and refresh, or pick another one."
        info "Nothing is installed until a database backup is available."
        echo

        local i=1 name
        for name in "${sqls[@]}"; do
            echo "  $i  $name"
            i=$((i + 1))
        done
        [[ ${#sqls[@]} -gt 0 ]] && echo
        echo "  r  Refresh"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        if [[ "$choice" == "0" ]]; then
            return 1
        elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#sqls[@]} )); then
            db="${sqls[$((choice - 1))]}"
        elif [[ "$choice" != "r" ]] && [[ "$choice" != "R" ]]; then
            error "Invalid selection."
        fi

    done
}

restore_database_required() {

    # Restore mode, after the build: imports RESTORE_DB_FILE (checked
    # by restore_database_select before installing).

    local db="$RESTORE_DB_FILE"

    if [[ ! -s "$BACKUP_DIR/$db" ]]; then
        error "The database backup is gone from $BACKUP_DIR: $db"
        info "Copy it back into that folder."
        return 1
    fi

    echo
    info "Restoring the database from $db ..."
    info "Starting the database container..."

    compose up -d ac-database

    echo

    if ! wait_for_database; then
        error "Could not bring up the database to restore into."
        return 1
    fi

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        error "Could not read the database password."
        return 1
    fi

    if compose exec -T ac-database mysql -uroot -p"$password" < "$BACKUP_DIR/$db"; then
        success "Database restored ($db)."
        return 0
    fi

    error "Database restore failed."
    return 1
}

restore_config_pin_core() {

    [[ -n "$RESTORE_DIR" ]] || return 0
    [[ "$RESTORE_MODE" == "exact" ]] || return 0

    local core_branch core_commit
    IFS="|" read -r core_branch core_commit <<< "$(manifest_get core)"

    [[ "$core_commit" =~ ^[0-9a-f]{7,40}$ ]] || return 0

    if pin_repo_to_commit "$CORE_DIR" "$CORE_BRANCH" "$core_commit"; then
        success "Core pinned to ${core_commit:0:9}."
    else
        warning "Core commit ${core_commit:0:9} not found -- using the latest $CORE_BRANCH."
    fi
}

restore_config_pin_playerbots() {

    [[ -n "$RESTORE_DIR" ]] || return 0
    [[ "$RESTORE_MODE" == "exact" ]] || return 0

    local line name repo branch commit state

    while IFS= read -r line; do

        IFS="|" read -r name repo branch commit state <<< "$line"
        [[ "$name" == "mod-playerbots" ]] || continue
        [[ "$commit" =~ ^[0-9a-f]{7,40}$ ]] || return 0

        if pin_repo_to_commit "$CORE_DIR/modules/mod-playerbots" "$PLAYERBOTS_BRANCH" "$commit"; then
            success "mod-playerbots pinned to ${commit:0:9}."
        else
            warning "mod-playerbots commit ${commit:0:9} not found -- using the latest."
        fi

        return 0

    done < <(manifest_modules)
}

restore_config_apply() {

    [[ -n "$RESTORE_DIR" ]] || return 0

    echo
    info "Restoring the saved configuration..."
    echo

    # --- Modules ----------------------------------------------

    local line name repo branch commit state target

    while IFS= read -r line; do

        [[ -z "$line" ]] && continue
        IFS="|" read -r name repo branch commit state <<< "$line"

        valid_manifest_module "$name" "$repo" "$branch" "$commit" || continue
        [[ "$name" == "mod-playerbots" ]] && continue

        if [[ "$RESTORE_SKIP" == *" $name "* ]]; then
            info "Skipping $name (as requested)."
            continue
        fi

        target="$CORE_DIR/modules/$name"

        if [[ -d "$target" ]]; then
            RESTORE_INSTALLED+=("$name")
            continue
        fi

        info "Installing $name..."

        local clone_ok=0
        if [[ "$branch" == "HEAD" ]]; then
            git clone "$repo" "$target" && clone_ok=1
        else
            git clone --branch "$branch" "$repo" "$target" && clone_ok=1
        fi

        if [[ "$clone_ok" -ne 1 ]]; then
            error "Could not clone $name."
            RESTORE_FAILED+=("$name")
            continue
        fi

        if [[ "$RESTORE_MODE" == "exact" ]]; then
            if pin_repo_to_commit "$target" "$branch" "$commit"; then
                success "$name pinned to ${commit:0:9}."
            else
                warning "$name: commit ${commit:0:9} not found -- using the latest $branch."
            fi
        else
            success "$name installed (latest)."
        fi

        RESTORE_INSTALLED+=("$name")

    done < <(manifest_modules)

    clean_module_sql_duplicates

    # --- .conf files ------------------------------------------

    local etc="$CORE_DIR/env/dist/etc"
    local -A dist_for=()
    local d dist f

    for d in "$CORE_DIR"/modules/*/; do
        [[ -d "$d" ]] || continue
        while IFS= read -r dist; do
            [[ -n "$dist" ]] && dist_for["$(basename "${dist%.dist}")"]="$dist"
        done < <(find_dist_files "$d")
    done

    for dist in "$etc"/modules/*.conf.dist; do
        [[ -f "$dist" ]] || continue
        [[ -n "${dist_for[$(basename "${dist%.dist}")]:-}" ]] || dist_for["$(basename "${dist%.dist}")"]="$dist"
    done

    mkdir -p "$etc/modules"

    local rel dest base restored copied=0 skipped=0

    if [[ -d "$RESTORE_DIR/etc" ]]; then

        while IFS= read -r -d '' f; do

            rel="${f#"$RESTORE_DIR/etc/"}"
            dest="$etc/$rel"
            base="$(basename "$rel")"

            if [[ "$rel" == modules/* ]]; then

                if [[ -z "${dist_for[$base]:-}" ]]; then
                    skipped=$((skipped + 1))
                    continue
                fi

                cp "$f" "$dest"
                restored="$(update_conf_from_dist "${dist_for[$base]}" "$dest")"
                rm -f "$dest.bak"
                copied=$((copied + 1))

            else

                mkdir -p "$(dirname "$dest")"
                cp "$f" "$dest"
                copied=$((copied + 1))

            fi

        done < <(find "$RESTORE_DIR/etc" -type f -name '*.conf' -print0)

    fi

    success "Settings restored: $copied file(s)."
    [[ "$skipped" -gt 0 ]] && info "$skipped module .conf file(s) skipped (module not installed)."

    # --- Docker override: bridge service ----------------------

    if [[ -d "$CORE_DIR/modules/mod-llm-chatter" ]]; then
        add_llm_chatter_bridge_service || true

        # The saved .conf has the old install's database password.
        local llm_conf="$etc/modules/mod_llm_chatter.conf"
        if [[ -f "$llm_conf" ]] && grep -q '^LLMChatter.Database.Password' "$llm_conf"; then
            conf_set_value "$llm_conf" "LLMChatter.Database.Password" "$(env_db_password)"
        fi
    fi

    # --- AutoSleep / AutoBackup settings --------------------

    if [[ -f "$RESTORE_DIR/script/.ac-sleep.conf" ]] || [[ -f "$RESTORE_DIR/script/.ac-backup.conf" ]]; then

        echo
        if confirm "Also restore the AutoSleep / AutoBackup settings?"; then
            # These files are sourced by the script: keep only plain
            # NAME=value lines, never anything that could run code.
            local pattern='^[A-Z_]+=("[A-Za-z0-9._:/@ +-]*"|[A-Za-z0-9._:/@+-]*)$'
            [[ -f "$RESTORE_DIR/script/.ac-sleep.conf" ]] &&
                grep -E "$pattern" "$RESTORE_DIR/script/.ac-sleep.conf" > "$SLEEP_CONFIG_FILE"
            [[ -f "$RESTORE_DIR/script/.ac-backup.conf" ]] &&
                grep -E "$pattern" "$RESTORE_DIR/script/.ac-backup.conf" > "$BACKUP_CONFIG_FILE" &&
                chmod 600 "$BACKUP_CONFIG_FILE" 2>/dev/null
            success "AutoSleep / AutoBackup settings restored (the services still need enabling)."
        fi

    fi

    return 0
}

restore_config_notes() {

    [[ -n "$RESTORE_DIR" ]] || return 0

    echo
    echo "Restore summary"
    echo "────────────────────────────────────────"

    if [[ ${#RESTORE_INSTALLED[@]} -gt 0 ]]; then
        success "Modules: ${RESTORE_INSTALLED[*]}"
    fi

    if [[ ${#RESTORE_FAILED[@]} -gt 0 ]]; then
        warning "Could NOT be installed: ${RESTORE_FAILED[*]}"
        info "Install them later from Modules (the repository or commit may be gone)."
    fi

    echo
    info "Still to do by hand:"
    echo "    - Start the server, then re-enable AutoSleep and AutoBackup (their menus)."

    if [[ " ${RESTORE_INSTALLED[*]} " == *" mod-llm-chatter "* ]]; then
        echo "    - mod-llm-chatter: Modules > mod-llm-chatter > Configure (installs Ollama"
        echo "      and the model on this machine)."
    fi

    if [[ " ${RESTORE_INSTALLED[*]} " == *" mod-playerbots-city-life "* ]]; then
        echo "    - mod-playerbots-city-life: its world data is applied when the module is"
        echo "      installed; reinstall it (Remove, then Install) once the server has run once."
    fi

    if [[ " ${RESTORE_INSTALLED[*]} " == *" mod-ah-bot-plus "* ]]; then
        echo "    - mod-ah-bot-plus: its character comes back with the database backup."
    fi

    if command -v rclone >/dev/null 2>&1; then
        :
    else
        echo "    - rclone is not installed here: AutoBackup > Remote backup, if you use it."
    fi

    rm -rf "$RESTORE_DIR"
    RESTORE_DIR=""
}

install_server() {

    header

    echo "Install"
    echo "────────────────────────────────────────"
    echo

    if [[ -d "$CORE_DIR" ]]; then

        warning "AzerothCore already exists."
        echo
        echo "  $CORE_DIR"

        pause
        return

    fi

    local install_mode=""

    while [[ -z "$install_mode" ]]; do

        echo "  1  New install"
        echo "  2  Restore from a backup"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " install_mode || exit 0

        case "$install_mode" in
            1)
                install_mode="new"
                ;;
            2)
                install_mode="restore"
                echo
                info "Restore reinstalls your modules and settings from a configuration"
                info "backup (azerothcore-config-<date>.tar.gz), then its database backup."
                if ! restore_config_choose; then
                    install_mode=""
                    echo
                fi
                ;;
            0)
                return
                ;;
            *)
                error "Invalid selection."
                install_mode=""
                echo
                ;;
        esac

    done

    echo

    if ! install_dependencies; then

        pause
        return

    fi

    info "Cloning AzerothCore..."
    echo
    echo "  Repository: $CORE_REPO"
    echo "  Branch:     $CORE_BRANCH"
    echo

    git clone \
        --branch "$CORE_BRANCH" \
        "$CORE_REPO" \
        "$CORE_DIR"

    if [[ $? -ne 0 ]]; then

        error "Failed to clone AzerothCore."

        pause
        return

    fi

    success "AzerothCore cloned."
    restore_config_pin_core

    echo

    configure_timezone
    configure_database_env
    prepare_directories

    echo

    info "Installing mod-playerbots..."
    echo

    if ! install_playerbots; then

        error "Playerbot installation failed."

        pause
        return

    fi

    restore_config_pin_playerbots

    echo

    info "Preparing Docker Compose override for Playerbots..."

    write_playerbots_docker_override

    echo

    info "Preparing Playerbots SQL..."

    if ! check_playerbots_sql; then

        error "Playerbots SQL is missing."

        pause
        return

    fi

    install_playerbots_standard_sql

    echo

    info "Preparing Playerbots configuration..."

    prepare_playerbots_config

    restore_config_apply

    echo

    # --------------------------------------------------------
    # Permissions BEFORE Docker build/import.
    # --------------------------------------------------------

    info "Fixing Docker permissions..."

    if ! fix_permissions; then

        error "Permission setup failed."

        pause
        return

    fi

    echo

    # --------------------------------------------------------
    # Build
    # --------------------------------------------------------

    info "Starting initial Docker build..."
    echo

    run_build "Build"

    local result=$?

    echo

    if [[ "$result" -ne 0 ]]; then

        error "Installation failed during build."

        pause
        return

    fi

    success "Docker build completed."

    echo

    # --------------------------------------------------------
    # Restore mode: the database backup (no skip)
    # --------------------------------------------------------

    if [[ "$install_mode" == "restore" ]]; then

        mkdir -p "$BACKUP_DIR"

        until restore_database_required; do
            echo
            confirm "Try the database restore again?" && continue
            warning "The server is installed, but WITHOUT your database."
            info "Restore it with Server > Restore before starting the server:"
            echo "  $BACKUP_DIR/$RESTORE_DB_FILE"
            break
        done

        echo

    fi

    restore_config_notes

    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    if confirm "Start the server now?"; then

        start_server

    else

        echo
        info "Server remains OFFLINE."
        info "Use Start when you want to run AzerothCore."

        pause

    fi
}

# ============================================================
# Uninstall
# ============================================================

# ============================================================
# Uninstall
# ============================================================

cleanup_sleep_backup_services() {

    # The Sleep and Backup sections install systemd services
    # against this install. Leaving them running after an
    # uninstall just means broken loops (nothing left to
    # pause/back up), so remove them as part of the uninstall.

    local units=(
        ac-manager-sleep-proxy.service
        ac-manager-sleep.service
        ac-manager-backup.timer
        ac-manager-backup.service
    )

    local found=()
    local unit

    for unit in "${units[@]}"; do
        [[ -f "/etc/systemd/system/$unit" ]] && found+=("$unit")
    done

    [[ ${#found[@]} -eq 0 ]] && return 0

    echo
    info "Also stopping and removing Sleep/Backup section services for this server:"
    for unit in "${found[@]}"; do
        echo "    - $unit"
    done

    for unit in "${found[@]}"; do
        sudo systemctl disable --now "$unit" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/$unit"
    done

    sudo systemctl daemon-reload

    success "Sleep/Backup services stopped and removed."

    return 0
}

human_age() {

    # $1 = epoch seconds. Prints "5 min", "3 h" or "2 days" ago.

    local now diff
    now="$(date +%s)"
    diff=$((now - $1))
    (( diff < 0 )) && diff=0

    if (( diff < 3600 )); then
        echo "$((diff / 60)) min ago"
    elif (( diff < 86400 )); then
        echo "$((diff / 3600)) h ago"
    else
        echo "$((diff / 86400)) day(s) ago"
    fi
}

show_last_backups_before_delete() {

    # Shown before anything is deleted: the newest backup actually on
    # disk, and the newest one actually on the rclone remote (queried
    # live, not taken from the log), so it's clear what survives.

    local newest="" size mtime
    local newest_name=""

    echo "Last backups"
    echo "────────────────────────────────────────"

    # --- Local -------------------------------------------------

    if [[ -d "$BACKUP_DIR" ]]; then
        newest="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' -size +0 2>/dev/null | sort -r | head -n1)"
    fi

    if [[ -n "$newest" ]]; then

        newest_name="$(basename "$newest")"
        size="$(du -h "$newest" | cut -f1)"
        mtime="$(stat -c %Y "$newest" 2>/dev/null)"

        info "Local : $newest_name  ($size, $(date -d "@$mtime" '+%Y-%m-%d %H:%M' 2>/dev/null), $(human_age "$mtime"))"
        echo "        in $BACKUP_DIR"
        echo "        (this folder is NOT deleted by uninstall)"

    else

        warning "Local : no backups found in $BACKUP_DIR"

    fi

    local newest_cfg=""
    [[ -d "$BACKUP_DIR" ]] &&
        newest_cfg="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-config-*.tar.gz' -size +0 2>/dev/null | sort -r | head -n1)"

    if [[ -n "$newest_cfg" ]]; then
        info "Config: $(basename "$newest_cfg")  (modules + settings, restorable from Setup > Install)"
    else
        warning "Config: no configuration backup yet (Server > Backup creates one)."
    fi

    # --- Remote ------------------------------------------------

    if [[ -z "${RCLONE_REMOTE:-}" ]]; then

        warning "Remote: not configured -- there is no copy outside this machine."

    elif ! command -v rclone >/dev/null 2>&1; then

        warning "Remote: $RCLONE_REMOTE is configured but rclone is not installed -- can't check it."

    else

        local raw rc listing remote_latest remote_time remote_size remote_name

        raw="$(timeout 30 rclone lsf "$RCLONE_REMOTE" --files-only --format "tsp" --separator "|" 2>/dev/null)"
        rc=$?

        listing="$(awk -F'|' '$3 ~ /^azerothcore-.*\.sql$/' <<< "$raw" | sort -t'|' -k3 -r)"

        if [[ "$rc" -ne 0 ]]; then

            warning "Remote: could not query $RCLONE_REMOTE (offline or not authorized?) -- not verified."

            local logged
            logged="$(grep "Uploaded to remote:" "$LOG_FILE" 2>/dev/null | tail -n1)"
            [[ -n "$logged" ]] && echo "        last upload in the log (not verified): $logged"

        elif [[ -z "$listing" ]]; then

            warning "Remote: $RCLONE_REMOTE is reachable but has no backups."

        else

            remote_latest="$(head -n1 <<< "$listing")"
            IFS="|" read -r remote_time remote_size remote_name <<< "$remote_latest"

            info "Remote: $remote_name  ($(numfmt --to=iec "$remote_size" 2>/dev/null || echo "${remote_size} B"), $remote_time)"
            echo "        at $RCLONE_REMOTE  (verified now)"

            if [[ -n "$newest_name" ]] && [[ "$remote_name" != "$newest_name" ]]; then
                if grep -q "|$newest_name\$" <<< "$listing"; then
                    echo "        the newest local backup is also on the remote."
                else
                    warning "The newest local backup ($newest_name) is NOT on the remote."
                fi
            elif [[ -n "$newest_name" ]]; then
                echo "        it matches the newest local backup."
            fi

        fi

    fi

    echo
}

remove_core_dir() {

    # Deletes the AzerothCore folder. Files created by the database
    # container may belong to another user, so if a plain delete
    # leaves anything behind, retry with sudo. Only reports success
    # when the folder is really gone.

    rm -rf -- "$CORE_DIR" 2>/dev/null

    if [[ -e "$CORE_DIR" ]]; then
        warning "Some files couldn't be deleted as your user -- retrying with sudo."
        sudo rm -rf -- "$CORE_DIR"
    fi

    if [[ -e "$CORE_DIR" ]]; then
        error "Could not delete $CORE_DIR. Remove it manually: sudo rm -rf \"$CORE_DIR\""
        return 1
    fi

    return 0
}

uninstall_server() {

    # Always a full removal (server files, database, client data).
    # First thing: a final database + configuration backup; only then
    # the DELETE confirmation. The backups/ folder is never touched.

    header

    check_core || {
        pause
        return
    }

    echo "Uninstall"
    echo "────────────────────────────────────────"
    echo

    # --- Final backup ---------------------------------------

    info "Final backup (database + configuration) into:"
    echo "    $BACKUP_DIR"
    echo

    local backup_ok=0

    if check_docker >/dev/null 2>&1; then

        if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
            info "Starting the database for the backup..."
            compose up -d ac-database >/dev/null 2>&1
            wait_for_database >/dev/null 2>&1
        fi

        do_backup 0 && backup_ok=1

    fi

    echo

    if [[ "$backup_ok" -ne 1 ]]; then

        error "The final backup failed."
        echo

        if ! confirm "Continue with the uninstall WITHOUT a final backup?"; then
            info "Nothing was deleted."
            pause
            return
        fi

        echo

    fi

    show_last_backups_before_delete

    echo
    warning "This will permanently delete:"
    echo "    - The AzerothCore server files (source, config, docker-compose)"
    echo "    - The ENTIRE DATABASE (all accounts, characters, guilds, mail, everything)"
    echo "    - The client data (volumes/)"
    echo

    local confirm_word

    read -r -p "Type DELETE to confirm: " confirm_word || exit 0

    if [[ "$confirm_word" != "DELETE" ]]; then
        warning "Not confirmed. Nothing was deleted."
        [[ "$backup_ok" -eq 1 ]] && info "The backup just made stays in $BACKUP_DIR."
        pause
        return
    fi

    # --- Removal --------------------------------------------

    echo

    cleanup_sleep_backup_services

    compose down --volumes 2>/dev/null || true

    remove_core_dir || { pause; return; }

    echo
    success "AzerothCore completely removed."
    [[ "$backup_ok" -eq 1 ]] && info "The final backup is in $BACKUP_DIR (Setup > Install can restore it)."

    pause
}

# ============================================================
# Main menu
# ============================================================

# ============================================================
# Configure
# ============================================================

configure_server() {

    while true; do

        header
        echo "Configure"
        echo "────────────────────────────────────────"
        echo

        echo "  1  Change realm name"
        echo
        echo "  2  Change XP rates"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) change_realm_name ;;
            2) xp_rates_menu ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

# ------------------------------------------------------------
# XP rates (worldserver.conf)
# ------------------------------------------------------------

XP_RATE_KEYS=(
    "Rate.XP.Kill|Killing creatures"
    "Rate.XP.Quest|Quests"
    "Rate.XP.Quest.DF|Dungeon Finder (LFG) quests"
    "Rate.XP.Explore|Discovering new areas"
    "Rate.XP.Pet|Hunter pets"
)

worldserver_conf_path() {
    echo "$CORE_DIR/env/dist/etc/worldserver.conf"
}

xp_rate_default() {

    # $1 = key. The default comes from worldserver.conf.dist (the
    # file shipped with the server); falls back to 1.

    local dist="$CORE_DIR/env/dist/etc/worldserver.conf.dist" value=""

    [[ -f "$dist" ]] && value="$(read_key_value "$dist" "$1")"

    echo "${value:-1}"
}

valid_xp_rate() {
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]
}

show_xp_rates() {

    # $1 = worldserver.conf. Prints the notes table: each rate, what
    # it affects, the current value and the default.

    local conf="$1" entry key label current default

    printf "  %-18s %-30s %8s %9s\n" "Setting" "Applies to" "Current" "Default"
    echo "  ──────────────────────────────────────────────────────────────"

    for entry in "${XP_RATE_KEYS[@]}"; do

        IFS="|" read -r key label <<< "$entry"

        current="$(read_key_value "$conf" "$key")"
        default="$(xp_rate_default "$key")"

        printf "  %-18s %-30s %8s %9s\n" "$key" "$label" "${current:-?}" "$default"

    done

    echo
}

set_xp_rate() {

    # $1 = conf, $2 = key, $3 = value.
    conf_set_value "$1" "$2" "$3"
}

xp_rates_menu() {

    while true; do

        header
        echo "Change XP rates"
        echo "────────────────────────────────────────"
        echo

        local conf
        conf="$(worldserver_conf_path)"

        if [[ ! -f "$conf" ]]; then
            error "worldserver.conf not found at: $conf"
            info "It's created the first time the server starts. Start the server"
            info "once (Server > Start), then come back here."
            pause
            return 1
        fi

        info "Notes"
        echo "  - Each value is a multiplier: 1 = default (normal XP), 2 = double,"
        echo "    0.5 = half, 0 = no XP from that source."
        echo "  - Battleground XP rates are separate and are not changed here."
        echo "  - Applies on the next worldserver restart (Server > Restart)."
        echo "  - Option 2 multiplies every rate by a factor, keeping the differences"
        echo "    between them (e.g. x2 turns 1 / 2 / 0.5 into 2 / 4 / 1)."
        echo "  - Option 4 puts every rate back to its default."
        echo

        show_xp_rates "$conf"

        echo "  1  Set all rates to one value"
        echo "  2  Multiply all rates by a factor"
        echo "  3  Set a single rate"
        echo
        echo "  4  Reset all to default"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in

            1)
                local value entry key
                read -r -p "New value for all rates (e.g. 2): " value

                if ! valid_xp_rate "$value"; then
                    error "Enter a plain number (e.g. 1, 2, 0.5)."
                    pause
                    continue
                fi

                [[ "$value" == "0" ]] && warning "0 means no XP at all from these sources."

                if confirm "Set all XP rates to $value?"; then
                    for entry in "${XP_RATE_KEYS[@]}"; do
                        IFS="|" read -r key _ <<< "$entry"
                        set_xp_rate "$conf" "$key" "$value"
                    done
                    success "All XP rates set to $value."
                    warning "Restart ac-worldserver for the change to take effect."
                fi
                pause
                ;;

            2)
                local factor entry key current result
                read -r -p "Multiply all rates by (e.g. 2 = double, 0.5 = half): " factor

                if ! valid_xp_rate "$factor"; then
                    error "Enter a plain number (e.g. 2, 0.5)."
                    pause
                    continue
                fi

                [[ "$factor" == "0" ]] && warning "0 would set every rate to 0 (no XP at all)."

                if confirm "Multiply all XP rates by $factor?"; then
                    for entry in "${XP_RATE_KEYS[@]}"; do
                        IFS="|" read -r key _ <<< "$entry"
                        current="$(read_key_value "$conf" "$key")"
                        valid_xp_rate "$current" || current="$(xp_rate_default "$key")"
                        result="$(awk -v a="$current" -v b="$factor" 'BEGIN { printf "%.4f", a * b }' |
                                  sed -E 's/(\.[0-9]*[1-9])0+$/\1/; s/\.0+$//')"
                        set_xp_rate "$conf" "$key" "$result"
                        echo "  $key: $current -> $result"
                    done
                    success "XP rates multiplied by $factor."
                    warning "Restart ac-worldserver for the change to take effect."
                fi
                pause
                ;;

            3)
                local n i=1 entry key label value
                echo
                for entry in "${XP_RATE_KEYS[@]}"; do
                    IFS="|" read -r key label <<< "$entry"
                    echo "  $i  $key  ($label)"
                    i=$((i + 1))
                done
                echo
                read -r -p "Which one: " n

                if ! [[ "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > ${#XP_RATE_KEYS[@]} )); then
                    error "Invalid selection."
                    pause
                    continue
                fi

                IFS="|" read -r key label <<< "${XP_RATE_KEYS[$((n - 1))]}"
                read -r -p "New value for $key [default $(xp_rate_default "$key")]: " value

                if ! valid_xp_rate "$value"; then
                    error "Enter a plain number (e.g. 1, 2, 0.5)."
                    pause
                    continue
                fi

                set_xp_rate "$conf" "$key" "$value"
                success "$key set to $value."
                warning "Restart ac-worldserver for the change to take effect."
                pause
                ;;

            4)
                local entry key
                if confirm "Reset all XP rates to their default?"; then
                    for entry in "${XP_RATE_KEYS[@]}"; do
                        IFS="|" read -r key _ <<< "$entry"
                        set_xp_rate "$conf" "$key" "$(xp_rate_default "$key")"
                    done
                    success "XP rates reset to default."
                    warning "Restart ac-worldserver for the change to take effect."
                fi
                pause
                ;;

            0) return ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

change_realm_name() {

    header
    echo "Change Realm Name"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }

    if ! compose ps \
        --status running \
        --services 2>/dev/null |
        grep -qx "ac-database"; then

        error "ac-database is not running."
        info "Start the server first."
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

    info "Current realmlist entries:"
    echo

    compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -t \
        -e "SELECT id, name, address, port FROM acore_auth.realmlist;" \
        2>/dev/null

    echo

    local realm_id new_name

    read -r -p "Realm id to rename [1]: " realm_id
    realm_id="${realm_id:-1}"

    if ! [[ "$realm_id" =~ ^[0-9]+$ ]]; then
        error "Realm id must be a number."
        pause
        return 1
    fi

    read -r -p "New realm name: " new_name

    if [[ -z "$new_name" ]]; then
        warning "No name entered. Nothing changed."
        pause
        return
    fi

    new_name="$(sql_clean "$new_name")"

    echo
    confirm "Set realmlist.name = '$new_name' for realm id $realm_id?" || {
        pause
        return
    }

    if compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -e "UPDATE acore_auth.realmlist SET name='${new_name}' WHERE id = ${realm_id};" \
        2>/dev/null; then

        success "Realm name updated to '$new_name'."
        info "authserver refreshes the realmlist from the database periodically --"
        info "no restart needed, it should take effect within moments."

    else

        error "Failed to update the realm name."

    fi

    pause
}

print_server_status() {

    if [[ -d "$CORE_DIR" ]] &&
       [[ -f "$CORE_DIR/docker-compose.yml" ]]; then

        if compose ps \
            --status running \
            --services 2>/dev/null |
            grep -qx "ac-worldserver"; then

            echo -e "Server      ${GREEN}● ONLINE${RESET}"

        elif is_container_paused "ac-worldserver"; then

            echo -e "Server      ${YELLOW}● SLEEPING${RESET}"

        else

            echo -e "Server      ${RED}● OFFLINE${RESET}"

        fi

        if compose ps \
            --status running \
            --services 2>/dev/null |
            grep -qx "ac-database"; then

            echo -e "Database    ${GREEN}● ONLINE${RESET}"

        else

            echo -e "Database    ${RED}● OFFLINE${RESET}"

        fi

    else

        echo -e "Server      ${DIM}○ NOT INSTALLED${RESET}"

    fi
}

main_menu() {

    while true; do

        header

        print_server_status

        echo
        echo "  1  Start"
        echo "  2  Stop"
        echo "  3  Restart"
        echo "  4  Status"
        echo "  5  Logs"

        echo
        echo "  6  Backup"
        echo "  7  Restore"

        echo
        echo "  8  Configure"

        echo
        echo "  0  Back"

        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in

            1)
                start_server
                ;;

            2)
                stop_server
                ;;

            3)
                restart_server
                ;;

            4)
                status_server
                ;;

            5)
                logs_server
                ;;

            6)
                backup_databases
                ;;

            7)
                restore_databases
                ;;

            8)
                configure_server
                ;;

            0)

                clear_screen
                return
                ;;

            *)

                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Command line mode
# ============================================================

server_usage() {
    echo "Usage: $(basename "$0") server [start|stop|restart|status|logs|backup|restore|configure]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  start          start the server"
    echo "  stop           stop the server"
    echo "  restart        restart the server"
    echo "  status         show container status"
    echo "  logs           follow the live logs"
    echo "  backup         database backup + configuration archive"
    echo "  restore        restore a database backup"
    echo "  configure      realm name, XP rates"
}

manager_dispatch() {

    case "${1:-}" in

        -h|--help)
            server_usage
            ;;

        start)
            start_server
            ;;

        stop)
            stop_server
            ;;

        restart)
            restart_server
            ;;

        status)
            status_server
            ;;

        logs)
            logs_server
            ;;

        backup)
            backup_databases
            ;;

        restore)
            restore_databases
            ;;

        configure)
            configure_server
            ;;

        "")
            main_menu
            ;;

        *)
            error "Unknown command: $1"
            echo
            server_usage
            exit 1
            ;;

    esac
}

# ============================================================
# SECTION: setup
# ============================================================

# ============================================================
# AzerothCore Setup
#
# Install, update, rebuild and uninstall of AzerothCore itself,
# kept apart from the day-to-day server controls.
# ============================================================

setup_menu() {

    while true; do

        header "AzerothCore Setup"

        if [[ -d "$CORE_DIR" ]] &&
           [[ -f "$CORE_DIR/docker-compose.yml" ]]; then
            echo -e "Status   ${GREEN}● installed${RESET}"
        else
            echo -e "Status   ${DIM}○ not installed${RESET}"
        fi

        echo
        echo "  1  Rebuild"
        echo
        echo "  2  Update"
        echo
        echo "  3  Install"
        echo "  4  Uninstall"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in

            1) rebuild_server ;;
            2) update_core ;;
            3) install_server ;;
            4) uninstall_server ;;

            0)
                return
                ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

setup_usage() {
    echo "Usage: $(basename "$0") setup [install|update|rebuild|uninstall]"
    echo
    echo "  (no argument)   interactive menu"
    echo "  install         install AzerothCore + Playerbots (can restore a saved configuration)"
    echo "  update          update the core, Playerbots and every installed module"
    echo "  rebuild         rebuild the Docker images"
    echo "  uninstall       final backup, then remove everything (server + database)"
}

setup_dispatch() {

    case "${1:-menu}" in

        menu)
            setup_menu
            ;;

        install)
            install_server
            ;;

        update)
            update_core
            ;;

        rebuild)
            rebuild_server
            ;;

        uninstall)
            uninstall_server
            ;;

        -h|--help|help)
            setup_usage
            ;;

        *)
            error "Unknown setup command: $1"
            echo
            setup_usage
            exit 1
            ;;

    esac
}

# ============================================================
# SECTION: modules
# ============================================================

# ============================================================
# Modules section
#
# Installs, removes, updates, and configures optional AzerothCore
# modules.
#
# mod-playerbots is also listed here (it's shown first, since
# it's required for the install), but only for its status and its
# Configure menu (individual bot settings) -- its actual
# install/remove/update lifecycle
# stays entirely in the Setup section, since it's a required
# dependency, not optional.
#
# Installed/removed modules get picked up automatically by the
# docker-compose.override.yml the Setup section generates (it
# mounts the whole modules/ directory into ac-worldserver,
# regardless of what's inside it) -- this section only manages
# what's on disk under modules/. Installing, removing or updating a
# module triggers the (mandatory) rebuild automatically, unless it's
# postponed (see rebuild_if_modules_changed).
#
# Usage:
#   ./azerothcore-manager.sh modules                interactive menu
#   ./azerothcore-manager.sh modules list           show install status of every module
#   ./azerothcore-manager.sh modules install <n>    clone a module
#   ./azerothcore-manager.sh modules remove <n>     remove a module
#   ./azerothcore-manager.sh modules update [name]  update one module, or all installed ones
# ============================================================


# ============================================================
# Modules
#
# mod-playerbots is NOT in this array on purpose -- it's required
# for the install and is cloned/updated by the Setup section.
# It's handled separately (see "mod-playerbots" section below)
# and listed first in the menu, but only for status + Configure.
# ============================================================

MODULES=(
    "mod-ah-bot-plus|https://github.com/NathanHandley/mod-ah-bot-plus.git|master"
    "mod-autobalance|https://github.com/azerothcore/mod-autobalance.git|master"
    "mod-challenge-modes|https://github.com/ZhengPeiRu21/mod-challenge-modes.git|master"
    "mod-individual-progression|https://github.com/ZhengPeiRu21/mod-individual-progression.git|master"
    "mod-dungeon-clear|https://github.com/jrad7/mod-dungeon-clear.git|master"
    "mod-playerbots-city-life|https://github.com/vrzgames/mod-playerbots-city-life.git|main"
    "mod-llm-chatter|https://github.com/Hokken/mod-llm-chatter.git|master"
)















# ============================================================
# Core validation
# ============================================================











modules_db_query() {
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
# rebuild (Setup > Rebuild) doesn't choke on it.
# ============================================================



# ============================================================
# Install / remove / update
# ============================================================

# Set to 1 by do_install / do_remove / do_update_one when a module's
# code actually changed. The caller then runs the (mandatory) rebuild
# once via rebuild_if_modules_changed.
MODULES_CHANGED=0

rebuild_if_modules_changed() {

    # $1 = "ask" (menus: Enter = rebuild now, "n" = postpone) or
    # empty (rebuild straight away). The CLI flag --no-rebuild
    # sets MODULES_SKIP_REBUILD=1 to postpone without asking.

    if [[ "$MODULES_CHANGED" -ne 1 ]]; then
        info "No module code changed -- no rebuild needed."
        return 0
    fi

    local postpone=0 answer

    if [[ "${MODULES_SKIP_REBUILD:-0}" -eq 1 ]]; then
        postpone=1
    elif [[ "${1:-}" == "ask" ]]; then
        echo
        read -r -p "Rebuild now? (needed for the change to work) [Y/n]: " answer
        [[ "$answer" =~ ^[Nn]$ ]] && postpone=1
    fi

    if [[ "$postpone" -eq 1 ]]; then
        warning "Rebuild postponed. The change won't take effect until you run"
        warning "Setup > Rebuild (azerothcore-manager.sh setup rebuild)."
        return 0
    fi

    MODULES_CHANGED=0

    echo
    info "Module changes need a rebuild -- starting it now..."

    check_docker || return 1

    info "Synchronizing Playerbots SQL..."

    if ! install_playerbots_standard_sql; then
        error "Playerbots SQL preparation failed. Run Setup > Rebuild manually."
        return 1
    fi

    echo
    fix_permissions

    if run_build "Rebuild"; then
        success "Rebuild finished."
        info "Start (or restart) the server to run with the new build."
        return 0
    fi

    error "Rebuild failed. Fix the error above and run Setup > Rebuild."
    return 1
}

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
        MODULES_CHANGED=1

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

        if [[ "$name" == "mod-playerbots-city-life" ]]; then
            install_city_life_sql "$target"
        fi

        if [[ "$name" == "mod-llm-chatter" ]]; then
            show_llm_chatter_notes
            if confirm "Install Ollama, the bridge and configure everything now?"; then
                setup_llm_chatter || warning "Setup incomplete -- re-run it from this module's menu (Configure)."
            else
                info "Skipped. Run Configure in this module's menu later."
            fi
        fi

        return 0

    fi

    error "Failed to install $name."

    return 1
}

install_city_life_sql() {

    # mod-playerbots-city-life ships its world SQL under
    # data/sql/manual/ on purpose -- AzerothCore's dbimport only
    # auto-applies data/sql/db-world/, so this needs a manual
    # import into acore_world or the module has no hub data to
    # work with.

    local target="$1"
    local sql_file="$target/data/sql/manual/world_city_life.sql"

    if [[ ! -f "$sql_file" ]]; then
        warning "world_city_life.sql not found at the expected path -- check the module's own README."
        return 1
    fi

    if ! check_docker >/dev/null 2>&1; then
        warning "Docker not available right now -- apply this SQL manually later:"
        echo "    docker compose exec -T ac-database mysql -uroot -p<password> acore_world < $sql_file"
        return 1
    fi

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        warning "ac-database is not running -- apply this SQL manually once it's up:"
        echo "    docker compose exec -T ac-database mysql -uroot -p<password> acore_world < $sql_file"
        return 1
    fi

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        warning "Could not read the database password -- apply this SQL manually:"
        echo "    docker compose exec -T ac-database mysql -uroot -p<password> acore_world < $sql_file"
        return 1
    fi

    info "Applying world_city_life.sql to acore_world (required by this module)..."

    if compose exec -T ac-database \
        mysql -uroot -p"$password" acore_world < "$sql_file" 2>/dev/null; then
        success "world_city_life.sql applied."
    else
        error "Failed to apply world_city_life.sql -- check the module's README and apply it manually."
        return 1
    fi

    return 0
}

# ============================================================
# mod-llm-chatter
#
# LLM-generated bot chat. Unlike a plain module, it needs a
# separate Python "bridge" process that talks to the LLM, so
# installing it also sets up:
#   - Ollama on this host (local LLM) + a model,
#   - an ac-llm-chatter-bridge service in docker-compose.override.yml
#     (python:3.11-slim, mounts the module's tools/ and the config dir),
#   - mod_llm_chatter.conf (provider, model, Ollama URL, database).
# https://github.com/Hokken/mod-llm-chatter
# ============================================================

LLM_CHATTER_DEFAULT_MODEL="qwen3:8b"
LLM_CHATTER_HOST_ALIAS="host.docker.internal"
LLM_CHATTER_BLOCK_START="  # >>> ac-llm-chatter-bridge (managed by azerothcore-manager.sh)"
LLM_CHATTER_BLOCK_END="  # <<< ac-llm-chatter-bridge"

conf_set_value() {

    # $1 = conf path, $2 = key, $3 = value. Replaces the first
    # "key = ..." line, or appends it if the key isn't there. Done
    # in awk through the environment so values holding | & \ or
    # quotes (passwords, prompts) are written back untouched.

    local conf="$1" key="$2" value="$3" tmp
    tmp="$(mktemp)"

    K="$key" V="$value" awk '
        BEGIN { k = ENVIRON["K"]; v = ENVIRON["V"]; done = 0 }
        {
            if (!done && index($0, k) == 1) {
                rest = substr($0, length(k) + 1)
                if (rest ~ /^[ \t]*=/) {
                    print k " = " v
                    done = 1
                    next
                }
            }
            print
        }
        END { if (!done) print k " = " v }
    ' "$conf" > "$tmp" && cat "$tmp" > "$conf"

    rm -f "$tmp"
}

install_ollama_binary() {

    if command -v ollama >/dev/null 2>&1; then
        success "Ollama is already installed ($(ollama --version 2>/dev/null | head -n1))."
        return 0
    fi

    info "Installing Ollama via its official install script (ollama.com)."
    warning "This downloads and runs a script as root (curl | sh) -- the method"
    warning "recommended by Ollama itself."
    echo

    confirm "Continue with the official install script?" || return 1

    if curl -fsSL https://ollama.com/install.sh | sh; then
        success "Ollama installed."
        return 0
    fi

    error "Ollama install script failed (it may need zstd: sudo apt install zstd)."
    return 1
}

expose_ollama_to_containers() {

    # Ollama listens on 127.0.0.1 only by default; the bridge runs
    # in a container and reaches the host through the docker
    # gateway, so Ollama must listen on 0.0.0.0. The module also
    # asks for OLLAMA_CONTEXT_LENGTH (4096) to be set on the server.
    # Both go in one systemd drop-in.

    if ! command -v systemctl >/dev/null 2>&1 ||
       ! systemctl cat ollama.service >/dev/null 2>&1; then
        warning "No ollama systemd service found. Start Ollama yourself with:"
        echo "    OLLAMA_HOST=0.0.0.0 OLLAMA_CONTEXT_LENGTH=4096 ollama serve"
        return 0
    fi

    local dropin_dir="/etc/systemd/system/ollama.service.d"
    local dropin="$dropin_dir/azerothcore.conf"

    if [[ -f "$dropin" ]] &&
       grep -q "OLLAMA_HOST=0.0.0.0" "$dropin" &&
       grep -q "OLLAMA_CONTEXT_LENGTH" "$dropin"; then
        success "Ollama already listens on 0.0.0.0 with the module's context length."
        return 0
    fi

    warning "Listening on 0.0.0.0 makes Ollama reachable from your whole network."
    warning "Ollama has no authentication -- keep port 11434 closed to the internet"
    warning "(router/firewall), and allow it from docker if you use ufw."
    echo

    confirm "Make Ollama listen on 0.0.0.0 (systemd override)?" || {
        warning "Skipped. The bridge won't reach Ollama until it listens beyond 127.0.0.1."
        return 0
    }

    if sudo mkdir -p "$dropin_dir" &&
       printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0"\nEnvironment="OLLAMA_CONTEXT_LENGTH=4096"\n' |
           sudo tee "$dropin" >/dev/null &&
       sudo systemctl daemon-reload &&
       sudo systemctl enable ollama >/dev/null 2>&1 &&
       sudo systemctl restart ollama; then
        success "Ollama now listens on 0.0.0.0:11434 (context length 4096)."
        return 0
    fi

    error "Could not apply the systemd override."
    return 1
}

wait_for_ollama() {

    local i
    for i in $(seq 1 30); do
        if curl -fsS http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

llm_chatter_bridge_configured() {
    grep -qF "$LLM_CHATTER_BLOCK_START" "$CORE_DIR/docker-compose.override.yml" 2>/dev/null
}

add_llm_chatter_bridge_service() {

    # Adds the bridge service to docker-compose.override.yml (right
    # under "services:"), between markers so it can be removed
    # cleanly later. Same service definition as the module's README,
    # minus its "dev" profile so a normal start brings it up.

    local override="$CORE_DIR/docker-compose.override.yml"
    local timezone

    if [[ ! -f "$override" ]]; then
        write_playerbots_docker_override || return 1
    fi

    if llm_chatter_bridge_configured; then
        return 0
    fi

    if ! grep -q "^services:" "$override"; then
        warning "No 'services:' block in docker-compose.override.yml. Add the"
        warning "ac-llm-chatter-bridge service from the module's README manually."
        return 1
    fi

    timezone="$(get_timezone)"

    local block
    block="$(cat << EOB
$LLM_CHATTER_BLOCK_START
  ac-llm-chatter-bridge:
    container_name: ac-llm-chatter-bridge
    image: python:3.11-slim
    networks:
      - ac-network
    working_dir: /app
    environment:
      - PYTHONUNBUFFERED=1
      - TZ=$timezone
    extra_hosts:
      - "$LLM_CHATTER_HOST_ALIAS:host-gateway"
    command: >
      bash -c "
        pip install --quiet -r /app/requirements.txt &&
        python llm_chatter_bridge.py --config /config/mod_llm_chatter.conf
      "
    volumes:
      - ./modules/mod-llm-chatter/tools:/app:ro
      - ./env/dist/etc/modules:/config:ro
    restart: unless-stopped
    depends_on:
      ac-database:
        condition: service_healthy
$LLM_CHATTER_BLOCK_END
EOB
)"

    cp -f "$override" "$override.bak"

    BLOCK="$block" awk '
        { print }
        /^services:[[:space:]]*$/ && !added {
            print ENVIRON["BLOCK"]
            added = 1
        }
    ' "$override.bak" > "$override"

    success "docker-compose.override.yml: ac-llm-chatter-bridge service added."
    return 0
}

remove_llm_chatter_bridge_service() {

    local override="$CORE_DIR/docker-compose.override.yml"

    llm_chatter_bridge_configured || return 0

    if command -v docker >/dev/null 2>&1; then
        compose rm -sf ac-llm-chatter-bridge >/dev/null 2>&1 || true
    fi

    cp -f "$override" "$override.bak"

    S="$LLM_CHATTER_BLOCK_START" E="$LLM_CHATTER_BLOCK_END" awk '
        BEGIN { s = ENVIRON["S"]; e = ENVIRON["E"]; skip = 0 }
        $0 == s { skip = 1; next }
        skip && $0 == e { skip = 0; next }
        !skip { print }
    ' "$override.bak" > "$override"

    success "ac-llm-chatter-bridge removed from docker-compose.override.yml."
    return 0
}

start_llm_chatter_bridge() {

    # Called after the server starts/restarts: brings the bridge
    # up when the module is installed AND enabled, and stops it
    # when it's disabled so it doesn't idle for nothing.

    [[ -d "$CORE_DIR/modules/mod-llm-chatter" ]] || return 0
    llm_chatter_bridge_configured || return 0

    local conf value
    conf="$CORE_DIR/env/dist/etc/modules/mod_llm_chatter.conf"
    value="$(read_key_value "$conf" "LLMChatter.Enable")"

    if [[ "$value" == "1" ]]; then
        info "Starting ac-llm-chatter-bridge..."
        if compose up -d ac-llm-chatter-bridge >/dev/null 2>&1; then
            success "ac-llm-chatter-bridge running."
            info "Logs: docker compose logs -f ac-llm-chatter-bridge (in $CORE_DIR)"
        else
            warning "Could not start ac-llm-chatter-bridge. Try: docker compose up -d ac-llm-chatter-bridge"
        fi
    else
        compose stop ac-llm-chatter-bridge >/dev/null 2>&1 || true
    fi

    return 0
}

show_llm_chatter_notes() {

    echo
    info "mod-llm-chatter generates bot chat with an LLM through a small Python"
    info "bridge. Setup installs Ollama (local LLM), adds the bridge as a Docker"
    info "service, pulls a model and fills mod_llm_chatter.conf for you."
    echo
    warning "Local models need real hardware: the module's author recommends a"
    warning "8B+ instruct model and warns that consumer hardware / a Raspberry Pi"
    warning "gives very slow replies. A cloud provider (Anthropic, OpenAI, Google,"
    warning "OpenRouter) is an alternative -- set it in mod_llm_chatter.conf."
    echo
}

setup_llm_chatter() {

    local model="${1:-}"

    check_core || return 1
    check_docker || return 1

    if [[ ! -d "$CORE_DIR/modules/mod-llm-chatter" ]]; then
        error "mod-llm-chatter is not installed."
        return 1
    fi

    local conf
    conf="$(ensure_module_conf_containing_key "$CORE_DIR/modules/mod-llm-chatter" "LLMChatter.Provider")"

    if [[ -z "$conf" ]]; then
        error "mod_llm_chatter.conf could not be prepared."
        return 1
    fi

    # --- Ollama ------------------------------------------------

    install_ollama_binary || return 1
    expose_ollama_to_containers || true

    info "Waiting for the Ollama API..."

    if ! wait_for_ollama; then
        error "Ollama is not answering on http://127.0.0.1:11434."
        info "Check: systemctl status ollama"
        return 1
    fi

    if [[ -z "$model" ]]; then
        local current
        current="$(read_key_value "$conf" "LLMChatter.Model")"
        # The .dist ships a Claude model ID; only reuse a value that
        # looks like an Ollama tag we set earlier.
        if [[ "$(read_key_value "$conf" "LLMChatter.Provider")" != "ollama" ]]; then
            current=""
        fi
        current="${current:-$LLM_CHATTER_DEFAULT_MODEL}"
        info "Recommended: an instruct model of 8B or larger (e.g. qwen3:8b);"
        info "on weak hardware try qwen3:4b-instruct (may be less reliable)."
        read -r -p "Model to use [$current]: " model
        model="${model:-$current}"
    fi

    if [[ ! "$model" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
        error "Invalid model name: $model"
        return 1
    fi

    info "Pulling model $model (this can take a while)..."

    if ! ollama pull "$model"; then
        error "ollama pull failed."
        return 1
    fi

    if ! curl -fsS http://127.0.0.1:11434/api/tags | grep -qF "\"$model\""; then
        warning "The model doesn't show up in /api/tags under that exact name -- check: ollama list"
    fi

    # --- Module config ----------------------------------------

    conf_set_value "$conf" "LLMChatter.Provider" "ollama"
    conf_set_value "$conf" "LLMChatter.Model" "$model"
    conf_set_value "$conf" "LLMChatter.Ollama.BaseUrl" "http://$LLM_CHATTER_HOST_ALIAS:11434"

    # The bridge runs in its own container: it must reach the
    # database by its compose service name, not localhost.
    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        warning "Could not read the database password (is ac-database running?)."
        read -r -s -p "Database root password (Enter to set it manually later): " password
        echo
    fi

    conf_set_value "$conf" "LLMChatter.Database.Host" "ac-database"
    conf_set_value "$conf" "LLMChatter.Database.Port" "3306"
    conf_set_value "$conf" "LLMChatter.Database.User" "root"
    conf_set_value "$conf" "LLMChatter.Database.Name" "acore_characters"

    if [[ -n "$password" ]]; then
        conf_set_value "$conf" "LLMChatter.Database.Password" "$password"
    else
        warning "Set LLMChatter.Database.Password in $(basename "$conf") before enabling."
    fi

    success "$(basename "$conf"): provider ollama, model $model, database settings written."

    # --- Bridge service ---------------------------------------

    add_llm_chatter_bridge_service || true

    # --- Built-in bot chatter (the module replaces it) ---------

    local pbconf prefix k
    pbconf="$CORE_DIR/env/dist/etc/modules/playerbots.conf"

    if [[ -f "$pbconf" ]]; then

        # Use whichever prefix this file has (see playerbots_prefix).
        prefix="$(playerbots_prefix "$pbconf")"

        echo
        info "The module replaces the built-in bot chatter, so its README requires"
        info "turning that off in playerbots.conf (${prefix}.*)."

        # Current mod-playerbots has 6 of these; GuildFeedback only
        # exists under the old AiPlayerbot.* prefix.
        local -a chatter_keys=(EnableBroadcasts RandomBotTalk RandomBotEmote
                               RandomBotSuggestDungeons EnableGreet
                               RandomBotSayWithoutMaster)
        [[ "$prefix" == "AiPlayerbot" ]] && chatter_keys+=(GuildFeedback)

        if confirm "Apply those ${#chatter_keys[@]} settings now?"; then

            for k in "${chatter_keys[@]}"; do
                conf_set_value "$pbconf" "$prefix.$k" "0"
            done

            success "playerbots.conf updated."

        fi

    fi

    echo

    if confirm "Enable mod-llm-chatter now (LLMChatter.Enable = 1)?"; then
        conf_set_value "$conf" "LLMChatter.Enable" "1"
        success "LLMChatter.Enable = 1."
    else
        conf_set_value "$conf" "LLMChatter.Enable" "0"
        info "Left disabled. Enable it from the module's menu when ready."
    fi

    echo
    warning "The module needs a rebuild; then Start (or Restart) the server -- that"
    warning "also starts the bridge when the module is enabled."

    return 0
}

do_remove() {

    local name="$1"
    local target="$CORE_DIR/modules/$name"

    if [[ ! -d "$target" ]]; then
        warning "$name is not installed."
        return 1
    fi

    if [[ "$name" == "mod-llm-chatter" ]]; then
        remove_llm_chatter_bridge_service
    fi

    rm -rf -- "$target"
    MODULES_CHANGED=1

    success "$name removed."

    return 0
}

# update_conf_from_dist() is shared with the Setup section above
# -- same function, used here for module .conf files instead of
# playerbots.conf.

update_module_configs() {

    # $1 = module directory. For every *.conf.dist the module
    # ships, rebuilds the matching .conf from the fresh template,
    # restoring the admin's current values into it (see
    # update_conf_from_dist). Only runs during an actual module
    # update -- never touched just for Enable/Disable checks.

    local module_dir="$1"
    local dist conf restored

    while IFS= read -r dist; do

        [[ -z "$dist" ]] && continue

        conf="$(ensure_conf_for_dist "$dist")"
        restored="$(update_conf_from_dist "$dist" "$conf")"

        if [[ "${restored:-0}" -gt 0 ]]; then
            info "$(basename "$conf"): rebuilt from the updated template ($restored existing option(s) restored)."
        fi

    done < <(find_dist_files "$module_dir")

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

    local before after
    before="$(git -C "$target" rev-parse HEAD 2>/dev/null)"

    if git -C "$target" pull --ff-only; then
        after="$(git -C "$target" rev-parse HEAD 2>/dev/null)"
        [[ "$before" != "$after" ]] && MODULES_CHANGED=1
        success "$name updated."
        update_module_configs "$target"
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
    # update_core() rebuilds right after this on its own; the module
    # menu / CLI call rebuild_if_modules_changed instead.

    return 0
}

# ============================================================
# mod-playerbots (required -- listed for status/Configure only;
# install/remove/update stay in the Setup section)
# ============================================================

# Configurable settings (names without the prefix -- Playerbots. or
# AiPlayerbot., see playerbots_prefix). Fields:
#   name | label | type | min | max | recommended | note
# type: int / float. recommended empty = no recommendation.
PLAYERBOTS_SETTINGS=(
    "DisabledWithoutRealPlayer|Bots only with a real player online|int|0|1||0 = bots log in when the server starts. 1 = bots log in ~30 s after a real player logs in and log out ~300 s after the last one leaves."
    "DisableMoveSplinePath|Smooth bot movement paths|int|0|2||0 = enabled. 1 = disabled in battlegrounds/arenas only. 2 = disabled everywhere. Disabling makes movement more erratic but is needed for stuns, snares and roots to work on bots."
    "MaxMovementSearchTime|Max movement path search time|int|1|1000||Higher gives better movement on slopes."
    "AutoGearQualityLimit|Max gear quality (autogear)|int|1|5||1 normal, 2 uncommon, 3 rare, 4 epic, 5 legendary."
    "RandomGearLoweringChance|Chance of lower-quality gear|float|0|1||Chance a random bot gets less-than-optimized gear. 0 = never, 1 = always."
    "MinRandomBots|Random bots (minimum)|int|0|100000||Random bot count. Keep it lower than or equal to the maximum."
    "MaxRandomBots|Random bots (maximum)|int|0|100000||Random bot count. Keep it higher than or equal to the minimum."
)

# Recommended performance values (applied together by option 2).
PLAYERBOTS_RECOMMENDED=(
    "DisabledWithoutRealPlayer|1"
    "DisableMoveSplinePath|1"
    "MaxMovementSearchTime|5"
    "AutoGearQualityLimit|4"
    "RandomGearLoweringChance|0.75"
)

playerbots_conf_path() {
    echo "$CORE_DIR/env/dist/etc/modules/playerbots.conf"
}

playerbots_recommended_value() {
    # $1 = setting name (no prefix). Prints its recommended value, if any.
    local entry name value
    for entry in "${PLAYERBOTS_RECOMMENDED[@]}"; do
        IFS="|" read -r name value <<< "$entry"
        [[ "$name" == "$1" ]] && { echo "$value"; return; }
    done
}

playerbots_default_value() {
    # $1 = playerbots.conf, $2 = setting name. The default comes from
    # playerbots.conf.dist next to it (the shipped file).
    local dist="${1}.dist" value=""
    [[ -f "$dist" ]] && value="$(read_key_value "$dist" "$(playerbots_prefix "$dist").$2")"
    echo "$value"
}

valid_playerbots_value() {

    # $1 = value, $2 = type, $3 = min, $4 = max.

    local value="$1" type="$2" min="$3" max="$4"

    if [[ "$type" == "int" ]]; then
        [[ "$value" =~ ^[0-9]+$ ]] || return 1
    else
        [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    fi

    awk -v v="$value" -v lo="$min" -v hi="$max" 'BEGIN { exit !(v + 0 >= lo + 0 && v + 0 <= hi + 0) }'
}

show_playerbots_settings() {

    # $1 = playerbots.conf. Table of every setting: current, default
    # and recommended value.

    local conf="$1" prefix entry name label current default rec
    prefix="$(playerbots_prefix "$conf")"

    printf "  %-3s %-36s %8s %8s %12s\n" "#" "Setting" "Current" "Default" "Recommended"
    echo "  ───────────────────────────────────────────────────────────────────────"

    local i=1
    for entry in "${PLAYERBOTS_SETTINGS[@]}"; do

        IFS="|" read -r name label _ <<< "$entry"

        current="$(read_key_value "$conf" "$prefix.$name")"
        default="$(playerbots_default_value "$conf" "$name")"
        rec="$(playerbots_recommended_value "$name")"

        printf "  %-3s %-36s %8s %8s %12s\n" "$i" "$label" "${current:-?}" "${default:--}" "${rec:--}"
        i=$((i + 1))

    done

    echo
}

change_playerbots_setting() {

    # $1 = playerbots.conf, $2 = index (1-based) in PLAYERBOTS_SETTINGS.

    local conf="$1" idx="$2"
    local prefix entry name label type min max note rec current default value other

    prefix="$(playerbots_prefix "$conf")"
    entry="${PLAYERBOTS_SETTINGS[$((idx - 1))]}"
    IFS="|" read -r name label type min max _ note <<< "$entry"

    current="$(read_key_value "$conf" "$prefix.$name")"
    default="$(playerbots_default_value "$conf" "$name")"
    rec="$(playerbots_recommended_value "$name")"

    echo
    echo "  $prefix.$name"
    echo "  $note"
    echo "  Allowed: $type from $min to $max."
    echo "  Current: ${current:-?}   Default: ${default:--}   Recommended: ${rec:--}"
    echo

    read -r -p "New value (Enter = keep, d = default${rec:+, r = recommended}): " value

    case "$value" in
        "") warning "No change made."; return 0 ;;
        d|D)
            if [[ -z "$default" ]]; then
                error "Default value not available (playerbots.conf.dist missing)."
                return 1
            fi
            value="$default"
            ;;
        r|R)
            if [[ -z "$rec" ]]; then
                error "No recommended value for this setting."
                return 1
            fi
            value="$rec"
            ;;
    esac

    if ! valid_playerbots_value "$value" "$type" "$min" "$max"; then
        error "Invalid value. Allowed: $type from $min to $max."
        return 1
    fi

    # Keep min <= max for the random bot count.
    if [[ "$name" == "MinRandomBots" ]]; then
        other="$(read_key_value "$conf" "$prefix.MaxRandomBots")"
        if [[ "$other" =~ ^[0-9]+$ ]] && (( value > other )); then
            error "MinRandomBots ($value) can't be greater than MaxRandomBots ($other). Change the maximum first."
            return 1
        fi
    elif [[ "$name" == "MaxRandomBots" ]]; then
        other="$(read_key_value "$conf" "$prefix.MinRandomBots")"
        if [[ "$other" =~ ^[0-9]+$ ]] && (( value < other )); then
            error "MaxRandomBots ($value) can't be lower than MinRandomBots ($other). Change the minimum first."
            return 1
        fi
    fi

    conf_set_value "$conf" "$prefix.$name" "$value"
    success "$prefix.$name = $value."
    warning "Restart ac-worldserver for the change to take effect."
    return 0
}

playerbots_configure_menu() {

    while true; do

        header "AzerothCore Modules"
        echo "Configure mod-playerbots"
        echo "────────────────────────────────────────"
        echo

        check_core || { pause; return 1; }

        if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
            error "mod-playerbots is not installed."
            info "It's installed automatically by azerothcore-manager.sh setup > Install."
            pause
            return 1
        fi

        local conf
        conf="$(playerbots_conf_path)"

        if [[ ! -f "$conf" ]]; then
            error "playerbots.conf not found at: $conf"
            info "Run azerothcore-manager.sh setup > Install (or Update) first."
            pause
            return 1
        fi

        info "Notes"
        echo "  - Pick a number to change one setting; its description is shown first."
        echo "  - Option r (recommended) applies the performance-tuned values to the"
        echo "    five settings that have one; Default comes from playerbots.conf.dist."
        echo "  - Changes apply on the next worldserver restart (Server > Restart)."
        echo

        show_playerbots_settings "$conf"

        local count=${#PLAYERBOTS_SETTINGS[@]}

        echo "  1-$count  Change a setting"
        echo
        echo "  r  Apply recommended performance settings"
        echo "  d  Reset all settings to default"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in

            [1-9]*)
                if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
                    change_playerbots_setting "$conf" "$choice"
                    pause
                else
                    error "Invalid selection."
                    sleep 1
                fi
                ;;

            r|R)
                local entry name value prefix
                prefix="$(playerbots_prefix "$conf")"
                echo
                info "This sets:"
                for entry in "${PLAYERBOTS_RECOMMENDED[@]}"; do
                    IFS="|" read -r name value <<< "$entry"
                    echo "    $prefix.$name = $value"
                done
                echo
                if confirm "Apply them?"; then
                    for entry in "${PLAYERBOTS_RECOMMENDED[@]}"; do
                        IFS="|" read -r name value <<< "$entry"
                        conf_set_value "$conf" "$prefix.$name" "$value"
                    done
                    success "Recommended performance settings applied."
                    warning "Restart ac-worldserver for the change to take effect."
                fi
                pause
                ;;

            d|D)
                local entry name default prefix skipped=0
                prefix="$(playerbots_prefix "$conf")"
                echo
                if confirm "Reset all settings in this list to their default?"; then
                    for entry in "${PLAYERBOTS_SETTINGS[@]}"; do
                        IFS="|" read -r name _ <<< "$entry"
                        default="$(playerbots_default_value "$conf" "$name")"
                        if [[ -n "$default" ]]; then
                            conf_set_value "$conf" "$prefix.$name" "$default"
                        else
                            skipped=1
                        fi
                    done
                    success "Settings reset to default."
                    [[ "$skipped" -eq 1 ]] && warning "Some defaults weren't available (playerbots.conf.dist missing) and were skipped."
                    warning "Restart ac-worldserver for the change to take effect."
                fi
                pause
                ;;

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

        header "AzerothCore Modules"
        echo "mod-playerbots"
        echo "────────────────────────────────────────"
        echo

        if [[ -d "$CORE_DIR/modules/mod-playerbots" ]]; then
            echo -e "Status   ${GREEN}● installed${RESET} (required, managed by the Setup section)"
        else
            echo -e "Status   ${RED}○ not installed${RESET} (run azerothcore-manager.sh setup > Install)"
        fi

        echo
        local pb_conf pb_status
        pb_conf="$(playerbots_conf_path)"
        pb_status="$(enable_status_label "$(read_key_value "$pb_conf" "$(playerbots_prefix "$pb_conf").Enabled")")"
        echo -e "  1  Enable / Disable   [${pb_status}]"
        echo
        echo "  2  Configure"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1)
                local conf
                conf="$(playerbots_conf_path)"
                if [[ ! -f "$conf" ]]; then
                    error "playerbots.conf not found at: $conf"
                    info "Run azerothcore-manager.sh setup > Install (or Update) first."
                    pause
                else
                    toggle_single_key "mod-playerbots" "$conf" "$(playerbots_prefix "$conf").Enabled"
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
# the Server section.
# ============================================================

module_enable_key() {
    # Prints the module's Enable key, or nothing if it doesn't
    # support one.
    case "$1" in
        mod-autobalance)             echo "AutoBalance.Enable.Global" ;;
        mod-challenge-modes)         echo "ChallengeModes.Enable" ;;
        mod-individual-progression)  echo "IndividualProgression.Enable" ;;
        mod-llm-chatter)             echo "LLMChatter.Enable" ;;
        *)                           echo "" ;;
    esac
}

read_key_value() {
    # $1 = conf path, $2 = key. Prints the trimmed current value, or nothing.
    [[ -f "$1" ]] || return
    grep -E "^${2//./\\.}[[:space:]]*=" "$1" 2>/dev/null |
        tail -n1 |
        sed -E 's/^[^=]+=[[:space:]]*//; s/[[:space:]]+$//'
}

enable_status_label() {
    # $1 = current raw value ("1" / "0" / anything else / empty).
    case "$1" in
        1) echo -e "${GREEN}Enabled${RESET}" ;;
        0) echo -e "${RED}Disabled${RESET}" ;;
        "") echo -e "${DIM}unknown${RESET}" ;;
        *) echo -e "${DIM}$1${RESET}" ;;
    esac
}

find_dist_files() {
    # $1 = module directory. Prints every *.conf.dist found under it,
    # except optional presets (e.g. mod-llm-chatter's conf/presets/),
    # which are alternative files to copy by hand, not loaded configs.
    find "$1" -maxdepth 3 -type f -name '*.conf.dist' \
        -not -path '*/presets/*' 2>/dev/null
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

    header "AzerothCore Modules"
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

        header "AzerothCore Modules"
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

        local printed_top=0

        if [[ -n "$key" ]]; then

            enable_num=$next

            local status_label="${DIM}not installed${RESET}"

            if [[ -d "$CORE_DIR/modules/$name" ]]; then

                local conf cur
                conf="$(ensure_module_conf_containing_key "$CORE_DIR/modules/$name" "$key")"

                if [[ -n "$conf" ]]; then
                    cur="$(read_key_value "$conf" "$key")"
                    status_label="$(enable_status_label "$cur")"
                fi

            fi

            echo -e "  $next  Enable / Disable   [${status_label}]"
            next=$((next + 1))
            printed_top=1

        fi

        if [[ "$name" == "mod-ah-bot-plus" ]]; then

            [[ "$printed_top" -eq 1 ]] && echo

            configure_num=$next
            echo "  $next  Configure (auction house bot account/character)"
            next=$((next + 1))
            printed_top=1

        fi

        if [[ "$name" == "mod-llm-chatter" ]]; then

            [[ "$printed_top" -eq 1 ]] && echo

            configure_num=$next
            echo "  $next  Configure (Ollama, model, bridge service)"
            next=$((next + 1))
            printed_top=1

        fi

        [[ "$printed_top" -eq 1 ]] && echo

        update_num=$next
        echo "  $next  Update"
        next=$((next + 1))

        install_num=$next
        echo "  $next  Install"
        next=$((next + 1))

        remove_num=$next
        echo "  $next  Remove"
        next=$((next + 1))

        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        if [[ "$choice" == "0" ]]; then

            return

        elif [[ -n "$enable_num" ]] && [[ "$choice" == "$enable_num" ]]; then

            module_toggle_menu "$name"

        elif [[ "$choice" == "$install_num" ]]; then

            echo
            MODULES_CHANGED=0
            if confirm "Install $name?"; then
                do_install "$name" "$repo" "$branch" && rebuild_if_modules_changed ask
            fi
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
            MODULES_CHANGED=0
            if confirm "Continue?"; then
                do_remove "$name" && rebuild_if_modules_changed ask
            fi
            pause

        elif [[ "$choice" == "$update_num" ]]; then

            echo
            MODULES_CHANGED=0
            do_update_one "$name"
            clean_module_sql_duplicates
            rebuild_if_modules_changed ask
            pause

        elif [[ -n "$configure_num" ]] && [[ "$choice" == "$configure_num" ]]; then

            if [[ "$name" == "mod-llm-chatter" ]]; then
                echo
                setup_llm_chatter
                pause
            else
                cmd_ahbot_setup
            fi

        else

            error "Invalid selection."
            sleep 1

        fi

    done
}

modules_menu() {

    while true; do

        header "AzerothCore Modules"

        check_core || { pause; return; }

        module_status

        local update_all_num=$(( ${#MODULES[@]} + 2 ))

        echo
        echo "  $update_all_num  Update all installed modules"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        if [[ "$choice" == "0" ]]; then

            return

        elif [[ "$choice" == "1" ]]; then

            playerbots_detail_menu

        elif [[ "$choice" == "$update_all_num" ]]; then

            header "AzerothCore Modules"
            echo "Update modules"
            echo "────────────────────────────────────────"
            echo
            MODULES_CHANGED=0
            do_update_all
            rebuild_if_modules_changed ask
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



ensure_ahbot_account() {

    # Prints the account id on success (stdout), nothing on failure.

    local password="$1"
    local existing_id

    existing_id="$(modules_db_query "$password" \
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

    modules_db_query "$password" \
        "INSERT INTO acore_auth.account (username, salt, verifier, reg_mail, email, joindate)
         VALUES ('${AHBOT_ACCOUNT_NAME}', UNHEX('${salt_hex}'), UNHEX('${verifier_hex}'), '', '', NOW());" \
        >/dev/null

    existing_id="$(modules_db_query "$password" \
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

    modules_db_query "$password" \
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

    header "AzerothCore Modules"

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
    warning "Restart the server to apply it."

    pause
}

modules_usage() {
    echo "Usage: $(basename "$0") modules [list|install <name>|remove <name>|update [name]|ahbot|llmchatter [model]] [--no-rebuild]"
    echo
    echo "  (no argument)   interactive menu"
    echo "  list            show install status of every module"
    echo "  install <name>  clone a module"
    echo "  remove <name>   remove a module"
    echo "  update [name]   update one module, or every installed module if omitted"
    echo "  ahbot           configure mod-ah-bot-plus (creates/reuses its account + character)"
    echo "  llmchatter [m]  install Ollama + bridge and configure mod-llm-chatter"
    echo "  --no-rebuild    with install/remove/update: skip the automatic rebuild"
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

modules_dispatch() {

    # --no-rebuild (anywhere in the arguments): skip the automatic
    # rebuild after install / remove / update.

    local -a args=()
    local a
    MODULES_SKIP_REBUILD=0

    for a in "$@"; do
        if [[ "$a" == "--no-rebuild" ]]; then
            MODULES_SKIP_REBUILD=1
        else
            args+=("$a")
        fi
    done

    set -- "${args[@]}"

    case "${1:-menu}" in

        menu)
            modules_menu
            ;;

        ahbot)
            cmd_ahbot_setup
            ;;

        llmchatter)
            header "AzerothCore Modules"
            echo "Configure mod-llm-chatter"
            echo "────────────────────────────────────────"
            echo
            check_core || exit 1
            setup_llm_chatter "${2:-}"
            ;;

        list)
            check_core || exit 1
            header "AzerothCore Modules"
            module_status
            ;;

        install)

            check_core || exit 1

            if [[ -z "${2:-}" ]]; then
                error "Usage: $(basename "$0") modules install <name>"
                exit 1
            fi

            module="$(find_module "$2")" || {
                error "Unknown module: $2"
                exit 1
            }

            IFS="|" read -r name repo branch <<< "$module"
            MODULES_CHANGED=0
            do_install "$name" "$repo" "$branch" && rebuild_if_modules_changed
            ;;

        remove)

            check_core || exit 1

            if [[ -z "${2:-}" ]]; then
                error "Usage: $(basename "$0") modules remove <name>"
                exit 1
            fi

            find_module "$2" >/dev/null || {
                error "Unknown module: $2"
                exit 1
            }

            MODULES_CHANGED=0
            do_remove "$2" && rebuild_if_modules_changed
            ;;

        update)

            check_core || exit 1

            if [[ -n "${2:-}" ]]; then

                find_module "$2" >/dev/null || {
                    error "Unknown module: $2"
                    exit 1
                }

                MODULES_CHANGED=0
                do_update_one "$2"
                clean_module_sql_duplicates
                rebuild_if_modules_changed

            else

                MODULES_CHANGED=0
                do_update_all
                rebuild_if_modules_changed

            fi
            ;;

        -h|--help)
            modules_usage
            ;;

        *)
            error "Unknown command: $1"
            echo
            modules_usage
            exit 1
            ;;

    esac
}

# ============================================================
# SECTION: sleep
# ============================================================

# ============================================================
# Sleep section
#
# Freezes the AzerothCore
# containers when no players are connected and wakes them up
# instantly when a player tries to connect, to save resources on
# an idle server.
#
# Adapted from https://github.com/andymarden/azeroth-sleep for a
# Docker Compose install:
#
#   - "kill -STOP / kill -CONT" on bare processes becomes
#     "docker compose pause / unpause" on ac-worldserver and
#     ac-authserver (same cgroup-freezer mechanism under the hood).
#   - The idle-connection monitor is this same script, run in a
#     loop by a systemd service. Player activity is detected two
#     ways: (1) an established connection on our own proxy's
#     listen port, for the login/char-select phase, and (2)
#     querying the database directly for characters flagged
#     online, for in-world gameplay. Querying the DB sidesteps
#     every Docker networking quirk (userland-proxy vs
#     iptables-only publishing, IPv4/IPv6 dual-stack sockets) that
#     made watching the worldserver's TCP connections from the
#     host unreliable.
#   - The instant-thaw proxy is also this same script (a "proxy"
#     sub-command run by a second systemd service). It's a plain,
#     transparent TCP forward (socat) from the port players
#     actually connect to (3724) to the real ac-authserver, which
#     is moved to an internal-only port (3725) to make room. It
#     does not touch pause/unpause itself -- that stays entirely
#     in the monitor, which polls quickly for a connection attempt
#     on the proxy port while sleeping and unpauses within ~1-2s.
#     Keeping the proxy a single dumb forward (instead of chaining
#     a thaw script into the same data path) keeps the WoW
#     protocol traffic itself completely untouched.
#
# ac-database is left running so waking up is fast and doesn't
# need a fresh DB import.
#
# Usage:
#   ./azerothcore-manager.sh sleep                 interactive menu
#   ./azerothcore-manager.sh sleep enable          set everything up and start it
#   ./azerothcore-manager.sh sleep disable         stop + remove everything
#   ./azerothcore-manager.sh sleep status          show monitor/proxy/server status
#   ./azerothcore-manager.sh sleep wake            unpause the server now
#   ./azerothcore-manager.sh sleep configure       change timeouts/ports
#   ./azerothcore-manager.sh sleep monitor         run the idle-watch loop (used by systemd)
#   ./azerothcore-manager.sh sleep proxy           run the instant-wake proxy (used by systemd)
#   ./azerothcore-manager.sh sleep thaw            unpause quietly (used by the proxy)
# ============================================================


SLEEP_CONFIG_FILE="$SCRIPT_DIR/.ac-sleep.conf"
STATE_FILE="$SCRIPT_DIR/.sleep-last-activity"
SLEEP_SINCE_FILE="$SCRIPT_DIR/.sleep-since"

SLEEP_SERVICE_NAME="ac-manager-sleep.service"
SLEEP_SERVICE_FILE="/etc/systemd/system/$SLEEP_SERVICE_NAME"

PROXY_SERVICE_NAME="ac-manager-sleep-proxy.service"
PROXY_SERVICE_FILE="/etc/systemd/system/$PROXY_SERVICE_NAME"

# Defaults, overridden by $SLEEP_CONFIG_FILE if it exists.
IDLE_TIMEOUT=300          # seconds of inactivity before pausing (5 min)
CHECK_INTERVAL=60         # how often the monitor checks (seconds)

# MySQL's default wait_timeout is 8h -- a sleep longer than that
# gets ac-worldserver/ac-authserver's idle DB connections closed
# by ac-database (which is never paused) before they wake up,
# causing slow or broken wake-ups. Rather than touching MySQL's
# config, the monitor just wakes the server on its own a bit
# before that mark, then lets the normal idle timeout put it back
# to sleep if nobody actually connects.
MAX_SLEEP_HOURS=7.5       # force a wake after this long asleep, even with no players

PROXY_LISTEN_PORT=3724    # the port players actually connect to
PROXY_TARGET_PORT=3725    # internal port ac-authserver moves to, to make room for the proxy

detect_auth_port_from_env() {

    local env_file="$CORE_DIR/.env"

    [[ -f "$env_file" ]] || return

    # Prints just the port (a "127.0.0.1:3725" value gives 3725).
    local value
    value="$(grep -E '^DOCKER_AUTH_EXTERNAL_PORT=' "$env_file" 2>/dev/null |
        tail -n1 |
        cut -d= -f2-)"
    echo "${value##*:}"
}

[[ -f "$SLEEP_CONFIG_FILE" ]] && source "$SLEEP_CONFIG_FILE"















# ============================================================
# Docker helpers
# ============================================================





sleep_check_docker_boot_enabled() {

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if systemctl is-enabled --quiet docker 2>/dev/null; then
        return 0
    fi

    warning "docker.service is not enabled to start on boot."
    warning "After a reboot nothing will come back up (containers, monitor, or proxy)."
    info "Fix it with: sudo systemctl enable docker"

    return 1
}

check_dependencies() {

    if ! command -v ss >/dev/null 2>&1; then

        error "ss (from iproute2) is required but not installed."
        echo
        echo "  sudo apt install iproute2"
        echo

        return 1

    fi

    return 0
}

check_proxy_dependencies() {

    if ! command -v socat >/dev/null 2>&1; then
        error "socat is required for the instant-wake proxy but not installed."
        return 1
    fi

    return 0
}

ensure_proxy_dependencies() {

    # Interactive variant (offers to auto-install) -- only safe to
    # call from a user-facing command, never from cmd_proxy itself
    # (that runs non-interactively under systemd).

    if command -v socat >/dev/null 2>&1; then
        return 0
    fi

    warning "socat is required for the instant-wake proxy but not installed."

    if ! command -v apt >/dev/null 2>&1; then
        error "Can't auto-install it (apt not found). Install socat manually and retry."
        return 1
    fi

    if ! confirm "Install it now (sudo apt install socat)?"; then
        return 1
    fi

    echo

    if sudo apt update && sudo apt install -y socat; then
        success "socat installed."
        return 0
    fi

    error "Failed to install socat. Install it manually and retry."
    return 1
}





# Cached across calls within the same monitor process -- the root
# password doesn't change while ac-database keeps running, so
# there's no need to "docker exec printenv" every single cycle.
CACHED_DB_PASSWORD=""

players_online() {

    # Sidesteps all Docker networking ambiguity (userland-proxy vs
    # iptables, IPv4 vs IPv6, container shell/tooling availability)
    # by asking the database directly for how many characters are
    # currently flagged online -- the same signal AzerothCore
    # itself relies on, updated the moment a character enters or
    # leaves the world.

    local count

    if [[ -z "$CACHED_DB_PASSWORD" ]]; then
        CACHED_DB_PASSWORD="$(get_db_password)"
    fi

    if [[ -z "$CACHED_DB_PASSWORD" ]]; then
        echo "-1"
        return
    fi

    count="$(
        compose exec -T ac-database \
            mysql -uroot -p"$CACHED_DB_PASSWORD" -N -B \
            -e "SELECT COUNT(*) FROM acore_characters.characters WHERE online = 1;" \
            2>/dev/null
    )"

    if [[ ! "$count" =~ ^[0-9]+$ ]]; then

        # Could be a stale cached password (e.g. ac-database got
        # recreated) -- refresh once and retry before giving up.
        CACHED_DB_PASSWORD="$(get_db_password)"

        if [[ -n "$CACHED_DB_PASSWORD" ]]; then
            count="$(
                compose exec -T ac-database \
                    mysql -uroot -p"$CACHED_DB_PASSWORD" -N -B \
                    -e "SELECT COUNT(*) FROM acore_characters.characters WHERE online = 1;" \
                    2>/dev/null
            )"
        fi

    fi

    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "-1"
        return
    fi

    echo "$count"
}

check_services() {

    local defined missing=()
    defined="$(compose config --services 2>/dev/null)"

    if [[ -z "$defined" ]]; then
        warning "Could not read services from docker-compose.yml, skipping check."
        return 0
    fi

    for svc in ac-worldserver ac-authserver ac-database; do
        grep -qx "$svc" <<< "$defined" || missing+=("$svc")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then

        warning "This install's docker-compose.yml doesn't define: ${missing[*]}"
        info "Sleep mode expects the standard AzerothCore service names"
        info "(ac-worldserver, ac-authserver, ac-database). Pausing/waking may not work."
        echo

        return 1

    fi

    return 0
}

ensure_auth_port_moved() {

    local env_file="$CORE_DIR/.env"
    local current mapped

    touch "$env_file"
    current="$(detect_auth_port_from_env)"

    if [[ "$current" == "$PROXY_TARGET_PORT" ]]; then
        return 0
    fi

    warning "ac-authserver is currently published on host port ${current:-3724}."
    warning "The instant-wake proxy needs port ${PROXY_LISTEN_PORT} for itself, so"
    warning "ac-authserver has to move to an internal-only port: ${PROXY_TARGET_PORT}."
    echo

    confirm "Set DOCKER_AUTH_EXTERNAL_PORT=127.0.0.1:${PROXY_TARGET_PORT} in .env and recreate ac-authserver now?" || return 1

    # 127.0.0.1 only: players must go through the proxy (that's what
    # wakes the server), not straight to the internal port.
    env_set_value DOCKER_AUTH_EXTERNAL_PORT "127.0.0.1:${PROXY_TARGET_PORT}"

    success "Updated .env: DOCKER_AUTH_EXTERNAL_PORT=127.0.0.1:${PROXY_TARGET_PORT}"
    info "Recreating ac-authserver with the new port mapping..."

    if ! compose up -d ac-authserver >/dev/null 2>&1; then
        error "Failed to recreate ac-authserver. Run manually: docker compose up -d ac-authserver"
        return 1
    fi

    mapped="$(compose port ac-authserver 3724 2>/dev/null | cut -d: -f2)"

    if [[ "$mapped" != "$PROXY_TARGET_PORT" ]]; then

        error "ac-authserver is published on port '${mapped:-unknown}', not ${PROXY_TARGET_PORT}."
        info "This install's docker-compose.yml may not use \$DOCKER_AUTH_EXTERNAL_PORT."
        info "Map it manually in docker-compose.override.yml instead:"
        echo
        echo "  services:"
        echo "    ac-authserver:"
        echo "      ports:"
        echo "        - \"${PROXY_TARGET_PORT}:3724\""
        echo

        return 1

    fi

    success "ac-authserver confirmed on 127.0.0.1:${PROXY_TARGET_PORT}"

    return 0
}

is_running() {
    compose ps --status running --services 2>/dev/null | grep -qx "$1"
}

is_paused() {
    compose ps --status paused --services 2>/dev/null | grep -qx "$1"
}

# ============================================================
# Config persistence
# ============================================================

sleep_save_config() {

    cat > "$SLEEP_CONFIG_FILE" << EOF
IDLE_TIMEOUT=$IDLE_TIMEOUT
CHECK_INTERVAL=$CHECK_INTERVAL
MAX_SLEEP_HOURS=$MAX_SLEEP_HOURS
PROXY_LISTEN_PORT=$PROXY_LISTEN_PORT
PROXY_TARGET_PORT=$PROXY_TARGET_PORT
EOF
}

# ============================================================
# Systemd unit
# ============================================================

write_systemd_unit() {

    local user
    user="$(whoami)"

    sudo tee "$SLEEP_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore AutoSleep Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/azerothcore-manager.sh sleep monitor
Restart=always
RestartSec=5
User=$user

[Install]
WantedBy=multi-user.target
EOF
}

write_proxy_systemd_unit() {

    local user
    user="$(whoami)"

    sudo tee "$PROXY_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore AutoSleep Instant-Wake Proxy
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/azerothcore-manager.sh sleep proxy
Restart=always
RestartSec=5
User=$user

[Install]
WantedBy=multi-user.target
EOF
}

service_status() {
    systemctl is-active --quiet "$SLEEP_SERVICE_NAME" 2>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$SLEEP_SERVICE_NAME" 2>/dev/null
}

proxy_service_status() {
    systemctl is-active --quiet "$PROXY_SERVICE_NAME" 2>/dev/null
}


# ============================================================
# Monitor loop (run by systemd, or manually for debugging)
# ============================================================

sleep_log_message() {
    logger -t ac-sleep "$1" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

has_connections() {

    # A player counts as "connected" during either phase:
    #   1. Login / char-select  → established connection on PROXY_LISTEN_PORT (3724)
    #   2. In-world              → at least one character flagged online in the DB
    # We must watch BOTH so we don't count idle time while a player
    # is still on the login screen or selecting a character.

    # Auth / login port (our own proxy process, host-side -- no
    # Docker networking ambiguity at all here, always reliable).
    local count_auth
    count_auth="$(ss -Htn state established "sport = :${PROXY_LISTEN_PORT}" 2>/dev/null | wc -l)"
    [[ "${count_auth:-0}" -gt 0 ]] && return 0

    # In-world: ask the database directly instead of trying to
    # infer it from TCP connection state. This sidesteps every
    # Docker networking quirk (userland-proxy vs iptables-only,
    # IPv4/IPv6 dual-stack, container tooling availability) by
    # using the same "online" flag AzerothCore itself maintains.
    local online
    online="$(players_online)"

    if [[ "$online" == "-1" ]]; then
        # Couldn't read the DB password or the query failed --
        # fail safe: assume there might be activity rather than
        # risk pausing mid-session on a false negative.
        sleep_log_message "Warning: could not query online player count this cycle, assuming activity."
        return 0
    fi

    [[ "$online" -gt 0 ]]
}

has_proxy_connection_attempt() {
    # Any connection touching our own proxy listen port -- this
    # fires the instant a client's TCP handshake reaches us, well
    # before the WoW auth handshake itself even starts.
    local count
    count="$(ss -Htn state established "sport = :${PROXY_LISTEN_PORT}" 2>/dev/null | wc -l)"
    [[ "$count" -gt 0 ]]
}

freeze_servers() {

    if is_paused "ac-worldserver"; then
        return
    fi

    if ! is_running "ac-worldserver"; then
        sleep_log_message "ac-worldserver is not running, nothing to freeze."
        return
    fi

    sleep_log_message "No activity for ${IDLE_TIMEOUT}s. Pausing ac-worldserver and ac-authserver..."

    if compose pause ac-worldserver ac-authserver 2>/dev/null; then
        date +%s > "$SLEEP_SINCE_FILE"
        sleep_pause_extras
        sleep_log_message "Server is now sleeping."
    else
        sleep_log_message "Failed to pause containers."
    fi
}

sleep_pause_extras() {

    # Optional companion containers that only make sense while the
    # worldserver is awake. Right now: mod-llm-chatter's bridge, which
    # would otherwise keep polling the database (and could keep calling
    # the LLM) for a server nobody is playing on. Best effort.

    if is_running "ac-llm-chatter-bridge"; then
        if compose pause ac-llm-chatter-bridge >/dev/null 2>&1; then
            sleep_log_message "ac-llm-chatter-bridge paused too."
        fi
    fi
}

sleep_thaw_extras() {

    if is_paused "ac-llm-chatter-bridge"; then
        if compose unpause ac-llm-chatter-bridge >/dev/null 2>&1; then
            sleep_log_message "ac-llm-chatter-bridge resumed."
        fi
    fi
}

thaw_servers() {

    local reason="${1:-Player connecting}"

    sleep_log_message "${reason} - thawing server..."

    if compose unpause ac-worldserver ac-authserver 2>/dev/null; then
        sleep_thaw_extras
        sleep_log_message "Server thawed."
    else
        sleep_log_message "Failed to thaw server."
    fi

    rm -f "$SLEEP_SINCE_FILE"
    date +%s > "$STATE_FILE"
}

cmd_monitor() {

    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || date +%s > "$STATE_FILE"

    sleep_log_message "Sleep monitor starting (idle timeout ${IDLE_TIMEOUT}s, checking every ${CHECK_INTERVAL}s, detecting players via DB + proxy port ${PROXY_LISTEN_PORT}). Max sleep before a scheduled wake: ${MAX_SLEEP_HOURS}h."

    while true; do

        if is_paused "ac-worldserver"; then

            # Sleeping. Poll quickly (every 3s, not the full
            # CHECK_INTERVAL) for a player hitting the proxy port,
            # so wake-up feels instant instead of laggy.
            if has_proxy_connection_attempt; then

                thaw_servers "Player connecting"

            else

                # Also force a wake if we've been asleep too long,
                # so ac-worldserver/ac-authserver's DB connections
                # never sit idle long enough to hit MySQL's default
                # wait_timeout (8h). If nobody actually connects,
                # the normal idle timeout below just puts it back
                # to sleep after IDLE_TIMEOUT.
                local sleep_since sleep_elapsed max_sleep_seconds
                sleep_since="$(cat "$SLEEP_SINCE_FILE" 2>/dev/null || date +%s)"
                sleep_elapsed=$(( $(date +%s) - sleep_since ))
                max_sleep_seconds=$(awk -v h="$MAX_SLEEP_HOURS" 'BEGIN { printf "%d", h * 3600 }')

                if [[ "$sleep_elapsed" -ge "$max_sleep_seconds" ]]; then
                    thaw_servers "Scheduled wake (asleep ${MAX_SLEEP_HOURS}h)"
                fi

            fi

            sleep 3
            continue

        fi

        # Stopped (or starting up): nothing to pause, and no point
        # querying a database that may be down. Keep the idle timer
        # fresh so a later start isn't paused straight away.
        if ! is_running "ac-worldserver"; then
            date +%s > "$STATE_FILE"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        if has_connections; then

            date +%s > "$STATE_FILE"

        else

            local last_activity now idle
            last_activity="$(cat "$STATE_FILE" 2>/dev/null || date +%s)"
            now="$(date +%s)"
            idle=$((now - last_activity))

            if [[ "$idle" -ge "$IDLE_TIMEOUT" ]]; then
                freeze_servers
            fi

        fi

        sleep "$CHECK_INTERVAL"

    done
}

# ============================================================
# Instant-wake proxy
#
# Listens on PROXY_LISTEN_PORT (the port players actually connect
# to) and does a plain, transparent TCP forward to the real
# ac-authserver on 127.0.0.1:PROXY_TARGET_PORT -- nothing else.
# It never touches pause/unpause itself, so the WoW protocol data
# path is a single, well-tested socat one-liner with no extra
# hops that could interfere with it.
#
# Waking up is handled separately by the monitor (see above),
# which polls quickly for a connection attempt on this port while
# the server is sleeping and unpauses within ~1-2s of it seeing one.
# ============================================================

cmd_thaw() {
    thaw_servers "Manual wake"
}

cmd_proxy() {

    check_proxy_dependencies || exit 1

    sleep_log_message "Instant-wake proxy starting: 0.0.0.0:${PROXY_LISTEN_PORT} -> 127.0.0.1:${PROXY_TARGET_PORT}"

    exec socat \
        TCP4-LISTEN:"${PROXY_LISTEN_PORT}",fork,reuseaddr \
        TCP4:127.0.0.1:"${PROXY_TARGET_PORT}"
}

# ============================================================
# Commands
# ============================================================

sleep_cmd_enable() {

    header "AzerothCore AutoSleep"

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_dependencies || { pause; return 1; }
    ensure_proxy_dependencies || { pause; return 1; }
    sleep_check_docker_boot_enabled
    echo

    echo "Enable Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    check_services || {
        confirm "Continue enabling anyway?" || { pause; return 1; }
        echo
    }

    info "Idle timeout       : ${IDLE_TIMEOUT}s"
    info "Check every        : ${CHECK_INTERVAL}s"
    info "Max sleep duration : ${MAX_SLEEP_HOURS}h (scheduled wake even with no players)"
    info "Player detection   : DB query (acore_characters.characters.online) + proxy port"
    info "Player connects to : ${PROXY_LISTEN_PORT} (proxy, instant wake)"
    echo

    ensure_auth_port_moved || {
        error "Could not move ac-authserver's port. Aborting."
        pause
        return 1
    }

    echo

    sleep_save_config
    success "Configuration written: $SLEEP_CONFIG_FILE"

    info "Installing systemd services (needs sudo)..."
    echo

    if ! write_systemd_unit || ! write_proxy_systemd_unit; then
        error "Failed to write systemd unit(s)."
        pause
        return 1
    fi

    sudo systemctl daemon-reload

    local ok=1

    if ! sudo systemctl enable --now "$SLEEP_SERVICE_NAME"; then
        error "Failed to start the sleep monitor service."
        ok=0
    fi

    if ! sudo systemctl enable --now "$PROXY_SERVICE_NAME"; then
        error "Failed to start the instant-wake proxy service."
        ok=0
    fi

    if [[ "$ok" -eq 1 ]]; then
        echo
        success "Sleep mode enabled and running."
        info "ac-worldserver/ac-authserver will pause after ${IDLE_TIMEOUT}s idle."
        info "Players still connect on port ${PROXY_LISTEN_PORT}; the proxy wakes"
        info "the server automatically on their first connection attempt."
    fi

    pause
}

sleep_cmd_disable() {

    header "AzerothCore AutoSleep"

    echo "Disable Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    if [[ ! -f "$SLEEP_SERVICE_FILE" ]] && [[ ! -f "$PROXY_SERVICE_FILE" ]]; then
        warning "Sleep mode is not installed."
        pause
        return
    fi

    if ! confirm "Stop and remove the sleep monitor and instant-wake proxy?"; then
        return
    fi

    sudo systemctl disable --now "$SLEEP_SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable --now "$PROXY_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SLEEP_SERVICE_FILE" "$PROXY_SERVICE_FILE"
    sudo systemctl daemon-reload

    success "Sleep mode disabled."

    if check_core >/dev/null 2>&1 && check_docker >/dev/null 2>&1; then

        if is_paused "ac-worldserver"; then
            # Nothing would ever wake it now that the monitor is gone.
            echo
            info "The server was sleeping -- waking it up..."
            if compose unpause ac-worldserver ac-authserver >/dev/null 2>&1; then
                sleep_thaw_extras
                rm -f "$SLEEP_SINCE_FILE"
                success "Server awake."
            else
                error "Could not wake it. Run: docker compose unpause ac-worldserver ac-authserver"
            fi
        fi

        local current
        current="$(detect_auth_port_from_env)"

        if [[ "$current" == "$PROXY_TARGET_PORT" ]]; then

            echo
            warning "ac-authserver is still published on internal port ${PROXY_TARGET_PORT},"
            warning "and nothing is listening on ${PROXY_LISTEN_PORT} anymore -- players won't"
            warning "be able to connect until this is reverted."
            echo

            if confirm "Move ac-authserver back to port ${PROXY_LISTEN_PORT} now?"; then

                sed -i "s|^DOCKER_AUTH_EXTERNAL_PORT=.*\$|DOCKER_AUTH_EXTERNAL_PORT=${PROXY_LISTEN_PORT}|" "$CORE_DIR/.env"

                if compose up -d ac-authserver >/dev/null 2>&1; then
                    success "ac-authserver back on port ${PROXY_LISTEN_PORT}."
                else
                    error "Failed to recreate ac-authserver. Run manually: docker compose up -d ac-authserver"
                fi

            fi

        fi

    fi

    pause
}

cmd_wake() {

    header "AzerothCore AutoSleep"

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }

    echo "Wake Server"
    echo "────────────────────────────────────────"
    echo

    if ! is_paused "ac-worldserver"; then
        info "The server is not sleeping."
        pause
        return
    fi

    info "Waking up ac-worldserver and ac-authserver..."

    if compose unpause ac-worldserver ac-authserver; then
        sleep_thaw_extras
        rm -f "$SLEEP_SINCE_FILE"
        date +%s > "$STATE_FILE"
        success "Server woken up."
    else
        error "Failed to wake the server."
    fi

    pause
}

sleep_cmd_status() {

    header "AzerothCore AutoSleep"

    echo "Sleep Mode Status"
    echo "────────────────────────────────────────"
    echo

    sleep_check_docker_boot_enabled && info "docker.service enabled at boot: yes"
    echo
    if [[ -f "$SLEEP_SERVICE_FILE" ]]; then

        if service_status; then
            echo -e "Monitor      ${GREEN}● RUNNING${RESET}"
        else
            echo -e "Monitor      ${RED}● STOPPED${RESET}"
        fi

        if service_enabled; then
            info "Enabled at boot: yes"
        else
            info "Enabled at boot: no"
        fi

    else
        echo -e "Monitor      ${DIM}○ NOT INSTALLED${RESET}"
    fi

    if [[ -f "$PROXY_SERVICE_FILE" ]]; then

        if proxy_service_status; then
            echo -e "Proxy        ${GREEN}● RUNNING${RESET} (players connect on ${PROXY_LISTEN_PORT})"
        else
            echo -e "Proxy        ${RED}● STOPPED${RESET}"
        fi

    else
        echo -e "Proxy        ${DIM}○ NOT INSTALLED${RESET}"
    fi

    echo

    if check_core >/dev/null 2>&1 && check_docker >/dev/null 2>&1; then

        if is_paused "ac-worldserver"; then

            echo -e "Server       ${YELLOW}● SLEEPING${RESET}"

            if [[ -f "$SLEEP_SINCE_FILE" ]]; then

                local sleep_since sleep_elapsed max_sleep_seconds remaining
                sleep_since="$(cat "$SLEEP_SINCE_FILE" 2>/dev/null)"

                if [[ "$sleep_since" =~ ^[0-9]+$ ]]; then

                    sleep_elapsed=$(( $(date +%s) - sleep_since ))
                    max_sleep_seconds=$(awk -v h="$MAX_SLEEP_HOURS" 'BEGIN { printf "%d", h * 3600 }')
                    remaining=$(( max_sleep_seconds - sleep_elapsed ))

                    info "Asleep for $((sleep_elapsed / 60))min, scheduled wake in $((remaining > 0 ? remaining / 60 : 0))min"

                fi

            fi

        else

            echo -e "Server       ${DIM}○ awake (or offline)${RESET}"

            if is_running "ac-worldserver"; then

                if has_connections; then
                    echo -e "Detected     ${GREEN}● player activity right now${RESET}"
                else
                    echo -e "Detected     ${DIM}○ no player activity right now${RESET}"
                fi

            fi

        fi

    fi

    echo
    info "Idle timeout       : ${IDLE_TIMEOUT}s"
    info "Check every        : ${CHECK_INTERVAL}s"
    info "Max sleep duration : ${MAX_SLEEP_HOURS}h"
    info "Player detection   : DB query + proxy port"
    info "Players connect on : ${PROXY_LISTEN_PORT}"
    info "ac-authserver on   : ${PROXY_TARGET_PORT} (internal)"

    local env_auth_port
    env_auth_port="$(detect_auth_port_from_env)"

    if [[ -f "$PROXY_SERVICE_FILE" ]] && [[ "$env_auth_port" != "$PROXY_TARGET_PORT" ]]; then
        echo
        warning "The install's .env has DOCKER_AUTH_EXTERNAL_PORT=${env_auth_port:-3724},"
        warning "but the proxy expects ac-authserver on ${PROXY_TARGET_PORT}. Re-run 'Enable' to fix."
    fi

    if [[ -f "$STATE_FILE" ]]; then

        local last_activity
        last_activity="$(cat "$STATE_FILE" 2>/dev/null || echo "")"

        if [[ -n "$last_activity" ]]; then
            info "Last activity: $(date -d "@$last_activity" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_activity")"
        fi

    fi

    pause
}

sleep_cmd_configure() {

    header "AzerothCore AutoSleep"

    echo "Configure Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    info "Current idle timeout       : ${IDLE_TIMEOUT}s"
    info "Current check every        : ${CHECK_INTERVAL}s"
    info "Current max sleep duration : ${MAX_SLEEP_HOURS}h (forces a wake even with no players)"
    info "Current player-facing port : ${PROXY_LISTEN_PORT}"
    info "Current ac-authserver port : ${PROXY_TARGET_PORT} (internal)"
    echo

    local new_timeout new_interval new_max_sleep new_listen new_target

    read -r -p "New idle timeout in seconds [$IDLE_TIMEOUT]: " new_timeout
    read -r -p "New check interval in seconds [$CHECK_INTERVAL]: " new_interval
    read -r -p "New max sleep duration in hours [$MAX_SLEEP_HOURS]: " new_max_sleep
    read -r -p "New player-facing (proxy) port [$PROXY_LISTEN_PORT]: " new_listen
    read -r -p "New internal ac-authserver port [$PROXY_TARGET_PORT]: " new_target

    [[ -n "$new_timeout" ]] && IDLE_TIMEOUT="$new_timeout"
    [[ -n "$new_interval" ]] && CHECK_INTERVAL="$new_interval"
    [[ -n "$new_max_sleep" ]] && MAX_SLEEP_HOURS="$new_max_sleep"
    [[ -n "$new_listen" ]] && PROXY_LISTEN_PORT="$new_listen"
    [[ -n "$new_target" ]] && PROXY_TARGET_PORT="$new_target"

    sleep_save_config

    if [[ -f "$PROXY_SERVICE_FILE" ]]; then
        echo
        ensure_auth_port_moved
    fi

    if [[ -f "$SLEEP_SERVICE_FILE" ]]; then
        echo
        info "Restarting monitor service with the new settings..."
        sudo systemctl restart "$SLEEP_SERVICE_NAME"
    fi

    if [[ -f "$PROXY_SERVICE_FILE" ]]; then
        info "Restarting proxy service with the new settings..."
        sudo systemctl restart "$PROXY_SERVICE_NAME"
    fi

    success "Sleep mode reconfigured."

    pause
}

# ============================================================
# Interactive menu
# ============================================================

sleep_menu() {

    while true; do

        header "AzerothCore AutoSleep"

        if check_core >/dev/null 2>&1 && check_docker >/dev/null 2>&1; then

            if is_paused "ac-worldserver"; then
                echo -e "Server       ${YELLOW}● SLEEPING${RESET}"
            else
                echo -e "Server       ${DIM}○ awake (or offline)${RESET}"
            fi

        fi

        if [[ -f "$SLEEP_SERVICE_FILE" ]] && service_status; then
            echo -e "Monitor      ${GREEN}● RUNNING${RESET}"
        elif [[ -f "$SLEEP_SERVICE_FILE" ]]; then
            echo -e "Monitor      ${RED}● STOPPED${RESET}"
        else
            echo -e "Monitor      ${DIM}○ NOT INSTALLED${RESET}"
        fi

        if [[ -f "$PROXY_SERVICE_FILE" ]] && proxy_service_status; then
            echo -e "Proxy        ${GREEN}● RUNNING${RESET}"
        elif [[ -f "$PROXY_SERVICE_FILE" ]]; then
            echo -e "Proxy        ${RED}● STOPPED${RESET}"
        else
            echo -e "Proxy        ${DIM}○ NOT INSTALLED${RESET}"
        fi

        echo
        echo "  1  Enable (idle-pause monitor + instant-wake proxy)"
        echo "  2  Disable (stop + remove both)"
        echo
        echo "  3  Status"
        echo "  4  Wake now"
        echo
        echo "  5  Configure (timeouts / ports)"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) sleep_cmd_enable ;;
            2) sleep_cmd_disable ;;
            3) sleep_cmd_status ;;
            4) cmd_wake ;;
            5) sleep_cmd_configure ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

sleep_usage() {
    echo "Usage: $(basename "$0") sleep [enable|disable|status|wake|configure|monitor|proxy|thaw]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  enable         set up + start the idle-pause monitor and the instant-wake proxy"
    echo "  disable        stop + remove both"
    echo "  status         show monitor/proxy/server status"
    echo "  wake           unpause ac-worldserver/ac-authserver now"
    echo "  configure      change idle timeout / check interval / ports"
    echo "  monitor        run the idle-watch loop in the foreground (used by systemd)"
    echo "  proxy          run the instant-wake proxy in the foreground (used by systemd)"
    echo "  thaw           unpause quietly (manual/debug use; the proxy no longer calls this itself)"
}

# ============================================================
# Entry point
# ============================================================

sleep_dispatch() {

    case "${1:-menu}" in
        enable)    sleep_cmd_enable ;;
        disable)   sleep_cmd_disable ;;
        status)    sleep_cmd_status ;;
        wake)      cmd_wake ;;
        configure) sleep_cmd_configure ;;
        monitor)   cmd_monitor ;;
        proxy)     cmd_proxy ;;
        thaw)      cmd_thaw ;;
        menu)      sleep_menu ;;
        -h|--help) sleep_usage ;;
        *)
            error "Unknown command: $1"
            echo
            sleep_usage
            exit 1
            ;;
    esac
}

# ============================================================
# SECTION: backup
# ============================================================

# ============================================================
# Backup section
#
# Installs and manages automatic, periodic database backups
# (e.g. every 4 hours) using a systemd timer, independent of the
# manual backups in the Server section.
#
# Backups land in the same folder the Server section already uses
# ($SCRIPT_DIR/backups) and use the same filename pattern
# (azerothcore-players-<timestamp>.sql), so anything created here also
# shows up in the Server section's own "Restore" menu.
#
# Usage:
#   ./azerothcore-manager.sh backup                interactive menu
#   ./azerothcore-manager.sh backup enable         install + start the timer
#   ./azerothcore-manager.sh backup disable        stop + remove the timer
#   ./azerothcore-manager.sh backup status         show timer/last-backup status
#   ./azerothcore-manager.sh backup run            take a backup right now
#   ./azerothcore-manager.sh backup list           list existing backups
#   ./azerothcore-manager.sh backup prune          delete backups beyond the retention count
#   ./azerothcore-manager.sh backup configure      change interval / retention
# ============================================================


BACKUP_CONFIG_FILE="$SCRIPT_DIR/.ac-backup.conf"
LOG_FILE="$SCRIPT_DIR/.ac-backup.log"

BACKUP_SERVICE_NAME="ac-manager-backup.service"
TIMER_NAME="ac-manager-backup.timer"
BACKUP_SERVICE_FILE="/etc/systemd/system/$BACKUP_SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

# Defaults, overridden by $BACKUP_CONFIG_FILE if it exists.
INTERVAL_HOURS=4      # how often to back up
KEEP_LAST=30          # how many backups to keep locally (oldest get pruned)

RCLONE_ENABLED=0      # 1 = also upload each backup to a remote via rclone
RCLONE_REMOTE=""      # e.g. "gdrive:AzerothCore-Backups"
RCLONE_KEEP_LAST=10   # how many backups to keep on the remote

[[ -f "$BACKUP_CONFIG_FILE" ]] && source "$BACKUP_CONFIG_FILE"















# ============================================================
# Docker helpers
# ============================================================





backup_check_docker_boot_enabled() {

    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    if systemctl is-enabled --quiet docker 2>/dev/null; then
        return 0
    fi

    warning "docker.service is not enabled to start on boot."
    warning "Scheduled backups will silently stop happening after a reboot."
    info "Fix it with: sudo systemctl enable docker"

    return 1
}





# ============================================================
# Config persistence
# ============================================================

backup_save_config() {

    cat > "$BACKUP_CONFIG_FILE" << EOF
INTERVAL_HOURS=$INTERVAL_HOURS
KEEP_LAST=$KEEP_LAST
RCLONE_ENABLED=$RCLONE_ENABLED
RCLONE_REMOTE="$RCLONE_REMOTE"
RCLONE_KEEP_LAST=$RCLONE_KEEP_LAST
EOF
}

# ============================================================
# Systemd service + timer
# ============================================================

write_systemd_units() {

    local user
    user="$(whoami)"

    sudo tee "$BACKUP_SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore AutoBackup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/azerothcore-manager.sh backup run --quiet
User=$user
EOF

    sudo tee "$TIMER_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore AutoBackup every ${INTERVAL_HOURS}h

[Timer]
OnActiveSec=1min
OnUnitActiveSec=${INTERVAL_HOURS}h
Persistent=true
Unit=$BACKUP_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF
}

timer_status() {
    systemctl is-active --quiet "$TIMER_NAME" 2>/dev/null
}

timer_enabled() {
    systemctl is-enabled --quiet "$TIMER_NAME" 2>/dev/null
}

# ============================================================
# Backup / prune (shared by "run" command and systemd)
# ============================================================

backup_log_message() {
    logger -t ac-backup "$1" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

do_backup() {

    local quiet="$1"

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        backup_log_message "Skipped: ac-database is not running."
        [[ "$quiet" == "1" ]] || error "Database container is not running."
        return 1
    fi

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        backup_log_message "Skipped: could not read MYSQL_ROOT_PASSWORD."
        [[ "$quiet" == "1" ]] || error "Could not read database password."
        return 1
    fi

    mkdir -p "$BACKUP_DIR"

    local timestamp backup_file
    timestamp="$(date +%F_%H-%M-%S)"
    backup_file="$BACKUP_DIR/azerothcore-players-$timestamp.sql"

    [[ "$quiet" == "1" ]] || { info "Creating database backup..."; echo; }

    compose exec -T \
        ac-database \
        mysqldump \
        --databases acore_auth acore_characters acore_playerbots \
        --single-transaction \
        --routines \
        --triggers \
        -uroot \
        -p"$password" \
        > "$backup_file" 2>/dev/null

    if [[ $? -eq 0 ]] && [[ -s "$backup_file" ]]; then

        chmod 600 "$backup_file" 2>/dev/null
        backup_log_message "Backup created: $(basename "$backup_file") ($(du -h "$backup_file" | cut -f1))"
        [[ "$quiet" == "1" ]] || { success "Backup completed."; echo; echo "  $backup_file"; }

    else

        rm -f "$backup_file"
        backup_log_message "Backup FAILED."
        [[ "$quiet" == "1" ]] || error "Backup failed."
        return 1

    fi

    local config_file=""
    if create_config_backup "$timestamp" 1; then
        config_file="$BACKUP_DIR/azerothcore-config-$timestamp.tar.gz"
    fi

    do_prune "$quiet"
    do_prune_config

    if [[ "$RCLONE_ENABLED" == "1" ]] && [[ -n "$RCLONE_REMOTE" ]]; then
        do_remote_upload "$backup_file" "$quiet"
        [[ -n "$config_file" ]] && do_remote_upload "$config_file" "$quiet"
    fi

    return 0
}

do_prune() {

    local quiet="$1"

    [[ -d "$BACKUP_DIR" ]] || return 0

    mapfile -t backups < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'azerothcore-*.sql' \
            -printf '%f\n' |
        sort -r
    )

    local total=${#backups[@]}

    if [[ "$total" -le "$KEEP_LAST" ]]; then
        return 0
    fi

    local to_delete=("${backups[@]:$KEEP_LAST}")

    for f in "${to_delete[@]}"; do
        rm -f "$BACKUP_DIR/$f"
        backup_log_message "Pruned old backup: $f"
    done

    [[ "$quiet" == "1" ]] || info "Pruned ${#to_delete[@]} old backup(s), keeping the newest $KEEP_LAST."

    return 0
}

do_prune_config() {

    # Same retention as the database backups, for the config archives.

    [[ -d "$BACKUP_DIR" ]] || return 0

    local -a cfgs
    mapfile -t cfgs < <(
        find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-config-*.tar.gz' \
            -printf '%f\n' | sort -r
    )

    [[ ${#cfgs[@]} -le "$KEEP_LAST" ]] && return 0

    local f
    for f in "${cfgs[@]:$KEEP_LAST}"; do
        rm -f "$BACKUP_DIR/$f"
        backup_log_message "Pruned old config backup: $f"
    done

    return 0
}

# ============================================================
# Remote backup (rclone)
#
# Optional: after each local backup, also copy it to a remote
# configured in rclone (Google Drive, S3, Dropbox, an SSH/SFTP
# server, etc.), with its own retention limit so the remote
# doesn't fill up either. rclone's own setup wizard (`rclone
# config`) handles the actual provider/OAuth details -- this
# script only wires the result into the backup flow.
# ============================================================

check_rclone() {

    if ! command -v rclone >/dev/null 2>&1; then
        error "rclone is not installed."
        info "Install it from this menu (Remote backup > Install rclone)."
        return 1
    fi

    return 0
}

install_rclone() {

    header "AzerothCore AutoBackup"
    echo "Install rclone"
    echo "────────────────────────────────────────"
    echo

    if command -v rclone >/dev/null 2>&1; then
        success "rclone is already installed ($(rclone version 2>/dev/null | head -n1))."
        pause
        return 0
    fi

    info "Installing via rclone's official install script (recommended by"
    info "rclone itself -- distro repos are often several versions behind)."
    warning "This downloads and runs a script as root (curl | sudo bash) --"
    warning "standard practice for rclone, but worth knowing before you continue."
    echo

    if confirm "Continue with the official install script?"; then

        if curl -fsSL https://rclone.org/install.sh | sudo bash; then

            success "rclone installed."

        else

            error "Official install script failed."

            if command -v apt >/dev/null 2>&1 && confirm "Try installing via apt instead?"; then

                if sudo apt update && sudo apt install -y rclone; then
                    success "rclone installed via apt."
                else
                    error "apt install also failed."
                fi

            fi

        fi

    fi

    pause
}

configure_remote() {

    header "AzerothCore AutoBackup"
    echo "Configure rclone Remote"
    echo "────────────────────────────────────────"
    echo

    check_rclone || { pause; return 1; }

    info "Launching rclone's own setup wizard (add/edit/remove remotes,"
    info "including any provider login). Exit it normally when done."
    echo
    pause

    rclone config

    local remotes
    remotes="$(rclone listremotes 2>/dev/null)"

    if [[ -z "$remotes" ]]; then
        warning "No remotes configured yet."
        pause
        return 0
    fi

    echo
    info "Configured remotes:"
    echo "$remotes" | sed 's/^/    /'
    echo

    if confirm "Set which remote + folder backups should upload to now?"; then
        set_remote_target
    else
        pause
    fi
}

set_remote_target() {

    local remotes
    remotes="$(rclone listremotes 2>/dev/null)"

    if [[ -z "$remotes" ]]; then
        error "No rclone remotes configured yet -- run 'Configure remote' first."
        pause
        return 1
    fi

    echo
    info "Configured remotes:"
    echo "$remotes" | sed 's/^/    /'
    echo

    local remote_name folder

    read -r -p "Remote name (as listed above, without the trailing ':'): " remote_name
    remote_name="${remote_name%:}"

    if ! echo "$remotes" | grep -qx "${remote_name}:"; then
        error "'$remote_name' is not one of the configured remotes."
        pause
        return 1
    fi

    read -r -p "Folder on that remote for backups [AzerothCore-Backups]: " folder
    folder="${folder:-AzerothCore-Backups}"

    RCLONE_REMOTE="${remote_name}:${folder}"
    RCLONE_ENABLED=1

    backup_save_config

    success "Remote backups will go to: $RCLONE_REMOTE"

    pause
}

do_remote_upload() {

    local backup_file="$1" quiet="$2"

    if ! command -v rclone >/dev/null 2>&1; then
        backup_log_message "Remote upload skipped: rclone not installed."
        return 1
    fi

    [[ "$quiet" == "1" ]] || { info "Uploading to $RCLONE_REMOTE..."; echo; }

    if rclone copy "$backup_file" "$RCLONE_REMOTE" >/dev/null 2>&1; then

        backup_log_message "Uploaded to remote: $(basename "$backup_file")"
        [[ "$quiet" == "1" ]] || success "Uploaded to $RCLONE_REMOTE."

        do_remote_prune "$quiet"

    else

        backup_log_message "Remote upload FAILED for $(basename "$backup_file")."
        [[ "$quiet" == "1" ]] || error "Remote upload failed."
        return 1

    fi

    return 0
}

do_remote_prune() {

    local quiet="$1"

    local listing pattern
    listing="$(rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null)" || return 0

    for pattern in '^azerothcore-(players-|accounts-)?[0-9].*\.sql$' '^azerothcore-config-.*\.tar\.gz$'; do

        mapfile -t remote_files < <(grep -E "$pattern" <<< "$listing" | sort -r)

        local total=${#remote_files[@]}

        [[ "$total" -le "$RCLONE_KEEP_LAST" ]] && continue

        local to_delete=("${remote_files[@]:$RCLONE_KEEP_LAST}")

        for f in "${to_delete[@]}"; do
            rclone deletefile "${RCLONE_REMOTE}/${f}" >/dev/null 2>&1
            backup_log_message "Pruned old remote backup: $f"
        done

        [[ "$quiet" == "1" ]] || info "Pruned ${#to_delete[@]} old remote backup(s), keeping the newest $RCLONE_KEEP_LAST."

    done

    return 0
}

cmd_remote_toggle() {

    header "AzerothCore AutoBackup"
    echo "Remote Backup (rclone)"
    echo "────────────────────────────────────────"
    echo

    if [[ -z "$RCLONE_REMOTE" ]]; then
        warning "No remote configured yet -- set one first."
        pause
        return 1
    fi

    if [[ "$RCLONE_ENABLED" == "1" ]]; then
        RCLONE_ENABLED=0
        backup_save_config
        success "Remote uploads disabled. Local backups are unaffected."
    else
        RCLONE_ENABLED=1
        backup_save_config
        success "Remote uploads enabled -> $RCLONE_REMOTE"
    fi

    pause
}

cmd_remote_retention() {

    header "AzerothCore AutoBackup"
    echo "Remote Retention"
    echo "────────────────────────────────────────"
    echo

    info "Current: keep last $RCLONE_KEEP_LAST backup(s) on the remote."
    echo

    local new_keep
    read -r -p "New remote retention count [$RCLONE_KEEP_LAST]: " new_keep

    if [[ -n "$new_keep" ]]; then

        if ! [[ "$new_keep" =~ ^[0-9]+$ ]]; then
            error "Must be a plain number."
            pause
            return 1
        fi

        RCLONE_KEEP_LAST="$new_keep"
        backup_save_config
        success "Remote retention set to $RCLONE_KEEP_LAST."

    fi

    pause
}

remote_menu() {

    while true; do

        header "AzerothCore AutoBackup"
        echo "Remote Backup (rclone)"
        echo "────────────────────────────────────────"
        echo

        if command -v rclone >/dev/null 2>&1; then
            success "rclone installed"
        else
            warning "rclone not installed"
        fi

        if [[ -n "$RCLONE_REMOTE" ]]; then
            info "Target     : $RCLONE_REMOTE"
            if [[ "$RCLONE_ENABLED" == "1" ]]; then
                echo -e "Uploads    ${GREEN}● ENABLED${RESET}"
            else
                echo -e "Uploads    ${DIM}○ disabled${RESET}"
            fi
            info "Retention  : last $RCLONE_KEEP_LAST on remote"
        else
            info "Target     : not set"
        fi

        echo
        echo "  1  Install rclone"
        echo "  2  Configure remote (rclone config)"
        echo
        echo "  3  Set remote + folder for backups"
        echo "  4  Enable / Disable remote uploads"
        echo
        echo "  5  Remote retention (max copies)"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) install_rclone ;;
            2) configure_remote ;;
            3) set_remote_target ;;
            4) cmd_remote_toggle ;;
            5) cmd_remote_retention ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# Commands
# ============================================================

cmd_run() {

    local quiet=0
    [[ "$1" == "--quiet" ]] && quiet=1

    if [[ "$quiet" -eq 0 ]]; then
        header "AzerothCore AutoBackup"
        check_core || { pause; return 1; }
        check_docker || { pause; return 1; }
        echo "Run Backup Now"
        echo "────────────────────────────────────────"
        echo
    fi

    do_backup "$quiet"
    local result=$?

    [[ "$quiet" -eq 1 ]] || pause

    return $result
}

backup_cmd_enable() {

    header "AzerothCore AutoBackup"

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    backup_check_docker_boot_enabled
    echo

    echo "Enable Automatic Backups"
    echo "────────────────────────────────────────"
    echo

    info "Interval : every ${INTERVAL_HOURS}h"
    info "Keep     : last ${KEEP_LAST} backups"
    info "Folder   : $BACKUP_DIR"
    echo

    backup_save_config
    success "Configuration written: $BACKUP_CONFIG_FILE"

    info "Installing systemd service + timer (needs sudo)..."
    echo

    if ! write_systemd_units; then
        error "Failed to write systemd units."
        pause
        return 1
    fi

    sudo systemctl daemon-reload

    if sudo systemctl enable --now "$TIMER_NAME"; then
        echo
        success "Automatic backups enabled."
        info "First backup runs ~1 min from now, then every ${INTERVAL_HOURS}h."
        info "If the server is off when a backup is due, it runs as soon as it's back up."
    else
        error "Failed to start the backup timer."
    fi

    pause
}

backup_cmd_disable() {

    header "AzerothCore AutoBackup"

    echo "Disable Automatic Backups"
    echo "────────────────────────────────────────"
    echo

    if [[ ! -f "$TIMER_FILE" ]]; then
        warning "Automatic backups are not installed."
        pause
        return
    fi

    if ! confirm "Stop and remove the backup timer? (existing backup files are kept)"; then
        return
    fi

    sudo systemctl disable --now "$TIMER_NAME" 2>/dev/null || true
    sudo systemctl stop "$BACKUP_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$BACKUP_SERVICE_FILE" "$TIMER_FILE"
    sudo systemctl daemon-reload

    success "Automatic backups disabled. Existing backups were not deleted."

    pause
}

backup_cmd_status() {

    header "AzerothCore AutoBackup"

    echo "Automatic Backups Status"
    echo "────────────────────────────────────────"
    echo

    backup_check_docker_boot_enabled && info "docker.service enabled at boot: yes"
    echo

    if [[ -f "$TIMER_FILE" ]]; then

        if timer_status; then
            echo -e "Timer        ${GREEN}● ACTIVE${RESET}"
        else
            echo -e "Timer        ${RED}● INACTIVE${RESET}"
        fi

        if timer_enabled; then
            info "Enabled at boot: yes"
        else
            info "Enabled at boot: no"
        fi

        if command -v systemctl >/dev/null 2>&1; then

            local next
            next="$(systemctl list-timers "$TIMER_NAME" --no-legend 2>/dev/null | awk '{print $1, $2, $3}')"
            [[ -n "$next" ]] && info "Next run: $next"

        fi

    else
        echo -e "Timer        ${DIM}○ NOT INSTALLED${RESET}"
    fi

    echo
    info "Interval : every ${INTERVAL_HOURS}h"
    info "Keep     : last ${KEEP_LAST} backups"
    info "Folder   : $BACKUP_DIR"
    echo

    if [[ -d "$BACKUP_DIR" ]]; then

        local count last
        count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' | wc -l)"
        last="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' -printf '%f\n' 2>/dev/null | sort -r | head -n1)"

        info "Backups on disk: $count"
        [[ -n "$last" ]] && info "Most recent: $last"
        info "Config archives: $(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-config-*.tar.gz' | wc -l)"

    else
        info "Backups on disk: 0 (folder doesn't exist yet)"
    fi

    echo

    if [[ "$RCLONE_ENABLED" == "1" ]] && [[ -n "$RCLONE_REMOTE" ]]; then
        echo -e "Remote       ${GREEN}● ENABLED${RESET} -> $RCLONE_REMOTE (keep last $RCLONE_KEEP_LAST)"
    elif [[ -n "$RCLONE_REMOTE" ]]; then
        echo -e "Remote       ${DIM}○ configured but disabled${RESET} ($RCLONE_REMOTE)"
    else
        echo -e "Remote       ${DIM}○ not configured${RESET}"
    fi

    if [[ -f "$LOG_FILE" ]]; then
        echo
        info "Last log lines:"
        tail -n 5 "$LOG_FILE" | sed 's/^/    /'
    fi

    if [[ -f "$BACKUP_SERVICE_FILE" ]] && command -v journalctl >/dev/null 2>&1; then
        echo
        info "Last systemd log lines for the backup service:"
        journalctl -u "$BACKUP_SERVICE_NAME" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
    fi

    pause
}

backup_cmd_list() {

    header "AzerothCore AutoBackup"

    echo "Existing Backups"
    echo "────────────────────────────────────────"
    echo

    if [[ ! -d "$BACKUP_DIR" ]]; then
        warning "No backup directory found."
        pause
        return
    fi

    mapfile -t backups < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'azerothcore-*.sql' \
            -printf '%f\t%s\n' |
        sort -r
    )

    if [[ ${#backups[@]} -eq 0 ]]; then
        warning "No backups found."
        pause
        return
    fi

    for entry in "${backups[@]}"; do

        local name size
        name="${entry%%$'\t'*}"
        size="${entry##*$'\t'}"

        printf "  %-32s %8s\n" "$name" "$(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")"

    done

    echo
    info "Total: ${#backups[@]} backup(s) in $BACKUP_DIR"

    local cfg_count
    cfg_count="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-config-*.tar.gz' | wc -l)"
    [[ "$cfg_count" -gt 0 ]] && info "Plus $cfg_count configuration archive(s) (azerothcore-config-*.tar.gz)."

    pause
}

cmd_prune() {

    header "AzerothCore AutoBackup"

    echo "Prune Old Backups"
    echo "────────────────────────────────────────"
    echo

    info "Keeping the newest $KEEP_LAST backup(s), deleting the rest."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    do_prune 0
    do_prune_config

    pause
}

backup_cmd_configure() {

    header "AzerothCore AutoBackup"

    echo "Configure Automatic Backups"
    echo "────────────────────────────────────────"
    echo

    info "Current interval : every ${INTERVAL_HOURS}h"
    info "Current retention: last ${KEEP_LAST} backups"
    echo

    local new_interval new_keep

    read -r -p "New interval in hours [$INTERVAL_HOURS]: " new_interval
    read -r -p "New retention (how many backups to keep) [$KEEP_LAST]: " new_keep

    [[ -n "$new_interval" ]] && INTERVAL_HOURS="$new_interval"
    [[ -n "$new_keep" ]] && KEEP_LAST="$new_keep"

    backup_save_config

    if [[ -f "$TIMER_FILE" ]]; then

        echo
        info "Rewriting timer with the new interval and restarting it..."

        if ! write_systemd_units; then
            error "Failed to write systemd units."
            pause
            return 1
        fi

        sudo systemctl daemon-reload
        sudo systemctl restart "$TIMER_NAME"
        success "Automatic backups reconfigured."

    else
        success "Configuration updated (timer not installed yet)."
    fi

    pause
}

# ============================================================
# Interactive menu
# ============================================================

backup_menu() {

    while true; do

        header "AzerothCore AutoBackup"

        if [[ -f "$TIMER_FILE" ]] && timer_status; then
            echo -e "Timer        ${GREEN}● ACTIVE${RESET}  (every ${INTERVAL_HOURS}h, keeping last ${KEEP_LAST})"
        elif [[ -f "$TIMER_FILE" ]]; then
            echo -e "Timer        ${RED}● INACTIVE${RESET}"
        else
            echo -e "Timer        ${DIM}○ NOT INSTALLED${RESET}"
        fi

        echo
        echo "  1  Enable (install + start automatic backups)"
        echo "  2  Disable (stop + remove the timer)"
        echo
        echo "  3  Status"
        echo "  4  Run backup now"
        echo
        echo "  5  List backups"
        echo "  6  Prune old backups"
        echo
        echo "  7  Configure (interval / retention)"
        echo
        echo "  8  Remote backup (rclone)"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) backup_cmd_enable ;;
            2) backup_cmd_disable ;;
            3) backup_cmd_status ;;
            4) cmd_run ;;
            5) backup_cmd_list ;;
            6) cmd_prune ;;
            7) backup_cmd_configure ;;
            8) remote_menu ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

backup_usage() {
    echo "Usage: $(basename "$0") backup [enable|disable|status|run|list|prune|configure|remote]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  enable         install + start the systemd timer"
    echo "  disable        stop + remove the timer (keeps existing backups)"
    echo "  status         show timer status, backup count, recent log"
    echo "  run            take a backup right now (database + configuration archive; --quiet for scripted/cron use)"
    echo "  list           list existing backups with sizes"
    echo "  prune          delete backups beyond the retention count"
    echo "  configure      change interval (hours) / retention (count)"
    echo "  remote         configure/manage remote backup via rclone"
}

# ============================================================
# Entry point
# ============================================================

backup_dispatch() {

    case "${1:-menu}" in
        enable)    backup_cmd_enable ;;
        disable)   backup_cmd_disable ;;
        status)    backup_cmd_status ;;
        run)       cmd_run "$2" ;;
        list)      backup_cmd_list ;;
        prune)     cmd_prune ;;
        configure) backup_cmd_configure ;;
        remote)    remote_menu ;;
        menu)      backup_menu ;;
        -h|--help) backup_usage ;;
        *)
            error "Unknown command: $1"
            echo
            backup_usage
            exit 1
            ;;
    esac
}

# ============================================================
# SECTION: account
# ============================================================

# ============================================================
# Account section
#
# Manages AzerothCore
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
#   ./azerothcore-manager.sh account                      interactive menu
#   ./azerothcore-manager.sh account create <user> [pass] create an account
#   ./azerothcore-manager.sh account list                 list every account
#   ./azerothcore-manager.sh account info <user>          show one account's details
#   ./azerothcore-manager.sh account setgm <user> <lvl>   set GM level (0-4, all realms)
#   ./azerothcore-manager.sh account setpass <user> [pw]  change an account's password
#   ./azerothcore-manager.sh account delete <user>        delete an account (blocked if it has characters)
# ============================================================
















# ============================================================
# Core / Docker / DB helpers
# ============================================================













# Cached across calls within the same run -- the root password
# doesn't change while ac-database keeps running.
CACHED_DB_PASSWORD=""

db_password() {

    if [[ -z "$CACHED_DB_PASSWORD" ]]; then
        CACHED_DB_PASSWORD="$(get_db_password)"
    fi

    echo "$CACHED_DB_PASSWORD"
}

account_db_query() {
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

        if [[ ${#p1} -gt 16 ]]; then
            error "The WoW client only accepts passwords up to 16 characters." >&2
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
    account_db_query "SELECT id FROM acore_auth.account WHERE UPPER(username) = UPPER('$(sql_clean "$1")');"
}

account_gmlevel() {
    # $1 = account id. Prints the all-realms (RealmID=-1) gmlevel, or 0.
    local level
    level="$(account_db_query "SELECT gmlevel FROM acore_auth.account_access WHERE id = ${1} AND RealmID = -1;")"
    echo "${level:-0}"
}

character_count() {
    # $1 = account id.
    account_db_query "SELECT COUNT(*) FROM acore_characters.characters WHERE account = ${1};"
}

# ============================================================
# Commands
# ============================================================

cmd_create() {

    header "AzerothCore Account"
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

    if ! [[ "$username" =~ ^[A-Za-z0-9]{1,17}$ ]]; then
        error "Use 1-17 letters or digits for the account name."
        pause
        return 1
    fi

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

    header "AzerothCore Account"
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

    header "AzerothCore Account"
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

    header "AzerothCore Account"
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

    header "AzerothCore Account"
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

    header "AzerothCore Account"
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

account_menu() {

    while true; do

        header "AzerothCore Account"

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
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

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

account_usage() {
    echo "Usage: $(basename "$0") account [create|list|info|setgm|setpass|delete] [args]"
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

account_dispatch() {

    case "${1:-menu}" in
        menu)     account_menu ;;
        create)   cmd_create "$2" "$3" ;;
        list)     cmd_list ;;
        info)     cmd_info "$2" ;;
        setgm)    cmd_setgm "$2" "$3" ;;
        setpass)  cmd_setpass "$2" "$3" ;;
        delete)   cmd_delete "$2" ;;
        -h|--help) account_usage ;;
        *)
            error "Unknown command: $1"
            echo
            account_usage
            exit 1
            ;;
    esac
}

# ============================================================
# SECTION: network
# ============================================================

# ============================================================
# Network section
#
# Views and changes the
# realmlist's public address and/or local address (the IPs
# players connect to and that the auth server hands out).
#
# Usage:
#   ./azerothcore-manager.sh network          interactive menu
#   ./azerothcore-manager.sh network show     show current realmlist entries
#   ./azerothcore-manager.sh network set      change address / localAddress
# ============================================================
















# ============================================================
# Core / Docker / DB helpers
# ============================================================











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

    header "AzerothCore Network"

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

    header "AzerothCore Network"

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

            new_address="$(sql_clean "$new_address")"

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

            new_local_address="$(sql_clean "$new_local_address")"

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

network_menu() {

    while true; do

        header "AzerothCore Network"

        echo "  1  Show realmlist"
        echo
        echo "  2  Change address / localAddress"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice || exit 0

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

network_usage() {
    echo "Usage: $(basename "$0") network [show|set]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  show           show current realmlist entries"
    echo "  set            change address and/or localAddress"
}

# ============================================================
# Entry point
# ============================================================

network_dispatch() {

    case "${1:-menu}" in
        menu) network_menu ;;
        show) cmd_show ;;
        set)  cmd_set ;;
        -h|--help) network_usage ;;
        *)
            error "Unknown command: $1"
            echo
            network_usage
            exit 1
            ;;
    esac
}


# ============================================================
# Unified top-level menu and CLI entry point
# ============================================================

top_menu() {

    while true; do

        header "AzerothCore Manager"

        print_server_status

        echo
        echo "  1  Server"
        echo "  2  Modules"
        echo
        echo "  3  AutoSleep"
        echo "  4  AutoBackup"
        echo
        echo "  5  Account"
        echo "  6  Network"
        echo
        echo "  7  Setup"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice || exit 0

        case "$choice" in
            1) main_menu ;;
            2) modules_menu ;;
            3) sleep_menu ;;
            4) backup_menu ;;
            5) account_menu ;;
            6) network_menu ;;
            7) setup_menu ;;
            0)
                clear_screen
                exit 0
                ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

top_usage() {
    echo "Usage: $(basename "$0") [server|modules|sleep|backup|account|network|setup] [args...]"
    echo
    echo "  (no argument)  interactive top-level menu (pick a section)"
    echo
    echo "  server  [args...]   start/stop/restart/status/logs, backup/restore, configure"
    echo "  modules [args...]   optional module management + Playerbots/AH Bot config"
    echo "  sleep   [args...]   idle-pause monitor + instant-wake proxy"
    echo "  backup  [args...]   scheduled automatic backups + rclone remote copy"
    echo "  account [args...]   account creation, GM levels"
    echo "  network [args...]   realmlist address configuration"
    echo "  setup   [args...]   install/update/rebuild/uninstall AzerothCore"
    echo
    echo "Each section takes its own subcommands -- e.g.:"
    echo "  $(basename "$0") sleep enable"
    echo "  $(basename "$0") backup run --quiet"
    echo "  $(basename "$0") account create Someone"
    echo "  $(basename "$0") network show"
    echo
    echo "Run '$(basename "$0") <section> --help' for that section's own commands."
}

case "${1:-}" in

    server)
        shift
        manager_dispatch "$@"
        ;;

    modules)
        shift
        modules_dispatch "$@"
        ;;

    sleep)
        shift
        sleep_dispatch "$@"
        ;;

    backup)
        shift
        backup_dispatch "$@"
        ;;

    account)
        shift
        account_dispatch "$@"
        ;;

    network)
        shift
        network_dispatch "$@"
        ;;

    setup)
        shift
        setup_dispatch "$@"
        ;;

    -h|--help)
        top_usage
        ;;

    "")
        top_menu
        ;;

    *)
        error "Unknown section: $1"
        echo
        top_usage
        exit 1
        ;;

esac
