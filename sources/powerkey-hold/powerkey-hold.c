/* powerkey-hold - power button needs a HOLD, in two stages
 *
 * Stage 1 (default 3 s): start an orderly shutdown — runs `/sbin/shutdown -h
 *         now`, so services stop, filesystems sync and unmount (Slackware's
 *         init 0 -> rc.6 path).
 * Stage 2 (default 10 s): if you keep holding, cut the power for real —
 *         `/sbin/poweroff -f` after a sync(2), i.e. reboot(RB_POWER_OFF)
 *         without waiting for init. This is the "shutdown is stuck" escape.
 * Anything shorter than stage 1 does nothing at all (the accidental-tap case).
 *
 * Both thresholds fire WHILE the button is held, not on release, so you can
 * hold straight through: shutdown at 3 s, power off at 10 s.
 *
 * The daemon ignores SIGTERM/SIGINT/SIGHUP/SIGPIPE on purpose: rc.6 stops
 * processes during a shutdown, and if this helper died then the 10 s escape
 * would never be reachable.
 *
 * elogind must be told not to act on the press (HandlePowerKey=ignore) and
 * acpid's `power) /sbin/init 0` handler must be neutralised — both are done by
 * steps/powerkey-hold.sh. Otherwise a tap powers the machine off before this
 * program can measure anything.
 *
 * Usage: powerkey-hold [-t SECONDS] [-T SECONDS] [-d /dev/input/eventN] [-n] [-v]
 *          -t  hold to start shutdown            (default 3)
 *          -T  hold to force power off           (default 10; 0 disables)
 *          -d  input device (default: the one named "Power Button")
 *          -n  dry run: report, never run anything
 *          -v  verbose
 */

#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <time.h>
#include <unistd.h>

#define PIDFILE "/run/powerkey-hold.pid"

static int verbose = 0;
static int dry_run = 0;

static void logmsg(const char *fmt, ...)
{
	va_list ap;
	time_t t = time(NULL);
	struct tm tm;

	localtime_r(&t, &tm);
	fprintf(stderr, "%04d-%02d-%02d %02d:%02d:%02d: ",
		tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
		tm.tm_hour, tm.tm_min, tm.tm_sec);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	fflush(stderr);
}

static double now_ms(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static int find_power_button(char *out, size_t outlen)
{
	DIR *d;
	struct dirent *de;
	int found = 0;

	d = opendir("/sys/class/input");
	if (!d)
		return -1;
	while ((de = readdir(d)) != NULL) {
		char path[300], name[128];
		FILE *f;

		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof(path), "/sys/class/input/%s/device/name", de->d_name);
		f = fopen(path, "r");
		if (!f)
			continue;
		if (!fgets(name, sizeof(name), f)) {
			fclose(f);
			continue;
		}
		fclose(f);
		name[strcspn(name, "\n")] = '\0';
		if (strcmp(name, "Power Button") == 0) {
			snprintf(out, outlen, "/dev/input/%s", de->d_name);
			found = 1;
			break;
		}
	}
	closedir(d);
	return found ? 0 : -1;
}

/* Run a command without ever returning into the caller's state machine. */
static void run(const char *path, char *const argv[])
{
	if (dry_run) {
		logmsg("dry run: would exec %s", path);
		return;
	}
	if (fork() == 0) {
		execv(path, argv);
		_exit(127);
	}
}

int main(int argc, char **argv)
{
	double shutdown_s = 3.0, forceoff_s = 10.0;
	const char *dev = NULL;
	char devbuf[300];
	int fd, opt;
	double pressed_at = 0.0;
	int is_down = 0, shutdown_done = 0, forceoff_done = 0;

	while ((opt = getopt(argc, argv, "t:T:d:nv")) != -1) {
		switch (opt) {
		case 't':
			shutdown_s = atof(optarg);
			if (shutdown_s <= 0.0) {
				fprintf(stderr, "powerkey-hold: -t must be > 0\n");
				return 2;
			}
			break;
		case 'T':
			forceoff_s = atof(optarg);
			break;
		case 'd':
			dev = optarg;
			break;
		case 'n':
			dry_run = 1;
			break;
		case 'v':
			verbose = 1;
			break;
		default:
			fprintf(stderr, "usage: powerkey-hold [-t s] [-T s] [-d dev] [-n] [-v]\n");
			return 2;
		}
	}

	if (!dev) {
		if (find_power_button(devbuf, sizeof(devbuf)) != 0) {
			logmsg("no input device named \"Power Button\" found");
			return 1;
		}
		dev = devbuf;
	}

	/* Survive the shutdown we ourselves start (rc.6 SIGTERMs everything),
	 * otherwise the 10 s force-off stage could never run. */
	signal(SIGTERM, SIG_IGN);
	signal(SIGINT, SIG_IGN);
	signal(SIGHUP, SIG_IGN);
	signal(SIGPIPE, SIG_IGN);

	/* Single instance. */
	int lockfd = open(PIDFILE, O_RDWR | O_CREAT, 0644);
	if (lockfd >= 0) {
		if (flock(lockfd, LOCK_EX | LOCK_NB) != 0) {
			logmsg("already running (lock held on %s) — exiting", PIDFILE);
			return 0;
		}
		if (ftruncate(lockfd, 0) == 0) {
			char buf[32];
			int n = snprintf(buf, sizeof(buf), "%ld\n", (long)getpid());
			if (write(lockfd, buf, (size_t)n) < 0 && verbose)
				logmsg("pidfile write failed: %s", strerror(errno));
		}
	}

	fd = open(dev, O_RDONLY);
	if (fd < 0) {
		logmsg("cannot open %s: %s", dev, strerror(errno));
		return 1;
	}

	logmsg("watching %s: hold %.0f s = orderly shutdown, hold %.0f s = force power off, shorter = ignored%s",
	       dev, shutdown_s, forceoff_s, dry_run ? " (dry run)" : "");

	for (;;) {
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		struct input_event ev;
		ssize_t n;
		int pr;

		/* Timers must also run while the button is held and no events arrive,
		 * hence poll() with a timeout instead of a blocking read(). */
		pr = poll(&pfd, 1, 100);
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			logmsg("poll error: %s", strerror(errno));
			return 1;
		}

		if (pr > 0) {
			n = read(fd, &ev, sizeof(ev));
			if (n == (ssize_t)sizeof(ev) && ev.type == EV_KEY && ev.code == KEY_POWER) {
				if (ev.value == 1) {
					is_down = 1;
					pressed_at = now_ms();
					shutdown_done = 0;
					forceoff_done = 0;
					if (verbose)
						logmsg("power button pressed");
				} else if (ev.value == 0) {
					double held = is_down ? (now_ms() - pressed_at) / 1000.0 : 0.0;

					is_down = 0;
					if (!shutdown_done)
						logmsg("released after %.2f s (< %.0f s) ignored",
						       held, shutdown_s);
					else
						logmsg("released after %.2f s (shutdown already started)", held);
				}
			}
		}

		if (!is_down)
			continue;

		double held = (now_ms() - pressed_at) / 1000.0;

		if (forceoff_s > 0 && !forceoff_done && held >= forceoff_s) {
			char *const av[] = { "/sbin/poweroff", "-f", NULL };
			forceoff_done = 1;
			logmsg("held %.0f s — FORCE power off now", forceoff_s);
			sync();
			run("/sbin/poweroff", av);
		} else if (!shutdown_done && held >= shutdown_s) {
			char *const av[] = { "/sbin/shutdown", "-h", "now", NULL };
			shutdown_done = 1;
			logmsg("held %.0f s — starting orderly shutdown (/sbin/shutdown -h now)", shutdown_s);
			run("/sbin/shutdown", av);
		}
	}
}
