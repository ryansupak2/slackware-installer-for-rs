#!/bin/bash
# steps/sof-firmware.sh - SOF DSP FIRMWARE + TOPOLOGY (Intel DMIC support)
#
# Slackware's kernel-firmware package includes the DSP firmware (.ri) but NOT
# the generic HDA topology file required by the real SOF driver. Without it,
# SOF fails to probe and the legacy snd_soc_skl driver hijacks the device,
# producing no sound cards at all.
#
# This step:
#   1. Blacklists snd_soc_skl (legacy driver, broken on Comet Lake+)
#   2. softdep: SOF loads before snd_hda_intel to claim the PCI device
#   3. Installs missing sof-hda-generic-2ch.tplg topology
#   4. Installs matching sof-cml.ri firmware

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/logs/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "SOF FIRMWARE + TOPOLOGY (Intel DMIC)"
echo "*****************************************************"

SOF_TGZ="/tmp/sof-bin.tar.gz"
SOF_URL="https://github.com/thesofproject/sof-bin/releases/download/v2024.09.1/sof-bin-2024.09.1.tar.gz"
TARGET_TPL="/lib/firmware/intel/sof-tplg/sof-hda-generic-2ch.tplg"
TARGET_RI="/lib/firmware/intel/sof/sof-cml.ri"
MODPROBE_CONF="/etc/modprobe.d/sof-intel.conf"
ok=true

# ── Modprobe config ─────────────────────────────────────────────────
# Blacklist the old Skylake driver, and use softdep so SOF loads before
# snd_hda_intel. This is required because snd_hda_intel claims the PCI
# device first, then defers with "using SOF driver", but the kernel does
# not auto-trigger a reprobe — SOF never gets a chance to bind.
echo "Writing modprobe config for SOF..."
cat > "$MODPROBE_CONF" << 'EOF'
# Prefer snd-sof-pci over legacy snd_soc_skl
blacklist snd_soc_skl
blacklist snd_soc_sst_ipc
blacklist snd_soc_sst_dsp

# Load SOF before snd_hda_intel so it claims the cAVS device first
softdep snd_hda_intel pre: snd-sof-pci-intel-cnl
EOF
echo "  written $MODPROBE_CONF"

# ── Firmware + topology ────────────────────────────────────────────
if [ -f "$TARGET_TPL" ] && [ -s "$TARGET_TPL" ] && \
   [ -f "$TARGET_RI" ] && [ -s "$TARGET_RI" ]; then
    echo "sof-hda-generic-2ch topology and sof-cml firmware already present."
else
    echo "Downloading SOF firmware release..."
    if curl -fsSL --connect-timeout 30 "$SOF_URL" -o "$SOF_TGZ"; then
        echo "  downloaded $(stat -c%s "$SOF_TGZ" 2>/dev/null || echo '?') bytes"
    else
        echo "ERROR: failed to download from $SOF_URL"
        ok=false
    fi

    if $ok; then
        echo "Extracting topology..."
        if tar xzf "$SOF_TGZ" -C /lib/firmware/intel/sof-tplg/ \
            --strip-components=2 \
            "sof-bin-2024.09.1/sof-tplg/sof-hda-generic-2ch.tplg" 2>/dev/null; then
            echo "  sof-hda-generic-2ch.tplg installed"
        else
            echo "  WARNING: topology extraction failed"
            ok=false
        fi

        echo "Extracting firmware..."
        if tar xzf "$SOF_TGZ" -C /lib/firmware/intel/sof/ \
            --strip-components=2 \
            "sof-bin-2024.09.1/sof/sof-cml.ri" 2>/dev/null; then
            echo "  sof-cml.ri installed"
        else
            echo "  WARNING: firmware extraction failed"
            ok=false
        fi

        rm -f "$SOF_TGZ"
    fi
fi

# ── Verify ──────────────────────────────────────────────────────────
if [ -f "$TARGET_TPL" ] && [ -s "$TARGET_TPL" ]; then
    echo "  topology: OK ($(stat -c%s "$TARGET_TPL") bytes)"
else
    echo "  topology: MISSING"
    ok=false
fi

if [ -f "$TARGET_RI" ] && [ -s "$TARGET_RI" ]; then
    echo "  firmware: OK ($(stat -c%s "$TARGET_RI") bytes)"
else
    echo "  firmware: MISSING"
    ok=false
fi

if $ok; then
    echo "SUCCESS: SOF firmware + topology installed."
    exit 0
else
    echo "ERROR: SOF firmware/topology setup failed."
    exit 1
fi
