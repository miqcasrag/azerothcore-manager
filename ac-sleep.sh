#!/usr/bin/env bash

set -o pipefail

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
#   ./ac-sleep.sh                 interactive menu
#   ./ac-sleep.sh enable          set everything up and start it
#   ./ac-sleep.sh disable         stop + remove everything
#   ./ac-sleep.sh status          show monitor/proxy/server status
#   ./ac-sleep.sh wake            unpause the server now
#   ./ac-sleep.sh configure       change timeouts/ports
#   ./ac-sleep.sh monitor         run the idle-watch loop (used by systemd)
#   ./ac-sleep.sh proxy           run the instant-wake proxy (used by systemd)
#   ./ac-sleep.sh thaw            unpause quietly (used by the proxy)
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE_DIR="$SCRIPT_DIR/azerothcore-wotlk"

CONFIG_FILE="$SCRIPT_DIR/.ac-sleep.conf"
STATE_FILE="$SCRIPT_DIR/.sleep-last-activity"

SERVICE_NAME="ac-manager-sleep.service"
SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME"

PROXY_SERVICE_NAME="ac-manager-sleep-proxy.service"
PROXY_SERVICE_FILE="/etc/systemd/system/$PROXY_SERVICE_NAME"

# Defaults, overridden by $CONFIG_FILE if it exists.
IDLE_TIMEOUT=300          # seconds of inactivity before pausing (5 min)
CHECK_INTERVAL=60         # how often the monitor checks (seconds)

PROXY_LISTEN_PORT=3724    # the port players actually connect to
PROXY_TARGET_PORT=3725    # internal port ac-authserver moves to, to make room for the proxy

detect_auth_port_from_env() {

    local env_file="$CORE_DIR/.env"

    [[ -f "$env_file" ]] || return

    grep -E '^DOCKER_AUTH_EXTERNAL_PORT=' "$env_file" 2>/dev/null |
        tail -n1 |
        cut -d= -f2-
}

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
    echo -e "${BOLD}AzerothCore Sleep${RESET}"
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

get_db_password() {
    compose exec -T \
        ac-database \
        printenv MYSQL_ROOT_PASSWORD \
        2>/dev/null
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

save_config() {

    cat > "$CONFIG_FILE" << EOF
IDLE_TIMEOUT=$IDLE_TIMEOUT
CHECK_INTERVAL=$CHECK_INTERVAL
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
ExecStart=$SCRIPT_DIR/ac-sleep.sh monitor
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
ExecStart=$SCRIPT_DIR/ac-sleep.sh proxy
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
        log_message "Warning: could not query online player count this cycle, assuming activity."
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

thaw_servers() {

    log_message "Player connecting - thawing server..."

    if compose unpause ac-worldserver ac-authserver 2>/dev/null; then
        log_message "Server thawed."
    else
        log_message "Failed to thaw server."
    fi

    date +%s > "$STATE_FILE"
}

cmd_monitor() {

    mkdir -p "$(dirname "$STATE_FILE")"
    [[ -f "$STATE_FILE" ]] || date +%s > "$STATE_FILE"

    log_message "Sleep monitor starting (idle timeout ${IDLE_TIMEOUT}s, checking every ${CHECK_INTERVAL}s, detecting players via DB + proxy port ${PROXY_LISTEN_PORT})."

    while true; do

        if is_paused "ac-worldserver"; then

            # Sleeping. Poll quickly (every 2s, not the full
            # CHECK_INTERVAL) for a player hitting the proxy port,
            # so wake-up feels instant instead of laggy.
            if has_proxy_connection_attempt; then
                thaw_servers
            fi

            sleep 2
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
    thaw_servers
}

cmd_proxy() {

    check_proxy_dependencies || exit 1

    log_message "Instant-wake proxy starting: 0.0.0.0:${PROXY_LISTEN_PORT} -> 127.0.0.1:${PROXY_TARGET_PORT}"

    exec socat \
        TCP4-LISTEN:"${PROXY_LISTEN_PORT}",fork,reuseaddr \
        TCP4:127.0.0.1:"${PROXY_TARGET_PORT}"
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

    info "Idle timeout       : ${IDLE_TIMEOUT}s"
    info "Check every        : ${CHECK_INTERVAL}s"
    info "Player detection   : DB query (acore_characters.characters.online) + proxy port"
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
            info "Run './ac-sleep.sh wake' to wake it up."
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

cmd_configure() {

    header

    echo "Configure Sleep Mode"
    echo "────────────────────────────────────────"
    echo

    info "Current idle timeout       : ${IDLE_TIMEOUT}s"
    info "Current check every        : ${CHECK_INTERVAL}s"
    info "Current player-facing port : ${PROXY_LISTEN_PORT}"
    info "Current ac-authserver port : ${PROXY_TARGET_PORT} (internal)"
    echo

    local new_timeout new_interval new_listen new_target

    read -r -p "New idle timeout in seconds [$IDLE_TIMEOUT]: " new_timeout
    read -r -p "New check interval in seconds [$CHECK_INTERVAL]: " new_interval
    read -r -p "New player-facing (proxy) port [$PROXY_LISTEN_PORT]: " new_listen
    read -r -p "New internal ac-authserver port [$PROXY_TARGET_PORT]: " new_target

    [[ -n "$new_timeout" ]] && IDLE_TIMEOUT="$new_timeout"
    [[ -n "$new_interval" ]] && CHECK_INTERVAL="$new_interval"
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
    echo "  thaw           unpause quietly (manual/debug use; the proxy no longer calls this itself)"
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
