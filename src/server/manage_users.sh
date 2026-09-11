#!/bin/bash

# manage_users.sh - Manage backup users, view stats, cleanup, and delete users
# Usage: ./manage_users.sh [command] [options]
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Get version from VERSION file in repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../../VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    VERSION="unknown"
fi

# Source common functions
COMMON_LIB="$SCRIPT_DIR/common.sh"
if [ -f "$COMMON_LIB" ]; then
    source "$COMMON_LIB"
else
    echo "ERROR: Cannot find common.sh library" >&2
    exit 1
fi

set -e

SCRIPT_NAME=$(basename "$0")

# Source delete_user.sh to reuse the reclaim_btrfs_space function
# This avoids code duplication across multiple scripts (used in cleanup_user, rebuild_user)
DELETE_USER_SCRIPT="$SCRIPT_DIR/delete_user.sh"
if [ -f "$DELETE_USER_SCRIPT" ]; then
    # Source only the reclaim_btrfs_space function definition, not the full script
    # This extracts the function from delete_user.sh without executing the main script logic
    eval "$(sed -n '/^reclaim_btrfs_space()/,/^}/p' "$DELETE_USER_SCRIPT")"
fi

usage() {
    cat <<EOF
termiNAS User Management Tool v$VERSION
Copyright (c) 2025 Yianni Bourkelis
https://github.com/YiannisBourkelis/terminas

Usage: $SCRIPT_NAME <command> [options]

Commands:
    list [--refresh]        List all backup users with disk usage and connection status
    info <username> [--refresh]  Show detailed information including connection activity
    refresh-sizes [username] [--force]  Compute exact sizes into the cache used by list/info (run nightly)
    status [--quiet]        Health check: monitor, uncaptured changes, quota blocks, disk, cron jobs (exit 0/1/2)
    history <username>      Show snapshot history for a user
    search <pattern>        Search for files in latest snapshots
    inactive [days]         List users with no recent uploads (default: 30 days)
    restore <username> <snapshot> <dest>  Restore files from a snapshot
    delete <username>       Delete a user and all their files
    cleanup <username>      Keep only the latest snapshot (removes old snapshots, keeps actual files)
    cleanup-all             Cleanup all backup users (keep latest snapshot for each)
    rebuild <username>      Delete all snapshots and create fresh snapshot from uploads
    rebuild-all             Rebuild snapshots for all users (skips users with open files)
    set-quota <username> <GB|MB>  Set storage quota for user (0 = unlimited)
    remove-quota <username>    Remove storage quota (unlimited)
    show-quota <username>      Show quota usage and limit for user
    show-pending-deletions  Show Btrfs pending deleted subvolumes under /home
    force-clean             Restart monitor and commit Btrfs deletions (non-blocking)
    change-password <username>  Change password for user (updates SFTP and Samba if enabled)
    enable-samba <username> Enable Samba (SMB) sharing for an existing user
    disable-samba <username> Disable Samba (SMB) sharing for an existing user
    enable-samba-versions <username>  Enable read-only SMB access to versions (snapshots) directory
    disable-samba-versions <username> Disable SMB access to versions directory
    enable-timemachine <username>     Enable macOS Time Machine support for a user
    disable-timemachine <username>    Disable macOS Time Machine support for a user
    version                 Show version information
    help                    Show this help message

Examples:
    $SCRIPT_NAME list
    $SCRIPT_NAME status
    $SCRIPT_NAME info testuser
    $SCRIPT_NAME history testuser
    $SCRIPT_NAME search "*.pdf"
    $SCRIPT_NAME inactive 60
    $SCRIPT_NAME restore testuser 2025-10-01_14-30-00 /tmp/restore
    $SCRIPT_NAME delete testuser
    $SCRIPT_NAME cleanup testuser
    $SCRIPT_NAME cleanup-all
    $SCRIPT_NAME rebuild testuser
    $SCRIPT_NAME rebuild-all
    $SCRIPT_NAME set-quota testuser 100
    $SCRIPT_NAME remove-quota testuser
    $SCRIPT_NAME show-quota testuser
    $SCRIPT_NAME change-password testuser
    $SCRIPT_NAME enable-samba testuser
    $SCRIPT_NAME enable-samba-versions testuser
    $SCRIPT_NAME disable-samba-versions testuser
    $SCRIPT_NAME disable-samba testuser
    $SCRIPT_NAME enable-timemachine testuser
    $SCRIPT_NAME disable-timemachine testuser

Notes:
    - list/info read sizes cached by refresh-sizes (installed as a nightly cron job by setup.sh);
      rows marked * changed since their sizes were computed. Connection times are read from the
      journal incrementally and reused for 15 minutes; --refresh forces a fresh read.
    - The cleanup command removes old Btrfs snapshots and keeps only the latest
    - Delete command removes the user and ALL their data permanently
    - Restore command copies files to specified destination (destination must not exist)
    - Search looks through latest snapshots only
    - Rebuild command deletes ALL existing snapshots and creates fresh snapshot from uploads
    - Rebuild skips users with files open in uploads directory (warns and continues)
    - Rebuild verifies file integrity between uploads and created snapshot
    - Protocol column shows available access methods:
      * SFTP: Basic SFTP-only access
      * SMB+SFTP: Samba share enabled
      * SMB*+SFTP: Samba share + read-only versions access
      * SMBTM+SFTP: Samba share + Time Machine support
      * SMB*TM+SFTP: Samba share + versions + Time Machine
EOF
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi
}

# Update Samba configuration to use explicit includes for per-user config files
# This ensures all shares in per-user files are loaded (wildcards don't work with multiple shares)
update_samba_includes() {
    local smb_conf="/etc/samba/smb.conf"
    
    # Check if Samba is configured
    if [ ! -f "$smb_conf" ]; then
        return 0  # Samba not configured, skip
    fi
    
    # Check if smb.conf.d directory exists
    if [ ! -d "/etc/samba/smb.conf.d" ]; then
        return 0
    fi
    
    # Remove any existing include lines (both wildcard and explicit)
    sed -i '/^include = \/etc\/samba\/smb.conf.d\//d' "$smb_conf"
    sed -i '/^config include = \/etc\/samba\/smb.conf.d\//d' "$smb_conf"
    # Also remove the comment line if it exists
    sed -i '/^# Explicit includes for per-user configurations/d' "$smb_conf"
    
    # Find where to insert the includes
    local first_share_line=$(grep -n '^\[.*-backup\]' "$smb_conf" | head -1 | cut -d: -f1)
    
    if [ -n "$first_share_line" ]; then
        # Create a temporary file with the includes
        local tmpfile=$(mktemp)
        echo "# Explicit includes for per-user configurations" > "$tmpfile"
        for conf in /etc/samba/smb.conf.d/*.conf; do
            if [ -f "$conf" ]; then
                echo "include = $conf" >> "$tmpfile"
            fi
        done
        echo "" >> "$tmpfile"
        
        # Split the file and insert includes
        head -n $((first_share_line - 1)) "$smb_conf" > "${smb_conf}.tmp"
        cat "$tmpfile" >> "${smb_conf}.tmp"
        tail -n +${first_share_line} "$smb_conf" >> "${smb_conf}.tmp"
        mv "${smb_conf}.tmp" "$smb_conf"
        rm -f "$tmpfile"
    else
        # No shares yet, append at end of file
        echo "" >> "$smb_conf"
        echo "# Explicit includes for per-user configurations" >> "$smb_conf"
        for conf in /etc/samba/smb.conf.d/*.conf; do
            if [ -f "$conf" ]; then
                echo "include = $conf" >> "$smb_conf"
            fi
        done
    fi
}

# Show Btrfs pending deletions under /home
show_pending_deletions() {
    echo "Checking Btrfs pending deletions for /home..."
    if ! command -v btrfs >/dev/null 2>&1; then
        echo "ERROR: btrfs command not found. This server must run on Btrfs."
        return 1
    fi

    # btrfs subvolume list -d lists subvolumes pending delete on this filesystem
    local output
    output=$(btrfs subvolume list -d /home 2>/dev/null || true)
    local count
    if [ -z "$output" ]; then
        count=0
    else
        # Count lines robustly and strip spaces/newlines
        count=$(printf "%s\n" "$output" | wc -l | tr -cd '0-9')
        [ -z "$count" ] && count=0
    fi

    echo "=========================================="
    echo "Pending deleted subvolumes: $count"
    echo "Filesystem: /home"
    echo "=========================================="

    if [ "$count" -eq 0 ]; then
        echo "No pending deletions. The cleaner has processed all deletions."
        return 0
    fi

    # Show up to 50 entries to avoid overwhelming the terminal
    local limit=50
    if [ "$count" -le "$limit" ]; then
        printf "%s\n" "$output"  
    else
        printf "%s\n" "$output" | head -n "$limit"
        # Safe arithmetic: both are integers here
        local remaining=$((count - limit))
        echo "... (${remaining} more not shown)"
    fi

    echo ""
    echo "Tip: Space is reclaimed asynchronously by the Btrfs cleaner."
    echo "     You can run: $SCRIPT_NAME force-clean to commit deletions."
}

# Change password for a user (updates SFTP and Samba if enabled)
change_password_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        usage
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if user is a backup user
    if ! groups "$username" 2>/dev/null | grep -q "backupusers"; then
        echo "Error: User '$username' is not a backup user" >&2
        return 1
    fi
    
    echo "========================================="
    echo "Change Password for: $username"
    echo "========================================="
    echo ""
    
    # Check which services are enabled
    local has_samba=false
    if has_samba_enabled "$username"; then
        has_samba=true
        echo "Services enabled: SFTP, Samba (SMB)"
    else
        echo "Services enabled: SFTP"
    fi
    echo ""
    
    # Prompt for new password (with confirmation)
    local password1 password2
    while true; do
        read -s -p "Enter new password (30+ chars, must contain lowercase, uppercase, and numbers): " password1
        echo ""
        read -s -p "Confirm new password: " password2
        echo ""
        
        if [ "$password1" != "$password2" ]; then
            echo "Error: Passwords do not match. Please try again."
            echo ""
            continue
        fi
        
        # Validate password strength using shared function
        if validate_password "$password1" 2>/dev/null; then
            # Password is valid
            break
        else
            # Show error (validate_password already printed it to stderr)
            echo ""
            continue
        fi
    done
    
    echo ""
    echo "Updating password..."
    
    # Update system password (SFTP)
    if echo "$username:$password1" | chpasswd 2>/dev/null; then
        echo "✓ SFTP password updated"
    else
        echo "✗ ERROR: Failed to update SFTP password" >&2
        return 1
    fi
    
    # Update Samba password if enabled
    if [ "$has_samba" = true ]; then
        if command -v smbpasswd &>/dev/null; then
            if echo -e "$password1\n$password1" | smbpasswd -s "$username" 2>/dev/null; then
                echo "✓ Samba password updated"
            else
                echo "✗ ERROR: Failed to update Samba password" >&2
                echo "  SFTP password was changed but Samba password remains old"
                echo "  You may need to manually update: smbpasswd -a $username"
                return 1
            fi
        else
            echo "⚠ WARNING: smbpasswd command not found"
            echo "  SFTP password was changed but Samba password could not be updated"
        fi
    fi
    
    echo ""
    echo "========================================="
    echo "✓ Password changed successfully"
    echo "========================================="
    echo ""
    echo "The new password is now active for:"
    if [ "$has_samba" = true ]; then
        echo "  - SFTP connections"
        echo "  - Samba (SMB) shares"
        if has_timemachine_enabled "$username"; then
            echo "  - Time Machine backups"
        fi
    else
        echo "  - SFTP connections"
    fi
    echo ""
}

# Force a non-blocking cleanup: restart monitor (to drop inotify descriptors)
# and commit deletion metadata so the kernel cleaner can reclaim space
force_clean() {
    echo "Forcing non-blocking cleanup..."

    # Restart monitor service if present
    if command -v systemctl >/dev/null 2>&1 && [ -f /etc/systemd/system/terminas-monitor.service ]; then
        if systemctl is-active --quiet terminas-monitor.service; then
            echo "Restarting terminas-monitor.service..."
            systemctl restart terminas-monitor.service || true
        else
            echo "terminas-monitor.service is not active; attempting to start..."
            systemctl restart terminas-monitor.service || true
        fi
    else
        echo "Monitor service not found; skipping service restart"
    fi

    # Show count before sync
    local before
    before=$(btrfs subvolume list -d /home 2>/dev/null | wc -l || echo 0)
    echo "Pending deletions before: $before"

    # Commit metadata; do NOT use 'btrfs subvolume sync' here
    if btrfs filesystem sync /home >/dev/null 2>&1; then
        echo "✓ Committed deletions to disk (filesystem sync)"
    else
        echo "⚠ WARNING: 'btrfs filesystem sync /home' failed"
    fi

    # Show count after sync
    local after
    after=$(btrfs subvolume list -d /home 2>/dev/null | wc -l || echo 0)
    echo "Pending deletions after:  $after"

    echo "Note: The Btrfs extent cleaner reclaims space asynchronously."
    echo "      Counts may decrease over time even if not immediately zero."
}

# Get list of backup users (members of backupusers group)
get_backup_users() {
    # Get the GID of backupusers group
    local gid=$(getent group backupusers 2>/dev/null | cut -d: -f3)
    if [ -z "$gid" ]; then
        return
    fi
    
    # Find users with backupusers as primary group (from /etc/passwd)
    # Format: username:x:uid:gid:...
    local primary_users=$(getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}')
    
    # Find users with backupusers as supplementary group
    local supp_users=$(getent group backupusers 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    
    # Combine and deduplicate
    echo -e "${primary_users}\n${supp_users}" | grep -v '^$' | sort -u
}

# Calculate actual disk usage (counting hardlinks only once) in MB with decimals
get_actual_size() {
    local path="$1"
    if [ -d "$path" ]; then
        # Use du in KB and convert to MB with 2 decimal places
        local kb=$(du -sLk "$path" 2>/dev/null | awk '{print $1}')
        echo "scale=2; $kb / 1024" | bc
    else
        echo "0.00"
    fi
}

# Get last backup date for a user
# Parse snapshot directory name to extract timestamp
# Btrfs snapshots preserve the original subvolume's metadata (birth/modify times),
# so we must parse the snapshot name (YYYY-MM-DD_HH-MM-SS) to get actual creation time
# Args: $1 = snapshot directory path or name
# Returns: "epoch|formatted_date" or "0|Unknown" if parsing fails
parse_snapshot_timestamp() {
    local snapshot="$1"
    local name=$(basename "$snapshot")
    
    # Extract date/time from snapshot name format: YYYY-MM-DD_HH-MM-SS
    if [[ "$name" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        local year="${BASH_REMATCH[1]}"
        local month="${BASH_REMATCH[2]}"
        local day="${BASH_REMATCH[3]}"
        local hour="${BASH_REMATCH[4]}"
        local min="${BASH_REMATCH[5]}"
        local sec="${BASH_REMATCH[6]}"
        
        local formatted="$year-$month-$day $hour:$min:$sec"
        local epoch=$(date -d "$formatted" "+%s" 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S" "$formatted" "+%s" 2>/dev/null || echo 0)
        echo "$epoch|$formatted"
    else
        echo "0|Unknown"
    fi
}

# Get snapshot info (oldest or newest) for a user
# Args: $1 = username or versions_dir path, $2 = "oldest" or "newest" (default: newest)
# Returns: "path|epoch|formatted_date" or "||Never" if no snapshots
# Parses snapshot directory name (YYYY-MM-DD_HH-MM-SS) for accurate creation time
get_snapshot_info() {
    local input="$1"
    local which="${2:-newest}"
    local versions_dir
    
    # Support both username and direct path
    if [[ "$input" == /* ]]; then
        versions_dir="$input"
    else
        versions_dir="/home/$input/versions"
    fi
    
    if [ ! -d "$versions_dir" ]; then
        echo "||Never"
        return
    fi
    
    # Build list of snapshots with parsed timestamps from directory names
    # This is reliable because Btrfs snapshots preserve original subvolume metadata
    local sort_cmd="tail -1"
    [ "$which" = "oldest" ] && sort_cmd="head -1"
    
    local snapshot_list=""
    for d in "$versions_dir"/*/; do
        if [ -d "$d" ]; then
            local ts_info=$(parse_snapshot_timestamp "$d")
            local epoch=$(echo "$ts_info" | cut -d'|' -f1)
            snapshot_list+="$epoch $d"$'\n'
        fi
    done
    
    local snapshot=$(echo -n "$snapshot_list" | sort -n | $sort_cmd | cut -d' ' -f2-)
    
    if [ -n "$snapshot" ] && [ -d "$snapshot" ]; then
        local ts_info=$(parse_snapshot_timestamp "$snapshot")
        local epoch=$(echo "$ts_info" | cut -d'|' -f1)
        local formatted=$(echo "$ts_info" | cut -d'|' -f2)
        echo "$snapshot|$epoch|$formatted"
    else
        echo "||Never"
    fi
}

# Build a dictionary of all user last connections (called once for performance)
# Returns associative array: username -> "formatted_date|epoch"
build_connection_cache() {
    declare -gA CONNECTION_CACHE
    
    # Try systemd journal first (Debian 12+)
    if command -v journalctl &>/dev/null; then
        # Get all accepted authentications in last 90 days, extract username and timestamp
        # Use awk for efficient single-pass processing
        # Note: journalctl timestamps don't include year, so we need to handle year rollover
        local current_epoch=$(date +%s)
        while IFS='|' read -r user epoch; do
            if [ -n "$user" ] && [ "$epoch" -gt 0 ]; then
                local formatted=$(date -d "@$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")
                CONNECTION_CACHE[$user]="$formatted|$epoch"
            fi
        done < <(journalctl -u ssh.service --since "90 days ago" 2>/dev/null | \
        grep -i "Accepted password for\|Accepted publickey for" | \
        awk -v current_epoch="$current_epoch" '
        BEGIN {
            one_year = 31536000  # seconds in a year
        }
        {
            # Extract timestamp (fields 1-3: Oct 10 08:15:30)
            ts = $1 " " $2 " " $3
            
            # Extract username from "Accepted password for USERNAME" or "Accepted publickey for USERNAME"
            # Use mawk-compatible approach
            if (match($0, /Accepted (password|publickey) for ([^ ]+)/)) {
                # Split the line and find the username after "for"
                split($0, parts, " ")
                for (i = 1; i <= length(parts); i++) {
                    if (parts[i] == "for") {
                        user = parts[i+1]
                        break
                    }
                }
                
                if (user != "") {
                    if (!(ts in epoch_cache)) {
                        cmd = "date -d \"" ts "\" +%s 2>/dev/null"
                        cmd | getline epoch_ts
                        close(cmd)
                        # Fix year rollover: if date is in the future, it is from last year
                        if (epoch_ts > current_epoch) {
                            epoch_ts = epoch_ts - one_year
                        }
                        epoch_cache[ts] = epoch_ts
                    } else {
                        epoch_ts = epoch_cache[ts]
                    }
                    
                    if (!(user in users) || epoch_ts > users[user]) {
                        users[user] = epoch_ts
                    }
                }
            }
        }
        END {
            for (user in users) {
                print user "|" users[user]
            }
        }
        ')
        return
    fi
    
    # Fallback to auth.log if available
    if [ -f /var/log/auth.log ]; then
        # Note: auth.log timestamps don't include year, so we need to handle year rollover
        local current_epoch=$(date +%s)
        while IFS='|' read -r user epoch; do
            if [ -n "$user" ] && [ "$epoch" -gt 0 ]; then
                local formatted=$(date -d "@$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")
                CONNECTION_CACHE[$user]="$formatted|$epoch"
            fi
        done < <(grep -i "Accepted password for\|Accepted publickey for" /var/log/auth.log 2>/dev/null | \
        awk -v current_epoch="$current_epoch" '
        BEGIN {
            one_year = 31536000  # seconds in a year
        }
        {
            ts = $1 " " $2 " " $3
            # Use mawk-compatible approach
            if (match($0, /Accepted (password|publickey) for ([^ ]+)/)) {
                # Split the line and find the username after "for"
                split($0, parts, " ")
                for (i = 1; i <= length(parts); i++) {
                    if (parts[i] == "for") {
                        user = parts[i+1]
                        break
                    }
                }
                
                if (user != "") {
                    if (!(ts in epoch_cache)) {
                        cmd = "date -d \"" ts "\" +%s 2>/dev/null"
                        cmd | getline epoch_ts
                        close(cmd)
                        # Fix year rollover: if date is in the future, it is from last year
                        if (epoch_ts > current_epoch) {
                            epoch_ts = epoch_ts - one_year
                        }
                        epoch_cache[ts] = epoch_ts
                    } else {
                        epoch_ts = epoch_cache[ts]
                    }
                    
                    if (!(user in users) || epoch_ts > users[user]) {
                        users[user] = epoch_ts
                    }
                }
            }
        }
        END {
            for (user in users) {
                print user "|" users[user]
            }
        }
        ')
    fi
}

# True when a connection state file is younger than the reuse window
# (TERMINAS_CONNECTION_CACHE_TTL seconds, default 900).
connection_state_is_fresh() {
    local state="$1"
    local ttl="${TERMINAS_CONNECTION_CACHE_TTL:-900}"
    local mtime
    mtime=$(stat -c %Y "$state" 2>/dev/null) || return 1
    [ $(( $(date +%s) - mtime )) -lt "$ttl" ]
}

# Age description of the connection state for footers ("as of HH:MM")
connection_state_asof() {
    local state="$TERMINAS_CACHE_DIR/ssh_logins"
    local mtime
    mtime=$(stat -c %Y "$state" 2>/dev/null) || return 1
    date -d "@$mtime" "+%Y-%m-%d %H:%M"
}

# Read journal entries incrementally into a file.
# journalctl does not accept --since together with a cursor, so the first run
# reads the whole window with --show-cursor and saves the cursor; later runs
# pass only --cursor-file (which journalctl updates at the end). If the saved
# cursor is unusable (e.g. journal vacuumed) the full window is re-read.
# journalctl errors are reported on stderr instead of being hidden.
# Usage: journal_read_incremental <cursor_file> <since> <out_file> <journalctl args...>
journal_read_incremental() {
    local cursor="$1" since="$2" out="$3"
    shift 3
    local err
    err=$(mktemp)

    if [ -s "$cursor" ]; then
        if journalctl -q "$@" --cursor-file="$cursor" >"$out" 2>"$err" || [ ! -s "$err" ]; then
            rm -f "$err"
            return 0
        fi
        echo "Warning: incremental journal read failed ($(head -1 "$err")); re-reading last $since" >&2
        rm -f "$cursor"
        : > "$err"
    fi

    journalctl -q "$@" --since "$since" --show-cursor >"$out" 2>"$err" || true
    if [ -s "$err" ]; then
        echo "Warning: journalctl: $(head -1 "$err")" >&2
    fi
    rm -f "$err"

    local c
    c=$(grep '^-- cursor: ' "$out" | tail -1 | sed 's/^-- cursor: //')
    if [ -n "$c" ]; then
        echo "$c" > "$cursor"
    fi
    return 0
}

# SSH login cache (incremental). Reads the journal with native timestamps and
# native filtering, and keeps a cursor so each run only reads entries added
# since the previous run (a full 90-day read costs ~13s on a busy server; the
# incremental read is nearly free). Matches every "Accepted <method> for"
# line, including keyboard-interactive/pam which Debian uses for passwords.
# Falls back to the original implementation when journald is absent.
build_connection_cache_fast() {
    declare -gA CONNECTION_CACHE=()

    if ! command -v journalctl &>/dev/null; then
        build_connection_cache
        return
    fi
    ensure_cache_dir || { build_connection_cache; return; }

    local state="$TERMINAS_CACHE_DIR/ssh_logins"
    local cursor="$TERMINAS_CACHE_DIR/ssh_logins.cursor"
    declare -A last=()
    local user epoch

    if [ -f "$state" ]; then
        while IFS='|' read -r user epoch; do
            [ -n "$user" ] && last[$user]="$epoch"
        done < "$state"
        # Opening a large journal costs seconds even for a cursor read, so
        # reuse recent state unless a refresh was requested.
        if [ "${FAST_REFRESH_CONNECTIONS:-false}" != true ] && connection_state_is_fresh "$state"; then
            for user in "${!last[@]}"; do
                CONNECTION_CACHE[$user]="$(date -d "@${last[$user]}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")|${last[$user]}"
            done
            return 0
        fi
    fi

    local tmp
    tmp=$(mktemp)
    # SYSLOG_IDENTIFIER is a single indexed field; "-u ssh.service" expands to
    # many match terms and costs several seconds on a large journal. OpenSSH
    # 9.8+ logs connections from a separate "sshd-session" process; repeating
    # the field ORs the two identifiers.
    journal_read_incremental "$cursor" "90 days ago" "$tmp" \
        SYSLOG_IDENTIFIER=sshd SYSLOG_IDENTIFIER=sshd-session \
        -o short-unix --no-pager --grep 'Accepted \S+ for '

    while IFS='|' read -r user epoch; do
        [ -n "$user" ] || continue
        if [ "${epoch:-0}" -gt "${last[$user]:-0}" ]; then
            last[$user]="$epoch"
        fi
    done < <(awk '$1 !~ /^[0-9]/ { next }
        {
            ts = int($1)
            for (i = 1; i <= NF; i++) {
                if ($i == "for") {
                    u = $(i + 1)
                    if (!(u in l) || ts > l[u]) l[u] = ts
                    break
                }
            }
        }
        END { for (u in l) print u "|" l[u] }' "$tmp")
    rm -f "$tmp"

    : > "$state.tmp"
    for user in "${!last[@]}"; do
        echo "$user|${last[$user]}" >> "$state.tmp"
        CONNECTION_CACHE[$user]="$(date -d "@${last[$user]}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")|${last[$user]}"
    done
    mv -f "$state.tmp" "$state"
}

# Samba activity cache (incremental): one pass for all users (the original
# scans the journal once per Samba user), with a journal cursor like the SSH
# cache. Audit payload format: user|ip|machine|operation|... (last field).
# When /var/log/samba/audit.log is in use it is scanned in a single pass
# (log files rotate, so no cursor is kept for them).
build_samba_connection_cache_fast() {
    declare -gA SAMBA_CONNECTION_CACHE=()

    local audit_log="/var/log/samba/audit.log"
    local user epoch

    if [ -s "$audit_log" ]; then
        local current_epoch
        current_epoch=$(date +%s)
        while IFS='|' read -r user epoch; do
            [ -n "$user" ] && [ "${epoch:-0}" -gt 0 ] || continue
            SAMBA_CONNECTION_CACHE[$user]="$(date -d "@$epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")|$epoch"
        done < <(awk -v current_epoch="$current_epoch" '
            /^[A-Za-z]/ {
                n = split($NF, f, "|")
                if (n < 4 || f[4] !~ /^(connect|write|pwrite|close)$/) next
                ts = $1 " " $2 " " $3
                if (!(ts in cache)) {
                    cmd = "date -d \"" ts "\" +%s 2>/dev/null"
                    cmd | getline e; close(cmd)
                    if (e > current_epoch) e -= 31536000
                    cache[ts] = e
                }
                e = cache[ts]
                if (!(f[1] in l) || e > l[f[1]]) l[f[1]] = e
            }
            END { for (u in l) print u "|" l[u] }' "$audit_log")
        return
    fi

    command -v journalctl &>/dev/null || return 0
    ensure_cache_dir || return 0

    local state="$TERMINAS_CACHE_DIR/smb_activity"
    local cursor="$TERMINAS_CACHE_DIR/smb_activity.cursor"
    declare -A last=()
    if [ -f "$state" ]; then
        while IFS='|' read -r user epoch; do
            [ -n "$user" ] && last[$user]="$epoch"
        done < "$state"
        if [ "${FAST_REFRESH_CONNECTIONS:-false}" != true ] && connection_state_is_fresh "$state"; then
            for user in "${!last[@]}"; do
                SAMBA_CONNECTION_CACHE[$user]="$(date -d "@${last[$user]}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")|${last[$user]}"
            done
            return 0
        fi
    fi

    local tmp
    tmp=$(mktemp)
    journal_read_incremental "$cursor" "30 days ago" "$tmp" \
        SYSLOG_IDENTIFIER=smbd_audit -o short-unix --no-pager

    while IFS='|' read -r user epoch; do
        [ -n "$user" ] || continue
        if [ "${epoch:-0}" -gt "${last[$user]:-0}" ]; then
            last[$user]="$epoch"
        fi
    done < <(awk '$1 !~ /^[0-9]/ { next }
        {
            n = split($NF, f, "|")
            if (n < 4 || f[4] !~ /^(connect|write|pwrite|close)$/) next
            ts = int($1)
            if (!(f[1] in l) || ts > l[f[1]]) l[f[1]] = ts
        }
        END { for (u in l) print u "|" l[u] }' "$tmp")
    rm -f "$tmp"

    : > "$state.tmp"
    for user in "${!last[@]}"; do
        echo "$user|${last[$user]}" >> "$state.tmp"
        SAMBA_CONNECTION_CACHE[$user]="$(date -d "@${last[$user]}" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "Unknown")|${last[$user]}"
    done
    mv -f "$state.tmp" "$state"
}

# Get last connection time for a user from cache
get_last_connection() {
    local user="$1"
    
    # Return from cache if available
    if [ -n "${CONNECTION_CACHE[$user]}" ]; then
        echo "${CONNECTION_CACHE[$user]}"
    else
        echo "Never|0"
    fi
}

# Get last Samba connection time for a user from cache
get_last_samba_connection() {
    local user="$1"
    
    # Return from cache if available
    if [ -n "${SAMBA_CONNECTION_CACHE[$user]}" ]; then
        echo "${SAMBA_CONNECTION_CACHE[$user]}"
    else
        echo "Never|0"
    fi
}

# Check if read-only Samba access to versions is enabled for a user
has_samba_versions_enabled() {
    local username="$1"
    # Check if versions share exists in the user's main Samba config file
    local smb_conf="/etc/samba/smb.conf.d/${username}.conf"
    [ -f "$smb_conf" ] && grep -qF "[${username}-versions]" "$smb_conf" 2>/dev/null
}

# Enable Samba sharing for an existing user
enable_samba() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if user is in backupusers group
    if ! id "$username" | grep -q "backupusers"; then
        echo "Error: User '$username' is not a backup user" >&2
        return 1
    fi
    
    # Check if Samba is already enabled
    if has_samba_enabled "$username"; then
        echo "Samba sharing is already enabled for user '$username'"
        return 0
    fi
    
    echo "Enabling Samba sharing for user '$username'..."
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        echo "To enable Samba support, run setup.sh with the --samba option:"
        echo "  ./setup.sh --samba"
        return 1
    fi
    
    # Check if Samba user already exists
    if pdbedit -L | grep -q "^$username:"; then
        echo "Samba user account already exists for '$username'"
    else
        # Get user's password from /etc/shadow (we need to extract it)
        local shadow_entry=$(getent shadow "$username")
        if [ -z "$shadow_entry" ]; then
            echo "ERROR: Cannot retrieve password for user '$username'" >&2
            return 1
        fi
        
        # For Samba, we need the plain text password. Since we don't have it stored,
        # we'll need to prompt the user to provide it
        echo "Samba requires the user's password to set up the share."
        echo "Please enter the password for user '$username':"
        local password
        read -s -p "Password: " password
        echo ""
        
        if [ -z "$password" ]; then
            echo "ERROR: Password cannot be empty" >&2
            return 1
        fi
        
        # Enable Samba user with the provided password
        echo -e "$password\n$password" | smbpasswd -a "$username" -s
    fi
    
    # Create Samba configuration for this user with strict security
    local smb_conf="/etc/samba/smb.conf.d/$username.conf"
    mkdir -p /etc/samba/smb.conf.d
    
    cat > "$smb_conf" << EOF
[$username-backup]
   path = /home/$username/uploads
   browseable = no
   writable = yes
   guest ok = no
   valid users = $username
   create mask = 0644
   directory mask = 0755
   force user = $username
   force group = backupusers
   # Strict security settings
   read only = no
   public = no
   printable = no
   store dos attributes = no
   map archive = no
   map hidden = no
   map system = no
   map readonly = no
   # VFS audit module for tracking SMB file operations
   vfs objects = full_audit
   full_audit:prefix = %u|%I|%m
   full_audit:success = connect disconnect write pwrite
   full_audit:failure = none
   full_audit:facility = local5
   full_audit:priority = notice
EOF
    
    # Update main smb.conf to include this user's config file
    update_samba_includes
    
    # Restart Samba services
    systemctl restart smbd nmbd
    
    echo "✓ Samba sharing enabled for user '$username'"
    echo "  Share name: //$HOSTNAME/$username-backup"
    echo "  Access credentials: $username / [provided password]"
}

# Disable Samba sharing for an existing user
disable_samba() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if Samba is enabled
    if ! has_samba_enabled "$username"; then
        echo "Samba sharing is not enabled for user '$username'"
        return 0
    fi
    
    echo "Disabling Samba sharing for user '$username'..."
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        return 1
    fi
    
    # Remove Samba user account
    smbpasswd -x "$username" 2>/dev/null || true
    
    # Remove Samba configuration file
    local smb_conf="/etc/samba/smb.conf.d/$username.conf"
    if [ -f "$smb_conf" ]; then
        rm -f "$smb_conf"
        echo "  Removed Samba configuration file"
    fi
    
    # Update main smb.conf to remove this user's include
    update_samba_includes
    
    # Restart Samba services
    systemctl restart smbd nmbd
    
    echo "✓ Samba sharing disabled for user '$username'"
}

# Enable read-only Samba access to versions (snapshots) directory
enable_samba_versions() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if user is in backupusers group
    if ! id "$username" | grep -q "backupusers"; then
        echo "Error: User '$username' is not a backup user" >&2
        return 1
    fi
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        echo "To enable Samba support, run setup.sh with the --samba option:"
        echo "  ./setup.sh --samba"
        return 1
    fi
    
    # Check if Samba user account exists
    if ! pdbedit -L | grep -q "^$username:"; then
        echo "ERROR: User '$username' does not have a Samba account."
        echo "Please run: $SCRIPT_NAME enable-samba $username"
        return 1
    fi
    
    # Check if versions directory exists
    if [ ! -d "/home/$username/versions" ]; then
        echo "ERROR: Versions directory does not exist for user '$username'"
        return 1
    fi
    
    # Check if already enabled (check in the user's main config file)
    local smb_conf="/etc/samba/smb.conf.d/${username}.conf"
    if grep -qF "[${username}-versions]" "$smb_conf" 2>/dev/null; then
        echo "Read-only SMB access to versions is already enabled for user '$username'"
        return 0
    fi
    
    echo "Enabling read-only SMB access to versions for user '$username'..."
    
    # Append versions share to the user's existing Samba config file
    # This ensures Samba loads it properly (same file as the backup share)
    mkdir -p /etc/samba/smb.conf.d
    
    cat >> "$smb_conf" << EOF

# Read-only access to backup snapshots for disaster recovery
[$username-versions]
   path = /home/$username/versions
   comment = Read-only backup snapshots for $username
   browseable = yes
   read only = yes
   writable = no
   guest ok = no
   valid users = $username
   force user = $username
   force group = backupusers
   # Strict security settings
   public = no
   printable = no
   create mask = 0000
   directory mask = 0000
   # VFS audit module for tracking access
   vfs objects = full_audit
   full_audit:prefix = %u|%I|%m|versions
   full_audit:success = connect disconnect
   full_audit:failure = none
   full_audit:facility = local5
   full_audit:priority = notice
EOF
    
    # Update main smb.conf to reload includes (picks up the new share)
    update_samba_includes
    
    # Restart Samba services (reload might not pick up new shares immediately)
    systemctl restart smbd nmbd
    
    echo "=========================================="
    echo "✓ Read-only SMB access to versions enabled"
    echo "=========================================="
    echo ""
    echo "Share details:"
    echo "  Share name: //$HOSTNAME/$username-versions"
    echo "  Path: /home/$username/versions"
    echo "  Access: Read-only"
    echo "  User: $username"
    echo ""
    echo "Windows access:"
    echo "  \\\\$HOSTNAME\\$username-versions"
    echo ""
    echo "Security notes:"
    echo "  • Snapshots are read-only and cannot be modified"
    echo "  • All access is logged via VFS audit"
    echo "  • SMB3 encryption is enforced"
    echo "  • Only user '$username' can access this share"
    echo ""
    echo "To disable: $SCRIPT_NAME disable-samba-versions $username"
}

# Disable read-only Samba access to versions directory
disable_samba_versions() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        return 1
    fi
    
    # Check if enabled (check in user's main config file)
    local smb_conf="/etc/samba/smb.conf.d/${username}.conf"
    if [ ! -f "$smb_conf" ] || ! grep -qF "[${username}-versions]" "$smb_conf" 2>/dev/null; then
        echo "Read-only SMB access to versions is not enabled for user '$username'"
        return 0
    fi
    
    echo "Disabling read-only SMB access to versions for user '$username'..."
    
    # Remove the versions share section from the user's config file
    # Use sed to delete from [username-versions] to the next section or EOF
    sed -i "/^\[${username}-versions\]/,/^\[/{ /^\[${username}-versions\]/d; /^\[/!d; }" "$smb_conf"
    # Also handle case where versions section is at the end of file (no next section)
    sed -i "/^\[${username}-versions\]/,\$d" "$smb_conf"
    
    echo "  Removed versions share from Samba configuration"
    
    # Update main smb.conf (no change needed as we still include the same file)
    # But we reload includes anyway for consistency
    update_samba_includes
    
    # Restart Samba services (reload doesn't always work for removing shares)
    systemctl restart smbd nmbd
    
    echo "✓ Read-only SMB access to versions disabled for user '$username'"
}

# Enable macOS Time Machine support for a user
enable_timemachine() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if user is in backupusers group
    if ! id "$username" | grep -q "backupusers"; then
        echo "Error: User '$username' is not a backup user" >&2
        return 1
    fi
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        echo "Time Machine requires Samba. Please run setup.sh first."
        return 1
    fi
    
    # Check if Samba is enabled first
    if ! has_samba_enabled "$username"; then
        echo "Error: Samba is not enabled for user '$username'"
        echo "Please enable Samba first: $SCRIPT_NAME enable-samba $username"
        return 1
    fi
    
    # Check if Time Machine is already enabled
    if has_timemachine_enabled "$username"; then
        echo "Time Machine support is already enabled for user '$username'"
        return 0
    fi
    
    echo "Enabling Time Machine support for user '$username'..."
    
    local home_dir="/home/${username}"
    local uploads_dir="${home_dir}/uploads"
    
    # Create Time Machine share configuration
    local smb_conf="/etc/samba/smb.conf.d/${username}.conf"
    cat >> "$smb_conf" <<EOF

[${username}-timemachine]
   comment = Time Machine Backup for ${username}
   path = ${uploads_dir}
   browseable = yes
   writable = yes
   read only = no
   create mask = 0700
   directory mask = 0700
   valid users = ${username}
   vfs objects = fruit streams_xattr full_audit
   fruit:aapl = yes
   fruit:time machine = yes
   fruit:time machine max size = 0
   # VFS audit module for tracking Time Machine connections
   full_audit:prefix = %u|%I|%m|timemachine
   full_audit:success = connect disconnect write pwrite
   full_audit:failure = connect
   full_audit:facility = local1
   full_audit:priority = notice
EOF
    
    echo "  Added Time Machine share to Samba configuration"
    
    # Update main smb.conf (no change needed as we still include the same file)
    # But we reload includes anyway for consistency
    update_samba_includes
    
    # Restart Samba services (reload doesn't always work for new shares)
    systemctl restart smbd nmbd
    
    echo "✓ Time Machine support enabled for user '$username'"
    echo ""
    echo "macOS Setup Instructions:"
    echo "1. Connect to the share in Finder first:"
    echo "   - Open Finder → Go → Connect to Server (or press Command+K)"
    echo "   - Enter: smb://<server-ip>/${username}-timemachine"
    echo "   - Click Connect and enter credentials:"
    echo "     Username: ${username}"
    echo "     Password: [user's Samba password]"
    echo ""
    echo "2. Configure Time Machine:"
    echo "   - Open System Preferences → Time Machine"
    echo "   - Click '+' (Add Disk) or 'Select Disk'"
    echo "   - Select '${username}-timemachine' from the list"
    echo "   - Time Machine will now use this network share for backups"
    echo ""
    echo "Note: termiNAS's monitoring service will automatically create snapshots"
    echo "      when Time Machine writes files to the uploads directory."
}

# Disable macOS Time Machine support for a user
disable_timemachine() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if Samba is installed
    if ! command -v smbpasswd &>/dev/null; then
        echo "ERROR: Samba is not installed on this server."
        return 1
    fi
    
    # Check if enabled (check in user's main config file)
    local smb_conf="/etc/samba/smb.conf.d/${username}.conf"
    if [ ! -f "$smb_conf" ] || ! grep -qF "[${username}-timemachine]" "$smb_conf" 2>/dev/null; then
        echo "Time Machine support is not enabled for user '$username'"
        return 0
    fi
    
    echo "Disabling Time Machine support for user '$username'..."
    
    # Remove the timemachine share section from the user's config file
    # Use sed to delete from [username-timemachine] to the next section or EOF
    sed -i "/^\[${username}-timemachine\]/,/^\[/{ /^\[${username}-timemachine\]/d; /^\[/!d; }" "$smb_conf"
    # Also handle case where timemachine section is at the end of file (no next section)
    sed -i "/^\[${username}-timemachine\]/,\$d" "$smb_conf"
    
    echo "  Removed Time Machine share from Samba configuration"
    
    # Update main smb.conf (no change needed as we still include the same file)
    # But we reload includes anyway for consistency
    update_samba_includes
    
    # Restart Samba services (reload doesn't always work for removing shares)
    systemctl restart smbd nmbd
    
    echo "✓ Time Machine support disabled for user '$username'"
    echo ""
    echo "Note: Existing backups in the uploads directory are not deleted."
    echo "      The user can still access files via SFTP or the main SMB share."
}

# Get quota information for a user
# Returns: used_bytes|limit_bytes|qgroup_id|total_bytes|is_blocked
# Uses level-0 qgroup on uploads subvolume for fast quota enforcement
# Hybrid mode: calculates total usage (uploads + snapshots) separately
get_user_quota() {
    local username="$1"
    local home_dir="/home/$username"
    
    # Check if quotas are enabled
    if ! btrfs qgroup show /home &>/dev/null; then
        return 1
    fi
    
    # Read user's uploads qgroup from config file (created by create_user.sh)
    local uploads_qgroup=""
    if [ -f "$home_dir/.terminas-qgroup" ]; then
        uploads_qgroup=$(cat "$home_dir/.terminas-qgroup" 2>/dev/null)
    fi
    
    # Fallback: try to determine qgroup from uploads subvolume
    if [ -z "$uploads_qgroup" ] || [[ "$uploads_qgroup" == 1/* ]]; then
        # Old format was level-1 qgroup (1/UID), need to look up level-0
        if [ -d "$home_dir/uploads" ]; then
            local uploads_subvol_id=$(btrfs subvolume show "$home_dir/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
            if [ -n "$uploads_subvol_id" ]; then
                uploads_qgroup="0/$uploads_subvol_id"
            fi
        fi
    fi
    
    if [ -z "$uploads_qgroup" ]; then
        return 1
    fi
    
    # Get usage from uploads subvolume (level-0 qgroup)
    local qgroup_info=$(btrfs qgroup show --raw /home 2>/dev/null | grep "^${uploads_qgroup}\s" || echo "")
    
    if [ -z "$qgroup_info" ]; then
        return 1
    fi
    
    # Use referenced bytes (column 2)
    local used_bytes=$(echo "$qgroup_info" | awk '{print $2}')
    
    # Get limit from uploads qgroup
    local limit_info=$(btrfs qgroup show --raw -r /home 2>/dev/null | grep "^${uploads_qgroup}\s" || echo "")
    local limit_bytes=""
    
    if [ -n "$limit_info" ]; then
        # Column 4 is max_rfer (referenced limit)
        limit_bytes=$(echo "$limit_info" | awk '{print $4}')
    fi
    
    # Check if limit is set (0, none, or empty means unlimited)
    if [ "$limit_bytes" = "0" ] || [ "$limit_bytes" = "none" ] || [ -z "$limit_bytes" ]; then
        limit_bytes="0"
    fi
    
    # Calculate total usage including snapshots (for hybrid quota display)
    local total_bytes="$used_bytes"
    if [ -d "$home_dir/versions" ]; then
        for snap in "$home_dir/versions"/*; do
            if [ -d "$snap" ]; then
                local snap_subvol_id=$(btrfs subvolume show "$snap" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
                if [ -n "$snap_subvol_id" ]; then
                    local snap_qgroup="0/$snap_subvol_id"
                    local snap_excl=$(btrfs qgroup show --raw -re /home 2>/dev/null | grep "^${snap_qgroup}\s" | awk '{print $2}' || echo "0")
                    total_bytes=$((total_bytes + snap_excl))
                fi
            fi
        done
    fi
    
    # Check if uploads are blocked (quota exceeded flag)
    local is_blocked="0"
    if [ -f "$home_dir/.terminas-quota-exceeded" ]; then
        is_blocked="1"
    fi
    
    # Return: used_bytes|limit_bytes|qgroup_id|total_bytes|is_blocked
    echo "${used_bytes}|${limit_bytes}|${uploads_qgroup}|${total_bytes}|${is_blocked}"
    return 0
}

# Set quota for a user
set_quota_user() {
    local username="$1"
    local quota_raw="$2"
    
    if [ -z "$username" ] || [ -z "$quota_raw" ]; then
        echo "Usage: $SCRIPT_NAME set-quota <username> <GB|MB>"
        return 1
    fi
    
    local parsed_quota
    if ! parsed_quota=$(parse_quota_value "$quota_raw"); then
        echo "ERROR: Quota must be a positive integer with optional unit (e.g., 50, 50GB, 13000MB)"
        return 1
    fi

    local quota_bytes=$(echo "$parsed_quota" | cut -d'|' -f1)
    local quota_amount=$(echo "$parsed_quota" | cut -d'|' -f2)
    local quota_unit=$(echo "$parsed_quota" | cut -d'|' -f3)
    local quota_display=$(echo "$parsed_quota" | cut -d'|' -f4)

    if [ "$quota_amount" -le 0 ] 2>/dev/null; then
        echo "ERROR: Quota must be greater than zero"
        return 1
    fi
    
    # Verify user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist"
        return 1
    fi
    
    # Check if user is a backup user
    if ! groups "$username" 2>/dev/null | grep -q "backupusers"; then
        echo "ERROR: User '$username' is not a backup user"
        return 1
    fi
    
    # Check if quotas are enabled
    if ! btrfs qgroup show /home &>/dev/null; then
        echo "ERROR: Btrfs quotas are not enabled on /home"
        echo "Run setup.sh to enable quotas, or manually: btrfs quota enable --simple /home"
        return 1
    fi
    
    local home_dir="/home/$username"
    
    # Get uploads subvolume qgroup
    local uploads_qgroup=""
    if [ -d "$home_dir/uploads" ]; then
        local uploads_subvol_id=$(btrfs subvolume show "$home_dir/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
        if [ -n "$uploads_subvol_id" ]; then
            uploads_qgroup="0/$uploads_subvol_id"
        fi
    fi
    
    if [ -z "$uploads_qgroup" ]; then
        echo "ERROR: Could not determine uploads subvolume qgroup"
        echo "Ensure /home/$username/uploads exists and is a Btrfs subvolume"
        return 1
    fi
    
    # Set quota on uploads subvolume (fast, reliable)
    if btrfs qgroup limit "$quota_bytes" "$uploads_qgroup" /home 2>/dev/null; then
        echo "✓ Set quota limit for user '$username': ${quota_display} on uploads ($uploads_qgroup)"
    else
        echo "ERROR: Failed to set quota limit on uploads subvolume"
        return 1
    fi
    
    # Update stored qgroup reference
    echo "$uploads_qgroup" > "$home_dir/.terminas-qgroup"
    chown root:root "$home_dir/.terminas-qgroup"
    chmod 644 "$home_dir/.terminas-qgroup"
    
    # Update stored quota limit (for hybrid quota checking)
    # Store the configured quota with unit (legacy plain number = GB)
    if [ "$quota_unit" = "MB" ]; then
        echo "${quota_amount}MB" > "$home_dir/.terminas-quota-limit"
    else
        echo "$quota_amount" > "$home_dir/.terminas-quota-limit"
    fi
    chown root:root "$home_dir/.terminas-quota-limit"
    chmod 644 "$home_dir/.terminas-quota-limit"
    
    # Clear any quota exceeded flag
    rm -f "$home_dir/.terminas-quota-exceeded" 2>/dev/null || true
    
    # Show current usage
    local quota_info=$(get_user_quota "$username")
    if [ -n "$quota_info" ]; then
        local used_bytes=$(echo "$quota_info" | cut -d'|' -f1)
        local total_bytes=$(echo "$quota_info" | cut -d'|' -f4)
        local used_gb=$(printf "%.2f" $(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
        local total_gb=$(printf "%.2f" $(echo "scale=2; $total_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
        local usage_pct=$(printf "%.1f" $(echo "scale=1; ($total_bytes / $quota_bytes) * 100" | bc 2>/dev/null || echo "0"))
        echo "  Uploads usage: ${used_gb}GB"
        echo "  Total usage (uploads + snapshots): ${total_gb}GB (${usage_pct}%)"
    fi
}

# Remove quota for a user (set to unlimited)
remove_quota_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Usage: $SCRIPT_NAME remove-quota <username>"
        return 1
    fi
    
    # Verify user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist"
        return 1
    fi
    
    # Check if user is a backup user
    if ! groups "$username" 2>/dev/null | grep -q "backupusers"; then
        echo "ERROR: User '$username' is not a backup user"
        return 1
    fi
    
    # Check if quotas are enabled
    if ! btrfs qgroup show /home &>/dev/null; then
        echo "Btrfs quotas are not enabled - user already has unlimited storage"
        return 0
    fi
    
    local home_dir="/home/$username"
    
    # Get uploads subvolume qgroup
    local uploads_qgroup=""
    if [ -f "$home_dir/.terminas-qgroup" ]; then
        uploads_qgroup=$(cat "$home_dir/.terminas-qgroup" 2>/dev/null)
    fi
    
    # Fallback: determine from uploads subvolume
    if [ -z "$uploads_qgroup" ] || [[ "$uploads_qgroup" == 1/* ]]; then
        if [ -d "$home_dir/uploads" ]; then
            local uploads_subvol_id=$(btrfs subvolume show "$home_dir/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
            if [ -n "$uploads_subvol_id" ]; then
                uploads_qgroup="0/$uploads_subvol_id"
            fi
        fi
    fi
    
    if [ -z "$uploads_qgroup" ]; then
        echo "ERROR: Could not determine uploads subvolume qgroup"
        return 1
    fi
    
    # Remove quota from uploads subvolume
    if btrfs qgroup limit none "$uploads_qgroup" /home 2>/dev/null; then
        echo "✓ Removed quota limit for user '$username' (unlimited storage)"
    else
        echo "ERROR: Failed to remove quota limit"
        return 1
    fi
    
    # Update config files
    echo "$uploads_qgroup" > "$home_dir/.terminas-qgroup"
    echo "0" > "$home_dir/.terminas-quota-limit"
    rm -f "$home_dir/.terminas-quota-exceeded" 2>/dev/null || true
}

# Show quota usage and limit for a user
show_quota_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Usage: $SCRIPT_NAME show-quota <username>"
        return 1
    fi
    
    # Verify user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist"
        return 1
    fi
    
    # Check if user is a backup user
    if ! groups "$username" 2>/dev/null | grep -q "backupusers"; then
        echo "ERROR: User '$username' is not a backup user"
        return 1
    fi
    
    # Check if quotas are enabled
    if ! btrfs qgroup show /home &>/dev/null; then
        echo "=========================================="
        echo "Quota Status for: $username"
        echo "=========================================="
        echo ""
        echo "Quota: Not available (Btrfs quotas not enabled)"
        echo ""
        echo "To enable quotas, run: btrfs quota enable --simple /home"
        return 0
    fi
    
    local quota_info=$(get_user_quota "$username")
    
    echo "=========================================="
    echo "Quota Status for: $username"
    echo "=========================================="
    echo ""
    
    if [ -z "$quota_info" ]; then
        echo "Quota: Unlimited (no quota set)"
        echo ""
        echo "To set a quota: $SCRIPT_NAME set-quota $username <GB|MB>"
    else
        local used_bytes=$(echo "$quota_info" | cut -d'|' -f1)
        local limit_bytes=$(echo "$quota_info" | cut -d'|' -f2)
        local qgroup_id=$(echo "$quota_info" | cut -d'|' -f3)
        local total_bytes=$(echo "$quota_info" | cut -d'|' -f4)
        local is_blocked=$(echo "$quota_info" | cut -d'|' -f5)
        
        # Ensure values are numeric for calculations
        used_bytes=${used_bytes:-0}
        limit_bytes=${limit_bytes:-0}
        total_bytes=${total_bytes:-0}
        
        # Validate numeric values
        [[ ! "$used_bytes" =~ ^[0-9]+$ ]] && used_bytes=0
        [[ ! "$limit_bytes" =~ ^[0-9]+$ ]] && limit_bytes=0
        [[ ! "$total_bytes" =~ ^[0-9]+$ ]] && total_bytes=0
        
        # Get configured quota limit from file (for hybrid display)
        local home_dir="/home/$username"
        local quota_limit_raw="0"
        local quota_limit_bytes=0
        local quota_limit_display="0GB"
        if [ -f "$home_dir/.terminas-quota-limit" ]; then
            quota_limit_raw=$(cat "$home_dir/.terminas-quota-limit" 2>/dev/null || echo "0")
            local parsed_quota_file
            if parsed_quota_file=$(parse_quota_value "$quota_limit_raw"); then
                quota_limit_bytes=$(echo "$parsed_quota_file" | cut -d'|' -f1)
                quota_limit_display=$(echo "$parsed_quota_file" | cut -d'|' -f4)
            fi
        fi
        
        # Format bytes to GB
        local used_gb=$(printf "%.2f" $(echo "scale=2; $used_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
        local total_gb=$(printf "%.2f" $(echo "scale=2; $total_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
        
        if [ "$limit_bytes" = "0" ] && [ "$quota_limit_bytes" -eq 0 ]; then
            echo "Quota: Unlimited"
            echo "Uploads usage: ${used_gb}GB"
            echo "Total usage (uploads + snapshots): ${total_gb}GB"
        else
            local limit_gb=$(printf "%.2f" $(echo "scale=2; $limit_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
            
            # Show uploads quota status
            echo "Uploads Quota:"
            echo "  Limit: ${limit_gb}GB"
            echo "  Usage: ${used_gb}GB"
            
            # Show total quota status (hybrid)
            if [ "$quota_limit_bytes" -gt 0 ]; then
                local total_pct=$(printf "%.1f" $(echo "scale=1; ($total_bytes / $quota_limit_bytes) * 100" | bc 2>/dev/null || echo "0"))
                local total_available=$((quota_limit_bytes - total_bytes))
                local total_available_gb=$(printf "%.2f" $(echo "scale=2; $total_available / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0"))
                
                echo ""
                echo "Total Quota (uploads + snapshots):"
                echo "  Limit: ${quota_limit_display}"
                echo "  Usage: ${total_gb}GB (${total_pct}%)"
                
                if [ "$total_available" -gt 0 ]; then
                    echo "  Available: ${total_available_gb}GB"
                fi
                
                # Show warning/blocked status
                if [ "$is_blocked" = "1" ]; then
                    echo ""
                    echo "⛔ UPLOADS BLOCKED: Total usage exceeds quota limit!"
                    echo "   User must delete files from uploads folder to get under quota."
                    echo "   After next snapshot, uploads will be re-enabled automatically."
                elif [[ "$total_pct" =~ ^[0-9]+\.?[0-9]*$ ]] && [ $(echo "$total_pct > 90" | bc 2>/dev/null || echo 0) -eq 1 ]; then
                    echo ""
                    echo "⚠ WARNING: Total storage usage is above 90%"
                fi
            fi
        fi
        
        echo ""
        echo "Qgroup: $qgroup_id"
    fi
    
    echo ""
}

# List all backup users with their disk usage
# ---------------------------------------------------------------------------
# list / info
# ---------------------------------------------------------------------------
# `list` and `info` read exact sizes from the cache maintained by
# `refresh-sizes` (see the size-cache helpers in common.sh) instead of walking
# every file on each run, and use incremental journal caches for connection
# times. Walking large trees on every invocation used to take minutes.

# Determine the status text/color for a user from snapshot and connection times.
# Args: $1 = last snapshot date ("Never" or formatted), $2 = last snapshot epoch,
#       $3 = last connection epoch, $4 = current epoch
# Prints: "<status>|<ansi color or empty>"
compute_user_status() {
    local last_date="$1" last_epoch="$2" conn_epoch="$3" now="$4"
    local status="OK" status_color=""

    if [ "$last_date" = "Never" ] && [ "${conn_epoch:-0}" -eq 0 ]; then
        status="⚠ NEVER USED"
        status_color="\033[1;33m"
    elif [ "$last_date" = "Never" ]; then
        local conn_days=$(( (now - conn_epoch) / 86400 ))
        status="⚠ No snapshot (conn: ${conn_days}d)"
        status_color="\033[1;33m"
    elif [ "${last_epoch:-0}" -gt 0 ]; then
        local backup_days=$(( (now - last_epoch) / 86400 ))
        if [ "${conn_epoch:-0}" -gt "$last_epoch" ]; then
            if [ "$backup_days" -gt 15 ]; then
                status="✓ No changes (${backup_days}d)"
            else
                status="✓ OK (${backup_days}d)"
            fi
            status_color="\033[0;32m"
        else
            if [ "$backup_days" -gt 15 ]; then
                status="⚠ ${backup_days}d ago"
                status_color="\033[1;33m"
            else
                status="✓ OK (${backup_days}d)"
                status_color="\033[0;32m"
            fi
        fi
    fi

    echo "${status}|${status_color}"
}

# Determine the protocol column value for a user (SFTP, SMB+SFTP, SMB*TM+SFTP, ...)
get_user_protocol() {
    local user="$1"
    local protocol="SFTP"
    if has_samba_enabled "$user"; then
        local has_versions=no has_tm=no
        has_samba_versions_enabled "$user" 2>/dev/null && has_versions=yes
        has_timemachine_enabled "$user" 2>/dev/null && has_tm=yes
        if [ "$has_versions" = yes ] && [ "$has_tm" = yes ]; then
            protocol="SMB*TM+SFTP"
        elif [ "$has_versions" = yes ]; then
            protocol="SMB*+SFTP"
        elif [ "$has_tm" = yes ]; then
            protocol="SMBTM+SFTP"
        else
            protocol="SMB+SFTP"
        fi
    fi
    echo "$protocol"
}

# Print the "Connection Activity" block for a user (caches must be built first)
print_connection_activity() {
    local username="$1"
    local now
    now=$(date +%s)

    local conn_info
    conn_info=$(get_last_connection "$username")
    local last_conn="${conn_info%%|*}"
    local conn_epoch="${conn_info##*|}"

    echo "Connection Activity:"
    if [ "$last_conn" != "Never" ] && [ "${conn_epoch:-0}" -gt 0 ]; then
        local days_ago=$(( (now - conn_epoch) / 86400 ))
        local hours_ago=$(( (now - conn_epoch) / 3600 ))
        echo "  Last SFTP:       $last_conn"
        if [ "$hours_ago" -lt 24 ]; then
            echo "                   ${hours_ago} hours ago"
        else
            echo "                   ${days_ago} days ago"
        fi
    else
        echo "  Last SFTP:       Never"
    fi

    if has_samba_enabled "$username"; then
        local samba_info="${SAMBA_CONNECTION_CACHE[$username]}"
        local samba_conn="${samba_info%%|*}"
        local samba_epoch="${samba_info##*|}"
        if [ -n "$samba_info" ] && [ "${samba_epoch:-0}" -gt 0 ]; then
            local days_ago=$(( (now - samba_epoch) / 86400 ))
            local hours_ago=$(( (now - samba_epoch) / 3600 ))
            echo "  Last SMB:        $samba_conn"
            if [ "$hours_ago" -lt 24 ]; then
                echo "                   ${hours_ago} hours ago"
            else
                echo "                   ${days_ago} days ago"
            fi
        else
            echo "  Last SMB:        Never"
        fi
    fi
}

# Print the retention policy block for a user
print_retention_policy() {
    local username="$1"
    [ -f /etc/terminas-retention.conf ] || return 0
    source /etc/terminas-retention.conf

    # Replace dashes with underscores for valid bash variable names
    local safe_username="${username//-/_}"
    local user_daily_var="${safe_username}_KEEP_DAILY"
    local user_weekly_var="${safe_username}_KEEP_WEEKLY"
    local user_monthly_var="${safe_username}_KEEP_MONTHLY"
    local user_retention_var="${safe_username}_RETENTION_DAYS"
    local user_advanced_var="${safe_username}_ENABLE_ADVANCED_RETENTION"

    if [ -n "${!user_daily_var}" ] || [ -n "${!user_weekly_var}" ] || [ -n "${!user_monthly_var}" ] || \
       [ -n "${!user_retention_var}" ] || [ -n "${!user_advanced_var}" ]; then
        echo "Retention Policy: Custom"
        [ -n "${!user_advanced_var}" ] && echo "  Advanced: ${!user_advanced_var}"
        [ -n "${!user_daily_var}" ] && echo "  Keep daily: ${!user_daily_var}"
        [ -n "${!user_weekly_var}" ] && echo "  Keep weekly: ${!user_weekly_var}"
        [ -n "${!user_monthly_var}" ] && echo "  Keep monthly: ${!user_monthly_var}"
        [ -n "${!user_retention_var}" ] && echo "  Retention days: ${!user_retention_var}"
    else
        echo "Retention Policy: Default (from /etc/terminas-retention.conf)"
    fi
    return 0
}

# Print a notice when Btrfs reports its quota accounting as inconsistent
print_qgroup_inconsistency_note() {
    if [ "${QGROUP_INCONSISTENT:-false}" = true ]; then
        echo ""
        echo -e "\033[1;33m⚠ Btrfs reports quota accounting as inconsistent.\033[0m"
        echo "  With simple quotas this is expected when data existed before quotas were enabled:"
        echo "  such extents are never attributed, so quota usage figures only cover data written"
        echo "  after enablement (sizes from refresh-sizes are exact). Do NOT toggle quotas"
        echo "  off/on to fix it - that resets attribution for ALL current data."
    fi
    return 0
}

# List users; sizes read from the size cache written by
# `refresh-sizes` (exact figures, computed in the background). Rows whose data
# changed since the cache was computed are marked with '*'.
list_users() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --refresh|-r) FAST_REFRESH_CONNECTIONS=true ;;
            *) echo "Error: unknown option '$arg' for list" >&2; return 1 ;;
        esac
    done

    local users
    users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo "No backup users found."
        return
    fi

    local any_samba=false
    local user
    while IFS= read -r user; do
        if [ -n "$user" ] && has_samba_enabled "$user"; then
            any_samba=true
            break
        fi
    done <<< "$users"

    echo "Backup Users:"
    if [ "$any_samba" = true ]; then
        echo "======================================================================================================================================================================================================"
        printf "%-16s %12s %12s %6s %12s %23s %20s %20s %10s\n" "Username" "Size(MB)" "Apparent" "Snaps" "Protocol" "Last Snapshot" "Last SFTP" "Last SMB" "Status"
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    else
        echo "======================================================================================================================================"
        printf "%-16s %12s %12s %6s %12s %23s %23s %10s\n" "Username" "Size(MB)" "Apparent" "Snaps" "Protocol" "Last Snapshot" "Last SFTP" "Status"
        echo "--------------------------------------------------------------------------------------------------------------------------------------"
    fi

    build_connection_cache_fast
    if [ "$any_samba" = true ]; then
        build_samba_connection_cache_fast
    fi
    build_uploads_generation_cache /home

    local total_actual_bytes=0 total_apparent_bytes=0 total_users=0
    local missing=0 stale=0
    local oldest_computed=0 newest_computed=0
    local now
    now=$(date +%s)

    while IFS= read -r user; do
        [ -n "$user" ] || continue
        local home_dir="/home/$user"
        [ -d "$home_dir" ] || continue

        # Snapshot count and newest snapshot from a single directory listing
        local range
        range=$(get_snapshot_range "$home_dir/versions")
        local snapshot_count="${range%%|*}"
        local newest="${range##*|}"
        local last_date="Never" last_epoch=0
        if [ -n "$newest" ]; then
            local ts
            ts=$(snapshot_name_to_epoch "$newest")
            last_epoch="${ts%%|*}"
            if [ "$last_epoch" -gt 0 ]; then
                last_date=$(date -d "@$last_epoch" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "${ts#*|}")
            fi
        fi

        # Sizes from the cache; mark rows whose data changed since computed
        local actual_size="n/a" apparent_size="n/a" marker=""
        if read_size_cache "$user"; then
            local actual_bytes=$SC_PHYSICAL
            local apparent_bytes=$((SC_UP_LOGICAL + SC_SNAP_LOGICAL))
            local snapset
            snapset=$(get_snapshot_set "$user")
            if [ "${UPLOADS_GEN[$user]:-}" != "$SC_GEN" ] || [ "$snapset" != "$SC_SNAPSET" ]; then
                marker="*"
                stale=$((stale + 1))
            fi
            actual_size="$(bytes_to_mb "$actual_bytes")$marker"
            apparent_size="$(bytes_to_mb "$apparent_bytes")$marker"
            total_actual_bytes=$((total_actual_bytes + actual_bytes))
            total_apparent_bytes=$((total_apparent_bytes + apparent_bytes))
            if [ "$oldest_computed" -eq 0 ] || [ "$SC_COMPUTED" -lt "$oldest_computed" ]; then
                oldest_computed=$SC_COMPUTED
            fi
            [ "$SC_COMPUTED" -gt "$newest_computed" ] && newest_computed=$SC_COMPUTED
        else
            missing=$((missing + 1))
        fi

        local conn_info
        conn_info=$(get_last_connection "$user")
        local display_sftp="${conn_info%%|*}"
        local conn_epoch="${conn_info##*|}"

        local status_info
        status_info=$(compute_user_status "$last_date" "$last_epoch" "$conn_epoch" "$now")
        local status="${status_info%%|*}"
        local status_color="${status_info#*|}"

        local display_smb="N/A"
        if [ "$any_samba" = true ] && has_samba_enabled "$user"; then
            local smb_info
            smb_info=$(get_last_samba_connection "$user")
            display_smb="${smb_info%%|*}"
        fi

        local protocol
        protocol=$(get_user_protocol "$user")

        if [ "$any_samba" = true ]; then
            if [ -n "$status_color" ]; then
                printf "%-16s %12s %12s %6s %12s %23s %20s %20s ${status_color}%12s\033[0m\n" "$user" "$actual_size" "$apparent_size" "$snapshot_count" "$protocol" "$last_date" "$display_sftp" "$display_smb" "$status"
            else
                printf "%-16s %12s %12s %6s %12s %23s %20s %20s %12s\n" "$user" "$actual_size" "$apparent_size" "$snapshot_count" "$protocol" "$last_date" "$display_sftp" "$display_smb" "$status"
            fi
        else
            if [ -n "$status_color" ]; then
                printf "%-16s %12s %12s %6s %12s %23s %23s ${status_color}%12s\033[0m\n" "$user" "$actual_size" "$apparent_size" "$snapshot_count" "$protocol" "$last_date" "$display_sftp" "$status"
            else
                printf "%-16s %12s %12s %6s %12s %23s %23s %12s\n" "$user" "$actual_size" "$apparent_size" "$snapshot_count" "$protocol" "$last_date" "$display_sftp" "$status"
            fi
        fi

        total_users=$((total_users + 1))
    done <<< "$users"

    if [ "$any_samba" = true ]; then
        echo "------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
    else
        echo "--------------------------------------------------------------------------------------------------------------------------------------"
    fi
    printf "%-16s %12s %12s %6s %12s\n" "Total: $total_users" "$(bytes_to_mb "$total_actual_bytes")" "$(bytes_to_mb "$total_apparent_bytes")" "" ""

    echo ""
    echo "Note: Size(MB) shows physical disk usage with Btrfs deduplication"
    echo "      Apparent shows logical size (sum of all files as if independent copies)"
    echo "      The difference shows space saved by Btrfs CoW snapshots"
    if [ "$oldest_computed" -gt 0 ]; then
        echo "      Sizes are cached by 'refresh-sizes'; computed between $(date -d "@$oldest_computed" "+%Y-%m-%d %H:%M") and $(date -d "@$newest_computed" "+%Y-%m-%d %H:%M")"
    fi
    if [ "$stale" -gt 0 ]; then
        echo "      * = data changed since the size was computed ($stale user(s); run: $SCRIPT_NAME refresh-sizes)"
    fi
    local asof
    if asof=$(connection_state_asof); then
        echo "      Connection times as of $asof (reused for up to $(( ${TERMINAS_CONNECTION_CACHE_TTL:-900} / 60 )) min; force with: $SCRIPT_NAME list --refresh)"
    fi
    if [ "$missing" -gt 0 ]; then
        echo "      n/a = no cached size yet for $missing user(s); run: $SCRIPT_NAME refresh-sizes"
    fi
    echo "      Protocol shows available access methods (SFTP or SMB+SFTP)"
    echo "      SMB* = Read-only versions access enabled (disable with 'disable-samba-versions <user>')"
    echo "      Last Snapshot shows when the most recent snapshot was created"
    echo "      Last SFTP shows most recent SSH/SFTP authentication"
    if [ "$any_samba" = true ]; then
        echo "      Last SMB shows most recent Samba/SMB connection (N/A if Samba not enabled for user)"
    fi
    echo "      Status meanings:"
    echo "        ✓ OK           = Recent snapshot or connection with no changes (good!)"
    echo "        ✓ No changes   = Backup job running but no file changes detected"
    echo "        ⚠ NEVER USED   = User never connected"
    echo "        ⚠ No snapshot  = Connected but no snapshot created yet"
    echo "        ⚠ Xd ago       = Last snapshot more than 15 days old"
    return 0
}

# Per-user detail with cached exact sizes plus the quota-accounting
# view (Referenced/Exclusive per snapshot) for cross-checking.
info_user() {
    local username="$1"
    shift
    local arg
    for arg in "$@"; do
        case "$arg" in
            --refresh|-r) FAST_REFRESH_CONNECTIONS=true ;;
            *) echo "Error: unknown option '$arg' for info" >&2; exit 1 ;;
        esac
    done

    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        usage
        exit 1
    fi
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        exit 1
    fi
    local home_dir="/home/$username"
    if [ ! -d "$home_dir" ]; then
        echo "Error: Home directory not found for user '$username'" >&2
        exit 1
    fi

    echo "User Information: $username"
    echo "========================================"
    echo "UID: $(id -u "$username")"
    echo "Groups: $(groups "$username" | cut -d: -f2)"
    echo "Home: $home_dir"
    echo ""

    build_connection_cache_fast
    if has_samba_enabled "$username"; then
        build_samba_connection_cache_fast
    fi
    print_connection_activity "$username"
    echo ""

    # Cached exact sizes
    build_uploads_generation_cache /home
    if read_size_cache "$username"; then
        local total_logical=$((SC_UP_LOGICAL + SC_SNAP_LOGICAL))
        local space_saved=$((total_logical - SC_PHYSICAL))
        # Physical can slightly exceed logical (metadata, small-file overhead)
        [ "$space_saved" -lt 0 ] && space_saved=0
        local efficiency_pct="0.0"
        if [ "$total_logical" -gt 0 ]; then
            efficiency_pct=$(awk -v s="$space_saved" -v l="$total_logical" 'BEGIN { printf "%.1f", (s / l) * 100 }')
        fi
        echo "Disk Usage (computed $(date -d "@$SC_COMPUTED" "+%Y-%m-%d %H:%M")):"
        echo "  Uploads:            $(bytes_to_mb "$SC_UP_LOGICAL") MB (current files)"
        echo "  Snapshots (${SC_SNAP_COUNT}):       $(bytes_to_mb "$SC_SNAP_LOGICAL") MB (logical size)"
        echo "  Total logical:      $(bytes_to_mb "$total_logical") MB (sum of all files)"
        echo "  Physical usage:     $(bytes_to_mb "$SC_PHYSICAL") MB (with Btrfs deduplication)"
        echo "  Space saved:        $(bytes_to_mb "$space_saved") MB (${efficiency_pct}% efficient)"
        local snapset
        snapset=$(get_snapshot_set "$username")
        if [ "${UPLOADS_GEN[$username]:-}" != "$SC_GEN" ] || [ "$snapset" != "$SC_SNAPSET" ]; then
            echo "  ⚠ Data changed since these figures were computed - run: $SCRIPT_NAME refresh-sizes $username"
        fi
    else
        echo "Disk Usage: not cached yet - run: $SCRIPT_NAME refresh-sizes $username"
    fi
    echo ""

    # Quota information (same helper as `info`)
    local quota_info
    quota_info=$(get_user_quota "$username")
    if [ -n "$quota_info" ]; then
        local used_bytes="${quota_info%%|*}"
        local limit_bytes
        limit_bytes=$(echo "$quota_info" | cut -d'|' -f2)
        local used_gb
        used_gb=$(awk -v b="$used_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
        if [ "$limit_bytes" = "0" ] || ! [[ "$limit_bytes" =~ ^[0-9]+$ ]]; then
            echo "Storage Quota: Unlimited (${used_gb}GB used)"
        else
            local limit_gb usage_pct available_gb
            limit_gb=$(awk -v b="$limit_bytes" 'BEGIN { printf "%.2f", b / 1073741824 }')
            usage_pct=$(awk -v u="$used_bytes" -v l="$limit_bytes" 'BEGIN { printf "%.1f", (u / l) * 100 }')
            available_gb=$(awk -v u="$used_bytes" -v l="$limit_bytes" 'BEGIN { printf "%.2f", (l - u) / 1073741824 }')
            echo "Storage Quota: ${used_gb}GB / ${limit_gb}GB (${usage_pct}% used, ${available_gb}GB available)"
            if [ "$(awk -v p="$usage_pct" 'BEGIN { print (p > 90) ? 1 : 0 }')" -eq 1 ]; then
                echo "  ⚠ WARNING: Quota usage above 90%"
            fi
        fi
    else
        echo "Storage Quota: Unlimited (no quota set)"
    fi
    if [ -f "$home_dir/.terminas-quota-exceeded" ]; then
        echo "  ⚠ Uploads are currently BLOCKED (.terminas-quota-exceeded present)"
    fi
    echo ""

    # Snapshot statistics with cached logical size and quota-accounting view
    local versions_dir="$home_dir/versions"
    local range
    range=$(get_snapshot_range "$versions_dir")
    local snapshot_count="${range%%|*}"
    local rest="${range#*|}"
    local oldest="${rest%%|*}"
    local newest="${rest##*|}"

    echo "Snapshots: $snapshot_count"
    if [ "$snapshot_count" -gt 0 ]; then
        local ts
        ts=$(snapshot_name_to_epoch "$oldest")
        echo "  Oldest:  $oldest"
        echo "           Created: ${ts#*|}"
        ts=$(snapshot_name_to_epoch "$newest")
        echo "  Newest:  $newest"
        echo "           Created: ${ts#*|}"
        echo ""

        local have_qgroups=false
        build_qgroup_usage_cache /home && have_qgroups=true
        printf "  %-21s %12s %9s %14s %14s\n" "Snapshot" "Logical(MB)" "Files" "Referenced(MB)" "Exclusive(MB)"
        local d name key entry logical_col files_col rfer_col excl_col
        for d in "$versions_dir"/*/; do
            [ -d "$d" ] || continue
            name="${d%/}"; name="${name##*/}"
            [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || continue
            logical_col="n/a"; files_col="n/a"; rfer_col="n/a"; excl_col="n/a"
            if [ -s "$TERMINAS_CACHE_DIR/snapshots/$username/$name" ]; then
                entry=$(cat "$TERMINAS_CACHE_DIR/snapshots/$username/$name")
                logical_col=$(bytes_to_mb "${entry%%|*}")
                files_col="${entry##*|}"
            fi
            key="$username/$name"
            if [ "$have_qgroups" = true ] && [ -n "${QG_SNAP_RFER_BY_NAME[$key]+set}" ]; then
                rfer_col=$(bytes_to_mb "${QG_SNAP_RFER_BY_NAME[$key]}")
                excl_col=$(bytes_to_mb "${QG_SNAP_EXCL_BY_NAME[$key]}")
            fi
            printf "  %-21s %12s %9s %14s %14s\n" "$name" "$logical_col" "$files_col" "$rfer_col" "$excl_col"
        done
        echo "  (Referenced/Exclusive come from simple-quota accounting and only cover data written after quotas were enabled)"
    fi
    echo ""

    if read_size_cache "$username"; then
        echo "Current uploads: $SC_UP_FILES files (as of $(date -d "@$SC_COMPUTED" "+%Y-%m-%d %H:%M"))"
    else
        echo "Current uploads: not cached yet"
    fi
    echo ""

    print_retention_policy "$username"
    print_qgroup_inconsistency_note
    return 0
}

# Compute exact sizes for one user into the cache. Skips the expensive work
# when nothing changed since the last run (uploads generation and snapshot set
# unchanged) unless force=true. Snapshots are only ever computed once.
# Usage: refresh_user_sizes <user> [force]
refresh_user_sizes() {
    local user="$1"
    local force="${2:-false}"
    local home_dir="/home/$user"

    if [ ! -d "$home_dir/uploads" ]; then
        echo "  $user: skipped (no uploads directory)"
        return 0
    fi

    local started
    started=$(date +%s)

    local snap_info
    snap_info=$(refresh_snapshot_size_cache "$user") || { echo "  $user: ERROR updating snapshot cache" >&2; return 1; }
    local snap_logical snap_files snap_count snap_new rest
    snap_logical="${snap_info%%|*}"; rest="${snap_info#*|}"
    snap_files="${rest%%|*}"; rest="${rest#*|}"
    snap_count="${rest%%|*}"; snap_new="${rest##*|}"

    local gen="${UPLOADS_GEN[$user]:-}"
    local snapset
    snapset=$(get_snapshot_set "$user")

    if [ "$force" != true ] && [ -n "$gen" ] && read_size_cache "$user" \
       && [ "$SC_GEN" = "$gen" ] && [ "$SC_SNAPSET" = "$snapset" ]; then
        echo "  $user: unchanged since $(date -d "@$SC_COMPUTED" "+%Y-%m-%d %H:%M") (generation $gen), kept"
        return 0
    fi

    local up_info
    up_info=$(get_tree_logical "$home_dir/uploads")
    local up_logical="${up_info%%|*}" up_files="${up_info##*|}"
    local physical
    physical=$(get_tree_physical_bytes "$home_dir")
    [[ "$physical" =~ ^[0-9]+$ ]] || physical=0

    write_size_cache "$user" "$physical" "$up_logical" "$up_files" "$snap_logical" "$snap_files" "$snap_count" "$gen" "$snapset" \
        || { echo "  $user: ERROR writing cache" >&2; return 1; }

    local elapsed=$(( $(date +%s) - started ))
    echo "  $user: physical $(bytes_to_mb "$physical") MB, uploads $(bytes_to_mb "$up_logical") MB ($up_files files), $snap_count snapshots ($snap_new newly computed) - ${elapsed}s"
    return 0
}

# refresh-sizes [username] [--force]
refresh_sizes() {
    local target="" force=false arg
    for arg in "$@"; do
        case "$arg" in
            --force|-f) force=true ;;
            *) target="$arg" ;;
        esac
    done

    if ! ensure_cache_dir; then
        echo "Error: cannot create cache directory $TERMINAS_CACHE_DIR" >&2
        return 1
    fi
    build_uploads_generation_cache /home

    local users
    if [ -n "$target" ]; then
        if ! id "$target" &>/dev/null; then
            echo "Error: User '$target' does not exist" >&2
            return 1
        fi
        users="$target"
    else
        users=$(get_backup_users)
    fi
    if [ -z "$users" ]; then
        echo "No backup users found."
        return 0
    fi

    echo "Refreshing size cache in $TERMINAS_CACHE_DIR ..."
    local started
    started=$(date +%s)
    local user failed=0
    while IFS= read -r user; do
        [ -n "$user" ] || continue
        refresh_user_sizes "$user" "$force" || failed=$((failed + 1))
    done <<< "$users"

    # Drop caches of users that no longer exist
    local f
    for f in "$TERMINAS_CACHE_DIR/sizes"/*; do
        [ -f "$f" ] || continue
        user=$(basename "$f")
        if ! id "$user" &>/dev/null; then
            remove_size_cache "$user"
            echo "  removed stale cache for deleted user $user"
        fi
    done

    echo "Refreshing connection caches from the journal..."
    local conn_started
    conn_started=$(date +%s)
    FAST_REFRESH_CONNECTIONS=true
    build_connection_cache_fast
    build_samba_connection_cache_fast
    echo "  connection caches refreshed in $(( $(date +%s) - conn_started ))s"

    echo "Done in $(( $(date +%s) - started ))s${failed:+ ($failed error(s))}"
    [ "$failed" -eq 0 ]
}

# ---------------------------------------------------------------------------
# status [--quiet]: health summary with a monitoring-friendly exit code
#   0 = OK, 1 = WARNING, 2 = CRITICAL   (Nagios/Icinga convention)
# --quiet prints only problems, so a cron entry mails you only when something
# is wrong:   */10 * * * * /opt/terminas/src/server/manage_users.sh status --quiet
# ---------------------------------------------------------------------------
STATUS_WORST=0
STATUS_QUIET=false
status_report() {
    local lvl="$1"; shift
    local tag
    case "$lvl" in 0) tag="[ OK ]" ;; 1) tag="[WARN]" ;; *) tag="[CRIT]" ;; esac
    [ "$lvl" -gt "$STATUS_WORST" ] && STATUS_WORST=$lvl
    if [ "$STATUS_QUIET" = false ] || [ "$lvl" -gt 0 ]; then
        echo "$tag $*"
    fi
}

# Read TERMINAS_* settings from the running unit (falls back to defaults)
status_monitor_setting() {
    local name="$1" default="$2"
    local v
    v=$(systemctl show -p Environment --value terminas-monitor.service 2>/dev/null | tr ' ' '\n' | grep "^${name}=" | tail -1 | cut -d= -f2)
    echo "${v:-$default}"
}

status_check() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --quiet|-q) STATUS_QUIET=true ;;
            *) echo "Error: unknown option '$arg' for status" >&2; return 2 ;;
        esac
    done

    local now
    now=$(date +%s)
    local rundir=/var/run/terminas
    local monitor_script=/var/terminas/scripts/terminas-monitor.sh
    local poll inactivity snap_interval
    poll=$(status_monitor_setting TERMINAS_POLL_INTERVAL 10)
    inactivity=$(status_monitor_setting TERMINAS_INACTIVITY_WINDOW 60)
    snap_interval=$(status_monitor_setting TERMINAS_SNAPSHOT_INTERVAL 1800)

    [ "$STATUS_QUIET" = false ] && echo "termiNAS health - $(date '+%Y-%m-%d %H:%M:%S') on $(hostname)"

    # --- monitor service ---
    local active since nrestarts
    active=$(systemctl is-active terminas-monitor.service 2>/dev/null || true)
    if [ "$active" = "active" ]; then
        since=$(systemctl show -p ActiveEnterTimestamp --value terminas-monitor.service 2>/dev/null | cut -d' ' -f2-3)
        nrestarts=$(systemctl show -p NRestarts --value terminas-monitor.service 2>/dev/null || echo 0)
        if [ "${nrestarts:-0}" -gt 0 ]; then
            status_report 1 "Monitor service active since $since, but restarted $nrestarts time(s) (journalctl -u terminas-monitor.service)"
        else
            status_report 0 "Monitor service active since $since"
        fi
    else
        status_report 2 "Monitor service is ${active:-not found} - snapshots are NOT being created (systemctl start terminas-monitor.service)"
    fi

    # --- monitor script version and liveness ---
    if [ ! -f "$monitor_script" ]; then
        status_report 2 "Monitor script missing ($monitor_script) - run setup.sh"
    elif ! grep -q 'generation polling' "$monitor_script"; then
        status_report 1 "Monitor script is the legacy inotify version - run setup.sh to upgrade"
    elif [ -f "$rundir/heartbeat" ]; then
        local hb_age=$(( now - $(stat -c %Y "$rundir/heartbeat" 2>/dev/null || echo 0) ))
        local hb_max=$(( poll * 6 + 120 ))
        if [ "$active" = "active" ] && [ "$hb_age" -gt "$hb_max" ]; then
            status_report 2 "Monitor loop stalled: last poll ${hb_age}s ago (expected every ${poll}s)"
        elif [ "$active" = "active" ]; then
            status_report 0 "Monitor loop alive: last poll ${hb_age}s ago"
        fi
    elif [ "$active" = "active" ]; then
        status_report 1 "No monitor heartbeat yet (monitor predates heartbeat support or just started - re-run setup.sh if this persists)"
    fi

    # --- uncaptured changes ---
    local f u p_since p_age pending=0 overdue=0 overdue_list=""
    local overdue_after=$(( snap_interval + inactivity + poll * 3 + 120 ))
    for f in "$rundir"/pending_*; do
        [ -f "$f" ] || continue
        u="${f##*/pending_}"
        p_since=$(cat "$f" 2>/dev/null || echo "$now")
        p_age=$(( now - p_since ))
        pending=$((pending + 1))
        if [ "$p_age" -gt "$overdue_after" ]; then
            overdue=$((overdue + 1))
            overdue_list="$overdue_list $u ($((p_age / 60)) min)"
        fi
    done
    if [ "$overdue" -gt 0 ]; then
        status_report 2 "Changes not snapshotted within the maximum interval:$overdue_list"
    elif [ "$pending" -gt 0 ]; then
        status_report 0 "$pending user(s) with changes waiting for the inactivity window"
    else
        status_report 0 "No uncaptured changes"
    fi

    # --- snapshot activity from the log ---
    local last_snap count24
    if [ -f /var/log/terminas.log ]; then
        last_snap=$(grep 'Btrfs snapshot created for' /var/log/terminas.log | tail -1 | sed -E 's/^([0-9-]+ [0-9:]+) Btrfs snapshot created for ([^ ]+) .*/\1 (\2)/')
        count24=$(awk -v since="$(date -d '24 hours ago' '+%F %T')" '/Btrfs snapshot created for/ && ($1 " " $2) >= since' /var/log/terminas.log | wc -l)
        if [ -n "$last_snap" ]; then
            status_report 0 "Last snapshot: $last_snap; $count24 snapshot(s) in the last 24h"
        else
            status_report 1 "No snapshot recorded in /var/log/terminas.log"
        fi
    else
        status_report 1 "Log file /var/log/terminas.log not found"
    fi

    # --- quota-blocked users ---
    local blocked=""
    for f in /home/*/.terminas-quota-exceeded; do
        [ -f "$f" ] || continue
        u="${f#/home/}"; u="${u%%/*}"
        blocked="$blocked $u"
    done
    if [ -n "$blocked" ]; then
        status_report 1 "Uploads blocked (over quota):$blocked"
    else
        status_report 0 "No users blocked by quota"
    fi

    # --- disk space on /home ---
    local warn_pct="${TERMINAS_DISK_WARN_PCT:-80}" crit_pct="${TERMINAS_DISK_CRIT_PCT:-95}"
    local df_line used size pct
    df_line=$(df -h /home 2>/dev/null | awk 'NR==2 {print $3 "|" $2 "|" $5}')
    used="${df_line%%|*}"; size=$(echo "$df_line" | cut -d'|' -f2); pct="${df_line##*|}"; pct="${pct%\%}"
    if [ -n "$pct" ] && [ "$pct" -ge "$crit_pct" ] 2>/dev/null; then
        status_report 2 "/home is ${pct}% full ($used of $size)"
    elif [ -n "$pct" ] && [ "$pct" -ge "$warn_pct" ] 2>/dev/null; then
        status_report 1 "/home is ${pct}% full ($used of $size)"
    else
        status_report 0 "/home usage ${pct:-?}% ($used of $size)"
    fi

    # --- scheduled maintenance ---
    local cron
    cron=$(crontab -l 2>/dev/null || true)
    if ! echo "$cron" | grep -q 'terminas-cleanup.sh'; then
        status_report 1 "Retention cleanup cron job missing (run setup.sh)"
    elif [ -f /var/log/terminas.log ]; then
        local last_cleanup
        last_cleanup=$(grep '\[CLEANUP\] All maintenance tasks completed' /var/log/terminas.log | tail -1 | cut -c1-16)
        if [ -z "$last_cleanup" ]; then
            status_report 1 "Retention cleanup has not completed yet (first run at 03:00)"
        elif [ $(( now - $(date -d "$last_cleanup" +%s 2>/dev/null || echo 0) )) -gt $(( 26 * 3600 )) ]; then
            status_report 1 "Retention cleanup last completed $last_cleanup (more than 26h ago)"
        else
            status_report 0 "Retention cleanup last completed $last_cleanup"
        fi
    fi
    if ! echo "$cron" | grep -q 'refresh-sizes'; then
        status_report 1 "Size-cache refresh cron job missing (run setup.sh)"
    elif [ -f /var/log/terminas-refresh-sizes.log ]; then
        local rs_age=$(( now - $(stat -c %Y /var/log/terminas-refresh-sizes.log) ))
        if [ "$rs_age" -gt $(( 26 * 3600 )) ]; then
            status_report 1 "Size cache last refreshed $((rs_age / 3600))h ago (cron at 03:30 may have failed)"
        else
            status_report 0 "Size cache refreshed $((rs_age / 3600))h ago"
        fi
    elif [ ! -d "$TERMINAS_CACHE_DIR/sizes" ] || [ -z "$(ls -A "$TERMINAS_CACHE_DIR/sizes" 2>/dev/null)" ]; then
        status_report 1 "Size cache empty - run: $SCRIPT_NAME refresh-sizes"
    else
        status_report 0 "Size cache present (nightly cron not run yet)"
    fi

    # --- supporting services ---
    if [ "$(systemctl is-active ssh.service 2>/dev/null || systemctl is-active sshd.service 2>/dev/null)" != "active" ]; then
        status_report 2 "SSH service is not active - clients cannot upload"
    else
        status_report 0 "SSH service active"
    fi
    if command -v fail2ban-client >/dev/null 2>&1; then
        if [ "$(systemctl is-active fail2ban 2>/dev/null)" = "active" ]; then
            status_report 0 "fail2ban active"
        else
            status_report 1 "fail2ban is not active"
        fi
    fi
    if has_samba_installed && ls /etc/samba/smb.conf.d/*.conf >/dev/null 2>&1; then
        if [ "$(systemctl is-active smbd 2>/dev/null)" = "active" ]; then
            status_report 0 "Samba active"
        else
            status_report 1 "Samba users are configured but smbd is not active"
        fi
    fi

    # --- Btrfs housekeeping ---
    local pending_del
    pending_del=$(btrfs subvolume list -d /home 2>/dev/null | grep -c DELETED || true)
    status_report 0 "Btrfs pending subvolume deletions: ${pending_del:-0}"
    if build_qgroup_usage_cache /home 2>/dev/null; then
        if [ "$QGROUP_INCONSISTENT" = true ]; then
            status_report 0 "Quota accounting: enabled (marked inconsistent - expected with pre-quota data)"
        else
            status_report 0 "Quota accounting: enabled"
        fi
    else
        status_report 1 "Btrfs quotas are not enabled on /home (quota limits are not enforced)"
    fi

    # --- overall ---
    local overall
    case "$STATUS_WORST" in 0) overall="OK" ;; 1) overall="WARNING" ;; *) overall="CRITICAL" ;; esac
    if [ "$STATUS_QUIET" = false ] || [ "$STATUS_WORST" -gt 0 ]; then
        echo "Overall: $overall"
    fi
    return "$STATUS_WORST"
}

# Show snapshot history for a user
history_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        usage
        exit 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        exit 1
    fi
    
    local versions_dir="/home/$username/versions"
    
    if [ ! -d "$versions_dir" ]; then
        echo "No versions directory found for user '$username'"
        return
    fi
    
    local snapshots=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
    local snapshot_count=$(echo "$snapshots" | grep -v '^$' | wc -l)
    
    if [ "$snapshot_count" -eq 0 ]; then
        echo "No snapshots found for user '$username'"
        return
    fi
    
    echo "Snapshot History for: $username"
    echo "========================================"
    printf "%-25s %15s %10s\n" "Snapshot" "Size (MB)" "Files"
    echo "----------------------------------------"
    
    while IFS= read -r snapshot; do
        if [ -z "$snapshot" ] || [ ! -d "$snapshot" ]; then
            continue
        fi
        
        local name=$(basename "$snapshot")
        local size=$(get_actual_size "$snapshot")
        local file_count=$(find "$snapshot" -type f 2>/dev/null | wc -l)
        
        printf "%-25s %15s %10s\n" "$name" "$size" "$file_count"
    done <<< "$snapshots"
    
    echo "----------------------------------------"
    echo "Total snapshots: $snapshot_count"
}

# Search for files across all users' latest snapshots
search_files() {
    local pattern="$1"
    
    if [ -z "$pattern" ]; then
        echo "Error: Search pattern is required" >&2
        usage
        exit 1
    fi
    
    echo "Searching for: $pattern"
    echo "========================================"
    
    local users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo "No backup users found."
        return
    fi
    
    local found=0
    
    while IFS= read -r user; do
        if [ -z "$user" ]; then
            continue
        fi
        
        local versions_dir="/home/$user/versions"
        if [ ! -d "$versions_dir" ]; then
            continue
        fi
        
        # Get latest snapshot
        local latest_snapshot=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
        if [ -z "$latest_snapshot" ]; then
            continue
        fi
        
        # Search in latest snapshot
        local results=$(find "$latest_snapshot" -type f -name "$pattern" 2>/dev/null)
        
        if [ -n "$results" ]; then
            echo ""
            echo "User: $user ($(basename "$latest_snapshot"))"
            echo "----------------------------------------"
            while IFS= read -r file; do
                if [ -n "$file" ]; then
                    local size=$(stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null)
                    local rel_path=${file#$latest_snapshot/}
                    printf "  %s (%s bytes)\n" "$rel_path" "$size"
                    found=$((found + 1))
                fi
            done <<< "$results"
        fi
    done <<< "$users"
    
    echo ""
    echo "========================================"
    echo "Found $found matching files"
}

# List inactive users (no recent uploads)
list_inactive() {
    local days="${1:-30}"
    
    echo "Users with no uploads in last $days days:"
    echo "========================================"
    printf "%-20s %25s %15s\n" "Username" "Last Activity" "Snapshots"
    echo "----------------------------------------"
    
    local users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo "No backup users found."
        return
    fi
    
    local now=$(date +%s)
    local cutoff=$((now - days * 86400))
    local inactive_count=0
    
    while IFS= read -r user; do
        if [ -z "$user" ]; then
            continue
        fi
        
        local home_dir="/home/$user"
        if [ ! -d "$home_dir/uploads" ]; then
            continue
        fi
        
        # Find most recent file modification in uploads
        local latest_file=$(find "$home_dir/uploads" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1)
        
        if [ -z "$latest_file" ]; then
            # No files in uploads - check versions
            local versions_dir="$home_dir/versions"
            if [ -d "$versions_dir" ]; then
                local latest_snapshot=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | tail -1)
                if [ -n "$latest_snapshot" ]; then
                    local snapshot_time=$(stat -c %Y "$latest_snapshot" 2>/dev/null || stat -f %m "$latest_snapshot" 2>/dev/null)
                    if [ "$snapshot_time" -lt "$cutoff" ]; then
                        local last_activity=$(date -d "@$snapshot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$snapshot_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                        local snapshot_count=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
                        printf "%-20s %25s %15s\n" "$user" "$last_activity" "$snapshot_count"
                        inactive_count=$((inactive_count + 1))
                    fi
                else
                    printf "%-20s %25s %15s\n" "$user" "Never" "0"
                    inactive_count=$((inactive_count + 1))
                fi
            else
                printf "%-20s %25s %15s\n" "$user" "Never" "0"
                inactive_count=$((inactive_count + 1))
            fi
        else
            local file_time=$(echo "$latest_file" | cut -d' ' -f1 | cut -d. -f1)
            if [ "$file_time" -lt "$cutoff" ]; then
                local last_activity=$(date -d "@$file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$file_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
                local snapshot_count=0
                if [ -d "$home_dir/versions" ]; then
                    snapshot_count=$(find "$home_dir/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
                fi
                printf "%-20s %25s %15s\n" "$user" "$last_activity" "$snapshot_count"
                inactive_count=$((inactive_count + 1))
            fi
        fi
    done <<< "$users"
    
    echo "----------------------------------------"
    echo "Total inactive users: $inactive_count"
}

# Restore files from a snapshot
restore_snapshot() {
    local username="$1"
    local snapshot_name="$2"
    local dest_path="$3"
    
    if [ -z "$username" ] || [ -z "$snapshot_name" ] || [ -z "$dest_path" ]; then
        echo "Error: Username, snapshot name, and destination path are required" >&2
        usage
        exit 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        exit 1
    fi
    
    local snapshot_dir="/home/$username/versions/$snapshot_name"
    
    if [ ! -d "$snapshot_dir" ]; then
        echo "Error: Snapshot '$snapshot_name' not found for user '$username'" >&2
        echo ""
        echo "Available snapshots:"
        find "/home/$username/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | xargs -n1 basename
        exit 1
    fi
    
    # Check if destination exists
    if [ -e "$dest_path" ]; then
        echo "Error: Destination '$dest_path' already exists" >&2
        echo "Please choose a different destination or remove the existing path" >&2
        exit 1
    fi
    
    echo "Restoring snapshot '$snapshot_name' for user '$username'..."
    echo "Source: $snapshot_dir"
    echo "Destination: $dest_path"
    echo ""
    
    # Create destination directory
    mkdir -p "$dest_path"
    
    # Copy files
    echo "Copying files..."
    rsync -av --progress "$snapshot_dir/" "$dest_path/" 2>&1 | tail -20
    
    if [ $? -eq 0 ]; then
        local file_count=$(find "$dest_path" -type f 2>/dev/null | wc -l)
        local total_size=$(du -sh "$dest_path" 2>/dev/null | cut -f1)
        echo ""
        echo "Restore completed successfully!"
        echo "Files restored: $file_count"
        echo "Total size: $total_size"
        echo "Location: $dest_path"
    else
        echo "Error: Restore failed" >&2
        exit 1
    fi
}

# Delete a user and all their files
delete_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        usage
        exit 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        exit 1
    fi
    
    # Check if user is in backupusers group
    if ! groups "$username" | grep -q backupusers; then
        echo "Error: User '$username' is not a backup user" >&2
        exit 1
    fi
    
    # Confirm deletion
    echo "WARNING: This will permanently delete user '$username' and ALL their data!"
    echo "This includes:"
    echo "  - User account"
    echo "  - /home/$username/uploads/"
    echo "  - /home/$username/versions/ (all snapshots)"
    echo ""
    read -p "Are you sure? Type 'yes' to confirm: " confirmation
    
    if [ "$confirmation" != "yes" ]; then
        echo "Deletion cancelled."
        exit 0
    fi
    
    echo "Deleting user '$username'..."
    
    # Kill any processes owned by the user
    pkill -u "$username" 2>/dev/null || true
    
    # Delete user account
    userdel "$username" 2>/dev/null || true
    
    # Remove Samba user if exists
    if command -v smbpasswd &>/dev/null; then
        smbpasswd -x "$username" 2>/dev/null || true
    fi
    
    # Remove Samba configuration
    if [ -f "/etc/samba/smb.conf.d/$username.conf" ]; then
        rm -f "/etc/samba/smb.conf.d/$username.conf"
        
        # Also remove from main smb.conf
        if [ -f /etc/samba/smb.conf ]; then
            # Remove the share section (from comment line to next blank line or EOF)
            sed -i "/^# Share for user: $username$/,/^$/d" /etc/samba/smb.conf
            # Fallback: remove share block if comment line doesn't exist
            sed -i "/^\[$username-backup\]$/,/^$/d" /etc/samba/smb.conf
        fi
        
        # Restart Samba to apply changes
        systemctl restart smbd 2>/dev/null || true
    fi
    
    # Remove home directory and all Btrfs subvolumes
    if [ -d "/home/$username" ]; then
        echo "Removing Btrfs subvolumes and data..."
        
        # Delete uploads subvolume
        if [ -d "/home/$username/uploads" ]; then
            if btrfs subvolume show "/home/$username/uploads" &>/dev/null; then
                echo "  Deleting uploads subvolume..."
                btrfs subvolume delete "/home/$username/uploads" >/dev/null 2>&1 || rm -rf "/home/$username/uploads"
            else
                rm -rf "/home/$username/uploads"
            fi
        fi
        
        # Delete all snapshot subvolumes in versions/
        if [ -d "/home/$username/versions" ]; then
            echo "  Deleting snapshot subvolumes..."
            local count=0
            for snapshot in /home/$username/versions/*; do
                if [ -d "$snapshot" ]; then
                    if btrfs subvolume show "$snapshot" &>/dev/null; then
                        # Make snapshot writable before deletion
                        btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
                        btrfs subvolume delete "$snapshot" >/dev/null 2>&1 && count=$((count + 1))
                    else
                        rm -rf "$snapshot" && count=$((count + 1))
                    fi
                fi
            done
            [ $count -gt 0 ] && echo "    Deleted $count snapshots"
            rmdir "/home/$username/versions" 2>/dev/null || rm -rf "/home/$username/versions"
        fi
        
        # Remove home directory
        rm -rf "/home/$username"
    fi
    
    # Remove any runtime files
    rm -f "/var/run/terminas/last_$username" 2>/dev/null || true
    
    echo "User '$username' and all their data have been deleted."
}

# Cleanup user: keep only latest snapshot with actual files
cleanup_user() {
    local username="$1"
    
    if [ -z "$username" ]; then
        echo "Error: Username is required" >&2
        usage
        exit 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        exit 1
    fi
    
    local home_dir="/home/$username"
    local versions_dir="$home_dir/versions"
    
    if [ ! -d "$versions_dir" ]; then
        echo "No versions directory found for user '$username'"
        return
    fi
    
    # Find all snapshots
    local snapshots=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    local snapshot_count=$(echo "$snapshots" | grep -v '^$' | wc -l)
    
    if [ "$snapshot_count" -eq 0 ]; then
        echo "No snapshots found for user '$username'"
        return
    fi
    
    if [ "$snapshot_count" -eq 1 ]; then
        echo "User '$username' has only one snapshot. Nothing to cleanup."
        return
    fi
    
    # Get latest snapshot
    local latest_snapshot=$(echo "$snapshots" | tail -1)
    local latest_name=$(basename "$latest_snapshot")
    
    echo "User: $username"
    echo "Total snapshots: $snapshot_count"
    echo "Latest snapshot: $latest_name"
    echo "Keeping latest snapshot and removing $((snapshot_count - 1)) older snapshot(s)..."
    
    # Calculate space before cleanup
    local size_before=$(get_actual_size "$versions_dir")
    
    # With Btrfs snapshots, we don't need to "consolidate" like with hardlinks
    # Just remove all old snapshots except the latest
    echo "Removing $((snapshot_count - 1)) old Btrfs snapshot(s)..."
    
    local removed=0
    while IFS= read -r snapshot; do
        if [ -n "$snapshot" ] && [ -d "$snapshot" ] && [ "$snapshot" != "$latest_snapshot" ]; then
            # Check if it's a Btrfs subvolume
            if btrfs subvolume show "$snapshot" &>/dev/null; then
                # Make snapshot writable before deletion
                btrfs property set -ts "$snapshot" ro false &>/dev/null || true
                if btrfs subvolume delete "$snapshot" &>/dev/null; then
                    removed=$((removed + 1))
                fi
            else
                # Fallback for non-subvolume directories
                rm -rf "$snapshot" && removed=$((removed + 1))
            fi
        fi
    done <<< "$snapshots"
    
    # Reclaim Btrfs space from deleted subvolumes (reuses function from delete_user.sh)
    if [ "$removed" -gt 0 ]; then
        reclaim_btrfs_space "$removed"
    fi
    
    # Calculate space after cleanup
    local size_after=$(get_actual_size "$versions_dir")
    local space_freed=$(echo "$size_before - $size_after" | bc)
    
    echo "Cleanup complete for user '$username'"
    echo "Removed $removed old snapshots"
    echo "Space before: ${size_before} MB"
    echo "Space after: ${size_after} MB"
    echo "Space freed: ${space_freed} MB"
    echo "Latest snapshot preserved: $latest_name"
}

# Check if user has open files in uploads directory
has_open_files() {
    local username="$1"
    local home_dir="/home/$username"
    local uploads_dir="$home_dir/uploads"
    
    if [ ! -d "$uploads_dir" ]; then
        return 1  # No uploads dir = no open files
    fi
    
    # Check for open files using lsof
    local open_files=$(lsof +D "$uploads_dir" 2>/dev/null | grep -E "\s+[0-9]+[uw]" || true)
    
    if [ -n "$open_files" ]; then
        return 0  # Has open files
    else
        return 1  # No open files
    fi
}

# Verify file integrity between uploads and snapshot
verify_snapshot_integrity() {
    local username="$1"
    local snapshot_path="$2"
    local uploads_dir="/home/$username/uploads"
    
    echo "Verifying file integrity..."
    
    # Count files in uploads
    local uploads_count=$(find "$uploads_dir" -type f 2>/dev/null | wc -l)
    local snapshot_count=$(find "$snapshot_path" -type f 2>/dev/null | wc -l)
    
    if [ "$uploads_count" -ne "$snapshot_count" ]; then
        echo "⚠ WARNING: File count mismatch! Uploads: $uploads_count, Snapshot: $snapshot_count"
        return 1
    fi
    
    echo "✓ File count matches: $uploads_count files"
    
    # Compare file sizes and checksums for each file
    local errors=0
    local checked=0
    
    while IFS= read -r upload_file; do
        if [ -f "$upload_file" ]; then
            local rel_path="${upload_file#$uploads_dir/}"
            local snapshot_file="$snapshot_path/$rel_path"
            
            if [ ! -f "$snapshot_file" ]; then
                echo "✗ Missing in snapshot: $rel_path"
                errors=$((errors + 1))
            else
                # Compare file sizes
                local upload_size=$(stat -c %s "$upload_file" 2>/dev/null || stat -f %z "$upload_file" 2>/dev/null)
                local snapshot_size=$(stat -c %s "$snapshot_file" 2>/dev/null || stat -f %z "$snapshot_file" 2>/dev/null)
                
                if [ "$upload_size" != "$snapshot_size" ]; then
                    echo "✗ Size mismatch: $rel_path (upload: $upload_size, snapshot: $snapshot_size)"
                    errors=$((errors + 1))
                fi
                
                checked=$((checked + 1))
            fi
        fi
    done < <(find "$uploads_dir" -type f 2>/dev/null)
    
    if [ "$errors" -eq 0 ]; then
        echo "✓ All $checked files verified successfully"
        return 0
    else
        echo "✗ Verification failed: $errors errors found"
        return 1
    fi
}

# Rebuild snapshots for a single user
rebuild_user() {
    local username="$1"
    local skip_confirmation="${2:-false}"  # Optional parameter, defaults to false
    
    # Validate user
    if ! id "$username" &>/dev/null; then
        echo "Error: User '$username' does not exist" >&2
        return 1
    fi
    
    # Check if user is a backup user
    local backup_users=$(get_backup_users)
    if ! echo "$backup_users" | grep -q "^${username}$"; then
        echo "Error: User '$username' is not a backup user" >&2
        return 1
    fi
    
    local home_dir="/home/$username"
    local uploads_dir="$home_dir/uploads"
    local versions_dir="$home_dir/versions"
    
    echo "=========================================="
    echo "Rebuilding snapshots for user: $username"
    echo "=========================================="
    
    # Confirmation prompt (skip if called from rebuild_all)
    if [ "$skip_confirmation" != "true" ]; then
        # Count existing snapshots for confirmation message
        local existing_count=0
        if [ -d "$versions_dir" ]; then
            existing_count=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        fi
        
        echo "WARNING: This will DELETE ALL existing snapshots for user '$username' and create a fresh one!"
        if [ "$existing_count" -gt 0 ]; then
            echo "Existing snapshots to be deleted: $existing_count"
        fi
        echo ""
        read -p "Are you sure you want to continue? (yes/no): " confirmation
        
        if [ "$confirmation" != "yes" ]; then
            echo "Rebuild cancelled for user '$username'."
            return 1
        fi
        echo ""
    fi
    
    # Check if uploads directory exists
    if [ ! -d "$uploads_dir" ]; then
        echo "⚠ WARNING: No uploads directory found for user '$username'"
        echo "Skipping this user."
        return 1
    fi
    
    # Check for open files
    if has_open_files "$username"; then
        echo "⚠ WARNING: User '$username' has files currently open in uploads directory"
        echo "Cannot rebuild while files are in progress. Skipping this user."
        local open_files=$(lsof +D "$uploads_dir" 2>/dev/null | grep -E "\s+[0-9]+[uw]" | awk '{print $NF}')
        echo "Open files:"
        echo "$open_files" | while IFS= read -r file; do
            if [ -n "$file" ]; then
                echo "  - ${file#$uploads_dir/}"
            fi
        done
        return 1
    fi
    
    # Check if uploads directory has any files
    local file_count=$(find "$uploads_dir" -type f 2>/dev/null | wc -l)
    if [ "$file_count" -eq 0 ]; then
        echo "⚠ WARNING: Uploads directory is empty for user '$username'"
        echo "Skipping this user."
        return 1
    fi
    
    echo "✓ No open files detected"
    echo "Files to snapshot: $file_count"
    
    # Delete all existing snapshots
    if [ -d "$versions_dir" ]; then
        local snapshots=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        local snapshot_count=$(echo "$snapshots" | grep -v '^$' | wc -l)
        
        if [ "$snapshot_count" -gt 0 ]; then
            echo "Deleting $snapshot_count existing snapshot(s)..."
            
            local deleted=0
            while IFS= read -r snapshot; do
                if [ -n "$snapshot" ] && [ -d "$snapshot" ]; then
                    # Try to make writable first if it's read-only
                    btrfs property set -ts "$snapshot" ro false &>/dev/null || true
                    
                    # Check if it's a Btrfs subvolume
                    if btrfs subvolume show "$snapshot" &>/dev/null; then
                        if btrfs subvolume delete "$snapshot" &>/dev/null; then
                            deleted=$((deleted + 1))
                            echo "  ✓ Deleted: $(basename "$snapshot")"
                        else
                            echo "  ✗ Failed to delete: $(basename "$snapshot")"
                        fi
                    else
                        # Fallback for non-subvolume directories
                        if rm -rf "$snapshot"; then
                            deleted=$((deleted + 1))
                            echo "  ✓ Deleted: $(basename "$snapshot")"
                        else
                            echo "  ✗ Failed to delete: $(basename "$snapshot")"
                        fi
                    fi
                fi
            done <<< "$snapshots"
            
            echo "Deleted $deleted snapshot(s)"
            
            # Reclaim Btrfs space from deleted subvolumes (reuses function from delete_user.sh)
            if [ "$deleted" -gt 0 ]; then
                reclaim_btrfs_space "$deleted"
            fi
        else
            echo "No existing snapshots to delete"
        fi
    else
        echo "Creating versions directory..."
        mkdir -p "$versions_dir"
        chown root:backupusers "$versions_dir"
        chmod 755 "$versions_dir"
    fi
    
    # Create fresh snapshot from uploads
    echo "Creating fresh snapshot from uploads directory..."
    
    local timestamp=$(date +%Y-%m-%d_%H-%M-%S)
    local snapshot_path="$versions_dir/$timestamp"
    
    # Check if uploads is a Btrfs subvolume
    if btrfs subvolume show "$uploads_dir" &>/dev/null; then
        # Create Btrfs snapshot
        if btrfs subvolume snapshot "$uploads_dir" "$snapshot_path" &>/dev/null; then
            echo "✓ Btrfs snapshot created: $timestamp"
            
            # Make snapshot read-only for ransomware protection
            if btrfs property set -ts "$snapshot_path" ro true &>/dev/null; then
                echo "✓ Snapshot set to read-only"
            else
                echo "⚠ WARNING: Failed to set snapshot as read-only"
            fi
            
            # Set ownership and permissions
            chown root:backupusers "$snapshot_path" 2>/dev/null || true
            chmod 755 "$snapshot_path" 2>/dev/null || true
            
            # Verify integrity
            if verify_snapshot_integrity "$username" "$snapshot_path"; then
                echo "✓ Snapshot rebuild completed successfully for user '$username'"
                return 0
            else
                echo "✗ Snapshot created but integrity verification failed"
                return 1
            fi
        else
            echo "✗ ERROR: Failed to create Btrfs snapshot"
            return 1
        fi
    else
        echo "✗ ERROR: Uploads directory is not a Btrfs subvolume"
        echo "This should not happen. Please check the user setup."
        return 1
    fi
}

# Rebuild snapshots for all users
rebuild_all() {
    echo "=========================================="
    echo "Rebuilding snapshots for all backup users"
    echo "=========================================="
    echo ""
    
    local users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo "No backup users found."
        return
    fi
    
    # Count total users and snapshots for confirmation
    local user_count=$(echo "$users" | grep -v '^$' | wc -l)
    local total_snapshots=0
    
    while IFS= read -r user; do
        if [ -n "$user" ] && [ -d "/home/$user/versions" ]; then
            local count=$(find "/home/$user/versions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
            total_snapshots=$((total_snapshots + count))
        fi
    done <<< "$users"
    
    # Confirmation prompt
    echo "WARNING: This will DELETE ALL existing snapshots for ALL backup users!"
    echo "Total users: $user_count"
    echo "Total snapshots to be deleted: $total_snapshots"
    echo "Each user will get a fresh snapshot created from their current uploads."
    echo ""
    read -p "Are you sure you want to continue? (yes/no): " confirmation
    
    if [ "$confirmation" != "yes" ]; then
        echo "Rebuild cancelled."
        return
    fi
    echo ""
    
    local processed=0
    local succeeded=0
    local skipped=0
    local failed=0
    
    while IFS= read -r user; do
        if [ -z "$user" ]; then
            continue
        fi
        
        processed=$((processed + 1))
        
        # Pass 'true' as second parameter to skip individual confirmation prompts
        if rebuild_user "$user" "true"; then
            succeeded=$((succeeded + 1))
        else
            # Check if it was skipped or failed
            if has_open_files "$user" 2>/dev/null; then
                skipped=$((skipped + 1))
            else
                failed=$((failed + 1))
            fi
        fi
        
        echo ""
    done <<< "$users"
    
    echo "=========================================="
    echo "Rebuild Summary"
    echo "=========================================="
    echo "Total users processed: $processed"
    echo "Successfully rebuilt: $succeeded"
    echo "Skipped (open files): $skipped"
    echo "Failed: $failed"
    echo "=========================================="
}

# Cleanup all backup users
cleanup_all() {
    echo "Cleaning up all backup users..."
    echo ""
    
    local users=$(get_backup_users)
    if [ -z "$users" ]; then
        echo "No backup users found."
        return
    fi
    
    local cleaned=0
    local skipped=0
    
    while IFS= read -r user; do
        if [ -z "$user" ]; then
            continue
        fi
        
        echo "----------------------------------------"
        cleanup_user "$user"
        cleaned=$((cleaned + 1))
        echo ""
    done <<< "$users"
    
    echo "========================================"
    echo "Cleanup summary:"
    echo "  Users processed: $cleaned"
    echo "========================================"
}

# Main script logic
check_root

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

command="$1"
shift

case "$command" in
    list|ls|list-fast|lsf)
        list_users "$@"
        ;;
    info|show|info-fast)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for info command" >&2
            usage
            exit 1
        fi
        info_user "$@"
        ;;
    refresh-sizes)
        refresh_sizes "$@"
        ;;
    status|health)
        status_check "$@"
        exit $?
        ;;
    history|hist)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for history command" >&2
            usage
            exit 1
        fi
        history_user "$1"
        ;;
    search|find)
        if [ $# -eq 0 ]; then
            echo "Error: Search pattern is required for search command" >&2
            usage
            exit 1
        fi
        search_files "$1"
        ;;
    inactive)
        list_inactive "$1"
        ;;
    restore)
        if [ $# -lt 3 ]; then
            echo "Error: Username, snapshot name, and destination are required for restore command" >&2
            usage
            exit 1
        fi
        restore_snapshot "$1" "$2" "$3"
        ;;
    delete|remove|del)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for delete command" >&2
            usage
            exit 1
        fi
        delete_user "$1"
        ;;
    cleanup)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for cleanup command" >&2
            usage
            exit 1
        fi
        cleanup_user "$1"
        ;;
    cleanup-all)
        cleanup_all
        ;;
    rebuild)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for rebuild command" >&2
            usage
            exit 1
        fi
        rebuild_user "$1"
        ;;
    rebuild-all)
        rebuild_all
        ;;
    set-quota)
        if [ $# -lt 2 ]; then
            echo "Error: Username and quota (GB or MB) are required for set-quota command" >&2
            echo "Usage: $SCRIPT_NAME set-quota <username> <GB|MB>" >&2
            exit 1
        fi
        set_quota_user "$1" "$2"
        ;;
    remove-quota)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for remove-quota command" >&2
            usage
            exit 1
        fi
        remove_quota_user "$1"
        ;;
    show-quota)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for show-quota command" >&2
            usage
            exit 1
        fi
        show_quota_user "$1"
        ;;
    enable-samba)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for enable-samba command" >&2
            usage
            exit 1
        fi
        enable_samba "$1"
        ;;
    disable-samba)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for disable-samba command" >&2
            usage
            exit 1
        fi
        disable_samba "$1"
        ;;
    enable-samba-versions)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for enable-samba-versions command" >&2
            usage
            exit 1
        fi
        enable_samba_versions "$1"
        ;;
    disable-samba-versions)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for disable-samba-versions command" >&2
            usage
            exit 1
        fi
        disable_samba_versions "$1"
        ;;
    enable-timemachine)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for enable-timemachine command" >&2
            usage
            exit 1
        fi
        enable_timemachine "$1"
        ;;
    disable-timemachine)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for disable-timemachine command" >&2
            usage
            exit 1
        fi
        disable_timemachine "$1"
        ;;
    show-pending-deletions)
        show_pending_deletions
        ;;
    force-clean)
        force_clean
        ;;
    change-password)
        if [ $# -eq 0 ]; then
            echo "Error: Username is required for change-password command" >&2
            usage
            exit 1
        fi
        change_password_user "$1"
        ;;
    version|--version|-v)
        echo "termiNAS User Management Tool v$VERSION"
        echo "Copyright (c) 2025 Yianni Bourkelis"
        echo "https://github.com/YiannisBourkelis/terminas"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo "Error: Unknown command '$command'" >&2
        echo ""
        usage
        exit 1
        ;;
esac