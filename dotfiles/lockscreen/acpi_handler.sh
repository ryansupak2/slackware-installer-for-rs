#!/bin/sh
# acpi_handler.sh — handles ACPI events not caught by specific event files
# Power button: logged with timestamp for debugging wake responsiveness

IFS=${IFS}/
set $@

case "$1" in
  button)
    case "$2" in
      power)
        echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') ACPI: power button pressed" | tee /dev/kmsg 2>/dev/null | logger -t "acpi-power"
        ;;
      lid)
        echo "$(date '+%Y-%m-%d %H:%M:%S.%3N') ACPI: lid event ($3 $4)" | logger -t "acpi-lid"
        ;;
      *)
        logger "ACPI action $2 is not defined"
        ;;
    esac
    ;;
  *)
    logger "ACPI group $1 / action $2 is not defined"
    ;;
esac
