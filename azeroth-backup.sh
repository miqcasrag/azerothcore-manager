#!/usr/bin/env bash

set -o pipefail

# ============================================================
# azeroth-backup.sh
#
# Standalone companion to ac-manager.sh. Installs and manages
# automatic, periodic database backups (e.g. every 4 hours) using
# a systemd timer, independent of ac-manager.sh and
# azeroth-sleep.sh.
#
# Backups land in the same folder ac-manager.sh already uses
# ($SCRIPT_DIR/backups) and use the same filename pattern
# (azerothcore-<timestamp>.sql), so anything created here also
# shows up in ac-manager.sh's own "Restore" menu.
#
# Usage:
#   ./azeroth-backup.sh                interactive menu
#   ./azeroth-backup.sh enable         install + start the timer
#   ./azeroth-backup.sh disable        stop + remove the timer
#   ./azeroth-backup.sh status         show timer/last-backup status
#   ./azeroth-backup.sh run            take a backup right now
#   ./azeroth-backup.sh list           list existing backups
#   ./azeroth-backup.sh prune          delete backups beyond the retention count
#   ./azeroth-backup.sh configure      change interval / retention
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"
BACKUP_DIR="$SCRIPT_DIR/backups"

CONFIG_FILE="$SCRIPT_DIR/.azeroth-backup.conf"
LOG_FILE="$SCRIPT_DIR/.azeroth-backup.log"

SERVICE_NAME="ac-manager-backup.service"
TIMER_NAME="ac-manager-backup.timer"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

# Defaults, overridden by $CONFIG_FILE if it exists.
INTERVAL_HOURS=4      # how often to back up
KEEP_LAST=30          # how many backups to keep (oldest get pruned)

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

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
    echo -e "${BOLD}AzerothCore Automatic Backups${RESET}"
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
# Docker helpers
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

check_docker_boot_enabled() {

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

# ============================================================
# Config persistence
# ============================================================

save_config() {

    cat > "$CONFIG_FILE" << EOF
INTERVAL_HOURS=$INTERVAL_HOURS
KEEP_LAST=$KEEP_LAST
EOF
}

# ============================================================
# Systemd service + timer
# ============================================================

write_systemd_units() {

    local user
    user="$(whoami)"

    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore Scheduled Backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/azeroth-backup.sh run --quiet
User=$user
EOF

    sudo tee "$TIMER_FILE" > /dev/null << EOF
[Unit]
Description=Run AzerothCore Scheduled Backup every ${INTERVAL_HOURS}h

[Timer]
OnBootSec=10min
OnUnitActiveSec=${INTERVAL_HOURS}h
Persistent=true
Unit=$SERVICE_NAME

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

log_message() {
    logger -t azeroth-backup "$1" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1" >> "$LOG_FILE"
}

do_backup() {

    local quiet="$1"

    if ! compose ps --status running --services 2>/dev/null | grep -qx "ac-database"; then
        log_message "Skipped: ac-database is not running."
        [[ "$quiet" == "1" ]] || error "Database container is not running."
        return 1
    fi

    local password
    password="$(get_db_password)"

    if [[ -z "$password" ]]; then
        log_message "Skipped: could not read MYSQL_ROOT_PASSWORD."
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
        --all-databases \
        --single-transaction \
        --routines \
        --triggers \
        -uroot \
        -p"$password" \
        > "$backup_file" 2>/dev/null

    if [[ $? -eq 0 ]] && [[ -s "$backup_file" ]]; then

        log_message "Backup created: $(basename "$backup_file") ($(du -h "$backup_file" | cut -f1))"
        [[ "$quiet" == "1" ]] || { success "Backup completed."; echo; echo "  $backup_file"; }

    else

        rm -f "$backup_file"
        log_message "Backup FAILED."
        [[ "$quiet" == "1" ]] || error "Backup failed."
        return 1

    fi

    do_prune "$quiet"

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
        log_message "Pruned old backup: $f"
    done

    [[ "$quiet" == "1" ]] || info "Pruned ${#to_delete[@]} old backup(s), keeping the newest $KEEP_LAST."

    return 0
}

# ============================================================
# Commands
# ============================================================

cmd_run() {

    local quiet=0
    [[ "$1" == "--quiet" ]] && quiet=1

    if [[ "$quiet" -eq 0 ]]; then
        header
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

cmd_enable() {

    header

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_docker_boot_enabled
    echo

    echo "Enable Automatic Backups"
    echo "────────────────────────────────────────"
    echo

    info "Interval : every ${INTERVAL_HOURS}h"
    info "Keep     : last ${KEEP_LAST} backups"
    info "Folder   : $BACKUP_DIR"
    echo

    save_config
    success "Configuration written: $CONFIG_FILE"

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
        info "First backup runs ~10 min after this timer starts, then every ${INTERVAL_HOURS}h."
        info "Missed runs (server was off) are caught up on next boot, thanks to Persistent=true."
    else
        error "Failed to start the backup timer."
    fi

    pause
}

cmd_disable() {

    header

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
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE" "$TIMER_FILE"
    sudo systemctl daemon-reload

    success "Automatic backups disabled. Existing backups were not deleted."

    pause
}

cmd_status() {

    header

    echo "Automatic Backups Status"
    echo "────────────────────────────────────────"
    echo

    check_docker_boot_enabled && info "docker.service enabled at boot: yes"
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

    if [[ -f "$LOG_FILE" ]]; then
        echo
        info "Last log lines:"
        tail -n 5 "$LOG_FILE" | sed 's/^/    /'
    fi

    pause
}

cmd_list() {

    header

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

    header

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

cmd_configure() {

    header

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

    save_config

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

menu() {

    while true; do

        header

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
        echo "  3  Status"
        echo "  4  Run backup now"
        echo "  5  List backups"
        echo "  6  Prune old backups"
        echo "  7  Configure (interval / retention)"
        echo
        echo "  0  Back / Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) cmd_enable ;;
            2) cmd_disable ;;
            3) cmd_status ;;
            4) cmd_run ;;
            5) cmd_list ;;
            6) cmd_prune ;;
            7) cmd_configure ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [enable|disable|status|run|list|prune|configure]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  enable         install + start the systemd timer"
    echo "  disable        stop + remove the timer (keeps existing backups)"
    echo "  status         show timer status, backup count, recent log"
    echo "  run            take a backup right now (add --quiet for scripted/cron use)"
    echo "  list           list existing backups with sizes"
    echo "  prune          delete backups beyond the retention count"
    echo "  configure      change interval (hours) / retention (count)"
}

# ============================================================
# Entry point
# ============================================================

case "${1:-menu}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    status)    cmd_status ;;
    run)       cmd_run "$2" ;;
    list)      cmd_list ;;
    prune)     cmd_prune ;;
    configure) cmd_configure ;;
    menu)      menu ;;
    -h|--help) usage ;;
    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;
esac
