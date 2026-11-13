# Lofty PFD

A primary flight display for RC radios flying [ArduPilot](https://ardupilot.org), in the
style of [Lofty GCS](https://gcs.loftedaero.com), and the setup tool for Lofted Aero's gyro
firmware.

- **Radios:** Ethos (FrSky X20 and family) and EdgeTX 2.11 or later on color radios.
- **Links:** ExpressLRS and Crossfire (plain CRSF telemetry or ArduPilot passthrough), and
  FrSky S.Port and F.Port passthrough.
- **Setup:** browses and edits the settings of any CRSF device (transmitter module,
  receiver, flight controller). A guided setup for the gyro is planned.

Status: **preview.** It runs in the Ethos and EdgeTX simulators against recorded ArduPilot
SITL flights and the gyro's SITL menu, and on one X20 on the bench over S.Port. ExpressLRS and
EdgeTX haven't been tried on a real radio yet.

## Installing

Download the zip for your radio from the
[latest release](https://github.com/LoftedAero/loftypfd/releases/latest) and unzip it onto the
radio's SD card. [Installing and testing Lofty PFD](docs/installing.md) has the steps for each
radio, ArduPilot's settings, and how to report issues. Lofty GCS will install and update it
too.

## Development

Requires Python 3.14 on Windows. The SITL checks also need WSL with the gyro firmware's SITL
build and a Python there with the same packages (`tools/requirements.txt`).

```sh
py -3.14 -m venv .venv
.venv/Scripts/python -m pip install -r tools/requirements.txt
.venv/Scripts/python tools/test.py
```

See [CLAUDE.md](CLAUDE.md), [docs/architecture.md](docs/architecture.md) and, for a release,
[docs/releasing.md](docs/releasing.md).

## License

GPL-3.0. See [LICENSE](LICENSE).

The voice clips are spoken by [Piper](https://github.com/OHF-Voice/piper1-gpl)'s "cori"
voice: Cori Samuel's LibriVox readings, from the Hi-Fi Multi-Speaker English TTS Dataset by
NVIDIA ([openslr.org/109](https://www.openslr.org/109/)), licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). See
[src/audio/en/CREDITS.txt](src/audio/en/CREDITS.txt).
