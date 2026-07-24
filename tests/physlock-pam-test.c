/*
 * tests/physlock-pam-test.c
 *
 * Tests the physlock PAM conversation function in isolation.
 * Uses the same raw read()/write() conversation as physlock's main.c.
 * Does NOT switch VTs — safe to run in any terminal.
 *
 * Build: gcc -o physlock-pam-test physlock-pam-test.c -lpam
 * Run:   ./physlock-pam-test           (prompts for password)
 *        echo "mypass" | ./physlock-pam-test   (pipe password)
 */

#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define MAX_PW_LEN 256

/* ─── Same PAM conversation function as physlock main.c ─────── */

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
			/* Print prompt using raw write */
			if (msg[i]->msg) {
				const char *p = msg[i]->msg;
				write(1, p, strlen(p));
			}

			/* Save terminal, switch to raw/no-echo */
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
					/* Ctrl-U: clear all */
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

			/* Restore terminal, print newline */
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

/* ─── Main test ─────────────────────────────────────────────────── */

int main(void) {
	struct pam_conv conv = { pam_conv_fn, NULL };
	pam_handle_t *ph = NULL;
	int ret;

	printf("=== physlock PAM conversation test ===\n");
	printf("This tests the same conversation function used by physlock.\n");
	printf("Uses raw read()/write() — same as the VT path.\n\n");

	ret = pam_start("physlock", getenv("USER") ? getenv("USER") : "root",
	                &conv, &ph);
	if (ret != PAM_SUCCESS) {
		fprintf(stderr, "FAIL: pam_start returned %d (%s)\n",
		        ret, pam_strerror(ph, ret));
		return 1;
	}

	ret = pam_authenticate(ph, 0);
	if (ret == PAM_SUCCESS) {
		printf("PASS: pam_authenticate succeeded\n");
		pam_end(ph, ret);
		return 0;
	} else {
		fprintf(stderr, "FAIL: pam_authenticate returned %d (%s)\n",
		        ret, pam_strerror(ph, ret));
		pam_end(ph, ret);
		return 1;
	}
}
