#ifndef FFB_DEVICE_H
#define FFB_DEVICE_H

// One Linux evdev device with force-feedback. Talks to /dev/input/eventN
// directly via the kernel Force Feedback API (ioctl EVIOCSFF, EV_FF events).
// Handles both directions:
//   - reading:  axes (EV_ABS) + buttons (EV_KEY) via non-blocking poll()
//   - writing:  constant force, condition effects (spring/damper/friction),
//               periodic, ramp, rumble, plus global gain / autocenter.

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <linux/input.h>
#include <unordered_map>

namespace godot {

class FFBDevice : public RefCounted {
	GDCLASS(FFBDevice, RefCounted)

public:
	// Periodic waveforms (mirror of kernel FF_* codes), exposed to GDScript.
	enum Waveform {
		WAVE_SINE = 0,
		WAVE_SQUARE,
		WAVE_TRIANGLE,
		WAVE_SAW_UP,
		WAVE_SAW_DOWN,
	};

private:
	int fd = -1;
	String device_name;
	int vendor_id = 0;
	int product_id = 0;
	int version_id = 0;
	int max_effects = 0;

	// Cached at open(): which abs axes exist + their ranges.
	std::unordered_map<int, input_absinfo> abs_info;
	// Live state, updated by poll().
	std::unordered_map<int, int> axis_values;
	std::unordered_map<int, int> button_values;

	// Every uploaded effect, keyed by the kernel-assigned id. Kept so we can
	// update a live effect (e.g. the constant force every physics frame).
	std::unordered_map<int, ff_effect> effects;
	int constant_id = -1; // managed constant-force slot, -1 = not started

	bool invert = false; // some wheels (e.g. Moza R3) flip constant-force sign
	// cached EV_FF capability bits, read at open(), used to guard unsupported ops
	unsigned long ff_bits[(FF_CNT + (sizeof(unsigned long) * 8) - 1) / (sizeof(unsigned long) * 8)] = {};

	bool write_ff_event(int code, int value);
	int upload(ff_effect &e); // EVIOCSFF, returns id or -1
	bool has_feature(int feature) const; // test an FF_* capability bit
	static int direction_to_u16(double degrees);

protected:
	static void _bind_methods();

public:
	FFBDevice();
	~FFBDevice();

	// --- lifecycle ---
	bool open(const String &path);
	void close();
	bool is_open() const;

	// --- identity / capabilities ---
	String get_device_name() const;
	int get_vendor_id() const;
	int get_product_id() const;
	int get_num_effects() const;
	Dictionary get_capabilities();

	// --- input (call poll() once per frame, then read getters) ---
	void poll();
	Array get_axes();
	Dictionary get_abs_info(int code);
	int get_axis_raw(int code);
	float get_axis_normalized(int code); // [0,1] across [min,max]
	float get_axis_centered(int code);   // [-1,1], rest at 0 for a centered axis
	bool is_button_pressed(int code);

	// --- global tuning ---
	void set_gain(float gain);             // 0..1
	void set_autocenter(float strength);   // 0..1 (kernel-side centering spring; ignored if unsupported)

	// Flip constant-force direction for this wheel. The Moza R3 reports forces
	// with the opposite sign to the conventional one, so set this true on it.
	void set_inverted(bool inverted);
	bool is_inverted() const;

	// --- managed constant force (the main sim-racing path) ---
	bool start_constant_force();
	void update_constant_force(float level); // [-1,1], updates the live effect
	void stop_constant_force();

	// --- generic effect creation (return effect id, -1 on failure) ---
	int upload_constant(float level, float direction_deg, float duration_s);
	int upload_spring(float center, float coeff, float saturation, float deadband);
	int upload_damper(float coeff, float saturation);
	int upload_friction(float coeff, float saturation);
	int upload_periodic(int waveform, float magnitude, float offset, int period_ms,
			float direction_deg, int duration_ms, int attack_ms, int fade_ms);
	int upload_ramp(float start_level, float end_level, float direction_deg, int duration_ms);
	int upload_rumble(float strong, float weak, int duration_ms);

	// --- playback control ---
	void play_effect(int id, int count);
	void stop_effect(int id);
	void update_constant(int id, float level); // change a constant effect's level by id
	void erase_effect(int id);
	void stop_all();
};

} // namespace godot

VARIANT_ENUM_CAST(FFBDevice::Waveform);

#endif // FFB_DEVICE_H
