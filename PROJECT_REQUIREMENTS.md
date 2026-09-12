# Project Requirements: termiNAS Backup Server

## Original User Requirements
"create a script that will ran in debian and will setup the following: I want remote clients to be able to upload files or directories using scp or sftp. The server, will store the files to the user specific folder with versioning for ransomware protection. Even if the user machine is infected with malware and the malware encryptes or deletes files localy, it should not be able to modify the verion info of the file. The client can download a versioned copy of the files. Create a script thet will setup in debian such an environment and Create a script that will accept a user name and will create this user with a long secure default password. After that the user should be able to upload files securely with versioning support."

Additional Requirements:
- The users should not be able to access/view anywhere except their home folder.
- The server should monitor users filesystem for changes and create a snapshot as soon as a new file is added/removed etc.

## Clarified Understanding
This project aims to create a secure, versioned backup server on Debian Linux. Key features include:

### Core Functionality
- **Remote Uploads**: Clients can upload files or directories to the server using SFTP (SCP is not supported with chroot for security reasons).
- **User-Specific Storage**: Each user has their own dedicated folder on the server for storing uploaded files.
- **Versioning for Ransomware Protection**:
  - Uploaded files are automatically versioned (snapshotted) to prevent data loss from ransomware.
  - Even if a client's local machine is infected (e.g., files encrypted or deleted locally), the server-side version information remains intact and unmodifiable by the client.
  - Versions are stored in an immutable manner (read-only for users, owned by root).
- **Download Access**: Clients can download previous versions of their files from the server.

### Scripts to Implement
1. **Setup Script (`setup.sh`)**:
   - Installs and configures necessary software on a Debian system (e.g., OpenSSH with internal-sftp for restricted access).
   - Sets up SSH/SFTP with security best practices (e.g., no root login, chrooted SFTP).
   - Creates a group for backup users.
   - Configures real-time versioning: a monitor service detects changes to each user's uploads (by polling Btrfs generation numbers) and creates read-only Btrfs snapshots.
   - Prepares the server environment for user creation.

2. **User Creation Script (`create_user.sh <username>`)**:
   - Accepts a username as input.
   - Creates a new system user with a long, secure default password (generated randomly).
   - Sets up user-specific directories: `uploads/` (writable) and `versions/` (read-only snapshots).
   - Assigns the user to the backup group and restricts shell to nologin (SFTP-only access).
   - Ensures the user can immediately start uploading files, which will be versioned automatically.

### Security and Protection
- **Ransomware Mitigation**: Versioned snapshots are owned by root and not modifiable by users, preventing malware from altering or deleting historical versions.
- **Access Control**: Users are chrooted to their home directories with SFTP-only access; no shell or SCP access.
- **Authentication**: Uses SSH keys or passwords (with strong defaults); can be configured for key-only later.
- **Data Integrity**: Snapshots are read-only Btrfs subvolumes; copy-on-write means unchanged blocks are shared between versions, so full version history costs only the changed data.

### Assumptions and Scope
- Target OS: Debian Linux (tested on recent versions).
- No advanced features like encryption at rest, web UI, or cloud integration (can be added later).
- Versioning is near-real-time: a snapshot follows the end of an upload by about a minute (the monitor waits for activity to stop, then snapshots once), with periodic snapshots during very long uploads.
- Scripts require root/sudo access for installation and user management.
- Clients use standard tools like SFTP clients (e.g., FileZilla, WinSCP) or `sftp` command for uploads/downloads.

### Future Enhancements (Not in Initial Scope)


This document serves as a reference for development, testing, and future feature requests.