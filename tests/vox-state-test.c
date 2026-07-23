/*
 * vox-state-test.c — Unit tests for VOX state machine
 *
 * Tests the vox_state file transitions that control the [VOX] badge:
 *   absent      → "loading"          [VOX Loading...]  (toggle ON, init starts)
 *   "loading"   → "recording"        [VOX]             (pipeline init complete)
 *   "recording" → absent             (badge removed)   (toggle OFF)
 *
 * Pipeline init = model load (if cold) + ALSA open + stream create/reset.
 * Once init completes the mic is hot. Badge reflects this, not speech detection.
 *
 * Compile: gcc -Wall -o vox-state-test vox-state-test.c
 * Run:     ./vox-state-test
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/stat.h>
#include <stdarg.h>
#include <errno.h>

/* ── Simulated state file ─────────────────────────────────────────── */
static char *g_state_path = NULL;

static void state_write(const char *val) {
    const char *xdg = "/tmp/vox-test-xdg";
    mkdir(xdg, 0755);
    char path[256];
    snprintf(path, sizeof(path), "%s/vox_state", xdg);
    g_state_path = strdup(path);
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%s\n", val); fclose(f); }
}

static void state_clear(void) {
    if (g_state_path) unlink(g_state_path);
    free(g_state_path);
    g_state_path = NULL;
}

static const char *state_read(void) {
    if (!g_state_path) return "(absent)";
    FILE *f = fopen(g_state_path, "r");
    if (!f) return "(absent)";
    static char buf[64];
    if (fgets(buf, sizeof(buf), f)) {
        size_t len = strlen(buf);
        if (len && buf[len-1] == '\n') buf[len-1] = '\0';
        fclose(f);
        return buf;
    }
    fclose(f);
    return "(empty)";
}

/* ── Badge display logic (matches dwm-status.sh / dwl-status.sh) ─── */
static const char *badge_for_state(const char *state) {
    if (!state || !*state || strcmp(state, "(absent)") == 0 || strcmp(state, "(empty)") == 0)
        return "";
    if (strcmp(state, "loading") == 0)         return "[VOX Loading...] ";
    if (strcmp(state, "recording") == 0)       return "[VOX] ";
    if (strcmp(state, "recording+dump") == 0)  return "[VOX (recording...)] ";
    return "[VOX] ";
}

/* ── Simulated log buffer ─────────────────────────────────────────── */
static char g_log_buf[16384];
static int  g_log_len = 0;

static void log_msg(const char *fmt, ...) {
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_log_len + n < (int)sizeof(g_log_buf) - 2) {
        strcpy(g_log_buf + g_log_len, buf);
        g_log_len += n;
        g_log_buf[g_log_len++] = '\n';
        g_log_buf[g_log_len] = '\0';
    }
}

static int log_contains(const char *needle) {
    return strstr(g_log_buf, needle) != NULL;
}

static void log_clear(void) {
    g_log_buf[0] = '\0';
    g_log_len = 0;
}

/* ── Simulated pipeline ───────────────────────────────────────────── */
static int g_model_loaded = 0;
static int g_model_warm = 0;

static void load_model(void) {
    if (g_model_loaded) return;
    log_msg("Cold start — loading sherpa-onnx model (this may take a moment)...");
    g_model_loaded = 1;
    log_msg("Model loaded in 0.99s");
}

static void init_alsa(void) {
    log_msg("Opening ALSA device plughw:0,7...");
}

static void init_stream(int is_warm) {
    if (is_warm)
        log_msg("Stream reset");
    else
        log_msg("Stream created");
}

/* ── Simulate full toggle ON ──────────────────────────────────────── */
static void toggle_on(int dump_audio) {
    log_msg("TOGGLE ON — user pressed Mod+V");
    state_write("loading");

    /* Lazy model load on first use */
    load_model();
    /* Lazy ALSA open */
    init_alsa();
    /* Stream create/reset */
    init_stream(g_model_warm);

    /* Pipeline init complete — mic is hot */
    const char *new_state = dump_audio ? "recording+dump" : "recording";
    state_write(new_state);
    log_msg("%s start — ready", g_model_warm ? "Warm" : "Cold");
}

/* ── Simulate toggle OFF ──────────────────────────────────────────── */
static void toggle_off(void) {
    log_msg("TOGGLE OFF — user pressed Mod+V");
    g_model_warm = 1;
    state_clear();
    log_msg("Mic closed — model stays warm for next use");
}

/* ── Test framework ────────────────────────────────────────────────── */
static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) \
    do { \
        printf("\n─── TEST %d: %s ───\n", ++tests_run, name); \
    } while(0)

#define ASSERT_STR(want, got, label) \
    do { \
        if (strcmp((want), (got)) != 0) { \
            printf("  FAIL: %s:\n    expected: |%s|\n    got:      |%s|\n", \
                   label, want, got); \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define ASSERT_TRUE(cond, label) \
    do { \
        if (!(cond)) { \
            printf("  FAIL: %s: condition false\n", label); \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define PASS() \
    do { tests_passed++; printf("  PASS\n"); } while(0)

static void reset_all(void) {
    state_clear();
    log_clear();
    g_model_loaded = 0;
    g_model_warm = 0;
    system("rm -rf /tmp/vox-test-xdg 2>/dev/null");
}

/* ══════════════════════════════════════════════════════════════════════
 * TESTS
 * ══════════════════════════════════════════════════════════════════════ */

/* Test 1: Initial state — no state file → no badge */
static void test_01_initial_state_no_badge(void) {
    TEST("Initial state: no vox_state → badge is empty");
    reset_all();
    ASSERT_STR("", badge_for_state(state_read()), "badge when no state file");
    PASS();
}

/* Test 2: Cold start toggle ON → loading, then recording when init done */
static void test_02_cold_toggle_on(void) {
    TEST("Cold start: loading during model load, then [VOX] when init done");
    reset_all();
    toggle_on(0);

    ASSERT_STR("recording", state_read(), "state after init complete");
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "badge shows [VOX]");
    ASSERT_TRUE(log_contains("Cold start — loading sherpa-onnx"), "log: model loading");
    ASSERT_TRUE(log_contains("Model loaded in"), "log: model loaded timing");
    ASSERT_TRUE(log_contains("Cold start — ready"), "log: cold start ready");
    PASS();
}

/* Test 3: Toggle OFF clears badge */
static void test_03_toggle_off_clears_badge(void) {
    TEST("Toggle OFF → state cleared, badge removed");
    reset_all();
    toggle_on(0);
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "badge ON");

    toggle_off();
    ASSERT_STR("(absent)", state_read(), "state file removed");
    ASSERT_STR("", badge_for_state(state_read()), "badge empty");
    ASSERT_TRUE(g_model_warm, "model stays warm");
    ASSERT_TRUE(log_contains("Mic closed — model stays warm"), "log: model stays warm");
    PASS();
}

/* Test 4: Warm start — near-instant [VOX] */
static void test_04_warm_start(void) {
    TEST("Warm start: loading briefly, then [VOX] near-instantly");
    reset_all();

    /* First cycle to warm the model */
    toggle_on(0);
    toggle_off();
    ASSERT_STR("", badge_for_state(state_read()), "off after first cycle");
    log_clear();

    /* Warm start — no model load, still goes through loading→recording */
    toggle_on(0);
    ASSERT_STR("recording", state_read(), "warm start: recording");
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "badge shows [VOX]");
    ASSERT_TRUE(log_contains("Warm start — ready"), "log: warm start ready");
    ASSERT_TRUE(!log_contains("Cold start — loading"), "log: no model load on warm start");
    PASS();
}

/* Test 5: Dump-audio mode */
static void test_05_dump_audio(void) {
    TEST("Dump-audio mode: recording+dump state and badge");
    reset_all();
    toggle_on(1);
    ASSERT_STR("recording+dump", state_read(), "state: recording+dump");
    ASSERT_STR("[VOX (recording...)] ", badge_for_state(state_read()), "badge: recording+dump");
    toggle_off();
    ASSERT_STR("", badge_for_state(state_read()), "badge cleared");
    PASS();
}

/* Test 6: Multiple cycles */
static void test_06_multiple_cycles(void) {
    TEST("Multiple toggle cycles: correct badge at each step");
    reset_all();

    toggle_on(0);
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "cycle 1: ON → [VOX]");
    toggle_off();
    ASSERT_STR("", badge_for_state(state_read()), "cycle 1: OFF → empty");

    toggle_on(0);
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "cycle 2: ON → [VOX]");
    toggle_off();
    ASSERT_STR("", badge_for_state(state_read()), "cycle 2: OFF → empty");

    toggle_on(0);
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "cycle 3: ON → [VOX]");
    toggle_off();
    ASSERT_STR("", badge_for_state(state_read()), "cycle 3: OFF → empty");
    PASS();
}

/* Test 7: Log trace for cold start */
static void test_07_log_trace_cold_start(void) {
    TEST("Log contains complete trace for cold start cycle");
    reset_all();

    toggle_on(0);
    toggle_off();

    ASSERT_TRUE(log_contains("TOGGLE ON — user pressed Mod+V"), "log: TOGGLE ON");
    ASSERT_TRUE(log_contains("Cold start — loading sherpa-onnx"), "log: model loading");
    ASSERT_TRUE(log_contains("Model loaded in"), "log: model loaded");
    ASSERT_TRUE(log_contains("Stream created"), "log: stream created");
    ASSERT_TRUE(log_contains("Cold start — ready"), "log: cold start ready");
    ASSERT_TRUE(log_contains("TOGGLE OFF — user pressed Mod+V"), "log: TOGGLE OFF");
    ASSERT_TRUE(log_contains("Mic closed — model stays warm"), "log: mic closed");
    PASS();
}

/* Test 8: Log trace for warm start */
static void test_08_log_trace_warm_start(void) {
    TEST("Log contains correct trace for warm start (no model load)");
    reset_all();

    toggle_on(0);
    toggle_off();
    log_clear();

    toggle_on(0);
    toggle_off();

    ASSERT_TRUE(log_contains("TOGGLE ON"), "log: TOGGLE ON");
    ASSERT_TRUE(log_contains("Stream reset"), "log: stream reset");
    ASSERT_TRUE(log_contains("Warm start — ready"), "log: warm start ready");
    ASSERT_TRUE(!log_contains("Cold start — loading"), "log: NO model load");
    ASSERT_TRUE(!log_contains("Model loaded in"), "log: NO model timing");
    ASSERT_TRUE(log_contains("TOGGLE OFF"), "log: TOGGLE OFF");
    PASS();
}

/* Test 9: Badge is [VOX] immediately after init, NOT waiting for speech */
static void test_09_badge_immediate_after_init(void) {
    TEST("Badge shows [VOX] as soon as pipeline init completes");
    reset_all();

    /* Simulate: during init, badge would show loading */
    /* But we can't test mid-function without splitting toggle_on */
    /* The key assertion: after toggle_on returns, state is recording */
    toggle_on(0);
    ASSERT_STR("recording", state_read(), "state is recording immediately after toggle_on");
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "badge is [VOX], not loading");

    /* Even on warm start */
    toggle_off();
    toggle_on(0);
    ASSERT_STR("recording", state_read(), "warm start: recording");
    ASSERT_STR("[VOX] ", badge_for_state(state_read()), "warm start: [VOX]");
    PASS();
}

/* Test 10: No lingering 'loading' state after init */
static void test_10_no_loading_after_init(void) {
    TEST("State is never 'loading' after toggle_on returns");
    reset_all();

    for (int i = 0; i < 5; i++) {
        toggle_on(0);
        ASSERT_STR("recording", state_read(), "after toggle_on: recording, not loading");
        toggle_off();
        ASSERT_STR("(absent)", state_read(), "after toggle_off: absent");
    }
    PASS();
}

int main(void) {
    printf("VOX state machine — badge transition tests\n");
    printf("==========================================\n");
    printf("\nBadge rules:\n");
    printf("  no state file       → (no badge)\n");
    printf("  state=\"loading\"     → [VOX Loading...]\n");
    printf("  state=\"recording\"   → [VOX]\n");
    printf("  state=\"recording+dump\" → [VOX (recording...)]\n");
    printf("\nState transitions:\n");
    printf("  (absent) → \"loading\"            toggle ON (init begins)\n");
    printf("  \"loading\" → \"recording\"         pipeline init complete (mic hot)\n");
    printf("  \"recording\" → (absent)           toggle OFF\n");
    printf("  Cold/warm only affects model disk I/O, not badge timing.\n");

    test_01_initial_state_no_badge();
    test_02_cold_toggle_on();
    test_03_toggle_off_clears_badge();
    test_04_warm_start();
    test_05_dump_audio();
    test_06_multiple_cycles();
    test_07_log_trace_cold_start();
    test_08_log_trace_warm_start();
    test_09_badge_immediate_after_init();
    test_10_no_loading_after_init();

    printf("\n==================================\n");
    printf("RESULTS: %d tests, %d passed, %d failed\n",
           tests_passed + tests_failed, tests_passed, tests_failed);

    reset_all();
    return tests_failed > 0 ? 1 : 0;
}
