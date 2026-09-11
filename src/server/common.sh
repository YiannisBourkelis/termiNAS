#!/bin/bash

# common.sh - Shared functions for termiNAS server scripts
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Function to validate password strength
# Returns 0 if valid, 1 if invalid
# Usage: validate_password "password"
validate_password() {
    local password="$1"
    local length=${#password}
    
    # Check minimum length (30 characters)
    if [ "$length" -lt 30 ]; then
        echo "ERROR: Password must be at least 30 characters long (provided: $length characters)" >&2
        return 1
    fi
    
    # Check for lowercase letters
    if ! echo "$password" | grep -q '[a-z]'; then
        echo "ERROR: Password must contain at least one lowercase letter" >&2
        return 1
    fi
    
    # Check for uppercase letters
    if ! echo "$password" | grep -q '[A-Z]'; then
        echo "ERROR: Password must contain at least one uppercase letter" >&2
        return 1
    fi
    
    # Check for numbers
    if ! echo "$password" | grep -q '[0-9]'; then
        echo "ERROR: Password must contain at least one number" >&2
        return 1
    fi
    
    return 0
}

# Function to check if Samba is installed
# Returns 0 if installed, 1 if not
has_samba_installed() {
    command -v smbpasswd &>/dev/null
}

# Function to check if a user has Samba enabled
# Returns 0 if enabled, 1 if not
# Usage: has_samba_enabled "username"
has_samba_enabled() {
    local username="$1"
    [ -f "/etc/samba/smb.conf.d/$username.conf" ]
}

# Function to check if a user has Time Machine enabled
# Returns 0 if enabled, 1 if not
# Usage: has_timemachine_enabled "username"
has_timemachine_enabled() {
    local username="$1"
    if [ -f "/etc/samba/smb.conf.d/$username.conf" ]; then
        grep -q "^\[$username-timemachine\]" "/etc/samba/smb.conf.d/$username.conf"
    else
        return 1
    fi
}

# Function to get list of backup users (users in backupusers group)
# Prints usernames one per line
get_backup_users() {
    getent group backupusers | cut -d: -f4 | tr ',' '\n' | grep -v '^$'
}

# Parse quota values with optional unit suffix.
# - raw: input string (e.g., "50", "50GB", "13000MB", or legacy bytes when default_unit="B")
# - default_unit: unit to assume when no suffix is provided (GB by default). Accepts GB, MB, or B.
# Returns: "bytes|amount|unit|display" on success; non-zero on failure.
parse_quota_value() {
    local raw="$1"
    local default_unit="${2:-GB}"

    local normalized="${raw,,}"
    normalized="${normalized// /}"

    local amount=""
    local unit=""

    if [[ "$normalized" =~ ^([0-9]+)mb$ ]]; then
        amount="${BASH_REMATCH[1]}"
        unit="MB"
    elif [[ "$normalized" =~ ^([0-9]+)gb$ ]]; then
        amount="${BASH_REMATCH[1]}"
        unit="GB"
    elif [[ "$normalized" =~ ^([0-9]+)$ ]]; then
        amount="$normalized"
        case "${default_unit^^}" in
            MB) unit="MB" ;;
            B) unit="B" ;;
            *) unit="GB" ;;
        esac
    else
        return 1
    fi

    local bytes=0
    case "$unit" in
        MB) bytes=$((amount * 1024 * 1024)) ;;
        B)  bytes=$amount ;;
        *)  bytes=$((amount * 1024 * 1024 * 1024)) ;;
    esac

    local display="$(format_quota_display "$bytes")"
    echo "${bytes}|${amount}|${unit}|${display}"
    return 0
}

# Format bytes into a human-friendly quota string (prefers GB, falls back to MB).
format_quota_display() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0GB"
        return 0
    fi
    local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    # If at least 0.01 GB, show GB with 2 decimals; otherwise show MB rounded.
    if echo "$gb >= 0.01" | bc -l >/dev/null 2>&1 && [ "$(echo "$gb >= 0.01" | bc)" -eq 1 ]; then
        printf "%.2fGB" "$gb"
    else
        local mb=$(echo "scale=0; $bytes / 1024 / 1024" | bc 2>/dev/null || echo "0")
        printf "%sMB" "$mb"
    fi
}

# Function to check if user is a backup user
# Returns 0 if user is backup user, 1 if not
# Usage: is_backup_user "username"
is_backup_user() {
    local username="$1"
    groups "$username" 2>/dev/null | grep -q "backupusers"
}

# ---------------------------------------------------------------------------
# Btrfs quota-accounting usage cache
# ---------------------------------------------------------------------------
# Builds per-user usage figures from ONE `btrfs qgroup show --raw` call instead
# of walking the filesystem. Cost is O(subvolumes), independent of file count,
# so it stays fast even for users with millions of files.
#
# Semantics (simple-quota / squota mode):
#   Referenced = bytes of extents referenced by the subvolume (~logical size)
#   Exclusive  = bytes attributed to this subvolume (each extent is attributed
#                to exactly one subvolume, so summing Exclusive over a user's
#                uploads + snapshots gives that user's physical footprint)
#
# Populates global associative arrays keyed by username (values in bytes):
#   QG_UPLOADS_RFER, QG_UPLOADS_EXCL   - the uploads subvolume
#   QG_SNAP_RFER,    QG_SNAP_EXCL      - summed over all snapshots
#   QG_SNAP_COUNT                      - number of snapshot subvolumes seen
# and keyed by "username/snapshot-name":
#   QG_SNAP_RFER_BY_NAME, QG_SNAP_EXCL_BY_NAME
# Sets QGROUP_INCONSISTENT=true when btrfs warns that accounting is stale.
#
# Usage: build_qgroup_usage_cache [mountpoint]   (default /home)
# Returns 1 if quotas are not enabled or the output cannot be parsed.
build_qgroup_usage_cache() {
    local mount="${1:-/home}"
    declare -gA QG_UPLOADS_RFER=() QG_UPLOADS_EXCL=() QG_SNAP_RFER=() QG_SNAP_EXCL=() QG_SNAP_COUNT=()
    declare -gA QG_SNAP_RFER_BY_NAME=() QG_SNAP_EXCL_BY_NAME=()
    declare -g QGROUP_INCONSISTENT=false
    declare -g QGROUP_CACHE_READY=false

    local errfile
    errfile=$(mktemp) || return 1
    local output
    if ! output=$(btrfs qgroup show --raw "$mount" 2>"$errfile"); then
        rm -f "$errfile"
        return 1
    fi
    if grep -qi "inconsistent" "$errfile" 2>/dev/null; then
        QGROUP_INCONSISTENT=true
    fi
    rm -f "$errfile"

    # Only level-0 qgroups (0/<subvol id>) map to real subvolumes. Skip the
    # header, <toplevel>, <stale> (pending deletions) and level-1 groups.
    # Paths are printed relative to the mounted subvolume, so match the
    # trailing "<user>/uploads" or "<user>/versions/<snapshot>" segments
    # regardless of any prefix (e.g. "@home/").
    local kind user snap rfer excl
    while IFS='|' read -r kind user snap rfer excl; do
        case "$kind" in
            uploads)
                QG_UPLOADS_RFER["$user"]=$rfer
                QG_UPLOADS_EXCL["$user"]=$excl
                ;;
            snapshot)
                QG_SNAP_RFER["$user"]=$(( ${QG_SNAP_RFER["$user"]:-0} + rfer ))
                QG_SNAP_EXCL["$user"]=$(( ${QG_SNAP_EXCL["$user"]:-0} + excl ))
                QG_SNAP_COUNT["$user"]=$(( ${QG_SNAP_COUNT["$user"]:-0} + 1 ))
                QG_SNAP_RFER_BY_NAME["$user/$snap"]=$rfer
                QG_SNAP_EXCL_BY_NAME["$user/$snap"]=$excl
                ;;
        esac
    done < <(echo "$output" | awk '
        $1 ~ /^0\// && NF >= 4 && $4 !~ /^</ {
            n = split($4, seg, "/")
            if (n >= 2 && seg[n] == "uploads") {
                print "uploads|" seg[n-1] "||" $2 "|" $3
            } else if (n >= 3 && seg[n-1] == "versions") {
                print "snapshot|" seg[n-2] "|" seg[n] "|" $2 "|" $3
            }
        }')

    QGROUP_CACHE_READY=true
    return 0
}

# Convert a byte count to MB with two decimals (no bc dependency).
# Usage: bytes_to_mb <bytes>
bytes_to_mb() {
    local bytes="${1:-0}"
    [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
    awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1048576 }'
}

# Enumerate a user's snapshot directories without spawning a process per
# snapshot. Snapshot names are YYYY-MM-DD_HH-MM-SS, so lexicographic order is
# chronological order and no date parsing is needed to find oldest/newest.
# Prints: "<count>|<oldest name>|<newest name>" (names empty when count is 0)
# Usage: get_snapshot_range <versions_dir>
get_snapshot_range() {
    local versions_dir="$1"
    local count=0 oldest="" newest="" d name
    if [ -d "$versions_dir" ]; then
        for d in "$versions_dir"/*/; do
            [ -d "$d" ] || continue
            name=$(basename "$d")
            [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || continue
            count=$((count + 1))
            [ -z "$oldest" ] && oldest="$name"
            newest="$name"
        done
    fi
    echo "${count}|${oldest}|${newest}"
}

# Convert a snapshot name (YYYY-MM-DD_HH-MM-SS) to "epoch|YYYY-MM-DD HH:MM:SS".
# Usage: snapshot_name_to_epoch <name>
snapshot_name_to_epoch() {
    local name="$1"
    if [[ "$name" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2})$ ]]; then
        local formatted="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}"
        local epoch
        epoch=$(date -d "$formatted" +%s 2>/dev/null || echo 0)
        echo "${epoch}|${formatted}"
    else
        echo "0|Unknown"
    fi
}
