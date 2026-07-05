#!/bin/bash
for i in {1..10}; do
  lid_closed=$(loginctl show-seat seat0 | grep -o 'LidClosed=yes' || echo "no")
  if [ "$lid_closed" != "LidClosed=yes" ]; then
    exit 0
  fi
  sleep 1
done
systemctl suspend