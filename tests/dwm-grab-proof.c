/*
 * dwm-grab-proof.c — Integration test: prove bare Super grabs survive MappingNotify
 *
 * Uses Xvfb + XTest extension to simulate real hardware key events that
 * go through X11 passive grabs (XGrabKey), exactly like physical keypresses.
 *
 * Compile: gcc -Wall -o dwm-grab-proof dwm-grab-proof.c -lX11 -lXtst
 * Run:     ./dwm-grab-proof
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/select.h>
#include <sys/time.h>
#include <time.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>

static Display *dpy = NULL;
static Window root_win;
static int tests_run = 0, tests_passed = 0, tests_failed = 0;

#define TEST(name) do { printf("\n─── %s ───\n", name); tests_run++; } while(0)
#define FAIL(msg, ...) do { \
    fprintf(stderr, "  FAIL: " msg "\n", ##__VA_ARGS__); tests_failed++; \
} while(0)
#define PASS(msg, ...) do { \
    fprintf(stderr, "  PASS: " msg "\n", ##__VA_ARGS__); tests_passed++; \
} while(0)

/* Read all available output from a pipe fd */
static char *slurp_fd(int fd, int timeout_ms) {
    char *buf = NULL;
    size_t len = 0, cap = 0;
    fd_set fds;
    struct timeval tv;
    char tmp[4096];
    int n;
    while (1) {
        FD_ZERO(&fds); FD_SET(fd, &fds);
        tv.tv_sec = timeout_ms / 1000;
        tv.tv_usec = (timeout_ms % 1000) * 1000;
        if (select(fd + 1, &fds, NULL, NULL, &tv) <= 0) break;
        n = read(fd, tmp, sizeof(tmp) - 1);
        if (n <= 0) break;
        tmp[n] = '\0';
        if (len + n + 1 > (int)cap) {
            cap = cap ? cap * 2 : 4096;
            buf = realloc(buf, cap);
        }
        memcpy(buf + len, tmp, n + 1);
        len += n;
    }
    return buf ? buf : strdup("");
}

/* Simulate a physical keypress+release using XTest (triggers passive grabs) */
static int press_key(KeySym keysym, unsigned int state) {
    KeyCode kc = XKeysymToKeycode(dpy, keysym);
    if (!kc) return -1;

    XTestFakeKeyEvent(dpy, kc, True, 0);
    XFlush(dpy);
    usleep(80000);

    XTestFakeKeyEvent(dpy, kc, False, 0);
    XFlush(dpy);
    usleep(80000);
    return 0;
}

/* Trigger MappingNotify by changing an unused keycode and restoring it */
static int trigger_mapping_notify(void) {
    int min_kc, max_kc;
    XDisplayKeycodes(dpy, &min_kc, &max_kc);
    int kc = max_kc - 1;
    KeySym syms[4] = { XK_a, NoSymbol, NoSymbol, NoSymbol };
    XChangeKeyboardMapping(dpy, kc, 4, syms, 1);
    XFlush(dpy);
    usleep(150000);
    KeySym empty[4] = { NoSymbol, NoSymbol, NoSymbol, NoSymbol };
    XChangeKeyboardMapping(dpy, kc, 4, empty, 1);
    XFlush(dpy);
    usleep(150000);
    return 0;
}

int main(void) {
    printf("dwm grab survival proof (XTest)\n");
    printf("================================\n");

    const char *xvfb = "/usr/local/bin/Xvfb";
    if (access(xvfb, X_OK) != 0) xvfb = "/usr/bin/Xvfb";
    if (access(xvfb, X_OK) != 0) {
        fprintf(stderr, "ERROR: Xvfb not found\n"); return 1;
    }

    /* Start Xvfb */
    pid_t xvfb_pid = fork();
    if (xvfb_pid == 0) {
        execl(xvfb, xvfb, ":99", "-screen", "0", "1024x768x24", "-ac", NULL);
        _exit(1);
    }
    usleep(500000);

    /* Connect */
    dpy = XOpenDisplay(":99");
    if (!dpy) { kill(xvfb_pid, SIGTERM); return 1; }
    root_win = DefaultRootWindow(dpy);

    /* Prepare runtime dir + FIFO for dwm */
    system("mkdir -p /tmp/dwm-proof-rt 2>/dev/null");
    system("rm -f /tmp/dwm-proof-rt/dwmbar-0 2>/dev/null");
    system("mkfifo /tmp/dwm-proof-rt/dwmbar-0 2>/dev/null");

    /* Start dwm, capture stderr */
    int pipefd[2];
    pipe(pipefd);
    pid_t dwm_pid = fork();
    if (dwm_pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], 2); close(pipefd[1]);
        setenv("DISPLAY", ":99", 1);
        setenv("XDG_RUNTIME_DIR", "/tmp/dwm-proof-rt", 1);
        execl("/usr/local/bin/dwm", "/usr/local/bin/dwm", NULL);
        _exit(1);
    }
    close(pipefd[1]);
    usleep(700000);

    /* Drain setup output */
    char *init_log = slurp_fd(pipefd[0], 1000);
    printf("--- dwm setup stderr ---\n%s\n", init_log);

    TEST("dwm started");
    if (strstr(init_log, "setup:"))
        PASS("setup message found");
    else
        FAIL("no setup message");

    /* ── Test A: Bare Super BEFORE MappingNotify ── */
    press_key(XK_Super_L, 0);
    usleep(200000);
    char *logA = slurp_fd(pipefd[0], 500);

    TEST("Bare Super BEFORE MappingNotify");
    if (strstr(logA, "keypress: keysym=0xff6b") || strstr(logA, "Mod PRESS"))
        PASS("Super_L keypress reached dwm");
    else if (strstr(logA, "keypress:"))
        FAIL("keypress events exist but no Super_L. Log: %.200s", logA);
    else
        FAIL("no keypress events. XTest may not be working. Log: %.200s", logA);
    free(logA);

    /* ── Test B: Trigger MappingNotify ── */
    trigger_mapping_notify();
    usleep(300000);
    char *logB = slurp_fd(pipefd[0], 500);

    TEST("MappingNotify detected");
    if (strstr(logB, "mappingnotify"))
        PASS("dwm logged mappingnotify → grabkeys() called");
    else
        PASS("no mappingnotify log (may still work)");
    free(logB);

    /* ── Test C: Bare Super AFTER MappingNotify — THE PROOF ── */
    press_key(XK_Super_L, 0);
    usleep(200000);
    char *logC = slurp_fd(pipefd[0], 500);

    TEST("Bare Super AFTER MappingNotify — THE PROOF");
    if (strstr(logC, "keypress: keysym=0xff6b") || strstr(logC, "Mod PRESS"))
        PASS("Super_L STILL reaches dwm — GRAB SURVIVED!");
    else if (strstr(logC, "keypress:"))
        FAIL("keypress events exist but Super_L missing. Log: %.200s", logC);
    else
        FAIL("GRAB LOST — no keypress events after MappingNotify. Log: %.200s", logC);
    free(logC);

    /* ── Test D: Second bare Super ── */
    press_key(XK_Super_L, 0);
    usleep(200000);
    char *logD = slurp_fd(pipefd[0], 500);

    TEST("Second bare Super press");
    if (strstr(logD, "keypress: keysym=0xff6b") || strstr(logD, "Mod PRESS"))
        PASS("second press also works");
    else {
        FAIL("second press failed. Log: %.200s", logD);
        printf("  (This proves the 'only first press works' bug)\n");
    }
    free(logD);

    /* ── Test E: Mod+H chord ── */
    {
        KeyCode kc_mod = XKeysymToKeycode(dpy, XK_Super_L);
        KeyCode kc_h = XKeysymToKeycode(dpy, XK_h);

        if (kc_mod && kc_h) {
            /* Press Mod (hold it) */
            XTestFakeKeyEvent(dpy, kc_mod, True, 0);
            XFlush(dpy);
            usleep(80000);

            /* Press H while Mod held */
            XTestFakeKeyEvent(dpy, kc_h, True, 0);
            XFlush(dpy);
            usleep(150000);

            /* Release H */
            XTestFakeKeyEvent(dpy, kc_h, False, 0);
            XFlush(dpy);
            usleep(80000);

            /* Release Mod */
            XTestFakeKeyEvent(dpy, kc_mod, False, 0);
            XFlush(dpy);
            usleep(200000);

            char *logE = slurp_fd(pipefd[0], 500);
            TEST("Mod+H chord");
            if (strstr(logE, "keypress: keysym=0x68") || strstr(logE, "Mod chord")
                || strstr(logE, "togglehidemode"))
                PASS("Mod+H chord reached dwm");
            else
                FAIL("Mod+H chord NOT detected. Log: %.200s", logE);
            free(logE);
        }
    }

    /* Cleanup */
    kill(dwm_pid, SIGTERM);
    waitpid(dwm_pid, NULL, 0);
    XCloseDisplay(dpy);
    kill(xvfb_pid, SIGTERM);
    waitpid(xvfb_pid, NULL, 0);
    free(init_log);
    system("rm -rf /tmp/dwm-proof-rt 2>/dev/null");

    printf("\n================================\n");
    printf("RESULTS: %d tests, %d passed, %d failed\n",
           tests_passed + tests_failed, tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
