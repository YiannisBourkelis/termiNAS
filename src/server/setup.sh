#!/bin/bash

# setup.sh - Setup script for Debian backup server with Btrfs snapshots
# This script configures a Debian system to allow remote clients to upload files via SCP/SFTP
# with automatic Btrfs snapshot versioning for ransomware protection.
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas
#
# Requirements:
#   - Debian 12 or later
#   - Btrfs filesystem for /home

# Get version from VERSION file in repository root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared helpers (quota mode detection, parsing)
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    source "$SCRIPT_DIR/common.sh"
fi
VERSION_FILE="$SCRIPT_DIR/../../VERSION"
if [ -f "$VERSION_FILE" ]; then
    VERSION=$(cat "$VERSION_FILE" | tr -d '[:space:]')
else
    VERSION="unknown"
fi

set -e

# Parse command line arguments
ENABLE_SAMBA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --samba)
            ENABLE_SAMBA=true
            shift
            ;;
        --help|-h)
            echo "termiNAS Server Setup v$VERSION"
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --samba    Enable Samba (SMB) support for wbadmin compatibility"
            echo "  --help     Show this help message"
            echo ""
            echo "By default, only SFTP access is enabled for security."
            echo "Use --samba to also enable Samba sharing with strict security settings."
            exit 0
            ;;
        --version|-v)
            echo "termiNAS Server Setup v$VERSION"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

echo "Starting termiNAS server setup v$VERSION..."
if [ "$ENABLE_SAMBA" = "true" ]; then
    echo "Samba support: ENABLED"
else
    echo "Samba support: DISABLED (use --samba to enable)"
fi
echo ""

# Check Btrfs filesystem requirement
echo "Checking filesystem requirements..."
if [ ! -d /home ]; then
    echo "ERROR: /home directory does not exist"
    exit 1
fi

HOME_FS=$(df -T /home | tail -1 | awk '{print $2}')
if [ "$HOME_FS" != "btrfs" ]; then
    echo ""
    echo "=========================================="
    echo "ERROR: Btrfs filesystem required"
    echo "=========================================="
    echo ""
    echo "/home is currently on: $HOME_FS"
    echo ""
    echo "termiNAS requires Btrfs for efficient snapshot functionality."
    echo ""
    echo "To fix this:"
    echo "  1. Reinstall Debian with Btrfs for /home partition during installation"
    echo "  2. Or create a Btrfs partition and mount it at /home:"
    echo "     # mkfs.btrfs /dev/sdXY"
    echo "     # mount /dev/sdXY /home"
    echo "     # Add to /etc/fstab for persistence"
    echo ""
    exit 1
fi

echo "✓ Btrfs filesystem detected on /home"

# ---------------------------------------------------------------------------
# noatime on /home
# With the default relatime, reads cause writes: every directory listing or
# file read (e.g. a daily rclone sync that transfers nothing) rewrites inode
# metadata on this copy-on-write filesystem, bumps the uploads generation the
# monitor watches, and duplicates metadata blocks that snapshots could share.
# Nothing in termiNAS uses atime (snapshots and clients rely on mtime).
# Applied only when it can be done safely; otherwise a warning is printed.
# ---------------------------------------------------------------------------
echo "Checking mount options on /home..."
HOME_MOUNT_OPTS=$(findmnt -no OPTIONS --target /home 2>/dev/null || true)
HOME_MOUNT_TARGET=$(findmnt -no TARGET --target /home 2>/dev/null || true)
if echo ",$HOME_MOUNT_OPTS," | grep -q ',noatime,'; then
    echo "  ✓ /home is mounted with noatime"
elif [ "$HOME_MOUNT_TARGET" != "/home" ]; then
    echo "  ⚠ /home is not a separate mount point (it belongs to the ${HOME_MOUNT_TARGET:-unknown} mount)."
    echo "    Recommended: add 'noatime' to that filesystem's options in /etc/fstab and remount."
else
    if mount -o remount,noatime /home 2>/dev/null; then
        echo "  ✓ Remounted /home with noatime"
    else
        echo "  ⚠ Could not remount /home with noatime; add it to /etc/fstab and remount manually"
    fi

    # Persist in /etc/fstab only when the /home entry is unambiguous
    fstab_home_lines=$(awk '$1 !~ /^#/ && NF >= 4 && $2 == "/home" { n++ } END { print n + 0 }' /etc/fstab 2>/dev/null)
    if [ "$fstab_home_lines" = "1" ]; then
        if awk '$1 !~ /^#/ && NF >= 4 && $2 == "/home" && $4 ~ /(^|,)noatime(,|$)/ { found = 1 } END { exit !found }' /etc/fstab; then
            echo "  ✓ /etc/fstab already has noatime for /home"
        else
            # Replace any explicit atime option with noatime, otherwise append it
            awk '$1 !~ /^#/ && NF >= 4 && $2 == "/home" {
                     n = split($4, o, ","); out = ""
                     for (i = 1; i <= n; i++) {
                         if (o[i] == "relatime" || o[i] == "strictatime" || o[i] == "atime" || o[i] == "noatime") continue
                         out = out (out == "" ? "" : ",") o[i]
                     }
                     $4 = (out == "" ? "noatime" : out ",noatime")
                 }
                 { print }' OFS='\t' /etc/fstab > /etc/fstab.terminas.tmp
            # Install only if the edited file verifies no worse than the original
            # (pre-existing issues such as an unplugged 'nofail' disk must not block us,
            # but anything our edit introduced must). Summary line: "N parse errors, N errors, N warnings"
            fstab_verify_counts() {
                local out
                out=$(findmnt --verify --tab-file "$1" 2>&1)
                if echo "$out" | grep -q '^Success'; then
                    echo "0,0"
                else
                    echo "$out" | awk '/parse errors/ { print $1 + 0 "," $4 + 0 }'
                fi
            }
            orig_counts=$(fstab_verify_counts /etc/fstab)
            new_counts=$(fstab_verify_counts /etc/fstab.terminas.tmp)
            if [ -n "$new_counts" ] && [ "${new_counts%%,*}" -le "${orig_counts%%,*}" ] && [ "${new_counts##*,}" -le "${orig_counts##*,}" ]; then
                fstab_backup="/etc/fstab.terminas-$(date +%Y%m%d%H%M%S).bak"
                cp -a /etc/fstab "$fstab_backup"
                mv -f /etc/fstab.terminas.tmp /etc/fstab
                # systemd generates mount units from fstab; pick up the new options
                systemctl daemon-reload 2>/dev/null || true
                echo "  ✓ Added noatime to the /home entry in /etc/fstab (backup: $fstab_backup)"
            else
                rm -f /etc/fstab.terminas.tmp
                echo "  ⚠ Edited /etc/fstab did not pass verification (original: $orig_counts, edited: ${new_counts:-n/a} parse errors,errors)."
                echo "    /etc/fstab was left unchanged; add 'noatime' to the /home entry manually."
            fi
        fi
    elif [ "$fstab_home_lines" = "0" ]; then
        echo "  ⚠ /home has no /etc/fstab entry (mounted another way); make noatime persistent yourself."
    else
        echo "  ⚠ Several /home entries in /etc/fstab; add 'noatime' to the active one manually."
    fi
fi
echo ""

# Enable Btrfs simple quotas (squotas) on /home filesystem
# Simple quotas avoid the performance issues of full qgroup accounting
# by attributing all extents to the subvolume that first allocated them
echo "Enabling Btrfs simple quotas on /home..."
if btrfs qgroup show /home &>/dev/null; then
    QUOTA_MODE=$(get_btrfs_quota_mode /home)
    case "$QUOTA_MODE" in
        squota)
            echo "  ✓ Btrfs simple quotas (squota) already enabled" ;;
        qgroup)
            echo "  ⚠ Btrfs quotas are enabled in FULL accounting mode, not simple quotas."
            echo "    termiNAS is designed for simple quotas: full mode undercounts the per-user"
            echo "    total (uploads + snapshots), adds accounting work to every snapshot, and"
            echo "    stops counting new data whenever the accounting is marked inconsistent."
            echo "    Migrate with:  $SCRIPT_DIR/manage_users.sh migrate-squota"
            echo "    (existing data is not attributed under simple quotas; new writes are)" ;;
        *)
            echo "  ✓ Btrfs quotas already enabled (mode: $QUOTA_MODE)" ;;
    esac
else
    if btrfs quota enable --simple /home; then
        echo "  ✓ Enabled Btrfs simple quotas (squotas)"
        echo "  Note: Quota tracking may take a few minutes to initialize for existing data"
    else
        echo "  ⚠ WARNING: Failed to enable Btrfs quotas"
        echo "  Quota management will not be available"
    fi
fi
echo ""

# Update system
echo "Updating system packages..."
apt update && apt upgrade -y

# Install required packages (removed rsync, added btrfs-progs)
echo "Installing required packages..."
PACKAGES="openssh-server pwgen cron inotify-tools btrfs-progs fail2ban nftables bc coreutils sshpass smbclient expect"
if [ "$ENABLE_SAMBA" = "true" ]; then
    PACKAGES="$PACKAGES samba samba-common-bin"
    echo "  - Including Samba packages for SMB support"
fi
apt install -y $PACKAGES

# Create backup users group
echo "Creating backupusers group..."
groupadd -f backupusers

# Configure SSH
echo "Configuring SSH..."

# Check SSH security settings (but don't modify them automatically)
PERMIT_ROOT=$(grep "^PermitRootLogin" /etc/ssh/sshd_config 2>/dev/null || echo "")
PASSWORD_AUTH=$(grep "^PasswordAuthentication" /etc/ssh/sshd_config 2>/dev/null || echo "")

SSH_WARNINGS=()

if ! echo "$PERMIT_ROOT" | grep -q "^PermitRootLogin no"; then
    SSH_WARNINGS+=("PermitRootLogin is not set to 'no'")
fi

if ! echo "$PASSWORD_AUTH" | grep -q "^PasswordAuthentication yes"; then
    SSH_WARNINGS+=("PasswordAuthentication is not set to 'yes'")
fi

if [ ${#SSH_WARNINGS[@]} -gt 0 ]; then
    echo ""
    echo "=========================================="
    echo "⚠ SSH Configuration Recommendations"
    echo "=========================================="
    echo ""
    echo "The following SSH settings should be configured for termiNAS:"
    echo ""
    for warning in "${SSH_WARNINGS[@]}"; do
        echo "  ⚠ $warning"
    done
    echo ""
    echo "Recommended configuration in /etc/ssh/sshd_config:"
    echo "  PermitRootLogin no"
    echo "  PasswordAuthentication yes  (or use public key authentication - see below)"
    echo ""
    echo "Security Note: Public key authentication is MORE SECURE than passwords."
    echo "If you prefer public keys over passwords:"
    echo "  - Set: PubkeyAuthentication yes"
    echo "  - Set: PasswordAuthentication no"
    echo "  - Add your public key to ~/.ssh/authorized_keys for each user"
    echo "  - termiNAS backup users support both password and key-based authentication"
    echo ""
    echo "⚠ IMPORTANT - Before making these changes:"
    echo "  1. Create a non-root user:"
    echo "     adduser yourusername"
    echo ""
    echo "  2. (Optional) Set up SSH key for the new user:"
    echo "     mkdir -p /home/yourusername/.ssh"
    echo "     echo 'your-public-key-here' >> /home/yourusername/.ssh/authorized_keys"
    echo "     chmod 700 /home/yourusername/.ssh"
    echo "     chmod 600 /home/yourusername/.ssh/authorized_keys"
    echo "     chown -R yourusername:yourusername /home/yourusername/.ssh"
    echo ""
    echo "  3. Test SSH login with the new user in a NEW terminal"
    echo "     (keep this session open as backup)"
    echo ""
    echo "  4. Verify you can escalate to root using 'su -' with the new user"
    echo ""
    echo "  5. After confirming the new user works, edit /etc/ssh/sshd_config:"
    echo "     nano /etc/ssh/sshd_config"
    echo "     Set: PermitRootLogin no"
    echo "     Set: PasswordAuthentication yes (or no if using keys only)"
    echo "     Set: PubkeyAuthentication yes (if using keys)"
    echo ""
    echo "  6. Restart SSH service:"
    echo "     systemctl restart ssh"
    echo ""
    echo "Note: Don't add the user to sudo group unless necessary - use 'su -' instead."
    echo "These changes are optional but strongly recommended for security."
    echo "Setup will continue without modifying your SSH configuration."
    echo "=========================================="
    echo ""
    read -p "Press Enter to continue with setup..."
fi

# Enable internal-sftp subsystem (check if already configured)
if ! grep -q "Subsystem sftp internal-sftp" /etc/ssh/sshd_config; then
    sed -i 's/#*Subsystem sftp.*/Subsystem sftp internal-sftp/' /etc/ssh/sshd_config
    echo "  - Configured internal-sftp subsystem"
fi

# Configure SSH keepalive to prevent long uploads from timing out
if ! grep -q "^ClientAliveInterval" /etc/ssh/sshd_config; then
    sed -i 's/#*ClientAliveInterval.*/ClientAliveInterval 60/' /etc/ssh/sshd_config
    echo "  - Set ClientAliveInterval to 60 seconds"
fi

if ! grep -q "^ClientAliveCountMax" /etc/ssh/sshd_config; then
    sed -i 's/#*ClientAliveCountMax.*/ClientAliveCountMax 120/' /etc/ssh/sshd_config
    echo "  - Set ClientAliveCountMax to 120 (allows 2 hours of inactivity)"
fi

# Add group chroot configuration (only if not already present)
if ! grep -q "Match Group backupusers" /etc/ssh/sshd_config; then
    echo "" >> /etc/ssh/sshd_config
    echo "# termiNAS backup users configuration" >> /etc/ssh/sshd_config
    echo "Match Group backupusers" >> /etc/ssh/sshd_config
    echo "    ChrootDirectory %h" >> /etc/ssh/sshd_config
    echo "    ForceCommand internal-sftp" >> /etc/ssh/sshd_config
    echo "    AllowTcpForwarding no" >> /etc/ssh/sshd_config
    echo "    X11Forwarding no" >> /etc/ssh/sshd_config
    echo "  - Added backupusers chroot configuration"
fi

# Restart SSH
echo "Restarting SSH service..."
systemctl restart ssh

# Configure fail2ban for SSH/SFTP protection
echo "Configuring fail2ban..."

# Detect the correct auth log path
if [ -f /var/log/auth.log ]; then
    AUTH_LOG="/var/log/auth.log"
elif [ -f /var/log/secure ]; then
    AUTH_LOG="/var/log/secure"
else
    # Create auth.log if it doesn't exist
    touch /var/log/auth.log
    AUTH_LOG="/var/log/auth.log"
fi

if [ ! -f /etc/fail2ban/jail.d/terminas-sshd.conf ]; then
    cat > /etc/fail2ban/jail.d/terminas-sshd.conf <<F2B
# termiNAS fail2ban configuration for SSH/SFTP protection
# This protects both SSH and SFTP since SFTP uses SSH authentication

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = $AUTH_LOG
backend = systemd
maxretry = 5
bantime = 3600
findtime = 600
banaction = nftables[type=multiport]

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = $AUTH_LOG
backend = systemd
maxretry = 10
bantime = 600
findtime = 60
banaction = nftables[type=multiport]
F2B
    echo "  - Created fail2ban SSH/SFTP jail configuration (using $AUTH_LOG)"
else
    echo "  - fail2ban SSH/SFTP jail configuration already exists"
fi

# Create sshd-ddos filter for connection flooding protection
if [ ! -f /etc/fail2ban/filter.d/sshd-ddos.conf ]; then
    cat > /etc/fail2ban/filter.d/sshd-ddos.conf <<'FILTER'
# termiNAS filter for SSH/SFTP DOS (connection flooding) protection
# Detects rapid connection attempts that may indicate a DOS attack
[Definition]
failregex = ^.*Did not receive identification string from <HOST>.*$
            ^.*Connection closed by <HOST> port \d+ \[preauth\].*$
            ^.*Connection reset by <HOST> port \d+ \[preauth\].*$
            ^.*SSH: Server;Ltype: Version;Remote: <HOST>-\d+;.*$
ignoreregex =
FILTER
    echo "  - Created sshd-ddos filter"
fi

# Create custom filter for SFTP-specific issues if needed
if [ ! -f /etc/fail2ban/filter.d/terminas-sftp.conf ]; then
    cat > /etc/fail2ban/filter.d/terminas-sftp.conf <<'FILTER'
# termiNAS custom filter for SFTP abuse
[Definition]
failregex = ^.*subsystem request for sftp.*Failed password for .* from <HOST>.*$
            ^.*subsystem request for sftp.*Connection closed by authenticating user .* <HOST>.*\[preauth\]$
ignoreregex =
FILTER
    echo "  - Created custom SFTP abuse filter"
fi

# Configure nftables action defaults (chain priority and blocktype)
if [ ! -f /etc/fail2ban/action.d/nftables-common.local ]; then
    cat > /etc/fail2ban/action.d/nftables-common.local <<'NFTCOMMON'
# termiNAS fail2ban nftables configuration
# Override default nftables action parameters for better performance

[Init]
# Set chain priority to -100 (earlier in packet processing than default "filter - 1")
# This ensures fail2ban rules are evaluated early for better performance
chain_priority = -100

# Use reject to send RST packets (faster connection failures for legitimate clients)
blocktype = reject
NFTCOMMON
    echo "  - Created nftables-common.local configuration"
fi

# Enable and start fail2ban
echo "Starting fail2ban service..."
systemctl enable fail2ban
systemctl restart fail2ban
echo "  - fail2ban is now protecting SSH/SFTP:"
echo "    * 5 failed login attempts = 1 hour ban"
echo "    * 10 connection attempts in 60s = 10 minute ban (DOS protection)"
echo "    * Applies to both SSH and SFTP connections"

# Configure Samba if enabled
if [ "$ENABLE_SAMBA" = "true" ]; then
    echo "Configuring Samba..."
    
    # Create Samba configuration directory for user-specific configs
    mkdir -p /etc/samba/smb.conf.d
    
    # Backup original smb.conf if it exists
    if [ -f /etc/samba/smb.conf ] && [ ! -f /etc/samba/smb.conf.bak ]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
        echo "  - Backed up original smb.conf"
    fi
    
    # Create main Samba configuration with security settings
    cat > /etc/samba/smb.conf <<SMB
# termiNAS Samba configuration - STRICT SECURITY SETTINGS
[global]
   workgroup = WORKGROUP
   server string = termiNAS Backup Server
   security = user
   map to guest = never
   
   # Strict protocol requirements
   server min protocol = SMB3
   client min protocol = SMB3
   server max protocol = SMB3
   client max protocol = SMB3
   
   # Encryption required
   smb encrypt = required
   
   # Disable insecure features
   load printers = no
   printing = bsd
   printcap name = /dev/null
   disable spoolss = yes
   show add printer wizard = no
   
   # Disable usershares since we use global shares
   usershare max shares = 0
   usershare allow guests = no
   usershare owner only = no
   
   # Suppress quota warnings (optional)
   get quota command = 
   set quota command =
   
   # Logging
   syslog only = yes
   log file = /var/log/samba/log.%m
   max log size = 1000
   # Log level 3 auth:5 ensures authentication failures are logged
   # auth:5 = detailed authentication logging for fail2ban detection
   log level = 3 auth:5
   
   # Performance
   socket options = TCP_NODELAY IPTOS_LOWDELAY SO_KEEPALIVE
   read raw = yes
   write raw = yes
   oplocks = yes
   max xmit = 65535
   dead time = 15
   
   # macOS Time Machine support (VFS fruit module)
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:nfs_aces = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

SMB
    
    # Add explicit includes for each per-user config file
    # This ensures all shares in per-user files are loaded (wildcards have limitations)
    echo "" >> /etc/samba/smb.conf
    echo "# Explicit includes for per-user configurations" >> /etc/samba/smb.conf
    if [ -d /etc/samba/smb.conf.d ]; then
        for user_conf in /etc/samba/smb.conf.d/*.conf; do
            if [ -f "$user_conf" ]; then
                echo "include = $user_conf" >> /etc/samba/smb.conf
            fi
        done
    fi
    
    cat >> /etc/samba/smb.conf <<'SMB2'

# Note: Per-user config files in /etc/samba/smb.conf.d/ are included above
# To add new users: run create_user.sh or manage_users.sh enable-samba
# The include list is automatically updated when users are added/removed
SMB2
    
    # Configure fail2ban for Samba protection
    # Create custom filter that works with both auth logs and audit logs
    cat > /etc/fail2ban/filter.d/terminas-samba.conf <<'FILTER'
# termiNAS fail2ban filter for Samba - AUTOMATICALLY CONFIGURED
# This file is automatically generated by termiNAS setup.sh
# MANUAL CHANGES WILL BE OVERWRITTEN when setup.sh is re-run
# 
# Matches authentication failures from Samba logs (log level 2+)
# Authentication failures are logged to /var/log/samba/log.<ip> files

[Definition]
# Match authentication failures with NT_STATUS errors
# The IP is extracted from "remote host [ipv4:IP:port]" in the Auth line
# Log format: 
#   [2025/10/16 18:45:37.752262,  2] ../../auth/auth_log.c:647(log_authentication_event_human_readable)
#     Auth: [SMB2,(null)] user [...] status [NT_STATUS_NO_SUCH_USER] ... remote host [ipv4:202.61.225.34:44202]
# Note: Auth line starts with spaces (continuation of previous line), not timestamp
failregex = ^\s+Auth:.*status\s*\[NT_STATUS_(?:WRONG_PASSWORD|NO_SUCH_USER|LOGON_FAILURE|ACCESS_DENIED)\].*remote host \[ipv4:<HOST>:\d+\]

# Ignore successful authentications
ignoreregex = NT_STATUS_OK
FILTER
    echo "  - Created/updated fail2ban Samba filter"
    
    # Create custom nftables action for Samba (without port filtering)
    # This is needed because tcp dport filtering breaks nftables blocking for some reason
    cat > /etc/fail2ban/action.d/nftables-terminas.conf <<'ACTION'
# Fail2Ban nftables action for Samba - WITHOUT port filtering
# This is a workaround for the issue where tcp dport filtering breaks blocking
#
# Based on nftables.conf but overrides to use simple IP-based blocking

[INCLUDES]
before = nftables.conf

[Definition]

# Force type to custom so we don't get port-based matching
type = custom

# Override match to be empty (no port/protocol filtering)
rule_match-custom = 

# Override rule_stat to use simple IP-based blocking
rule_stat = <addr_family> saddr @<addr_set> <blocktype>
ACTION
    echo "  - Created custom nftables action for Samba"
    
    # Configure fail2ban jail
    cat > /etc/fail2ban/jail.d/terminas-samba.conf <<F2B
# termiNAS fail2ban configuration for Samba protection
# Monitors Samba log files for authentication failures
[terminas-samba]
enabled = true
port = 445
filter = terminas-samba
# Monitor per-IP log files - Samba logs to /var/log/samba/log.<ip>
# Use polling backend to detect new log files created by new connections
logpath = /var/log/samba/log.*[0-9]
backend = polling
maxretry = 5
bantime = 3600
findtime = 600
banaction = nftables-terminas
F2B
    echo "  - Created/updated fail2ban Samba jail configuration"
    
    # Always restart fail2ban when Samba is enabled to pick up filter updates
    echo "Reloading fail2ban with Samba protection..."
    systemctl restart fail2ban
    echo "  - fail2ban Samba jail is now active"
    
    # Configure Samba audit logging (journald)
    echo "  - Samba VFS audit logging configured (using journald)"
    echo "  - View audit logs with: journalctl SYSLOG_IDENTIFIER=smbd_audit"
    
    # Enable and start Samba services
    echo "Starting Samba services..."
    systemctl enable smbd nmbd
    systemctl restart smbd nmbd
    echo "  - Samba is now running with strict security:"
    echo "    * SMB3 protocol only (no older insecure versions)"
    echo "    * Encryption required for all connections"
    echo "    * fail2ban protection (5 failed attempts = 1 hour ban)"
    echo "    * VFS audit logging for connection tracking and security"
    echo "    * User-specific shares with restricted permissions"
    echo "    * VFS audit logging enabled for connection tracking"
fi

# Create base directories
echo "Creating base directories..."
mkdir -p /var/terminas/scripts
# Shared helpers used by the generated monitor and cleanup scripts
cp "$SCRIPT_DIR/common.sh" /var/terminas/scripts/common.sh
chmod 644 /var/terminas/scripts/common.sh

# Create monitor script for real-time incremental snapshots
echo "Creating/updating monitor script..."

# Detect git commit hash at setup time
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ -d "$REPO_ROOT/.git" ]; then
    TERMINAS_COMMIT=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    TERMINAS_VERSION="git-$TERMINAS_COMMIT"
else
    TERMINAS_COMMIT="unknown"
    TERMINAS_VERSION="non-git"
fi

cat > /var/terminas/scripts/terminas-monitor.sh <<'EOF'
#!/bin/bash
# termiNAS real-time snapshot monitor (Btrfs generation polling)
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas
#
# Generated by setup.sh at __GENERATED_AT__
# Version: __TERMINAS_VERSION__
# Commit: __TERMINAS_COMMIT__
#
# How it works
# ------------
# Every Btrfs subvolume carries a "generation" counter that the kernel bumps
# whenever anything inside it changes (write, delete, rename). This monitor
# polls `btrfs subvolume list -c /home` - ONE cheap ioctl for all users - and
# compares each user's uploads generation with the creation generation of the
# user's newest snapshot:
#
#     uploads generation > newest snapshot creation generation
#         => something changed; `btrfs subvolume find-new` then confirms
#            that data was actually written (metadata-only changes such as
#            atime updates from directory listings are ignored)
#
# A snapshot is taken once the generation has been stable for
# TERMINAS_INACTIVITY_WINDOW seconds (upload finished), or after
# TERMINAS_SNAPSHOT_INTERVAL seconds of continuous activity (long upload;
# files still open for writing are excluded from that snapshot).
#
# Compared with the previous inotify-based monitor this costs nothing per
# directory or file: a user with a million files is watched as cheaply as an
# empty one, there are no watch limits, no event floods, and no kernel
# references that delay Btrfs space reclamation after deletions. Detection
# latency is the Btrfs commit interval (30s by default) plus the poll
# interval, well inside the inactivity window.
#
# Environment (set in the [Service] section of terminas-monitor.service):
#   TERMINAS_POLL_INTERVAL      seconds between generation checks   (default 10)
#   TERMINAS_INACTIVITY_WINDOW  quiet seconds before a snapshot       (default 60)
#   TERMINAS_SNAPSHOT_INTERVAL  max seconds of activity per snapshot (default 1800)
#   TERMINAS_DEBUG=1            log every generation change

LOG=/var/log/terminas.log
RUNDIR=/var/run/terminas
COMMON=/var/terminas/scripts/common.sh
HOME_MOUNT=/home

POLL_INTERVAL=${TERMINAS_POLL_INTERVAL:-10}
INACTIVITY_WINDOW=${TERMINAS_INACTIVITY_WINDOW:-60}
SNAPSHOT_INTERVAL=${TERMINAS_SNAPSHOT_INTERVAL:-1800}
DEBUG=${TERMINAS_DEBUG:-0}

mkdir -p "$(dirname "$LOG")" "$RUNDIR"
touch "$LOG"
chown root:adm "$LOG" 2>/dev/null || true
chmod 640 "$LOG" 2>/dev/null || true

log() {
    printf '%(%F %T)T %s\n' -1 "$*" >> "$LOG"
}

debug() {
    [ "$DEBUG" = "1" ] && log "DEBUG: $*"
    return 0
}

if [ -f "$COMMON" ]; then
    # shellcheck source=/dev/null
    source "$COMMON"
else
    log "ERROR: $COMMON not found - re-run setup.sh"
    exit 1
fi

trap 'log "Monitor stopping (signal received)"; exit 0' TERM INT

log "========================================"
log "termiNAS Monitor Service Started (Btrfs generation polling)"
log "Version: __TERMINAS_VERSION__  Commit: __TERMINAS_COMMIT__"
log "Poll ${POLL_INTERVAL}s, inactivity window ${INACTIVITY_WINDOW}s, max interval ${SNAPSHOT_INTERVAL}s"
log "========================================"

# ---------------------------------------------------------------------------
# Open-file detection: scans /proc/*/fd, so the cost is proportional to the
# number of open descriptors on the system, not to the number of files a
# user has. Prints paths under the user's uploads held open for writing.
# ---------------------------------------------------------------------------
list_open_write_files() {
    local user="$1"
    local fd target fdinfo flags
    find /proc/[0-9]*/fd -maxdepth 1 -type l -lname "$HOME_MOUNT/$user/uploads/*" -printf '%p %l\n' 2>/dev/null |
    while read -r fd target; do
        case "$target" in *" (deleted)") continue ;; esac
        fdinfo="${fd/\/fd\//\/fdinfo\/}"
        flags=$(awk '/^flags:/ { print $2; exit }' "$fdinfo" 2>/dev/null)
        [ -n "$flags" ] || continue
        # flags is octal; O_WRONLY = 01, O_RDWR = 02
        if (( (8#$flags & 3) != 0 )); then
            echo "$target"
        fi
    done | sort -u
}

# ---------------------------------------------------------------------------
# Quota helpers
# ---------------------------------------------------------------------------
# Level-0 qgroup of the user's uploads subvolume ("0/<id>")
uploads_qgroup_of() {
    local user="$1"
    local q=""
    [ -f "$HOME_MOUNT/$user/.terminas-qgroup" ] && q=$(cat "$HOME_MOUNT/$user/.terminas-qgroup" 2>/dev/null)
    if [ -z "$q" ] || [[ "$q" == 1/* ]]; then
        local id
        id=$(btrfs subvolume show "$HOME_MOUNT/$user/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || true)
        [ -n "$id" ] && q="0/$id"
    fi
    echo "$q"
}

# Hybrid quota check: total exclusive usage (uploads + all snapshots) against
# the configured limit. Over the limit: the uploads qgroup limit is set to 1
# byte (blocks writes) and .terminas-quota-exceeded is written. Under the
# limit: the configured limit is restored and the flag removed. One
# `btrfs qgroup show` call regardless of the number of snapshots.
hybrid_quota_check() {
    local user="$1"
    local home_dir="$HOME_MOUNT/$user"
    local limit_file="$home_dir/.terminas-quota-limit"
    local flag="$home_dir/.terminas-quota-exceeded"

    [ -f "$limit_file" ] || return 0
    local parsed
    parsed=$(parse_quota_value "$(cat "$limit_file" 2>/dev/null || echo 0)") || return 0
    local limit_bytes="${parsed%%|*}"
    local limit_display="${parsed##*|}"
    [ "$limit_bytes" -gt 0 ] 2>/dev/null || return 0

    local qgroup
    qgroup=$(uploads_qgroup_of "$user")
    [ -n "$qgroup" ] || return 0

    build_qgroup_usage_cache "$HOME_MOUNT" || return 0
    local total=$(( ${QG_UPLOADS_EXCL[$user]:-0} + ${QG_SNAP_EXCL[$user]:-0} ))
    local total_gb
    total_gb=$(awk -v b="$total" 'BEGIN { printf "%.2f", b / 1073741824 }')

    if [ "$total" -gt "$limit_bytes" ]; then
        btrfs qgroup limit 1 "$qgroup" "$HOME_MOUNT" 2>/dev/null || true
        if [ ! -f "$flag" ]; then
            log "QUOTA EXCEEDED: User $user is over quota (${total_gb}GB / ${limit_display}) - uploads blocked"
        fi
        echo "$total" > "$flag"
        chown root:root "$flag" 2>/dev/null || true
        chmod 644 "$flag" 2>/dev/null || true
    else
        btrfs qgroup limit "$limit_bytes" "$qgroup" "$HOME_MOUNT" 2>/dev/null || true
        if [ -f "$flag" ]; then
            rm -f "$flag"
            log "User $user: Quota restored - now at ${total_gb}GB / ${limit_display} (uploads unblocked)"
        else
            local pct
            pct=$(awk -v t="$total" -v l="$limit_bytes" 'BEGIN { printf "%.1f", (t / l) * 100 }')
            if [ "$(awk -v p="$pct" 'BEGIN { print (p > 90) ? 1 : 0 }')" -eq 1 ]; then
                log "WARNING: User $user approaching quota limit (${total_gb}GB / ${limit_display}, ${pct}%)"
            else
                log "Quota check OK: User $user at ${total_gb}GB / ${limit_display}"
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# Real-change test. A subvolume's generation also moves on metadata-only
# updates (atime from a directory listing, chmod, a pure deletion), which
# would otherwise produce empty snapshots every time a client lists the
# share. `btrfs subvolume find-new` reports data extents written after a
# generation using the tree's generation bounds, so it is cheap even on
# huge trees; only new data justifies a snapshot (the same semantics as the
# former close_write trigger).
# ---------------------------------------------------------------------------
has_new_data() {
    local user="$1"
    local since="$2"
    btrfs subvolume find-new "$HOME_MOUNT/$user/uploads" "$since" 2>/dev/null | grep -q '^inode '
}

# ---------------------------------------------------------------------------
# Snapshot creation
# Returns 0 = created, 1 = failed, 2 = nothing to snapshot
# ---------------------------------------------------------------------------
take_snapshot() {
    local user="$1"
    local reason="$2"
    local uploads="$HOME_MOUNT/$user/uploads"
    local versions="$HOME_MOUNT/$user/versions"

    if [ ! -d "$uploads" ]; then
        log "Skipping snapshot for $user: uploads subvolume does not exist"
        return 2
    fi
    if [ -z "$(find "$uploads" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        debug "Skipping snapshot for $user: uploads directory is empty"
        return 2
    fi

    if [ ! -d "$versions" ]; then
        mkdir -p "$versions"
        chown root:backupusers "$versions" 2>/dev/null || true
        chmod 755 "$versions" 2>/dev/null || true
    fi

    local ts
    ts=$(printf '%(%Y-%m-%d_%H-%M-%S)T' -1)
    local snap="$versions/$ts"
    if [ -e "$snap" ]; then
        log "Snapshot $snap already exists - skipping this cycle"
        return 1
    fi

    # Writable snapshot first so files still being uploaded can be removed
    # from it, then read-only for ransomware protection.
    if ! btrfs subvolume snapshot "$uploads" "$snap" >> "$LOG" 2>&1; then
        log "ERROR: Failed to create Btrfs snapshot for $user"
        return 1
    fi

    local excluded=0 f rel
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        rel="${f#$uploads/}"
        if [ -f "$snap/$rel" ]; then
            rm -f "$snap/$rel"
            excluded=$((excluded + 1))
            log "  Excluded: $rel (still open for writing)"
        fi
    done < <(list_open_write_files "$user")

    # Ownership/permissions must be set before the subvolume becomes read-only
    chown root:backupusers "$snap" 2>/dev/null || true
    chmod 755 "$snap" 2>/dev/null || true
    btrfs property set -ts "$snap" ro true >> "$LOG" 2>&1 || true

    if [ "$excluded" -gt 0 ]; then
        log "Btrfs snapshot created for $user at $ts ($reason, excluded $excluded in-progress files)"
    else
        log "Btrfs snapshot created for $user at $ts ($reason)"
    fi

    hybrid_quota_check "$user"
    return 0
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
declare -A last_gen        # generation seen at the previous poll
declare -A last_change     # epoch when the generation last changed
declare -A active_since    # epoch when the current activity burst started (0 = idle)
declare -A settled_gen     # generation already handled (snapshotted or nothing to do)
declare -A checked_gen     # generation last tested with find-new
declare -A has_data        # result of that test (1 = new data extents exist)

while true; do
    now=$(printf '%(%s)T' -1)
    # Heartbeat for `manage_users.sh status` (a hung loop stops updating it)
    : > "$RUNDIR/heartbeat"

    # One call for every subvolume: uploads generation and snapshot creation generations
    declare -A cur_gen=()
    declare -A newest_ogen=()
    while IFS='|' read -r user kind gen ogen; do
        [ -n "$user" ] || continue
        case "$kind" in
            uploads)
                cur_gen[$user]=$gen
                ;;
            snapshot)
                if [ "${ogen:-0}" -gt "${newest_ogen[$user]:-0}" ]; then
                    newest_ogen[$user]=$ogen
                fi
                ;;
        esac
    done < <(btrfs subvolume list -c "$HOME_MOUNT" 2>/dev/null | awk '{
        gen = ""; ogen = ""
        for (i = 1; i < NF; i++) {
            if ($i == "gen") gen = $(i + 1)
            if ($i == "cgen" || $i == "ogen") ogen = $(i + 1)
        }
        n = split($NF, seg, "/")
        if (n >= 2 && seg[n] == "uploads") {
            print seg[n-1] "|uploads|" gen "|" ogen
        } else if (n >= 3 && seg[n-1] == "versions") {
            print seg[n-2] "|snapshot|" gen "|" ogen
        }
    }')

    if [ "${#cur_gen[@]}" -eq 0 ]; then
        debug "No uploads subvolumes found under $HOME_MOUNT"
    fi

    for user in "${!cur_gen[@]}"; do
        gen=${cur_gen[$user]}
        [ -d "$HOME_MOUNT/$user/uploads" ] || continue

        if [ "$gen" != "${last_gen[$user]:-}" ]; then
            debug "User $user: generation ${last_gen[$user]:-none} -> $gen"
            last_gen[$user]=$gen
            last_change[$user]=$now
            [ "${active_since[$user]:-0}" -eq 0 ] && active_since[$user]=$now
            # A blocked user changing data (deletions) may now be under quota
            if [ -f "$HOME_MOUNT/$user/.terminas-quota-exceeded" ]; then
                hybrid_quota_check "$user"
            fi
        fi

        # Anything new since the newest snapshot (or since we last handled this generation)?
        if [ "$gen" -le "${newest_ogen[$user]:-0}" ] || [ "$gen" = "${settled_gen[$user]:-}" ]; then
            active_since[$user]=0
            [ -e "$RUNDIR/pending_$user" ] && rm -f "$RUNDIR/pending_$user"
            continue
        fi

        # Generation moved, but was any data written? Checked once per generation.
        if [ "$gen" != "${checked_gen[$user]:-}" ]; then
            checked_gen[$user]=$gen
            if has_new_data "$user" "${newest_ogen[$user]:-0}"; then
                has_data[$user]=1
            else
                has_data[$user]=0
                debug "User $user: generation $gen has no new data extents (metadata-only change) - no snapshot"
            fi
        fi
        if [ "${has_data[$user]:-0}" -eq 0 ]; then
            settled_gen[$user]=$gen
            active_since[$user]=0
            [ -e "$RUNDIR/pending_$user" ] && rm -f "$RUNDIR/pending_$user"
            continue
        fi

        # Uncaptured changes exist: record since when, for `manage_users.sh status`
        echo "${active_since[$user]}" > "$RUNDIR/pending_$user"

        idle=$(( now - last_change[$user] ))
        active=$(( now - active_since[$user] ))
        reason=""
        if [ "$idle" -ge "$INACTIVITY_WINDOW" ]; then
            reason="upload complete (no activity for ${idle}s)"
        elif [ "$active" -ge "$SNAPSHOT_INTERVAL" ]; then
            reason="periodic snapshot after ${active}s of continuous activity"
        fi
        [ -n "$reason" ] || continue

        take_snapshot "$user" "$reason"
        rc=$?
        if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
            settled_gen[$user]=$gen
            active_since[$user]=0
            rm -f "$RUNDIR/pending_$user"
        fi
    done

    sleep "$POLL_INTERVAL"
done
EOF
sed -i -e "s|__TERMINAS_VERSION__|$TERMINAS_VERSION|g" \
       -e "s|__TERMINAS_COMMIT__|$TERMINAS_COMMIT|g" \
       -e "s|__GENERATED_AT__|$(date '+%F %T')|g" /var/terminas/scripts/terminas-monitor.sh

chmod +x /var/terminas/scripts/terminas-monitor.sh

echo "Installing systemd unit for backup monitor..."
if [ -f /etc/systemd/system/terminas-monitor.service ]; then
    # Extract existing Environment variables
    existing_env=$(grep "^Environment=" /etc/systemd/system/terminas-monitor.service 2>/dev/null || true)
    cat > /etc/systemd/system/terminas-monitor.service <<'UNIT'
[Unit]
Description=termiNAS real-time backup monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /var/terminas/scripts/terminas-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    # Re-add any existing Environment variables
    if [ -n "$existing_env" ]; then
        # Insert Environment lines after [Service] line
        sed -i "/^\[Service\]/a $existing_env" /etc/systemd/system/terminas-monitor.service
        echo "  - Preserved existing environment variables"
    fi
else
    cat > /etc/systemd/system/terminas-monitor.service <<'UNIT'
[Unit]
Description=termiNAS real-time backup monitor
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /var/terminas/scripts/terminas-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

systemctl daemon-reload
systemctl enable terminas-monitor.service
systemctl restart terminas-monitor.service

# Tune inotify max_user_watches to support many users/directories
if [ ! -f /etc/sysctl.d/99-terminas-inotify.conf ]; then
    echo "Configuring inotify limits..."
    echo "fs.inotify.max_user_watches=524288" > /etc/sysctl.d/99-terminas-inotify.conf
    sysctl --system >/dev/null 2>&1 || true
fi

# Add logrotate config for the monitor log
echo "Configuring log rotation..."
cat > /etc/logrotate.d/terminas <<'LR'
/var/log/terminas.log /var/log/terminas-refresh-sizes.log {
    weekly
    rotate 12
    compress
    missingok
    notifempty
    create 640 root adm
}
LR

# Create retention policy configuration file (only if it doesn't exist)
if [ ! -f /etc/terminas-retention.conf ]; then
    echo "Creating retention policy configuration..."
    cat > /etc/terminas-retention.conf <<'CONF'
# termiNAS Retention Policy Configuration
# Edit this file to customize snapshot retention

# Default retention mode: advanced (recommended)
# Set to 'false' to use simple age-based retention
ENABLE_ADVANCED_RETENTION=true

# Simple age-based retention (days) - used when ENABLE_ADVANCED_RETENTION=false
# Snapshots older than this will be deleted
RETENTION_DAYS=30

# Advanced retention policy (Grandfather-Father-Son strategy)
# Keep: last N daily, last M weekly, last Y monthly snapshots
KEEP_DAILY=7        # Keep last 7 daily snapshots
KEEP_WEEKLY=4       # Keep last 4 weekly snapshots (one per week)
KEEP_MONTHLY=6      # Keep last 6 monthly snapshots (one per month)

# Per-user overrides (optional)
# Format: USERNAME_KEEP_DAILY=N, USERNAME_KEEP_WEEKLY=M, USERNAME_KEEP_MONTHLY=Y
# Note: For usernames with dashes (e.g., backup-server), replace dashes with
#       underscores in variable names (e.g., backup_server_KEEP_DAILY=30)
# Example:
#   produser_KEEP_DAILY=30
#   produser_KEEP_WEEKLY=12
#   produser_KEEP_MONTHLY=24
#   testuser_RETENTION_DAYS=7
#   testuser_ENABLE_ADVANCED_RETENTION=false

# Run cleanup at this hour (0-23)
CLEANUP_HOUR=3

# ============================================================================
# Quota Configuration
# ============================================================================
# Btrfs quotas limit total disk usage (uploads + all snapshots) per user
# Quotas are disabled by default when creating users (unlimited storage)

# Default quota for new users (in GB, 0 = unlimited)
DEFAULT_QUOTA_GB=0

# Per-user quota overrides (in GB)
# Note: For usernames with dashes (e.g., backup-server), replace dashes with
#       underscores in variable names (e.g., backup_server_QUOTA_GB=100)
# Example:
#   testuser_QUOTA_GB=50
#   produser_QUOTA_GB=500

# Quota warning threshold (percentage)
# Log warning when user reaches this % of quota
QUOTA_WARN_THRESHOLD=90
CONF
else
    echo "Retention policy configuration already exists, preserving existing settings"
fi

# Create/update cleanup script with configurable retention
echo "Creating/updating cleanup script..."
cat > /var/terminas/scripts/terminas-cleanup.sh <<'EOF'
#!/bin/bash
# Cleanup old snapshots based on retention policy
# Configuration: /etc/terminas-retention.conf
#
# Copyright (c) 2025 Yianni Bourkelis
# Licensed under the MIT License - see LICENSE file for details
# https://github.com/YiannisBourkelis/terminas

# Load configuration
if [ -f /etc/terminas-retention.conf ]; then
    source /etc/terminas-retention.conf
else
    # Defaults if config file is missing
    RETENTION_DAYS=30
    ENABLE_ADVANCED_RETENTION=false
fi

LOG=/var/log/terminas.log

# Shared helpers (installed by setup.sh)
if [ -f /var/terminas/scripts/common.sh ]; then
    source /var/terminas/scripts/common.sh
fi

log_msg() {
    echo "$(date '+%F %T') [CLEANUP] $*" >> "$LOG"
}

# Format bytes into a human-friendly quota string (prefers GB, falls back to MB).
format_quota_display() {
    local bytes="$1"
    if [ -z "$bytes" ] || ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
        echo "0GB"
        return 0
    fi
    local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    if echo "$gb >= 0.01" | bc -l >/dev/null 2>&1 && [ "$(echo "$gb >= 0.01" | bc)" -eq 1 ]; then
        printf "%.2fGB" "$gb"
    else
        local mb=$(echo "scale=0; $bytes / 1024 / 1024" | bc 2>/dev/null || echo "0")
        printf "%sMB" "$mb"
    fi
}

# Parse quota values with optional unit suffix.
# - raw: input string (e.g., "50", "50GB", "13000MB")
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

# Simple age-based cleanup
cleanup_by_age() {
    log_msg "Running age-based cleanup (keeping last $RETENTION_DAYS days)"
    local count=0
    while IFS= read -r -d '' snapshot; do
        # Check if it's a Btrfs subvolume before deleting
        if btrfs subvolume show "$snapshot" &>/dev/null; then
            # Make snapshot writable before deletion
            btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
            btrfs subvolume delete "$snapshot" &>/dev/null && count=$((count + 1))
        else
            # Fallback for non-subvolume directories (shouldn't happen in Btrfs setup)
            rm -rf "$snapshot" && count=$((count + 1))
        fi
    done < <(find /home -mindepth 2 -maxdepth 3 -type d -path '*/versions/*' -mtime +$RETENTION_DAYS -print0 2>/dev/null)
    log_msg "Removed $count snapshots older than $RETENTION_DAYS days"
}

# Advanced retention: keep daily, weekly, monthly snapshots
cleanup_advanced() {
    log_msg "Running advanced retention cleanup (default: daily=$KEEP_DAILY, weekly=$KEEP_WEEKLY, monthly=$KEEP_MONTHLY)"
    
    # Get list of backup users (both primary group members and supplementary group members)
    local gid=$(getent group backupusers 2>/dev/null | cut -d: -f3)
    local users=""
    
    # Get users whose primary group is backupusers
    if [ -n "$gid" ]; then
        users=$(getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}')
    fi
    
    # Also get users who have backupusers as supplementary group
    local supp_users=$(getent group backupusers 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    if [ -n "$supp_users" ]; then
        users=$(echo -e "$users\n$supp_users" | sort -u)
    fi
    
    while IFS= read -r user; do
        [ -z "$user" ] && continue
        local versions_dir="/home/$user/versions"
        [ ! -d "$versions_dir" ] && continue
        
        # Check for per-user retention settings
        # Sanitize username for variable names (replace hyphens with underscores)
        local user_safe="${user//-/_}"
        local user_daily_var="${user_safe}_KEEP_DAILY"
        local user_weekly_var="${user_safe}_KEEP_WEEKLY"
        local user_monthly_var="${user_safe}_KEEP_MONTHLY"
        local user_daily=${!user_daily_var:-$KEEP_DAILY}
        local user_weekly=${!user_weekly_var:-$KEEP_WEEKLY}
        local user_monthly=${!user_monthly_var:-$KEEP_MONTHLY}
        
        if [ "$user_daily" != "$KEEP_DAILY" ] || [ "$user_weekly" != "$KEEP_WEEKLY" ] || [ "$user_monthly" != "$KEEP_MONTHLY" ]; then
            log_msg "User $user: using custom retention (daily=$user_daily, weekly=$user_weekly, monthly=$user_monthly)"
        fi
        
        # Get all snapshots sorted by date (newest first)
        local snapshots=$(find "$versions_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -r)
        [ -z "$snapshots" ] && continue
        
        # Arrays to track what to keep
        declare -A keep_snapshots
        local snapshot_array=()
        while IFS= read -r s; do
            [ -n "$s" ] && snapshot_array+=("$s")
        done <<< "$snapshots"
        
        # GFS (Grandfather-Father-Son) retention strategy:
        # 1. Keep last N daily snapshots (recent backups)
        # 2. Keep one snapshot per week for N weeks (excluding dailies)
        # 3. Keep one snapshot per month for N months (excluding dailies and weeklies)
        
        # Mark last N daily snapshots
        local daily_count=0
        for snapshot in "${snapshot_array[@]}"; do
            [ $daily_count -ge $user_daily ] && break
            keep_snapshots["$snapshot"]="daily"
            daily_count=$((daily_count + 1))
        done
        
        # Mark last N weekly snapshots (one per week, skip if already kept as daily)
        local weekly_count=0
        local last_week=""
        for snapshot in "${snapshot_array[@]}"; do
            [ $weekly_count -ge $user_weekly ] && break
            [ -n "${keep_snapshots[$snapshot]}" ] && continue  # Already kept as daily
            
            # Extract date from snapshot name (format: YYYY-MM-DD_HH-MM-SS)
            local snap_date=$(basename "$snapshot" | cut -d_ -f1)
            local week=$(date -d "$snap_date" +%Y-W%U 2>/dev/null || echo "")
            if [ -n "$week" ] && [ "$week" != "$last_week" ]; then
                keep_snapshots["$snapshot"]="weekly"
                last_week="$week"
                weekly_count=$((weekly_count + 1))
            fi
        done
        
        # Mark last N monthly snapshots (one per month, skip if already kept as daily/weekly)
        local monthly_count=0
        local last_month=""
        for snapshot in "${snapshot_array[@]}"; do
            [ $monthly_count -ge $user_monthly ] && break
            [ -n "${keep_snapshots[$snapshot]}" ] && continue  # Already kept as daily/weekly
            
            local snap_date=$(basename "$snapshot" | cut -d_ -f1)
            local month=$(date -d "$snap_date" +%Y-%m 2>/dev/null || echo "")
            if [ -n "$month" ] && [ "$month" != "$last_month" ]; then
                keep_snapshots["$snapshot"]="monthly"
                last_month="$month"
                monthly_count=$((monthly_count + 1))
            fi
        done
        
        # Remove snapshots not in keep list
        local removed=0
        local kept=0
        for snapshot in "${snapshot_array[@]}"; do
            local snap_name=$(basename "$snapshot")
            if [ -z "${keep_snapshots[$snapshot]}" ]; then
                # Check if it's a Btrfs subvolume before deleting
                if btrfs subvolume show "$snapshot" &>/dev/null; then
                    # Make snapshot writable before deletion
                    btrfs property set -ts "$snapshot" ro false 2>/dev/null || true
                    if btrfs subvolume delete "$snapshot" &>/dev/null; then
                        log_msg "User $user: deleted snapshot $snap_name"
                        removed=$((removed + 1))
                    fi
                else
                    # Fallback for non-subvolume directories (shouldn't happen)
                    if rm -rf "$snapshot"; then
                        log_msg "User $user: deleted snapshot $snap_name"
                        removed=$((removed + 1))
                    fi
                fi
            else
                kept=$((kept + 1))
            fi
        done
        
        if [ $removed -gt 0 ] || [ $kept -gt 0 ]; then
            log_msg "User $user: kept $kept snapshots, removed $removed snapshots"
        fi
    done <<< "$users"
}

# Main cleanup logic
if [ "$ENABLE_ADVANCED_RETENTION" = "true" ]; then
    cleanup_advanced
else
    cleanup_by_age
fi

log_msg "Cleanup completed"

# Re-check quota for users who are blocked (uploads quota set to 0 or 1)
# This allows users to regain access after deleting files
recheck_blocked_quotas() {
    log_msg "Checking for blocked users who may now be under quota..."

    # One qgroup query for all users (see build_qgroup_usage_cache in common.sh)
    local have_qgroups=false
    if type build_qgroup_usage_cache >/dev/null 2>&1 && build_qgroup_usage_cache /home; then
        have_qgroups=true
    fi
    
    # Get list of backup users
    local gid=$(getent group backupusers 2>/dev/null | cut -d: -f3)
    local users=""
    if [ -n "$gid" ]; then
        users=$(getent passwd | awk -F: -v gid="$gid" '$4 == gid {print $1}')
    fi
    local supp_users=$(getent group backupusers 2>/dev/null | cut -d: -f4 | tr ',' '\n' | grep -v '^$')
    if [ -n "$supp_users" ]; then
        users=$(echo -e "$users\n$supp_users" | sort -u)
    fi
    
    while IFS= read -r user; do
        [ -z "$user" ] && continue
        local home_dir="/home/$user"
        
        # Only check users with quota exceeded flag
        [ ! -f "$home_dir/.terminas-quota-exceeded" ] && continue
        
        # Get configured quota limit
        local quota_limit_raw=$(cat "$home_dir/.terminas-quota-limit" 2>/dev/null || echo "0")
        local quota_limit_bytes=0
        local quota_limit_display="0GB"
        if quota_parsed=$(parse_quota_value "$quota_limit_raw"); then
            quota_limit_bytes=$(echo "$quota_parsed" | cut -d'|' -f1)
            quota_limit_display=$(echo "$quota_parsed" | cut -d'|' -f4)
        fi
        [ "$quota_limit_bytes" -eq 0 ] && continue
        
        # Total exclusive usage (uploads + all snapshots) from the qgroup cache
        [ "$have_qgroups" = true ] || continue
        local uploads_qgroup=""
        [ -f "$home_dir/.terminas-qgroup" ] && uploads_qgroup=$(cat "$home_dir/.terminas-qgroup" 2>/dev/null)
        if [ -z "$uploads_qgroup" ] || [[ "$uploads_qgroup" == 1/* ]]; then
            local uploads_subvol_id=$(btrfs subvolume show "$home_dir/uploads" 2>/dev/null | grep -oP 'Subvolume ID:\s+\K[0-9]+' || echo "")
            [ -n "$uploads_subvol_id" ] && uploads_qgroup="0/$uploads_subvol_id"
        fi
        local total_exclusive_bytes=$(( ${QG_UPLOADS_EXCL[$user]:-0} + ${QG_SNAP_EXCL[$user]:-0} ))

        local total_gb=$(echo "scale=2; $total_exclusive_bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
        
        # Check if now under quota
        if [ "$total_exclusive_bytes" -le "$quota_limit_bytes" ]; then
            # UNDER QUOTA: Restore normal uploads limit
            if [ -n "$uploads_qgroup" ]; then
                btrfs qgroup limit "$quota_limit_bytes" "$uploads_qgroup" /home 2>/dev/null || true
                rm -f "$home_dir/.terminas-quota-exceeded" 2>/dev/null || true
                log_msg "User $user: Quota restored - now at ${total_gb}GB / ${quota_limit_display} (uploads unblocked)"
            fi
        else
            log_msg "User $user: Still over quota at ${total_gb}GB / ${quota_limit_display}"
        fi
    done <<< "$users"
}

# Run quota recheck after cleanup (cleanup may have freed space)
recheck_blocked_quotas

log_msg "All maintenance tasks completed"
EOF
chmod +x /var/terminas/scripts/terminas-cleanup.sh

# Install daily cron job for cleanup (run at configured hour) - only if not already present
if ! crontab -l 2>/dev/null | grep -q "terminas-cleanup.sh"; then
    echo "Installing cleanup cron job..."
    (crontab -l 2>/dev/null; echo "0 3 * * * /var/terminas/scripts/terminas-cleanup.sh") | crontab -
else
    echo "Cleanup cron job already exists"
fi

# Nightly size-cache refresh for manage_users.sh list/info (30 minutes after cleanup)
if ! crontab -l 2>/dev/null | grep -q "manage_users.sh refresh-sizes"; then
    echo "Installing size-cache refresh cron job..."
    (crontab -l 2>/dev/null; echo "30 3 * * * $SCRIPT_DIR/manage_users.sh refresh-sizes >> /var/log/terminas-refresh-sizes.log 2>&1") | crontab -
else
    echo "Size-cache refresh cron job already exists"
fi

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Create backup users: ./create_user.sh <username>"
echo "  2. Monitor logs: tail -f /var/log/terminas.log"
echo "  3. Check service: systemctl status terminas-monitor.service"
echo "  4. Manage users: ./manage_users.sh list  (sizes appear after: ./manage_users.sh refresh-sizes)"
echo ""
echo "Configuration files:"
echo "  - Retention policy: /etc/terminas-retention.conf"
echo "  - Monitor service: /etc/systemd/system/terminas-monitor.service"
echo "  - Scripts: /var/terminas/scripts/"
echo "  - Log file: /var/log/terminas.log"
echo ""