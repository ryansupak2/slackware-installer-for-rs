#!/bin/bash
# steps/remote-desktop.sh - RDP REMOTE DESKTOP SERVER (xrdp -> wayvnc bridge)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "RDP REMOTE DESKTOP (xrdp + wayvnc bridge)"
echo "*****************************************************"

SRC_DIR=/usr/local/src/remote-desktop
BUILD_LOG="$SRC_DIR/build.log"
mkdir -p "$SRC_DIR"

ok=true

echo ""
echo "--- Phase 1: wayvnc (Wayland VNC server) ---"

if command -v wayvnc >/dev/null 2>&1; then
    echo "  wayvnc already installed: $(which wayvnc)"
else
    echo "  Installing build dependencies for wayvnc chain..."
    install_pkg "gnutls libjpeg-turbo pam jansson"

    # meson (needed for wayvnc chain — not in SBo, use pip)
    echo "  Ensuring meson is available..."
    if ! command -v meson >/dev/null 2>&1; then
        pip3 install meson 2>&1 | tee -a "$BUILD_LOG" || { echo "ERROR: pip3 install meson failed"; ok=false; }
    fi

    _run_step() {
        local label="$1"; shift
        echo "  Running: $label..."
        "$@" 2>&1 | tee -a "$BUILD_LOG"
        local rc="${PIPESTATUS[0]}"
        if [ "$rc" -ne 0 ]; then
            echo "ERROR: $label failed (exit $rc)"
            return 1
        fi
        return 0
    }

    _build_meson() {
        local name="$1" src="$2"
        cd "$src"
        rm -rf build
        _run_step "$name meson setup" meson setup build || return 1
        _run_step "$name ninja build"  ninja -C build || return 1
        _run_step "$name ninja install" ninja -C build install || return 1
        echo "  $name: OK"
    }

    cd "$SRC_DIR"
    rm -rf aml
    if git clone --depth 1 https://github.com/any1/aml 2>&1 | tee -a "$BUILD_LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
        _build_meson "aml" "$SRC_DIR/aml" || ok=false
    else
        echo "ERROR: aml clone failed"; ok=false
    fi

    if $ok; then
        cd "$SRC_DIR"
        rm -rf neatvnc
        if git clone --depth 1 https://github.com/any1/neatvnc 2>&1 | tee -a "$BUILD_LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
            cd "$SRC_DIR/neatvnc"
            rm -rf build
            _run_step "neatvnc meson setup" meson setup build -Dexamples=false || ok=false
            if $ok; then _run_step "neatvnc ninja build" ninja -C build || ok=false; fi
            if $ok; then _run_step "neatvnc ninja install" ninja -C build install || ok=false; fi
            $ok && echo "  neatvnc: OK"
        else
            echo "ERROR: neatvnc clone failed"; ok=false
        fi
    fi

    if $ok; then
        cd "$SRC_DIR"
        rm -rf wayvnc
        if git clone --depth 1 https://github.com/any1/wayvnc 2>&1 | tee -a "$BUILD_LOG"; [ "${PIPESTATUS[0]}" -eq 0 ]; then
            cd "$SRC_DIR/wayvnc"
            rm -rf build
            _run_step "wayvnc meson setup" meson setup build || ok=false
            if $ok; then _run_step "wayvnc ninja build" ninja -C build || ok=false; fi
            if $ok; then _run_step "wayvnc ninja install" ninja -C build install || ok=false; fi
            $ok && { ldconfig 2>/dev/null || true; echo "  wayvnc: OK"; }
        else
            echo "ERROR: wayvnc clone failed"; ok=false
        fi
    fi
fi

echo ""
echo "--- Phase 2: xrdp (RDP server) ---"

if command -v xrdp >/dev/null 2>&1; then
    echo "  xrdp already installed: $(which xrdp)"
else
    echo "  Installing xrdp via sbopkg..."
    if ! install_sbo "xrdp"; then
        echo "ERROR: xrdp not available via sbopkg."
        ok=false
    else
        echo "  xrdp: OK (from sbopkg)"
    fi
fi

echo ""
echo "--- Phase 3: Configuration ---"

if $ok; then
    echo "  Deploying xrdp.ini..."
    mkdir -p /etc/xrdp
    cp "$REPO_DIR/dotfiles/configs/xrdp.ini" /etc/xrdp/xrdp.ini
    echo "    /etc/xrdp/xrdp.ini deployed"

    # Create BSD-style init script for xrdp
    if [ ! -f /etc/rc.d/rc.xrdp ]; then
        echo "  Creating /etc/rc.d/rc.xrdp init script..."
        cat > /etc/rc.d/rc.xrdp << 'INITSCRIPT'
#!/bin/bash
# /etc/rc.d/rc.xrdp - start/stop xrdp RDP server
case "$1" in
    start)
        echo "Starting xrdp..."
        /usr/sbin/xrdp
        ;;
    stop)
        echo "Stopping xrdp..."
        killall xrdp 2>/dev/null || true
        ;;
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        ;;
esac
INITSCRIPT
        chmod +x /etc/rc.d/rc.xrdp
        echo "    /etc/rc.d/rc.xrdp created"
    fi

    # Start xrdp
    /etc/rc.d/rc.xrdp start 2>/dev/null || true
    echo "  xrdp started"

    # Firewall: open port 3389/tcp
    if command -v iptables >/dev/null 2>&1; then
        if iptables -L INPUT -n 2>/dev/null | grep -q '3389'; then
            echo "  Port 3389 already open in iptables"
        else
            iptables -I INPUT -p tcp --dport 3389 -j ACCEPT 2>/dev/null || true
            echo "  Opened port 3389/tcp in iptables"
        fi
    fi

    echo ""
    echo "SUCCESS: Remote Desktop (RDP) server installed and configured."
    echo ""
    echo "  Architecture:  mstsc.exe -> xrdp:3389 -> wayvnc:5900 -> dwl"
    echo "  Windows users:  Open Remote Desktop Connection, enter this machine's IP"
    echo "  xrdp: /etc/rc.d/rc.xrdp {start|stop|restart}"
    exit 0
else
    echo "ERROR: Remote Desktop setup encountered errors."
    exit 1
fi
