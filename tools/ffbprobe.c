/* ffbprobe — list /dev/input/event* devices, their USB ids, force-feedback
 * capabilities and absolute axes. No Godot required.
 *
 *   gcc -O2 -o ffbprobe ffbprobe.c
 *   ./ffbprobe
 */
#include <dirent.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>

#define BITS_PER_LONG (sizeof(long) * 8)
#define NLONGS(x) (((x) + BITS_PER_LONG - 1) / BITS_PER_LONG)
static int test_bit(int bit, const unsigned long *arr) {
	return (arr[bit / BITS_PER_LONG] >> (bit % BITS_PER_LONG)) & 1UL;
}

static const char *abs_name(int code) {
	switch (code) {
		case ABS_X: return "ABS_X";
		case ABS_Y: return "ABS_Y";
		case ABS_Z: return "ABS_Z";
		case ABS_RX: return "ABS_RX";
		case ABS_RY: return "ABS_RY";
		case ABS_RZ: return "ABS_RZ";
		case ABS_THROTTLE: return "ABS_THROTTLE";
		case ABS_RUDDER: return "ABS_RUDDER";
		case ABS_WHEEL: return "ABS_WHEEL";
		case ABS_GAS: return "ABS_GAS";
		case ABS_BRAKE: return "ABS_BRAKE";
		case ABS_HAT0X: return "ABS_HAT0X";
		case ABS_HAT0Y: return "ABS_HAT0Y";
		default: return "ABS_?";
	}
}

static void probe(const char *path) {
	int fd = open(path, O_RDONLY);
	if (fd < 0) return;

	char name[256] = {0};
	ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);
	struct input_id id;
	memset(&id, 0, sizeof(id));
	ioctl(fd, EVIOCGID, &id);

	unsigned long ff[NLONGS(FF_CNT)];
	memset(ff, 0, sizeof(ff));
	int has_ff_ioctl = ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff)), ff) >= 0;

	int effects = 0;
	ioctl(fd, EVIOCGEFFECTS, &effects);

	int has_ff = has_ff_ioctl && (test_bit(FF_CONSTANT, ff) || test_bit(FF_PERIODIC, ff) ||
			test_bit(FF_SPRING, ff) || test_bit(FF_DAMPER, ff) || test_bit(FF_RUMBLE, ff) ||
			test_bit(FF_FRICTION, ff) || test_bit(FF_RAMP, ff) || test_bit(FF_INERTIA, ff));

	printf("%-20s  %04x:%04x  %s%s\n", path, id.vendor, id.product, name,
			has_ff ? "   [FORCE FEEDBACK]" : "");

	if (has_ff) {
		printf("    effects(max %d):", effects);
		if (test_bit(FF_CONSTANT, ff)) printf(" constant");
		if (test_bit(FF_PERIODIC, ff)) printf(" periodic");
		if (test_bit(FF_SPRING, ff)) printf(" spring");
		if (test_bit(FF_DAMPER, ff)) printf(" damper");
		if (test_bit(FF_FRICTION, ff)) printf(" friction");
		if (test_bit(FF_INERTIA, ff)) printf(" inertia");
		if (test_bit(FF_RAMP, ff)) printf(" ramp");
		if (test_bit(FF_RUMBLE, ff)) printf(" rumble");
		if (test_bit(FF_GAIN, ff)) printf(" +gain");
		if (test_bit(FF_AUTOCENTER, ff)) printf(" +autocenter");
		printf("\n");

		unsigned long absb[NLONGS(ABS_CNT)];
		memset(absb, 0, sizeof(absb));
		if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absb)), absb) >= 0) {
			printf("    axes:");
			for (int c = 0; c < ABS_CNT; c++) {
				if (!test_bit(c, absb)) continue;
				struct input_absinfo ai;
				if (ioctl(fd, EVIOCGABS(c), &ai) < 0) continue;
				printf(" %s[%d..%d]", abs_name(c), ai.minimum, ai.maximum);
			}
			printf("\n");
		}
	}
	close(fd);
}

int main(void) {
	DIR *dir = opendir("/dev/input");
	if (!dir) {
		perror("opendir /dev/input");
		return 1;
	}
	struct dirent *e;
	while ((e = readdir(dir)) != NULL) {
		if (strncmp(e->d_name, "event", 5) != 0) continue;
		char path[300];
		snprintf(path, sizeof(path), "/dev/input/%s", e->d_name);
		probe(path);
	}
	closedir(dir);
	return 0;
}
