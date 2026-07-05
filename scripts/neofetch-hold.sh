#!/bin/sh
# neofetch-hold — run neofetch, then drop to an interactive shell
neofetch
exec "${SHELL:-/bin/sh}"
