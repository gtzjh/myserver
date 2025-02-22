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
            
            # Remove snapd
            apt autoremove --purge snapd -y
            
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
        # Remove old versions if they exist
        for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
            apt-get remove $pkg 2>/dev/null || true
        done

        # Install prerequisites
        $PKG_INSTALL apt-transport-https ca-certificates curl gnupg lsb-release

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]')/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(lsb_release -is | tr '[:upper:]' '[:lower:]') \
            $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Update package list
        $PKG_UPDATE

        # Install Docker packages
        $PKG_INSTALL docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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

        # Add new user to docker group if user was created
        if [ "$create_user_choice" = "y" ]; then
            usermod -aG docker "$new_username"
        fi

        # Create symbolic link for docker-compose
        ln -sf $(which docker-compose) /usr/local/bin/docker-compose

        # Verify installations
        echo "Verifying Docker and Docker Compose installations..."
        docker --version
        docker compose version
    } || handle_error "Install Docker" "$?"
}

# Main program
main() {
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