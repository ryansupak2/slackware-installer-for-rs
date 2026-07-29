#!/bin/sh
# acpi_handler.sh — handles ACPI events not caught by specific event files
# Logs to syslog AND to the project log directory.

LOG_DIR="/var/log"
[ -w "$LOG_DIR" ] || LOG_DIR="$HOME/logs"
LOG="$LOG_DIR/${USER:-root}-acpi-$(date +%Y%m%d-%H%M%S).log"

IFS=${IFS}/
set $@

case "$1" in
  button)
    case "$2" in
      power)
        MSG="$(date '+%Y-%m-%d %H:%M:%S.%3N') ACPI: power button pressed"
        echo "$MSG" | tee /dev/kmsg 2>/dev/null | logger -t "acpi-power"
        echo "$MSG" >> "$LOG"
        ;;
      lid)
        MSG="$(date '+%Y-%m-%d %H:%M:%S.%3N') ACPI: lid event ($3 $4)"
        echo "$MSG" | logger -t "acpi-lid"
        echo "$MSG" >> "$LOG"
        ;;
      *)
        MSG="ACPI action $2 is not defined"
        logger "$MSG"
        echo "$(date) $MSG" >> "$LOG"
        ;;
    esac
    ;;
  *)
    MSG="ACPI group $1 / action $2 is not defined"
    logger "$MSG"
    echo "$(date) $MSG" >> "$LOG"
    ;;
esac
