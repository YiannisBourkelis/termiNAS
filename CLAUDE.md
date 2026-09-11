# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

termiNAS is a versioned backup/NAS server for Debian 12+ that provides ransomware protection through real-time, immutable Btrfs copy-on-write snapshots. Clients upload via SFTP (chrooted, no shell) or optionally Samba/Time Machine; a server-side monitor (Btrfs generation polling) snapshots each user's `uploads/` into root-owned, read-only `versions/<YYYY-MM-DD_HH-MM-SS>/` snapshots that clients can read but never modify or delete.

**Core principle: server-side immutability.** Snapshots are root-owned read-only Btrfs snapshots — even a fully compromised client cannot alter version history.

The entire project is Bash (plus Markdown docs). There is no build system, package manager, or CI. `.github/copilot-instructions.md` contains the same project conventions for GitHub Copilot — keep both files in sync when conventions change.

## Commands

```bash
# Syntax-check a script — required after ANY script modification
bash -n src/server/manage_users.sh

# Run a single test (must run as root on a Debian server with Btrfs on /home)
cd src/server/tests
sudo ./test_quota.sh              # full quota suite (creates real users/files, waits for monitor)
sudo ./test_quota.sh --cleanup-only   # every test supports --cleanup-only
sudo ./test_quota_fast.sh         # faster quota check
sudo ./test_create_user.sh        # user creation + password change (SFTP/Samba auth)
sudo ./test_delete_user_cleanup.sh
sudo ./test_uploads_quota.sh
```

Scripts target Debian and mutate real system state (users, SSH config, Btrfs subvolumes, systemd) — they **cannot run on the macOS dev machine**. Locally only `bash -n` validation is possible; functional testing happens on a Debian VM/VPS, always as root, never on production first.

## Git Workflow

- **All development happens on `dev`** (the default branch). Never commit directly to `main` — it holds tagged releases only.
- Release: update `VERSION` (single source of truth) and `CHANGELOG.md` on `dev`, optionally add `RELEASE_NOTES_v<X>.md`, commit, merge to `main`, tag `v<X>`, push both branches with `--tags`. Full steps in `RELEASE_WORKFLOW.md`.
- Commit messages: present tense ("Add feature"), explain why not just what.

## Architecture

### Repo scripts vs. generated runtime scripts (most important thing to know)

`src/server/setup.sh` does not just configure the system — it **generates the runtime scripts as embedded heredocs**:

- `/var/terminas/scripts/terminas-monitor.sh` — quoted heredoc (`<<'EOF'`) with `__TERMINAS_VERSION__`/`__TERMINAS_COMMIT__`/`__GENERATED_AT__` placeholders substituted by `sed` afterwards, so write plain bash inside it (no `\$` escaping). Both generated scripts `source /var/terminas/scripts/common.sh`, which setup.sh copies from `src/server/common.sh`.
- `/var/terminas/scripts/terminas-cleanup.sh` — quoted heredoc (`<<'EOF'`), no escaping needed.
- Also generated: fail2ban jails/filters/actions (nftables), `/etc/samba/smb.conf` (with `--samba`), `terminas-monitor.service` systemd unit, `/etc/terminas-retention.conf`, logrotate config.

**To change snapshot/monitor/quota-enforcement behavior, edit the heredocs in `setup.sh`**, then re-run `sudo ./setup.sh` on the server (it's designed to be idempotent — it greps existing config before appending; preserve that when adding features).

### Server components (`src/server/`)

- `common.sh` — shared helpers sourced by the other scripts: `validate_password` (30+ chars, mixed case + digits), `parse_quota_value`/`format_quota_display` (GB/MB/bytes parsing), `get_backup_users`, Samba/Time Machine detection.
- `create_user.sh <user> [-p pass] [--samba] [--timemachine] [--quota <GB|MB>]` — creates a chrooted SFTP-only user (nologin shell, member of `backupusers`), creates `uploads/` as a Btrfs subvolume, applies qgroup quota, writes quota metadata dotfiles.
- `delete_user.sh` — removes user, subvolumes, snapshots, Samba config, quota metadata.
- `manage_users.sh <command>` — ~20 admin commands (list, info, refresh-sizes, history, restore, cleanup, rebuild, set/show/remove-quota, enable/disable-samba[-versions], enable/disable-timemachine, change-password, force-clean, …). Adding a command = add function + update `usage()` + add case entry in the dispatch at the bottom + document in README.md.
- `list`/`info` never walk files: they read `/var/terminas/cache/` written by `refresh-sizes` (nightly cron from setup.sh; unchanged users skipped via uploads generation, immutable snapshots computed once) and incremental journald caches (`--cursor-file`, reused 15 min). Sizes must not come from qgroups: simple quotas only attribute data written after they were enabled, and toggling quotas resets that attribution.

### Data model (per user)

```
/home/<user>/                 # root-owned (chroot requirement — users cannot write here)
├── uploads/                  # Btrfs subvolume, user-writable — the only place clients write
├── versions/<timestamp>/     # root-owned read-only Btrfs snapshots of uploads/
├── .terminas-qgroup          # qgroup ID of uploads subvolume ("0/<subvol_id>")
├── .terminas-quota-limit     # configured quota (0 = unlimited)
└── .terminas-quota-exceeded  # flag file: present = uploads blocked (over total quota)
```

Chroot constraint: everything in the home directory must be root-owned or SSH refuses the chroot; never place `.bash*` files there.

### Snapshot monitor (Btrfs generation polling — no inotify)

Every `TERMINAS_POLL_INTERVAL` (10s) the monitor runs one `btrfs subvolume list -c /home` and, per user, compares the uploads subvolume's `gen` with the newest snapshot's `cgen` (creation generation). `gen > cgen` means something changed, and `btrfs subvolume find-new uploads <cgen>` then confirms real data extents were written (atime updates from directory listings, chmod, or pure deletions move the generation too but never justify a snapshot); a snapshot is taken once `gen` has been stable for `TERMINAS_INACTIVITY_WINDOW` (60s) or after `TERMINAS_SNAPSHOT_INTERVAL` (30 min) of continuous activity, excluding files some process holds open for writing (found via `/proc/*/fd`, not `lsof`). Cost is independent of file/directory count. Do not reintroduce recursive inotify: a user with ~500k directories exhausted the watch limit and silently killed the service in Sep 2026 (`docs/ARCHITECTURE_PER_USER_INOTIFY.md` has the history). Pending Btrfs deletions are now reclaimed on their own.

### Quota system (hybrid)

Uses Btrfs **simple quotas** (`btrfs quota enable --simple /home`) — never full qgroup accounting, which causes kernel-level write stalls. Two layers:

1. **Hard limit**: level-0 qgroup on the `uploads` subvolume blocks writes at the filesystem level.
2. **Hybrid total check**: after each snapshot the monitor sums uploads + all snapshots (exclusive bytes); if over the limit it sets the uploads qgroup limit to 1 byte and writes `.terminas-quota-exceeded`. Unblocked automatically when the blocked user's data changes again (deletions) or by the daily cleanup recheck.

Note: in squota mode `btrfs quota rescan` is invalid, and **never toggle quotas off/on to "refresh"** — extents that exist when squota is enabled are never attributed, so a toggle zeroes the accounting for all current data (this is why Btrfs reports the accounting as "inconsistent" on servers with pre-quota data). Details in `docs/QUOTA_ARCHITECTURE.md`.

### Retention

Daily cron (3 AM) runs `terminas-cleanup.sh`, and 03:30 runs `manage_users.sh refresh-sizes`: Grandfather-Father-Son by default (7 daily / 4 weekly / 6 monthly) or simple age-based, configured in `/etc/terminas-retention.conf` with per-user overrides (`<user>_KEEP_DAILY=…`; dashes in usernames become underscores in variable names).

### Clients (`src/client/`)

Both platforms use **rclone over SFTP** syncing to the user's `uploads/` (mirror semantics; `copyto` for single files to avoid deletions). Linux: `setup-client.sh` interactively generates an rclone remote (`/root/.config/rclone/rclone.conf`), a backup script in `/usr/local/bin/terminas-backup/`, a cron job, and logrotate config. Windows: documentation-only (`src/client/windows/RCLONE_BACKUP_SETUP.md`). Versioning is entirely server-side — clients are dumb uploaders. See `docs/LINUX_CLIENT_ARCHITECTURE.md`.

## Conventions

- Bash 4.x compatible (no Bash 5-only features). Quote all expansions, use `[[ ]]`, validate inputs, functions for modularity.
- Every script starts with a header: copyright (c) 2025 Yianni Bourkelis, MIT License reference, purpose, usage.
- Colored terminal output: red = error, yellow = warning, green = success (see existing scripts / test template in `src/server/tests/README.md`).
- New tests: `src/server/tests/test_<feature>.sh`, must support `--cleanup-only`, use `terminas_test_<feature>` as the test username, and be documented in the tests README.
- Never break: the `/home/<user>/uploads` + `versions/` directory structure, credential/config file formats, or idempotency of `setup.sh`.
- When changing behavior, update README.md and the relevant `docs/` architecture file in the same change.
