#ifndef VOXD_CONFIG_H
#define VOXD_CONFIG_H

/* --- Paths --- */
#define MODEL_DIR  "/usr/local/share/vox/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
#define TOKENS     MODEL_DIR "/tokens.txt"
#define ENCODER    MODEL_DIR "/encoder-epoch-99-avg-1.onnx"
#define DECODER    MODEL_DIR "/decoder-epoch-99-avg-1.onnx"
#define JOINER     MODEL_DIR "/joiner-epoch-99-avg-1.onnx"

/* --- ALSA --- */
/* Preferred capture device. sof-soundwire renumbers its PCM devices between
 * boots (this mic has been 0,7 / 0,6 / 0,4), so this is only a hint: voxd
 * falls back to auto-detection (first capture-capable PCM), then "default".
 * Force one explicitly with VOXD_ALSA_DEVICE=plughw:0,4 in the environment. */
#define ALSA_DEVICE      "plughw:0,4"  /* DMIC capture device (hint) */
#define SAMPLE_RATE      16000
#define CHANNELS         1
#define CHUNK_MS         60             /* 60ms audio chunks (was 100ms) */
#define CHUNK_SAMPLES    (SAMPLE_RATE * CHUNK_MS / 1000)

/* --- Streaming / endpoint --- */
#define ENDPOINT_SILENCE 1.2
#define MAX_UTTERANCE 20.0
#define NUM_THREADS      4              /* onnxruntime threads */
#define SILENCE_FLUSH_S  1.0             /* silence to flush decoder context after warmup */

/* --- Keyboard typing --- */
/* WTYPE_BIN is used when WAYLAND_DISPLAY is set;
   otherwise X11 XTest is used directly (no external tool needed). */
#define WTYPE_BIN "/usr/bin/wtype"

/* --- state files (built at runtime from $HOME) --- */
/* /var/log/<user>/vox.log  — append-only, "$(date): message" format */
/* $XDG_RUNTIME_DIR/vox_state — "loading" | "recording" | deleted */

#endif
/* --- Calibration --- */
#define CALIBRATE_WAV "/usr/local/share/vox/calibrate.wav"
