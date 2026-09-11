# termiNAS

> **⚠️ EXPERIMENTAL SOFTWARE - USE WITH CAUTION**
>
> termiNAS is currently in **experimental/alpha stage**. While it has been tested in development environments, it has not yet been extensively tested in production scenarios. Use at your own risk and **always maintain independent backups** of your critical data. The software may contain bugs, and breaking changes may occur in future releases.
>
> **Not recommended for production use without thorough testing in your specific environment.**

## Overview
termiNAS is a versioned storage server for Debian Linux using **Btrfs copy-on-write snapshots**. It functions as both a backup server (via SFTP) and a NAS (via optional SMB support), providing real-time incremental versioning for ransomware protection. Even if a client's local machine is infected, the server-side version history remains intact and unmodifiable. Users are strictly chrooted to their home directories for security.

Key features:
- **Instant Btrfs snapshots** triggered by filesystem changes (millisecond creation time).
- **Ransomware protection** via immutable read-only Btrfs snapshots (cannot be modified even by root without explicit command).
- **Strict access control**: Users cannot access anything outside their home folder.
- **Superior storage efficiency**: Block-level copy-on-write (only changed blocks consume space).
- **Terminal-based administration**: Lightweight command-line management with no GUI overhead. Benefits include:
  - Minimal resource usage (no web server or desktop environment required)
  - Remote administration via SSH from any device
  - Perfect for headless servers and low-power ARM devices
  - Script-friendly automation and integration with monitoring tools
  - Faster workflow for experienced administrators

## Use Cases

termiNAS is flexible — use it wherever you need server-side, versioned, immutable protection for files. Typical uses include:

1. Backup target for your OS or favourite backup software
   - Use SFTP to push backups from Windows, Linux or other OS backup tools (Duplicati, Veeam agents, rsync-based scripts, Borg, etc.).
   - Server-side Btrfs snapshots provide point-in-time versions without requiring special client-side behaviour.

2. macOS Time Machine target (per-user)
   - Expose a per-user Time Machine share via Samba (VFS fruit). Each macOS device can have its own user/Timemachine share for isolated backups.
   - Time Machine writes are detected by the snapshot monitor and turned into immutable Btrfs snapshots for easy restores.

3. Samba network share for file sharing
   - Use the `uploads` SMB share for day-to-day file storage and collaboration between multiple machines.
   - Administrators can optionally expose the `versions` directory as a read-only SMB share for disaster recovery (one-command enable/disable).

4. Low-power / ARM-based deployments (Raspberry Pi, small servers)
   - Run termiNAS on resource-efficient ARM hardware for home labs or remote sites; ideal when combined with USB-attached storage.
   - Keep an eye on I/O and storage (Btrfs works on ARM but performance depends on media and CPU). Use the retention settings to control disk usage.

Additional targets and audiences

- System administrators
  - Centralise backups from many hosts (servers, workstations) with consistent retention policies and audit logging.
  - Integrate with monitoring/automation (Ansible, cron) to orchestrate restores and snapshot lifecycle.

- Power users / Desktop users
  - Keep per-user version history for documents, photos and project files without changing your normal workflow — use SFTP, SMB or Time Machine as you prefer.
  - Quick restores via SFTP/WinSCP or admin-enabled SMB versions share.

- Homelab owners
  - Use termiNAS as a compact, immutable backup target for VMs, containers and services in your homelab.
  - Snapshot-based rollbacks make testing and experimenting safe — restore a known-good state quickly.

- Remote/edge backups
  - Deploy small termiNAS instances at remote sites to collect local backups and optionally replicate critical snapshots to a central server.

All of the above benefit from server-side immutable, root-owned snapshots. Clients decide how they use the share (backup target vs general file server) while termiNAS ensures version history and ransomware protection are preserved.

## ⚠️ Disclaimer

**USE AT YOUR OWN RISK**

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages or other liability, whether in an action of contract, tort or otherwise, arising from, out of or in connection with the software or the use or other dealings in the software.

**Important Notes:**
- This software modifies system configurations including SSH/SFTP settings, user accounts, and file permissions.
- Always test in a non-production environment (VM or test server) before deploying to production.
- Ensure you have proper backups of your system before running setup scripts.
- Review all scripts and understand what they do before executing them with root privileges.
- The authors are not responsible for any data loss, system damage, or security breaches.
- Security configurations should be reviewed and hardened based on your specific requirements.

## Prerequisites

### Server Requirements
- **Debian 12 (Bookworm) or later** (requires Linux 6.x kernel for stable Btrfs support)
- **Btrfs filesystem for /home** (required for snapshot functionality), ideally as its own mount point so `setup.sh` can enable `noatime` on it (reads no longer cause metadata writes; see the note under Snapshot Timing Configuration)
- Root or sudo access for setup
- OpenSSH server (installed automatically by setup script)

### Setting Up Btrfs During Debian Installation
During Debian installation, when you reach the partitioning step:
1. Select **"Manual partitioning"**
2. Create a separate partition for `/home`
3. Format it as **Btrfs** filesystem
4. Or: Use Btrfs for the entire root filesystem (simpler, works fine)

**Example partitioning scheme:**
```
/dev/sda1  →  EFI System  →  512 MB
/dev/sda2  →  ext4        →  / (root)     →  30 GB
/dev/sda3  →  Btrfs       →  /home        →  remaining space
/dev/sda4  →  swap        →  8 GB
```

**Or convert existing system:**
```bash
# WARNING: This destroys all data on /home!
# Backup first: rsync -a /home/ /backup/home/

umount /home
mkfs.btrfs /dev/sdXY
mount /dev/sdXY /home

# Update /etc/fstab:
# UUID=xxx /home btrfs defaults,compress=zstd 0 2

# Restore data: rsync -a /backup/home/ /home/
```

### Client Requirements
- Linux/Unix system (for Linux client) or Windows (for PowerShell client)
- Git (for cloning repository and updates)
- lftp or sshpass (installed automatically if needed)
- Basic knowledge of SFTP

## Installation

### Server Installation
The recommended installation location depends on your use case:

| Location | Best For | Notes |
|----------|----------|-------|
| **`/opt/terminas`** | **Production systems** | Standard location for third-party software. Root-owned, system-wide, survives user account changes. |
| `/usr/local/src/terminas` | Alternative production | Also system-wide and root-owned. Traditionally used for locally built software. |
| `~/terminas` | Testing only | User-specific, deleted with user account. Not suitable for root cron jobs or production use. |

**Recommendation:** Use `/opt/terminas` for all production client installations.

1. Clone the repository:
   ```
   git clone https://github.com/YiannisBourkelis/terminas.git
   ```
2. Navigate to the project directory:
   ```
   cd termiNAS
   ```
3. Run the setup script as root:
   ```
   sudo ./src/server/setup.sh
   ```
   This installs required packages, configures SSH/SFTP with restrictions, sets up real-time monitoring with configurable retention policies, and prepares the server.
   
   **Security Features Enabled:**
   - fail2ban protection against brute force attacks
   - SSH/SFTP authentication monitoring (5 failed attempts = 1 hour ban)
   - Samba authentication monitoring (5 failed attempts = 1 hour ban, when Samba is enabled)
   - DOS protection (10 connection attempts in 60s = 10 minute ban)
   - IP blocking at firewall level (nftables)

5. Create backup users (run as root for each user):
   ```bash
   # Create user with auto-generated 64-character password
   sudo ./src/server/create_user.sh <username>
   
   # Or provide your own password (must be 30+ chars with lowercase, uppercase, and numbers)
   sudo ./src/server/create_user.sh <username> -p "YourSecurePassword123456789012345"
   ```
   This creates a user with a secure password, sets up Btrfs subvolumes, and applies restrictions.

## Usage

### Client Upload Scripts

termiNAS includes cross-platform client scripts for easy file uploads:

#### Linux Client (`src/client/linux/setup-client.sh`)
The recommended installation location depends on your use case:

**Recommendation:** Use `/opt/terminas` for all production client installations.

Interactive setup script that configures automated rclone-based backups:
```bash
# Run the interactive setup (requires root)
sudo ./setup-client.sh
```

The setup will prompt for:
- Local path to backup
- Backup server hostname/IP
- Username and password
- Remote destination path (default: /uploads)
- Backup schedule time
- Backup job name

**What it creates:**
- An rclone remote configuration stored securely in `/root/.config/rclone/rclone.conf`
- A backup script in `/usr/local/bin/terminas-backup/backup-<jobname>.sh`
- A cron job for daily automated backups
- Logrotate configuration for log management

**Features:**
- Uses `rclone sync` for efficient directory mirroring (like rsync)
- Credentials stored securely in rclone config (not visible in process list)
- Automatic host key handling
- Mirror mode for directory uploads (uploads contents)
- Host key auto-acceptance option

#### Automated Linux Backup Setup (`src/client/linux/setup-client.sh`)

Interactive setup script that configures automated daily backups for Linux clients:

```bash
# Make it executable
chmod +x src/client/linux/setup-client.sh

# Run as root
sudo ./src/client/linux/setup-client.sh
```

**What it does:**
- Interactively prompts for backup configuration (path, server, credentials, schedule)
- Creates secure credentials file in `/root/.terminas-credentials/` (mode 600)
- Generates backup script in `/usr/local/bin/terminas-backup/`
- Configures log rotation for backup logs
- Adds cron job for automated daily backups
- Validates all settings and offers immediate test run

**Example Session:**
```
==========================================
termiNAS Client Setup
==========================================
This script will help you configure automated daily backups.

ℹ Please provide the following information:

Local path to backup (e.g., /var/backup/web1): /var/backup/web1
Backup server hostname or IP: backup.example.com
Backup username: myuser
Backup password: ****
Confirm password: ****
Remote destination path (default: /uploads): /uploads
Backup time (HH:MM, e.g., 01:00): 01:00
Backup job name (default: web1): web1-production

==========================================
Configuration Summary
==========================================
Local path:      /var/backup/web1
Backup server:   backup.example.com
Username:        myuser
Remote path:     /uploads
Backup time:     01:00 daily
Job name:        web1-production

Is this correct? (y/n): y

==========================================
Installing Backup Configuration
==========================================
✓ Created scripts directory: /usr/local/bin/terminas-backup
✓ Created secure credentials file: /root/.terminas-credentials/web1-production.conf
✓ Created backup script: /usr/local/bin/terminas-backup/backup-web1-production.sh
✓ Created log rotation config: /etc/logrotate.d/terminas-web1-production
✓ Added cron job to run daily at 01:00
✓ lftp is installed

==========================================
Setup Complete!
==========================================

✓ Backup job 'web1-production' has been configured successfully!

ℹ Configuration details:
  • Backup script:    /usr/local/bin/terminas-backup/backup-web1-production.sh
  • Credentials:      /root/.terminas-credentials/web1-production.conf
  • Log file:         /var/log/terminas-web1-production.log
  • Schedule:         Daily at 01:00

ℹ Useful commands:
  • Test backup now:      /usr/local/bin/terminas-backup/backup-web1-production.sh
  • View logs:            tail -f /var/log/terminas-web1-production.log
  • List cron jobs:       crontab -l
  • Edit cron schedule:   crontab -e

Would you like to test the backup now? (y/n):
```

**What gets created:**
```
/usr/local/bin/terminas-backup/
  └── backup-web1-production.sh        # Backup script

/root/.terminas-credentials/
  └── web1-production.conf             # Secure credentials (mode 600)

/etc/logrotate.d/
  └── terminas-web1-production            # Log rotation config

/var/log/
  └── terminas-web1-production.log        # Backup logs

Cron job:
  0 1 * * * /usr/local/bin/terminas-backup/backup-web1-production.sh
```

**Multiple backup jobs:** Run the script multiple times to configure different backup jobs (e.g., web1, database, documents). Each gets its own script, credentials, logs, and schedule.

#### Windows Client (rclone + SFTP)

Windows backups use **rclone** to sync a local folder to the server over SFTP.

- Setup guide: `src/client/windows/RCLONE_BACKUP_SETUP.md`

At a high level:

1. Download rclone from https://github.com/rclone/rclone and place `rclone.exe` in a user-protected folder.
2. Run `rclone.exe config` and create an `sftp` remote pointing to your termiNAS server (host/user/password).
3. Test a one-way mirror (local → server) with `rclone sync`.
4. Create a Windows Scheduled Task to run daily.

### Server Administration

#### User Management (`src/server/manage_users.sh`)

Comprehensive tool for managing backup users and snapshots:

**List all users with disk usage:**
```bash
sudo ./src/server/manage_users.sh list
```
Shows username, actual disk usage, apparent size (before Btrfs deduplication), snapshot count, and last backup date/time.

**Get detailed user information:**
```bash
sudo ./src/server/manage_users.sh info <username>
```
Displays:
- User ID and group membership
- Disk usage breakdown (uploads, versions, space saved via Btrfs copy-on-write)
- Snapshot statistics (oldest, newest, total count)
- Upload activity and last upload time
- Custom retention policy (if configured)

**View snapshot history:**
```bash
sudo ./src/server/manage_users.sh history <username>
```
Lists all snapshots with size and file count for a specific user.

**Search for files across all users:**
```bash
sudo ./src/server/manage_users.sh search "*.pdf"
sudo ./src/server/manage_users.sh search "invoice_*"
```
Searches through the latest snapshot of each user.

**Find inactive users:**
```bash
sudo ./src/server/manage_users.sh inactive        # Default: 30 days
sudo ./src/server/manage_users.sh inactive 60     # Custom: 60 days
```
Lists users with no uploads in the specified time period.

**Restore files from a snapshot:**
```bash
sudo ./src/server/manage_users.sh restore <username> <snapshot> <destination>
# Example:
sudo ./src/server/manage_users.sh restore produser 2025-10-01_14-30-00 /tmp/restore
```
Copies files from a specific snapshot to a local destination (with progress display).

**Cleanup old snapshots:**
```bash
# Cleanup specific user (keeps only latest snapshot)
sudo ./src/server/manage_users.sh cleanup <username>

# Cleanup all users
sudo ./src/server/manage_users.sh cleanup-all
```
Removes old Btrfs snapshots while preserving the latest snapshot.

**Rebuild snapshots from current uploads:**
```bash
# Rebuild snapshots for a specific user
sudo ./src/server/manage_users.sh rebuild <username>

# Rebuild snapshots for all users
sudo ./src/server/manage_users.sh rebuild-all
```
Deletes ALL existing snapshots and creates a fresh Btrfs snapshot from the current uploads directory. This is useful when you need to:
- Clean up snapshot history and start fresh
- Fix corrupted or inconsistent snapshots
- Reduce disk space by eliminating snapshot history

**Features:**
- Automatically skips users with files currently open (warns and continues)
- Verifies file integrity after creating the new snapshot
- Compares file count and sizes between uploads and snapshot
- Provides detailed progress output and summary statistics

**Example output:**
```
==========================================
Rebuilding snapshots for user: testuser
==========================================
✓ No open files detected
Files to snapshot: 1247
Deleting 3 existing snapshot(s)...
  ✓ Deleted: 2025-10-08_14-30-00
  ✓ Deleted: 2025-10-09_08-15-22
  ✓ Deleted: 2025-10-09_12-45-10
Deleted 3 snapshot(s)
Creating fresh snapshot from uploads directory...
✓ Btrfs snapshot created: 2025-10-09_15-30-45
✓ Snapshot set to read-only
Verifying file integrity...
✓ File count matches: 1247 files
✓ All 1247 files verified successfully
✓ Snapshot rebuild completed successfully for user 'testuser'
```

**Delete a user:**
```bash
sudo ./src/server/manage_users.sh delete <username>
```
Removes the user account and all their data (requires confirmation).

**Change password for a user:**
```bash
sudo ./src/server/manage_users.sh change-password <username>
```
Changes the password for an existing backup user. Updates authentication for:
- SFTP connections (always)
- Samba (SMB) shares (if enabled)
- Time Machine backups (uses Samba password)

**Features:**
- Interactive password prompts with confirmation
- Validates password strength (30+ characters, mixed case, numbers)
- Automatically detects which services are enabled
- Atomic updates - rollback warnings if partial failure

**Example session:**
```
=========================================
Change Password for: produser
=========================================

Services enabled: SFTP, Samba (SMB)

Enter new password (30+ chars, must contain lowercase, uppercase, and numbers): ********
Confirm new password: ********

Updating password...
✓ SFTP password updated
✓ Samba password updated

=========================================
✓ Password changed successfully
=========================================

The new password is now active for:
  - SFTP connections
  - Samba (SMB) shares
  - Time Machine backups
```

**Enable/Disable Samba for existing users:**
```bash
# Enable Samba (SMB) sharing
sudo ./src/server/manage_users.sh enable-samba <username>

# Disable Samba (SMB) sharing
sudo ./src/server/manage_users.sh disable-samba <username>
```
Enables or disables SMB/Samba access for an existing user. When enabled, creates the `username-backup` share for the uploads directory.

**Enable/Disable read-only SMB access to versions (snapshots):**
```bash
# Enable read-only access to snapshots via SMB (for disaster recovery)
sudo ./src/server/manage_users.sh enable-samba-versions <username>

# Disable read-only access
sudo ./src/server/manage_users.sh disable-samba-versions <username>
```

**Important Notes:**
- By default, only the `uploads` directory is shared via SMB for security
- The `versions` directory is NOT exposed via SMB by default
- Use `enable-samba-versions` when disaster recovery is needed (e.g., after ransomware attack)
- This creates a separate read-only SMB share: `\\server\username-versions`
- Snapshots remain immutable and root-owned (cannot be modified via SMB)
- All access is logged via VFS audit for security monitoring
- Requires Samba to be enabled for the user first (`enable-samba`)

**Disaster Recovery Workflow:**
1. User reports ransomware - `uploads` directory is encrypted
2. Admin enables versions access: `enable-samba-versions username`
3. User connects via `\\server\username-versions` in Windows Explorer
4. User browses timestamped snapshots and restores needed files
5. After recovery, admin disables access: `disable-samba-versions username`

**Manage storage quotas:**
```bash
# Set quota for user (in GB)
sudo ./src/server/manage_users.sh set-quota <username> <GB>

# Example: Set 100GB quota
sudo ./src/server/manage_users.sh set-quota produser 100

# Show quota status
sudo ./src/server/manage_users.sh show-quota <username>

# Remove quota (unlimited storage)
sudo ./src/server/manage_users.sh remove-quota <username>
```

Quota management controls physical disk usage (uploads + all snapshots with Btrfs deduplication). See [Storage Quota Management](#storage-quota-management) section for details.

**Inspect and force Btrfs cleanup:**
```bash
# Show pending deleted subvolumes (diagnostic)
sudo ./src/server/manage_users.sh show-pending-deletions

# Force cleanup (restart monitor + filesystem sync)
sudo ./src/server/manage_users.sh force-clean
```

**Understanding Pending Deletions:**

After deleting users or snapshots, `btrfs subvolume list -d` may briefly show "DELETED" entries
while the Btrfs cleaner reclaims the space asynchronously. This is normal.

Earlier versions of the monitor used recursive inotify watches, which held kernel references
to deleted directories and delayed reclamation until the service restarted. The current
monitor polls Btrfs generation numbers and holds no such references, so space is reclaimed
by the kernel cleaner on its own. `force-clean` remains available to restart the monitor and
force a filesystem sync if you want to confirm reclamation immediately.

**Example:**
```bash
$ sudo ./src/server/manage_users.sh show-pending-deletions
Pending Btrfs deletions under /home: 3

$ sudo ./src/server/manage_users.sh force-clean
Pending deletions before: 3
Restarting monitor service...
✓ Monitor service restarted
Committing filesystem metadata...
✓ Filesystem sync complete
Pending deletions after: 0

✓ Cleanup complete (non-blocking - kernel cleaner will reclaim space)
```

**Size cache (`refresh-sizes`):**
```bash
sudo ./src/server/manage_users.sh refresh-sizes            # all users, skips unchanged ones
sudo ./src/server/manage_users.sh refresh-sizes <username> # one user
sudo ./src/server/manage_users.sh refresh-sizes --force    # recompute everything
sudo ./src/server/manage_users.sh list --refresh           # force a fresh journal read for connection times
```

`list` and `info` read sizes from a cache in `/var/terminas/cache/` instead of walking every
file on each invocation (which took minutes on servers with large directory trees).
`setup.sh` installs a nightly cron job (03:30) that runs `refresh-sizes`; run it manually after
installing or upgrading, or whenever you want fresh figures.

- Physical usage (`btrfs filesystem du`) and the logical size of `uploads/` are recomputed only
  for users whose data changed (detected via the Btrfs generation of the uploads subvolume and
  the set of snapshots), so the nightly run is cheap.
- Each snapshot's logical size is computed **once**, because snapshots are immutable, and
  dropped when the snapshot is deleted.
- `list` marks a row with `*` when the user's data changed since its sizes were computed, and
  shows `n/a` for users with no cached size yet.
- Connection times come from incremental journal reads (`journalctl --cursor-file`) and are
  reused for 15 minutes (`TERMINAS_CONNECTION_CACHE_TTL` seconds to change); `--refresh`
  forces a fresh read.
- Simple-quota accounting (`show-quota`, and the Referenced/Exclusive columns in `info`) only
  covers data written after quotas were enabled, and Btrfs reports it as "inconsistent" when
  older data exists. **Do not toggle quotas off and on to "refresh"** - that resets attribution
  for all current data.

#### macOS Time Machine Support

termiNAS supports macOS Time Machine backups via Samba with automatic versioning using Btrfs snapshots.

**Server Setup:**

1. **Enable Samba during initial setup:**
```bash
sudo ./src/server/setup.sh --samba
```

2. **Create user with Time Machine support:**
```bash
# Option A: Create new user with Time Machine enabled
sudo ./src/server/create_user.sh username --samba --timemachine

# Option B: Enable Time Machine for existing user
sudo ./src/server/manage_users.sh enable-samba username
sudo ./src/server/manage_users.sh enable-timemachine username
```

**macOS Client Setup:**

1. **Connect to the share in Finder first:**
   - Open **Finder** → **Go** → **Connect to Server** (or press `Command+K`)
   - Enter: `smb://<server-ip>/username-timemachine`
     - Replace `<server-ip>` with your server's IP address or hostname
     - Replace `username` with your actual username
   - Click **Connect**
   - Enter credentials:
     - **Username**: `username`
     - **Password**: Your Samba password
   - The share will mount in Finder

2. **Configure Time Machine:**
   - Open **System Preferences** (or **System Settings** on newer macOS)
   - Go to **Time Machine**
   - Click **"+"** (Add Disk) or **"Select Disk"**
   - Select `username-timemachine` from the list
   - If prompted for credentials again, enter the same username/password
   - Time Machine will start backing up automatically

**How It Works:**
- Time Machine writes backups to the `uploads` directory via Samba
- termiNAS's monitoring service detects file changes automatically
- Btrfs snapshots are created in real-time as Time Machine saves files
- All snapshots are stored in the `versions` directory (root-owned, immutable)
- Retention policies apply to Time Machine snapshots automatically
- You can restore from any snapshot using `manage_users.sh restore`

**Disable Time Machine:**
```bash
sudo ./src/server/manage_users.sh disable-timemachine username
```

**Important Notes:**
- Time Machine requires Samba to be enabled (`--samba` flag during setup)
- Uses VFS fruit module for full macOS compatibility
- Snapshots are created automatically - no manual intervention needed
- Time Machine backups coexist with regular SFTP uploads in the same directory
- All Time Machine files are subject to the same Btrfs snapshot versioning
- To browse snapshots, enable read-only SMB access: `enable-samba-versions username`

**Troubleshooting:**
- If Time Machine doesn't see the share, make sure you connected via Finder first
- Check that the user has Time Machine enabled: `./manage_users.sh list`
  - Should show: `SMBTM+SFTP` or `SMB*TM+SFTP` in the Protocol column
- Verify Samba is running: `sudo systemctl status smbd`
- Check Samba config: `sudo testparm -s | grep -A 10 "username-timemachine"`

#### Retention Policy Configuration

Edit `/etc/terminas-retention.conf` to customize snapshot retention:

**Advanced Retention (Default - Grandfather-Father-Son):**
```bash
ENABLE_ADVANCED_RETENTION=true
KEEP_DAILY=7        # Keep last 7 daily snapshots
KEEP_WEEKLY=4       # Keep last 4 weekly snapshots (one per week)
KEEP_MONTHLY=6      # Keep last 6 monthly snapshots (one per month)
```

**Simple Age-Based Retention:**
```bash
ENABLE_ADVANCED_RETENTION=false
RETENTION_DAYS=30   # Delete snapshots older than 30 days
```

**Per-User Overrides:**
```bash
# Production user: extended retention
produser_KEEP_DAILY=30
produser_KEEP_WEEKLY=12
produser_KEEP_MONTHLY=24

# Test user: minimal retention
testuser_ENABLE_ADVANCED_RETENTION=false
testuser_RETENTION_DAYS=7
```

> **Note:** For usernames containing dashes (e.g., `backup-server`), replace dashes with underscores in the variable name (e.g., `backup_server_KEEP_DAILY=14`).

The cleanup script runs daily at 3:00 AM (configurable via `CLEANUP_HOUR` in the config file).

**Manual cleanup:**
```bash
sudo /var/terminas/scripts/terminas-cleanup.sh
```

#### Storage Quota Management

termiNAS supports per-user storage quotas using Btrfs qgroups to track physical disk usage across uploads and all snapshots. Quotas are **unlimited by default**.

**Create user with quota:**
```bash
# Create user with 100GB quota
sudo ./src/server/create_user.sh testuser --quota 100

# Create user with unlimited storage (default)
sudo ./src/server/create_user.sh testuser
```

**Manage quotas for existing users:**
```bash
# Set 50GB quota for user
sudo ./src/server/manage_users.sh set-quota testuser 50

# Show quota status
sudo ./src/server/manage_users.sh show-quota testuser

# Remove quota (unlimited)
sudo ./src/server/manage_users.sh remove-quota testuser

# View quota in user info
sudo ./src/server/manage_users.sh info testuser
```

**Configure default quota for new users:**

Edit `/etc/terminas-retention.conf`:
```bash
# Default quota for new users (GB, 0 = unlimited)
DEFAULT_QUOTA_GB=0

# Per-user quota overrides (GB)
testuser_QUOTA_GB=50
produser_QUOTA_GB=500

# Quota warning threshold (%)
QUOTA_WARN_THRESHOLD=90
```

> **Note:** For usernames containing dashes (e.g., `backup-server`), replace dashes with underscores in the variable name (e.g., `backup_server_QUOTA_GB=100`).

**How quota enforcement works:**

1. **Tracks physical disk usage** - Measures actual space used on disk (deduplicated via Btrfs CoW)
2. **Includes uploads + all snapshots** - Total storage for user across all versions
3. **Blocks snapshots when exceeded** - Monitor service prevents new snapshots if quota is full
4. **Warns at 90% usage** - Logged to `/var/log/terminas.log` when threshold reached
5. **Works for all protocols** - Enforced for SFTP, Samba, and Time Machine uploads

**Example quota output:**
```bash
$ sudo ./src/server/manage_users.sh show-quota produser

==========================================
Quota Status for: produser
==========================================

Quota limit: 100.00GB
Current usage: 87.34GB (87.3% used, 12.66GB available)

⚠ WARNING: Storage usage is above 90%

Qgroup: 1/258
```

**Monitor quota in logs:**
```bash
# View quota warnings and errors
sudo tail -f /var/log/terminas.log | grep -i quota

# Example log output:
# 2025-11-12 14:30:15 WARNING: User produser approaching quota limit (92.1GB / 100.0GB, 92.1%)
# 2025-11-12 15:45:22 ERROR: User produser is over quota (100.2GB / 100.0GB)
# 2025-11-12 15:45:22 Snapshot creation blocked - user must free up space
```

**What happens when quota is exceeded:**

- ❌ **File uploads are blocked** - All write operations fail at filesystem level
- ❌ **No new snapshots created** until space is freed
- 📝 All quota events logged to `/var/log/terminas.log`
- 🔄 Automatic recovery when space becomes available
- ⚠️ Warning logged at 90% threshold

**How quota enforcement works:**

Btrfs enforces quotas at the **filesystem level** for all protocols automatically:

- **SFTP uploads**: Write fails with "Disk quota exceeded" error
- **Samba uploads**: Write fails with "No space left on device" error
- **Time Machine**: Backup fails with disk full error
- **Snapshots**: Monitor script blocks snapshot creation when over quota

No per-protocol checks needed - Btrfs handles everything uniformly.

**Free up space:**
```bash
# Remove old snapshots (keeps only latest)
sudo ./src/server/manage_users.sh cleanup testuser

# Or adjust retention policy for user
# Edit /etc/terminas-retention.conf:
testuser_KEEP_DAILY=3
testuser_KEEP_WEEKLY=2

# Run cleanup manually (applies retention policy)
sudo /var/terminas/scripts/terminas-cleanup.sh
```

**Quota best practices:**

1. **Set realistic limits** based on expected data growth
2. **Monitor usage regularly** with `show-quota` command
3. **Configure retention policies** to match quota limits
4. **Test quota enforcement** before deploying to production
5. **Alert on 90% threshold** using log monitoring tools

**Technical details:**

- Uses Btrfs qgroups (level 0) on user's home directory subvolume
- Tracks ALL user data: uploads + all snapshots (versions)
- Uses **excl** (exclusive bytes) = actual physical disk usage
- Accounts for Btrfs Copy-on-Write (CoW) deduplication automatically
- Quota enforced at filesystem level - blocks writes when exceeded
- Quota checked before each snapshot creation for logging/warnings

#### Monitoring

**Health check (one command):**
```bash
sudo ./src/server/manage_users.sh status
```
Reports the monitor service and its poll heartbeat, users whose changes have not been
snapshotted within the maximum interval, the last snapshot and the count in the last 24h,
quota-blocked users, `/home` usage, whether the nightly cron jobs exist and ran, SSH/fail2ban/
Samba state, and Btrfs housekeeping. The exit code follows the monitoring convention
(0 = OK, 1 = WARNING, 2 = CRITICAL), and `--quiet` prints only problems, so cron mails you
only when something needs attention:
```bash
# /etc/cron.d/terminas-health (cron mails any output to MAILTO)
MAILTO=admin@example.com
*/10 * * * * root /opt/terminas/src/server/manage_users.sh status --quiet
```
Thresholds: `/home` usage warns at 80% and is critical at 95% (`TERMINAS_DISK_WARN_PCT`,
`TERMINAS_DISK_CRIT_PCT`); changes are critical when not captured within the snapshot
interval plus the inactivity window.

**View backup activity logs:**
```bash
sudo tail -f /var/log/terminas.log
```

**Check monitor service status:**
```bash
sudo systemctl status terminas-monitor.service
```

**Restart monitor service:**
```bash
sudo systemctl restart terminas-monitor.service
```

#### Security Monitoring (fail2ban)

**Check fail2ban status:**
```bash
sudo systemctl status fail2ban
```

**View currently banned IPs:**
```bash
sudo fail2ban-client status sshd
sudo fail2ban-client status sshd-ddos
```

**View ban statistics and history:**
```bash
# Show all banned IPs across all jails
sudo fail2ban-client banned

# View detailed jail statistics
sudo fail2ban-client status

# Check fail2ban logs
sudo tail -f /var/log/fail2ban.log

# Count banned IPs today
sudo grep "$(date +%Y-%m-%d)" /var/log/fail2ban.log | grep "Ban" | wc -l
```

**Manually unban an IP (if needed):**
```bash
sudo fail2ban-client set sshd unbanip <IP_ADDRESS>
sudo fail2ban-client set sshd-ddos unbanip <IP_ADDRESS>
```

**View recent failed SSH/SFTP authentication attempts:**
```bash
# On systems using systemd journal (Debian 12+, modern Linux distributions)
sudo journalctl -u ssh -u sshd --since "1 hour ago" | grep "Failed\|Invalid" | tail -20
sudo journalctl -u ssh -u sshd --since "today" | grep "Failed password" | tail -20

# On systems with traditional syslog (older Debian versions, check if /var/log/auth.log has content)
sudo grep "Failed password" /var/log/auth.log | tail -20
sudo grep "Connection closed by authenticating user" /var/log/auth.log | tail -20
```

**View recent failed Samba authentication attempts:**
```bash
# Samba authentication failures are logged to separate log files
# Find which log files contain authentication failures
sudo find /var/log/samba/ -name "log.*" -exec grep -l "check_ntlm_password.*FAILED\|NT_STATUS_WRONG_PASSWORD\|NT_STATUS_LOGON_FAILURE" {} \;

# View recent failures from all Samba log files
sudo find /var/log/samba/ -name "log.*" -exec grep "check_ntlm_password.*FAILED with error NT_STATUS\|status \[NT_STATUS" {} \; | tail -10

# Monitor all Samba logs for new authentication failures (real-time)
sudo tail -f /var/log/samba/log.* 2>/dev/null | grep --line-buffered "check_ntlm_password.*FAILED with error NT_STATUS\|status \[NT_STATUS"

# More generic monitoring for any Samba failures or errors
sudo tail -f /var/log/samba/log.* 2>/dev/null | grep --line-buffered "FAILED\|NT_STATUS"
```

**Security configuration details:**
- **Authentication failures**: 5 failed attempts within 10 minutes = 1 hour IP ban
- **DOS protection**: 10 connection attempts within 60 seconds = 10 minute IP ban
- **Scope**: Protects both SSH and SFTP (same authentication layer)
- **Action**: Complete IP block at firewall level (iptables)

### For End Users (SFTP Access)

- **Upload files**: Use SFTP to connect and upload to the `uploads` directory:
  ```bash
  sftp username@server
  cd uploads
  put file.txt
  put -r directory/
  ```

- **Download snapshots**: Access the `versions` directory to browse and download snapshots:
  ```bash
  sftp username@server
  cd versions
  ls                                    # List all snapshots
  cd 2025-10-01_14-30-00                # Enter specific snapshot
  get -r . /local/restore/path          # Download entire snapshot
  ```

- **Snapshots**: Created automatically on any file changes (add, modify, delete, move). Each snapshot is timestamped in `YYYY-MM-DD_HH-MM-SS` format.

### Disaster Recovery: Accessing Backups After Ransomware Attack

**Critical Scenario**: Your Windows machine is infected with ransomware, the `uploads` directory (SMB share) is encrypted, but your read-only `versions` snapshots remain intact. Here's how to restore your data:

#### ✅ Method 1: SFTP Access (Recommended - Works Always)

Even if SMB/Samba is compromised, SFTP access to versions always works because it uses a different protocol:

**Using WinSCP (Windows GUI - Easiest):**
1. Download and install WinSCP: https://winscp.net/
2. Connect via SFTP to your backup server
3. Navigate to the `/versions/` directory (read-only snapshots)
4. Browse timestamped snapshots (e.g., `2025-10-14_12-47-05`)
5. Right-click → Download to restore files to your Windows machine

**Using Command Line SFTP:**
```bash
# Connect via SFTP
sftp username@backup-server

# List available snapshots
cd versions
ls

# Enter the most recent snapshot
cd 2025-10-14_12-47-05

# Download specific files
get important-file.docx

# Download entire snapshot recursively
get -r . C:\Restored\
```

**Why SFTP Always Works:**
- ✅ Uses SSH protocol (port 22) - independent of SMB/Samba
- ✅ Snapshots are read-only and owned by root - ransomware cannot modify them
- ✅ Chrooted access means user can browse their own versions directory
- ✅ Works even if Samba service is stopped or compromised

#### ✅ Method 2: SMB Access to Versions (Admin-Enabled)

**Security by Default**: The `versions` directory is NOT shared via SMB by default to minimize attack surface. However, for disaster recovery, an administrator can enable read-only SMB access with a single command.

**Quick Enable (Recommended for Disaster Recovery):**

```bash
# Server administrator runs:
sudo ./manage_users.sh enable-samba-versions username
```

**Output:**
```
==========================================
✓ Read-only SMB access to versions enabled
==========================================

Share details:
  Share name: //backup-server/username-versions
  Path: /home/username/versions
  Access: Read-only
  User: username

Windows access:
  \\backup-server\username-versions

Security notes:
  • Snapshots are read-only and cannot be modified
  • All access is logged via VFS audit
  • SMB3 encryption is enforced
  • Only user 'username' can access this share
```

**Then from Windows:**
```
1. Open Windows Explorer
2. Navigate to: \\backup-server\username-versions
3. Browse timestamped snapshots (e.g., 2025-10-14_12-47-05)
4. Copy needed files to local machine
```

**After Recovery:**
```bash
# Disable SMB access to versions for security
sudo ./manage_users.sh disable-samba-versions username
```

**Why This Approach Is Better:**
- ✅ Secure by default (versions not exposed unless needed)
- ✅ One-command enable/disable by administrator
- ✅ Read-only access (snapshots remain immutable)
- ✅ All access is logged for audit trail
- ✅ Easy for Windows users (no WinSCP needed)
- ✅ Can be toggled per user as needed

#### 🔧 Method 3: Server-Side Restore (Admin Assistance)

If you cannot access the server remotely, contact your system administrator to use the `manage_users.sh` restore command:

```bash
# Server admin runs:
sudo ./manage_users.sh restore username 2025-10-14_12-47-05 /tmp/restore

# Then admin can:
# 1. ZIP the restored files: tar -czf restore.tar.gz /tmp/restore
# 2. Transfer via secure method (SFTP, USB, etc.)
```

#### 📋 Best Practices for Disaster Recovery Preparation

1. **Test SFTP access before disaster strikes**:
   - Ensure you have WinSCP installed on recovery media or another machine
   - Document your backup server hostname/IP and credentials
   - Practice browsing the versions directory via SFTP

2. **Keep credentials secure but accessible**:
   - Store backup credentials in a password manager
   - Keep a printed copy in a secure physical location
   - Don't store credentials only on the machine being backed up!

3. **Regular restore drills**:
   - Periodically test downloading files from versions via SFTP
   - Verify you can access versions from a different machine
   - Confirm snapshots contain expected data

4. **Document your backup server details**:
   - Server hostname or IP address
   - Your backup username
   - SFTP port (usually 22)
   - Location of latest snapshot (check via `manage_users.sh info username`)

5. **Alternative access methods**:
   - If your main network is compromised, consider:
     * VPN access to backup server network
     * Out-of-band management (iLO, IPMI, etc.)
     * Physical console access to backup server

#### 🛡️ Why This Protection Works

- **Read-only snapshots**: Btrfs snapshots are immutable - even root cannot modify them without explicit commands
- **Root ownership**: Snapshots are owned by root, not by the backup user
- **Separate protocol**: SFTP doesn't depend on SMB/Samba - if one is compromised, the other still works
- **Chroot isolation**: Users can only access their own data, preventing lateral movement
- **Timestamped history**: Multiple snapshots mean you can choose a known-good restore point before infection

**The golden rule**: **Always test disaster recovery before you need it!**

## Configuration Options

### Server Configuration

#### Snapshot Timing Configuration

The monitor detects changes by polling Btrfs generation numbers (one `btrfs subvolume list` call for all users every 10 seconds; detection latency is that interval plus the Btrfs commit interval, 30 s by default). A generation change alone is not enough: `btrfs subvolume find-new` must also report new data extents, so directory listings (atime), permission changes or pure deletions never produce empty snapshots. Mounting `/home` with `noatime` (recommended anyway) avoids the metadata churn entirely. The monitor uses **smart periodic snapshots** that exclude in-progress files:

**How it works:**
1. **Immediate snapshot when all files complete**: No waiting - snapshot taken 60s after last file closes
2. **Periodic snapshots while uploading**: Takes snapshot every 30 minutes (default) if files are still open
3. **Excludes in-progress files**: Only completed (closed) files are included in periodic snapshots
4. **Efficient snapshot management**: Prevents excessive snapshot creation from frequent small file changes

**Example scenarios:**

**Scenario 1: Quick upload (all files complete quickly)**
```
03:00:00 - Start uploading: file1.sql (10 MB) + file2.sql (50 MB)
03:00:15 - Both files complete (all closed)
03:01:15 - Immediate snapshot: includes BOTH files (60-second wait completed!)
```

**Scenario 2: Mixed upload (small + large files)**
```
03:00:00 - Start uploading: small.sql (10 MB) + huge.tar.gz (500 GB)
03:00:30 - small.sql completes (closed)
03:00:30 - huge.tar.gz still uploading (in progress...)
03:30:30 - Periodic snapshot #1: includes small.sql, EXCLUDES huge.tar.gz (still open)
04:00:30 - Periodic snapshot #2: includes small.sql, EXCLUDES huge.tar.gz (still open)
04:15:00 - huge.tar.gz completes (all files closed)
04:15:30 - Final snapshot: includes BOTH small.sql + huge.tar.gz (immediate!)
```

**Configuration** (edit `/etc/systemd/system/terminas-monitor.service`):

```bash
sudo nano /etc/systemd/system/terminas-monitor.service

# Add to [Service] section:
Environment="TERMINAS_POLL_INTERVAL=10"        # Check Btrfs generations every 10s (default)
Environment="TERMINAS_INACTIVITY_WINDOW=60"    # Wait for 60s of inactivity before snapshot (default)
Environment="TERMINAS_SNAPSHOT_INTERVAL=1800"  # Max wait time: force snapshot after 30 min (default)
```

**Behavior Summary:**

| Scenario | Snapshot Timing | Notes |
|----------|----------------|-------|
| **Single file upload** | 60 seconds after upload completes | One snapshot per batch |
| **Multiple files (batch)** | 60 seconds after LAST file completes | One snapshot for entire batch! |
| **Files still uploading** | Every 30 minutes (default) | Periodic snapshots exclude in-progress files |
| **Large ongoing upload** | 60 seconds after large file finishes | Final snapshot includes everything |

**Recommended intervals:**

| Upload Pattern | INACTIVITY_WINDOW | SNAPSHOT_INTERVAL | Notes |
|----------------|-------------------|-------------------|-------|
| Frequent small files | 30 seconds | 300 (5 min) | Quick snapshots after activity stops |
| **Mixed sizes (default)** | **60 seconds** | **1800 (30 min)** | **Balanced - recommended** |
| Few large files | 120 seconds | 3600 (60 min) | Wait longer to group uploads |
| Continuous uploads | 180 seconds | 7200 (2 hours) | Minimize snapshot count |

After changes:
```bash
sudo systemctl daemon-reload
sudo systemctl restart terminas-monitor.service
```

**Benefits:**
- ✅ **One snapshot per upload batch** (not one per file!)
- ✅ Automatically waits for inactivity before creating snapshot
- ✅ Multiple files uploaded together → single snapshot
- ✅ Periodic snapshots for very long uploads
- ✅ Fewer snapshots = easier version management

#### Optimizing for Very Large Files (100+ GB)

**1. Increase Btrfs commit interval** (reduce metadata overhead):
```bash
# Add to /etc/fstab mount options:
UUID=xxx /home btrfs defaults,compress=zstd,commit=120 0 2

# Remount:
sudo mount -o remount,commit=120 /home
```

**2. Disable atime updates** (faster file operations):
```bash
# Add to /etc/fstab:
UUID=xxx /home btrfs defaults,compress=zstd,noatime 0 2

sudo mount -o remount,noatime /home
```

**3. Increase disk cache** (better for large sequential writes):
```bash
# Add to /etc/sysctl.conf:
vm.dirty_ratio = 40
vm.dirty_background_ratio = 10
vm.vfs_cache_pressure = 50

sudo sysctl -p
```

**4. Monitor disk I/O during uploads:**
```bash
# Real-time I/O stats
sudo iotop -o

# Check if disk is bottleneck
iostat -x 2
```

#### SSH Security

Additional hardening can be done in `/etc/ssh/sshd_config`:
- Restrict allowed authentication methods
- Configure connection limits
- Set up fail2ban for brute-force protection (configured automatically by setup.sh)

### Client Configuration

Both client scripts support configuration via command-line parameters. For automated backups, consider:

#### Automated Setup (Recommended)

**Windows:** Use rclone (see `src/client/windows/RCLONE_BACKUP_SETUP.md`)

**Linux:** Use `src/client/linux/setup-client.sh` (see [Automated Linux Backup Setup](#automated-linux-backup-setup-srcclientlinuxsetup-clientsh) above)

#### Manual Scheduling

If you prefer to manually configure scheduled backups:

**Windows - Task Scheduler (GUI):**
1. Open **Task Scheduler** (`taskschd.msc`)
2. Create a task and select **Run whether user is logged on or not**
3. Action: **Start a program**
4. Program/script: full path to `rclone.exe`
5. Arguments (example):
   ```
   sync "C:\Users\USER_NAME\Downloads\test-user1" testuser1:uploads --log-file "C:\Users\USER_NAME\Downloads\rclone-testuser1.log" --log-level INFO --log-file-max-size 10M --log-file-max-backups 10 --log-file-max-age 30d
   ```

**Note:** On Windows versions prior to Windows 10, use rclone v1.63.1 and remove the `--log-file-max-*` flags.

**Linux - Cron Job:**

The recommended approach is to use `setup-client.sh` which automatically creates a cron job:
```bash
sudo ./src/client/linux/setup-client.sh
```

Alternatively, for manual rclone setup:
```bash
# Create rclone remote
rclone config create terminas sftp host backup.example.com user backupuser pass $(rclone obscure "SecurePass123!")

# Add cron job
sudo crontab -e

# Add this line to run backup daily at 2:00 AM
0 2 * * * rclone sync /var/data terminas:uploads --log-file /var/log/terminas-backup.log --log-level INFO

# Optional: Add log rotation
# Create /etc/logrotate.d/terminas-backup with:
/var/log/terminas-backup.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
}
```

**Cron Schedule Examples:**
```bash
# Every day at 2:00 AM
0 2 * * * /path/to/backup-script.sh

# Every day at 3:30 AM
30 3 * * * /path/to/backup-script.sh

# Every Sunday at 1:00 AM (weekly)
0 1 * * 0 /path/to/backup-script.sh

# Every 6 hours
0 */6 * * * /path/to/backup-script.sh

# Every 30 minutes
*/30 * * * * /path/to/backup-script.sh
```

**Security Notes:**
- For production use, avoid embedding passwords in command lines (visible in process lists)
- Use the automated setup scripts which store credentials securely
- On Windows: Credentials stored in `C:\ProgramData\terminas-credentials\` (restricted to Administrators)
- On Linux: Credentials stored in `/root/.terminas-credentials/` (mode 600)

**Host Key Verification (TOFU - Trust On First Use):**
- First connection: Script accepts any host key and caches fingerprint in `%LOCALAPPDATA%\terminas\hostkeys\`
- Subsequent connections: Script verifies server fingerprint against cached value
- Cache location depends on user running the task:
  - `NT AUTHORITY\SYSTEM` (recommended): `C:\Windows\System32\config\systemprofile\AppData\Local\terminas\`
  - Admin user: `C:\Users\<username>\AppData\Local\terminas\`
- If server key changes (e.g., server reinstall), task will fail with exit code 6
- To reset trust: Delete the cached fingerprint file and let the script recapture it
- For paranoid security: Manually provide `-ExpectedHostFingerprint` parameter to bypass TOFU

## Development
To modify or extend the scripts:
- Edit `src/server/setup.sh` for server configuration changes
- Edit `src/server/create_user.sh` for user setup tweaks
- Edit `src/server/manage_users.sh` to add new management commands
- Edit client script (`src/client/linux/setup-client.sh`) for backup setup behavior
- Test in a VM to avoid disrupting production

**Key Files:**
- `src/server/setup.sh` - Server initialization and configuration
- `src/server/create_user.sh` - User creation with password generation
- `src/server/delete_user.sh` - User deletion
- `src/server/manage_users.sh` - User and snapshot management
- `src/client/linux/setup-client.sh` - Linux client backup setup (creates rclone config)
- `/var/terminas/scripts/terminas-monitor.sh` - Real-time snapshot monitor, Btrfs generation polling (created by setup)
- `/var/terminas/scripts/terminas-cleanup.sh` - Retention policy cleanup (created by setup)
- `/etc/terminas-retention.conf` - Retention configuration (created by setup)

## Troubleshooting

### Windows Client Issues

Windows backups are implemented with rclone. See `src/client/windows/RCLONE_BACKUP_SETUP.md` for setup, logging, and Task Scheduler guidance.
# Check task trigger
Get-ScheduledTask -TaskName "termiNAS-Backup-<jobname>" | Select-Object -ExpandProperty Triggers

# Manually trigger task to test
Start-ScheduledTask -TaskName "termiNAS-Backup-<jobname>"

# Check execution history
Get-ScheduledTask -TaskName "termiNAS-Backup-<jobname>" | Get-ScheduledTaskInfo
```

### Linux Client Issues

**Problem: "lftp: command not found" or "sftp: command not found"**

Solution:
```bash
# Install lftp (recommended)
sudo apt-get install lftp

# Or install openssh-client for sftp
sudo apt-get install openssh-client
```

**Problem: "Host key verification failed"**

Solution:
```bash
# Accept host key manually first
ssh-keyscan -H backup.example.com >> ~/.ssh/known_hosts

# The setup-client.sh script handles this automatically
```

### Server Issues

**Problem: fail2ban bans legitimate clients**

Check ban status:
```bash
sudo fail2ban-client status sshd
```

Unban IP:
```bash
sudo fail2ban-client set sshd unbanip <IP_ADDRESS>
```

Whitelist trusted IPs (edit `/etc/fail2ban/jail.local`):
```ini
[sshd]
ignoreip = 127.0.0.1/8 ::1 192.168.1.0/24 10.0.0.0/8
```

**Note: Pending Btrfs deletions after snapshot removal**

- Deleted subvolumes are reclaimed asynchronously by the Btrfs cleaner and may show as pending for a short while. The former inotify monitor could delay this indefinitely; the current generation-polling monitor does not (see [docs/ARCHITECTURE_PER_USER_INOTIFY.md](docs/ARCHITECTURE_PER_USER_INOTIFY.md) for the history). `sudo ./src/server/manage_users.sh force-clean` restarts the monitor and syncs the filesystem if you want to check reclamation immediately.

**Problem: Snapshots missing files or contain incomplete files**

**This is now fixed!** The new monitor logic creates **periodic snapshots** (every 30 minutes) that automatically exclude in-progress files.

**How it works:**
- Small completed files are included in snapshots within 30 minutes
- Large files still uploading are excluded from periodic snapshots
- Final snapshot is created when ALL files complete

Update your installation:
```bash
# Pull latest fix
cd /opt/terminas
git pull

# Re-run setup to update monitor script
sudo ./src/server/setup.sh

# Restart service
sudo systemctl restart terminas-monitor.service

# Verify new logic is applied
sudo grep "Excluding in-progress" /var/terminas/scripts/terminas-monitor.sh
```

**Monitor the snapshot process:**

```bash
# Watch for open files in uploads directory
sudo watch -n 1 "lsof +D /home/*/uploads 2>/dev/null | grep -E '\s+[0-9]+[uw]'"

# Check monitor logs to see exclusions
sudo tail -f /var/log/backup_monitor.log

# Example log output (10 MB + 500 GB mixed upload):
# 2025-10-09 03:00:30 Activity for eventsaxd: waiting for interval or completion
# 2025-10-09 03:30:30 Excluding in-progress files from snapshot:
# 2025-10-09 03:30:30   Excluded: huge.tar.gz (387GB, still uploading)
# 2025-10-09 04:00:30 Excluding in-progress files from snapshot:
# 2025-10-09 04:00:30   Excluded: huge.tar.gz (465GB, still uploading)
# 2025-10-09 04:15:00 huge.tar.gz upload completes
# 2025-10-09 04:16:00 Btrfs snapshot created for eventsaxd (all files closed)

# Example log output (quick upload - all files complete fast):
# 2025-10-09 05:00:10 files.tar.gz upload completes
# 2025-10-09 05:01:10 Btrfs snapshot created for eventsaxd (all files closed)
# ↑ Immediate snapshot (no 30-minute wait!)
```

**Verify excluded files:**
```bash
# Check final snapshot (all files present)
ls -lh /home/user/versions/2025-10-09_04-16-00/
# Shows: small.sql (10 MB), huge.tar.gz (500 GB)
```

**View snapshot history:**
```bash
# List all snapshots for a user
ls -lht /home/eventsaxd/versions/

# Compare snapshots (see what changed)
diff -r /home/eventsaxd/versions/2025-10-09_03-00-08 \
        /home/eventsaxd/versions/2025-10-09_04-30-15
```

### For very large files (500+ GB):

The monitor automatically handles files of any size by waiting until they're fully closed. However, if uploads take longer than 10 minutes (default `TERMINAS_MAX_WAIT=600`), increase the timeout:

```bash
sudo nano /etc/systemd/system/terminas-monitor.service

# Add to [Service] section:
Environment="TERMINAS_MAX_WAIT=1800"  # 30 minutes for very slow uploads

sudo systemctl daemon-reload
sudo systemctl restart terminas-monitor.service
```

**Best practices:**
1. Upload during off-peak hours (less I/O contention)
2. Monitor logs to verify snapshots capture complete files
3. Use fast network (10 Gbps) for massive file uploads
4. Consider dedicated backup disk/network for better throughput

**Problem: Snapshots not being created**

Check monitor service:
```bash
sudo systemctl status terminas-monitor.service
sudo journalctl -u terminas-monitor.service -f
```

Check the monitor log for the user's generation changes and snapshot decisions:
```bash
sudo tail -f /var/log/terminas.log

# Verbose: log every generation change (add to the [Service] section of the unit, then
# systemctl daemon-reload && systemctl restart terminas-monitor.service)
Environment="TERMINAS_DEBUG=1"

# The monitor compares these two numbers: uploads "gen" vs. the newest snapshot's "cgen"
sudo btrfs subvolume list -c /home | grep '<username>/'
```

The monitor does not use inotify, so inotify watch limits are irrelevant to snapshot creation.

**Problem: Disk full due to too many snapshots**

Manually trigger cleanup:
```bash
sudo /var/terminas/scripts/terminas-cleanup.sh
```

Adjust retention policy in `/etc/terminas-retention.conf`:
```bash
# Reduce retention for all users
KEEP_DAILY=3
KEEP_WEEKLY=2
KEEP_MONTHLY=1

# Or disable advanced retention
ENABLE_ADVANCED_RETENTION=false
RETENTION_DAYS=7
```

**Problem: Quota not working / "Btrfs quotas are not enabled"**

Check if quotas are enabled:
```bash
sudo btrfs qgroup show /home
```

If you see "ERROR: can't list qgroups: quotas not enabled", enable **simple quotas (squotas)**:
```bash
# Enable simple quotas (squota mode)
sudo btrfs quota disable /home
sudo btrfs quota enable --simple /home

# Verify
sudo btrfs qgroup show /home
```

Or re-run setup script (automatically enables squotas):
```bash
sudo ./src/server/setup.sh
```

**Problem: Quota shows lower usage than `info` / "qgroup data inconsistent" warning**

First check which quota mode `/home` is in (`status` reports it too):
```bash
cat /sys/fs/btrfs/$(findmnt -no UUID --target /home)/qgroups/mode    # squota or qgroup
```

- **`qgroup` (full accounting)** — termiNAS is designed for simple quotas, and servers set up
  before the simple-quota design (or where quotas were enabled by hand) may still run full mode.
  In full mode per-user totals exclude data shared with snapshots (so the uploads+snapshots check
  undercounts), every snapshot carries accounting work, and while the accounting is flagged
  "inconsistent" the kernel does not count new data at all until `btrfs quota rescan /home`
  completes. Migrate with `sudo ./src/server/manage_users.sh migrate-squota` (it re-applies all
  configured limits). Existing data is not attributed under simple quotas; new writes are.
- **`squota` (simple quotas)** — only extents written *after* quotas were enabled are accounted;
  data that already existed is never attributed, `btrfs quota rescan` does not apply, and Btrfs
  flags the accounting as "inconsistent" as long as such data exists. This is expected. Exact
  sizes come from `refresh-sizes` (`list`/`info`); quota enforcement applies to new writes.
  **Do not** disable and re-enable quotas to "refresh" the numbers: that resets attribution for
  all current data.
```bash
# Compare exact usage with quota-accounted usage
sudo ./src/server/manage_users.sh info username
sudo ./src/server/manage_users.sh show-quota username
```

**Problem: User over quota but snapshots still being created**

Check monitor logs for quota enforcement:
```bash
# View quota-related log entries
sudo grep -i quota /var/log/terminas.log | tail -20

# Should see entries like:
# ERROR: User testuser is over quota (50.2GB / 50.0GB)
# Snapshot creation blocked - user must free up space
```

Verify monitor service is running:
```bash
sudo systemctl status terminas-monitor.service
sudo systemctl restart terminas-monitor.service
```

**Problem: Cannot set quota / "Failed to create qgroup"**

This usually means quotas are not enabled or the subvolume doesn't exist.

Verify user structure:
```bash
# Check if home directory is a subvolume (required for quota)
sudo btrfs subvolume show /home/username

# Check if quotas are enabled
sudo btrfs qgroup show /home

# Get subvolume ID for home directory
sudo btrfs subvolume list /home | grep username
```

**Problem: Quota reached but files still uploading**

With the current implementation, quota blocks file writes at the filesystem level:

- ❌ SFTP/Samba uploads fail with "Disk quota exceeded" error
- ❌ New snapshots are blocked until space is freed
- 📸 Existing snapshots remain accessible for restores
- 🧹 Free space by removing old snapshots: `./manage_users.sh cleanup username`

**Problem: Quota usage doesn't match disk usage**

Quota tracks **exclusive bytes** (physical disk usage), not logical file sizes:

```bash
# View detailed Btrfs usage
sudo btrfs filesystem du -s /home/username/

# Compare with quota
sudo ./src/server/manage_users.sh show-quota username

# Quota uses "excl" (exclusive) which is:
# - Actual physical disk space consumed
# - Accounts for Btrfs CoW deduplication between uploads and snapshots
# - Lower than logical size when data is shared between snapshots
```

**Test quota functionality:**

Run the comprehensive test suite:
```bash
cd /opt/terminas/src/server/tests
sudo ./test_quota.sh

# This will:
# - Create test user with 1GB quota
# - Upload files to test enforcement
# - Verify quota blocking works
# - Test quota modification
# - Clean up test user

# Cleanup test user
sudo ./test_quota.sh --cleanup-only
```
