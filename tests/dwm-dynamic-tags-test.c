/*
 * dwm-dynamic-tags-test.c — Unit tests for dwm dynamic tag system
 *
 * Models the exact state transitions from dotfiles/suckless/dwm/dwm.c
 * after the dynamic-tags patch (bartags + curtagidx + collapse model):
 *   - bartags  = tags drawn in the bar (occupied + revealed + anchor)
 *   - tagset   = always pinned to 1 << curtagidx (only current tag's windows show)
 *   - collapse = when leaving empty tag with higher occupied tags,
 *                all higher windows shift down (tag N+1 → tag N)
 *
 * Compile: gcc -Wall -o dwm-dynamic-tags-test dwm-dynamic-tags-test.c
 * Run:     ./dwm-dynamic-tags-test
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* ── Constants ────────────────────────────────────────────────────── */
#define TAGS_COUNT 9
#define TAGMASK     ((1 << TAGS_COUNT) - 1)

/* ── State variables (matching dwm.c) ─────────────────────────────── */
static unsigned int bartags = 1;
static unsigned int tagset0  = 1;
static unsigned int tagset1  = 1;
static int curtagidx = 0;

/* Simple client model */
#define MAX_CLIENTS 64
static unsigned int clients[MAX_CLIENTS];
static int client_count = 0;
static int client_focused = -1;

/* ── dwm.c functions ──────────────────────────────────────────────── */

static int tagisoccupied(int tagidx) {
	int i;
	for (i = 0; i < client_count; i++)
		if (clients[i] & (1 << tagidx))
			return 1;
	return 0;
}

static int has_higher_occupied(int from) {
	int i;
	for (i = from + 1; i < TAGS_COUNT; i++)
		if (tagisoccupied(i))
			return 1;
	return 0;
}

static void ensurebartagsvalid(void) {
	bartags |= 1;
	if (!(bartags & (1 << curtagidx))) {
		curtagidx = __builtin_ffs(bartags) - 1;
		if (curtagidx < 0)
			curtagidx = 0;
	}
	tagset0 = tagset1 = 1 << curtagidx;
}

static void collapse(int from) {
	int i;
	for (i = from; i < TAGS_COUNT - 1; i++) {
		unsigned int fr = 1 << (i + 1);
		unsigned int to = 1 << i;
		int ci;
		for (ci = 0; ci < client_count; ci++) {
			if (clients[ci] & fr) {
				clients[ci] &= ~fr;
				clients[ci] |= to;
			}
		}
		if (bartags & fr) {
			bartags |= to;
			bartags &= ~fr;
		} else {
			bartags &= ~to;
		}
	}
}

static void view(unsigned int mask) {
	mask &= TAGMASK;
	if (mask == TAGMASK) {
		bartags = TAGMASK;
		curtagidx = 0;
		tagset0 = tagset1 = 1;
		return;
	}
	if (!(bartags & mask))
		return;
	int idx = __builtin_ffs(mask) - 1;
	if (idx < 0 || idx == curtagidx)
		return;

	/* If leaving an empty non-anchor tag, clean it up (same as viewprev) */
	int oldidx = curtagidx;
	if (oldidx > 0 && !tagisoccupied(oldidx)) {
		if (has_higher_occupied(oldidx)) {
			collapse(oldidx);
			if (idx > oldidx)
				idx--;  /* target shifted down in collapse */
		} else {
			bartags &= ~(1 << oldidx);
		}
	}

	curtagidx = idx;
	tagset0 = tagset1 = 1 << idx;
}

static void viewnext(void) {
	/* Tag 1 (anchor) can advance even when empty */
	if (!tagisoccupied(curtagidx) && curtagidx > 0)
		return;
	if (curtagidx >= TAGS_COUNT - 1)
		return;
	int next = curtagidx + 1;
	bartags |= (1 << next);
	curtagidx = next;
	tagset0 = tagset1 = 1 << next;
}

static void viewprev(void) {
	int oldidx = curtagidx;

	/* Rule 3c/6: leaving an empty non-anchor tag */
	if (oldidx > 0 && !tagisoccupied(oldidx)) {
		if (has_higher_occupied(oldidx))
			collapse(oldidx);  /* Rule 6a: renumber down */
		else
			bartags &= ~(1 << oldidx);  /* Rule 6b: just hide */
	}

	/* Find previous tag in the bar */
	int prev;
	for (prev = oldidx - 1; prev >= 0; prev--)
		if (bartags & (1 << prev))
			break;
	if (prev < 0) {
		ensurebartagsvalid();
		return;
	}

	curtagidx = prev;
	tagset0 = tagset1 = 1 << prev;
}

static void tag_op(unsigned int mask) {
	mask &= TAGMASK;
	if (client_focused >= 0 && (bartags & mask))
		clients[client_focused] = mask;
}

static void tagnext(void) {
	if (client_focused < 0 || curtagidx >= TAGS_COUNT - 1)
		return;
	int next = curtagidx + 1;
	unsigned int nextmask = 1 << next;
	clients[client_focused] = nextmask;
	bartags |= nextmask;
	curtagidx = next;
	tagset0 = tagset1 = nextmask;
}

static void tagprev(void) {
	if (client_focused < 0 || curtagidx <= 0)
		return;
	unsigned int bt = bartags;
	int prev;
	for (prev = curtagidx - 1; prev >= 0; prev--)
		if (bt & (1 << prev))
			break;
	if (prev < 0)
		return;
	clients[client_focused] = 1 << prev;
}

static void toggletag(unsigned int mask) {
	mask &= TAGMASK;
	if (client_focused < 0)
		return;
	if (!(bartags & mask))
		return;
	unsigned int newtags = clients[client_focused] ^ mask;
	if (newtags)
		clients[client_focused] = newtags;
}

static void toggleview(unsigned int mask) {
	mask &= TAGMASK;
	if (!(bartags & mask))
		return;
	unsigned int newbartags = bartags ^ mask;
	if (newbartags) {
		bartags = newbartags;
		ensurebartagsvalid();
	}
}

static int manage_client(unsigned int tags) {
	if (client_count >= MAX_CLIENTS)
		return -1;
	int idx = client_count++;
	clients[idx] = tags;
	bartags |= tags;
	if (client_focused < 0)
		client_focused = idx;
	return idx;
}

static void unmanage_client(int idx) {
	if (idx < 0 || idx >= client_count)
		return;
	int i;
	for (i = idx; i < client_count - 1; i++)
		clients[i] = clients[i + 1];
	client_count--;
	if (client_focused == idx)
		client_focused = (client_count > 0) ? 0 : -1;
	else if (client_focused > idx)
		client_focused--;

	unsigned int newset = 1;
	for (i = 0; i < client_count; i++)
		newset |= clients[i];
	newset |= (1 << curtagidx);
	bartags = newset & TAGMASK;
	ensurebartagsvalid();
}

/* ── Test framework ────────────────────────────────────────────────── */
static int tests_passed = 0;
static int tests_failed = 0;
static int test_num = 0;

#define TEST(name) \
	printf("\n─── TEST %d: %s ───\n", ++test_num, name)

static void reset_state(void) {
	bartags = 1;
	tagset0 = tagset1 = 1;
	curtagidx = 0;
	client_count = 0;
	client_focused = -1;
	memset(clients, 0, sizeof(clients));
}

#define ASSERT_INT(want, got, label) \
	do { \
		if ((want) != (got)) { \
			printf("  FAIL %s: want %d, got %d\n", label, want, got); \
			tests_failed++; \
			return; \
		} \
	} while(0)

#define ASSERT_BARTAGS(want)  ASSERT_INT(want, bartags, "bartags")
#define ASSERT_CURTAG(want)   ASSERT_INT(want, curtagidx, "curtagidx")
#define ASSERT_TAGSET(want)   ASSERT_INT(want, tagset0, "tagset")

#define ASSERT_VISIBLE_COUNT(want) \
	do { \
		int c = 0, i; \
		for (i = 0; i < TAGS_COUNT; i++) \
			if (bartags & (1 << i)) c++; \
		ASSERT_INT(want, c, "bar count"); \
	} while(0)

#define ASSERT_CLIENT_TAGS(idx, want) \
	do { \
		if (idx < 0 || idx >= client_count) { \
			printf("  FAIL: client %d out of range (count=%d)\n", idx, client_count); \
			tests_failed++; return; \
		} \
		ASSERT_INT(want, clients[idx], "client tags"); \
	} while(0)

#define PASS() do { printf("  PASS\n"); tests_passed++; } while(0)

/* ── Helper: dump state for debugging ──────────────────────────────── */
static void dump(void) {
	printf("  State: bartags=0x%x curtagidx=%d tagset=0x%x clients=%d\n",
	       bartags, curtagidx, tagset0, client_count);
	int i;
	for (i = 0; i < client_count; i++)
		printf("    client[%d] tags=0x%x\n", i, clients[i]);
}


/* ══════════════════════════════════════════════════════════════════════
 * TESTS
 * ══════════════════════════════════════════════════════════════════════ */

static void test_01_startup_single_tag(void) {
	TEST("Startup: exactly tag 1 visible");
	reset_state();
	ASSERT_BARTAGS(1);
	ASSERT_TAGSET(1);
	ASSERT_CURTAG(0);
	ASSERT_VISIBLE_COUNT(1);
	PASS();
}

static void test_02_viewnext_empty_tag_noop(void) {
	TEST("Rule 3b: Mod+Right from empty non-anchor tag does nothing");
	reset_state();
	/* Reveal tag 2, navigate to it (empty), then try viewnext — should block */
	bartags |= (1 << 1);
	curtagidx = 1;
	tagset0 = tagset1 = 1 << 1;
	viewnext();
	ASSERT_CURTAG(1);  /* still on tag 2, didn't advance */
	ASSERT_BARTAGS(1 | (1 << 1));
	PASS();
}

static void test_03_viewnext_reveals_next_tag(void) {
	TEST("Rule 3a: Mod+Right from occupied tag reveals next in bar");
	reset_state();
	manage_client(1 << 0);
	viewnext();
	ASSERT_CURTAG(1);
	ASSERT_BARTAGS(1 | (1 << 1));
	ASSERT_TAGSET(1 << 1);
	PASS();
}

static void test_04_viewprev_hides_empty_revealed_tag(void) {
	TEST("Rule 3c: Mod+Left from empty revealed tag hides it (no higher occupied)");
	reset_state();
	manage_client(1 << 0);
	viewnext();
	viewprev();
	ASSERT_CURTAG(0);
	ASSERT_BARTAGS(1);
	PASS();
}

static void test_05_viewprev_occupied_tag_stays(void) {
	TEST("Rule 3c: Mod+Left from occupied tag keeps it");
	reset_state();
	manage_client(1 << 0);
	manage_client(1 << 1);
	/* Manually reveal empty tag 3 in bar */
	bartags |= (1 << 2);
	curtagidx = 2;
	tagset0 = tagset1 = 1 << 2;
	viewprev();
	ASSERT_CURTAG(1);
	ASSERT_BARTAGS(1 | (1 << 1));  /* tag 3 hidden */
	PASS();
}

static void test_06_tagnext_reveals_destination(void) {
	TEST("Rule 4: Mod+Shift+Right reveals destination tag in bar");
	reset_state();
	int c = manage_client(1 << 0);
	client_focused = c;
	tagnext();
	ASSERT_CLIENT_TAGS(c, 1 << 1);
	ASSERT_CURTAG(1);
	ASSERT_BARTAGS(1 | (1 << 1));
	ASSERT_TAGSET(1 << 1);
	PASS();
}

static void test_07_view_only_visible_tags(void) {
	TEST("Rule 5: Mod+Number only switches to tags in the bar");
	reset_state();
	view(1 << 2);
	ASSERT_CURTAG(0);
	view(1 << 0);
	ASSERT_CURTAG(0);
	PASS();
}

static void test_08_tag_only_visible_tags(void) {
	TEST("Rule 5: Mod+Shift+Number only tags onto tags in bar");
	reset_state();
	int c = manage_client(1 << 0);
	client_focused = c;
	tag_op(1 << 2);
	ASSERT_CLIENT_TAGS(c, 1 << 0);
	PASS();
}

/* ── THE KEY TEST: collapse with renumbering ──────────────────────── */
static void test_09_collapse_renumbers_higher_windows(void) {
	TEST("Rule 6a: collapse shifts higher windows down (tag 4 → tag 3)");
	reset_state();

	/* Tags 1,2,3,4 in bar. Tag 1 has window A, tag 4 has window B.
	 * Tag 3 is empty. User leaves tag 3 → collapse: B moves from 4→3. */
	manage_client(1 << 0);  /* window on tag 1 */
	int b = manage_client(1 << 3);  /* window on tag 4 */

	bartags = 1 | (1 << 1) | (1 << 2) | (1 << 3);  /* 1,2,3,4 */
	curtagidx = 2;  /* on tag 3 */
	tagset0 = tagset1 = 1 << 2;

	ASSERT_BARTAGS(1 | (1 << 1) | (1 << 2) | (1 << 3));
	ASSERT_CLIENT_TAGS(b, 1 << 3);

	viewprev();  /* leave empty tag 3, tag 4 has windows → collapse */

	/* After collapse: bars shows 1,2,3. Window B now on tag 3 (was 4). */
	ASSERT_CURTAG(1);  /* moved to tag 2 */
	ASSERT_BARTAGS(1 | (1 << 1) | (1 << 2));  /* tags 1,2,3 */
	ASSERT_CLIENT_TAGS(b, 1 << 2);  /* B's tag shifted from 4→3 */
	PASS();
}

/* ── Collapse: only happens when higher tags ARE populated ─────────── */
static void test_10_collapse_no_higher_populated(void) {
	TEST("Rule 6b: no higher populated → tag just disappears (no collapse)");
	reset_state();
	manage_client(1 << 0);
	bartags |= (1 << 2);  /* reveal empty tag 3 */
	curtagidx = 2;
	tagset0 = tagset1 = 1 << 2;

	viewprev();
	ASSERT_CURTAG(0);
	ASSERT_BARTAGS(1);  /* just tag 1 */
	PASS();
}

static void test_11_manage_reveals_tag(void) {
	TEST("manage() adds client's tag to bartags");
	reset_state();
	manage_client(1 << 4);
	ASSERT_BARTAGS(1 | (1 << 4));
	PASS();
}

static void test_12_unmanage_hides_empty_noncurrent_tag(void) {
	TEST("unmanage() hides empty non-current tag from bar");
	reset_state();
	manage_client(1 << 0);
	int c2 = manage_client(1 << 1);
	(void)c2;
	curtagidx = 0;
	tagset0 = tagset1 = 1;
	unmanage_client(1);
	ASSERT_BARTAGS(1);
	PASS();
}

static void test_13_unmanage_preserves_current_empty_tag(void) {
	TEST("unmanage() keeps current tag in bar even if empty");
	reset_state();
	manage_client(1 << 1);
	bartags = 1 | (1 << 1);
	curtagidx = 1;
	tagset0 = tagset1 = 1 << 1;
	unmanage_client(0);
	ASSERT_BARTAGS(1 | (1 << 1));
	viewprev();
	ASSERT_BARTAGS(1);
	PASS();
}

static void test_14_mod0_shows_all_tags(void) {
	TEST("Mod+0 reveals all 9 tags in bar");
	reset_state();
	view(TAGMASK);
	ASSERT_BARTAGS(TAGMASK);
	ASSERT_CURTAG(0);
	ASSERT_VISIBLE_COUNT(9);
	PASS();
}

static void test_15_tag1_never_hidden(void) {
	TEST("Rule 1: Tag 1 never hidden from bar");
	reset_state();
	toggleview(1 << 0);
	ASSERT_INT(1, bartags & 1, "tag 1 in bartags");
	int c = manage_client(1 << 0);
	unmanage_client(c);
	ASSERT_INT(1, bartags & 1, "tag 1 still in bartags");
	PASS();
}

static void test_16_revealed_tag_shows_only_its_own_windows(void) {
	TEST("Revealing tag 2 does not show tag 1's windows");
	reset_state();
	manage_client(1 << 0);
	viewnext();
	ASSERT_TAGSET(1 << 1);
	ASSERT_INT(0, tagisoccupied(1), "tag 2 empty");
	int c2 = manage_client(1 << 1);
	ASSERT_CLIENT_TAGS(c2, 1 << 1);
	PASS();
}

static void test_17_chain_viewnext_multiple(void) {
	TEST("Chain Mod+Right: reveal tags 2,3,4 sequentially");
	reset_state();
	manage_client(1 << 0);
	viewnext();
	ASSERT_CURTAG(1);
	manage_client(1 << 1);
	viewnext();
	ASSERT_CURTAG(2);
	manage_client(1 << 2);
	viewnext();
	ASSERT_CURTAG(3);
	ASSERT_BARTAGS(1 | (1<<1) | (1<<2) | (1<<3));
	PASS();
}

static void test_18_collapse_chain(void) {
	TEST("Chain Mod+Left through empty tags: collapse cascades");
	reset_state();

	/* Tags 1 and 4 have windows. Reveal 2 and 3 empty in between.
	 * Navigate 4→3→2→1. Each empty tag with higher occupied triggers collapse. */
	manage_client(1 << 0);
	int w4 = manage_client(1 << 3);  /* tag 4 has window */
	bartags = 1 | (1<<1) | (1<<2) | (1<<3);
	curtagidx = 3;
	tagset0 = tagset1 = 1 << 3;

	viewprev();  /* 4→3: tag 4 occupied, no collapse */
	ASSERT_CURTAG(2);

	viewprev();  /* 3→2: tag 3 empty, tag 4 occupied → collapse: 4→3 */
	ASSERT_CURTAG(1);
	ASSERT_CLIENT_TAGS(w4, 1 << 2);  /* was tag 4, now tag 3 */

	viewprev();  /* 2→1: tag 2 empty, tag 3 occupied → collapse: 3→2 */
	ASSERT_CURTAG(0);
	ASSERT_CLIENT_TAGS(w4, 1 << 1);  /* now tag 2 */
	ASSERT_BARTAGS(1 | (1 << 1));     /* tags 1 and 2 */

	PASS();
}

static void test_19_toggleview_only_visible_tags(void) {
	TEST("toggleview only works on tags in the bar");
	reset_state();
	toggleview(1 << 2);
	ASSERT_BARTAGS(1);
	bartags |= (1 << 1);
	toggleview(1 << 1);
	ASSERT_BARTAGS(1);
	PASS();
}

static void test_20_toggletag_only_visible_tags(void) {
	TEST("toggletag only works on tags in the bar");
	reset_state();
	int c = manage_client(1 << 0);
	client_focused = c;
	toggletag(1 << 2);
	ASSERT_CLIENT_TAGS(c, 1 << 0);
	bartags |= (1 << 1);
	toggletag(1 << 1);
	ASSERT_CLIENT_TAGS(c, 1 | (1 << 1));
	PASS();
}

static void test_21_tagprev_to_previous_visible(void) {
	TEST("Mod+Shift+Left moves window to previous bar tag");
	reset_state();
	manage_client(1 << 0);
	int c = manage_client(1 << 2);
	client_focused = c;
	bartags |= (1 << 2);
	curtagidx = 2;
	tagset0 = tagset1 = 1 << 2;
	tagprev();
	ASSERT_CLIENT_TAGS(c, 1 << 0);
	PASS();
}

static void test_22_kill_last_on_anchor(void) {
	TEST("Killing last window on anchor");
	reset_state();
	int c = manage_client(1 << 0);
	unmanage_client(c);
	ASSERT_INT(1, bartags & 1, "tag 1 still in bartags");
	PASS();
}

static void test_23_viewnext_at_tag9_boundary(void) {
	TEST("Mod+Right at tag 9: no-op");
	reset_state();
	manage_client(1 << 7);
	curtagidx = 8;
	tagset0 = tagset1 = 1 << 8;
	bartags |= (1 << 8);
	viewnext();
	ASSERT_CURTAG(8);
	PASS();
}

static void test_24_tagnext_at_tag9_boundary(void) {
	TEST("Mod+Shift+Right at tag 9: no-op");
	reset_state();
	int c = manage_client(1 << 8);
	client_focused = c;
	curtagidx = 8;
	tagset0 = tagset1 = 1 << 8;
	bartags |= (1 << 8);
	tagnext();
	ASSERT_CLIENT_TAGS(c, 1 << 8);
	PASS();
}

static void test_25_no_client_tag_ops(void) {
	TEST("tagnext/tagprev with no focused client: no-op");
	reset_state();
	client_focused = -1;
	tagnext();
	tagprev();
	PASS();
}

static void test_26_advance_from_empty_tag1(void) {
	TEST("Can advance from empty tag 1 (anchor) to reveal tag 2");
	reset_state();
	/* Tag 1 is empty but it's the anchor — viewnext must work to escape */
	viewnext();
	ASSERT_CURTAG(1);
	ASSERT_BARTAGS(1 | (1 << 1));
	PASS();
}

static void test_27_viewprev_at_tag1_boundary(void) {
	TEST("Mod+Left at tag 1: stays on tag 1");
	reset_state();
	viewprev();
	ASSERT_CURTAG(0);
	PASS();
}

static void test_28_multi_client_tag_stays(void) {
	TEST("Tag with multiple clients stays when one removed");
	reset_state();
	manage_client(1 << 1);
	manage_client(1 << 1);
	unmanage_client(0);
	ASSERT_INT(1, tagisoccupied(1), "tag 2 still occupied");
	ASSERT_BARTAGS(1 | (1 << 1));
	curtagidx = 0;
	tagset0 = tagset1 = 1;
	unmanage_client(0);
	ASSERT_BARTAGS(1);
	PASS();
}

static void test_29_full_workflow(void) {
	TEST("Full workflow: open, navigate, populate, close, collapse");
	reset_state();

	int term1 = manage_client(1 << 0);
	client_focused = term1;

	viewnext();  /* reveal tag 2 */
	ASSERT_CURTAG(1);

	int browser = manage_client(1 << 1);
	client_focused = browser;

	viewnext();  /* reveal tag 3 (empty) */
	ASSERT_CURTAG(2);

	/* Spawn something on tag 4 directly */
	int four = manage_client(1 << 3);
	ASSERT_CLIENT_TAGS(four, 1 << 3);

	/* Now: tags 1,2,3,4 in bar. On tag 3 (empty). Higher (tag 4) occupied.
	 * Leave tag 3 → collapse: tag 4 moves to tag 3 */
	viewprev();
	ASSERT_CURTAG(1);  /* on tag 2 */
	/* Window that was on tag 4 should now be on tag 3 */
	ASSERT_CLIENT_TAGS(four, 1 << 2);
	/* Bar shows 1,2,3 */
	ASSERT_BARTAGS(1 | (1 << 1) | (1 << 2));

	PASS();
}

static void test_30_collapse_multi_level(void) {
	TEST("Multi-level collapse: empty tag 2, higher tags 3+4 shift down");
	reset_state();

	manage_client(1 << 0);           /* tag 1 */
	int win3 = manage_client(1 << 2); /* tag 3 */
	int win4 = manage_client(1 << 3); /* tag 4 */

	/* Tags 1,2,3,4 all in bar. On tag 2 (empty). */
	bartags = 1 | (1<<1) | (1<<2) | (1<<3);
	curtagidx = 1;
	tagset0 = tagset1 = 1 << 1;

	/* Leave tag 2 → collapse: 3→2, 4→3 */
	viewprev();
	ASSERT_CURTAG(0);
	ASSERT_BARTAGS(1 | (1<<1) | (1<<2));
	ASSERT_CLIENT_TAGS(win3, 1 << 1);  /* was tag 3, now tag 2 */
	ASSERT_CLIENT_TAGS(win4, 1 << 2);  /* was tag 4, now tag 3 */
	PASS();
	PASS();
}

/* ── Mod+Number cleanup: same as viewprev when leaving empty tag ──── */
static void test_31_view_number_cleans_up_empty(void) {
	TEST("Mod+Number off empty tag hides it (no higher occupied)");
	reset_state();

	/* Tags 1 and 3 visible, both with windows, on tag 3 */
	manage_client(1 << 0);
	int c3 = manage_client(1 << 2);
	(void)c3;
	bartags = 1 | (1 << 2);
	curtagidx = 2;
	tagset0 = tagset1 = 1 << 2;

	/* Delete window on tag 3 — tag 3 now empty but user still on it */
	unmanage_client(1);  /* c3 removed, tag 3 empty */
	ASSERT_INT(0, tagisoccupied(2), "tag 3 empty");
	ASSERT_BARTAGS(1 | (1 << 2));  /* still in bar (current) */

	/* Now press Mod+1 — navigate to tag 1, tag 3 should be hidden */
	view(1 << 0);
	ASSERT_CURTAG(0);
	ASSERT_BARTAGS(1);  /* tag 3 gone */
	PASS();
}

static void test_32_view_number_collapses_with_higher(void) {
	TEST("Mod+Number off empty tag collapses + target adjusts");
	reset_state();

	/* Tags 1,2,3,4 visible. Windows on tag 1 and tag 4. On tag 3 (empty). */
	manage_client(1 << 0);
	int w4 = manage_client(1 << 3);
	bartags = 1 | (1<<1) | (1<<2) | (1<<3);
	curtagidx = 2;  /* on tag 3 (empty) */
	tagset0 = tagset1 = 1 << 2;

	/* Press Mod+2 — navigate to tag 2, tag 3 collapses, tag 4→3 */
	view(1 << 1);
	ASSERT_CURTAG(1);  /* on tag 2 */
	ASSERT_BARTAGS(1 | (1<<1) | (1<<2));  /* tags 1,2,3 */
	ASSERT_CLIENT_TAGS(w4, 1 << 2);  /* was tag 4, now tag 3 (idx 2) */

	/* Press Mod+3 — tag 3 has the window. But tag 2 (current) is
	 * empty → collapse fires: window 3→2, target 3→2. */
	view(1 << 2);
	ASSERT_CURTAG(1);  /* target adjusted: old tag 3 collapsed to tag 2 */
	ASSERT_CLIENT_TAGS(w4, 1 << 1);  /* window now on tag 2 */
	ASSERT_BARTAGS(1 | (1 << 1));  /* only tags 1 and 2 */
	PASS();
}


/* ══════════════════════════════════════════════════════════════════════ */
int main(void) {
	printf("dwm dynamic tags state machine tests (bartags + collapse)\n");
	printf("========================================================\n");

	test_01_startup_single_tag();
	test_02_viewnext_empty_tag_noop();
	test_03_viewnext_reveals_next_tag();
	test_04_viewprev_hides_empty_revealed_tag();
	test_05_viewprev_occupied_tag_stays();
	test_06_tagnext_reveals_destination();
	test_07_view_only_visible_tags();
	test_08_tag_only_visible_tags();
	test_09_collapse_renumbers_higher_windows();
	test_10_collapse_no_higher_populated();
	test_11_manage_reveals_tag();
	test_12_unmanage_hides_empty_noncurrent_tag();
	test_13_unmanage_preserves_current_empty_tag();
	test_14_mod0_shows_all_tags();
	test_15_tag1_never_hidden();
	test_16_revealed_tag_shows_only_its_own_windows();
	test_17_chain_viewnext_multiple();
	test_18_collapse_chain();
	test_19_toggleview_only_visible_tags();
	test_20_toggletag_only_visible_tags();
	test_21_tagprev_to_previous_visible();
	test_22_kill_last_on_anchor();
	test_23_viewnext_at_tag9_boundary();
	test_24_tagnext_at_tag9_boundary();
	test_25_no_client_tag_ops();
	test_26_advance_from_empty_tag1();
	test_27_viewprev_at_tag1_boundary();
	test_28_multi_client_tag_stays();
	test_29_full_workflow();
	test_30_collapse_multi_level();
	test_31_view_number_cleans_up_empty();
	test_32_view_number_collapses_with_higher();

	printf("\n========================================================\n");
	printf("RESULTS: %d tests, %d passed, %d failed\n",
	       tests_passed + tests_failed, tests_passed, tests_failed);
	return tests_failed > 0 ? 1 : 0;
}
