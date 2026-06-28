extends Control

# Demo: a thin consumer of the FFB library.
#
# The library (addons/ffb) owns the device + force synthesis (FFBWheel +
# FFBForceModel). The game owns the vehicle state — here a toy longitudinal
# model that turns the pedals into a normalized speed, which is fed to the
# wheel's force model. Swap in a real vehicle later and feed real state.

const ACCEL := 0.5
const BRAKE_DECEL := 1.2
const DRAG := 0.35

var wheel: FFBWheel
var model: FFBForceModel
var label: Label
var speed := 0.0
var status := ""


func _ready() -> void:
	label = Label.new()
	label.anchor_right = 1.0
	label.anchor_bottom = 1.0
	label.add_theme_font_size_override("font_size", 18)
	add_child(label)

	model = FFBForceModel.new()
	wheel = FFBWheel.new()
	wheel.force_model = model
	wheel.opened.connect(func(n): print("FFB wheel opened: ", n, "  caps: ", wheel.device.get_capabilities()))
	wheel.open_failed.connect(func(r): status = "No FFB wheel: " + r + "\nCheck ./dist/ffbprobe.")
	add_child(wheel)  # auto_open runs here

	if not wheel.is_open():
		push_warning(status)


func _physics_process(delta: float) -> void:
	if not wheel.is_open():
		_redraw()
		return

	wheel.poll(delta)

	# toy vehicle: pedals -> normalized speed
	speed += (wheel.throttle * ACCEL - wheel.brake * BRAKE_DECEL - DRAG * speed) * delta
	speed = clampf(speed, 0.0, 1.0)

	wheel.state.speed = speed
	wheel.update_force(delta)

	_redraw()


func _redraw() -> void:
	if not wheel.is_open():
		label.text = "Godot FFB demo\n\n" + status
		return

	var lines := []
	lines.append("Godot FFB — %s" % wheel.device.get_device_name())
	lines.append("")
	lines.append("steering: %+.3f    torque: %+.3f    speed: %.2f    grip: %.2f" % [
		wheel.state.steering, wheel.last_torque, speed, model.grip_at(wheel.state.steering)])
	lines.append("throttle: %.2f     brake: %.2f" % [wheel.throttle, wheel.brake])
	lines.append("")
	lines.append("all axes:")
	for code in wheel.device.get_axes():
		lines.append("   code %2d : raw %6d   norm %+.3f" % [
			code, wheel.device.get_axis_raw(code), wheel.device.get_axis_normalized(code)])
	lines.append("")
	lines.append("model:  centering=%.2f  damping=%.3f  understeer=%.2f  scale=%.2f  inverted=%s" % [
		model.centering, model.damping, model.understeer, model.output_scale, wheel.inverted])
	lines.append("keys:  [SPACE] curb   [↑/↓] centering   [←/→] output scale   [C] flip direction")
	label.text = "\n".join(lines)


func _unhandled_input(event: InputEvent) -> void:
	if not wheel.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE:
				wheel.play_curb()
			KEY_UP:
				model.centering = clampf(model.centering + 0.05, 0.0, 2.0)
			KEY_DOWN:
				model.centering = clampf(model.centering - 0.05, 0.0, 2.0)
			KEY_RIGHT:
				model.output_scale = clampf(model.output_scale + 0.05, 0.0, 1.0)
			KEY_LEFT:
				model.output_scale = clampf(model.output_scale - 0.05, 0.0, 1.0)
			KEY_C:
				wheel.set_inverted(not wheel.inverted)


func _exit_tree() -> void:
	if wheel != null:
		wheel.close()
