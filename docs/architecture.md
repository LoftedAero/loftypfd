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
- **Some messages are the radio link's alone.** ArduPilot's telemetry library adds sensor
  health warnings ("Bad GPS Health", "Bad or No Terrain Data") and the firmware's name at
  startup (`AP_RCTelemetry.cpp`); MAVLink never carries them.
- **A port set to FrSky passthrough** (`SERIALn_PROTOCOL 10`) stops passthrough over CRSF:
  in SITL the custom frames carried no words once one was.
- **Satellites** are capped at 15 in passthrough (4 bits).
- **Zeros are not readings** on either encoding: without a fix ArduPilot sends latitude and
  longitude 0 (seen on the X20 over S.Port), and without a battery 0 V; both stay nil.
- **Link statistics** (0x14) come from the receiver and transmitter, not ArduPilot. The
  uplink's power is a step (0-8), shown in mW from the CRSF specification's list; 0 RSSI
  is an antenna the receiver does not have. On EdgeTX the frame arrives as sensors, whose
  antenna sensor counts from 1 for ELRS in 2.12 and later and from 0 otherwise, so the
  stronger antenna's RSSI counts rather than the one it names.
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
  standard flight-mode frame updates every 0.5 s, which is why it is preferred. A mode
  number has no name until the frame type (passthrough parameter 1) arrives, which in SITL
  took half a minute from the start.
- **Home over plain CRSF** is the radio's own (`core/home.lua`), since no standard frame
  carries it: it follows the aircraft while disarmed and is fixed at arming, as ArduPilot's
  is; with armed unknown, the first position stands. Passthrough's own home distance and
  bearing outrank it while they arrive.
- **EdgeTX's sensors** (`core/sensors.lua`) are the standard frames as the firmware decoded
  them: radians, km/h, a `{lat, lon}` table, the mode text with its star. They go through the
  same setters as the frames (`crsf.set`), so both mean the same thing. `getSourceValue`
  says whether a sensor is current and whether it is fresh; a held value is shown, but only
  a fresh one counts as telemetry arriving, so a dropped link shows as lost.
- **Sensors are found by where EdgeTX keeps them,** not by name: the CRSF frame type
  (`model.getSensor`'s `id`) and the place in it (`instance`), which no version has changed.
  EdgeTX 2.11 named the GPS and the baro altitude both "Alt" (2.12 calls the GPS one
  "GAlt"), a model keeps the names its sensors were discovered with, and a name finds the
  first sensor that has it, so on a TX15 set up under 2.11 "Alt" read the GPS altitude. The
  list is read 8 slots a call and again every 3 s; sensor n's source id is the first
  sensor's plus 3n, the first found with `getFieldInfo` by its name.

## The CRSF device menu (`core/devices.lua`)

The protocol the ExpressLRS script browses under Other Devices. A ping (0x28) is answered by
every device with its info (0x29): name, serial, versions, entry count. Entries are read by
number (0x2C, with a chunk index) and come back as 0x2B frames: parent, type (top bit
hidden), name, then a value whose layout depends on the type. Long entries span chunks
(ArduPilot: 55 bytes, the parent only in the first).

- **While a menu loads, telemetry waits.** While disarmed, any pending menu read puts
  ArduPilot in a "params mode" that turns off every telemetry frame until 5 s after the
  last read (`AP_CRSF_Telem::adjust_packet_weight`); armed, it never enters it. Measured in
  gyro SITL (2026-11-13): reading all 91 entries took 8 s and stopped GPS, battery,
  attitude and flight mode for 13 s; opening the device now stops them for 5.5 s (0.5 s of
  reads), and each folder for 5.2-6 s. ArduPilot's answer to a ping does not start the
  mode but restarts its 5 s while it is on. So, disarmed, readings are not refreshed and
  the device list pings every 6 s (see "The device browser").
- **A folder is read when it opens.** A read of entry 0 is answered with a root folder
  (the gyro: parent 0, type 11, "root", its eight top-level ids, 0xFF), so opening a device
  reads entry 0 and the entries it lists; opening a folder reads the entries it lists,
  hidden ones too (so Gyro Setup can reach the hidden "Menu version" by opening Tools). Ids
  differ between firmware versions, so nothing is looked up by number. How ExpressLRS and
  Crossfire devices answer entry 0 is unknown: where it goes unanswered three times, or
  lists nothing, the device is read in full, 1 to count, as before.
- One request in flight, retried after a second unanswered. A device whose name, count or
  version changes is reloaded from scratch: the ExpressLRS script caches the count from its
  first ping and shows empty menus after a reflash.
- **An entry too short for its type is not stored.** Stock ArduPilot's chunking counted
  the parent in the first chunk's 55 bytes, so an entry of 54 or 109 bytes went out with
  nothing after the parent (the gyro's "Learn gain knob" did, with some texts). The read is
  asked three times, then left out, and what was shown stays; opening its folder asks
  again. The gyro firmware is fixed; boards flashed before the fix still do it.
- Folders list their children, ending 0xFF; where a folder lists none the client falls back
  to the entries' parents, after reading every entry.
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
- **Readings refresh** every 2 s while their folder is open, nothing else is waiting and
  the aircraft is armed; the device list pings every 2 s armed and every 6 s otherwise.
  Disarmed, each read would keep ArduPilot's telemetry off (see "While a menu loads"). The
  armed state comes from the widget's telemetry; EdgeTX's tool decodes none, so it never
  refreshes.
- **The bar counts a folder's entries** ("3/11") while they load; nothing until entry 0
  has said what the top level holds.

## The gyro

Lofted Aero's gyro firmware (WSL `~/ardupilot-gyro`, `GYRO_README.md`) is a stripped
ArduPlane that serves its whole setup menu over CRSF as device 0xC8, named "Gyro". Its
SITL build (`build/sitl/bin/arduplane`, built with `Tools/gyro/sitl-gyro.hwdef`) serves the
same menu, which is what `tests/sitl_test.py` drives.

- **Chunks:** each carries up to 55 bytes of the entry from chunk x 55, the parent byte
  before the first only (`tests/lib/fakegyro.lua` splits the same way, and the stock way
  with `oldChunks`).
- **Armed,** it refuses every write except the numbers in "6 Tuning"; the read-back shows
  the value unchanged. The model does not arm while a command dialog is open.
- **A command ends itself** with "Timed out" when the radio stops asking: 10 s without a
  poll while in progress, 2 minutes while waiting for confirmation.

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
written for cost and `tests/hud_test.lua` holds the numbers. On the X20 (Ethos 1.6.3) an
instruction is also time: it ran 40,000 in 291 ms, about 7 microseconds each, presumably
the cost of Ethos counting them.

| | Lays out and draws in | Cost |
| --- | --- | --- |
| Ethos | `paint` (limit 20,000-40,000 in the simulator) | the whole 800x480 screen: about 11,000 instructions in the core |
| EdgeTX | `refresh` | the full 480x320 screen: 55% typical, 63% peak (`getUsage()`); decoding up to 8 passthrough frames adds about 15% more |

- **Ethos draws in `paint`, in one pass;** `wakeup` reads the telemetry, speaks, and asks for a
  paint. Laying out into a display list in `wakeup` and replaying it in `paint` took about
  350 ms a frame on the X20 (186 to lay out and record, 162 to replay and draw), recording
  nearly as many instructions as the layout itself, and a wakeup that slow let S.Port's queue
  overflow and lose words from the middle of messages.
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
left with two tiles in a column beside it, and the message log across the bottom. The map
takes the HUD's place (see "The map"). The bar is
Lofty GCS's app-bar status (see "The status bar"); the column, its
actions column. The HUD shrinks to make the room, and draws none of its corner readings, which
the bar and tiles carry. Panels use the design system's tokens: surface cards with a
hairline frame and the orange rule under the title, a charcoal bar.

- **Settings are the radio's own widget options** (`core/options.lua`, one list both
  radios build their pages from): tiles, theme, distance, speed and climb units, coordinate
  format, cell count, voice callouts, the devices button, warning beeps. Names, choices, order and defaults are Lofty GCS's Preferences
  wherever it has the setting ("Distance and altitude", "Follow distance", "Match the
  radio" for its "Match the system"), so a pilot meets one set of words in both. Each is a choice stored as its place, so new choices go on the end;
  EdgeTX keeps them by place in the list (new options on the end too, and an option added
  since a widget was set up reads 0, the default), Ethos by key. They are resolved when they
  change, not each frame. The button beside the log opens devices only (Eric's choice, for now). Yaapu's
  alert thresholds are left out: thresholds come from the aircraft.
- **Tiles** (`core/tiles.lua`) fill the two slots; Battery and Position by default.
  Battery voltage is the battery card for a pack with no current sensor, common on these
  models: in place of used, level and load it shows the lowest voltage since arming
  (`vehicle.setVolts`, the minimum of what the aircraft sent), the sag under load being
  what tells such a pack's state. For models with no GPS and a bare battery monitor there
  are also Link (the receiver's and module's statistics, which ELRS sends with no flight
  controller at all), Stats (`core/stats.lua`: flight time from arming, highest altitude
  and speed, lowest LQ and voltage; reset at arming, kept after) and Timers (the model's
  timers, read by the platform only while that tile shows: EdgeTX's `model.getTimer` with
  mode 0 off, Ethos's `model.getTimer(i)` objects, `:value()` and `:name()`, empty when
  unnamed). Ethos reads only LQ and RSSI as sensors so far; the rest of Link fills there
  only if its CRSF queue passes the 0x14 frame, unconfirmed.
- **Light and dark** (`core/palette.lua`): panels and the browser follow the radio's theme,
  or the widget's Theme setting where the pilot chose one. Ethos says so (`lcd.darkMode()`,
  1.6); EdgeTX has no flag, so its theme counts as dark when its background
  (`COLOR_THEME_SECONDARY3`, read with `lcd.getColor`, RGB565 in the top 16 bits) is.
  EdgeTX's default theme is light. Modules keep a reference to `palette.T`, which is filled
  in place, so the theme is set once per frame before drawing. The HUD and the charcoal bar
  are dark grounds in both themes: what is drawn on the bar takes the dark colors
  (`palette.BAR`).
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
- **A tap on the log fills the screen with it** below the bar, and another closes it
  (Eric's choice). The rotary or a drag scrolls it, whole lines, with a scroll bar where the
  64 messages kept do not fit. Neither the HUD nor the map is drawn under it.
- **Coordinates** in degrees, minutes and seconds take a smaller size where the pair would
  not fit the tile; both radios' fonts draw the degree sign.
- **Home** is a house on the heading ribbon at its bearing, at the ribbon's edge with an arrow
  when it is behind; the ribbon's labels step around it.
- **Climb** is also a bar on the altitude tape's inner edge, square-root scaled to 10 m/s.
- **Before any telemetry the HUD says "Waiting for telemetry..."**, Lofty GCS's words for that
  state, at its center; otherwise it is a blank field of dashes (Eric's first hardware run).
- **The failsafe banner names its type:** battery, EKF, fence breach, or plain "FAILSAFE" for
  the radio and ground-station failsafes, which ArduPilot reports with one flag.
- **The devices button** (Eric's choice), a square with sliders at the bottom right, the
  message log ending beside it, opens the device browser in place of the flight display;
  Back from its top page returns. Its side is the log's height, a finger wide on every
  radio. It shows only where the widget can be operated: always on Ethos, and on EdgeTX in
  full screen, the only mode in which a widget gets events (`refresh` has `event` nil
  otherwise; no Lua call enters it, and the "App mode" layout of 2.11 and later enters it
  with one long press). Decoding goes on underneath. A setting hides it (and EdgeTX's Enter
  with it) for a pilot who never uses it; the radio's tools menu still opens the browser.
- **The sliders are all filled rectangles** in whole pixels: both radios leave hairline gaps
  between filled triangles and miss pixels inside sliver ones (a gear of them cost EdgeTX
  3,800 instructions a frame as well). Rectangles have neither problem.
- **The transmitter's battery** comes from the platform: Ethos's main-voltage system source,
  EdgeTX's `getValue("tx-voltage")`.
- **The HUD draws in its part of the screen** through a canvas offset. On EdgeTX the drawing
  functions take the offset themselves (`screen.origin`): a wrapping canvas cost a sixth of
  the frame budget in extra calls. Elsewhere `core/subcanvas.lua` wraps.

## Voice callouts and alerts (`core/callouts.lua`, `core/phrases.lua`)

Lofty GCS's callouts (`src/services/voice` there): its rows, words, tones and rules, cut
down by Eric's review of every row (2026-11-10). What a radio link does not carry is left
out, and so is what the radio already says (telemetry lost and regained, link quality,
timers). Thresholds the pilot would set (cell voltage, altitude, distance, airspeed) are
left out too, since alerts come from the aircraft. Nothing repeats, and critical callouts
vibrate. A row that is off is not built at all, since the one setting cannot turn it on.

- **The rules are the GCS's.** A change is said, never a running value. The state is taken
  as found for 3 s after telemetry starts. A mode is said once it has held for 0.5 s.
  Battery steps from 50% only go down. While the link is down nothing is said; changes made
  meanwhile are said when it is back.
- **No text-to-speech on either radio.** Every phrase is a recorded clip (`core/phrases.lua`
  lists them; `tools/voice.py` makes them, 16 kHz 16-bit mono, which both radios play, every
  clip at one peak level). The voice is Piper's "cori" (Eric's choice after sampling 13), an
  open-source neural voice that runs offline. It was trained on recordings licensed CC BY
  4.0, so `src/audio/en/CREDITS.txt` and the README credit them. Its model comes from a
  fixed revision, checked by its hash. Some words are respelled for Piper (`PIPER_RESPELL`),
  and the index records a fingerprint of those, so changing one remakes the clips. Piper reads
  a lone capital "A" as the article ("uh"), so it is given "eh", the letter. "Fly by wire"
  sounded robotic as three words, and run together as one unknown word Piper guessed "bih"
  for "by"; "Fly-bye-wire" is one word with each syllable full (Eric's pick of eight). Numbers are the radio's own (`playNumber`), in its language. A message
  from the aircraft is spoken only where a clip says it, else it gets its row's tone.
  `tools/test.py` fails when a phrase has no clip or its clip says other words.
- **Plain CRSF carries no messages, fix type or failsafe flags,** so over it only the mode,
  arming (with the disarmed star) and battery steps are said. The rest needs passthrough.
- **ArduPilot's own words decide the matching.** Plane's autotune reports each axis
  ("Roll: Finished") and its gains ("RollD: 0.0123") at error severity, so the gains are
  ignored and the axis is said, rather than an error tone each time; Copter's is
  "AutoTune: Success". The battery is "Battery 1 is low 10.50V used 1200 mAh" at warning
  severity. Plane's failsafes are "RC Short Failsafe On", "RC Long Failsafe On: switched to
  RTL", "GCS Failsafe On", and "... Cleared" when they end.
- **Two settings.** Voice callouts: All, Alerts only (information left out) or Off. Warning
  beeps: Always or Only when armed (the default, since on the bench they come one after
  another; Eric's first hardware run). The second quiets only the tones the aircraft's
  messages get; a message with a clip is still said, and a refused arm or mode still beeps,
  since it answers what the pilot did.
- **One voice per link.** Ethos's one link speaks at the level the widget was last set to.
  Each EdgeTX widget decodes its own copy of the link, so only one of them speaks; another
  takes over when it goes quiet.
- **The tones** are the GCS's defaults through `playTone`: a 1000 Hz beep of 120 ms for
  information, three 1250 Hz pips of 90 ms for warnings.

## The map (`core/maps.lua`, `core/flight.lua`)

Lofty GCS's Fly map (`src/ui/tabs/flight/MapView.tsx`) from tiles stored on the radio, which
Lofty GCS copies there (see "Map tiles"). It draws what the GCS draws: the aircraft as an
orange arrow along its heading, a blue trail, home as a green outlined house, Leaflet's zoom
buttons, and the imagery's credit, which its terms keep on screen. Overlay colors are the
GCS's literals, since they sit on imagery; the controls take the theme's tokens, as the GCS's
do.

- **Satellite only, always following the aircraft** (Eric's choice): no layer switch, no
  Follow, no panning. The radio reads the `satellite` line of the index and ignores others.
- **The zoom buttons are a finger wide** (44 px at scale 1), larger than Leaflet's, with the
  marks drawn as fills, which stay crisp where a font's "+" would not.

- **A tap on the HUD or the map fills the screen** below the status bar, and another goes
  back; **a button swaps them**, in the top right corner below the HUD's heading ribbon and
  above its altitude tape, showing a small picture of the view it opens in that view's
  colors: a map tile with the arrow on the HUD, a level horizon on the map (Eric's choices,
  after the GCS's handheld Fly screen). Double taps were tried first and cannot work on the X20: Ethos reads the
  touchscreen only between frames, 300 ms apart there, and never saw the finger lift
  between two quick taps, so each double tap arrived as one long touch. The full-screen HUD
  draws its battery and GPS corners, which the hidden tiles carried. There is no
  picture-in-picture inset: drawing both would cost the frame budget.
- On the map the rotary zooms too. Zoom stays within the stored levels, north up, tiles at
  their own 256 px.
- **Placed by differences from the view's center.** EdgeTX's single-precision floats hold a
  world pixel at zoom 18 only to a few pixels, so tiles, trail and markers are placed by their
  offset in degrees and in Mercator units from the center, and tile edges come from the tile
  numbers exactly. Tile numbers in paths are integers (`1 << z`): `2 ^ z` is a float and
  prints "119844.0".
- **Drawn first, covered after.** A bitmap cannot be clipped on either radio, so the map is
  painted before the bar, the tile column and the log, which cover what reaches past it.
  Before the tiles the map is filled, so a tile not stored leaves a plain square; the radio
  cannot ask whether a file exists before Ethos's recorded paint replays it.
- **Only the tiles that cover the map** are drawn. Twelve requested at once on Ethos, a row and
  a column more than needed, drew none in the simulator; the cause is unknown, so watch for it
  on hardware. `core/imagecache.lua` keeps the twelve most recently drawn (a decoded tile is
  128 kB, and EdgeTX refuses bitmaps past its Lua allowance) and remembers missing files.
- **Tiles load one a frame on Ethos, two on EdgeTX,** the rest drawn as plain ground until
  their turn: each takes about a third of a second to decode on the X20, and a new zoom
  level held the screen for two seconds while all of them loaded.
- **Home** is the radio's own when it keeps one, else worked back from passthrough's home
  distance and bearing.
- **The trail** is a point each 3 m, the last 120: the GCS keeps every position, but a radio
  draws each point every frame. A new vehicle state (a replay starting over) starts it again.
- Cost on EdgeTX: 40-55% of the budget with the tiles beside it, 25-40% full screen, against
  63-77% for the HUD; a full trail adds about 4,000 instructions.

### Map tiles

Lofty GCS's Offline maps panel has "Copy to radio" (`src/services/radio-maps.ts` there): the
pilot picks the radio's SD card, and the GCS finds Lofty PFD on it (`WIDGETS/LoftyPFD` or
`scripts/loftypfd`), fetches whatever of the view's satellite imagery is not stored, and writes
`maps/<layer>/<z>/<x>/<y>.jpg` with `maps/index.txt`, one layer a line:
`id|label|min zoom|max zoom|center lat|center lon|credit`.

- **Satellite whatever the GCS's map shows,** since that is the radio's only layer. The
  index keeps a line per layer, so another could be added without changing the format.
- **Baseline JPEG.** Both radios load it (checked in both simulators); the GCS re-encodes
  every tile, whatever its source format. Neither radio lists a folder, which is why the index
  exists; its center is where the map looks before the aircraft has a position.
- **Neither radio's font has "©"**, nor Ethos's a "·", so the credit says "(c)".
- The maps live in the widget's folder, so updating Lofty PFD by copying files over keeps
  them; deleting the folder first does not.

## Installing from Lofty GCS (`manifest.json`)

Lofty GCS installs and updates Lofty PFD on a radio's card, downloading the latest release
(Eric's choice). A release is a version tag on this public repository; nothing built is
committed, since what goes on a radio is the source files, placed per radio.

- **`manifest.json`** at the repository's root lists, for each radio, every file
  (`from` in the repository, `to` on the card, `size`, `sha256`) and the install rules.
  `tools/build.py --manifest` writes it from the same plan the build and `--sd` use
  (`plan()`, `rules()`), and `tools/test.py` fails when it is stale. `VERSION` holds the
  version; the tag is `v` and that.
- **Fetching:** GitHub's API gives the latest release's tag
  (`api.github.com/repos/LoftedAero/loftypfd/releases/latest`), and each file comes from
  `raw.githubusercontent.com/LoftedAero/loftypfd/<tag>/<from>` (the manifest's `files`
  template). Both answer any page; a release's attached files do not (GitHub's download
  redirect sends no CORS header), so the installer works in Chrome as well as the desktop
  app. Text is stored with LF, so a file's hash on disk is the one GitHub serves.
- **Installing** (`rules()`): every listed file is written; in each `owned` folder a file the
  release no longer lists is removed; files matching `remove` go (the `.luac` both radios
  compile beside a script, which could run in place of the new source, and what only a
  development build adds); everything else stays, the maps and captures among it. Download
  and check every file before touching the card, so a failed download changes nothing.
- **Which radio:** the folder Lofty PFD is installed in (`folder`), else the card's `signs`
  (an X20's SD card and internal storage hold `sdcard.cpuid` and `radio.cpuid`; an EdgeTX
  card holds `RADIO/radio.yml`); where neither tells, the pilot says.
- **A release** ([releasing.md](releasing.md)): bump `VERSION`, run `tools/build.py
  --manifest`, commit, tag `v<VERSION>`, push the tag, and publish it as a GitHub release
  (not a pre-release, which `latest` skips) with the zips `tools/build.py --package` makes,
  for installing by hand.

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
- `lcd.loadBitmap` loads baseline JPEG; `lcd.drawBitmap(x, y, bitmap, w, h)` scales it.
- `system.playFile` resolves a relative path against the script's folder
  (`SCRIPTS:/loftypfd/audio/en/armed.wav`); `system.playTone(frequency, duration, pause)`
  takes milliseconds. `system.playHaptic(duration, pause)` exists, but its units are
  unconfirmed: Ethos's own startup buzz logs `duration=10`. Each call is guarded, so a call
  a radio refuses prints and does not stop the widget.
- **Lua is slow on the X20** (Ethos 1.6.3): about 140,000 instructions a second, so the
  screen is drawn in one pass in `paint` (see "The instruction budget"). The test build
  records the rate and each call's time (`B`, `T` and `U` capture lines).
- **Ethos compiles `main.lua` to `main.luac`** beside it; an install deletes any `.luac`, so a
  stale one is never run in place of the new source.
- **Touches reach a widget only between frames.** The simulator delivers each touch's start
  twice; a second touch starting 30 ms after the first lost the first one's end there. The
  test build logs every touch (`E` capture lines).
- **A widget's `event` returns false for what it does not use,** or Ethos loses its own
  long press, which opens the widget's menu (Configure widget).

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
- `Bitmap.open` loads baseline JPEG. Bitmaps count against a Lua allowance
  (`LUA_MEM_EXTRA_MAX`) until collected; past it, `Bitmap.open` returns a bitmap of size 0.
- A slide's `touch` carries `slideX` and `slideY`; input is "drag" by both.
- **A sound file's path is at most 42 characters** (`AUDIO_LUA_FILENAME_MAXLEN`), longer
  ones are cut. The widget's own folder leaves 11 for a name, so the clips are in
  `/SOUNDS/en/lofty/` and their names are 21 characters at most (a test holds them to it).
  `playTone(frequency, duration, pause)` and `playHaptic(duration, pause)` take milliseconds;
  `playNumber(value, unit)` says an integer in the radio's voice.

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
  - **How a reading is judged** (`tools/judge.py`, shared with the hardware test). Every
    reading a frame changes must lie on the path of MAVLink values from 1.5 s before its
    arrival to 1.2 s after. A frame can be sampled
    between two MAVLink messages, and MAVLink can trail it: CRSF frames go out at once
    while MAVLink is buffered and the heartbeat is 1 Hz. Comparing against the newest
    MAVLink value instead measures latency, not decoding.
  - Ground truth for groundspeed is `GPS_RAW_INT`, the source CRSF's GPS frame uses;
    `VFR_HUD` is the attitude estimator's and differs in a turn.
  - The flight takes off in Manual and climbs in FBWA from 10 m; held in Manual at full
    throttle the SITL plane loops.
- **Replay.** `tools/sitl.py record` saves a SITL flight's CRSF frames; `tools/build.py
  --replay` puts one beside the widget as `replay.txt`, which the widget plays in place of
  a link. That is how both simulators show a real flight. A capture from a radio plays the
  same way, S.Port words included.
- **The hardware test** (`docs/hardware-test.md`, `tools/hwtest.py`). A test build
  (`tools/build.py --capture`, Ethos only so far) records everything the widget receives
  and sends (`core/capture.lua`): frames in replay's form, S.Port words, its own decoding,
  the link sensors and its timing, appended a second at a time so a switched-off radio
  loses nothing. The PC drives the flight controller over USB, records its MAVLink, then
  decodes the capture with the same core and judges it as the SITL test does.
  - **The two clocks** are lined up by the changes of mode and arming both sides saw, the
    offset that explains the most of them, then exactly by the roll while the board was
    rocked by hand. A reading that never changes during a segment is judged as the radio
    already held it, or it would go unjudged.
  - **S.Port's mode and armed state** come only in the status word, so they are judged
    against the 6 s before their arrival.
  - **Voice:** the capture records each callout played, and every mode change, arming and
    disarming the test made must be said within the time the link takes to carry it.
  - `hwtest.py rehearse` runs it all against SITL, a simulated radio writing the capture.
    S.Port's words there come from passthrough over CRSF, since a FrSky port would stop them;
    once a GCS is connected SITL sends text only as whole messages (0xF1), which the
    simulated radio turns into text words, as S.Port carries it.
  - **Messages** arriving until the next segment begins are a segment's own: over a slow link
    a burst takes a minute. One that arrives within two minutes of the recording's start may
    have been sent before it, so it is listed, not judged.
  - `tools/ethos-sim/run.cjs --pull DIR` copies a capture out of the X20 simulator;
    Ethos's `io.open(name, "a")` and `io.write(file, text)` append as expected.
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
- **Map tiles without a GCS:** `tools/build.py --maps DIR` copies a folder as Lofty GCS writes
  it (`index.txt` and the layers) into the widget's `maps`.
- **The device browser without a device.** Neither simulator has a CRSF device, so
  `tools/sitl.py menu out/gyro-menu.txt` records the gyro's menu from SITL and `tools/build.py
  --menu` puts it beside the scripts as `menu.txt`, with `tools/snapshot.lua` as
  `core/snapshot.lua`: it answers from the recording, keeps written values, and answers a
  command with a confirmation. Frames stay hex until asked for (see `create` above).

## Language

American English everywhere. Third-party text and identifiers keep their spelling.
