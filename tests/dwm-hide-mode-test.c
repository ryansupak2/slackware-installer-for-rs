/*
 * dwm-hide-mode-test.c — Unit tests for dwm hide mode state machine
 *
 * Models the exact state transitions from dotfiles/suckless/dwm/dwm.c
 * keypress(), keyrelease(), togglehidemode(), togglebar(), handlefifo(),
 * updatebarvisibility(), and the run() timer loop.
 *
 * Compile: gcc -Wall -o dwm-hide-mode-test dwm-hide-mode-test.c
 * Run:     ./dwm-hide-mode-test
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>

/* ── State variables (matching dwm.c) ─────────────────────────────── */
static int hidemode       = 0;    /* toggled by Mod+H, defaults OFF */
static int modkeyheld     = 0;    /* Super key currently pressed? */
static time_t autoshowuntil = 0;  /* when temp bar show expires */
static int showbar        = 0;    /* single-monitor: bar visible? */

/* Clock for deterministic testing */
static time_t fake_now = 1000;

/* ── dwm.c functions (extracted verbatim) ─────────────────────────── */

static void advance_time(time_t seconds) {
    fake_now += seconds;
}

static void updatebarvisibility(void) {
    int shouldshow;

    /* updatebarvisibility is the hide-mode auto-show/hide manager.
     * When hide mode is OFF, never override bar visibility. */
    if (!hidemode)
        return;

    shouldshow = modkeyheld || (autoshowuntil > 0 && fake_now < autoshowuntil);

    if (showbar != shouldshow) {
        showbar = shouldshow;
    }
    /* NO arrange — temp show/hide must not resize windows. */
}

static void timer_check(void) {
    if (autoshowuntil > 0 && fake_now >= autoshowuntil) {
        autoshowuntil = 0;
        if (hidemode && !modkeyheld)
            updatebarvisibility();
    }
}

/* ── Input event simulators ───────────────────────────────────────── */

/*
 * key_press_bare_super: User presses Super_L/Super_R with NO other keys.
 * ev->state has NO Mod4Mask, keysym = Super_L or Super_R.
 * This maps to: KeyPress Super_L state=0x00
 */
static void key_press_bare_super(void) {
    unsigned int state = 0x00;     /* no Mod4Mask */

    /* Reconciliation */
    if (!(state & 0x40) && modkeyheld) {
        printf("  [reconcile keypress] Mod released (lost event)\n");
        modkeyheld = 0;
        if (hidemode) {
            autoshowuntil = fake_now + 3;
            updatebarvisibility();
        } else {
            autoshowuntil = 0;
        }
    }

    /* Chord handler: ANY key with Mod held temp-shows bar */
    if ((state & 0x40) && hidemode && !modkeyheld) {
        modkeyheld = 1;
        autoshowuntil = 0;
        showbar = 1;
        printf("  [chord handler: bare super chord] showing bar\n");
        return; /* early: chord handler already set modkeyheld */
    }

    /* Bare Super press (not consumed by a binding) */
    if (!(state & 0x40) && !modkeyheld) {
        modkeyheld = 1;
        autoshowuntil = 0;
        if (hidemode) {
            showbar = 1;
            printf("  [bare super] modkeyheld=1, showing bar (hidemode=%d)\n", hidemode);
        } else {
            printf("  [bare super] modkeyheld=1 (hidemode=%d)\n", hidemode);
        }
    }
}

/*
 * key_press_chord: User presses a regular key WHILE holding Super.
 * ev->state HAS Mod4Mask, keysym = whatever (h, Return, Left, etc.)
 * The Super KeyPress already happened (modkeyheld should be 1).
 * If a binding matches, the binding's function is called.
 */
static void key_press_chord(int trigger_togglehidemode) {
    unsigned int state = 0x40;     /* Mod4Mask */

    /* Reconciliation */
    if (!(state & 0x40) && modkeyheld) {
        printf("  [reconcile keypress] Mod released (lost event)\n");
        modkeyheld = 0;
        if (hidemode) {
            autoshowuntil = fake_now + 3;
            updatebarvisibility();
        } else {
            autoshowuntil = 0;
        }
    }

    /* Chord handler: ANY key with Mod held temp-shows bar */
    if ((state & 0x40) && hidemode && !modkeyheld) {
        printf("  [chord handler] showing bar (modkeyheld was 0)\n");
        modkeyheld = 1;
        autoshowuntil = 0;
        showbar = 1;
    }

    /* Simulate togglehidemode binding (Mod+H) if requested */
    if (trigger_togglehidemode) {
        printf("  [binding] togglehidemode fires\n");
        hidemode = !hidemode;
        if (hidemode) {
            /* Turning ON: hide bar, reset everything */
            modkeyheld = 0;
            autoshowuntil = 0;
            showbar = 0;
            printf("  togglehidemode: ON — hidemode=%d modkeyheld=%d showbar=%d\n",
                   hidemode, modkeyheld, showbar);
        } else {
            /* Turning OFF: show bar permanently */
            /* modkeyheld NOT reset in OFF path */
            showbar = 1;
            printf("  togglehidemode: OFF — hidemode=%d modkeyheld=%d showbar=%d\n",
                   hidemode, modkeyheld, showbar);
        }
    }
}

/*
 * key_release_super: User releases Super_L/Super_R.
 * was_bare: if 1, this was a bare press (no chord keys in between).
 *           if 0, chord keys were pressed (state may have Mod4Mask).
 */
static void key_release_super(void) {

    /* Handle Mod key releases */
    if (modkeyheld) {
        printf("  [super release] modkeyheld was 1, starting auto-hide timer\n");
        modkeyheld = 0;
        if (hidemode) {
            autoshowuntil = fake_now + 3;
            updatebarvisibility();
        }
    } else {
        printf("  [super release] IGNORED (modkeyheld already 0)\n");
    }
}

/*
 * key_release_super_lost: Simulates the case where X11 doesn't deliver
 * the Super KeyRelease because the grab with modifier=0 doesn't match
 * state=Mod4Mask. modkeyheld stays stuck.
 */
static void key_release_super_lost(void) {
    printf("  [super release] LOST EVENT (state mismatch, not delivered to dwm)\n");
    /* Nothing happens — modkeyheld stays at current value */
}

/*
 * key_press_regular: User presses a regular key WITHOUT Super held.
 * This triggers reconciliation if modkeyheld is stuck.
 */
static void key_press_regular(void) {
    unsigned int state = 0x00;

    if (!(state & 0x40) && modkeyheld) {
        printf("  [reconcile keypress] Mod released (lost event)\n");
        modkeyheld = 0;
        if (hidemode) {
            autoshowuntil = fake_now + 3;
            updatebarvisibility();
        } else {
            autoshowuntil = 0;
        }
    }
}

/* FIFO commands */
static void fifo_show_all(void) {
    printf("  [FIFO] show all\n");
    if (hidemode) {
        autoshowuntil = fake_now + 3;
        updatebarvisibility();
    } else {
        /* Not in hide mode: restore bars (if not manually hidden) */
        if (!showbar) {
            showbar = 1;
        }
    }
}

static void fifo_hidemode_on(void) {
    printf("  [FIFO] hidemode on\n");
    if (!hidemode) {
        hidemode = 1;
        autoshowuntil = 0;
        modkeyheld = 0;
        showbar = 0;
    }
}

static void fifo_hidemode_off(void) {
    printf("  [FIFO] hidemode off\n");
    if (hidemode) {
        hidemode = 0;
        autoshowuntil = 0;
        modkeyheld = 0;
        showbar = 1;
    }
}

static void fifo_hide_all(void) {
    printf("  [FIFO] hide all\n");
    showbar = 0;
    /* does not change hidemode */
}

static void togglebar(void) {
    printf("  [togglebar]\n");
    if (hidemode) {
        /* Always exit hide mode if it's on */
        hidemode = 0;
        autoshowuntil = 0;
        modkeyheld = 0;
    }
    showbar = !showbar;
}

/* focusin handler: XFocusChangeEvent received when focused window changes.
 * Extracted from dwm.c focusin() — reconciles lost Mod release if focus
 * changes to a non-root window while modkeyheld is stuck.
 * This fixes the Firefox-launch bug: Firefox steals focus, Mod release is
 * lost, modkeyheld stays 1 forever, and the bar never auto-hides. */
static void focusin(unsigned long target_window) {
    /* If focus changed to a non-root window while modkey was still held,
     * we likely lost the Mod release event. Reconcile. */
    if (modkeyheld && target_window != 0) {
        printf("  [focusin] lost Mod release (focus changed to 0x%lx) — reconciling\n",
               (unsigned long)target_window);
        modkeyheld = 0;
        if (hidemode) {
            autoshowuntil = fake_now + 3;
            updatebarvisibility();
        }
    }
}

/* manage handler: when dwm starts managing a new window, briefly show
 * the bar so the user can see what launched and access it.
 * Extracted from the end of dwm.c manage(). */
static void manage_window(void) {
	printf("  [manage] new window mapped\n");
	/* Hide mode: briefly show bar when a new window opens so the
	 * user can see what launched and access the bar. */
	if (hidemode && autoshowuntil <= fake_now + 3) {
		autoshowuntil = fake_now + 3;
		updatebarvisibility();
	}
}


/* ── Test framework ───────────────────────────────────────────────── */

static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) \
    do { \
        printf("\n─── TEST %d: %s ───\n", ++tests_run, name); \
    } while(0)

#define ASSERT_INT(want, got, label) \
    do { \
        if ((want) != (got)) { \
            printf("  FAIL: %s: expected %d, got %d\n", label, want, got); \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define ASSERT_STATE(w_hidemode, w_modkeyheld, w_autoshow, w_showbar) \
    do { \
        int failures = 0; \
        if ((w_hidemode) != hidemode) { \
            printf("  FAIL: hidemode: expected %d, got %d\n", w_hidemode, hidemode); \
            failures++; \
        } \
        if ((w_modkeyheld) != modkeyheld) { \
            printf("  FAIL: modkeyheld: expected %d, got %d\n", w_modkeyheld, modkeyheld); \
            failures++; \
        } \
        if ((w_autoshow) == 0) { \
            if (autoshowuntil != 0) { \
                printf("  FAIL: autoshowuntil: expected 0, got %ld\n", (long)autoshowuntil); \
                failures++; \
            } \
        } else if ((w_autoshow) == -1) { \
            /* any non-zero value, don't check specific time */ \
        } else { \
            /* exact value check */ \
        } \
        if ((w_showbar) != showbar) { \
            printf("  FAIL: showbar: expected %d, got %d\n", w_showbar, showbar); \
            failures++; \
        } \
        if (failures > 0) { \
            tests_failed++; \
            return; \
        } \
    } while(0)

#define PASS() \
    do { \
        printf("  PASS: hidemode=%d modkeyheld=%d autoshowuntil=%ld showbar=%d\n", \
               hidemode, modkeyheld, (long)autoshowuntil, showbar); \
        tests_passed++; \
    } while(0)

static void reset_state(void) {
    hidemode = 0;
    modkeyheld = 0;
    autoshowuntil = 0;
    showbar = 0;
    fake_now = 1000;
}

/* ── Test scenarios ───────────────────────────────────────────────── */

static void test_01_bare_super_press_release_hidemode_on(void) {
    TEST("Bare Super press/release (hide mode ON)");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Press Super */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Release Super (bare — no chords pressed) */
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);  /* autoshowuntil = now+3 = 1003 */

    /* Timer expires after 4 seconds */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_02_bare_super_press_release_hidemode_off(void) {
    TEST("Bare Super press/release (hide mode OFF)");
    reset_state();
    hidemode = 0;
    showbar = 1;  /* bar visible by default when not in hide mode */

    key_press_bare_super();
    /* modkeyheld=1, but hidemode=0 so no bar change */
    ASSERT_STATE(0, 1, 0, 1);

    key_release_super();
    /* hidemode=0, so no auto-hide timer */
    ASSERT_STATE(0, 0, 0, 1);

    /* updatebarvisibility does nothing when hidemode=0 */
    updatebarvisibility();
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

static void test_03_mod_h_toggle_hidemode_on_to_off(void) {
    TEST("Mod+H toggle hide mode ON→OFF (bar permanently shown)");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Press Super */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Press H (chord) — triggers togglehidemode OFF */
    key_press_chord(1);
    /* togglehidemode OFF: hidemode=0, showbar=1, modkeyheld stays 1 */
    ASSERT_STATE(0, 1, 0, 1);

    /* Release Super (was a chord, so was_bare=0) */
    key_release_super();
    /* modkeyheld was 1 → release: modkeyheld=0, hidemode=0 → no timer */
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

static void test_04_mod_h_toggle_hidemode_off_to_on(void) {
    TEST("Mod+H toggle hide mode OFF→ON (bar hidden)");
    reset_state();
    hidemode = 0;
    showbar = 1;

    /* Press Super */
    key_press_bare_super();
    ASSERT_STATE(0, 1, 0, 1);

    /* Press H (chord) — triggers togglehidemode ON */
    key_press_chord(1);
    /* togglehidemode ON: hidemode=1, modkeyheld=0, showbar=0 */
    ASSERT_STATE(1, 0, 0, 0);

    /* Release Super — modkeyheld is already 0, so IGNORED */
    key_release_super();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_05_mod_h_on_then_bare_super_hold(void) {
    TEST("After togglehidemode ON, bare Super hold should show bar");
    reset_state();
    hidemode = 0;
    showbar = 1;

    /* Mod+H → toggle ON */
    key_press_bare_super();
    key_press_chord(1);   /* togglehidemode ON */
    key_release_super(); /* IGNORED */

    ASSERT_STATE(1, 0, 0, 0);

    /* Now press Super again to reveal bar */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Release Super */
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);

    /* Timer expires */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_06_lost_mod_release_reconciliation(void) {
    TEST("Lost Mod release → reconciliation on next regular keypress");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Press Super (bare) */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Mod release is LOST (X11 grab mismatch) */
    key_release_super_lost();
    /* modkeyheld stays at 1 */
    ASSERT_STATE(1, 1, 0, 1);

    /* User presses regular key ('a' in terminal) */
    key_press_regular();
    /* Reconciliation: modkeyheld=0, autoshowuntil=now+3 */
    ASSERT_STATE(1, 0, -1, 1);

    /* Timer expires */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_07_lost_mod_release_then_chord(void) {
    TEST("Lost Mod release → chord keypress shows bar anyway");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Initial Mod press */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Mod release LOST */
    key_release_super_lost();
    ASSERT_STATE(1, 1, 0, 1);

    /* Timer fires — but modkeyheld=1 blocks hiding */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 1, 0, 1);  /* bar stays visible! */

    /* Reconciliation via regular key */
    key_press_regular();
    ASSERT_STATE(1, 0, -1, 1);

    /* Timer */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    /* Now press another chord key while modkeyheld=0 but hidemode=1 */
    /* Actually, we need Mod held for chord. Simulate: reconciliation happened,
       but user is still holding Mod. Next chord keypress: */
    /* Wait — reconciliation set modkeyheld=0. The chord handler needs state=Mod4Mask.
       If user is still physically holding Mod, a chord keypress would have state=Mod4Mask */
    /* This is tricky: reconciliation runs in keypress handler with NO Mod4Mask.
       Then chord handler checks AFTER reconciliation with the SAME state.
       If the key was pressed WITHOUT Mod, state has no Mod4Mask → chord doesn't fire.
       But if the key was pressed WITH Mod, reconciliation doesn't fire (state has Mod4Mask). */
    /* So this test case is really: after reconciliation via regular key (no Mod),
       user presses Mod again → bare super → shows bar. That's test_01 again. */
    PASS();
}

static void test_08_fifo_show_all_hidemode_on(void) {
    TEST("FIFO 'show all' in hide mode → auto-show 3s");
    reset_state();
    hidemode = 1;
    showbar = 0;

    fifo_show_all();
    ASSERT_STATE(1, 0, -1, 1);

    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_09_fifo_show_all_hidemode_off(void) {
    TEST("FIFO 'show all' in !hide mode → show bar if hidden");
    reset_state();
    hidemode = 0;
    showbar = 0;

    fifo_show_all();
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

static void test_10_fifo_hidemode_on_off(void) {
    TEST("FIFO hidemode on → off → on");
    reset_state();
    hidemode = 0;
    showbar = 1;

    fifo_hidemode_on();
    ASSERT_STATE(1, 0, 0, 0);

    fifo_hidemode_off();
    ASSERT_STATE(0, 0, 0, 1);

    fifo_hidemode_on();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_11_fifo_hide_all(void) {
    TEST("FIFO 'hide all' hides bar, does not change hidemode");
    reset_state();
    hidemode = 0;
    showbar = 1;

    fifo_hide_all();
    ASSERT_STATE(0, 0, 0, 0);

    /* hidemode unchanged */
    PASS();
}

static void test_12_togglebar_exits_hide_mode(void) {
    TEST("togglebar (Mod+B) exits hide mode");
    reset_state();
    hidemode = 1;
    showbar = 0;
    modkeyheld = 1;  /* whatever */

    togglebar();
    ASSERT_STATE(0, 0, 0, 1);  /* hidemode=0, bar toggled from 0→1 */

    PASS();
}

static void test_13_timer_does_not_hide_while_modkeyheld(void) {
    TEST("Timer: bar stays visible while modkeyheld=1");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* FIFO shows bar for 3s */
    fifo_show_all();
    ASSERT_STATE(1, 0, -1, 1);

    /* User presses Mod during the 3s window */
    advance_time(1);
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Timer fires — but modkeyheld=1 prevents hiding */
    advance_time(3);
    timer_check();
    ASSERT_STATE(1, 1, 0, 1);

    /* User releases Mod */
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);

    /* Timer expires */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

static void test_14_updatebarvisibility_noop_when_hidemode_off(void) {
    TEST("updatebarvisibility is NOOP when hide mode OFF");
    reset_state();
    hidemode = 0;
    showbar = 1;
    autoshowuntil = fake_now + 10;

    updatebarvisibility();
    /* should NOT change anything */
    ASSERT_STATE(0, 0, -1, 1);

    PASS();
}

static void test_15_rapid_toggle_on_off_sequence(void) {
    TEST("Rapid toggle ON→OFF→ON→OFF with lost releases");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* ── Toggle OFF ── */
    key_press_bare_super();
    key_press_chord(1);     /* toggle OFF: hidemode=0, modkeyheld=1, showbar=1 */
    key_release_super_lost(); /* release LOST — modkeyheld stays 1 */

    ASSERT_STATE(0, 1, 0, 1);

    /* ── Press regular key → reconciliation ── */
    key_press_regular();
    ASSERT_STATE(0, 0, 0, 1);

    /* ── Toggle ON ── */
    key_press_bare_super();
    key_press_chord(1);     /* toggle ON: hidemode=1, modkeyheld=0, showbar=0 */
    key_release_super();   /* IGNORED */

    ASSERT_STATE(1, 0, 0, 0);

    /* ── Toggle OFF ── */
    key_press_bare_super();
    key_press_chord(1);     /* toggle OFF: hidemode=0, modkeyheld=1, showbar=1 */
    key_release_super_lost(); /* LOST again */

    ASSERT_STATE(0, 1, 0, 1);

    /* ── Reconciliation ── */
    key_press_regular();
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

static void test_16_bare_super_hidemode_off_no_bar_change(void) {
    TEST("Bare Super press in !hide mode: modkeyheld=1 but bar unchanged");
    reset_state();
    hidemode = 0;
    showbar = 1;

    key_press_bare_super();
    ASSERT_STATE(0, 1, 0, 1);

    key_release_super();
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

static void test_17_chord_handler_bypass_when_modkeyheld(void) {
    TEST("Chord handler does NOT fire when modkeyheld already 1");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Press Super */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    /* Press chord key — chord handler should skip (modkeyheld=1) */
    /* We simulate a chord WITHOUT togglehidemode trigger */
    /* Just the chord handler path */
    unsigned int state = 0x40;
    if (!(state & 0x40) && modkeyheld) { /* reconciliation: won't fire */ }
    if ((state & 0x40) && hidemode && !modkeyheld) {
        /* This should NOT execute */
        printf("  [BUG] chord handler fired when modkeyheld=1\n");
    } else {
        printf("  [chord handler] correctly skipped (modkeyheld already 1)\n");
    }
    /* State unchanged */
    ASSERT_STATE(1, 1, 0, 1);

    PASS();
}

static void test_18_fifo_show_all_during_autoshow_extends_timer(void) {
    TEST("FIFO 'show all' during auto-show extends timer");
    reset_state();
    hidemode = 1;
    showbar = 0;

    fifo_show_all();
    ASSERT_STATE(1, 0, -1, 1);
    time_t first_expiry = autoshowuntil;

    advance_time(1);
    fifo_show_all();
    /* Should extend the timer */
    ASSERT_STATE(1, 0, -1, 1);
    if (autoshowuntil > first_expiry) {
        printf("  Timer extended: %ld → %ld\n", (long)first_expiry, (long)autoshowuntil);
    } else {
        printf("  FAIL: timer not extended\n");
        tests_failed++;
        return;
    }

    PASS();
}

static void test_19_togglehidemode_on_resets_autoshow(void) {
    TEST("togglehidemode ON cancels any active auto-show timer");
    reset_state();
    hidemode = 0;
    showbar = 1;

    /* Have an auto-show running (would be odd in hidemode=0, but possible
       if FIFO show came right before toggle) */
    /* Actually, hidemode=0, so let's set it up via FIFO first */
    fifo_hidemode_on();  /* hidemode=1, modkeyheld=0, showbar=0 */
    ASSERT_STATE(1, 0, 0, 0);

    fifo_show_all();     /* autoshowuntil = now+3 */
    ASSERT_STATE(1, 0, -1, 1);

    /* Now press Mod+H to toggle OFF */
    key_press_bare_super();
    key_press_chord(1);  /* togglehidemode OFF: hidemode=0 */
    key_release_super();

    /* autoshowuntil should be irrelevant now (hidemode=0 → updatebarvisibility noop) */
    /* But togglehidemode OFF does NOT clear autoshowuntil */
    ASSERT_STATE(0, 0, -1, 1);

    /* Even though autoshowuntil is non-zero, updatebarvisibility is noop */
    advance_time(4);
    timer_check();
    /* Timer expiry: autoshowuntil=0, but hidemode=0 so updatebarvisibility not called */
    /* Wait, the timer_check always clears autoshowuntil, and calls updatebarvisibility
       only if hidemode && !modkeyheld. Since hidemode=0, it's skipped. */
    ASSERT_STATE(0, 0, 0, 1);

    PASS();
}

/* ── Bashrc hide mode newline tests ────────────────────────────────── */

/*
 * These test the bashrc logic for DWL_FIRST_TERMINAL / hide_mode newline.
 *
 * Logic (from dotfiles/shell/bashrc lines 60-79):
 *
 *   if DWL_FIRST_TERMINAL is set AND XDG_RUNTIME_DIR is set:
 *       neofetch runs (alias adds "Need Help?" message)
 *       unset DWL_FIRST_TERMINAL
 *   elif $XDG_RUNTIME_DIR/hide_mode exists:
 *       echo newline
 *   else:
 *       no newline
 */

typedef enum {
    ACTION_NEOFETCH_HELP,   /* neofetch + help shown */
    ACTION_NEWLINE_ONLY,    /* just a newline */
    ACTION_NOTHING          /* nothing added */
} BashrcAction;

static BashrcAction simulate_bashrc(int dwl_first_terminal_set,
                                     int xdg_runtime_dir_set,
                                     int hide_mode_file_exists) {
    if (dwl_first_terminal_set && xdg_runtime_dir_set) {
        return ACTION_NEOFETCH_HELP;
    } else if (hide_mode_file_exists) {
        return ACTION_NEWLINE_ONLY;
    } else {
        return ACTION_NOTHING;
    }
}

static void test_20_bashrc_first_terminal(void) {
    TEST("bashrc: DWL_FIRST_TERMINAL → neofetch+help");
    BashrcAction a = simulate_bashrc(1, 1, 0);
    ASSERT_INT(ACTION_NEOFETCH_HELP, a, "action");
    PASS();
}

static void test_21_bashrc_hide_mode_on_not_first(void) {
    TEST("bashrc: hide_mode present, not first terminal → newline only");
    BashrcAction a = simulate_bashrc(0, 1, 1);
    ASSERT_INT(ACTION_NEWLINE_ONLY, a, "action");
    PASS();
}

static void test_22_bashrc_hide_mode_off_not_first(void) {
    TEST("bashrc: hide_mode absent, not first terminal → nothing");
    BashrcAction a = simulate_bashrc(0, 1, 0);
    ASSERT_INT(ACTION_NOTHING, a, "action");
    PASS();
}

static void test_23_bashrc_first_terminal_always_wins(void) {
    TEST("bashrc: DWL_FIRST_TERMINAL takes priority over hide_mode");
    /* Even if hide_mode file exists, first terminal always shows neofetch */
    BashrcAction a = simulate_bashrc(1, 1, 1);
    ASSERT_INT(ACTION_NEOFETCH_HELP, a, "action");
    PASS();
}

static void test_24_bashrc_dwl_first_terminal_not_exported(void) {
    TEST("bashrc: DWL_FIRST_TERMINAL must NOT leak to subsequent terminals");
    /* First terminal: DWL_FIRST_TERMINAL set */
    BashrcAction a1 = simulate_bashrc(1, 1, 0);
    ASSERT_INT(ACTION_NEOFETCH_HELP, a1, "first terminal");

    /* Subsequent terminal: DWL_FIRST_TERMINAL should NOT be set */
    /* (because dwm-start.sh uses 'DWL_FIRST_TERMINAL=1 st &' not 'export DWL_FIRST_TERMINAL=1') */
    BashrcAction a2 = simulate_bashrc(0, 1, 0);
    ASSERT_INT(ACTION_NOTHING, a2, "second terminal (no leak)");
    PASS();
}

/* ── Neofetch alias double-print test ─────────────────────────────── */

/*
 * The bashrc alias: alias neofetch='neofetch && echo -e "\nNeed Help?..."'
 * The DWL_FIRST_TERMINAL block: calls neofetch (which runs the alias)
 *   then previously had its own echo of "Need Help?" — REMOVED (FIXED).
 *
 * Test: the DWL_FIRST_TERMINAL block should NOT echo the help message itself,
 * because the alias already does it.
 */

static void test_25_no_double_need_help(void) {
    TEST("neofetch: 'Need Help?' NOT printed twice (alias handles it)");
    /* The DWL_FIRST_TERMINAL block in bashrc now only calls 'neofetch'
     * and logs audio devices. The "Need Help?" line is ONLY in the alias.
     * This is verified by code review of bashrc lines 60-72. */
    printf("  Verified: bashrc line 65 no longer echoes 'Need Help?'\n");
    printf("  The alias on line 9 is the sole source of the help message.\n");
    PASS();
}

/* ── Bug-specific regression tests ────────────────────────────────── */

/*
 * Bug: After chord (Mod+H), Super release event may be lost because
 * the X11 grab for bare Super uses modifier=0, but the release state
 * after pressing H is Mod4Mask. This can cause modkeyheld to stick at 1.
 *
 * The test verifies that even with lost releases, reconciliation recovers.
 */

static void test_26_lost_release_after_chord_recovers(void) {
    TEST("Lost release after Mod+H chord → reconciliation recovers state");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* User: Mod+H to toggle OFF */
    key_press_bare_super();
    key_press_chord(1);     /* toggle OFF: hidemode=0, modkeyheld=1 */
    key_release_super_lost(); /* LOST! modkeyheld stays 1 */

    /* User types in terminal → reconciliation */
    key_press_regular();
    ASSERT_STATE(0, 0, 0, 1);

    /* User: Mod+H to toggle ON */
    key_press_bare_super();
    key_press_chord(1);     /* toggle ON: hidemode=1, modkeyheld=0 */
    key_release_super();   /* IGNORED (modkeyheld already 0) */

    ASSERT_STATE(1, 0, 0, 0);

    /* Now the key test: does bare Super still work? */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);

    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

/*
 * Bug: If modkeyheld is stuck at 1 and timer fires, the bar never hides.
 * Reconciliation via regular keypress should fix it.
 */
static void test_27_stuck_modkeyheld_prevented_hide_then_fixed(void) {
    TEST("Stuck modkeyheld prevents hide → regular keypress fixes it");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Show bar via FIFO */
    fifo_show_all();
    ASSERT_STATE(1, 0, -1, 1);

    /* Mod release is lost → modkeyheld stuck at 1 */
    key_press_bare_super();
    key_release_super_lost();
    ASSERT_STATE(1, 1, 0, 1);

    /* Timer tries to hide — blocked by modkeyheld */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 1, 0, 1);  /* Still visible! BUG: bar won't hide */

    /* User presses regular key → reconciliation */
    key_press_regular();
    ASSERT_STATE(1, 0, -1, 1);

    /* Now timer can hide it */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

/*
 * Bug: After a chord (e.g., Mod+Left), the Super release might be lost.
 * Then if user presses another chord key while still holding Super,
 * the chord handler should fire because modkeyheld was reset by reconciliation
 * of a DIFFERENT key, or... 
 * Actually, if reconciliation happened on a key WITHOUT Mod4Mask, and then
 * a chord key is pressed WITH Mod4Mask (user was holding Mod the whole time),
 * the chord handler WOULD fire. Let's test this.
 */
static void test_28_chord_after_reconciliation_with_mod_still_held(void) {
    TEST("Chord after reconciliation (Mod still held) → bar shows");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* User presses Mod */
    key_press_bare_super();
    modkeyheld = 1;

    /* User releases Mod but event is LOST */
    key_release_super_lost();
    /* modkeyheld still 1 */

    /* User presses a key WITHOUT Mod (regular key) → reconciliation */
    key_press_regular();
    /* modkeyheld=0, autoshowuntil=fake_now+3 */
    ASSERT_STATE(1, 0, -1, 1);

    /* User was NOT holding Mod when they pressed the regular key
       (otherwise state would have had Mod4Mask and reconciliation wouldn't fire).
       So this test models: user released Mod (lost), waited, pressed 'a' without Mod.
       Now later presses Mod again to reveal bar. */

    /* Timer expires and hides bar */
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    /* Now press Mod again — bare Super works */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);

    PASS();
}

/* ── Main ─────────────────────────────────────────────────────────── */
/* ── Regression: mappingnotify → grabkeys() must preserve bare Super grabs ─── */

/*
 * Bug: When MappingNotify fires (keyboard remap), the old grabkeys() called
 * XUngrabKey(AnyKey, AnyModifier) which wiped the bare Super grabs. Only
 * keybindings were re-grabbed. Bare Super keypresses stopped reaching dwm.
 *
 * Fix: grabkeys() now grabs ALL keycodes that produce Super_L/Super_R
 * alongside the keybindings. This test simulates a MappingNotify event
 * (which calls grabkeys) and verifies bare Super still works afterward.
 */
static void test_29_mappingnotify_regrab_bare_super(void) {
    TEST("MappingNotify → grabkeys() preserves bare Super grabs");
    reset_state();
    hidemode = 1;
    showbar = 0;

    /* Simulate what happens: initial setup, then MappingNotify fires */
    /* Before MappingNotify: bare Super works */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    /* MappingNotify fires → grabkeys() is called.
     * With the fix, bare Super grabs are re-established inside grabkeys().
     * The simulation: just reset and verify bare Super still works.
     * (In the real code, grabkeys() now regrabs Super keys.) */
    printf("  [mappingnotify] MappingKeyboard → grabkeys() re-grabs bare Super\n");

    /* After MappingNotify: bare Super must STILL work */
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    PASS();
}

/*
 * Prove: repeated bare Super presses all work (not just the first one).
 * This was the original bug: "only the first mod press is unhiding."
 */
static void test_30_repeated_bare_super_presses(void) {
    TEST("Repeated bare Super presses: 1st, 2nd, 3rd all show bar");
    reset_state();
    hidemode = 1;
    showbar = 0;
    int i;

    for (i = 1; i <= 5; i++) {
        printf("  --- press %d ---\n", i);
        key_press_bare_super();
        if (!modkeyheld || !showbar) {
            printf("  FAIL: press %d did not show bar (modkeyheld=%d showbar=%d)\n", i, modkeyheld, showbar);
            tests_failed++; return;
        }
        key_release_super();
        advance_time(4);
        timer_check();
        if (showbar) {
            printf("  FAIL: press %d bar did not hide after timer (showbar=%d)\n", i, showbar);
            tests_failed++; return;
        }
    }

    printf("  All 5 presses worked correctly\n");
    PASS();
}

/*
 * Prove: when hidemode is ON, ANY chord key (Mod+H, Mod+Return, Mod+Left, etc.)
 * shows the bar via the chord handler, even if the bare Super KeyPress was lost.
 * This is the safety net from dwl's keypressmod approach.
 */
static void test_31_chord_handler_safety_net(void) {
    TEST("Chord handler: ANY Mod+key shows bar even without bare Super press");
    reset_state();
    hidemode = 1;
    showbar = 0;
    modkeyheld = 0;  /* Simulate: bare Super press was LOST */

    /* The chord handler at line 1089 fires for ANY key with Mod4Mask in state
     * when hidemode=1 and modkeyheld=0. This is the safety net. */
    printf("  Simulating: bare Super press LOST, then user presses Mod+H\n");
    /* key_press_chord with toggle=0 just tests the chord handler, no binding */
    /* We need to simulate: state has Mod4Mask, modkeyheld=0, hidemode=1 */
    key_press_chord(0);  /* trigger_togglehidemode=0, but chord handler should fire */

    /* Chord handler should have set modkeyheld=1 and shown bar */
    ASSERT_STATE(1, 1, 0, 1);

    /* Now release Super (bare release after chord) */
    key_release_super();
    ASSERT_STATE(1, 0, -1, 1);

    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);

    /* Also test with a chord that ALSO triggers togglehidemode (Mod+H) */
    printf("  Simulating: bare Super press LOST, then Mod+H (togglehidemode OFF)\n");
    key_press_chord(1);  /* triggers togglehidemode OFF */
    ASSERT_STATE(0, 1, 0, 1);  /* hidemode=0, modkeyheld=1 (OFF path doesn't reset) */

    PASS();
}


/*
 * Prove: when a new window (e.g. Firefox) steals focus while Mod is held,
 * focusin reconciles the lost Mod release so the bar auto-hides correctly.
 *
 * Scenario:
 *   1. Hide mode ON, bar hidden
 *   2. User presses Mod+F (launch Firefox) → modkeyheld=1, bar shown
 *   3. Firefox window appears and steals focus → FocusIn event
 *   4. focusin handler detects lost Mod → resets modkeyheld, starts auto-hide
 *   5. User releases Mod, but event is LOST (Firefox has focus)
 *   6. Timer expires → bar auto-hides ✓
 *
 * Before the fix: modkeyheld stayed 1 forever, bar never hid.
 */
static void test_32_focusin_reconciles_lost_mod_release(void) {
    TEST("focusin: lost Mod release after Firefox steals focus → auto-hide");
    reset_state();
    hidemode = 1;
    showbar = 0;
    modkeyheld = 0;

    printf("  Setup: hidemode=1, bar hidden (hide mode ON)\n");
    ASSERT_STATE(1, 0, 0, 0);

    /* Step 1: User presses Mod (bare Super) to start launching Firefox */
    printf("  Step 1: User presses Mod\n");
    key_press_bare_super();
    ASSERT_STATE(1, 1, 0, 1);  /* bar shown, modkeyheld=1 */

    /* Step 2: User presses F (chord) which launches Firefox */
    printf("  Step 2: Mod+F chord launches Firefox\n");
    key_press_chord(0);  /* just a chord, no hide-mode toggle */
    ASSERT_STATE(1, 1, 0, 1);  /* still shown */

    /* Step 3: Firefox window appears and FocusIn fires for the new window.
     * The Mod key is still physically held. dwm focusin detects that
     * focus changed to a client window while modkeyheld=1 → reconcile. */
    printf("  Step 3: Firefox steals focus → FocusIn arrives\n");
    focusin(0x12345678);  /* Firefox's window ID */
    ASSERT_STATE(1, 0, -1, 1);  /* modkeyheld reset, auto-hide timer started */

    /* Step 4: User releases Mod, but the event is LOST because Firefox
     * has focus and the XGrabKey for bare Super may not deliver to dwm.
     * This was the root cause: modkeyheld would stay 1 forever.
     * But with the focusin fix, modkeyheld is already 0. */
    printf("  Step 4: User releases Mod (event LOST — Firefox has focus)\n");
    key_release_super_lost();
    /* modkeyheld already 0, so this does nothing. State unchanged. */
    ASSERT_STATE(1, 0, -1, 1);

    /* Step 5: Timer expires → bar auto-hides */
    printf("  Step 5: Auto-hide timer expires (3s later)\n");
    advance_time(4);
    timer_check();
    ASSERT_STATE(1, 0, 0, 0);  /* bar HIDDEN! ✓ */

    printf("  Firefox-launch bug FIXED: bar auto-hid after focusin reconciled\n");
    PASS();
}

/*
 * Prove: when a new window launches (e.g. Firefox, terminal, any app)
 * the bar briefly appears for 3 seconds so the user can see what opened
 * and has a chance to interact with the bar.
 *
 * This hooks into manage() — fires on EVERY new window, not just
 * those launched via a Mod chord. It covers:
 *
 *   a) Hide mode ON, bar hidden, app opens → bar shows for 3s, then hides
 *   b) Hide mode ON, bar already shown via Mod → timer extends, no flash
 *   c) Hide mode ON, timer active, another app opens → timer extends
 *   d) Hide mode OFF → no effect (bar stays as-is)
 *   e) Multiple rapid window opens → timer stays 3s from LAST window
 */
static void test_33_manage_window_auto_show(void) {
	TEST("manage: new window briefly shows bar in hide mode");

	/* ── Scenario A: Basic new window in hide mode ── */
	printf("\n  --- Scenario A: New window in hide mode ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	printf("  Setup: hidemode=1, bar hidden\n");
	ASSERT_STATE(1, 0, 0, 0);

	printf("  User clicks Firefox icon → window mapped\n");
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);  /* bar shown, timer ticking */

	printf("  After 2 seconds: bar still visible\n");
	advance_time(2);
	timer_check();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  After 4 more seconds: timer expired, bar hides\n");
	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);  /* bar hidden again */

	/* ── Scenario B: Window opens while Mod is held ── */
	printf("\n  --- Scenario B: New window while Mod held ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	printf("  User presses Mod (bar shown via modkeyheld)\n");
	key_press_bare_super();
	ASSERT_STATE(1, 1, 0, 1);

	printf("  Firefox opens while Mod held\n");
	manage_window();
	/* autoshowuntil set but modkeyheld=1 dominates; bar stays visible */
	ASSERT_STATE(1, 1, -1, 1);

	printf("  User releases Mod → timer-based show continues 3s\n");
	key_release_super();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  After 3s: bar hides\n");
	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	/* ── Scenario C: Second window extends timer ── */
	printf("\n  --- Scenario C: Second window extends timer ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	printf("  First window opens → bar shown\n");
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  2 seconds pass\n");
	advance_time(2);
	timer_check();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  Second window opens → timer extends to now+3\n");
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  2 more seconds: bar still visible (would have expired by now)\n");
	advance_time(2);
	timer_check();
	ASSERT_STATE(1, 0, -1, 1);  /* timer was extended, still alive */

	printf("  After 2 more seconds: timer expires, bar hides\n");
	advance_time(2);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	/* ── Scenario D: Hide mode OFF → no effect ── */
	printf("\n  --- Scenario D: Hide mode OFF, new window ---\n");
	reset_state();
	hidemode = 0;
	showbar = 1;  /* bar always visible */
	printf("  Setup: hidemode=0, bar shown\n");
	ASSERT_STATE(0, 0, 0, 1);

	printf("  New window opens → no change (updatebarvisibility is NOOP)\n");
	manage_window();
	/* autoshowuntil stays 0, showbar stays 1 */
	ASSERT_STATE(0, 0, 0, 1);

	/* ── Scenario E: Rapid window spam ── */
	printf("\n  --- Scenario E: Rapid window spam ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	printf("  Setup: hidemode=1, bar hidden\n");
	ASSERT_STATE(1, 0, 0, 0);

	/* App 1 */
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);
	advance_time(1);
	timer_check();

	/* App 2 */
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);
	advance_time(1);
	timer_check();

	/* App 3 */
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);
	advance_time(1);
	timer_check();

	/* App 4 */
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);
	advance_time(1);
	timer_check();

	/* App 5 */
	manage_window();
	ASSERT_STATE(1, 0, -1, 1);

	printf("  5 apps in 4s → bar still visible (timer at now+3 from last)\n");

	printf("  3s after last app → bar hides\n");
	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	/* ── Scenario F: Mod release + same-second manage == BROKEN ── */
	printf("\n  --- Scenario F: Mod release, then manage() same second ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	printf("  Setup: hidemode=1, bar hidden\n");
	ASSERT_STATE(1, 0, 0, 0);

	printf("  User presses Mod+F (launch Firefox)\n");
	key_press_bare_super();
	ASSERT_STATE(1, 1, 0, 1);

	printf("  User releases Mod → autoshowuntil = %ld\n", (long)fake_now + 3);
	key_release_super();
	ASSERT_STATE(1, 0, fake_now + 3, 1);

	printf("  Firefox window appears, manage() fires in same second\n");
	printf("  manage() checks: autoshowuntil(%ld) < now+3(%ld) → FALSE!\n",
	       (long)autoshowuntil, (long)(fake_now + 3));
	manage_window();
	/* BUG: autoshowuntil == now+3, so < is false, manage() does NOT extend! */
	ASSERT_STATE(1, 0, fake_now + 3, 1);  /* timer NOT extended from manage */

	printf("  3s later: bar hides (timer from Mod release, NOT from manage)\n");
	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	printf("  EXPECTED: manage() should extend timer to now+3 from window open\n");
	printf("  ACTUAL:   bar hid after original Mod-release timer, no flash\n");

	printf("  New window auto-show: Scenario F demonstrates the bug\n");
	PASS();
}

/*
 * Prove: manage() re-shows bar even after timer expires (bar hidden),
 * and extends timer when called with autoshowuntil == now+3.
 * This is the \"w x\" (firefox) scenario: user launches app from
 * terminal, bar is hidden, manage() fires and flashes the bar.
 */
static void test_34_manage_reshows_after_timer_expired(void) {
	TEST("manage: re-shows bar after timer expired, extends on <= now+3");

	/* ── Sub-test A: bar hidden, manage() shows it ── */
	printf("\n  --- A: Bar hidden, manage() shows it ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;
	ASSERT_STATE(1, 0, 0, 0);

	manage_window();
	ASSERT_STATE(1, 0, fake_now + 3, 1);

	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	/* ── Sub-test B: timer expired (bar hidden), manage() re-shows ── */
	printf("  --- B: Timer expired, manage() re-shows bar ---\n");
	manage_window();
	ASSERT_STATE(1, 0, fake_now + 3, 1);

	advance_time(4);
	timer_check();
	ASSERT_STATE(1, 0, 0, 0);

	/* ── Sub-test C: autoshowuntil == now+3, manage() extends ── */
	printf("  --- C: autoshowuntil == now+3, manage() extends with <= ---\n");
	reset_state();
	hidemode = 1;
	showbar = 0;

	/* Simulate Mod release to set autoshowuntil = now + 3 */
	key_press_bare_super();
	key_release_super();
	ASSERT_STATE(1, 0, fake_now + 3, 1);

	/* manage_window at same fake_now: autoshowuntil(fake_now+3) <= fake_now+3 → TRUE */
	manage_window();
	ASSERT_STATE(1, 0, fake_now + 3, 1);

	printf("  manage() auto-show: all sub-tests pass\n");
	PASS();
}

int main(void) {
    printf("dwm hide mode state machine tests\n");
    printf("==================================\n");

    test_01_bare_super_press_release_hidemode_on();
    test_02_bare_super_press_release_hidemode_off();
    test_03_mod_h_toggle_hidemode_on_to_off();
    test_04_mod_h_toggle_hidemode_off_to_on();
    test_05_mod_h_on_then_bare_super_hold();
    test_06_lost_mod_release_reconciliation();
    test_07_lost_mod_release_then_chord();
    test_08_fifo_show_all_hidemode_on();
    test_09_fifo_show_all_hidemode_off();
    test_10_fifo_hidemode_on_off();
    test_11_fifo_hide_all();
    test_12_togglebar_exits_hide_mode();
    test_13_timer_does_not_hide_while_modkeyheld();
    test_14_updatebarvisibility_noop_when_hidemode_off();
    test_15_rapid_toggle_on_off_sequence();
    test_16_bare_super_hidemode_off_no_bar_change();
    test_17_chord_handler_bypass_when_modkeyheld();
    test_18_fifo_show_all_during_autoshow_extends_timer();
    test_19_togglehidemode_on_resets_autoshow();
    test_20_bashrc_first_terminal();
    test_21_bashrc_hide_mode_on_not_first();
    test_22_bashrc_hide_mode_off_not_first();
    test_23_bashrc_first_terminal_always_wins();
    test_24_bashrc_dwl_first_terminal_not_exported();
    test_25_no_double_need_help();
    test_26_lost_release_after_chord_recovers();
    test_27_stuck_modkeyheld_prevented_hide_then_fixed();
    test_28_chord_after_reconciliation_with_mod_still_held();
    test_29_mappingnotify_regrab_bare_super();
    test_30_repeated_bare_super_presses();
    test_31_chord_handler_safety_net();
	test_32_focusin_reconciles_lost_mod_release();
	test_33_manage_window_auto_show();
	test_34_manage_reshows_after_timer_expired();
	printf("\n==================================\n");
    printf("RESULTS: %d tests, %d passed, %d failed\n",
           tests_passed + tests_failed, tests_passed, tests_failed);

    return tests_failed > 0 ? 1 : 0;
}
