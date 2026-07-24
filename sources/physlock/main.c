/* Copyright 2013 Bert Muennich
 *
 * This file is part of physlock.
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by the
 * Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.
 */

#include "physlock.h"
#include "config.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <pwd.h>
#include <signal.h>
#include <termios.h>

static int oldvt;
static vt_t vt;
static int oldsysrq;
static int oldprintk;
static pid_t chpid;
static int locked;
static userinfo_t root, user;

/* ─── PAM conversation with asterisk feedback ─────────────────── */
#define MAX_PW_LEN 256

static int
pam_conv_fn(int num_msg, const struct pam_message **msg,
            struct pam_response **resp, void *appdata)
{
	(void)appdata;
	struct termios old_term, new_term;
	char password[MAX_PW_LEN + 1];
	int pw_len = 0;
	char c;

	if (num_msg <= 0 || num_msg > PAM_MAX_NUM_MSG)
		return PAM_CONV_ERR;

	struct pam_response *r = calloc(num_msg, sizeof(struct pam_response));
	if (!r) return PAM_BUF_ERR;

	for (int i = 0; i < num_msg; i++) {
		if (msg[i]->msg_style == PAM_PROMPT_ECHO_OFF) {
			/* Print prompt using raw write (fd 1 is the VT) */
			if (msg[i]->msg) {
				const char *p = msg[i]->msg;
				write(1, p, strlen(p));
			}

			/* Save terminal attrs, switch to raw/no-echo */
			if (tcgetattr(0, &old_term) == -1) {
				free(r);
				return PAM_CONV_ERR;
			}
			new_term = old_term;
			new_term.c_lflag &= ~(ECHO | ICANON | ISIG);
			new_term.c_cc[VMIN] = 1;
			new_term.c_cc[VTIME] = 0;
			tcsetattr(0, TCSAFLUSH, &new_term);

			/* Read password char by char, echo asterisks */
			pw_len = 0;
			while (pw_len < MAX_PW_LEN) {
				if (read(0, &c, 1) != 1) break;
				if (c == '\n' || c == '\r') {
					break;
				} else if (c == 127 || c == '\b') {
					if (pw_len > 0) {
						pw_len--;
						write(1, "\b \b", 3);
					}
				} else if (c == 21) {
					/* Ctrl-U: clear all asterisks */
					while (pw_len > 0) {
						pw_len--;
						write(1, "\b \b", 3);
					}
				} else if (c >= 32) {
					password[pw_len++] = c;
					write(1, "*", 1);
				}
			}
			password[pw_len] = '\0';

			/* Restore terminal and print newline */
			tcsetattr(0, TCSAFLUSH, &old_term);
			write(1, "\n", 1);

			r[i].resp = strdup(password);
			if (!r[i].resp) {
				free(r);
				return PAM_BUF_ERR;
			}
		} else if (msg[i]->msg_style == PAM_PROMPT_ECHO_ON) {
			if (msg[i]->msg)
				write(1, msg[i]->msg, strlen(msg[i]->msg));
			char buf[256];
			ssize_t n = read(0, buf, sizeof(buf) - 1);
			if (n > 0) {
				buf[n] = '\0';
				r[i].resp = strdup(buf);
			}
		} else if (msg[i]->msg_style == PAM_TEXT_INFO) {
			if (msg[i]->msg) {
				write(1, msg[i]->msg, strlen(msg[i]->msg));
				write(1, "\n", 1);
			}
		} else if (msg[i]->msg_style == PAM_ERROR_MSG) {
			if (msg[i]->msg) {
				write(1, msg[i]->msg, strlen(msg[i]->msg));
				write(1, "\n", 1);
			}
		}
	}
	*resp = r;
	return PAM_SUCCESS;
}

static struct pam_conv conv = {
	pam_conv_fn,
	NULL
};

static void get_pam(userinfo_t *uinfo) {
	if (pam_start("physlock", uinfo->name, &conv, &uinfo->pamh) != PAM_SUCCESS)
		error(EXIT_FAILURE, 0, "No pam for user %s", uinfo->name);
}

void get_user_by_id(userinfo_t *uinfo, uid_t uid) {
	struct passwd *pw;

	while (errno = 0, (pw = getpwuid(uid)) == NULL && errno == EINTR);
	if (pw == NULL)
		error(EXIT_FAILURE, 0, "No password file entry for uid %u found", uid);

	get_user_by_name(uinfo, pw->pw_name);
}

void get_user_by_name(userinfo_t *uinfo, const char *name) {
	uinfo->name = estrdup(name);
	get_pam(uinfo);
}

CLEANUP void free_user(userinfo_t *uinfo) {
	if (uinfo->pamh != NULL)
		pam_end(uinfo->pamh, uinfo->pam_status);
}

void cleanup() {
	if (options->detach && chpid > 0)
		/* No cleanup in parent after successful fork */
		return;
	free_user(&user);
	free_user(&root);
	close(0);
	close(1);
	close(2);
	if (oldprintk > 1)
		write_int_to_file(PRINTK_PATH, oldprintk);
	/* Always restore TTY state and VT switching, even if we are
	 * exiting early due to a PAM error (locked still set).
	 * Skipping VT restoration is what causes the permanent
	 * softlock that requires a hard reboot. */
	if (vt.fd >= 0)
		vt_reset(&vt);
	vt_lock_switch(0);
	vt_release(&vt, oldvt);
	vt_destroy();
	if (oldsysrq > 0)
		write_int_to_file(SYSRQ_PATH, oldsysrq);
}

void sa_handler_exit(int signum) {
	exit(0);
}

void setup_signal(int signum, void (*handler)(int)) {
	struct sigaction sigact;

	sigact.sa_flags = 0;
	sigact.sa_handler = handler;
	sigemptyset(&sigact.sa_mask);
	
	if (sigaction(signum, &sigact, NULL) < 0)
		error(0, errno, "signal %d", signum);
}

int main(int argc, char **argv) {
	int try = 0, root_user = 1;
	uid_t owner;
	userinfo_t *u = &user;

	oldvt = oldsysrq = oldprintk = vt.nr = vt.fd = -1;
	vt.ios = NULL;

	error_init(2);
	parse_options(argc, argv);

	if (geteuid() != 0)
		error(EXIT_FAILURE, 0, "Must be root!");

	setup_signal(SIGTERM, sa_handler_exit);
	setup_signal(SIGQUIT, sa_handler_exit);
	setup_signal(SIGHUP, SIG_IGN);
	setup_signal(SIGINT, SIG_IGN);
	setup_signal(SIGUSR1, SIG_IGN);
	setup_signal(SIGUSR2, SIG_IGN);

	vt_init();
	vt_get_current(&oldvt, &owner);

	if (options->lock_switch != -1) {
		if (vt_lock_switch(options->lock_switch) == -1)
			exit(EXIT_FAILURE);
		vt_destroy();
		return 0;
	}

	if (get_user_logind(&user, oldvt) == -1 && get_user_utmp(&user, oldvt) == -1)
		get_user_by_id(&user, owner);
	get_user_by_id(&root, 0);
	if (strcmp(user.name, root.name) != 0)
		root_user = 0;
	else
		u = &root;

	atexit(cleanup);

	if (options->disable_sysrq) {
		oldsysrq = read_int_from_file(SYSRQ_PATH, '\n');
		if (oldsysrq > 0)
			if (write_int_to_file(SYSRQ_PATH, 0) == -1)
				exit(EXIT_FAILURE);
	}

	if (options->mute_kernel_messages) {
		oldprintk = read_int_from_file(PRINTK_PATH, '\t');
		if (oldprintk > 1)
			if (write_int_to_file(PRINTK_PATH, 1) == -1)
				exit(EXIT_FAILURE);
	}

	vt_lock_switch(0);
	vt_acquire(&vt);
	vt_lock_switch(1);

	if (options->detach) {
		chpid = fork();
		if (chpid < 0) {
			error(EXIT_FAILURE, errno, "fork");
		} else if (chpid > 0) {
			return 0;
		} else {
			setsid();
			sleep(1); /* w/o this, accessing the vt might fail */
			vt_reopen(&vt);
		}
	}
	vt_secure(&vt);

	dup2(vt.fd, 0);
	dup2(vt.fd, 1);
	dup2(vt.fd, 2);

	if (options->prompt != NULL && options->prompt[0] != '\0') {
		fprintf(vt.ios, "%s\n\n", options->prompt);
	}

	locked = 1;

	while (locked) {
		if (!root_user && try >= (u == &root ? 1 : 3)) {
			/* Reset failed user's PAM handle before switching */
			pam_end(u->pamh, u->pam_status);
			get_pam(u == &root ? &user : &root);
			u = u == &root ? &user : &root;
			try = 0;
		}
		u->pam_status = pam_authenticate(u->pamh, 0);
		switch (u->pam_status) {
		case PAM_SUCCESS:
			pam_setcred(u->pamh, PAM_REFRESH_CRED);
			locked = 0;
			break;
		case PAM_AUTH_ERR:
		case PAM_MAXTRIES:
			fprintf(vt.ios, "Authentication failed\n\n");
			fflush(vt.ios);
			try++;
			/* Reinitialize PAM handle for clean retry */
			pam_end(u->pamh, u->pam_status);
			get_pam(u);
			break;
		case PAM_ABORT:
		case PAM_CRED_INSUFFICIENT:
		case PAM_USER_UNKNOWN:
			fprintf(vt.ios, "%s\n", pam_strerror(u->pamh, u->pam_status));
			fflush(vt.ios);
			/* Exit cleanly — cleanup() will restore TTY and VT */
			return EXIT_FAILURE;
		default:
			fprintf(vt.ios, "Unexpected PAM error, retrying...\n");
			fflush(vt.ios);
			sleep(2);
			/* Reinitialize PAM handle for clean retry */
			pam_end(u->pamh, u->pam_status);
			get_pam(u);
			break;
		}
	}

	return 0;
}

