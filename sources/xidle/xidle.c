/* xidle - print the X server's idle time in milliseconds
 *
 * Why this exists: nothing in this base system reports idle time (xprintidle,
 * xssstate and xautolock are all absent from Slackware), and the idle timer is
 * what lets us lock the screen BEFORE the display blanks. Locking after the
 * blank is too late for the guarantee we want: the panel could come back while
 * the desktop is still the topmost thing on screen.
 *
 * Uses the MIT-SCREEN-SAVER extension (libXss). Exit codes:
 *   0 = idle time printed (milliseconds)
 *   2 = cannot open DISPLAY
 *   3 = server has no MIT-SCREEN-SAVER extension
 */
#include <X11/Xlib.h>
#include <X11/extensions/scrnsaver.h>
#include <stdio.h>

int
main(void)
{
	Display *dpy = XOpenDisplay(NULL);
	int event_base, error_base;

	if (!dpy)
		return 2;

	if (!XScreenSaverQueryExtension(dpy, &event_base, &error_base)) {
		XCloseDisplay(dpy);
		return 3;
	}

	XScreenSaverInfo *info = XScreenSaverAllocInfo();
	if (!info) {
		XCloseDisplay(dpy);
		return 4;
	}

	XScreenSaverQueryInfo(dpy, DefaultRootWindow(dpy), info);
	printf("%lu\n", (unsigned long)info->idle);

	XFree(info);
	XCloseDisplay(dpy);
	return 0;
}
