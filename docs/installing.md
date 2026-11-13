# Installing and testing Lofty PFD

This guide covers installing Lofty PFD on an Ethos or EdgeTX radio, setting up ArduPilot's
telemetry for it, and reporting what you find.

Lofty PFD shows what the aircraft sends, speaks callouts, and edits the settings of CRSF
devices: the transmitter module, the receiver and the flight controller. Preview builds are
early builds shared for feedback, and have yet to be fully validated in the real world:

- Keep the radio's own telemetry alarms (RSSI, link quality, battery) set up. Don't rely on
  Lofty PFD's callouts alone.
- Take the props off before changing settings in the device browser.
- Note down any setting you change in the device browser, so you can put it back.

## What you need

- **A radio:** a FrSky radio with Ethos 1.6 or later (X20 and family), or a color-screen radio
  with EdgeTX 2.11 or later.
- **A link:** ExpressLRS or Crossfire, or a FrSky receiver with S.Port or F.Port.
- **ArduPilot** sending telemetry on that link (see "Setting up ArduPilot" below).

So far Lofty PFD has run on one X20 on the bench, over S.Port, and in the Ethos and EdgeTX
simulators against ArduPilot's simulator. ExpressLRS and EdgeTX haven't been tried on a real
radio yet.

## Installing

Lofty GCS will install and update Lofty PFD on a radio's SD card. Until then, install it by
hand from the release's zip for your radio.

### Ethos

1. Download `LoftyPFD_<version>_ethos.zip` from the release.
2. Connect the radio by USB and choose **USB storage**. Ethos shows the radio's storage and its
   SD card as drives.
3. Unzip onto the SD card's root, replacing what is there. That puts Lofty PFD in
   `scripts/loftypfd`.
4. When updating, delete every file ending in `.luac` in `scripts/loftypfd` and its `core`
   folder. Ethos compiles each script beside its source, and an old compiled copy can run in
   place of the new one. Keep the `maps` folder; it holds the tiles Lofty GCS copied.
5. Eject the drive and unplug.

To put it on a screen, tap the screens icon in the bottom bar, add a screen (or pick one), and
choose **Change layout**, then **Full screen**. Then choose **Configure** and pick Lofty PFD from
the widget list. It also runs in smaller layouts.

The device browser also opens on its own from the System menu, on its second page, as Lofty
PFD.

### EdgeTX

1. Download `LoftyPFD_<version>_edgetx.zip` from the release.
2. Connect the radio by USB and choose **USB Storage (SD)**.
3. Unzip onto the SD card's root, replacing what is there. That puts the widget in
   `WIDGETS/LoftyPFD`, the tool in `SCRIPTS/TOOLS`, and the voice clips in `SOUNDS/en/lofty`.
4. When updating, delete every file ending in `.luac` in `WIDGETS/LoftyPFD` and its `core`
   folder, and `SCRIPTS/TOOLS/LoftyPFD.luac`. Keep the `maps` folder.
5. Eject the drive and unplug.

To put it on a screen, open the model's screen setup, add a screen with the full-screen
layout, and choose LoftyPFD as its widget. EdgeTX passes touches and keys to a widget only in
full-screen mode: select the widget and choose Full screen, or, on EdgeTX 2.11 and later, use
the App mode layout and long-press it. Outside full-screen mode it shows everything but can't
be operated.

The device browser also opens on its own from the radio's tools menu (SYS, then Tools), as
Lofty PFD.

## Setting up ArduPilot

**ExpressLRS or Crossfire.** The receiver's port is `SERIALn_PROTOCOL 23` (RCIN), as for RC
alone. With nothing more, ArduPilot sends plain CRSF telemetry: attitude, GPS, battery,
altitude and flight mode. Two `RC_OPTIONS` bits add more:

- **Bit 12 (4096)** marks a disarmed flight mode with a star, which is the only way plain CRSF
  carries the armed state.
- **Bit 8 (256)** turns on passthrough over CRSF, which adds messages, failsafes, home,
  satellites and the fix. Without it, Lofty PFD shows no messages and says only the mode,
  arming and battery steps.

Make sure the ELRS telemetry ratio isn't Off. On Ethos, go to Telemetry and choose **Discover
new sensors** with the receiver powered, so the link quality sensors exist.

**FrSky S.Port or F.Port.** Set the port to `SERIALn_PROTOCOL 10` (FrSky passthrough), with the
inversion your board needs. ArduPilot's "FrSky Telemetry" page has the details for each board.
Then discover the sensors on the radio. A setup that already works with Yaapu's script works
as it is.

Over S.Port the mode name can take half a minute to appear after power-up. The name needs the
frame type, which ArduPilot sends only now and then.

## Settings

On Ethos, long-press the widget and choose Configure widget. On EdgeTX, open the widget's
settings from the screen setup.

| Setting | Choices |
| --- | --- |
| Top tile, Bottom tile | Battery, Position |
| Theme | Match the radio, Light, Dark |
| Distance and altitude | Meters, Feet |
| Speed | Meters per second, Kilometers per hour, Knots, Miles per hour |
| Climb rate | Follow distance, Meters per second, Feet per minute |
| Coordinates | Decimal degrees; Degrees, minutes, seconds |
| Cell count | Automatic, 1S to 14S. Set it for a large pack plugged in partly flat. |
| Voice callouts | All, Alerts only, Off |
| Devices button | Show, Hide |
| Warning beeps | Always, Only when armed |

Warnings and colors come from the aircraft's own thresholds, so there are none to set here.

## Using it

- **Tap the HUD or the map** to fill the screen with it; tap again to go back.
- **The swap button**, top right of the HUD or map, swaps between them. It shows a little map
  on the HUD and a little horizon on the map.
- **On the map,** the + and − buttons and the rotary zoom.
- **Tap the message log** to fill the screen with it. The rotary or a drag scrolls it; tap
  again to close it.
- **The sliders button,** bottom right, opens the device browser. Back from its top page
  returns to the flight display.

## Maps

The map shows satellite imagery stored on the radio. To store some, open Lofty GCS, go to Plan
→ Offline maps, frame the area you fly, press **Copy to radio**, and pick the radio's SD card.
Lofty GCS writes the tiles into Lofty PFD's folder.

Updating Lofty PFD by unzipping over it keeps the maps. Deleting its folder first doesn't.

## Reporting issues

Open an issue at <https://github.com/LoftedAero/loftypfd/issues>, or email
info@loftedaero.com.

Confusing behavior counts as a bug. If you could not find something, that is worth reporting.

When something breaks, include:

- what you were doing, and what you expected to happen
- the Lofty PFD version (the zip's name)
- the radio's model and its Ethos or EdgeTX version
- the link (ExpressLRS, Crossfire, S.Port or F.Port), and whether passthrough was on
- the vehicle type and ArduPilot version

A photo of the screen helps, especially for layout or wording problems.
