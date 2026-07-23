#!/bin/sh
# toggle-vox.sh — voice dictation: 2s drafts + 5s revisions
# Drafts type instantly. Revisions backspace all drafts + old rev,
# then type only the new canonical text (not the full buffer).
# Counters track exactly what's on screen. Lock prevents races.

XDG_RT="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE_FILE="$XDG_RT/vox_state"; PID_F="$XDG_RT/vox_recorder_pid"
FIFO="${XDG_RT}/dwmbar-0"
FULL="$XDG_RT/vox-full"
LOCK="$XDG_RT/vox-wtype-lock"
plen_d="$XDG_RT/vox-plen-d"; plen_r="$XDG_RT/vox-plen-r"
MODEL="/usr/local/share/vox/ggml-tiny.en.bin"
MODEL_REV="/usr/local/share/vox/ggml-base.en.bin"
W="/usr/local/bin/whisper-cli"; T="/usr/bin/wtype"
L="/var/log"; mkdir -p "$L" 2>/dev/null; VL="$L/${USER:-root}-vox.log"
log_msg() { echo "$(date): $*" >> "$VL"; }
[ -f /usr/local/bin/temp-msg.sh ] && . /usr/local/bin/temp-msg.sh

transcribe() {
    local wav="$1" m="${2:-$MODEL}"
    [ ! -f "$wav" ] && return 1
    [ "$(stat -c%s "$wav")" -lt 500 ] && return 1
    "$W" -m "$m" -f "$wav" --no-timestamps --no-fallback --entropy-thold 2.0 -otxt >/dev/null 2>>"$VL"
    [ ! -f "$wav.txt" ] && return 1; [ ! -s "$wav.txt" ] && { rm -f "$wav.txt"; return 1; }
    local t=$(sed '/^[[:space:]]*$/d; s/\[[^]]*\]//g; s/([^)]*)//g; s/{[^}]*}//g; s/\*[^*]*\*//g' "$wav.txt" | tr '\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '\r')
    rm -f "$wav.txt"
    [ -z "$t" ] && return 1
    printf '%s' "$t"; return 0
}

acquire() { while ! mkdir "$LOCK" 2>/dev/null; do sleep 0.02; done; }
release() { rmdir "$LOCK" 2>/dev/null; }

type_text() {
    local t="$1"
    log_msg "  [WTYPE] text (${#t} chars): $t"
    printf '%s ' "$t" | "$T" -
}

type_key() {
    log_msg "  [WTYPE] key: $*"
    "$T" "$@"
}

# Backspace N times
bs() {
    local n=$1 i=0
    [ "$n" -le 0 ] 2>/dev/null && return
    log_msg "  [WTYPE] backspace x$n"
    while [ $i -lt $n ]; do "$T" -k backspace; i=$((i+1)); done
}


if [ -f "$STATE_FILE" ]; then
    log_msg "OFF"; echo "off" > "$STATE_FILE"
    [ -f "$PID_F" ] && { for p in $(cat "$PID_F"); do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -f "$PID_F"; }
    rm -f "$STATE_FILE" "$FULL" "$plen_d" "$plen_r" "$XDG_RT"/vox-buf*.wav
    rmdir "$LOCK" 2>/dev/null
    rm -f "$STATE_FILE"
    type set_temp_msg >/dev/null 2>&1 && set_temp_msg "(VOX Off [Mod+V])" 3
else
    log_msg "ON"; echo "loading" > "$STATE_FILE"
    echo -n "" > "$FULL"
    echo 0 > "$plen_d"; echo 0 > "$plen_r"
    rmdir "$LOCK" 2>/dev/null

    # Draft: 2s chunks, instant rough text (dev7)
    (
        last=""; n=0
        arecord -D plughw:0,7 -d 1 -c 1 -f S16_LE -r 16000 "$XDG_RT/vox-buf-d0.wav" 2>>"$VL" &
        rpid=$!
        while [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" = "recording" ]; do
            wait $rpid 2>/dev/null
            buf="$XDG_RT/vox-buf-d$n.wav"; n=$((1-n))
            arecord -D plughw:0,7 -d 1 -c 1 -f S16_LE -r 16000 "$XDG_RT/vox-buf-d$n.wav" 2>>"$VL" &
            rpid=$!
            t=$(transcribe "$buf" 2>/dev/null); rm -f "$buf"
            if [ -n "$t" ] && [ "$t" != "$last" ]; then
                last="$t"
                # Skip draft if already at end of canonical buffer
                full_now=$(cat "$FULL" 2>/dev/null)
                case "$full_now" in *"$t") ;; *"$t "*) ;; *)
                    log_msg "  draft: $t"
                    acquire
                    type_text "$t"
                    echo $(($(cat "$plen_d" 2>/dev/null || echo 0) + ${#t} + 1)) > "$plen_d"
                    log_msg "  [CNT] plen_d=$(cat $plen_d 2>/dev/null) (added ${#t}+1)"
                    release
                esac
            fi
        done
        [ -n "$rpid" ] && { kill $rpid 2>/dev/null; wait $rpid 2>/dev/null; }
    ) &
    dp=$!

    # Revision: 5s chunks, backspaces accumulated drafts, types only new chunk (dev6)
    (
        last=""; n=0
        arecord -D plughw:0,6 -d 5 -c 1 -f S16_LE -r 16000 "$XDG_RT/vox-buf-r0.wav" 2>>"$VL" &
        rpid=$!
        while [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE" 2>/dev/null)" = "recording" ]; do
            wait $rpid 2>/dev/null
            buf="$XDG_RT/vox-buf-r$n.wav"; n=$((1-n))
            arecord -D plughw:0,6 -d 5 -c 1 -f S16_LE -r 16000 "$XDG_RT/vox-buf-r$n.wav" 2>>"$VL" &
            rpid=$!
            t=$(transcribe "$buf" "$MODEL_REV" 2>/dev/null); rm -f "$buf"
            if [ -n "$t" ] && [ "$t" != "$last" ]; then
                last="$t"
                printf '%s ' "$t" >> "$FULL"
                nd=$(cat "$plen_d" 2>/dev/null || echo 0)
                log_msg "  [CNT] rev reads plen_d=$nd"
                log_msg "  rev: $t"
                acquire
                bs $nd
                type_text "$t"
                echo 0 > "$plen_d"; log_msg "  [CNT] rev reset plen_d=0"
                release
            fi
        done
        [ -n "$rpid" ] && { kill $rpid 2>/dev/null; wait $rpid 2>/dev/null; }
    ) &
    rp=$!

    echo "$dp $rp" > "$PID_F"
    echo "recording" > "$STATE_FILE"
    echo "show all" > "$FIFO" 2>/dev/null
    type set_temp_msg >/dev/null 2>&1 && set_temp_msg "(VOX On [Mod+V])" 3
fi
