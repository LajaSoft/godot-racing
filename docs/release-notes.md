Godot FFB 0.1.0 — initial Linux/Moza runtime addon.

- gd-plug-compatible prebuilt distribution tag: `addon-v0.1.0`.
- Linux x86-64, Godot 4.4+ single precision; checked against Godot 4.4.1 and 4.7.2.
- Direct USB Gudsen/Moza R3 wheel and pedals are the verified hardware target.
- Native Linux evdev constant/condition/periodic/ramp/rumble effect API, normalized axes/buttons and reusable GDScript wheel/state/force model.
- Debug and release libraries built against the Ubuntu 22.04 ABI (glibc 2.35+, GLIBCXX_3.4.30+).
- MIT license; includes godot-cpp attribution.

The host kernel must provide the wheel's FF-capable input device. No Moza SDK, kernel driver, wheel firmware setup, Windows/macOS/Web backend or other-model hardware verification is included. Check the addon README for setup and API details.

This release is prepared as a draft so hardware verification and the final release description can be reviewed before publication.
