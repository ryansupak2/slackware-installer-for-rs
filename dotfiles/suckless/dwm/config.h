/* See LICENSE file for copyright and license details. */

#include <X11/XF86keysym.h>


/* appearance */
static const unsigned int borderpx  = 1;        /* border pixel of windows */
static const unsigned int snap      = 32;       /* snap pixel */
static const int showbar            = 1;        /* 0 means no bar */
static const int topbar             = 1;        /* 0 means bottom bar */
/* pixelsize (not "size") keeps the bar DPI-independent and in the same units as st's
 * font, so the bar text never shrinks relative to the terminal on hidpi panels. */
static const char *fonts[]          = { "Berkeley Mono:pixelsize=28", "DejaVu Sans Mono:pixelsize=28", "Noto Sans CJK JP:pixelsize=28", "Noto Color Emoji:pixelsize=24" };
static const char dmenufont[]       = "Berkeley Mono:pixelsize=28";
static const char col_gray1[]       = "#000000";
static const char col_gray2[]       = "#444444";
static const char col_gray3[]       = "#bbbbbb";
static const char col_gray4[]       = "#eeeeee";
static const char col_cyan[]        = "#005577";
static const char *colors[][3]      = {
	/*               fg         bg         border   */
	[SchemeNorm] = { col_gray3, col_gray1, col_gray2 },
	[SchemeSel]  = { "#ffffff", col_gray1, col_gray1 },
};

/* tagging */
static const char *tags[] = { "1", "2", "3", "4", "5", "6", "7", "8", "9" };

static const Rule rules[] = {
	/* xprop(1):
	 *	WM_CLASS(STRING) = instance, class
	 *	WM_NAME(STRING) = title
	 */
	/* class      instance    title       tags mask     isfloating   monitor */
	{ NULL,       NULL,       "Open File",    0,            1,           -1 },
	{ NULL,       NULL,       "Save File",    0,            1,           -1 },
	{ NULL,       NULL,       "Save As",      0,            1,           -1 },
	{ NULL,       NULL,       "Select File",  0,            1,           -1 },
	{ "Gimp",     NULL,       NULL,       0,            1,           -1 },
	{ "Firefox",  NULL,       NULL,       1 << 8,       0,           -1 },
};

/* layout(s) */
static const float mfact     = 0.55; /* factor of master area size [0.05..0.95] */
static const int nmaster     = 1;    /* number of clients in master area */
/* Size hints OFF for tiled windows. st advertises PResizeInc (height_inc =
 * character height ≈34px at Berkeley Mono pixelsize=28), so honouring the hints
 * snapped every tiled st window down to a whole number of rows and left up to
 * one cell (~50px) of bare desktop under it. dwm now hands st the full area and
 * st draws a partial last row instead — windows reach the bottom edge, matching
 * hint-less clients like Chrome. */
static const int resizehints = 0;    /* 0 = ignore size hints in tiled resizals */
static const int lockfullscreen = 1; /* 1 will force focus on the fullscreen window */
static const int refreshrate = 120;  /* refresh rate (per second) for client move/resize */

static const Layout layouts[] = {
	/* symbol     arrange function */
	{ "[M]",      monocle },  /* first entry is default */
	{ "[]=",      tile },
	{ "><>",      NULL },    /* no layout function means floating behavior */
};

/* key definitions */
#define MODKEY Mod4Mask
#define TAGKEYS(KEY,TAG) \
	{ MODKEY,                       KEY,      view,           {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask,           KEY,      toggleview,     {.ui = 1 << TAG} }, \
	{ MODKEY|ShiftMask,             KEY,      tag,            {.ui = 1 << TAG} }, \
	{ MODKEY|ControlMask|ShiftMask, KEY,      toggletag,      {.ui = 1 << TAG} },

/* helper for spawning shell commands in the pre dwm-5.0 fashion */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static char dmenumon[2] = "0"; /* component of dmenucmd, manipulated in spawn() */
static const char *dmenucmd[] = { "bemenu-run", NULL };
static const char *termcmd[]  = { "st", NULL };
static const char *surfcmd[]  = { "/usr/local/bin/browser", NULL };

static const Key keys[] = {
	/* modifier                     key        function        argument */
	{ MODKEY,                       XK_r,      spawn,          {.v = dmenucmd } },
	{ MODKEY,                       XK_Return, spawn,          {.v = termcmd } },
	{ ControlMask|ShiftMask,        XK_t,      spawn,          {.v = termcmd } },
	{ ControlMask|ShiftMask,        XK_b,      spawn,          {.v = surfcmd } },
	{ MODKEY,                       XK_b,      togglebar,      {0} },
	{ MODKEY,                       XK_Down,   focusstack,     {.i = +1 } },
	{ MODKEY,                       XK_Up,     focusstack,     {.i = -1 } },
	{ MODKEY,                       XK_bracketright, setmfact, {.f = +0.05f} },
	/* Mod+Escape: lock the screen (steps/slock.sh builds sources/slock).
	 * Unlock with the password of $USER (root here). slock ignores SIGTERM —
	 * if it ever wedges, Ctrl+Alt+F2 then `pkill -9 slock`. */
	{ MODKEY,                       XK_Escape, spawn,          SHCMD("/usr/local/bin/slock") },
	{ MODKEY,                       XK_t,      setlayout,      {.v = &layouts[1]} },
	{ MODKEY,                       XK_f,      setlayout,      {.v = &layouts[2]} },
	{ MODKEY,                       XK_m,      setlayout,      {.v = &layouts[0]} },
	{ MODKEY,                       XK_0,      view,           {.ui = ~0 } },
	{ MODKEY|ShiftMask,             XK_0,      tag,            {.ui = ~0 } },
	{ MODKEY,                       XK_comma,  focusmon,       {.i = -1 } },
	{ MODKEY,                       XK_period, focusmon,       {.i = +1 } },
	{ MODKEY|ShiftMask,             XK_comma,  tagmon,         {.i = -1 } },
	{ MODKEY|ShiftMask,             XK_period, tagmon,         {.i = +1 } },
	TAGKEYS(                        XK_1,                      0)
	TAGKEYS(                        XK_2,                      1)
	TAGKEYS(                        XK_3,                      2)
	TAGKEYS(                        XK_4,                      3)
	TAGKEYS(                        XK_5,                      4)
	TAGKEYS(                        XK_6,                      5)
	TAGKEYS(                        XK_7,                      6)
	TAGKEYS(                        XK_8,                      7)
	TAGKEYS(                        XK_9,                      8)
	{ MODKEY|ShiftMask,             XK_Left,   tagprev,        {0} },
	{ MODKEY|ShiftMask,             XK_Right,  tagnext,        {0} },
	{ MODKEY,                       XK_Left,   viewprev,       {0} },
	{ MODKEY,                       XK_Right,  viewnext,       {0} },
	{ MODKEY,                       XK_w,      focusstack,     {.i = -1 } },
	{ MODKEY,                       XK_s,      focusstack,     {.i = +1 } },
	{ MODKEY,                       XK_a,      viewprev,       {0} },
	{ MODKEY|ShiftMask,             XK_a,      tagprev,        {0} },
	{ MODKEY,                       XK_d,      viewnext,       {0} },
	{ MODKEY|ShiftMask,             XK_d,      tagnext,        {0} },
	{ MODKEY|ShiftMask,             XK_q,      quit,           {0} },
	{ MODKEY|ShiftMask,             XK_z,      killclient,     {0} },
	{ MODKEY,                       XK_h,      togglehidemode, {0} },
	{ MODKEY,                       XK_v,      spawn,          SHCMD("/usr/local/bin/toggle-vox.sh") },
	{ MODKEY|ShiftMask,             XK_v,      spawn,          SHCMD("/usr/local/bin/toggle-vox-record.sh") },
	/* Media keys: bare top-row keys emit XF86* keysyms (ThinkPad/Dell media
	 * layer). Fn+key emits plain F1-F12, left unbound so F-keys keep their
	 * normal function and media actions stay consistent with the bare keys. */
	{ 0,                            XF86XK_AudioLowerVolume, spawn, {.v = (const char*[]){"/usr/local/bin/volume_down.sh", NULL} } },
	{ 0,                            XF86XK_AudioRaiseVolume, spawn, {.v = (const char*[]){"/usr/local/bin/volume_up.sh", NULL} } },
	{ 0,                            XF86XK_AudioMute,        spawn, {.v = (const char*[]){"/usr/local/bin/volume_mute.sh", NULL} } },
	{ 0,                            XF86XK_MonBrightnessDown, spawn, {.v = (const char*[]){"/usr/local/bin/brightness_down.sh", NULL} } },
	{ 0,                            XF86XK_MonBrightnessUp, spawn, {.v = (const char*[]){"/usr/local/bin/brightness_up.sh", NULL} } },
	{ 0,                            XF86XK_KbdBrightnessDown, spawn, {.v = (const char*[]){"/usr/local/bin/kbd_backlight_down.sh", NULL} } },
	{ 0,                            XF86XK_KbdBrightnessUp, spawn, {.v = (const char*[]){"/usr/local/bin/kbd_backlight_up.sh", NULL} } },
};

/* button definitions */
/* click can be ClkTagBar, ClkLtSymbol, ClkStatusText, ClkWinTitle, ClkClientWin, or ClkRootWin */
static const Button buttons[] = {
	/* click                event mask      button          function        argument */
	{ ClkLtSymbol,          0,              Button1,        setlayout,      {0} },
	{ ClkLtSymbol,          0,              Button3,        setlayout,      {.v = &layouts[0]} },
	{ ClkWinTitle,          0,              Button2,        zoom,           {0} },
	{ ClkStatusText,        0,              Button2,        spawn,          {.v = termcmd } },
	{ ClkClientWin,         MODKEY,         Button1,        movemouse,      {0} },
	{ ClkClientWin,         MODKEY,         Button2,        togglefloating, {0} },
	{ ClkClientWin,         MODKEY,         Button3,        resizemouse,    {0} },
	{ ClkTagBar,            0,              Button1,        view,           {0} },
	{ ClkTagBar,            0,              Button3,        toggleview,     {0} },
	{ ClkTagBar,            MODKEY,         Button1,        tag,            {0} },
	{ ClkTagBar,            MODKEY,         Button3,        toggletag,      {0} },
};
