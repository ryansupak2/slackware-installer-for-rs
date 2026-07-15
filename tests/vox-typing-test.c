/*
 * vox-typing-test.c — Unit tests for voxd type_replace / display detection
 *
 * Tests the logic for auto-detecting X11 vs Wayland and routing typing
 * to the correct backend (XTest vs wtype).
 *
 * Compile: gcc -Wall -o vox-typing-test vox-typing-test.c
 * Run:     ./vox-typing-test
 *
 * NOTE: This tests the LOGIC, not the actual X11/XTest connection.
 * It simulates the display detection and typing routing.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* ── Simulated environment ─────────────────────────────────────────── */
static char *sim_env_wayland = NULL;
static char *sim_env_display = NULL;

#define getenv_sim(name) \
    (strcmp(name, "WAYLAND_DISPLAY") == 0 ? sim_env_wayland : \
     strcmp(name, "DISPLAY") == 0 ? sim_env_display : NULL)

/* ── State (matching voxd.c) ────────────────────────────────────────── */
static int g_use_wayland = 0;
static int g_x11_available = 0;
static char g_typed_buf[65536];
static int  g_typed_len = 0;

/* ── Detection logic (extracted from voxd.c x11_init) ──────────────── */
static void detect_display(void) {
    const char *wayland = getenv_sim("WAYLAND_DISPLAY");
    if (wayland && *wayland) {
        g_use_wayland = 1;
        return;
    }

    const char *display = getenv_sim("DISPLAY");
    if (display && *display) {
        g_use_wayland = 0;
        g_x11_available = 1;  /* In real code, XOpenDisplay succeeds */
        return;
    }

    g_use_wayland = 0;
    g_x11_available = 0;
}

/* ── Typing routing (extracted from voxd.c type_replace) ───────────── */
static void sim_type(const char *text) {
    if (!text) return;
    if (g_use_wayland) {
        /* Would fork/exec wtype */
        strncat(g_typed_buf, "[WTYPE]", sizeof(g_typed_buf) - g_typed_len - 1);
    } else if (g_x11_available) {
        /* Would use XTest */
        strncat(g_typed_buf, "[XTEST]", sizeof(g_typed_buf) - g_typed_len - 1);
    } else {
        strncat(g_typed_buf, "[NONE]", sizeof(g_typed_buf) - g_typed_len - 1);
    }
    strncat(g_typed_buf, text, sizeof(g_typed_buf) - g_typed_len - 1);
    g_typed_len = strlen(g_typed_buf);
}

/* ── Backspace + text typing (matching voxd's buffer construction) ─── */
static void sim_type_replace(int bs, const char *text) {
    if (bs == 0 && (!text || !*text)) return;
    int tlen = text ? (int)strlen(text) : 0;
    int bufsz = bs + tlen;
    if (bufsz == 0) return;
    char *buf = malloc(bufsz);
    if (!buf) return;
    if (bs > 0) memset(buf, '\b', bs);
    if (tlen > 0) memcpy(buf + bs, text, tlen);

    /* Simulate what type_replace does with buf */
    for (int i = 0; i < bufsz; i++) {
        if (buf[i] == '\b') {
            sim_type("[BS]");
        } else {
            char tmp[2] = {buf[i], 0};
            sim_type(tmp);
        }
    }
    free(buf);
}

/* ── Test framework ────────────────────────────────────────────────── */
static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) \
    do { \
        printf("\n─── TEST %d: %s ───\n", ++tests_run, name); \
    } while(0)

#define ASSERT_INT(want, got, label) \
    do { \
        if ((want) != (got)) { \
            printf("  FAIL: %s: expected %d, got %d\n", label, want, got); \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define ASSERT_STR(want, got, label) \
    do { \
        if (strcmp((want), (got)) != 0) { \
            printf("  FAIL: %s:\n    expected: |%s|\n    got:      |%s|\n", label, want, got); \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define PASS() \
    do { tests_passed++; printf("  PASS\n"); } while(0)

/* ── Test helpers ──────────────────────────────────────────────────── */
static void reset_state(void) {
    g_use_wayland = 0;
    g_x11_available = 0;
    g_typed_buf[0] = '\0';
    g_typed_len = 0;
    sim_env_wayland = NULL;
    sim_env_display = NULL;
}

/* ══════════════════════════════════════════════════════════════════════
 * TESTS
 * ══════════════════════════════════════════════════════════════════════ */

/* Test 1: X11 detection when DISPLAY is set */
static void test_01_x11_detection(void) {
    TEST("X11 detected when DISPLAY=:0 and no WAYLAND_DISPLAY");
    reset_state();
    sim_env_display = ":0";
    sim_env_wayland = NULL;
    detect_display();
    ASSERT_INT(0, g_use_wayland, "g_use_wayland");
    ASSERT_INT(1, g_x11_available, "g_x11_available");
    PASS();
}

/* Test 2: Wayland detection when WAYLAND_DISPLAY is set */
static void test_02_wayland_detection(void) {
    TEST("Wayland detected when WAYLAND_DISPLAY=wayland-0");
    reset_state();
    sim_env_display = ":0";
    sim_env_wayland = "wayland-0";
    detect_display();
    ASSERT_INT(1, g_use_wayland, "g_use_wayland");
    PASS();
}

/* Test 3: No display — typing disabled */
static void test_03_no_display(void) {
    TEST("No DISPLAY or WAYLAND_DISPLAY → typing disabled");
    reset_state();
    sim_env_display = NULL;
    sim_env_wayland = NULL;
    detect_display();
    ASSERT_INT(0, g_use_wayland, "g_use_wayland");
    ASSERT_INT(0, g_x11_available, "g_x11_available");
    PASS();
}

/* Test 4: X11 typing routes through [XTEST] */
static void test_04_x11_typing_routes_to_xtest(void) {
    TEST("X11 typing uses XTest (not wtype)");
    reset_state();
    sim_env_display = ":0";
    detect_display();
    sim_type_replace(0, "hello");
    ASSERT_STR("[XTEST]h[XTEST]e[XTEST]l[XTEST]l[XTEST]o", g_typed_buf, "typed output");
    PASS();
}

/* Test 5: Wayland typing routes through [WTYPE] */
static void test_05_wayland_typing_routes_to_wtype(void) {
    TEST("Wayland typing uses wtype");
    reset_state();
    sim_env_wayland = "wayland-0";
    detect_display();
    sim_type_replace(0, "hello");
    ASSERT_STR("[WTYPE]h[WTYPE]e[WTYPE]l[WTYPE]l[WTYPE]o", g_typed_buf, "typed output");
    PASS();
}

/* Test 6: Backspace + text replacement */
static void test_06_backspace_and_text(void) {
    TEST("Backspace + text replacement buffer construction");
    reset_state();
    sim_env_display = ":0";
    detect_display();
    /* Simulate: replace 5 chars with backspace, then type "world" */
    sim_type_replace(5, "world");
    ASSERT_STR("[XTEST][BS][XTEST][BS][XTEST][BS][XTEST][BS][XTEST][BS][XTEST]w[XTEST]o[XTEST]r[XTEST]l[XTEST]d", g_typed_buf, "typed output");
    PASS();
}

/* Test 7: Empty text + no backspace = no-op */
static void test_07_empty_noop(void) {
    TEST("Empty text with no backspace is a no-op");
    reset_state();
    sim_env_display = ":0";
    detect_display();
    sim_type_replace(0, "");
    ASSERT_STR("", g_typed_buf, "typed output (should be empty)");
    PASS();
}

/* Test 8: Normal dictation appends suffix only (no backspace) */
static void test_08_append_incremental(void) {
    TEST("Incremental appends: suffix-only typing (no backspace)");
    reset_state();
    sim_env_display = ":0";
    detect_display();
    /* First partial: "is this" */
    sim_type_replace(0, "is this");
    char after_first[65536];
    strcpy(after_first, g_typed_buf);

    /* Second partial: "is this working" — only " working" is new */
    const char *old_text = "is this";
    const char *new_text = "is this working";
    int old_len = strlen(old_text);
    int new_len = strlen(new_text);
    if (new_len > old_len) {
        const char *suffix = new_text + old_len;
        sim_type_replace(0, suffix);
    }

    /* Should have both appends, no backspaces.
     * Each character gets its own [XTEST] since XTest handles key events individually. */
    char expected[65536];
    snprintf(expected, sizeof(expected), "%s[XTEST] [XTEST]w[XTEST]o[XTEST]r[XTEST]k[XTEST]i[XTEST]n[XTEST]g", after_first);
    ASSERT_STR(expected, g_typed_buf, "incremental typing");
    PASS();
}

int main(void) {
    printf("VOX typing — display detection + routing tests\n");
    printf("==============================================\n");

    test_01_x11_detection();
    test_02_wayland_detection();
    test_03_no_display();
    test_04_x11_typing_routes_to_xtest();
    test_05_wayland_typing_routes_to_wtype();
    test_06_backspace_and_text();
    test_07_empty_noop();
    test_08_append_incremental();

    printf("\n==================================\n");
    printf("RESULTS: %d tests, %d passed, %d failed\n",
           tests_passed + tests_failed, tests_passed, tests_failed);

    return tests_failed > 0 ? 1 : 0;
}
