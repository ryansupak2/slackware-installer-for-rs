#!/bin/sh
# audio-mixer-fix — put the ALSA mixer into a usable state, idempotently.
#
# Used by steps/audio-mixer.sh (install time) and by dwm-start (session time).
#
# Why this exists:
#   1. On SOF/SoundWire hardware (Dell XPS 13: cs42l43 codec + 2x CS35L56 amps)
#      the legacy HDA numids used by older versions of this installer
#      (numid=1..10 "Master/Speaker/Headphone") point at completely different
#      controls. `numid=1 0,0` / `numid=2 off,off` — which older dwm-start used
#      to force headphone muting — actually muted the internal speaker's
#      Playback Switch + Volume, so the machine came up silent every session.
#   2. /etc/rc.d/rc.alsa ships mode 0644 on a fresh install. rc.M only calls it
#      when it is executable, so the saved mixer state was never restored at
#      boot and the card came up at driver defaults (Speaker off, volume 0).
#
# Everything here uses NAMED controls and is safe to run repeatedly.

set -u

CARD="${AUDIO_CARD:-0}"

# ---- 1. Save/restore plumbing (once per boot) ----
# rc.alsa must be executable or rc.M silently skips restoring the mixer.
if [ -f /etc/rc.d/rc.alsa ] && [ ! -x /etc/rc.d/rc.alsa ]; then
    chmod +x /etc/rc.d/rc.alsa 2>/dev/null || true
fi

# ---- 2. Unmute the speaker path ----
# 'Speaker' is the aggregated kcontrol: it drives AMPL/AMPR (CS35L56 amps) and
# cs42l43 Speaker Digital in one go. Level 76% ≈ -23.75 dB (limit is 0-400).
amixer -c "$CARD" sset 'Speaker' 76% unmute           >/dev/null 2>&1 || true
amixer -c "$CARD" sset 'AMPL Speaker' 76% unmute      >/dev/null 2>&1 || true
amixer -c "$CARD" sset 'AMPR Speaker' 76% unmute      >/dev/null 2>&1 || true
amixer -c "$CARD" sset 'cs42l43 Speaker Digital' on   >/dev/null 2>&1 || true
amixer -c "$CARD" sset 'Headphone' 76% unmute         >/dev/null 2>&1 || true

# ---- 3. Microphone (VOX dictation) ----
# cs42l43 Microphone is 0-191; 160 ≈ -10 dB. Switch must be on ('cap').
amixer -c "$CARD" sset 'cs42l43 Microphone' 160 cap   >/dev/null 2>&1 || true

# ---- 4. Persist for the next boot ----
alsactl store >/dev/null 2>&1 || true

# ---- 5. Report ----
status=0
speaker_state=$(amixer -c "$CARD" sget 'Speaker' 2>/dev/null | tail -1)
case "$speaker_state" in
    *"[on]"*) : ;;
    *) status=1 ;;
esac
if [ -x /etc/rc.d/rc.alsa ]; then
    rcalsa="rc.alsa executable (mixer restored at boot)"
else
    rcalsa="rc.alsa NOT executable — mixer will not be restored at boot"
    status=1
fi

if [ "${AUDIO_MIXER_QUIET:-0}" != "1" ]; then
    echo "  Speaker: ${speaker_state:-<no such control>}"
    echo "  $rcalsa"
fi
exit $status
