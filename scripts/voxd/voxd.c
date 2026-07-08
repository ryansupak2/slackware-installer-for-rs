/*
 * voxd.c — VOX voice dictation daemon (sherpa-onnx / streaming Zipformer)
 *
 * Sim mode:  voxd --sim foo.wav   — same code path as live, no wtype
 * File mode: voxd --file foo.wav  — decode WAV, no typing
 * Daemon:    voxd                 — ALSA mic → wtype
 *
 * Architecture:
 *   type_append(old, len, new) → computes suffix → type_replace(0, suffix)
 *   type_replace(bs, text)     → sim appends to buffer, real forks wtype
 *
 * One code path. Sim mode only changes the bottom of type_replace.
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

#include <alsa/asoundlib.h>
#include <sherpa-onnx/c-api/c-api.h>

/* ======================================================================
 * Config
 * ====================================================================== */

#define MODEL_DIR  "/usr/local/share/vox/sherpa-onnx-streaming-zipformer-en-20M-2023-02-17"
#define TOKENS     MODEL_DIR "/tokens.txt"
#define ENCODER    MODEL_DIR "/encoder-epoch-99-avg-1.onnx"
#define DECODER    MODEL_DIR "/decoder-epoch-99-avg-1.onnx"
#define JOINER     MODEL_DIR "/joiner-epoch-99-avg-1.onnx"

#define ALSA_DEVICE      "plughw:0,7"
#define SAMPLE_RATE      16000
#define CHANNELS         1
#define CHUNK_MS         100
#define CHUNK_SAMPLES    (SAMPLE_RATE * CHUNK_MS / 1000)

#define ENDPOINT_SILENCE 0.6
#define MAX_UTTERANCE 20.0
#define NUM_THREADS      2

#define WTYPE_BIN "/usr/bin/wtype"
#define WARMUP_FILE "/tmp/warmup.raw"
#define WARMUP_SAMPLES 80000

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

static float *g_warmup = NULL;
static int   g_warmup_count = 0;

/* ======================================================================
 * Logging
 * ====================================================================== */
static void log_msg(const char *fmt, ...) {
    if (!g_log) {
        const char *home = getenv("HOME"); if (!home) home = "/root";
        char buf[512]; snprintf(buf, sizeof(buf), "%s/logs", home);
        mkdir(buf, 0755); snprintf(buf, sizeof(buf), "%s/logs/vox.log", home);
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
 * Warmup
 * ====================================================================== */
static void warmup_load(void) {
    FILE *f = fopen(WARMUP_FILE, "rb");
    if (!f) { log_msg("WARNING: no warmup file"); return; }
    g_warmup = malloc(WARMUP_SAMPLES * sizeof(float));
    if (!g_warmup) { fclose(f); return; }
    g_warmup_count = fread(g_warmup, sizeof(float), WARMUP_SAMPLES, f);
    fclose(f);
    log_msg("Warmup loaded: %d samples (%.1fs)", g_warmup_count, (float)g_warmup_count/SAMPLE_RATE);
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
 * Core: type_replace — sim appends to buffer, real forks wtype
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

    log_msg("[WTYPE] replace bs=%d + %d chars", bs, tlen);

    pid_t pid = fork();
    if (pid == 0) {
        int pipefd[2];
        if (pipe(pipefd) != 0) _exit(1);
        pid_t writer = fork();
        if (writer == 0) {
            close(pipefd[0]);
            write(pipefd[1], buf, bufsz);
            close(pipefd[1]);
            _exit(0);
        }
        close(pipefd[1]);
        dup2(pipefd[0], STDIN_FILENO);
        close(pipefd[0]);
        execl(WTYPE_BIN, "wtype", "-", (char *)NULL);
        _exit(1);
    }
    free(buf);
    if (pid > 0) {
        int status; waitpid(pid, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) != 0)
            log_msg("[WTYPE ERROR] exit=%d", WEXITSTATUS(status));
    }
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
    const char *home = getenv("HOME"); if (!home) home = "/root";
    time_t now = time(NULL); struct tm tm; localtime_r(&now, &tm);
    snprintf(g_dump_path, sizeof(g_dump_path), "%s/logs/vox-%04d%02d%02d-%02d%02d%02d.wav",
             home, tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
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
    snprintf(g_dump_txt_path, sizeof(g_dump_txt_path), "%s/logs/vox-%04d%02d%02d-%02d%02d%02d.txt",
             home, tm.tm_year+1900, tm.tm_mon+1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec);
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
    int last_partial_len = 0; /* BUG */

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
    const SherpaOnnxOnlineRecognizer *recognizer = recognizer_create();
    if (!recognizer) { log_msg("FATAL: no recognizer"); return; }

    snd_pcm_t *alsa = NULL;
    const SherpaOnnxOnlineStream *stream = NULL;
    int recording = 0, segment_id = 0, last_partial_len = 0, suppress_first = 0;
    char last_text[4096] = {0};

    while (g_running) {
        if (g_toggle) {
            g_toggle = 0;
            if (!recording) {
                /* --- TOGGLE ON --- */
                log_msg("ON"); state_write("loading");
                if (g_dump_audio) dump_open();
                stream = SherpaOnnxCreateOnlineStream(recognizer);

                /* Warmup: feed 5s audio to prime model */
                if (g_warmup && g_warmup_count > 0) {
                    int pos = 0, chunk = CHUNK_SAMPLES;
                    while (pos < g_warmup_count) {
                        int n = (pos+chunk > g_warmup_count) ? g_warmup_count-pos : chunk;
                        SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, g_warmup+pos, n);
                        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
                        const SherpaOnnxOnlineRecognizerResult *wr = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                        if (wr) SherpaOnnxDestroyOnlineRecognizerResult(wr);
                        pos += n;
                    }
                    /* Flush residue with silence */
                    { float z[1600] = {0}; int flushed = 0;
                      for (int fi = 0; fi < 50 && !flushed; fi++) {
                          SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, z, 1600);
                          while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
                          if (SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream)) {
                              const SherpaOnnxOnlineRecognizerResult *wr = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                              if (wr) { log_msg("  [flushed] %s", wr->text); SherpaOnnxDestroyOnlineRecognizerResult(wr); }
                              SherpaOnnxOnlineStreamReset(recognizer, stream);
                              flushed = 1;
                          }
                      }
                    }
                    log_msg("Warmup complete — stream primed");
                }

                /* Open ALSA AFTER warmup so ring buffer doesn't overflow */
                alsa = alsa_open();
                if (!alsa) {
                    SherpaOnnxDestroyOnlineStream(stream); stream = NULL;
                    state_clear(); continue;
                }

                recording = 1; segment_id = 0; last_partial_len = 0;
                suppress_first = 1; last_text[0] = '\0';
                state_write(g_dump_audio ? "recording+dump" : "recording");
                log_msg("Recording started (streaming Zipformer)%s", g_dump_audio?" [audio dump enabled]":"");
            } else {
                /* --- TOGGLE OFF --- */
                log_msg("OFF");
                if (stream) {
                    SherpaOnnxOnlineStreamInputFinished(stream);
                    while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);
                    const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
                    if (r && strlen(r->text)) {
                        char final_buf[4096]; strncpy(final_buf, r->text, sizeof(final_buf)-1); final_buf[sizeof(final_buf)-1]='\0';
                        sanitize(final_buf);
                        type_append(last_text, last_partial_len, final_buf);
                    }
                    if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
                    SherpaOnnxDestroyOnlineStream(stream); stream = NULL;
                }
                if (alsa) { snd_pcm_close(alsa); alsa = NULL; }
                if (g_dump_audio) dump_close();
                state_clear(); recording = 0;
            }
            continue;
        }

        if (!recording || !alsa) { usleep(50000); continue; }

        /* --- Audio capture --- */
        int16_t buf[CHUNK_SAMPLES];
        int rc = snd_pcm_readi(alsa, buf, CHUNK_SAMPLES);
        if (rc < 0) { rc = snd_pcm_recover(alsa, rc, 0); if (rc < 0) break; continue; }
        if (g_dump_audio) dump_write(buf, rc);

        float samples[CHUNK_SAMPLES];
        for (int i = 0; i < rc; i++) samples[i] = buf[i] / 32768.0f;
        SherpaOnnxOnlineStreamAcceptWaveform(stream, SAMPLE_RATE, samples, rc);
        while (SherpaOnnxIsOnlineStreamReady(recognizer, stream)) SherpaOnnxDecodeOnlineStream(recognizer, stream);

        const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(recognizer, stream);
        char text_buf[4096]; strncpy(text_buf, r?r->text:"", sizeof(text_buf)-1); text_buf[sizeof(text_buf)-1]='\0';
        sanitize(text_buf);
        const char *text = text_buf;
        int is_endpoint = SherpaOnnxOnlineStreamIsEndpoint(recognizer, stream);
        /* Partial update */
        if (strlen(text) && strcmp(text, last_text) != 0) {
    log_msg("  [DBG] suppress_first=%d text=%s", suppress_first, text);
            if (suppress_first) {
                suppress_first = 0;
                log_msg("  [suppressed] partial: %s", text);
            } else {
                if (g_dump_audio) dump_log_text("PARTIAL", last_partial_len, last_text, text);
                type_append(last_text, last_partial_len, text);
                last_partial_len = strlen(text);
                strncpy(last_text, text, sizeof(last_text)-1);
                log_msg("  partial: %s", text);
            }
        }

        /* Endpoint */
        if (is_endpoint) {
            if (strlen(text)) {
    log_msg("  [DBG] suppress_first=%d text=%s", suppress_first, text);
                if (suppress_first) {
                    suppress_first = 0;
                    log_msg("  [suppressed] endpoint: %s", text);
                } else {
                    char spaced[4096]; snprintf(spaced, sizeof(spaced), "%s ", text);
                    if (g_dump_audio) dump_log_text("ENDPOINT", last_partial_len, last_text, spaced);
                    type_append(last_text, last_partial_len, spaced);
                }
                last_partial_len = 0;
            SherpaOnnxOnlineStreamReset(recognizer, stream);
        }
        if (r) SherpaOnnxDestroyOnlineRecognizerResult(r);
    }

    if (stream) SherpaOnnxDestroyOnlineStream(stream);
    if (alsa) snd_pcm_close(alsa);
    SherpaOnnxDestroyOnlineRecognizer(recognizer);
    state_clear();
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
                    "  voxd                   Daemon (ALSA mic → wtype)\n"
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
    log_msg("voxd starting (daemon mode)%s", g_dump_audio?" [audio dump enabled]":"");
    warmup_load();
    signal(SIGUSR1, sig_handler); signal(SIGTERM, sig_handler); signal(SIGINT, sig_handler);
    signal(SIGPIPE, SIG_IGN);

    pid_t pid = fork();
    if (pid < 0) return 1;
    if (pid > 0) { log_msg("Daemonized, PID %d", pid); return 0; }
    setsid();
    run_alsa_mode();
    log_msg("voxd exiting");
    if (g_log && g_log != stderr) fclose(g_log);
    return 0;
}
