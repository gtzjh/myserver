#!/bin/bash

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
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
        PKG_UPDATE="dnf update -y"
        PKG_INSTALL="dnf install -y"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
        PKG_UPDATE="yum update -y"
        PKG_INSTALL="yum install -y"
    else
        echo "No supported package manager found"
        exit 1
    fi
else
    echo "Cannot determine OS type"
    exit 1
fi

# 1. Remove snap (Ubuntu only)
remove_snap() {
    {
        if [[ "$OS" == *"Ubuntu"* ]]; then
            echo "Ubuntu detected. Do you want to remove snap? (y/n)"
            read -r remove_snap_confirm
            if [ "$remove_snap_confirm" = "y" ]; then
                snap list | awk 'NR>1 {print $1}' | xargs -I {} sudo snap remove {}
                apt autoremove --purge snapd -y
                rm -rf ~/snap/
                rm -rf /snap
                rm -rf /var/snap
                rm -rf /var/lib/snapd
            fi
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
            if [ "$PKG_MANAGER" = "apt" ]; then
                $PKG_INSTALL openssh-server
            else
                $PKG_INSTALL openssh-server
                # For RHEL/CentOS, also open firewall port
                if command -v firewall-cmd >/dev/null 2>&1; then
                    firewall-cmd --permanent --add-service=ssh
                    firewall-cmd --reload
                fi
            fi
            systemctl enable sshd
            systemctl start sshd
        fi
    } || handle_error "Setup SSH" "$?"
}

# 5. Create new user
create_user() {
    {
        echo "Enter new username:"
        read -r new_username

        # Create user with home directory
        useradd -m "$new_username"
        
        # Set password
        passwd "$new_username"
        
        # Add to sudo/wheel group based on OS
        if [ "$PKG_MANAGER" = "apt" ]; then
            usermod -aG sudo "$new_username"
        else
            usermod -aG wheel "$new_username"
            # Ensure wheel group has sudo privileges
            if [ ! -f /etc/sudoers.d/wheel ]; then
                echo "%wheel  ALL=(ALL)       ALL" > /etc/sudoers.d/wheel
                chmod 440 /etc/sudoers.d/wheel
            fi
        fi
        
        # Set shell
        usermod -s /bin/bash "$new_username"
        
        # Create .ssh directory
        mkdir -p "/home/$new_username/.ssh"
        chmod 700 "/home/$new_username/.ssh"
        touch "/home/$new_username/.ssh/authorized_keys"
        chmod 600 "/home/$new_username/.ssh/authorized_keys"
        chown -R "$new_username:$new_username" "/home/$new_username/.ssh"

        echo "Enter SSH public key (paste and press Enter, then Ctrl+D when done):"
        cat > "/home/$new_username/.ssh/authorized_keys"
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

        # Update firewall rules for RHEL/CentOS
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --permanent --remove-service=ssh
            firewall-cmd --permanent --add-port="$ssh_port/tcp"
            firewall-cmd --reload
        fi

        systemctl restart sshd
    } || handle_error "Configure SSH" "$?"
}

# 7. Install Docker
install_docker() {
    {
        if [ "$PKG_MANAGER" = "apt" ]; then
            # Debian/Ubuntu installation
            $PKG_INSTALL apt-transport-https ca-certificates curl software-properties-common

            # Add Docker's official GPG key
            curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

            # Add Docker repository
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

            $PKG_UPDATE
            $PKG_INSTALL docker-ce docker-ce-cli containerd.io
        else
            # RHEL/CentOS installation
            $PKG_INSTALL yum-utils
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
            $PKG_INSTALL docker-ce docker-ce-cli containerd.io

            # Configure firewall
            if command -v firewall-cmd >/dev/null 2>&1; then
                firewall-cmd --permanent --add-service=docker
                firewall-cmd --reload
            fi
        fi

        # Create docker config directory
        mkdir -p /etc/docker

        # Configure Docker daemon
        cat > /etc/docker/daemon.json << EOF
{
    "registry-mirrors": [
        "https://mirror.ccs.tencentyun.com",
        "https://hub-mirror.c.163.com",
        "https://mirror.baidubce.com"
    ]
}
EOF

        # Start and enable Docker
        systemctl enable docker
        systemctl start docker

        # Add new user to docker group
        usermod -aG docker "$new_username"

        # Install Docker Compose
        if [ "$PKG_MANAGER" = "apt" ]; then
            # For Debian/Ubuntu
            $PKG_INSTALL docker-compose-plugin
            # Create symbolic link for backward compatibility
            ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
        else
            # For RHEL/CentOS
            $PKG_INSTALL docker-compose-plugin
            # Create symbolic link for backward compatibility
            ln -sf /usr/libexec/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
        fi

        # Verify installations
        echo "Verifying Docker and Docker Compose installations..."
        docker --version
        docker compose version
    } || handle_error "Install Docker" "$?"
}

# Main program
main() {
    remove_snap
    system_update
    disable_hibernation
    setup_ssh
    create_user
    configure_ssh
    install_docker

    echo "System initialization completed!"
    echo "Please use SSH port $ssh_port and username $new_username to login"
    echo "Remember to save the SSH config backup file: /etc/ssh/sshd_config.backup"

    # Check if any steps failed and report
    if [ ${#FAILED_STEPS[@]} -gt 0 ]; then
        echo -e "\nWarning: The following steps encountered errors:"
        printf '%s\n' "${FAILED_STEPS[@]}"
        echo "Please check $ERROR_LOG for detailed error messages"
    fi
}

# Execute main program
main 