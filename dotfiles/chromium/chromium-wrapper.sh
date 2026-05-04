#!/bin/bash

# Default zoom factor
zoom=1.33
nosandbox=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --zoom=*)
            zoom="${1#*=}"
            shift
            ;;
        --no-sandbox)
            nosandbox="--no-sandbox"
            shift
            ;;
        --help)
            echo "Usage: $0 [options] [chromium-options]"
            echo ""
            echo "Options:"
            echo "  --zoom=VALUE    Set zoom factor (default 1.33)"
            echo "  --no-sandbox    Run without sandbox"
            echo "  --help          Show this help"
            echo ""
            echo "All other arguments are passed to chromium."
            exit 0
            ;;
        *)
            # Collect remaining arguments for chromium
            break
            ;;
    esac
done

# Launch chromium with options
chromium --password-store=basic --force-device-scale-factor=$zoom $nosandbox "$@"