#!/bin/bash
# steps/gpu-display.sh - INTEL xe DISPLAY PARAMETERS (profiles)
#
# Context and evidence: doc/display-freeze.md. Short version, all measured on
# this box (Wildcat Lake, GPU bound to the **xe** driver, eDP 2560x1600@120):
#
#   * Fullscreen hi-res video in Chrome, usually at playback start, sometimes
#     wedges the display: picture frozen, no cursor, keyboard dead, audio
#     continues. The kernel logs, at every such event:
#         xe 0000:00:02.0: [drm] *ERROR* [CRTC:151:pipe A] flip_done timed out
#         xe 0000:00:02.0: [drm] *ERROR* commit wait timed out
#         xe 0000:00:02.0: [drm] *ERROR* [PLANE:35:plane 1A] commit wait timed out
#   * At boot, on the same pipe:
#         xe 0000:00:02.0: [drm] Selective fetch area calculation failed in pipe A
#   * `i915.enable_psr=0` (already in the cmdline, for the older XPS 13) is
#     INERT here: this GPU binds to xe, whose enable_psr was still -1 (= on).
#
# This step is therefore NOT here to disable the power feature. Its default
# profile is `stock` — it changes nothing. The other profiles exist as
# fallbacks, to be applied deliberately after the collector below has named the
# wait that hangs (see doc/display-freeze.md).
#
#   stock  (default)  no xe overrides; kernel defaults, PSR2 on. Doing nothing,
#                     on purpose: PSR/panel self-refresh is a power feature and
#                     is not disabled on a guess.
#   psr1              keep panel self-refresh (PSR1) — where the power saving
#                     actually is — and drop only PSR2 / Panel Replay +
#                     selective fetch, the path that failed here at boot.
#                     Selective fetch only helps partial-damage frames, so the
#                     self-refresh saving survives without it.
#   off               disable PSR entirely (last resort).
#
# Usage:
#   REPO_DIR=$PWD bash steps/gpu-display.sh            # -> stock (no change)
#   REPO_DIR=$PWD bash steps/gpu-display.sh psr1
#   REPO_DIR=$PWD bash steps/gpu-display.sh off
#   EXTRA="xe.enable_fbc=0" ... bash steps/gpu-display.sh stock   # add a knob
#
# Idempotent: the managed knobs are stripped and re-written in one pass, so
# repeated runs converge and switching profiles never accumulates parameters.
# A timestamped backup is kept for every actual change. Takes effect on reboot.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

PROFILE="${1:-stock}"
[ "$PROFILE" = "--help" ] && { sed -n '2,40p' "$0"; exit 0; }

echo "*****************************************************"
echo "GPU / DISPLAY (Intel xe profile: $PROFILE)"
echo "*****************************************************"

ok=true

# --- profile -> kernel parameters ------------------------------------------
case "$PROFILE" in
    psr1)
        # xe.enable_dsb=0 is the important one: measured 2026-11-09 on this box,
# `[CRTC:151:pipe A] DSB 0 response timeout` repeats ~250 times at X start and
# the commit worker parks in drm_atomic_helper_wait_for_flip_done ->
# intel_atomic_commit_tail (captured at the time by display-hang-catcher,
# retired since — see doc/display-freeze.md). DSB is the
# hardware display-state-buffer engine; turning it off makes the driver program
# display registers from the CPU instead. That is the freeze mechanism.
TOKENS="xe.enable_dsb=0 xe.enable_psr=1 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
        DESC="panel self-refresh ON, selective fetch / Panel Replay OFF"
        ;;
    off)
        TOKENS="xe.enable_dsb=0 xe.enable_psr=0 xe.enable_psr2_sel_fetch=0 xe.enable_panel_replay=0"
        DESC="PSR fully OFF"
        ;;
    stock)
        TOKENS=""
        DESC="no xe overrides (kernel defaults: PSR2 enabled)"
        ;;
    *)
        echo "ERROR: unknown profile '$PROFILE' (use: stock | psr1 | off)"
        exit 1
        ;;
esac
TOKENS="${TOKENS}${EXTRA:+ $EXTRA}"
echo "  profile: $DESC"
[ -n "$TOKENS" ] && echo "  tokens:  $TOKENS"

# Knobs this step owns. Anything else on the cmdline (i915.*, pcie_aspm, ...)
# is preserved verbatim.
MANAGED_RE='^xe\.(enable_psr|enable_psr2_sel_fetch|enable_panel_replay|psr_safest_params|enable_fbc|enable_dsb|enable_dpt|enable_ips)='

strip_managed() {   # $1 = cmdline value -> value without the knobs we manage
    local out="" w
    for w in $1; do
        [[ $w =~ $MANAGED_RE ]] && continue
        out="${out:+$out }$w"
    done
    printf '%s' "$out"
}

rewrite_file() {    # $1=file  $2=line-prefix-regex  $3=key  $4=new value
    local file=$1 re=$2 key=$3 newval=$4
    cp -a "$file" "$file.bak-$(date +%Y%m%d-%H%M%S)" || return 1
    awk -v v="$newval" -v key="$key" '
        $0 ~ "^[[:space:]]*" key "=\"" {
            sub(key "=\"[^\"]*\"", key "=\"" v "\"")
            print; next
        }
        { print }
    ' "$file" > "$file.new" && mv "$file.new" "$file"
}

current_value() {   # $1=file $2=key -> the quoted value
    sed -n "s/^[[:space:]]*$2=\"\([^\"]*\)\".*/\1/p" "$1" | head -1
}

apply_to() {        # $1=file $2=key $3=label
    local file=$1 key=$2 label=$3 cur new
    cur=$(current_value "$file" "$key")
    if [ -z "$cur" ]; then
        echo "  ERROR: no $key=\"...\" line in $file — not touching it"
        ok=false
        return 1
    fi
    new=$(strip_managed "$cur")
    new="${new}${TOKENS:+ $TOKENS}"
    if [ "$cur" = "$new" ]; then
        echo "  $label: already '$new'"
    else
        if rewrite_file "$file" "append" "$key" "$new"; then
            echo "  $label: set to '$new'"
        else
            echo "  ERROR: could not rewrite $file"
            ok=false
            return 1
        fi
    fi
    # Verify by re-reading, never by trusting the edit.
    local check
    check=$(current_value "$file" "$key")
    [ "$check" = "$new" ] || { echo "  ERROR: read-back mismatch in $file"; ok=false; }
}

ELILO_PATH="/boot/efi/EFI/Slackware/elilo.conf"
GRUB_DEFAULT="/etc/default/grub"

if [ -f "$ELILO_PATH" ]; then
    apply_to "$ELILO_PATH" append elilo
    echo "  cmdline:"
    grep -o 'append=.*' "$ELILO_PATH" | sed 's/^/    /'
elif [ -f "$GRUB_DEFAULT" ]; then
    apply_to "$GRUB_DEFAULT" GRUB_CMDLINE_LINUX_DEFAULT grub
    grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1 || true
    check=$(grep -o 'GRUB_CMDLINE_LINUX_DEFAULT=.*' "$GRUB_DEFAULT")
    echo "  grub: $check"
else
    echo "  WARNING: neither $ELILO_PATH nor $GRUB_DEFAULT found — nothing to do"
    ok=false
fi

# Running state: these are load-time module parameters, so this prints what is
# in force NOW (after a reboot it should match the profile above).
if [ -d /sys/module/xe/parameters ]; then
    echo "  running kernel (load-time values, changes apply on reboot):"
    for p in enable_psr enable_psr2_sel_fetch enable_panel_replay psr_safest_params \
             enable_fbc enable_dsb enable_dpt enable_ips; do
        [ -r "/sys/module/xe/parameters/$p" ] && \
            printf '    %-24s %s\n' "$p" "$(cat "/sys/module/xe/parameters/$p")"
    done
else
    echo "  running kernel: no xe driver — parameters are inert on this machine"
fi

if $ok; then
    echo "SUCCESS: xe display profile '$PROFILE' written (takes effect on next boot)."
    exit 0
else
    echo "ERROR: display parameters incomplete (see messages above)."
    exit 1
fi
