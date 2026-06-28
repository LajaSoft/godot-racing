class_name VehicleFFBModel
extends FFBForceModel

## Force model driven by the car's real motion: the self-aligning torque comes
## from the FRONT TIRE SLIP ANGLE, not a position spring. The wheel returns to
## where the car is actually heading (and stays put when parked), instead of
## always snapping to dead-center.
##
## The game fills, each physics frame:
##   state.slip             front tire slip angle in radians (steer - heading)
##   state.speed            forward speed normalized 0..1
##   state.surface_friction front-wheel grip 0..1 (VehicleWheel3D.get_skidinfo)

## Peak self-aligning gain.
@export var self_align_gain := 0.9
## Slip angle (rad) at which the aligning torque peaks; beyond it the force
## falls off — the tire's classic Mz curve — so you feel the front let go.
@export var peak_slip := 0.10
## Speed (as a fraction of normalized speed) at which alignment is fully present.
@export_range(0.01, 1.0) var full_align_speed := 0.2


func compute(state: FFBState, dt: float) -> float:
	var grip := clampf(state.surface_friction, 0.0, 1.0)
	var speed_factor := clampf(state.speed / full_align_speed, 0.0, 1.0)

	# tire self-aligning torque vs slip angle: 2x/(1+x^2) rises to ±1 at the
	# peak slip, then decays past it (grip loss).
	var x := state.slip / peak_slip
	var mz := 2.0 * x / (1.0 + x * x)
	var aligning := self_align_gain * mz * grip * speed_factor

	# damping + subtle road texture (damping/road_texture/output_scale/_phase from base)
	var damp := -damping * state.steer_velocity
	_phase += dt * (10.0 + 25.0 * state.speed)
	var texture := sin(_phase) * road_texture * state.speed * grip

	return clampf((aligning + damp + texture) * output_scale, -1.0, 1.0)
