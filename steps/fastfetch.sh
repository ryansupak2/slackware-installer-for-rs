#!/bin/bash
# steps/fastfetch.sh - FASTFETCH (Slackware)
REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"
if [ -f "$REPO_DIR/lib/common.sh" ]; then . "$REPO_DIR/lib/common.sh"; fi
echo "*****************************************************"
echo "FASTFETCH"
echo "*****************************************************"
ok=true

echo "Installing fastfetch (prebuilt Linux binary)..."
if command -v fastfetch >/dev/null 2>&1; then
    echo "  fastfetch already installed."
elif curl -fsSL https://github.com/fastfetch-cli/fastfetch/releases/latest/download/fastfetch-linux-amd64.tar.gz -o /tmp/fastfetch.tgz 2>/dev/null; then
    rm -rf /tmp/fastfetch-x && mkdir -p /tmp/fastfetch-x
    tar -xzf /tmp/fastfetch.tgz -C /tmp/fastfetch-x 2>/dev/null
    bin="$(find /tmp/fastfetch-x -type f -name fastfetch | head -1)"
    if [ -n "$bin" ]; then
        install -m 0755 "$bin" /usr/local/bin/fastfetch
        flash="$(find /tmp/fastfetch-x -type f -name flashfetch | head -1)"
        [ -n "$flash" ] && install -m 0755 "$flash" /usr/local/bin/flashfetch
        echo "  fastfetch installed."
    else
        echo "ERROR: fastfetch binary not found in tarball."
        ok=false
    fi
    rm -rf /tmp/fastfetch-x /tmp/fastfetch.tgz
else
    echo "ERROR: failed to download fastfetch."
    ok=false
fi

# Deploy config + ASCII logo to a home dir. Idempotent.
deploy_fastfetch() {
    local home="$1"
    local dir="$home/.config/fastfetch"
    local cfg="$dir/config.jsonc"
    local art="$dir/bobdobbs.txt"

    mkdir -p "$dir" 2>/dev/null || { echo "ERROR: could not create $dir."; return 1; }

    if cmp -s "$REPO_DIR/dotfiles/fastfetch/config.jsonc" "$cfg" 2>/dev/null && \
       cmp -s "$REPO_DIR/dotfiles/fastfetch/bobdobbs.txt" "$art" 2>/dev/null; then
        echo "  fastfetch config already current: $dir"
        return 0
    fi

    cp "$REPO_DIR/dotfiles/fastfetch/config.jsonc" "$cfg" 2>/dev/null || return 1
    cp "$REPO_DIR/dotfiles/fastfetch/bobdobbs.txt" "$art" 2>/dev/null || return 1
    echo "  fastfetch config deployed: $dir"
    return 0
}

if $ok; then
    deploy_fastfetch "/root"     || ok=false
    deploy_fastfetch "/etc/skel" || ok=false
fi

# Clean up legacy neofetch artifacts (migrated to fastfetch)
if [ -e /usr/local/bin/neofetch ] || [ -e /usr/bin/neofetch ] || \
   [ -d /root/.config/neofetch ] || [ -d /etc/skel/.config/neofetch ]; then
    echo "Removing legacy neofetch install..."
    rm -f /usr/local/bin/neofetch /usr/bin/neofetch 2>/dev/null || true
    rm -rf /root/.config/neofetch /etc/skel/.config/neofetch 2>/dev/null || true
fi

if $ok; then echo "SUCCESS: Fastfetch installed."; exit 0; else echo "ERROR: Fastfetch setup encountered errors."; exit 1; fi
