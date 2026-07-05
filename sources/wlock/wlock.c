/* wlock - Wayland screen locker (slock equivalent for Wayland)
 *
 * Uses ext-session-lock-v1 protocol, PAM authentication, shm buffers,
 * and xkbcommon for proper keyboard handling.
 *
 * Build: make
 * Run:   wlock
 */

#define _POSIX_C_SOURCE 200809L
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <security/pam_appl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/mman.h>
#include <unistd.h>
#include <xkbcommon/xkbcommon.h>
#include <wayland-client.h>
#include "ext-session-lock-v1-client.h"

/* ─── colors (like slock) ─────────────────────────────────────────── */
static const uint32_t COLOR_BG       = 0xFF000000; /* black background   */
static const uint32_t COLOR_INPUT    = 0xFF00AA00; /* green while typing  */
static const uint32_t COLOR_CHECKING = 0xFFAAAA00; /* yellow (checking)   */
static const uint32_t COLOR_FAILED   = 0xFFAA0000; /* red flash on fail   */
static const uint32_t COLOR_SUCCESS  = 0xFF555555; /* dim on success      */
/* derived colors */
static uint32_t col_bg       = COLOR_BG;
static uint32_t col_input    = COLOR_INPUT;
static uint32_t col_checking = COLOR_CHECKING;
static uint32_t col_failed   = COLOR_FAILED;
static uint32_t col_success  = COLOR_SUCCESS;
#define MAX_PW_LEN 256

/* ─── globals ─────────────────────────────────────────────────────── */
static struct wl_display      *display;
static struct wl_registry     *registry;
static struct wl_compositor   *compositor;
static struct wl_shm          *shm;
static struct wl_seat         *seat;
static struct wl_keyboard     *keyboard;
static struct ext_session_lock_manager_v1 *lock_mgr;
static struct ext_session_lock_v1 *session_lock;

static bool locked   = false;
static bool finished = false;

/* xkb */
static struct xkb_context *xkb_ctx;
static struct xkb_keymap  *xkb_keymap;
static struct xkb_state   *xkb_state;

/* outputs */
#define MAX_OUTPUTS 16
struct output {
	struct wl_output      *wl_output;
	struct wl_surface     *surface;
	struct ext_session_lock_surface_v1 *lock_surface;
	uint32_t               width, height;
	bool                   configured;
};
static struct output outputs[MAX_OUTPUTS];
static int num_outputs = 0;

/* password state */
static char password[MAX_PW_LEN + 1];
static int  pw_len = 0;
static bool pw_failed   = false;
static bool pw_checking = false;

/* ─── helpers ─────────────────────────────────────────────────────── */

static void die(const char *msg) {
	fprintf(stderr, "wlock: %s\n", msg);
	exit(1);
}

static int
os_create_anonymous_file(off_t size)
{
	char tmpl[] = "/wlock-shm-XXXXXX";
	const char *path = getenv("XDG_RUNTIME_DIR");
	if (!path) path = "/tmp";

	char *name;
	if (asprintf(&name, "%s%s", path, tmpl) < 0)
		return -1;

	int fd = mkostemp(name, O_CLOEXEC);
	if (fd >= 0) {
		if (ftruncate(fd, size) < 0) {
			close(fd); fd = -1;
		}
		unlink(name);
	}
	free(name);
	return fd;
}

static struct wl_buffer *
create_shm_buffer(int width, int height, void **data_out)
{
	int stride = width * 4;
	int size   = stride * height;

	int fd = os_create_anonymous_file(size);
	if (fd < 0) die("os_create_anonymous_file");

	void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (data == MAP_FAILED) { close(fd); die("mmap"); }

	struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
	struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0,
		width, height, stride, WL_SHM_FORMAT_ARGB8888);
	wl_shm_pool_destroy(pool);
	close(fd);

	*data_out = data;
	return buf;
}

static void
draw_lock_screen(struct output *out, uint32_t *px, uint32_t bg_color)
{
	int w = out->width, h = out->height;
	for (int i = 0; i < w * h; i++)
		px[i] = bg_color;
}

static void
render_with_color(uint32_t color)
{
	for (int i = 0; i < num_outputs; i++) {
		if (!outputs[i].configured) continue;
		void *shm_data;
		struct wl_buffer *buf = create_shm_buffer(
			outputs[i].width, outputs[i].height, &shm_data);
		draw_lock_screen(&outputs[i], (uint32_t *)shm_data, color);
		wl_surface_attach(outputs[i].surface, buf, 0, 0);
		wl_surface_damage_buffer(outputs[i].surface, 0, 0,
			outputs[i].width, outputs[i].height);
		wl_surface_commit(outputs[i].surface);
		wl_buffer_destroy(buf);
		munmap(shm_data, outputs[i].width * outputs[i].height * 4);
	}
	wl_display_flush(display);
}

static uint32_t
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
render_all(void)
{
	render_with_color(current_color());
}

static void
beep(void)
{
	/* try multiple console paths for an audible bell */
	const char *paths[] = {"/dev/tty0", "/dev/console", "/dev/tty1", NULL};
	for (int i = 0; paths[i]; i++) {
		int fd = open(paths[i], O_WRONLY | O_NONBLOCK);
		if (fd >= 0) {
			write(fd, "\a", 1);
			close(fd);
			return;
		}
	}
	/* fallback: try stderr */
	write(STDERR_FILENO, "\a", 1);
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
	int ret = pam_start("wlock", user, &conv, &ph);
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
	if (session_lock && locked) {
		ext_session_lock_v1_unlock_and_destroy(session_lock);
		/* ensure compositor processes the unlock before we exit */
		wl_display_roundtrip(display);
	}
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

	/* dark grey while PAM hashes */
	pw_checking = true;
	render_all();
	wl_display_roundtrip(display);

	if (pam_auth(user)) {
		pw_checking = false;
		render_with_color(col_success);
		wl_display_roundtrip(display);
		unlock_and_exit();
	} else {
		pw_checking = false;
		pw_failed = true;
		pw_len = 0;
		beep();
		render_all();
	}
}

static void
clear_input(void)
{
	pw_len = 0;
	pw_failed = false;
	pw_checking = false;
	render_all();
}

/* ─── keyboard via xkbcommon ──────────────────────────────────────── */

static void
wl_keyboard_keymap(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                   uint32_t format, int fd, uint32_t size)
{
	if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
		close(fd);
		return;
	}

	char *map_str = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
	if (map_str == MAP_FAILED) { close(fd); return; }

	if (xkb_keymap) xkb_keymap_unref(xkb_keymap);
	if (xkb_state)  xkb_state_unref(xkb_state);

	xkb_keymap = xkb_keymap_new_from_string(xkb_ctx, map_str,
		XKB_KEYMAP_FORMAT_TEXT_V1, XKB_KEYMAP_COMPILE_NO_FLAGS);
	munmap(map_str, size);
	close(fd);

	if (!xkb_keymap) return;
	xkb_state = xkb_state_new(xkb_keymap);
}

static void
wl_keyboard_enter(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                  uint32_t serial __attribute__((unused)), struct wl_surface *surf __attribute__((unused)),
                  struct wl_array *keys __attribute__((unused)))
{
}

static void
wl_keyboard_leave(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                  uint32_t serial __attribute__((unused)), struct wl_surface *surf __attribute__((unused)))
{
}

static void
wl_keyboard_key(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                uint32_t serial __attribute__((unused)), uint32_t time __attribute__((unused)),
                uint32_t key, uint32_t state)
{
	if (!locked) return;
	if (!xkb_state) return;
	if (state != WL_KEYBOARD_KEY_STATE_PRESSED) return;

	xkb_keycode_t keycode = key + 8; /* evdev offset */
	xkb_keysym_t sym = xkb_state_key_get_one_sym(xkb_state, keycode);
	xkb_mod_mask_t mods = xkb_state_serialize_mods(xkb_state,
		XKB_STATE_MODS_DEPRESSED);

	bool ctrl = (mods & xkb_keymap_mod_get_index(xkb_keymap, XKB_MOD_NAME_CTRL)) != 0;

	if (ctrl && sym == XKB_KEY_u) {
		/* Ctrl-U: clear input (like slock) */
		clear_input();
		return;
	}

	switch (sym) {
	case XKB_KEY_Escape:
		clear_input();
		return;
	case XKB_KEY_BackSpace:
		if (pw_len > 0) {
			pw_len--;
			render_all();
		}
		return;
	case XKB_KEY_Return:
	case XKB_KEY_KP_Enter:
		try_auth();
		return;
	default:
		break;
	}

	/* regular character — clear any failure state so screen turns blue */
	if (pw_failed)
		pw_failed = false;

	char buf[16] = {0};
	int len = xkb_state_key_get_utf8(xkb_state, keycode, buf, sizeof(buf));
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
		render_all();
	}
}

static void
wl_keyboard_modifiers(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                      uint32_t serial __attribute__((unused)), uint32_t mods_depressed,
                      uint32_t mods_latched, uint32_t mods_locked,
                      uint32_t group)
{
	if (!xkb_state) return;
	xkb_state_update_mask(xkb_state, mods_depressed, mods_latched,
		mods_locked, 0, 0, group);
}

static void
wl_keyboard_repeat_info(void *data __attribute__((unused)), struct wl_keyboard *kb __attribute__((unused)),
                        int32_t rate __attribute__((unused)), int32_t delay __attribute__((unused)))
{
}

static const struct wl_keyboard_listener keyboard_listener = {
	.keymap       = wl_keyboard_keymap,
	.enter        = wl_keyboard_enter,
	.leave        = wl_keyboard_leave,
	.key          = wl_keyboard_key,
	.modifiers    = wl_keyboard_modifiers,
	.repeat_info  = wl_keyboard_repeat_info,
};

/* ─── seat ────────────────────────────────────────────────────────── */

static void
wl_seat_capabilities(void *data __attribute__((unused)), struct wl_seat *s, uint32_t caps)
{
	if (caps & WL_SEAT_CAPABILITY_KEYBOARD) {
		if (!keyboard) {
			keyboard = wl_seat_get_keyboard(s);
			wl_keyboard_add_listener(keyboard, &keyboard_listener, NULL);
		}
	}
}

static void
wl_seat_name(void *data __attribute__((unused)), struct wl_seat *s __attribute__((unused)), const char *name __attribute__((unused))) {}

static const struct wl_seat_listener seat_listener = {
	.capabilities = wl_seat_capabilities,
	.name         = wl_seat_name,
};

/* ─── session lock ────────────────────────────────────────────────── */

static void
lock_handle_locked(void *data __attribute__((unused)), struct ext_session_lock_v1 *lock __attribute__((unused)))
{
	locked = true;
	for (int i = 0; i < num_outputs; i++) {
		outputs[i].lock_surface = ext_session_lock_v1_get_lock_surface(
			session_lock, outputs[i].surface, outputs[i].wl_output);
	}
}

static void
lock_handle_finished(void *data __attribute__((unused)), struct ext_session_lock_v1 *lock __attribute__((unused)))
{
	finished = true;
}

static const struct ext_session_lock_v1_listener lock_listener = {
	.locked   = lock_handle_locked,
	.finished = lock_handle_finished,
};

/* ─── lock surface configure ──────────────────────────────────────── */

static void
lock_surface_configure(void *data,
                       struct ext_session_lock_surface_v1 *ls,
                       uint32_t serial, uint32_t width, uint32_t height)
{
	struct output *out = data;
	out->width = width;
	out->height = height;
	out->configured = true;

	ext_session_lock_surface_v1_ack_configure(ls, serial);

	if (locked) {
		render_with_color(current_color());
	}
}

static const struct ext_session_lock_surface_v1_listener lock_surface_listener = {
	.configure = lock_surface_configure,
};

/* ─── registry / globals ──────────────────────────────────────────── */

static void
registry_global(void *data __attribute__((unused)), struct wl_registry *reg,
                uint32_t name, const char *interface, uint32_t version __attribute__((unused)))
{
	if (strcmp(interface, wl_compositor_interface.name) == 0) {
		compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
	} else if (strcmp(interface, wl_shm_interface.name) == 0) {
		shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
	} else if (strcmp(interface, wl_seat_interface.name) == 0) {
		seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
		wl_seat_add_listener(seat, &seat_listener, NULL);
	} else if (strcmp(interface,
	                  ext_session_lock_manager_v1_interface.name) == 0) {
		lock_mgr = wl_registry_bind(reg, name,
			&ext_session_lock_manager_v1_interface, 1);
	} else if (strcmp(interface, wl_output_interface.name) == 0) {
		if (num_outputs < MAX_OUTPUTS) {
			outputs[num_outputs].wl_output = wl_registry_bind(
				reg, name, &wl_output_interface, 3);
			outputs[num_outputs].surface =
				wl_compositor_create_surface(compositor);
			outputs[num_outputs].configured = false;
			outputs[num_outputs].lock_surface = NULL;
			num_outputs++;
		}
	}
}

static void
registry_global_remove(void *data __attribute__((unused)), struct wl_registry *reg __attribute__((unused)), uint32_t name __attribute__((unused))) {}

static const struct wl_registry_listener registry_listener = {
	.global        = registry_global,
	.global_remove = registry_global_remove,
};

/* ─── main loop ───────────────────────────────────────────────────── */

static int
dispatch_loop(void)
{
	while (!finished) {
		struct pollfd fds[1];

		fds[0].fd = wl_display_get_fd(display);
		fds[0].events = POLLIN;
		fds[0].revents = 0;

		while (wl_display_prepare_read(display) != 0) {
			if (wl_display_dispatch_pending(display) < 0)
				return 1;
		}
		wl_display_flush(display);

		int ret = poll(fds, 1, -1);
		if (ret < 0) {
			wl_display_cancel_read(display);
			if (errno != EINTR) return 1;
			continue;
		}

		if (fds[0].revents & (POLLIN | POLLERR | POLLHUP)) {
			wl_display_read_events(display);
		} else {
			wl_display_cancel_read(display);
		}

		if (wl_display_dispatch_pending(display) < 0)
			return 1;
	}
	return 0;
}

/* ─── main ────────────────────────────────────────────────────────── */

int
main(int argc __attribute__((unused)), char **argv __attribute__((unused)))
{
	signal(SIGINT,  SIG_IGN);
	signal(SIGTERM, SIG_IGN);

	xkb_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
	if (!xkb_ctx) die("xkb_context_new");

	display = wl_display_connect(NULL);
	if (!display) die("cannot connect to Wayland display");


	registry = wl_display_get_registry(display);
	wl_registry_add_listener(registry, &registry_listener, NULL);
	wl_display_roundtrip(display);

	if (!compositor) die("no wl_compositor");
	if (!shm)        die("no wl_shm");
	if (!seat)       die("no wl_seat");
	if (!lock_mgr)   die("no ext_session_lock_manager_v1 — "
	                     "compositor does not support session lock");
	if (num_outputs == 0) die("no outputs found");

	/* request lock */
	session_lock = ext_session_lock_manager_v1_lock(lock_mgr);
	ext_session_lock_v1_add_listener(session_lock, &lock_listener, NULL);
	/* two round-trips: one for locked/finished event, one for configure */
	wl_display_roundtrip(display);

	if (finished) die("session lock denied by compositor");

	/* add lock surface listeners */
	for (int i = 0; i < num_outputs; i++) {
		if (outputs[i].lock_surface) {
			ext_session_lock_surface_v1_add_listener(
				outputs[i].lock_surface,
				&lock_surface_listener, &outputs[i]);
		}
	}
	wl_display_roundtrip(display);

	/* initial render */
	render_all();
	wl_display_flush(display);

	dispatch_loop();

	/* cleanup */
	for (int i = 0; i < num_outputs; i++) {
		if (outputs[i].lock_surface)
			ext_session_lock_surface_v1_destroy(outputs[i].lock_surface);
		if (outputs[i].surface)
			wl_surface_destroy(outputs[i].surface);
		if (outputs[i].wl_output)
			wl_output_destroy(outputs[i].wl_output);
	}
	if (keyboard)   wl_keyboard_destroy(keyboard);
	if (seat)       wl_seat_destroy(seat);
	if (shm)        wl_shm_destroy(shm);
	if (compositor) wl_compositor_destroy(compositor);
	if (lock_mgr)   ext_session_lock_manager_v1_destroy(lock_mgr);
	if (registry)   wl_registry_destroy(registry);
	wl_display_disconnect(display);

	if (xkb_state)  xkb_state_unref(xkb_state);
	if (xkb_keymap) xkb_keymap_unref(xkb_keymap);
	if (xkb_ctx)    xkb_context_unref(xkb_ctx);

	return 0;
}
