#!/usr/bin/env bash

set -o pipefail

# ============================================================
# ac-aio.sh
#
# All-in-one build combining, as sections of a single file:
#   ac-manager.sh   (install, start/stop/restart, backups, update/uninstall)
#   ac-modules.sh   (optional modules + Playerbots/AH Bot config)
#   ac-sleep.sh     (idle-pause monitor + instant-wake proxy)
#   ac-backup.sh    (scheduled automatic backups + rclone remote copy)
#   ac-account.sh   (account creation, GM levels)
#   ac-network.sh   (realmlist address configuration)
#
# This is a separate, standalone project from the six individual
# scripts it was assembled from -- it does not need any of them
# present to run. Everything lives in this one file, name-spaced
# into sections to avoid collisions (see the section markers
# below), sharing one copy of the identical helper functions
# (colours, header/success/error/warning/info, pause/confirm,
# check_core, check_docker, compose, get_db_password, etc.) that
# every section used to carry its own copy of.
#
# Usage:
#   ./ac-aio.sh                       interactive top-level menu
#   ./ac-aio.sh manager  [args...]    -> ac-manager.sh's own commands
#   ./ac-aio.sh modules  [args...]    -> ac-modules.sh's own commands
#   ./ac-aio.sh sleep    [args...]    -> ac-sleep.sh's own commands
#   ./ac-aio.sh backup   [args...]    -> ac-backup.sh's own commands
#   ./ac-aio.sh account  [args...]    -> ac-account.sh's own commands
#   ./ac-aio.sh network  [args...]    -> ac-network.sh's own commands
#
# Each section's own [args...] are exactly what that script
# accepted standalone -- e.g.:
#   ./ac-aio.sh sleep enable
#   ./ac-aio.sh backup run --quiet
#   ./ac-aio.sh account create Someone
#   ./ac-aio.sh network show
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
# Shared helpers (identical across all six original scripts,
# kept here as a single copy)
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

header() {
    clear_screen

    echo
    echo -e "${BOLD}${1:-AzerothCore Manager}${RESET}"
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
# SECTION: manager  (ac-manager.sh)
# ============================================================

# ============================================================
# AzerothCore Manager
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

    success "Directories ready."
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

    (
        cd "$CORE_DIR" || exit 1

        sudo chown -R \
            "${DOCKER_UID}:${DOCKER_GID}" \
            .
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
# installed there by ac-module.sh), since the same bug can hit
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

database_exists() {

    local database="$1"
    local password

    password="$(get_db_password)"

    [[ -z "$password" ]] && return 1

    compose exec -T \
        ac-database \
        mysql \
        -uroot \
        -p"$password" \
        -Nse \
        "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$database';" \
        2>/dev/null |
    grep -qx "$database"
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
        # deliberately (edit playerbots.conf: AiPlayerbot.Enabled = 1)
        # once ready, instead of 500 random bots populating the
        # world right after the first start.
        sed -i \
            's|^AiPlayerbot.Enabled[[:space:]]*=.*$|AiPlayerbot.Enabled = 0|' \
            "$config_dir/playerbots.conf"

        success "Playerbots configuration created (disabled by default)."
        info "Enable it in: $config_dir/playerbots.conf (AiPlayerbot.Enabled = 1)"

    else

        success "Existing Playerbots configuration preserved."

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

PLAYERBOTS_OVERRIDE_MARKER="# managed-by: ac-manager.sh (playerbots modules mount + TZ)"

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

build_server() {

    header

    check_core || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    run_build "Build"

    pause
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

check_db_import() {

    local status

    status="$(get_container_status "ac-db-import")"

    [[ -z "$status" ]] && return 0

    if echo "$status" |
        grep -qiE '\|exited\|.*\(0\)|\|running\|'; then

        return 0

    fi

    if echo "$status" |
        grep -qiE '\|exited\|.*\([1-9][0-9]*\)|unhealthy|failed'; then

        return 1

    fi

    return 0
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

    info "Restarting server..."

    if ! compose restart; then

        error "Failed to restart server."
        pause
        return

    fi

    sleep 5

    if ! compose ps \
        --status running \
        --services 2>/dev/null |
        grep -qx "ac-worldserver"; then

        error "ac-worldserver is not running after restart."
        echo

        compose logs --tail=100 ac-worldserver

        pause
        return

    fi

    success "Server restarted."

    pause
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
# managed separately by ac-modules.sh)
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

    backup_file="$BACKUP_DIR/azerothcore-$timestamp.sql"

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

    if [[ "$result" -eq 0 ]]; then

        success "Backup completed."

        echo
        echo "  $backup_file"

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

    local password

    password="$(get_db_password)"

    if [[ -z "$password" ]]; then

        error "Could not read database password."
        pause
        return

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

    if [[ "$current_commit" == "$latest_commit" ]]; then

        success "AzerothCore is already up to date."

    else

        echo
        info "New AzerothCore commits are available."
        echo

        if ! confirm "Update AzerothCore?"; then
            return
        fi

        echo

        # ----------------------------------------------------
        # Safety: require clean working tree.
        # ----------------------------------------------------

        if [[ -n "$(git -C "$CORE_DIR" status --porcelain)" ]]; then

            warning "AzerothCore working tree contains local changes."
            echo
            git -C "$CORE_DIR" status --short
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

    fi

    # --------------------------------------------------------
    # Playerbots
    # --------------------------------------------------------

    if [[ -d "$CORE_DIR/modules/mod-playerbots/.git" ]]; then

        echo
        info "Updating mod-playerbots..."

        if ! git -C \
            "$CORE_DIR/modules/mod-playerbots" \
            pull --ff-only; then

            error "Failed to update mod-playerbots."
            pause
            return

        fi

        success "mod-playerbots updated."

    fi

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

    echo
    info "Rebuilding..."

    run_build "Rebuild"

    local result=$?

    echo

    if [[ "$result" -eq 0 ]]; then

        success "Update completed successfully."
        info "Server remains OFFLINE."

    else

        error "Update completed, but rebuild failed."
        warning "Server remains OFFLINE."

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

        sudo curl -fsSL \
            https://download.docker.com/linux/debian/gpg \
            -o /etc/apt/keyrings/docker.asc

        sudo chmod a+r \
            /etc/apt/keyrings/docker.asc

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
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

    if ! install_dependencies; then

        pause
        return

    fi

    echo

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

    echo

    configure_timezone
    prepare_directories

    echo

    info "Installing mod-playerbots..."
    echo

    if ! install_playerbots; then

        error "Playerbot installation failed."

        pause
        return

    fi

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
    # Optional: restore an existing backup before the first start
    # --------------------------------------------------------

    mkdir -p "$BACKUP_DIR"

    local has_backup=0

    while true; do

        if find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' -print -quit 2>/dev/null | grep -q .; then
            has_backup=1
            break
        fi

        warning "No backups found in:"
        echo "  $BACKUP_DIR"
        echo
        info "Copy a backup file into that folder now, then refresh."
        echo
        echo "  1  Refresh"
        echo "  2  Skip -- continue without restoring"
        echo

        read -r -p "Select: " backup_choice

        case "$backup_choice" in

            1)
                echo
                continue
                ;;

            2)
                echo
                break
                ;;

            *)
                error "Invalid selection."
                echo
                ;;

        esac

    done

    if [[ "$has_backup" -eq 1 ]]; then

        if confirm "An existing backup was found. Restore it now, before starting the server?"; then

            echo
            info "Starting the database container..."

            compose up -d ac-database

            echo

            if wait_for_database; then

                echo

                restore_databases

            else

                error "Could not bring up the database to restore into."
                pause

            fi

        fi

        echo

    fi

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

cleanup_companion_services() {

    # ac-sleep.sh and ac-backup.sh are independent scripts, but if
    # they've installed systemd services against this install,
    # leaving them running after an uninstall just means broken
    # loops (nothing left to pause/back up). Offer to clean them
    # up too, purely as a courtesy -- this script still doesn't
    # depend on either of them to function.

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
    info "Also stopping and removing ac-sleep.sh/ac-backup.sh services for this server:"
    for unit in "${found[@]}"; do
        echo "    - $unit"
    done

    for unit in "${found[@]}"; do
        sudo systemctl disable --now "$unit" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/$unit"
    done

    sudo systemctl daemon-reload

    success "Companion services stopped and removed."

    return 0
}

uninstall_server() {

    header

    check_core || {
        pause
        return
    }

    echo "Uninstall"
    echo "────────────────────────────────────────"
    echo

    echo "  1  Remove server"
    echo "  2  Remove server + volumes"
    echo "  0  Cancel"
    echo

    read -r -p "Select: " choice

    if [[ "$choice" == "1" ]] || [[ "$choice" == "2" ]]; then
        cleanup_companion_services
    fi

    case "$choice" in

        1)

            echo
            info "This will delete:"
            echo "    - The AzerothCore server files (source, config, docker-compose)"
            echo
            info "This will be preserved:"
            echo "    - The database (Docker volume)"
            echo "    - The client data cache (Docker volume)"
            echo
            info "A future reinstall will pick up right where this left off."
            echo

            compose down 2>/dev/null || true

            local temp_dir

            temp_dir="$(mktemp -d)"

            if [[ -d "$CORE_DIR/volumes" ]]; then

                mv \
                    "$CORE_DIR/volumes" \
                    "$temp_dir/volumes"

            fi

            rm -rf -- "$CORE_DIR"

            success "Server removed."

            if [[ -d "$temp_dir/volumes" ]]; then

                warning "Volumes preserved at:"
                echo "  $temp_dir/volumes"

            fi

            ;;

        2)

            echo
            warning "This will permanently delete:"
            echo "    - The AzerothCore server files"
            echo "    - The ENTIRE DATABASE (all accounts, characters, guilds, mail, everything)"
            echo "    - The client data cache (Docker volumes)"
            echo
            warning "There is no undo. Back up first (ac-aio.sh manager > Backup) if you're not sure."
            echo

            local confirm_word

            read -r -p "Type DELETE to confirm: " confirm_word

            if [[ "$confirm_word" != "DELETE" ]]; then
                warning "Not confirmed. Nothing was deleted."
                pause
                return
            fi

            compose down --volumes 2>/dev/null || true

            rm -rf -- "$CORE_DIR"

            success "AzerothCore completely removed, including the database volumes."

            ;;

        0)

            return
            ;;

        *)

            error "Invalid selection."
            ;;

    esac

    pause
}

# ============================================================
# Main menu
# ============================================================

main_menu() {

    while true; do

        header

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
        echo "  8  Rebuild"

        echo
        echo "  9  Update"
        echo " 10  Install"
        echo " 11  Uninstall"

        echo
        echo "  0  Exit"

        echo

        read -r -p "Select: " choice

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
                rebuild_server
                ;;

            9)
                update_core
                ;;

            10)
                install_server
                ;;

            11)
                uninstall_server
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

manager_dispatch() {

    case "${1:-}" in

        install)
            install_server
            ;;

        uninstall)
            uninstall_server
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

        rebuild)
            rebuild_server
            ;;

        update)
            update_core
            ;;

        *)

            main_menu
            ;;

    esac
}

# ============================================================
# SECTION: modules  (ac-modules.sh)
# ============================================================

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
#   ./ac-aio.sh modules                interactive menu
#   ./ac-aio.sh modules list           show install status of every module
#   ./ac-aio.sh modules install <name> clone a module
#   ./ac-aio.sh modules remove <name>  remove a module
#   ./ac-aio.sh modules update [name]  update one module, or all installed ones
# ============================================================


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
# rebuild via ac-manager.sh doesn't choke on it.
# ============================================================



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

        warning "A rebuild is required (ac-aio.sh manager > Rebuild)."

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
    warning "A rebuild is required (ac-aio.sh manager > Rebuild)."

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
    warning "A rebuild is required (ac-aio.sh manager > Rebuild)."

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

    header "AzerothCore Modules"
    echo "Performance-Tuned Bot Settings (mod-playerbots)"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }

    if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        error "mod-playerbots is not installed."
        info "It's installed automatically by ac-aio.sh manager > Install."
        pause
        return 1
    fi

    local conf
    conf="$(playerbots_conf_path)"

    if [[ ! -f "$conf" ]]; then
        error "playerbots.conf not found at: $conf"
        info "Run ac-aio.sh manager > Install (or Update) first."
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

    header "AzerothCore Modules"
    echo "Random Bot Count (mod-playerbots)"
    echo "────────────────────────────────────────"
    echo

    check_core || { pause; return 1; }

    if [[ ! -d "$CORE_DIR/modules/mod-playerbots" ]]; then
        error "mod-playerbots is not installed."
        info "It's installed automatically by ac-aio.sh manager > Install."
        pause
        return 1
    fi

    local conf
    conf="$(playerbots_conf_path)"

    if [[ ! -f "$conf" ]]; then
        error "playerbots.conf not found at: $conf"
        info "Run ac-aio.sh manager > Install (or Update) first."
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

        header "AzerothCore Modules"
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

        header "AzerothCore Modules"
        echo "mod-playerbots"
        echo "────────────────────────────────────────"
        echo

        if [[ -d "$CORE_DIR/modules/mod-playerbots" ]]; then
            echo -e "Status   ${GREEN}● installed${RESET} (required, managed by ac-manager.sh)"
        else
            echo -e "Status   ${RED}○ not installed${RESET} (run ac-aio.sh manager > Install)"
        fi

        echo
        local pb_conf pb_status
        pb_conf="$(playerbots_conf_path)"
        pb_status="$(enable_status_label "$(read_key_value "$pb_conf" "AiPlayerbot.Enabled")")"
        echo -e "  1  Enable / Disable   [${pb_status}]"
        echo
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
                    info "Run ac-aio.sh manager > Install (or Update) first."
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

modules_menu() {

    while true; do

        header "AzerothCore Modules"

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

            header "AzerothCore Modules"
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
    warning "A rebuild + restart is required (ac-aio.sh manager > Rebuild)."

    pause
}

modules_usage() {
    echo "Usage: $(basename "$0") modules [list|install <name>|remove <name>|update [name]|ahbot]"
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

modules_dispatch() {

    case "${1:-menu}" in

        menu)
            modules_menu
            ;;

        ahbot)
            cmd_ahbot_setup
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
            do_install "$name" "$repo" "$branch"
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
# SECTION: sleep  (ac-sleep.sh)
# ============================================================

# ============================================================
# ac-sleep.sh
#
# Standalone companion to ac-manager.sh. Freezes the AzerothCore
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
#   ./ac-aio.sh sleep                 interactive menu
#   ./ac-aio.sh sleep enable          set everything up and start it
#   ./ac-aio.sh sleep disable         stop + remove everything
#   ./ac-aio.sh sleep status          show monitor/proxy/server status
#   ./ac-aio.sh sleep wake            unpause the server now
#   ./ac-aio.sh sleep configure       change timeouts/ports
#   ./ac-aio.sh sleep monitor         run the idle-watch loop (used by systemd)
#   ./ac-aio.sh sleep proxy           run the instant-wake proxy (used by systemd)
#   ./ac-aio.sh sleep thaw            unpause quietly (used by the proxy)
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

    grep -E '^DOCKER_AUTH_EXTERNAL_PORT=' "$env_file" 2>/dev/null |
        tail -n1 |
        cut -d= -f2-
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
        info "ac-sleep.sh expects the standard AzerothCore service names"
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

    confirm "Set DOCKER_AUTH_EXTERNAL_PORT=${PROXY_TARGET_PORT} in .env and recreate ac-authserver now?" || return 1

    if grep -q '^DOCKER_AUTH_EXTERNAL_PORT=' "$env_file"; then
        sed -i "s|^DOCKER_AUTH_EXTERNAL_PORT=.*\$|DOCKER_AUTH_EXTERNAL_PORT=${PROXY_TARGET_PORT}|" "$env_file"
    else
        echo "DOCKER_AUTH_EXTERNAL_PORT=${PROXY_TARGET_PORT}" >> "$env_file"
    fi

    success "Updated .env: DOCKER_AUTH_EXTERNAL_PORT=${PROXY_TARGET_PORT}"
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
Description=AzerothCore Sleep Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/ac-aio.sh sleep monitor
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
Description=AzerothCore Sleep Instant-Wake Proxy
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/ac-aio.sh sleep proxy
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

proxy_service_enabled() {
    systemctl is-enabled --quiet "$PROXY_SERVICE_NAME" 2>/dev/null
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
        sleep_log_message "Server is now sleeping."
    else
        sleep_log_message "Failed to pause containers."
    fi
}

thaw_servers() {

    local reason="${1:-Player connecting}"

    sleep_log_message "${reason} - thawing server..."

    if compose unpause ac-worldserver ac-authserver 2>/dev/null; then
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

    header "AzerothCore Sleep"

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

    header "AzerothCore Sleep"

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
            echo
            warning "The server is currently sleeping (paused)."
            info "Run './ac-aio.sh sleep wake' to wake it up."
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

    header "AzerothCore Sleep"

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
        rm -f "$SLEEP_SINCE_FILE"
        date +%s > "$STATE_FILE"
        success "Server woken up."
    else
        error "Failed to wake the server."
    fi

    pause
}

sleep_cmd_status() {

    header "AzerothCore Sleep"

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

    header "AzerothCore Sleep"

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

        header "AzerothCore Sleep"

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
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

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
# SECTION: backup  (ac-backup.sh)
# ============================================================

# ============================================================
# ac-backup.sh
#
# Standalone companion to ac-manager.sh. Installs and manages
# automatic, periodic database backups (e.g. every 4 hours) using
# a systemd timer, independent of ac-manager.sh and
# ac-sleep.sh.
#
# Backups land in the same folder ac-manager.sh already uses
# ($SCRIPT_DIR/backups) and use the same filename pattern
# (azerothcore-<timestamp>.sql), so anything created here also
# shows up in ac-manager.sh's own "Restore" menu.
#
# Usage:
#   ./ac-aio.sh backup                interactive menu
#   ./ac-aio.sh backup enable         install + start the timer
#   ./ac-aio.sh backup disable        stop + remove the timer
#   ./ac-aio.sh backup status         show timer/last-backup status
#   ./ac-aio.sh backup run            take a backup right now
#   ./ac-aio.sh backup list           list existing backups
#   ./ac-aio.sh backup prune          delete backups beyond the retention count
#   ./ac-aio.sh backup configure      change interval / retention
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
RCLONE_REMOTE=""      # e.g. "gdrive:AzerothBackups"
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
Description=AzerothCore Scheduled Backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/ac-aio.sh backup run --quiet
User=$user
EOF

    sudo tee "$TIMER_FILE" > /dev/null << EOF
[Unit]
Description=Run AzerothCore Scheduled Backup every ${INTERVAL_HOURS}h

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
    backup_file="$BACKUP_DIR/azerothcore-$timestamp.sql"

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

        backup_log_message "Backup created: $(basename "$backup_file") ($(du -h "$backup_file" | cut -f1))"
        [[ "$quiet" == "1" ]] || { success "Backup completed."; echo; echo "  $backup_file"; }

    else

        rm -f "$backup_file"
        backup_log_message "Backup FAILED."
        [[ "$quiet" == "1" ]] || error "Backup failed."
        return 1

    fi

    do_prune "$quiet"

    if [[ "$RCLONE_ENABLED" == "1" ]] && [[ -n "$RCLONE_REMOTE" ]]; then
        do_remote_upload "$backup_file" "$quiet"
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

    header "AzerothCore Backup"
    echo "Install rclone"
    echo "────────────────────────────────────────"
    echo

    if command -v rclone >/dev/null 2>&1; then
        success "rclone is already installed ($(rclone version 2>/dev/null | head -n1))."
        pause
        return 0
    fi

    if command -v apt >/dev/null 2>&1; then

        info "Installing rclone via apt..."
        echo

        if sudo apt update && sudo apt install -y rclone; then
            success "rclone installed."
            pause
            return 0
        fi

        warning "apt install failed or rclone isn't in your repos."

    fi

    echo
    warning "Falling back to rclone's official install script."
    warning "This downloads and runs a script as root (curl | sudo bash) --"
    warning "standard practice for rclone, but worth knowing before you continue."
    echo

    if confirm "Continue with the official install script?"; then

        if curl -fsSL https://rclone.org/install.sh | sudo bash; then
            success "rclone installed."
        else
            error "rclone installation failed."
        fi

    fi

    pause
}

configure_remote() {

    header "AzerothCore Backup"
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

    if confirm "Set which remote + folder ac-backup.sh should upload to now?"; then
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

    read -r -p "Folder on that remote for backups [AzerothBackups]: " folder
    folder="${folder:-AzerothBackups}"

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

    mapfile -t remote_files < <(
        rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null |
        grep '^azerothcore-.*\.sql$' |
        sort -r
    )

    local total=${#remote_files[@]}

    if [[ "$total" -le "$RCLONE_KEEP_LAST" ]]; then
        return 0
    fi

    local to_delete=("${remote_files[@]:$RCLONE_KEEP_LAST}")

    for f in "${to_delete[@]}"; do
        rclone deletefile "${RCLONE_REMOTE}/${f}" >/dev/null 2>&1
        backup_log_message "Pruned old remote backup: $f"
    done

    [[ "$quiet" == "1" ]] || info "Pruned ${#to_delete[@]} old remote backup(s), keeping the newest $RCLONE_KEEP_LAST."

    return 0
}

cmd_remote_toggle() {

    header "AzerothCore Backup"
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

    header "AzerothCore Backup"
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

        header "AzerothCore Backup"
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

        read -r -p "Select: " choice

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
        header "AzerothCore Backup"
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

    header "AzerothCore Backup"

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

    header "AzerothCore Backup"

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

    header "AzerothCore Backup"

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

    header "AzerothCore Backup"

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

    pause
}

cmd_prune() {

    header "AzerothCore Backup"

    echo "Prune Old Backups"
    echo "────────────────────────────────────────"
    echo

    info "Keeping the newest $KEEP_LAST backup(s), deleting the rest."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    do_prune 0

    pause
}

backup_cmd_configure() {

    header "AzerothCore Backup"

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

        header "AzerothCore Backup"

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
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

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
    echo "  run            take a backup right now (add --quiet for scripted/cron use)"
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
# SECTION: account  (ac-account.sh)
# ============================================================

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
#   ./ac-aio.sh account                      interactive menu
#   ./ac-aio.sh account create <user> [pass] create an account
#   ./ac-aio.sh account list                 list every account
#   ./ac-aio.sh account info <user>          show one account's details
#   ./ac-aio.sh account setgm <user> <lvl>   set GM level (0-4, all realms)
#   ./ac-aio.sh account setpass <user> [pw]  change an account's password
#   ./ac-aio.sh account delete <user>        delete an account (blocked if it has characters)
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

        echo "$p1"
        return 0

    done
}

# ============================================================
# Account lookups
# ============================================================

account_id() {
    # $1 = username (case-insensitive). Prints the id, or nothing.
    account_db_query "SELECT id FROM acore_auth.account WHERE UPPER(username) = UPPER('${1//\'/}');"
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
# SECTION: network  (ac-network.sh)
# ============================================================

# ============================================================
# ac-network.sh
#
# Standalone companion to ac-manager.sh. Views and changes the
# realmlist's public address and/or local address (the IPs
# players connect to and that the auth server hands out).
#
# Usage:
#   ./ac-aio.sh network          interactive menu
#   ./ac-aio.sh network show     show current realmlist entries
#   ./ac-aio.sh network set      change address / localAddress
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

network_menu() {

    while true; do

        header "AzerothCore Network"

        echo "  1  Show realmlist"
        echo
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

        header "AzerothCore Manager (All-in-One)"

        echo "  1  Manager"
        echo "  2  Modules"
        echo
        echo "  3  Sleep"
        echo "  4  Backup"
        echo
        echo "  5  Account"
        echo "  6  Network"
        echo
        echo "  0  Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) main_menu ;;
            2) modules_menu ;;
            3) sleep_menu ;;
            4) backup_menu ;;
            5) account_menu ;;
            6) network_menu ;;
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
    echo "Usage: $(basename "$0") [manager|modules|sleep|backup|account|network] [args...]"
    echo
    echo "  (no argument)  interactive top-level menu (pick a section)"
    echo
    echo "  manager [args...]   AzerothCore install/start/stop/backup/update/uninstall"
    echo "  modules [args...]   optional module management + Playerbots/AH Bot config"
    echo "  sleep   [args...]   idle-pause monitor + instant-wake proxy"
    echo "  backup  [args...]   scheduled automatic backups + rclone remote copy"
    echo "  account [args...]   account creation, GM levels"
    echo "  network [args...]   realmlist address configuration"
    echo
    echo "Each section's [args...] are exactly what that section's original"
    echo "standalone script accepted -- e.g.:"
    echo "  $(basename "$0") sleep enable"
    echo "  $(basename "$0") backup run --quiet"
    echo "  $(basename "$0") account create Someone"
    echo "  $(basename "$0") network show"
    echo
    echo "Run '$(basename "$0") <section> --help' for that section's own commands."
}

case "${1:-}" in

    manager)
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
