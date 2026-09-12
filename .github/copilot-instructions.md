# termiNAS Project - Custom Instructions

## Project Overview

termiNAS is a secure, versioned backup server for Debian Linux that provides ransomware protection through real-time incremental snapshots. The system allows remote clients (Windows/Linux) to upload files via SFTP, with server-side automatic versioning that prevents client-side malware from corrupting or deleting backup history.

**Key Principle**: Server-side immutability - clients can upload files, but cannot modify or delete version history stored in root-owned snapshots.

## Project Goals

### Primary Objectives
1. **Ransomware Protection**: Ensure backup versions remain intact even if client machines are compromised
2. **Real-time Versioning**: Automatically snapshot file changes as they occur by polling Btrfs generation numbers (no inotify)
3. **Secure Access Control**: Strict chroot SFTP-only access with fail2ban protection
4. **Efficient Storage**: Btrfs copy-on-write snapshots share unchanged blocks between versions
5. **Easy Setup**: Automated configuration scripts for both server and clients

### Security Requirements
- Users chrooted to home directories (cannot access other parts of filesystem)
- Version snapshots owned by root (users can read but not modify)
- fail2ban protection against brute force attacks and DOS
- SSH/SFTP only (no shell access for backup users)
- 64-character secure passwords by default

### User Experience Goals
- One-command server setup (`setup.sh`)
- One-command user creation (`create_user.sh <username>`)
- Interactive client setup wizards (Linux: `setup-client.sh`, Windows: rclone guide)
- Comprehensive management tools (`manage_users.sh`: list, info, status, refresh-sizes, restore, quotas, Samba, ...)
- Clear documentation with troubleshooting guides

## Folder Structure

```
terminas/
├── LICENSE                      # MIT License
├── CONTRIBUTING.md              # Contribution guidelines with CLA
├── README.md                    # Complete project documentation
├── PROJECT_REQUIREMENTS.md      # Original requirements and scope
├── CLAUDE.md                    # Project instructions for Claude Code (keep in sync with this file)
├── .github/copilot-instructions.md  # This file - project instructions for GitHub Copilot
├── docs/                        # Technical documentation
│   ├── SNAPSHOT_MONITOR_ARCHITECTURE.md  # Server snapshot monitor design (Btrfs generation polling)
│   ├── QUOTA_ARCHITECTURE.md    # Btrfs quota system design
│   └── LINUX_CLIENT_ARCHITECTURE.md      # Linux client backup system design
└── src/
    ├── server/                  # Server-side scripts (Debian)
    │   ├── setup.sh            # Main server installation & configuration; generates the runtime scripts below
    │   ├── common.sh           # Shared helpers (quota parsing, qgroup reader, size cache, quota mode)
    │   ├── create_user.sh      # Create backup users with secure passwords
    │   ├── delete_user.sh      # Remove backup users and their data
    │   ├── manage_users.sh     # User/snapshot management (list, info, status, refresh-sizes, etc.)
    │   └── tests/              # Integration tests (run as root on a Btrfs server)
    └── client/                  # Client-side scripts
        ├── linux/               # Linux/Unix clients
        │   └── setup-client.sh # Interactive automated backup setup (creates rclone config)
        └── windows/             # Windows clients
          └── RCLONE_BACKUP_SETUP.md  # rclone-based SFTP backup guide

Server Runtime Files (created by setup.sh):
/var/terminas/scripts/
├── terminas-monitor.sh         # Snapshot monitor (Btrfs generation polling; see docs/SNAPSHOT_MONITOR_ARCHITECTURE.md)
├── terminas-cleanup.sh         # Retention policy enforcement + blocked-user quota recheck (cron 03:00)
└── common.sh                   # Copy of src/server/common.sh, sourced by both
/var/terminas/cache/            # Size cache written by manage_users.sh refresh-sizes (cron 03:30), read by list/info
/var/run/terminas/              # Monitor heartbeat and pending_<user> markers for manage_users.sh status

/etc/
├── terminas-retention.conf        # Retention policy configuration
└── systemd/system/
    └── terminas-monitor.service   # systemd service for monitoring (Restart=always)

/home/<username>/               # Per-user backup structure
├── uploads/                    # Writable upload directory (user:backupusers, 700)
└── versions/                   # Read-only snapshots (root:backupusers, 755)
    ├── YYYY-MM-DD_HH-MM-SS/   # Timestamped snapshots
    └── ...

Client Runtime Files:
Linux: /root/.config/rclone/rclone.conf, /usr/local/bin/terminas-backup/backup-<job>.sh, /var/log/terminas-<job>.log, root crontab
Windows: rclone.exe + rclone config, a Task Scheduler task running `rclone sync` (see src/client/windows/RCLONE_BACKUP_SETUP.md)
```

## Tools and Technologies

### Server-Side (Debian Linux)
- **Bash 4.x+**: All server scripts
- **OpenSSH**: SFTP with chroot configuration
- **btrfs-progs**: Subvolumes, read-only snapshots, generation polling (`btrfs subvolume list -c`, `find-new`), simple quotas
- **fail2ban**: SSH/SFTP (and Samba) brute force and DOS protection
- **nftables**: Firewall-level IP blocking (via fail2ban)
- **Samba** (optional): SMB shares and macOS Time Machine targets
- **systemd**: Service management (`terminas-monitor.service`)
- **cron**: Retention cleanup (03:00) and size-cache refresh (03:30)
- **systemd-journald**: Source of last-connection times (read incrementally with `journalctl --cursor-file`)
- **pwgen**: Secure 64-character password generation
- **getent/groupadd/useradd**: User and group management

### Client-Side
**Linux/Unix:**
- **Bash 4.x+**: `setup-client.sh` (interactive setup)
- **rclone**: SFTP transfer engine (`rclone sync` mirror semantics; `copyto` for single files)
- **cron**: Scheduled automated backups
- **logrotate**: Log management

**Windows:**
- **rclone**: SFTP transfer engine (documentation-only setup, no scripts)
- **Task Scheduler**: Automated backup scheduling

### Version Control & Collaboration
- **Git**: Source control
- **GitHub**: Repository hosting at YiannisBourkelis/terminas
- **Markdown**: Documentation format

## Official Documentation Links

Reference documentation for key technologies used in this project:

### Filesystem & Storage
- **Btrfs**: https://btrfs.readthedocs.io/ (subvolumes, snapshots, qgroups and simple quotas)
### SSH & Security
- **OpenSSH**: https://www.openssh.com/manual.html
- **SFTP Chroot Configuration**: https://man.openbsd.org/sshd_config#ChrootDirectory
- **fail2ban**: https://www.fail2ban.org/wiki/index.php/Main_Page
- **nftables**: https://wiki.nftables.org/
- **Samba**: https://www.samba.org/samba/docs/

### File Transfer & Sync
- **rclone**: https://rclone.org/docs/ (SFTP backend: https://rclone.org/sftp/)

### Scripting
- **Bash Reference Manual**: https://www.gnu.org/software/bash/manual/bash.html

## Architecture and Design Patterns

### Security Architecture
1. **Defense in Depth**:
   - Network layer: fail2ban blocks malicious IPs at nftables level
   - Authentication layer: SSH with strong passwords or keys
   - Authorization layer: Chroot prevents filesystem access outside home
   - Data layer: Root-owned snapshots prevent client modification

2. **Principle of Least Privilege**:
   - Backup users: SFTP-only, chrooted, nologin shell
   - Monitor service: Runs as root but only writes to versions directories
   - Client credentials: Stored in rclone's config with restrictive permissions (600, root-only on Linux)

### Snapshot Strategy
- **Trigger**: The uploads subvolume's Btrfs generation is newer than the newest snapshot's creation generation (polled every 10s, one `btrfs subvolume list -c /home` call for all users) AND `btrfs subvolume find-new` confirms new data extents (metadata-only changes such as atime never trigger a snapshot)
- **Timing**: snapshot after 60s without generation changes (`TERMINAS_INACTIVITY_WINDOW`), or every 30 min during continuous activity (`TERMINAS_SNAPSHOT_INTERVAL`), excluding files a process holds open for writing (found via `/proc/*/fd`)
- **Method**: writable Btrfs snapshot, in-progress files removed, `chown root:backupusers` + `chmod 755`, then read-only property set
- **Storage**: CoW snapshots share data blocks with source until modified
- **Ownership**: snapshot directory root:backupusers 755 (immutable subvolume); files inside keep their original ownership
- **Never** reintroduce recursive inotify: a user with ~500k directories exhausted the watch limit and silently killed the service (Sep 2026)

### Btrfs Quota Architecture
Per-user storage quotas use **Simple Quotas (squotas)** for reliable, high-performance enforcement.

**Why Simple Quotas?**
- Full btrfs qgroup accounting causes severe write performance issues (kernel hangs)
- Even level-0 qgroups with limits can block writes during back-reference resolution
- Simple quotas (`btrfs quota enable --simple`) avoid this by attributing all extents to the subvolume that first allocated them
- All accounting decisions are local to the allocation/freeing operation
- Reference: https://btrfs.readthedocs.io/en/latest/Qgroups.html#simple-quotas-squota

**Level-0 Qgroup (0/SUBVOL_ID)**: Direct quota on uploads subvolume
- Created automatically when subvolume is created
- Quota limit is set directly on uploads subvolume
- Stored in `/home/<username>/.terminas-qgroup`

**Hybrid Quota Check**: Total usage monitoring after each snapshot
- After each snapshot, calculates: uploads_size + all_snapshots_size
- If total > user quota limit, uploads are blocked (subvolume limit set to 1 byte)
- User can still delete files from uploads
- Quota is re-checked when:
  1. The blocked user's uploads generation changes (e.g. files deleted) - on the next monitor poll
  2. During daily retention cleanup (catches any missed cases)
- Flag file: `/home/<username>/.terminas-quota-exceeded`

**Configuration Files**:
- `.terminas-qgroup`: Uploads subvolume qgroup ID (e.g., "0/1234")
- `.terminas-quota-limit`: Configured quota limit in GB
- `.terminas-quota-exceeded`: Flag file when over total quota

**Important**: Server setup uses `btrfs quota enable --simple /home` to enable squotas mode. `setup.sh` and `manage_users.sh status` warn when `/home` is in full `qgroup` mode; `manage_users.sh migrate-squota` converts it. Simple quotas never attribute data that existed before they were enabled, so **never toggle quotas off/on to "refresh"**, and never derive size reports from qgroups: `list`/`info` read exact sizes cached by `refresh-sizes`.

### Retention Policy
**Grandfather-Father-Son (default)**:
- Daily: Keep last 7 days
- Weekly: Keep last 4 weeks (one snapshot per week)
- Monthly: Keep last 6 months (one snapshot per month)

**Simple Age-Based (alternative)**:
- Keep snapshots for N days, delete older

**Per-User Overrides**: Configurable in `/etc/terminas-retention.conf`

### Size Reporting and Health
- `manage_users.sh list`/`info` never walk files on demand: sizes come from `/var/terminas/cache/` written by `refresh-sizes` (nightly cron; unchanged users skipped via the uploads generation, immutable snapshots computed once); rows marked `*` changed since. Connection times come from journald read incrementally and reused for 15 min (`--refresh` forces a read).
- `manage_users.sh status [--quiet]` is the health check (exit 0/1/2): monitor service and poll heartbeat, changes not snapshotted within the maximum interval, quota blocks, disk usage, cron jobs, SSH/fail2ban/Samba, quota mode.

## Development Guidelines

### Code Style
**Bash Scripts**:
- Use `#!/usr/bin/env bash` shebang
- Enable strict mode: `set -euo pipefail` (except where specific handling needed)
- Use functions for modularity
- Quote all variable expansions: `"$variable"`
- Use `[[` for conditionals instead of `[`
- Validate inputs and check command exit codes
- Add descriptive comments for complex logic
- **Always validate syntax**: Run `bash -n <script>` after any modification

**Generated scripts** (`terminas-monitor.sh`, `terminas-cleanup.sh`) live inside quoted heredocs in `setup.sh` (`<<'EOF'`): write plain bash, no `\$` escaping; version placeholders `__TERMINAS_VERSION__`/`__TERMINAS_COMMIT__`/`__GENERATED_AT__` are substituted by `sed` afterwards. Both source `/var/terminas/scripts/common.sh`.

### Testing Approach
- **Always test in VM/test environment first** before production
- Test idempotency: Run setup scripts multiple times safely
- Test edge cases: Empty directories, special characters in filenames
- Test security: Attempt to bypass chroot, modify versions as user
- Test fail2ban: Verify IP banning and unbanning
- Test cross-platform: Linux and Windows clients (both rclone-based)
- Run `src/server/tests/*.sh` on a Btrfs test server after monitor or quota changes (tests poll for snapshots for up to 150s)

### Error Handling
- Scripts should fail gracefully with clear error messages
- Use colored output: Red for errors, Yellow for warnings, Green for success
- Log important operations for troubleshooting
- Validate prerequisites before making system changes
- Provide rollback instructions in documentation

### Backward Compatibility
- Maintain compatibility with:
  - Debian 12 and later (kernel 6.x Btrfs; OpenSSH 9.8+ logs as `sshd-session`, older as `sshd` - match both)
  - Any client that can run rclone (Linux, Windows, macOS)
  - Bash 4.x+ (avoid Bash 5-specific features)
- Avoid breaking changes to:
  - Directory structure (`/home/<user>/uploads`, `/home/<user>/versions`)
  - Credential file formats
  - Configuration file formats

## Common Tasks

### Adding a New Server Feature
1. Update `setup.sh` with idempotent checks (grep existing config before adding); monitor/cleanup behavior lives in the heredocs there
2. Update `create_user.sh` if per-user setup needed
3. Test on clean Debian VM, then re-run `setup.sh` on the test server (it regenerates the runtime scripts and restarts the monitor)
4. Update README.md with new feature documentation
5. Add troubleshooting section if complex

### Adding a New Client Feature
1. Review `docs/LINUX_CLIENT_ARCHITECTURE.md` for technical details and file locations
2. Update Linux client script (`setup-client.sh`) as needed
3. Update Windows documentation (`src/client/windows/RCLONE_BACKUP_SETUP.md`) for rclone-based backups
4. Test on multiple client OS versions
5. Update README.md with examples
6. Update architecture documentation if adding new files or changing behavior

### Adding a New Management Command
1. Add function to `manage_users.sh`
2. Update usage function with new command
3. Add to main case statement
4. Test with various users and edge cases
5. Document in README.md "User Management" section

### Fixing a Security Issue
1. Assess severity and impact
2. Create fix with minimal disruption
3. Test thoroughly in isolated environment
4. Update documentation with security note
5. Consider if users need to re-run setup scripts

## Known Limitations and Workarounds

### Chroot SFTP Restrictions
- **Issue**: All files in home directory must be root-owned
- **Workaround**: Only `uploads/` and `versions/` subdirectories are writable/readable by user
- **Note**: Cannot use `.bash*` files in user home (breaks chroot)

### Snapshot Latency
- **Issue**: Btrfs generations only move on transaction commits (30s by default) and the monitor polls every 10s, so a snapshot follows the last write by ~70-100s rather than ~60s
- **Trade-off**: Accepted; the cost of detection is independent of file count, which the former inotify design could not offer
- **Note**: `commit=` mount option and `TERMINAS_POLL_INTERVAL` are the levers if lower latency is ever needed

### Size Computation Cost
- **Issue**: Physical size with deduplication (`btrfs filesystem du`) walks every file in uploads and every snapshot; minutes for users with hundreds of thousands of files
- **Solution**: Computed off-peak by `refresh-sizes` and cached; never in the `list`/`info` request path

### fail2ban and Testing
- **Issue**: Testing authentication from same IP can trigger bans
- **Workaround**: Use `fail2ban-client unban --all` to clear bans
- **Production**: Consider whitelisting admin IPs in jail configuration

## Documentation Standards

### Code Documentation
- Every script must have header comment with:
  - Copyright (c) 2025 Yianni Bourkelis
  - MIT License reference
  - Brief description of purpose
  - Usage examples
- Functions must have comment describing purpose and parameters
- Complex logic blocks need explanatory comments

### README.md Structure
- Clear installation instructions (server and client)
- Usage examples with expected output
- Troubleshooting section for common issues
- Security configuration details
- Command reference tables

### Commit Messages
- Use present tense: "Add feature" not "Added feature"
- Reference issue numbers where applicable
- Be descriptive: Explain why, not just what
- Examples:
  - ✅ "Fix chroot issue by removing .bash* files from user home"
  - ❌ "Fix bug"

## Support and Community

### Getting Help
- Check README.md troubleshooting section first
- Review README.md for scope clarification
- Check GitHub Issues for similar problems
- Review fail2ban logs for connection issues

### Contributing
- All contributors must sign CLA (see CONTRIBUTING.md)
- Follow existing code style and patterns
- Add tests/verification steps in VM environment
- Update documentation with changes
- One feature per pull request

### License
- Project licensed under MIT License
- All contributions must be compatible with MIT
- Copyright notices must be maintained in all files

## Project Status and Roadmap

### Completed Features ✅
- Server setup with chroot SFTP, fail2ban (nftables) and optional Samba / Time Machine
- Snapshot monitoring by Btrfs generation polling (cost independent of file count)
- Retention policies (GFS and age-based)
- Per-user simple quotas with hybrid (uploads + snapshots) enforcement
- User management (create, delete, list, info, status, refresh-sizes, history, restore, cleanup, rebuild, quotas, Samba, change-password)
- Cached size reporting and health check with monitoring exit codes
- Linux client setup wizard and Windows guide, both rclone over SFTP
- Comprehensive documentation with troubleshooting

### Known Issues 🔧
- None currently tracked

### Future Enhancements (Not Committed) 💡
- Web interface for browsing/downloading versions
- Email notifications for backup failures
- Backup verification and integrity checks
- Remote backup replication to secondary servers
- Integration with cloud storage (S3, etc.)
- Support for other Linux distros (Ubuntu, Arch, Fedora): needs an OS abstraction for package names and service names (ssh/sshd, smbd/smb, cron/cronie)

## Critical Reminders

⚠️ **Always test in VM before production deployment**
⚠️ **Scripts modify system SSH configuration - review changes carefully**
⚠️ **Backup existing system configuration before running setup scripts**
⚠️ **fail2ban will ban IPs after failed login attempts - whitelist admin IPs**
⚠️ **Chroot SFTP requires strict directory ownership - follow documented structure**
⚠️ **Credentials are stored on disk - ensure proper file permissions**
⚠️ **Monitor disk usage - snapshots can grow large without retention cleanup**

---

*This file serves as a comprehensive guide for development, maintenance, and contributions to the termiNAS project. Keep it updated as the project evolves.*
