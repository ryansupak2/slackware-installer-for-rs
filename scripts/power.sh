#!/bin/bash
# power — laptop power / battery policy tool (check + change + auto mode)
#
# Installed as /usr/local/bin/power by steps/power.sh.
#
# Usage:
#   power                       Power mode + status: source, battery, CPU,
#                               backlight, display, sleep, lid
#   power profile NAME          Apply powersave|balanced|performance now and store
#                               it as this power source's profile
#   power set governor GOV      performance | powersave
#   power set epp EPP           default | performance | balance_performance |
#                               balance_power | power
#   power set turbo on|off      intel_pstate turbo
#   power set brightness PCT    Panel backlight 1-100 (marks it as a manual choice:
#                               the policy will not override it until you run
#                               'power profile ...' again)
#   power set blank MIN         X screen blank timeout in minutes (0 = never)
#   power set avg SECONDS       Window for the time-left estimate (default 120,
#                               60-1800; smaller = more responsive, noisier)
#   power auto                  Show auto mode
#   power auto on|off           Follow AC/battery automatically (udev hook)
#   power auto battery NAME     Profile applied while unplugged
#   power auto ac NAME          Profile applied while plugged in
#   power wake                  Show wake sources + suspend mode
#   power wake restrict         Wake sources: power button + lid only
#                               (this does not change the sleep state)
#   power set sleep s2idle|deep Sleep state used by the next suspend. s2idle
#                               (modern standby) is what this firmware
#                               implements; deep (S3) never resumes here —
#                               see doc/screen-locking.md before changing it.
#   power wake allow            Re-enable all wake sources
#   power apply                 Re-apply policy for the current source
#                               (internal: udev + elogind hooks call this)
#   power boot                  apply + wake policy (rc.local / X session start)
#   power menu                  Interactive menu
#
# State lives in /var/lib/power/state. Profiles:
#   powersave    governor=powersave epp=power          turbo off  backlight 25%
#   balanced     governor=powersave epp=balance_power  turbo on   backlight 50%
#   performance  governor=performance epp=performance  turbo on   backlight 100%
#
# Time left = energy_now / average draw over the last RATE_WINDOW seconds.
# The average comes from upowerd's own history file (it already samples the
# battery every ~30 s): /var/lib/upower/history-rate-*.dat. Reading the tail of
# that file is instant, so `power` never sits and samples the battery itself.
# If upower history is unavailable the estimate falls back to the instantaneous
# power_now value (and says so).

export PATH="/usr/sbin:/sbin:$PATH"

STATE_DIR="/var/lib/power"
STATE_FILE="$STATE_DIR/state"
SAVED_BRIGHTNESS="$STATE_DIR/brightness.saved"   # pre-cap value, restored on AC
BL_POLICY_FILE="$STATE_DIR/brightness.policy"    # last value the policy itself wrote

# ── Elevation ─────────────────────────────────────────────────────────
# Changing anything writes to sysfs; read-only commands run as the user.
elevate() {
    local self
    [ "$(id -u)" -eq 0 ] && return 0
    [ -n "${POWER_ELEVATED:-}" ] && return 0
    self=$(command -v /usr/local/bin/power 2>/dev/null || echo "$0")
    if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        export POWER_ELEVATED=1
        export POWER_INVOKER="${POWER_INVOKER:-${USER:-$(id -un)}}"
        export POWER_DISPLAY="${POWER_DISPLAY:-${DISPLAY:-}}"
        export POWER_XAUTHORITY="${POWER_XAUTHORITY:-${XAUTHORITY:-}}"
        exec sudo -n "$self" "$@"
    fi
    echo "ERROR: changing power settings needs root (or passwordless sudo for /usr/local/bin/power)." >&2
    echo "       Read-only: 'power status', 'power wake' still work unprivileged." >&2
    exit 1
}

# ── Defaults / state ──────────────────────────────────────────────────
AUTO=on
BATTERY_PROFILE=balanced
AC_PROFILE=performance
WAKE=power-button-lid
BLANK_MINUTES=5
BRIGHTNESS_MODE=auto
RATE_WINDOW=120     # seconds of battery-draw history averaged for time-left

load_state() {
    # shellcheck disable=SC1090
    [ -r "$STATE_FILE" ] && . "$STATE_FILE"
    # Older state files said "power-button-only"; the policy now also keeps the
    # lid (lid close suspends, lid open resumes) so map the old value forward.
    [ "$WAKE" = "power-button-only" ] && WAKE=power-button-lid
    return 0
}

save_state() {
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    cat > "$STATE_FILE" <<EOF
# power state — managed by /usr/local/bin/power
# Change it with: power auto|profile|set|wake  (do not hand-edit unless you mean it)
AUTO=$AUTO
BATTERY_PROFILE=$BATTERY_PROFILE
AC_PROFILE=$AC_PROFILE
WAKE=$WAKE
BLANK_MINUTES=$BLANK_MINUTES
BRIGHTNESS_MODE=${BRIGHTNESS_MODE:-auto}
RATE_WINDOW=${RATE_WINDOW:-120}
EOF
}

# ── Logging ───────────────────────────────────────────────────────────
# Hooks (udev/elogind/rc.local) append to one file: YYYY-MM-DD HH:MM:SS: msg
# Interactive runs go to /var/log/<user>-power-YYYYMMDD-HHMMSS.log (tee'd).
HOOK_LOG="/var/log/${POWER_INVOKER:-root}-power.log"

hook_log() {
    printf '%s: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$HOOK_LOG" 2>/dev/null || true
    echo "$*"
}

setup_cli_log() {
    local f="/var/log/${POWER_INVOKER:-${USER:-root}}-power-$(date +%Y%m%d-%H%M%S).log"
    mkdir -p /var/log 2>/dev/null || true
    if : >>"$f" 2>/dev/null; then
        exec > >(tee -a "$f") 2>&1
    fi
}

# ── Terminal formatting ───────────────────────────────────────────────
if [ -t 1 ]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; RED=$'\033[31m'
    YELLOW=$'\033[33m'; CYAN=$'\033[36m'; NC=$'\033[0m'
else
    BOLD=''; DIM=''; GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

warn() { echo "${YELLOW}WARNING:${NC} $*" >&2; }
die()  { echo "${RED}ERROR:${NC} $*" >&2; exit 1; }

# ── Hardware discovery ────────────────────────────────────────────────
ac_online() {
    # POWER_FORCE_SOURCE=ac|battery overrides detection — lets the plug/unplug
    # paths be tested without physically unplugging the machine.
    case "${POWER_FORCE_SOURCE:-}" in
        ac|AC|mains) return 0 ;;
        battery|bat|BAT) return 1 ;;
    esac
    local d
    for d in /sys/class/power_supply/*; do
        [ -r "$d/type" ] || continue
        [ "$(cat "$d/type" 2>/dev/null)" = "Mains" ] || continue
        [ "$(cat "$d/online" 2>/dev/null)" = "1" ] && return 0
    done
    return 1
}

battery_dir() {
    local d
    for d in /sys/class/power_supply/*; do
        [ -r "$d/type" ] || continue
        [ "$(cat "$d/type" 2>/dev/null)" = "Battery" ] || continue
        echo "$d"; return 0
    done
    return 1
}

bat_watts() {   # current draw in watts (positive number), or nothing
    local b p i v
    b=$(battery_dir) || return 1
    if [ -r "$b/power_now" ]; then
        p=$(cat "$b/power_now" 2>/dev/null)
        if [ "${p:-0}" -gt 0 ] 2>/dev/null; then
            awk -v p="$p" 'BEGIN{printf "%.1f", p/1e6}'; return 0
        fi
    fi
    if [ -r "$b/current_now" ] && [ -r "$b/voltage_now" ]; then
        i=$(cat "$b/current_now" 2>/dev/null); v=$(cat "$b/voltage_now" 2>/dev/null)
        awk -v i="$i" -v v="$v" 'BEGIN{ if (i<0) i=-i; printf "%.1f", (i*v)/1e12 }'
        return 0
    fi
    return 1
}

# ── Battery draw history (rolling average) ────────────────────────────
# upowerd samples the battery about every 30 s and appends each reading to
#   /var/lib/upower/history-rate-<model>-<serial>.dat
# as "<epoch>\t<watts>\t<charging|discharging|unknown>". Reading the tail of
# that file costs nothing, so the estimate is an average of the recent past
# without `power` itself waiting for samples to accumulate. The current sysfs
# reading is folded in as the newest sample, so the average never goes stale
# even when upowerd pauses between history writes.
RATE_HISTORY_DIR=/var/lib/upower

rate_history_file() {   # newest upower rate-history file belonging to our battery
    local b serial f t best="" best_t=0
    local cands=()
    b=$(battery_dir 2>/dev/null) || return 1
    serial=$(cat "$b/serial_number" 2>/dev/null)

    if [ -n "$serial" ]; then       # upower names the file after model + serial
        for f in "$RATE_HISTORY_DIR"/history-rate-*-"$serial".dat; do
            [ -f "$f" ] && cands+=("$f")
        done
    fi
    if [ "${#cands[@]}" -eq 0 ]; then
        for f in "$RATE_HISTORY_DIR"/history-rate-*.dat; do
            [ -f "$f" ] || continue
            case "$f" in *generic_id.dat) continue ;; esac
            cands+=("$f")
        done
    fi
    [ "${#cands[@]}" -gt 0 ] || return 1

    for f in "${cands[@]}"; do      # the one with the freshest sample wins
        t=$(stat -c %Y "$f" 2>/dev/null) || continue
        [ "$t" -ge "$best_t" ] && { best_t=$t; best=$f; }
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

rate_cache_file() {   # dwm-status's own sample cache (it reads the battery every tick)
    local f t best="" best_t=0
    f="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/battery-rate.tsv"
    if [ -f "$f" ]; then echo "$f"; return 0; fi
    # root, or a status run outside its own session: use the newest cache we
    # can see (the session user's runtime dir).
    for f in /run/user/*/battery-rate.tsv; do
        [ -f "$f" ] || continue
        t=$(stat -c %Y "$f" 2>/dev/null) || continue
        [ "$t" -ge "$best_t" ] && { best_t=$t; best=$f; }
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

rate_history_dump() {   # every rate sample we can see (dwm-status cache + upower)
    local cf uf self have_cache=0
    if cf=$(rate_cache_file); then      # written every ~20 s by the status bar
        have_cache=1
        cat "$cf" 2>/dev/null
    fi
    uf=$(rate_history_file) || return 0
    if [ -r "$uf" ]; then
        cat "$uf" 2>/dev/null
        return 0
    fi
    # upowerd writes history 0640 root:root. The cache above is enough on its
    # own, so only pay for the sudo round-trip when there is nothing else.
    [ "$have_cache" = 1 ] && return 0
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || return 0
    self=$(command -v /usr/local/bin/power 2>/dev/null || echo "$0")
    sudo -n "$self" _rates 2>/dev/null
}

rate_window_label() {   # 120 -> "2m", 90 -> "90s"
    local w=${RATE_WINDOW:-120}
    case "$w" in ''|*[!0-9]*) echo "${w}s"; return 0 ;; esac
    if [ "$w" -ge 60 ] && [ $((w % 60)) -eq 0 ]; then echo "$((w / 60))m"; else echo "${w}s"; fi
}

bat_rate_stats() {   # "<avg_watts> <samples>" over the last RATE_WINDOW seconds, or fail
    local w=${RATE_WINDOW:-120} inst hist
    case "$w" in ''|*[!0-9]*) w=120 ;; esac
    # upower samples every ~30 s: under a minute there is nothing to average.
    [ "$w" -lt 60 ] && w=60
    [ "$(cat "$(battery_dir 2>/dev/null)/status" 2>/dev/null)" = Discharging ] || return 1
    inst=$(bat_watts 2>/dev/null) || inst=0
    hist=$(rate_history_dump 2>/dev/null) || return 1
    [ -n "$hist" ] || return 1
    printf '%s\n' "$hist" | awk -v now="$(date +%s)" -v win="$w" -v inst="$inst" '
        BEGIN { FS = "\t"; n = 0; sum = 0
                # the live sysfs reading counts as the freshest sample
                if (inst > 0) { n = 1; sum = inst } }
        {
            t = $1 + 0; r = $2 + 0
            if ($3 != "discharging" || t <= 0 || r <= 0) next
            if (t > now || now - t > win) next
            n++; sum += r
        }
        END {
            if (n < 2) exit 1                 # only the live reading: no average yet
            printf "%.2f %d", sum / n, n
        }'
}

bat_rate_avg_w() {   # discharge watts averaged over the last RATE_WINDOW seconds
    local out
    out=$(bat_rate_stats) || return 1
    echo "${out%% *}"
}

bat_time_left() {   # "4h12m" while discharging (arg 1: watts, optional)
    local b e rate=${1:-}
    b=$(battery_dir) || return 1
    e=$(cat "$b/energy_now" 2>/dev/null)
    [ "${e:-0}" -gt 0 ] 2>/dev/null || return 1
    # Rolling average first; instantaneous power_now only as a fallback.
    [ -n "$rate" ] || { rate=$(bat_rate_avg_w) || rate=$(bat_watts 2>/dev/null); }
    [ -n "$rate" ] || return 1
    awk -v e="$e" -v r="$rate" 'BEGIN{
        if (r <= 0) exit 1
        h = (e / 1e6) / r
        hh = int(h); mm = int((h - hh) * 60)
        printf "%dh%02dm", hh, mm }'
}

backlight_dir() {
    local d
    for d in /sys/class/backlight/*; do
        [ -d "$d" ] && { echo "$d"; return 0; }
    done
    return 1
}

brightness_pct() {
    local d cur max
    d=$(backlight_dir) || return 1
    cur=$(cat "$d/brightness" 2>/dev/null); max=$(cat "$d/max_brightness" 2>/dev/null)
    [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null || return 1
    echo $((cur * 100 / max))
}

# ── CPU controls ──────────────────────────────────────────────────────
set_governor() {
    local gov=$1 f
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [ -w "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "$gov" ] || echo "$gov" >"$f" 2>/dev/null
    done
}

epp_available() { cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_available_preferences 2>/dev/null; }

set_epp() {
    local want=$1 f
    case " $(epp_available) " in
        *" $want "*) ;;
        *) return 1 ;;
    esac
    for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/energy_performance_preference; do
        [ -w "$f" ] || continue
        [ "$(cat "$f" 2>/dev/null)" = "$want" ] || echo "$want" >"$f" 2>/dev/null
    done
}

set_turbo() {   # on|off
    local f=/sys/devices/system/cpu/intel_pstate/no_turbo
    [ -w "$f" ] || return 1
    if [ "$1" = "off" ]; then echo 1 >"$f" 2>/dev/null; else echo 0 >"$f" 2>/dev/null; fi
}

turbo_state() {
    local f=/sys/devices/system/cpu/intel_pstate/no_turbo
    [ -r "$f" ] || return 1
    [ "$(cat "$f" 2>/dev/null)" = "1" ] && echo off || echo on
}

# ── Backlight controls ────────────────────────────────────────────────
# The policy writes brightness only while BRIGHTNESS_MODE=auto. Any change it
# did not make (brightness keys, manual sysfs write, 'power set brightness')
# switches it to manual, and the policy then stops touching the panel until
# the user explicitly hands control back with 'power profile ...'.
bl_raw() {
    local d
    d=$(backlight_dir) || return 1
    cat "$d/brightness" 2>/dev/null
}

bl_pct_to_raw() {
    local pct=$1 d max target
    d=$(backlight_dir) || return 1
    max=$(cat "$d/max_brightness" 2>/dev/null)
    [ -n "$max" ] && [ "$max" -gt 0 ] 2>/dev/null || return 1
    [ "$pct" -lt 1 ] 2>/dev/null && pct=1
    [ "$pct" -gt 100 ] 2>/dev/null && pct=100
    target=$((max * pct / 100)); [ "$target" -lt 1 ] && target=1
    echo "$target"
}

policy_bl_write() {   # raw value -> device, remembered as policy-written
    local raw=$1 d
    d=$(backlight_dir) || return 1
    echo "$raw" >"$d/brightness" 2>/dev/null || { warn "cannot write $d/brightness"; return 1; }
    echo "$raw" >"$BL_POLICY_FILE" 2>/dev/null || true
}

policy_bl_forget() { rm -f "$BL_POLICY_FILE" 2>/dev/null || true; }

set_brightness_pct() {
    local raw
    raw=$(bl_pct_to_raw "$1") || { warn "no backlight device found"; return 1; }
    if [ "$(bl_raw)" = "$raw" ]; then
        # Value already right — still record it, otherwise the next apply
        # would mistake it for a manual change.
        echo "$raw" >"$BL_POLICY_FILE" 2>/dev/null || true
        return 0
    fi
    policy_bl_write "$raw"
}

# True when the panel was changed by something other than the policy.
brightness_drifted() {
    local cur last
    [ -r "$BL_POLICY_FILE" ] || return 1
    last=$(cat "$BL_POLICY_FILE" 2>/dev/null)
    cur=$(bl_raw) || return 1
    [ -n "$last" ] && [ "$cur" != "$last" ]
}

# Called before any policy brightness change: a manual change wins, and keeps
# winning until the user runs 'power profile ...' again.
brightness_yield_if_manual() {
    if brightness_drifted; then
        BRIGHTNESS_MODE=manual; save_state; policy_bl_forget
        hook_log "backlight changed by user ($(brightness_pct)%) — leaving it alone (BRIGHTNESS_MODE=manual)"
        return 1
    fi
    [ "${BRIGHTNESS_MODE:-auto}" = "auto" ]
}

# Battery: lower to the profile value, remembering what the user had.
cap_brightness_pct() {
    local raw cur
    brightness_yield_if_manual || return 0
    raw=$(bl_pct_to_raw "$1") || return 0
    cur=$(bl_raw) || return 0
    [ "$cur" -le "$raw" ] && return 0
    echo "$cur" >"$SAVED_BRIGHTNESS" 2>/dev/null || true
    policy_bl_write "$raw" || true
}

# AC: put back the pre-cap value (only if the user has not touched it since).
restore_brightness() {
    [ -r "$SAVED_BRIGHTNESS" ] || return 0
    brightness_yield_if_manual || return 0
    local saved cur max
    saved=$(cat "$SAVED_BRIGHTNESS" 2>/dev/null)
    rm -f "$SAVED_BRIGHTNESS" 2>/dev/null || true
    [ -n "$saved" ] || return 0
    cur=$(bl_raw) || return 0
    max=$(cat "$(backlight_dir)/max_brightness" 2>/dev/null)
    if [ "$saved" -le "$max" ] 2>/dev/null; then
        policy_bl_write "$saved" || true
    fi
}

# ── Profiles ──────────────────────────────────────────────────────────
valid_profile() {
    case "$1" in powersave|balanced|performance) return 0 ;; esac
    return 1
}
profile_governor()   { case "$1" in powersave|balanced) echo powersave ;; performance) echo performance ;; *) return 1 ;; esac; }
profile_epp()        { case "$1" in powersave) echo power ;; balanced) echo balance_power ;; performance) echo performance ;; *) return 1 ;; esac; }
profile_turbo()      { case "$1" in powersave) echo off ;; *) echo on ;; esac; }
profile_brightness() { case "$1" in powersave) echo 25 ;; balanced) echo 50 ;; performance) echo 100 ;; *) echo 50 ;; esac; }

apply_cpu_profile() {
    local prof=$1 gov epp turbo
    gov=$(profile_governor "$prof") || return 1
    epp=$(profile_epp "$prof")
    turbo=$(profile_turbo "$prof")
    set_governor "$gov"
    set_epp "$epp" || true
    set_turbo "$turbo" || true
}

# ── Wake sources ──────────────────────────────────────────────────────
# The sleep state, which is NOT the same question as the wake sources:
#
# s2idle is ACPI low-power S0 idle ("Modern Standby"). This platform's
# firmware advertises it (dmesg: "Low-power S0 idle used by default for
# system suspend"), which is the kernel saying the firmware wants s2idle.
#
# `deep` is legacy S3. `power wake restrict` used to force it, to make sysfs
# wakeup restrictions bite — and that is exactly what broke the lid: on this
# machine S3 never comes back. /var/log/messages ends with
#
#     Nov 12 10:22:14 ... kernel: PM: suspend entry (deep)
#
# and the next line is the next boot, 26 hours later, after a power-button
# reset. Lid close therefore suspended into a state only a held power button
# could leave. s2idle is what the firmware implements, so it is what we ask
# for; `deep` stays available as a fallback with `power set sleep deep` for
# machines where s2idle is the broken one.
mem_sleep_cur() { sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null; }

preferred_mem_sleep() {
    # The state this kernel/firmware should use: s2idle when offered.
    local avail
    avail=$(cat /sys/power/mem_sleep 2>/dev/null)
    case "$avail" in
        *s2idle*) echo s2idle ;;
        *deep*)   echo deep ;;
        *)        echo "" ;;
    esac
}

set_mem_sleep() {
    # $1 = s2idle|deep. Returns 0 only when the kernel now reports it.
    local want=$1
    case "$want" in s2idle|deep) ;; *) return 1 ;; esac
    grep -qw "$want" /sys/power/mem_sleep 2>/dev/null || return 1
    [ "$(mem_sleep_cur)" = "$want" ] && return 0
    echo "$want" > /sys/power/mem_sleep 2>/dev/null || return 1
    [ "$(mem_sleep_cur)" = "$want" ]
}

wake_enabled_count() {
    local f n=0
    while IFS= read -r -d '' f; do
        [ "$(cat "$f" 2>/dev/null)" = "enabled" ] && n=$((n + 1))
    done < <(find /sys/devices -path '*/power/wakeup' -not -path '*/virtual/*' -print0 2>/dev/null)
    echo "$n"
}

wake_restrict() {
    local dev n=0 f d=0
    if [ -r /proc/acpi/wakeup ]; then
        while read -r dev; do
            [ -n "$dev" ] || continue
            # LID* stays enabled: lid close suspends, lid open resumes
            case "$dev" in PWRB|SLPB|LID*|LNXPWRBN*) continue ;; esac
            echo "$dev" >/proc/acpi/wakeup 2>/dev/null && n=$((n + 1))
        done < <(awk 'NR>1 && $3 ~ /\*enabled/ {print $1}' /proc/acpi/wakeup 2>/dev/null)
    fi
    while IFS= read -r -d '' f; do
        case "$f" in
            # PNP0C0D is the lid switch — it must be able to wake the machine
            *LNXPWRBN*|*PWRB*|*PNP0C0D*) echo enabled >"$f" 2>/dev/null; continue ;;
        esac
        if [ "$(cat "$f" 2>/dev/null)" = "enabled" ] && echo disabled >"$f" 2>/dev/null; then
            d=$((d + 1))
        fi
    done < <(find /sys/devices -path '*/power/wakeup' -not -path '*/virtual/*' -print0 2>/dev/null)
    # Make the chosen sleep state explicit (never silently leave it on
    # whatever a previous run wrote). See preferred_mem_sleep() for why
    # s2idle and not deep — forcing deep here used to hang lid close.
    set_mem_sleep "$(preferred_mem_sleep)" || true
    hook_log "wake: power button + lid ($d sysfs source(s) disabled, $n ACPI toggled, mem_sleep=$(mem_sleep_cur))"
}

wake_allow() {
    local f n=0 dev
    while IFS= read -r -d '' f; do
        if [ "$(cat "$f" 2>/dev/null)" = "disabled" ] && echo enabled >"$f" 2>/dev/null; then
            n=$((n + 1))
        fi
    done < <(find /sys/devices -path '*/power/wakeup' -not -path '*/virtual/*' -print0 2>/dev/null)
    if [ -r /proc/acpi/wakeup ]; then
        while read -r dev; do
            [ -n "$dev" ] || continue
            echo "$dev" >/proc/acpi/wakeup 2>/dev/null || true
        done < <(awk 'NR>1 && $3 ~ /\*disabled/ {print $1}' /proc/acpi/wakeup 2>/dev/null)
    fi
    hook_log "wake: all sources re-enabled ($n sysfs source(s))"
}

cmd_wake() {
    local sub=${1:-}
    case "$sub" in
        restrict)
            elevate wake restrict
            wake_restrict
            WAKE=power-button-lid; save_state
            echo "SUCCESS: only the power button and the lid can wake this machine (mem_sleep=$(mem_sleep_cur))."
            echo "         Undo with: power wake allow"
            ;;
        allow)
            elevate wake allow
            wake_allow
            WAKE=all; save_state
            echo "SUCCESS: all wake sources re-enabled."
            ;;
        "")
            local ms ms_note
            ms=$(mem_sleep_cur)
            case "$ms" in
                s2idle) ms_note="modern standby — what this firmware implements" ;;
                deep)   ms_note="legacy S3 — HANGS this machine on entry; see doc/screen-locking.md" ;;
                *)      ms_note="kernel/firmware default" ;;
            esac
            echo "${BOLD}Wake sources${NC}"
            echo "  Suspend mode  : mem_sleep=${ms:-?} ${DIM}(${ms_note})${NC}"
            echo "  Policy        : $WAKE"
            echo "  sysfs enabled : $(wake_enabled_count) source(s)"
            if [ -r /proc/acpi/wakeup ]; then
                echo "  ACPI enabled  :"
                awk 'NR>1 && $3 ~ /\*enabled/ {printf "                  %s\n", $1}' /proc/acpi/wakeup 2>/dev/null
            fi
            echo "  ${DIM}change: power wake restrict|allow · power set sleep s2idle|deep${NC}"
            ;;
        *) die "unknown wake subcommand '$sub' (restrict|allow)" ;;
    esac
}

# ── X / display timeout ───────────────────────────────────────────────
apply_xset_blank() {
    local d=${POWER_DISPLAY:-$DISPLAY} a=${POWER_XAUTHORITY:-$XAUTHORITY} secs
    secs=$((BLANK_MINUTES * 60))
    if [ -z "$d" ]; then
        echo "  ${DIM}(no DISPLAY — saved for the next X session)${NC}"
        return 0
    fi
    if [ "$BLANK_MINUTES" -gt 0 ]; then
        DISPLAY="$d" XAUTHORITY="$a" xset s "$secs" "$secs" >/dev/null 2>&1 || warn "xset s failed"
        DISPLAY="$d" XAUTHORITY="$a" xset +dpms >/dev/null 2>&1 || true
        DISPLAY="$d" XAUTHORITY="$a" xset dpms "$secs" $((secs * 2)) $((secs * 4)) >/dev/null 2>&1 || warn "xset dpms failed"
    else
        DISPLAY="$d" XAUTHORITY="$a" xset s 0 0 >/dev/null 2>&1 || true
        DISPLAY="$d" XAUTHORITY="$a" xset dpms 0 0 0 >/dev/null 2>&1 || true
    fi
}

# ── Apply / boot ──────────────────────────────────────────────────────
cmd_apply() {
    local src prof brt
    if ac_online; then src="AC"; prof=$AC_PROFILE; else src="battery"; prof=$BATTERY_PROFILE; fi
    if [ "$AUTO" != "on" ]; then
        hook_log "auto off — left policy alone (source=$src)"
        return 0
    fi
    apply_cpu_profile "$prof"
    # Brightness is only touched while BRIGHTNESS_MODE=auto; a manual change
    # (brightness keys, 'power set brightness') wins and is left alone.
    if [ "$src" = "AC" ]; then
        restore_brightness
    else
        cap_brightness_pct "$(profile_brightness "$prof")"
    fi
    brt=$(brightness_pct 2>/dev/null || echo '?')
    hook_log "auto: source=$src profile=$prof governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) turbo=$(turbo_state 2>/dev/null) backlight=${brt}% brightness_mode=${BRIGHTNESS_MODE:-auto}"
}

cmd_boot() {
    cmd_apply
    if [ "$WAKE" = "power-button-lid" ]; then
        wake_restrict
    fi
}

# ── Status ────────────────────────────────────────────────────────────
cmd_status() {
    local b pct st watts avg left leftnote draw gov epp turbo brt blname msleep wenabled lid
    local sleep_note
    local mode_src mode_prof mode_line

    b=$(battery_dir)
    if [ -n "$b" ]; then
        pct=$(cat "$b/capacity" 2>/dev/null)
        st=$(cat "$b/status" 2>/dev/null)
        watts=$(bat_watts 2>/dev/null)
        avg=$(bat_rate_avg_w 2>/dev/null)          # rolling average, may be empty
        left=$(bat_time_left "$avg" 2>/dev/null)
    fi

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
    turbo=$(turbo_state 2>/dev/null)
    brt=$(brightness_pct 2>/dev/null)
    blname=$(backlight_dir 2>/dev/null); blname=${blname##*/}
    msleep=$(mem_sleep_cur)
    wenabled=$(wake_enabled_count)
    # Lid policy is elogind's now (steps/screen-locking.sh); the old acpid
    # poweroff handler is gone, so read the logind drop-in instead.
    lid=$(grep -h '^HandleLidSwitch=' /etc/elogind/logind.conf.d/*.conf 2>/dev/null \
          | tail -1 | cut -d= -f2)

    # Top line: the one thing you want at a glance.
    if ac_online; then
        mode_src="${GREEN}AC${NC}"; mode_prof=$AC_PROFILE
    else
        mode_src="${RED}battery${NC}"; mode_prof=$BATTERY_PROFILE
    fi
    if [ "$AUTO" = on ]; then
        mode_line="${mode_src} · ${BOLD}${mode_prof}${NC}"
    else
        mode_line="${mode_src} · ${YELLOW}auto off${NC} (governor ${gov:-?})"
    fi
    echo "${BOLD}Power mode:${NC} ${mode_line}"
    echo
    if [ -n "$pct" ]; then
        [ -n "$watts" ] && draw="${watts} W now"
        if [ -n "$avg" ]; then
            draw="${draw:+$draw · }avg ${avg} W/$(rate_window_label)"
        elif [ -n "$left" ]; then
            leftnote=" (instant)"
        fi
        printf '  %-13s %s%% %s%s%s%s\n' "Battery" "$pct" "$st" \
            "${draw:+ · $draw}" "${left:+ · ~$left left}" "$leftnote"
    else
        printf '  %-13s %s\n' "Battery" "(none detected)"
    fi
    printf '  %-13s auto=%s   battery:%s   ac:%s\n' "Auto mode" \
        "$([ "$AUTO" = on ] && echo "${GREEN}on${NC}" || echo "${YELLOW}off${NC}")" \
        "$BATTERY_PROFILE" "$AC_PROFILE"
    printf '  %-13s %s  governor=%s  epp=%s  turbo=%s\n' "CPU" \
        "$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver 2>/dev/null)" "$gov" "$epp" "$turbo"
    printf '  %-13s %s%%%s\n' "Backlight" "${brt:-?}" \
        "${blname:+ $blname · }$([ "${BRIGHTNESS_MODE:-auto}" = manual ] && echo 'manual — policy will not change it' || echo 'auto')"
    printf '  %-13s blank after %s min; DPMS %s/%s/%s min\n' "Display" \
        "$BLANK_MINUTES" "$BLANK_MINUTES" "$((BLANK_MINUTES * 2))" "$((BLANK_MINUTES * 4))"
    case "$msleep" in
        s2idle) sleep_note="s2idle (modern standby)" ;;
        deep)   sleep_note="deep (legacy S3 — hangs here, see doc/screen-locking.md)" ;;
        *)      sleep_note="${msleep:-?}" ;;
    esac
    printf '  %-13s %s; wake=%s (%s)\n' "Sleep" \
        "$sleep_note" "$WAKE" \
        "$([ "$wenabled" -eq 0 ] 2>/dev/null && echo 'power button only — ACPI fixed event, nothing else' || echo "$wenabled sysfs source(s) enabled")"
    printf '  %-13s %s\n' "Lid" \
        "lid close → ${lid:-suspend} (elogind); wakes on lid open + power button"
    echo
    echo "${DIM}  change: power profile powersave|balanced|performance  ·  power menu${NC}"
}

# ── One-line battery summary (fastfetch, status bars) ────────────────
# Same numbers as `power status`: capacity, plus the time-left estimate from
# the rolling discharge average (rolling average of upower history, with the
# live sysfs reading folded in; instant power_now only as a fallback).
# Prints nothing at all when there is no battery, so a caller can drop the
# whole line instead of showing an empty key. No ANSI escapes — this is data.
cmd_battery_line() {
    local b pct st avg left out
    b=$(battery_dir 2>/dev/null) || return 0
    pct=$(cat "$b/capacity" 2>/dev/null)
    st=$(cat "$b/status" 2>/dev/null)
    [ -n "$pct" ] || return 0
    case "$st" in
        Charging) echo "${pct}% · charging"; return 0 ;;
        Full)     echo "${pct}% · full";     return 0 ;;
    esac
    avg=$(bat_rate_avg_w 2>/dev/null)          # rolling average, may be empty
    left=$(bat_time_left "$avg" 2>/dev/null)
    out="${pct}%"
    [ -n "$avg" ] && out="$out · avg ${avg} W/$(rate_window_label)"
    [ -n "$left" ] && out="$out · ~${left} left"
    # Plugged in but not charging (charge threshold, battery care mode, ...).
    ac_online && out="$out · on AC"
    echo "$out"
}

# ── Interactive menu ──────────────────────────────────────────────────
cmd_menu() {
    local c
    while true; do
        echo
        echo "${BOLD}*****************************************************${NC}"
        echo "${BOLD}POWER — battery policy${NC}"
        echo "${BOLD}*****************************************************${NC}"
        cmd_status
        echo
        echo "  1) powersave profile (now)"
        echo "  2) balanced profile (now)"
        echo "  3) performance profile (now)"
        echo "  4) toggle auto mode (currently: $AUTO)"
        echo "  5) battery profile (currently: $BATTERY_PROFILE)"
        echo "  6) AC profile (currently: $AC_PROFILE)"
        echo "  7) set backlight % (now)"
        echo "  8) set screen blank minutes (currently: $BLANK_MINUTES)"
        echo "  9) wake sources: $WAKE (power button + lid / allow all)"
        echo " 10) time-left averaging window (currently: $(rate_window_label))"
        echo "  r) re-apply policy for current power source"
        echo "  q) quit"
        read -r -p "Choice: " c || return 0
        case "$c" in
            1|2|3)
                local p; case "$c" in 1) p=powersave ;; 2) p=balanced ;; 3) p=performance ;; esac
                cmd_profile "$p"
                ;;
            4)
                if [ "$AUTO" = on ]; then cmd_auto off; else cmd_auto on; fi
                ;;
            5)
                read -r -p "Battery profile (powersave|balanced|performance): " p
                cmd_auto battery "$p"
                ;;
            6)
                read -r -p "AC profile (powersave|balanced|performance): " p
                cmd_auto ac "$p"
                ;;
            7)
                read -r -p "Backlight percent (1-100): " p
                cmd_set brightness "$p"
                ;;
            8)
                read -r -p "Blank after N minutes (0 = never): " p
                cmd_set blank "$p"
                ;;
            9)
                if [ "$WAKE" = power-button-lid ]; then cmd_wake allow; else cmd_wake restrict; fi
                ;;
            10)
                read -r -p "Average battery draw over N seconds (60-1800): " p
                cmd_set avg "$p"
                ;;
            r) cmd_apply ;;
            q|Q|x|X) return 0 ;;
            *) echo "Invalid choice." ;;
        esac
    done
}

# ── Change commands ───────────────────────────────────────────────────
cmd_profile() {
    local prof=${1:-} src
    [ -n "$prof" ] || { echo "current: battery=$BATTERY_PROFILE ac=$AC_PROFILE"; return 0; }
    valid_profile "$prof" || die "unknown profile '$prof' (powersave|balanced|performance)"
    elevate profile "$prof"
    # An explicit profile request is the user taking control back: apply it and
    # store it for the current power source so auto mode will not undo it.
    if ac_online; then AC_PROFILE=$prof; src="ac"; else BATTERY_PROFILE=$prof; src="battery"; fi
    BRIGHTNESS_MODE=auto
    rm -f "$SAVED_BRIGHTNESS" 2>/dev/null || true
    apply_cpu_profile "$prof"
    set_brightness_pct "$(profile_brightness "$prof")" || true
    save_state
    echo "SUCCESS: profile '$prof' applied and remembered as the $src profile — governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null) turbo=$(turbo_state 2>/dev/null) backlight=$(brightness_pct 2>/dev/null)% (auto)"
}

cmd_set() {
    local what=${1:-} val=${2:-}
    [ -n "$what" ] && [ -n "$val" ] || die "usage: power set governor|epp|turbo|brightness|blank|avg|sleep <value>"
    elevate set "$what" "$val"
    case "$what" in
        governor)
            case "$val" in performance|powersave) ;; *) die "governor must be performance or powersave" ;; esac
            set_governor "$val"
            echo "SUCCESS: governor=$val on all CPUs."
            ;;
        epp)
            set_epp "$val" || die "EPP '$val' not supported (available: $(epp_available))"
            echo "SUCCESS: energy_performance_preference=$val."
            ;;
        turbo)
            case "$val" in on|off) ;; *) die "turbo must be on or off" ;; esac
            set_turbo "$val" || die "turbo control not available (no intel_pstate/no_turbo)"
            echo "SUCCESS: turbo=$val."
            ;;
        brightness)
            case "$val" in *[!0-9]*|'') die "brightness must be 1-100" ;; esac
            set_brightness_pct "$val" || exit 1
            # The user picked this value: keep it, do not let the policy cap it.
            BRIGHTNESS_MODE=manual; policy_bl_forget
            rm -f "$SAVED_BRIGHTNESS" 2>/dev/null || true
            save_state
            echo "SUCCESS: backlight=$(brightness_pct)% (manual — the policy will not change it; 'power profile ...' hands it back)"
            ;;
        blank)
            case "$val" in *[!0-9]*|'') die "blank must be a number of minutes (0 = never)" ;; esac
            BLANK_MINUTES=$val; save_state
            apply_xset_blank
            echo "SUCCESS: screen blank after ${BLANK_MINUTES} min (persists across X restarts)."
            ;;
        avg)
            case "$val" in *[!0-9]*|'') die "avg must be a number of seconds (60-1800)" ;; esac
            [ "$val" -ge 60 ] && [ "$val" -le 1800 ] || die "avg must be 60-1800 seconds"
            RATE_WINDOW=$val; save_state
            echo "SUCCESS: time-left estimate averages the last $(rate_window_label) of battery draw."
            ;;
        sleep)
            case "$val" in
                s2idle|deep) ;;
                *) die "sleep state must be s2idle (modern standby) or deep (legacy S3)" ;;
            esac
            set_mem_sleep "$val" || die "cannot select mem_sleep=$val (available: $(cat /sys/power/mem_sleep 2>/dev/null))"
            echo "SUCCESS: mem_sleep=$val — used by the next suspend (lid close and wake)."
            [ "$val" = deep ] && echo "         WARNING: deep/S3 is the state that never returned on this machine."
            ;;
        *)
            die "unknown setting '$what' (governor|epp|turbo|brightness|blank|avg|sleep)"
            ;;
    esac
}

cmd_auto() {
    local sub=${1:-} val=${2:-}
    case "$sub" in
        "")
            echo "auto mode: $AUTO"
            echo "  battery profile : $BATTERY_PROFILE"
            echo "  ac profile      : $AC_PROFILE"
            echo "  (toggle: power auto on|off; set: power auto battery|ac <profile>)"
            ;;
        on|off)
            elevate auto "$sub"
            AUTO=$sub; save_state
            echo "SUCCESS: auto mode $AUTO."
            [ "$AUTO" = on ] && cmd_apply
            ;;
        battery|ac)
            [ -n "$val" ] || die "usage: power auto $sub <powersave|balanced|performance>"
            valid_profile "$val" || die "unknown profile '$val'"
            elevate auto "$sub" "$val"
            if [ "$sub" = battery ]; then BATTERY_PROFILE=$val; else AC_PROFILE=$val; fi
            save_state
            echo "SUCCESS: $sub profile = $val."
            [ "$AUTO" = on ] && cmd_apply
            ;;
        *) die "usage: power auto [on|off|battery <profile>|ac <profile>]" ;;
    esac
}

usage() {
    # header comment block only (stops at the first non-comment line)
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

# ── Main ──────────────────────────────────────────────────────────────
load_state
# POWER_AVG_WINDOW=SECONDS overrides the stored averaging window for one run
[ -n "${POWER_AVG_WINDOW:-}" ] && RATE_WINDOW=$POWER_AVG_WINDOW
case "${RATE_WINDOW:-120}" in ''|*[!0-9]*) RATE_WINDOW=120 ;; esac

case "${1:-}" in
    _battery)
        # internal, called by fastfetch's command module: one compact line,
        # read-only and unprivileged (no logging, no elevation, no sampling)
        cmd_battery_line
        ;;
    _rates)
        # internal, called through sudo by cmd_status: dump upower's rate history
        cat "$(rate_history_file)" 2>/dev/null
        ;;
    "")
        setup_cli_log
        cmd_status
        ;;
    set)
        elevate set "${2:-}" "${3:-}"
        setup_cli_log
        cmd_set "${2:-}" "${3:-}"
        ;;
    profile)
        elevate profile "${2:-}"
        setup_cli_log
        cmd_profile "${2:-}"
        ;;
    auto)
        elevate auto "${2:-}" "${3:-}"
        setup_cli_log
        cmd_auto "${2:-}" "${3:-}"
        ;;
    wake)
        if [ -n "${2:-}" ]; then elevate wake "$2"; else setup_cli_log; fi
        cmd_wake "${2:-}"
        ;;
    apply)
        # hook mode: no per-run log file, append to one shared log
        cmd_apply
        ;;
    boot)
        cmd_boot
        ;;
    menu)
        elevate menu
        setup_cli_log
        cmd_menu
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "ERROR: unknown command '$1'" >&2
        echo >&2
        usage >&2
        exit 1
        ;;
esac
