extends SceneTree

var failures := 0
var checks := 0

func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		printerr("FFB TEST FAIL: " + message)

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	check(ClassDB.class_exists("FFBManager"), "Native manager registered")
	check(ClassDB.class_exists("FFBDevice"), "Native device registered")
	var manager := FFBManager.new()
	check(manager.has_method("open_moza") and manager.has_method("open_device"), "Device discovery API")
	var device := FFBDevice.new()
	check(not device.is_open(), "Creating device does not open hardware")
	check(device.get_axes().is_empty() and device.get_capabilities().is_empty(), "Closed device is empty")
	for method in ["poll", "get_abs_info", "get_axis_raw", "get_axis_normalized", "get_axis_centered", "is_button_pressed", "set_gain", "set_autocenter", "set_inverted", "start_constant_force", "update_constant_force", "stop_constant_force", "upload_spring", "upload_damper", "upload_friction", "upload_periodic", "upload_ramp", "upload_rumble", "play_effect", "stop_all"]:
		check(device.has_method(method), "Native method " + method)
	device.close()
	var wheel := FFBWheel.new()
	wheel.auto_open = false
	root.add_child(wheel)
	check(not wheel.is_open(), "Explicitly disabled auto-open does not access hardware")
	check(wheel.steer_code == 0 and wheel.throttle_code == 2 and wheel.brake_code == 5, "Moza R3 default ABS mapping")
	wheel.poll(1.0 / 120)
	check(wheel.throttle == 0 and wheel.brake == 0, "Closed wheel input is neutral")
	wheel.apply_torque(2.0)
	check(wheel.last_torque == 1.0, "Normalized torque upper bound")
	wheel.apply_torque(-2.0)
	check(wheel.last_torque == -1.0, "Normalized torque lower bound")
	wheel.state.steering = 0.5
	wheel.steering_range_deg = 900
	check(wheel.steering_angle_deg() == 225, "Physical steering angle")
	wheel.close()
	check(wheel.last_torque == 0 and wheel.state.steering == 0, "Close clears force and input telemetry")
	wheel.free()
	var model := FFBForceModel.new()
	model.road_texture = 0
	var state := FFBState.new()
	check(model.compute(state, 0.01) == 0, "Neutral force is zero")
	state.speed = 0.6
	state.steering = 0.4
	var left := model.compute(state, 0.01)
	state.steering = -0.4
	var right := model.compute(state, 0.01)
	check(left < 0 and right > 0 and absf(left + right) < 0.00001, "Restoring force is symmetric")
	for i in range(100):
		state.steering = sin(i)
		state.steer_velocity = cos(i) * 20
		state.speed = float(i) / 100
		var torque := model.compute(state, 0.01)
		check(is_finite(torque) and absf(torque) <= 1, "Bounded force %d" % i)
	check(model.grip_at(0) == 1 and model.grip_at(1) < 1, "Grip curve")
	model.reset()
	print("FFB TEST RESULT: ", checks, " checks; ", failures, " failures; hardware not opened")
	quit(1 if failures else 0)
