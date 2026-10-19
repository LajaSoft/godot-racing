class_name FFBForceModel
extends Resource

## Base force model: maps an FFBState to a wheel torque in [-1, 1].
##
## The default implementation is a parametric self-aligning model — use it when
## your game has no tire model. For a physical feel, subclass and override
## compute() to integrate real wheel forces, rack inertia and friction:
##
##     class_name FFBRackModel extends FFBForceModel
##     var _rack_vel := 0.0
##     func compute(s: FFBState, dt: float) -> float:
##         # torque from tire self-aligning force, resisted by rack inertia/friction
##         ...
##
## Tunables are exported, so a model can be authored and saved as a .tres.

## Base self-aligning (centering) gain.
@export_range(0.0, 2.0) var centering := 0.8
## Damping — resists fast wheel motion, kills oscillation.
@export_range(0.0, 0.5) var damping := 0.04
## How much grip (and force) drops as you turn harder — the wheel "lightens"
## near the limit, like understeer / loss of front grip.
@export_range(0.0, 1.0) var understeer := 0.6
## Subtle road buzz amplitude, scaled by speed (0 disables).
@export_range(0.0, 0.2) var road_texture := 0.02
## Force fraction still present at a standstill (parking effort).
@export_range(0.0, 1.0) var standstill_force := 0.15
## Overall output multiplier.
@export_range(0.0, 1.0) var output_scale := 1.0

var _phase := 0.0


## Override in subclasses. Returns torque in [-1, 1].
func compute(state: FFBState, dt: float) -> float:
	var steer := state.steering
	var grip := grip_at(steer)
	var align := -centering * steer * (standstill_force + (1.0 - standstill_force) * state.speed) * grip
	var damp := -damping * state.steer_velocity

	_phase += dt * (8.0 + 30.0 * state.speed)
	var texture := sin(_phase) * road_texture * state.speed

	return clampf((align + damp + texture) * output_scale, -1.0, 1.0)


## Grip factor at a given steering position (for UI/telemetry).
func grip_at(steer: float) -> float:
	return 1.0 - clampf(absf(steer) * understeer, 0.0, 0.7)


func reset() -> void:
	_phase = 0.0
