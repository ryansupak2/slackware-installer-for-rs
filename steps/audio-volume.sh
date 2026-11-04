#!/bin/bash
# steps/audio-volume.sh - AUDIO/VOLUME (Slackware: PipeWire via ALSA)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "AUDIO/VOLUME"
echo "*****************************************************"

ok=true

# ALSA is always present on Slackware base
if ! install_pkg "alsa-utils"; then ok=false; fi

# The SOF firmware IS present on this system (see /lib/firmware/intel/sof/).
# Do NOT force legacy HDA — the internal DMIC requires the SOF DSP driver.
#
# However, SOF firmware can fail to load on cold boot due to a firmware-loader
# race (the driver probes before the rootfs is fully settled). Including the SOF
# module + firmware in the initrd ensures it's available at probe time.
if [ -f "$ELILO_CONF" ]; then
    sed -i 's/ snd-intel-dspcfg.dsp_driver=[0-9]//g' "$ELILO_CONF"
    echo "  Removed any snd-intel-dspcfg.dsp_driver override from elilo"
fi

# Add audio group
addgroup audio 2>/dev/null || true
usermod -aG audio root 2>/dev/null || true

# Hardware unmute + boot persistence lives in its own idempotent step:
#   steps/audio-mixer.sh  ->  /usr/local/bin/audio-mixer-fix
# It uses NAMED controls (never numids) because numids differ per card/driver
# on SOF/SoundWire hardware: the legacy HDA ids that used to be here
# (9/10/3/4) matched nothing on the cs42l43/CS35L56 card, and dwm-start's
# 'numid=1 0,0 / numid=2 off,off' accidentally muted the internal speaker.
# It also makes /etc/rc.d/rc.alsa executable — rc.M only restores the saved
# mixer state when that file is executable, and it ships 0644 on a fresh
# Slackware install, so the card used to boot at driver defaults (silent).
if [ -x "$REPO_DIR/steps/audio-mixer.sh" ] || [ -f "$REPO_DIR/steps/audio-mixer.sh" ]; then
    bash "$REPO_DIR/steps/audio-mixer.sh" || ok=false
else
    echo "  WARNING: steps/audio-mixer.sh missing — mixer left untouched"
    ok=false
fi

# Disable PulseAudio autospawn (PipeWire handles audio instead)
if [ -f /etc/pulse/client.conf ]; then
    sed -i 's/^autospawn = yes/autospawn = no/' /etc/pulse/client.conf
    sed -i 's/^; *autospawn = .*/autospawn = no/' /etc/pulse/client.conf
    echo "  PulseAudio autospawn disabled"
fi

# PipeWire configuration — NEVER edit it by line number.
# The old code here did `sed -i '177s/^    #//'` to "enable the ALSA backend".
# Line 178 of pipewire.conf is prose inside context.modules, so that sed
# turned a comment into the bare line `     The portal module monitors the PID
# of the portal process`, which SPA-JSON cannot parse. PipeWire then reported
#   pw.conf | malformed object array in '[ ...
# and loaded ZERO modules — the daemons all appeared to run, sockets existed,
# yet every client either hung or got ECONNREFUSED. That is a second, separate
# cause of "no sound".
#
# Nothing needs enabling: since PipeWire 0.3.6x, ALSA devices are created by
# the session manager (wireplumber), not by a spa-device-factory object in
# pipewire.conf. So keep the packaged default and just make sure it parses.
PW_STOCK=/usr/share/pipewire/pipewire.conf
PW_LOCAL=/etc/pipewire/pipewire.conf
if [ -f "$PW_STOCK" ]; then
    mkdir -p /etc/pipewire
    if [ ! -f "$PW_LOCAL" ] || ! cmp -s "$PW_STOCK" "$PW_LOCAL"; then
        cp "$PW_STOCK" "$PW_LOCAL"
        echo "  pipewire.conf restored from the packaged default"
    else
        echo "  pipewire.conf already matches the packaged default"
    fi
    if command -v pw-config >/dev/null 2>&1; then
        if timeout 15 pw-config -n pipewire.conf list 2>/dev/null | grep -q '"context.modules"'; then
            echo "  pipewire.conf parses (context.modules present)"
        else
            echo "  ERROR: pipewire.conf does not parse — clients cannot connect"
            ok=false
        fi
    fi
fi

# ── Rebuild initrd with SOF audio for cold-boot reliability ──────
# The SOF driver needs firmware at probe time. On some boots the firmware
# loader races with rootfs availability and fails (ENOENT). Including the
# module + firmware in the initrd fixes this permanently.
SOF_MOD="snd_sof_pci_intel_cnl"
INITRD_IMG="/boot/initrd.gz"
CMDLINE_FILE="/boot/initrd-tree/command_line"
if [ -d "/lib/firmware/intel/sof" ] && [ -f "/lib/firmware/intel/sof/sof-cnl.ri" ]; then
    if ! zcat "$INITRD_IMG" 2>/dev/null | cpio -t 2>/dev/null | grep -q 'sof.*\.ri'; then
        echo "Rebuilding initrd with SOF audio firmware for cold-boot reliability..."
        if [ -f "$CMDLINE_FILE" ]; then
            PREV_CMD=$(cat "$CMDLINE_FILE")
            if echo "$PREV_CMD" | grep -q -- '-m '; then
                # Strip any prior SOF_MOD from the list to avoid doubling up
                CLEAN_CMD=$(echo "$PREV_CMD" | sed "s/:${SOF_MOD}//g")
                NEW_CMD=$(echo "$CLEAN_CMD" | sed "s/-m [^ ]\+/&:${SOF_MOD}/")
            else
                NEW_CMD="$PREV_CMD -m ${SOF_MOD}"
            fi
            echo "  Running: $NEW_CMD"
            # SOF modules don't declare firmware via modinfo (the firmware
            # name is built dynamically at runtime). Manually copy firmware
            # into the initrd-tree and repack so it's available at cold-boot
            # probe time.
            if [ -d "/boot/initrd-tree" ]; then
                mkdir -p /boot/initrd-tree/lib/firmware/intel/sof
                mkdir -p /boot/initrd-tree/lib/firmware/intel/sof-tplg
                cp -a /lib/firmware/intel/sof/sof-cnl.ri /boot/initrd-tree/lib/firmware/intel/sof/ 2>/dev/null || true
                cp -a /lib/firmware/intel/sof-tplg/sof-hda-generic-2ch.tplg /boot/initrd-tree/lib/firmware/intel/sof-tplg/ 2>/dev/null || true
                # Also copy cml and cfl symlinks (Comet Lake uses sof-cml.ri)
                for f in sof-cml.ri sof-cfl.ri; do
                    if [ -L "/lib/firmware/intel/sof/$f" ]; then
                        TGT=$(readlink "/lib/firmware/intel/sof/$f")
                        ln -sf "$TGT" "/boot/initrd-tree/lib/firmware/intel/sof/$f" 2>/dev/null || true
                    fi
                done
                echo "  Repacking initrd with SOF firmware..."
                /sbin/mkinitrd 2>/dev/null || echo "  WARNING: initrd repack failed"
            fi
        else
            echo "  WARNING: no command_line file — skipping initrd rebuild"
        fi
    else
        echo "  SOF firmware already in initrd."
    fi
else
    echo "  SOF firmware not found — skipping initrd rebuild."
fi

# Force duplex capture profile (jack detection may report mic as unavailable)
echo "Enabling audio capture profile..."
CARD_ID=$(pactl list cards short 2>/dev/null | grep alsa | head -1 | awk '{print $1}')
if [ -n "$CARD_ID" ]; then
    pactl set-card-profile "$CARD_ID" output:analog-stereo+input:analog-stereo 2>/dev/null || \
    pactl set-card-profile "$CARD_ID" output:analog-stereo+input:iec958-stereo 2>/dev/null || \
    echo "  Capture profile set on card $CARD_ID"
else
    echo "  WARNING: No ALSA card found — capture may not work."
fi

# Deploy volume scripts
cp "$REPO_DIR/dotfiles/volume/volume_up.sh"    /usr/local/bin/volume_up.sh 2>/dev/null || true
cp "$REPO_DIR/dotfiles/volume/volume_down.sh"  /usr/local/bin/volume_down.sh 2>/dev/null || true
cp "$REPO_DIR/dotfiles/volume/volume_mute.sh"  /usr/local/bin/volume_mute.sh 2>/dev/null || true
chmod +x /usr/local/bin/volume_up.sh /usr/local/bin/volume_down.sh /usr/local/bin/volume_mute.sh 2>/dev/null || true

cp "$REPO_DIR/scripts/mic-test.sh" /usr/local/bin/mic-test 2>/dev/null || true
chmod +x /usr/local/bin/mic-test 2>/dev/null || true

# XDG profile
mkdir -p /etc/profile.d
cp "$REPO_DIR/dotfiles/system/xdg.sh" /etc/profile.d/xdg.sh 2>/dev/null || true
chmod 644 /etc/profile.d/xdg.sh 2>/dev/null || true

if $ok; then
    echo "SUCCESS: Audio/volume configured (PipeWire)."
    exit 0
else
    echo "ERROR: Audio/volume setup had issues."
    exit 1
fi
