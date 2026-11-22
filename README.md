# AzerothCore Manager

A single-file, all-in-one Bash tool for running an **AzerothCore WotLK**
server with **Playerbots** on Docker. Everything lives in one script,
`azerothcore-manager.sh`, organized into seven sections reachable from one
menu or one command — no other files needed.

## Usage

```bash
./azerothcore-manager.sh              # interactive top-level menu (pick a section)
./azerothcore-manager.sh server       # start/stop, status/logs, backup/restore, configure
./azerothcore-manager.sh modules      # optional modules + Playerbots/AH Bot config
./azerothcore-manager.sh sleep        # idle-pause monitor + instant-wake proxy
./azerothcore-manager.sh backup       # scheduled automatic backups + rclone
./azerothcore-manager.sh account      # account creation, GM levels
./azerothcore-manager.sh network      # realmlist address configuration
./azerothcore-manager.sh setup        # install, update, rebuild, uninstall AzerothCore
```

Each section takes its own subcommands — e.g. `./azerothcore-manager.sh sleep enable`,
`./azerothcore-manager.sh backup run --quiet`,
`./azerothcore-manager.sh account create Someone`. Run
`./azerothcore-manager.sh <section> --help` to see a section's own
commands.

## 1. Server

Day-to-day control of the running server.

- **Server control** — Start, stop, restart, status (including a
  `SLEEPING` state when idle-paused), and live Docker logs. The status
  also shows on the main menu. Restart is a stop plus a full Start, so it
  picks up a new build and applies new module SQL. Start wakes a sleeping
  server first. Restore stops the worldserver/authserver during the
  restore.
- **Backups** — Create and restore (Restore lists every `.sql` in
  `backups/`, old names included) backups of the Auth, Characters, and
  Playerbots databases (the World database is skipped, since it's
  static game content reproduced by `dbimport` on any fresh install),
  saved as `azerothcore-players-<date>.sql` (older backups named
  `azerothcore-<date>.sql` are still recognized).
  Each backup also saves a **configuration archive**
  (`azerothcore-config-<date>.tar.gz`, same folder, mode 600) with the
  `.conf` files, the list of installed modules (repository, branch,
  exact commit, enabled or not), the compose override and the
  AutoSleep/AutoBackup settings. It contains secrets (database
  password, API keys): keep it private.
- **Configure** — Change the realm's name, stored in `realmlist`, and
  the **XP rates** (`Rate.XP.Kill`, `.Quest`, `.Quest.DF`, `.Explore`,
  `.Pet` in `worldserver.conf`). The screen shows notes and a table with
  each rate's current and default value; you can set all of them to one
  value, multiply them all by a factor (keeping the differences between
  them), set a single one, or reset everything to default. Applies on the
  next worldserver restart. `worldserver.conf` is created the first time
  the server starts.

## 2. Modules

Installs, removes, updates, and configures optional modules.
`mod-playerbots` is listed too (status + configuration only — it's
required, so its actual install/update stays with the Setup section).

Installing, removing or updating a module changes the server's code, so
the script runs the mandatory **rebuild automatically** right afterwards
(Playerbots SQL sync, permissions, then the Docker build). Updating
rebuilds only if some module actually received new commits, and Update
all rebuilds once at the end. The server is not started or restarted for
you — start it when the build finishes.

In the menus it asks `Rebuild now? [Y/n]` (Enter = rebuild); answer `n`
to postpone it, e.g. when installing several modules in a row, and run
**Setup > Rebuild** once at the end. From the command line, add
`--no-rebuild` to `modules install|remove|update` to skip it.

- **Per-module menu** — Pick a module by number to see its status and
  the actions it supports (Install / Remove / Update, plus Enable/Disable
  and Configure where the module has them).
- **Enable / Disable** — For modules that support it (`mod-playerbots`,
  `mod-autobalance`, `mod-challenge-modes`, `mod-individual-progression`, `mod-llm-chatter`),
  flips the module's own config flag and shows its current state right
  in the menu. Installed disabled by default.
- **Update** — Pulls each module's latest commits and rebuilds its
  `.conf` file(s) from the updated template, restoring your current
  values the same way the Setup section does for `playerbots.conf`.
  After each rebuild it lists the options the update added (kept at their
  default) and the ones it dropped, so renamed options are easy to spot.
- **Playerbots settings prefix** — mod-playerbots renamed its settings
  from `AiPlayerbot.*` to `Playerbots.*`. The script works with either: it
  detects which prefix `playerbots.conf` uses, and on **Update** it
  carries your old `AiPlayerbot.*` values over to the new `Playerbots.*`
  names automatically.
- **mod-playerbots configuration** — Individually configurable settings,
  with notes: a table shows each setting's current, default (from
  `playerbots.conf.dist`) and recommended value. Pick a number to see that
  setting's description and allowed range, then type a value (`d` =
  default, `r` = recommended). Covers `DisabledWithoutRealPlayer`,
  `DisableMoveSplinePath`, `MaxMovementSearchTime`, `AutoGearQualityLimit`,
  `RandomGearLoweringChance` and the random bot count (`MinRandomBots` /
  `MaxRandomBots`, kept consistent with each other). `r` applies the
  performance-tuned values to the five that have one, `d` resets all to
  default.
- **mod-ah-bot-plus configuration** — Creates (or reuses) a dedicated
  `ahbot`/`ahbot` account via direct SQL with a real SRP6 verifier. The
  character itself is never created via SQL — this only looks up a
  character named `Ahbot` you've created yourself with the client, then
  writes its GUID into `mod_ahbot.conf`.
- **mod-playerbots-city-life** — Populates cities and social hubs with
  bot traffic. Its world SQL lives under `data/sql/manual/` on purpose
  (not auto-imported by `dbimport`), so installing it also applies that
  SQL to the World database automatically.
- **mod-llm-chatter** — Bot chat generated by an LLM
  ([repo](https://github.com/Hokken/mod-llm-chatter)). It runs a separate
  Python "bridge" next to the server, so after cloning it offers to set
  everything up: installs Ollama with its official script (if missing),
  makes it listen on `0.0.0.0` with `OLLAMA_CONTEXT_LENGTH=4096` through a
  systemd override (Ollama has no authentication — keep port 11434 closed
  to the internet), pulls a model (default `qwen3:8b`, the size the module
  recommends), fills `mod_llm_chatter.conf` (provider `ollama`, model, URL
  `http://host.docker.internal:11434`, database host `ac-database` +
  password) and adds an `ac-llm-chatter-bridge` service to
  `docker-compose.override.yml`. It can also turn off the built-in bot
  chatter in `playerbots.conf` (which the module requires) and enable the
  module. The bridge starts with **Start / Restart** only while the module
  is enabled. Re-run the setup from the module's **Configure** entry or
  with `modules llmchatter [model]`. Removing the module also removes the
  bridge service. Note: local models need real hardware — the module's
  author warns that consumer hardware (a Raspberry Pi included) gives very
  slow replies; a cloud provider can be set in the `.conf` instead.
  Compatible with **AutoSleep**: when the server goes to sleep, the
  bridge is paused with it (no idle polling or LLM calls) and resumed on
  wake-up.

## 3. AutoSleep

Puts the server to sleep when nobody's playing and wakes it up instantly
when someone tries to connect.

- **Idle detection** — Checks for a connection on its own proxy port
  (login/char-select) or a character flagged online in the database
  (in-world play) — this sidesteps Docker networking quirks that make
  watching TCP connections from the host unreliable.
- **Instant-wake proxy** — A transparent TCP proxy in front of the auth
  port wakes the server within a couple of seconds of a connection
  attempt.
- **Scheduled wake** — Also wakes the server on its own after a
  configurable maximum sleep duration (default 7.5h), even with no
  players, so idle database connections never sit long enough to hit
  MySQL's default 8h `wait_timeout`. If nobody connects, it goes back to
  sleep after the normal idle timeout.
- **Self-configuring** — Reads the auth port from `.env`, moves `ac-authserver` to an internal-only port to make room
  for the proxy, and validates the expected containers exist before
  enabling itself. Installs `socat` automatically if missing.
- **Runs as systemd services** — `ac-manager-sleep.service` (monitor)
  and `ac-manager-sleep-proxy.service` (proxy), run as your user; they
  survive reboots and restart on failure.
- **Safe around stops/starts** — Doesn't watch a stopped server, resets
  its idle timer on Start/Restart (so a starting server isn't paused),
  and wakes the server when AutoSleep is disabled. The internal auth
  port is published on 127.0.0.1 only, so players always go through the
  proxy.

## 4. AutoBackup

Automatic, scheduled database backups, independent of the manual
backups in the Server section.

- **Scheduled backups** — Configurable interval (e.g. every 4 hours) via
  a systemd timer that fires shortly after being enabled, not tied to
  system boot time.
- **Retention** — Prunes old backups automatically, keeping only the N
  most recent.
- **Shared backup folder** — Uses the same folder as the Server
  section's manual backups, so scheduled ones show up in its restore
  menu too.
- **Remote backup (rclone)** — Optionally install rclone (via its
  official install script by default) and upload each backup to a
  cloud/remote target (`<remote>:<folder>`, default folder
  `AzerothCore-Backups`), with its own separate retention limit.
- **systemd** — `ac-manager-backup.timer` runs `ac-manager-backup.service`
  every N hours (default 4), as your user.
- **Configuration archive** — Each scheduled backup also creates, prunes
  (same retention) and uploads the `azerothcore-config-*.tar.gz` file.

## 5. Account

Create, inspect, and manage accounts and GM security levels without
attaching to the worldserver console.

- **Account creation** — Direct SQL with a real SRP6 verifier, the same
  technique AzerothCore web account panels use. Names are 1–17 letters
  or digits; passwords up to 16 characters (the client's limit).
- **GM level** — Set security level 0–4 (`SEC_PLAYER` through
  `SEC_CONSOLE`) for all realms.
- **List / info** — See every account with its GM level, or inspect one
  account's details and characters.
- **Password changes** — Update a password the same safe way.
- **Conservative deletion** — Refuses to delete an account that still
  has characters on it, rather than leaving orphaned characters, mail,
  or guild memberships behind.

## 6. Network

Views and changes the realmlist's public address and/or local address.

- **Show realmlist** — Current `address`, `localAddress`, and port for
  every realm.
- **Independent prompts** — Change the public address, the local
  address, both, or neither — only what you ask for gets updated.
- **Client reminder** — Suggests the matching `realmlist.wtf` line for
  the client after a change.

## 7. Setup

Controls the installation of AzerothCore itself, kept apart from the
server's day-to-day controls. Also reachable as
`./azerothcore-manager.sh setup [install|update|rebuild|uninstall]`.

- **Rebuild** — Compiles the server with elapsed-time tracking.
- **Update** — Brings everything up to date, in order: the core
  (`Playerbot` branch), then `mod-playerbots`, then every other
  installed module (their configs are merged the same way). Rebuilds
  `playerbots.conf` from the updated template while restoring your
  current values for every option that still exists (new options keep
  their defaults, removed ones are dropped, a `.bak` of the previous
  file is kept), and lists the options added or dropped, then rebuilds
  (only if some code changed). Declining the core update still updates
  the modules.
- **Install** — Two options:
  - **New install** — Installs dependencies, clones the `Playerbot`
    branch and `mod-playerbots`, sets the host timezone, publishes the
    database/SOAP ports on 127.0.0.1 only, fixes permissions and builds.
    Starts with an empty database.
  - **Restore from a backup** — Same install, rebuilt from a saved
    configuration and its database backup (see below). It can't be
    skipped once chosen: you pick a backup or go Back to the two options.
- **Uninstall** — Always a full removal: server files, database and
  client data. It starts with a **final backup** (database +
  configuration archive, uploaded too if remote backup is enabled); if
  that fails, it asks before going on without one. Then it reports the
  newest backup on disk and on the rclone remote (queried live) and asks
  you to type `DELETE`. It also stops and removes the
  AutoSleep/AutoBackup services. The `backups/` folder is never
  deleted.

### Restore from a backup

1. Pick where the configuration backup is:
   - **A file** — copy `azerothcore-config-<date>.tar.gz` into the
     `backups/` folder next to the script (the path is shown on screen,
     with a *Refresh* option), then pick it.
   - **The cloud (rclone)** — pick the remote folder; the archives there
     are listed, and the chosen one and its database backup are
     downloaded into `backups/`.
2. A summary shows the core and every module (enabled/disabled,
   repository, commit). Choose **exact versions** (the backup's commits)
   or **latest**, skip modules by number if you want, and confirm.
   Declining goes back to step 1.
3. It checks that the **database backup** linked to that configuration
   (`azerothcore-players-<same date>.sql`) is in `backups/`: copy it
   there and refresh, or pick another `.sql`. Without both files nothing
   is installed: the only way out is Back.
4. The install pins the core and `mod-playerbots`, clones the other
   modules, puts the saved `.conf` values over the fresh templates (new
   options keep their defaults) and re-adds the `mod-llm-chatter` bridge.
5. After the build, the database backup is restored (no skip; a failed
   import can be retried).

Ollama and its model are not reinstalled automatically: use the module's
Configure option. AutoSleep / AutoBackup settings come back, but the
services need enabling again.

## Installation

```bash
git clone https://github.com/miqcasrag/azerothcore-manager.git
cd azerothcore-manager
chmod +x azerothcore-manager.sh
./azerothcore-manager.sh
```
