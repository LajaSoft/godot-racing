#include "ffb_device.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <cstring>
#include <cerrno>
#include <cmath>
#include <vector>

using namespace godot;

// --- bit-test helpers for EVIOCGBIT results ---
#define FFB_BITS_PER_LONG (sizeof(long) * 8)
#define FFB_NLONGS(x) (((x) + FFB_BITS_PER_LONG - 1) / FFB_BITS_PER_LONG)
static inline bool ffb_test_bit(int bit, const unsigned long *arr) {
	return (arr[bit / FFB_BITS_PER_LONG] >> (bit % FFB_BITS_PER_LONG)) & 1UL;
}

static inline int clamp_i(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

FFBDevice::FFBDevice() {}

FFBDevice::~FFBDevice() { close(); }

int FFBDevice::direction_to_u16(double degrees) {
	// Kernel direction is 0..0xFFFF over a full circle.
	double d = fmod(degrees, 360.0);
	if (d < 0) d += 360.0;
	return (int)(d / 360.0 * 65536.0) & 0xFFFF;
}

bool FFBDevice::write_ff_event(int code, int value) {
	if (fd < 0) return false;
	input_event ev;
	memset(&ev, 0, sizeof(ev));
	ev.type = EV_FF;
	ev.code = code;
	ev.value = value;
	ssize_t n = ::write(fd, &ev, sizeof(ev));
	if (n != (ssize_t)sizeof(ev)) {
		UtilityFunctions::push_error("FFBDevice: write EV_FF failed: ", strerror(errno));
		return false;
	}
	return true;
}

int FFBDevice::upload(ff_effect &e) {
	if (fd < 0) return -1;
	if (ioctl(fd, EVIOCSFF, &e) < 0) {
		UtilityFunctions::push_error("FFBDevice: EVIOCSFF failed: ", strerror(errno));
		return -1;
	}
	effects[e.id] = e;
	return e.id;
}

// ----------------------------------------------------------------------------
// lifecycle
// ----------------------------------------------------------------------------
bool FFBDevice::open(const String &path) {
	close();
	int f = ::open(path.utf8().get_data(), O_RDWR | O_NONBLOCK);
	if (f < 0) {
		UtilityFunctions::push_error("FFBDevice: cannot open ", path, ": ", strerror(errno));
		return false;
	}
	fd = f;

	char name[256] = {0};
	if (ioctl(fd, EVIOCGNAME(sizeof(name) - 1), name) >= 0) {
		device_name = String(name);
	}
	input_id id;
	memset(&id, 0, sizeof(id));
	if (ioctl(fd, EVIOCGID, &id) >= 0) {
		vendor_id = id.vendor;
		product_id = id.product;
		version_id = id.version;
	}
	max_effects = 0;
	ioctl(fd, EVIOCGEFFECTS, &max_effects);

	// Cache which FF effects this device supports.
	memset(ff_bits, 0, sizeof(ff_bits));
	ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ff_bits)), ff_bits);

	// Cache absinfo for every abs axis the device reports.
	unsigned long absbits[FFB_NLONGS(ABS_CNT)];
	memset(absbits, 0, sizeof(absbits));
	if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) >= 0) {
		for (int code = 0; code < ABS_CNT; code++) {
			if (!ffb_test_bit(code, absbits)) continue;
			input_absinfo ai;
			memset(&ai, 0, sizeof(ai));
			if (ioctl(fd, EVIOCGABS(code), &ai) >= 0) {
				abs_info[code] = ai;
				axis_values[code] = ai.value;
			}
		}
	}
	return true;
}

void FFBDevice::close() {
	if (fd < 0) return;
	stop_all();
	::close(fd);
	fd = -1;
	device_name = String();
	vendor_id = product_id = version_id = max_effects = 0;
	constant_id = -1;
	abs_info.clear();
	axis_values.clear();
	button_values.clear();
	effects.clear();
	memset(ff_bits, 0, sizeof(ff_bits));
}

bool FFBDevice::is_open() const { return fd >= 0; }

bool FFBDevice::has_feature(int feature) const {
	if (fd < 0) return false;
	return ffb_test_bit(feature, ff_bits);
}

// ----------------------------------------------------------------------------
// identity / capabilities
// ----------------------------------------------------------------------------
String FFBDevice::get_device_name() const { return device_name; }
int FFBDevice::get_vendor_id() const { return vendor_id; }
int FFBDevice::get_product_id() const { return product_id; }
int FFBDevice::get_num_effects() const { return max_effects; }

Dictionary FFBDevice::get_capabilities() {
	Dictionary d;
	if (fd < 0) return d;
	d["constant"] = ffb_test_bit(FF_CONSTANT, ff_bits);
	d["periodic"] = ffb_test_bit(FF_PERIODIC, ff_bits);
	d["spring"] = ffb_test_bit(FF_SPRING, ff_bits);
	d["damper"] = ffb_test_bit(FF_DAMPER, ff_bits);
	d["friction"] = ffb_test_bit(FF_FRICTION, ff_bits);
	d["inertia"] = ffb_test_bit(FF_INERTIA, ff_bits);
	d["ramp"] = ffb_test_bit(FF_RAMP, ff_bits);
	d["rumble"] = ffb_test_bit(FF_RUMBLE, ff_bits);
	d["gain"] = ffb_test_bit(FF_GAIN, ff_bits);
	d["autocenter"] = ffb_test_bit(FF_AUTOCENTER, ff_bits);
	d["sine"] = ffb_test_bit(FF_SINE, ff_bits);
	d["square"] = ffb_test_bit(FF_SQUARE, ff_bits);
	d["triangle"] = ffb_test_bit(FF_TRIANGLE, ff_bits);
	d["saw_up"] = ffb_test_bit(FF_SAW_UP, ff_bits);
	d["saw_down"] = ffb_test_bit(FF_SAW_DOWN, ff_bits);
	d["max_effects"] = max_effects;
	return d;
}

// ----------------------------------------------------------------------------
// input
// ----------------------------------------------------------------------------
void FFBDevice::poll() {
	if (fd < 0) return;
	input_event ev;
	ssize_t n;
	while ((n = ::read(fd, &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
		if (ev.type == EV_ABS) {
			axis_values[ev.code] = ev.value;
		} else if (ev.type == EV_KEY) {
			button_values[ev.code] = ev.value;
		}
	}
}

Array FFBDevice::get_axes() {
	Array a;
	for (const auto &kv : abs_info) a.push_back(kv.first);
	return a;
}

Dictionary FFBDevice::get_abs_info(int code) {
	Dictionary d;
	auto it = abs_info.find(code);
	if (it == abs_info.end()) return d;
	const input_absinfo &ai = it->second;
	d["value"] = ai.value;
	d["min"] = ai.minimum;
	d["max"] = ai.maximum;
	d["fuzz"] = ai.fuzz;
	d["flat"] = ai.flat;
	d["resolution"] = ai.resolution;
	return d;
}

int FFBDevice::get_axis_raw(int code) {
	auto it = axis_values.find(code);
	return it == axis_values.end() ? 0 : it->second;
}

float FFBDevice::get_axis_normalized(int code) {
	auto it = abs_info.find(code);
	if (it == abs_info.end()) return 0.0f;
	const input_absinfo &ai = it->second;
	if (ai.maximum == ai.minimum) return 0.0f;
	float raw = (float)get_axis_raw(code);
	return clampf((raw - ai.minimum) / (float)(ai.maximum - ai.minimum), 0.0f, 1.0f);
}

float FFBDevice::get_axis_centered(int code) {
	return get_axis_normalized(code) * 2.0f - 1.0f;
}

bool FFBDevice::is_button_pressed(int code) {
	auto it = button_values.find(code);
	return it != button_values.end() && it->second != 0;
}

// ----------------------------------------------------------------------------
// global tuning
// ----------------------------------------------------------------------------
void FFBDevice::set_gain(float gain) {
	if (!has_feature(FF_GAIN)) return;
	write_ff_event(FF_GAIN, clamp_i((int)(clampf(gain, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF));
}

void FFBDevice::set_autocenter(float strength) {
	if (!has_feature(FF_AUTOCENTER)) return; // e.g. Moza R3 has no kernel autocenter
	write_ff_event(FF_AUTOCENTER, clamp_i((int)(clampf(strength, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF));
}

void FFBDevice::set_inverted(bool inverted) { invert = inverted; }
bool FFBDevice::is_inverted() const { return invert; }

// ----------------------------------------------------------------------------
// managed constant force
// ----------------------------------------------------------------------------
bool FFBDevice::start_constant_force() {
	if (fd < 0) return false;
	if (constant_id >= 0) return true;
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_CONSTANT;
	e.id = -1;
	e.direction = 0x4000; // 90deg; signed level selects left/right on a wheel
	e.u.constant.level = 0;
	e.replay.length = 0; // infinite, until stopped
	e.replay.delay = 0;
	int id = upload(e);
	if (id < 0) return false;
	constant_id = id;
	play_effect(constant_id, 1);
	return true;
}

void FFBDevice::update_constant_force(float level) {
	if (fd < 0 || constant_id < 0) return;
	auto it = effects.find(constant_id);
	if (it == effects.end()) return;
	float lv = invert ? -level : level;
	it->second.u.constant.level = (short)clamp_i((int)(clampf(lv, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	ioctl(fd, EVIOCSFF, &it->second); // live update of the playing effect
}

void FFBDevice::stop_constant_force() {
	if (constant_id < 0) return;
	erase_effect(constant_id);
	constant_id = -1;
}

// ----------------------------------------------------------------------------
// generic effect creation
// ----------------------------------------------------------------------------
int FFBDevice::upload_constant(float level, float direction_deg, float duration_s) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_CONSTANT;
	e.id = -1;
	e.direction = direction_to_u16(direction_deg);
	float lv = invert ? -level : level;
	e.u.constant.level = (short)clamp_i((int)(clampf(lv, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.replay.length = duration_s <= 0.0f ? 0 : (unsigned short)clamp_i((int)(duration_s * 1000.0f), 0, 0xFFFF);
	return upload(e);
}

int FFBDevice::upload_spring(float center, float coeff, float saturation, float deadband) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_SPRING;
	e.id = -1;
	e.replay.length = 0;
	short c = (short)clamp_i((int)(clampf(coeff, 0.0f, 1.0f) * 0x7FFF), 0, 0x7FFF);
	unsigned short sat = (unsigned short)clamp_i((int)(clampf(saturation, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.u.condition[0].right_coeff = c;
	e.u.condition[0].left_coeff = c;
	e.u.condition[0].right_saturation = sat;
	e.u.condition[0].left_saturation = sat;
	e.u.condition[0].center = (short)clamp_i((int)(clampf(center, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.u.condition[0].deadband = (unsigned short)clamp_i((int)(clampf(deadband, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.u.condition[1] = e.u.condition[0];
	return upload(e);
}

int FFBDevice::upload_damper(float coeff, float saturation) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_DAMPER;
	e.id = -1;
	e.replay.length = 0;
	short c = (short)clamp_i((int)(clampf(coeff, 0.0f, 1.0f) * 0x7FFF), 0, 0x7FFF);
	unsigned short sat = (unsigned short)clamp_i((int)(clampf(saturation, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.u.condition[0].right_coeff = c;
	e.u.condition[0].left_coeff = c;
	e.u.condition[0].right_saturation = sat;
	e.u.condition[0].left_saturation = sat;
	e.u.condition[1] = e.u.condition[0];
	return upload(e);
}

int FFBDevice::upload_friction(float coeff, float saturation) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_FRICTION;
	e.id = -1;
	e.replay.length = 0;
	short c = (short)clamp_i((int)(clampf(coeff, 0.0f, 1.0f) * 0x7FFF), 0, 0x7FFF);
	unsigned short sat = (unsigned short)clamp_i((int)(clampf(saturation, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.u.condition[0].right_coeff = c;
	e.u.condition[0].left_coeff = c;
	e.u.condition[0].right_saturation = sat;
	e.u.condition[0].left_saturation = sat;
	e.u.condition[1] = e.u.condition[0];
	return upload(e);
}

int FFBDevice::upload_periodic(int waveform, float magnitude, float offset, int period_ms,
		float direction_deg, int duration_ms, int attack_ms, int fade_ms) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_PERIODIC;
	e.id = -1;
	e.direction = direction_to_u16(direction_deg);
	switch (waveform) {
		case WAVE_SQUARE: e.u.periodic.waveform = FF_SQUARE; break;
		case WAVE_TRIANGLE: e.u.periodic.waveform = FF_TRIANGLE; break;
		case WAVE_SAW_UP: e.u.periodic.waveform = FF_SAW_UP; break;
		case WAVE_SAW_DOWN: e.u.periodic.waveform = FF_SAW_DOWN; break;
		case WAVE_SINE:
		default: e.u.periodic.waveform = FF_SINE; break;
	}
	e.u.periodic.magnitude = (short)clamp_i((int)(clampf(magnitude, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.u.periodic.offset = (short)clamp_i((int)(clampf(offset, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.u.periodic.period = (unsigned short)clamp_i(period_ms, 1, 0xFFFF);
	e.u.periodic.phase = 0;
	e.u.periodic.envelope.attack_length = (unsigned short)clamp_i(attack_ms, 0, 0xFFFF);
	e.u.periodic.envelope.attack_level = 0;
	e.u.periodic.envelope.fade_length = (unsigned short)clamp_i(fade_ms, 0, 0xFFFF);
	e.u.periodic.envelope.fade_level = 0;
	e.replay.length = duration_ms <= 0 ? 0 : (unsigned short)clamp_i(duration_ms, 0, 0xFFFF);
	return upload(e);
}

int FFBDevice::upload_ramp(float start_level, float end_level, float direction_deg, int duration_ms) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_RAMP;
	e.id = -1;
	e.direction = direction_to_u16(direction_deg);
	e.u.ramp.start_level = (short)clamp_i((int)(clampf(start_level, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.u.ramp.end_level = (short)clamp_i((int)(clampf(end_level, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	e.replay.length = duration_ms <= 0 ? 0 : (unsigned short)clamp_i(duration_ms, 0, 0xFFFF);
	return upload(e);
}

int FFBDevice::upload_rumble(float strong, float weak, int duration_ms) {
	ff_effect e;
	memset(&e, 0, sizeof(e));
	e.type = FF_RUMBLE;
	e.id = -1;
	e.u.rumble.strong_magnitude = (unsigned short)clamp_i((int)(clampf(strong, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.u.rumble.weak_magnitude = (unsigned short)clamp_i((int)(clampf(weak, 0.0f, 1.0f) * 0xFFFF), 0, 0xFFFF);
	e.replay.length = duration_ms <= 0 ? 0 : (unsigned short)clamp_i(duration_ms, 0, 0xFFFF);
	return upload(e);
}

// ----------------------------------------------------------------------------
// playback control
// ----------------------------------------------------------------------------
void FFBDevice::play_effect(int id, int count) {
	write_ff_event(id, count);
}

void FFBDevice::stop_effect(int id) {
	write_ff_event(id, 0);
}

void FFBDevice::update_constant(int id, float level) {
	if (fd < 0) return;
	auto it = effects.find(id);
	if (it == effects.end() || it->second.type != FF_CONSTANT) return;
	float lv = invert ? -level : level;
	it->second.u.constant.level = (short)clamp_i((int)(clampf(lv, -1.0f, 1.0f) * 32767.0f), -32767, 32767);
	ioctl(fd, EVIOCSFF, &it->second);
}

void FFBDevice::erase_effect(int id) {
	if (fd < 0) return;
	stop_effect(id);
	ioctl(fd, EVIOCRMFF, id);
	effects.erase(id);
}

void FFBDevice::stop_all() {
	if (fd < 0) return;
	// copy ids first, erase_effect mutates the map
	std::vector<int> ids;
	for (const auto &kv : effects) ids.push_back(kv.first);
	for (int id : ids) erase_effect(id);
	constant_id = -1;
}

// ----------------------------------------------------------------------------
// bindings
// ----------------------------------------------------------------------------
void FFBDevice::_bind_methods() {
	ClassDB::bind_method(D_METHOD("open", "path"), &FFBDevice::open);
	ClassDB::bind_method(D_METHOD("close"), &FFBDevice::close);
	ClassDB::bind_method(D_METHOD("is_open"), &FFBDevice::is_open);

	ClassDB::bind_method(D_METHOD("get_device_name"), &FFBDevice::get_device_name);
	ClassDB::bind_method(D_METHOD("get_vendor_id"), &FFBDevice::get_vendor_id);
	ClassDB::bind_method(D_METHOD("get_product_id"), &FFBDevice::get_product_id);
	ClassDB::bind_method(D_METHOD("get_num_effects"), &FFBDevice::get_num_effects);
	ClassDB::bind_method(D_METHOD("get_capabilities"), &FFBDevice::get_capabilities);

	ClassDB::bind_method(D_METHOD("poll"), &FFBDevice::poll);
	ClassDB::bind_method(D_METHOD("get_axes"), &FFBDevice::get_axes);
	ClassDB::bind_method(D_METHOD("get_abs_info", "code"), &FFBDevice::get_abs_info);
	ClassDB::bind_method(D_METHOD("get_axis_raw", "code"), &FFBDevice::get_axis_raw);
	ClassDB::bind_method(D_METHOD("get_axis_normalized", "code"), &FFBDevice::get_axis_normalized);
	ClassDB::bind_method(D_METHOD("get_axis_centered", "code"), &FFBDevice::get_axis_centered);
	ClassDB::bind_method(D_METHOD("is_button_pressed", "code"), &FFBDevice::is_button_pressed);

	ClassDB::bind_method(D_METHOD("set_gain", "gain"), &FFBDevice::set_gain);
	ClassDB::bind_method(D_METHOD("set_autocenter", "strength"), &FFBDevice::set_autocenter);
	ClassDB::bind_method(D_METHOD("set_inverted", "inverted"), &FFBDevice::set_inverted);
	ClassDB::bind_method(D_METHOD("is_inverted"), &FFBDevice::is_inverted);

	ClassDB::bind_method(D_METHOD("start_constant_force"), &FFBDevice::start_constant_force);
	ClassDB::bind_method(D_METHOD("update_constant_force", "level"), &FFBDevice::update_constant_force);
	ClassDB::bind_method(D_METHOD("stop_constant_force"), &FFBDevice::stop_constant_force);

	ClassDB::bind_method(D_METHOD("upload_constant", "level", "direction_deg", "duration_s"), &FFBDevice::upload_constant);
	ClassDB::bind_method(D_METHOD("upload_spring", "center", "coeff", "saturation", "deadband"), &FFBDevice::upload_spring);
	ClassDB::bind_method(D_METHOD("upload_damper", "coeff", "saturation"), &FFBDevice::upload_damper);
	ClassDB::bind_method(D_METHOD("upload_friction", "coeff", "saturation"), &FFBDevice::upload_friction);
	ClassDB::bind_method(D_METHOD("upload_periodic", "waveform", "magnitude", "offset", "period_ms", "direction_deg", "duration_ms", "attack_ms", "fade_ms"), &FFBDevice::upload_periodic);
	ClassDB::bind_method(D_METHOD("upload_ramp", "start_level", "end_level", "direction_deg", "duration_ms"), &FFBDevice::upload_ramp);
	ClassDB::bind_method(D_METHOD("upload_rumble", "strong", "weak", "duration_ms"), &FFBDevice::upload_rumble);

	ClassDB::bind_method(D_METHOD("play_effect", "id", "count"), &FFBDevice::play_effect);
	ClassDB::bind_method(D_METHOD("stop_effect", "id"), &FFBDevice::stop_effect);
	ClassDB::bind_method(D_METHOD("update_constant", "id", "level"), &FFBDevice::update_constant);
	ClassDB::bind_method(D_METHOD("erase_effect", "id"), &FFBDevice::erase_effect);
	ClassDB::bind_method(D_METHOD("stop_all"), &FFBDevice::stop_all);

	BIND_ENUM_CONSTANT(WAVE_SINE);
	BIND_ENUM_CONSTANT(WAVE_SQUARE);
	BIND_ENUM_CONSTANT(WAVE_TRIANGLE);
	BIND_ENUM_CONSTANT(WAVE_SAW_UP);
	BIND_ENUM_CONSTANT(WAVE_SAW_DOWN);
}
