#!/bin/bash



# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with root privileges"
    exit 1
fi



# Check if system is Ubuntu or Debian
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$NAME" != *"Ubuntu"* && "$NAME" != *"Debian"* ]]; then
        echo "This script is only for Ubuntu or Debian systems"
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
            # Get actual failed command
            retry_command=$(fc -ln -0 2>/dev/null || echo "$BASH_COMMAND")
            while [ $retry_count -lt $max_retries ]; do
                echo "[RETRY] Retrying: $retry_command"
                if eval "$retry_command"; then
                    echo "[SUCCEED] Retry successful"
                    return 0
                fi
                sleep $wait_time
                ((wait_time += 5))  # Linear backoff
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
    echo "[INFO] Checking system timezone..."
    {   
        # Add timeout and error handling
        echo "[INFO] Detecting timezone based on IP..."
        detected_tz=$(curl -s --max-time 10 --retry 10 http://ip-api.com/line/?fields=timezone 2>/dev/null || true)
        
        # Only show option 2 when valid timezone is detected
        valid_detected_tz=false
        if [ -n "$detected_tz" ] && timedatectl list-timezones | grep -q "^$detected_tz$"; then
            valid_detected_tz=true
        fi

        echo "Choose an option:"

        current_tz=$(timedatectl show --property=Timezone --value)
        echo "Current system timezone: $current_tz"
        echo "1. Keep current system timezone [$current_tz]"

        if $valid_detected_tz; then
            echo "2. Use detected timezone [$detected_tz]"
        fi

        echo "3. Manually select timezone"
        read -p "Enter choice (1-3): " tz_choice

        # Handle invalid input when option 2 is unavailable
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
    echo -e "\nCurrent mirror: $current_mirror"
    
    # 确定操作系统类型
    if [[ "$OS" == *"Debian"* ]]; then
        os_type="debian"
        echo "Please select your preferred Debian mirror:"
        echo "1) USTC Mirror (University of Science and Technology of China)"
        echo "2) TUNA Mirror (Tsinghua University)"
        echo "3) Aliyun Mirror (Alibaba Cloud)"
        echo "4) Official Debian Archive"
    else
        os_type="ubuntu"
        echo "Please select your preferred Ubuntu mirror:"
        echo "1) USTC Mirror (University of Science and Technology of China)"
        echo "2) TUNA Mirror (Tsinghua University)"
        echo "3) Aliyun Mirror (Alibaba Cloud)"
        echo "4) Official Ubuntu Archive"
    fi
    
    echo "n) Keep current mirror"
    read -r -p "Enter your choice (1|2|3|4|n) [default: n]: " mirror_choice
    mirror_choice=${mirror_choice:-n}
    
    case $mirror_choice in
        1)
            if [ "$os_type" = "debian" ]; then
                MIRROR_URL="mirrors.ustc.edu.cn/debian"
            else
                MIRROR_URL="mirrors.ustc.edu.cn/ubuntu"
            fi
            MIRROR_NAME="USTC Mirror"
            ;;
        2)
            if [ "$os_type" = "debian" ]; then
                MIRROR_URL="mirrors.tuna.tsinghua.edu.cn/debian"
            else
                MIRROR_URL="mirrors.tuna.tsinghua.edu.cn/ubuntu"
            fi
            MIRROR_NAME="TUNA Mirror"
            ;;
        3)
            if [ "$os_type" = "debian" ]; then
                MIRROR_URL="mirrors.aliyun.com/debian"
            else
                MIRROR_URL="mirrors.aliyun.com/ubuntu"
            fi
            MIRROR_NAME="Aliyun Mirror"
            ;;
        4)
            if [ "$os_type" = "debian" ]; then
                MIRROR_URL="deb.debian.org/debian"
            else
                MIRROR_URL="archive.ubuntu.com/ubuntu"
            fi
            MIRROR_NAME="Official Archive"
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
    echo "[INFO] Configuring APT sources..."
    {
        
        if [ -n "$MIRROR_URL" ]; then
            local backup_dir="/etc/apt/backups"
            mkdir -p "$backup_dir"
            
            # Check if source file exists
            if [ -f /etc/apt/sources.list ]; then
                local backup_file="$backup_dir/sources.list.backup.$(date +%Y%m%d%H%M%S)"
                if ! cp -v /etc/apt/sources.list "$backup_file"; then
                    echo "[ERROR] Failed to backup sources.list"
                    return 1
                fi
            else
                echo "[WARN] /etc/apt/sources.list does not exist, creating new"
            fi
            
            # Ensure correct version code
            if [ -f /etc/os-release ]; then
                . /etc/os-release
                VERSION_CODE=${VERSION_CODENAME:-$(echo $VERSION_ID | tr -d .)}
            else
                echo "[ERROR] Cannot determine OS version"
                return 1
            fi
            
            echo "[INFO] Configuring sources with $MIRROR_NAME ($MIRROR_URL)"
            
            # 根据操作系统类型配置不同的源
            if [[ "$OS" == *"Debian"* ]]; then
                # Configure Debian sources
                cat > /etc/apt/sources.list << EOF
# Debian $VERSION_CODE repository ($MIRROR_NAME)
deb https://$MIRROR_URL $VERSION_CODE main contrib non-free non-free-firmware
deb https://$MIRROR_URL $VERSION_CODE-updates main contrib non-free non-free-firmware
deb https://$MIRROR_URL $VERSION_CODE-backports main contrib non-free non-free-firmware
deb https://$MIRROR_URL-security $VERSION_CODE-security main contrib non-free non-free-firmware
EOF
            else
                # Configure Ubuntu sources
                cat > /etc/apt/sources.list << EOF
# Ubuntu $VERSION_CODE repository ($MIRROR_NAME)
deb https://$MIRROR_URL $VERSION_CODE main restricted universe multiverse
deb https://$MIRROR_URL $VERSION_CODE-updates main restricted universe multiverse
deb https://$MIRROR_URL $VERSION_CODE-backports main restricted universe multiverse
deb https://$MIRROR_URL $VERSION_CODE-security main restricted universe multiverse
EOF
            fi
            
            # Verify file creation and content
            if [ -f /etc/apt/sources.list ] && [ -s /etc/apt/sources.list ]; then
                echo "[SUCCEED] APT sources configured"
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
            echo "[INFO] No mirror selected, keeping default configuration"
            return 0
        fi
    } || handle_error "Configure APT Sources" "$?"
}



# Remove snap
remove_snap() {
    echo "[INFO] Removing snap..."
    {
        # Use the global choice made at the beginning
        echo "Executing remove snap..."
        # Check if snap exists
        if command -v snap >/dev/null 2>&1; then
            # Stop service
            systemctl stop snapd.service snapd.socket
            
            # Safer removal
            for pkg in $(snap list | awk 'NR>1 {print $1}'); do
                snap remove --purge "$pkg" || true
            done
            
            # Check existence before deletion
            [ -d /snap ] && rm -rf /snap
            [ -d /var/snap ] && rm -rf /var/snap
            [ -d /var/lib/snapd ] && rm -rf /var/lib/snapd
            
            apt-get purge -y snapd
            apt-mark hold snapd
        else
            echo "[INFO] Snap not installed, skipping removal"
        fi
    } || handle_error "Remove Snap" "$?"
}



# System update
system_update() {
    echo "[INFO] System update..."
    {
        eval "$PKG_UPDATE"
    } || handle_error "System Update" "$?"
}


install_necessary_packages() {
    echo "[INFO] Installing necessary system packages..."
    echo "[INFO] Installing iputils-ping..."
    apt-get install -y iputils-ping
    echo "[INFO] Installing curl..."
    apt-get install -y curl
    echo "[INFO] Installing vim..."
    apt-get install -y vim
    echo "[INFO] Installing git..."
    apt-get install -y git
    echo "[SUCCEED] Basic packages installed successfully"
}


# Disable hibernation (For Debian only)
disable_hibernation() {
    echo "[INFO] Disabling hibernation..."
    {
        systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
        echo "Hibernation disabled"
    } || handle_error "Disable Hibernation" "$?"
}



# Configure Docker Registry Mirror
speed_up_mirror() {
    echo "[INFO] Configuring Docker registry mirrors..."
    {

        # 原有Docker检查
        if ! command -v docker &> /dev/null; then
            echo "[ERROR] Docker is not installed, cannot configure registry mirrors"
            return 1
        fi
        
        # Create Docker daemon directory if it doesn't exist
        mkdir -p /etc/docker
        
        # Define available mirrors
        declare -a available_mirrors=(
            "docker.io"
            "mirror.gcr.io"
            "azurecr.io"
            "public.ecr.aws"
            "registry.docker-cn.com"
            "hub-mirror.c.163.com"
            "mirror.baidubce.com"
            "docker-0.unsee.tech"
            "docker-cf.registry.cyou"
            "docker.1panel.live"
            "cr.laoyou.ip-ddns.com"
            "image.cloudlayer.icu"
            "hub.fast360.xyz"
            "docker.1panelproxy.com"
            "docker.tbedu.top"
            "dockerpull.cn"
            "docker.m.daocloud.io"
            "hub.rat.dev"
            "docker.kejilion.pro"
            "docker.hlmirror.com"
            "docker.imgdb.de"
            "docker.melikeme.cn"
            "ccr.ccs.tencentyun.com"
            "pull.loridocker.com"
        )
        
        # Array to store working mirrors
        declare -a working_mirrors=()
        
        echo "Testing mirror connectivity..."
        max_mirrors=6
        for mirror in "${available_mirrors[@]}"; do
            if [ ${#working_mirrors[@]} -ge $max_mirrors ]; then
                echo "Found ${max_mirrors} working mirrors, stopping further checks"
                break
            fi
            
            # 静默测试镜像，不输出每次尝试结果
            success=false
            for attempt in {1..6}; do 
                if ping -c 3 -W 6 "$mirror" >/dev/null 2>&1; then
                    working_mirrors+=("https://$mirror")
                    success=true
                    echo "[YES] $mirror: Reachable"
                    break
                fi
            done
            if ! $success; then
                # 仅在全部尝试失败后输出一次
                echo "[NO] $mirror: Connection failed"
            fi
        done
        
        # Check if we have any working mirrors
        if [ ${#working_mirrors[@]} -eq 0 ]; then
            echo "[WARN] No working mirrors found, using default only"
        fi

        # 强制添加默认镜像（即使其他都失败）
        default_mirror="docker-0.unsee.tech"
        if ! printf '%s\n' "${working_mirrors[@]}" | grep -q "^https://$default_mirror$"; then
            echo "[WARN] Adding fallback mirror: $default_mirror"
            working_mirrors+=("https://$default_mirror")
        fi
        
        # Check if we have any working mirrors
        if [ ${#working_mirrors[@]} -eq 0 ]; then
            echo "[ERROR] No working Docker mirrors found. Cannot configure registry mirrors."
            return 1
        fi
        
        echo "Found ${#working_mirrors[@]} working mirrors."
        
        # Create JSON array structure for registry-mirrors
        registry_mirrors_json="["
        for ((i=0; i<${#working_mirrors[@]}; i++)); do
            registry_mirrors_json+="\"${working_mirrors[$i]}\""
            if [ $i -lt $((${#working_mirrors[@]}-1)) ]; then
                registry_mirrors_json+=", "
            fi
        done
        registry_mirrors_json+="]"
        
        # Create configuration file
        echo "Creating Docker daemon configuration file with working mirrors..."
        cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": $registry_mirrors_json
}
EOF

        # Verify file creation
        if [ ! -f /etc/docker/daemon.json ]; then
            echo "[ERROR] Failed to create Docker daemon configuration file"
            return 1
        fi
        
        # Display selected mirrors
        echo "Selected mirrors:"
        for mirror in "${working_mirrors[@]}"; do
            echo "  - $mirror"
        done
        
        # Restart Docker service
        echo "Restarting Docker service to apply mirror configuration..."
        if ! systemctl restart docker; then
            echo "[ERROR] Failed to restart Docker service"
            journalctl -u docker.service | tail -n 30
            return 1
        fi
        
        # Verify Docker service is running
        if ! systemctl is-active docker >/dev/null; then
            echo "[ERROR] Docker service failed to start after configuration"
            journalctl -u docker.service | tail -n 30
            return 1
        fi
        
        # 新增配置验证
        echo "Verifying configuration reload..."
        sleep 6  # 等待服务完全启动
        if ! docker info 2>/dev/null | grep -q "Registry Mirrors"; then
            echo "[WARN] No registry mirrors detected in Docker config"
        else
            echo "[SUCCEED] Docker daemon reloaded configuration successfully"
            echo "Current registry mirrors:"
            docker info | grep "Registry Mirrors" -A 10 | sed 's/^/  /'
        fi
        
        echo "[SUCCEED] Docker registry mirrors configured successfully"

        # Run test container after installation and configuration
        echo "Running Docker test..."
        if ! docker run --rm hello-world; then
            echo "[ERROR] Docker test failed"
            return 1
        fi

    } || handle_error "Configure Docker Registry Mirror" "$?"
}



# Install Docker
install_docker() {
    echo "[INFO] Installing Docker..."
    {
        # Clean old Docker components
        clean() {
            echo "Cleaning old Docker components..."
            # Remove APT source files and GPG keys
            rm -f /etc/apt/sources.list.d/docker.list
            rm -rf /etc/apt/sources.list.d/*docker*.list
            rm -rf /usr/share/keyrings/docker-archive-keyring.gpg
            
            # Clean up installation scripts
            rm -f get-docker.sh
            
            # Uninstall all Docker related packages in one command
            apt-get remove -y docker.io docker-buildx-plugin docker-ce-cli docker-ce-rootless-extras \
                          docker-compose-plugin docker-doc docker-compose podman-docker containerd runc \
                          docker docker-engine docker.io containerd runc
            
            apt-get update
        }

        install_docker_from_official_script() {
            echo "Installing Docker using official script..."
            # Download installation script
            local max_retries=6
            local initial_timeout=6  # 初始超时2秒
            local timeout_increment=6  # 每次增加3秒
            local retry_count=0
            local download_success=false
            
            echo "Downloading Docker installation script..."
            while [ $retry_count -le $max_retries ]; do
                local current_timeout=$((initial_timeout + timeout_increment * retry_count))
                echo "Attempt $((retry_count + 1)) with timeout ${current_timeout}s"
                if curl --max-time $current_timeout -fsSL https://get.docker.com -o get-docker.sh; then
                    download_success=true
                    break
                else
                    echo "[WARN] Download attempt $((retry_count + 1))/$((max_retries + 1)) failed"
                    ((retry_count++))
                fi
            done

            if [ "$download_success" != "true" ]; then
                echo "[ERROR] Failed to download Docker script after $((max_retries + 1)) attempts"
                return 1
            fi

            chmod +x get-docker.sh
            sh get-docker.sh 2>&1 | tee /var/log/docker-install.log
            if ! command -v docker &> /dev/null; then
                echo "[ERROR] Docker installation failed"
                return 1
            fi
        }

        # Install from USTC mirror
        install_docker_from_USTC() {
            echo "Installing Docker from USTC mirror..."
            # Download installation script
            local max_retries=6
            local initial_timeout=6  # 初始超时2秒
            local timeout_increment=6  # 每次增加3秒
            local retry_count=0
            local download_success=false
            
            echo "Downloading Docker installation script..."
            while [ $retry_count -le $max_retries ]; do
                local current_timeout=$((initial_timeout + timeout_increment * retry_count))
                echo "Attempt $((retry_count + 1)) with timeout ${current_timeout}s"
                if curl --max-time $current_timeout -fsSL https://get.docker.com -o get-docker.sh; then
                    download_success=true
                    break
                else
                    echo "[WARN] Download attempt $((retry_count + 1))/$((max_retries + 1)) failed"
                    ((retry_count++))
                fi
            done

            if [ "$download_success" != "true" ]; then
                echo "[ERROR] Failed to download Docker script after $((max_retries + 1)) attempts"
                return 1
            fi

            chmod +x get-docker.sh
            DOWNLOAD_URL=https://mirrors.ustc.edu.cn/docker-ce sh get-docker.sh
        }


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
        }

        # Main installation
        echo "[INFO] Starting Docker installation..."
        # Perform cleanup
        echo "[INFO] Excuting cleanup..."
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
        # Main installation flow
        current_tz=$(timedatectl show --property=Timezone --value | tr '[:upper:]' '[:lower:]')
        if [[ "$current_tz" == *"shanghai"* || "$current_tz" == *"chongqing"* ]]; then
            if install_docker_from_USTC; then
                echo "[SUCCEED] Docker installation via USTC mirror completed"
            else
                echo "[WARN] USTC mirror installation failed, trying official script..."
                clean
                if install_docker_from_official_script; then
                    echo "[SUCCEED] Docker installation via official script completed"
                else
                    return 1
                fi
            fi
        else
            if install_docker_from_official_script; then
                echo "[SUCCEED] Docker installation via official script completed"
            else
                echo "[WARN] Official script installation failed, trying USTC mirror..."
                clean
                if install_docker_from_USTC; then
                    echo "[SUCCEED] Docker installation via USTC mirror completed"
                else
                    return 1
                fi
            fi
        fi
        echo "[SUCCEED] Docker installation completed"
        after_installation
    } || handle_error "Install Docker" "$?"
}



# Main program
main() {
    echo "[INIT] Starting system initialization..."
    
    # Initialize variables and log
    ERROR_LOG="$(dirname "$0")/init_error.log"
    > "$ERROR_LOG"  # Clear error log
    declare -a FAILED_STEPS=()
    
    
    # Execute initialization steps
    local steps=(
        "set_timezone"
        "select_apt_mirror"
        "configure_apt_sources"
        "system_update"
        "install_necessary_packages"
    )


    # 只在Ubuntu系统中添加remove_snap步骤
    if [[ "$OS_LC" == *"ubuntu"* ]]; then
        # Ask about snap removal at the beginning for Ubuntu systems
        read -p "Do you want to remove snap? (y/n): " remove_snap_choice
        if [[ "$remove_snap_choice" =~ [yY] ]]; then
            steps+=("remove_snap")
        fi
    else
        echo "[INFO] Non-Ubuntu system detected, skipping snap removal"
    fi

    
    # Disable hibernation based on OS type
    if [[ "$OS_LC" == *"debian"* ]]; then
        steps+=("disable_hibernation")
    fi


    # Ask about Docker installation
    local install_docker=false
    read -p "Do you want to install Docker? (y/n): " docker_choice
    if [[ "$docker_choice" =~ [yY] ]]; then
        install_docker=true
    fi

    # Docker installation steps
    if $install_docker; then
        steps+=("install_docker")
        
        # 镜像配置必须在Docker安装之后
        read -p "Do you want to configure Docker registry mirrors? (y/n): " mirror_choice
        if [[ "$mirror_choice" =~ [yY] ]]; then
            steps+=("speed_up_mirror")
        fi
    fi

    # Execute steps
    for step in "${steps[@]}"; do
        echo ""
        echo "==============================================================================================="
        echo "[INFO] Executing step: $step"
        if ! $step; then
            FAILED_STEPS+=("$step")
            echo "[ERROR] Step $step failed"
            # 记录关键步骤失败但继续执行
            if [[ "$step" == "configure_apt_sources" ]]; then
                echo "[WARN] APT source configuration failed, some following steps may not work properly"
            fi
        fi
        echo "==============================================================================================="
        echo ""
    done

    # Summary report
    echo -e "\nSystem initialization completed!"

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
main 2>&1 | tee init.log