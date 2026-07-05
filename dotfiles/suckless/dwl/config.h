/* See LICENSE file for copyright and license details.
 *
 * dwl config.h — ported 1:1 from the project's dwm config.h
 * All keybindings, colors, tags, layouts, and rules match exactly.
 */

#define COLOR(hex)    { ((hex >> 24) & 0xFF) / 255.0f, \
                        ((hex >> 16) & 0xFF) / 255.0f, \
                        ((hex >> 8) & 0xFF) / 255.0f, \
                        (hex & 0xFF) / 255.0f }

/* appearance */
static const int sloppyfocus               = 0;  /* dwm-style click-to-focus */
static const int bypass_surface_visibility = 0;
static const unsigned int borderpx         = 1;
static const float rootcolor[]             = COLOR(0x000000ff);   /* #000000 */
static const float bordercolor[]           = COLOR(0x444444ff);   /* #444444 */
static const float focuscolor[]            = COLOR(0x000000ff);   /* #000000 — dwm SchemeSel border */
static const float urgentcolor[]           = COLOR(0x005577ff);   /* #005577 — col_cyan */
static const float fullscreen_bg[]         = {0.0f, 0.0f, 0.0f, 1.0f};

/* tagging — TAGCOUNT must be no greater than 31 */
#define TAGCOUNT (9)

/* logging */
static int log_level = WLR_ERROR;

static const Rule rules[] = {
	/* app_id     title       tags mask     isfloating   monitor */
	{ "Gimp",     NULL,       0,            1,           -1 },
	{ "Firefox",  NULL,       1 << 8,       0,           -1 },
};

/* layout(s) */
static const Layout layouts[] = {
	/* symbol     arrange function */
	{ "[M]",      monocle },  /* first entry is default */
	{ "[]=",      tile },
	{ "><>",      NULL },    /* no layout function means floating behavior */
};

/* monitors */
static const MonitorRule monrules[] = {
	/* name       mfact  nmaster scale layout       rotate/reflect                x    y */
	{ NULL,       0.55f, 1,      1,    &layouts[0], WL_OUTPUT_TRANSFORM_NORMAL,   -1,  -1 },
};

/* keyboard */
static const struct xkb_rule_names xkb_rules = {
.options = "caps:super",
};

static const int repeat_rate = 25;
static const int repeat_delay = 600;

/* Trackpad */
static const int tap_to_click = 0;
static const int tap_and_drag = 0;
static const int drag_lock = 1;
static const int natural_scrolling = 0;
static const int disable_while_typing = 1;
static const int left_handed = 0;
static const int middle_button_emulation = 0;
static const enum libinput_config_scroll_method scroll_method = LIBINPUT_CONFIG_SCROLL_2FG;
static const enum libinput_config_click_method click_method = LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
static const uint32_t send_events_mode = LIBINPUT_CONFIG_SEND_EVENTS_ENABLED;
static const enum libinput_config_accel_profile accel_profile = LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
static const double accel_speed = 0.0;
static const enum libinput_config_tap_button_map button_map = LIBINPUT_CONFIG_TAP_MAP_LRM;

/* key definitions */
#define MODKEY WLR_MODIFIER_LOGO
#define TAGKEYS(KEY,SKEY,TAG) \
	{ MODKEY,                    KEY,            view,            {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL,  KEY,            toggleview,      {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_SHIFT, SKEY,           tag,             {.ui = 1 << TAG} }, \
	{ MODKEY|WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT,SKEY,toggletag, {.ui = 1 << TAG} }

/* helper for spawning shell commands */
#define SHCMD(cmd) { .v = (const char*[]){ "/bin/sh", "-c", cmd, NULL } }

/* commands */
static const char *termcmd[]    = { "foot", NULL };
static const char *menucmd[]    = { "bemenu-run", NULL };
static const char *tabnewcmd[]  = { "foot", NULL };
static const char *surfnewcmd[] = { "/usr/local/bin/w", NULL };

static const Key keys[] = {
	/* modifier                     key                 function        argument */
	{ MODKEY,                       XKB_KEY_r,          spawn,          {.v = menucmd } },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_Return,     spawn,          {.v = termcmd } },
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT, XKB_KEY_t, spawn,          {.v = tabnewcmd } },
	{ WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT, XKB_KEY_b, spawn,          {.v = surfnewcmd } },
	{ MODKEY,                       XKB_KEY_Down,       focusstack,     {.i = +1 } },
	{ MODKEY,                       XKB_KEY_Up,         focusstack,     {.i = -1 } },
	{ MODKEY,                       XKB_KEY_bracketright,setmfact,      {.f = +0.05f} },
	{ MODKEY,                       XKB_KEY_Escape,      spawn,          SHCMD("/usr/local/bin/lock-screen.sh") },
	{ MODKEY,                       XKB_KEY_t,           setlayout,      {.v = &layouts[1]} }, /* tile */
	{ MODKEY,                       XKB_KEY_f,           setlayout,      {.v = &layouts[2]} }, /* floating */
	{ MODKEY,                       XKB_KEY_m,           setlayout,      {.v = &layouts[0]} }, /* monocle */
	{ MODKEY,                       XKB_KEY_0,           view,           {.ui = ~0 } },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_parenright,  tag,            {.ui = ~0 } },
	{ MODKEY,                       XKB_KEY_comma,       focusmon,       {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY,                       XKB_KEY_period,      focusmon,       {.i = WLR_DIRECTION_RIGHT} },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_less,        tagmon,         {.i = WLR_DIRECTION_LEFT} },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_greater,     tagmon,         {.i = WLR_DIRECTION_RIGHT} },
	TAGKEYS(                        XKB_KEY_1, XKB_KEY_exclam,            0),
	TAGKEYS(                        XKB_KEY_2, XKB_KEY_at,                1),
	TAGKEYS(                        XKB_KEY_3, XKB_KEY_numbersign,        2),
	TAGKEYS(                        XKB_KEY_4, XKB_KEY_dollar,            3),
	TAGKEYS(                        XKB_KEY_5, XKB_KEY_percent,           4),
	TAGKEYS(                        XKB_KEY_6, XKB_KEY_asciicircum,       5),
	TAGKEYS(                        XKB_KEY_7, XKB_KEY_ampersand,         6),
	TAGKEYS(                        XKB_KEY_8, XKB_KEY_asterisk,          7),
	TAGKEYS(                        XKB_KEY_9, XKB_KEY_parenleft,         8),
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_Left,       tagprev,        {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_Right,      tagnext,        {0} },
	{ MODKEY,                       XKB_KEY_Left,       viewprev,       {0} },
	{ MODKEY,                       XKB_KEY_Right,      viewnext,       {0} },
	{ MODKEY,                       XKB_KEY_a,          viewprev,       {0} },
	{ MODKEY,                       XKB_KEY_d,          viewnext,       {0} },
	{ MODKEY,                       XKB_KEY_w,          focusstack,     {.i = -1 } },
	{ MODKEY,                       XKB_KEY_s,          focusstack,     {.i = +1 } },
	{ MODKEY|WLR_MODIFIER_CTRL|WLR_MODIFIER_SHIFT, XKB_KEY_q, quit,    {0} },
	{ MODKEY|WLR_MODIFIER_SHIFT,    XKB_KEY_z,          killclient,     {0} },
	{ 0,                            XKB_KEY_XF86AudioLowerVolume,  spawn, {.v = (const char*[]){"/usr/local/bin/volume_down.sh", NULL} } },
	{ 0,                            XKB_KEY_XF86AudioRaiseVolume,  spawn, {.v = (const char*[]){"/usr/local/bin/volume_up.sh", NULL} } },
	{ 0,                            XKB_KEY_XF86AudioMute,         spawn, {.v = (const char*[]){"/usr/local/bin/volume_mute.sh", NULL} } },
	{ 0,                            XKB_KEY_XF86MonBrightnessDown, spawn, {.v = (const char*[]){"/usr/local/bin/brightness_down.sh", NULL} } },
	{ 0,                            XKB_KEY_XF86MonBrightnessUp,   spawn, {.v = (const char*[]){"/usr/local/bin/brightness_up.sh", NULL} } },
	{ WLR_MODIFIER_SHIFT,           XKB_KEY_XF86MonBrightnessDown, spawn, {.v = (const char*[]){"/usr/local/bin/kbd_backlight_down.sh", NULL} } },
	{ WLR_MODIFIER_SHIFT,           XKB_KEY_XF86MonBrightnessUp,   spawn, {.v = (const char*[]){"/usr/local/bin/kbd_backlight_up.sh", NULL} } },
};

static const Button buttons[] = {
	{ MODKEY, BTN_LEFT,   moveresize,     {.ui = CurMove} },
	{ MODKEY, BTN_MIDDLE, togglefloating, {0} },
	{ MODKEY, BTN_RIGHT,  moveresize,     {.ui = CurResize} },
};
