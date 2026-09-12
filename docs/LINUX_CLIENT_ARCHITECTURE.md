# Linux Client Architecture

This document describes the technical architecture of the termiNAS Linux client backup system, implemented in `src/client/linux/setup-client.sh`.

## Overview

The Linux client uses **rclone** as the underlying SFTP transfer engine to sync local directories to a termiNAS server. The setup script creates all necessary configuration for automated daily backups via cron.

## How It Works

### Backup Flow

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│  Local Machine  │     │   rclone sync   │     │ termiNAS Server │
│                 │     │                 │     │                 │
│  /local/path/   │────▶│  SFTP Transfer  │────▶│  ~/uploads/     │
│                 │     │  (encrypted)    │     │                 │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                                               │
        │                                               ▼
        │                                    ┌─────────────────────┐
        │                                    │ Server-side Monitor │
        │                                    │ Creates immutable   │
        │                                    │ snapshots in        │
        │                                    │ ~/versions/         │
        └────────────────────────────────────┴─────────────────────┘
```

1. **Cron** triggers the backup script at the scheduled time
2. **Backup script** calls `rclone sync` (or `rclone copyto` for single files)
3. **rclone** connects via SFTP using credentials from its config file
4. **rclone sync** compares local vs remote (size + mtime) and transfers only changed files
5. **rclone sync** deletes remote files that no longer exist locally (mirror behavior)
6. **Server monitor** (separate process) detects changes and creates immutable snapshots

### Sync Behavior

The client uses `rclone sync` which behaves like `rsync --delete`:

| Local | Remote | Action |
|-------|--------|--------|
| File exists | File missing | Upload |
| File exists | File exists, same | Skip (no transfer) |
| File exists | File exists, different | Upload (overwrite) |
| File missing | File exists | Delete from remote |

This ensures the remote `uploads/` folder is always an exact mirror of the local source.

**Single File Mode**: When backing up a single file (not directory), `rclone copyto` is used instead to avoid accidentally deleting other files in the destination.

## Files Created by setup-client.sh

### 1. Rclone Remote Configuration

**Location**: `/root/.config/rclone/rclone.conf`  
**Permissions**: `600` (root only)  
**Owner**: root

Contains the SFTP remote definition:
```ini
[terminas-<jobname>]
type = sftp
host = <server>
user = <username>
pass = <obscured_password>
```

The password is obscured using `rclone obscure` (base64 + XOR, not true encryption but prevents casual viewing). The config file's restrictive permissions (600) provide the actual security.

**Remote naming**: Each backup job gets a unique remote name (`terminas-<jobname>`) allowing multiple backup jobs on the same client.

### 2. Backup Script

**Location**: `/usr/local/bin/terminas-backup/backup-<jobname>.sh`  
**Permissions**: `755` (executable)  
**Owner**: root

Auto-generated bash script that:
1. Checks if local path exists
2. Logs start time to log file
3. Runs `rclone sync` or `rclone copyto`
4. Logs completion status and exit code

Example generated script:
```bash
#!/bin/bash
LOG_FILE="/var/log/terminas-<jobname>.log"
LOCAL_PATH="/path/to/backup"
RCLONE_REMOTE="terminas-<jobname>"
DEST_PATH="uploads"

# ... logging and sync logic ...
rclone sync "$LOCAL_PATH" "$RCLONE_REMOTE:$DEST_PATH" \
    --log-file "$LOG_FILE" \
    --log-level INFO
```

### 3. Logrotate Configuration

**Location**: `/etc/logrotate.d/terminas-<jobname>`  
**Purpose**: Prevents log files from growing indefinitely

Configuration:
```
/var/log/terminas-<jobname>.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root adm
}
```

This keeps 12 weeks of compressed logs.

### 4. Cron Job

**Location**: Root's crontab (`crontab -l`)  
**Format**: `<minute> <hour> * * * /usr/local/bin/terminas-backup/backup-<jobname>.sh`

Example:
```
# termiNAS automated backup: mybackup
0 2 * * * /usr/local/bin/terminas-backup/backup-mybackup.sh
```

### 5. Log File

**Location**: `/var/log/terminas-<jobname>.log`  
**Permissions**: `640` (root:adm)

Contains timestamped entries for each backup run plus rclone's transfer details.

## File Structure Summary

```
/root/.config/rclone/
└── rclone.conf                 # Rclone remote configs (600, contains obscured passwords)

/usr/local/bin/terminas-backup/
└── backup-<jobname>.sh         # Generated backup script (755, executable)

/etc/logrotate.d/
└── terminas-<jobname>          # Log rotation config

/var/log/
└── terminas-<jobname>.log      # Backup log file (640)

/var/spool/cron/crontabs/root   # Or equivalent - contains cron job
```

## Security Considerations

### Password Storage
- Passwords are stored in rclone's config with obscuration (not encryption)
- Config file permissions (600) restrict access to root only
- Passwords are **never** passed as command-line arguments (would be visible in `ps`)

### File Permissions
| File | Permissions | Rationale |
|------|-------------|-----------|
| rclone.conf | 600 | Contains credentials |
| rclone config dir | 700 | Directory protection |
| Backup script | 755 | Needs to be executable |
| Log file | 640 | Readable by adm group for monitoring |

### Root Requirement
The setup script requires root because:
1. Writes to `/usr/local/bin/`
2. Writes to `/etc/logrotate.d/`
3. Modifies root's crontab
4. Rclone config stored in `/root/.config/`

## Debugging Guide

### Common Issues

#### Backup Not Running
```bash
# Check if cron job exists
crontab -l | grep terminas

# Check cron daemon is running
systemctl status cron

# Check backup script exists and is executable
ls -la /usr/local/bin/terminas-backup/
```

#### Connection Failures
```bash
# Test rclone connection manually
rclone lsd terminas-<jobname>:

# Check SSH connectivity
ssh -v <username>@<server>

# Verify host key is in known_hosts
ssh-keygen -F <server>
```

#### Permission Errors
```bash
# Check rclone config permissions
ls -la /root/.config/rclone/

# Verify remote path exists on server
rclone lsd terminas-<jobname>:uploads/
```

#### Transfer Issues
```bash
# Run backup with verbose output
rclone sync /local/path terminas-<jobname>:uploads -vv

# Check what would be transferred (dry run)
rclone sync /local/path terminas-<jobname>:uploads --dry-run
```

### Log Analysis
```bash
# View recent log entries
tail -100 /var/log/terminas-<jobname>.log

# Search for errors
grep -i "error\|fail" /var/log/terminas-<jobname>.log

# Watch log in real-time during backup
tail -f /var/log/terminas-<jobname>.log
```

### Rclone Debugging
```bash
# List configured remotes
rclone listremotes

# Show remote config (password will be obscured)
rclone config show terminas-<jobname>

# Test with maximum verbosity
rclone sync /local/path terminas-<jobname>:uploads -vv --progress
```

## Adding Features / Modifying Behavior

### To Change Sync Options
Edit the generated backup script at `/usr/local/bin/terminas-backup/backup-<jobname>.sh` or modify the template in `setup-client.sh` (around line 250).

Common rclone options to consider:
- `--bwlimit 1M` - Limit bandwidth
- `--transfers 4` - Parallel transfers (default: 4)
- `--checkers 8` - Parallel file checks
- `--exclude "*.tmp"` - Exclude patterns
- `--min-age 1h` - Only sync files older than 1 hour

### To Add Email Notifications
Add to the generated backup script after the sync:
```bash
if [ $EXIT_CODE -ne 0 ]; then
    echo "Backup failed" | mail -s "termiNAS Backup Failed: $BACKUP_NAME" admin@example.com
fi
```

### To Support Multiple Schedules
The current script only supports daily backups. To add hourly/weekly:
1. Modify the time input validation regex
2. Adjust cron job format generation
3. Update prompts and documentation

### To Add Bandwidth Limiting
Add a prompt for bandwidth limit in setup-client.sh and include `--bwlimit` in the generated rclone command.

## Dependencies

### Required
- **rclone**: SFTP transfer engine (installed via package manager)
- **cron**: Scheduling (typically pre-installed)
- **bash**: Shell interpreter

### Optional
- **logrotate**: Log management (typically pre-installed)
- **ssh-keyscan**: For host key management (part of openssh-client)

## Version Compatibility

### Rclone Versions
- **v1.53+**: Minimum supported (available in Debian 11)
- **v1.55+**: Adds `--log-file-max-size` and rotation flags
- Older versions work but require external log rotation (handled by logrotate)

### Linux Distributions
Tested with:
- Debian 10, 11, 12
- Ubuntu 20.04, 22.04, 24.04
- CentOS/RHEL 8, 9
- Any distro with bash 4.x+ and rclone in repos

## Related Documentation

- [RCLONE_BACKUP_SETUP.md](../src/client/windows/RCLONE_BACKUP_SETUP.md) - Windows client setup
- [QUOTA_ARCHITECTURE.md](QUOTA_ARCHITECTURE.md) - Server-side quota enforcement
- [SNAPSHOT_MONITOR_ARCHITECTURE.md](SNAPSHOT_MONITOR_ARCHITECTURE.md) - Server-side snapshot monitoring

## Reference Documentation

- [Official Rclone Documentation](https://rclone.org/docs/)
