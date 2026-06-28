#include "ffb_manager.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <dirent.h>
#include <linux/input.h>
#include <cstring>

using namespace godot;

#define FFB_BITS_PER_LONG (sizeof(long) * 8)
#define FFB_NLONGS(x) (((x) + FFB_BITS_PER_LONG - 1) / FFB_BITS_PER_LONG)
static inline bool ffb_test_bit(int bit, const unsigned long *arr) {
	return (arr[bit / FFB_BITS_PER_LONG] >> (bit % FFB_BITS_PER_LONG)) & 1UL;
}

FFBManager::FFBManager() {}
FFBManager::~FFBManager() {}

static bool probe_device(const String &path, Dictionary &out) {
	int fd = ::open(path.utf8().get_data(), O_RDONLY);
	if (fd < 0) return false; // unreadable node, skip silently

	char name[256] = {0};
	ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name);

	input_id id;
	memset(&id, 0, sizeof(id));
	ioctl(fd, EVIOCGID, &id);

	unsigned long ff[FFB_NLONGS(FF_CNT)];
	memset(ff, 0, sizeof(ff));
	bool has_ff = false;
	if (ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff)), ff) >= 0) {
		// FF_CONSTANT..FF_RUMBLE are the actual effect bits; bits above are
		// FF_GAIN/FF_AUTOCENTER properties. Treat "has any effect" as FFB.
		has_ff = ffb_test_bit(FF_CONSTANT, ff) || ffb_test_bit(FF_PERIODIC, ff) ||
				ffb_test_bit(FF_SPRING, ff) || ffb_test_bit(FF_DAMPER, ff) ||
				ffb_test_bit(FF_FRICTION, ff) || ffb_test_bit(FF_RUMBLE, ff) ||
				ffb_test_bit(FF_RAMP, ff) || ffb_test_bit(FF_INERTIA, ff);
	}
	::close(fd);

	out["path"] = path;
	out["name"] = String(name);
	out["vendor_id"] = (int)id.vendor;
	out["product_id"] = (int)id.product;
	out["has_ff"] = has_ff;
	return true;
}

Array FFBManager::list_devices() {
	Array result;
	DIR *dir = opendir("/dev/input");
	if (!dir) {
		UtilityFunctions::push_error("FFBManager: cannot open /dev/input");
		return result;
	}
	struct dirent *ent;
	while ((ent = readdir(dir)) != nullptr) {
		if (strncmp(ent->d_name, "event", 5) != 0) continue;
		String path = String("/dev/input/") + String(ent->d_name);
		Dictionary d;
		if (probe_device(path, d)) result.push_back(d);
	}
	closedir(dir);
	return result;
}

Array FFBManager::list_ffb_devices() {
	Array all = list_devices();
	Array result;
	for (int i = 0; i < all.size(); i++) {
		Dictionary d = all[i];
		if ((bool)d["has_ff"]) result.push_back(d);
	}
	return result;
}

Ref<FFBDevice> FFBManager::open_device(const String &path) {
	Ref<FFBDevice> dev;
	dev.instantiate();
	if (!dev->open(path)) return Ref<FFBDevice>();
	return dev;
}

Ref<FFBDevice> FFBManager::open_moza() {
	Array devs = list_ffb_devices();
	for (int i = 0; i < devs.size(); i++) {
		Dictionary d = devs[i];
		if ((int)d["vendor_id"] == VENDOR_GUDSEN) {
			return open_device((String)d["path"]);
		}
	}
	UtilityFunctions::push_error("FFBManager: no Moza (Gudsen 0x346e) force-feedback device found");
	return Ref<FFBDevice>();
}

void FFBManager::_bind_methods() {
	ClassDB::bind_method(D_METHOD("list_devices"), &FFBManager::list_devices);
	ClassDB::bind_method(D_METHOD("list_ffb_devices"), &FFBManager::list_ffb_devices);
	ClassDB::bind_method(D_METHOD("open_device", "path"), &FFBManager::open_device);
	ClassDB::bind_method(D_METHOD("open_moza"), &FFBManager::open_moza);
}
