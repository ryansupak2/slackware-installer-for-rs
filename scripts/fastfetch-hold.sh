#!/bin/sh
# fastfetch-hold — run fastfetch, then drop to an interactive shell
fastfetch
exec "${SHELL:-/bin/sh}"
