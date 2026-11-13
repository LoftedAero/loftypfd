"""Assembles what goes on each radio, and copies it to the simulators.

    .venv/Scripts/python tools/build.py [--replay out/flight-crsf.txt]
        [--menu out/gyro-menu.txt] [--maps out/maps] [--capture]
        [--edgetx] [--ethos] [--sd DRIVE]

dist/edgetx/WIDGETS/LoftyPFD/ and dist/ethos/scripts/loftypfd/ each get the
platform's scripts and the shared core; EdgeTX's tool goes to
dist/edgetx/SCRIPTS/TOOLS/LoftyPFD.lua and loads the widget's core. The voice
clips (tools/voice.py) go beside the Ethos scripts in audio/en, and to EdgeTX's
SOUNDS/en/lofty, since EdgeTX plays no sound path longer than 42 characters.

Two development additions stand in for what a simulator lacks, and never
ship: --replay adds a SITL recording as replay.txt, which the widget plays in
place of a telemetry link, and --menu a recorded device menu as menu.txt
(tools/sitl.py menu), which the device browser browses in place of the link,
with tools/snapshot.lua answering from it. --maps copies a folder of map tiles
as Lofty GCS's "Copy to radio" writes them (index.txt and <layer>/<z>/<x>/<y>.jpg)
into the widget's maps folder. --capture makes an Ethos test build, which
records its link for tools/hwtest.py (core/capture.lua).

--edgetx copies the widget onto the TX15 simulator's SD card
(out/edgetx-tx15/sd, the SD path of Companion's profile 0), seeding radio
settings and a model the first time. Start the simulator with
    "C:\\Program Files\\EdgeTX\\Companion 2.12\\bin\\simulator.exe" -p 0 -w sd
or pick Reload > Reload Lua scripts in one already running.

--ethos copies into Ethos Suite's simulator storage, after which Ethos Suite
needs Reload; the widget then goes on a screen through Configure screens.

--sd copies the build onto a radio's SD card (the radio in USB storage
mode), over what is there, by the same rules Lofty GCS installs with: the
maps Lofty GCS copied and earlier captures stay, and what this build no
longer has is removed. --radio says which radio, where the card does not.

--package writes dist/LoftyPFD_<version>_<radio>.zip, each laid out as the
card's root, for installing by hand from a release.

--manifest writes manifest.json, the release's file list and install rules,
which Lofty GCS downloads (docs/architecture.md, "Installing from Lofty
GCS"); tools/test.py fails when it is out of date.
"""
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
TARGETS = {
    "edgetx": ("WIDGETS/LoftyPFD", ROOT / "src" / "edgetx"),
    "ethos": ("scripts/loftypfd", ROOT / "src" / "ethos"),
}
# Where the voice clips go, by platform, from the platform's root.
CLIPS = {"edgetx": "SOUNDS/en/lofty", "ethos": "scripts/loftypfd/audio/en"}
# Files only a development build has, beside the widget's scripts.
DEV_FILES = ("replay.txt", "menu.txt", "capture.on", "core/snapshot.lua")
# Scripts that live outside the widget's folder, by platform.
ELSEWHERE = {"edgetx": {"tool.lua": "SCRIPTS/TOOLS/LoftyPFD.lua"}}
EDGETX_SD = ROOT / "out" / "edgetx-tx15" / "sd"
# What a card holds that says which radio it belongs to, as seen on an X20's
# drives and EdgeTX's SD layout: Ethos's SD card and internal storage, and
# EdgeTX's radio settings.
SIGNS = {"edgetx": ["RADIO/radio.yml"], "ethos": ["sdcard.cpuid", "radio.cpuid"]}
REPOSITORY = "LoftedAero/loftypfd"
MANIFEST = ROOT / "manifest.json"


def plan(name):
    """The release's files for one radio: (source in the repository, path on
    the card). The build, an install and the manifest all come from this."""
    folder, src = TARGETS[name]
    elsewhere = ELSEWHERE.get(name, {})
    out = []
    for f in sorted(src.glob("*.lua")) + sorted(src.glob("*.png")):
        out.append((f, elsewhere.get(f.name, folder + "/" + f.name)))
    for f in sorted((ROOT / "src" / "core").glob("*.lua")):
        out.append((f, folder + "/core/" + f.name))
    audio = ROOT / "src" / "audio" / "en"
    # The voice's license asks for its credit to go with the clips.
    for f in sorted(audio.glob("*.wav")) + [audio / "CREDITS.txt"]:
        out.append((f, CLIPS[name] + "/" + f.name))
    return out


def rules(name):
    """How an install treats what is already on the card: in an owned folder,
    a file the release no longer has is removed; anything matching `remove`
    goes (compiled scripts the radio made from the old source, and what only a
    development build adds); everything else stays (maps, captures)."""
    folder = TARGETS[name][0]
    owned = [folder + "/core", CLIPS[name]]
    remove = [folder + "/**/*.luac"] + [p[:-4] + ".luac" for p in ELSEWHERE.get(name, {}).values()]
    remove += [folder + "/" + d for d in DEV_FILES if not d.startswith("core/")]
    return owned, remove


def manifest():
    """manifest.json's text: the version, and for each radio its files (from
    the repository at the release's tag) and install rules."""
    radios = {}
    for name in sorted(TARGETS):
        owned, remove = rules(name)
        radios[name] = {
            "folder": TARGETS[name][0],
            "signs": SIGNS[name],
            "files": [{"from": f.relative_to(ROOT).as_posix(), "to": to, "size": f.stat().st_size,
                       "sha256": hashlib.sha256(f.read_bytes()).hexdigest()} for f, to in plan(name)],
            "owned": owned,
            "remove": remove,
        }
    data = {
        "format": 1,
        "name": "Lofty PFD",
        "version": (ROOT / "VERSION").read_text(encoding="utf-8").strip(),
        "repository": REPOSITORY,
        "files": "https://raw.githubusercontent.com/%s/v{version}/{from}" % REPOSITORY,
        "radios": radios,
    }
    return json.dumps(data, indent=1) + "\n"


def ethos_storage():
    sim = pathlib.Path(os.environ["APPDATA"]) / "Ethos Suite" / ".simulator"
    version = sorted(d for d in sim.iterdir() if d.name[0].isdigit())[-1]
    persist = version / "persist"
    return next(persist.iterdir())


def build(replay, menu, maps=None, capture=False):
    for name, (folder, src) in TARGETS.items():
        if (DIST / name).exists():
            shutil.rmtree(DIST / name)
        out = DIST / name / folder
        for f, to in plan(name):
            dest = DIST / name / to
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(f, dest)
        if replay:
            shutil.copy2(replay, out / "replay.txt")
        if menu:
            shutil.copy2(menu, out / "menu.txt")
            shutil.copy2(ROOT / "tools" / "snapshot.lua", out / "core" / "snapshot.lua")
        if maps:
            shutil.copytree(maps, out / "maps")
        if capture and name == "ethos":
            (out / "capture.on").write_text("")
        print("built " + (DIST / name).relative_to(ROOT).as_posix())


def package():
    """A zip per radio of the release's files, laid out as the card's root."""
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    for name in sorted(TARGETS):
        out = DIST / ("LoftyPFD_%s_%s.zip" % (version, name))
        out.parent.mkdir(exist_ok=True)
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for f, to in plan(name):
                z.write(f, to)
        print("wrote " + out.relative_to(ROOT).as_posix())


def seed_edgetx_sd():
    """Gives a fresh simulator SD card radio settings and a model whose one
    screen is Lofty PFD, full size (tools/edgetx-sim, generated by the TX15
    simulator and edited). The simulator refuses an SD card without them."""
    if (EDGETX_SD / "RADIO" / "radio.yml").exists():
        return
    for sub in ("RADIO", "MODELS"):
        (EDGETX_SD / sub).mkdir(parents=True, exist_ok=True)
        for f in (ROOT / "tools" / "edgetx-sim" / sub).iterdir():
            shutil.copy2(f, EDGETX_SD / sub / f.name)
    print("seeded radio settings and a model on " + str(EDGETX_SD))


def copy(name, dest_root):
    folder = TARGETS[name][0]
    dest = dest_root / folder
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(DIST / name / folder, dest)
    for path in ELSEWHERE.get(name, {}).values():
        (dest_root / path).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(DIST / name / path, dest_root / path)
    clips = dest_root / CLIPS[name]
    if not clips.is_relative_to(dest):
        if clips.exists():
            shutil.rmtree(clips)
        shutil.copytree(DIST / name / CLIPS[name], clips)
    print("copied to " + str(dest))


def install(name, dest_root):
    """Copies a build over a radio's card by the release's rules (rules()),
    as Lofty GCS does: maps and captures stay."""
    built = DIST / name
    have = {p.relative_to(built).as_posix() for p in built.rglob("*") if p.is_file()}
    owned, remove = rules(name)
    for pattern in remove:
        for old in list(dest_root.glob(pattern)):
            if old.is_file() and old.relative_to(dest_root).as_posix() not in have:
                old.unlink()
    for folder in owned:
        for old in list((dest_root / folder).rglob("*")) if (dest_root / folder).exists() else []:
            if old.is_file() and old.relative_to(dest_root).as_posix() not in have:
                old.unlink()
    for rel in sorted(have):
        (dest_root / rel).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(built / rel, dest_root / rel)
    print("installed on %s (%s)" % (dest_root / TARGETS[name][0], name))


def radio_of(card):
    """Which radio a card is from, by what it holds, or None."""
    found = {name for name, signs in SIGNS.items() if any((card / s).exists() for s in signs)}
    found |= {name for name, (folder, _) in TARGETS.items() if (card / folder).exists()}
    return found.pop() if len(found) == 1 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--replay", type=pathlib.Path)
    ap.add_argument("--menu", type=pathlib.Path)
    ap.add_argument("--maps", type=pathlib.Path)
    ap.add_argument("--capture", action="store_true", help="an Ethos test build that records its link")
    ap.add_argument("--edgetx", action="store_true", help="copy to the TX15 simulator's SD card")
    ap.add_argument("--ethos", action="store_true", help="copy to Ethos Suite's simulator storage")
    ap.add_argument("--sd", type=pathlib.Path, help="install the build on a radio's SD card")
    ap.add_argument("--radio", choices=sorted(TARGETS), help="which radio the --sd card is from")
    ap.add_argument("--manifest", action="store_true", help="write manifest.json for a release")
    ap.add_argument("--package", action="store_true", help="zip each radio's files for a release")
    args = ap.parse_args()
    if args.package:
        package()
        return
    if args.manifest:
        MANIFEST.write_text(manifest(), encoding="utf-8", newline="\n")
        print("wrote manifest.json")
        return
    build(args.replay, args.menu, args.maps, args.capture)
    if args.edgetx:
        seed_edgetx_sd()
        copy("edgetx", EDGETX_SD)
    if args.ethos:
        copy("ethos", ethos_storage())
    if args.sd:
        # "G:" alone is that drive's current folder to Windows, not its root.
        sd = args.sd
        if len(str(sd)) == 2 and str(sd)[1] == ":":
            sd = pathlib.Path(str(sd) + "\\")
        radio = args.radio or radio_of(sd)
        if not radio:
            raise SystemExit("cannot tell which radio %s is from: give --radio ethos or --radio edgetx" % sd)
        install(radio, sd)


if __name__ == "__main__":
    main()
