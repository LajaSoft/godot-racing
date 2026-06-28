#ifndef FFB_MANAGER_H
#define FFB_MANAGER_H

// Enumerates /dev/input/event* devices, reports which have force feedback,
// and opens them as FFBDevice. Knows the Moza (Gudsen) USB vendor id so it
// can find the wheel without the caller hard-coding an event path.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "ffb_device.h"

namespace godot {

class FFBManager : public RefCounted {
	GDCLASS(FFBManager, RefCounted)

public:
	static const int VENDOR_GUDSEN = 0x346e; // Moza Racing

protected:
	static void _bind_methods();

public:
	FFBManager();
	~FFBManager();

	// One Dictionary per /dev/input/event* node:
	//   path, name, vendor_id, product_id, has_ff (bool)
	Array list_devices();

	// Subset of list_devices() where has_ff is true.
	Array list_ffb_devices();

	Ref<FFBDevice> open_device(const String &path);

	// First force-feedback device whose vendor id is Gudsen/Moza. Empty Ref if none.
	Ref<FFBDevice> open_moza();
};

} // namespace godot

#endif // FFB_MANAGER_H
