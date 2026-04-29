#!/bin/bash

# help.sh - Display keybindings and aliases

# Load aliases from bashrc
source ~/.bashrc

echo "Mod + Shift + Enter        -> Terminal"
echo "Mod + 1-9                  -> Switch to tag"
echo "Mod + Shift + 1-9          -> Move window to tag"
echo "Mod + Left/Right           -> Switch to prev/next tag"
echo "Mod + Down/Up              -> Focus prev/next window"
echo "Mod + Shift + Left/Right   -> Move window to prev/next tag"
echo "Mod + M/T/F                -> Monocle/Tile/Float mode"
echo "Mod + Shift + C            -> Kill current window"
echo "Mod + Shift + Q            -> Quit dwm"
echo ""
echo "Aliases from local config:"
alias | sed 's/alias //' | sort
