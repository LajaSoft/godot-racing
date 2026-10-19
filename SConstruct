#!/usr/bin/env python
import os
import shutil
from SCons.Script import ARGUMENTS, Default, Dir, Environment, Exit, Glob, SConscript

# Native Linux evdev backend. Build profiles trim unused Godot C++ bindings.
ARGUMENTS.setdefault("build_profile", Dir("#").abspath + "/build_profile.json")
# Resolve the versioned GCC paths so SCons does not reuse Ubuntu 24 objects
# when a portable Ubuntu 22 release is built in the same checkout.
env = Environment(tools=["default"], PLATFORM="")
for variable, command in [("CC", "gcc"), ("CXX", "g++")]:
    compiler = shutil.which(command)
    if compiler is None:
        raise RuntimeError("Run the build through Docker Compose: " + command + " is missing")
    env[variable] = os.path.realpath(compiler)
env = SConscript("godot-cpp/SConstruct", exports={"env": env})
if env["platform"] != "linux" or env["arch"] != "x86_64":
    print("Godot FFB 0.1 supports Linux x86_64 builds only.")
    Exit(1)
env.Append(CPPPATH=["src/"])
library = env.SharedLibrary(
    "addons/ffb/bin/libffb{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=Glob("src/*.cpp"),
)
Default(library)
