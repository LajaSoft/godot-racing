# Changelog

## 0.1.0 — release candidate

- Package the evdev backend, FFBWheel, FFBState and FFBForceModel as `addons/ffb`.
- Preserve demo scene paths through a symlink to the canonical addon.
- Add pinned godot-cpp and gd-plug integration tests, portable debug/release builds, ABI checks, ZIP metadata/checksums and generated binary distribution tags.
- Add MIT licensing and godot-cpp notices.
- Close all effects and reset telemetry when FFBWheel closes; check constant-force initialization and only prepare sine effects when supported.
- Initial distribution target: Linux x86-64 / Godot 4.4+ single precision; USB-connected Moza R3 verified during development.
