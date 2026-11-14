#!/bin/sh
# build-ticker.sh — one compact progress line every few seconds while a big
# source build runs, so "is it working or hung?" is answerable without reading
# thousands of gcc lines.
#
# It never filters or buffers the build's own output: the compiler lines keep
# going to the terminal exactly as they are. This only ADDS a status line.
#
# Usage:
#   build-ticker.sh LABEL WATCH_DIR MARKER_FILE [INTERVAL_SECONDS]
#
#   LABEL        short name shown in the line ("kitty", "notcurses")
#   WATCH_DIR    directory scanned for *.o/*.lo files (the build tree)
#   MARKER_FILE  ticker runs while this file exists; `rm` it to stop it
#   INTERVAL     seconds between lines (default 5)
#
# The caller removes the marker file when the build finishes; the ticker then
# exits on its own within one interval, so nothing has to send it a signal.

label="$1"
watch="$2"
marker="$3"
interval="${4:-5}"

if [ -z "$label" ] || [ -z "$watch" ] || [ -z "$marker" ]; then
    echo "usage: build-ticker.sh LABEL WATCH_DIR MARKER_FILE [INTERVAL]" >&2
    exit 2
fi

t0=$(date +%s)
prev=0

while [ -e "$marker" ]; do
    sleep "$interval"
    [ -e "$marker" ] || break

    elapsed=$(( $(date +%s) - t0 ))
    objs=0
    if [ -d "$watch" ]; then
        objs=$(find "$watch" \( -name '*.o' -o -name '*.lo' \) 2>/dev/null | wc -l)
    fi
    delta=$(( objs - prev ))
    prev=$objs
    # live compiler/linker processes (cc1/cc1plus/as/ld/go) — proof of work
    busy=$(ps -eo comm 2>/dev/null | grep -cE '^(cc1|cc1plus|as|ld|go|make|cmake|ninja)$')

    printf '[%s ticker] %dm%02ds elapsed | %d objects (+%d) | %d compute procs\n' \
        "$label" $(( elapsed / 60 )) $(( elapsed % 60 )) "$objs" "$delta" "$busy"
done
