# Godot FFB — Moza / Linux

A Linux force-feedback runtime addon for Godot. The repository is still named `godot-racing`; the reusable plugin is `addons/ffb`. Vehicle and Rocket Pong demos remain under `demo/`.

**Initial support:** Linux x86-64, standard single-precision Godot 4.4.1+, directly USB-connected Gudsen/Moza R3 wheel and pedals. The backend uses Linux evdev Force Feedback (`/dev/input/event*`, `EVIOCSFF`), not the Moza SDK. The host needs an FF-capable kernel driver and read/write device permissions. Other wheels may work through `open_device(path)` if their kernel driver exposes supported effects, but are not verified. There is no Windows, macOS or Web backend in 0.1.0; DirectInput is not used.

## Install the release addon

Download/extract `godot-ffb-0.1.0-linux-x86_64.zip` into a Godot project, or declare the prebuilt Git distribution tag with gd-plug:

```gdscript
extends "res://addons/gd-plug/plug.gd"

func _plugging():
    plug("OWNER/godot-racing", {"tag": "addon-v0.1.0"})
```

Replace OWNER with the eventual GitHub owner. The repository currently has no remote and the release tags are not published yet. Install through your Godot/gd-plug environment, with the editor closed. No compiler or Docker is required by consumers of the prebuilt addon. The extension imports automatically; it is not an EditorPlugin requiring activation.

`v0.1.0` is a source tag. `addon-v0.1.0` is an automatically generated snapshot containing the compiled addon. gd-plug copies the repository's `addons/` tree and does not fetch Release ZIP attachments, so these two tags serve different purposes. Both `template_debug` and `template_release` libraries are included in the binary distribution.

See [the standalone addon README](addons/ffb/README.md) for the API and [release instructions](docs/RELEASING.md) for publishing.

## API

```gdscript
extends Node

var wheel: FFBWheel

func _ready() -> void:
    wheel = FFBWheel.new()
    wheel.auto_open = false
    wheel.gain = 0.35
    wheel.open_failed.connect(func(reason): push_error(reason))
    add_child(wheel)
    wheel.open()

func _physics_process(delta: float) -> void:
    wheel.poll(delta)
    if not wheel.is_open():
        return
    var torque := -0.3 * wheel.state.steering - 0.03 * wheel.state.steer_velocity
    wheel.apply_torque(torque)
```

`FFBWheel` provides normalized steering/pedals/buttons, torque output, physical angle conversion and lifecycle cleanup. Its optional `FFBForceModel` Resource converts `FFBState` into normalized torque. Game-specific vehicle and gyroscope models stay outside the plugin.

`FFBManager` enumerates devices and opens Moza automatically or another device by path. `FFBDevice` exposes constant, spring, damper, friction, periodic, ramp and rumble effects plus playback, gain/autocenter and axis metadata. Query `get_capabilities()` because effect support depends on the device/kernel. Initial R3 ABS codes are steering 0, throttle 2 and brake 5; force inversion defaults to true. The addon does not configure wheel firmware, physical lock or pedal calibration.

## Build and test in Docker

```bash
# Reproducible portable release candidate, including installation tests
docker compose run --rm release

# Individual developer tasks
docker compose run --rm build
docker compose run --rm build-release
docker compose run --rm tools
docker compose run --rm test
docker compose run --rm package

# Verify the same compiled libraries on the newer Godot runtime
docker compose run --rm test bash scripts/test_compatibility.sh 4.7.2-stable
```

Release builds use Ubuntu 22.04 (glibc 2.35 / GLIBCXX_3.4.30 baseline), pinned godot-cpp commit from `godot-cpp.ref`, and a minimal binding profile. The baseline runtime is Godot 4.4.1; CI also verifies Godot 4.7.2. Prebuilt libraries are single precision and Linux x86-64 only. Packaging rejects binaries requiring a newer libc/libstdc++ baseline; after a developer build on Ubuntu 24.04, use the `release` service to regenerate portable binaries.

The source branch ignores compiled libraries. Output is under `dist/`: the standalone addon ZIP, SHA256SUMS and machine-readable provenance. `BUILD.json` inside the addon records the source commit, dirty status, godot-cpp commit, ABI requirements and each payload file's SHA256. Local uncommitted candidates are allowed for inspection but cannot pass the publish script's provenance checks.

Tests install the ZIP into an empty project, load both native template libraries, verify classes/methods and model behavior, then use the real vendored gd-plug 0.2.6 to install/reinstall/uninstall the package from a temporary local Git tag. No input device is opened and no force is sent. Runtime script errors fail the test even when Godot returns exit code zero. The GitHub workflow builds, tests and uploads candidates; pushing a matching `v*` source tag additionally creates the immutable `addon-v*` tag and a draft GitHub Release. See [RELEASING.md](docs/RELEASING.md).

## Existing demos and desktop container

```bash
docker compose run --rm build
# Host device discovery, without playing any effects:
docker compose run --rm wheel
# NVIDIA + input devices + host XWayland:
docker compose run --rm gui
```

`demo/addons/ffb` links to the canonical root addon, so existing `res://addons/ffb` references and the historical binary path still resolve. The user's selected scene and local demo edits are retained. Force-producing demos and `dist/ffbtest` run only when launched explicitly.

The GUI service retains the existing desktop setup: NVIDIA Container Toolkit, `/dev/input`, `/run/user/1000`, X11 sockets, host DISPLAY/XAUTHORITY and input group 995. Set XAUTHORITY to your desktop cookie under the mounted runtime directory. Build containers default to UID/GID 1000; override LOCAL_UID/LOCAL_GID and INPUT_GID when needed. Native Wayland can be selected by overriding the GUI command. The default demo uses dummy audio.

The default Dockerfile stage remains the Ubuntu 24.04 runtime/toolchain image (`godot-ffb-build`), preserving FoldRoom's current build-context and binary-copy integration. The separate `portable` stage is used for releases. Neither project nor repository has been renamed.

## License

MIT. See [LICENSE](LICENSE), [third-party notices](THIRD_PARTY.md) and the godot-cpp notice shipped with the addon.

The upstream gd-plug 0.2.6 installer does not parse on Godot 4.7.2 (`_process` lacks the now-required return value). Use Godot 4.4.1 for projects retaining gd-plug 0.2.6, or install the ZIP directly on 4.7.2. Compatibility tests explicitly use 4.4.1 for the gd-plug consumer and 4.7.2 for clean ZIP consumers; the vendored installer is unmodified.
