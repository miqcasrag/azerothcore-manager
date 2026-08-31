#!/usr/bin/env bash

set -o pipefail

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
#   ./ac-backup.sh                interactive menu
#   ./ac-backup.sh enable         install + start the timer
#   ./ac-backup.sh disable        stop + remove the timer
#   ./ac-backup.sh status         show timer/last-backup status
#   ./ac-backup.sh run            take a backup right now
#   ./ac-backup.sh list           list existing backups
#   ./ac-backup.sh prune          delete backups beyond the retention count
#   ./ac-backup.sh configure      change interval / retention
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"
BACKUP_DIR="$SCRIPT_DIR/backups"

CONFIG_FILE="$SCRIPT_DIR/.ac-backup.conf"
LOG_FILE="$SCRIPT_DIR/.ac-backup.log"

SERVICE_NAME="ac-manager-backup.service"
TIMER_NAME="ac-manager-backup.timer"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"
TIMER_FILE="/etc/systemd/system/$TIMER_NAME"

# Defaults, overridden by $CONFIG_FILE if it exists.
INTERVAL_HOURS=4      # how often to back up
KEEP_LAST=30          # how many backups to keep locally (oldest get pruned)

RCLONE_ENABLED=0      # 1 = also upload each backup to a remote via rclone
RCLONE_REMOTE=""      # e.g. "gdrive:AzerothBackups"
RCLONE_KEEP_LAST=10   # how many backups to keep on the remote

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
    echo -e "${BOLD}AzerothCore Backup${RESET}"
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

    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore Scheduled Backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/ac-backup.sh run --quiet
User=$user
EOF

    sudo tee "$TIMER_FILE" > /dev/null << EOF
[Unit]
Description=Run AzerothCore Scheduled Backup every ${INTERVAL_HOURS}h

[Timer]
OnActiveSec=1min
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
    logger -t ac-backup "$1" 2>/dev/null || true
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
        --databases acore_auth acore_characters acore_playerbots \
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
        log_message "Pruned old backup: $f"
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

    header
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

    header
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

    save_config

    success "Remote backups will go to: $RCLONE_REMOTE"

    pause
}

do_remote_upload() {

    local backup_file="$1" quiet="$2"

    if ! command -v rclone >/dev/null 2>&1; then
        log_message "Remote upload skipped: rclone not installed."
        return 1
    fi

    [[ "$quiet" == "1" ]] || { info "Uploading to $RCLONE_REMOTE..."; echo; }

    if rclone copy "$backup_file" "$RCLONE_REMOTE" >/dev/null 2>&1; then

        log_message "Uploaded to remote: $(basename "$backup_file")"
        [[ "$quiet" == "1" ]] || success "Uploaded to $RCLONE_REMOTE."

        do_remote_prune "$quiet"

    else

        log_message "Remote upload FAILED for $(basename "$backup_file")."
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
        log_message "Pruned old remote backup: $f"
    done

    [[ "$quiet" == "1" ]] || info "Pruned ${#to_delete[@]} old remote backup(s), keeping the newest $RCLONE_KEEP_LAST."

    return 0
}

cmd_remote_toggle() {

    header
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
        save_config
        success "Remote uploads disabled. Local backups are unaffected."
    else
        RCLONE_ENABLED=1
        save_config
        success "Remote uploads enabled -> $RCLONE_REMOTE"
    fi

    pause
}

cmd_remote_retention() {

    header
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
        save_config
        success "Remote retention set to $RCLONE_KEEP_LAST."

    fi

    pause
}

remote_menu() {

    while true; do

        header
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
        info "First backup runs ~1 min from now, then every ${INTERVAL_HOURS}h."
        info "If the server is off when a backup is due, it runs as soon as it's back up."
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

    if [[ -f "$SERVICE_FILE" ]] && command -v journalctl >/dev/null 2>&1; then
        echo
        info "Last systemd log lines for the backup service:"
        journalctl -u "$SERVICE_NAME" -n 5 --no-pager 2>/dev/null | sed 's/^/    /'
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
            1) cmd_enable ;;
            2) cmd_disable ;;
            3) cmd_status ;;
            4) cmd_run ;;
            5) cmd_list ;;
            6) cmd_prune ;;
            7) cmd_configure ;;
            8) remote_menu ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [enable|disable|status|run|list|prune|configure|remote]"
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

case "${1:-menu}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    status)    cmd_status ;;
    run)       cmd_run "$2" ;;
    list)      cmd_list ;;
    prune)     cmd_prune ;;
    configure) cmd_configure ;;
    remote)    remote_menu ;;
    menu)      menu ;;
    -h|--help) usage ;;
    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;
esac
