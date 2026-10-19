# Run through Docker Compose; no host toolchain is required.
GODOT_CPP_REF ?= $(shell cat godot-cpp.ref)
JOBS ?= 4
VERSION := $(shell cat addons/ffb/VERSION)

.PHONY: all setup build build-release tools test package release help
all: build

setup:
	python3 scripts/setup_dependency.py --ref $(GODOT_CPP_REF)

build: setup
	scons -j$(JOBS) platform=linux arch=x86_64 target=template_debug

build-release: setup
	scons -j$(JOBS) platform=linux arch=x86_64 target=template_release

tools:
	mkdir -p dist
	gcc -O2 -Wall -Wextra -Werror -o dist/ffbprobe tools/ffbprobe.c
	gcc -O2 -Wall -Wextra -Werror -o dist/ffbtest tools/ffbtest.c

test:
	python3 -m unittest discover -s tests -p "test_*.py"
	python3 scripts/test_release.py

package:
	python3 scripts/package_release.py --version $(VERSION)

release: build build-release tools test package

help:
	@echo "docker compose run --rm build          Build debug extension"
	@echo "docker compose run --rm build-release  Build release extension"
	@echo "docker compose run --rm release        Portable build, tests and release ZIP"
	@echo "docker compose run --rm test           Test standalone ZIP/gd-plug installation"
	@echo "docker compose run --rm package        Package both compiled libraries"
