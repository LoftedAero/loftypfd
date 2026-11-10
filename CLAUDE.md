# Lofty PFD: notes for AI coding agents

A telemetry display and setup tool for RC radios flying ArduPilot: a widget for Ethos (FrSky
X20 and family) and EdgeTX color radios, in the style of Lofty GCS, that also sets up Lofted
Aero's gyro firmware over CRSF. GPL-3.0. Plain Lua, no build step on the radio.

## Read first

- `docs/architecture.md`: layering, the telemetry and device-menu protocols and their traps,
  the platforms' Lua, and the development loop. Imported at the end of this file.
- `docs/lofted-aero/`: the shared Lofted Aero design rules (vendored; see below).

## Keeping the docs current

A protocol, platform or tooling trap, or a design decision, goes into `docs/architecture.md`
in the same change, stated briefly with its reason, not the story of how it was found. This
file holds only agent rules.

## Rules that must not break

**Clean room.** Nothing here is copied from the Yaapu Telemetry Script or the ExpressLRS Lua
script. Protocol facts come from ArduPilot's encoders and the CRSF specification.
`C:\Users\ericm\PFD` is an earlier Yaapu fork: context only, never a source.

**Layering.** `src/core` is plain Lua with no radio API: it runs on EdgeTX's Lua 5.3 (32-bit
integers, single-precision floats) and Ethos's Lua 5.4 alike. So bit fields use the integer
operators masked to 32 bits, never float division; strings are called as `string.sub(s, ...)`,
never `s:sub(...)` (EdgeTX strings have no methods); no `os`, `utf8` or `string.pack`. It
reaches nothing but its arguments and the standard library; the tests load it with globals
locked and string methods removed. `src/ethos` and `src/edgetx` are the only places a
platform API appears.

**The frame budget.** Radios stop a script after about 20,000 Lua instructions per draw call.
`tests/hud_test.lua` holds the HUD's share; measure on the simulators after changing it
(`docs/architecture.md`, "The instruction budget").

**Never draw a value the aircraft did not send.** State starts nil and a screen shows a
dash; colors come from the aircraft's own thresholds or not at all.

**Design system.** `design/` and `docs/lofted-aero/` are vendored from
`C:\Users\ericm\lofted-aero-design` and checked against `design/lofted-aero.json`; never edit
them here. `src/core/theme.lua` is generated from them by `tools/theme.py`; never edit it by
hand.

**No explanatory prose on screens.** A screen is controls and readings. A hint says the one
thing needed at that moment; reasons go in code comments.

**Comments say why, briefly.** Not what the code does, and not its history.

**American English** in code, comments, UI strings and docs. Third-party identifiers keep
their spelling.

**SITL is the acceptance target.** Telemetry decoding and the device menu are checked against
ArduPilot SITL (`tests/sitl_test.py`), not only against hand-built frames.

**Other repositories.** `C:\Users\ericm\loftgcs` is read-only from here. Changes to the gyro
firmware (WSL `~/ardupilot-gyro`) need Eric's agreement first.

## Files

UTF-8 with LF line endings. After a scripted edit, check the tail of the file survived.

## Commands

```
py -3.14 -m venv .venv && .venv/Scripts/python -m pip install -r tools/requirements.txt
.venv/Scripts/python tools/test.py        design files, theme, compile on 5.3/5.4, core tests
.venv/Scripts/python tests/sitl_test.py   the core against gyro SITL in WSL (a few minutes)
.venv/Scripts/python tools/theme.py       regenerate src/core/theme.lua
.venv/Scripts/python tools/icons.py       redraw the bitmaps in src/icons and src/ethos
.venv/Scripts/python tools/sitl.py record out/flight.txt [--passthrough]
.venv/Scripts/python tools/sitl.py menu out/gyro-menu.txt
.venv/Scripts/python tools/build.py [--replay out/flight-crsf.txt] [--menu out/gyro-menu.txt] [--edgetx] [--ethos]
node tools/ethos-sim/run.cjs --models out/ethos/models [--ms 8000] [--tap X,Y@MS] [--every MS]
"C:\Program Files\EdgeTX\Companion 2.12\bin\simulator.exe" -p 0 -w sd     the TX15 simulator
```

`tools/test.py` must pass before work is done; run the SITL test when decoding or the device
client changes.

## Git

Commit or push only when asked.

@docs/architecture.md
