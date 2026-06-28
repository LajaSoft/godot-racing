# Build environment for the FFB GDExtension, plus a Godot runtime so the demo
# can be run inside the container (GPU via nvidia-container-toolkit on the host,
# display via the host's Wayland socket / XWayland).
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Toolchain (godot-cpp + src + C tools) and Godot GUI runtime libraries.
RUN apt-get update && apt-get install -y --no-install-recommends \
		build-essential scons python3 git ca-certificates gcc make curl unzip \
		# GL / Vulkan
		libgl1 libegl1 libvulkan1 \
		# X11 / XWayland client libs
		libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 libxfixes3 libxcb1 \
		# native Wayland client libs
		libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 libdecor-0-0 \
		# fonts / dbus (+ session bus) / udev / audio / TTS / vulkan diag
		libfontconfig1 libfreetype6 libdbus-1-3 dbus dbus-x11 libudev1 \
		libasound2t64 libpulse0 libspeechd2 vulkan-tools \
	&& rm -rf /var/lib/apt/lists/*

# Godot 4.4.1 (matches the host Godot) for running the demo in-container.
ARG GODOT_VERSION=4.4.1-stable
RUN curl -fL -o /tmp/godot.zip \
		"https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
	&& unzip -q /tmp/godot.zip -d /tmp \
	&& mv "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot \
	&& chmod +x /usr/local/bin/godot \
	&& rm /tmp/godot.zip

WORKDIR /work
