# Lofty PFD architecture

## Source layout and layering

| Path | What | Runs on |
| --- | --- | --- |
| `src/core/` | telemetry decoding, vehicle state, flight modes, the CRSF device client, the HUD, the theme | Lua 5.3 and 5.4 |
| `src/ethos/` | the Ethos widget: its canvas, telemetry and loader | Lua 5.4 |
| `src/edgetx/` | the EdgeTX widget: its canvas, telemetry and loader | Lua 5.3 |
| `design/`, `docs/lofted-aero/` | the vendored Lofted Aero design system | |
| `tools/` | checks, the theme generator, the build, the SITL bridge, the simulator drivers | Python, Node |
| `tests/` | core tests (Lua) and the SITL acceptance test (Python) | |

A core module is a chunk that receives a loader and returns a table:

```lua
local use = ...
local bits = use("bits")
local M = {}
...
return M
```

Each platform supplies `use` (Ethos `loadfile`, EdgeTX `loadScript`, the tests `load`), so no
module touches `require`. The tests load core modules in an environment that raises on any
undefined global, read or write: radios share one global table across scripts, and a
platform call in the core would only fail on the radio that lacks it.

The core's Lua is what both radios accept:

- **Lua 5.3 and 5.4.** EdgeTX 2.11 and later run 5.3; Ethos runs 5.4. EdgeTX 2.10 and older
  (5.2) are not supported.
- **32-bit integers and single-precision floats on EdgeTX.** A 32-bit word divided as a float
  loses its low bits, and integer arithmetic wraps at 2^31. Bit fields use the integer
  operators and mask to 32 bits (`core/bits.lua`), which gives the same answer with 32-bit
  integers and with the 64-bit ones the tests and Ethos have.
- **No string methods on EdgeTX:** `s:sub(1)` fails, so the core writes `string.sub(s, 1)`.
  The test harness removes string methods too, so a slip fails the tests.
- **No `os` library on EdgeTX.** The clock comes from the platform (`getTime()` there,
  `os.clock()` on Ethos) and is passed in.

## Vehicle state (`core/vehicle.lua`)

Every reading is nil until a frame carries it, so screens draw a dash rather than a zero the
aircraft never sent. SI units and degrees inside; conversion happens on screen.

- **0 V and 0%.** Plain CRSF's battery frame has no "absent": no monitor reads 0 V and no
  capacity reads 0%. Both are kept nil.
- **Armed on plain CRSF** is known only when ArduPilot appends `*` to a disarmed flight mode
  (RC_OPTIONS bit 12, `CRSF_FM_DISARM_STAR`). Without it, armed stays nil. The gyro defaults
  (RC_OPTIONS 96) do not set it, so either the gyro turns it on or its users fly passthrough.
- **Speed over passthrough** is one number whose kind is unknown: ArduPilot sends airspeed
  when it has an estimate and groundspeed otherwise. Only with FRSKY_OPTIONS bit 2 does it
  alternate them and flag airspeed (bit 28), which is when `airspeed` and `groundspeed` fill;
  otherwise the value is in `speed`.
- **Mode names** come from `core/modes.lua`, which mirrors Lofty GCS's `src/protocol/modes.ts`
  so both call a mode the same thing. Passthrough sends the number, resolved once the frame
  type (passthrough parameter 1) arrives; plain CRSF sends `Mode::name4()`, which maps to the
  same names through one table, since Copter and Plane share their four-letter names. Where
  both arrive, the CRSF name is used while it is fresh (see "Both encodings at once").

## Telemetry

Three transports, two encodings:

| Link | Encoding |
| --- | --- |
| ELRS or Crossfire, default | standard CRSF frames: attitude, GPS, battery, baro altitude, flight mode |
| ELRS or Crossfire, RC_OPTIONS bit 8 | ArduPilot's custom frame (0x80; 0x7F before TBS 4.06) carrying passthrough words |
| FrSky S.Port or F.Port | passthrough words as S.Port DIY sensors (0x5000-0x50FF, 0x0800) |

The encoders are ArduPilot's `AP_CRSF_Telem.cpp` and `AP_Frsky_SPort_Passthrough.cpp`; there
is no other specification.

- **Byte order.** Standard CRSF frames are big-endian. Passthrough words inside the custom
  frame are little-endian, copied from the flight controller's memory.
- **Numbers in passthrough** are mostly a few significant digits times a power of ten
  (`prep_number`), with the sign bit above the digits; `passthrough.num` decodes them. Some
  fields overlap their neighbor's sign bit, which is harmless because those values are never
  negative (home distance, battery current).
- **Status text over passthrough** arrives four 7-bit characters per word, each word up to
  three times; repeats are dropped by comparing with the previous word. The message ends at
  a zero character or at 50 characters, and its last word carries the severity in bits 7, 15
  and 23. Over CRSF the custom frame's sub-type 0xF1 carries the whole message, and the
  words follow seconds later; once an 0xF1 has arrived the words are ignored, or every
  message would show twice.
- **Satellites** are capped at 15 in passthrough (4 bits).
- **Link statistics** (0x14) come from the receiver and transmitter, not ArduPilot.
- **Both encodings at once.** With passthrough on, ArduPilot keeps sending the standard
  frames too, at different rates (measured in SITL: GPS and flight mode every 0.5 s;
  battery, altitude, climb and attitude every 1 s; passthrough attitude every 0.35 s, its
  status word every 3.4 s and up to 4.7 s apart). Each reading takes the faster source while
  it keeps arriving (`vehicle.recent`): standard frames for position, battery, altitude,
  climb, heading, mode and armed; passthrough for roll and pitch. Letting both write made a
  queued passthrough latitude overwrite a fresh GPS frame, so the position jumped back.
- **Passthrough attitude is ArduPilot's display attitude** (`get_osd_roll_pitch_rad`):
  pitch less `PTCH_TRIM_DEG`, and on a quadplane in a VTOL mode the VTOL view. The standard
  attitude frame is the raw estimate, so the two differ by the trim. Passthrough is the only
  source of roll and pitch while it arrives, so the horizon never jumps between them.
- **Mode and armed are slow over passthrough** (the status word, every few seconds). The
  standard flight-mode frame updates every 0.5 s, which is why it is preferred.
- **Home over plain CRSF** is the radio's own (`core/home.lua`), since no standard frame
  carries it: it follows the aircraft while disarmed and is fixed at arming, as ArduPilot's
  is; with armed unknown, the first position stands. Passthrough's own home distance and
  bearing outrank it while they arrive.
- **EdgeTX's sensors** (`core/sensors.lua`) are the standard frames as the firmware decoded
  them: radians, km/h, a `{lat, lon}` table, the mode text with its star. They go through the
  same setters as the frames (`crsf.set`), so both mean the same thing. `getSourceValue`
  says whether a sensor is current and whether it is fresh; a held value is shown, but only
  a fresh one counts as telemetry arriving, so a dropped link shows as lost.

## The CRSF device menu (`core/devices.lua`)

The protocol the ExpressLRS script browses under Other Devices. A ping (0x28) is answered by
every device with its info (0x29): name, serial, versions, entry count. Entries are read by
number (0x2C, with a chunk index) and come back as 0x2B frames: parent, type (top bit
hidden), name, then a value whose layout depends on the type. Long entries span chunks
(ArduPilot: 55 bytes, the parent only in the first).

- Entries are loaded 1 to count, one request in flight, retried after a second unanswered.
  A device whose name, count or version changes is reloaded from scratch: the ExpressLRS
  script caches the count from its first ping and shows empty menus after a reflash.
- Folders list their children, ending 0xFF; where a folder lists none the client falls back
  to the entries' parents.
- A write (0x2D) is always followed by a read of the same entry, which is what the screen
  shows: devices differ in whether and how they echo a write.
- A folder's entries are read again each time it opens, shown as they were meanwhile: a
  write can change entries elsewhere (the gyro's Wing type sets four channels' functions).
- A command entry carries a status and a line of text. The client writes start (1), confirm
  (4) or cancel (5); while the status is progress (2) it writes poll (6) at the interval the
  entry asks for, in tens of milliseconds. Confirmation-needed (3) waits for the pilot. The
  gyro reports results as confirmation-needed because the ExpressLRS script closes its popup
  on ready.
- Integer entries are parsed as value, min, max, default, unit. Nothing tested so far sends
  one (the gyro uses selections, floats, info and commands), so this layout is unverified.

### The device browser (`core/menu.lua`)

Every device on the link and its settings, drawn through the same canvas as the HUD, in the
theme being shown (see "Light and dark"): the charcoal bar with Back and the title, then one
card of rows, label left and the control in one column on the right.

- **Pages stack,** so Back goes up one level; the ExpressLRS script returns to the top
  instead, which is why the gyro keeps its folders at the top level.
- **A setting is edited in its own box:** Enter or a tap opens it (orange, with step arrows),
  the rotary or the arrows step it, Enter or a tap on the value writes, Back or a tap
  elsewhere leaves it unwritten. The box shows the written value dim until the device's
  read-back replaces the entry. A selection skips options with no name, which ExpressLRS
  uses for ones that do not apply.
- **A command that learns the setting above it shares that setting's row** as a Learn
  button beside the value (Eric's choice): "Learn " and the start of the setting's name, as
  the gyro names them ("Learn autotune sw" for "Autotune switch"), which halves its Radio
  folder. The rotary stops on the value, then the button. The device still serves two
  entries, so the ExpressLRS script shows two lines.
- **A command opens a dialog** that shows the device's text and follows its status: Cancel
  while it runs, OK as well while it asks for confirmation, closed when it reports ready.
  The open folder is read again afterwards, since a command can change other entries.
- **Input is abstract** ("next", "prev", "enter", "back", "tap" at x, y, "drag" by dy); the
  platforms map their keys and touch onto it. Taps are matched against what the last paint
  drew.
- **Readings refresh** every 2 s while their folder is open and nothing else is waiting.

## The gyro

Lofted Aero's gyro firmware (WSL `~/ardupilot-gyro`, `GYRO_README.md`) is a stripped
ArduPlane that serves its whole setup menu over CRSF as device 0xC8, named "Gyro". Its
SITL build (`build/sitl/bin/arduplane`, built with `Tools/gyro/sitl-gyro.hwdef`) serves the
same menu, which is what `tests/sitl_test.py` drives.

## The HUD (`core/hud.lua`)

Lofty GCS's Fly-screen HUD (`src/ui/tabs/flight/hud-paint.ts`), same layout and colors, scaled
by the shorter side of the widget (1.0 at 320 px, capped at 0.75 and 1.5). Its colors are
literals copied from the GCS, not design tokens: the HUD is a dark ground in both themes.

### The canvas

The HUD draws through a canvas the platform supplies: `fill`, `tri`, `line(..., width)`,
`text` (y is the text's middle, size in CSS pixels of an em), `textWidth`, and optionally
`shadowText`. Colors are `{r, g, b}`; the platform caches its own form by table (weak keys,
since the horizon's gradient makes new tables each frame). Filled triangles are the only
shape both radios fill at any angle, so the horizon is convex polygons clipped to the screen
(`core/geometry.lua`) and fanned into triangles.

- **Radios leave hairline gaps between filled triangles.** The screen is filled with sky and
  the ground painted over it, so a gap shows sky rather than the black behind.
- **Sky and ground are solid** (Eric's choice): a gradient in bands showed its steps on a
  radio and cost a clip per band per frame.
- **Line widths are whole pixels.** A wider line is several, which the platform draws.

### The instruction budget

Both radios stop a script after about 20,000 Lua instructions per call, so the HUD is
written for cost and `tests/hud_test.lua` holds the numbers. Measured on the simulators:

| | Lays out in | Draws in | Cost |
| --- | --- | --- | --- |
| Ethos | `wakeup` (no limit found up to 320,000) | `paint` (limit 20,000-40,000) | replaying a frame: about half of paint's budget |
| EdgeTX | `refresh` | `refresh` | the full 480x320 screen: 55% typical, 63% peak (`getUsage()`); decoding up to 8 passthrough frames adds about 15% more |

- **Ethos splits the work.** `wakeup` lays the HUD out into a display list
  (`core/displaylist.lua`), `paint` replays it. Recording costs as much again as laying out,
  which only Ethos's `wakeup` can afford.
- **EdgeTX draws directly** from the layout, in the one call it has. What keeps it in budget:
  coordinates go to the firmware unrounded (EdgeTX's Lua floors a fractional argument itself);
  lines are clipped only when an end is off screen; color and font lookups are written out
  in place; the bank scale's fixed lines are computed once per size; tape and ribbon ticks
  build no tables; below 800x480 the rungs are 1 px.
- **Decoding is capped per call** on EdgeTX: 8 frames of each kind, twice the rate a 75 Hz
  telemetry link delivers per refresh. A frame of passthrough words costs about 170
  instructions, and a burst after a stall would otherwise take the whole budget.
  The replay is capped the same way, and after a stall it falls behind rather than
  catching up: a simulator starved of CPU stopped the widget with "CPU limit".
- **A `pcall` does not catch the limit in Ethos's `wakeup`:** the callback ends. Measure
  headroom there by padding with a fixed loop, not by burning until the error.
- **The rendering convention is pinned by a test:** in a right bank the horizon's right end
  is higher and the bank pointer swings left.

## The screen (`core/layout.lua`)

Eric's choice from three rendered arrangements: a status bar across the top, the HUD on the
left with two tiles in a column beside it, and the message log across the bottom. The bar is
Lofty GCS's app-bar status (see "The status bar"); the column, its
actions column. The HUD shrinks to make the room, and draws none of its corner readings, which
the bar and tiles carry. Panels use the design system's tokens: surface cards with a
hairline frame and the orange rule under the title, a charcoal bar.

- **Settings are the radio's own widget options** (`core/options.lua`, one list both
  radios build their pages from): tiles, theme, distance, speed and climb units, coordinate
  format, cell count. Names, choices, order and defaults are Lofty GCS's Preferences
  wherever it has the setting ("Distance and altitude", "Follow distance", "Match the
  radio" for its "Match the system"), so a pilot meets one set of words in both. Each is a choice stored as its place, so new choices go on the end;
  EdgeTX keeps them by place in the list (new options on the end too, and an option added
  since a widget was set up reads 0, the default), Ethos by key. They are resolved when they
  change, not each frame. The gear opens devices only (Eric's choice, for now). Yaapu's
  alert thresholds are left out: thresholds come from the aircraft.
- **Tiles** (`core/tiles.lua`) fill the two slots; Battery and Position by default.
- **Light and dark** (`core/palette.lua`): panels and the browser follow the radio's theme,
  or the widget's Theme setting where the pilot chose one. Ethos says so (`lcd.darkMode()`,
  1.6); EdgeTX has no flag, so its theme counts as dark when its background
  (`COLOR_THEME_SECONDARY3`, read with `lcd.getColor`, RGB565 in the top 16 bits) is.
  EdgeTX's default theme is light. Modules keep a reference to `palette.T`, which is filled
  in place, so the theme is set once per frame before drawing. The HUD and the charcoal bar
  are dark grounds in both themes: what is drawn on the bar takes the dark colors
  (`palette.BAR`). The gear is a bitmap per theme.
- **Battery:** volts per cell from the pilot's cell count, else one worked out once, the
  voltage over 4.35 rounded up. That is right only above 4.35 (n-1)/n V a cell (2.9 V for
  3S, 3.6 V for 6S), so a big pack plugged in partly flat needs the setting; used against the capacity passthrough
  sends, with a level bar and no status color, since a level needs no threshold.
- **The status bar** keeps two things from Lofty GCS's (`AppStatus.tsx`, `app-status.ts`),
  with their words and colors, and leaves battery and GPS to the tiles (Eric's choice, after a
  full copy crowded the bar):
  - **The status pill:** link, then failsafe, then arm state, as one word ("Link lost",
    "Failsafe", "Armed"), with no telemetry yet "No telemetry". It says "Disarmed" where the
    GCS says "Ready" or "Not ready": neither CRSF nor passthrough carries prearm health.
    Its width fits the longest word, so the mode beside it stays put.
  - **The flight mode** follows the pill, not last as in the GCS, which centers its row: a
    pilot reads the two together.
  - **The link item** (signal bars lit from ExpressLRS's link quality, and "LQ 99%") and the
    transmitter's battery are on the right, the radio's side. Both show before any
    telemetry, which tells a silent aircraft from a dead link.
- **Tiles are dense** to leave the message log four lines (Eric's minimum): current and power
  share a "Load" row, and the coordinates share one unlabeled row, so a short tile shows both
  or neither.
- **The message log** has no title. A message ArduPilot repeats (the terrain warning every
  5 s) shows once with a count (`vehicle.addMessage`). Debug messages never show. With the log
  on screen, the HUD's chip only says "Link lost", the bar's word for it.
- **Coordinates** in degrees, minutes and seconds take a smaller size where the pair would
  not fit the tile; both radios' fonts draw the degree sign.
- **Home** is a house on the heading ribbon at its bearing, at the ribbon's edge with an arrow
  when it is behind; the ribbon's labels step around it.
- **Climb** is also a bar on the altitude tape's inner edge, square-root scaled to 10 m/s.
- **The failsafe banner names its type:** battery, EKF, fence breach, or plain "FAILSAFE" for
  the radio and ground-station failsafes, which ArduPilot reports with one flag.
- **The settings button** (Eric's choice), a square with a gear at the bottom right, the
  message log ending beside it, opens the device browser in place of the flight display;
  Back from its top page returns. Its side is the log's height, a finger wide on every
  radio. It shows only where the widget can be operated: always on Ethos, and on EdgeTX in
  full screen, the only mode in which a widget gets events (`refresh` has `event` nil
  otherwise; no Lua call enters it, and the "App mode" layout of 2.11 and later enters it
  with one long press). Decoding goes on underneath.
- **Icons are bitmaps** (`src/icons`, drawn by `tools/icons.py`) through the canvas's
  optional `icon(name, x, y, size)`: one call. The gear as filled triangles cost EdgeTX
  3,800 instructions a frame, and both radios left holes in it: hairline gaps along shared
  edges, and pixels missing inside sliver triangles. Triangles remain the fallback where a
  canvas has no `icon`.
- **The transmitter's battery** comes from the platform: Ethos's main-voltage system source,
  EdgeTX's `getValue("tx-voltage")`.
- **The HUD draws in its part of the screen** through a canvas offset. On EdgeTX the drawing
  functions take the offset themselves (`screen.origin`): a wrapping canvas cost a sixth of
  the frame budget in extra calls. Elsewhere `core/subcanvas.lua` wraps.

## Platforms

### Ethos (1.6.6 X20 Pro simulator; FrSky's 1.6.8 Lua reference)

- Lua 5.4. `loadfile` and `io.open` resolve relative paths against the script's own folder.
- `system.registerWidget{key (7 characters at most), name, title = false, create, wakeup,
  paint, event, ...}`. `wakeup` runs whether or not the widget is showing; gate drawing on
  `lcd.isVisible()`.
- A full-screen layout gives the widget 800x480; Ethos's standard layout about 784x316.
- `lcd.RGB(r, g, b, alpha)` takes alpha 0-1, and draw calls want integers (a fractional
  color channel is an error).
- `crsf.getSensor():popFrame()` returns `command, data`, data from the destination byte for
  extended frames (before 1.5 the queue was `crsf.popFrame()`);
  `sport.getSensor{appIdStart, appIdEnd}:popFrame()` returns a frame with `physId()`,
  `primId()`, `appId()`, `value()`. Link sensors are found by name with
  `system.getSource(name)`.
- `system.registerTask`, `registerSource`, `registerSystemTool`, and the undocumented
  `registerDeviceConfig` (FrSky's own device scripts use it; guard it with a nil check).
- No text-to-speech: `playText` exists in 1.6.6 but is undocumented and unused anywhere.
- Print lines longer than about 200 characters are cut short.
- **`create` has the instruction limit too:** decoding a 10 kB file there stopped the script.
- `system.registerSystemTool{name, icon, create, wakeup, paint, event, close}` refuses a
  tool without an icon. `title = false` hides Ethos's own title bar, as for widgets. The
  icon is `lcd.loadMask` of a grayscale PNG in which **dark is drawn**: a white glyph on
  black came out as a white square. Tools are on the second page of the System menu.
- A tool's `event(tool, category, value, x, y)` gets `EVT_KEY` with `KEY_ROTARY_LEFT`/`RIGHT`,
  `KEY_ENTER_BREAK`, `KEY_EXIT_BREAK`, and `EVT_TOUCH` with `TOUCH_START`, `TOUCH_MOVE`,
  `TOUCH_END`; returning true keeps Ethos from handling it. `system.exit()` closes the tool.
- **One reader for the radio's queues.** The widget and the tool live in one script and
  share one link (`src/ethos/main.lua`): the aircraft's state, the CRSF and S.Port queues,
  and the device client while the tool is open. Two readers would each see half the
  frames.
- In the simulator `crsf` exists but has neither `getSensor` nor `popFrame`.

### EdgeTX (2.12, from the firmware source; TX15 simulator)

- Lua 5.3 with 32-bit integers and single-precision floats; no `os`, no string methods (see
  "Source layout and layering").
- A widget is `{name, options, create(zone, options, path), update, refresh(widget, event,
  touch), background}`. `background` runs only while the widget is off screen, so decoding
  happens in `refresh` too. Refresh runs about 20 times a second.
- A `CHOICE` option's value counts from 1 in Lua (the firmware stores the list index plus
  one).
- `lcd.drawFilledRectangle(x, y, w, h, flags, opacity)`: opacity 0-15 with **0 opaque**.
  Triangles take no opacity. `lcd.drawLine` skips a line with any end off the screen.
- Fonts on 480x272 and 480x320, by line height: TINSIZE 12, SMLSIZE 17, standard 21,
  MIDSIZE 29, DBLSIZE 40. `VCENTER` centers on y and `SHADOWED` draws the dark shadow.
- **The firmware keeps the standard CRSF frames** (GPS, vario, battery, baro, attitude,
  flight mode, link statistics) and Lua never sees them through `crossfireTelemetryPop`;
  they are read as telemetry sensors instead. Passthrough's custom frames and the device
  menu do reach Lua. `sportTelemetryPop` passes 0x5000-0x50FF.
- `io` has only `open`, `read(f, n)`, `write`, `seek` and `close`: no lines, no methods. The
  replay reads a chunk at a time and closes the file in between, so a new build can be
  copied over it while the simulator runs.
- **The tool** is `SCRIPTS/TOOLS/LoftyPFD.lua` (`src/edgetx/tool.lua`), named by its
  `TNS|...|TNE` comment. It loads the widget's core, canvas (`src/edgetx/screen.lua`) and
  link and input mapping (`src/edgetx/link.lua`), so
  the widget must be installed. `run(event, touchState)` gets `EVT_VIRTUAL_NEXT`, `PREV`,
  `ENTER` and `EXIT`, `EVT_TOUCH_TAP` and `EVT_TOUCH_SLIDE` (`slideY`); returning nonzero
  closes it. A widget does not run while a tool does, so the tool reads the queue itself.
- `crossfireTelemetryPush(type, payload)` sends; it returns false while its queue is full.

## Development loop

- `tools/test.py`: the vendored files against their manifest, the generated theme, every Lua
  file compiled on the Lua its radio runs, and the core tests on real 5.3 and 5.4 VMs
  (lupa), with string methods removed as on EdgeTX.
- `tests/sitl_test.py`: the gyro's SITL, driven as a CRSF receiver (RC frames out at
  100 Hz; ArduPilot sends CRSF telemetry only in reply to them), with its MAVLink read as
  ground truth.
  - **It runs inside WSL.** A connection from Windows through WSL's localhost forwarding is
    accepted and dropped at once, and the simulator exits. Started from Windows, the
    scripts re-run themselves in WSL, whose Python needs lupa and pymavlink.
  - The simulator nearly stops its clock when nobody reads its MAVLink, so a reader drains
    it throughout. It is the script's own child and is stopped by its handle, never by
    name (`pkill -f` matches the calling shell's own command line, and other sessions run
    simulators too).
  - **How a reading is judged.** Every reading a frame changes must lie on the path of
    MAVLink values from 1.5 s before its arrival to 1.2 s after. A frame can be sampled
    between two MAVLink messages, and MAVLink can trail it: CRSF frames go out at once
    while MAVLink is buffered and the heartbeat is 1 Hz. Comparing against the newest
    MAVLink value instead measures latency, not decoding.
  - Ground truth for groundspeed is `GPS_RAW_INT`, the source CRSF's GPS frame uses;
    `VFR_HUD` is the attitude estimator's and differs in a turn.
  - The flight takes off in Manual and climbs in FBWA from 10 m; held in Manual at full
    throttle the SITL plane loops.
- **Replay.** `tools/sitl.py record` saves a SITL flight's CRSF frames; `tools/build.py
  --replay` puts one beside the widget as `replay.txt`, which the widget plays in place of
  a link. That is how both simulators show a real flight.
- **The TX15 simulator** is EdgeTX Companion's (`simulator.exe -p 0 -w sd`), with profile 0
  pointing at `out/edgetx-tx15/sd`. In SD mode it refuses a card without
  `RADIO/radio.yml`; `tools/build.py --edgetx` seeds one, and a model whose single
  full-size screen holds the widget (`tools/edgetx-sim`). `tools/winshot.ps1` captures its
  window. Started without `-w sd`, it keeps radio data in a file under Documents instead.
- **The Ethos simulator runs headless in Node** (`tools/ethos-sim/run.cjs`). Ethos Suite's
  simulator is an Emscripten build (`%APPDATA%\Ethos Suite\.simulator\<version>\<radio>\`,
  files named with underscores where the folder has a dash). It boots in Node with an
  in-memory `/persist/<board>` holding `radio.bin`, `models` and `scripts`, then
  `_start()`. Each frame arrives at `Module.updateCanvas(width, height, pointer)` as RGB565,
  rows bottom to top. Input: `onMouseDown`, `onMouseMove`, `onMouseUp` (two arguments),
  `onKeyEvent`, `setAnalogPosition`, `setSwitchPosition`.
  - **Telemetry injection is in the 26.1 builds only:** `injectSPortFrame(module, band, rx,
    physId, primId, appId, value)`, which Ethos Suite calls with module, band and receiver
    0. The 1.6.6 and 1.6.8 builds export none, and no build injects CRSF. FrSky publishes
    each build as `<radio>-<region>-WebSimulator.zip` (listed in Ethos Suite's
    `Releases/releases.json`); `--sim DIR` runs one unpacked, and `--sport RECORDING` plays
    a passthrough recording's words into it as a FrSky receiver would deliver them.
  - A screen holding the widget is set up once through the menus and kept with
    `--save-models out/ethos/models`, then used with `--models`. On the X20 Pro: tap
    705,392 (dismiss the throttle warning), 373,447 (screens), 103,88 (the screen's tab),
    400,263 (Change layout), drag up three times, 293,167 (Full screen), then Configure,
    the widget list (605,93), scroll, and the widget. The saved models start from Ethos
    Suite's own, so they stay out of the repo.
  - The widget's settings page, from that screen: tap 705,392, 373,447, 103,88, then
    400,239 (Configure widget).
  - Keys go to `onKeyEvent(keyCode, key, shift, down)` as Ethos Suite's keyboard sends them;
    the radio's keys are arrows: SYS is ArrowLeft, MDL ArrowUp, DISP ArrowRight, RTN
    ArrowDown, PAGE PageUp.
- **The device browser without a device.** Neither simulator has a CRSF device, so
  `tools/sitl.py menu out/gyro-menu.txt` records the gyro's menu from SITL and `tools/build.py
  --menu` puts it beside the scripts as `menu.txt`, with `tools/snapshot.lua` as
  `core/snapshot.lua`: it answers from the recording, keeps written values, and answers a
  command with a confirmation. Frames stay hex until asked for (see `create` above).

## Language

American English everywhere. Third-party text and identifiers keep their spelling.
