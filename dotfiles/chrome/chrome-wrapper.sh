#!/bin/bash
# Chrome wrapper to force GTK font settings for file picker
export GTK_THEME=Adwaita
export GTK_FONT_NAME="Berkeley Mono 12"
export gtk-font-name="Berkeley Mono 12"
exec google-chrome-stable --gtk-version=3 --password-store=basic --no-sandbox --force-dark-mode --force-device-scale-factor=1.5 "$@"