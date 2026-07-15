#!/bin/bash
# steps/whisper-cpp-vox.sh - WHISPER-CPP VOX (speech-to-text dictation)
# Builds whisper-cpp from source, downloads tiny.en + base.en models.
# Provides whisper-cli + whisper-stream binaries for toggle-vox.sh.

REPO_DIR="${REPO_DIR:-/root/slackware-installer-for-rs}"
LOG_FILE="${LOG_FILE:-/var/log/installer.log}"

if [ -f "$REPO_DIR/lib/common.sh" ]; then
    . "$REPO_DIR/lib/common.sh"
fi

echo "*****************************************************"
echo "WHISPER-CPP VOX (voice dictation → cursor)"
echo "*****************************************************"

ok=true

SRC=/usr/local/src/whisper.cpp
CLI_BIN=/usr/local/bin/whisper-cli
STREAM_BIN=/usr/local/bin/whisper-stream
MODEL_DIR=/usr/local/share/vox
TINY_MODEL="$MODEL_DIR/ggml-tiny.en.bin"
BASE_MODEL="$MODEL_DIR/ggml-base.en.bin"

# Already installed?
if [ -x "$CLI_BIN" ] && [ -x "$STREAM_BIN" ] && [ -f "$TINY_MODEL" ] && [ -f "$BASE_MODEL" ]; then
    echo "whisper-cli, whisper-stream, tiny + base models already installed."
    # Always deploy the toggle script (idempotent)
    cp "$REPO_DIR/scripts/toggle-vox.sh" /usr/local/bin/toggle-vox.sh && chmod +x /usr/local/bin/toggle-vox.sh
    echo "SUCCESS: VOX dictation (already present)."
    exit 0
fi


# Build dependencies
install_pkg "git make gcc cmake" || ok=false
install_pkg "SDL2" || ok=false

if $ok; then
    echo "Building whisper-cpp from source (with SDL2 streaming)..."
    mkdir -p /usr/local/src
    cd /usr/local/src
    [ ! -d whisper.cpp ] && rm -rf whisper.cpp
    if [ -d whisper.cpp ]; then
        cd whisper.cpp && git pull --ff-only 2>/dev/null
    else
        git clone --depth 1 https://github.com/ggerganov/whisper.cpp && cd whisper.cpp
    fi || { echo "ERROR: clone/update failed"; ok=false; }

    if $ok; then
        # Download models
        for model in tiny.en base.en; do
            if [ ! -f "models/ggml-${model}.bin" ]; then
                bash ./models/download-ggml-model.sh "$model" || {
                    echo "ERROR: failed to download $model model"
                    ok=false
                }
            fi
        done
    fi

    if $ok && [ ! -d build ] || [ ! -f build/bin/whisper-cli ]; then
        mkdir -p build && cd build
        cmake .. -DWHISPER_SDL2=ON || { echo "ERROR: cmake failed"; ok=false; }
    fi

    if $ok; then
        cd build 2>/dev/null || cd /usr/local/src/whisper.cpp/build
        make -j"$(nproc)" whisper-cli whisper-stream || { echo "ERROR: build failed"; ok=false; }
    fi

    if $ok; then
        cp bin/whisper-cli "$CLI_BIN" && chmod +x "$CLI_BIN" || ok=false
        cp bin/whisper-stream "$STREAM_BIN" && chmod +x "$STREAM_BIN" || ok=false
        mkdir -p "$MODEL_DIR"
        cp models/ggml-tiny.en.bin "$TINY_MODEL" || ok=false
        cp models/ggml-base.en.bin "$BASE_MODEL" || ok=false
        echo "  whisper-cli → $CLI_BIN"
        echo "  whisper-stream → $STREAM_BIN"
        echo "  tiny.en → $TINY_MODEL"
        echo "  base.en → $BASE_MODEL"
    fi
    # Deploy toggle-vox.sh manager script
    cp "$REPO_DIR/scripts/toggle-vox.sh" /usr/local/bin/toggle-vox.sh 2>/dev/null || true
    chmod +x /usr/local/bin/toggle-vox.sh 2>/dev/null || true
    echo "  toggle-vox.sh → /usr/local/bin/toggle-vox.sh"
fi

if $ok; then
    echo "SUCCESS: VOX dictation installed."
    exit 0
else
    echo "ERROR: VOX dictation setup failed."
    exit 1
fi
