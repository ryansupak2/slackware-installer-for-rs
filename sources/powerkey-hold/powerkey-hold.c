/* powerkey-hold - the power button must be HELD to shut down
 *
 * Stage 1 (the installed setting is `-t 1.0`): start an orderly, Linux-based
 *         shutdown — runs `/sbin/shutdown -h now`, so services stop and the
 *         filesystems sync and unmount (Slackware's init 0 -> rc.6 path).
 * Stage 2 (default 10 s, DISABLED by the installer with `-T 0`): if you keep
 *         holding, cut the power for real — `/sbin/poweroff -f` after a
 *         sync(2), i.e. reboot(RB_POWER_OFF) without waiting for init. It is
 *         off here because the embedded controller hard-cuts power at ~5 s by
 *         itself, so a software stage after ~5 s could never fire: keeping the
 *         button held past 1 s is therefore the system/hardware fallback.
 * Anything shorter than stage 1 does nothing at all (the accidental-tap case).
 *
 * Stage 1 fires WHILE the button is held, not on release, so the hold can be
 * continued straight into the ~5 s hardware cut-off if the orderly path is
 * not wanted (it starts anyway, and stops when the power goes away).
 *
 *
 * The daemon ignores SIGTERM/SIGINT/SIGHUP/SIGPIPE on purpose: rc.6 stops
 * processes during a shutdown, and if this helper died then stage 2 would
 * never be reachable.
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
#include <sys/ioctl.h>
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

/* d_name comes from readdir (up to 256 bytes) but real names are "eventNN";
 * the truncation warnings are noise, the snprintf calls are bounded. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wformat-truncation"

/* Does this input device advertise KEY_POWER at all? */
static int has_power_key(int fd)
{
	unsigned long bits[(KEY_MAX / (8 * sizeof(unsigned long))) + 2] = { 0 };
	size_t n = sizeof(bits);

	if (ioctl(fd, EVIOCGBIT(EV_KEY, n), bits) < 0)
		return 0;
	return (bits[KEY_POWER / (8 * sizeof(unsigned long))] &
		(1UL << (KEY_POWER % (8 * sizeof(unsigned long))))) ? 1 : 0;
}

/* Open every input event device that reports KEY_POWER.
 *
 * Matching on the device NAME is wrong on this machine: the node called
 * "Power Button" is silent, while "Intel HID events" is the one that actually
 * delivers press/release pairs (measured 2026-11-09). Capability decides. */
#define MAX_DEVS 8
static int open_power_devices(char names[][64], int *fds, int max)
{
	DIR *d;
	struct dirent *de;
	int n = 0;

	d = opendir("/dev/input");
	if (!d)
		return 0;
	while ((de = readdir(d)) != NULL && n < max) {
		char path[320], comm[64];
		FILE *f;
		int fd;

		if (strncmp(de->d_name, "event", 5) != 0)
			continue;
		snprintf(path, sizeof(path), "/dev/input/%s", de->d_name);
		fd = open(path, O_RDONLY | O_NONBLOCK);
		if (fd < 0)
			continue;
		if (!has_power_key(fd)) {
			close(fd);
			continue;
		}
		snprintf(comm, sizeof(comm), "/sys/class/input/%s/device/name", de->d_name);
		f = fopen(comm, "r");
		if (f && fgets(names[n], 64, f))
			names[n][strcspn(names[n], "\n")] = '\0';
		else
			snprintf(names[n], 64, "%s", de->d_name);
		if (f)
			fclose(f);
		fds[n] = fd;
		n++;
	}
	closedir(d);
	return n;
}

#pragma GCC diagnostic pop

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
	char names[MAX_DEVS][64];
	int fds[MAX_DEVS];
	int ndev = 0, opt;
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

	if (dev) {
		int fd = open(dev, O_RDONLY | O_NONBLOCK);
		if (fd < 0) {
			logmsg("cannot open %s: %s", dev, strerror(errno));
			return 1;
		}
		fds[0] = fd;
		snprintf(names[0], sizeof(names[0]), "%s", dev);
		ndev = 1;
	} else {
		ndev = open_power_devices(names, fds, MAX_DEVS);
		if (ndev == 0) {
			logmsg("no input device advertising KEY_POWER found");
			return 1;
		}
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

	{
		char list[512] = "";
		int i;

		for (i = 0; i < ndev; i++)
			snprintf(list + strlen(list), sizeof(list) - strlen(list),
				 "%s%s", i ? ", " : "", names[i]);
		if (forceoff_s > 0.0)
			logmsg("watching %d device(s) [%s]: hold %.1f s = orderly shutdown, hold %.1f s = force power off, shorter = ignored%s",
			       ndev, list, shutdown_s, forceoff_s, dry_run ? " (dry run)" : "");
		else
			logmsg("watching %d device(s) [%s]: hold %.1f s = orderly shutdown, shorter = ignored, longer = hardware EC force off (~5 s)%s",
			       ndev, list, shutdown_s, dry_run ? " (dry run)" : "");
	}

	for (;;) {
		struct pollfd pfds[MAX_DEVS];
		int i, pr;

		for (i = 0; i < ndev; i++) {
			pfds[i].fd = fds[i];
			pfds[i].events = POLLIN;
			pfds[i].revents = 0;
		}
		/* Timers must run while the button is held and no events arrive, so
		 * poll() with a timeout rather than a blocking read(). */
		pr = poll(pfds, (nfds_t)ndev, 100);
		if (pr < 0) {
			if (errno == EINTR)
				continue;
			logmsg("poll error: %s", strerror(errno));
			return 1;
		}
		for (i = 0; i < ndev && pr > 0; i++) {
			struct input_event ev;
			ssize_t n;

			if (!(pfds[i].revents & (POLLIN | POLLERR | POLLHUP)))
				continue;
			n = read(fds[i], &ev, sizeof(ev));
			if (n < 0 && (errno == EAGAIN || errno == EINTR))
				continue;
			if (n != (ssize_t)sizeof(ev))
				continue;
			if (ev.type != EV_KEY || ev.code != KEY_POWER)
				continue;
			if (ev.value == 1) {
				if (is_down)
					continue;	/* one press at a time */
				is_down = 1;
				pressed_at = now_ms();
				shutdown_done = 0;
				forceoff_done = 0;
				if (verbose)
					logmsg("power button pressed (%s)", names[i]);
			} else if (ev.value == 0) {
				double held = is_down ? (now_ms() - pressed_at) / 1000.0 : 0.0;

				is_down = 0;
				if (!is_down && !shutdown_done && held > 0.0)
					logmsg("released after %.2f s (< %.1f s) ignored", held, shutdown_s);
				else if (shutdown_done)
					logmsg("released after %.2f s (shutdown already started)", held);
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
			logmsg("held %.1f s — starting orderly shutdown (/sbin/shutdown -h now)", shutdown_s);
			run("/sbin/shutdown", av);
		}
	}
}
