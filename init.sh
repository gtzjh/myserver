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
            local retry_command
            # 获取实际失败命令
            retry_command=$(fc -ln -0 2>/dev/null || echo "$BASH_COMMAND")
            while [ $retry_count -lt $max_retries ]; do
                echo "[RETRY] Retrying: $retry_command"
                if eval "$retry_command"; then
                    echo "[SUCCEED] Retry successful"
                    return 0
                fi
                sleep $wait_time
                ((wait_time += 5))  # 改为线性增加
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
        
        # 增加超时和错误处理
        echo "[INFO] Detecting timezone based on IP..."
        detected_tz=$(curl -s --max-time 5 --retry 2 http://ip-api.com/line/?fields=timezone 2>/dev/null || true)
        
        # 只有当检测到有效时区时才显示选项2
        valid_detected_tz=false
        if [ -n "$detected_tz" ] && timedatectl list-timezones | grep -q "^$detected_tz$"; then
            valid_detected_tz=true
        fi

        echo "Choose an option:"
        echo "1. Keep current system timezone [$current_tz]"
        if $valid_detected_tz; then
            echo "2. Use detected timezone [$detected_tz]"
        fi
        echo "3. Manually select timezone"
        read -p "Enter choice (1-3): " tz_choice

        # 当选项2不可用时处理无效输入
        if ! $valid_detected_tz && [ "$tz_choice" == "2" ]; then
            echo "[ERROR] Invalid selection, detected timezone not available"
            return 1
        fi

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
            local backup_dir="/etc/apt/backups"
            mkdir -p "$backup_dir"
            
            # 增加源文件存在性检查
            if [ -f /etc/apt/sources.list ]; then
                local backup_file="$backup_dir/sources.list.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -v /etc/apt/sources.list "$backup_file"; then
                    echo "[ERROR] Failed to backup sources.list"
                    return 1
                fi
            else
                echo "[WARN] /etc/apt/sources.list does not exist, creating new"
            fi
            
            # 确保获取正确的版本代号
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                VERSION_CODE=${VERSION_CODENAME:-$(echo $VERSION_ID | tr -d .)}
            else
                echo "[ERROR] Cannot determine OS version"
                return 1
            fi
            
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
            # 增加存在性检查
            if command -v snap >/dev/null 2>&1; then
                # 先停止服务
                systemctl stop snapd.service snapd.socket
                
                # 更安全的删除方式
                for pkg in $(snap list | awk 'NR>1 {print $1}'); do
                    snap remove --purge "$pkg" || true
                done
                
                # 增加存在性检查再删除
                [ -d /snap ] && rm -rf /snap
                [ -d /var/snap ] && rm -rf /var/snap
                [ -d /var/lib/snapd ] && rm -rf /var/lib/snapd
                
                apt-get purge -y snapd
                apt-mark hold snapd
            else
                echo "[INFO] Snap not installed, skipping removal"
            fi
        fi
    } || handle_error "Remove Snap" "$?"
}

# System update
system_update() {
    {
        eval "$PKG_UPDATE"
    } || handle_error "System Update" "$?"
}

# Disable hibernation (For Debian only)
disable_hibernation() {
    {
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
        echo "Hibernation disabled"
    } || handle_error "Disable Hibernation" "$?"
}

# Install Docker
install_docker() {
    {
        echo "[INFO] Starting Docker installation..."

        # Clean old Docker components
        clean() {
            echo "Cleaning old Docker components..."
            # Remove APT source files
            rm -f /etc/apt/sources.list.d/docker.list
            rm -f /etc/apt/sources.list.d/*docker*.list
            # Remove old GPG keys
            rm -f /usr/share/keyrings/docker-archive-keyring.gpg
            # Uninstall old packages
            for pkg in docker.io docker-buildx-plugin docker-ce-cli docker-ce-rootless-extras \
                       docker-compose-plugin docker-doc docker-compose podman-docker containerd runc; do
                apt-get remove -y $pkg
            done
            # Clean up installation scripts
            rm -f get-docker.sh
        }
        # Perform cleanup
        clean

        # Install required dependencies
        echo "Installing system dependencies..."
        required_pkgs=(
            apt-transport-https 
            ca-certificates 
            curl 
            software-properties-common
            gnupg
        )
        if ! apt-get install -y --no-install-recommends "${required_pkgs[@]}"; then
            echo "[ERROR] Dependency installation failed"
            return 1
        fi
        # Update package lists
        apt-get update

        # Post-installation configuration
        after_installation() {
            # Start Docker service
            echo "Starting Docker service..."
            if ! systemctl start docker; then
                echo "[ERROR] Failed to start Docker service"
                journalctl -u docker.service | tail -n 30
                return 1
            fi

            # Verify service status
            if ! systemctl is-active docker >/dev/null; then
                echo "[ERROR] Docker service is not running properly"
                journalctl -u docker.service | tail -n 30
                return 1
            fi

            # Enable auto-start on boot
            echo "Enabling Docker auto-start..."
            if ! systemctl enable docker; then
                echo "[ERROR] Failed to enable Docker auto-start"
                return 1
            fi

            # Verify Docker version
            echo "Verifying Docker version..."
            docker --version || {
                echo "[ERROR] Docker command not available"
                return 1
            }

            # Run test container
            echo "Running Docker test..."
            if ! docker run --rm hello-world; then
                echo "[ERROR] Docker test failed"
                return 1
            fi
        }

        # Install from USTC mirror
        install_script_from_USTC() {
            echo "Installing Docker from USTC mirror..."
            # Download installation script
            if ! curl -fsSL https://get.docker.com -o get-docker.sh; then
                echo "[ERROR] Failed to download Docker installation script"
                rm -f get-docker.sh
                return 1
            fi

            # Install using USTC mirror
            echo "Installing Docker using USTC mirror..."
            DOWNLOAD_URL=https://mirrors.ustc.edu.cn/docker-ce sh get-docker.sh || {
                echo "[ERROR] Docker installation failed"
                return 1
            }
        }

        # Install from Aliyun mirror
        install_from_aliyun() {
            echo "Installing Docker from Aliyun mirror..."
            # Add GPG key
            curl -fsSL http://mirrors.cloud.aliyuncs.com/docker-ce/linux/ubuntu/gpg | apt-key add -
            # Add APT repository
            add-apt-repository -y "deb [arch=$(dpkg --print-architecture)] http://mirrors.cloud.aliyuncs.com/docker-ce/linux/ubuntu $(lsb_release -cs) stable"
            # Update and install packages
            apt-get update
            apt-get install -y --no-install-recommends \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin
        }

        # Main installation flow
        if install_script_from_USTC; then
            after_installation
        else
            echo "[WARN] USTC mirror installation failed, trying Aliyun..."
            clean
            if install_from_aliyun; then
                after_installation
            else
                return 1
            fi
        fi

        echo "[SUCCEED] Docker installation completed"
    } || handle_error "Install Docker" "$?"
}

# Main program
main() {
    echo "[INIT] Starting Ubuntu system initialization..."
    
    # Initialize variables and log
    ERROR_LOG="$(dirname "$0")/error.log"
    > "$ERROR_LOG"  # Clear error log
    declare -a FAILED_STEPS=()
    
    # 询问是否安装Docker
    local install_docker=false
    read -p "是否需要安装Docker？(y/n): " docker_choice
    if [[ "$docker_choice" =~ [yY] ]]; then
        install_docker=true
    fi

    # Execute initialization steps
    local steps=(
        "set_timezone"
        "select_apt_mirror"
        "configure_apt_sources"
        "remove_snap"
        "system_update"
    )
    
    # 根据系统类型决定是否禁用休眠
    if [[ "$OS_LC" == *"debian"* ]]; then
        steps+=("disable_hibernation")
    fi

    # 添加Docker安装步骤
    if $install_docker; then
        steps+=("install_docker")
    fi
    
    # Execute steps
    for step in "${steps[@]}"; do
        echo "[INFO] Executing step: $step"
        if ! $step; then
            FAILED_STEPS+=("$step")
            echo "[ERROR] Step $step failed"
            # 关键步骤失败时中止
            if [[ "$step" == "configure_apt_sources" ]]; then
                echo "[FATAL] APT源配置失败，无法继续"
                break
            fi
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