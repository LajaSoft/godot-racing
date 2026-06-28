/* ffbtest — drive a force-feedback wheel through a short scripted sequence so
 * you can physically feel that FFB works. No Godot required.
 *
 *   gcc -O2 -o ffbtest ffbtest.c
 *   ./ffbtest                 # auto-find a Moza (Gudsen 0x346e) wheel
 *   ./ffbtest /dev/input/eventN
 *
 * WARNING: the wheel will turn on its own. Keep hands clear / hold it lightly.
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define VENDOR_GUDSEN 0x346e

#define BITS_PER_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_PER_LONG - 1) / BITS_PER_LONG)
static int test_bit(int bit, const unsigned long *arr) {
	return (arr[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1UL;
}

static void msleep(int ms) {
	struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
	nanosleep(&ts, NULL);
}

static int has_constant_ff(int fd) {
	unsigned long ff[NLONGS(FF_CNT)];
	memset(ff, 0, sizeof(ff));
	if (ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff)), ff) < 0) return 0;
	return test_bit(FF_CONSTANT, ff);
}

/* Find the first Moza wheel event node. Returns malloc'd path or NULL. */
static char *find_moza(void) {
	DIR *dir = opendir("/dev/input");
	if (!dir) return NULL;
	struct dirent *e;
	char *found = NULL;
	while ((e = readdir(dir)) != NULL) {
		if (strncmp(e->d_name, "event", 5) != 0) continue;
		char path[300];
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		int fd = open(path, O_RDONLY);
		if (fd < 0) continue;
		struct input_id id;
		memset(&id, 0, sizeof(id));
		ioctl(fd, EVIOCGID, &id);
		int ok = (id.vendor == VENDOR_GUDSEN) && has_constant_ff(fd);
		close(fd);
		if (ok) { found = strdup(path); break; }
	}
	closedir(dir);
	return found;
}

static void play(int fd, int id, int value) {
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.code = id;
	ev.value = value;
	if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev))
		perror("write play");
}

static void set_ctl(int fd, int code, int value) { /* FF_GAIN / FF_AUTOCENTER */
	struct input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.code = code;
	ev.value = value;
	if (write(fd, &ev, sizeof(ev)) != (ssize_t)sizeof(ev))
		perror("write ctl");
}

int main(int argc, char **argv) {
	char *path = NULL;
	if (argc > 1) {
		path = strdup(argv[1]);
	} else {
		path = find_moza();
		if (!path) {
			fprintf(stderr, "No Moza (0x346e) FFB wheel found. Pass an event path explicitly.\n");
			return 1;
		}
	}

	int fd = open(path, O_RDWR);
	if (fd < 0) {
		perror("open");
		fprintf(stderr, "Need read/write on %s (install udev/99-moza-ffb.rules or run as root).\n", path);
		return 1;
	}

	char name[256] = {0};
	ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
	printf("Device: %s (%s)\n", name, path);
	if (!has_constant_ff(fd)) {
		fprintf(stderr, "This device has no FF_CONSTANT. Aborting.\n");
		return 1;
	}

	set_ctl(fd, FF_GAIN, 0xFFFF); /* full gain */

	/* --- 1. constant force, right then left --- */
	struct ff_effect c;
	memset(&c, 0, sizeof(c));
	c.type = FF_CONSTANT;
	c.id = -1;
	c.direction = 0x4000;
	c.u.constant.level = 0;
	c.replay.length = 0; /* infinite until stopped */
	if (ioctl(fd, EVIOCSFF, &c) < 0) { perror("EVIOCSFF constant"); return 1; }
	play(fd, c.id, 1);

	/* Moza R3 reports forces with the opposite sign to the conventional one:
	 * a positive level pushes LEFT. So negative = right here. */
	printf("constant force: RIGHT (40%%) ...\n");
	c.u.constant.level = -13000;
	ioctl(fd, EVIOCSFF, &c);
	msleep(1200);

	printf("constant force: LEFT (40%%) ...\n");
	c.u.constant.level = 13000;
	ioctl(fd, EVIOCSFF, &c);
	msleep(1200);

	printf("constant force: off\n");
	c.u.constant.level = 0;
	ioctl(fd, EVIOCSFF, &c);
	play(fd, c.id, 0);
	ioctl(fd, EVIOCRMFF, c.id);
	msleep(300);

	/* --- 2. spring (centering) --- */
	struct ff_effect s;
	memset(&s, 0, sizeof(s));
	s.type = FF_SPRING;
	s.id = -1;
	s.replay.length = 0;
	for (int i = 0; i < 2; i++) {
		s.u.condition[i].right_coeff = 0x4000;
		s.u.condition[i].left_coeff = 0x4000;
		s.u.condition[i].right_saturation = 0xFFFF;
		s.u.condition[i].left_saturation = 0xFFFF;
		s.u.condition[i].center = 0;
		s.u.condition[i].deadband = 0;
	}
	if (ioctl(fd, EVIOCSFF, &s) >= 0) {
		printf("spring (self-centering) for 3s — try to turn the wheel ...\n");
		play(fd, s.id, 1);
		msleep(3000);
		play(fd, s.id, 0);
		ioctl(fd, EVIOCRMFF, s.id);
	} else {
		printf("(device has no spring effect, skipping)\n");
	}
	msleep(300);

	/* --- 3. sine vibration --- */
	struct ff_effect p;
	memset(&p, 0, sizeof(p));
	p.type = FF_PERIODIC;
	p.id = -1;
	p.direction = 0x4000;
	p.u.periodic.waveform = FF_SINE;
	p.u.periodic.period = 60;       /* ms */
	p.u.periodic.magnitude = 12000;
	p.u.periodic.offset = 0;
	p.u.periodic.phase = 0;
	p.replay.length = 2000;
	if (ioctl(fd, EVIOCSFF, &p) >= 0) {
		printf("sine vibration for 2s ...\n");
		play(fd, p.id, 1);
		msleep(2000);
		ioctl(fd, EVIOCRMFF, p.id);
	} else {
		printf("(device has no periodic effect, skipping)\n");
	}

	printf("done.\n");
	close(fd);
	free(path);
	return 0;
}
