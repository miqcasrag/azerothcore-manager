#!/usr/bin/env bash

set -o pipefail

# ============================================================
# azeroth-sleep.sh
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
#     loop by a systemd service, watching established TCP
#     connections on the worldserver port.
#   - The instant-thaw proxy is also this same script (a "proxy"
#     sub-command run by a second systemd service). It uses socat
#     to listen on the port players actually connect to (3724),
#     thaws the containers if they're paused, then bridges the
#     connection to the real ac-authserver -- which is moved to
#     an internal-only port (3725) to make room. This is the same
#     trick the original project uses, just aimed at Docker
#     instead of bare processes.
#
# ac-database is left running so waking up is fast and doesn't
# need a fresh DB import.
#
# Usage:
#   ./azeroth-sleep.sh                 interactive menu
#   ./azeroth-sleep.sh enable          set everything up and start it
#   ./azeroth-sleep.sh disable         stop + remove everything
#   ./azeroth-sleep.sh status          show monitor/proxy/server status
#   ./azeroth-sleep.sh wake            unpause the server now
#   ./azeroth-sleep.sh configure       change timeouts/ports
#   ./azeroth-sleep.sh monitor         run the idle-watch loop (used by systemd)
#   ./azeroth-sleep.sh proxy           run the instant-wake proxy (used by systemd)
#   ./azeroth-sleep.sh thaw            unpause quietly (used by the proxy)
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

CONFIG_FILE="$SCRIPT_DIR/.azeroth-sleep.conf"
STATE_FILE="$SCRIPT_DIR/.sleep-last-activity"

SERVICE_NAME="ac-manager-sleep.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

PROXY_SERVICE_NAME="ac-manager-sleep-proxy.service"
PROXY_SERVICE_FILE="/etc/systemd/system/$PROXY_SERVICE_NAME"

# Defaults, overridden by $CONFIG_FILE if it exists.
IDLE_TIMEOUT=300          # seconds of inactivity before pausing (5 min)
CHECK_INTERVAL=60         # how often the monitor checks (seconds)
WORLD_PORT=8085           # worldserver port to watch for connections (AzerothCore's docker-compose.yml default)

PROXY_LISTEN_PORT=3724    # the port players actually connect to
PROXY_TARGET_PORT=3725    # internal port ac-authserver moves to, to make room for the proxy

# ------------------------------------------------------------
# If this is the first run (no saved config yet), try to pick up
# a custom port from the install's own .env, in case the user
# changed DOCKER_WORLD_EXTERNAL_PORT there. Falls back to the
# 8085 default above if .env doesn't set it.
# ------------------------------------------------------------

detect_world_port_from_env() {

    local env_file="$CORE_DIR/.env"

    [[ -f "$env_file" ]] || return

    grep -E '^DOCKER_WORLD_EXTERNAL_PORT=' "$env_file" 2>/dev/null |
        tail -n1 |
        cut -d= -f2-
}

detect_auth_port_from_env() {

    local env_file="$CORE_DIR/.env"

    [[ -f "$env_file" ]] || return

    grep -E '^DOCKER_AUTH_EXTERNAL_PORT=' "$env_file" 2>/dev/null |
        tail -n1 |
        cut -d= -f2-
}

if [[ -f "$CONFIG_FILE" ]]; then

    source "$CONFIG_FILE"

else

    detected_port="$(detect_world_port_from_env)"
    [[ -n "$detected_port" ]] && WORLD_PORT="$detected_port"

fi

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
    echo -e "${BOLD}AzerothCore Sleep Mode${RESET}"
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
        echo
        echo "  sudo apt install socat"
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
        info "azeroth-sleep.sh expects the standard AzerothCore service names"
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

save_config() {

    cat > "$CONFIG_FILE" << EOF
IDLE_TIMEOUT=$IDLE_TIMEOUT
CHECK_INTERVAL=$CHECK_INTERVAL
WORLD_PORT=$WORLD_PORT
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

    sudo tee "$SERVICE_FILE" > /dev/null << EOF
[Unit]
Description=AzerothCore Sleep Monitor
After=docker.service
Requires=docker.service

[Service]
Type=simple
ExecStart=$SCRIPT_DIR/azeroth-sleep.sh monitor
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
ExecStart=$SCRIPT_DIR/azeroth-sleep.sh proxy
Restart=always
RestartSec=5
User=$user

[Install]
WantedBy=multi-user.target
EOF
}

service_status() {
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null
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

log_message() {
    logger -t azeroth-sleep "$1" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

has_connections() {
    local count
    count="$(ss -Htn state established "sport = :${WORLD_PORT}" 2>/dev/null | wc -l)"
    [[ "$count" -gt 0 ]]
}

freeze_servers() {

    if is_paused "ac-worldserver"; then
        return
    fi

    if ! is_running "ac-worldserver"; then
        log_message "ac-worldserver is not running, nothing to freeze."
        return
    fi

    log_message "No activity for ${IDLE_TIMEOUT}s. Pausing ac-worldserver and ac-authserver..."

    if compose pause ac-worldserver ac-authserver 2>/dev/null; then
        log_message "Server is now sleeping."
    else
        log_message "Failed to pause containers."
    fi
}

cmd_monitor() {

    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || date +%s > "$STATE_FILE"

    log_message "Sleep monitor starting (idle timeout ${IDLE_TIMEOUT}s, checking every ${CHECK_INTERVAL}s, watching port ${WORLD_PORT})."

    while true; do

        if is_paused "ac-worldserver"; then
            # Already sleeping. Waking up is handled by the proxy
            # (a player connecting) or manually ("wake"), so just
            # wait and don't touch the activity timer.
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
# to). Every incoming connection first triggers a quiet thaw (only
# does anything if the server is paused), then gets bridged
# straight through to the real ac-authserver on
# 127.0.0.1:PROXY_TARGET_PORT. If the server was already awake
# this adds practically no delay; if it was sleeping, the player
# waits roughly as long as "docker compose unpause" takes.
# ============================================================

cmd_thaw() {

    if is_paused "ac-worldserver"; then

        log_message "Incoming connection - thawing server..."

        if compose unpause ac-worldserver ac-authserver >/dev/null 2>&1; then
            log_message "Server thawed."
        else
            log_message "Failed to thaw server."
        fi

    fi

    date +%s > "$STATE_FILE"
}

cmd_proxy() {

    check_proxy_dependencies || exit 1

    log_message "Instant-wake proxy starting: 0.0.0.0:${PROXY_LISTEN_PORT} -> 127.0.0.1:${PROXY_TARGET_PORT}"

    exec socat -d \
        TCP4-LISTEN:"${PROXY_LISTEN_PORT}",fork,reuseaddr \
        SYSTEM:"'$SCRIPT_DIR/azeroth-sleep.sh' thaw >&2; exec socat STDIO TCP4:127.0.0.1:${PROXY_TARGET_PORT}"
}

# ============================================================
# Commands
# ============================================================

cmd_enable() {

    header

    check_core || { pause; return 1; }
    check_docker || { pause; return 1; }
    check_dependencies || { pause; return 1; }
    check_proxy_dependencies || { pause; return 1; }
    check_docker_boot_enabled
    echo

    echo "Enable Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    check_services || {
        confirm "Continue enabling anyway?" || { pause; return 1; }
        echo
    }

    info "Idle timeout   : ${IDLE_TIMEOUT}s"
    info "Check every    : ${CHECK_INTERVAL}s"
    info "Watched port   : ${WORLD_PORT} (ac-worldserver)"
    info "Player connects to : ${PROXY_LISTEN_PORT} (proxy, instant wake)"
    echo

    ensure_auth_port_moved || {
        error "Could not move ac-authserver's port. Aborting."
        pause
        return 1
    }

    echo

    save_config
    success "Configuration written: $CONFIG_FILE"

    info "Installing systemd services (needs sudo)..."
    echo

    if ! write_systemd_unit || ! write_proxy_systemd_unit; then
        error "Failed to write systemd unit(s)."
        pause
        return 1
    fi

    sudo systemctl daemon-reload

    local ok=1

    if ! sudo systemctl enable --now "$SERVICE_NAME"; then
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

cmd_disable() {

    header

    echo "Disable Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    if [[ ! -f "$SERVICE_FILE" ]] && [[ ! -f "$PROXY_SERVICE_FILE" ]]; then
        warning "Sleep mode is not installed."
        pause
        return
    fi

    if ! confirm "Stop and remove the sleep monitor and instant-wake proxy?"; then
        return
    fi

    sudo systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable --now "$PROXY_SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "$SERVICE_FILE" "$PROXY_SERVICE_FILE"
    sudo systemctl daemon-reload

    success "Sleep mode disabled."

    if check_core >/dev/null 2>&1 && check_docker >/dev/null 2>&1; then

        if is_paused "ac-worldserver"; then
            echo
            warning "The server is currently sleeping (paused)."
            info "Run './azeroth-sleep.sh wake' to wake it up."
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

    header

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
        date +%s > "$STATE_FILE"
        success "Server woken up."
    else
        error "Failed to wake the server."
    fi

    pause
}

cmd_status() {

    header

    echo "Sleep Mode Status"
    echo "────────────────────────────────────────"
    echo

    check_docker_boot_enabled && info "docker.service enabled at boot: yes"
    echo
    if [[ -f "$SERVICE_FILE" ]]; then

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
        else
            echo -e "Server       ${DIM}○ awake (or offline)${RESET}"
        fi

    fi

    echo
    info "Idle timeout       : ${IDLE_TIMEOUT}s"
    info "Check every        : ${CHECK_INTERVAL}s"
    info "Watched port       : ${WORLD_PORT}"
    info "Players connect on : ${PROXY_LISTEN_PORT}"
    info "ac-authserver on   : ${PROXY_TARGET_PORT} (internal)"

    local env_port env_auth_port
    env_port="$(detect_world_port_from_env)"
    env_auth_port="$(detect_auth_port_from_env)"

    if [[ -n "$env_port" ]] && [[ "$env_port" != "$WORLD_PORT" ]]; then
        echo
        warning "The install's .env now has DOCKER_WORLD_EXTERNAL_PORT=$env_port,"
        warning "but this monitor is watching port $WORLD_PORT. Run 'Configure' to fix."
    fi

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

cmd_configure() {

    header

    echo "Configure Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    info "Current idle timeout       : ${IDLE_TIMEOUT}s"
    info "Current check every        : ${CHECK_INTERVAL}s"
    info "Current watched port       : ${WORLD_PORT}"
    info "Current player-facing port : ${PROXY_LISTEN_PORT}"
    info "Current ac-authserver port : ${PROXY_TARGET_PORT} (internal)"
    echo

    local new_timeout new_interval new_port new_listen new_target

    read -r -p "New idle timeout in seconds [$IDLE_TIMEOUT]: " new_timeout
    read -r -p "New check interval in seconds [$CHECK_INTERVAL]: " new_interval
    read -r -p "New worldserver port [$WORLD_PORT]: " new_port
    read -r -p "New player-facing (proxy) port [$PROXY_LISTEN_PORT]: " new_listen
    read -r -p "New internal ac-authserver port [$PROXY_TARGET_PORT]: " new_target

    [[ -n "$new_timeout" ]] && IDLE_TIMEOUT="$new_timeout"
    [[ -n "$new_interval" ]] && CHECK_INTERVAL="$new_interval"
    [[ -n "$new_port" ]] && WORLD_PORT="$new_port"
    [[ -n "$new_listen" ]] && PROXY_LISTEN_PORT="$new_listen"
    [[ -n "$new_target" ]] && PROXY_TARGET_PORT="$new_target"

    save_config

    if [[ -f "$PROXY_SERVICE_FILE" ]]; then
        echo
        ensure_auth_port_moved
    fi

    if [[ -f "$SERVICE_FILE" ]]; then
        echo
        info "Restarting monitor service with the new settings..."
        sudo systemctl restart "$SERVICE_NAME"
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

menu() {

    while true; do

        header

        if [[ -f "$SERVICE_FILE" ]] && service_status; then
            echo -e "Monitor      ${GREEN}● RUNNING${RESET}"
        elif [[ -f "$SERVICE_FILE" ]]; then
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
        echo "  3  Status"
        echo "  4  Wake now"
        echo "  5  Configure (timeouts / ports)"
        echo
        echo "  0  Back / Exit"
        echo

        read -r -p "Select: " choice

        case "$choice" in
            1) cmd_enable ;;
            2) cmd_disable ;;
            3) cmd_status ;;
            4) cmd_wake ;;
            5) cmd_configure ;;
            0) return ;;
            *)
                error "Invalid selection."
                sleep 1
                ;;
        esac

    done
}

usage() {
    echo "Usage: $(basename "$0") [enable|disable|status|wake|configure|monitor|proxy|thaw]"
    echo
    echo "  (no argument)  interactive menu"
    echo "  enable         set up + start the idle-pause monitor and the instant-wake proxy"
    echo "  disable        stop + remove both"
    echo "  status         show monitor/proxy/server status"
    echo "  wake           unpause ac-worldserver/ac-authserver now"
    echo "  configure      change idle timeout / check interval / ports"
    echo "  monitor        run the idle-watch loop in the foreground (used by systemd)"
    echo "  proxy          run the instant-wake proxy in the foreground (used by systemd)"
    echo "  thaw           unpause quietly, no output formatting (used by the proxy)"
}

# ============================================================
# Entry point
# ============================================================

case "${1:-menu}" in
    enable)    cmd_enable ;;
    disable)   cmd_disable ;;
    status)    cmd_status ;;
    wake)      cmd_wake ;;
    configure) cmd_configure ;;
    monitor)   cmd_monitor ;;
    proxy)     cmd_proxy ;;
    thaw)      cmd_thaw ;;
    menu)      menu ;;
    -h|--help) usage ;;
    *)
        error "Unknown command: $1"
        echo
        usage
        exit 1
        ;;
esac
