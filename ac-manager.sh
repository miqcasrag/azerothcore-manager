#!/usr/bin/env bash

set -o pipefail

# ============================================================
# AzerothCore Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"
BACKUP_DIR="$SCRIPT_DIR/backups"

CORE_REPO="https://github.com/mod-playerbots/azerothcore-wotlk.git"
CORE_BRANCH="Playerbot"

PLAYERBOTS_REPO="https://github.com/mod-playerbots/mod-playerbots.git"
PLAYERBOTS_BRANCH="master"

DOCKER_UID="1000"
DOCKER_GID="1000"

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
# UI
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

header() {
    clear_screen

    echo
    echo -e "${BOLD}AzerothCore Manager${RESET}"
    echo "────────────────────────────────────────"
    echo
}

success() {
    echo -e "${GREEN}✓${RESET} $1"
}

error() {
    echo -e "${RED}✗${RESET} $1"
}

warning() {
    echo -e "${YELLOW}!${RESET} $1"
}

info() {
    echo -e "${CYAN}›${RESET} $1"
}

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
# Docker
# ============================================================

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

get_db_password() {

    compose exec -T \
        ac-database \
        printenv MYSQL_ROOT_PASSWORD \
        2>/dev/null
}

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

        echo

        if confirm "Apply recommended performance-tuned bot settings?"; then
            apply_playerbots_tuning "$config_dir/playerbots.conf"
        fi

    else

        success "Existing Playerbots configuration preserved."

    fi

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

    success "Performance-tuned bot settings applied:"
    echo "    AiPlayerbot.DisabledWithoutRealPlayer = 1"
    echo "    AiPlayerbot.DisableMoveSplinePath     = 1"
    echo "    AiPlayerbot.MaxMovementSearchTime     = 5"
    echo "    AiPlayerbot.AutoGearQualityLimit      = 4"
    echo "    AiPlayerbot.RandomGearLoweringChance  = 0.75"
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
           grep -q "TZ=" "$override_file"; then
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

        return 1

    fi

    cat > "$override_file" << EOF
$PLAYERBOTS_OVERRIDE_MARKER
services:
  ac-worldserver:
    volumes:
      - ./modules:/azerothcore/modules:ro
    environment:
      - TZ=$timezone
  ac-authserver:
    environment:
      - TZ=$timezone
  ac-database:
    environment:
      - TZ=$timezone
EOF

    success "docker-compose.override.yml created (mounts modules/ and sets TZ=$timezone)."

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
        --all-databases \
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

    if [[ -d "$BACKUP_DIR" ]] && \
       find "$BACKUP_DIR" -maxdepth 1 -type f -name 'azerothcore-*.sql' -print -quit | grep -q .; then

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

    case "$choice" in

        1)

            echo
            warning "AzerothCore will be removed."
            echo "The volumes directory will be preserved."
            echo

            if ! confirm "Continue?"; then
                return
            fi

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
            warning "This will delete the complete server and all volumes."
            echo

            if ! confirm "THIS CANNOT BE UNDONE. Continue?"; then
                return
            fi

            compose down 2>/dev/null || true

            rm -rf -- "$CORE_DIR"

            success "AzerothCore completely removed."

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
                exit 0
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
