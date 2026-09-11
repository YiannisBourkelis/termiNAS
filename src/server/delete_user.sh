#!/bin/bash

# delete_user.sh - Delete a backup user and all their data
# Usage: sudo ./delete_user.sh <username>
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

set -e

# Reusable function for Btrfs space reclamation after subvolume deletion
# Can be sourced by other scripts (e.g., manage_users.sh)
# Args: $1 = number of deleted subvolumes (optional, for display only)
# Returns: 0 on success, 1 on failure
reclaim_btrfs_space() {
    local deleted_count="${1:-0}"

    # If no subvolumes were deleted in this operation, nothing to do
    if [ "$deleted_count" -eq 0 ]; then
        return 0
    fi

    # Non-blocking: commit deletion metadata and let the kernel cleaner work
    echo "Committing Btrfs deletions (non-blocking)..."
    if btrfs filesystem sync /home >/dev/null 2>&1; then
        echo "✓ Deletion committed; space will be reclaimed asynchronously"
    else
        echo "⚠ WARNING: 'btrfs filesystem sync /home' failed"
        echo "  Deletions are still marked; the kernel cleaner will reclaim space."
        echo "  Inspect pending deletions with: ./manage_users.sh show-pending-deletions"
    fi
    return 0
}

# Parse arguments
FORCE_DELETE=false
USERNAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --force|-f)
            FORCE_DELETE=true
            shift
            ;;
        *)
            USERNAME="$1"
            shift
            ;;
    esac
done

if [ -z "$USERNAME" ]; then
    echo "Usage: $0 [--force] <username>"
    echo ""
    echo "Options:"
    echo "  --force, -f    Skip confirmation prompt (use with caution!)"
    exit 1
fi

# Check if user exists
if ! id "$USERNAME" &>/dev/null; then
    echo "User $USERNAME does not exist."
    exit 1
fi

# Safety confirmation - require typing username (unless --force)
if [ "$FORCE_DELETE" = false ]; then
    echo ""
    echo "WARNING: This will permanently delete user '$USERNAME' and ALL backup data!"
    echo "This action CANNOT be undone."
    echo ""
    read -p "Type the username '$USERNAME' again to confirm deletion: " confirmation

    if [ "$confirmation" != "$USERNAME" ]; then
        echo "Username mismatch. Aborting deletion."
        exit 1
    fi
fi

echo ""
echo "Deleting user $USERNAME..."

# Kill the background monitoring subprocess for this user (runs as root)
# This stops any in-progress snapshot monitoring for the deleted user.
# Note: This does NOT clear inotify watches held by the main inotifywait process,
# which may cause pending Btrfs deletions until terminas-monitor.service restarts.
# Pending deletions are normal and do not affect functionality.
if [ -f "/var/run/terminas/processing_$USERNAME" ]; then
    monitor_pid=$(cat "/var/run/terminas/processing_$USERNAME" 2>/dev/null)
    if [ -n "$monitor_pid" ] && kill -0 "$monitor_pid" 2>/dev/null; then
        echo "Stopping background monitor process for $USERNAME (PID $monitor_pid)..."
        kill "$monitor_pid" 2>/dev/null || true
        
        # Wait up to 5 seconds for the process to exit
        for i in {1..10}; do
            if ! kill -0 "$monitor_pid" 2>/dev/null; then
                break
            fi
            sleep 0.5
        done
        
        # Force kill if still running
        if kill -0 "$monitor_pid" 2>/dev/null; then
            echo "  Force killing monitoring process..."
            kill -9 "$monitor_pid" 2>/dev/null || true
            sleep 0.5
        fi
    fi
    # Remove the lock file
    rm -f "/var/run/terminas/processing_$USERNAME" 2>/dev/null || true
fi

# Kill any processes owned by the user
pkill -u "$USERNAME" 2>/dev/null || true

# Remove Samba user if exists
if command -v smbpasswd &>/dev/null; then
    if pdbedit -L 2>/dev/null | grep -q "^$USERNAME:"; then
        echo "Removing Samba user..."
        smbpasswd -x "$USERNAME" 2>/dev/null || true
    fi
fi

# Remove Samba configuration file
if [ -f "/etc/samba/smb.conf.d/$USERNAME.conf" ]; then
    echo "Removing Samba configuration..."
    rm -f "/etc/samba/smb.conf.d/$USERNAME.conf"
    
    # Also remove from main smb.conf
    if [ -f /etc/samba/smb.conf ]; then
        # Remove the share section (from comment line to next blank line or EOF)
        sed -i "/^# Share for user: $USERNAME$/,/^$/d" /etc/samba/smb.conf
        # Fallback: remove share block if comment line doesn't exist
        sed -i "/^\[$USERNAME-backup\]$/,/^$/d" /etc/samba/smb.conf
    fi
    
    # Restart Samba to apply changes
    if systemctl is-active --quiet smbd; then
        systemctl restart smbd 2>/dev/null || true
        echo "  Restarted Samba service"
    fi
fi

# Remove quota from uploads subvolume
if btrfs qgroup show /home &>/dev/null; then
    # Read user's uploads qgroup from config file (created by create_user.sh)
    UPLOADS_QGROUP=""
    if [ -f "/home/$USERNAME/.terminas-qgroup" ]; then
        UPLOADS_QGROUP=$(cat "/home/$USERNAME/.terminas-qgroup" 2>/dev/null)
    fi
    
    if [ -n "$UPLOADS_QGROUP" ]; then
        # Remove quota limit
        btrfs qgroup limit none "$UPLOADS_QGROUP" /home 2>/dev/null || true
        echo "Removed quota from: $UPLOADS_QGROUP"
    fi
fi

# Remove the user (without -r since home is owned by root)
userdel "$USERNAME"

# Delete Btrfs subvolumes and directories
if [ -d "/home/$USERNAME" ]; then
    echo "Removing Btrfs subvolumes and data..."
    
    # Track total subvolumes deleted for space reclamation
    total_deleted=0
    
    # Delete uploads subvolume
    if [ -d "/home/$USERNAME/uploads" ]; then
        if btrfs subvolume show "/home/$USERNAME/uploads" &>/dev/null; then
            echo "  Deleting uploads subvolume..."
            if btrfs subvolume delete "/home/$USERNAME/uploads" >/dev/null 2>&1; then
                total_deleted=$((total_deleted + 1))
            else
                rm -rf "/home/$USERNAME/uploads"
            fi
        else
            rm -rf "/home/$USERNAME/uploads"
        fi
    fi
    
    # Delete all snapshot subvolumes in versions/
    if [ -d "/home/$USERNAME/versions" ]; then
        echo "  Deleting snapshot subvolumes..."
        count=0
        for snapshot in /home/$USERNAME/versions/*; do
            if [ -d "$snapshot" ]; then
                if btrfs subvolume show "$snapshot" &>/dev/null; then
                    # Make snapshot writable before deletion
                    btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
                    if btrfs subvolume delete "$snapshot" >/dev/null 2>&1; then
                        count=$((count + 1))
                        total_deleted=$((total_deleted + 1))
                    fi
                else
                    rm -rf "$snapshot" && count=$((count + 1))
                fi
            fi
        done
        [ $count -gt 0 ] && echo "    Deleted $count snapshots"
        rmdir "/home/$USERNAME/versions" 2>/dev/null || rm -rf "/home/$USERNAME/versions"
    fi
    
    # Reclaim Btrfs space from deleted subvolumes (uploads + snapshots)
    if [ $total_deleted -gt 0 ]; then
        echo "  Total subvolumes deleted in this operation: $total_deleted (uploads + snapshots)"
        reclaim_btrfs_space $total_deleted
    fi
    
    # Check if /home/<username> itself is a Btrfs subvolume (created by useradd -m on Btrfs)
    # If yes, delete it as a subvolume. If no, remove it as a regular directory.
    if btrfs subvolume show "/home/$USERNAME" &>/dev/null; then
        echo "  Deleting home directory subvolume..."
        if btrfs subvolume delete "/home/$USERNAME" >/dev/null 2>&1; then
            total_deleted=$((total_deleted + 1))
            echo "  ✓ Deleted home directory subvolume"
            # Reclaim space from the home directory subvolume deletion
            reclaim_btrfs_space 1
        else
            echo "  ⚠ WARNING: Failed to delete home directory subvolume, using rm -rf"
            rm -rf "/home/$USERNAME"
        fi
    else
        # Not a subvolume, remove as regular directory
        rm -rf "/home/$USERNAME"
    fi
fi

# Remove cached size figures (maintained by manage_users.sh refresh-sizes)
rm -f "/var/terminas/cache/sizes/$USERNAME" 2>/dev/null || true
rm -rf "/var/terminas/cache/snapshots/$USERNAME" 2>/dev/null || true

# Remove any runtime files
rm -f "/var/run/terminas/last_$USERNAME" 2>/dev/null || true
rm -f "/var/run/terminas/activity_$USERNAME" 2>/dev/null || true
rm -f "/var/run/terminas/snapshot_$USERNAME" 2>/dev/null || true
rm -f "/var/run/terminas/processing_$USERNAME" 2>/dev/null || true

echo "User $USERNAME and all their data have been deleted."