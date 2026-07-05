#!/bin/bash

# bootstrap.sh - Early bootstrap for Slackware Linux + pi installer
# Run as root very early (e.g. from Slackware live environment or first boot after base install).
# Installs minimal prerequisites, sets console font, installs the pi agent,
# installs pi-hashline-edit, deploys pi config (settings/trust/auth) and
# the readonly-mode extension for root, using keys from setup.keys.root.
#
# This script follows the same banner style, dual logging to screen + ~/logs/bootstrap-YYYYMMDD-HHMMSS.log,
# and success/error counting + FINAL SUMMARY flow as post-install-global.sh.
#
# Prerequisites:
#   - Basic Slackware (slackpkg available)
#   - setup.keys.root populated with WIFI_SSID/WIFI_PASS + XAI_API_KEY
#
# After this, typically run post-install-global.sh (and then post-install-user.sh).

# Set up dual logging: everything from this point on goes to the screen
# AND is appended to ~/logs/bootstrap-<timestamp>.log so the user can review the full output later.
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "Bootstrap log started: $(date)"
echo "Log file: $LOG_FILE (also duplicated to screen)"
echo "=================================================="
# Global setup (always run)
echo "*****************************************************"
echo "BOOTSTRAP INITIALIZATION (Slackware Linux + pi)"
echo "*****************************************************"

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Reading Keys from setup.keys.root..."
KEY_FILE="$REPO_DIR/setup.keys.root"
if [ -f "$KEY_FILE" ]; then
    while IFS='=' read -r key value; do
      [[ -z "$key" || "$key" =~ ^# ]] && continue
      export "$key"="$value"
    done < "$KEY_FILE"
else
    echo "Warning: $KEY_FILE not found. No keys loaded for bootstrap."
fi

# ------------------------------------------------------------------
# Connect to WiFi if credentials are provided (needed for pi install)
# ------------------------------------------------------------------
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
    echo "*****************************************************"
    echo "CONNECTING TO WIFI: $WIFI_SSID"
    echo "*****************************************************"

    # Ensure NetworkManager is running
    chmod +x /etc/rc.d/rc.networkmanager 2>/dev/null || true
    /etc/rc.d/rc.networkmanager start 2>/dev/null || true
    sleep 2

    # Connect
    if command -v nmcli >/dev/null 2>&1; then
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" 2>/dev/null && {
            echo "Connected to $WIFI_SSID."
        } || {
            echo "WARNING: nmcli connection attempt returned non-zero."
            echo "  If you are already online via Ethernet, this is harmless."
        }
    else
        echo "WARNING: nmcli not found — cannot auto-connect WiFi."
        echo "  Use nmtui manually or connect via Ethernet."
    fi

    # Quick connectivity check
    if command -v curl >/dev/null 2>&1; then
        if curl -s --connect-timeout 5 https://github.com >/dev/null 2>&1; then
            echo "Internet reachable."
        else
            echo "WARNING: Internet not reachable. pi install may fail."
        fi
    fi
else
    echo "No WIFI_SSID / WIFI_PASS in setup.keys.root — skipping auto-connect."
    echo "If not already online, use nmtui or Ethernet before proceeding."
fi
echo ""
# Global counters for FINAL SUMMARY
success_count=0
error_count=0

# Source shared helpers for log_msg() etc.
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SBOPKG + BASE PACKAGES + CONSOLE FONT"
echo "*****************************************************"

# --- Install sbopkg (needed for nodejs22) ---
echo "Downloading and installing sbopkg..."
if ! command -v sbopkg >/dev/null 2>&1; then
    SBOPKG_URL="https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz"
    if wget -q "$SBOPKG_URL" -O /tmp/sbopkg.tgz; then
        installpkg /tmp/sbopkg.tgz && rm -f /tmp/sbopkg.tgz
        sbopkg -r  # sync SBo repository (~100MB, needs internet)
    else
        echo "ERROR: could not download sbopkg. nodejs22 install will fail."
    fi
else
    echo "sbopkg already installed."
fi

# --- Install base packages ---
echo "Installing base packages..."
install_pkg "curl sudo" || true
install_sbo "nodejs22" && {
    echo "SUCCESS: base packages and nodejs installed."
    success_count=$((success_count + 1))
} || {
    echo "ERROR: base package install failed."
    error_count=$((error_count + 1))
}

# Set readable console font
setfont ter-v32b 2>/dev/null || true

echo "*****************************************************"
echo "PI INSTALLER"
echo "*****************************************************"
echo "Running pi installer (curl -fsSL https://pi.dev/install.sh | sh)..."
if curl -fsSL https://pi.dev/install.sh | sh; then
    echo "SUCCESS: pi installed."
    success_count=$((success_count + 1))

    # Install the pi-hashline-edit extension right after pi is installed.
    echo "Installing pi-hashline-edit..."
    if pi install npm:pi-hashline-edit; then
        echo "SUCCESS: pi-hashline-edit installed."
        success_count=$((success_count + 1))
    else
        echo "Warning: pi install npm:pi-hashline-edit failed (non-fatal)."
    fi
else
    echo "ERROR: pi installation failed."
    error_count=$((error_count + 1))
fi

echo "*****************************************************"
echo "PI CONFIGURATION (root)"
echo "*****************************************************"

mkdir -p /root/.pi/agent /root/.pi/extensions

# settings.json
if cp "$REPO_DIR/dotfiles/pi/agent/settings.json" /root/.pi/agent/settings.json 2>/dev/null; then
    echo "SUCCESS: settings.json deployed."
    success_count=$((success_count + 1))
else
    echo "Warning: could not copy settings.json (non-fatal)."
fi

# trust.json
if cp "$REPO_DIR/dotfiles/pi/agent/trust.json" /root/.pi/agent/trust.json 2>/dev/null; then
    echo "SUCCESS: trust.json deployed."
    success_count=$((success_count + 1))
else
    echo "Warning: could not copy trust.json (non-fatal)."
fi

# auth.json (requires DEEPSEEK_API_KEY)
if [ -n "$DEEPSEEK_API_KEY" ]; then
    cat > /root/.pi/agent/auth.json << AUTHJSON
{
  "xai": {
    "type": "api_key",
    "key": ""
  },
  "deepseek": {
    "type": "api_key",
    "key": "$DEEPSEEK_API_KEY"
  }
}
AUTHJSON
    chmod 600 /root/.pi/agent/auth.json
    echo "SUCCESS: auth.json deployed (DEEPSEEK_API_KEY injected)."
    success_count=$((success_count + 1))
else
    echo "Warning: DEEPSEEK_API_KEY not set; auth.json not configured."
fi

# readonly-mode extension (copy + register with pi)
if cp "$REPO_DIR/dotfiles/pi/readonly-mode.ts" /root/.pi/extensions/readonly-mode.ts 2>/dev/null; then
    echo "SUCCESS: readonly-mode.ts copied."
    if pi install /root/.pi/extensions/readonly-mode.ts; then
        echo "SUCCESS: readonly-mode extension registered."
        success_count=$((success_count + 1))
    else
        echo "Warning: pi install readonly-mode.ts failed (non-fatal)."
    fi
else
    echo "Warning: could not copy readonly-mode.ts (non-fatal)."
fi

echo "*****************************************************"
echo "ROOT DOTFILES (bashrc, bash_profile)"
echo "*****************************************************"
if cp "$REPO_DIR/dotfiles/shell/bashrc" /root/.bashrc 2>/dev/null; then
    echo "SUCCESS: bashrc deployed."
    success_count=$((success_count + 1))
else
    echo "Warning: could not copy bashrc (non-fatal)."
fi
if cp "$REPO_DIR/dotfiles/shell/bash_profile" /root/.bash_profile 2>/dev/null; then
    echo "SUCCESS: bash_profile deployed."
    success_count=$((success_count + 1))
else
    echo "Warning: could not copy bash_profile (non-fatal)."
fi

echo ""
echo "*****************************************************"
echo "FINAL SUMMARY"
echo "*****************************************************"
echo ""
echo "SUCCESS: $success_count"
echo "ERROR:   $error_count"
echo ""
log_msg INFO "Bootstrap complete. Run post-install-global.sh for full global setup (and post-install-user.sh afterward)."
echo ""
if [ -f "$LOG_FILE" ]; then
    echo ""
    echo "Full bootstrap output has been captured to: $LOG_FILE"
    echo "(You can view it with: cat $LOG_FILE | less  or  tail -n 200 $LOG_FILE)"
fi
echo "Done."