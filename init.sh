#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run this script with root privileges"
    exit 1
fi

# Check system type and package manager
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    # Determine package manager
    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update && apt upgrade -y"
        PKG_INSTALL="apt install -y"
    else
        echo "No supported package manager found (only apt is supported)"
        exit 1
    fi
else
    echo "Cannot determine OS type"
    exit 1
fi

# Add near the beginning of the script, after OS detection
OS_LC=$(echo "$OS" | tr '[:upper:]' '[:lower:]')  # lowercase OS name

# Set system timezone
set_timezone() {
    {
        echo "[INFO] Checking system timezone..."
        current_tz=$(timedatectl show --property=Timezone --value)
        echo "Current system timezone: $current_tz"
        
        # Detect timezone by IP
        echo "[INFO] Detecting timezone based on IP..."
        detected_tz=$(curl -s --max-time 5 http://ip-api.com/line/?fields=timezone || true)
        
        # Display timezone options
        echo "Choose an option:"
        echo "1. Keep current system timezone [$current_tz]"
        if [ -n "$detected_tz" ] && timedatectl list-timezones | grep -q "^$detected_tz$"; then
            echo "2. Use detected timezone [$detected_tz]"
        fi
        echo "3. Manually select timezone"
        read -p "Enter choice (1-3): " tz_choice
        
        case $tz_choice in
            2)  
                if [ -n "$detected_tz" ]; then
                    new_timezone=$detected_tz
                else
                    echo "[ERROR] No detected timezone available"
                    return 1
                fi
                ;;
            3)  
                echo "Available timezones:"
                timedatectl list-timezones
                while true; do
                    read -p "Enter your timezone (e.g., Asia/Shanghai): " new_timezone
                    if timedatectl list-timezones | grep -q "^$new_timezone$"; then
                        break
                    else
                        echo "[ERROR] Invalid timezone. Please try again."
                    fi
                done
                ;;
            *)  
                echo "[INFO] Keeping current timezone: $current_tz"
                return 0
                ;;
        esac

        # Set new timezone if selected
        if [ -n "$new_timezone" ]; then
            if timedatectl set-timezone "$new_timezone"; then
                echo "[SUCCEED] Timezone successfully set to: $new_timezone"
                if ! hwclock --systohc; then
                    echo "[WARN] Failed to sync hardware clock"
                fi
            else
                echo "[ERROR] Failed to set timezone"
                return 1
            fi
        fi
    } || handle_error "Set Timezone" "$?"
}


# Configuration choices
get_user_choices() {
    echo "System initialization configuration"
    echo "----------------------------------------"
    
    # Choice 1/7: Select APT mirror
    echo "Choice (1/7): APT Mirror Selection"
    select_apt_mirror

    # Choice 2/7: Remove snap
    echo -e "\nChoice (2/7): Remove snap?"
    if [[ "$OS" == *"Ubuntu"* ]]; then
        echo "Do you want to remove snap? (y/n)"
        read -r remove_snap_choice
    else
        remove_snap_choice="n"
    fi

    # Choice 3/7: Create new user
    echo -e "\nChoice (3/7): User creation"
    echo "Do you want to create a new user? (y/n)"
    read -r create_user_choice
    
    if [ "$create_user_choice" = "y" ]; then
        echo "Enter new username:"
        read -r new_username
    fi

    # Choice 4/7: SSH key
    echo -e "\nChoice (4/7): SSH configuration"
    echo "Do you want to add SSH public key? (y/n)"
    read -r add_ssh_key_choice
    
    if [ "$add_ssh_key_choice" = "y" ] && [ "$create_user_choice" != "y" ]; then
        echo "Note: You need to create a user to add SSH key"
        add_ssh_key_choice="n"
    fi

    # Choice 5/7: SSH port
    echo -e "\nChoice (5/7): SSH port configuration"
    echo "Do you want to change the SSH port? [y/n]"
    read -r change_ssh_port
    if [ "$change_ssh_port" = "y" ]; then
        while true; do
            read -r -p "Enter new SSH port (recommended: greater than 1024): " ssh_port
            if [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -gt 1024 ] && [ "$ssh_port" -lt 65536 ]; then
                break
            else
                echo "[ERROR] Invalid port number. Please enter a number between 1024 and 65535"
            fi
        done
    fi

    # Choice 6/7: Install Docker
    echo -e "\nChoice (6/7): Docker Installation"
    echo "Do you want to install Docker? (y/n)"
    read -r install_docker_choice
    
    # Choice 7/7: Install Git
    echo -e "\nChoice (7/7): Git Installation"
    echo "Do you want to install Git? (y/n)"
    read -r install_git_choice
    
    echo -e "\nConfiguration complete. Starting system initialization..."
    echo "----------------------------------------"
}


# Error handling function
handle_error() {
    local step=$1
    local error_code=$2
    local error_msg=${3:-"Unknown error"}  # Add default error message
    local max_retries=${MAX_RETRIES:-3}
    local retry_count=0
    local wait_time=5
    
    # Log error
    log_error "$step" "$error_code" "$error_msg"
    
    # 根据错误类型决定是否重试
    case $error_code in
        1)  # 一般错误
            echo "[ERROR] General error in $step"
            return 1
            ;;
        100|101|102)  # 网络错误
            while [ $retry_count -lt $max_retries ]; do
                echo "[RETRY] Attempting retry $((retry_count + 1))/$max_retries for $step"
                sleep $wait_time
                ((wait_time *= 2))
                ((retry_count++))
                
                if "$@"; then
                    echo "[SUCCEED] Retry successful"
                    return 0
                fi
            done
            ;;
        126|127)  # 命令不存在
            echo "[ERROR] Required command not found"
            if ! install_dependencies; then
                return 1
            fi
            ;;
        *)  # 其他错误
            echo "[ERROR] Unhandled error in $step"
            return 1
            ;;
    esac
    
    FAILED_STEPS+=("$step")
    return 1
}

log_error() {
    local step=$1
    local error_code=$2
    local error_msg=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] ERROR in $step (Code: $error_code)" >> "$ERROR_LOG"
    echo "Message: $error_msg" >> "$ERROR_LOG"
    echo "Command: $BASH_COMMAND" >> "$ERROR_LOG"
    echo "----------------------------------------" >> "$ERROR_LOG"
}

# Select APT mirror function
select_apt_mirror() {
    if [[ "$OS" == *"Debian"* || "$OS" == *"Ubuntu"* ]]; then
        # Display current mirror
        echo "[INFO] Current APT mirror configuration:"
        current_mirror=$(grep -v '^#' /etc/apt/sources.list | grep '^deb' | head -n1 | awk '{print $2}' | sed 's|https://||;s|http://||;s|/.*||')
        echo "Current mirror: $current_mirror"
        
        echo "Please select your preferred mirror:"
        if [[ "$OS" == *"Debian"* ]]; then
            echo "1) USTC Mirror (University of Science and Technology of China)"
            echo "2) TUNA Mirror (Tsinghua University)"
            echo "3) Aliyun Mirror (Alibaba Cloud)"
        else  # Ubuntu
            echo "1) USTC Mirror (University of Science and Technology of China)"
            echo "2) TUNA Mirror (Tsinghua University)"
            echo "3) Aliyun Mirror (Alibaba Cloud)"
        fi
        echo "n) Keep current mirror"
        read -r -p "Enter your choice (1|2|3|n) [default: n]: " mirror_choice
        mirror_choice=${mirror_choice:-n}
        
        case $mirror_choice in
            1)
                if [[ "$OS" == *"Debian"* ]]; then
                    MIRROR_URL="mirrors.ustc.edu.cn/debian"
                else
                    MIRROR_URL="mirrors.ustc.edu.cn/ubuntu"
                fi
                MIRROR_NAME="USTC Mirror"
                ;;
            2)
                if [[ "$OS" == *"Debian"* ]]; then
                    MIRROR_URL="mirrors.tuna.tsinghua.edu.cn/debian"
                else
                    MIRROR_URL="mirrors.tuna.tsinghua.edu.cn/ubuntu"
                fi
                MIRROR_NAME="TUNA Mirror"
                ;;
            3)
                if [[ "$OS" == *"Debian"* ]]; then
                    MIRROR_URL="mirrors.aliyun.com/debian"
                else
                    MIRROR_URL="mirrors.aliyun.com/ubuntu"
                fi
                MIRROR_NAME="Aliyun Mirror"
                ;;
            *)
                MIRROR_URL=""
                MIRROR_NAME="Default Mirror"
                echo "Keeping current sources"
                ;;
        esac
        [ -n "$MIRROR_URL" ] && echo "Selected: $MIRROR_NAME"
    fi
}

# Configure APT sources
configure_apt_sources() {
    {
        echo "[INFO] Configuring APT sources..."
        
        if [[ "$OS" == *"Debian"* || "$OS" == *"Ubuntu"* ]] && [ -n "$MIRROR_URL" ]; then
            # Create backup directory
            local backup_dir="/etc/apt/backups"
            mkdir -p "$backup_dir"
            
            # Backup original sources with timestamp
            if [ -f /etc/apt/sources.list ]; then
                local backup_file="$backup_dir/sources.list.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp /etc/apt/sources.list "$backup_file"; then
                    echo "[ERROR] Failed to backup sources.list"
                    return 1
                fi
                echo "[SUCCEED] Backed up original sources.list to $backup_file"
                
                # Clean up old backups
                cleanup_backups
            fi
            
            if [[ "$OS" == *"Debian"* ]]; then
                VERSION_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
                VERSION_NUM=$(. /etc/os-release && echo "$VERSION_ID")
                
                echo "[INFO] Configuring Debian sources with $MIRROR_NAME ($MIRROR_URL)"
                
                # Configure different sources based on Debian version
                if [ "$VERSION_NUM" -ge 12 ]; then
                    # Debian 12 (Bookworm) and above includes non-free-firmware
                    cat > /etc/apt/sources.list << EOF
# Debian $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main contrib non-free non-free-firmware
deb http://$MIRROR_URL $VERSION_CODE-updates main contrib non-free non-free-firmware
deb http://$MIRROR_URL $VERSION_CODE-backports main contrib non-free non-free-firmware
deb http://$MIRROR_URL-security $VERSION_CODE-security main contrib non-free non-free-firmware
EOF
                else
                    # Debian 11 (Bullseye) and below
                    cat > /etc/apt/sources.list << EOF
# Debian $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main contrib non-free
deb http://$MIRROR_URL $VERSION_CODE-updates main contrib non-free
deb http://$MIRROR_URL $VERSION_CODE-backports main contrib non-free
deb http://$MIRROR_URL-security $VERSION_CODE-security main contrib non-free
EOF
                fi
            else  # Ubuntu
                VERSION_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
                
                echo "[INFO] Configuring Ubuntu sources with $MIRROR_NAME ($MIRROR_URL)"
                
                cat > /etc/apt/sources.list << EOF
# Ubuntu $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-updates main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-backports main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-security main restricted universe multiverse
EOF
            fi
            
            # Verify file creation and content
            if [ -f /etc/apt/sources.list ] && [ -s /etc/apt/sources.list ]; then
                echo "[SUCCEED] APT sources configured for $OS"
                echo "[SUCCEED] Using $MIRROR_NAME"
                
                # Test new source availability
                if apt-get update -qq &>/dev/null; then
                    echo "[SUCCEED] APT sources update completed"
                else
                    echo "[ERROR] Failed to update APT sources"
                    # Restore backup
                    cp "$backup_file" /etc/apt/sources.list
                    echo "[INFO] Restored original sources.list from backup"
                    return 1
                fi
            else
                echo "[ERROR] Failed to write sources.list"
                return 1
            fi
            
        else
            echo "[WARN] Skipping APT source configuration: either unsupported system or no mirror selected"
        fi
        
    } || handle_error "Configure APT Sources" "$?"
}

# 1. Remove snap (Ubuntu only)
remove_snap() {
    {
        if [[ "$OS" == *"Ubuntu"* && "$remove_snap_choice" = "y" ]]; then
            echo "Removing snap packages..."
            # First remove LXD if installed
            if snap list | grep -q lxd; then
                echo "Removing LXD..."
                snap remove lxd
            fi
            
            # Remove all snap packages
            echo "Removing all snap packages..."
            snap list | awk 'NR>1 {print $1}' | xargs -I {} sudo snap remove {}
            
            # Clean up snap directories
            rm -rf ~/snap/
            rm -rf /snap
            rm -rf /var/snap
            rm -rf /var/lib/snapd
            
            # Prevent snap from being installed automatically
            apt-mark hold snapd
        fi
    } || handle_error "Remove Snap" "$?"
}

# 2. System update
system_update() {
    {
        eval "$PKG_UPDATE"
    } || handle_error "System Update" "$?"
}

# 3. Disable hibernation (Debian only)
disable_hibernation() {
    {
        if [[ "$OS" == *"Debian"* ]]; then
            systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
            echo "Hibernation disabled"
        fi
    } || handle_error "Disable Hibernation" "$?"
}

# 4. Check and install SSH server
setup_ssh() {
    {
        if ! systemctl is-active --quiet sshd; then
            $PKG_INSTALL openssh-server
            systemctl enable sshd
            systemctl start sshd
        fi
    } || handle_error "Setup SSH" "$?"
}

# 5. Create new user
create_user() {
    {
        # Validate username
        local username_regex="^[a-z_][a-z0-9_-]*[$]?$"
        while true; do
            if [ -z "$new_username" ]; then
                read -p "Enter new username: " new_username
            fi
            
            if [[ ! $new_username =~ $username_regex ]]; then
                echo "[ERROR] Invalid username format. Use only lowercase letters, numbers, - and _"
                new_username=""
                continue
            fi
            
            if id "$new_username" &>/dev/null; then
                echo "[ERROR] User $new_username already exists"
                new_username=""
                continue
            fi
            break
        done

        echo "[INFO] Creating user $new_username..."
        if ! useradd -m -s /bin/bash "$new_username"; then
            echo "[ERROR] Failed to create user"
            return 1
        fi
        
        # Set password policy
        echo "[INFO] Setting password policy..."
        if ! apt-get install -y libpam-pwquality; then
            echo "[WARN] Failed to install password quality checker"
        fi
        
        # Set password
        while true; do
            if passwd "$new_username"; then
                break
            else
                echo "[ERROR] Password setting failed. Please try again."
            fi
        done
        
        # Add to sudo group
        if ! usermod -aG sudo "$new_username"; then
            echo "[WARN] Failed to add user to sudo group"
        fi
        
        # Configure SSH
        if [ "$add_ssh_key_choice" = "y" ]; then
            setup_ssh_for_user "$new_username"
        fi
        
        echo "[SUCCEED] User $new_username created successfully"
    } || handle_error "Create User" "$?"
}

setup_ssh_for_user() {
    local username=$1
    local ssh_dir="/home/$username/.ssh"
    
    # Create and set .ssh directory permissions
    if ! mkdir -p "$ssh_dir"; then
        echo "[ERROR] Failed to create SSH directory"
        return 1
    fi
    
    # Set correct permissions
    chmod 700 "$ssh_dir"
    touch "$ssh_dir/authorized_keys"
    chmod 600 "$ssh_dir/authorized_keys"
    chown -R "$username:$username" "$ssh_dir"

    echo "Enter SSH public key (paste and press Enter, then Ctrl+D when done):"
    if ! cat > "$ssh_dir/authorized_keys"; then
        echo "[ERROR] Failed to write SSH key"
        return 1
    fi
    
    # Verify SSH key format
    if ! ssh-keygen -l -f "$ssh_dir/authorized_keys" &>/dev/null; then
        echo "[ERROR] Invalid SSH key format"
        return 1
    fi
}

# 6. Configure SSH
configure_ssh() {
    {
        # Use previously obtained ssh_port
        if [ -z "$ssh_port" ]; then
            echo "[ERROR] SSH port not set"
            return 1
        fi
        
        # Backup original config
        cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

        # Modify SSH config
        cat > /etc/ssh/sshd_config << EOF
Port $ssh_port
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

SyslogFacility AUTH
LogLevel INFO

PermitRootLogin no
StrictModes yes
MaxAuthTries 3

PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no

UsePAM yes
X11Forwarding no
PrintMotd no

AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server

AllowUsers $new_username
EOF

        if systemctl restart sshd; then
            echo "[SUCCEED] SSH service restarted successfully"
        else
            echo "[ERROR] Failed to restart SSH service"
            return 1
        fi
    } || handle_error "Configure SSH" "$?"
}

# 7. Install Docker
install_docker() {
    if [ "$install_docker_choice" = "y" ]; then
        {
            echo "[INFO] Starting Docker installation..."
            
            # Check if Docker is already installed
            if command -v docker &>/dev/null; then
                echo "[INFO] Docker is already installed. Version: $(docker --version)"
                read -p "Do you want to reinstall Docker? (y/n): " reinstall
                if [ "$reinstall" != "y" ]; then
                    echo "[INFO] Skipping Docker installation"
                    return 0
                fi
            fi
            
            # Clean up old versions
            echo "[INFO] Removing old Docker installations..."
            if ! remove_old_docker; then
                echo "[WARN] Failed to remove old Docker installations"
                # Continue anyway as this might be a fresh install
            fi
            
            # Install new version
            echo "[INFO] Installing new Docker version..."
            if ! install_new_docker; then
                echo "[ERROR] Failed to install Docker"
                return 1
            fi
            
            # Configure Docker
            echo "[INFO] Configuring Docker..."
            if ! configure_docker; then
                echo "[ERROR] Failed to configure Docker"
                return 1
            fi
            
            # Verify installation
            echo "[INFO] Verifying Docker installation..."
            if ! verify_docker_installation; then
                echo "[ERROR] Docker installation verification failed"
                return 1
            fi
            
            echo "[SUCCEED] Docker installation completed successfully"
            return 0
            
        } || handle_error "Install Docker" "$?"
    fi
}


# 8. Install Git
install_git() {
    {
        if [ "$install_git_choice" = "y" ]; then
            # Check if Git is already installed
            if command -v git &>/dev/null; then
                echo "Git is already installed. Checking for updates..."
                
                # Get current version
                current_version=$(git --version | awk '{print $3}')
                
                # Check and update
                if apt list --upgradable 2>/dev/null | grep -q "^git/"; then
                    echo "Upgrading Git..."
                    apt install -y --only-upgrade git
                    new_version=$(git --version | awk '{print $3}')
                    echo "Git upgraded from $current_version to $new_version"
                else
                    echo "Git is already the latest version ($current_version)"
                fi
            else
                echo "Installing latest version of Git..."
                apt install -y git
                echo "Git installed successfully. Version: $(git --version)"
            fi
            
            # Configure Git global settings
            if [ -n "$new_username" ]; then
                echo "Do you want to configure Git for $new_username? (y/n)"
                read -r configure_git
                if [ "$configure_git" = "y" ]; then
                    su - "$new_username" -c 'read -p "Enter Git user name: " git_name && git config --global user.name "$git_name"'
                    su - "$new_username" -c 'read -p "Enter Git email: " git_email && git config --global user.email "$git_email"'
                    echo "[SUCCEED] Git configured for $new_username"
                fi
            fi
        fi
    } || handle_error "Install Git" "$?"
}

# Add this function at the beginning of the script
load_config() {
    local config_file="/etc/system-init.conf"
    if [ -f "$config_file" ]; then
        # shellcheck source=/dev/null
        source "$config_file"
    else
        # Create default configuration
        cat > "$config_file" << EOF
# System initialization configuration
MAX_RETRIES=3
DEFAULT_TIMEZONE="UTC"
SSH_PORT_MIN=1024
SSH_PORT_MAX=65535
BACKUP_RETENTION_DAYS=30
LOG_LEVEL="INFO"  # DEBUG, INFO, WARN, ERROR
EOF
    fi
}

# Clean up old backups
cleanup_backups() {
    local backup_dir="/etc/apt/backups"
    find "$backup_dir" -name "sources.list.backup.*" -mtime +${BACKUP_RETENTION_DAYS} -delete
}

# Check network connectivity
check_network() {
    local test_hosts=("8.8.8.8" "1.1.1.1")
    local success=false
    
    for host in "${test_hosts[@]}"; do
        if ping -c 1 -W 2 "$host" &>/dev/null; then
            success=true
            break
        fi
    done
    
    if ! $success; then
        echo "[ERROR] No network connectivity"
        return 1
    fi
    
    return 0
}

# Backup management
manage_backups() {
    local backup_dir=$1
    local retention_days=${BACKUP_RETENTION_DAYS:-30}
    
    # Create backup directory
    mkdir -p "$backup_dir"
    
    # Clean up old backups
    find "$backup_dir" -type f -mtime +"$retention_days" -delete
    
    # Compress old backups
    find "$backup_dir" -type f -mtime +7 -not -name "*.gz" -exec gzip {} \;
}

# Add these missing Docker functions
remove_old_docker() {
    apt-get remove -y docker docker-engine docker.io containerd runc || true
}

install_new_docker() {
    echo "[INFO] Installing Docker for $OS..."
    
    if [[ "$OS" == *"Ubuntu"* ]]; then
        # Original Ubuntu installation process
        echo "[INFO] Installing Docker prerequisites for Ubuntu..."
        $PKG_INSTALL \
            apt-transport-https \
            ca-certificates \
            curl \
            gnupg \
            lsb-release

        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/$OS_LC/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_LC \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    elif [[ "$OS" == *"Debian"* ]]; then
        # Debian installation process
        echo "[INFO] Installing Docker prerequisites for Debian..."
        
        # Remove old versions if exist
        for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
            $PKG_INSTALL remove $pkg
        done
        
        # Install prerequisites
        $PKG_INSTALL \
            apt-transport-https \
            ca-certificates \
            curl \
            software-properties-common

        # Add Docker's official GPG key
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Ensure you are now installing Docker from the official Docker repository instead of the default Debian repository:
        apt-cache policy docker-ce

    else
        echo "[ERROR] Unsupported operating system: $OS"
        return 1
    fi

    # Update package index and install Docker
    $PKG_UPDATE
    $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    return $?
}

configure_docker() {
    echo "[INFO] Configuring Docker..."
    
    # Create docker daemon config directory
    mkdir -p /etc/docker

    # Configure Docker daemon
    cat > /etc/docker/daemon.json << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
EOF

    # Start and enable Docker service
    systemctl enable docker
    systemctl start docker

    return $?
}

verify_docker_installation() {
    echo "[INFO] Verifying Docker installation..."
    if docker --version && docker run hello-world; then
        echo "[SUCCEED] Docker installed and running correctly"
        return 0
    else
        echo "[ERROR] Docker installation verification failed"
        return 1
    fi
}

# Add after loading config
STOP_ON_ERROR=${STOP_ON_ERROR:-false}
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}

# Add this function near the beginning of the script
check_security_requirements() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then 
        echo "[ERROR] Please run this script with root privileges"
        exit 1
    fi

    # Check if password complexity requirements are met
    if ! grep -q "pam_pwquality.so" /etc/pam.d/common-password; then
        echo "[WARN] Password complexity requirements not configured"
    fi

    # Check SSH configuration
    if [ -f /etc/ssh/sshd_config ]; then
        if grep -q "PermitRootLogin yes" /etc/ssh/sshd_config; then
            echo "[WARN] Root login is currently permitted via SSH"
        fi
    fi
}

# Main program
main() {
    echo "[INIT] Starting system initialization..."
    
    # Add security check
    check_security_requirements
    
    # Initialize variables and log
    ERROR_LOG="$(dirname "$0")/error.log"
    > "$ERROR_LOG"  # Clear error log
    declare -a FAILED_STEPS=()
    
    # Load configuration
    load_config
    
    # Create temporary directory
    TEMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TEMP_DIR"' EXIT
    
    # Execute initialization steps
    local steps=(
        "set_timezone"
        "get_user_choices"
        "configure_apt_sources"
        "remove_snap"
        "system_update"
        "disable_hibernation"
        "setup_ssh"
        "install_docker"
        "install_git"
    )
    
    # Conditional steps
    [ "$create_user_choice" = "y" ] && steps+=("create_user" "configure_ssh")
    
    # Execute steps
    for step in "${steps[@]}"; do
        echo "[INFO] Executing step: $step"
        if ! $step; then
            FAILED_STEPS+=("$step")
            echo "[ERROR] Step $step failed"
            # Based on error handling strategy, whether to continue
            if [ "${STOP_ON_ERROR:-false}" = "true" ]; then
                break
            fi
        fi
    done

    # Summary report
    echo -e "\nSystem initialization completed!"
    if [ "$create_user_choice" = "y" ]; then
        echo "Please use SSH port $ssh_port and username $new_username to login"
        echo "Remember to save the SSH config backup file: /etc/ssh/sshd_config.backup"
    fi

    # Check failed steps
    if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
        echo -e "\nWarning: The following steps encountered errors:"
        printf '%s\n' "${FAILED_STEPS[@]}"
        echo "Please check $ERROR_LOG for detailed error messages"
        exit 1
    else
        # Clean up empty error log
        if [ ! -s "$ERROR_LOG" ]; then
            rm -f "$ERROR_LOG"
            echo -e "\nNo errors occurred during initialization"
        fi
        exit 0
    fi
}

# Execute main program
main