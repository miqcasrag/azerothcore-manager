#!/usr/bin/env bash

set -o pipefail

# ============================================================
# AzerothCore Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

OVERRIDE_FILE="$SCRIPT_DIR/docker-compose.override.yml"

CORE_REPO="https://github.com/mod-playerbots/azerothcore-wotlk.git"
CORE_BRANCH="Playerbot"

PLAYERBOTS_REPO="https://github.com/mod-playerbots/mod-playerbots.git"
PLAYERBOTS_BRANCH="master"

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
# Modules
# ============================================================

MODULES=(
    "mod-playerbots|https://github.com/miqcasrag/mod-playerbots.git|master"
    "mod-ah-bot-plus|https://github.com/NathanHandley/mod-ah-bot-plus.git|master"
    "mod-autobalance|https://github.com/azerothcore/mod-autobalance.git|master"
    "mod-challenge-modes|https://github.com/ZhengPeiRu21/mod-challenge-modes.git|master"
    "mod-individual-progression|https://github.com/ZhengPeiRu21/mod-individual-progression.git|master"
    "mod-dungeon-clear|https://github.com/jrad7/mod-dungeon-clear.git|master"
)

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

    if [[ ! -f "$CORE_DIR/.env" ]]; then
        touch "$CORE_DIR/.env"
    fi

    if grep -q '^TZ=' "$CORE_DIR/.env"; then
        sed -i "s|^TZ=.*$|TZ=$timezone|" "$CORE_DIR/.env"
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
        "$CORE_DIR/volumes/ac-database" \
        "$CORE_DIR/volumes/ac-client-data" \
        "$CORE_DIR/volumes/ac-build-dev" \
        "$CORE_DIR/volumes/ac-ccache-dev" \
        "$CORE_DIR/volumes/backups" \
        "$CORE_DIR/env/dist/etc" \
        "$CORE_DIR/env/dist/logs"

    success "Directories ready."
}

# ============================================================
# Portable override
# ============================================================

install_override() {

    if [[ ! -f "$OVERRIDE_FILE" ]]; then
        error "docker-compose.override.yml not found."
        echo
        echo "Expected:"
        echo "  $OVERRIDE_FILE"
        return 1
    fi

    cp "$OVERRIDE_FILE" \
        "$CORE_DIR/docker-compose.override.yml"

    if [[ $? -ne 0 ]]; then
        error "Failed to copy docker-compose.override.yml."
        return 1
    fi

    success "Portable Docker override installed."
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

    if ! command -v git >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y git
    fi

    if ! command -v docker >/dev/null 2>&1; then

        sudo apt update
        sudo apt install -y \
            ca-certificates \
            curl

        sudo install -m 0755 -d /etc/apt/keyrings

        sudo curl -fsSL \
            https://download.docker.com/linux/debian/gpg \
            -o /etc/apt/keyrings/docker.asc

        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
            sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

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

    if ! docker compose version >/dev/null 2>&1; then
        sudo apt update
        sudo apt install -y docker-compose-plugin
    fi

    success "Dependencies ready."
}

# ============================================================
# Build / Rebuild
# ============================================================

run_build() {

    local operation="$1"
    local start_time
    local result

    start_time="$(date +%s)"

    echo
    echo -e "${BOLD}${operation}${RESET}"
    echo "────────────────────────────────────────"
    echo

    (
        cd "$CORE_DIR" || exit 1
        docker compose build --progress=plain
    )

    result=$?

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

    run_build "Rebuild"

    pause
}

# ============================================================
# Permissions
# ============================================================

fix_permissions() {

    check_core || return 1

    (
        cd "$CORE_DIR" || exit 1

        sudo chown -R 1000:1000 \
            env/dist/etc \
            env/dist/logs
    )
}

# ============================================================
# ac-db-import
# ============================================================

check_db_import() {

    local status

    status="$(
        compose ps -a \
            --format '{{.Name}} {{.Status}}' \
            2>/dev/null |
        grep 'ac-db-import' || true
    )"

    [[ -z "$status" ]] && return 0

    if echo "$status" |
        grep -qiE 'Exited \([1-9]|unhealthy|failed'; then
        return 1
    fi

    return 0
}

check_after_start() {

    sleep 2

    if check_db_import; then
        return 0
    fi

    echo
    error "ac-db-import failed."
    echo

    warning "This is usually caused by incorrect permissions."
    echo
    echo "Run from the AzerothCore directory:"
    echo
    echo "  cd azerothcore-wotlk"
    echo "  sudo chown -R 1000:1000 env/dist/etc env/dist/logs"
    echo
    warning "Then run Start again."

    return 1
}

# ============================================================
# Server control
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

    info "Starting server..."
    echo

    compose up -d

    if [[ $? -ne 0 ]]; then
        error "Docker Compose failed."
        pause
        return
    fi

    if ! check_after_start; then
        pause
        return
    fi

    success "Server started."

    pause
}

stop_server() {

    header

    check_core || {
        pause
        return
    }

    info "Stopping server..."

    compose down

    if [[ $? -eq 0 ]]; then
        success "Server stopped."
    else
        error "Failed to stop server."
    fi

    pause
}

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

    compose restart

    if [[ $? -ne 0 ]]; then
        error "Failed to restart server."
        pause
        return
    fi

    if ! check_after_start; then
        pause
        return
    fi

    success "Server restarted."

    pause
}

status_server() {

    header

    check_core || {
        pause
        return
    }

    compose ps

    pause
}

logs_server() {

    check_core || return 1

    (
        cd "$CORE_DIR" || exit 1
        docker compose logs -f --tail=100
    )
}

# ============================================================
# Modules
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

install_module() {

    local name="$1"
    local repo="$2"
    local branch="$3"

    local target="$CORE_DIR/modules/$name"

    if [[ -d "$target" ]]; then
        warning "$name is already installed."
        return 0
    fi

    mkdir -p "$CORE_DIR/modules"

    info "Installing $name..."

    git clone \
        --branch "$branch" \
        "$repo" \
        "$target"

    if [[ $? -eq 0 ]]; then
        success "$name installed."
        warning "A rebuild is required."
        return 0
    fi

    error "Failed to install $name."
    return 1
}

module_status() {

    local number=1

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name repo branch <<< "$module"

        if [[ -d "$CORE_DIR/modules/$name" ]]; then
            printf "  %-2s %-30s " "$number" "$name"
            echo -e "${GREEN}● installed${RESET}"
        else
            printf "  %-2s %-30s " "$number" "$name"
            echo -e "${DIM}○ not installed${RESET}"
        fi

        ((number++))

    done
}

module_install_menu() {

    header

    echo "Install module"
    echo "────────────────────────────────────────"
    echo

    local number=1

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name repo branch <<< "$module"

        echo "  $number  $name"

        ((number++))

    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[1-6]$ ]]; then
        error "Invalid selection."
        pause
        return
    fi

    local index=$((choice - 1))

    IFS="|" read -r name repo branch <<< "${MODULES[$index]}"

    echo

    if confirm "Install $name?"; then
        install_module "$name" "$repo" "$branch"
    fi

    pause
}

module_remove_menu() {

    header

    echo "Remove module"
    echo "────────────────────────────────────────"
    echo

    local number=1

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name repo branch <<< "$module"

        echo "  $number  $name"

        ((number++))

    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[1-6]$ ]]; then
        error "Invalid selection."
        pause
        return
    fi

    local index=$((choice - 1))

    IFS="|" read -r name repo branch <<< "${MODULES[$index]}"

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

    if ! confirm "Continue?"; then
        return
    fi

    rm -rf -- "$target"

    success "$name removed."

    echo
    warning "A rebuild is required."

    pause
}

module_update_menu() {

    header

    echo "Update modules"
    echo "────────────────────────────────────────"
    echo

    local updated=0

    for module in "${MODULES[@]}"; do

        IFS="|" read -r name repo branch <<< "$module"

        local target="$CORE_DIR/modules/$name"

        if [[ -d "$target/.git" ]]; then

            info "Updating $name..."

            git -C "$target" pull --ff-only

            echo

            updated=1
        fi

    done

    if [[ "$updated" -eq 0 ]]; then
        warning "No modules are installed."
    else
        success "Module update completed."
        warning "A rebuild may be required."
    fi

    pause
}

module_menu() {

    while true; do

        header

        echo "Modules"
        echo "────────────────────────────────────────"
        echo

        module_status

        echo
        echo "  7  Install module"
        echo "  8  Remove module"
        echo "  9  Update modules"
        echo
        echo "  0  Back"
        echo

        read -r -p "Select: " choice

        case "$choice" in

            7) module_install_menu ;;
            8) module_remove_menu ;;
            9) module_update_menu ;;
            0) return ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Backup / Restore
# ============================================================

get_db_password() {

    compose exec -T ac-database \
        printenv MYSQL_ROOT_PASSWORD 2>/dev/null
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

    mkdir -p "$CORE_DIR/volumes/backups"

    local timestamp
    local backup_file

    timestamp="$(date +%F_%H-%M-%S)"
    backup_file="$CORE_DIR/volumes/backups/azerothcore-$timestamp.sql"

    info "Creating database backup..."
    echo

    compose exec -T ac-database \
        mysqldump \
        --all-databases \
        --single-transaction \
        --routines \
        --triggers \
        -uroot \
        -p"$password" \
        > "$backup_file"

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        success "Backup completed."
        echo
        echo "  $backup_file"
    else
        error "Backup failed."
        rm -f "$backup_file"
    fi

    pause
}

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

    local backup_dir="$CORE_DIR/volumes/backups"

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
        ((i++))
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

    compose exec -T ac-database \
        mysql \
        -uroot \
        -p"$password" \
        < "$selected"

    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        success "Restore completed."
    else
        error "Restore failed."
    fi

    pause
}

# ============================================================
# Update
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

    info "Checking for updates..."

    git -C "$CORE_DIR" fetch origin "$CORE_BRANCH"

    if [[ $? -ne 0 ]]; then
        error "Failed to fetch updates."
        pause
        return
    fi

    local current_commit
    local latest_commit

    current_commit="$(git -C "$CORE_DIR" rev-parse HEAD)"
    latest_commit="$(
        git -C "$CORE_DIR" rev-parse "origin/$CORE_BRANCH"
    )"

    if [[ "$current_commit" == "$latest_commit" ]]; then
        success "AzerothCore is already up to date."
        pause
        return
    fi

    echo
    info "New AzerothCore commits are available."
    echo

    if ! confirm "Update AzerothCore?"; then
        return
    fi

    echo

    info "Updating AzerothCore..."

    if ! git -C "$CORE_DIR" merge --ff-only \
        "origin/$CORE_BRANCH"; then

        error "Failed to update AzerothCore."
        pause
        return
    fi

    configure_timezone
    install_override

    success "AzerothCore updated."

    echo
    info "Rebuilding..."
    echo

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

    install_override || {
        pause
        return
    }

    configure_timezone
    prepare_directories

    echo

    if confirm "Install mod-playerbots?"; then

        install_playerbots

        if [[ $? -ne 0 ]]; then
            error "Playerbot installation failed."
            pause
            return
        fi

    else

        info "mod-playerbots skipped."

    fi

    echo
    info "Starting initial build..."
    echo

    run_build "Build"

    local result=$?

    echo

    if [[ "$result" -ne 0 ]]; then
        error "Installation failed during build."
        pause
        return
    fi

    success "Installation completed."

    echo
    warning "AzerothCore Docker containers use UID:GID 1000:1000."
    echo

    if confirm "Fix permissions for env/dist/etc and env/dist/logs?"; then

        if fix_permissions; then
            success "Permissions fixed."
        else
            error "Failed to fix permissions."
        fi
    fi

    echo
    info "Server remains OFFLINE."
    info "Use Start when you want to run AzerothCore."

    pause
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
                mv "$CORE_DIR/volumes" \
                    "$temp_dir/volumes"
            fi

            rm -rf -- "$CORE_DIR"

            success "Server removed."

            warning "Volumes preserved at:"
            echo "  $temp_dir/volumes"

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
        echo "  8  Modules"

        echo
        echo "  9  Rebuild"

        echo
        echo " 10  Update"
        echo " 11  Install"
        echo " 12  Uninstall"

        echo
        echo "  0  Exit"

        echo

        read -r -p "Select: " choice

        case "$choice" in

            1)  start_server ;;
            2)  stop_server ;;
            3)  restart_server ;;
            4)  status_server ;;
            5)  logs_server ;;
            6)  backup_databases ;;
            7)  restore_databases ;;
            8)  module_menu ;;
            9)  rebuild_server ;;
            10) update_core ;;
            11) install_server ;;
            12) uninstall_server ;;

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

    install)   install_server ;;
    uninstall) uninstall_server ;;
    start)     start_server ;;
    stop)      stop_server ;;
    restart)   restart_server ;;
    status)    status_server ;;
    logs)      logs_server ;;
    backup)    backup_databases ;;
    restore)   restore_databases ;;
    rebuild)   rebuild_server ;;
    update)    update_core ;;

    module)

        case "${2:-}" in
            install) module_install_menu ;;
            remove)  module_remove_menu ;;
            update)  module_update_menu ;;
            *)       module_menu ;;
        esac

        ;;

    *)
        main_menu
        ;;

esac
