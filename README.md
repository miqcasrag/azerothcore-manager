# AzerothCore Manager

A simple and minimal Bash manager for running an **AzerothCore WotLK**
server with **Playerbots** on Docker.

The manager provides a single interface to install, configure, build,
update and manage the server.

## Features

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
  needed to expose `modules/` inside `ac-worldserver`, verifies it before
  every start, and cleans up any module SQL duplicated into `data/sql/custom/`
  to avoid `dbimport` failing with a "Duplicate filename" error.
- **Backups** — Create and restore backups of the Auth, Characters,
  World and Playerbots databases.
- **Safe permissions** — Uses `CORE_DIR` and verifies the repository
  location before changing ownership.

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
