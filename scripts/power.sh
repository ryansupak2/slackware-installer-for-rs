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
#   power auto                  Show auto mode
#   power auto on|off           Follow AC/battery automatically (udev hook)
#   power auto battery NAME     Profile applied while unplugged
#   power auto ac NAME          Profile applied while plugged in
#   power wake                  Show wake sources + suspend mode
#   power wake restrict         Power button only (disables USB/lid/PCI wake,
#                               forces mem_sleep=deep so it is honoured)
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
WAKE=power-button-only
BLANK_MINUTES=5
BRIGHTNESS_MODE=auto

load_state() {
    # shellcheck disable=SC1090
    [ -r "$STATE_FILE" ] && . "$STATE_FILE"
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

bat_time_left() {   # "4h12m" while discharging
    local b p e
    b=$(battery_dir) || return 1
    p=$(cat "$b/power_now" 2>/dev/null); e=$(cat "$b/energy_now" 2>/dev/null)
    [ -n "$p" ] && [ -n "$e" ] || return 1
    [ "$p" -gt 0 ] 2>/dev/null || return 1
    awk -v e="$e" -v p="$p" 'BEGIN{h=e/p; hh=int(h); mm=int((h-hh)*60); printf "%dh%02dm", hh, mm}'
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
mem_sleep_cur() { sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/power/mem_sleep 2>/dev/null; }

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
            case "$dev" in PWRB|SLPB|LNXPWRBN*) continue ;; esac
            echo "$dev" >/proc/acpi/wakeup 2>/dev/null && n=$((n + 1))
        done < <(awk 'NR>1 && $3 ~ /\*enabled/ {print $1}' /proc/acpi/wakeup 2>/dev/null)
    fi
    while IFS= read -r -d '' f; do
        case "$f" in
            *LNXPWRBN*|*PWRB*) echo enabled >"$f" 2>/dev/null; continue ;;
        esac
        if [ "$(cat "$f" 2>/dev/null)" = "enabled" ] && echo disabled >"$f" 2>/dev/null; then
            d=$((d + 1))
        fi
    done < <(find /sys/devices -path '*/power/wakeup' -not -path '*/virtual/*' -print0 2>/dev/null)
    # s2idle ignores /proc/acpi/wakeup and sysfs wakeup entirely.
    if grep -q deep /sys/power/mem_sleep 2>/dev/null; then
        echo deep >/sys/power/mem_sleep 2>/dev/null || true
    fi
    hook_log "wake: power button only ($d sysfs source(s) disabled, $n ACPI toggled, mem_sleep=$(mem_sleep_cur))"
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
            WAKE=power-button-only; save_state
            echo "SUCCESS: only the power button can wake this machine (mem_sleep=$(mem_sleep_cur))."
            echo "         Undo with: power wake allow"
            ;;
        allow)
            elevate wake allow
            wake_allow
            WAKE=all; save_state
            echo "SUCCESS: all wake sources re-enabled."
            ;;
        "")
            echo "${BOLD}Wake sources${NC}"
            deep_note=$([ "$(mem_sleep_cur)" = deep ] && echo "(honours wake restrictions)" || echo "(s2idle ignores wake restrictions)")
            echo "  Suspend mode  : mem_sleep=$(mem_sleep_cur) ${DIM}${deep_note}${NC}"
            echo "  Policy        : $WAKE"
            echo "  sysfs enabled : $(wake_enabled_count) source(s)"
            if [ -r /proc/acpi/wakeup ]; then
                echo "  ACPI enabled  :"
                awk 'NR>1 && $3 ~ /\*enabled/ {printf "                  %s\n", $1}' /proc/acpi/wakeup 2>/dev/null
            fi
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
    if [ "$WAKE" = "power-button-only" ]; then
        wake_restrict
    fi
}

# ── Status ────────────────────────────────────────────────────────────
cmd_status() {
    local b pct st watts left gov epp turbo brt blname msleep wenabled lid
    local mode_src mode_prof mode_line

    b=$(battery_dir)
    if [ -n "$b" ]; then
        pct=$(cat "$b/capacity" 2>/dev/null)
        st=$(cat "$b/status" 2>/dev/null)
        watts=$(bat_watts 2>/dev/null)
        left=$(bat_time_left 2>/dev/null)
        [ -n "$watts" ] && watts="${watts} W"
    fi

    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
    epp=$(cat /sys/devices/system/cpu/cpu0/cpufreq/energy_performance_preference 2>/dev/null)
    turbo=$(turbo_state 2>/dev/null)
    brt=$(brightness_pct 2>/dev/null)
    blname=$(backlight_dir 2>/dev/null); blname=${blname##*/}
    msleep=$(mem_sleep_cur)
    wenabled=$(wake_enabled_count)
    lid=$(sed -n 's/^action=//p' /etc/acpi/events/lid-close 2>/dev/null)

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
        printf '  %-13s %s%% %s%s%s%s\n' "Battery" "$pct" "$st" \
            "${watts:+ · $watts}" "${left:+ · ~$left left}" ""
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
    printf '  %-13s mem_sleep=%s; wake=%s (%s)\n' "Sleep" \
        "$msleep" "$WAKE" \
        "$([ "$wenabled" -eq 0 ] 2>/dev/null && echo 'power button only — ACPI fixed event, nothing else' || echo "$wenabled sysfs source(s) enabled")"
    printf '  %-13s %s\n' "Lid" \
        "${lid:+close → $lid (acpid); }elogind handles lid=$([ -f /etc/elogind/logind.conf.d/10-lid-ignore.conf ] && echo ignore || echo default)"
    echo
    echo "${DIM}  change: power profile powersave|balanced|performance  ·  power menu${NC}"
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
        echo "  9) wake sources: $WAKE (restrict to power button / allow all)"
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
                if [ "$WAKE" = power-button-only ]; then cmd_wake allow; else cmd_wake restrict; fi
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
    [ -n "$what" ] && [ -n "$val" ] || die "usage: power set governor|epp|turbo|brightness|blank <value>"
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
        *)
            die "unknown setting '$what' (governor|epp|turbo|brightness|blank)"
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
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

# ── Main ──────────────────────────────────────────────────────────────
load_state

case "${1:-}" in
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
