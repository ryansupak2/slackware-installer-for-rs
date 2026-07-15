#!/bin/bash
# steps/console-font.sh - CONSOLE FONT

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "CONSOLE FONT"
echo "*****************************************************"
echo "Enabling console font and keyboard repeat via /etc/rc.d/rc.font..."

# Slackware's rc.M already calls /etc/rc.d/rc.font if it's executable.
# Write rc.font: set console font + keyboard repeat rate
cat > /etc/rc.d/rc.font << 'EOF'
#!/bin/bash
setfont ter-v32b
# Keyboard repeat: 250ms delay, 30 cps (prevents runaway repeats)
kbdrate -d 250 -r 30 -s 2>/dev/null || true
EOF
chmod +x /etc/rc.d/rc.font

# Apply font + keyboard rate immediately
setfont ter-v32b 2>/dev/null || true
kbdrate -d 250 -r 30 -s 2>/dev/null || true

echo "SUCCESS: Console font configured (ter-v32b, keyboard repeat 250ms/30cps, permanent via rc.font)."
exit 0
