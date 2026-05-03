#!/bin/bash

rescan_loop() {
    while pgrep -x nmtui > /dev/null; do
        nmcli device wifi rescan
        sleep 10
    done
}

rescan_loop &

nmtui