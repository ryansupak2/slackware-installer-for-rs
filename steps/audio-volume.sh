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

# ALSA is always present on Slackware base
install_pkg "alsa-utils"

# The SOF firmware IS present on this system (see /lib/firmware/intel/sof/).
# Do NOT force legacy HDA — the internal DMIC requires the SOF DSP driver.
if [ -f "$ELILO_CONF" ]; then
    sed -i 's/ snd-intel-dspcfg.dsp_driver=[0-9]//g' "$ELILO_CONF"
    echo "  Removed any snd-intel-dspcfg.dsp_driver override from elilo"
fi

# Add audio group
addgroup audio 2>/dev/null || true
usermod -aG audio root 2>/dev/null || true

# Hardware unmute
amixer -c0 cset numid=9  87           2>/dev/null || true  # Master Playback Volume
amixer -c0 cset numid=10 on           2>/dev/null || true  # Master Playback Switch
amixer -c0 cset numid=3  87,87        2>/dev/null || true  # Speaker Playback Volume
amixer -c0 cset numid=4  on,on        2>/dev/null || true  # Speaker Playback Switch
for nid in 35 38 39 40 46 47; do
    amixer -c0 cset numid=$nid 32,32 2>/dev/null || true   # PGA gains
done

# Mic capture: max boost + max volume for VOX voice dictation
amixer -c0 cset numid=6  63,63       2>/dev/null || true  # Capture Volume
amixer -c0 cset numid=7  on,on       2>/dev/null || true  # Capture Switch
amixer -c0 cset numid=8  3,3         2>/dev/null || true  # Mic Boost Volume
alsactl store 2>/dev/null || true

# Disable PulseAudio autospawn (PipeWire handles audio instead)
if [ -f /etc/pulse/client.conf ]; then
    sed -i 's/^autospawn = yes/autospawn = no/' /etc/pulse/client.conf
    sed -i 's/^; *autospawn = .*/autospawn = no/' /etc/pulse/client.conf
    echo "  PulseAudio autospawn disabled"
fi

# Enable PipeWire ALSA backend (commented out by default on Slackware)
if [ -f /usr/share/pipewire/pipewire.conf ]; then
    mkdir -p /etc/pipewire
    if ! grep -q '^    { factory = spa-device-factory.*api.alsa.enum.udev' /etc/pipewire/pipewire.conf 2>/dev/null; then
        cp /usr/share/pipewire/pipewire.conf /etc/pipewire/pipewire.conf
        sed -i '177s/^    #/    /' /etc/pipewire/pipewire.conf
        sed -i '178s/^    #/    /' /etc/pipewire/pipewire.conf
        echo "  PipeWire ALSA backend enabled"
    else
        echo "  PipeWire ALSA backend already enabled"
    fi
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

echo "SUCCESS: Audio/volume configured (PipeWire)."
exit 0
