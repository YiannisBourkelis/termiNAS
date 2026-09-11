# Changelog

All notable changes to termiNAS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Snapshot monitor rewritten around Btrfs generation polling** (replaces recursive inotify). The monitor polls `btrfs subvolume list -c /home` (one call for all users) and snapshots a user when the uploads generation is newer than the newest snapshot's creation generation and has been stable for the inactivity window. Cost is independent of file and directory count: no inotify watch limits, no event floods, no kernel references delaying Btrfs space reclamation. Fixes the outage where a user with ~500k directories exhausted `max_user_watches` and the service silently stayed dead (the pipeline exited 0 so `Restart=on-failure` never fired; the unit now uses `Restart=always`). Snapshots are only taken when `btrfs subvolume find-new` confirms new data extents since the last snapshot, so metadata-only changes (atime, chmod, pure deletions) do not create empty snapshots. Also fixes the periodic-snapshot check that could never fire, replaces `lsof +D` (a full tree stat) with a `/proc/*/fd` scan, and computes quota totals with one qgroup query instead of two per snapshot. New tunable `TERMINAS_POLL_INTERVAL` (default 10s).
- **`manage_users.sh list` and `info` now read cached sizes** computed by the new `refresh-sizes [user] [--force]` command (physical via `btrfs filesystem du --raw`, logical via a file walk, stored in `/var/terminas/cache/`). Users whose uploads generation and snapshot set are unchanged are skipped; each immutable snapshot's logical size is computed only once. `list` went from many minutes to under a second; `info` shows a per-snapshot breakdown. `setup.sh` installs a nightly cron job (03:30) for `refresh-sizes`. `list-fast`/`info-fast` are accepted as aliases.
- Connection times (`Last SFTP`/`Last SMB`) are read from journald incrementally (`--cursor-file`) and reused for 15 minutes (`TERMINAS_CONNECTION_CACHE_TTL`, `--refresh` to force). The SSH query matches `SYSLOG_IDENTIFIER=sshd`/`sshd-session` (OpenSSH 9.8+) and includes `keyboard-interactive/pam` logins, which the previous scan missed.
- `setup.sh` installs `common.sh` to `/var/terminas/scripts/` for the generated monitor and cleanup scripts; the monitor is generated from a quoted heredoc with placeholder substitution (no more `\$` escaping). The cleanup script's blocked-user quota recheck uses the one-pass qgroup parser.
- Sizes in `list` are now exact bytes; the previous implementation parsed rounded GiB values (±5 MB).

### Fixed
- Samba last-connection detection no longer counts `disconnect` events as activity.
- `delete_user.sh` removes the deleted user's size cache.

### Notes
- Simple-quota (`squota`) accounting cannot report sizes of data written before quotas were enabled, and toggling quotas off/on resets attribution for all existing data. Sizes therefore come from `refresh-sizes`; qgroup data remains the basis for quota enforcement. The README no longer recommends toggling quotas to "refresh" accounting.
- The alpha.4 changelog entry stating that `list` was switched to a single qgroup fetch was inaccurate: `list` still ran `btrfs filesystem du` per user until this change.

## [1.0.0-alpha.4] - 2026-03-02

### Changed
- **Unified backup clients to use rclone**: Both Linux and Windows clients now use rclone for SFTP backups, providing consistent behavior across platforms.
- **Refactored Linux client setup**: Removed standalone `upload.sh` script and integrated rclone configuration directly into `setup-client.sh` for a streamlined single-script setup experience.
- **Simplified Windows client setup**: Replaced PowerShell scripts with rclone-based approach documented in `RCLONE_BACKUP_SETUP.md`.
- **Optimized `manage_users.sh list` performance**: Replaced parallel `btrfs filesystem du` calls with single qgroup data fetch, improving speed and accuracy of user size calculations.
- Enhanced snapshot handling with new `parse_snapshot_timestamp` function for accurate extraction of creation times from snapshot directory names.
- Refactored `get_last_backup_date` to use `get_snapshot_info` for improved consistency.

### Fixed
- Fixed year rollover handling in `build_connection_cache` and `build_samba_connection_cache` functions for accurate timestamp processing across year boundaries.
- Added notes for handling usernames with dashes in variable names in setup and manage_users scripts.

### Documentation
- Added reference documentation section to Linux Client Architecture for rclone.
- Updated Windows client documentation with comprehensive rclone setup guide.

## [1.0.0-alpha.3] - 2026-01-11


### Added
- Hybrid Btrfs simple-quota architecture with migration tooling and documentation to enforce limits across uploads and snapshots.
- `manage_users.sh change-password` command to rotate SFTP/Samba credentials with strength validation and synced updates.
- Expanded automated coverage for quotas, monitor lifecycle, and user deletion to detect regressions earlier.

### Changed
- Quota handling across setup, create_user, and manage_users now parses GB/MB limits consistently, uses referenced/exclusive bytes for accuracy, and formats output for clarity.
- Snapshot cleanup and deletion workflows improve Btrfs space reclamation (pending deletions handling, inotify exclusions) and standardize monitor/cleanup scripts under `/var/terminas` with fixed service generation.
- Documentation refreshed around simple quotas, Btrfs behavior, and retention expectations.

### Fixed
- User deletion and quota tests now handle quota rescan edge cases, stop monitor subprocesses, avoid reflink quirks, and provide clearer failure signals.
- Samba audit configuration streamlined and setup hardening expanded with additional SSH security/package checks.

## [1.0.0-alpha.2] - 2025-10-23

### Performance Improvements
- **Optimized `manage_users.sh` snapshot size calculations** (7-20x faster for users with many snapshots):
  - Replaced inefficient per-snapshot iteration with single-pass `find` processing
  - Created reusable `get_snapshots_logical_size()` function for better code maintainability
  - Significantly improved performance for `list` and `info` commands when dealing with 100+ snapshots
  - Users with 500+ snapshots now see results in 3-5 seconds instead of 60+ seconds

### Fixed
- **Fixed connection cache data extraction in `manage_users.sh`**:
  - Resolved bash subshell issue preventing `CONNECTION_CACHE` array persistence
  - Changed from pipe to process substitution to maintain parent shell context
  - "Last SFTP" column now correctly displays actual connection times instead of "Never"
  - Made awk scripts compatible with both GNU awk and mawk

### Changed
- **Improved `build_connection_cache()` performance**:
  - Replaced inefficient log parsing with optimized awk single-pass processing
  - Reduced execution time from ~8 seconds to ~1-2 seconds
  - Added epoch timestamp caching to avoid redundant `date` command invocations

## [1.0.0-alpha.1] - 2025-10-19

### Added
- Initial alpha release of termiNAS backup server

- **Core Features**:
  - Real-time incremental snapshot system using Btrfs and inotify
  - Ransomware protection via root-owned, immutable snapshot versions
  - Chroot SFTP-only access for backup users
  - fail2ban integration for SSH/SFTP brute force protection
  - Flexible retention policies (Grandfather-Father-Son or age-based)
  - Per-user configurable retention settings

- **Server Scripts**:
  - `setup.sh`: Automated server installation and configuration with optional Samba support
  - `create_user.sh`: Create backup users with secure 64-character passwords
  - `delete_user.sh`: Delete users with safety confirmation prompt
  - `manage_users.sh`: Comprehensive management tool with 17 commands:
    - User listing with disk usage, snapshot counts, and connection status
    - Detailed user info with connection activity tracking
    - Snapshot history and search capabilities
    - Inactive user detection
    - File restoration from snapshots
    - Snapshot cleanup and rebuild operations
    - Samba/SMB share management (enable/disable per user)
    - Time Machine support for macOS clients
    - Read-only SMB access to version snapshots

- **Client Support**:
  - **Linux Client**:
    - `setup-client.sh`: Interactive automated backup setup with cron scheduling
    - `upload.sh`: Manual upload with SHA-256 hash checking to skip unchanged files
    - Support for lftp (preferred) and sftp
  - **Windows Client**:
    - rclone + SFTP sync (see `src/client/windows/RCLONE_BACKUP_SETUP.md`)
    - Supports older Windows by using rclone v1.63.1 (log rotation flags not available)

- **Security Features**:
  - Chroot environment prevents filesystem traversal
  - Root-owned snapshots prevent client modification/deletion
  - fail2ban DOS and brute force protection
  - SSH key or strong password authentication (64 characters default)
  - Secure credential storage on clients (restrictive permissions)
  - Optional Samba sharing with strict security settings

- **Storage Efficiency**:
  - Btrfs Copy-on-Write (CoW) snapshots with automatic block-level deduplication for minimal disk space usage
  - Retention policies to manage snapshot growth

- **Documentation**:
  - Comprehensive README with installation, usage, and troubleshooting
  - PROJECT_REQUIREMENTS.md detailing original scope and goals
  - CONTRIBUTING.md with Contributor License Agreement
  - Inline script comments and usage help in all tools

- **Version Tracking**:
  - VERSION file in repository root (1.0.0-alpha.1)
  - All scripts read version from central VERSION file
  - `--version` flags in setup.sh and manage_users.sh
  - Version information in PowerShell script help headers

### Requirements
- Debian 12+ (Btrfs filesystem required for /home)
- OpenSSH with chroot SFTP support (strict directory ownership enforced)
- inotify-tools for real-time filesystem monitoring
- Windows clients require WinSCP for SFTP transfers
- Linux clients work best with lftp (falls back to sftp)

### Changed
- Enhanced manage_users.sh output formatting:
  - Widened columns for better readability (Size, Apparent, Protocol, Last Snapshot, Last SFTP, Last SMB)
  - Right-aligned numeric and date columns
  - Status column with proper alignment
  - Improved separator lines for clean table display

### Fixed
- Safety confirmation in delete_user.sh now requires typing exact username (prevents accidental deletions)
- Snapshot timing uses `close_write` and `moved_to` events to avoid capturing incomplete files
- Proper handling of special characters in filenames
- Correct chroot directory ownership (root:root for parent, user permissions for subdirectories)

### Security
- All backup users created with nologin shell (SFTP-only access)
- fail2ban configured for both brute force and DOS protection
- Credentials stored with 600 permissions (Linux) or Administrators-only (Windows)
- Optional Samba shares use strict security settings (no guest access by default)

### Known Limitations
- Guest/anonymous access without password not supported (all access requires authentication)
- Single server deployment only (no built-in replication to secondary servers)
- No web interface for browsing or downloading backup versions
- No email notifications for backup failures or warnings

---

## [Unreleased]

---

[1.0.0-alpha.3]: https://github.com/YiannisBourkelis/terminas/releases/tag/v1.0.0-alpha.3
[1.0.0-alpha.2]: https://github.com/YiannisBourkelis/terminas/releases/tag/v1.0.0-alpha.2
[1.0.0-alpha.1]: https://github.com/YiannisBourkelis/terminas/releases/tag/v1.0.0-alpha.1
