/* xclick — synthesize X mouse button click via XTest
   Usage: xclick 4   (scroll up / Button4)
          xclick 5   (scroll down / Button5) */
#include <stdio.h>
#include <stdlib.h>
#include <X11/Xlib.h>
#include <X11/extensions/XTest.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "Usage: xclick <button>\n");
        return 1;
    }
    int button = atoi(argv[1]);
    if (button < 1 || button > 5) {
        fprintf(stderr, "Button must be 1-5 (4=scrollup, 5=scrolldown)\n");
        return 1;
    }
    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) { fprintf(stderr, "Cannot open display\n"); return 1; }
    XTestFakeButtonEvent(dpy, button, True,  CurrentTime);
    XTestFakeButtonEvent(dpy, button, False, CurrentTime);
    XFlush(dpy);
    XCloseDisplay(dpy);
    return 0;
}
