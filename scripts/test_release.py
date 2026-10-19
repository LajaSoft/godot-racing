"""Install the real release ZIP and gd-plug tag into clean Godot projects."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("package_release", ROOT / "scripts/package_release.py")
PACKAGER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKAGER)
GODOT = os.environ.get("GODOT_BIN", "godot")
GD_PLUG_GODOT = os.environ.get("GD_PLUG_GODOT_BIN", GODOT)


def run(command, cwd=None, env=None, gd_plug=False):
    result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    print(result.stdout, end="", flush=True)
    # Upstream 0.2.6's async completion signal calls request_quit() with -1,
    # producing POSIX status 255 on success too. Accept that only for gd-plug,
    # only after a complete run without errors; installation hashes are checked below.
    valid_exit = result.returncode == 0 or (gd_plug and result.returncode == 255 and "Finished, elapsed" in result.stdout)
    if not valid_exit or any(marker in result.stdout for marker in ("SCRIPT ERROR:", "SHADER ERROR:", "ERROR:", "FFB TEST FAIL:", "[ERROR]", "Failed to")):
        raise RuntimeError(f"Command exited {result.returncode}: {command}")
    if gd_plug and result.returncode == 255:
        print("NOTE gd-plug 0.2.6 upstream async exit=255; checking completed installation independently")
    return result.stdout


def consumer(path, template="smoke.gd"):
    path.mkdir(parents=True, exist_ok=True)
    (path / "project.godot").write_text('config_version=5\n[application]\nconfig/name="FFB package tests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copyfile(ROOT / "tests/smoke.gd", path / template)


def import_project(path, godot=GODOT):
    # Godot #111048: immediate headless shutdown races extension documentation.
    # Allow editor frames to complete; never retry or accept a crashed import.
    run([godot, "--headless", "--path", str(path), "--editor",
         "--quit-after", "120", "--frame-delay", "20"])


def smoke(path, godot=GODOT):
    import_project(path, godot)
    run([godot, "--headless", "--path", str(path), "--check-only", "--script", "res://smoke.gd"])
    output = run([godot, "--headless", "--path", str(path), "--script", "res://smoke.gd"])
    if "FFB TEST RESULT:" not in output or "0 failures; hardware not opened" not in output:
        raise RuntimeError("Smoke script did not complete")


def verify_archive(archive):
    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        if not names or any(not name.startswith("addons/ffb/") or ".." in Path(name).parts for name in names):
            raise RuntimeError("Archive contains files outside addons/ffb")
        if any("demo/" in name or "godot-cpp/" in name or "/.git/" in name for name in names):
            raise RuntimeError("Development-only files leaked into release")
        metadata = json.loads(z.read("addons/ffb/BUILD.json"))
        for name, expected in metadata["sha256"].items():
            if hashlib.sha256(z.read(name)).hexdigest() != expected:
                raise RuntimeError(f"Checksum mismatch: {name}")
        for binary in PACKAGER.BINARY_NAMES:
            if "addons/ffb/bin/" + binary not in names:
                raise RuntimeError(f"Missing binary {binary}")
    print("PASS standalone archive scope, debug/release libraries, licenses and hashes")


def main():
    version = (ROOT / "addons/ffb/VERSION").read_text().strip()
    with tempfile.TemporaryDirectory(prefix="godot-ffb-install-") as temporary:
        workspace = Path(temporary)
        archive = PACKAGER.package(workspace / "packages", version)
        verify_archive(archive)
        direct = workspace / "direct"
        consumer(direct)
        with zipfile.ZipFile(archive) as z:
            z.extractall(direct)
        smoke(direct)
        # Check release template selection without duplicating a large export-template
        # download: load the release binary through a temporary debug mapping too.
        manifest = direct / "addons/ffb/ffb.gdextension"
        original = manifest.read_text()
        manifest.write_text(original.replace("template_debug", "template_release"))
        smoke(direct)
        print("PASS both native template libraries load and expose the same API")

        distribution = workspace / "distribution"
        distribution.mkdir()
        with zipfile.ZipFile(archive) as z:
            z.extractall(distribution)
        run(["git", "init", "-b", "main"], cwd=distribution)
        run(["git", "add", "addons"], cwd=distribution)
        run(["git", "-c", "user.name=Godot FFB Tests", "-c", "user.email=tests@invalid.example", "commit", "-m", "Local binary distribution fixture"], cwd=distribution)
        run(["git", "tag", f"addon-v{version}"], cwd=distribution)
        bare = workspace / "godot-ffb.git"
        run(["git", "clone", "--bare", str(distribution), str(bare)])
        project = workspace / "gd-plug-consumer"
        consumer(project)
        gd_plug = project / "addons/gd-plug"
        gd_plug.mkdir(parents=True)
        shutil.copyfile(ROOT / "tests/vendor/gd-plug/plug.gd", gd_plug / "plug.gd")
        (project / "plug.gd").write_text('extends "res://addons/gd-plug/plug.gd"\nfunc _plugging():\n    plug(' + json.dumps(bare.as_uri()) + ', {"tag": "addon-v' + version + '"})\n')
        run([GD_PLUG_GODOT, "--headless", "--path", str(project), "--script", "plug.gd", "install"], gd_plug=True)
        installed = project / "addons/ffb"
        if not (installed / "bin" / PACKAGER.BINARY_NAMES[0]).is_file():
            raise RuntimeError("gd-plug did not install a usable native addon")
        if (project / "demo").exists() or (project / "src").exists():
            raise RuntimeError("gd-plug copied development files")
        with zipfile.ZipFile(archive) as z:
            for name in z.namelist():
                if (project / name).read_bytes() != z.read(name):
                    raise RuntimeError("gd-plug installed different bytes: " + name)
        smoke(project, GD_PLUG_GODOT)
        # A second install must be idempotent; never use gd-plug's force flag.
        run([GD_PLUG_GODOT, "--headless", "--path", str(project), "--script", "plug.gd", "install"], gd_plug=True)
        run([GD_PLUG_GODOT, "--headless", "--path", str(project), "--script", "plug.gd", "uninstall"], gd_plug=True)
        if installed.exists():
            raise RuntimeError("gd-plug uninstall left addon files behind")
        print("PASS actual gd-plug 0.2.6 install, repeat install, import and uninstall")
        # The demo keeps its historical res:// paths through a single symlink.
        link = ROOT / "demo/addons/ffb"
        if not link.is_symlink() or link.resolve() != (ROOT / "addons/ffb").resolve():
            raise RuntimeError("Demo no longer resolves the canonical addon")
        print("PASS demo path compatibility; no duplicate addon implementation")
    print("FFB RELEASE TESTS PASSED (no physical input devices opened)")


if __name__ == "__main__":
    main()
