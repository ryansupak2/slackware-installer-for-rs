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

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
export REPO_DIR

# Source shared helpers early — we need init_installer_log, read_setup_keys, etc.
if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

# Set up dual logging: tee to screen + /var/log
init_installer_log "bootstrap"

echo "=================================================="
echo "Bootstrap log started: $(date)"
echo "Log file: $LOG_FILE (also duplicated to screen)"
echo "=================================================="

echo "*****************************************************"
echo "BOOTSTRAP INITIALIZATION (Slackware Linux + pi)"
echo "*****************************************************"

# Load keys from setup.keys.root
read_setup_keys

# ------------------------------------------------------------------
# Ensure internet connectivity (only touch WiFi if not already online)
# ------------------------------------------------------------------
ONLINE=false
if command -v curl >/dev/null 2>&1; then
    if curl --connect-timeout 5 -s https://github.com >/dev/null 2>&1; then
        ONLINE=true
        echo "Internet already reachable — skipping WiFi setup."
    fi
fi

if [ "$ONLINE" = false ] && [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PASS" ]; then
    echo "*****************************************************"
    echo "CONNECTING TO WIFI: $WIFI_SSID"
    echo "*****************************************************"

    chmod +x /etc/rc.d/rc.networkmanager 2>/dev/null || true
    /etc/rc.d/rc.networkmanager start 2>/dev/null || true
    sleep 2

    if command -v nmcli >/dev/null 2>&1; then
        echo "Running: nmcli device wifi connect \"$WIFI_SSID\" ..."
        if nmcli device wifi connect "$WIFI_SSID" password "$WIFI_PASS"; then
            echo "Connected to $WIFI_SSID."
        else
            echo "WARNING: nmcli connection attempt returned non-zero."
            echo "  If you are already online via Ethernet, this is harmless."
        fi
    else
        echo "ERROR: nmcli not found — cannot auto-connect WiFi."
        echo "  Use nmtui manually or connect via Ethernet."
    fi

    # Re-test after WiFi attempt
    if command -v curl >/dev/null 2>&1 && curl --connect-timeout 5 -s https://github.com >/dev/null 2>&1; then
        echo "Internet reachable."
    else
        echo "WARNING: Internet not reachable. pi install may fail."
    fi
elif [ "$ONLINE" = false ]; then
    echo "No internet and no WIFI_SSID / WIFI_PASS in setup.keys.root — cannot auto-connect."
    echo "Use nmtui or Ethernet before proceeding."
fi
echo ""

success_count=0
error_count=0

# Set timezone to Chicago early (before any timestamped operations)
set_timezone_chicago

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
    # Fix: prebuilt Node tarball has lib/ but npm internally references lib64/
    [ -L "$NODE_DIR/lib64" ] || ln -sf lib "$NODE_DIR/lib64"
    ln -sf "$NODE_DIR/bin/npx"  /usr/local/bin/npx
    echo "Node.js $(/usr/local/bin/node --version) installed."
    success_count=$((success_count + 1))
else
    echo "ERROR: Node.js not found after install."
    error_count=$((error_count + 1))
fi
# Make Node.js (and pi once installed) available in current shell
export PATH="$NODE_DIR/bin:$PATH"

# --- Console font (delegated to step script) ---
"$REPO_DIR/steps/console-font.sh" && success_count=$((success_count + 1)) || error_count=$((error_count + 1))

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
        ln -sf "$NODE_DIR/bin/pi" /usr/local/bin/pi
        hash -r  # clear bash command cache so pi is found immediately
        if ! command -v pi >/dev/null 2>&1; then
            echo "WARNING: pi installed but not found in PATH — extension installs may fail."
        fi
    else
        echo "ERROR: pi installation failed."
        error_count=$((error_count + 1))
    fi
fi

echo "Installing pi-hashline-edit..."
if pi list 2>/dev/null | grep -qF "pi-hashline-edit"; then
    echo "SUCCESS: pi-hashline-edit already installed — skipping."
    success_count=$((success_count + 1))
else
    echo "(This may take a few minutes — downloading npm package...)"
    if pi install npm:pi-hashline-edit 2>&1; then
        echo "SUCCESS: pi-hashline-edit installed."
        success_count=$((success_count + 1))
    else
        echo "ERROR: pi install npm:pi-hashline-edit failed."
        error_count=$((error_count + 1))
    fi
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
    if pi list 2>/dev/null | grep -qF "readonly-mode"; then
        echo "SUCCESS: readonly-mode extension already registered — skipping."
        success_count=$((success_count + 1))
    else
        if pi install /root/.pi/extensions/readonly-mode.ts 2>&1; then
            echo "SUCCESS: readonly-mode extension registered."
            success_count=$((success_count + 1))
        else
            echo "ERROR: pi install readonly-mode.ts failed."
            error_count=$((error_count + 1))
        fi
    fi
else
    echo "ERROR: could not copy readonly-mode.ts."
    error_count=$((error_count + 1))
fi

# --- Root dotfiles (delegated to step script) ---
"$REPO_DIR/steps/root-dotfiles.sh" && success_count=$((success_count + 1)) || error_count=$((error_count + 1))

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
