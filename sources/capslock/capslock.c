/* capslock — switch the X Caps Lock state from the command line.
 *
 * This machine has no Caps Lock key any more: keycode 66 is remapped to Super_L
 * (Mod) so it can be used as the dwm modifier, and Fn never reaches software
 * (the AT keyboard does not advertise KEY_FN), so Fn+CapsLock cannot bring the
 * lock back. The lock state itself still exists in the X server, which is what
 * this command drives:
 *
 *     capslock          toggle
 *     capslock on       lock   -> prints "Capslock On"
 *     capslock off      unlock -> prints "Capslock Off"
 *     capslock --help   this text
 *
 * It sets the Lock modifier with XkbLockModifiers (the same state a Caps Lock
 * key would set, LEDs included); nothing is faked through a keycode, so it also
 * works while no keyboard has a Caps_Lock keysym.
 *
 * Exit status: 0 on success, 1 when there is no usable X display, 2 on bad
 * arguments.
 */

#define _DEFAULT_SOURCE

#include <X11/XKBlib.h>
#include <X11/Xlib.h>

#include <stdio.h>
#include <string.h>

static void
usage(FILE *out)
{
	fprintf(out,
		"usage: capslock [on|off]\n"
		"\n"
		"  capslock          toggle Caps Lock\n"
		"  capslock on       turn it on\n"
		"  capslock off      turn it off\n"
		"  capslock --help   this help\n"
		"\n"
		"There is no Caps Lock key on this machine (Caps Lock is the dwm Mod key\n"
		"and Fn does not reach software), so this is how the lock is switched.\n");
}

int
main(int argc, char **argv)
{
	Display *dpy;
	XkbStateRec state;
	int want = -1;			/* -1 = toggle */
	int on;

	if (argc > 1) {
		if (!strcmp(argv[1], "--help") || !strcmp(argv[1], "-h") || !strcmp(argv[1], "help")) {
			usage(stdout);
			return 0;
		}
		if (!strcmp(argv[1], "on")) {
			want = 1;
		} else if (!strcmp(argv[1], "off")) {
			want = 0;
		} else {
			fprintf(stderr, "capslock: unknown argument: %s\n\n", argv[1]);
			usage(stderr);
			return 2;
		}
	}

	if (!(dpy = XOpenDisplay(NULL))) {
		fprintf(stderr, "capslock: cannot open X display (no DISPLAY?)\n");
		return 1;
	}
	if (XkbGetState(dpy, XkbUseCoreKbd, &state) != Success) {
		fprintf(stderr, "capslock: cannot read the keyboard state\n");
		return 1;
	}

	on = (state.locked_mods & LockMask) != 0;
	if (want < 0)
		want = !on;

	if (want != on) {
		XkbLockModifiers(dpy, XkbUseCoreKbd, LockMask, want ? LockMask : 0);
		XSync(dpy, False);
	}

	printf("Capslock %s\n", want ? "On" : "Off");
	XCloseDisplay(dpy);
	return 0;
}
