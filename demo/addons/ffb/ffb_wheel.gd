class_name FFBWheel
extends Node

## Drop-in force-feedback wheel node.
##
## Wraps FFBManager/FFBDevice: opens the wheel, reads steering/pedals/buttons,
## and applies force. Two ways to drive the force each physics frame:
##
##   wheel.poll(delta)                 # refresh inputs from the device
##   wheel.state.speed = my_speed      # feed vehicle-side state
##   wheel.update_force(delta)         # force_model.compute() -> wheel
##
## or, if your game computes its own normalized torque:
##
##   wheel.poll(delta)
##   wheel.apply_torque(my_torque)     # -1..1, directly
##
## Axis codes default to the Moza R3 mapping (verify with dist/ffbprobe).

@export var auto_open := true
@export var device_path := ""          ## "" = auto-find a Moza wheel
@export_range(0.0, 1.0) var gain := 1.0
@export var inverted := true           ## Moza R3 reports forces with inverted sign
@export var steer_code := 0            ## ABS_X
@export var throttle_code := 2         ## ABS_Z on the R3
@export var brake_code := 5            ## ABS_RZ on the R3
@export var clutch_code := -1          ## -1 = none
@export var steering_range_deg := 900.0 ## physical lock-to-lock range set on the wheel
@export var force_model: FFBForceModel

var manager := FFBManager.new()
var device: FFBDevice
var state := FFBState.new()

var throttle := 0.0
var brake := 0.0
var clutch := 0.0
var last_torque := 0.0

var _curb_id := -1

signal opened(device_name: String)
signal open_failed(reason: String)


func _ready() -> void:
	if auto_open:
		open()


func open() -> bool:
	device = manager.open_device(device_path) if device_path != "" else manager.open_moza()
	if device == null or not device.is_open():
		open_failed.emit("no FFB wheel found")
		return false
	device.set_gain(gain)
	device.set_inverted(inverted)
	device.start_constant_force()
	# Pre-make the curb effect once so play_curb() doesn't burn an effect slot.
	_curb_id = device.upload_periodic(FFBDevice.WAVE_SINE, 0.6, 0.0, 50, 90.0, 250, 0, 50)
	opened.emit(device.get_device_name())
	return true


func is_open() -> bool:
	return device != null and device.is_open()


## Refresh inputs (steering / pedals) from the device. Call once per frame.
func poll(delta: float) -> void:
	if not is_open():
		return
	device.poll()
	var s := device.get_axis_centered(steer_code)
	state.steer_velocity = (s - state.steering) / maxf(delta, 0.0001)
	state.steering = s
	throttle = device.get_axis_normalized(throttle_code) if throttle_code >= 0 else 0.0
	brake = device.get_axis_normalized(brake_code) if brake_code >= 0 else 0.0
	clutch = device.get_axis_normalized(clutch_code) if clutch_code >= 0 else 0.0


## Run the assigned force_model against the current state and apply its torque.
func update_force(delta: float) -> float:
	if is_open() and force_model != null:
		apply_torque(force_model.compute(state, delta))
	return last_torque


## Actual physical wheel angle in degrees (uses steering_range_deg).
func steering_angle_deg() -> float:
	return state.steering * steering_range_deg * 0.5


## Apply a normalized torque directly (-1..1).
func apply_torque(t: float) -> void:
	last_torque = clampf(t, -1.0, 1.0)
	if is_open():
		device.update_constant_force(last_torque)


func play_curb() -> void:
	if is_open() and _curb_id >= 0:
		device.play_effect(_curb_id, 1)


func is_button_pressed(code: int) -> bool:
	return is_open() and device.is_button_pressed(code)


func set_inverted(v: bool) -> void:
	inverted = v
	if is_open():
		device.set_inverted(v)


func set_gain(g: float) -> void:
	gain = clampf(g, 0.0, 1.0)
	if is_open():
		device.set_gain(gain)


func close() -> void:
	if is_open():
		device.stop_constant_force()
		device.close()


func _exit_tree() -> void:
	close()
