# Godot FFB — Moza / Linux

Runtime GDExtension and GDScript API for Linux evdev force feedback. Version 0.1.0.

## Supported configuration

- Linux x86-64; Godot 4.4.1 or newer, standard single-precision builds.
- Prebuilt releases target glibc 2.35+ and libstdc++ GLIBCXX_3.4.30 or newer.
- Verified device: directly USB-connected Gudsen/Moza R3 wheel and pedals, vendor 0x346e.
- The host kernel must expose the wheel as an FF-capable `/dev/input/event*` device, and the user needs read/write permission on that node.
- No Moza SDK, serial protocol, Pit House replacement, kernel-driver installation or wheel-firmware configuration is included. Wheel rotation range must match the range configured outside the game.

Other Linux evdev FF-capable wheels can be opened by path, but are not hardware-verified. Available effects and axis codes depend on the kernel driver and device. There is no Windows, macOS, Web or Bluetooth backend in this release.

## Install

Extract the release ZIP into your Godot project, producing `addons/ffb/`, or use gd-plug with the prebuilt distribution tag:

```gdscript
extends "res://addons/gd-plug/plug.gd"

func _plugging():
    plug("OWNER/godot-racing", {"tag": "addon-v0.1.0"})
```

Replace OWNER with the repository owner. `addon-v0.1.0` is the generated binary distribution tag; `v0.1.0` contains buildable source and does not include compiled libraries. gd-plug clones Git tags; it does not download GitHub Release attachments.

Install while the Godot editor is closed, then import/open the project. This is a runtime addon: no EditorPlugin or Plugins-tab activation is required. Both template_debug (editor/debug) and template_release (exported release) libraries are included in the packaged addon. Retain the license files when redistributing it.

## Usage

```gdscript
extends Node

var wheel: FFBWheel

func _ready() -> void:
    wheel = FFBWheel.new()
    wheel.auto_open = false
    wheel.gain = 0.35
    wheel.inverted = true # Initial Moza R3 force polarity; tune for your setup.
    wheel.open_failed.connect(func(reason): push_error(reason))
    add_child(wheel)
    wheel.open()

func _physics_process(delta: float) -> void:
    wheel.poll(delta)
    if not wheel.is_open():
        return
    # Replace this example centering/damping torque with your game's model.
    var torque := -0.3 * wheel.state.steering - 0.03 * wheel.state.steer_velocity
    wheel.apply_torque(torque)

func pause_forces() -> void:
    wheel.apply_torque(0.0)

func disconnect_wheel() -> void:
    wheel.close()
```

FFBWheel is a Node, automatically closes on removal, reports `opened(device_name)` / `open_failed(reason)` and provides normalized `state.steering`, `throttle`, `brake`, `clutch`, `is_button_pressed(code)`, `set_gain()`, `set_inverted()`, `steering_angle_deg()` and `play_curb()`. Initial R3 ABS codes: steer 0, throttle 2, brake 5; clutch disabled (-1). Override axis codes to match the device. `steering_range_deg` only describes the physical range; it does not configure the hardware.

For a reusable force model, assign an FFBForceModel Resource, fill its FFBState from the game, then call `wheel.update_force(delta)`. Vehicle dynamics and gyroscope models belong in the consuming game. No scenes, gameplay bindings, autoloads or editor settings are installed by the addon.

Low-level API: `FFBManager.list_devices()`, `list_ffb_devices()`, `open_moza()` and `open_device(path)` return FFBDevice instances. A device exposes axis metadata/values, buttons, capabilities, managed constant force, spring/damper/friction, periodic/ramp/rumble effects, gain/autocenter and effect playback/cleanup. Check `get_capabilities()` before choosing effects.

## License

MIT for Godot FFB. The statically linked godot-cpp dependency is MIT; its notice is in `licenses/godot-cpp.txt`.

The upstream gd-plug 0.2.6 installer does not parse on Godot 4.7.2 (`_process` lacks the now-required return value). Use Godot 4.4.1 for projects retaining gd-plug 0.2.6, or install the ZIP directly on 4.7.2. Compatibility tests explicitly use 4.4.1 for the gd-plug consumer and 4.7.2 for clean ZIP consumers; the vendored installer is unmodified.
