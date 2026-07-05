#!/bin/bash
# slsk - Soulseek daemon (slskd) control
# Usage: slsk start | stop | restart | status
# Sudo-aware: uses sudo/doas if not root.

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas "$@"
    else
        echo "slsk: need root or sudo/doas to control the slskd service."
        return 1
    fi
}

cmd="${1:-}"

case "$cmd" in
    start)
        echo -n "Starting slskd... "
        if as_root /etc/rc.d/rc.slskd start >/dev/null 2>&1; then
            echo "OK."
        else
            echo "FAILED."
            echo "  Check: /etc/rc.d/rc.slskd status"
            echo "  Check: tail /var/log/slskd.log"
            exit 1
        fi
        ;;
    stop)
        echo -n "Stopping slskd... "
        if as_root /etc/rc.d/rc.slskd stop >/dev/null 2>&1; then
            echo "OK."
        else
            echo "FAILED."
            exit 1
        fi
        ;;
    restart)
        echo -n "Restarting slskd... "
        if as_root /etc/rc.d/rc.slskd restart >/dev/null 2>&1; then
            echo "OK."
        else
            echo "FAILED."
            exit 1
        fi
        ;;
    status)
        as_root /etc/rc.d/rc.slskd status 2>&1
        ;;
    *)
        echo "slsk — Soulseek daemon (slskd) control"
        echo ""
        echo "Usage: slsk start | stop | restart | status"
        echo ""
        if as_root /etc/rc.d/rc.slskd status >/dev/null 2>&1; then
            echo "Current status: running  (web UI: http://localhost:5030)"
        else
            echo "Current status: stopped"
        fi
        ;;
esac
