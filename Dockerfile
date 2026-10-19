# syntax=docker/dockerfile:1
ARG GODOT_VERSION=4.4.1-stable

# Portable release compiler: glibc 2.35 / libstdc++ from Ubuntu 22.04.
FROM ubuntu:22.04 AS portable
ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential scons python3 git ca-certificates curl unzip binutils libfontconfig1
ARG GODOT_VERSION
RUN curl -fL -o /tmp/godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
    && unzip -q /tmp/godot.zip -d /tmp \
    && install -m 755 "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot \
    && rm /tmp/godot.zip "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64"
WORKDIR /work

# Keep the existing desktop/build image contract for FoldRoom and racing.
FROM ubuntu:24.04 AS runtime
ENV DEBIAN_FRONTEND=noninteractive
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    build-essential scons python3 git ca-certificates gcc make curl unzip binutils \
    libgl1 libegl1 libvulkan1 \
    libx11-6 libxcursor1 libxinerama1 libxrandr2 libxi6 libxext6 libxrender1 libxfixes3 libxcb1 \
    libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 libdecor-0-0 \
    libfontconfig1 libfreetype6 libdbus-1-3 dbus dbus-x11 libudev1 \
    libasound2t64 libpulse0 libspeechd2 vulkan-tools
ARG GODOT_VERSION
RUN curl -fL -o /tmp/godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.x86_64.zip" \
    && unzip -q /tmp/godot.zip -d /tmp \
    && install -m 755 "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64" /usr/local/bin/godot \
    && rm /tmp/godot.zip "/tmp/Godot_v${GODOT_VERSION}_linux.x86_64"
WORKDIR /work
