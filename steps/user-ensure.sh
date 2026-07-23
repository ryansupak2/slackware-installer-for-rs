#!/bin/bash
# steps/user-ensure.sh - ENSURE USER EXISTS + DESKTOP GROUPS

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
TARGET_USER="${TARGET_USER:-$1}"
ADD_WHEEL="${ADD_WHEEL:-false}"

if [ -z "$TARGET_USER" ]; then
    echo "ERROR: TARGET_USER not set for user-ensure.sh"
    exit 1
fi
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "ENSURE USER + GROUPS: $TARGET_USER"
echo "*****************************************************"

if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User $TARGET_USER already exists. Keeping existing user."
    # Still ensure groups and shell are correct
    if $ADD_WHEEL; then
        if ! groups "$TARGET_USER" | grep -q '\bwheel\b'; then
            usermod -aG wheel "$TARGET_USER"
            echo "Added $TARGET_USER to wheel group."
        fi
    fi
    for grp in wheel input video seat audio tty netdev; do
        addgroup "$grp" 2>/dev/null || true
        if ! groups "$TARGET_USER" | grep -q "\b$grp\b"; then
            usermod -aG "$grp" "$TARGET_USER"
            echo "Added $TARGET_USER to $grp group."
        fi
    done
    current_shell=$(getent passwd "$TARGET_USER" | cut -d: -f7)
    if [ "$current_shell" != "/bin/bash" ]; then
        usermod -s /bin/bash "$TARGET_USER" || true
        echo "Set login shell for $TARGET_USER to /bin/bash"
    fi
    echo "SUCCESS: User $TARGET_USER ensured (existing user kept and groups updated)."
    # Deploy sudoers for passwordless modprobe/rmmod (wheel group)
    if $ADD_WHEEL; then
        mkdir -p /etc/sudoers.d
        cp "$REPO_DIR/dotfiles/sudoers/modprobe" /etc/sudoers.d/modprobe 2>/dev/null || true
        chmod 440 /etc/sudoers.d/modprobe 2>/dev/null || true
    fi
fi

# Create the user (fresh)
echo "Creating user $TARGET_USER..."
if ! useradd -m "$TARGET_USER"; then
    echo "ERROR: useradd failed for $TARGET_USER"
    exit 1
fi

# Add all the standard groups a desktop user needs
for grp in wheel input video seat audio tty netdev; do
    addgroup "$grp" 2>/dev/null || true
    usermod -aG "$grp" "$TARGET_USER" 2>/dev/null || true
done

if $ADD_WHEEL; then
    echo "Added $TARGET_USER to wheel group (sudo access)."
fi

echo "Setting password for new user $TARGET_USER..."
passwd "$TARGET_USER"

# Ensure correct login shell
usermod -s /bin/bash "$TARGET_USER" || true
echo "Set login shell for $TARGET_USER to /bin/bash"

echo "SUCCESS: User $TARGET_USER created with all required groups."
# Deploy sudoers for passwordless modprobe/rmmod (wheel group)
if $ADD_WHEEL; then
    mkdir -p /etc/sudoers.d
    cp "$REPO_DIR/dotfiles/sudoers/modprobe" /etc/sudoers.d/modprobe 2>/dev/null || true
    chmod 440 /etc/sudoers.d/modprobe 2>/dev/null || true
fi
exit 0