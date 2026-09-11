# Per-User Inotify Architecture Proposal

> **Superseded (September 2026).** The monitor no longer uses inotify at all. It polls Btrfs
> generation numbers (`btrfs subvolume list -c /home`, one call for every user) and snapshots a
> user's `uploads` subvolume when its generation is newer than the newest snapshot's creation
> generation and has been stable for the inactivity window. This has no per-directory cost, no
> watch limits, and holds no kernel references, so the pending-deletion problem described below
> no longer occurs. The change was prompted by an outage in which a user with ~500k directories
> exhausted `max_user_watches` and the service stayed dead. This document is kept for history.


## Overview

This document describes an alternative architecture for the termiNAS monitoring service that uses **one inotifywait process per user** instead of a single global watcher. This architecture would allow immediate cleanup of Btrfs subvolumes when users are deleted.

## Current Architecture

### How It Works Now

```
┌─────────────────────────────────────────────────────────────────┐
│                    terminas-monitor.service                      │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │     inotifywait -m -r /home --exclude versions/          │   │
│  │                                                          │   │
│  │  Watches ALL of /home recursively:                       │   │
│  │    /home/user1/uploads/                                  │   │
│  │    /home/user1/uploads/subdir1/                          │   │
│  │    /home/user2/uploads/                                  │   │
│  │    /home/user3/uploads/                                  │   │
│  │    ...                                                   │   │
│  └──────────────────────────────────────────────────────────┘   │
│                           │                                      │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Event Processing Loop                        │   │
│  │                                                          │   │
│  │  For each close_write event:                             │   │
│  │    1. Extract username from path                         │   │
│  │    2. Spawn background subprocess for debouncing         │   │
│  │    3. Create snapshot after inactivity period            │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### Problem with Current Architecture

When a user is deleted:

1. The user's directories (`/home/username/uploads/`, etc.) are removed
2. The inotify watches created by `inotifywait` still hold **kernel-level references** to the deleted inodes
3. These references prevent the Btrfs cleaner from immediately reclaiming space
4. The `btrfs subvolume list -d` command shows "DELETED" entries (pending deletions)
5. Space is only reclaimed when `terminas-monitor.service` restarts (clearing all watches)

**Why this happens**: `inotifywait -m` (monitor mode) creates persistent watches. Even after a directory is deleted, the watch remains active in the kernel until the watching process exits or explicitly removes the watch.

**Impact**: Pending deletions continue to consume disk space until cleanup completes. No data integrity issues, but disk space is not reclaimed until the monitor service restarts.

## Proposed Architecture: Per-User Inotify

### Design Goals

1. **Immediate cleanup**: When a user is deleted, kill only their inotifywait process
2. **Isolation**: Each user's monitoring is independent
3. **Scalability**: Easy to add/remove users without affecting others
4. **Reliability**: Failure of one user's watcher doesn't affect others
5. **Immediate detection**: New users are monitored instantly via event-driven notification

### Known Issue: Polling-Based User Detection

The original proposal used a 30-second polling loop to detect new users. This has a critical flaw:

**Problem**: If a user is created and uploads a file within 30 seconds, the file event may be 
missed because no watcher is active yet for that user.

**Solution**: Use an **event-driven approach** with signal directories that `create_user.sh` and 
`delete_user.sh` can write to, triggering immediate action.

### Proposed Architecture (Event-Driven)

```
┌─────────────────────────────────────────────────────────────────┐
│                    terminas-monitor.service                      │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │              Signal Directory Watchers                    │   │
│  │                                                          │   │
│  │  inotifywait /var/run/terminas/new_users/     → Start    │   │
│  │  inotifywait /var/run/terminas/deleted_users/ → Stop     │   │
│  └──────────────────────────────────────────────────────────┘   │
│                           │                                      │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                   Main Supervisor                         │   │
│  │                                                          │   │
│  │  On startup: Start watchers for all existing users       │   │
│  │  On new_user signal: Immediately start watcher           │   │
│  │  On deleted_user signal: Stop watcher, restart main      │   │
│  │                          inotify to clear watches        │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  Per-User Watchers:                                             │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────┐ │
│  │ inotifywait      │  │ inotifywait      │  │ inotifywait    │ │
│  │ /home/user1/     │  │ /home/user2/     │  │ /home/user3/   │ │
│  │ uploads/         │  │ uploads/         │  │ uploads/       │ │
│  │                  │  │                  │  │                │ │
│  │ PID: 12345       │  │ PID: 12346       │  │ PID: 12347     │ │
│  └──────────────────┘  └──────────────────┘  └────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Signal Directory Mechanism

```
/var/run/terminas/
├── new_users/              # create_user.sh writes here
│   └── <username>          # Empty file, triggers new watcher
├── deleted_users/          # delete_user.sh writes here
│   └── <username>          # Empty file, triggers watcher stop + restart
├── inotify_user1           # PID of user1's watcher
├── inotify_user2           # PID of user2's watcher
└── ...
```

### How It Works

1. **create_user.sh** creates `/var/run/terminas/new_users/<username>`
2. Monitor detects new file via inotifywait on `new_users/` directory
3. Monitor immediately starts watcher for the new user (no 30-second delay)
4. Monitor removes the signal file after processing

5. **delete_user.sh** creates `/var/run/terminas/deleted_users/<username>`
6. Monitor detects new file via inotifywait on `deleted_users/` directory
7. Monitor stops the user's watcher, removing inotify references
8. Monitor removes the signal file after processing
9. Btrfs cleaner can now immediately reclaim space

### Implementation Details

#### 1. Main Supervisor Script Structure

```bash
#!/bin/bash
# /var/terminas/scripts/terminas-monitor.sh (new architecture)

LOG=/var/log/terminas.log
RUNDIR=/var/run/terminas
SIGNAL_NEW="$RUNDIR/new_users"
SIGNAL_DEL="$RUNDIR/deleted_users"
mkdir -p "$RUNDIR" "$SIGNAL_NEW" "$SIGNAL_DEL"

# Get list of backup users
get_backup_users() {
    getent group backupusers | cut -d: -f4 | tr ',' '\n' | grep -v '^$'
}

# Start watcher for a specific user
start_user_watcher() {
    local user="$1"
    local pid_file="$RUNDIR/inotify_$user"
    local uploads_dir="/home/$user/uploads"
    
    # Check if uploads directory exists
    if [ ! -d "$uploads_dir" ]; then
        return
    fi
    
    # Check if watcher already running
    if [ -f "$pid_file" ]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            return  # Already running
        fi
        rm -f "$pid_file"
    fi
    
    # Start new watcher for this user
    (
        inotifywait -m -r "$uploads_dir" -e close_write --format '%w%f %e' 2>/dev/null |
        while read path event; do
            # Handle events for this user
            handle_user_event "$user" "$path" "$event"
        done
    ) &
    
    echo "$!" > "$pid_file"
    echo "$(date '+%F %T') Started watcher for $user (PID $!)" >> "$LOG"
}

# Stop watcher for a specific user
stop_user_watcher() {
    local user="$1"
    local pid_file="$RUNDIR/inotify_$user"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            # Wait for process to exit
            for i in {1..10}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done
            # Force kill if needed
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null
            fi
            echo "$(date '+%F %T') Stopped watcher for $user (PID $pid)" >> "$LOG"
        fi
        rm -f "$pid_file"
    fi
}

# Cleanup watchers for deleted users
cleanup_stale_watchers() {
    for pid_file in "$RUNDIR"/inotify_*; do
        [ -f "$pid_file" ] || continue
        local user=$(basename "$pid_file" | sed 's/^inotify_//')
        
        # If user no longer exists, stop their watcher
        if ! id "$user" &>/dev/null; then
            stop_user_watcher "$user"
        fi
    done
}

# Handle event for a user (debouncing logic here)
handle_user_event() {
    local user="$1"
    local path="$2"
    local event="$3"
    
    echo "$(date '+%F %T') Event: user=$user path=$path event=$event" >> "$LOG"
    
    # ... existing debounce and snapshot logic ...
}

# Process signal files for new users
process_new_user_signals() {
    for signal_file in "$SIGNAL_NEW"/*; do
        [ -f "$signal_file" ] || continue
        local user=$(basename "$signal_file")
        
        echo "$(date '+%F %T') New user signal received: $user" >> "$LOG"
        start_user_watcher "$user"
        rm -f "$signal_file"
    done
}

# Process signal files for deleted users
process_deleted_user_signals() {
    for signal_file in "$SIGNAL_DEL"/*; do
        [ -f "$signal_file" ] || continue
        local user=$(basename "$signal_file")
        
        echo "$(date '+%F %T') Deleted user signal received: $user" >> "$LOG"
        stop_user_watcher "$user"
        rm -f "$signal_file"
    done
}

# Main function
main() {
    # Start watchers for all existing backup users on startup
    for user in $(get_backup_users); do
        start_user_watcher "$user"
    done
    
    # Process any pending signals from before service started
    process_new_user_signals
    process_deleted_user_signals
    
    # Watch signal directories for new/deleted user notifications
    inotifywait -m -q "$SIGNAL_NEW" "$SIGNAL_DEL" -e create -e moved_to --format '%w %f' |
    while read dir file; do
        case "$dir" in
            "$SIGNAL_NEW/")
                echo "$(date '+%F %T') New user signal: $file" >> "$LOG"
                start_user_watcher "$file"
                rm -f "$SIGNAL_NEW/$file"
                ;;
            "$SIGNAL_DEL/")
                echo "$(date '+%F %T') Deleted user signal: $file" >> "$LOG"
                stop_user_watcher "$file"
                rm -f "$SIGNAL_DEL/$file"
                ;;
        esac
    done
}

main
```

#### 2. Updated create_user.sh

```bash
# At the end of create_user.sh, after user is fully set up:

# Signal the monitor service to start watching this user immediately
SIGNAL_DIR="/var/run/terminas/new_users"
if [ -d "$SIGNAL_DIR" ]; then
    touch "$SIGNAL_DIR/$USERNAME"
    echo "Signaled monitor service to start watching $USERNAME"
fi
```

#### 3. Updated delete_user.sh

```bash
# In delete_user.sh, before removing directories:

# Stop the per-user inotify watcher (releases inotify watches immediately)
stop_user_inotify_watcher() {
    local username="$1"
    local pid_file="/var/run/terminas/inotify_$username"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "Stopping inotify watcher for $username (PID $pid)..."
            kill "$pid" 2>/dev/null || true
            
            # Wait for graceful exit
            for i in {1..10}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi
                sleep 0.5
            done
            
            # Force kill if needed
            if kill -0 "$pid" 2>/dev/null; then
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        rm -f "$pid_file"
    fi
}

# Call before directory deletion
stop_user_inotify_watcher "$USERNAME"

# Also signal the monitor (for cleanup)
SIGNAL_DIR="/var/run/terminas/deleted_users"
if [ -d "$SIGNAL_DIR" ]; then
    touch "$SIGNAL_DIR/$USERNAME"
fi
```

### File Structure

```
/var/run/terminas/
├── new_users/             # Signal directory for new users
│   └── <username>         # Empty signal file (auto-removed after processing)
├── deleted_users/         # Signal directory for deleted users
│   └── <username>         # Empty signal file (auto-removed after processing)
├── inotify_user1          # PID of user1's inotifywait process
├── inotify_user2          # PID of user2's inotifywait process
├── inotify_user3          # PID of user3's inotifywait process
├── activity_user1         # Last activity timestamp for user1
├── activity_user2         # Last activity timestamp for user2
├── processing_user1       # PID of debounce subprocess for user1
└── ...
```

### Advantages

1. **Immediate Btrfs cleanup**: Killing the user's inotifywait releases all watches, allowing immediate space reclamation
2. **No service restart needed**: Other users' monitoring continues uninterrupted
3. **Fault isolation**: If one watcher crashes, others continue working
4. **Easier debugging**: Can check each user's watcher status independently
5. **Resource tracking**: Easy to see which users are being monitored

### Disadvantages

1. **More processes**: One inotifywait per user (instead of one global)
2. **More complexity**: Supervisor loop to manage watchers
3. **Slightly more memory**: Each inotifywait process has overhead (~2-5MB per user)
4. **Race conditions**: Need careful handling when users are created/deleted

### Resource Considerations

- **Memory**: ~2-5MB per inotifywait process
- **CPU**: Minimal - inotifywait blocks on kernel events
- **File descriptors**: ~3 per inotifywait process, plus watches
- **Inotify watches**: Same as current architecture (one per directory)

For a server with 100 users: ~500MB additional memory, which is acceptable.

### Migration Path

1. Implement new architecture in parallel with current
2. Test thoroughly with multiple users
3. Add feature flag to switch between architectures
4. Default to new architecture in next major version
5. Remove old architecture after validation period

### Testing Checklist

- [ ] New user created → watcher starts automatically
- [ ] User deleted → watcher stops, Btrfs cleanup immediate
- [ ] Service restart → all watchers restart correctly
- [ ] User uploads file → snapshot created after debounce
- [ ] Multiple users upload simultaneously → all snapshots created
- [ ] Watcher crashes → supervisor restarts it
- [ ] User created during heavy activity → doesn't affect others

---

## Alternative: Signal-Based Improvement to Current Architecture

Instead of the full per-user architecture, we can apply the **signal directory concept** to the 
existing single-inotifywait architecture. This is a simpler change that solves the pending 
deletion problem without the complexity of per-user watchers.

### Concept

Keep the current global `inotifywait -m -r /home` but add a signal mechanism:

1. **delete_user.sh** writes a signal file to `/var/run/terminas/restart_monitor`
2. The monitor script watches this signal directory
3. When signal received, monitor restarts itself (spawns new inotifywait, clears all watches)
4. This clears the inotify references and allows Btrfs cleanup

### Why This Works

The key insight is that we can **restart the monitor atomically**:

1. Stop the old inotifywait process
2. Start a new inotifywait process immediately
3. The gap is minimal (milliseconds)
4. Even if a file event occurs during restart, inotify will still catch it because:
   - New watches are established before old process fully exits
   - Files that complete upload trigger close_write which persists

### Implementation

#### Signal Directory Structure

```
/var/run/terminas/
├── restart_monitor/        # delete_user.sh writes here
│   └── <username>_<timestamp>  # Signal file triggers restart
├── activity_*              # Existing activity tracking
├── snapshot_*              # Existing snapshot tracking
└── processing_*            # Existing processing locks
```

#### Updated terminas-monitor.sh (Current Architecture + Signals)

```bash
#!/bin/bash
# Add to the beginning of terminas-monitor.sh

SIGNAL_DIR="/var/run/terminas/restart_monitor"
mkdir -p "$SIGNAL_DIR"

# Function to restart the monitor
restart_monitor() {
    local reason="$1"
    echo "$(date '+%F %T') Restarting monitor: $reason" >> "$LOG"
    
    # Clean up signal files
    rm -f "$SIGNAL_DIR"/* 2>/dev/null
    
    # Re-exec ourselves (replaces current process, clears all inotify watches)
    exec "$0" "$@"
}

# Watch for restart signals in background
(
    inotifywait -m -q "$SIGNAL_DIR" -e create -e moved_to --format '%f' |
    while read signal_file; do
        echo "$(date '+%F %T') Restart signal received: $signal_file" >> "$LOG"
        
        # Send SIGHUP to parent process to trigger restart
        kill -HUP $$ 2>/dev/null
    done
) &
SIGNAL_WATCHER_PID=$!

# Handle SIGHUP to restart
trap 'restart_monitor "SIGHUP received"' HUP

# Cleanup on exit
trap 'kill $SIGNAL_WATCHER_PID 2>/dev/null' EXIT

# ... rest of existing monitor script ...
```

#### Updated delete_user.sh

```bash
# After deleting user directories, signal monitor to restart

# Signal the monitor to restart (clears inotify watches for deleted user)
SIGNAL_DIR="/var/run/terminas/restart_monitor"
if [ -d "$SIGNAL_DIR" ]; then
    touch "$SIGNAL_DIR/${USERNAME}_$(date +%s)"
    echo "Signaled monitor service to restart (clearing inotify watches)"
    
    # Wait briefly for monitor to restart
    sleep 2
    
    # Verify Btrfs can now clean up
    btrfs filesystem sync /home 2>/dev/null || true
fi
```

### Advantages Over Full Per-User Architecture

1. **Minimal code changes**: Only add signal handling, not complete rewrite
2. **Same memory footprint**: Still one inotifywait process
3. **Proven architecture**: Keep existing tested code
4. **Solves the problem**: Pending deletions cleared on user deletion

### Disadvantages

1. **Brief monitoring gap**: Milliseconds during restart (acceptable)
2. **All users affected**: Restart clears all watches (but immediately re-established)
3. **Not isolated**: Still can't stop watching one user without affecting others

### Risk Analysis: Missing File Events During Restart

**Question**: Could we miss a file upload event during the restart?

**Answer**: Very unlikely, because:

1. **Restart is fast**: inotifywait startup is ~10-50ms
2. **close_write is the trigger**: We watch for file close, not file create
3. **Files aren't instant**: Upload takes time, close_write happens at the end
4. **Inotify is kernel-level**: Events are queued even during brief gaps

**Worst case scenario**:
- User A's upload completes close_write during the 50ms restart window
- The event is lost
- **Mitigation**: The next upload from User A will trigger a snapshot that includes the missed file

**Probability**: Extremely low. Would require:
- User deletion at exact moment another user's upload completes
- The close_write event in the ~50ms restart window
- In practice, this is a non-issue

### Recommendation

**For immediate implementation**: Use this signal-based improvement to the current architecture.
It's simpler, lower risk, and solves the pending deletion problem.

**For future consideration**: The full per-user architecture remains documented above for cases 
where complete isolation between users is required.

---

## Decision

**Current Status**: Both architectures are documented but NOT implemented.

### Option 1: Signal-Based Restart (Recommended for Implementation)

Add signal directory mechanism to current architecture:
- `delete_user.sh` signals monitor to restart
- Monitor restarts, clearing inotify watches
- Btrfs can immediately clean up
- Minimal code changes, low risk

### Option 2: Full Per-User Architecture (Future Consideration)

Complete rewrite with one inotifywait per user:
- Maximum isolation between users
- More complex implementation
- Higher memory usage
- Consider if Option 1 proves insufficient

### Option 3: Accept Current Behavior (Current Choice)

Keep current architecture as-is:
- Pending deletions are documented as expected
- Space reclaimed on service restart
- Simplest approach, no code changes
- Acceptable if disk space is not critical

**Rationale for Option 3 (current choice)**:
- Pending Btrfs deletions cause no data loss or integrity issues
- Disk space is reclaimed on service restart (system reboot, manual restart)
- Current architecture is simpler and well-tested
- Signal-based or per-user architecture can be implemented if needed

**When to implement Option 1 or 2**:
- If pending deletions cause operational issues
- If disk space becomes critical and immediate reclamation is needed
- If users report confusion about pending deletions

## References

- [inotify(7) man page](https://man7.org/linux/man-pages/man7/inotify.7.html)
- [Btrfs Subvolume Documentation](https://btrfs.readthedocs.io/en/latest/Subvolumes.html)
- [termiNAS GitHub Repository](https://github.com/YiannisBourkelis/terminas)

---

*Document created: November 2025*
*Last updated: November 2025*
