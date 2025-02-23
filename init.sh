#!/bin/bash

# Set system timezone
set_timezone() {
    {
        echo -e "${BLUE}[INFO]${NC} Checking system timezone..."
        current_tz=$(timedatectl show --property=Timezone --value)
        echo -e "Current system timezone: ${GREEN}$current_tz${NC}"
        
        # Detect timezone by IP
        echo -e "${BLUE}[INFO]${NC} Detecting timezone based on IP..."
        detected_tz=$(curl -s --max-time 5 http://ip-api.com/line/?fields=timezone || true)
        
        if [ -n "$detected_tz" ] && timedatectl list-timezones | grep -q "^$detected_tz$"; then
            echo "Detected location timezone: $detected_tz"
            echo "Choose an option:"
            echo "1. Keep current system timezone [$current_tz]"
            echo "2. Use detected timezone [$detected_tz]"
            echo "3. Manually select timezone"
            read -p "Enter choice (1-3): " tz_choice
            
            case $tz_choice in
                2) new_timezone=$detected_tz ;;
                3) manual_select=true ;;
                *) return 0 ;;
            esac
        else
            echo "Could not detect timezone automatically"
            echo "Using default timezone: UTC"
            new_timezone="UTC"
            read -p "Would you like to manually select timezone? (y/n): " manual_select
            if [ "$manual_select" = "y" ]; then
                echo "Available timezones:"
                timedatectl list-timezones
                read -p "Enter your timezone (e.g., Asia/Shanghai): " new_timezone
            fi
        fi

        # Set new timezone if selected
        if [ -n "$new_timezone" ]; then
            if timedatectl set-timezone "$new_timezone"; then
                echo -e "${GREEN}[SUCCEED]${NC} Timezone successfully set to: $new_timezone"
                hwclock --systohc
            else
                echo -e "${RED}[ERROR]${NC} Failed to set timezone"
                return 1
            fi
        fi
    } || handle_error "Set Timezone" "$?"
}

# Initialize error log and error tracking
ERROR_LOG="$(dirname "$0")/error.log"
> "$ERROR_LOG"  # Clear error log at start
declare -a FAILED_STEPS=()

# Error handling function
handle_error() {
    local step=$1
    local error_msg=$2
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        echo -e "${RED}[ERROR]${NC} Step failed: $step (Attempt $((retry_count + 1))/$max_retries)"
        echo "[$step] Error occurred at $(date '+%Y-%m-%d %H:%M:%S')" >> "$ERROR_LOG"
        echo "Error message: $error_msg" >> "$ERROR_LOG"
        echo "Command: $BASH_COMMAND" >> "$ERROR_LOG"
        echo "----------------------------------------" >> "$ERROR_LOG"
        
        # 对于网络相关错误，等待后重试
        if echo "$error_msg" | grep -q "Connection timed out\|Network is unreachable"; then
            sleep 5
            ((retry_count++))
            continue
        fi
        
        break
    done
    
    if [ $retry_count -eq $max_retries ]; then
        FAILED_STEPS+=("$step")
        return 1
    fi
}

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

# Select APT mirror function
select_apt_mirror() {
    if [[ "$OS" == *"Debian"* || "$OS" == *"Ubuntu"* ]]; then
        # Display current mirror
        echo -e "${BLUE}[INFO]${NC} Current APT mirror configuration:"
        current_mirror=$(grep -v '^#' /etc/apt/sources.list | grep '^deb' | head -n1 | awk '{print $2}' | sed 's|https://||;s|http://||;s|/.*||')
        echo -e "Current mirror: ${GREEN}$current_mirror${NC}"
        
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
        echo "Enter new SSH port (recommended: greater than 1024):"
        read -r ssh_port
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
        echo -e "${BLUE}[INFO]${NC} Creating user $new_username..."
        if ! useradd -m "$new_username"; then
            echo -e "${RED}[ERROR]${NC} Failed to create user"
            return 1
        fi
        
        echo -e "${GREEN}[SUCCEED]${NC} User created. Please set password:"
        passwd "$new_username"
        
        # Add to sudo group
        usermod -aG sudo "$new_username"
        
        # Set shell
        usermod -s /bin/bash "$new_username"
        
        if [ "$add_ssh_key_choice" = "y" ]; then
            # Create .ssh directory
            mkdir -p "/home/$new_username/.ssh"
            chmod 700 "/home/$new_username/.ssh"
            touch "/home/$new_username/.ssh/authorized_keys"
            chmod 600 "/home/$new_username/.ssh/authorized_keys"
            chown -R "$new_username:$new_username" "/home/$new_username/.ssh"

            echo "Enter SSH public key (paste and press Enter, then Ctrl+D when done):"
            cat > "/home/$new_username/.ssh/authorized_keys"
        fi
    } || handle_error "Create User" "$?"
}

# 6. Configure SSH
configure_ssh() {
    {
        # 使用之前在 get_user_choices 中获取的 ssh_port
        if [ -z "$ssh_port" ]; then
            echo -e "${RED}[ERROR]${NC} SSH port not set"
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
            echo -e "${GREEN}[SUCCEED]${NC} SSH service restarted successfully"
        else
            echo -e "${RED}[ERROR]${NC} Failed to restart SSH service"
            return 1
        fi
    } || handle_error "Configure SSH" "$?"
}

# 7. Install Docker
install_docker() {
    {
        echo -e "${BLUE}[INFO]${NC} Starting Docker installation..."
        # 更彻底的旧版本清理
        echo "Removing all Docker components..."
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        apt-get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        rm -rf /var/lib/docker /var/lib/containerd

        # 统一使用中科大docker镜像源配置
        echo "Starting Docker installation using USTC mirror..."
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common

        # 通用镜像源配置
        if [[ "$OS" == *"Ubuntu"* ]]; then
            MIRROR_PATH="ubuntu"
            VERSION_CODE=$(lsb_release -cs)
        elif [[ "$OS" == *"Debian"* ]]; then
            MIRROR_PATH="debian"
            VERSION_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
        fi

        # 统一从中科大获取 GPG 密钥
        curl -fsSL https://mirrors.ustc.edu.cn/docker-ce/linux/$MIRROR_PATH/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.ustc.edu.cn/docker-ce/linux/$MIRROR_PATH $VERSION_CODE stable" > /etc/apt/sources.list.d/docker.list

        apt-get update
        # Debian 需要额外安装组件
        local pkg_list="docker-ce docker-ce-cli containerd.io"
        [[ "$OS" == *"Debian"* ]] && pkg_list+=" docker-buildx-plugin docker-compose-plugin"
        
        apt-get install -y $pkg_list

        # 验证安装
        if docker --version; then
            echo -e "${GREEN}[SUCCEED]${NC} Docker $(docker --version | awk '{print $3}') installed"
        else
            echo -e "${RED}[ERROR]${NC} Docker installation failed"
            return 1
        fi

        # 处理旧配置文件
        echo "Configuring Docker registry mirrors..."
        mkdir -p /etc/docker
        [ -f /etc/docker/daemon.json ] && rm -f /etc/docker/daemon.json

        # 生成daemon.json配置
        echo "Creating docker daemon.json..."
        cat > /etc/docker/daemon.json <<EOF
{
    "registry-mirrors": [
        "https://docker-0.unsee.tech",
        "https://docker.1panel.live"
    ]
}
EOF
        sudo systemctl daemon-reload && sudo systemctl restart docker

        # 配置用户权限（即使使用脚本安装也需要）
        if [ "$create_user_choice" = "y" ]; then
            if ! getent group docker >/dev/null; then
                if ! groupadd docker; then
                    handle_error "Docker Group Creation" "$?"
                    return 1
                fi
            fi
            if ! usermod -aG docker "$new_username"; then
                handle_error "Docker User Permission" "$?"
                return 1
            fi
            # 验证用户是否成功添加到组
            if ! groups "$new_username" | grep -q docker; then
                handle_error "Docker Group Verification" "Failed to add user to docker group"
                return 1
            fi
        fi

        # 基础功能验证
        if ! docker run --rm hello-world; then
            handle_error "Docker Test" "Hello-world container failed"
            return 1
        fi

        # 配置服务自启动
        echo "Configuring Docker service..."
        systemctl enable docker
        systemctl start docker

        # 重启docker使配置生效
        systemctl daemon-reload
        systemctl restart docker

        # 最终系统更新
        echo "Performing final system update..."
        eval "$PKG_UPDATE"

    } || handle_error "Install Docker" "$?"
}

# 8. Install Git
install_git() {
    {
        if [ "$install_git_choice" = "y" ]; then
            # 检查是否已安装Git
            if command -v git &>/dev/null; then
                echo "Git is already installed. Checking for updates..."
                
                # 获取当前版本
                current_version=$(git --version | awk '{print $3}')
                
                # 检查并更新
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
        fi
    } || handle_error "Install Git" "$?"
}

# Configure APT sources
configure_apt_sources() {
    {
        echo -e "${BLUE}[INFO]${NC} Configuring APT sources..."
        
        if [[ "$OS" == *"Debian"* || "$OS" == *"Ubuntu"* ]] && [ -n "$MIRROR_URL" ]; then
            # Backup original sources
            if [ -f /etc/apt/sources.list ]; then
                cp /etc/apt/sources.list "/etc/apt/sources.list.backup.$(date +%Y%m%d%H%M%S)"
                echo -e "${GREEN}[SUCCEED]${NC} Backed up original sources.list"
            fi
            
            if [[ "$OS" == *"Debian"* ]]; then
                VERSION_CODE=$(. /etc/os-release && echo "$VERSION_CODENAME")
                VERSION_NUM=$(. /etc/os-release && echo "$VERSION_ID")
                
                echo -e "${BLUE}[INFO]${NC} Configuring Debian sources with $MIRROR_NAME ($MIRROR_URL)"
                
                # 根据Debian版本配置不同的源
                if [ "$VERSION_NUM" -ge 12 ]; then
                    # Debian 12 (Bookworm) 及以上版本包含 non-free-firmware
                    cat > /etc/apt/sources.list << EOF
# Debian $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main contrib non-free non-free-firmware
deb http://$MIRROR_URL $VERSION_CODE-updates main contrib non-free non-free-firmware
deb http://$MIRROR_URL $VERSION_CODE-backports main contrib non-free non-free-firmware
deb http://$MIRROR_URL-security $VERSION_CODE-security main contrib non-free non-free-firmware
EOF
                else
                    # Debian 11 (Bullseye) 及以下版本
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
                
                echo -e "${BLUE}[INFO]${NC} Configuring Ubuntu sources with $MIRROR_NAME ($MIRROR_URL)"
                
                cat > /etc/apt/sources.list << EOF
# Ubuntu $VERSION_CODE repository ($MIRROR_NAME)
deb http://$MIRROR_URL $VERSION_CODE main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-updates main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-backports main restricted universe multiverse
deb http://$MIRROR_URL $VERSION_CODE-security main restricted universe multiverse
EOF
            fi
            
            # 验证文件是否成功创建和写入
            if [ -f /etc/apt/sources.list ] && [ -s /etc/apt/sources.list ]; then
                echo -e "${GREEN}[SUCCEED]${NC} APT sources configured for $OS"
                echo -e "${GREEN}[SUCCEED]${NC} Using $MIRROR_NAME"
                
                # Update package lists
                if apt-get update; then
                    echo -e "${GREEN}[SUCCEED]${NC} APT sources update completed"
                else
                    echo -e "${RED}[ERROR]${NC} Failed to update APT sources"
                    return 1
                fi
            else
                echo -e "${RED}[ERROR]${NC} Failed to write sources.list"
                return 1
            fi
            
        else
            echo -e "${YELLOW}[WARN]${NC} Skipping APT source configuration: either unsupported system or no mirror selected"
        fi
        
    } || handle_error "Configure APT Sources" "$?"
}

# Main program
main() {
    echo -e "${BLUE}[INIT]${NC} Starting system initialization..."
    set_timezone
    get_user_choices
    remove_snap        
    system_update        
    install_git        
    disable_hibernation        
    setup_ssh
    
    if [ "$create_user_choice" = "y" ]; then
        create_user
        configure_ssh
    fi
    
    if [ "$install_docker_choice" = "y" ]; then
        install_docker
    fi

    echo "System initialization completed!"
    if [ "$create_user_choice" = "y" ]; then
        echo "Please use SSH port $ssh_port and username $new_username to login"
        echo "Remember to save the SSH config backup file: /etc/ssh/sshd_config.backup"
    fi

    # Check if any steps failed and report
    if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
        echo -e "\nWarning: The following steps encountered errors:"
        printf '%s\n' "${FAILED_STEPS[@]}"
        echo "Please check $ERROR_LOG for detailed error messages"
    else
        # Clean up error log if empty
        if [ ! -s "$ERROR_LOG" ]; then
            rm -f "$ERROR_LOG"
            echo -e "\nNo errors occurred during initialization - error log removed"
        fi
    fi
}

# Execute main program
main 