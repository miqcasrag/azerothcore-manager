# AzerothCore Manager

A simple and minimal Bash toolkit for running an **AzerothCore WotLK**
server with **Playerbots** on Docker.

`ac-manager.sh` is the main script — install, configure, build, update
and manage the server from a single interface. Five optional companion
scripts add module management, idle-pausing, scheduled backups, account
management, and realmlist/network configuration. Every script is fully
independent and can be installed and used on its own.

## ac-manager.sh (main script)

- **Installation** — Automatically installs dependencies, clones the
  `Playerbot` branch and `mod-playerbots`, configures the host timezone,
  fixes permissions and performs the initial build.
- **Server control** — Start, stop, restart, check status (including a
  `SLEEPING` state when paused) and view Docker logs.
- **Build / Rebuild** — Compile the server while showing the build output
  and elapsed time.
- **Core updates** — Pulls the latest `Playerbot` branch and
  `mod-playerbots` commits, refreshes the SQL and configuration, then
  rebuilds.
- **Playerbots automation** — Auto-generates the `docker-compose.override.yml`
  needed to expose `modules/` inside `ac-worldserver` and set the host
  timezone, verifies it before every start, installs `playerbots.conf`
  disabled by default (`AiPlayerbot.Enabled = 0`), and cleans up any
  module SQL duplicated into `data/sql/custom/` to avoid `dbimport`
  failing with a "Duplicate filename" error.
- **Backups** — Create and restore backups of the Auth, Characters, and
  Playerbots databases (everything needed to restore server state --
  the World database is skipped, since it's static game content
  reproduced by `dbimport` on any fresh install), stored in a dedicated
  `backups/` folder
  outside the Docker volumes. Installation itself offers to restore an
  existing backup before the first start, with a refresh option if none
  is found yet.
- **Uninstall** — Remove just the server (database preserved for a future
  reinstall) or remove everything including the Docker volumes.
- **Safe permissions** — Uses `CORE_DIR` and verifies the repository
  location before changing ownership.

## ac-modules.sh (optional)

Installs, removes, updates, and configures optional modules —
`mod-playerbots` is listed too (status + configuration only; its
install/update lifecycle stays with `ac-manager.sh`, since it's required,
not optional).

- **Per-module menu** — Select a module by number to see its status and
  the actions it actually supports (Install / Remove / Update, plus
  Enable/Disable and Configure where applicable).
- **Enable / Disable** — For the modules that support it
  (`mod-playerbots`, `mod-autobalance`, `mod-challenge-modes`,
  `mod-individual-progression`), flips the module's own config flag and
  shows its current state (`Enabled`/`Disabled`) right in the menu.
  Installed disabled by default.
- **mod-playerbots configuration** — Apply recommended performance-tuned
  bot settings, and change the random bot count
  (`Min`/`MaxRandomBots`).
- **mod-ah-bot-plus configuration** — Creates (or reuses) a dedicated
  `ahbot`/`ahbot` account via direct SQL with a real SRP6 verifier (the
  same technique AzerothCore web account panels use). The character
  itself is never created via SQL — direct character insertion was
  tried and crashed the worldserver — so this only looks up a character
  named `Ahbot` you've created yourself with the client, then writes its
  GUID into `mod_ahbot.conf`.

## ac-sleep.sh (optional)

Puts the server to sleep when nobody's playing and wakes it up instantly
when someone tries to connect, so an idle server doesn't sit there
burning CPU/RAM for nothing.

- **Idle detection** — Checks for an established connection on its own
  proxy port (login/char-select) or a character flagged online in the
  database (in-world play), avoiding the Docker networking quirks that
  make watching TCP connections from the host unreliable.
- **Instant-wake proxy** — A transparent TCP proxy sits in front of the
  auth port; the moment a player tries to connect, the monitor unpauses
  the server within a couple of seconds, no manual action needed.
- **Self-configuring** — Auto-detects the real worldserver port from
  `.env`, moves `ac-authserver` to an internal-only port to make room for
  the proxy, and validates that the expected containers actually exist
  before enabling itself.
- **Runs as systemd services** — Survives reboots, restarts on failure.

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

## ac-account.sh (optional)

Create, inspect, and manage AzerothCore accounts and their GM security
level, without needing to attach to the worldserver console.

- **Account creation** — Direct SQL with a real SRP6 verifier, the same
  technique every AzerothCore web account panel uses.
- **GM level** — Set security level 0-4 (`SEC_PLAYER` through
  `SEC_CONSOLE`) for all realms.
- **List / info** — See every account with its GM level, or inspect one
  account's details and characters.
- **Password changes** — Update an account's password the same safe way.
- **Conservative deletion** — Refuses to delete an account that still has
  characters on it, rather than leaving orphaned characters, mail, or
  guild memberships behind.

## ac-network.sh (optional)

Views and changes the realmlist's public address and/or local address.

- **Show realmlist** — See the current `address`, `localAddress`, and
  port for every realm.
- **Independent prompts** — Change the public address, the local
  address, both, or neither — only what you ask for gets updated.
- **Client reminder** — Suggests the matching `realmlist.wtf` line to
  update on the client after applying a change.

## Supported Modules

- `mod-playerbots` (required, managed by `ac-manager.sh`)
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

The companion scripts are optional and installed the same way, in the
same folder:

```bash
chmod +x ac-modules.sh ac-sleep.sh ac-backup.sh ac-account.sh ac-network.sh
./ac-modules.sh    # module management (Playerbots + optional modules)
./ac-sleep.sh      # idle-pause monitor + instant-wake proxy
./ac-backup.sh     # scheduled automatic backups
./ac-account.sh    # account creation and GM level management
./ac-network.sh    # realmlist address configuration
```
