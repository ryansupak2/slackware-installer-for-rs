# VOX — Voice Dictation

Streaming speech-to-text for dwl/somebar using sherpa-onnx (Zipformer EN 20M).

## How it works

1. Press **Mod+V** to toggle dictation on/off
2. Press **Mod+Shift+V** for dictation with audio recording saved to `~/logs/`
3. Words appear incrementally as you speak — no backspacing, only append
4. A trailing space is added after each utterance (0.6s pause)
5. The first phantom word after warmup is silently suppressed

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
                          vox_state → somebar [VOX] badge
                          ~/logs/vox.log
```

## Key behaviors

- **No backspaces.** The model never revises earlier words — each new partial is the old partial plus new words. Only the new suffix is typed.
- **Warmup on start.** 5s of newyorkgroove.wav primes the model at daemon startup. Residue is flushed with silence before user audio begins.
- **First-word suppression.** The very first partial+endpoint after warmup is suppressed (ambient noise can produce a spurious word).
- **Utterance spacing.** A single trailing space is added when the model detects 0.6s of silence (endpoint). Between utterances, the space provides natural separation.
- **Idempotent install.** `steps/vox-sherpa.sh` handles everything — models, library, binary, wrappers. Safe to rerun.
- **Audio recording.** Mod+Shift+V saves matching `.wav` and `.txt` files with synchronized timestamps and full backspace/revision tracking.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/voxd` | Daemon binary (C, sherpa-onnx) |
| `/usr/local/bin/toggle-vox.sh` | Mod+V handler |
| `/usr/local/bin/toggle-vox-record.sh` | Mod+Shift+V handler |
| `/usr/local/bin/vox` | CLI wrapper (`vox on`/`vox off`) |
| `~/logs/vox.log` | Session log |
| `~/logs/vox-YYYYMMDD-HHMMSS.wav` | Audio recording |
| `~/logs/vox-YYYYMMDD-HHMMSS.txt` | Transcription log |
| `/usr/local/share/vox/` | Model files |
| `/tmp/warmup.raw` | Warmup audio (generated from newyorkgroove.wav) |

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
voxd --sim /tmp/newyorkgroove.wav    # 0 SIM ERRORs expected
voxd --sim /path/to/recording.wav    # Reproduce bugs from recorded audio
```

The sim uses the exact same code path as live typing — only the wtype fork/exec is replaced with a screen buffer.
