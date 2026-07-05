#!/bin/bash
# steps/audio-volume.sh - AUDIO/VOLUME (Slackware: PipeWire via ALSA)

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "AUDIO/VOLUME"
echo "*****************************************************"

# ALSA is always present on Slackware base
install_pkg "alsa-utils"

# Force legacy HDA driver on Intel Skylake+ (SOF firmware not in base Slackware)
ELILO_CONF="/boot/efi/EFI/Slackware/elilo.conf"
if [ -f "$ELILO_CONF" ] && ! grep -q "snd-intel-dspcfg.dsp_driver" "$ELILO_CONF" 2>/dev/null; then
    sed -i 's/append="\(.*\)"/append="\1 snd-intel-dspcfg.dsp_driver=1"/' "$ELILO_CONF"
    echo "  Added snd-intel-dspcfg.dsp_driver=1 to elilo"
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
