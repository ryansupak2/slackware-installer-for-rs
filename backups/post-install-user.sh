#!/bin/bash

# post-install-user.sh - Per-user setup for Slackware installer
# Run for each user after post-install-global.sh.

if [ "$1" = "--help" ]; then
    echo "Usage: $0 --user <username> [--wheel]"
    echo "Sets up per-user configs for the specified user."
    echo "Run as root. Creates user if they don't exist (with confirmation)."
    echo "Interactive menu by default."
    echo "Prompts before overwriting existing files."
    echo ""
    echo "Options:"
    echo "  --user <username>       Specify the target user (creates if not exists)."
    echo "  --wheel                 Add user to wheel group for sudo access."

    echo ""
    echo "Examples:"
    echo "  $0 --user alice                           # Interactive setup (creates alice if needed)"
    echo "  $0 --user bob --wheel                     # Create/setup bob with sudo access"

    echo ""
    echo "Prerequisites: Run from the slackware-installer-for-rs repo directory."
    exit 0
fi

if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi
TARGET_USER=""
ADD_WHEEL=false
INTERACTIVE=true
while [ $# -gt 0 ]; do
    case $1 in
        --user) TARGET_USER="$2"; shift 2 ;;
        --wheel) ADD_WHEEL=true; shift ;;
        
        *) echo "Invalid option. Use --help for usage."; exit 1 ;;
    esac
done
if [ -z "$TARGET_USER" ]; then echo "Specify --user. Use --help for usage."; exit 1; fi

# User creation/setup
setup_user() {
    if id "$TARGET_USER" >/dev/null 2>&1; then
        echo "User $TARGET_USER exists."
        if $ADD_WHEEL; then
            if groups "$TARGET_USER" | grep -q '\bwheel\b'; then
                echo "User already in wheel group."
            else
                usermod -aG wheel "$TARGET_USER"
                echo "Added $TARGET_USER to wheel group."
                usermod -aG openvpn "$TARGET_USER"
                echo "Added $TARGET_USER to openvpn group."
            fi
        fi

        # Add user to openvpn group if not already
        if groups "$TARGET_USER" | grep -q '\bopenvpn\b'; then
            echo "User already in openvpn group."
        else
            usermod -aG openvpn "$TARGET_USER"
            echo "Added $TARGET_USER to openvpn group."
        fi

        # Allow wheel users to run openvpn and related commands without password
        if [ ! -f /etc/sudoers.d/openvpn ]; then
            cp dotfiles/sudoers/openvpn /etc/sudoers.d/openvpn
            chmod 440 /etc/sudoers.d/openvpn
            echo "Configured sudo for OpenVPN and related commands."
        fi
    else
        echo "User $TARGET_USER does not exist."
        if [ -t 0 ]; then
            read -p "Create user $TARGET_USER? (y/n): " choice
            case "$choice" in
                y|Y)
                    useradd -m "$TARGET_USER"
                    if $ADD_WHEEL; then
                        usermod -aG wheel "$TARGET_USER"
                        usermod -aG openvpn "$TARGET_USER"
                        echo "Added $TARGET_USER to openvpn group."
                        # Allow wheel users to run openvpn and related commands without password
                        cp dotfiles/sudoers/openvpn /etc/sudoers.d/openvpn
                        chmod 440 /etc/sudoers.d/openvpn
                        echo "Configured sudo for OpenVPN and related commands."
                    fi
                    passwd "$TARGET_USER"
                    echo "User $TARGET_USER created."
                    ;;
                *)
                    echo "Cannot proceed without user. Exiting."
                    exit 1
                    ;;
            esac
        else
            echo "Non-interactive mode: Cannot create user. Exiting."
            exit 1
        fi
    fi
}

setup_user
HOME_TARGET=$(eval echo ~$TARGET_USER)

# Ensure user config directory exists
mkdir -p "$HOME_TARGET/.config"
chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config"

# Auto-copy user-specific setup.keys
USER_KEY_FILE="/root/slackware-installer-for-rs/setup.keys.$TARGET_USER"
if [ -f "$USER_KEY_FILE" ]; then
    cp "$USER_KEY_FILE" "$HOME_TARGET/.setup.keys"
    chmod 600 "$HOME_TARGET/.setup.keys"
else
    echo "Warning: $USER_KEY_FILE not found; some setups may fail."
fi

# Function definitions
setup_bashrc() {
    echo "Copying User Preferences..."
    target="$HOME_TARGET/.bashrc"
    if [ -f "$target" ] && [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/shell/bashrc "$target"; chmod 600 "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        cp ./dotfiles/shell/bashrc "$target"
        chmod 600 "$target"
        echo "Copied to $target"
    fi
}

setup_vim() {
    echo "Updating vim Config..."
    mkdir -p "$HOME_TARGET/.vim/swap"
    mkdir -p "$HOME_TARGET/.vim/backup"
    mkdir -p "$HOME_TARGET/.vim/undo"
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.vim"

    target="$HOME_TARGET/.vimrc"
    if [ -f "$target" ] && [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/editors/vimrc "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        cp ./dotfiles/editors/vimrc "$target"
        echo "Copied to $target"
    fi
}

setup_opencode() {
    echo "Configuring OpenCode..."

    # Source keys
    if [ -f "$HOME_TARGET/.setup.keys" ]; then
        source "$HOME_TARGET/.setup.keys"
    fi

    mkdir -p "$HOME_TARGET/.config/opencode"
    target="$HOME_TARGET/.config/opencode/opencode.json"
    if [ -f "$target" ]; then
        if [ -t 0 ]; then
            read -p "Overwrite $target? (y/n): " choice
            case "$choice" in
                y|Y) cp ./dotfiles/opencode/opencode.json "$target"; chmod 600 "$target"; echo "Overwritten $target" ;;
                *) echo "Skipped $target (safety: no overwrite)" ;;
            esac
        else
            echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
        fi
    else
        cp ./dotfiles/opencode/opencode.json "$target"
        chmod 600 "$target"
        echo "Copied to $target"
    fi

    # Set OpenCode API key
    if [ -n "$XAI_API_KEY_CODE" ]; then
        mkdir -p "$HOME_TARGET/.local/state"
        mkdir -p "$HOME_TARGET/.local/share/opencode"
        echo "{\"xai\": {\"type\": \"api\", \"key\": \"$XAI_API_KEY_CODE\"}}" > "$HOME_TARGET/.local/share/opencode/auth.json"
        chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.local/state" "$HOME_TARGET/.local/share/opencode"
    else
        echo "Warning: XAI_API_KEY_CODE not set; OpenCode keys not configured."
    fi

    mkdir -p "$HOME_TARGET/.local/share/opencode"
    # NOTE: setup.keys must be pre-copied to ~/.local/share/opencode/ by root for each user (excluded from shared repo for security)
    if [ -f "$HOME_TARGET/.local/share/opencode/setup.keys" ]; then
        chmod 600 "$HOME_TARGET/.local/share/opencode/setup.keys"
    fi
}

setup_ssh() {
    echo "Setting up SSH for $TARGET_USER..."

    # Ensure .ssh directory exists
    mkdir -p "$HOME_TARGET/.ssh"
    chmod 700 "$HOME_TARGET/.ssh"
    chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh"

    # Generate SSH key if not exists (RSA for compatibility)
    if [ ! -f "$HOME_TARGET/.ssh/id_rsa" ]; then
        echo "Generating SSH key..."
        su - "$TARGET_USER" -c "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N '' -C '$TARGET_USER@localhost'"
        echo "SSH key generated. Public key: $HOME_TARGET/.ssh/id_rsa.pub"
        echo "Add the public key to your GitHub or remote servers."
    else
        echo "SSH key already exists at $HOME_TARGET/.ssh/id_rsa"
    fi

    # Create basic SSH config
    if [ ! -f "$HOME_TARGET/.ssh/config" ]; then
        cat > "$HOME_TARGET/.ssh/config" <<EOF
Host *
    StrictHostKeyChecking ask
    UserKnownHostsFile ~/.ssh/known_hosts
    IdentitiesOnly yes
EOF
        chmod 600 "$HOME_TARGET/.ssh/config"
        chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh/config"
        echo "Basic SSH config created."
    fi

    # Set up SSH agent
    if command -v keychain >/dev/null 2>&1; then
        echo 'eval `keychain --eval --quiet ~/.ssh/id_rsa`' >> "$HOME_TARGET/.bashrc"
        echo "SSH keychain setup added to $HOME_TARGET/.bashrc"
    else
        echo 'eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_rsa' >> "$HOME_TARGET/.bashrc"
        echo "SSH agent setup added to $HOME_TARGET/.bashrc (keychain not available)"
    fi

    # Set ownership
    chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.ssh"
}

setup_startx() {
    echo "Configuring startx..."
    target="$HOME_TARGET/.xinitrc"
    if [ -f "$target" ] && [ -t 0 ]; then
        read -p "Overwrite $target? (y/n): " choice
        case "$choice" in
            y|Y) cp ./dotfiles/x11/xinitrc "$target"; echo "Overwritten $target" ;;
            *) echo "Skipped $target (safety: no overwrite)" ;;
        esac
    else
        cp ./dotfiles/x11/xinitrc "$target"
        echo "Copied to $target"
    fi
}

setup_neofetch() {
    echo "Setting up Neofetch..."
    mkdir -p "$HOME_TARGET/.config/neofetch"

    # Copy bobdobbs.txt
    target="$HOME_TARGET/.config/neofetch/bobdobbs.txt"
    if [ -f "$target" ]; then
        if [ -t 0 ]; then
            read -p "Overwrite $target? (y/n): " choice
            case "$choice" in
                y|Y) cp ./dotfiles/neofetch/bobdobbs.txt "$target"; echo "Overwritten $target" ;;
                *) echo "Skipped $target (safety: no overwrite)" ;;
            esac
        else
            echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
        fi
    else
        cp ./dotfiles/neofetch/bobdobbs.txt "$target"
        echo "Copied to $target"
    fi

    # Copy and modify config.conf
    target="$HOME_TARGET/.config/neofetch/config.conf"
    if [ -f "$target" ]; then
        if [ -t 0 ]; then
            read -p "Overwrite $target? (y/n): " choice
            case "$choice" in
                y|Y) cp ./dotfiles/neofetch/config.conf "$target"; sed -i "s|/root/|$HOME_TARGET/|g" "$target"; echo "Overwritten $target" ;;
                *) echo "Skipped $target (safety: no overwrite)" ;;
            esac
        else
            echo "Non-interactive mode: Skipped $target (safety: no overwrite)"
        fi
    else
        cp ./dotfiles/neofetch/config.conf "$target"
        sed -i "s|/root/|$HOME_TARGET/|g" "$target"
        echo "Copied to $target"
    fi
}

setup_llm() {
    echo "Setting up LLM for $TARGET_USER..."

    # Source keys
    if [ -f "$HOME_TARGET/.setup.keys" ]; then
        source "$HOME_TARGET/.setup.keys"
    fi

    # Copy system prompt
    cp /root/slackware-installer-for-rs/dotfiles/llm/llm-system-prompt "$HOME_TARGET/.llm-system-prompt"

    # Set Grok API key (assumes XAI_API_KEY_CHAT in setup.keys, copied to user)
    if [ -n "$XAI_API_KEY_CHAT" ]; then
        mkdir -p "$HOME_TARGET/.config/io.datasette.llm"
        echo '{"grok": "'$XAI_API_KEY_CHAT'"}' > "$HOME_TARGET/.config/io.datasette.llm/keys.json"
        chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.config/io.datasette.llm"
        chmod 600 "$HOME_TARGET/.config/io.datasette.llm/keys.json"
    else
        echo "Warning: XAI_API_KEY_CHAT not set; LLM keys not configured."
    fi

    # Set default model
    su - "$TARGET_USER" -c "llm models default grok-4-1-fast"

    echo "LLM setup complete for $TARGET_USER."
}

echo "*****************************************************"
echo "USER-SPECIFIC SETUP FOR $TARGET_USER"
echo "*****************************************************"

    options=("Bashrc" "Vim" "OpenCode" "SSH Setup" "StartX" "Neofetch" "LLM")

if $INTERACTIVE; then
    selected=()

    PS3="Enter your choice (or 'done' to proceed): "
    while true; do
        echo "Select dotfile sections to set up for $TARGET_USER:"
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done
        echo "8. All sections"
        echo "9. Exit"

        read -p "$PS3" choice
        case $choice in
            all|All|ALL|8)
                selected=("${options[@]}")
                break
                ;;
            exit|Exit|EXIT|9)
                exit 0
                ;;
            done|Done|DONE)
                break
                ;;
            [0-9]*,*[0-9]*)
                IFS=',' read -ra nums <<< "$choice"
                for num in "${nums[@]}"; do
                    if [ "$num" = "6" ]; then
                        selected=("${options[@]}")
                        break 2
                    elif [ "$num" = "7" ]; then
                        exit 0
                    elif [ $num -ge 1 ] && [ $num -le ${#options[@]} ]; then
                        selected+=("${options[$((num-1))]}")
                    fi
                done
                ;;
            [1-$(( ${#options[@]} ))])
                num=$((choice-1))
                selected+=("${options[$num]}")
                ;;
            *)
                echo "Invalid choice. Try again."
                ;;
        esac
    done

    if [ ${#selected[@]} -eq 0 ]; then
        echo "No sections selected. Exiting."
        exit 0
    fi

    echo "Selected sections: ${selected[*]}"
    read -p "Proceed with these sections? (y/N): " confirm
    [[ "$confirm" != [yY] ]] && exit 0
else
    selected=("${options[@]}")
fi

# Execute selected functions
for section in "${selected[@]}"; do
    case $section in
        "Bashrc") setup_bashrc ;;
        "Vim") setup_vim ;;
        "OpenCode") setup_opencode ;;
        "SSH Setup") setup_ssh ;;
        "StartX") setup_startx ;;
        "Neofetch") setup_neofetch ;;
        "LLM") setup_llm ;;
    esac
done

# Set ownership for user directories and files (always run)
chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.bashrc" "$HOME_TARGET/.vimrc" "$HOME_TARGET/.xinitrc" 2>/dev/null || true
for dir in "$HOME_TARGET/.config/opencode" "$HOME_TARGET/.local/share/opencode" "$HOME_TARGET/.config/neofetch" "$HOME_TARGET/.config/io.datasette.llm" "$HOME_TARGET/.local/state" "$HOME_TARGET/.ssh" "$HOME_TARGET/.vim"; do
    if [ -d "$dir" ]; then
        chown -R "$TARGET_USER:$TARGET_USER" "$dir"
    fi
done

echo "Per-user setup complete for $TARGET_USER."
