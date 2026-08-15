# AzerothCore Manager

A simple and minimal Bash manager for running an **AzerothCore WotLK**
server with Docker.

The manager provides a single interface to install, configure, build,
update and manage the server.

> [!IMPORTANT]
> **Portable Docker setup**
>
> This project replaces the default Docker volumes with local directories
> inside `azerothcore-wotlk/volumes/`.
>
> Database data, client data, build data and other persistent/generated
> files are therefore stored together with the server, making the complete
> installation easy to move, copy or back up.

## Features

- **Installation** — Automatically installs dependencies, clones the
  `Playerbot` branch, installs the portable Docker configuration,
  configures the host timezone and performs the initial build.
- **Server control** — Start, stop, restart, check status and view Docker
  logs.
- **Build / Rebuild** — Compile the server while showing the build output
  and elapsed time. Rebuilds never start or restart the containers.
- **Core updates** — Checks the `Playerbot` branch for new commits,
  updates AzerothCore while preserving local configuration, modules and
  persistent data, then automatically performs a rebuild.
- **Module management** — Install, remove, update and check the supported
  modules independently.
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
