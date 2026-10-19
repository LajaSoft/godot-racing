"""Create a standalone gd-plug-compatible addon archive, with ABI validation."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BINARY_NAMES = [f"libffb.linux.template_{target}.x86_64.so" for target in ("debug", "release")]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_binary(path):
    if not path.is_file() or path.read_bytes()[:4] != b"\x7fELF":
        raise RuntimeError(f"Missing ELF library: {path}. Run docker compose run --rm release.")
    symbols = subprocess.check_output(["readelf", "--dyn-syms", "--wide", str(path)], text=True)
    if not re.search(r"\bffb_library_init\b", symbols):
        raise RuntimeError(f"GDExtension entry point missing from {path}")
    version_info = subprocess.check_output(["readelf", "--version-info", str(path)], text=True)
    limits = {"GLIBC": (2, 35), "GLIBCXX": (3, 4, 30)}
    requirements = {}
    for namespace, limit in limits.items():
        versions = [tuple(map(int, value.split("."))) for value in re.findall(rf"\b{namespace}_([0-9.]+)", version_info)]
        required = max(versions, default=(0,))
        if required > limit:
            raise RuntimeError(f"{path.name} requires {namespace}_{'.'.join(map(str, required))}; rebuild using the portable release service")
        requirements[namespace] = ".".join(map(str, required))
    return requirements


def make_archive(source, destination):
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(source.rglob("*")):
            if not path.is_file():
                continue
            info = zipfile.ZipInfo(path.relative_to(source).as_posix(), (2026, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = (0o100755 if path.name in ("ffbprobe", "ffbtest") else 0o100644) << 16
            archive.writestr(info, path.read_bytes())


def package(output, version):
    if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?", version):
        raise ValueError("Use a semantic version such as 0.1.0 or 0.1.0-rc.1")
    source = ROOT / "addons/ffb"
    if (source / "VERSION").read_text().strip() != version:
        raise RuntimeError("Requested release version differs from addons/ffb/VERSION")
    abi = {name: validate_binary(source / "bin" / name) for name in BINARY_NAMES}
    source_commit = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
    dirty = bool(subprocess.check_output(["git", "-C", str(ROOT), "status", "--porcelain"], text=True).strip())
    metadata = {"name": "godot-ffb", "version": version, "platform": "linux.x86_64",
                "godot_minimum": "4.4", "precision": "single", "license": "MIT",
                "source_commit": source_commit, "source_dirty": dirty,
                "godot_cpp_commit": (ROOT / "godot-cpp.ref").read_text().strip(),
                "distribution_tag": f"addon-v{version}", "abi": abi}
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="godot-ffb-package-") as temporary:
        staging = Path(temporary)
        addon = staging / "addons/ffb"
        addon.mkdir(parents=True)
        for path in sorted(source.rglob("*")):
            if not path.is_file() or path.name == ".gitkeep":
                continue
            relative = path.relative_to(source)
            if relative.parts[0] == "bin" and path.name not in BINARY_NAMES:
                continue
            if path.suffix in (".o", ".os", ".a", ".import"):
                continue
            target = addon / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
        metadata["sha256"] = {path.relative_to(staging).as_posix(): digest(path) for path in sorted(addon.rglob("*")) if path.is_file()}
        (addon / "BUILD.json").write_text(json.dumps(metadata, indent=2) + "\n")
        archive = output / f"godot-ffb-{version}-linux-x86_64.zip"
        make_archive(staging, archive)
    (output / "release.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (output / "SHA256SUMS").write_text(f"{digest(archive)}  {archive.name}\n")
    print(f"Packaged {archive}; source_dirty={dirty}")
    return archive


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default=(ROOT / "addons/ffb/VERSION").read_text().strip())
    parser.add_argument("--output", type=Path, default=ROOT / "dist")
    args = parser.parse_args()
    package(args.output, args.version)


if __name__ == "__main__":
    main()
