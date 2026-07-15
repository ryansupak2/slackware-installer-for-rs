#!/bin/bash
# steps/vox-sherpa.sh — VOX voice dictation with sherpa-onnx streaming Zipformer
#
# IDEMPOTENT: safe to run multiple times. Checks for existing artifacts
# and skips work that's already done.
#
# Installs:
#   /usr/local/lib/libsherpa-onnx-c-api.so   — sherpa-onnx C API library
#   /usr/local/include/sherpa-onnx/c-api.h    — C header
#   /usr/local/share/vox/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17/ — model
#   /usr/local/bin/voxd                        — VOX daemon
#   /usr/local/bin/vox                         — CLI wrapper (symlink to script)

REPO_DIR="${REPO_DIR:-/root/Development/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "VOX SHERPA (streaming Zipformer voice dictation)"
echo "*****************************************************"

OK=true

SRC=/usr/local/src/sherpa-onnx
LIB=/usr/local/lib/libsherpa-onnx-c-api.so
HEADER=/usr/local/include/sherpa-onnx/c-api/c-api.h
MODEL_DIR=/usr/local/share/vox/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17
VOXD_BIN=/usr/local/bin/voxd
VOX_SCRIPT=/usr/local/bin/vox

# ── Sherpa-ONNX library ──────────────────────────────────────────

if [ -f "$LIB" ] && [ -f "$HEADER" ]; then
    echo "sherpa-onnx C API library already installed."
else
    echo "Building sherpa-onnx C API library..."

    install_pkg "git make gcc cmake" || OK=false
    install_pkg "alsa-lib" || OK=false

    if $OK; then
        mkdir -p /usr/local/src
        cd /usr/local/src

        if [ -d sherpa-onnx ]; then
            cd sherpa-onnx && git pull --ff-only 2>/dev/null || true
        else
            git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx
        fi || { echo "ERROR: clone/update failed"; OK=false; }

        if $OK; then
            cd /usr/local/src/sherpa-onnx
            mkdir -p build && cd build

            if [ ! -f "$LIB" ]; then
                cmake -DCMAKE_BUILD_TYPE=Release \
                      -DBUILD_SHARED_LIBS=ON \
                      -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
                      -DSHERPA_ONNX_ENABLE_TESTS=OFF \
                      -DSHERPA_ONNX_ENABLE_CHECK=OFF \
                      -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
                      .. || { echo "ERROR: cmake failed"; OK=false; }
            fi

            if $OK && [ ! -f "$LIB" ]; then
                make -j"$(nproc)" sherpa-onnx-c-api \
                    || { echo "ERROR: build failed"; OK=false; }
            fi

            if $OK; then
                cp lib/libsherpa-onnx-c-api.so /usr/local/lib/ || OK=false
                mkdir -p /usr/local/include/sherpa-onnx/c-api
                cp ../sherpa-onnx/c-api/c-api.h /usr/local/include/sherpa-onnx/c-api/ || OK=false
                # Install bundled onnxruntime too
                if [ -f "$SRC/build/_deps/onnxruntime-src/lib/libonnxruntime.so" ]; then
                    cp "$SRC/build/_deps/onnxruntime-src/lib/libonnxruntime.so" /usr/local/lib/libonnxruntime.so.1.27.0 || true
                    ln -sf libonnxruntime.so.1.27.0 /usr/local/lib/libonnxruntime.so || true
                fi
                # Ensure /usr/local/lib is in ldconfig path
                echo "/usr/local/lib" > /etc/ld.so.conf.d/local.conf 2>/dev/null || true
                ldconfig 2>/dev/null || true
                echo "  libsherpa-onnx-c-api.so → $LIB"
                echo "  c-api.h → $HEADER"
            fi
        fi
    fi
fi

# ── Zipformer EN 20M model ───────────────────────────────────────

MODEL_TARBALL="$MODEL_DIR/../zipformer-en-20M.tar.bz2"

if [ -f "$MODEL_DIR/tokens.txt" ] && \
   [ -f "$MODEL_DIR/encoder-epoch-99-avg-1.onnx" ] && \
   [ -f "$MODEL_DIR/decoder-epoch-99-avg-1.onnx" ] && \
   [ -f "$MODEL_DIR/joiner-epoch-99-avg-1.onnx" ]; then
    echo "Zipformer EN 20M model already installed."
else
    echo "Downloading Zipformer EN 20M model..."
    mkdir -p /usr/local/share/vox
    cd /usr/local/share/vox

    curl -L --progress-bar -o zipformer-en-20M.tar.bz2 \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2" || OK=false

    if $OK; then
        tar xf zipformer-en-20M.tar.bz2 || OK=false
        rm -f zipformer-en-20M.tar.bz2
        echo "  Model extracted to $MODEL_DIR"
    fi
fi

# ── voxd daemon ──────────────────────────────────────────────────

VOXD_SRC="$REPO_DIR/scripts/voxd/voxd.c"
VOXD_CFG="$REPO_DIR/scripts/voxd/config.h"
VOXD_MKF="$REPO_DIR/scripts/voxd/Makefile"
VOXD_STAMP=/usr/local/src/suckless/voxd-stamp

if [ -x "$VOXD_BIN" ] && \
   [ -f "$VOXD_STAMP/voxd.c" ] && \
   cmp -s "$VOXD_SRC" "$VOXD_STAMP/voxd.c" 2>/dev/null && \
   cmp -s "$VOXD_CFG" "$VOXD_STAMP/config.h" 2>/dev/null && \
   cmp -s "$VOXD_MKF" "$VOXD_STAMP/Makefile" 2>/dev/null; then
    echo "voxd already installed (source unchanged)."
else
    echo "Building voxd..."
    cd "$REPO_DIR/scripts/voxd"
    make clean 2>/dev/null || true
    make || { echo "ERROR: voxd build failed"; OK=false; }

    if $OK; then
        make install || OK=false
        mkdir -p "$VOXD_STAMP"
        cp "$VOXD_SRC" "$VOXD_STAMP/voxd.c"
        cp "$VOXD_CFG" "$VOXD_STAMP/config.h"
        cp "$VOXD_MKF" "$VOXD_STAMP/Makefile"
        echo "  voxd → $VOXD_BIN"
    fi
fi

# ── vox CLI wrapper ──────────────────────────────────────────────

cp "$REPO_DIR/scripts/vox" "$VOX_SCRIPT" 2>/dev/null || true
chmod +x "$VOX_SCRIPT" 2>/dev/null || true
echo "  vox → $VOX_SCRIPT"

# ── Update toggle-vox.sh (backward compat thin wrapper) ─────────

TOGGLE=/usr/local/bin/toggle-vox.sh
cat > "$TOGGLE" << 'TOGGLE_EOF'
#!/bin/sh
# toggle-vox.sh — VOX toggle (Mod+V) — regular dictation, NO audio dump
PID=$(pgrep -x voxd 2>/dev/null)
if [ -n "$PID" ]; then
    # If daemon is in dump mode, restart without it
    if grep -q -- '--dump-audio' /proc/$PID/cmdline 2>/dev/null; then
        pkill -x voxd 2>/dev/null; sleep 0.3
        /usr/local/bin/voxd &
        sleep 1.0
    fi
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
else
    /usr/local/bin/voxd &
    sleep 1.0
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
fi
TOGGLE_EOF
chmod +x "$TOGGLE"
echo "  toggle-vox.sh → $TOGGLE"

# ── Result ───────────────────────────────────────────────────────

if $OK; then
    echo "SUCCESS: VOX sherpa-onnx dictation installed."
    echo ""
    echo "Usage:"
    echo "  voxd &              Start daemon (auto-started by dwl session)"
    echo "  voxd --file foo.wav  Test decode a WAV file"
    echo "  Mod+V                Toggle recording on/off"
    exit 0
else
    echo "ERROR: VOX sherpa-onnx setup failed — check output above."
    exit 1
fi
