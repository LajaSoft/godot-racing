#!/usr/bin/env bash
set -euo pipefail
version=${1:?Pass an official Godot release version}
case "$version" in
  *[!0-9A-Za-z.-]*) echo "Invalid Godot version" >&2; exit 1 ;;
esac
runtime_dir=$(mktemp -d /tmp/godot-ffb-runtime.XXXXXX)
curl -fL -o "$runtime_dir/godot.zip" \
  "https://github.com/godotengine/godot/releases/download/${version}/Godot_v${version}_linux.x86_64.zip"
unzip -q "$runtime_dir/godot.zip" -d "$runtime_dir"
GD_PLUG_GODOT_BIN=godot GODOT_BIN="$runtime_dir/Godot_v${version}_linux.x86_64" python3 scripts/test_release.py
