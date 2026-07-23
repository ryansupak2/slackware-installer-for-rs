/* slock - X11 screen locker (with red/yellow/green colors like wlock)
 *
 * Minimal X11 screen locker with PAM authentication.
 * Colors mirror wlock:
 *   · Black  — idle (no input yet)
 *   · Green  — typing (password has characters)
 *   · Yellow — checking (PAM is hashing)
 *   · Red    — authentication failed
 *   · Gray   — success (brief flash before unlock)
 *
 * Build: make
 * Run:   slock
 */

#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <security/pam_appl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <X11/Xlib.h>
#include <X11/keysym.h>
#include <X11/Xutil.h>

/* ─── colors (matching wlock) ─────────────────────────────────────── */
static const unsigned long COLOR_BG       = 0x000000; /* black background   */
static const unsigned long COLOR_INPUT    = 0x00AA00; /* green while typing  */
static const unsigned long COLOR_CHECKING = 0xAAAA00; /* yellow (checking)   */
static const unsigned long COLOR_FAILED   = 0xAA0000; /* red flash on fail   */
static const unsigned long COLOR_SUCCESS  = 0x555555; /* dim on success      */

static unsigned long col_bg       = COLOR_BG;
static unsigned long col_input    = COLOR_INPUT;
static unsigned long col_checking = COLOR_CHECKING;
static unsigned long col_failed   = COLOR_FAILED;
static unsigned long col_success  = COLOR_SUCCESS;

#define MAX_PW_LEN 256

/* ─── globals ─────────────────────────────────────────────────────── */
static Display *dpy;
static int      screen;
static Window   win;
static GC       gc;
static Colormap cmap;
static int      width, height;

static char password[MAX_PW_LEN + 1];
static int  pw_len      = 0;
static bool pw_failed   = false;
static bool pw_checking = false;

/* ─── helpers ─────────────────────────────────────────────────────── */

static void die(const char *msg) {
	fprintf(stderr, "slock: %s\n", msg);
	exit(1);
}

static unsigned long
current_color(void)
{
	if (pw_checking)
		return col_checking;
	if (pw_failed)
		return col_failed;
	if (pw_len > 0)
		return col_input;
	return col_bg;
}

static void
render(void)
{
	XSetForeground(dpy, gc, current_color());
	XFillRectangle(dpy, win, gc, 0, 0, width, height);
	XFlush(dpy);
}

static void
beep(void)
{
	XBell(dpy, 100);
}

/* ─── PAM ─────────────────────────────────────────────────────────── */

static int
pam_conv_fn(int num_msg, const struct pam_message **msg,
            struct pam_response **resp, void *appdata __attribute__((unused)))
{
	if (num_msg <= 0) return PAM_CONV_ERR;
	struct pam_response *r = calloc(num_msg, sizeof(struct pam_response));
	if (!r) return PAM_BUF_ERR;

	for (int i = 0; i < num_msg; i++) {
		if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF ||
		    msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
			r[i].resp = strdup(password);
		}
	}
	*resp = r;
	return PAM_SUCCESS;
}

static bool
pam_auth(const char *user)
{
	struct pam_conv conv = { .conv = pam_conv_fn, .appdata_ptr = NULL };
	pam_handle_t *ph = NULL;
	int ret = pam_start("slock", user, &conv, &ph);
	if (ret != PAM_SUCCESS) return false;

	ret = pam_authenticate(ph, 0);
	if (ret == PAM_SUCCESS)
		ret = pam_acct_mgmt(ph, 0);

	pam_end(ph, ret);
	return (ret == PAM_SUCCESS);
}

static void
unlock_and_exit(void)
{
	XUngrabKeyboard(dpy, CurrentTime);
	XUngrabPointer(dpy, CurrentTime);
	if (gc)  XFreeGC(dpy, gc);
	if (win) XDestroyWindow(dpy, win);
	if (cmap) XFreeColormap(dpy, cmap);
	XCloseDisplay(dpy);
	exit(EXIT_SUCCESS);
}

static void
try_auth(void)
{
	if (pw_len == 0) return;
	password[pw_len] = '\0';

	const char *user = getenv("USER");
	if (!user) user = getenv("LOGNAME");
	if (!user) user = "root";

	/* yellow while PAM hashes */
	pw_checking = true;
	render();
	XSync(dpy, False);

	if (pam_auth(user)) {
		pw_checking = false;
		/* dim grey flash on success */
		XSetForeground(dpy, gc, col_success);
		XFillRectangle(dpy, win, gc, 0, 0, width, height);
		XFlush(dpy);
		unlock_and_exit();
	} else {
		pw_checking = false;
		pw_failed = true;
		pw_len = 0;
		beep();
		render();
	}
}

static void
clear_input(void)
{
	pw_len = 0;
	pw_failed = false;
	pw_checking = false;
	render();
}

/* ─── keyboard handling ───────────────────────────────────────────── */

static void
handle_keypress(XKeyEvent *ev)
{
	KeySym keysym;
	char buf[16] = {0};
	int len;

	/* translate with shift only — let X handle modifiers naturally */
	len = XLookupString(ev, buf, sizeof(buf) - 1, &keysym, NULL);

	/* Ctrl-U: clear input (like wlock/slock) */
	if ((ev->state & ControlMask) && (keysym == XK_u || keysym == XK_U)) {
		clear_input();
		return;
	}

	switch (keysym) {
	case XK_Escape:
		clear_input();
		return;
	case XK_BackSpace:
		if (pw_len > 0) {
			pw_len--;
			render();
		}
		return;
	case XK_Return:
	case XK_KP_Enter:
		try_auth();
		return;
	default:
		break;
	}

	/* regular character — clear any failure state so screen turns green */
	if (pw_failed)
		pw_failed = false;

	if (len > 0 && pw_len < MAX_PW_LEN) {
		/* Don't add control characters */
		if (buf[0] >= 0x20 || buf[0] == '\n' || buf[0] == '\t') {
			/* ignore newlines/tabs from keyboard */
			if (buf[0] == '\n' || buf[0] == '\t') return;
			password[pw_len++] = buf[0];
		} else if (len > 1) {
			/* multi-byte UTF-8: store first byte (best effort) */
			for (int i = 0; i < len && pw_len < MAX_PW_LEN; i++)
				password[pw_len++] = buf[i];
		}
		render();
	}
}

/* ─── grab keyboard + pointer ─────────────────────────────────────── */

static void
grab_inputs(void)
{
	/* Retry grab for ~1 second in case another grab is active
	 * (e.g., a dying locker hasn't released yet) */
	for (int i = 0; i < 100; i++) {
		int kg = XGrabKeyboard(dpy, win, True,
			GrabModeAsync, GrabModeAsync, CurrentTime);
		if (kg == GrabSuccess) {
			int pg = XGrabPointer(dpy, win, False,
				ButtonPressMask | ButtonReleaseMask |
				PointerMotionMask,
				GrabModeAsync, GrabModeAsync, None,
				None, CurrentTime);
			if (pg == GrabSuccess)
				return;
			XUngrabKeyboard(dpy, CurrentTime);
		}
		usleep(10000); /* 10 ms */
	}
	die("cannot grab keyboard/pointer");
}

/* ─── main ────────────────────────────────────────────────────────── */

int
main(int argc __attribute__((unused)), char **argv __attribute__((unused)))
{
	signal(SIGINT,  SIG_IGN);
	signal(SIGTERM, SIG_IGN);

	dpy = XOpenDisplay(NULL);
	if (!dpy) die("cannot open display");

	screen = DefaultScreen(dpy);
	width  = DisplayWidth(dpy, screen);
	height = DisplayHeight(dpy, screen);

	/* simple black-and-white colormap */
	cmap = DefaultColormap(dpy, screen);

	/* create a fullscreen override-redirect window (above everything) */
	XSetWindowAttributes wa = {
		.override_redirect = True,
		.background_pixel  = col_bg,
		.event_mask        = KeyPressMask | ExposureMask |
		                     StructureNotifyMask,
	};
	win = XCreateWindow(dpy, RootWindow(dpy, screen),
		0, 0, width, height, 0,
		DefaultDepth(dpy, screen), CopyFromParent,
		DefaultVisual(dpy, screen),
		CWOverrideRedirect | CWBackPixel | CWEventMask, &wa);

	gc = XCreateGC(dpy, win, 0, NULL);

	/* map and raise */
	XMapRaised(dpy, win);
	XSync(dpy, False);

	grab_inputs();

	/* event loop */
	XEvent ev;
	while (1) {
		XNextEvent(dpy, &ev);

		switch (ev.type) {
		case KeyPress:
			handle_keypress(&ev.xkey);
			break;
		case Expose:
			if (ev.xexpose.count == 0)
				render();
			break;
		case ConfigureNotify:
			width  = ev.xconfigure.width;
			height = ev.xconfigure.height;
			render();
			break;
		case MappingNotify:
			XRefreshKeyboardMapping(&ev.xmapping);
			break;
		}
	}

	/* unreachable, but quiet compiler */
	return 0;
}
