#!/bin/bash
# broadcast a message to every open terminal
msg="$*"
for t in /dev/pts/[0-9]*; do
    echo "$msg" > "$t" 2>/dev/null
done
