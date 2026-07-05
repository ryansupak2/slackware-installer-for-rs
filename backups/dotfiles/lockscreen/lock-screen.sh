#!/bin/bash
USER=$(ps -o user= -C dwm | head -1)
DISPLAY=:0 su "$USER" -c 'xlock -mode blank'