"""Lofty PFD on a real radio, checked against the flight controller's MAVLink.

    .venv/Scripts/python tools/hwtest.py install [--sd DRIVE]
    .venv/Scripts/python tools/hwtest.py run elrs|sport [--port COM5]
    .venv/Scripts/python tools/hwtest.py analyze out/hw/<session> [--capture FILE]
    .venv/Scripts/python tools/hwtest.py rehearse elrs|sport

install puts a test build on the X20's SD card (tools/build.py --capture),
which records everything the widget receives and sends (core/capture.lua).

run drives a bench test through the flight controller's USB, recording its
MAVLink: fake GPS where there is none, a hand-rocked roll to line up the
clocks, a cycle of flight modes, arming and disarming, ArduPilot's banner
messages, and over ELRS the same again with passthrough (RC_OPTIONS bit 8),
then the device browser. Parameters it changes are put back. Then it copies
the radio's capture off the SD card and analyzes it.

analyze decodes the capture with the same core the radio runs, lines its clock
up with the PC's and judges every reading against MAVLink as the SITL test
does (tools/judge.py), with the radio's own decoding, the link sensors, the
widget's timing and the device menus besides.

rehearse runs the same thing against SITL, with a simulated radio writing the
capture, to check the tooling without hardware (runs in WSL, like
tools/sitl.py).
"""
import argparse
import bisect
import datetime
import json
import math
import pathlib
import shutil
import statistics
import string
import subprocess
import sys
import threading
import time
import types

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

import judge  # noqa: E402
import re  # noqa: E402

OUT = ROOT / "out" / "hw"
# What the MAVLink recording keeps.
RECORDED = {
    "HEARTBEAT", "ATTITUDE", "GLOBAL_POSITION_INT", "VFR_HUD", "SYS_STATUS", "GPS_RAW_INT",
    "STATUSTEXT", "HOME_POSITION", "RC_CHANNELS", "COMMAND_ACK", "AUTOPILOT_VERSION",
}
# Messages ArduPilot's telemetry library sends the radio link and not
# MAVLink (AP_RCTelemetry.cpp): sensor health, and the firmware at startup.
TELEMETRY_ONLY = re.compile(r"^(Bad .* Health|Bad or No Terrain Data|Ardu\w+ V\d.*|ChibiOS: .*)$")
FORCE = 21196  # MAV_CMD_COMPONENT_ARM_DISARM's force code
CMD_SEND_BANNER = 42428
# Where the fake GPS puts the aircraft: the SITL field, which Lofty GCS's
# development maps cover.
FAKE_HOME = (-35.363261, 149.165230, 584.0)
MODES = {
    1: ["FBWA", "ACRO", "MANUAL"],                      # fixed wing
    2: ["ALT_HOLD", "ACRO", "STABILIZE"],               # quad
}
MODE_HOLD_S = 7     # passthrough's status word comes every 3.4 to 4.7 s
# The longest a mode change takes to reach the radio, and how far back a
# reading carried only by that status word is judged: S.Port's mode and
# armed state.
MODE_LATENCY_S = 6
SLOW_OVER_SPORT = {"mode": MODE_LATENCY_S, "armed": MODE_LATENCY_S}
ARMED_HOLD_S = 8
RC_PASSTHROUGH = 256
RC_STAR = 4096


# --- The radio's SD card ----------------------------------------------------

def find_widget():
    """Lofty PFD's folder on a mounted radio, or None: the X20 in USB storage
    mode shows its flash and its SD card as drives, and scripts can be on
    either."""
    for letter in string.ascii_uppercase[3:]:
        folder = pathlib.Path("%s:/scripts/loftypfd" % letter)
        try:
            if (folder / "main.lua").exists():
                return folder
        except OSError:
            continue
    return None


def install(sd):
    drive = pathlib.Path(sd) if sd else None
    if drive is None:
        widget = find_widget()
        if widget is None:
            sys.exit("No radio with Lofty PFD found. Connect the X20 by USB and choose "
                     "USB storage, or give --sd X: for a fresh card.")
        drive = widget.parent.parent
    subprocess.check_call([sys.executable, str(ROOT / "tools" / "build.py"), "--capture", "--sd", str(drive)])


def newest_capture(folder):
    found = []
    for p in folder.glob("capture-*.txt"):
        try:
            found.append((int(p.stem.split("-")[1]), p))
        except ValueError:
            pass
    return max(found)[1] if found else None


# --- The flight controller --------------------------------------------------

class Bench:
    """The flight controller over MAVLink, every message kept in a file."""

    def __init__(self, url, baud, log_path, ask):
        from pymavlink import mavutil
        self.mavutil = mavutil
        self.url, self.baud, self.ask = url, baud, ask
        self.log = open(log_path, "a", encoding="utf-8", newline="\n")
        self.lock = threading.Lock()
        self.latest = {}
        self.params = {}
        self.texts = []
        self.m = None
        self.running = True
        self.gps = None
        self.connect()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=self._gps_loop, daemon=True).start()

    def connect(self, timeout=60):
        deadline = time.time() + timeout
        while True:
            try:
                # Reconnection is done here, after a reboot, so pymavlink's
                # own would only hold a dead port open.
                m = self.mavutil.mavlink_connection(self.url, baud=self.baud, source_system=255)
                if m.wait_heartbeat(timeout=10):
                    break
                m.close()
            except Exception:
                pass
            if time.time() > deadline:
                raise RuntimeError("no heartbeat from %s" % self.url)
            time.sleep(1)
        m.mav.request_data_stream_send(m.target_system, m.target_component,
                                       self.mavutil.mavlink.MAV_DATA_STREAM_ALL, 10, 1)
        self.m = m

    def _read(self):
        while self.running:
            m = self.m
            try:
                msg = m.recv_match(blocking=True, timeout=0.5)
            except Exception:
                time.sleep(0.2)
                continue
            if msg is None:
                continue
            t = msg.get_type()
            if t not in RECORDED and t != "PARAM_VALUE":
                continue
            if t == "HEARTBEAT" and msg.get_srcComponent() != 1:
                continue
            now = time.time()
            with self.lock:
                self.latest[t] = msg
                if t == "PARAM_VALUE":
                    self.params[msg.param_id] = msg.param_value
                    continue
                if t == "STATUSTEXT":
                    self.texts.append((now, msg.text))
            d = msg.to_dict()
            d["_t"] = now
            if t == "HEARTBEAT":
                d["mode_name"] = self.mavutil.mode_string_v10(msg)
            self.log.write(json.dumps(d, default=str) + "\n")

    def get(self, msg_type):
        with self.lock:
            return self.latest.get(msg_type)

    def wait(self, seconds):
        time.sleep(seconds)

    def mode(self):
        hb = self.get("HEARTBEAT")
        return hb and self.mavutil.mode_string_v10(hb)

    def armed(self):
        hb = self.get("HEARTBEAT")
        return bool(hb and hb.base_mode & judge.ARMED_FLAG)

    def param(self, name, timeout=4):
        for _ in range(2):
            with self.lock:
                self.params.pop(name, None)
            self.m.param_fetch_one(name)
            deadline = time.time() + timeout / 2
            while time.time() < deadline:
                with self.lock:
                    if name in self.params:
                        return self.params[name]
                time.sleep(0.05)
        return None

    def set_param(self, name, value):
        for _ in range(3):
            self.m.param_set_send(name, value)
            time.sleep(0.3)
            got = self.param(name)
            if got is not None and abs(got - value) < 1e-3:
                return True
        return False

    def command(self, cmd, *params):
        p = list(params) + [0] * (7 - len(params))
        self.m.mav.command_long_send(self.m.target_system, self.m.target_component, cmd, 0, *p)

    def set_mode(self, name):
        mapping = self.m.mode_mapping() or {}
        if name not in mapping:
            return False
        self.m.set_mode(mapping[name])
        deadline = time.time() + 5
        while time.time() < deadline:
            if self.mode() == name:
                return True
            time.sleep(0.1)
        return False

    def arm(self, on):
        self.command(self.mavutil.mavlink.MAV_CMD_COMPONENT_ARM_DISARM, 1 if on else 0, FORCE)
        deadline = time.time() + 5
        while time.time() < deadline:
            if self.armed() == on:
                return True
            time.sleep(0.1)
        return False

    def reboot(self):
        """Reboots and reconnects: over USB the port goes away and comes back."""
        self.command(self.mavutil.mavlink.MAV_CMD_PREFLIGHT_REBOOT_SHUTDOWN, 1)
        time.sleep(1)
        try:
            self.m.close()
        except Exception:
            pass
        time.sleep(2)
        self.connect(timeout=90)
        time.sleep(3)

    def home(self):
        with self.lock:
            self.latest.pop("HOME_POSITION", None)
        self.command(self.mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE,
                     self.mavutil.mavlink.MAVLINK_MSG_ID_HOME_POSITION)
        deadline = time.time() + 5
        while time.time() < deadline:
            h = self.get("HOME_POSITION")
            if h is not None:
                return h.latitude / 1e7, h.longitude / 1e7
            time.sleep(0.1)
        return None

    def _gps_loop(self):
        """GPS_INPUT at 5 Hz while a fake GPS is on: still where the attitude
        comes from an EKF, which would reject a GPS moving under a still IMU;
        a slow circle where it is DCM."""
        t0 = time.time()
        while self.running:
            time.sleep(0.2)
            g = self.gps
            if not g:
                continue
            lat0, lon0, alt = FAKE_HOME
            north = east = vn = ve = 0.0
            if g == "moving":
                a = (time.time() - t0) * 3 / 40      # 3 m/s on a 40 m circle
                north, east = 40 * math.sin(a), 40 * (1 - math.cos(a))
                vn, ve = 3 * math.cos(a), 3 * math.sin(a)
            lat = lat0 + north / 111320
            lon = lon0 + east / (111320 * math.cos(math.radians(lat0)))
            now = time.time()
            gps_s = now - 315964800 + 18          # the GPS epoch, and leap seconds
            week = int(gps_s // 604800)
            week_ms = int((gps_s - week * 604800) * 1000)
            try:
                self.m.mav.gps_input_send(int(now * 1e6), 0, 0, week_ms, week, 3, int(lat * 1e7),
                                          int(lon * 1e7), alt, 0.8, 1.2, vn, ve, 0, 0.3, 1.0, 1.5, 14, 0)
            except Exception:
                pass

    def close(self):
        self.running = False
        time.sleep(0.7)
        try:
            self.m.close()
        except Exception:
            pass
        self.log.close()


def serial_port():
    """The flight controller's USB port: the one pymavlink recognizes as an
    autopilot, else the only one."""
    from pymavlink import mavutil
    ports = mavutil.auto_detect_serial(preferred_list=["*ArduPilot*", "*Holybro*", "*STM32*", "*CubePilot*",
                                                        "*Kakute*", "*Matek*", "*TBS*", "*mRo*", "*PX4*"])
    if len(ports) >= 1:
        return ports[0].device
    from serial.tools import list_ports
    every = list(list_ports.comports())
    if len(every) == 1:
        return every[0].device
    sys.exit("Found %d serial ports; name the flight controller's with --port: %s" % (
        len(every), ", ".join(p.device for p in every)))


def check_config(bench, link):
    """What the flight controller is set up to send. Returns the RC_OPTIONS
    to start from, or exits when the link is not configured."""
    protocols = {}
    for n in range(0, 9):
        v = bench.param("SERIAL%d_PROTOCOL" % n, timeout=2)
        if v is not None:
            protocols[n] = int(v)
    rc = int(bench.param("RC_OPTIONS") or 0)
    want = 23 if link == "elrs" else 10
    ports = [n for n, v in protocols.items() if v == want]
    if not ports:
        sys.exit("No serial port has SERIALn_PROTOCOL %d (%s). Set it on the port the receiver is wired "
                 "to, reboot, and run again." % (want, "RCIN, for CRSF" if want == 23 else "FrSky passthrough"))
    print("  receiver on SERIAL%s, RC_OPTIONS %d" % (ports[0], rc))
    if link == "elrs" and not rc & RC_STAR:
        print("  note: RC_OPTIONS bit 12 is off, so plain CRSF cannot carry the armed state; it is "
              "turned on for the test and put back after")
    return rc


class Session:
    """A run's record: its segments and events, with PC times."""

    def __init__(self, folder, link):
        self.folder = folder
        self.data = {"link": link, "created": datetime.datetime.now().isoformat(timespec="seconds"),
                     "segments": [], "events": []}

    def event(self, kind, at=None, **detail):
        """Something the test did, at the time the command went out: its
        confirmation can come after the radio has heard the change."""
        detail.update(kind=kind, t=at or time.time())
        self.data["events"].append(detail)

    def save(self):
        with open(self.folder / "session.json", "w", encoding="utf-8", newline="\n") as f:
            json.dump(self.data, f, indent=1)


def say(text):
    print(text, flush=True)


def run(args):
    link = args.link
    yes = args.yes
    folder = pathlib.Path(args.out) if args.out else OUT / (
        datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + link)
    folder.mkdir(parents=True, exist_ok=True)

    def ask(text):
        if yes:
            say("  " + text.split("\n")[0] + " [automatic]")
            return ""
        return input("\n" + text + "\n  Press Enter to go on: ")

    url = args.mavlink or serial_port()
    say("Lofty PFD hardware test, %s, session %s" % (link, folder))
    say("Connecting to the flight controller on %s" % url)
    bench = Bench(url, args.baud, folder / "mavlink.jsonl", ask)
    session = Session(folder, link)
    restore = {}
    try:
        deadline = time.time() + 5
        while bench.get("HEARTBEAT") is None and time.time() < deadline:
            time.sleep(0.1)
        hb = bench.get("HEARTBEAT")
        session.data["vehicle"] = {"type": hb.type, "autopilot": hb.autopilot}
        bench.command(bench.mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE,
                      bench.mavutil.mavlink.MAVLINK_MSG_ID_AUTOPILOT_VERSION)
        time.sleep(1)
        if getattr(args, "check_ports", True):
            rc = check_config(bench, link)
        else:
            rc = int(bench.param("RC_OPTIONS") or 0)
        ask("Safety and setup:\n"
            "  - Propellers OFF. The test arms the flight controller.\n"
            "  - Flight battery connected, so the receiver is powered and voltage can be checked.\n"
            "  - X20 on, the Lofty PFD test build on screen, receiver bound, the status pill not\n"
            "    'No telemetry'. Throttle stick down; leave the switches alone during the test.")

        # A GPS: the real one where it has a fix, else one from the PC.
        gps = args.gps
        if gps == "auto":
            deadline = time.time() + 5
            gps = "none"
            while time.time() < deadline:
                g = bench.get("GPS_RAW_INT")
                if g is not None and g.fix_type >= 3:
                    gps = "real"
                    break
                time.sleep(0.2)
            if gps == "none" and not yes:
                answer = input("\nNo GPS fix. Simulate a GPS from the PC? It sets GPS1_TYPE to 14 (MAVLink),"
                               " reboots, and puts it back at the end. [Y/n] ")
                gps = "none" if answer.strip().lower().startswith("n") else "fake"
        reboot = False
        if gps == "fake":
            name = "GPS1_TYPE" if bench.param("GPS1_TYPE") is not None else "GPS_TYPE"
            old = bench.param(name)
            if old != 14:
                restore[name] = old
                bench.set_param(name, 14)
                reboot = True
            ekf = bench.param("AHRS_EKF_TYPE")
            bench.gps = "still" if ekf not in (None, 0) else "moving"
        session.data["gps"] = gps
        say("GPS: %s%s" % (gps, " (%s)" % bench.gps if bench.gps else ""))

        variants = ["crsf", "crsf-passthrough"] if link == "elrs" else ["sport"]
        if args.only:
            variants = [v for v in variants if v == args.only]
        base_rc = rc | RC_STAR if link == "elrs" else rc
        for variant in variants:
            want_rc = base_rc | RC_PASSTHROUGH if variant == "crsf-passthrough" else base_rc & ~RC_PASSTHROUGH
            if link == "elrs" and want_rc != int(bench.param("RC_OPTIONS") or 0):
                restore.setdefault("RC_OPTIONS", rc)
                bench.set_param("RC_OPTIONS", want_rc)
                reboot = True
            if reboot:
                say("Rebooting the flight controller for the new settings")
                bench.reboot()
                reboot = False
            segment(bench, session, variant, want_rc, ask, yes, args.no_arm)
            session.save()

        if link == "elrs" and not yes:
            start = time.time()
            ask("Device browser: on the radio, tap the sliders button at the bottom right.\n"
                "  Open every device listed, and in each every folder. In the Gyro, change one\n"
                "  setting (the Radio folder's Autotune switch, say) and change it back. Run no\n"
                "  commands. Then press Back until the flight display shows again.")
            session.data["menu"] = [start, time.time()]
        home = bench.home()
        session.data["home"] = home
    finally:
        changed = bool(restore)
        for name, value in restore.items():
            if value is not None:
                say("Putting %s back to %s" % (name, int(value)))
                if not bench.set_param(name, value):
                    say("  COULD NOT: set %s to %s by hand" % (name, int(value)))
        bench.gps = None
        if changed and not yes:
            say("Rebooting the flight controller to apply them")
            try:
                bench.reboot()
            except Exception as e:
                say("  reboot failed (%s): power-cycle it" % e)
        session.save()
        bench.close()

    capture = pathlib.Path(args.capture) if args.capture else fetch_capture(folder, yes)
    if capture:
        if capture.resolve() != (folder / "capture.txt").resolve():
            shutil.copy2(capture, folder / "capture.txt")
        return analyze(folder)
    return 1


def segment(bench, session, variant, rc, ask, yes, no_arm):
    say("\n== %s" % variant)
    seg = {"name": variant, "start": time.time(), "rc_options": rc,
           "passthrough": variant != "crsf", "star": bool(rc & RC_STAR) or variant == "sport"}
    bench.wait(5)
    if not yes:
        ask("Rock the board: roll it left and right by about 30 degrees, a second each way,\n"
            "  and keep going until told to stop (this lines the radio's clock up with the PC's).")
        start = time.time()
        swings = {1: 0, -1: 0}
        side = 0
        while time.time() - start < 40 and min(swings.values()) < 3:
            a = bench.get("ATTITUDE")
            roll = math.degrees(a.roll) if a else 0
            now_side = 1 if roll > 15 else -1 if roll < -15 else 0
            if now_side and now_side != side:
                swings[now_side] += 1
                side = now_side
            time.sleep(0.05)
        say("  Stop. %s" % ("Got it." if min(swings.values()) >= 3 else "Not enough rocking seen; "
                                                                        "the clocks line up by mode changes only."))
        seg["rock"] = [start, time.time()]
        bench.wait(2)

    vtype = session.data["vehicle"]["type"]
    for mode in MODES.get(vtype, MODES[1]):
        at = time.time()
        ok = bench.set_mode(mode)
        say("  mode %s%s" % (mode, "" if ok else ": refused"))
        session.event("mode", at, mode=mode, ok=ok)
        bench.wait(MODE_HOLD_S)

    if not no_arm:
        # Arming is forced, past the checks, so the throttle is checked here.
        thr = int(bench.param("RCMAP_THROTTLE") or 3)

        def throttle():
            rcc = bench.get("RC_CHANNELS")
            return getattr(rcc, "chan%d_raw" % thr, 0) if rcc else 0
        if throttle() > 1150 and not yes:
            ask("The throttle stick is up (%d us). Put it down." % throttle())
        if throttle() > 1150:
            say("  throttle is up (%d us); not arming" % throttle())
            no_arm = True
    if not no_arm:
        at = time.time()
        ok = bench.arm(True)
        say("  armed" if ok else "  arming refused")
        session.event("arm", at, ok=ok)
        bench.wait(ARMED_HOLD_S)
        at = time.time()
        for _ in range(3):
            ok = bench.arm(False)
            if ok:
                break
        say("  disarmed" if ok else "  DISARMING REFUSED: disarm it from the radio now")
        session.event("disarm", at, ok=ok)
        bench.wait(ARMED_HOLD_S)

    bench.command(CMD_SEND_BANNER)
    say("  banner messages sent")
    session.event("banner")
    # S.Port's text is a few characters a word, so a burst takes longer.
    bench.wait(30 if variant == "sport" else 12)
    seg["end"] = time.time()
    session.data["segments"].append(seg)


def fetch_capture(folder, yes):
    if yes:
        return None
    input("\nNow the radio's capture. Unplug the flight controller if you like. Connect the X20 by\n"
          "USB and choose USB storage (SD card). Press Enter once its drives show in Explorer: ")
    for _ in range(30):
        widget = find_widget()
        if widget:
            cap = newest_capture(widget)
            if cap:
                say("Copying %s" % cap)
                return cap
            say("No capture on the radio in %s: was the test build installed (hwtest.py install)?" % widget)
            return None
        time.sleep(1)
    say("No radio found. Copy the newest capture-N.txt from scripts/loftypfd yourself and run\n"
        "  hwtest.py analyze %s --capture FILE" % folder)
    return None


# --- Decoding the capture ---------------------------------------------------

class Core:
    """The Lua core, as the radio runs it."""

    def __init__(self):
        import lupa.lua54 as lua
        self.rt = lua.LuaRuntime()
        read = lambda path: (ROOT / path).read_text(encoding="utf-8")  # noqa: E731
        self.use = self.rt.eval("""function(read)
            local cache = {}
            local function use(name)
              if cache[name] == nil then
                cache[name] = assert(load(read("src/core/" .. name .. ".lua"), "@" .. name))(use)
              end
              return cache[name]
            end
            return use
          end""")(read)
        self.vehicle = self.use("vehicle")
        self.devices = self.use("devices")
        self.capture = self.use("capture")
        self.callouts = self.use("callouts")
        self.state = self.vehicle.new()
        self._apply = self.rt.eval("""function(crsf, passthrough, home, s, kind, a, b, now)
            if kind == "S" then
              passthrough.apply(s, a, b, now)
            else
              local d = {}
              for i = 1, #b do d[i] = b:byte(i) end
              crsf.apply(s, a, d, now)
            end
            home.update(s)
          end""")
        self.crsf, self.passthrough, self.home = self.use("crsf"), self.use("passthrough"), self.use("home")
        self.table = self.rt.table_from
        self.parse = self.rt.eval("""function(devices, id, bytes)
            local d = {}
            for i = 1, #bytes do d[i] = bytes:byte(i) end
            local ok, e = pcall(devices.parseEntry, id, d)
            if not ok then return nil, e end
            if not e then return nil, "too short to parse (" .. #d .. " bytes)" end
            local enc = {}
            local okv, v = pcall(devices.encodeValue, e, e.raw or e.value)
            if okv and e.type ~= 13 and e.type ~= 11 and e.type ~= 12 then
              for i, b in ipairs(v) do enc[i] = b end
            end
            return e, enc
          end""")

    def apply(self, kind, a, b, now):
        self._apply(self.crsf, self.passthrough, self.home, self.state, kind, a, b, now)


def parse_capture(path):
    """(radio time, kind, fields) per line. Kind is "C" for a frame received,
    "S", "P", "L", "D", "W" or "H"."""
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                t = float(parts[0])
            except ValueError:
                continue
            kind = parts[1]
            try:
                if kind.isdigit():
                    out.append((t, "C", (int(kind), bytes.fromhex(parts[2] if len(parts) > 2 else ""))))
                elif kind == "S":
                    out.append((t, "S", (int(parts[2]), int(parts[3]))))
                elif kind == "P":
                    out.append((t, "P", (int(parts[2]), bytes.fromhex(parts[3] if len(parts) > 3 else ""))))
                elif kind in ("L", "D", "W", "A"):
                    out.append((t, kind, parts[2:]))
                elif kind == "H":
                    out.append((t, "H", line.split(None, 2)[2].strip()))
            except (ValueError, IndexError):
                continue
    return out


DEVICE_TYPES = {0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x2D, 0x2E}


def decode(lines):
    """Runs the capture through the core. Returns the readings as they
    changed, the messages as they arrived, the radio's own decoding compared
    with this one, and the device menus."""
    core = Core()
    s = core.state
    messages = []
    s.onMessage = lambda m: messages.append([None, m.text, m.severity])
    pending = []
    checked = {}
    d_checks = [0, []]
    menus = Menus(core)
    for t, kind, f in lines:
        if kind == "C" and f[0] in DEVICE_TYPES:
            menus.received(t, f[0], f[1])
            continue
        if kind == "P":
            menus.sent(t, f[0], f[1])
            continue
        if kind in ("C", "S"):
            n0 = len(messages)
            if kind == "C":
                core.apply("C", f[0], f[1], t)
            else:
                core.apply("S", f[0], f[1], t)
            for m in messages[n0:]:
                m[0] = t
            for name, value in judge.readings(s, core.vehicle).items():
                if value is None or value == checked.get(name):
                    continue
                checked[name] = value
                capped = name == "sats" and s.passthrough and not core.vehicle.recent(s, "crsf.gps")
                pending.append([name, value, t, kind == "S" and "S.Port" or "0x%02X" % f[0], capped])
        elif kind == "D":
            d_checks[0] += 1
            mismatch = own_decoding(f, s, core.vehicle)
            if mismatch and len(d_checks[1]) < 8:
                d_checks[1].append("       radio %.1f s: %s" % (t, mismatch))
            elif mismatch:
                d_checks[1].append(None)
    return pending, messages, d_checks, menus


def own_decoding(fields, s, vehicle):
    """Where the radio's D line differs from this decoding, or None."""
    names = ["roll", "pitch", "yaw", "lat", "lon", "alt", "volts", "mode", "armed"]
    battery = s.battery[1] if s.battery else None
    mine = {"roll": s.roll, "pitch": s.pitch, "yaw": s.yaw, "lat": s.lat, "lon": s.lon, "alt": s.alt,
            "volts": battery.volts if battery else None,
            "mode": (vehicle.modeName(s) or "-").replace(" ", "_"),
            "armed": "-" if s.armed is None else ("1" if s.armed else "0")}
    tolerance = {"roll": 0.06, "pitch": 0.06, "yaw": 0.06, "lat": 1e-7, "lon": 1e-7, "alt": 0.06, "volts": 0.006}
    diff = []
    for name, theirs in zip(names, fields):
        ours = mine[name]
        if name in tolerance:
            if theirs == "-" and ours is None:
                continue
            if theirs == "-" or ours is None or abs(float(theirs) - ours) > tolerance[name]:
                diff.append("%s %s, here %s" % (name, theirs, ours))
        elif str(ours) != theirs:
            diff.append("%s %s, here %s" % (name, theirs, ours))
    return "; ".join(diff) or None


class Menus:
    """The device menus as the capture shows them: each device's info, its
    entries reassembled from their chunks, writes and what was read back."""

    def __init__(self, core):
        self.core = core
        self.devices = {}
        self.buffers = {}
        self.requests = []
        self.writes = []
        self.errors = []

    def sent(self, t, ftype, d):
        if ftype == 0x2C and len(d) >= 4:
            dest, entry, chunk = d[0], d[2], d[3]
            self.requests.append((t, dest, entry, chunk))
            if chunk == 0:
                self.buffers[(dest, entry)] = b""
        elif ftype == 0x2D and len(d) >= 4:
            self.writes.append({"t": t, "dest": d[0], "id": d[2], "bytes": list(d[3:]), "back": None})

    def received(self, t, ftype, d):
        if ftype == 0x29 and len(d) >= 3:
            origin = d[1]
            end = d.index(0, 2) if 0 in d[2:] else len(d)
            name = d[2:end].decode("utf-8", "replace")
            rest = d[end + 1:]
            count = rest[12] if len(rest) > 12 else None
            dev = self.devices.setdefault(origin, {"name": name, "count": count, "entries": {}})
            dev["name"], dev["count"] = name, count
        elif ftype == 0x2B and len(d) >= 4:
            origin, entry, left = d[1], d[2], d[3]
            key = (origin, entry)
            self.buffers[key] = self.buffers.get(key, b"") + bytes(d[4:])
            if left == 0:
                data = self.buffers.pop(key)
                e, enc = self.core.parse(self.core.devices, entry, data)
                dev = self.devices.setdefault(origin, {"name": "?", "count": None, "entries": {}})
                if e is None:
                    self.errors.append("device 0x%02X entry %d: %s" % (origin, entry, enc))
                    return
                dev["entries"][entry] = {"name": e.name, "type": e.type}
                for w in self.writes:
                    if w["back"] is None and w["dest"] == origin and w["id"] == entry and t >= w["t"]:
                        w["back"] = [enc[i] for i in range(1, len(enc) + 1)] if enc else []
                        w["name"] = e.name
                        w["type"] = e.type

    def retries(self):
        seen, n = set(), 0
        for _, dest, entry, chunk in self.requests:
            key = (dest, entry, chunk)
            if key in seen:
                n += 1
            seen.add(key)
        return n


# --- Analysis ---------------------------------------------------------------

class Mavlink:
    """The recorded MAVLink, by type, in time order."""

    def __init__(self, path):
        self.by_type = {}
        with open(path, encoding="utf-8") as f:
            for line in f:
                try:
                    d = json.loads(line)
                except ValueError:
                    continue
                t = d.pop("_t")
                self.by_type.setdefault(d.get("mavpackettype"), []).append((t, types.SimpleNamespace(**d)))
        for v in self.by_type.values():
            v.sort(key=lambda p: p[0])
        self.times = {k: [p[0] for p in v] for k, v in self.by_type.items()}

    def between(self, msg_type, start, end):
        times = self.times.get(msg_type, [])
        i, j = bisect.bisect_left(times, start), bisect.bisect_right(times, end)
        return [p[1] for p in self.by_type[msg_type][i:j]]

    def series(self, msg_type, get):
        return [(t, get(m)) for t, m in self.by_type.get(msg_type, [])]


def interpolate(series, times, t):
    i = bisect.bisect_left(times, t)
    if i <= 0 or i >= len(series):
        return None
    (t0, v0), (t1, v1) = series[i - 1], series[i]
    if t1 - t0 > 1:
        return None
    return v0 + (v1 - v0) * (t - t0) / (t1 - t0)


def align(pending, mav, session):
    """The offset from the radio's clock to the PC's: roughly from the flight
    modes (each change, seen on both sides), then exactly from the roll while
    the board was rocked. Returns (offset, how it was found)."""
    # Changes of mode and of arming, on both sides.
    radio_modes = []
    last = {}
    for name, value, t, _, _ in pending:
        if name in ("mode", "armed") and value != last.get(name):
            # A first reading is when it was first heard, not a change.
            if name in last:
                radio_modes.append((t, "%s %s" % (name, str(value).upper())))
            last[name] = value
    mav_modes = []
    last = {}
    for t, m in mav.by_type.get("HEARTBEAT", []):
        for name, value in (("mode", judge.mode_of(m).upper()), ("armed", bool(m.base_mode & judge.ARMED_FLAG))):
            if value != last.get(name):
                if name in last:
                    mav_modes.append((t, "%s %s" % (name, str(value).upper())))
                last[name] = value
    diffs = [tm - tr for tr, rm in radio_modes for tm, mm in mav_modes if rm == mm]
    rolls = [(t, v) for name, v, t, _, _ in pending if name == "roll"]
    att = mav.series("ATTITUDE", lambda m: math.degrees(m.roll))
    att_t = [p[0] for p in att]

    roll_t = [t for t, _ in rolls]

    def score(offset, windows):
        errs = []
        for a, b in windows or [(roll_t[0] + offset, roll_t[-1] + offset)]:
            i, j = bisect.bisect_left(roll_t, a - offset), bisect.bisect_right(roll_t, b - offset)
            for t, v in rolls[i:j]:
                m = interpolate(att, att_t, t + offset)
                if m is not None:
                    errs.append(abs(judge.signed_angle(v - m)))
        return (statistics.median(errs), len(errs)) if len(errs) >= 10 else (None, len(errs))

    def search(lo, hi, step, windows):
        """The best offset in lo..hi. Only offsets that line most of the
        window up with radio readings count: a sliver of it, where both
        sides happen to be still, would agree perfectly."""
        found = []
        o = lo
        while o <= hi:
            err, n = score(o, windows)
            if err is not None:
                found.append((err, o, n))
            o += step
        if not found:
            return None, None
        most = max(n for _, _, n in found)
        err, o, _ = min(f for f in found if f[2] >= 0.6 * most)
        return o, err

    rocks = [seg["rock"] for seg in session["segments"] if seg.get("rock")]
    if diffs:
        # Each pairing of a change on the radio with one in MAVLink to the
        # same mode is a candidate: the true offset less that change's
        # latency. The offset that explains the most changes with latencies
        # under MODE_LATENCY_S wins, taken where the quickest change had
        # none.
        def matched(o):
            return sum(1 for tr, rm in radio_modes
                       if any(mm == rm and 0 <= tr + o - tm <= MODE_LATENCY_S for tm, mm in mav_modes))
        counts = {d: matched(d) for d in diffs}
        most = max(counts.values())
        coarse = max(d for d, n in counts.items() if n == most)
        how = "mode and arming changes (%d)" % most
        span = 3.0
    elif rolls and att:
        coarse = ((att_t[0] - rolls[-1][0]) + (att_t[-1] - rolls[0][0])) / 2
        span = ((att_t[-1] - rolls[0][0]) - (att_t[0] - rolls[-1][0])) / 2
        how = "roll alone"
    else:
        return None, "nothing to line the clocks up by"
    if rolls and att:
        windows = rocks or None
        varied = rocks or max(abs(v) for _, v in att) > 10
        if varied:
            if span > 10:
                best, err = search(coarse - span, coarse + span, 0.25, windows)
                if best is not None:
                    best, err = search(best - 0.5, best + 0.5, 0.02, windows)
            else:
                best, err = search(coarse - span, coarse + span, 0.02, windows)
            if best is not None:
                return best, "%s, then roll%s (median %.1f degrees apart)" % (
                    how, " while rocked" if rocks else "", err)
    if how == "roll alone":
        return None, "no mode changes, and no rocking to line the clocks up by"
    return coarse, how


def analyze(folder, capture=None):
    folder = pathlib.Path(folder)
    session = json.loads((folder / "session.json").read_text(encoding="utf-8"))
    capture = pathlib.Path(capture) if capture else folder / "capture.txt"
    mav = Mavlink(folder / "mavlink.jsonl")
    lines = parse_capture(capture)
    report = []
    results = []

    def out(text):
        report.append(text)
        print(text, flush=True)

    def check(name, ok, detail=""):
        results.append(ok)
        out(("PASS " if ok else "FAIL ") + name + ("  " + str(detail) if detail != "" else ""))

    def info(name, detail=""):
        out("     " + name + ("  " + str(detail) if detail != "" else ""))

    for t, kind, f in lines:
        if kind == "H":
            info("radio", f)
            break
    pending, messages, d_checks, menus = decode(lines)
    offset, how = align(pending, mav, session)
    if offset is None:
        check("the radio's clock lines up with the PC's", False, how)
        return finish(folder, report, results)
    info("clocks lined up by " + how)

    table = judge.truths()
    gps = session.get("gps") in ("real", "fake")
    segments = session["segments"]
    for k, seg in enumerate(segments):
        out("== %s" % seg["name"])
        start, end = seg["start"], seg["end"]
        here = [(n, v, t + offset, "radio %.2f s, %s" % (t, label), c)
                for n, v, t, label, c in pending if start <= t + offset <= end]
        # A reading that never changes in the segment is judged as the
        # radio already showed it, or it would go unjudged: when it arrived,
        # where MAVLink reaches back that far, else as still true at the
        # start.
        changing = {n for n, _, _, _, _ in here}
        held = {}
        for n, v, t, label, c in pending:
            if t + offset < start and n not in changing:
                kind = table[n][0]
                first = mav.times.get(kind, [None])[0]
                at = t + offset if first is not None and t + offset - judge.BEFORE_S >= first else start
                held[n] = (n, v, at, "held from radio %.2f s" % t, c)
        here = list(held.values()) + here
        slow = SLOW_OVER_SPORT if seg["name"] == "sport" else None
        stats, examples = judge.judge(here, mav.between, table, before=slow)
        volts = [m.voltage_battery for m in mav.between("SYS_STATUS", start, end)]
        expect = {"roll", "pitch", "yaw", "mode"}
        if seg.get("star") or seg.get("passthrough"):
            expect.add("armed")
        if gps:
            expect |= {"lat", "lon", "sats"}
        if volts and max(volts) > 1000:
            expect.add("volts")
        for name, (compared, wrong, worst) in stats.items():
            tolerance = table[name][2]
            if compared == 0 and name not in expect:
                info("%s: not sent on this link" % name)
                continue
            check("%s matches MAVLink" % name, compared > 0 and wrong == 0,
                  "%d updates, %d outside %s, worst %s" % (compared, wrong, tolerance, round(worst, 4)))
        for e in examples:
            out(e)

        # Messages: each the radio shows is one ArduPilot sent. Text is a few
        # characters a word, so a burst can take a minute over a slow link:
        # what arrives until the next segment begins is this one's, and is
        # looked for among what ArduPilot sent from a minute before it.
        until = segments[k + 1]["start"] if k + 1 < len(segments) else end + 60
        shown = [(t + offset, text, sev) for t, text, sev in messages
                 if t is not None and start <= t + offset <= until and sev < 7]
        texts = [(t, m.text, m.severity) for t, m in mav.by_type.get("STATUSTEXT", []) if start - 60 <= t <= until]
        sent = [m.text for _, m in mav.by_type.get("STATUSTEXT", [])]
        recorded_from = min((v[0][0] for v in mav.by_type.values() if v), default=start)

        def known(text):
            t = text.rstrip()
            return TELEMETRY_ONLY.match(t) or any(
                tt.startswith(t) and len(t) >= min(len(tt.rstrip()), 40) for tt in sent)
        unknown = [(t, text) for t, text, _ in shown if not known(text)]
        # One sent before the recording began, and slow to arrive, has nothing
        # to be compared with.
        early = [text for t, text in unknown if t - recorded_from < 120]
        garbled = [text for t, text in unknown if t - recorded_from >= 120]
        if early:
            info("not checked, perhaps sent before the recording began: " + "; ".join(early[:3]))
        if seg.get("passthrough"):
            check("messages arrive", len(shown) > 0, "%d shown, %d sent" % (len(shown), len(texts)))
        else:
            info("messages: %d shown, %d sent" % (len(shown), len(texts)))
        if shown:
            check("each message shown is one ArduPilot sent", not garbled, "; ".join(garbled[:3]))

        # Link sensors.
        link = [f for t, k, f in lines if k == "L" and start <= t + offset <= end]
        lq = [x[0] for x in link if x[0] != "-"]
        rssi = [x[1] for x in link if x[1] != "-"]
        tx = [x[2] for x in link if x[2] != "-"]
        if session["link"] == "elrs":
            check("the link quality reads", bool(lq) and all(0 <= float(v) <= 100 for v in lq),
                  "LQ %s to %s" % (min(lq, key=float), max(lq, key=float)) if lq else "never")
        else:
            check("the receiver's RSSI reads", bool(rssi), "RSSI %s to %s" % (
                min(rssi, key=float), max(rssi, key=float)) if rssi else "never")
        check("the transmitter's battery reads", bool(tx), (tx[-1] + " V") if tx else "never")

        # Voice: each mode change and arming the test made is said, within
        # the time the link takes to carry it.
        said = [(t + offset, f) for t, k, f in lines if k == "A" and start <= t + offset <= end + 10]
        info("callouts: " + (", ".join(" ".join(f) for _, f in said) or "none"))
        missed = []
        for ev in session["events"]:
            if not start <= ev["t"] <= end or not ev.get("ok", True):
                continue
            if ev["kind"] == "mode":
                want = ("mode", squash(ev["mode"]))
            elif ev["kind"] in ("arm", "disarm") and (seg.get("star") or seg.get("passthrough")):
                want = ("armed" if ev["kind"] == "arm" else "disarmed", None)
            else:
                continue
            heard = any(f[0] == want[0] and (want[1] is None or squash(f[1][5:]) == want[1])
                        for t, f in said if ev["t"] <= t <= ev["t"] + MODE_LATENCY_S + 2)
            if not heard:
                missed.append(want[1] or want[0])
        check("each mode change and arming is said", not missed, "missed: " + ", ".join(missed) if missed else "")

    out("== the widget")
    n, bad = d_checks[0], d_checks[1]
    check("the radio decodes as the core does here", n > 0 and not bad,
          "%d seconds compared, %d differ" % (n, len(bad)))
    for b in bad:
        if b:
            out(b)
    seconds = [t + offset for t, k, _ in lines if k == "D"]
    first = min(seg["start"] for seg in session["segments"]) if session["segments"] else None
    last = max(seg["end"] for seg in session["segments"]) if session["segments"] else None
    inside = [t for t in seconds if first is not None and first <= t <= last]
    gaps = [b - a for a, b in zip(inside, inside[1:])]
    check("the widget ran throughout", bool(inside) and inside[0] - first < 5 and last - inside[-1] < 5
          and (not gaps or max(gaps) < 3), "longest pause %.1f s" % max(gaps) if gaps else "no seconds")
    timing = [f for _, k, f in lines if k == "W"]
    if timing:
        wake = [float(x[0]) for x in timing]
        paint = [float(x[1]) for x in timing]
        mem = [float(x[2]) for x in timing]
        info("slowest wakeup %.0f ms (typical %.0f), slowest paint %.0f ms (typical %.0f), Lua memory to %.0f kB"
             % (max(wake), statistics.median(wake), max(paint), statistics.median(paint), max(mem)))

    if menus.devices or menus.requests:
        out("== device menus")
        for addr, dev in sorted(menus.devices.items()):
            loaded = len([k for k in dev["entries"] if k >= 1])   # entry 0 is the root
            count = dev["count"]
            check("%s (0x%02X) loads" % (dev["name"], addr), count is not None and loaded >= count,
                  "%d of %s entries" % (loaded, count))
        check("every entry parses", not menus.errors, "; ".join(menus.errors[:3]))
        info("%d reads, %d asked again" % (len(menus.requests), menus.retries()))
        for w in menus.writes:
            if w.get("type") == 13:
                info("command '%s' sent" % w.get("name"))
                continue
            check("a write to %s is read back" % w.get("name", "entry %d" % w["id"]),
                  w["back"] is not None and w["back"] == w["bytes"],
                  "wrote %s, read back %s" % (w["bytes"], w["back"]))
    elif session.get("menu"):
        check("the device browser talked to the devices", False, "no device frames in the capture")

    return finish(folder, report, results)


def squash(name):
    """A mode name to compare: pymavlink's ALT_HOLD with the radio's AltHold."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def finish(folder, report, results):
    failed = results.count(False)
    line = "%d checks passed, %d failed" % (results.count(True), failed)
    print(line)
    report.append(line)
    (folder / "report.txt").write_text("\n".join(report) + "\n", encoding="utf-8")
    print("report: %s" % (folder / "report.txt"))
    return 1 if failed else 0


# --- Rehearsal against SITL -------------------------------------------------

class FakeRadio:
    """A radio on SITL's CRSF port, writing a capture as the test build does:
    its own clock, CRSF frames over ELRS, the passthrough words alone over
    S.Port, and the device browser loading the gyro's menu with a write."""

    CLOCK = 5000.0   # where the radio's clock stands at the start

    def __init__(self, sitl, link, path):
        self.sitl, self.link = sitl, link
        self.core = Core()
        self.file = open(path, "w", encoding="utf-8", newline="\n")
        self.cap = self.core.capture.new(lambda text: self.file.write(text) or self.file.flush())
        self.t0 = time.time()
        self.client = None
        self.watch = self.core.callouts.new()
        self.written = False
        self.running = True
        # What the link sensors would read.
        link_state = self.core.state.link
        if link == "elrs":
            link_state.lq = 99
        else:
            link_state.rssi = 80
        self.c("header", self.now(), "Rehearsal SITL")
        threading.Thread(target=self._loop, daemon=True).start()

    def now(self):
        return time.time() - self.t0 + self.CLOCK

    def c(self, method, *args):
        """Calls a capture method; lupa does not pass self for us."""
        return self.cap[method](self.cap, *args)

    def browse(self):
        def push(ftype, payload):
            d = [payload[i] for i in range(1, len(payload) + 1)]
            self.sitl.crsf.send(ftype, d)
            self.c("sent", self.now(), ftype, self.core.table(d))
            return True
        self.client = self.core.devices.new(push)
        self.client.ping(self.client)
        self.browsing = time.time()

    def _loop(self):
        loaded = written = False
        while self.running:
            now = self.now()
            for t, ftype, payload in self.sitl.crsf.take():
                d = self.core.table(list(payload))
                if self.link == "elrs":
                    self.c("frame", now, ftype, d)
                    if self.client and self.client.handle(self.client, ftype, d, now):
                        continue
                    self.core.apply("C", ftype, bytes(payload), now)
                elif ftype in (0x80, 0x7F):
                    for app, value in passthrough_words(payload):
                        self.c("sport", now, app, value)
                        self.core.apply("S", app, value, now)
            if self.client:
                self.client.update(self.client, now)
                dev = self.client.devices[0xC8]
                if dev and not loaded:
                    # as a pilot opening every folder would
                    self.client.loadAll(self.client, 0xC8)
                    loaded = True
                if loaded and not written:
                    done, count = self.client.progress(self.client, 0xC8)
                    if count > 0 and done == count:
                        written = True
                        self.written = True
                        for i in range(1, count + 1):
                            e = dev.entries[i]
                            if e and e.type == 9:
                                self.client.write(self.client, 0xC8, i, e.value)
                                break
            said = self.watch.update(self.watch, self.core.state, now, "all")
            for i in range(1, len(said) + 1):
                self.c("callout", now, said[i])
            self.c("update", now, self.core.state, 7.5)
            time.sleep(0.02)

    def close(self):
        self.running = False
        time.sleep(0.1)
        self.c("flush")
        self.file.close()


def passthrough_words(payload):
    """The (app ID, value) words in ArduPilot's custom CRSF frame."""
    d = bytes(payload)
    words = []
    if d and d[0] == 0xF0 and len(d) >= 7:
        words.append((int.from_bytes(d[1:3], "little"), int.from_bytes(d[3:7], "little")))
    elif d and d[0] == 0xF2:
        for k in range(d[1]):
            at = 2 + k * 6
            if at + 6 <= len(d):
                words.append((int.from_bytes(d[at:at + 2], "little"), int.from_bytes(d[at + 2:at + 6], "little")))
    elif d and d[0] == 0xF1 and len(d) >= 3:
        # A whole message, which S.Port has no frame for: as the text words
        # S.Port carries instead.
        end = d.index(0, 2) if 0 in d[2:] else len(d)
        words += text_words(d[2:end].decode("ascii", "replace"), d[1])
    return words


def text_words(text, severity):
    """A status message as passthrough text words (app ID 0x5000): four 7-bit
    characters a word, ended by a zero character within 50, the severity in
    bits 23, 15 and 7 of the last word."""
    chars = [ord(c) & 0x7F for c in text[:50]]
    if len(chars) < 50:
        chars.append(0)
    chars += [0] * (-len(chars) % 4)
    words = []
    for i in range(0, len(chars), 4):
        w = chars[i] << 24 | chars[i + 1] << 16 | chars[i + 2] << 8 | chars[i + 3]
        words.append(w)
    words[-1] |= (severity & 4) << 21 | (severity & 2) << 14 | (severity & 1) << 7
    return [(0x5000, w) for w in words]


def rehearse(link):
    import sitl as S
    S.run_in_wsl(__file__)
    failed = 0
    variants = ["crsf", "crsf-passthrough"] if link == "elrs" else ["sport"]
    for variant in variants:
        folder = OUT / ("rehearsal-" + variant)
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        print("== rehearsal: %s" % variant, flush=True)
        # The fake GPS's type and a MAVLink port for the driver. S.Port's words
        # come from the CRSF port's passthrough, which ArduPilot stops sending
        # once a port is set to FrSky passthrough; so none is, and the
        # driver's check of the ports is skipped.
        extra = "GPS1_TYPE 14\nSERIAL1_PROTOCOL 2\n"
        with S.Sitl(passthrough=variant != "crsf", extra=extra) as sitl:
            radio = FakeRadio(sitl, link, folder / "capture.txt")
            # Over passthrough a mode has no name until the frame type comes,
            # which SITL sends about half a minute in; on the bench the radio
            # has been listening longer.
            time.sleep(8 if variant == "crsf" else 35)
            args = argparse.Namespace(link=link, yes=True, out=str(folder), mavlink="tcp:127.0.0.1:5762",
                                      baud=115200, gps="fake", only=variant, no_arm=False,
                                      check_ports=False, capture=str(folder / "capture.txt"))
            def finish_radio():
                # The browser after the timed part, as on the bench: while a
                # menu loads ArduPilot sends it ahead of telemetry.
                if variant == "crsf":
                    radio.browse()
                    deadline = time.time() + 90
                    while time.time() < deadline and not radio.written:
                        time.sleep(0.5)
                    time.sleep(3)   # the write's read-back
                else:
                    # The radio goes on listening while the pilot reaches
                    # for the cable; the slow link's last messages come then.
                    time.sleep(60)
                radio.close()
            try:
                failed += run_with_capture(args, finish_radio)
            finally:
                radio.running = False
    sys.exit(1 if failed else 0)


def run_with_capture(args, before_analysis):
    """run, with the capture closed before it is analyzed."""
    real = analyze

    def wrapped(folder, capture=None):
        before_analysis()
        return real(folder, capture)
    globals()["analyze"] = wrapped
    try:
        return run(args)
    finally:
        globals()["analyze"] = real


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    ins = sub.add_parser("install", help="put the test build on the radio's SD card")
    ins.add_argument("--sd", help="the card's drive, when the radio is not found by itself")
    r = sub.add_parser("run", help="drive a bench test and analyze it")
    r.add_argument("link", choices=["elrs", "sport"])
    r.add_argument("--port", help="the flight controller's serial port (found by itself)")
    r.add_argument("--baud", type=int, default=115200)
    r.add_argument("--mavlink", help="a pymavlink connection string instead of a serial port")
    r.add_argument("--gps", choices=["auto", "real", "fake", "none"], default="auto")
    r.add_argument("--only", choices=["crsf", "crsf-passthrough", "sport"])
    r.add_argument("--no-arm", action="store_true", help="leave arming out")
    r.add_argument("--out", help="the session folder")
    r.add_argument("--capture", help="the radio's capture, when it is not copied off the radio")
    r.add_argument("--yes", action="store_true", help="no prompts")
    a = sub.add_parser("analyze", help="analyze a session again")
    a.add_argument("session")
    a.add_argument("--capture")
    h = sub.add_parser("rehearse", help="the whole test against SITL")
    h.add_argument("link", choices=["elrs", "sport"])
    args = ap.parse_args()
    if args.cmd == "install":
        install(args.sd)
    elif args.cmd == "run":
        if args.port and not args.mavlink:
            args.mavlink = args.port
        sys.exit(run(args))
    elif args.cmd == "analyze":
        sys.exit(analyze(args.session, args.capture))
    else:
        rehearse(args.link)


if __name__ == "__main__":
    main()
