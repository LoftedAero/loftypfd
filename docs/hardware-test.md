# Hardware test: the X20

Lofty PFD on a real FrSky X20, checked against a real flight controller. Two bench
sessions: ELRS on the Kakute F4 Wing gyro, then S.Port on a stock ArduPlane board. Props
off throughout. The TX15 (EdgeTX) follows when it arrives.

Most of it is automated. A test build of the widget records everything it receives and
sends to the radio's SD card. Meanwhile `tools/hwtest.py` drives the flight controller over
USB and records its MAVLink, then judges the radio's decoding and its voice callouts
against it. The PC prompts
you when it needs hands: rocking the board, the device browser, and copying the capture
off the radio. What only eyes can judge is in the checklist at the end.

## What you need

- X20 with Ethos 1.6 or later, charged.
- **ELRS session:** an ExpressLRS 3.x module in the X20's module bay, and an ELRS receiver
  bound to it, on the Kakute F4 Wing gyro's RC port (SERIAL3).
- **S.Port session:** a FrSky ACCESS receiver with an S.Port pin (Archer R4, R6 or R8, RS,
  R-XSR and similar), bound to the X20's internal module, on a flight controller running stock
  ArduPlane 4.5 or later.
- A flight battery for each board, so the receiver is powered and battery voltage can be
  checked. **Props off.**
- USB cables for the flight controller and the X20.
- The PC with this repository and its venv. `pyserial` is new, so install the requirements
  again:

  ```
  .venv/Scripts/python -m pip install -r tools/requirements.txt
  ```

## Once: put the test build on the X20

1. Connect the X20 by USB and choose **USB storage** (Ethos shows the radio's storage
   and its SD card as drives).
2. Run:

   ```
   .venv/Scripts/python tools/hwtest.py install
   ```

   This finds Lofty PFD's folder (`scripts/loftypfd`), builds the test version and copies
   it over. Maps and earlier captures stay. On a card without Lofty PFD yet, name the drive:
   `install --sd E:`.
3. Optional, for the map: in Lofty GCS, go to Plan → Offline maps. Frame the SITL field
   near Canberra (−35.363, 149.165), where the test's simulated GPS puts the aircraft, or
   your own location if you have a real GPS fix. Then press **Copy to radio** and pick the
   X20's SD card.
4. Unplug. On the X20, give a model a screen with the full-screen layout and the Lofty PFD
   widget. Do it on the model each session will use, or use one model for both.
5. In the widget's settings (long-press it, Configure widget), set Voice callouts to All,
   and turn the radio's volume up.

The test build behaves like the normal one. It also writes a new
`scripts/loftypfd/capture-<n>.txt` each time the widget starts, about 2 kB a second while
telemetry flows.

## Session 1: ELRS on the Kakute F4 Wing gyro

**Set up**

1. Gyro firmware flashed, with its defaults: `SERIAL3_PROTOCOL 23`, `RC_OPTIONS 4192`.
2. In Ethos, set the model's external module to CRSF, with the ELRS module in the bay. Check
   that the receiver is bound and the ELRS telemetry ratio isn't Off.
3. In Ethos, go to Telemetry → **Discover new sensors** with the receiver powered, so the link
   sensors (link quality, RSSI) exist.
4. Battery on the Kakute, props off. Connect the Kakute to the PC by USB.
5. On the X20, the Lofty PFD screen should show the flight mode and a status pill that no
   longer says "No telemetry".

**Run**

```
.venv/Scripts/python tools/hwtest.py run elrs
```

The run finds the flight controller's COM port by itself; if it can't, give it with
`--port COM7`. It takes about 10 minutes. Here is what it does, and what you do:

1. **Checks the setup.** It reads the receiver port and RC_OPTIONS and asks you to confirm
   the safety list. It turns on RC_OPTIONS bit 12 for the test, if it's off, so plain CRSF
   carries the armed state.
2. **Sets up a GPS.** Indoors there's no fix, so it offers a simulated GPS from the PC. It
   sets GPS1_TYPE to 14 (MAVLink), reboots, and feeds positions at the SITL field. Say yes
   unless the board has a real fix.
3. **Plain CRSF segment:**
   - It asks you to **rock the board** left and right about 30° until it says stop. Rocking
     lines up the radio's clock with the PC's.
   - It cycles FBWA, ACRO and MANUAL, 7 s each.
   - It arms for 8 s and disarms. Arming is forced, so it first checks the throttle is down.
   - It asks ArduPilot to send its banner messages.
4. **Passthrough segment:** it sets RC_OPTIONS bit 8 (passthrough over CRSF), reboots, and
   repeats step 3, rocking included.
5. **Device browser:** follow the prompt.
   - Tap the sliders button and open every device and every folder.
   - In the Gyro, change one setting and change it back. The Radio folder's Autotune
     switch is a safe one.
   - Run no commands.
6. **Puts back what it changed** (GPS1_TYPE, RC_OPTIONS) and reboots. If it can't, it says so
   in capitals.
7. **Fetches the capture.** Connect the X20 by USB, choose USB storage, and press Enter. It
   copies the newest capture and analyzes it.

You can press Ctrl+C at any point; the parameters are still put back.

## Session 2: S.Port on stock ArduPlane

**Set up**

1. **Wiring.** S.Port is an inverted, half-duplex signal. Connect the receiver's S.Port pin to
   a UART's TX pin and set:
   - `SERIALn_PROTOCOL 10` (FrSky passthrough)
   - `SERIALn_OPTIONS 7` on F7 and H7 boards (inverted, half-duplex)
   - On F4 boards, which can't invert, use the receiver's uninverted S.Port pad or an inverter,
     and set `SERIALn_OPTIONS 4`.

   ArduPilot's "FrSky Telemetry" page has the details for each board. RC goes in as SBUS on
   the RC input, as usual. Reboot after changing these.
2. **Receiver.** Bind it to the X20's internal module (ACCESS). Then go to Telemetry →
   **Discover new sensors**, which should list RSSI and ArduPilot's passthrough sensor.
3. **Check it's working.** Battery on, props off, USB to the PC. Lofty PFD should show the
   mode name before you start. Over S.Port that can take half a minute: the name needs the
   frame type, which ArduPilot sends only now and then, and until it comes no mode is said.

**Run**

```
.venv/Scripts/python tools/hwtest.py run sport
```

The steps are the same as for ELRS, with one segment and no device browser. S.Port sends
the mode and armed state every 3 to 5 seconds, so the analysis allows for that delay.

## Reading the result

Each run leaves a folder `out/hw/<date>-<time>-<link>/`:

| File | What |
| --- | --- |
| `report.txt` | the verdict, also printed at the end of the run |
| `capture.txt` | everything the radio received and sent |
| `mavlink.jsonl` | the flight controller's MAVLink over the same time |
| `session.json` | when each step happened |

The report covers each segment, then the widget, then the device menus. A PASS or FAIL line
can be one of these checks:

- **Each reading matches MAVLink:** roll, pitch, heading, position, altitude, climb, battery,
  mode, armed and satellites. Every value the radio decoded is checked against what
  ArduPilot reported around that moment, by the same rules as the SITL test.
- **Messages:** messages arrive, and each one shown is a message ArduPilot sent. Plain CRSF
  carries no text, so that line only reports a count.
- **Link sensors:** the link quality (ELRS) or RSSI (S.Port), and the transmitter's battery.
- **The radio's own decoding:** what the X20 decoded matches the core run on the PC. This
  catches any difference between Ethos's Lua and the PC's.
- **The widget kept running:** no pause longer than 3 s. Also reported: its slowest wakeup
  and paint times, and its memory use.
- **Device menus:** every device's entries loaded and parsed, and the setting you changed was
  read back as written.
- **Voice:** every callout played is listed, and each mode change, arming and disarming the
  test made must have been said.

To analyze again after a fix to the analysis, run:

```
.venv/Scripts/python tools/hwtest.py analyze out/hw/<session>
```

**Send me the whole session folder.** A FAIL is most useful with its capture: the capture can
be replayed in both simulators (`tools/build.py --replay`).

## Watch while it runs

Automation can't judge these, so check them by eye during or after a session. Note anything
that looks wrong, along with the time.

- **HUD:**
  - Rock right: the horizon tilts so its right end rises, and the bank pointer swings left.
  - Pitch up: the horizon drops.
  - The heading ribbon turns the right way when you yaw the board.
- **Status bar:**
  - The pill goes "Disarmed", then "Armed", then "Disarmed".
  - The mode name changes with each step.
  - LQ and the signal bars show (ELRS), and the TX voltage shows.
- **Tiles:** battery volts and per cell, the satellite count, and the position at the SITL
  field.
- **Message log:**
  - The banner lines appear, with repeats counted.
  - Tap the log: it fills the screen, and the rotary and a drag scroll it. Tap again to close
    it.
- **Map:** tap the swap button (the little map, top right of the HUD) to swap to the map.
  - The orange arrow sits at the SITL field and points along the heading.
  - Satellite imagery shows if you copied tiles. Zoom + and − work, and so does the rotary.
  - Tap the map: it fills the screen; tap again to go back. The swap button swaps back to
    the HUD; on the map it shows a little horizon.
- **Device browser:**
  - Values edit in their box, with the step arrows.
  - The Gyro's Learn buttons sit beside their channels.
  - A long list scrolls by drag and by rotary.
  - Back goes up one level, then back to the flight display.
- **Voice and alerts:** listen as the run goes.
  - The mode is said each time it changes, as "Fly by wire A mode", "Acro mode" and "Manual
    mode", within a second over CRSF and up to 5 s over S.Port.
  - "Armed" and "Disarmed".
  - A warning message, such as one from the banner, gives three quick beeps.
  - The words are clear and the clips aren't cut short.
  - Set Voice callouts to Off, change mode with the switch, and nothing is said.
  - For a critical callout, switch the receiver off while armed, then on. The radio feels a
    buzz with "Radio failsafe" over passthrough. Note how long the buzz is: Ethos's units for
    it are unconfirmed.
- **Settings:** long-press the widget, then Configure widget.
  - Change the units: altitude in feet, speed in knots.
  - Set Theme to Light, then Dark, and check both look right.
- **System tool:** System menu, page 2, Lofty PFD. It opens the device browser on its own.
- **Link loss:** switch the receiver off. Within 3 s the pill says "Link lost" and the
  readings hold. Switch it back on, and it recovers.

## If something goes wrong

- **"No serial port has SERIALn_PROTOCOL …":** the flight controller isn't set up for that
  link. Set the parameter, reboot, and run again.
- **"The link quality reads … never":** Ethos named the ELRS sensors differently from what
  Lofty PFD looks for. Send me the sensor names from Ethos's telemetry list.
- **"The radio's clock lines up …" fails:** no mode change or rocking was seen on both sides.
  Check that telemetry was arriving (the pill), and rock harder next time.
- **No capture on the radio:** the test build isn't installed (`hwtest.py install`), or the
  widget wasn't on screen.
- **The flight controller doesn't come back after a reboot:** power-cycle it. Then check that
  GPS1_TYPE and RC_OPTIONS are back to their old values; the run prints both.

## Afterwards

Put the normal build back with the radio in USB storage mode. This removes the test build's
flag file and keeps the maps:

```
.venv/Scripts/python tools/build.py --sd E:
```

Delete the `capture-*.txt` files from `scripts/loftypfd` once they're copied off.

## Without hardware

`hwtest.py rehearse elrs` and `rehearse sport` run the whole thing against the gyro's SITL in
WSL. A simulated radio writes the capture, and nothing is asked. That checks the tooling, but
not the X20.
