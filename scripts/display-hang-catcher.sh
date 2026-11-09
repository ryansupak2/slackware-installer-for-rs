#!/bin/bash
# display-hang-catcher — snapshot the kernel state the moment a display commit stalls
#
# Why: on this machine fullscreen video sometimes wedges the display for ~10 s
# (picture frozen, no cursor, keyboard dead, audio still playing). The kernel
# then logs "flip_done timed out" / "commit wait timed out" / "Timed out
# waiting for PSR Idle", but that message only says a wait expired — it does
# NOT say which wait. Guessing between PSR, DSB, FBC and DPT is how you end up
# disabling power features that were never at fault.
#
# This watcher reads /dev/kmsg and, on the first signature line, dumps every
# task's kernel stack into /var/log. The stack of the display commit worker
# names the exact function that hung (e.g. intel_psr_wait_for_idle,
# intel_dsb_wait, intel_fbc_wait_until_comp_state_clear, …).
#
# It is read-only with respect to the system: it only reads /proc, /sys and
# the kernel log. No sysrq, no signals, no writes outside its own log dir.
#
# Usage: display-hang-catcher            (foreground; rc.local starts it)
#        DISPLAY_HANG_DRYRUN=1 display-hang-catcher   (print, never dump)
#
# Log (daemon convention): /var/log/<user>-display-hang.log
#   "YYYY-MM-DD HH:MM:SS: message"
# Dumps: /var/log/<user>-display-hang-YYYYMMDD-HHMMSS[-N]/

set -u

user="${USER:-root}"
log_file="/var/log/${user}-display-hang.log"
pidfile="/run/display-hang-catcher.pid"
max_dumps_per_boot=${DISPLAY_HANG_MAX_DUMPS:-10}
dump_count=0
quiet_until=0        # epoch; no new dump before this time
same_incident=0      # dumps already taken for the current incident

say() {
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$log_file" >&2
}

# Anything that means "the display was supposed to flip and did not".
# Deliberately broad: a missed trigger wastes a freeze, a false positive just
# writes one small directory.
signature_re='flip_done timed out|commit wait timed out|Timed out waiting for PSR|Timed out waiting PSR|Timed out waiting for DSB|DSB timed out|FBC.*timeout|GPU HANG|GT[0-9]: (GuC|.*reset)|xe .*ERROR'

collect() {
    local tag="$1" dir
    dir="/var/log/${user}-display-hang-$(date +%Y%m%d-%H%M%S)${tag}"
    mkdir -p "$dir" 2>/dev/null || return 1

    # 1. Full kernel ring, with timestamps.
    dmesg -T > "$dir/dmesg.txt" 2>/dev/null

    # 2. Every task: pid, name, state, wchan and kernel stack. This is the
    #    payload — the hung wait shows up as a stack frame.
    {
        for p in /proc/[0-9]*; do
            pid=${p#/proc/}
            comm=$(cat "$p/comm" 2>/dev/null) || continue
            state=$(awk '/^State:/{print $2, $3, $4, $5, $6}' "$p/status" 2>/dev/null)
            wchan=$(cat "$p/wchan" 2>/dev/null)
            stack=$(cat "$p/stack" 2>/dev/null)
            printf '=== pid=%s comm=%s state=%s wchan=%s\n' "$pid" "$comm" "${state:-?}" "${wchan:-?}"
            if [ -n "$stack" ]; then
                printf '%s\n' "$stack"
            else
                printf '   (no stack: task running, no CONFIG_STACKTRACE, or kernel thread)\n'
            fi
            tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-200 | sed 's/^/   cmdline: /'
            printf '\n'
        done
    } > "$dir/tasks.txt" 2>/dev/null

    # 3. Just the graphics-relevant stacks, so the answer is one grep away.
    grep -nE 'intel_|i915|xe_|drm_|wait_for_completion|drm_atomic|psr|dsb|fbc|flip' \
        "$dir/tasks.txt" > "$dir/display-waits.txt" 2>/dev/null

    # 4. Display state as userspace sees it.
    {
        for d in /sys/class/drm/card*/; do
            printf '=== %s\n' "$d"
            cat "$d/status" 2>/dev/null
            cat "$d/enabled" 2>/dev/null
            cat "$d/dpms" 2>/dev/null
        done
    } > "$dir/drm-sysfs.txt" 2>/dev/null
    DISPLAY=:0 timeout 10 xrandr --prop > "$dir/xrandr.txt" 2>/dev/null

    # 5. Driver debugfs, when it happens to be mounted.
    if [ -d /sys/kernel/debug/dri ]; then
        ls -R /sys/kernel/debug/dri > "$dir/debugfs-dri.txt" 2>/dev/null
        for f in /sys/kernel/debug/dri/*/error /sys/kernel/debug/dri/*/i915_error_state \
                 /sys/kernel/debug/dri/*/gt*/error; do
            [ -f "$f" ] || continue
            printf '=== %s\n' "$f" >> "$dir/debugfs-dri.txt" 2>/dev/null
            head -c 65536 "$f" >> "$dir/debugfs-dri.txt" 2>/dev/null
        done
    fi

    # 6. Module parameters actually in force (proves which knobs are active).
    {
        for f in /sys/module/xe/parameters/* /sys/module/i915/parameters/*; do
            [ -f "$f" ] && printf '%s=%s\n' "$(basename "$f")" "$(cat "$f" 2>/dev/null)"
        done
    } > "$dir/parameters.txt" 2>/dev/null

    # Durability matters more than speed here: the machine usually gets a hard
    # reset while the display is wedged, so everything must hit the disk now.
    sync

    dump_count=$((dump_count + 1))
    say "DUMP $dir (dumps this boot: $dump_count) trigger: $2"
    say "  grep display-waits.txt for: intel_psr|intel_dsb|intel_fbc|flip_done|dsb"
    return 0
}

# Manual self-test / "capture the current state now" entry point.
if [ "${1:-}" = "--dump-now" ]; then
    collect "-manual" "manual --dump-now"
    exit 0
fi

dstate_watch() {
    # An uninterruptible X client (Xorg/dwm/slock/chrome) is the signature of a
    # page flip that never came back. The kernel prints nothing in that case, so
    # watch the task states as well as the log.
    local p pid comm st key
    local -A seen=()
    while :; do
        sleep 2
        for p in /proc/[0-9]*; do
            pid=${p#/proc/}
            comm=$(cat "$p/comm" 2>/dev/null) || continue
            case "$comm" in
                Xorg|dwm|slock|chrome) ;;
                *) continue ;;
            esac
            st=$(awk '{print $3}' "$p/stat" 2>/dev/null)
            if [ "$st" != "D" ]; then
                unset "seen[$pid]"
                continue
            fi
            key=${seen[$pid]:-0}
            key=$((key + 1))
            seen[$pid]=$key
            if [ "$key" -eq 4 ]; then      # 4 polls x 2 s = ~8 s stuck
                collect "-dstate-${comm}-${pid}" "$comm pid $pid in D state for ~8s"
            fi
        done
    done
}

say "starting (pid $$), watching /dev/kmsg for display-commit stalls"
say "  signatures: flip_done timed out | commit wait timed out | PSR Idle | DSB | GPU HANG"

# Liveness marker for the installer step; a stale file is harmless because the
# step also checks that the pid still runs this script.
echo $$ > "$pidfile" 2>/dev/null
trap 'rm -f "$pidfile"' EXIT

# Userspace-stall watcher (runs until the script exits)
if [ "${DISPLAY_HANG_NO_DSTATE:-0}" != "1" ]; then
    dstate_watch &
fi

exec 3</dev/kmsg 2>/dev/null || { say "ERROR: cannot read /dev/kmsg (needs root)"; exit 1; }

while IFS= read -r line <&3; do
    # Strip the "<pri,seq,timestamp,flags>;" prefix kmsg puts on each record.
    msg=${line#*;}
    # /dev/kmsg can return EINVAL for messages bigger than the read buffer;
    # those read as an empty line, which simply cannot match.
    [ -n "$msg" ] || continue
    [[ $msg =~ $signature_re ]] || continue

    now=$(date +%s)
    if [ "$now" -lt "$quiet_until" ]; then
        continue
    fi
    if [ "$dump_count" -ge "$max_dumps_per_boot" ]; then
        say "limit reached ($max_dumps_per_boot dumps this boot) — not dumping again"
        quiet_until=$((now + 3600))
        continue
    fi

    if [ "${DISPLAY_HANG_DRYRUN:-0}" = "1" ]; then
        say "DRYRUN would dump: $msg"
        quiet_until=$((now + 60))
        continue
    fi

    # A stall produces several lines 10 s apart; take up to 3 dumps per
    # incident, then stay quiet for 10 minutes.
    same_incident=$((same_incident + 1))
    collect "-$same_incident" "$msg"
    if [ "$same_incident" -ge 3 ]; then
        same_incident=0
        quiet_until=$((now + 600))
    else
        quiet_until=$((now + 8))
    fi
done

say "kernel log closed — exiting"
