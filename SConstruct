#!/usr/bin/env python
# Builds the FFB GDExtension against godot-cpp. The compiled shared library is
# written straight into the demo project so demo/ stays a runnable, static dir.
import os

env = SConscript("godot-cpp/SConstruct")

env.Append(CPPPATH=["src/"])
sources = Glob("src/*.cpp")

libpath = "demo/addons/ffb/bin/libffb{}{}".format(env["suffix"], env["SHLIBSUFFIX"])
library = env.SharedLibrary(libpath, source=sources)

Default(library)
