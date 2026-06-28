# Build-only wrapper. Runs INSIDE the Docker build image (see compose.yml).
# The host never runs make — host steps (udev, running the demo) are plain
# shell commands, see README.

GODOT_CPP_BRANCH ?= 4.4
JOBS ?= $(shell nproc)

.PHONY: all build build-release tools clean distclean setup help

all: build

# Clone godot-cpp matching your Godot version (idempotent).
setup: godot-cpp/SConstruct
godot-cpp/SConstruct:
	git clone --depth 1 --branch $(GODOT_CPP_BRANCH) \
		https://github.com/godotengine/godot-cpp.git godot-cpp

# Debug library -> demo/addons/ffb/bin/libffb.linux.template_debug.x86_64.so
# This is what the Godot editor / a debug run loads.
build: setup
	scons -j$(JOBS) platform=linux target=template_debug

# Release library, for exported/release runs.
build-release: setup
	scons -j$(JOBS) platform=linux target=template_release

# Standalone C utilities (no Godot) to verify the wheel on the host quickly.
tools:
	mkdir -p dist
	gcc -O2 -Wall -o dist/ffbprobe tools/ffbprobe.c
	gcc -O2 -Wall -o dist/ffbtest  tools/ffbtest.c
	@echo "built dist/ffbprobe and dist/ffbtest"

# Remove build artifacts but keep the godot-cpp checkout.
clean:
	scons -c platform=linux target=template_debug || true
	scons -c platform=linux target=template_release || true
	rm -rf dist

# Also drop the godot-cpp checkout.
distclean: clean
	rm -rf godot-cpp

help:
	@echo "make setup          - clone godot-cpp ($(GODOT_CPP_BRANCH))"
	@echo "make build          - build debug GDExtension into demo/"
	@echo "make build-release  - build release GDExtension"
	@echo "make tools          - build standalone C probe/test tools into dist/"
	@echo "make clean          - remove build artifacts"
