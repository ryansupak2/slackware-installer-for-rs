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

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "VOX SHERPA (streaming Zipformer voice dictation)"
echo "*****************************************************"

ok=true

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

    install_pkg "git make gcc cmake" || ok=false
    install_pkg "alsa-lib" || ok=false

    if $ok; then
        mkdir -p /usr/local/src
        cd /usr/local/src

        if [ -d sherpa-onnx ]; then
            cd sherpa-onnx && git pull --ff-only 2>/dev/null || true
        else
            echo "  Cloning sherpa-onnx (this may take a minute)..."
            git clone --depth 1 https://github.com/k2-fsa/sherpa-onnx
            echo "  Clone complete."
        fi || { echo "ERROR: clone/update failed"; ok=false; }

        if $ok; then
            cd /usr/local/src/sherpa-onnx
            mkdir -p build && cd build

            if [ ! -f "$LIB" ]; then
                echo "  Running cmake (configuring build)..."
                cmake -DCMAKE_BUILD_TYPE=Release \
                      -DBUILD_SHARED_LIBS=ON \
                      -DSHERPA_ONNX_ENABLE_PYTHON=OFF \
                      -DSHERPA_ONNX_ENABLE_TESTS=OFF \
                      -DSHERPA_ONNX_ENABLE_CHECK=OFF \
                      -DSHERPA_ONNX_ENABLE_PORTAUDIO=OFF \
                      .. || { echo "ERROR: cmake failed"; ok=false; }
                echo "  cmake complete."
            fi

            if $ok && [ ! -f "$LIB" ]; then
                make -j"$(nproc)" sherpa-onnx-c-api \
                    || { echo "ERROR: build failed"; ok=false; }
            fi

            if $ok; then
                cp lib/libsherpa-onnx-c-api.so /usr/local/lib/ || ok=false
                mkdir -p /usr/local/include/sherpa-onnx/c-api
                cp ../sherpa-onnx/c-api/c-api.h /usr/local/include/sherpa-onnx/c-api/ || ok=false
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

    echo "  Downloading ~100MB model tarball (this may take a few minutes)..."
    wget --show-progress -O zipformer-en-20M.tar.bz2 \
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17.tar.bz2" || ok=false
    echo "  Download complete."

    if $ok; then
        tar xf zipformer-en-20M.tar.bz2 || ok=false
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
    make || { echo "ERROR: voxd build failed"; ok=false; }

    if $ok; then
        make install || ok=false
        mkdir -p "$VOXD_STAMP"
        cp "$VOXD_SRC" "$VOXD_STAMP/voxd.c"
        cp "$VOXD_CFG" "$VOXD_STAMP/config.h"
        cp "$VOXD_MKF" "$VOXD_STAMP/Makefile"
        echo "  voxd → $VOXD_BIN"
    fi
fi

# ── calibration WAV ──────────────────────────────────────────────
cp "$REPO_DIR/scripts/voxd/calibrate.wav" /usr/local/share/vox/calibrate.wav 2>/dev/null || true
echo "  calibrate.wav → /usr/local/share/vox/calibrate.wav"

# ── vox CLI wrapper ──────────────────────────────────────────────

cp "$REPO_DIR/scripts/vox" "$VOX_SCRIPT" 2>/dev/null || true
chmod +x "$VOX_SCRIPT" 2>/dev/null || true
echo "  vox → $VOX_SCRIPT"

# ── Update toggle-vox.sh (backward compat thin wrapper) ─────────

TOGGLE=/usr/local/bin/toggle-vox.sh
cat > "$TOGGLE" << 'TOGGLE_EOF'
#!/bin/sh
# toggle-vox.sh — VOX toggle (Mod+V) — regular dictation, NO audio dump
#
# Evidence-based startup: polls for voxd process instead of arbitrary sleep.
# Model loads lazily on first use inside voxd, not at daemon startup.
# Lock file prevents races when Mod+V fires twice in quick succession.

LOG_DIR="/var/log"
TOGGLE_LOG="$LOG_DIR/${USER:-root}-vox-toggle.log"
LOCK="$XDG_RUNTIME_DIR/vox-toggle-lock"

log_toggle() { echo "$(date '+%Y-%m-%d %H:%M:%S'): toggle-vox: $*" >> "$TOGGLE_LOG"; }

# Debounce: if lock exists, another toggle is already in flight — skip
if ! mkdir "$LOCK" 2>/dev/null; then
    log_toggle "SKIPPED (lock held — another toggle in flight)"
    exit 0
fi
# Remove lock on exit, with 250ms cooldown to prevent rapid double-toggles
trap 'sleep 0.25; rmdir "$LOCK" 2>/dev/null' EXIT

# Determine current VOX state for clear ON/OFF logging
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
if [ -f "$STATE_FILE" ]; then
    CUR_STATE=$(cat "$STATE_FILE" 2>/dev/null)
else
    CUR_STATE="off"
fi

log_toggle "TRIGGERED (current state: $CUR_STATE)"

PID=$(pgrep -x voxd 2>/dev/null)
if [ -n "$PID" ]; then
    log_toggle "voxd already running (PID=$PID)"
    # Regular dictation: ensure voxd is NOT in dump mode
    if grep -q -- '--dump-audio' /proc/$PID/cmdline 2>/dev/null; then
        log_toggle "restarting voxd without --dump-audio"
        pkill -x voxd 2>/dev/null
        while pgrep -x voxd >/dev/null 2>&1; do usleep 50000; done
        /usr/local/bin/voxd &
    fi
    if [ "$CUR_STATE" = "recording" ] || [ "$CUR_STATE" = "recording+dump" ]; then
        log_toggle ">>> VOX OFF <<<"
    else
        log_toggle ">>> VOX ON <<<"
    fi
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
else
    log_toggle "voxd not running — starting daemon"
    log_toggle ">>> VOX ON <<<"
    /usr/local/bin/voxd &
    for i in $(seq 1 50); do
        pgrep -x voxd >/dev/null 2>&1 && break
        usleep 20000
    done
    if pgrep -x voxd >/dev/null 2>&1; then
        log_toggle "voxd started (PID=$(pgrep -x voxd)) — sending SIGUSR1"
        kill -USR1 $(pgrep -x voxd) 2>/dev/null
    else
        log_toggle "ERROR: voxd failed to start after 1s"
    fi
fi
TOGGLE_EOF
chmod +x "$TOGGLE"
echo "  toggle-vox.sh → $TOGGLE"

# ── toggle-vox-record.sh (Mod+Shift+V) ───────────────────────────

TOGGLE_REC=/usr/local/bin/toggle-vox-record.sh
cat > "$TOGGLE_REC" << 'TOGGLE_REC_EOF'
#!/bin/sh
# toggle-vox-record.sh — VOX toggle with audio recording (Mod+Shift+V)
#
# Ensures voxd is running with --dump-audio, then toggles recording.
# Audio saved to /var/log/<user>-vox-YYYYMMDD-HHMMSS.wav
#
# Evidence-based: no arbitrary sleeps, polls for process state.
# Lock file prevents races when Mod+Shift+V fires twice in quick succession.

LOG_DIR="/var/log"
TOGGLE_LOG="$LOG_DIR/${USER:-root}-vox-toggle.log"
LOCK="$XDG_RUNTIME_DIR/vox-toggle-rec-lock"

log_toggle() { echo "$(date '+%Y-%m-%d %H:%M:%S'): toggle-rec: $*" >> "$TOGGLE_LOG"; }

# Debounce: skip if another toggle is in flight
if ! mkdir "$LOCK" 2>/dev/null; then
    log_toggle "SKIPPED (lock held — another toggle in flight)"
    exit 0
fi
trap 'sleep 0.25; rmdir "$LOCK" 2>/dev/null' EXIT

# Determine current VOX state for clear ON/OFF logging
STATE_FILE="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/vox_state"
if [ -f "$STATE_FILE" ]; then
    CUR_STATE=$(cat "$STATE_FILE" 2>/dev/null)
else
    CUR_STATE="off"
fi

log_toggle "TRIGGERED (current state: $CUR_STATE)"

VOXD=/usr/local/bin/voxd

if pgrep -x voxd >/dev/null 2>&1; then
    log_toggle "voxd already running (PID=$(pgrep -x voxd))"
    if ! grep -q -- '--dump-audio' /proc/$(pgrep -x voxd)/cmdline 2>/dev/null; then
        # voxd running but WITHOUT --dump-audio — restart it
        log_toggle "restarting voxd with --dump-audio"
        pkill -x voxd 2>/dev/null
        while pgrep -x voxd >/dev/null 2>&1; do usleep 50000; done
        CUR_STATE="off"
        $VOXD --dump-audio &
        # Evidence-based: wait for daemon to be alive
        for i in $(seq 1 50); do
            pgrep -x voxd >/dev/null 2>&1 && break
            usleep 20000
        done
    fi
else
    log_toggle "voxd not running — starting daemon with --dump-audio"
    CUR_STATE="off"
    $VOXD --dump-audio &
    for i in $(seq 1 50); do
        pgrep -x voxd >/dev/null 2>&1 && break
        usleep 20000
    done
fi

if pgrep -x voxd >/dev/null 2>&1; then
    if [ "$CUR_STATE" = "recording" ] || [ "$CUR_STATE" = "recording+dump" ]; then
        log_toggle ">>> VOX OFF (record) <<<"
    else
        log_toggle ">>> VOX ON (record) <<<"
    fi
    kill -USR1 $(pgrep -x voxd) 2>/dev/null
else
    log_toggle "ERROR: voxd not running — cannot toggle"
fi
TOGGLE_REC_EOF
chmod +x "$TOGGLE_REC"
echo "  toggle-vox-record.sh → $TOGGLE_REC"

# ── Result ───────────────────────────────────────────────────────

if $ok; then
    echo "SUCCESS: VOX sherpa-onnx dictation installed."
    echo ""
    echo "Usage:"
    echo "  voxd &              Start daemon (auto-started by dwm session)"
    echo "  voxd --file foo.wav  Test decode a WAV file"
    echo "  Mod+V                Toggle recording on/off"
    exit 0
else
    echo "ERROR: VOX sherpa-onnx setup failed — check output above."
    exit 1
fi
