# System Initialization Script

A comprehensive bash script for initializing a new Linux system (Debian/Ubuntu), setting up basic security configurations, and installing essential services.

## Features

1. **System Configuration**
   - Automatic timezone detection and configuration
   - APT mirror selection (for Debian)
   - System update and upgrade
   - Disables hibernation (Debian only)

2. **Package Management**
   - Removes snap packages (Ubuntu only)
   - Configures APT sources with preferred mirrors (Debian only)
   - Supports USTC, TUNA, and Aliyun mirrors

3. **SSH Server Setup**
   - Installs and configures SSH server
   - Configures secure SSH settings
   - Disables root login and password authentication
   - Changes default SSH port
   - Creates backup of SSH configuration

4. **User Management**
   - Creates new user with home directory
   - Adds user to sudo group
   - Sets up SSH key authentication
   - Configures proper permissions for SSH files

5. **Optional Software Installation**
   - Docker with Chinese registry mirrors
   - Git installation and updates
   - Docker permissions and group setup
   - Automatic service configuration

6. **Error Handling**
   - Logs all errors to `error.log`
   - Implements automatic retry for network-related errors
   - Continues execution even if some steps fail
   - Provides summary of failed steps at the end

## Prerequisites

- Root privileges
- Internet connection
- Supported Linux distributions:
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
1. Timezone configuration
2. APT mirror selection (Debian only)
3. Snap removal confirmation (Ubuntu only)
4. New username creation
5. SSH public key addition
6. Custom SSH port number
7. Docker installation preference
8. Git installation preference

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
   - The script automatically backs up SSH and APT configurations

2. **SSH Access**
   - Keep the SSH port number you choose
   - Ensure you have the corresponding private key
   - Test the new SSH configuration before closing existing sessions

3. **Docker Configuration**
   - Uses multiple registry mirrors for better availability
   - Configures proper user permissions
   - Includes automatic service startup

4. **System Specific**
   - APT mirror configuration only available for Debian
   - Snap removal only available for Ubuntu
   - Hibernation disable only applies to Debian

5. **Error Recovery**
   - Automatic retry for network-related errors
   - Detailed logging of all operations
   - Continues execution even after non-critical failures

## Troubleshooting

1. Check `error.log`