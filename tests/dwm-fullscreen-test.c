/*
 * dwm-fullscreen-test.c — Verify dwm fullscreen client message handling
 *
 * Tests:
 *   1. TOGGLE enters fullscreen (isfullscreen goes 0→1)
 *   2. TOGGLE exits fullscreen  (isfullscreen goes 1→0)
 *   3. Rapid TOGGLE within debounce window doesn't loop
 *   4. ADD enters fullscreen, REMOVE exits fullscreen
 *
 * Build:
 *   gcc -Wall -o tests/dwm-fullscreen-test tests/dwm-fullscreen-test.c -lX11
 *
 * Run under a running dwm X session:
 *   DISPLAY=:0 tests/dwm-fullscreen-test
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/Xatom.h>

static Display *dpy;
static Window test_win;
static Atom net_wm_state, net_wm_fullscreen, net_active_window;
static int errors = 0;

static int xerror_handler(Display *d, XErrorEvent *e) {
    (void)d; (void)e;
    fprintf(stderr, "  [X ERROR] type=%d\n", e->type);
    errors++;
    return 0;
}

/* Read _NET_WM_STATE property from window, check if it contains _NET_WM_STATE_FULLSCREEN */
static int window_is_fullscreen(Window win) {
    Atom type;
    int fmt;
    unsigned long nitems, after;
    unsigned char *data = NULL;
    int ret = 0;

    if (XGetWindowProperty(dpy, win, net_wm_state, 0, 64, False,
                           XA_ATOM, &type, &fmt, &nitems, &after, &data) == Success && data) {
        Atom *atoms = (Atom *)data;
        for (unsigned long i = 0; i < nitems; i++) {
            if (atoms[i] == net_wm_fullscreen) {
                ret = 1;
                break;
            }
        }
        XFree(data);
    }
    return ret;
}

/* Send a _NET_WM_STATE client message to toggle/add/remove fullscreen */
static void send_fullscreen_msg(Window win, int action) {
    XEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = ClientMessage;
    ev.xclient.window = win;
    ev.xclient.message_type = net_wm_state;
    ev.xclient.format = 32;
    ev.xclient.data.l[0] = action;   /* 0=REMOVE, 1=ADD, 2=TOGGLE */
    ev.xclient.data.l[1] = net_wm_fullscreen;
    ev.xclient.data.l[2] = 0;
    XSendEvent(dpy, DefaultRootWindow(dpy), False,
               SubstructureRedirectMask | SubstructureNotifyMask, &ev);
    XFlush(dpy);
}

static int wait_for_state(Window win, int expected_fullscreen, int timeout_ms) {
    int waited = 0;
    while (waited < timeout_ms) {
        usleep(50000); /* 50ms poll */
        waited += 50;
        XSync(dpy, False);

        int actual = window_is_fullscreen(win);
        if (actual == expected_fullscreen)
            return 1;
    }
    return 0;
}

static int test(const char *label, int (*fn)(void)) {
    printf("  %-55s ", label);
    fflush(stdout);
    int result = fn();
    printf("%s\n", result ? "PASS" : "FAIL");
    if (!result) errors++;
    return result;
}

/* ── Test 1: TOGGLE enters fullscreen ─────────────────────── */
static int test_toggle_enter(void) {
    XMapWindow(dpy, test_win);
    XFlush(dpy);
    usleep(50000);

    /* Should start not fullscreen */
    if (window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (already fullscreen?)\n");
        return 0;
    }

    /* Send TOGGLE — should enter fullscreen */
    send_fullscreen_msg(test_win, 2 /* TOGGLE */);
    if (!wait_for_state(test_win, 1, 2000)) {
        fprintf(stderr, "    (did not enter fullscreen within 2s)\n");
        return 0;
    }

    /* Verify _NET_WM_STATE_FULLSCREEN is set on window */
    if (!window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (_NET_WM_STATE_FULLSCREEN not set)\n");
        return 0;
    }

    return 1;
}

/* ── Test 2: TOGGLE exits fullscreen ──────────────────────── */
static int test_toggle_exit(void) {
    /* Should be fullscreen from test 1 */
    if (!window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (not fullscreen — test 1 must have failed?)\n");
        return 0;
    }

    /* Send TOGGLE — should exit fullscreen */
    send_fullscreen_msg(test_win, 2 /* TOGGLE */);
    if (!wait_for_state(test_win, 0, 2000)) {
        fprintf(stderr, "    (did not exit fullscreen within 2s)\n");
        return 0;
    }

    if (window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (_NET_WM_STATE_FULLSCREEN still set)\n");
        return 0;
    }

    return 1;
}

/* ── Test 3: Rapid TOGGLE doesn't cause loop ───────────────── */
static int test_toggle_debounce(void) {
    /* Send two TOGGLEs rapidly — first should enter fullscreen,
     * second should be debounced (within 1 second window) */
    send_fullscreen_msg(test_win, 2 /* TOGGLE */);
    usleep(50000); /* 50ms — well within debounce window */
    send_fullscreen_msg(test_win, 2 /* TOGGLE */);

    /* Should be fullscreen (first TOGGLE entered, second debounced) */
    if (!wait_for_state(test_win, 1, 2000)) {
        fprintf(stderr, "    (did not enter fullscreen)\n");
        return 0;
    }

    /* Now wait past debounce window and try again */
    sleep(1);
    send_fullscreen_msg(test_win, 2 /* TOGGLE */);

    /* Should exit fullscreen (debounce window passed) */
    if (!wait_for_state(test_win, 0, 2000)) {
        fprintf(stderr, "    (did not exit fullscreen after debounce)\n");
        return 0;
    }

    return 1;
}

/* ── Test 4: ADD enters, REMOVE exits ──────────────────────── */
static int test_add_remove(void) {
    /* ADD should enter fullscreen */
    send_fullscreen_msg(test_win, 1 /* ADD */);
    if (!wait_for_state(test_win, 1, 2000)) {
        fprintf(stderr, "    (ADD did not enter fullscreen)\n");
        return 0;
    }

    /* ADD when already fullscreen: should be no-op (not double-toggle) */
    send_fullscreen_msg(test_win, 1 /* ADD */);
    usleep(300000);
    if (!window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (ADD when fullscreen caused exit!)\n");
        return 0;
    }

    /* REMOVE should exit fullscreen */
    send_fullscreen_msg(test_win, 0 /* REMOVE */);
    if (!wait_for_state(test_win, 0, 2000)) {
        fprintf(stderr, "    (REMOVE did not exit fullscreen)\n");
        return 0;
    }

    /* REMOVE when not fullscreen: should be no-op */
    send_fullscreen_msg(test_win, 0 /* REMOVE */);
    usleep(300000);
    if (window_is_fullscreen(test_win)) {
        fprintf(stderr, "    (REMOVE when not fullscreen caused entry!)\n");
        return 0;
    }

    return 1;
}

int main(int argc, char *argv[]) {
    const char *display_name = NULL;
    if (argc > 1) display_name = argv[1];

    dpy = XOpenDisplay(display_name);
    if (!dpy) {
        fprintf(stderr, "ERROR: cannot open display %s\n",
                display_name ? display_name : ":0");
        fprintf(stderr, "Usage: %s [DISPLAY]\n", argv[0]);
        return 1;
    }

    XSetErrorHandler(xerror_handler);

    /* Intern atoms */
    net_wm_state       = XInternAtom(dpy, "_NET_WM_STATE", False);
    net_wm_fullscreen  = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
    net_active_window  = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);

    /* Create test window */
    test_win = XCreateSimpleWindow(dpy, DefaultRootWindow(dpy),
                                   100, 100, 400, 300, 0,
                                   BlackPixel(dpy, DefaultScreen(dpy)),
                                   WhitePixel(dpy, DefaultScreen(dpy)));
    XStoreName(dpy, test_win, "dwm-fullscreen-test");

    /* Set WM_CLASS so dwm manages us */
    XClassHint ch;
    ch.res_name  = "dwm-fullscreen-test";
    ch.res_class = "dwm-fullscreen-test";
    XSetClassHint(dpy, test_win, &ch);

    printf("dwm fullscreen test\n");
    printf("===================\n");
    printf("Window: 0x%lx\n\n", (unsigned long)test_win);

    test("TOGGLE enters fullscreen",         test_toggle_enter);
    test("TOGGLE exits fullscreen",          test_toggle_exit);
    test("Rapid TOGGLE debounced (no loop)", test_toggle_debounce);
    test("ADD enters, REMOVE exits",         test_add_remove);

    XDestroyWindow(dpy, test_win);
    XCloseDisplay(dpy);

    printf("\n%d error(s)\n", errors);
    return errors ? 1 : 0;
}
