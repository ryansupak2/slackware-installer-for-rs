#!/bin/bash

# Function to monitor D-Bus for initial scan completion
wait_for_scan() {
    echo "Starting WiFi scan..."
    if [ "$(id -u)" -eq 0 ]; then
        nmcli device wifi rescan
        sleep 5
        echo "WiFi scan completed"
    else
        python3 -c "
import pydbus
import time
import os
import gi.repository.GLib as GLib

try:
    bus = pydbus.SystemBus()
except GLib.GError as e:
    if 'LimitsExceeded' in str(e):
        print('DBus connection limit exceeded, restarting messagebus...')
        os.system('/etc/rc.d/rc.messagebus restart')
        time.sleep(2)
        bus = pydbus.SystemBus()
    else:
        raise
nm = bus.get('org.freedesktop.NetworkManager')
devices = nm.GetDevices()

# Find wireless device
wireless_path = None
for dev_path in devices:
    dev = bus.get('org.freedesktop.NetworkManager', dev_path)
    if dev.DeviceType == 2:  # WIFI
        wireless_path = dev_path
        break

if not wireless_path:
    print('No WiFi device found')
    exit(1)

wireless = bus.get('org.freedesktop.NetworkManager', wireless_path)
initial_scan = wireless.LastScan

# Trigger rescan
wireless.RequestScan({})

# Wait for LastScan update (poll every 0.5s, timeout 15s)
timeout = 15
elapsed = 0
while elapsed < timeout:
    time.sleep(0.5)
    if wireless.LastScan > initial_scan:
        break
    elapsed += 0.5

if elapsed >= timeout:
    print('Scan timeout')
else:
    print('WiFi scan completed successfully')
"
    fi
}

# Ongoing rescan loop (runs while nmtui is open)
rescan_loop() {
    while pgrep -x nmtui > /dev/null; do
        sudo nmcli device wifi rescan
        sleep 10
    done
}

# Main flow
pkill -f nmcli; pkill -f nmtui  # Clean up any hanging processes
wait_for_scan  # Wait for initial scan via D-Bus
echo "Launching nmtui..."
rescan_loop &  # Start background rescans
nmtui          # Launch nmtui synchronously
pkill -f nmcli; pkill -f nmtui  # Clean up after exit