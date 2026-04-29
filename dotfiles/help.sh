#!/bin/bash

# help.sh - Display keybindings and aliases

# Load aliases from bashrc
source ~/.bashrc

echo "Keybindings (from Neofetch config):"
echo "Mod + Enter          -> Terminal"
echo "Mod + Shift + Enter  -> Dmenu"
echo "Mod + Shift + C      -> Kill window"
echo "Mod + Shift + Q      -> Quit dwm"
echo "Mod + 1-9            -> Switch to tag"
echo "Mod + Shift + 1-9    -> Move window to tag"
echo "Mod + J/K            -> Focus next/prev window"
echo "Mod + Shift + J/K    -> Move window"
echo "Mod + H/L            -> Resize master area"
echo "Mod + Return         -> Zoom window"
echo "Mod + Tab            -> Last window"
echo "Mod + Shift + Space  -> Toggle floating"
echo "Mod + Space          -> Toggle layout"
echo ""
echo "Aliases from local config:"
alias | sed 's/alias //' | sort