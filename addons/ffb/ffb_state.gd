class_name FFBState
extends RefCounted

## Input bundle handed to an FFBForceModel each physics frame.
##
## Simple parametric models use only the first few fields. A future physical
## chassis / steering-rack model can use the richer ones (tire forces, load,
## friction, slip). Adding fields here never breaks existing models, which is
## why the model interface takes this object instead of fixed arguments.
##
## FFBWheel fills `steering` / `steer_velocity` from the device; the game fills
## the vehicle-side fields (speed, forces, ...) before calling update_force().

# --- always provided by FFBWheel (read from the device) ---
var steering := 0.0          ## actual wheel position, -1..1
var steer_velocity := 0.0    ## units/s

# --- provided by the game / vehicle ---
var speed := 0.0             ## normalized 0..1 for simple models, or m/s for physical ones
var lateral_accel := 0.0     ## m/s^2 (or g) — load transfer / understeer cues
var self_aligning := 0.0     ## net self-aligning torque from a tire model, N·m (physical models)
var wheel_load := 1.0        ## vertical load factor (0 = airborne, 1 = nominal)
var surface_friction := 1.0  ## 0..1 grip multiplier (ice .. dry tarmac)
var slip := 0.0              ## front slip angle / ratio, if available

## Free-form bag for experimentation without changing this class.
var extra := {}
