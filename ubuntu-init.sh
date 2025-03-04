#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "Please run this script with root privileges"
    exit 1
fi

# Check if system is Ubuntu
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$NAME" != *"Ubuntu"* ]]; then
        echo "This script is only for Ubuntu systems"
        exit 1
    fi
    OS=$NAME
    PKG_MANAGER="apt"
    PKG_UPDATE="apt update && apt upgrade -y"
    PKG_INSTALL="apt install -y"
else
    echo "Cannot determine OS type"
    exit 1
fi

# Convert OS name to lowercase
OS_LC=$(echo "$OS" | tr '[:upper:]' '[:lower:]')

# Error handling function
handle_error() {
    local step=$1
    local error_code=$2
    local error_msg=${3:-"Unknown error"}
    local max_retries=${MAX_RETRIES:-3}
    local retry_count=0
    local wait_time=5
    
    # Log error
    echo "[$timestamp] ERROR in $step (Code: $error_code)" >> "$ERROR_LOG"
    echo "Message: $error_msg" >> "$ERROR_LOG"
    echo "Command: $BASH_COMMAND" >> "$ERROR_LOG"
    echo "----------------------------------------" >> "$ERROR_LOG"
    
    case $error_code in
        1)  # General error
            echo "[ERROR] General error in $step"
            return 1
            ;;
        100|101|102)  # Network errors
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
        126|127)  # Command not found
            echo "[ERROR] Required command not found"
            return 1
            ;;
        *)  # Other errors
            echo "[ERROR] Unhandled error in $step"
            return 1
            ;;
    esac
    
    FAILED_STEPS+=("$step")
    return 1
}

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

# Select APT mirror
select_apt_mirror() {
    echo "[INFO] Current APT mirror configuration:"
    current_mirror=$(grep -v '^#' /etc/apt/sources.list | grep '^deb' | head -n1 | awk '{print $2}' | sed 's|https://||;s|http://||;s|/.*||')
    echo "Current mirror: $current_mirror"
    
    echo "Please select your preferred mirror:"
    echo "1) USTC Mirror (University of Science and Technology of China)"
    echo "2) TUNA Mirror (Tsinghua University)"
    echo "3) Aliyun Mirror (Alibaba Cloud)"
    echo "n) Keep current mirror"
    read -r -p "Enter your choice (1|2|3|n) [default: n]: " mirror_choice
    mirror_choice=${mirror_choice:-n}
    
    case $mirror_choice in
        1)
            MIRROR_URL="mirrors.ustc.edu.cn/ubuntu"
            MIRROR_NAME="USTC Mirror"
            ;;
        2)
            MIRROR_URL="mirrors.tuna.tsinghua.edu.cn/ubuntu"
            MIRROR_NAME="TUNA Mirror"
            ;;
        3)
            MIRROR_URL="mirrors.aliyun.com/ubuntu"
            MIRROR_NAME="Aliyun Mirror"
            ;;
        *)
            MIRROR_URL=""
            MIRROR_NAME="Default Mirror"
            echo "Keeping current sources"
            ;;
    esac
    [ -n "$MIRROR_URL" ] && echo "Selected: $MIRROR_NAME"
}

# Configure APT sources
configure_apt_sources() {
    {
        echo "[INFO] Configuring APT sources..."
        
        if [ -n "$MIRROR_URL" ]; then
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
            fi
            
            VERSION_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
            
            echo "[INFO] Configuring Ubuntu sources with $MIRROR_NAME ($MIRROR_URL)"
            
            # Configure Ubuntu sources
            cat > /etc/apt/sources.list << EOF
# Ubuntu $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-updates main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-backports main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-security main restricted universe multiverse
EOF
            
            # Verify file creation and content
            if [ -f /etc/apt/sources.list ] && [ -s /etc/apt/sources.list ]; then
                echo "[SUCCEED] APT sources configured for Ubuntu"
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
            echo "[WARN] Skipping APT source configuration: no mirror selected"
        fi
    } || handle_error "Configure APT Sources" "$?"
}

# Remove snap
remove_snap() {
    {
        echo "Do you want to remove snap? (y/n)"
        read -r remove_snap_choice
        
        if [ "$remove_snap_choice" = "y" ]; then
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
            
            echo "[SUCCEED] Snap has been removed and blocked from automatic installation"
        fi
    } || handle_error "Remove Snap" "$?"
}

# System update
system_update() {
    {
        eval "$PKG_UPDATE"
    } || handle_error "System Update" "$?"
}

# Install Docker
install_docker() {
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
        
        echo "[INFO] We will try three methods to install Docker:"
        echo "   1. Official installation script (recommended)"
        echo "   2. Shell script installation"
        echo "   3. Manual installation"
        
        # Method 1: Using official Docker installation script
        echo "[INFO] Trying Method 1: Official Docker installation script..."
        if install_docker_official_script; then
            echo "[SUCCEED] Docker installed successfully using official script"
            return 0
        else
            echo "[WARN] Official script installation failed, trying next method..."
        fi
        
        # Method 2: Using Shell script
        echo "[INFO] Trying Method 2: Shell script installation..."
        if install_docker_shell_script; then
            echo "[SUCCEED] Docker installed successfully using shell script"
            return 0
        else
            echo "[WARN] Shell script installation failed, trying next method..."
        fi
        
        # Method 3: Manual installation (original method)
        echo "[INFO] Trying Method 3: Manual installation..."
        if install_docker_manual; then
            echo "[SUCCEED] Docker installed successfully using manual method"
            return 0
        else
            echo "[ERROR] All Docker installation methods failed!"
            return 1
        fi
    } || handle_error "Install Docker" "$?"
}

# Method 1: Install Docker using official script
install_docker_official_script() {
    echo "[INFO] Downloading official Docker installation script..."
    if curl -fsSL https://get.docker.com -o get-docker.sh; then
        echo "[INFO] Running official Docker installation script..."
        if sh get-docker.sh; then
            # Clean up
            rm -f get-docker.sh
            
            # Configure Docker daemon
            configure_docker
            
            # Verify installation
            verify_docker_installation
            return $?
        else
            echo "[ERROR] Failed to run official Docker installation script"
            # Clean up
            rm -f get-docker.sh
            return 1
        fi
    else
        echo "[ERROR] Failed to download official Docker installation script"
        return 1
    fi
}

# Method 2: Install Docker using shell script
install_docker_shell_script() {
    echo "[INFO] Downloading test Docker installation script..."
    if curl -fsSL https://test.docker.com -o test-docker.sh; then
        echo "[INFO] Running test Docker installation script..."
        if sh test-docker.sh; then
            # Clean up
            rm -f test-docker.sh
            
            # Configure Docker daemon
            configure_docker
            
            # Verify installation
            verify_docker_installation
            return $?
        else
            echo "[ERROR] Failed to run test Docker installation script"
            # Clean up
            rm -f test-docker.sh
            return 1
        fi
    else
        echo "[ERROR] Failed to download test Docker installation script"
        return 1
    fi
}

# Method 3: Install Docker manually (original method)
install_docker_manual() {
    echo "[INFO] Attempting manual Docker installation..."
    
    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc || true
    
    # Install prerequisites
    $PKG_INSTALL \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Add Docker's official GPG key
    if ! curl -fsSL https://download.docker.com/linux/$OS_LC/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg; then
        echo "[ERROR] Failed to add Docker's GPG key"
        return 1
    fi

    # Add Docker repository
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$OS_LC \
        $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Update package index and install Docker
    $PKG_UPDATE
    if ! $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo "[ERROR] Failed to install Docker packages"
        return 1
    fi

    # Configure Docker daemon
    configure_docker
    
    # Verify installation
    verify_docker_installation
    return $?
}

# Configure Docker daemon
configure_docker() {
    echo "[INFO] Configuring Docker daemon..."
    mkdir -p /etc/docker
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
}

# Verify Docker installation
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

# Main program
main() {
    echo "[INIT] Starting Ubuntu system initialization..."
    
    # Initialize variables and log
    ERROR_LOG="$(dirname "$0")/error.log"
    > "$ERROR_LOG"  # Clear error log
    declare -a FAILED_STEPS=()
    
    # Execute initialization steps
    local steps=(
        "set_timezone"
        "select_apt_mirror"
        "configure_apt_sources"
        "remove_snap"
        "system_update"
        "install_docker"
    )
    
    # Execute steps
    for step in "${steps[@]}"; do
        echo "[INFO] Executing step: $step"
        if ! $step; then
            FAILED_STEPS+=("$step")
            echo "[ERROR] Step $step failed"
        fi
    done

    # Summary report
    echo -e "\nUbuntu system initialization completed!"

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