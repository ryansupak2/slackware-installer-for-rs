#!/bin/bash
# scripts/vnc.sh - VNC SCREEN SHARING MANAGER (x11vnc)
#
# Starts x11vnc to share your actual X11/dwm screen with remote viewers.
# Password-protected; uses password file at /usr/local/etc/x11vnc/passwd.
#
# Usage:
#   vnc start          Start screen sharing
#   vnc stop           Stop screen sharing
#   vnc status         Show status + active connections
#   vnc                Interactive menu (no args)
#
# Installed as /usr/local/bin/vnc

# ── Configuration ──────────────────────────────────────────────────────
LOG_DIR="/var/log/sessions"
LOG_FILE="$LOG_DIR/${USER:-root}-vnc-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$LOG_DIR" 2>/dev/null || true

exec > >(tee -a "$LOG_FILE") 2>&1

# Terminal formatting (matching wifi-manager)
BOLD='\033[1m'
GREEN='\033[32m'
RED='\033[31m'
NC='\033[0m'

echo "=================================================="
echo "VNC Screen Sharing started: $(date)"
echo "Log: $LOG_FILE"
echo "=================================================="
echo ""

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] [$level] $msg"
}

# ── State checks ───────────────────────────────────────────────────────
is_running() {
    pgrep x11vnc >/dev/null 2>&1
}

is_client_connected() {
    ss -tn state established sport = :5900 2>/dev/null | tail -n +2 | grep -q .
}

# ── Start ──────────────────────────────────────────────────────────────
start_server() {
    echo "*****************************************************"
    echo "STARTING SCREEN SHARING"
    echo "*****************************************************"

    if is_running; then
        echo "Screen sharing is already running."
        log_msg INFO "x11vnc already running"
        echo "Use 'vnc stop' to stop it first, or 'vnc status' for details."
        echo "*****************************************************"
        return 0
    fi

    if ! command -v x11vnc >/dev/null 2>&1; then
        echo "ERROR: x11vnc not found. Install it first:"
        echo "  (run the vnc installer step)"
        log_msg ERROR "x11vnc binary not found"
        echo "*****************************************************"
        return 1
    fi

    if [ -z "$DISPLAY" ]; then
        echo "ERROR: DISPLAY not set."
        echo "  x11vnc must be started from within your X11/dwm session."
        echo "  Run 'vnc start' from a terminal inside dwm."
        log_msg ERROR "DISPLAY not set — not in an X11 session"
        echo "*****************************************************"
        return 1
    fi

    PASSWD_FILE="/usr/local/etc/x11vnc/passwd"
    if [ ! -f "$PASSWD_FILE" ]; then
        echo "ERROR: x11vnc password file not found at $PASSWD_FILE"
        echo "  Run the vnc installer step to create one."
        log_msg ERROR "password file missing: $PASSWD_FILE"
        echo "*****************************************************"
        return 1
    fi

    echo "Starting x11vnc (screen capture) on port 5900..."
    log_msg INFO "Starting x11vnc -forever -shared -rfbauth $PASSWD_FILE"
    x11vnc -forever -shared -rfbauth "$PASSWD_FILE" -quiet -bg 2>/dev/null
    sleep 1
    if is_running; then
        echo ""
        echo "SUCCESS: Screen sharing started."
        log_msg OK "x11vnc started successfully"
        echo "  Connect with any VNC client:  $(hostname -i 2>/dev/null || ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"
        echo "  Mac Screen Sharing: vnc://$(hostname -i 2>/dev/null || ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"
    else
        echo "ERROR: x11vnc failed to start."
        log_msg ERROR "x11vnc failed to start"
        echo "  Make sure you are running this inside an X11/dwm session."
        echo "*****************************************************"
        return 1
    fi
    echo "*****************************************************"
}

# ── Stop ───────────────────────────────────────────────────────────────
stop_server() {
    echo "*****************************************************"
    echo "STOPPING SCREEN SHARING"
    echo "*****************************************************"

    if ! is_running; then
        echo "Screen sharing is not currently running."
        log_msg INFO "No x11vnc running — nothing to stop"
        echo "*****************************************************"
        return 0
    fi

    echo "Stopping x11vnc..."
    log_msg INFO "Stopping x11vnc"
    pkill x11vnc 2>/dev/null || true
    sleep 0.5

    if is_running; then
        pkill -9 x11vnc 2>/dev/null || true
        sleep 0.5
    fi

    if ! is_running; then
        echo "SUCCESS: Screen sharing stopped."
        log_msg OK "Screen sharing stopped"
    else
        echo "ERROR: Failed to stop x11vnc."
        log_msg ERROR "Failed to stop x11vnc"
        echo "*****************************************************"
        return 1
    fi
    echo "*****************************************************"
}

# ── Status ─────────────────────────────────────────────────────────────
show_status() {
    echo "*****************************************************"
    echo "SCREEN SHARING STATUS"
    echo "*****************************************************"

    if is_running; then
        if is_client_connected; then
            echo -e "Screen Sharing: ${GREEN}RUNNING${NC} (viewer ${GREEN}connected${NC}!)"
        else
            echo -e "Screen Sharing: ${GREEN}RUNNING${NC} (no viewers)"
        fi
        echo ""
        echo "  Process:"
        pgrep -a x11vnc 2>/dev/null | while read -r line; do
            echo "    $line"
        done
        echo ""
        echo "  Active viewers:"
        if is_client_connected; then
            ss -tn state established sport = :5900 2>/dev/null | grep -v '^State' || true
        else
            echo "    (none)"
        fi
        echo ""
        echo "  Port 5900: $(ss -tln sport = :5900 2>/dev/null | tail -n +2 | head -1 || echo 'not listening')"
        echo ""
        echo "  Connect:  vnc://$(hostname -i 2>/dev/null || ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)"
    else
        echo -e "Screen Sharing: ${RED}NOT RUNNING${NC}"
        echo ""
        echo "  Start it with: vnc start"
    fi
    echo "*****************************************************"
}

# ── Interactive menu ───────────────────────────────────────────────────
interactive_menu() {
    while true; do
        echo ""
        echo "Screen Sharing Manager"
        echo "======================"
        echo ""
        if is_running; then
            echo -e "Status: ${GREEN}RUNNING${NC}"
            echo ""
            echo "1. Stop screen sharing"
            echo "2. Show status"
            echo "3. Exit"
            echo ""
            read -p "Choice [1-3]: " choice
            case $choice in
                1) echo ""; stop_server ;;
                2) echo ""; show_status ;;
                3) echo ""; echo "Manager exiting (sharing stays active). Log: $LOG_FILE"; return 0 ;;
                *) echo "Invalid choice" ;;
            esac
        else
            echo -e "Status: ${RED}STOPPED${NC}"
            echo ""
            echo "1. Start screen sharing"
            echo "2. Show status"
            echo "3. Exit"
            echo ""
            read -p "Choice [1-3]: " choice
            case $choice in
                1) echo ""; start_server ;;
                2) echo ""; show_status ;;
                3) echo ""; echo "Manager exiting. Log: $LOG_FILE"; return 0 ;;
                *) echo "Invalid choice" ;;
            esac
        fi
    done
}

# ── CLI mode ───────────────────────────────────────────────────────────
run_cli() {
    case "$1" in
        start|up|on)    start_server ;;
        stop|down|off|kill) stop_server ;;
        status|st|s)    show_status ;;
        *)
            echo "Usage: vnc [start|stop|status]"
            echo "       vnc start        Start screen sharing"
            echo "       vnc stop         Stop screen sharing"
            echo "       vnc status       Show status + active viewers"
            echo "       vnc              Interactive menu"
            exit 1
            ;;
    esac
}

# ── Entry point ────────────────────────────────────────────────────────
if [ $# -eq 0 ]; then
    interactive_menu
else
    run_cli "$1"
fi
