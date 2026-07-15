#!/bin/bash
# steps/input-hardware.sh - INPUT HARDWARE

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "INPUT HARDWARE                                       "
echo "*****************************************************"

ok=true
echo "Disabling Touchscreen..."
if ! mkdir -p /etc/X11/xorg.conf.d; then ok=false; fi
if $ok; then
    if ! cp "$REPO_DIR/dotfiles/configs/99-disable-touchscreen.conf" /etc/X11/xorg.conf.d/99-disable-touchscreen.conf; then ok=false; fi
fi
# Also disable touchscreen for Wayland/wlroots via udev (Xorg config doesn't apply)
echo "Deploying udev rule to disable ELAN Touchscreen for Wayland..."
if ! cp "$REPO_DIR/dotfiles/configs/99-disable-touchscreen.rules" /etc/udev/rules.d/99-disable-touchscreen.rules; then ok=false; fi
udevadm control --reload-rules 2>/dev/null || true
udevadm trigger --subsystem-match=hid,input --action=change 2>/dev/null || true
# Also unbind immediately from hid-multitouch in case seatd/dwl already grabbed it
for hiddev in /sys/bus/hid/devices/*; do
    if grep -q 'ELAN Touchscreen' "$hiddev/uevent" 2>/dev/null; then
        echo -n "$(basename "$hiddev")" > /sys/bus/hid/drivers/hid-multitouch/unbind 2>/dev/null && \
            echo "  Unbound $(basename "$hiddev") from hid-multitouch" || true
        break
    fi
done
echo "Configuring Touchpad (disable tap-to-click and right-click areas)..."
if $ok; then
    if ! cp "$REPO_DIR/dotfiles/configs/70-synaptics.conf" /etc/X11/xorg.conf.d/70-synaptics.conf; then ok=false; fi
fi

# Also ensure the modern libinput-based versions from setup_x11_base are present (in case this step is run standalone).
# These override with libinput driver (safer than legacy synaptics module on Slackware).
cp "$REPO_DIR/dotfiles/configs/30-libinput.conf" /etc/X11/xorg.conf.d/30-libinput.conf

if $ok; then
    echo "SUCCESS: Input hardware (touchscreen/touchpad) configured."
    exit 0
else
    echo "ERROR: could not configure input hardware."
    exit 1
fi
