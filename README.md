# godot-ffb — Force Feedback steering wheels in Godot (Linux)

A Godot 4 GDExtension that gives GDScript real force feedback on Linux, talking
directly to the kernel Force Feedback API (`evdev` / `ioctl EVIOCSFF`). Godot's
built-in `Input` only exposes simple rumble; this adds constant force (the core
of sim-racing FFB), spring / damper / friction, periodic effects, ramp, rumble,
plus global gain and autocenter — and direct reading of wheel/pedal axes and
buttons straight from evdev.

Developed and tested against a **Moza R3** (Gudsen USB `346e:0005`), but works
with any wheel the kernel exposes as an FF-capable input device.

## How it works

- The kernel driver (`hid-universal-pidff` / `hid-pidff`) binds the wheel and
  creates `/dev/input/eventN` with FF capability — this lives on the **host**.
- This extension opens that node read/write, reads axes/buttons, and uploads /
  updates FF effects.
- You compute torque in your game and call `update_constant_force()` every
  physics frame — exactly how a sim drives an FFB wheel.

## Layout

```
src/        C++ GDExtension (FFBManager, FFBDevice)
tools/      standalone C utilities (no Godot): ffbprobe, ffbtest
demo/       self-contained Godot project (the .so is built into it)
```

## Build (in Docker, host stays clean)

Requires only Docker on the build machine. The Godot version is selected by
`GODOT_CPP_BRANCH` (default `4.4`, matching Godot 4.4.x — set it to your version).

```bash
# 1. build the GDExtension -> demo/addons/ffb/bin/libffb.linux.template_debug.x86_64.so
docker compose run --rm build

# 2. (optional) build the standalone C test tools -> dist/
docker compose run --rm tools

# release build of the extension:
docker compose run --rm build make build-release
```

First run clones `godot-cpp` and compiles it, so it takes a few minutes; later
builds are incremental.

> Check your Godot version with `godot --version`. If it is not 4.4.x, rebuild
> with e.g. `GODOT_CPP_BRANCH=4.5 docker compose run --rm build` and update
> `compatibility_minimum` in `demo/addons/ffb/ffb.gdextension`.

## Run (on the host, where the Moza is connected)

1. Sanity-check the hardware without Godot:

   ```bash
   ./dist/ffbprobe          # lists devices; the Moza shows [FORCE FEEDBACK]
   ./dist/ffbtest           # WARNING: the wheel will move. Push left/right, spring, vibration.
   ```

2. Run the demo:

   ```bash
   godot --path demo
   ```

   > First time only: a GDExtension is loaded from `.godot/extension_list.cfg`,
   > which Godot generates when it **imports** the project. If you run the game
   > before that file exists you get `Could not find type "FFBManager"`. Fix by
   > opening the project in the editor once, or generating it headless:
   >
   > ```bash
   > godot --headless --editor --path demo --quit   # writes .godot/extension_list.cfg
   > godot --path demo
   > ```
   >
   > (this repo ships that file pre-made, so a direct run works too).

### Run everything inside the container (GPU + wheel passthrough)

The `gui` service runs the demo in-container with the GPU (nvidia-container-toolkit)
and the wheel passed through, drawing to the host display. Runs as uid 1000 so the
Wayland / X sockets line up; group 995 = host `input` group for the wheel node.

```bash
docker compose run --rm gui          # XWayland; no xhost needed
```

X auth works by passing the host `XAUTHORITY` cookie (it lives under `/run/user/1000`,
which is mounted); `DISPLAY` comes from your shell. If `echo $XAUTHORITY` is empty:

```bash
export XAUTHORITY=$(ls /run/user/$UID/.mutter-Xwaylandauth.* | head -1)
docker compose run --rm gui
```

Native Wayland alternative (Godot 4.4's Wayland backend can SIGFPE on some compositors):

```bash
docker compose run --rm gui godot --path demo --display-driver wayland --audio-driver Dummy
```

Verified working in-container: GPU (`nvidia-smi`, both RTX 5060 Ti), Vulkan
(`vulkaninfo` enumerates the NVIDIA GPUs), X connection via the cookie, and the
Moza wheel (`ffbprobe`). The only thing that opens a window / moves the wheel is
the actual `gui` run.

Verify the pieces without opening a window / moving the wheel:

```bash
docker compose run --rm wheel                 # wheel visible? (read-only probe)
docker compose run --rm gui nvidia-smi        # GPU visible?
docker compose run --rm gui godot --version   # Godot present?
```

Adjust `WAYLAND_DISPLAY` / `DISPLAY` / the `/run/user/1000` mount in `compose.yml`
if your runtime dir or display names differ (e.g. uid != 1000).

   The wheel self-centers (computed in software via constant force). Turn it and
   feel the centering + damping; press SPACE for a curb bump; arrows tune it.

## GDScript API

High-level (recommended) — `FFBWheel` node + `FFBForceModel` resource:

```gdscript
var wheel := FFBWheel.new()
wheel.force_model = FFBForceModel.new()    # parametric self-aligning model
add_child(wheel)                            # auto-opens the Moza wheel

func _physics_process(delta):
    wheel.poll(delta)                       # read steering / pedals
    wheel.state.speed = my_speed_0_to_1     # feed vehicle state
    wheel.update_force(delta)               # model -> wheel torque
    # or compute the force yourself:  wheel.apply_torque(my_torque)
```

Subclass `FFBForceModel` and override `compute(state, dt)` for a physical
chassis / steering-rack model — `FFBState` already carries tire-force, load,
friction and slip fields for that.

### Low-level (device)

```gdscript
var mgr := FFBManager.new()
var wheel := mgr.open_moza()            # or mgr.open_device("/dev/input/eventN")
if wheel == null: return

wheel.set_gain(1.0)
wheel.start_constant_force()

func _physics_process(delta):
    wheel.poll()                        # refresh axis/button state
    var steer := wheel.get_axis_centered(0)   # ABS_X, -1..1
    var torque := -0.8 * steer          # your physics here
    wheel.update_constant_force(torque) # -1..1
```

Other effects: `upload_spring/ damper/ friction/ periodic/ ramp/ rumble(...)`
return an effect id; play with `play_effect(id, count)`, stop with
`stop_effect(id)`, remove with `erase_effect(id)`. `set_autocenter(0..1)` uses
the wheel's built-in centering spring. See `demo/main.gd` for a full example and
`src/ffb_device.h` for the complete surface.

## Force direction note

Constant force uses a signed level with a fixed direction. If torque feels
inverted on your wheel, negate the value you pass to `update_constant_force()`
(a per-device "invert" toggle is the intended config knob).
