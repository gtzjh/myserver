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
            local retry_command="$BASH_COMMAND"  # 获取原始命令
            while [ $retry_count -lt $max_retries ]; do
                echo "[RETRY] Retrying: $retry_command"
                if eval "$retry_command"; then
                    echo "[SUCCEED] Retry successful"
                    return 0
                fi
                sleep $wait_time
                ((wait_time *= 2))
                ((retry_count++))
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
        detected_tz=$(curl -s --max-time 5 --retry 2 http://ip-api.com/line/?fields=timezone || true)
        
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
                if ! hwclock --systohc 2>/dev/null; then
                    if [ -d /run/wsl ]; then
                        echo "[INFO] WSL detected, skipping hardware clock sync"
                    else
                        echo "[WARN] Failed to sync hardware clock"
                    fi
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
                if ! apt-get update -qq; then
                    echo "[ERROR] Failed to update package lists. Output:"
                    apt-get update 2>&1 | grep -iE 'err|fail'
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
            if command -v snap >/dev/null 2>&1; then
                snap list | awk 'NR>1 {print $1}' | xargs -I {} sudo snap remove {}
            else
                echo "Snap not installed, skipping removal"
            fi
            
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

# Disable hibernation
disable_hibernation() {
    {
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
        echo "Hibernation disabled"
    } || handle_error "Disable Hibernation" "$?"
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
        "disable_hibernation"
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