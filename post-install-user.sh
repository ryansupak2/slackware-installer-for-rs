#!/bin/bash

# post-install-user.sh - Per-user setup for Slackware Linux installer
# Run for each user after post-install-global.sh.
#
# Consistent with bootstrap.sh and post-install-global.sh:
# - Uses REPO_DIR for all paths (no reliance on cwd)
# - Dual logging to screen + ~/logs/post-install-user-YYYYMMDD-HHMMSS.log (uniquely identifiable, mirrors post-install-global.sh)

if [ "$1" = "--help" ]; then
    echo "Usage: $0 --user <username> [--wheel]"
    echo "Sets up per-user configs for the specified user."
    echo "Run as root. Creates user if they don't exist (with confirmation)."
    echo "Interactive menu by default."
    echo "Prompts before overwriting existing files."
    echo ""
    echo "Options:"
    echo "  --user <username>       Specify the target user (creates if not exists)."
    echo "  --wheel                 Add user to wheel group for sudo access."

    echo ""
    echo "Examples:"
    echo "  $0 --user alice                           # Interactive setup (creates alice if needed)"
    echo "  $0 --user bob --wheel                     # Create/setup bob with sudo access"

    echo ""
echo "Prerequisites: Run from the slackware-installer-for-rs repo directory."
    echo "(The script uses a hardcoded REPO_DIR for robustness.)"
    exit 0
fi

if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi
TARGET_USER=""
ADD_WHEEL=false
INTERACTIVE=false   # default: run everything, print summary, exit
DO_ALL=true

while [ $# -gt 0 ]; do
    case $1 in
        --user) TARGET_USER="$2"; shift 2 ;;
        --wheel) ADD_WHEEL=true; shift ;;
        --interactive|--menu) INTERACTIVE=true; DO_ALL=false; shift ;;
        --all|--non-interactive) DO_ALL=true; INTERACTIVE=false; shift ;;
        *) echo "Invalid option. Use --help for usage."; exit 1 ;;
    esac
done

if [ -z "$TARGET_USER" ]; then
    echo "Specify --user. Use --help for usage."; exit 1
fi

# Set REPO_DIR to the directory where this script (and the installer) lives.
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

# Set up dual logging: everything from this point on goes to the screen
# AND is appended to a dedicated per-user-installer log file.
LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG_FILE="$LOG_DIR/post-install-user-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=================================================="
echo "Per-user setup log for $TARGET_USER started: $(date)"
echo "Log file: $LOG_FILE (also duplicated to screen)"
echo "=================================================="

# The old monolithic user creation/setup logic has been replaced.
# User account creation (and the new "user already exists?" + destructive delete+recreate prompt)
# now lives in steps/user-ensure.sh so it can be run independently and always
# emits a proper SUCCESS/ERROR line like the global steps.
# REPO_DIR is already set above.
# (was duplicated — removed the second assignment)
export TARGET_USER
export ADD_WHEEL

# ------------------------------------------------------------------
# PHASE 1: Ensure user account + groups
# (This step now owns the "user already exists?" logic and the
#  prompt that lets you DELETE the user completely and start fresh.)
# ------------------------------------------------------------------
echo ""
echo "*****************************************************"
echo "PHASE: User account + desktop groups (via user-ensure)"
echo "*****************************************************"

# Ensure the step scripts are executable (defensive - they are sometimes created without +x)
chmod +x ./steps/user-*.sh 2>/dev/null || true

if [ -x "./steps/user-ensure.sh" ]; then
    TARGET_USER="$TARGET_USER" ADD_WHEEL="$ADD_WHEEL" ./steps/user-ensure.sh
    if [ $? -ne 0 ]; then
        echo "ERROR: user-ensure step failed. Aborting."
        exit 1
    fi
else
    echo "ERROR: ./steps/user-ensure.sh not found or not executable (even after chmod)."
    exit 1
fi

# Recompute HOME_TARGET (the user may have been deleted + recreated)
HOME_TARGET=$(eval echo ~$TARGET_USER)

# Ensure ~/logs exists for target user with correct ownership
USER_LOG_DIR="$HOME_TARGET/logs"
mkdir -p "$USER_LOG_DIR" 2>/dev/null || true
chown "$TARGET_USER:$TARGET_USER" "$USER_LOG_DIR" 2>/dev/null || true
chmod 700 "$USER_LOG_DIR" 2>/dev/null || true

# Counters (exact same style as post-install-global.sh)
success_count=0
error_count=0

# Helper to run one of the small step scripts.
# The called script is responsible for printing its own SUCCESS/ERROR
# and exiting with 0 (good) or 1 (bad).
run_step() {
    local label="$1"
    local script="$2"

    echo ""
    if [ -x "$script" ]; then
        TARGET_USER="$TARGET_USER" REPO_DIR="$REPO_DIR" "$script"
        if [ $? -eq 0 ]; then
            success_count=$((success_count + 1))
        else
            error_count=$((error_count + 1))
        fi
    else
        echo "ERROR: $script not found or not executable."
        error_count=$((error_count + 1))
    fi
}

# Available per-user configuration steps.
# Format: "Menu label shown to user:./steps/the-script.sh"
step_list=(
    "user-bashrc:./steps/user-bashrc.sh"
    "user-audio:./steps/user-audio.sh"
    "user-vim:./steps/user-vim.sh"
    "user-ssh:./steps/user-ssh.sh"
    "user-neofetch:./steps/user-neofetch.sh"
    "user-firefox:./steps/user-firefox.sh"
    "user-github-ssh:./steps/user-github-ssh.sh"
    "user-pi-agent:./steps/user-pi-agent.sh"
    "user-firefox-shortcuts:./steps/user-surf-shortcuts.sh"
)
# Build the human-readable menu entries
options=()
for entry in "${step_list[@]}"; do
    options+=("${entry%%:*}")
done

# ------------------------------------------------------------------
# Default / common case (what people actually type):
#   ./post-install-user.sh --user rs [--wheel]
# → run everything, print the summary, and exit.
#
# The menu is only shown if --interactive or --menu is passed.
# ------------------------------------------------------------------
if $DO_ALL || [ ! -t 0 ]; then
    selected=("${options[@]}")
    INTERACTIVE=false
fi

if $INTERACTIVE; then
    selected=()

    PS3="Enter your choice (or 'done' to proceed): "
    while true; do
        echo ""
        echo "Select sections to set up for $TARGET_USER:"
        for i in "${!options[@]}"; do
            echo "$((i+1)). ${options[$i]}"
        done
        echo "$(( ${#options[@]} + 1 )). All sections"
        echo "$(( ${#options[@]} + 2 )). Exit"

        read -p "$PS3" choice

        case "$choice" in
            all|All|ALL|$(( ${#options[@]} + 1 )) )
                selected=("${options[@]}")
                break
                ;;
            exit|Exit|EXIT|$(( ${#options[@]} + 2 )) )
                exit 0
                ;;
            done|Done|DONE)
                break
                ;;
            [0-9]*,*[0-9]*)
                IFS=',' read -ra nums <<< "$choice"
                for num in "${nums[@]}"; do
                    if [ "$num" -ge 1 ] && [ "$num" -le ${#options[@]} ]; then
                        selected+=("${options[$((num-1))]}")
                    fi
                done
                ;;
            [1-9])
                if [ "$choice" -le ${#options[@]} ]; then
                    selected+=("${options[$((choice-1))]}")
                fi
                ;;
            *)
                echo "Invalid choice. Try again."
                ;;
        esac
    done

    if [ ${#selected[@]} -eq 0 ]; then
        echo "No sections selected. Exiting."
        exit 0
    fi

    echo "Selected sections: ${selected[*]}"
    if $INTERACTIVE; then
        read -p "Proceed with these sections? (y/N): " confirm
        [[ "$confirm" != [yY] ]] && exit 0
    fi
else
    selected=("${options[@]}")
fi

# ------------------------------------------------------------------
# Execute the selected steps
# ------------------------------------------------------------------
for section in "${selected[@]}"; do
    for entry in "${step_list[@]}"; do
        if [ "${entry%%:*}" = "$section" ]; then
            run_step "$section" "${entry#*:}"
            break
        fi
    done
done

# ------------------------------------------------------------------
# Ensure net-watch runs for the target user (kills stale old-code
# processes and starts a fresh one writing to the per-user file).
# This remedies the [No Internet] stuck-on issue from old installs.
# ------------------------------------------------------------------
if [ -x /usr/local/bin/net-watch ]; then
    echo ""
    echo "NET-WATCH: ensuring fresh instance for $TARGET_USER..."
    pkill -u "$TARGET_USER" -f '/usr/local/bin/net-watch' 2>/dev/null || true
    sleep 0.3
    rm -f "/tmp/net-watch-$(id -u "$TARGET_USER").pid" "/tmp/net_status_$(id -u "$TARGET_USER")" 2>/dev/null || true
    su "$TARGET_USER" -c 'nohup /usr/local/bin/net-watch > /dev/null 2>&1 &'
    sleep 1
    echo "  net-watch started for $TARGET_USER (writes to /tmp/net_status_\$(id -u $TARGET_USER))"
fi

# ------------------------------------------------------------------
# Final ownership sweep (always performed)
chown "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/.bashrc" "$HOME_TARGET/.vimrc" 2>/dev/null || true
for d in .ssh .vim .config .mozilla .pi; do
    [ -d "$HOME_TARGET/$d" ] && chown -R "$TARGET_USER:$TARGET_USER" "$HOME_TARGET/$d" 2>/dev/null || true
done

# ------------------------------------------------------------------
# Log file location (before final summary)
if [ -f "$LOG_FILE" ]; then
    echo ""
    echo "Full output has been captured to: $LOG_FILE"
    echo "(View with: less $LOG_FILE  or  tail -n 200 $LOG_FILE)"
fi

# FINAL SUMMARY — must be the very last thing printed
echo ""
echo "*****************************************************"
echo "USER SETUP SUMMARY"
echo "*****************************************************"
echo ""
echo "User: $TARGET_USER"
echo "Home: $HOME_TARGET"
echo ""
echo "SUCCESS: $success_count"
echo "ERROR:   $error_count"

exit 0
