#!/bin/bash
# steps/user-ensure.sh - ENSURE USER EXISTS + DESKTOP GROUPS
#
# Idempotent: safe to run again on an existing user (it only tops up groups,
# shell and — when TARGET_PASS is set — the password).
#
# Environment:
#   TARGET_USER  user to create/ensure (or pass as $1)
#   TARGET_PASS  optional password to set non-interactively (chpasswd);
#                without it a newly created user gets an interactive passwd
#   ADD_WHEEL    true = also add to wheel + the modprobe sudoers rule.
#                This is NOT needed for desktop features: those are covered by
#                steps/user-helpers.sh, which grants only the specific helper
#                commands the installed UI calls.

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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: user-ensure.sh must run as root"
    exit 1
fi

echo "*****************************************************"
echo "ENSURE USER + GROUPS: $TARGET_USER"
echo "*****************************************************"

# Groups a desktop user needs to use the installed hardware:
#   input   - evdev (capslock, copilot-mod, trackpoint)
#   video   - /dev/dri, /dev/video* (Chrome camera, brightness)
#   audio   - /dev/snd (PipeWire, VOX)
#   seat/tty- logind session, console
#   netdev  - network config (wifi-manager, vpn without root)
#   plugdev - removable media
#   power   - power/backlight policy helpers
#   cdrom/lp/scanner - optical, printing, scanning
#   kvm     - /dev/kvm for VMs
#   dialout - serial/USB devices
# Deliberately NOT: disk, mem, kmem, raw, root/wheel (root-equivalent).
DESKTOP_GROUPS="input video seat audio tty netdev plugdev power cdrom lp scanner kvm dialout"
[ "$ADD_WHEEL" = "true" ] && DESKTOP_GROUPS="wheel $DESKTOP_GROUPS"

add_groups() {
    for grp in $DESKTOP_GROUPS; do
        # groupadd is the shadow tool that actually creates a group;
        # Slackware's addgroup wrapper silently does nothing without a GID.
        groupadd "$grp" 2>/dev/null || addgroup "$grp" 2>/dev/null || true
        if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$grp"; then
            usermod -aG "$grp" "$TARGET_USER" && echo "  Added $TARGET_USER to $grp group."
        fi
    done
}

set_password_noninteractive() {
    [ -n "${TARGET_PASS:-}" ] || return 1
    if printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASS" | chpasswd; then
        echo "  Password set for $TARGET_USER (non-interactive)."
        return 0
    fi
    echo "ERROR: chpasswd failed for $TARGET_USER"
    return 1
}

if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User $TARGET_USER already exists. Keeping existing user."
else
    echo "Creating user $TARGET_USER..."
    if ! useradd -m "$TARGET_USER"; then
        echo "ERROR: useradd failed for $TARGET_USER"
        exit 1
    fi
fi

add_groups

# Ensure correct login shell
current_shell=$(getent passwd "$TARGET_USER" | cut -d: -f7)
if [ "$current_shell" != "/bin/bash" ]; then
    usermod -s /bin/bash "$TARGET_USER" || true
    echo "Set login shell for $TARGET_USER to /bin/bash"
fi

# Password: non-interactive when TARGET_PASS is provided, otherwise prompt for
# a brand-new account only (never silently rewrite an existing password).
if [ -n "${TARGET_PASS:-}" ]; then
    set_password_noninteractive || exit 1
else
    if ! getent shadow "$TARGET_USER" >/dev/null 2>&1; then
        echo "ERROR: no shadow entry for $TARGET_USER"
        exit 1
    fi
    # "!" / "*" / "" = no usable password yet
    case "$(getent shadow "$TARGET_USER" | cut -d: -f2)" in
        ''|'!'*|'*'*)
            echo "Setting password for $TARGET_USER..."
            passwd "$TARGET_USER" || { echo "ERROR: passwd failed"; exit 1; }
            ;;
        *)
            echo "Keeping existing password for $TARGET_USER (set TARGET_PASS to change it)."
            ;;
    esac
fi

# The wheel-only modprobe rule is not needed by desktop features.
if [ "$ADD_WHEEL" = "true" ]; then
    mkdir -p /etc/sudoers.d
    cp "$REPO_DIR/dotfiles/sudoers/modprobe" /etc/sudoers.d/modprobe 2>/dev/null || true
    chmod 440 /etc/sudoers.d/modprobe 2>/dev/null || true
    echo "Added $TARGET_USER to wheel (sudo access)."
fi

echo "SUCCESS: User $TARGET_USER ensured (groups, shell, password)."
exit 0
