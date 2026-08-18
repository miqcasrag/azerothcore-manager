# AzerothCore Manager

A simple and minimal Bash manager for running an **AzerothCore WotLK**
server with **Playerbots** on Docker.

The manager provides a single interface to install, configure, build,
update and manage the server, with two optional companion scripts for
idle-pausing and automatic backups.

## ac-manager.sh (main script)

- **Installation** — Automatically installs dependencies, clones the
  `Playerbot` branch and `mod-playerbots`, configures the host timezone,
  fixes permissions and performs the initial build.
- **Server control** — Start, stop, restart, check status and view Docker
  logs.
- **Build / Rebuild** — Compile the server while showing the build output
  and elapsed time.
- **Core updates** — Pulls the latest `Playerbot` branch and module
  commits, refreshes the SQL and configuration, then rebuilds.
- **Module management** — Install, remove and update the supported
  modules independently.
- **Playerbots automation** — Auto-generates the `docker-compose.override.yml`
  needed to expose `modules/` inside `ac-worldserver` and set the host
  timezone, verifies it before every start, and cleans up any module SQL
  duplicated into `data/sql/custom/` to avoid `dbimport` failing with a
  "Duplicate filename" error.
- **Backups** — Create and restore backups of the Auth, Characters,
  World and Playerbots databases, stored in a dedicated `backups/` folder
  outside the Docker volumes.
- **Safe permissions** — Uses `CORE_DIR` and verifies the repository
  location before changing ownership.

## ac-sleep.sh (optional)

Puts the server to sleep when nobody's playing and wakes it up instantly
when someone tries to connect, so an idle server doesn't sit there
burning CPU/RAM for nothing.

- **Idle detection** — Watches the worldserver port and pauses
  `ac-worldserver`/`ac-authserver` after a configurable timeout with no
  connections, using `docker compose pause`.
- **Instant-wake proxy** — A transparent TCP proxy sits on the auth port;
  the moment a player tries to connect, the server is unpaused
  automatically, no manual action needed.
- **Self-configuring** — Auto-detects the real worldserver port from
  `.env` and validates that the expected containers actually exist
  before enabling itself.
- **Runs as a systemd service** — Survives reboots, restarts on failure.

## ac-backup.sh (optional)

Automatic, scheduled database backups, independent of the manual backups
in `ac-manager.sh`.

- **Scheduled backups** — Configurable interval (e.g. every 4 hours) via
  a systemd timer.
- **Retention** — Automatically prunes old backups, keeping only the N
  most recent.
- **Shared backup folder** — Uses the same `backups/` folder as
  `ac-manager.sh`, so scheduled backups also show up in its restore menu.
- **Catch-up on boot** — Missed runs (server was off) are executed
  automatically the next time the machine boots.

All three scripts are fully independent — each can be installed and used
on its own.

## Supported Modules

- `mod-playerbots`
- `mod-ah-bot-plus`
- `mod-autobalance`
- `mod-challenge-modes`
- `mod-individual-progression`
- `mod-dungeon-clear`

## Installation

```bash
git clone https://github.com/miqcasrag/azerothcore-manager.git
cd azerothcore-manager
chmod +x ac-manager.sh
./ac-manager.sh
```

The companion scripts are optional and installed the same way:

```bash
chmod +x ac-sleep.sh ac-backup.sh
./ac-sleep.sh      # idle-pause monitor + instant-wake proxy
./ac-backup.sh     # scheduled automatic backups
```
