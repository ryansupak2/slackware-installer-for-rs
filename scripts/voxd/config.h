#ifndef VOXD_CONFIG_H
#define VOXD_CONFIG_H

/* --- Paths --- */
#define MODEL_DIR  "/usr/local/share/vox/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
#define TOKENS     MODEL_DIR "/tokens.txt"
#define ENCODER    MODEL_DIR "/encoder-epoch-99-avg-1.onnx"
#define DECODER    MODEL_DIR "/decoder-epoch-99-avg-1.onnx"
#define JOINER     MODEL_DIR "/joiner-epoch-99-avg-1.onnx"

/* --- ALSA --- */
#define ALSA_DEVICE      "plughw:0,7"  /* DMIC capture device */
#define SAMPLE_RATE      16000
#define CHANNELS         1
#define CHUNK_MS         100            /* 100ms audio chunks */
#define CHUNK_SAMPLES    (SAMPLE_RATE * CHUNK_MS / 1000)

/* --- Streaming / endpoint --- */
#define ENDPOINT_SILENCE 1.2
#define MAX_UTTERANCE 20.0
#define NUM_THREADS      2              /* onnxruntime threads */

/* --- Keyboard typing --- */
/* WTYPE_BIN is used when WAYLAND_DISPLAY is set;
   otherwise X11 XTest is used directly (no external tool needed). */
#define WTYPE_BIN "/usr/bin/wtype"

/* --- state files (built at runtime from $HOME) --- */
/* /var/log/vox.log  — append-only, "$(date): message" format */
/* $XDG_RUNTIME_DIR/vox_state — "loading" | "recording" | deleted */

#endif
