"""Runs the project's checks.

    .venv/Scripts/python tools/test.py

- the vendored design files still match their manifest;
- src/core/theme.lua is what tools/theme.py generates from them;
- every Lua file compiles on the Lua its radio runs: EdgeTX is 5.2, Ethos
  is 5.4, and the shared core must run on both;
- the core's tests pass on both.

The SITL checks are separate (tests/sitl_test.py) because they need the
simulator running in WSL.
"""
import hashlib
import importlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import theme  # noqa: E402

# Which Lua versions each source tree must compile on.
TREES = {"src/core": ("lua53", "lua54"), "src/edgetx": ("lua53",), "src/ethos": ("lua54",)}

failures = []


def runtime(version):
    return importlib.import_module("lupa." + version).LuaRuntime()


def read(path):
    return (ROOT / path).read_text(encoding="utf-8")


def md5(path):
    return hashlib.md5(path.read_text(encoding="utf-8").replace("\r\n", "\n").encode("utf-8")).hexdigest()


def check_vendored():
    manifest = json.loads((ROOT / "design" / "lofted-aero.json").read_text(encoding="utf-8"))
    edited = [f for f, h in manifest["files"].items() if md5(ROOT / "design" / f) != h]
    edited += [f for f, h in manifest.get("docs", {}).items() if md5(ROOT / "docs" / "lofted-aero" / f) != h]
    if edited:
        failures.append("edited here, but vendored from lofted-aero-design %s: %s. Change them upstream and "
                        "vendor the release." % (manifest["version"], ", ".join(edited)))


def check_theme():
    if read("src/core/theme.lua") != theme.generate():
        failures.append("src/core/theme.lua is stale or hand-edited: run tools/theme.py")


def check_compiles():
    runtimes = {}
    for tree, versions in TREES.items():
        for path in sorted((ROOT / tree).rglob("*.lua")):
            rel = path.relative_to(ROOT).as_posix()
            for version in versions:
                rt = runtimes.setdefault(version, runtime(version))
                err = rt.eval('function(text, name) local _, err = load(text, "@" .. name) return err end')(
                    read(rel), rel)
                if err:
                    failures.append("%s does not compile on %s: %s" % (rel, version, err))


def run_tests():
    total = 0
    for version in ("lua53", "lua54"):
        for path in sorted((ROOT / "tests").glob("*_test.lua")):
            rel = path.relative_to(ROOT).as_posix()
            rt = runtime(version)
            h = rt.eval('function(text, read) return assert(load(text, "@tests/lib/harness.lua"))(read) end')(
                read("tests/lib/harness.lua"), read)
            err = rt.eval('function(text, name, h) local ok, err = pcall(assert(load(text, "@" .. name)), '
                          'h.use, h.T) if not ok then return tostring(err) end end')(read(rel), rel, h)
            if err:
                failures.append("%s on %s stopped: %s" % (rel, version, err))
            t = h["T"]
            total += t["passed"]
            for msg in t["failures"].values():
                failures.append("%s on %s: %s" % (rel, version, msg))
    return total


def main():
    check_vendored()
    check_theme()
    check_compiles()
    passed = run_tests()
    for f in failures:
        print("FAIL " + f)
    print("%d test cases passed, %d failures" % (passed, len(failures)))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
