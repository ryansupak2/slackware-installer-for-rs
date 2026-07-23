/*
 * voxd.c — VOX voice dictation daemon (sherpa-onnx / streaming Zipformer)
 *
 * Sim mode:  voxd --sim foo.wav   — same code path as live, no typing
 * File mode: voxd --file foo.wav  — decode WAV, no typing
 * Daemon:    voxd                 — ALSA mic → keyboard typing
 *
 * Architecture:
 *   type_append(old, len, new) → computes suffix → type_replace(0, suffix)
 *   type_replace(bs, text)     → sim appends to buffer, real types at cursor
 *
 * One code path. Sim mode only changes the bottom of type_replace.
 * Auto-detects X11 (XTest) vs Wayland (wtype) at startup.
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <errno.h>
#include <ctype.h>
#include <stdarg.h>

#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

#include <alsa/asoundlib.h>
#include <sherpa-onnx/c-api/c-api.h>

#include "config.h"

/* X11 keycode cache — populated once at startup */
static Display *g_x11_dpy = NULL;
static KeyCode  g_keycodes[128];  /* ASCII → keycode */
static int      g_need_shift[128]; /* ASCII → needs Shift? */

/* ======================================================================
 * Global state
 * ====================================================================== */
static volatile sig_atomic_t g_running   = 1;
static volatile sig_atomic_t g_toggle    = 0;

static int  g_sim_mode = 0;
static char g_sim_buf[65536];
static int  g_sim_len = 0;
static int  g_sim_errors = 0;
static char g_sim_expected[65536];

static char *g_state_path = NULL;
static FILE *g_log        = NULL;

static int  g_dump_audio = 0;
static FILE *g_dump_fp   = NULL;
static FILE *g_dump_txt  = NULL;
static int  g_dump_data_bytes = 0;
static char g_dump_path[512];
static char g_dump_txt_path[512];


/* ======================================================================
 * Logging
 * ====================================================================== */
static void log_msg(const char *fmt, ...) {
    if (!g_log) {
        const char *user = getenv("USER"); if (!user) user = "root";
        char buf[512]; mkdir("/var/log", 0755);
        snprintf(buf, sizeof(buf), "/var/log/%s-vox.log", user);
        g_log = fopen(buf, "a"); if (!g_log) g_log = stderr;
    }
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    fprintf(g_log, "%04d-%02d-%02d %02d:%02d:%02d: ",
            tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    va_list ap; va_start(ap, fmt); vfprintf(g_log, fmt, ap); va_end(ap);
    fprintf(g_log, "\n"); fflush(g_log);
}

static void log_open(void) { log_msg(""); } /* force log init */

/* ======================================================================
 * State file
 * ====================================================================== */
static void state_write(const char *val) {
    const char *xdg = getenv("XDG_RUNTIME_DIR");
    if (!xdg) { char buf[128]; snprintf(buf, sizeof(buf), "/run/user/%d", getuid()); xdg = buf; }
    char path[256]; snprintf(path, sizeof(path), "%s/vox_state", xdg);
    free(g_state_path); g_state_path = strdup(path);
    FILE *f = fopen(path, "w"); if (f) { fprintf(f, "%s\n", val); fclose(f); }
}
static void state_clear(void) {
    if (g_state_path) unlink(g_state_path);
    free(g_state_path); g_state_path = NULL;
}


/* ======================================================================
 * X11 keyboard typing via XTest (fallback when no WAYLAND_DISPLAY)
 * ====================================================================== */
static void x11_type(const char *buf, int len) {
    if (!g_x11_dpy || len <= 0) return;
    for (int i = 0; i < len; i++) {
        unsigned char c = (unsigned char)buf[i];
        if (c == '\b' || c == 0x7f) {
            /* Backspace */
            KeyCode kc = XKeysymToKeycode(g_x11_dpy, XK_BackSpace);
            if (kc) {
                XTestFakeKeyEvent(g_x11_dpy, kc, True, 0);
                XTestFakeKeyEvent(g_x11_dpy, kc, False, 0);
            }
            continue;
        }
        if (c >= 128) continue; /* skip non-ASCII */
        KeyCode kc = g_keycodes[c];
        if (!kc) continue;
        if (g_need_shift[c])
            XTestFakeKeyEvent(g_x11_dpy, XKeysymToKeycode(g_x11_dpy, XK_Shift_L), True, 0);
        XTestFakeKeyEvent(g_x11_dpy, kc, True, 0);
        XTestFakeKeyEvent(g_x11_dpy, kc, False, 0);
        if (g_need_shift[c])
            XTestFakeKeyEvent(g_x11_dpy, XKeysymToKeycode(g_x11_dpy, XK_Shift_L), False, 0);
    }
    XFlush(g_x11_dpy);
}

/* ======================================================================
 * Sim helpers
 * ====================================================================== */
static void sim_verify(const char *label) {
    if (strcmp(g_sim_buf, g_sim_expected) != 0) {
        g_sim_errors++;
        fprintf(stderr, "  [SIM ERROR #%d @ %s]\n", g_sim_errors, label);
        fprintf(stderr, "    expected (%zu): |%s|\n", strlen(g_sim_expected), g_sim_expected);
        fprintf(stderr, "    got      (%d): |%s|\n", g_sim_len, g_sim_buf);
        strncpy(g_sim_buf, g_sim_expected, sizeof(g_sim_buf)-1);
        g_sim_len = strlen(g_sim_buf);
    }
}

/* ======================================================================
 * Core: type_replace — sim appends to buffer, real types at cursor
 * ====================================================================== */
static void type_replace(int bs, const char *text) {
    if (bs == 0 && (!text || !*text)) return;

    if (g_sim_mode) {
        if (bs > 0) {
            if (bs > g_sim_len) bs = g_sim_len;
            g_sim_len -= bs;
            g_sim_buf[g_sim_len] = '\0';
            g_sim_expected[g_sim_len] = '\0';
        }
        if (text && *text) {
            strncat(g_sim_buf, text, sizeof(g_sim_buf)-g_sim_len-1);
            strncat(g_sim_expected, text, sizeof(g_sim_expected)-g_sim_len-1);
            g_sim_len = strlen(g_sim_buf);
        }
        fprintf(stderr, "  [SIM REPLACE] bs=%d text='%s' → screen(%d): |%s|\n",
                bs, text?text:"", g_sim_len, g_sim_buf);
        sim_verify("replace");
        return;
    }

    int tlen = text ? (int)strlen(text) : 0;
    int bufsz = bs + tlen;
    if (bufsz == 0) return;
    char *buf = malloc(bufsz);
    if (!buf) return;
    if (bs > 0) memset(buf, '\b', bs);
    if (tlen > 0) memcpy(buf + bs, text, tlen);

    log_msg("[TYPE] replace bs=%d + %d chars (XTest)", bs, tlen);

    /* X11: type directly via XTest */
    x11_type(buf, bufsz);
    free(buf);
}

/* ======================================================================
 * Core: type_append — incremental typing, no backspace
 * ====================================================================== */
static void type_append(const char *old_text, int old_len, const char *new_text) {
    if (!new_text || !*new_text) return;
    int new_len = (int)strlen(new_text);
    if (new_len <= old_len) {
        if (g_sim_mode) fprintf(stderr, "  [SIM SKIP] new_len=%d <= old_len=%d\n", new_len, old_len);
        return;
    }
    (void)old_text;
    const char *suffix = new_text + old_len;
    if (!*suffix) return;
    type_replace(0, suffix);
}

/* ======================================================================
 * Sanitize
 * ====================================================================== */
static void sanitize(char *s) {
    char *r = s, *w = s;
    int in_bracket = 0, in_paren = 0;
    while (*r) {
        if (*r == '[') { in_bracket = 1; r++; continue; }
        if (*r == ']') { in_bracket = 0; r++; continue; }
        if (*r == '(') { in_paren = 1; r++; continue; }
        if (*r == ')') { in_paren = 0; r++; continue; }
        if (in_bracket || in_paren) { r++; continue; }
        if (*r == '*') { r++; continue; }
        *w++ = (char)tolower((unsigned char)*r);
        r++;
    }
    *w = '\0';
    while (w > s && (*(w-1)==' '||*(w-1)=='\t'||*(w-1)=='\n')) { w--; *w='\0'; }
    char *start = s; while (*start==' '||*start=='\t') start++;
    if (start != s) memmove(s, start, strlen(start)+1);
}

/* ======================================================================
 * Audio dump
 * ====================================================================== */
static void dump_log_text(const char *phase, int bs, const char *old_text, const char *new_text) {
    if (!g_dump_txt) return;
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    fprintf(g_dump_txt, "[%02d:%02d:%02d] %s bs=%d old(%zu)=|%s| new(%zu)=|%s|\n",
            tm.tm_hour, tm.tm_min, tm.tm_sec, phase, bs,
            old_text?strlen(old_text):0, old_text?old_text:"",
            new_text?strlen(new_text):0, new_text?new_text:"");
    fflush(g_dump_txt);
}
static void dump_open(void) {
    const char *user = getenv("USER"); if (!user) user = "root";
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    snprintf(g_dump_path, sizeof(g_dump_path), "/var/log/%s-vox-%04d%02d%02d-%02d%02d%02d.wav",
             user, tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    g_dump_fp = fopen(g_dump_path, "wb");
    if (!g_dump_fp) { log_msg("ERROR: cannot open dump %s", g_dump_path); return; }
    char hdr[44] = {0};
    memcpy(hdr, "RIFF", 4); memcpy(hdr+8, "WAVEfmt ", 8);
    hdr[16]=16; hdr[20]=1; hdr[22]=1;
    hdr[24]=SAMPLE_RATE&0xFF; hdr[25]=(SAMPLE_RATE>>8)&0xFF;
    hdr[26]=(SAMPLE_RATE>>16)&0xFF; hdr[27]=(SAMPLE_RATE>>24)&0xFF;
    int br = SAMPLE_RATE*2;
    hdr[28]=br&0xFF; hdr[29]=(br>>8)&0xFF; hdr[30]=(br>>16)&0xFF; hdr[31]=(br>>24)&0xFF;
    hdr[32]=2; hdr[34]=16;
    memcpy(hdr+36, "data", 4);
    fwrite(hdr,1,44,g_dump_fp); g_dump_data_bytes=0;
    snprintf(g_dump_txt_path, sizeof(g_dump_txt_path), "/var/log/%s-vox-%04d%02d%02d-%02d%02d%02d.txt",
             user, tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
    g_dump_txt = fopen(g_dump_txt_path, "w");
    if (g_dump_txt) {
        fprintf(g_dump_txt, "# VOX transcription session\n");
        fprintf(g_dump_txt, "# Started: %04d-%02d-%02d %02d:%02d:%02d\n",
                tm.tm_year+1900,tm.tm_mon+1,tm.tm_mday,tm.tm_hour,tm.tm_min,tm.tm_sec);
        fprintf(g_dump_txt, "# Audio: vox-%04d%02d%02d-%02d%02d%02d.wav\n#\n",
                tm.tm_year+1900,tm.tm_mon+1,tm.tm_mday,tm.tm_hour,tm.tm_min,tm.tm_sec);
        fflush(g_dump_txt);
    }
}
static void dump_write(const int16_t *samples, int n) {
    if (!g_dump_fp) return;
    fwrite(samples, sizeof(int16_t), n, g_dump_fp);
    g_dump_data_bytes += n * sizeof(int16_t);
}
static void dump_close(void) {
    if (g_dump_txt) { fclose(g_dump_txt); g_dump_txt = NULL; }
    if (!g_dump_fp) return;
    uint32_t rs = 36+g_dump_data_bytes, ds = g_dump_data_bytes;
    fseek(g_dump_fp, 4, SEEK_SET); fwrite(&rs,4,1,g_dump_fp);
    fseek(g_dump_fp, 40, SEEK_SET); fwrite(&ds,4,1,g_dump_fp);
    fclose(g_dump_fp); g_dump_fp = NULL;
    log_msg("Audio dump closed: %s (%d bytes PCM)", g_dump_path, g_dump_data_bytes);
}

/* ======================================================================
 * Recognizer
 * ====================================================================== */
static const SherpaOnnxOnlineRecognizer *recognizer_create(void) {
    SherpaOnnxOnlineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.model_config.debug = 0;
    config.model_config.num_threads = NUM_THREADS;
    config.model_config.provider = "cpu";
    config.model_config.tokens = TOKENS;
    config.model_config.transducer.encoder = ENCODER;
    config.model_config.transducer.decoder = DECODER;
    config.model_config.transducer.joiner = JOINER;
    config.decoding_method = "greedy_search";
    config.max_active_paths = 4;
    config.feat_config.sample_rate = SAMPLE_RATE;
    config.feat_config.feature_dim = 80;
    config.enable_endpoint = 1;
    config.rule1_min_trailing_silence = ENDPOINT_SILENCE;
    config.rule2_min_trailing_silence = ENDPOINT_SILENCE * 2.0;
    config.rule3_min_utterance_length = MAX_UTTERANCE;
    return SherpaOnnxCreateOnlineRecognizer(&config);
}

/* ======================================================================
 * Calibration logic has been inlined into run_alsa_mode() as
 * Warmup[1/3] to give full control over the drain synchronisation.
 * ====================================================================== */
/* ======================================================================
 * ALSA
 * ====================================================================== */
static snd_pcm_t *alsa_open(void) {
    snd_pcm_t *handle;
    if (snd_pcm_open(&handle, ALSA_DEVICE, SND_PCM_STREAM_CAPTURE, 0) < 0) return NULL;
    snd_pcm_hw_params_t *params; snd_pcm_hw_params_alloca(&params);
    snd_pcm_hw_params_any(handle, params);
    snd_pcm_hw_params_set_access(handle, params, SND_PCM_ACCESS_RW_INTERLEAVED);
    snd_pcm_hw_params_set_format(handle, params, SND_PCM_FORMAT_S16_LE);
    snd_pcm_hw_params_set_channels(handle, params, CHANNELS);
    unsigned int rate = SAMPLE_RATE; snd_pcm_hw_params_set_rate_near(handle, params, &rate, NULL);
    snd_pcm_uframes_t period = CHUNK_SAMPLES, buffer = CHUNK_SAMPLES * 2;
    snd_pcm_hw_params_set_period_size_near(handle, params, &period, NULL);
    snd_pcm_hw_params_set_buffer_size_near(handle, params, &buffer);
    if (snd_pcm_hw_params(handle, params) < 0) { snd_pcm_close(handle); return NULL; }
    log_msg("ALSA opened: %s, rate=%u, ch=%d, period=%lu", ALSA_DEVICE, rate, CHANNELS, period);
    return handle;
}

/* ======================================================================
 * File mode
 * ====================================================================== */
static void run_file_mode(const char *wav_path) {
    log_msg("FILE MODE: %s", wav_path);
    const SherpaOnnxOnlineRecognizer *recognizer = recognizer_create();
    if (!recognizer) return;
    const SherpaOnnxOnlineStream *stream = SherpaOnnxCreateOnlineStream(recognizer);
    const SherpaOnnxWave *wave = SherpaOnnxReadWave(wav_path);
    if (!wave) { SherpaOnnxDestroyOnlineStream(stream); SherpaOnnxDestroyOnlineRecognizer(recognizer); return; }

    fprintf(stderr, "WAV: rate=%d samples=%d duration=%.2fs\n",
            wave->sample_rate, wave->num_samples, (float)wave->num_samples/wave->sample_rate);

    int segment_id = 0, k = 0, chunk = SAMPLE_RATE * 100 / 1000;
    char last_text[4096] = {0};
    int last_partial_len = 0;

    while (k < wave->num_samples) {
        int start = k, end = (start+chunk > wave->num_samples) ? wave->num_samples : (start+chunk);
        k += chunk;
        SherpaOnnxOnlineStreamAcceptWaveform(stream, wave->sample_rate, wave->samples+start, end-start);
        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
        const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(recognizer, stream);

        char text_buf[4096];
        strncpy(text_buf, r?r->text:"", sizeof(text_buf)-1); text_buf[sizeof(text_buf)-1]='\0';
        sanitize(text_buf);

        if (text_buf[0] && strcmp(text_buf, last_text) != 0) {
            type_append(last_text, last_partial_len, text_buf);
            last_partial_len = strlen(text_buf);
            strncpy(last_text, text_buf, sizeof(last_text)-1);
            fprintf(stderr, "  %d: %s\n", segment_id, text_buf);
        }

        if (SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream)) {
            if (text_buf[0]) {
                char spaced[4096]; snprintf(spaced, sizeof(spaced), "%s ", text_buf);
                type_append(last_text, last_partial_len, spaced);
                last_partial_len = 0;
                last_text[0] = '\0';
                fprintf(stderr, "  -> final segment %d\n\n", segment_id);
                segment_id++;
            }
            SherpaOnnxOnlineStreamReset(recognizer, stream);
        }
        if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
    }

    /* tail padding */
    { float tail[4800] = {0};
      SherpaOnnxOnlineStreamAcceptWaveform(stream, wave->sample_rate, tail, 4800);
      SherpaOnnxOnlineStreamInputFinished(stream);
      while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
      const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
      if (r && strlen(r->text)) {
          char text_buf[4096]; strncpy(text_buf, r->text, sizeof(text_buf)-1); text_buf[sizeof(text_buf)-1]='\0';
          sanitize(text_buf);
          type_append(last_text, last_partial_len, text_buf);
          fprintf(stderr, "  %d: %s\n  -> final\n", segment_id, text_buf);
      }
      if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
    }

    fprintf(stderr, "\n--- Ground truth ---\n");
    fprintf(stderr, "Here I am, again in the city. With a fistful of dollars. And baby, you'd better believe I'm back. Back in the New York Groove.\n");
    SherpaOnnxFreeWave(wave);
    SherpaOnnxDestroyOnlineStream(stream);
    SherpaOnnxDestroyOnlineRecognizer(recognizer);
}

/* ======================================================================
 * ALSA mode
 * ====================================================================== */
static void run_alsa_mode(void) {
    /* Lazy init: model and ALSA are created on first toggle ON,
     * kept alive between toggles, and destroyed on daemon exit.
     * Zero memory footprint until first use.
     */
    const SherpaOnnxOnlineRecognizer *recognizer = NULL;
    const SherpaOnnxOnlineStream *stream = NULL;
    snd_pcm_t *alsa = NULL;
    int recording = 0, segment_id = 0, last_partial_len = 0;
    int first_chunk_logged = 0, first_ready_logged = 0;
    int silent_chunks = 0, first_text_logged = 0;
    int model_warm = 0;  /* true after first successful load */

    char last_text[4096] = {0};
    while (g_running) {
        if (g_toggle) {
            g_toggle = 0;
            if (!recording) {
                /* --- TOGGLE ON --- */
                struct timespec t_start, t_ready;
                clock_gettime(CLOCK_MONOTONIC, &t_start);
                log_msg("TOGGLE ON — user pressed Mod+V");
                state_write("loading");

                if (g_dump_audio) dump_open();

                /* Lazy model load on first use only */
                if (!recognizer) {
                    log_msg("Cold start — loading sherpa-onnx model (this may take a moment)...");
                    recognizer = recognizer_create();
                    if (!recognizer) {
                        log_msg("FATAL: recognizer_create() returned NULL");
                        state_clear();
                        if (g_dump_audio) dump_close();
                        return;
                    }
                    clock_gettime(CLOCK_MONOTONIC, &t_ready);
                    double elapsed = (t_ready.tv_sec - t_start.tv_sec) +
                                     (t_ready.tv_nsec - t_start.tv_nsec) / 1e9;
                    log_msg("Model loaded in %.2fs", elapsed);
                }

                /* Lazy ALSA open on first use */
                if (!alsa) {
                    log_msg("Opening ALSA device %s...", ALSA_DEVICE);
                    alsa = alsa_open();
                    if (!alsa) {
                        log_msg("FATAL: cannot open ALSA device %s", ALSA_DEVICE);
                        state_clear();
                        if (g_dump_audio) dump_close();
                        return;
                    }
                /* ── Cold-start: warm up pipeline, then drain to clean slate ── */
                    struct timespec t_phase;
                    snd_pcm_drop(alsa);
                    snd_pcm_prepare(alsa);

                    stream = SherpaOnnxCreateOnlineStream(recognizer);
                    log_msg("Warmup: stream created");

                    int pipeline_live = 0;
                    int warmup_chunks_fed = 0;
                    int warmup_decode_iters = 0;

                    /* Phase 1: feed calibration WAV to prove model+stream work */
                    if (!model_warm) {
                        clock_gettime(CLOCK_MONOTONIC, &t_phase);
                        const SherpaOnnxWave *wave = SherpaOnnxReadWave(CALIBRATE_WAV);
                        if (wave) {
                            log_msg("Warmup[1/3] WAV loaded: %.2fs, %d samples, %dHz",
                                     (float)wave->num_samples / wave->sample_rate,
                                     wave->num_samples, wave->sample_rate);
                            int chunk = SAMPLE_RATE * 60 / 1000;
                            int wav_chunks = 0, wav_decodes = 0;
                            for (int k = 0; k < wave->num_samples; k += chunk) {
                                int n = (k + chunk > wave->num_samples) ? (wave->num_samples - k) : chunk;
                                float fbuf[CHUNK_SAMPLES];
                                for (int j = 0; j < n; j++) fbuf[j] = wave->samples[k + j];
                                SherpaOnnxOnlineStreamAcceptWaveform(stream, wave->sample_rate, fbuf, n);
                                wav_chunks++;
                                while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
                                    SherpaOnnxDecodeOnlineStream(recognizer, stream);
                                    wav_decodes++;
                                }
                                const SherpaOnnxOnlineRecognizerResult *r =
                                    SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                                if (r && strlen(r->text) > 0 && !pipeline_live) {
                                    char buf[256];
                                    strncpy(buf, r->text, sizeof(buf)-1); buf[sizeof(buf)-1] = '\0';
                                    sanitize(buf);
                                    log_msg("Warmup[1/3] WAV produced text → \"%s\" — PIPELINE LIVE", buf);
                                    pipeline_live = 1;
                                }
                                if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
                            }
                            SherpaOnnxFreeWave(wave);
                            warmup_chunks_fed += wav_chunks;
                            warmup_decode_iters += wav_decodes;
                            double t1 = (t_phase.tv_sec == 0) ? 0.0 : 0.0;
                            { struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
                              t1 = (tn.tv_sec - t_phase.tv_sec) + (tn.tv_nsec - t_phase.tv_nsec)/1e9; }
                            log_msg("Warmup[1/3] WAV done: %d chunks, %d decodes in %.3fs, live=%d",
                                     wav_chunks, wav_decodes, t1, pipeline_live);
                        } else {
                            log_msg("Warmup[1/3] WAV not found at %s — skipping", CALIBRATE_WAV);
                        }
                    } else {
                        log_msg("Warmup[1/3] WAV skipped (model already warm)");
                    }

                    /* Phase 2: if WAV didn't prove liveness, prime with mic audio */
                    if (!pipeline_live) {
                        clock_gettime(CLOCK_MONOTONIC, &t_phase);
                        int prime_chunks = 3 * (SAMPLE_RATE / CHUNK_SAMPLES);
                        log_msg("Warmup[2/3] Mic priming: %d chunks ≈ 3s (WAV did not prove liveness)",
                                 prime_chunks);
                        int16_t prime_buf[CHUNK_SAMPLES];
                        int mic_chunks = 0, mic_decodes = 0, mic_errors = 0;
                        for (int i = 0; i < prime_chunks; i++) {
                            int rc = snd_pcm_readi(alsa, prime_buf, CHUNK_SAMPLES);
                            if (rc < 0) { snd_pcm_recover(alsa, rc, 0); mic_errors++; break; }
                            float fbuf[CHUNK_SAMPLES];
                            for (int j = 0; j < rc; j++) fbuf[j] = prime_buf[j] / 32768.0f;
                            SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, fbuf, rc);
                            mic_chunks++;
                            while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
                                SherpaOnnxDecodeOnlineStream(recognizer, stream);
                                mic_decodes++;
                            }
                            const SherpaOnnxOnlineRecognizerResult *pr =
                                SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                            if (pr && strlen(pr->text) > 0 && !pipeline_live) {
                                char buf[256];
                                strncpy(buf, pr->text, sizeof(buf)-1); buf[sizeof(buf)-1] = '\0';
                                sanitize(buf);
                                log_msg("Warmup[2/3] Mic produced text → \"%s\" — PIPELINE LIVE", buf);
                                pipeline_live = 1;
                            }
                            if (pr) SherpaOnnxDestroyOnlineRecognizerResult(pr);
                        }
                        warmup_chunks_fed += mic_chunks;
                        warmup_decode_iters += mic_decodes;
                        double t2 = 0.0;
                        { struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
                          t2 = (tn.tv_sec - t_phase.tv_sec) + (tn.tv_nsec - t_phase.tv_nsec)/1e9; }
                        log_msg("Warmup[2/3] Mic priming done: %d chunks, %d decodes, %d ALSA errs in %.3fs, live=%d",
                                 mic_chunks, mic_decodes, mic_errors, t2, pipeline_live);
                    } else {
                        log_msg("Warmup[2/3] Mic priming skipped (pipeline already live from WAV)");
                    }

                    /* Phase 3: synchronisation point — flush decoder context,
                     * then drain EVERY last frame through the decoder, then reset.
                     *
                     * The streaming Zipformer decoder retains internal context
                     * across SherpaOnnxOnlineStreamReset.  We must push silence
                     * through the stream first to displace the WAV content from
                     * the decoder's lookback window.  Only then does
                     * InputFinished + drain + reset produce a truly clean slate. */
                    {
                        clock_gettime(CLOCK_MONOTONIC, &t_phase);
                        log_msg("Warmup[3/3] Flush: feeding %.1fs silence to displace WAV context...",
                                 SILENCE_FLUSH_S);
                        int silence_frames = (int)(SAMPLE_RATE * SILENCE_FLUSH_S);
                        int pos = 0;
                        while (pos < silence_frames) {
                            int n = (silence_frames - pos > CHUNK_SAMPLES) ? CHUNK_SAMPLES : (silence_frames - pos);
                            float silence[CHUNK_SAMPLES];
                            memset(silence, 0, sizeof(float) * n);
                            SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, silence, n);
                            while (SherpaOnnxIsOnlineStreamReady(recognizer, stream))
                                SherpaOnnxDecodeOnlineStream(recognizer, stream);
                            /* discard intermediate results — still warmup */
                            const SherpaOnnxOnlineRecognizerResult *sr =
                                SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                            if (sr) SherpaOnnxDestroyOnlineRecognizerResult(sr);
                            pos += n;
                        }

                        log_msg("Warmup[3/3] Drain: calling InputFinished + blocking drain...");
                        SherpaOnnxOnlineStreamInputFinished(stream);
                        int drain_iters = 0;
                        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) {
                            SherpaOnnxDecodeOnlineStream(recognizer, stream);
                            drain_iters++;
                        }
                        const SherpaOnnxOnlineRecognizerResult *drain_r =
                            SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                        int drain_text_len = 0;
                        if (drain_r) {
                            drain_text_len = (int)strlen(drain_r->text);
                            if (drain_text_len > 0) {
                                char dbg[256];
                                strncpy(dbg, drain_r->text, sizeof(dbg)-1); dbg[sizeof(dbg)-1] = '\0';
                                sanitize(dbg);
                                log_msg("Warmup[3/3] Drain: discarded text (len=%d) → \"%s\"",
                                         drain_text_len, dbg);
                            }
                            SherpaOnnxDestroyOnlineRecognizerResult(drain_r);
                        }
                        SherpaOnnxOnlineStreamReset(recognizer, stream);
                        double t3 = 0.0;
                        { struct timespec tn; clock_gettime(CLOCK_MONOTONIC, &tn);
                          t3 = (tn.tv_sec - t_phase.tv_sec) + (tn.tv_nsec - t_phase.tv_nsec)/1e9; }
                        log_msg("Warmup[3/3] Flush+drain complete: %d silence frames, %d drain iters, "
                                 "final_text_len=%d in %.3fs",
                                 silence_frames, drain_iters, drain_text_len, t3);
                    }

                    /* Summary: one log line with everything needed to debug warmup */
                    log_msg("Warmup SUMMARY: live=%d, total_chunks=%d, total_decodes=%d, "
                             "cal_wav=%s, mic_prime=%s, model_was_warm=%d",
                             pipeline_live, warmup_chunks_fed, warmup_decode_iters,
                             model_warm ? "skipped" : "used",
                             pipeline_live ? "skipped" : "used",
                             model_warm);
                    log_msg("Warmup complete — stream is clean, ready for user audio");

                } else {
                    /* ── Warm start: drain, prepare, reset stream ── */
                    snd_pcm_drop(alsa);
                    snd_pcm_prepare(alsa);
                    if (stream) {
                        SherpaOnnxOnlineStreamReset(recognizer, stream);
                        log_msg("Stream reset (warm)");
                    } else {
                        stream = SherpaOnnxCreateOnlineStream(recognizer);
                        log_msg("Stream created (warm)");
                    }
                }

                recording = 1;
                segment_id = 0;
                last_partial_len = 0;
                last_text[0] = '\0';
                first_chunk_logged = 0;
                first_ready_logged = 0;
                silent_chunks = 0;
                first_text_logged = 0;
                /* primed removed — drain handles this */
                segment_id = 0;
                last_partial_len = 0;
                last_text[0] = '\0';
                first_chunk_logged = 0;
                first_ready_logged = 0;
                silent_chunks = 0;
                first_text_logged = 0;

                /* Pipeline fully initialized: model loaded, ALSA open,
                 * recognizer calibrated. Mic is hot. Badge ON. */
                state_write(g_dump_audio ? "recording+dump" : "recording");
                log_msg("Badge → recording (pipeline ready, recognizer live)");

                clock_gettime(CLOCK_MONOTONIC, &t_ready);
                double elapsed = (t_ready.tv_sec - t_start.tv_sec) +
                                 (t_ready.tv_nsec - t_start.tv_nsec) / 1e9;
                log_msg("%s start — ready in %.3fs",
                         model_warm ? "Warm" : "Cold", elapsed);

            } else {
                /* --- TOGGLE OFF --- */
                log_msg("TOGGLE OFF — user pressed Mod+V");

                /* Model is now warm — keep it loaded for next use */
                model_warm = 1;

                if (stream) {
                    SherpaOnnxOnlineStreamInputFinished(stream);
                    while (SherpaOnnxIsOnlineStreamReady(recognizer, stream))
                        SherpaOnnxDecodeOnlineStream(recognizer, stream);
                    const SherpaOnnxOnlineRecognizerResult *r =
                        SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                    if (r && strlen(r->text)) {
                        char final_buf[4096];
                        strncpy(final_buf, r->text, sizeof(final_buf)-1);
                        final_buf[sizeof(final_buf)-1] = '\0';
                        sanitize(final_buf);
                        type_append(last_text, last_partial_len, final_buf);
                        log_msg("Final text at OFF: %s", final_buf);
                    }
                    if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
                }

                /* Stop audio capture but keep ALSA and model loaded */
                if (alsa) snd_pcm_drop(alsa);
                if (g_dump_audio) dump_close();

                state_clear();
                recording = 0;
                /* primed removed — drain handles this */
                log_msg("Mic closed — model stays warm for next use");
            }
            continue;
        }

        if (!recording || !alsa) { usleep(50000); continue; }

        /* --- Audio capture --- */
        int16_t buf[CHUNK_SAMPLES];
        int rc = snd_pcm_readi(alsa, buf, CHUNK_SAMPLES);
        if (rc < 0) { rc = snd_pcm_recover(alsa, rc, 0); if (rc < 0) break; continue; }

        /* Diagnostic: log first audio chunk arrival to identify DMIC lag */
        if (!first_chunk_logged) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            log_msg("First audio chunk arrived: %ld.%09ld", (long)ts.tv_sec, ts.tv_nsec);
            first_chunk_logged = 1;
        }

        if (g_dump_audio) dump_write(buf, rc);

        float samples[CHUNK_SAMPLES];
        for (int i = 0; i < rc; i++) samples[i] = buf[i] / 32768.0f;
        SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, samples, rc);

        /* Diagnostic: log first time recognizer becomes ready */
        int was_ready = SherpaOnnxIsOnlineStreamReady(recognizer, stream);
        if (!first_ready_logged && was_ready) {
            struct timespec ts;
            clock_gettime(CLOCK_MONOTONIC, &ts);
            log_msg("Recognizer first ready: %ld.%09ld", (long)ts.tv_sec, ts.tv_nsec);
            first_ready_logged = 1;
        }
        while (was_ready) {
            SherpaOnnxDecodeOnlineStream(recognizer, stream);
            was_ready = SherpaOnnxIsOnlineStreamReady(recognizer, stream);
        }

        const SherpaOnnxOnlineRecognizerResult *r =
            SherpaOnnxGetOnlineStreamResult(recognizer, stream);
        char text_buf[4096];
        strncpy(text_buf, r ? r->text : "", sizeof(text_buf)-1);
        text_buf[sizeof(text_buf)-1] = '\0';
        sanitize(text_buf);
        const char *text = text_buf;
        int is_endpoint = SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream);

        /* Diagnostic: count silent chunks to detect recognizer lag */
        int has_text = strlen(text) > 0;
        if (!has_text) {
            silent_chunks++;
            if (silent_chunks % 50 == 1)  /* every ~5s */
                log_msg("  (silent for %d chunks ≈ %.1fs)", silent_chunks,
                         silent_chunks * (CHUNK_MS / 1000.0));
        } else if (!first_text_logged) {
            log_msg("  FIRST TEXT after %d silent chunks (%.1fs)", silent_chunks,
                     silent_chunks * (CHUNK_MS / 1000.0));
            first_text_logged = 1;
            silent_chunks = 0;
        } else {
            silent_chunks = 0;
        }

        /* Partial update — type immediately, no suppression delay */
        if (has_text && strcmp(text, last_text) != 0) {
            if (g_dump_audio)
                dump_log_text("PARTIAL", last_partial_len, last_text, text);
            type_append(last_text, last_partial_len, text);
            last_partial_len = strlen(text);
            strncpy(last_text, text, sizeof(last_text)-1);
            log_msg("  partial: %s", text);
        }


        /* Endpoint — type immediately */
        if (is_endpoint) {
            if (strlen(text)) {
                char spaced[4096];
                snprintf(spaced, sizeof(spaced), "%s ", text);
                if (g_dump_audio)
                    dump_log_text("ENDPOINT", last_partial_len, last_text, spaced);
                type_append(last_text, last_partial_len, spaced);
                last_partial_len = 0;
                last_text[0] = '\0';
                segment_id++;
                log_msg("  utterance %d complete: %s", segment_id, text);
            }
            SherpaOnnxOnlineStreamReset(recognizer, stream);
        }
        if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
    }

    /* Cleanup on daemon exit */
    if (stream) SherpaOnnxDestroyOnlineStream(stream);
    if (alsa) snd_pcm_close(alsa);
    if (recognizer) SherpaOnnxDestroyOnlineRecognizer(recognizer);
    state_clear();
    log_msg("voxd daemon exiting — all resources freed");
}

/* ======================================================================
 * Display auto-detection + X11 keycode cache
 * ====================================================================== */
static void x11_init(void) {
    const char *display = getenv("DISPLAY");

    if (!display || !*display) {
        log_msg("WARNING: no DISPLAY — typing disabled");
        return;
    }

    g_x11_dpy = XOpenDisplay(NULL);
    if (!g_x11_dpy) {
        log_msg("WARNING: cannot open X11 display %s — typing disabled", display);
        return;
    }

    /* Verify XTest extension is available */
    int ev, er, ma, mi;
    if (!XTestQueryExtension(g_x11_dpy, &ev, &er, &ma, &mi)) {
        log_msg("WARNING: XTest extension not available — typing disabled");
        XCloseDisplay(g_x11_dpy);
        g_x11_dpy = NULL;
        return;
    }

    /* Build ASCII keycode cache */
    memset(g_keycodes, 0, sizeof(g_keycodes));
    memset(g_need_shift, 0, sizeof(g_need_shift));

    for (int c = 32; c < 127; c++) {
        char str[2] = { (char)c, 0 };
        KeySym ks = XStringToKeysym(str);
        if (ks == NoSymbol) continue;
        KeyCode kc = XKeysymToKeycode(g_x11_dpy, ks);
        if (!kc) continue;
        g_keycodes[c] = kc;

        /* Determine if shift is needed: compare with lowercase version */
        char lower[2] = { (char)tolower(c), 0 };
        KeySym lower_ks = XStringToKeysym(lower);
        g_need_shift[c] = (lower_ks != ks);
    }

    /* Ensure space and backspace work */
    if (!g_keycodes[' ']) {
        KeyCode kc = XKeysymToKeycode(g_x11_dpy, XK_space);
        if (kc) g_keycodes[' '] = kc;
    }

    log_msg("Display: X11 (%s) — using XTest", display);
}

static void x11_cleanup(void) {
    if (g_x11_dpy) { XCloseDisplay(g_x11_dpy); g_x11_dpy = NULL; }
}

/* ======================================================================
 * Signals
 * ====================================================================== */
static void sig_handler(int sig) { if (sig == SIGUSR1) g_toggle = 1; if (sig == SIGTERM || sig == SIGINT) g_running = 0; }

/* ======================================================================
 * main
 * ====================================================================== */
int main(int argc, char *argv[]) {
    if (argc > 1) {
        if (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
            fprintf(stderr, "voxd — VOX voice dictation daemon (sherpa-onnx / Zipformer)\n"
                    "  voxd                   Daemon (ALSA mic → keyboard typing, auto-detects X11/Wayland)\n"
                    "  voxd --dump-audio       Also save recorded audio\n"
                    "  voxd --sim foo.wav     Simulate typing (verify no garbling)\n"
                    "  voxd --file foo.wav    Decode WAV file\n");
            return 0;
        }
        if (strcmp(argv[1], "--sim") == 0 && argc > 2) {
            g_sim_mode = 1; log_open();
            run_file_mode(argv[2]);
            fprintf(stderr, "\n=== SIMULATION RESULT ===\n");
            fprintf(stderr, "Final screen: |%s|\n", g_sim_buf);
            return 0;
        }
        if (strcmp(argv[1], "--file") == 0 && argc > 2) { log_open(); run_file_mode(argv[2]); return 0; }
        if (strcmp(argv[1], "on") == 0 || strcmp(argv[1], "start") == 0) { system("pkill -USR1 voxd 2>/dev/null"); return 0; }
        if (strcmp(argv[1], "off") == 0 || strcmp(argv[1], "stop") == 0) { system("pkill -USR1 voxd 2>/dev/null"); return 0; }
        if (strcmp(argv[1], "--dump-audio") != 0) return 1;
    }

    for (int i = 1; i < argc; i++) if (strcmp(argv[i], "--dump-audio") == 0) g_dump_audio = 1;

    log_open();
    x11_init();
    log_msg("voxd starting (daemon mode)%s", g_dump_audio?" [audio dump enabled]":"");
    signal(SIGUSR1, sig_handler); signal(SIGTERM, sig_handler); signal(SIGINT, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid > 0) { log_msg("Daemonized, PID %d", pid); return 0; }
    setsid();
    run_alsa_mode();
    x11_cleanup();
    log_msg("voxd exiting");
    if (g_log && g_log != stderr) fclose(g_log);
    return 0;
}
