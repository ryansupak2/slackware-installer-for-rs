/* copilot-mod — make the Copilot key behave as the window manager's Mod key.
 *
 * The Copilot key on this Dell is keycode 201 (evdev KEY_F23) and its firmware
 * presses Shift and Super in the same burst, exactly as Microsoft specifies for
 * the key (Shift + Win + F23). xkeyboard-config even has a type for it,
 * PC_SHIFT_SUPER_LEVEL2, which maps that chord to XF86Assistant and *preserves*
 * Shift and Super in the event state.
 *
 * dwm uses Mod4 (Super) as MODKEY, so the Super half is what we want. The Shift
 * half is poison: dwm matches grab masks exactly, so MODKEY+letter would arrive
 * as MODKEY|ShiftMask+letter and do the tag/quit actions instead of the view
 * ones, and bindings without a Shift sibling (Mod+Return, Mod+r, Mod+h, ...)
 * would not reach dwm at all — the server would hand the event to the focused
 * client, because no exact grab matches.
 *
 * So the Shift must be gone from the server's modifier state *before* the next
 * key event is matched against the grabs. This daemon does that with XTest (a
 * fake release of whichever Shift is down), which updates the server's state
 * exactly like a real release:
 *
 *   - it watches with the RECORD extension, so nothing is grabbed and no event
 *     is taken away from dwm or from any client;
 *   - dwm-start also maps keycode 201 to Super_L (xmodmap), so the key asserts
 *     Mod4 even on firmware that does not send Super itself; if it did not, this
 *     daemon presses Super_L and releases it on the key's release;
 *   - a key that sends plain F23 (no modifiers at all) needs no fixing at all,
 *     which is why every step here is conditional.
 *
 * Nothing here is needed for Caps Lock: dwm-start maps that to Super_L itself.
 *
 * Usage: copilot-mod [-k KEYCODE] [-v]
 *        -k  keycode of the Copilot key (default 201)
 *        -v  verbose (log every press we act on; the session log already gets
 *            one line at startup)
 */

#define _DEFAULT_SOURCE

#include <X11/XKBlib.h>
#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/keysym.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/record.h>

#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#define SUPER_KEYCODE 133	/* left Super/Windows key */
#define COPILOT_DEFAULT 201	/* KEY_F23 -> X keycode 201 on this keyboard */

static Display *dpy;		/* control connection: XTest + queries */
static Display *rpy;		/* data connection: RECORD only */
static int copilot_kc = COPILOT_DEFAULT;
static int verbose;
static int synth_super;		/* we are the one holding Mod4 down */

static void
logmsg(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static int
key_down(unsigned int kc)
{
	char keys[32];

	XQueryKeymap(dpy, keys);
	return (keys[kc / 8] & (1 << (kc % 8))) != 0;
}

/* Drop the firmware's Shift from the server's modifier state. It is a real
 * Shift press, so it has to be released the same way; the later physical
 * release is then a no-op and the next real Shift press is unaffected. */
static void
clear_shift(void)
{
	KeyCode kc;
	int did = 0;

	kc = XKeysymToKeycode(dpy, XK_Shift_L);
	if (kc && key_down(kc)) {
		XTestFakeKeyEvent(dpy, kc, False, CurrentTime);
		did = 1;
	}
	kc = XKeysymToKeycode(dpy, XK_Shift_R);
	if (kc && key_down(kc)) {
		XTestFakeKeyEvent(dpy, kc, False, CurrentTime);
		did = 1;
	}
	if (did) {
		XFlush(dpy);
		if (verbose)
			logmsg("copilot-mod: cleared the firmware Shift");
	}
}

static void
record_cb(XPointer closure, XRecordInterceptData *data)
{
	xEvent *ev;
	int state;

	(void)closure;
	if (data->category != XRecordFromServer) {
		XRecordFreeData(data);
		return;
	}
	/* data_len counts 4-byte units, NOT bytes: a full event is 32 bytes = 8
	 * units. Comparing it against sizeof(xEvent) (32) rejects every event —
	 * that silently disabled this daemon until it was measured (2026-11-13). */
	if (data->data_len < 8)
		goto out;
	ev = (xEvent *)data->data;
	state = ev->u.keyButtonPointer.state;

	if (ev->u.u.type == KeyPress && ev->u.u.detail == copilot_kc) {
		if (verbose)
			logmsg("copilot-mod: key %d pressed, state=0x%x", copilot_kc, state);
		if (state & ShiftMask)
			clear_shift();
		/* Only press Super ourselves if the key did not do it. */
		if (!(state & Mod4Mask)) {
			XTestFakeKeyEvent(dpy, SUPER_KEYCODE, True, CurrentTime);
			XFlush(dpy);
			synth_super = 1;
			if (verbose)
				logmsg("copilot-mod: asserted Mod4 (firmware sent none)");
		}
	} else if (ev->u.u.type == KeyRelease && ev->u.u.detail == copilot_kc) {
		if (synth_super) {
			XTestFakeKeyEvent(dpy, SUPER_KEYCODE, False, CurrentTime);
			XFlush(dpy);
			synth_super = 0;
			if (verbose)
				logmsg("copilot-mod: released Mod4");
		}
	}
out:
	XRecordFreeData(data);
}

static void
cleanup(int sig)
{
	(void)sig;
	if (synth_super) {
		XTestFakeKeyEvent(dpy, SUPER_KEYCODE, False, CurrentTime);
		XFlush(dpy);
	}
	exit(0);
}

int
main(int argc, char **argv)
{
	int opt, rec_base, rec_err, xtst_event, xtst_err, xtst_major, xtst_minor;
	XRecordRange *range;
	XRecordClientSpec clients;
	XRecordContext ctx;

	while ((opt = getopt(argc, argv, "k:v")) != -1) {
		switch (opt) {
		case 'k':
			copilot_kc = atoi(optarg);
			if (copilot_kc <= 0 || copilot_kc > 255) {
				fprintf(stderr, "copilot-mod: invalid keycode %s\n", optarg);
				return 2;
			}
			break;
		case 'v':
			verbose = 1;
			break;
		default:
			fprintf(stderr, "usage: copilot-mod [-k keycode] [-v]\n");
			return 2;
		}
	}

	dpy = XOpenDisplay(NULL);
	if (!dpy) {
		logmsg("copilot-mod: cannot open display — nothing to do");
		return 1;
	}
	if (!XRecordQueryVersion(dpy, &rec_base, &rec_err)) {
		logmsg("copilot-mod: server has no RECORD extension — cannot watch keys");
		return 1;
	}
	if (!XTestQueryExtension(dpy, &xtst_event, &xtst_err, &xtst_major, &xtst_minor)) {
		logmsg("copilot-mod: server has no XTEST extension — cannot drop the Shift");
		return 1;
	}

	/* No flock here on purpose: the daemon's life is the X server's. When the
	 * server goes away (and that includes the dwm-restart path that respawns X
	 * with the same xinitrc) the connection breaks and this process exits. A
	 * pidfile lock would then be held by a corpse for the *next* session and the
	 * new instance would refuse to start — that is worse than the harmless case
	 * of two instances briefly overlapping. */
	signal(SIGTERM, cleanup);
	signal(SIGTERM, cleanup);
	signal(SIGINT, cleanup);
	signal(SIGHUP, cleanup);
	signal(SIGPIPE, SIG_IGN);

	/* RECORD needs its own connection: the callback runs on it. */
	if (!(rpy = XOpenDisplay(NULL))) {
		logmsg("copilot-mod: cannot open the second (record) display");
		return 1;
	}

	range = XRecordAllocRange();
	if (!range) {
		logmsg("copilot-mod: XRecordAllocRange failed");
		return 1;
	}
	/* Device events, so grabs elsewhere in the session cannot hide the key. */
	range->device_events.first = KeyPress;
	range->device_events.last = KeyRelease;
	clients = XRecordAllClients;

	ctx = XRecordCreateContext(dpy, 0, &clients, 1, &range, 1);
	XFree(range);
	if (!ctx) {
		logmsg("copilot-mod: XRecordCreateContext failed");
		return 1;
	}
	XSync(dpy, False);

	/* XRecordEnableContext() is the main loop: it blocks here and dispatches
	 * every key event to record_cb() until the context is disabled (i.e. until
	 * this X server goes away with the session). */
	logmsg("copilot-mod: watching keycode %d (Copilot key): its firmware Shift is dropped,"
	       " so the key acts as Mod4 alone", copilot_kc);

	if (!XRecordEnableContext(rpy, ctx, record_cb, NULL)) {
		logmsg("copilot-mod: XRecordEnableContext failed");
		return 1;
	}

	return 0;
}
