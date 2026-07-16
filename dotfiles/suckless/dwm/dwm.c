/* See LICENSE file for copyright and license details.
 *
 * dynamic window manager is designed like any other X client as well. It is
 * driven through handling X events. In contrast to other X clients, a window
 * manager selects for SubstructureRedirectMask on the root window, to receive
 * events about window (dis-)appearance. Only one X connection at a time is
 * allowed to select for this event mask.
 *
 * The event handlers of dwm are organized in an array which is accessed
 * whenever a new event has been fetched. This allows event dispatching
 * in O(1) time.
 *
 * Each child of the root window is called a client, except windows which have
 * set the override_redirect flag. Clients are organized in a linked client
 * list on each monitor, the focus history is remembered through a stack list
 * on each monitor. Each client contains a bit array to indicate the tags of a
 * client.
 *
 * Keys and tagging rules are organized as arrays and defined in config.h.
 *
 * To understand everything else, start reading main().
 */
#include <errno.h>
#include <locale.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <X11/cursorfont.h>
#include <X11/keysym.h>
#include <X11/Xatom.h>
#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/Xutil.h>
#ifdef XINERAMA
#include <X11/extensions/Xinerama.h>
#endif /* XINERAMA */
#include <X11/Xft/Xft.h>
#include <fcntl.h>
#include <sys/stat.h>

#include "drw.h"
#include "util.h"

/* macros */
#define BUTTONMASK              (ButtonPressMask|ButtonReleaseMask)
#define CLEANMASK(mask)         (mask & ~(numlockmask|LockMask) & (ShiftMask|ControlMask|Mod1Mask|Mod2Mask|Mod3Mask|Mod4Mask|Mod5Mask))
#define INTERSECT(x,y,w,h,m)    (MAX(0, MIN((x)+(w),(m)->wx+(m)->ww) - MAX((x),(m)->wx)) \
                               * MAX(0, MIN((y)+(h),(m)->wy+(m)->wh) - MAX((y),(m)->wy)))
#define ISVISIBLE(C)            ((C->tags & C->mon->tagset[C->mon->seltags]))
#define LENGTH(X)               (sizeof X / sizeof X[0])
#define MOUSEMASK               (BUTTONMASK|PointerMotionMask)
#define WIDTH(X)                ((X)->w + 2 * (X)->bw)
#define HEIGHT(X)               ((X)->h + 2 * (X)->bw)
#define TAGMASK                 ((1 << LENGTH(tags)) - 1)
#define TEXTW(X)                (drw_fontset_getwidth(drw, (X)) + lrpad)

/* enums */
enum { CurNormal, CurResize, CurMove, CurLast }; /* cursor */
enum { SchemeNorm, SchemeSel }; /* color schemes */
enum { NetSupported, NetWMName, NetWMState, NetWMCheck,
       NetWMFullscreen, NetActiveWindow, NetWMWindowType,
       NetWMWindowTypeDialog, NetClientList, NetLast }; /* EWMH atoms */
enum { WMProtocols, WMDelete, WMState, WMTakeFocus, WMLast }; /* default atoms */
enum { ClkTagBar, ClkLtSymbol, ClkStatusText, ClkWinTitle,
       ClkClientWin, ClkRootWin, ClkLast }; /* clicks */

typedef union {
	int i;
	unsigned int ui;
	float f;
	const void *v;
} Arg;

typedef struct {
	unsigned int click;
	unsigned int mask;
	unsigned int button;
	void (*func)(const Arg *arg);
	const Arg arg;
} Button;

typedef struct Monitor Monitor;
typedef struct Client Client;
struct Client {
	char name[256];
	float mina, maxa;
	int x, y, w, h;
	int oldx, oldy, oldw, oldh;
	int basew, baseh, incw, inch, maxw, maxh, minw, minh, hintsvalid;
	int bw, oldbw;
	unsigned int tags;
	int isfixed, isfloating, isurgent, neverfocus, oldstate, isfullscreen, infullscreenchange;
	Client *next;
	Client *snext;
	Monitor *mon;
	Window win;
};

typedef struct {
	unsigned int mod;
	KeySym keysym;
	void (*func)(const Arg *);
	const Arg arg;
} Key;

typedef struct {
	const char *symbol;
	void (*arrange)(Monitor *);
} Layout;

struct Monitor {
	char ltsymbol[16];
	float mfact;
	int nmaster;
	int num;
	int by;               /* bar geometry */
	int mx, my, mw, mh;   /* screen size */
	int wx, wy, ww, wh;   /* window area  */
	unsigned int seltags;
	unsigned int sellt;
	unsigned int tagset[2];
	int curtagidx;        /* currently focused tag index (0-8) */
	unsigned int bartags;   /* tags drawn in the bar (occupied + revealed + anchor) */
	int showbar;
	int topbar;
	Client *clients;
	Client *sel;
	Client *stack;
	Monitor *next;
	Window barwin;
	const Layout *lt[2];
	const Layout *taglt[9];
};

typedef struct {
	const char *class;
	const char *instance;
	const char *title;
	unsigned int tags;
	int isfloating;
	int monitor;
} Rule;

/* function declarations */
static void applyrules(Client *c);
static int applysizehints(Client *c, int *x, int *y, int *w, int *h, int interact);
static void arrange(Monitor *m);
static void arrangemon(Monitor *m);
static void attach(Client *c);
static void attachstack(Client *c);
static void buttonpress(XEvent *e);
static void checkotherwm(void);
static void cleanup(void);
static void cleanupmon(Monitor *mon);
static void clientmessage(XEvent *e);
static void configure(Client *c);
static void configurenotify(XEvent *e);
static void configurerequest(XEvent *e);
static Monitor *createmon(void);
static void destroynotify(XEvent *e);
static void detach(Client *c);
static void detachstack(Client *c);
static Monitor *dirtomon(int dir);
static void drawbar(Monitor *m);
static void drawbars(void);
static void enternotify(XEvent *e);
static void expose(XEvent *e);
static void focus(Client *c);
static void focusin(XEvent *e);
static void focusmon(const Arg *arg);
static void focusstack(const Arg *arg);
static Atom getatomprop(Client *c, Atom prop);
static int getrootptr(int *x, int *y);
static long getstate(Window w);
static int gettextprop(Window w, Atom atom, char *text, unsigned int size);
static void grabbuttons(Client *c, int focused);
static void grabkeys(void);
static void keypress(XEvent *e);
static void keyrelease(XEvent *e);
static void killclient(const Arg *arg);
static void manage(Window w, XWindowAttributes *wa);
static void mappingnotify(XEvent *e);
static void maprequest(XEvent *e);
static void monocle(Monitor *m);
static void motionnotify(XEvent *e);
static void movemouse(const Arg *arg);
static Client *nexttiled(Client *c);
static void pop(Client *c);
static void propertynotify(XEvent *e);
static void quit(const Arg *arg);
static Monitor *recttomon(int x, int y, int w, int h);
static void resize(Client *c, int x, int y, int w, int h, int interact);
static void resizeclient(Client *c, int x, int y, int w, int h);
static void resizemouse(const Arg *arg);
static void restack(Monitor *m);
static void run(void);
static void scan(void);
static void handlefifo(void);
static int sendevent(Client *c, Atom proto);
static void sendmon(Client *c, Monitor *m);
static void setclientstate(Client *c, long state);
static void setfocus(Client *c);
static void setfullscreen(Client *c, int fullscreen);
static void setlayout(const Arg *arg);
static void setmfact(const Arg *arg);
static void setup(void);
static void seturgent(Client *c, int urg);
static void showhide(Client *c);
static void spawn(const Arg *arg);
static void tag(const Arg *arg);
static void tagmon(const Arg *arg);
static void tagnext(const Arg *arg);
static void tagprev(const Arg *arg);
static void tile(Monitor *m);
static void togglebar(const Arg *arg);
static void togglehidemode(const Arg *arg);
static void updatebarvisibility(void);
static int tagisoccupied(Monitor *m, int tagidx);
static void ensurebartagsvalid(Monitor *m);
static void togglefloating(const Arg *arg);
static void toggletag(const Arg *arg);
static void toggleview(const Arg *arg);
static void unfocus(Client *c, int setfocus);
static void unmanage(Client *c, int destroyed);
static void unmapnotify(XEvent *e);
static void updatebarpos(Monitor *m);
static void updatebars(void);
static void updateclientlist(void);
static int updategeom(void);
static void updatenumlockmask(void);
static void updatesizehints(Client *c);
static void updatestatus(void);
static void updatetitle(Client *c);
static void updatewindowtype(Client *c);
static void updatewmhints(Client *c);
static void view(const Arg *arg);
static void viewnext(const Arg *arg);
static void viewprev(const Arg *arg);
static Client *wintoclient(Window w);
static Monitor *wintomon(Window w);
static int xerror(Display *dpy, XErrorEvent *ee);
static int xerrordummy(Display *dpy, XErrorEvent *ee);
static int xerrorstart(Display *dpy, XErrorEvent *ee);
static void zoom(const Arg *arg);

/* configuration, allows nested code to access above variables */
#include "config.h"

/* variables */
static const char broken[] = "broken";
static char stext[256];
static int screen;
static int sw, sh;           /* X display screen geometry width, height */
static int bh;               /* bar height */
static int lrpad;            /* sum of left and right padding for text */
static int (*xerrorxlib)(Display *, XErrorEvent *);
static unsigned int numlockmask = 0;
static void (*handler[LASTEvent]) (XEvent *) = {
	[ButtonPress] = buttonpress,
	[ClientMessage] = clientmessage,
	[ConfigureRequest] = configurerequest,
	[ConfigureNotify] = configurenotify,
	[DestroyNotify] = destroynotify,
	[EnterNotify] = enternotify,
	[Expose] = expose,
	[FocusIn] = focusin,
	[KeyPress] = keypress,
	[KeyRelease] = keyrelease,
	[MappingNotify] = mappingnotify,
	[MapRequest] = maprequest,
	[MotionNotify] = motionnotify,
	[PropertyNotify] = propertynotify,
	[UnmapNotify] = unmapnotify
};
static Atom wmatom[WMLast], netatom[NetLast];
static int running = 1;
static Cur *cursor[CurLast];
static Clr **scheme;
static Display *dpy;
static Drw *drw;
static Monitor *mons, *selmon;
static Window root, wmcheckwin;

/* hide mode */
static int hidemode = 0;          /* toggled by Mod+H, defaults OFF */
static int modkeyheld = 0;        /* Super key currently pressed? */
static time_t autoshowuntil = 0;   /* when temp bar show expires */
static int fifofd = -1;           /* FIFO fd for bar control */

/* configuration, allows nested code to access above variables */

/* compile-time check if all tags fit into an unsigned int bit array. */
struct NumTags { char limitexceeded[LENGTH(tags) > 31 ? -1 : 1]; };

/* function implementations */
void
applyrules(Client *c)
{
	const char *class, *instance;
	unsigned int i;
	const Rule *r;
	Monitor *m;
	XClassHint ch = { NULL, NULL };

	/* rule matching */
	c->isfloating = 0;
	c->tags = 0;
	XGetClassHint(dpy, c->win, &ch);
	class    = ch.res_class ? ch.res_class : broken;
	instance = ch.res_name  ? ch.res_name  : broken;

	for (i = 0; i < LENGTH(rules); i++) {
		r = &rules[i];
		if ((!r->title || strstr(c->name, r->title))
		&& (!r->class || strstr(class, r->class))
		&& (!r->instance || strstr(instance, r->instance)))
		{
			c->isfloating = r->isfloating;
			c->tags |= r->tags;
			for (m = mons; m && m->num != r->monitor; m = m->next);
			if (m)
				c->mon = m;
		}
	}
	if (ch.res_class)
		XFree(ch.res_class);
	if (ch.res_name)
		XFree(ch.res_name);
	c->tags = c->tags & TAGMASK ? c->tags & TAGMASK : c->mon->tagset[c->mon->seltags];
}

int
applysizehints(Client *c, int *x, int *y, int *w, int *h, int interact)
{
	int baseismin;
	Monitor *m = c->mon;

	/* set minimum possible */
	*w = MAX(1, *w);
	*h = MAX(1, *h);
	if (interact) {
		if (*x > sw)
			*x = sw - WIDTH(c);
		if (*y > sh)
			*y = sh - HEIGHT(c);
		if (*x + *w + 2 * c->bw < 0)
			*x = 0;
		if (*y + *h + 2 * c->bw < 0)
			*y = 0;
	} else {
		if (*x >= m->wx + m->ww)
			*x = m->wx + m->ww - WIDTH(c);
		if (*y >= m->wy + m->wh)
			*y = m->wy + m->wh - HEIGHT(c);
		if (*x + *w + 2 * c->bw <= m->wx)
			*x = m->wx;
		if (*y + *h + 2 * c->bw <= m->wy)
			*y = m->wy;
	}
	if (*h < bh)
		*h = bh;
	if (*w < bh)
		*w = bh;
	if (resizehints || c->isfloating || !c->mon->lt[c->mon->sellt]->arrange) {
		if (!c->hintsvalid)
			updatesizehints(c);
		/* see last two sentences in ICCCM 4.1.2.3 */
		baseismin = c->basew == c->minw && c->baseh == c->minh;
		if (!baseismin) { /* temporarily remove base dimensions */
			*w -= c->basew;
			*h -= c->baseh;
		}
		/* adjust for aspect limits */
		if (c->mina > 0 && c->maxa > 0) {
			if (c->maxa < (float)*w / *h)
				*w = *h * c->maxa + 0.5;
			else if (c->mina < (float)*h / *w)
				*h = *w * c->mina + 0.5;
		}
		if (baseismin) { /* increment calculation requires this */
			*w -= c->basew;
			*h -= c->baseh;
		}
		/* adjust for increment value */
		if (c->incw)
			*w -= *w % c->incw;
		if (c->inch)
			*h -= *h % c->inch;
		/* restore base dimensions */
		*w = MAX(*w + c->basew, c->minw);
		*h = MAX(*h + c->baseh, c->minh);
		if (c->maxw)
			*w = MIN(*w, c->maxw);
		if (c->maxh)
			*h = MIN(*h, c->maxh);
	}
	return *x != c->x || *y != c->y || *w != c->w || *h != c->h;
}

void
arrange(Monitor *m)
{
	if (m)
		showhide(m->stack);
	else for (m = mons; m; m = m->next)
		showhide(m->stack);
	if (m) {
		arrangemon(m);
		restack(m);
	} else for (m = mons; m; m = m->next)
		arrangemon(m);
}

const Layout *
getlayout(Monitor *m)
{
	unsigned int tagset = m->tagset[m->seltags];
	if (tagset == TAGMASK)
		return m->taglt[0];
	int primary = 0;
	while (!(tagset & (1 << primary)))
		primary++;
	return m->taglt[primary];
}

void
arrangemon(Monitor *m)
{
	const Layout *lt = getlayout(m);
	if (lt->arrange == monocle) {
		lt->arrange(m);
	} else {
		strncpy(m->ltsymbol, lt->symbol, sizeof m->ltsymbol);
		if (lt->arrange)
			lt->arrange(m);
	}
}

void
attach(Client *c)
{
	c->next = c->mon->clients;
	c->mon->clients = c;
}

void
attachstack(Client *c)
{
	c->snext = c->mon->stack;
	c->mon->stack = c;
}

void
buttonpress(XEvent *e)
{
	unsigned int i, x, click;
	Arg arg = {0};
	Client *c;
	Monitor *m;
	XButtonPressedEvent *ev = &e->xbutton;

	click = ClkRootWin;
	/* focus monitor if necessary */
	if ((m = wintomon(ev->window)) && m != selmon) {
		unfocus(selmon->sel, 1);
		selmon = m;
		focus(NULL);
	}
	if (ev->window == selmon->barwin) {
		i = x = 0;
		do {
			if (selmon->bartags & (1 << i))
				x += TEXTW(tags[i]);
		} while (ev->x >= x && ++i < LENGTH(tags));
		if (i < LENGTH(tags)) {
			click = ClkTagBar;
			arg.ui = 1 << i;
		} else if (ev->x < x + TEXTW(selmon->ltsymbol))
			click = ClkLtSymbol;
		else if (ev->x > selmon->ww - (int)TEXTW(stext) + lrpad - 2)
			click = ClkStatusText;
		else
			click = ClkWinTitle;
	} else if ((c = wintoclient(ev->window))) {
		focus(c);
		restack(selmon);
		XAllowEvents(dpy, ReplayPointer, CurrentTime);
		click = ClkClientWin;
	}
	for (i = 0; i < LENGTH(buttons); i++)
		if (click == buttons[i].click && buttons[i].func && buttons[i].button == ev->button
		&& CLEANMASK(buttons[i].mask) == CLEANMASK(ev->state))
			buttons[i].func(click == ClkTagBar && buttons[i].arg.i == 0 ? &arg : &buttons[i].arg);
}

void
checkotherwm(void)
{
	xerrorxlib = XSetErrorHandler(xerrorstart);
	/* this causes an error if some other window manager is running */
	XSelectInput(dpy, DefaultRootWindow(dpy), SubstructureRedirectMask);
	XSync(dpy, False);
	XSetErrorHandler(xerror);
	XSync(dpy, False);
}

void
cleanup(void)
{
	Arg a = {.ui = ~0};
	Layout foo = { "", NULL };
	Monitor *m;
	size_t i;

	view(&a);
	selmon->lt[selmon->sellt] = &foo;
	for (m = mons; m; m = m->next)
		while (m->stack)
			unmanage(m->stack, 0);
	XUngrabKey(dpy, AnyKey, AnyModifier, root);
	while (mons)
		cleanupmon(mons);
	for (i = 0; i < CurLast; i++)
		drw_cur_free(drw, cursor[i]);
	for (i = 0; i < LENGTH(colors); i++)
		free(scheme[i]);
	free(scheme);
	XDestroyWindow(dpy, wmcheckwin);
	drw_free(drw);
	XSync(dpy, False);
	XSetInputFocus(dpy, PointerRoot, RevertToPointerRoot, CurrentTime);
	XDeleteProperty(dpy, root, netatom[NetActiveWindow]);
	if (fifofd >= 0) {
		close(fifofd);
		fifofd = -1;
	}
	{
		const char *rundir = getenv("XDG_RUNTIME_DIR");
		char fifopath[256];
		if (rundir) {
			snprintf(fifopath, sizeof(fifopath), "%s/dwmbar-0", rundir);
			unlink(fifopath);
		}
	}
}

void
cleanupmon(Monitor *mon)
{
	Monitor *m;

	if (mon == mons)
		mons = mons->next;
	else {
		for (m = mons; m && m->next != mon; m = m->next);
		m->next = mon->next;
	}
	XUnmapWindow(dpy, mon->barwin);
	XDestroyWindow(dpy, mon->barwin);
	free(mon);
}

void
clientmessage(XEvent *e)
{
	XClientMessageEvent *cme = &e->xclient;
	Client *c = wintoclient(cme->window);

	if (!c)
		return;
	if (cme->message_type == netatom[NetWMState]) {
		if (cme->data.l[1] == netatom[NetWMFullscreen]
		|| cme->data.l[2] == netatom[NetWMFullscreen]) {
			/* Re-entrancy guard: when setfullscreen() calls
			 * XChangeProperty + resizeclient, Firefox receives
			 * PropertyNotify + ConfigureNotify and sends another
			 * ClientMessage before we return. This flag breaks the
			 * loop by ignoring requests while we're still processing. */
			if (c->infullscreenchange)
				return;
			c->infullscreenchange = 1;
			int action = cme->data.l[0];
			if (action == 1 /* _NET_WM_STATE_ADD */ && !c->isfullscreen)
				setfullscreen(c, 1);
			else if (action == 0 /* _NET_WM_STATE_REMOVE */ && c->isfullscreen)
				setfullscreen(c, 0);
			else if (action == 2 /* _NET_WM_STATE_TOGGLE */)
				setfullscreen(c, !c->isfullscreen);
			c->infullscreenchange = 0;
		}
	} else if (cme->message_type == netatom[NetActiveWindow]) {
		if (c != selmon->sel && !c->isurgent)
			seturgent(c, 1);
	}
}

void
configure(Client *c)
{
	XConfigureEvent ce;

	ce.type = ConfigureNotify;
	ce.display = dpy;
	ce.event = c->win;
	ce.window = c->win;
	ce.x = c->x;
	ce.y = c->y;
	ce.width = c->w;
	ce.height = c->h;
	ce.border_width = c->bw;
	ce.above = None;
	ce.override_redirect = False;
	XSendEvent(dpy, c->win, False, StructureNotifyMask, (XEvent *)&ce);
}

void
configurenotify(XEvent *e)
{
	Monitor *m;
	Client *c;
	XConfigureEvent *ev = &e->xconfigure;
	int dirty;

	/* TODO: updategeom handling sucks, needs to be simplified */
	if (ev->window == root) {
		dirty = (sw != ev->width || sh != ev->height);
		sw = ev->width;
		sh = ev->height;
		if (updategeom() || dirty) {
			drw_resize(drw, sw, bh);
			updatebars();
			for (m = mons; m; m = m->next) {
				for (c = m->clients; c; c = c->next)
					if (c->isfullscreen)
						resizeclient(c, m->mx, m->my, m->mw, m->mh);
				XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
			}
			focus(NULL);
			arrange(NULL);
		}
	}
}

void
configurerequest(XEvent *e)
{
	Client *c;
	Monitor *m;
	XConfigureRequestEvent *ev = &e->xconfigurerequest;
	XWindowChanges wc;

	if ((c = wintoclient(ev->window))) {
		if (ev->value_mask & CWBorderWidth)
			c->bw = ev->border_width;
		else if (c->isfloating || !selmon->lt[selmon->sellt]->arrange) {
			m = c->mon;
			if (ev->value_mask & CWX) {
				c->oldx = c->x;
				c->x = m->mx + ev->x;
			}
			if (ev->value_mask & CWY) {
				c->oldy = c->y;
				c->y = m->my + ev->y;
			}
			if (ev->value_mask & CWWidth) {
				c->oldw = c->w;
				c->w = ev->width;
			}
			if (ev->value_mask & CWHeight) {
				c->oldh = c->h;
				c->h = ev->height;
			}
			if ((c->x + c->w) > m->mx + m->mw && c->isfloating)
				c->x = m->mx + (m->mw / 2 - WIDTH(c) / 2); /* center in x direction */
			if ((c->y + c->h) > m->my + m->mh && c->isfloating)
				c->y = m->my + (m->mh / 2 - HEIGHT(c) / 2); /* center in y direction */
			if ((ev->value_mask & (CWX|CWY)) && !(ev->value_mask & (CWWidth|CWHeight)))
				configure(c);
			if (ISVISIBLE(c))
				XMoveResizeWindow(dpy, c->win, c->x, c->y, c->w, c->h);
		} else
			configure(c);
	} else {
		wc.x = ev->x;
		wc.y = ev->y;
		wc.width = ev->width;
		wc.height = ev->height;
		wc.border_width = ev->border_width;
		wc.sibling = ev->above;
		wc.stack_mode = ev->detail;
		XConfigureWindow(dpy, ev->window, ev->value_mask, &wc);
	}
	XSync(dpy, False);
}

Monitor *
createmon(void)
{
	Monitor *m;

	m = ecalloc(1, sizeof(Monitor));
	m->tagset[0] = m->tagset[1] = 1;
	m->curtagidx = 0;
	m->bartags = 1;
	m->mfact = mfact;
	m->nmaster = nmaster;
	m->showbar = showbar;
	m->topbar = topbar;
	m->lt[0] = &layouts[0];
	m->lt[1] = &layouts[1 % LENGTH(layouts)];
	for (int i = 0; i < LENGTH(tags); i++)
		m->taglt[i] = &layouts[0];
	arrangemon(m);
	return m;
}

void
destroynotify(XEvent *e)
{
	Client *c;
	XDestroyWindowEvent *ev = &e->xdestroywindow;

	if ((c = wintoclient(ev->window)))
		unmanage(c, 1);
}

void
detach(Client *c)
{
	Client **tc;

	for (tc = &c->mon->clients; *tc && *tc != c; tc = &(*tc)->next);
	*tc = c->next;
}

void
detachstack(Client *c)
{
	Client **tc, *t;

	for (tc = &c->mon->stack; *tc && *tc != c; tc = &(*tc)->snext);
	*tc = c->snext;

	if (c == c->mon->sel) {
		for (t = c->mon->stack; t && !ISVISIBLE(t); t = t->snext);
		c->mon->sel = t;
	}
}

Monitor *
dirtomon(int dir)
{
	Monitor *m = NULL;

	if (dir > 0) {
		if (!(m = selmon->next))
			m = mons;
	} else if (selmon == mons)
		for (m = mons; m->next; m = m->next);
	else
		for (m = mons; m->next != selmon; m = m->next);
	return m;
}

void
drawbar(Monitor *m)
{
	int x, w, tw = 0;
	int boxs = drw->fonts->h / 9;
	int boxw = drw->fonts->h / 6 + 2;
	unsigned int i, occ = 0, urg = 0;
	Client *c;

	if (!m->showbar)
		return;

	/* draw status first so it can be overdrawn by tags later */
	if (m == selmon) { /* status is only drawn on selected monitor */
		drw_setscheme(drw, scheme[SchemeNorm]);
		tw = TEXTW(stext) - lrpad + 2; /* 2px right padding */
		drw_text(drw, m->ww - tw, 0, tw, bh, 0, stext, 0);
	}

	for (c = m->clients; c; c = c->next) {
		occ |= c->tags;
		if (c->isurgent)
			urg |= c->tags;
	}
	x = 0;
	for (i = 0; i < LENGTH(tags); i++) {
		if (!(m->bartags & (1 << i)))
			continue;  /* dynamic tags: only draw tags in the bar */
		w = bh;  /* square tags: width = bar height */
		drw_setscheme(drw, scheme[i == m->curtagidx ? SchemeSel : SchemeNorm]);
		drw_text(drw, x, 0, w, bh, lrpad / 2, tags[i], urg & 1 << i);
		if (i == m->curtagidx)
			drw_rect(drw, x, 0, w, bh - 1, 0, 0);
		if (occ & 1 << i)
			drw_rect(drw, x + boxs, boxs, boxw, boxw,
				m == selmon && selmon->sel && selmon->sel->tags & 1 << i,
				urg & 1 << i);
		x += w;
	}
	w = TEXTW(m->ltsymbol);
	drw_setscheme(drw, scheme[SchemeNorm]);
	x = drw_text(drw, x, 0, w, bh, lrpad / 2, m->ltsymbol, 0);

	if ((w = m->ww - tw - x) > bh) {
		if (m->sel) {
			drw_setscheme(drw, scheme[m == selmon ? SchemeSel : SchemeNorm]);
			drw_text(drw, x, 0, w, bh, lrpad / 2, m->sel->name, 0);
			if (m->sel->isfloating)
				drw_rect(drw, x + boxs, boxs, boxw, boxw, m->sel->isfixed, 0);
		} else {
			drw_setscheme(drw, scheme[SchemeNorm]);
			drw_rect(drw, x, 0, w, bh, 1, 1);
		}
	}
	drw_map(drw, m->barwin, 0, 0, m->ww, bh);
}

void
drawbars(void)
{
	Monitor *m;

	for (m = mons; m; m = m->next)
		drawbar(m);
}

void
enternotify(XEvent *e)
{
	Client *c;
	Monitor *m;
	XCrossingEvent *ev = &e->xcrossing;

	if ((ev->mode != NotifyNormal || ev->detail == NotifyInferior) && ev->window != root)
		return;
	c = wintoclient(ev->window);
	m = c ? c->mon : wintomon(ev->window);
	if (m != selmon) {
		unfocus(selmon->sel, 1);
		selmon = m;
	} else if (!c || c == selmon->sel)
		return;
	focus(c);
}

void
expose(XEvent *e)
{
	Monitor *m;
	XExposeEvent *ev = &e->xexpose;

	if (ev->count == 0 && (m = wintomon(ev->window)))
		drawbar(m);
}

void
focus(Client *c)
{
	if (!c || !ISVISIBLE(c))
		for (c = selmon->stack; c && !ISVISIBLE(c); c = c->snext);
	if (selmon->sel && selmon->sel != c)
		unfocus(selmon->sel, 0);
	if (c) {
		if (c->mon != selmon)
			selmon = c->mon;
		if (c->isurgent)
			seturgent(c, 0);
		detachstack(c);
		attachstack(c);
		grabbuttons(c, 1);
		XSetWindowBorder(dpy, c->win, scheme[SchemeSel][ColBorder].pixel);
		setfocus(c);
	} else {
		XSetInputFocus(dpy, root, RevertToPointerRoot, CurrentTime);
		XDeleteProperty(dpy, root, netatom[NetActiveWindow]);
	}
	selmon->sel = c;
	drawbars();
}

/* there are some broken focus acquiring clients needing extra handling */
void
focusin(XEvent *e)
{
	XFocusChangeEvent *ev = &e->xfocus;

	if (selmon->sel && ev->window != selmon->sel->win)
		setfocus(selmon->sel);

	/* Hide mode: if focus changed while modkey was held, we likely lost
	 * the Mod release event (e.g. Firefox stole focus on launch).
	 * Reconcile by resetting modkeyheld and starting auto-hide timer. */
	if (modkeyheld && ev->window != root) {
		fprintf(stderr, "[dwm] focusin: lost Mod release (focus changed to 0x%lx) — reconciling\n",
			(unsigned long)ev->window);
		modkeyheld = 0;
		if (hidemode) {
			autoshowuntil = time(NULL) + 3;
			updatebarvisibility();
		}
	}
}

void
focusmon(const Arg *arg)
{
	Monitor *m;

	if (!mons->next)
		return;
	if ((m = dirtomon(arg->i)) == selmon)
		return;
	unfocus(selmon->sel, 0);
	selmon = m;
	focus(NULL);
}

void
focusstack(const Arg *arg)
{
	Client *c = NULL, *i;

	if (!selmon->sel || (selmon->sel->isfullscreen && lockfullscreen))
		return;
	if (arg->i > 0) {
		for (i = selmon->clients; i != selmon->sel; i = i->next)
			if (ISVISIBLE(i))
				c = i;
		if (!c)
			for (; i; i = i->next)
				if (ISVISIBLE(i))
					c = i;
	} else {
		for (c = selmon->sel->next; c && !ISVISIBLE(c); c = c->next);
		if (!c)
			for (c = selmon->clients; c && !ISVISIBLE(c); c = c->next);
	}
	if (c) {
		focus(c);
		if (getlayout(selmon)->arrange == monocle) {
			unsigned int n = 0, current = 0;
			Client *cc;
			for (cc = selmon->clients; cc; cc = cc->next)
				if (ISVISIBLE(cc))
					n++;
			if (n == 0) {
				snprintf(selmon->ltsymbol, sizeof selmon->ltsymbol, "[0]");
			} else {
				for (cc = nexttiled(selmon->clients), current = 1; cc; cc = nexttiled(cc->next), current++)
					if (cc == selmon->sel)
						break;
				if (current > n)
					current = n;
				snprintf(selmon->ltsymbol, sizeof selmon->ltsymbol, "[%d/%d]", current, n);
			}
			drawbars();
		}
		restack(selmon);
	}
}

Atom
getatomprop(Client *c, Atom prop)
{
	int format;
	unsigned long nitems, dl;
	unsigned char *p = NULL;
	Atom da, atom = None;

	if (XGetWindowProperty(dpy, c->win, prop, 0L, sizeof atom, False, XA_ATOM,
		&da, &format, &nitems, &dl, &p) == Success && p) {
		if (nitems > 0 && format == 32)
			atom = *(long *)p;
		XFree(p);
	}
	return atom;
}

int
getrootptr(int *x, int *y)
{
	int di;
	unsigned int dui;
	Window dummy;

	return XQueryPointer(dpy, root, &dummy, &dummy, x, y, &di, &di, &dui);
}

long
getstate(Window w)
{
	int format;
	long result = -1;
	unsigned char *p = NULL;
	unsigned long n, extra;
	Atom real;

	if (XGetWindowProperty(dpy, w, wmatom[WMState], 0L, 2L, False, wmatom[WMState],
		&real, &format, &n, &extra, &p) != Success)
		return -1;
	if (n != 0 && format == 32)
		result = *(long *)p;
	XFree(p);
	return result;
}

int
gettextprop(Window w, Atom atom, char *text, unsigned int size)
{
	char **list = NULL;
	int n;
	XTextProperty name;

	if (!text || size == 0)
		return 0;
	text[0] = '\0';
	if (!XGetTextProperty(dpy, w, &name, atom) || !name.nitems)
		return 0;
	if (name.encoding == XA_STRING) {
		strncpy(text, (char *)name.value, size - 1);
	} else if (XmbTextPropertyToTextList(dpy, &name, &list, &n) >= Success && n > 0 && *list) {
		strncpy(text, *list, size - 1);
		XFreeStringList(list);
	}
	text[size - 1] = '\0';
	XFree(name.value);
	return 1;
}

void
grabbuttons(Client *c, int focused)
{
	updatenumlockmask();
	{
		unsigned int i, j;
		unsigned int modifiers[] = { 0, LockMask, numlockmask, numlockmask|LockMask };
		XUngrabButton(dpy, AnyButton, AnyModifier, c->win);
		if (!focused)
			XGrabButton(dpy, AnyButton, AnyModifier, c->win, False,
				BUTTONMASK, GrabModeSync, GrabModeSync, None, None);
		for (i = 0; i < LENGTH(buttons); i++)
			if (buttons[i].click == ClkClientWin)
				for (j = 0; j < LENGTH(modifiers); j++)
					XGrabButton(dpy, buttons[i].button,
						buttons[i].mask | modifiers[j],
						c->win, False, BUTTONMASK,
						GrabModeAsync, GrabModeSync, None, None);
	}
}

void
grabkeys(void)
{
	updatenumlockmask();
	{
		unsigned int i, j, k;
		unsigned int modifiers[] = { 0, LockMask, numlockmask, numlockmask|LockMask };
		int start, end, skip;
		KeySym *syms;

		XUngrabKey(dpy, AnyKey, AnyModifier, root);
		XDisplayKeycodes(dpy, &start, &end);
		syms = XGetKeyboardMapping(dpy, start, end - start + 1, &skip);
		if (!syms)
			return;

		/* Re-grab all keybindings AND bare Super keys for hide-mode temp-bar-reveal.
		 * We must grab ALL keycodes that produce Super_L/Super_R (e.g. Caps Lock
		 * remapped to Super_L) so bare Mod presses always reach dwm.  This is
		 * called from mappingnotify() too, so grabs survive keyboard remaps. */
		for (k = start; k <= end; k++) {
			KeySym ks = syms[(k - start) * skip];

			/* Bare Super keys: grab with no modifiers so bare Mod press reaches dwm */
			if (ks == XK_Super_L || ks == XK_Super_R) {
				for (j = 0; j < LENGTH(modifiers); j++)
					XGrabKey(dpy, k, modifiers[j], root, True, GrabModeAsync, GrabModeAsync);
			}

			/* Keybinding keys: grab key+modifier combos from config */
			for (i = 0; i < LENGTH(keys); i++)
				/* skip modifier codes, we do that ourselves */
				if (keys[i].keysym == ks)
					for (j = 0; j < LENGTH(modifiers); j++)
						XGrabKey(dpy, k,
							 keys[i].mod | modifiers[j],
							 root, True,
							 GrabModeAsync, GrabModeAsync);
		}
		XFree(syms);
	}
}

#ifdef XINERAMA
static int
isuniquegeom(XineramaScreenInfo *unique, size_t n, XineramaScreenInfo *info)
{
	while (n--)
		if (unique[n].x_org == info->x_org && unique[n].y_org == info->y_org
		&& unique[n].width == info->width && unique[n].height == info->height)
			return 0;
	return 1;
}
#endif /* XINERAMA */

void
keypress(XEvent *e)
{
	unsigned int i;
	KeySym keysym;
	XKeyEvent *ev;

	ev = &e->xkey;
	keysym = XKeycodeToKeysym(dpy, (KeyCode)ev->keycode, 0);

	/* Diagnostic: log every keypress with hidemode/modkeyheld state for debugging */
	fprintf(stderr, "[dwm] keypress: keysym=0x%lx state=0x%x hidemode=%d modkeyheld=%d\n",
		(unsigned long)keysym, ev->state, hidemode, modkeyheld);
	/* Hide Mode: reconcile lost Mod release events (suspend/resume). */
	if (!(ev->state & Mod4Mask) && modkeyheld) {
		fprintf(stderr, "[dwm] reconcile (keypress): Mod released (lost event)\n");
		modkeyheld = 0;
		if (hidemode) {
			autoshowuntil = time(NULL) + 3;
			updatebarvisibility();
		} else {
			autoshowuntil = 0;
		}
	}

	/* Hide Mode: ANY key with Mod held temp-shows the bar immediately.
	 * This fires before keybinding matching so chords (Mod+h, Mod+Return)
	 * always reveal the bar. */
	if ((ev->state & Mod4Mask) && hidemode && !modkeyheld) {
		Monitor *m;
		fprintf(stderr, "[dwm] Mod chord: showing bar (keysym=0x%lx state=0x%x)\n",
			(unsigned long)keysym, ev->state);
		modkeyheld = 1;
		autoshowuntil = 0;
		for (m = mons; m; m = m->next) {
			m->showbar = 1;
			updatebarpos(m);
			XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
		}
		drawbars();
	}

	/* Match keybindings. */
	for (i = 0; i < LENGTH(keys); i++)
		if (keysym == keys[i].keysym
		&& CLEANMASK(keys[i].mod) == CLEANMASK(ev->state)
		&& keys[i].func) {
			keys[i].func(&(keys[i].arg));
			break;
		}

	/* Bare Super press: log it (bar already shown above if in hidemode).
	 * Ignore if this keysym was consumed by a binding. */
	for (i = 0; i < LENGTH(keys); i++) {
		if (keysym == keys[i].keysym && keys[i].func)
			return;
	}

	if (keysym == XK_Super_L || keysym == XK_Super_R) {
		fprintf(stderr, "[dwm] Mod PRESS (hidemode=%d modkeyheld=%d)\n", hidemode, modkeyheld);
		/* modkeyheld and bar-show already handled by the generic Mod4Mask
		 * check above; this path is only reached for bare Super with no
		 * chord — the bar was shown in the generic check. */
		if (!(ev->state & Mod4Mask) && !modkeyheld) {
			/* Bare Super without Mod4Mask in state (shouldn't happen
			 * if grab is working, but handle gracefully). */
			modkeyheld = 1;
			autoshowuntil = 0;
			if (hidemode) {
				Monitor *m;
				for (m = mons; m; m = m->next) {
					m->showbar = 1;
					updatebarpos(m);
					XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
				}
				drawbars();
			}
		}
	}
}

void
keyrelease(XEvent *e)
{
	KeySym keysym;
	XKeyEvent *ev;

	ev = &e->xkey;
	keysym = XKeycodeToKeysym(dpy, (KeyCode)ev->keycode, 0);

	/* Hide Mode: handle Mod key releases.
	 * Normal Super key release → start auto-hide timer.
	 * Reconciliation only fires for non-Super keys (genuinely lost Mod events). */
	if (keysym == XK_Super_L || keysym == XK_Super_R) {
		if (modkeyheld) {
			fprintf(stderr, "[dwm] Mod RELEASE (hidemode=%d) — starting auto-hide timer\n", hidemode);
			modkeyheld = 0;
			if (hidemode) {
				autoshowuntil = time(NULL) + 3;
				updatebarvisibility();
			}
		} else {
			fprintf(stderr, "[dwm] Mod RELEASE ignored (modkeyheld already 0)\n");
		}
		return;
	}

	/* Reconciliation: a non-Super key was released without Mod4Mask
	 * in state, meaning a Mod release event was lost (suspend/resume). */
	if (!(ev->state & Mod4Mask) && modkeyheld) {
		fprintf(stderr, "[dwm] reconcile (keyrelease): Mod released (lost event)\n");
		modkeyheld = 0;
		if (hidemode) {
			autoshowuntil = time(NULL) + 3;
			updatebarvisibility();
		} else {
			autoshowuntil = 0;
		}
	}
}

void
killclient(const Arg *arg)
{
	if (!selmon->sel)
		return;
	if (!sendevent(selmon->sel, wmatom[WMDelete])) {
		XGrabServer(dpy);
		XSetErrorHandler(xerrordummy);
		XSetCloseDownMode(dpy, DestroyAll);
		XKillClient(dpy, selmon->sel->win);
		XSync(dpy, False);
		XSetErrorHandler(xerror);
		XUngrabServer(dpy);
	}
}

void
manage(Window w, XWindowAttributes *wa)
{
	Client *c, *t = NULL;
	Window trans = None;
	XWindowChanges wc;

	c = ecalloc(1, sizeof(Client));
	c->win = w;
	/* geometry */
	c->x = c->oldx = wa->x;
	c->y = c->oldy = wa->y;
	c->w = c->oldw = wa->width;
	c->h = c->oldh = wa->height;
	c->oldbw = wa->border_width;

	updatetitle(c);
	if (XGetTransientForHint(dpy, w, &trans) && (t = wintoclient(trans))) {
		c->mon = t->mon;
		c->tags = t->tags;
	} else {
		c->mon = selmon;
		applyrules(c);
	}

	/* Dynamic tags: ensure the client's tag appears in the bar */
	c->mon->bartags |= c->tags;

	if (c->x + WIDTH(c) > c->mon->wx + c->mon->ww)
		c->x = c->mon->wx + c->mon->ww - WIDTH(c);
	if (c->y + HEIGHT(c) > c->mon->wy + c->mon->wh)
		c->y = c->mon->wy + c->mon->wh - HEIGHT(c);
	c->x = MAX(c->x, c->mon->wx);
	c->y = MAX(c->y, c->mon->wy);
	c->bw = borderpx;

	wc.border_width = c->bw;
	XConfigureWindow(dpy, w, CWBorderWidth, &wc);
	XSetWindowBorder(dpy, w, scheme[SchemeNorm][ColBorder].pixel);
	configure(c); /* propagates border_width, if size doesn't change */
	updatewindowtype(c);
	updatesizehints(c);
	updatewmhints(c);
	XSelectInput(dpy, w, EnterWindowMask|FocusChangeMask|PropertyChangeMask|StructureNotifyMask);
	grabbuttons(c, 0);
	if (!c->isfloating)
		c->isfloating = c->oldstate = trans != None || c->isfixed;
	if (c->isfloating)
		XRaiseWindow(dpy, c->win);
	attach(c);
	attachstack(c);
	XChangeProperty(dpy, root, netatom[NetClientList], XA_WINDOW, 32, PropModeAppend,
		(unsigned char *) &(c->win), 1);
	XMoveResizeWindow(dpy, c->win, c->x + 2 * sw, c->y, c->w, c->h); /* some windows require this */
	setclientstate(c, NormalState);
	if (c->mon == selmon)
		unfocus(selmon->sel, 0);
	c->mon->sel = c;
	arrange(c->mon);
	XMapWindow(dpy, c->win);
	focus(NULL);

	/* Hide mode: briefly show bar when a new window opens so the
	 * user can see what launched and access the bar. */
	if (hidemode && autoshowuntil <= time(NULL) + 3) {
		fprintf(stderr, "[dwm] manage: new window 0x%lx — extending auto-show to %ld\n",
			(unsigned long)w, (long)(time(NULL) + 3));
		autoshowuntil = time(NULL) + 3;
		updatebarvisibility();
	} else if (hidemode) {
		fprintf(stderr, "[dwm] manage: new window 0x%lx — NOT extending (autoshowuntil=%ld now+3=%ld)\n",
			(unsigned long)w, (long)autoshowuntil, (long)(time(NULL) + 3));
	}
}

void
mappingnotify(XEvent *e)
{
	XMappingEvent *ev = &e->xmapping;

	XRefreshKeyboardMapping(ev);
	if (ev->request == MappingKeyboard) {
		fprintf(stderr, "[dwm] mappingnotify: MappingKeyboard — re-grabbing ALL keys (incl bare Super)\n");
		grabkeys();
	}
}

void
maprequest(XEvent *e)
{
	static XWindowAttributes wa;
	XMapRequestEvent *ev = &e->xmaprequest;

	if (!XGetWindowAttributes(dpy, ev->window, &wa) || wa.override_redirect)
		return;
	if (!wintoclient(ev->window))
		manage(ev->window, &wa);
}

void
monocle(Monitor *m)
{
	unsigned int n = 0, current = 0;
	Client *c;

	for (c = m->clients; c; c = c->next)
		if (ISVISIBLE(c))
			n++;
	if (n == 0) {
		snprintf(m->ltsymbol, sizeof m->ltsymbol, "[0]");
	} else {
		for (c = nexttiled(m->clients), current = 1; c; c = nexttiled(c->next), current++)
			if (c == m->sel)
				break;
		if (current > n)
			current = n;  // Fallback if focus not found
		snprintf(m->ltsymbol, sizeof m->ltsymbol, "[%d/%d]", current, n);
	}
	for (c = nexttiled(m->clients); c; c = nexttiled(c->next))
		resize(c, m->wx, m->wy, m->ww - 2 * c->bw, m->wh - 2 * c->bw, 0);
	// XSync(dpy, False);
}

void
motionnotify(XEvent *e)
{
	static Monitor *mon = NULL;
	Monitor *m;
	XMotionEvent *ev = &e->xmotion;

	if (ev->window != root)
		return;
	if ((m = recttomon(ev->x_root, ev->y_root, 1, 1)) != mon && mon) {
		unfocus(selmon->sel, 1);
		selmon = m;
		focus(NULL);
	}
	mon = m;
}

void
movemouse(const Arg *arg)
{
	int x, y, ocx, ocy, nx, ny;
	Client *c;
	Monitor *m;
	XEvent ev;
	Time lasttime = 0;

	if (!(c = selmon->sel))
		return;
	if (c->isfullscreen) /* no support moving fullscreen windows by mouse */
		return;
	restack(selmon);
	ocx = c->x;
	ocy = c->y;
	if (XGrabPointer(dpy, root, False, MOUSEMASK, GrabModeAsync, GrabModeAsync,
		None, cursor[CurMove]->cursor, CurrentTime) != GrabSuccess)
		return;
	if (!getrootptr(&x, &y))
		return;
	do {
		XMaskEvent(dpy, MOUSEMASK|ExposureMask|SubstructureRedirectMask, &ev);
		switch(ev.type) {
		case ConfigureRequest:
		case Expose:
		case MapRequest:
			handler[ev.type](&ev);
			break;
		case MotionNotify:
			if ((ev.xmotion.time - lasttime) <= (1000 / refreshrate))
				continue;
			lasttime = ev.xmotion.time;

			nx = ocx + (ev.xmotion.x - x);
			ny = ocy + (ev.xmotion.y - y);
			if (abs(selmon->wx - nx) < snap)
				nx = selmon->wx;
			else if (abs((selmon->wx + selmon->ww) - (nx + WIDTH(c))) < snap)
				nx = selmon->wx + selmon->ww - WIDTH(c);
			if (abs(selmon->wy - ny) < snap)
				ny = selmon->wy;
			else if (abs((selmon->wy + selmon->wh) - (ny + HEIGHT(c))) < snap)
				ny = selmon->wy + selmon->wh - HEIGHT(c);
			if (!c->isfloating && selmon->lt[selmon->sellt]->arrange
			&& (abs(nx - c->x) > snap || abs(ny - c->y) > snap))
				togglefloating(NULL);
			if (!selmon->lt[selmon->sellt]->arrange || c->isfloating)
				resize(c, nx, ny, c->w, c->h, 1);
			break;
		}
	} while (ev.type != ButtonRelease);
	XUngrabPointer(dpy, CurrentTime);
	if ((m = recttomon(c->x, c->y, c->w, c->h)) != selmon) {
		sendmon(c, m);
		selmon = m;
		focus(NULL);
	}
}

Client *
nexttiled(Client *c)
{
	for (; c && (c->isfloating || !ISVISIBLE(c)); c = c->next);
	return c;
}

void
pop(Client *c)
{
	detach(c);
	attach(c);
	focus(c);
	arrange(c->mon);
}

void
propertynotify(XEvent *e)
{
	Client *c;
	Window trans;
	XPropertyEvent *ev = &e->xproperty;

	if ((ev->window == root) && (ev->atom == XA_WM_NAME))
		updatestatus();
	else if (ev->state == PropertyDelete)
		return; /* ignore */
	else if ((c = wintoclient(ev->window))) {
		switch(ev->atom) {
		default: break;
		case XA_WM_TRANSIENT_FOR:
			if (!c->isfloating && (XGetTransientForHint(dpy, c->win, &trans)) &&
				(c->isfloating = (wintoclient(trans)) != NULL))
				arrange(c->mon);
			break;
		case XA_WM_NORMAL_HINTS:
			c->hintsvalid = 0;
			break;
		case XA_WM_HINTS:
			updatewmhints(c);
			drawbars();
			break;
		}
		if (ev->atom == XA_WM_NAME || ev->atom == netatom[NetWMName]) {
			updatetitle(c);
			if (c == c->mon->sel)
				drawbar(c->mon);
		}
		if (ev->atom == netatom[NetWMWindowType])
			updatewindowtype(c);
	}
}

void
quit(const Arg *arg)
{
	running = 0;
}

Monitor *
recttomon(int x, int y, int w, int h)
{
	Monitor *m, *r = selmon;
	int a, area = 0;

	for (m = mons; m; m = m->next)
		if ((a = INTERSECT(x, y, w, h, m)) > area) {
			area = a;
			r = m;
		}
	return r;
}

void
resize(Client *c, int x, int y, int w, int h, int interact)
{
	if (applysizehints(c, &x, &y, &w, &h, interact))
		resizeclient(c, x, y, w, h);
}

void
resizeclient(Client *c, int x, int y, int w, int h)
{
	XWindowChanges wc;

	c->oldx = c->x; c->x = wc.x = x;
	c->oldy = c->y; c->y = wc.y = y;
	c->oldw = c->w; c->w = wc.width = w;
	c->oldh = c->h; c->h = wc.height = h;
	wc.border_width = c->bw;
	XConfigureWindow(dpy, c->win, CWX|CWY|CWWidth|CWHeight|CWBorderWidth, &wc);
	configure(c);
	XSync(dpy, False);
}

void
resizemouse(const Arg *arg)
{
	int ocx, ocy, nw, nh;
	Client *c;
	Monitor *m;
	XEvent ev;
	Time lasttime = 0;

	if (!(c = selmon->sel))
		return;
	if (c->isfullscreen) /* no support resizing fullscreen windows by mouse */
		return;
	restack(selmon);
	ocx = c->x;
	ocy = c->y;
	if (XGrabPointer(dpy, root, False, MOUSEMASK, GrabModeAsync, GrabModeAsync,
		None, cursor[CurResize]->cursor, CurrentTime) != GrabSuccess)
		return;
	XWarpPointer(dpy, None, c->win, 0, 0, 0, 0, c->w + c->bw - 1, c->h + c->bw - 1);
	do {
		XMaskEvent(dpy, MOUSEMASK|ExposureMask|SubstructureRedirectMask, &ev);
		switch(ev.type) {
		case ConfigureRequest:
		case Expose:
		case MapRequest:
			handler[ev.type](&ev);
			break;
		case MotionNotify:
			if ((ev.xmotion.time - lasttime) <= (1000 / refreshrate))
				continue;
			lasttime = ev.xmotion.time;

			nw = MAX(ev.xmotion.x - ocx - 2 * c->bw + 1, 1);
			nh = MAX(ev.xmotion.y - ocy - 2 * c->bw + 1, 1);
			if (c->mon->wx + nw >= selmon->wx && c->mon->wx + nw <= selmon->wx + selmon->ww
			&& c->mon->wy + nh >= selmon->wy && c->mon->wy + nh <= selmon->wy + selmon->wh)
			{
				if (!c->isfloating && selmon->lt[selmon->sellt]->arrange
				&& (abs(nw - c->w) > snap || abs(nh - c->h) > snap))
					togglefloating(NULL);
			}
			if (!selmon->lt[selmon->sellt]->arrange || c->isfloating)
				resize(c, c->x, c->y, nw, nh, 1);
			break;
		}
	} while (ev.type != ButtonRelease);
	XWarpPointer(dpy, None, c->win, 0, 0, 0, 0, c->w + c->bw - 1, c->h + c->bw - 1);
	XUngrabPointer(dpy, CurrentTime);
	while (XCheckMaskEvent(dpy, EnterWindowMask, &ev));
	if ((m = recttomon(c->x, c->y, c->w, c->h)) != selmon) {
		sendmon(c, m);
		selmon = m;
		focus(NULL);
	}
}

void
restack(Monitor *m)
{
	Client *c;
	XEvent ev;
	XWindowChanges wc;

	drawbar(m);
	if (!m->sel)
		return;
	if (m->sel->isfloating || !m->lt[m->sellt]->arrange)
		XRaiseWindow(dpy, m->sel->win);
	if (m->lt[m->sellt]->arrange) {
		wc.stack_mode = Below;
		wc.sibling = m->barwin;
		for (c = m->stack; c; c = c->snext)
			if (!c->isfloating && ISVISIBLE(c)) {
				XConfigureWindow(dpy, c->win, CWSibling|CWStackMode, &wc);
				wc.sibling = c->win;
			}
	}
	XSync(dpy, False);
	while (XCheckMaskEvent(dpy, EnterWindowMask, &ev));
}

void
handlefifo(void)
{
	/* Read lines from dwmbar-0 FIFO: hidemode/bar visibility control */
	char line[256], *p;
	int n, i = 0;

	while ((n = read(fifofd, &line[i], 1)) > 0) {
		if (line[i] == '\n' || i >= 254) {
			line[i + (line[i]=='\n' ? 0 : 1)] = '\0';
			p = line;
			/* Strip leading whitespace */
			while (*p == ' ' || *p == '\t') p++;

			if (strncmp(p, "show all", 8) == 0) {
				if (hidemode) {
					fprintf(stderr, "[dwm] FIFO: show all (hidemode=1) — auto-show 3s\n");
					autoshowuntil = time(NULL) + 3;
					updatebarvisibility();
				} else {
					/* Not in hide mode: only restore bars that weren't manually hidden.
					 * We check the dwm_bar_shown state file to respect manual toggles. */
					Monitor *m;
					int showed = 0;
					const char *rt = getenv("XDG_RUNTIME_DIR");
					char sf[256];
					int bar_was_shown = 1;  /* default: don't fight the user */
					if (rt) {
						snprintf(sf, sizeof(sf), "%s/dwm_bar_shown", rt);
						bar_was_shown = (access(sf, F_OK) == 0);
					}
					if (bar_was_shown || !rt) {
						fprintf(stderr, "[dwm] FIFO: show all (hidemode=0) — restoring bars\n");
						for (m = mons; m; m = m->next) {
							if (!m->showbar) {
								m->showbar = 1;
								updatebarpos(m);
								XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
								showed = 1;
							}
						}
						if (showed) {
							arrange(NULL);
							drawbars();
						}
					} else {
						fprintf(stderr, "[dwm] FIFO: show all IGNORED (bar manually hidden)\n");
					}
				}
		} else if (strncmp(p, "hidemode on", 11) == 0) {
			if (!hidemode) {
				Monitor *m;
				const char *rt = getenv("XDG_RUNTIME_DIR");
				char f[256];
				fprintf(stderr, "[dwm] FIFO: hidemode ON\n");
				hidemode = 1;
				autoshowuntil = 0;
				modkeyheld = 0;
				for (m = mons; m; m = m->next) {
					m->showbar = 0;
					updatebarpos(m);
					XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
				}
				arrange(NULL);
				drawbars();
				/* sync state files for scripts */
				if (rt) { snprintf(f, sizeof(f), "%s/hide_mode", rt); close(open(f, O_CREAT|O_WRONLY|O_TRUNC, 0644)); }
				if (rt) { snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt); unlink(f); }
			}
		} else if (strncmp(p, "hidemode off", 12) == 0) {
			if (hidemode) {
				Monitor *m;
				const char *rt = getenv("XDG_RUNTIME_DIR");
				char f[256];
				fprintf(stderr, "[dwm] FIFO: hidemode OFF\n");
				hidemode = 0;
				autoshowuntil = 0;
				modkeyheld = 0;
				for (m = mons; m; m = m->next) {
					m->showbar = 1;
					updatebarpos(m);
					XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
				}
				arrange(NULL);
				drawbars();
				/* sync state files for scripts */
				if (rt) { snprintf(f, sizeof(f), "%s/hide_mode", rt); unlink(f); }
				if (rt) { snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt); close(open(f, O_CREAT|O_WRONLY|O_TRUNC, 0644)); }
			}
			} else if (strncmp(p, "hide all", 8) == 0) {
				const char *rt = getenv("XDG_RUNTIME_DIR");
				char f[256];
				Monitor *m;
				int hidden = 0;
				fprintf(stderr, "[dwm] FIFO: hide all\n");
				for (m = mons; m; m = m->next) {
					if (m->showbar) {
						m->showbar = 0;
						updatebarpos(m);
						XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
						hidden = 1;
					}
				}
				if (hidden) {
					arrange(NULL);
					drawbars();
					/* sync state: bar is hidden */
					if (rt) { snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt); unlink(f); }
				}
			}

			i = 0;
		} else {
			i++;
		}
	}
	/* Log unexpected read failures (EAGAIN is normal for non-blocking FIFO) */
	if (n < 0 && errno != EAGAIN)
		fprintf(stderr, "[dwm] handlefifo: read error: %s\n", strerror(errno));
}

void
run(void)
{
	XEvent ev;
	int xfd = ConnectionNumber(dpy);
	fd_set fds;
	struct timeval tv;
	int maxfd = xfd;

	/* main event loop with auto-hide timer + FIFO support */
	XSync(dpy, False);
	while (running) {
		/* Check auto-hide timer */
		if (autoshowuntil > 0 && time(NULL) >= autoshowuntil) {
			autoshowuntil = 0;
			if (hidemode && !modkeyheld)
				updatebarvisibility();
		}

		/* Process all pending events non-blocking */
		while (XPending(dpy)) {
			XNextEvent(dpy, &ev);
			if (handler[ev.type])
				handler[ev.type](&ev);
		}

		/* Wait for next event with a short timeout so the hide timer
		 * is checked periodically even when idle. Also poll the FIFO. */
		FD_ZERO(&fds);
		FD_SET(xfd, &fds);
		if (fifofd >= 0) {
			FD_SET(fifofd, &fds);
			if (fifofd > maxfd) maxfd = fifofd;
		}
		tv.tv_sec = 1;
		tv.tv_usec = 0;
		select(maxfd + 1, &fds, NULL, NULL, &tv);

		/* Drain FIFO */
		if (fifofd >= 0 && FD_ISSET(fifofd, &fds))
			handlefifo();
	}
}

void
scan(void)
{
	unsigned int i, num;
	Window d1, d2, *wins = NULL;
	XWindowAttributes wa;

	if (XQueryTree(dpy, root, &d1, &d2, &wins, &num)) {
		for (i = 0; i < num; i++) {
			if (!XGetWindowAttributes(dpy, wins[i], &wa)
			|| wa.override_redirect || XGetTransientForHint(dpy, wins[i], &d1))
				continue;
			if (wa.map_state == IsViewable || getstate(wins[i]) == IconicState)
				manage(wins[i], &wa);
		}
		for (i = 0; i < num; i++) { /* now the transients */
			if (!XGetWindowAttributes(dpy, wins[i], &wa))
				continue;
			if (XGetTransientForHint(dpy, wins[i], &d1)
			&& (wa.map_state == IsViewable || getstate(wins[i]) == IconicState))
				manage(wins[i], &wa);
		}
		if (wins)
			XFree(wins);
	}
}

void
sendmon(Client *c, Monitor *m)
{
	if (c->mon == m)
		return;
	unfocus(c, 1);
	detach(c);
	detachstack(c);
	c->mon = m;
	c->tags = m->tagset[m->seltags]; /* assign tags of target monitor */
	attach(c);
	attachstack(c);
	if (c->isfullscreen)
		resizeclient(c, m->mx, m->my, m->mw, m->mh);
	focus(NULL);
	arrange(NULL);
}

void
setclientstate(Client *c, long state)
{
	long data[] = { state, None };

	XChangeProperty(dpy, c->win, wmatom[WMState], wmatom[WMState], 32,
		PropModeReplace, (unsigned char *)data, 2);
}

int
sendevent(Client *c, Atom proto)
{
	int n;
	Atom *protocols;
	int exists = 0;
	XEvent ev;

	if (XGetWMProtocols(dpy, c->win, &protocols, &n)) {
		while (!exists && n--)
			exists = protocols[n] == proto;
		XFree(protocols);
	}
	if (exists) {
		ev.type = ClientMessage;
		ev.xclient.window = c->win;
		ev.xclient.message_type = wmatom[WMProtocols];
		ev.xclient.format = 32;
		ev.xclient.data.l[0] = proto;
		ev.xclient.data.l[1] = CurrentTime;
		XSendEvent(dpy, c->win, False, NoEventMask, &ev);
	}
	return exists;
}

void
setfocus(Client *c)
{
	if (!c->neverfocus)
		XSetInputFocus(dpy, c->win, RevertToPointerRoot, CurrentTime);
	XChangeProperty(dpy, root, netatom[NetActiveWindow], XA_WINDOW, 32,
		PropModeReplace, (unsigned char *)&c->win, 1);
	sendevent(c, wmatom[WMTakeFocus]);
}

void
setfullscreen(Client *c, int fullscreen)
{
	if (fullscreen && !c->isfullscreen) {
		XChangeProperty(dpy, c->win, netatom[NetWMState], XA_ATOM, 32,
			PropModeReplace, (unsigned char*)&netatom[NetWMFullscreen], 1);
		c->isfullscreen = 1;
		c->oldstate = c->isfloating;
		c->oldbw = c->bw;
		c->bw = 0;
		c->isfloating = 1;
		resizeclient(c, c->mon->mx, c->mon->my, c->mon->mw, c->mon->mh);
		XRaiseWindow(dpy, c->win);
	} else if (!fullscreen && c->isfullscreen){
		XChangeProperty(dpy, c->win, netatom[NetWMState], XA_ATOM, 32,
			PropModeReplace, (unsigned char*)0, 0);
		c->isfullscreen = 0;
		c->isfloating = c->oldstate;
		c->bw = c->oldbw;
		c->x = c->oldx;
		c->y = c->oldy;
		c->w = c->oldw;
		c->h = c->oldh;
		resizeclient(c, c->x, c->y, c->w, c->h);
		arrange(c->mon);
		drawbars();
	}
}

void
setlayout(const Arg *arg)
{
	const Layout *newlt;
	unsigned int tagset = selmon->tagset[selmon->seltags];
	int primary = 0;
	if (tagset != TAGMASK) {
		while (!(tagset & (1 << primary)))
			primary++;
	}
	if (!arg || !arg->v) {
		selmon->sellt ^= 1;
		newlt = selmon->lt[selmon->sellt];
	} else {
		newlt = (Layout *)arg->v;
		selmon->lt[selmon->sellt] = newlt;
	}
	if (tagset == TAGMASK) {
		for (int i = 0; i < 9; i++)
			selmon->taglt[i] = newlt;
	} else {
		selmon->taglt[primary] = newlt;
	}
	strncpy(selmon->ltsymbol, newlt->symbol, sizeof selmon->ltsymbol);
	arrangemon(selmon);
	drawbars();
}

/* arg > 1.0 will set mfact absolutely */
void
setmfact(const Arg *arg)
{
	float f;

	if (!arg || !selmon->lt[selmon->sellt]->arrange)
		return;
	f = arg->f < 1.0 ? arg->f + selmon->mfact : arg->f - 1.0;
	if (f < 0.05 || f > 0.95)
		return;
	selmon->mfact = f;
	arrange(selmon);
}

void
setup(void)
{
	int i;
	XSetWindowAttributes wa;
	Atom utf8string;
	struct sigaction sa;

	/* do not transform children into zombies when they terminate */
	sigemptyset(&sa.sa_mask);
	sa.sa_flags = SA_NOCLDSTOP | SA_NOCLDWAIT | SA_RESTART;
	sa.sa_handler = SIG_IGN;
	sigaction(SIGCHLD, &sa, NULL);

	/* clean up any zombies (inherited from .xinitrc etc) immediately */
	while (waitpid(-1, NULL, WNOHANG) > 0);

	/* init screen */
	screen = DefaultScreen(dpy);
	sw = DisplayWidth(dpy, screen);
	sh = DisplayHeight(dpy, screen);
	root = RootWindow(dpy, screen);
	drw = drw_create(dpy, screen, root, sw, sh);
	if (!drw_fontset_create(drw, fonts, LENGTH(fonts)))
		die("no fonts could be loaded.");
	lrpad = drw->fonts->h;
	bh = drw->fonts->h + 2;
	updategeom();
	/* init atoms */
	utf8string = XInternAtom(dpy, "UTF8_STRING", False);
	wmatom[WMProtocols] = XInternAtom(dpy, "WM_PROTOCOLS", False);
	wmatom[WMDelete] = XInternAtom(dpy, "WM_DELETE_WINDOW", False);
	wmatom[WMState] = XInternAtom(dpy, "WM_STATE", False);
	wmatom[WMTakeFocus] = XInternAtom(dpy, "WM_TAKE_FOCUS", False);
	netatom[NetActiveWindow] = XInternAtom(dpy, "_NET_ACTIVE_WINDOW", False);
	netatom[NetSupported] = XInternAtom(dpy, "_NET_SUPPORTED", False);
	netatom[NetWMName] = XInternAtom(dpy, "_NET_WM_NAME", False);
	netatom[NetWMState] = XInternAtom(dpy, "_NET_WM_STATE", False);
	netatom[NetWMCheck] = XInternAtom(dpy, "_NET_SUPPORTING_WM_CHECK", False);
	netatom[NetWMFullscreen] = XInternAtom(dpy, "_NET_WM_STATE_FULLSCREEN", False);
	netatom[NetWMWindowType] = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE", False);
	netatom[NetWMWindowTypeDialog] = XInternAtom(dpy, "_NET_WM_WINDOW_TYPE_DIALOG", False);
	netatom[NetClientList] = XInternAtom(dpy, "_NET_CLIENT_LIST", False);
	/* init cursors */
	cursor[CurNormal] = drw_cur_create(drw, XC_left_ptr);
	cursor[CurResize] = drw_cur_create(drw, XC_sizing);
	cursor[CurMove] = drw_cur_create(drw, XC_fleur);
	/* init appearance */
	scheme = ecalloc(LENGTH(colors), sizeof(Clr *));
	for (i = 0; i < LENGTH(colors); i++)
		scheme[i] = drw_scm_create(drw, colors[i], 3);
	/* init bars */
	updatebars();
	updatestatus();
	/* init bar control FIFO */
	{
		const char *rundir = getenv("XDG_RUNTIME_DIR");
		char fifopath[256];
		if (rundir) {
			snprintf(fifopath, sizeof(fifopath), "%s/dwmbar-0", rundir);
			if (mkfifo(fifopath, 0666) < 0 && errno != EEXIST)
				fprintf(stderr, "[dwm] setup: mkfifo(%s) failed: %s\n", fifopath, strerror(errno));
			fifofd = open(fifopath, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
			if (fifofd < 0)
				fprintf(stderr, "[dwm] setup: open FIFO %s failed: %s\n", fifopath, strerror(errno));
			else
				fprintf(stderr, "[dwm] setup: FIFO %s opened (fd=%d)\n", fifopath, fifofd);
		} else {
			fprintf(stderr, "[dwm] setup: XDG_RUNTIME_DIR not set — FIFO disabled\n");
		}
	}
	/* supporting window for NetWMCheck */
	wmcheckwin = XCreateSimpleWindow(dpy, root, 0, 0, 1, 1, 0, 0, 0);
	XChangeProperty(dpy, wmcheckwin, netatom[NetWMCheck], XA_WINDOW, 32,
		PropModeReplace, (unsigned char *) &wmcheckwin, 1);
	XChangeProperty(dpy, wmcheckwin, netatom[NetWMName], utf8string, 8,
		PropModeReplace, (unsigned char *) "dwm", 3);
	XChangeProperty(dpy, root, netatom[NetWMCheck], XA_WINDOW, 32,
		PropModeReplace, (unsigned char *) &wmcheckwin, 1);
	/* EWMH support per view */
	XChangeProperty(dpy, root, netatom[NetSupported], XA_ATOM, 32,
		PropModeReplace, (unsigned char *) netatom, NetLast);
	XDeleteProperty(dpy, root, netatom[NetClientList]);
	/* select events */
	wa.cursor = cursor[CurNormal]->cursor;
	wa.event_mask = SubstructureRedirectMask|SubstructureNotifyMask
		|ButtonPressMask|PointerMotionMask|EnterWindowMask
		|LeaveWindowMask|StructureNotifyMask|PropertyChangeMask;
	XChangeWindowAttributes(dpy, root, CWEventMask|CWCursor, &wa);
	XSelectInput(dpy, root, wa.event_mask);
	grabkeys();
	/* Bare Super keys for hide-mode are now grabbed inside grabkeys()
	 * so they survive MappingNotify / keyboard remap events. */
	fprintf(stderr, "[dwm] setup: grabkeys() handles bare Super + all keybindings\n");
	focus(NULL);
}

void
seturgent(Client *c, int urg)
{
	XWMHints *wmh;

	c->isurgent = urg;
	if (!(wmh = XGetWMHints(dpy, c->win)))
		return;
	wmh->flags = urg ? (wmh->flags | XUrgencyHint) : (wmh->flags & ~XUrgencyHint);
	XSetWMHints(dpy, c->win, wmh);
	XFree(wmh);
}

void
showhide(Client *c)
{
	if (!c)
		return;
	if (ISVISIBLE(c)) {
		/* show clients top down */
		XMoveWindow(dpy, c->win, c->x, c->y);
		if ((!c->mon->lt[c->mon->sellt]->arrange || c->isfloating) && !c->isfullscreen)
			resize(c, c->x, c->y, c->w, c->h, 0);
		showhide(c->snext);
	} else {
		/* hide clients bottom up */
		showhide(c->snext);
		XMoveWindow(dpy, c->win, WIDTH(c) * -2, c->y);
	}
}

void
spawn(const Arg *arg)
{
	struct sigaction sa;

	if (arg->v == dmenucmd)
		dmenumon[0] = '0' + selmon->num;
	if (fork() == 0) {
		if (dpy)
			close(ConnectionNumber(dpy));
		setsid();

		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sa.sa_handler = SIG_DFL;
		sigaction(SIGCHLD, &sa, NULL);

		execvp(((char **)arg->v)[0], (char **)arg->v);
		die("dwm: execvp '%s' failed:", ((char **)arg->v)[0]);
	}
}

void
tag(const Arg *arg)
{
	/* Rule 5: only tag onto tags that are in the bar */
	if (selmon->sel && (arg->ui & TAGMASK) && (selmon->bartags & arg->ui)) {
		selmon->sel->tags = arg->ui & TAGMASK;
		focus(NULL);
		arrange(selmon);
	}
}

void
tagmon(const Arg *arg)
{
	if (!selmon->sel || !mons->next)
		return;
	sendmon(selmon->sel, dirtomon(arg->i));
}

void
tile(Monitor *m)
{
	unsigned int i, n, h, mw, my, ty;
	Client *c;

	for (n = 0, c = nexttiled(m->clients); c; c = nexttiled(c->next), n++);
	if (n == 0)
		return;

	if (n > m->nmaster)
		mw = m->nmaster ? m->ww * m->mfact : 0;
	else
		mw = m->ww;
	for (i = my = ty = 0, c = nexttiled(m->clients); c; c = nexttiled(c->next), i++)
		if (i < m->nmaster) {
			h = (m->wh - my) / (MIN(n, m->nmaster) - i);
			resize(c, m->wx, m->wy + my, mw - (2*c->bw), h - (2*c->bw), 0);
			if (my + HEIGHT(c) < m->wh)
				my += HEIGHT(c);
		} else {
			h = (m->wh - ty) / (n - i);
			resize(c, m->wx + mw, m->wy + ty, m->ww - mw - (2*c->bw), h - (2*c->bw), 0);
			if (ty + HEIGHT(c) < m->wh)
				ty += HEIGHT(c);
		}
}

void
togglebar(const Arg *arg)
{
	const char *rt = getenv("XDG_RUNTIME_DIR");
	char f[256];
	int was_hidemode = hidemode;

	/* Always exit hide mode if it's on (matches dwl toggle-bar.sh behaviour). */
	if (hidemode) {
		fprintf(stderr, "[dwm] togglebar: exiting hide mode\n");
		hidemode = 0;
		autoshowuntil = 0;
		modkeyheld = 0;
		if (rt) { snprintf(f, sizeof(f), "%s/hide_mode", rt); unlink(f); }
	}

	/* Toggle bar visibility on selected monitor. */
	selmon->showbar = !selmon->showbar;
	fprintf(stderr, "[dwm] togglebar: %s bar on monitor %d%s\n",
		selmon->showbar ? "showing" : "hiding", selmon->num,
		was_hidemode ? " (exited hide mode)" : "");

	updatebarpos(selmon);
	XMoveResizeWindow(dpy, selmon->barwin, selmon->wx, selmon->by, selmon->ww, bh);
	arrange(selmon);
	drawbars();

	/* Sync state file + temp message for scripts. */
	if (rt) {
		snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt);
		if (selmon->showbar) {
			close(open(f, O_CREAT|O_WRONLY|O_TRUNC, 0644));
			/* Temp message: "(Hide Mode Off + Bar Visible [Mod+B])" for 4s */
			if (was_hidemode) {
				FILE *fp;
				snprintf(f, sizeof(f), "%s/status_msg", rt);
				fp = fopen(f, "w");
				if (fp) { fprintf(fp, "(Hide Mode Off + Bar Visible [Mod+B])"); fclose(fp); }
				snprintf(f, sizeof(f), "%s/status_end", rt);
				fp = fopen(f, "w");
				if (fp) { fprintf(fp, "%ld", (long)time(NULL) + 4); fclose(fp); }
			}
		} else {
			unlink(f);
		}
	}
}

void
togglehidemode(const Arg *arg)
{
	Monitor *m;
	hidemode = !hidemode;
	if (hidemode) {
		fprintf(stderr, "[dwm] togglehidemode: ON — hiding bar, clearing modkeyheld\n");
		/* Turning hide mode ON: hide bar, reset timers */
		modkeyheld = 0;
		autoshowuntil = 0;
		for (m = mons; m; m = m->next) {
			m->showbar = 0;
			updatebarpos(m);
			XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
		}
		arrange(NULL);
		drawbars();
		/* sync state files + temp message for scripts */
		{ const char *rt = getenv("XDG_RUNTIME_DIR"); char f[256];
		  if (rt) { snprintf(f, sizeof(f), "%s/hide_mode", rt); close(open(f, O_CREAT|O_WRONLY|O_TRUNC, 0644)); }
		  if (rt) { snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt); unlink(f); }
		  /* Temp message: "(Hide Mode On [Mod+H])" for 4s */
		  if (rt) {
		    FILE *fp;
		    snprintf(f, sizeof(f), "%s/status_msg", rt);
		    fp = fopen(f, "w");
		    if (fp) { fprintf(fp, "(Hide Mode On [Mod+H])"); fclose(fp); }
		    snprintf(f, sizeof(f), "%s/status_end", rt);
		    fp = fopen(f, "w");
		    if (fp) { fprintf(fp, "%ld", (long)time(NULL) + 4); fclose(fp); }
		  }
		}
	} else {
		fprintf(stderr, "[dwm] togglehidemode: OFF — showing bar\n");
		/* Turning hide mode OFF: show bar permanently */
		for (m = mons; m; m = m->next) {
			m->showbar = 1;
			updatebarpos(m);
			XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
		}
		arrange(NULL);
		drawbars();
		/* sync state files + temp message for scripts */
		{ const char *rt = getenv("XDG_RUNTIME_DIR"); char f[256];
		  if (rt) { snprintf(f, sizeof(f), "%s/hide_mode", rt); unlink(f); }
		  if (rt) { snprintf(f, sizeof(f), "%s/dwm_bar_shown", rt); close(open(f, O_CREAT|O_WRONLY|O_TRUNC, 0644)); }
		  /* Temp message: "(Hide Mode Off [Mod+H])" for 4s */
		  if (rt) {
		    FILE *fp;
		    snprintf(f, sizeof(f), "%s/status_msg", rt);
		    fp = fopen(f, "w");
		    if (fp) { fprintf(fp, "(Hide Mode Off [Mod+H])"); fclose(fp); }
		    snprintf(f, sizeof(f), "%s/status_end", rt);
		    fp = fopen(f, "w");
		    if (fp) { fprintf(fp, "%ld", (long)time(NULL) + 4); fclose(fp); }
		  }
		}
	}
}

void
updatebarvisibility(void)
{
	Monitor *m;
	int shouldshow;

	/* updatebarvisibility is the hide-mode auto-show/hide manager.
	 * When hide mode is OFF, bar visibility is manually controlled via
	 * togglebar() or config defaults — never override it here. */
	if (!hidemode)
		return;

	shouldshow = modkeyheld || (autoshowuntil > 0 && time(NULL) < autoshowuntil);
	fprintf(stderr, "[dwm] updatebarvisibility: shouldshow=%d (hidemode=%d modkeyheld=%d autoUntil=%ld)\n",
		shouldshow, hidemode, modkeyheld, (long)autoshowuntil);

	for (m = mons; m; m = m->next) {
		if (m->showbar != shouldshow) {
			fprintf(stderr, "[dwm] updatebarvisibility: %s bar on monitor %d\n",
				shouldshow ? "showing" : "hiding", m->num);
			m->showbar = shouldshow;
			updatebarpos(m);
			XMoveResizeWindow(dpy, m->barwin, m->wx, m->by, m->ww, bh);
		}
	}
	/* NO arrange — temp show/hide must not resize windows.
	 * Only explicit toggles (togglebar, togglehidemode, FIFO commands)
	 * call arrange() to resize the screen. */
	drawbars();
}

void
togglefloating(const Arg *arg)
{
	if (!selmon->sel)
		return;
	if (selmon->sel->isfullscreen) /* no support for fullscreen windows */
		return;
	selmon->sel->isfloating = !selmon->sel->isfloating || selmon->sel->isfixed;
	if (selmon->sel->isfloating)
		resize(selmon->sel, selmon->sel->x, selmon->sel->y,
			selmon->sel->w, selmon->sel->h, 0);
	arrange(selmon);
}

void
toggletag(const Arg *arg)
{
	unsigned int newtags;

	if (!selmon->sel)
		return;
	if (!(selmon->bartags & (arg->ui & TAGMASK)))
		return;
	newtags = selmon->sel->tags ^ (arg->ui & TAGMASK);
	if (newtags) {
		selmon->sel->tags = newtags;
		focus(NULL);
		arrange(selmon);
	}
}

void
toggleview(const Arg *arg)
{
	unsigned int mask = arg->ui & TAGMASK;
	if (!(selmon->bartags & mask))
		return;

	unsigned int newbartags = selmon->bartags ^ mask;
	if (newbartags) {
		selmon->bartags = newbartags;
		ensurebartagsvalid(selmon);
		focus(NULL);
		arrange(selmon);
		drawbars();
	}
}

void
unfocus(Client *c, int setfocus)
{
	if (!c)
		return;
	grabbuttons(c, 0);
	XSetWindowBorder(dpy, c->win, scheme[SchemeNorm][ColBorder].pixel);
	if (setfocus) {
		XSetInputFocus(dpy, root, RevertToPointerRoot, CurrentTime);
		XDeleteProperty(dpy, root, netatom[NetActiveWindow]);
	}
}

void
unmanage(Client *c, int destroyed)
{
	Monitor *m = c->mon;
	XWindowChanges wc;

	detach(c);
	detachstack(c);
	if (!destroyed) {
		wc.border_width = c->oldbw;
		XGrabServer(dpy); /* avoid race conditions */
		XSetErrorHandler(xerrordummy);
		XSelectInput(dpy, c->win, NoEventMask);
		XConfigureWindow(dpy, c->win, CWBorderWidth, &wc); /* restore border */
		XUngrabButton(dpy, AnyButton, AnyModifier, c->win);
		setclientstate(c, WithdrawnState);
		XSync(dpy, False);
		XSetErrorHandler(xerror);
		XUngrabServer(dpy);
	}
	free(c);

	/* Dynamic tags: recalculate bar visibility after client removal */
	{
		unsigned int newset = 1;  /* tag 1 always in bar */
		Client *cl;
		for (cl = m->clients; cl; cl = cl->next)
			newset |= cl->tags;
		/* Don't hide the tag the user is currently on */
		newset |= (1 << m->curtagidx);
		m->bartags = newset & TAGMASK;
		ensurebartagsvalid(m);
	}
	focus(NULL);
	updateclientlist();
	arrange(m);
}

void
unmapnotify(XEvent *e)
{
	Client *c;
	XUnmapEvent *ev = &e->xunmap;

	if ((c = wintoclient(ev->window))) {
		if (ev->send_event)
			setclientstate(c, WithdrawnState);
		else
			unmanage(c, 0);
	}
}

void
updatebars(void)
{
	Monitor *m;
	XSetWindowAttributes wa = {
		.override_redirect = True,
		.background_pixmap = ParentRelative,
		.event_mask = ButtonPressMask|ExposureMask
	};
	XClassHint ch = {"dwm", "dwm"};
	for (m = mons; m; m = m->next) {
		if (m->barwin)
			continue;
		m->barwin = XCreateWindow(dpy, root, m->wx, m->by, m->ww, bh, 0, DefaultDepth(dpy, screen),
				CopyFromParent, DefaultVisual(dpy, screen),
				CWOverrideRedirect|CWBackPixmap|CWEventMask, &wa);
		XDefineCursor(dpy, m->barwin, cursor[CurNormal]->cursor);
		XMapRaised(dpy, m->barwin);
		XSetClassHint(dpy, m->barwin, &ch);
	}
}

void
updatebarpos(Monitor *m)
{
	m->wy = m->my;
	m->wh = m->mh;
	if (m->showbar && !hidemode) {
		/* Permanent bar: reserve space at top/bottom */
		m->wh -= bh;
		m->by = m->topbar ? m->wy : m->wy + m->wh;
		m->wy = m->topbar ? m->wy + bh : m->wy;
	} else if (m->showbar && hidemode) {
		/* Hide-mode temp bar: overlay on top, don't resize windows */
		m->by = m->topbar ? m->my : m->my + m->mh - bh;
	} else
		m->by = -bh;
}

void
updateclientlist(void)
{
	Client *c;
	Monitor *m;

	XDeleteProperty(dpy, root, netatom[NetClientList]);
	for (m = mons; m; m = m->next)
		for (c = m->clients; c; c = c->next)
			XChangeProperty(dpy, root, netatom[NetClientList],
				XA_WINDOW, 32, PropModeAppend,
				(unsigned char *) &(c->win), 1);
}

int
updategeom(void)
{
	int dirty = 0;

#ifdef XINERAMA
	if (XineramaIsActive(dpy)) {
		int i, j, n, nn;
		Client *c;
		Monitor *m;
		XineramaScreenInfo *info = XineramaQueryScreens(dpy, &nn);
		XineramaScreenInfo *unique = NULL;

		for (n = 0, m = mons; m; m = m->next, n++);
		/* only consider unique geometries as separate screens */
		unique = ecalloc(nn, sizeof(XineramaScreenInfo));
		for (i = 0, j = 0; i < nn; i++)
			if (isuniquegeom(unique, j, &info[i]))
				memcpy(&unique[j++], &info[i], sizeof(XineramaScreenInfo));
		XFree(info);
		nn = j;

		/* new monitors if nn > n */
		for (i = n; i < nn; i++) {
			for (m = mons; m && m->next; m = m->next);
			if (m)
				m->next = createmon();
			else
				mons = createmon();
		}
		for (i = 0, m = mons; i < nn && m; m = m->next, i++)
			if (i >= n
			|| unique[i].x_org != m->mx || unique[i].y_org != m->my
			|| unique[i].width != m->mw || unique[i].height != m->mh)
			{
				dirty = 1;
				m->num = i;
				m->mx = m->wx = unique[i].x_org;
				m->my = m->wy = unique[i].y_org;
				m->mw = m->ww = unique[i].width;
				m->mh = m->wh = unique[i].height;
				updatebarpos(m);
			}
		/* removed monitors if n > nn */
		for (i = nn; i < n; i++) {
			for (m = mons; m && m->next; m = m->next);
			while ((c = m->clients)) {
				dirty = 1;
				m->clients = c->next;
				detachstack(c);
				c->mon = mons;
				attach(c);
				attachstack(c);
			}
			if (m == selmon)
				selmon = mons;
			cleanupmon(m);
		}
		free(unique);
	} else
#endif /* XINERAMA */
	{ /* default monitor setup */
		if (!mons)
			mons = createmon();
		if (mons->mw != sw || mons->mh != sh) {
			dirty = 1;
			mons->mw = mons->ww = sw;
			mons->mh = mons->wh = sh;
			updatebarpos(mons);
		}
	}
	if (dirty) {
		selmon = mons;
		selmon = wintomon(root);
	}
	return dirty;
}

void
updatenumlockmask(void)
{
	unsigned int i, j;
	XModifierKeymap *modmap;

	numlockmask = 0;
	modmap = XGetModifierMapping(dpy);
	for (i = 0; i < 8; i++)
		for (j = 0; j < modmap->max_keypermod; j++)
			if (modmap->modifiermap[i * modmap->max_keypermod + j]
				== XKeysymToKeycode(dpy, XK_Num_Lock))
				numlockmask = (1 << i);
	XFreeModifiermap(modmap);
}

void
updatesizehints(Client *c)
{
	long msize;
	XSizeHints size;

	if (!XGetWMNormalHints(dpy, c->win, &size, &msize))
		/* size is uninitialized, ensure that size.flags aren't used */
		size.flags = PSize;
	if (size.flags & PBaseSize) {
		c->basew = size.base_width;
		c->baseh = size.base_height;
	} else if (size.flags & PMinSize) {
		c->basew = size.min_width;
		c->baseh = size.min_height;
	} else
		c->basew = c->baseh = 0;
	if (size.flags & PResizeInc) {
		c->incw = size.width_inc;
		c->inch = size.height_inc;
	} else
		c->incw = c->inch = 0;
	if (size.flags & PMaxSize) {
		c->maxw = size.max_width;
		c->maxh = size.max_height;
	} else
		c->maxw = c->maxh = 0;
	if (size.flags & PMinSize) {
		c->minw = size.min_width;
		c->minh = size.min_height;
	} else if (size.flags & PBaseSize) {
		c->minw = size.base_width;
		c->minh = size.base_height;
	} else
		c->minw = c->minh = 0;
	if (size.flags & PAspect) {
		c->mina = (float)size.min_aspect.y / size.min_aspect.x;
		c->maxa = (float)size.max_aspect.x / size.max_aspect.y;
	} else
		c->maxa = c->mina = 0.0;
	c->isfixed = (c->maxw && c->maxh && c->maxw == c->minw && c->maxh == c->minh);
	c->hintsvalid = 1;
}

void
updatestatus(void)
{
	if (!gettextprop(root, XA_WM_NAME, stext, sizeof(stext)))
		strcpy(stext, "dwm-"VERSION);
	drawbar(selmon);
}

void
updatetitle(Client *c)
{
	if (!gettextprop(c->win, netatom[NetWMName], c->name, sizeof c->name))
		gettextprop(c->win, XA_WM_NAME, c->name, sizeof c->name);
	if (c->name[0] == '\0') /* hack to mark broken clients */
		strcpy(c->name, broken);
}

void
updatewindowtype(Client *c)
{
	Atom state = getatomprop(c, netatom[NetWMState]);
	Atom wtype = getatomprop(c, netatom[NetWMWindowType]);

	if (state == netatom[NetWMFullscreen])
		setfullscreen(c, 1);
	if (wtype == netatom[NetWMWindowTypeDialog])
		c->isfloating = 1;
}

void
updatewmhints(Client *c)
{
	XWMHints *wmh;

	if ((wmh = XGetWMHints(dpy, c->win))) {
		if (c == selmon->sel && wmh->flags & XUrgencyHint) {
			wmh->flags &= ~XUrgencyHint;
			XSetWMHints(dpy, c->win, wmh);
		} else
			c->isurgent = (wmh->flags & XUrgencyHint) ? 1 : 0;
		if (wmh->flags & InputHint)
			c->neverfocus = !wmh->input;
		else
			c->neverfocus = 0;
		XFree(wmh);
	}
}

/* Dynamic tags: check if a tag index has any windows on this monitor */
int
tagisoccupied(Monitor *m, int tagidx)
{
	Client *c;
	for (c = m->clients; c; c = c->next)
		if (c->tags & (1 << tagidx))
			return 1;
	return 0;
}

/* Dynamic tags: ensure tag 1 is always in the bar and curtagidx is valid,
 * and keep tagset pinned to the current tag so only its windows show. */
void
ensurebartagsvalid(Monitor *m)
{
	m->bartags |= 1;  /* tag 1 (anchor) is always in the bar */
	if (!(m->bartags & (1 << m->curtagidx))) {
		m->curtagidx = __builtin_ffs(m->bartags) - 1;
		if (m->curtagidx < 0)
			m->curtagidx = 0;
	}
	m->tagset[0] = m->tagset[1] = 1 << m->curtagidx;
}

void
view(const Arg *arg)
{
	Monitor *m = selmon;
	unsigned int mask = arg->ui & TAGMASK;

	/* Mod+0: show all tags in the bar */
	if (mask == TAGMASK) {
		m->bartags = TAGMASK;
		m->curtagidx = 0;
		m->tagset[0] = m->tagset[1] = 1;
		focus(NULL);
		arrange(m);
		drawbars();
		return;
	}

	/* Rule 5: only switch to tags that are in the bar */
	if (!(m->bartags & mask))
		return;

	int idx = __builtin_ffs(mask) - 1;
	if (idx < 0 || idx == m->curtagidx)
		return;

	m->curtagidx = idx;
	m->tagset[0] = m->tagset[1] = 1 << idx;
	focus(NULL);
	arrange(m);
	drawbars();
}

void
viewnext(const Arg *arg)
{
	Monitor *m = selmon;

	/* Rule 3b: current tag must have windows to advance */
	if (!tagisoccupied(m, m->curtagidx))
		return;
	if (m->curtagidx >= LENGTH(tags) - 1)
		return;

	int next = m->curtagidx + 1;
	m->bartags |= (1 << next);          /* reveal in bar */
	m->curtagidx = next;
	m->tagset[0] = m->tagset[1] = 1 << next;  /* only new tag's windows */
	focus(NULL);
	arrange(m);
	drawbars();
}

void
viewprev(const Arg *arg)
{
	Monitor *m = selmon;
	int oldidx = m->curtagidx;

	/* Rule 3c/6: leaving an empty non-anchor tag */
	if (oldidx > 0 && !tagisoccupied(m, oldidx)) {
		/* Check if there are any higher-numbered occupied tags */
		int has_higher = 0, i;
		for (i = oldidx + 1; i < LENGTH(tags); i++) {
			if (tagisoccupied(m, i)) {
				has_higher = 1;
				break;
			}
		}

		if (has_higher) {
			/* Rule 6a: collapse — shift all higher tags down by one,
			 * reassigning every window to fill the gap. */
			for (i = oldidx; i < LENGTH(tags) - 1; i++) {
				Client *c;
				unsigned int from = 1 << (i + 1);
				unsigned int to   = 1 << i;
				for (c = m->clients; c; c = c->next) {
					if (c->tags & from) {
						c->tags &= ~from;
						c->tags |= to;
					}
				}
				/* Shift bartags: if i+1 was in bar, move to i */
				if (m->bartags & from) {
					m->bartags |= to;
					m->bartags &= ~from;
				} else {
					m->bartags &= ~to;
				}
			}
		} else {
			/* Rule 6b: no higher populated tags — just hide this one */
			m->bartags &= ~(1 << oldidx);
		}
	}

	/* Find previous tag in the bar */
	int prev;
	for (prev = oldidx - 1; prev >= 0; prev--)
		if (m->bartags & (1 << prev))
			break;
	if (prev < 0) {
		ensurebartagsvalid(m);
		return;
	}

	m->curtagidx = prev;
	m->tagset[0] = m->tagset[1] = 1 << prev;
	focus(NULL);
	arrange(m);
	drawbars();
}

void
tagnext(const Arg *arg)
{
	Monitor *m = selmon;
	if (!m->sel || m->curtagidx >= LENGTH(tags) - 1)
		return;

	int next = m->curtagidx + 1;
	unsigned int nextmask = 1 << next;

	m->sel->tags = nextmask;
	m->bartags |= nextmask;  /* reveal destination in bar */
	m->curtagidx = next;
	m->tagset[0] = m->tagset[1] = nextmask;
	focus(NULL);
	arrange(m);
	drawbars();
}

void
tagprev(const Arg *arg)
{
	Monitor *m = selmon;
	if (!m->sel || m->curtagidx <= 0)
		return;

	unsigned int bt = m->bartags;
	int prev;
	for (prev = m->curtagidx - 1; prev >= 0; prev--)
		if (bt & (1 << prev))
			break;
	if (prev < 0)
		return;

	m->sel->tags = 1 << prev;
	focus(NULL);
	arrange(m);
	drawbars();
}

Client *
wintoclient(Window w)
{
	Client *c;
	Monitor *m;

	for (m = mons; m; m = m->next)
		for (c = m->clients; c; c = c->next)
			if (c->win == w)
				return c;
	return NULL;
}

Monitor *
wintomon(Window w)
{
	int x, y;
	Client *c;
	Monitor *m;

	if (w == root && getrootptr(&x, &y))
		return recttomon(x, y, 1, 1);
	for (m = mons; m; m = m->next)
		if (w == m->barwin)
			return m;
	if ((c = wintoclient(w)))
		return c->mon;
	return selmon;
}

/* There's no way to check accesses to destroyed windows, thus those cases are
 * ignored (especially on UnmapNotify's). Other types of errors call Xlibs
 * default error handler, which may call exit. */
int
xerror(Display *dpy, XErrorEvent *ee)
{
	if (ee->error_code == BadWindow
	|| (ee->request_code == X_SetInputFocus && ee->error_code == BadMatch)
	|| (ee->request_code == X_PolyText8 && ee->error_code == BadDrawable)
	|| (ee->request_code == X_PolyFillRectangle && ee->error_code == BadDrawable)
	|| (ee->request_code == X_PolySegment && ee->error_code == BadDrawable)
	|| (ee->request_code == X_ConfigureWindow && ee->error_code == BadMatch)
	|| (ee->request_code == X_GrabButton && ee->error_code == BadAccess)
	|| (ee->request_code == X_GrabKey && ee->error_code == BadAccess)
	|| (ee->request_code == X_CopyArea && ee->error_code == BadDrawable))
		return 0;
	fprintf(stderr, "dwm: fatal error: request code=%d, error code=%d\n",
		ee->request_code, ee->error_code);
	return xerrorxlib(dpy, ee); /* may call exit */
}

int
xerrordummy(Display *dpy, XErrorEvent *ee)
{
	return 0;
}

/* Startup Error handler to check if another window manager
 * is already running. */
int
xerrorstart(Display *dpy, XErrorEvent *ee)
{
	die("dwm: another window manager is already running");
	return -1;
}

void
zoom(const Arg *arg)
{
	Client *c = selmon->sel;

	if (!selmon->lt[selmon->sellt]->arrange || !c || c->isfloating)
		return;
	if (c == nexttiled(selmon->clients) && !(c = nexttiled(c->next)))
		return;
	pop(c);
}

int
main(int argc, char *argv[])
{
	if (argc == 2 && !strcmp("-v", argv[1]))
		die("dwm-"VERSION);
	else if (argc != 1)
		die("usage: dwm [-v]");
	if (!setlocale(LC_CTYPE, "") || !XSupportsLocale())
		fputs("warning: no locale support\n", stderr);
	if (!(dpy = XOpenDisplay(NULL)))
		die("dwm: cannot open display");
	checkotherwm();
	setup();
#ifdef __OpenBSD__
	if (pledge("stdio rpath proc exec", NULL) == -1)
		die("pledge");
#endif /* __OpenBSD__ */
	scan();
	run();
	cleanup();
	XCloseDisplay(dpy);
	return EXIT_SUCCESS;
}
