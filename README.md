# System Initialization Script

A comprehensive bash script for initializing a new Linux system (Debian/Ubuntu), setting up basic security configurations, and installing essential services.

## Features

1. **Package Manager Detection**
   - Automatically detects and uses apt/dnf/yum
   - Supports Debian, Ubuntu systems

2. **System Cleanup and Update**
   - Removes snap packages (Ubuntu only)
   - Performs system update and upgrade
   - Disables hibernation (Debian only)

3. **SSH Server Setup**
   - Installs and configures SSH server
   - Configures secure SSH settings
   - Disables root login and password authentication
   - Changes default SSH port

4. **User Management**
   - Creates new user with home directory
   - Adds user to sudo/wheel group
   - Sets up SSH key authentication
   - Configures proper permissions for SSH files

5. **Docker Environment**
   - Installs Docker and Docker Compose
   - Configures Docker daemon with Chinese mirrors
   - Sets up user permissions for Docker
   - Creates backward compatibility links for Docker Compose

6. **Error Handling**
   - Logs all errors to `error.log`
   - Continues execution even if some steps fail
   - Provides summary of failed steps at the end

## Prerequisites

- Root privileges
- Internet connection
- One of the supported Linux distributions:
  - Debian
  - Ubuntu

## Usage

1. Download the script:
   ```bash
   wget https://raw.githubusercontent.com/gtzjh/myserver/main/init.sh
   ```

2. Make it executable:
   ```bash
   chmod +x init.sh
   ```

3. Run with root privileges:
   ```bash
   sudo ./init_system.sh
   ```

## Interactive Inputs Required

The script will prompt for:
1. Confirmation to remove snap (Ubuntu only)
2. New username
3. Password for the new user
4. SSH public key
5. Custom SSH port number

## Security Features

- Disables root SSH login
- Enforces key-based authentication
- Disables password authentication
- Configures proper file permissions
- Changes default SSH port
- Limits user access through AllowUsers directive

## Error Handling

- All errors are logged to `error.log` in the same directory as the script
- The script continues execution even if some steps fail
- At the end, it displays which steps failed (if any)
- Detailed error messages can be found in the log file

## Notes and Cautions

1. **Backup**
   - Always backup important data before running this script
   - The script creates a backup of the SSH configuration

2. **SSH Access**
   - Keep the SSH port number you choose
   - Ensure you have the corresponding private key
   - Test the new SSH configuration before closing existing sessions

3. **Docker Configuration**
   - Docker is configured with Chinese mirrors by default
   - Modify `daemon.json` if different mirrors are needed

4. **System Specific**
   - Some features only work on specific distributions
   - The script automatically detects and adapts to the system

5. **Firewall**
   - For Debian/Ubuntu, you may need to configure UFW separately

## Troubleshooting

1. Check `error.log` for detailed error messages
2. Ensure you have root privileges
3. Verify internet connectivity
4. Ensure your system is one of the supported distributions