#!/bin/bash

# Set system timezone
set_timezone() {
    {
        # Get current timezone
        current_tz=$(timedatectl show --property=Timezone --value)
        echo "Current system timezone: $current_tz"
        
        # Detect timezone by IP
        echo "Detecting timezone based on IP address..."
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
            read -p "Would you like to manually select timezone? (y/n): " manual_select
            [ "$manual_select" = "y" ] || return 0
        fi

        if [ "$manual_select" = "true" ] || [ "$manual_select" = "y" ]; then
            echo "Available timezones:"
            timedatectl list-timezones
            read -p "Enter your timezone (e.g., Asia/Shanghai): " new_timezone
        fi

        # Set new timezone if selected
        if [ -n "$new_timezone" ]; then
            if timedatectl set-timezone "$new_timezone"; then
                echo "Timezone successfully set to: $new_timezone"
                hwclock --systohc
            else
                echo "Failed to set timezone"
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
    echo "[$step] Error occurred at $(date '+%Y-%m-%d %H:%M:%S')" >> "$ERROR_LOG"
    echo "Error message: $error_msg" >> "$ERROR_LOG"
    echo "Command: $BASH_COMMAND" >> "$ERROR_LOG"
    echo "----------------------------------------" >> "$ERROR_LOG"
    FAILED_STEPS+=("$step")
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

# Configuration choices
get_user_choices() {
    echo "System initialization configuration"
    echo "----------------------------------------"
    
    # Choice 1/5: Remove snap
    echo "Choice (1/5): Remove snap?"
    if [[ "$OS" == *"Ubuntu"* ]]; then
        echo "Do you want to remove snap? (y/n)"
        read -r remove_snap_choice
    else
        remove_snap_choice="n"
    fi

    # Choice 2/5: Create new user
    echo -e "\nChoice (2/5): User creation"
    echo "Do you want to create a new user? (y/n)"
    read -r create_user_choice
    
    if [ "$create_user_choice" = "y" ]; then
        echo "Enter new username:"
        read -r new_username
    fi

    # Choice 3/5: SSH key
    echo -e "\nChoice (3/5): SSH configuration"
    echo "Do you want to add SSH public key? (y/n)"
    read -r add_ssh_key_choice
    
    if [ "$add_ssh_key_choice" = "y" ] && [ "$create_user_choice" != "y" ]; then
        echo "Note: You need to create a user to add SSH key"
        add_ssh_key_choice="n"
    fi

    # Choice 4/5: SSH port
    if [ "$create_user_choice" = "y" ]; then
        echo -e "\nChoice (4/5): SSH port"
        echo "Enter new SSH port (recommended: greater than 1024):"
        read -r ssh_port
    fi

    # Choice 5/5: Install Docker
    echo -e "\nChoice (5/5): Docker Installation"
    echo "Do you want to install Docker? (y/n)"
    read -r install_docker_choice
    
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
        # Create user with home directory
        useradd -m "$new_username"
        
        # Set password
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
        echo "Enter new SSH port (recommended: greater than 1024):"
        read -r ssh_port

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

        systemctl restart sshd
    } || handle_error "Configure SSH" "$?"
}

# 7. Install Docker
install_docker() {
    {
        # 更彻底的旧版本清理
        echo "Removing all Docker components..."
        apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
        apt-get purge -y docker-ce docker-ce-cli containerd.io 2>/dev/null || true
        rm -rf /var/lib/docker /var/lib/containerd

        # 直接进行手动安装
        echo "Starting manual Docker installation..."
        apt-get update
        apt-get install -y apt-transport-https ca-certificates curl gnupg-agent software-properties-common
        
        # 使用国内镜像源
        curl -fsSL https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.ustc.edu.cn/docker-ce/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io

        # 验证安装
        echo "Verifying Docker installation..."
        if ! docker --version; then
            handle_error "Docker Verification" "Docker installation failed"
            return 1
        fi

        # 配置用户权限（即使使用脚本安装也需要）
        if [ "$create_user_choice" = "y" ]; then
            if ! getent group docker >/dev/null; then
                groupadd docker
            fi
            usermod -aG docker "$new_username"
        fi

        # 基础功能验证
        if ! docker run --rm hello-world; then
            handle_error "Docker Test" "Hello-world container failed"
            return 1
        fi

        # 配置服务自启动
        echo "Configuring Docker service..."
        systemctl enable docker  # 设置开机自启
        systemctl start docker   # 立即启动服务

        # 最终系统更新
        echo "Performing final system update..."
        $PKG_UPDATE

        # 创建docker配置目录
        mkdir -p /etc/docker

        # 配置镜像加速器（包含多个备用源）
        cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://hub-mirror.c.163.com",
        "https://mirror.baidubce.com",
        "https://docker.mirrors.ustc.edu.cn",
        "https://docker.nju.edu.cn"
    ],
    "live-restore": true,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    }
}
EOF

        # 重启docker使配置生效
        systemctl daemon-reload
        systemctl restart docker

    } || handle_error "Install Docker" "$?"
}

# Main program
main() {
    set_timezone
    get_user_choices
    
    remove_snap
    system_update
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
    fi
}

# Execute main program
main 