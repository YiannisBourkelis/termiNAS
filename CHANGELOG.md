# Changelog

All notable changes to termiNAS will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`manage_users.sh refresh-sizes [user] [--force]`**: computes exact per-user sizes (physical via `btrfs filesystem du`, logical via a file walk) into `/var/terminas/cache/`. Users whose uploads generation and snapshot set are unchanged are skipped; each immutable snapshot's logical size is computed only once and pruned when the snapshot is deleted. Intended to run nightly from cron.
- **`manage_users.sh list-fast` and `info-fast`** (experimental): same output as `list`/`info` but read the size cache instead of walking files, so they return instantly. `list-fast` marks rows whose data changed since their sizes were computed; `info-fast` shows a per-snapshot breakdown (cached logical size, file count, and quota-accounting Referenced/Exclusive). Provided side by side with the originals for comparison.
- Incremental connection caches used by the `-fast` commands: SSH logins and Samba activity are read from journald with `--cursor-file`, so each run only reads entries added since the previous run instead of re-scanning 90 days (~13s on a busy server). SSH matching now includes `keyboard-interactive/pam` logins, which the original scan (password/publickey only) misses. The SSH query matches `SYSLOG_IDENTIFIER=sshd` / `sshd-session` (OpenSSH 9.8+) rather than `-u ssh.service` (a single indexed field instead of many match terms, ~4x faster on a large journal), and results are reused for `TERMINAS_CONNECTION_CACHE_TTL` seconds (default 900) since opening a large journal costs seconds by itself; `--refresh` forces a new read.
- Shared helpers in `common.sh`: size-cache read/write/prune functions, `build_uploads_generation_cache`, `get_tree_physical_bytes`, `get_tree_logical`, `build_qgroup_usage_cache` (one-pass qgroup parser), `bytes_to_mb`, `get_snapshot_range`, `snapshot_name_to_epoch`.

### Fixed
- Samba last-connection detection (in the `-fast` caches) no longer counts `disconnect` events as activity; the substring match for `connect` in the original implementation does.

### Notes
- Simple-quota (`squota`) accounting cannot report sizes of data written before quotas were enabled, and toggling quotas off/on resets attribution for all existing data. The `-fast` commands therefore use exact cached figures rather than qgroup numbers for sizes; qgroup data remains the basis for quota enforcement and is shown in `info-fast` for reference. The README no longer recommends toggling quotas to "refresh" accounting.
- The alpha.4 changelog entry stating that `list` was switched to a single qgroup fetch was inaccurate: `list` still runs `btrfs filesystem du` per user.

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
