# Lofty PFD

A primary flight display for RC radios flying [ArduPilot](https://ardupilot.org), in the
style of [Lofty GCS](https://gcs.loftedaero.com), and the setup tool for Lofted Aero's gyro
firmware.

- **Radios:** Ethos (FrSky X20 and family) and EdgeTX 2.11 or later on color radios.
- **Links:** ExpressLRS and Crossfire (plain CRSF telemetry or ArduPilot passthrough), and
  FrSky S.Port and F.Port passthrough.
- **Setup:** browses and edits the settings of any CRSF device (transmitter module,
  receiver, flight controller). A guided setup for the gyro is planned.

Status: **in development.** It runs in the Ethos and EdgeTX simulators against recorded
ArduPilot SITL flights and the gyro's SITL menu; it has not been tested on a radio yet.

## Development

Requires Python 3.14 on Windows. The SITL checks also need WSL with the gyro firmware's SITL
build and a Python there with the same packages (`tools/requirements.txt`).

```sh
py -3.14 -m venv .venv
.venv/Scripts/python -m pip install -r tools/requirements.txt
.venv/Scripts/python tools/test.py
```

See [CLAUDE.md](CLAUDE.md) and [docs/architecture.md](docs/architecture.md).

## License

GPL-3.0. See [LICENSE](LICENSE).
