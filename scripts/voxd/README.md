# VOX — Voice Dictation

Streaming speech-to-text using sherpa-onnx (Zipformer EN 20M).

## How it works

1. Press **Mod+V** to toggle dictation on/off
2. Words appear incrementally as you speak — no backspacing, only append
3. A trailing space is added after each utterance (0.6s pause)
4. Use `voxd --dump-audio` to save audio recordings to `~/logs/`

## Architecture

```
Mod+V → toggle-vox.sh → SIGUSR1 → voxd daemon
                                      │
                          ALSA plughw:0,7 @ 16kHz mono
                                      │
                          Zipformer EN 20M (streaming transducer)
                                      │
                          Incremental append via wtype
                                      │
                          vox_state → status bar [VOX] badge
                          ~/logs/vox.log
```

## Key behaviors

- **No backspaces.** The model never revises earlier words — each new partial is the old partial plus new words. Only the new suffix is typed.
- **No warmup.** The streaming Zipformer model produces results from the first audio chunk — no priming or delays needed. Verified against official sherpa-onnx examples.
- **Immediate.** Once you see the [VOX] badge, dictation is already active and processing.
- **Utterance spacing.** A single trailing space is added when the model detects 0.6s of silence (endpoint). Between utterances, the space provides natural separation.
- **Idempotent install.** `steps/vox-sherpa.sh` handles everything — models, library, binary, wrappers. Safe to rerun.
- **Audio recording.** Start with `voxd --dump-audio` to save matching `.wav` and `.txt` files with synchronized timestamps.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/voxd` | Daemon binary (C, sherpa-onnx) |
| `/usr/local/bin/toggle-vox.sh` | Mod+V handler |
| `/usr/local/bin/vox` | CLI wrapper (`vox on`/`vox off`) |
| `~/logs/vox.log` | Session log |
| `~/logs/vox-YYYYMMDD-HHMMSS.wav` | Audio recording (`--dump-audio` mode) |
| `~/logs/vox-YYYYMMDD-HHMMSS.txt` | Transcription log (`--dump-audio` mode) |
| `/usr/local/share/vox/` | Model files |

## Commands

```bash
voxd &                          # Start daemon
voxd --dump-audio &             # Start with audio recording
voxd --sim foo.wav              # Simulate typing (verify no garbling)
voxd --file foo.wav             # Decode WAV to stdout
vox on / vox off                # CLI toggle
pkill -USR1 voxd                # Toggle via signal
```

## Sim verification

```bash
voxd --sim /path/to/recording.wav    # Reproduce bugs from recorded audio
```

The sim uses the exact same code path as live typing — only the wtype fork/exec is replaced with a screen buffer.
