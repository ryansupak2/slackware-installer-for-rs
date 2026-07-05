#!/bin/bash

# bootstrap.sh - Early bootstrap for Slackware Linux + pi installer
# Run as root very early (e.g. from Slackware live environment or first boot after base install).
# Installs minimal prerequisites, sets console font, installs the pi agent,
# installs pi-hashline-edit, deploys pi config (settings/trust/auth) and
# the readonly-mode extension for root, using keys from setup.keys.root.
#
# All output is verbose — every step shows its progress.
#
# Prerequisites:
#   - Basic Slackware (slackpkg available)
#   - setup.keys.root populated with WIFI_SSID/WIFI_PASS + DEEPSEEK_API_KEY
#
# After this, typically run post-install-global.sh (and then post-install-user.sh).

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "Bootstrap log started: $(date)"
echo "Log file: $LOG_FILE (also duplicated to screen)"
echo "=================================================="

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
    echo "  Keys loaded."
else
    echo "ERROR: $KEY_FILE not found. No keys loaded for bootstrap."
fi

# ------------------------------------------------------------------
# Connect to WiFi if credentials are provided
# ------------------------------------------------------------------
if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
    echo "*****************************************************"
    echo "CONNECTING TO WIFI: $WIFI_SSID"
    echo "*****************************************************"

    chmod +x /etc/rc.d/rc.networkmanager 2>/dev/null || true
    /etc/rc.d/rc.networkmanager start 2>/dev/null || true
    sleep 2

    if command -v nmcli >/dev/null 2>&1; then
        echo "Running: nmcli device wifi connect \"$WIFI_SSID\" ..."
        nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS" && {
            echo "Connected to $WIFI_SSID."
        } || {
            echo "WARNING: nmcli connection attempt returned non-zero."
            echo "  If you are already online via Ethernet, this is harmless."
        }
    else
        echo "ERROR: nmcli not found — cannot auto-connect WiFi."
        echo "  Use nmtui manually or connect via Ethernet."
    fi

    if command -v curl >/dev/null 2>&1; then
        echo "Testing internet connectivity (curl https://github.com)..."
        if curl --connect-timeout 5 https://github.com >/dev/null 2>&1; then
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

success_count=0
error_count=0


# Set timezone to Chicago early (before any timestamped operations)
if [ -f /usr/share/zoneinfo/America/Chicago ]; then
    ln -sf /usr/share/zoneinfo/America/Chicago /etc/localtime
    hwclock --hctosys 2>/dev/null || true
    echo "Timezone set to America/Chicago"
fi
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SBOPKG + BASE PACKAGES + NODE.JS"
echo "*****************************************************"

# --- Install sbopkg ---
echo "Downloading and installing sbopkg..."
if ! command -v sbopkg >/dev/null 2>&1; then
    SBOPKG_URL="https://github.com/sbopkg/sbopkg/releases/download/0.38.3/sbopkg-0.38.3-noarch-1_wsr.tgz"
    if wget --show-progress "$SBOPKG_URL" -O /tmp/sbopkg.tgz; then
        installpkg /tmp/sbopkg.tgz && rm -f /tmp/sbopkg.tgz
        echo "Syncing SBo repository..."
        sbopkg -r
    else
        echo "ERROR: could not download sbopkg."
    fi
else
    echo "sbopkg already installed."
fi

# --- Install base packages ---
echo "Installing base packages (curl, sudo)..."
install_pkg "curl sudo"

# --- Install Node.js 22 LTS (latest pre-built binary) ---
echo "Installing Node.js 22 LTS..."
NODE_VERSION="22.19.0"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz"
NODE_DIR="/usr/local/node-v${NODE_VERSION}-linux-x64"

if [ -x "$NODE_DIR/bin/node" ]; then
    echo "Node.js ${NODE_VERSION} already installed at $NODE_DIR"
else
    # Clean up any older node installs
    rm -rf /usr/local/node-v*-linux-x64 /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx 2>/dev/null
    if wget --show-progress "$NODE_URL" -O /tmp/node.tar.xz; then
        echo "Extracting Node.js ${NODE_VERSION}..."
        tar xf /tmp/node.tar.xz -C /usr/local && rm -f /tmp/node.tar.xz
    else
        echo "ERROR: Node.js download failed."
        error_count=$((error_count + 1))
    fi
fi

if [ -x "$NODE_DIR/bin/node" ]; then
    ln -sf "$NODE_DIR/bin/node" /usr/local/bin/node
    ln -sf "$NODE_DIR/bin/npm"  /usr/local/bin/npm
    ln -sf "$NODE_DIR/bin/npx"  /usr/local/bin/npx
    echo "Node.js $(/usr/local/bin/node --version) installed."
    success_count=$((success_count + 1))
else
    echo "ERROR: Node.js not found after install."
    error_count=$((error_count + 1))
fi

# Set readable console font
setfont ter-v32b 2>/dev/null || true

echo "*****************************************************"
echo "PI INSTALLER"
echo "*****************************************************"
# Wipe stale pi artifacts before fresh install
rm -rf /root/.local/share/pi-node /usr/lib64/node_modules/@earendil-works 2>/dev/null
if command -v pi >/dev/null 2>&1; then
    echo "pi already installed: $(pi --version 2>/dev/null || echo ok)"
    echo "SUCCESS: pi installed."
    success_count=$((success_count + 1))
else
    echo "Downloading and running pi installer..."
    if curl -fsSL https://pi.dev/install.sh | sh; then
        echo "SUCCESS: pi installed."
        success_count=$((success_count + 1))
    else
        echo "ERROR: pi installation failed."
        error_count=$((error_count + 1))
    fi
fi

# Apply Kitty protocol flag fix (7 → 5, prevents keyup double-fire)
echo "Applying pi Kitty protocol fix..."
if [ -x "$REPO_DIR/lib/patch-pi-kitty-flags.sh" ]; then
    "$REPO_DIR/lib/patch-pi-kitty-flags.sh" && echo "SUCCESS: Kitty flags patched." || echo "WARNING: Kitty flags patch issues."
fi

echo "Installing pi-hashline-edit..."
if pi install npm:pi-hashline-edit; then
        echo "SUCCESS: pi-hashline-edit installed."
        success_count=$((success_count + 1))
    else
        echo "ERROR: pi install npm:pi-hashline-edit failed."
        error_count=$((error_count + 1))
    fi
echo "*****************************************************"
echo "PI CONFIGURATION (root)"
echo "*****************************************************"

mkdir -p /root/.pi/agent /root/.pi/extensions

# settings.json
echo "Deploying settings.json..."
if cp "$REPO_DIR/dotfiles/pi/agent/settings.json" /root/.pi/agent/settings.json 2>/dev/null; then
    echo "SUCCESS: settings.json deployed."
    success_count=$((success_count + 1))
else
    echo "ERROR: could not copy settings.json."
    error_count=$((error_count + 1))
fi

# trust.json
echo "Deploying trust.json..."
if cp "$REPO_DIR/dotfiles/pi/agent/trust.json" /root/.pi/agent/trust.json 2>/dev/null; then
    echo "SUCCESS: trust.json deployed."
    success_count=$((success_count + 1))
else
    echo "ERROR: could not copy trust.json."
    error_count=$((error_count + 1))
fi

# auth.json (requires DEEPSEEK_API_KEY)
echo "Deploying auth.json..."
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
    echo "ERROR: DEEPSEEK_API_KEY not set; auth.json not configured."
    error_count=$((error_count + 1))
fi

# readonly-mode extension
echo "Deploying readonly-mode extension..."
if cp "$REPO_DIR/dotfiles/pi/readonly-mode.ts" /root/.pi/extensions/readonly-mode.ts 2>/dev/null; then
    echo "  readonly-mode.ts copied."
    if pi install /root/.pi/extensions/readonly-mode.ts; then
        echo "SUCCESS: readonly-mode extension registered."
        success_count=$((success_count + 1))
    else
        echo "ERROR: pi install readonly-mode.ts failed."
        error_count=$((error_count + 1))
    fi
else
    echo "ERROR: could not copy readonly-mode.ts."
    error_count=$((error_count + 1))
fi

echo "*****************************************************"
echo "ROOT DOTFILES (bashrc, bash_profile)"
echo "*****************************************************"
if cp "$REPO_DIR/dotfiles/shell/bashrc" /root/.bashrc 2>/dev/null; then
    echo "SUCCESS: bashrc deployed."
    success_count=$((success_count + 1))
else
    echo "ERROR: could not copy bashrc."
    error_count=$((error_count + 1))
fi
if cp "$REPO_DIR/dotfiles/shell/bash_profile" /root/.bash_profile 2>/dev/null; then
    echo "SUCCESS: bash_profile deployed."
    success_count=$((success_count + 1))
else
    echo "ERROR: could not copy bash_profile."
    error_count=$((error_count + 1))
fi

# Log file location (before final summary)
echo ""
if [ -f "$LOG_FILE" ]; then
    echo "Full bootstrap output has been captured to: $LOG_FILE"
    echo "(View with: less $LOG_FILE  or  tail -n 200 $LOG_FILE)"
fi

# FINAL SUMMARY — must be the very last thing printed
echo ""
echo "*****************************************************"
echo "FINAL SUMMARY"
echo "*****************************************************"
echo ""
echo "SUCCESS: $success_count"
echo "ERROR:   $error_count"
