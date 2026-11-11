"""ArduPilot SITL as a CRSF receiver sees it.

Runs the gyro build of ArduPlane SITL in WSL (~/ardupilot-gyro), plays the
receiver on its CRSF port (RC frames out, telemetry and device-menu frames
in) and reads its MAVLink for ground truth. The radio side is the real Lua
core, run through lupa, so what the checks see is what a radio would decode.

    .venv/Scripts/python tools/sitl.py record out/flight.txt [--passthrough]

records a short flight's CRSF frames for replay, and

    .venv/Scripts/python tools/sitl.py menu out/gyro-menu.txt

the gyro's device menu as it answers, for a simulator to browse
(tools/build.py --menu). tests/sitl_test.py uses the same pieces as a
library.

The simulator serves one client per port and slows to a crawl when nobody
reads its MAVLink, so the reader here drains it continuously.

Everything runs inside WSL, next to the simulator: a connection from Windows
through WSL's localhost forwarding is accepted and then dropped at once, and
the simulator exits. Started from Windows, the scripts re-run themselves in
WSL, whose Python needs lupa and pymavlink (tools/requirements.txt).
"""
import argparse
import os
import pathlib
import socket
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
GYRO = os.path.expanduser(os.environ.get("GYRO_REPO", "~/ardupilot-gyro"))


def wsl_path(path):
    p = pathlib.Path(path).resolve()
    return "/mnt/" + p.drive[0].lower() + p.as_posix()[2:]


def run_in_wsl(script):
    """On Windows, runs `script` with the same arguments in WSL and exits."""
    if os.name == "nt":
        sys.exit(subprocess.call(["wsl", "-e", "python3", "-u", wsl_path(script)] + sys.argv[1:]))


if os.name != "nt":
    from pymavlink import mavutil
MAV_PORT = 5760
CRSF_PORT = 5765
HOME = "-35.363261,149.165230,584,353"

SYNC = 0xC8
# How long MAVLink ground truth is kept.
HISTORY_S = 120

# The gyro defaults that matter here: arm switch on 5, three-position mode
# switch on 6 (Manual low, FBWA middle and high), and CRSF on serial 5.
# RC_OPTIONS 96 is the gyro's own; bit 12 adds the disarmed star to CRSF
# flight modes and bit 8 switches CRSF telemetry to passthrough.
PARAMS = """
ARMING_REQUIRE 1
ARMING_SKIPCHK -65
RC5_OPTION 153
FLTMODE_CH 6
FLTMODE1 0
FLTMODE2 0
FLTMODE3 5
FLTMODE4 5
FLTMODE5 5
FLTMODE6 5
SERIAL5_PROTOCOL 23
RC_PROTOCOLS 512
SCR_ENABLE 0
"""


def crc8(data):
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = ((crc << 1) ^ 0xD5) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def frame(ftype, payload):
    body = bytes([ftype]) + bytes(payload)
    return bytes([SYNC, len(body) + 1]) + body + bytes([crc8(body)])


def rc_frame(channels):
    bits = 0
    for i, us in enumerate(list(channels) + [1500] * (16 - len(channels))):
        v = max(0, min(2047, int(round((us - 1500) * 1.6 + 992))))
        bits |= v << (11 * i)
    return frame(0x16, bits.to_bytes(22, "little"))


class Sitl:
    """One simulator run. Use as a context manager so it is always stopped."""

    def __init__(self, passthrough=False, star=True, extra=""):
        options = 96 | (256 if passthrough else 0) | (4096 if star else 0)
        self.out = ROOT / "out" / "sitl"
        self.out.mkdir(parents=True, exist_ok=True)
        # The simulator's own files (eeprom, logs) stay on the Linux side,
        # which is much faster than /mnt/c.
        self.workdir = pathlib.Path("/tmp/loftypfd-sitl")
        self.workdir.mkdir(parents=True, exist_ok=True)
        self.parm = self.workdir / "test.parm"
        self.parm.write_text(PARAMS + "RC_OPTIONS %d\n" % options + extra)
        self.proc = None

    def __enter__(self):
        for port in (MAV_PORT, CRSF_PORT):
            with socket.socket() as s:
                if s.connect_ex(("127.0.0.1", port)) == 0:
                    raise RuntimeError("port %d is in use: another simulator is running" % port)
        cmd = [GYRO + "/build/sitl/bin/arduplane", "--model", "plane", "--speedup", "1", "-w",
               "--home", HOME, "--serial5=tcp:%d" % CRSF_PORT,
               "--defaults", GYRO + "/Tools/autotest/models/plane.parm," + str(self.parm)]
        log = open(str(self.out / "sitl_stdout.txt"), "w")
        # Our own child, so it is stopped by its handle and never by name:
        # other sessions run simulators too.
        self.proc = subprocess.Popen(cmd, cwd=str(self.workdir), stdout=log, stderr=subprocess.STDOUT)
        try:
            self.mav = Mav(lambda: self.proc.poll() is None)
            self.crsf = CrsfLink()
        except Exception:
            self.__exit__()
            raise
        return self

    def __exit__(self, *exc):
        for part in ("crsf", "mav"):
            if hasattr(self, part):
                getattr(self, part).close()
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


class Mav:
    """MAVLink ground truth: the latest of each message, and status texts."""

    def __init__(self, alive):
        # `alive` says whether the simulator is still running; after it exits,
        # pymavlink would otherwise report EOF forever.
        self.alive = alive
        deadline = time.time() + 60
        while True:
            try:
                self.m = mavutil.mavlink_connection("tcp:127.0.0.1:%d" % MAV_PORT, source_system=255,
                                                    autoreconnect=False)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.m.wait_heartbeat(timeout=60)
        self.m.mav.request_data_stream_send(self.m.target_system, self.m.target_component,
                                            mavutil.mavlink.MAV_DATA_STREAM_ALL, 10, 1)
        self.latest = {}
        # Recent messages with their arrival time, so a telemetry value can be
        # compared with what was true while it was in flight.
        self.history = []
        self.texts = []
        self.params = {}
        self.lock = threading.Lock()
        self.running = True
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        while self.running and self.alive():
            try:
                msg = self.m.recv_match(blocking=True, timeout=1)
            except Exception:
                return
            if msg is None:
                continue
            t = msg.get_type()
            with self.lock:
                if t == "HEARTBEAT" and msg.get_srcComponent() != 1:
                    continue
                self.latest[t] = msg
                now = time.time()
                self.history.append((now, t, msg))
                # By age, not count: at the full stream rate a few thousand
                # messages are only a few seconds.
                if now - self.history[0][0] > HISTORY_S + 10:
                    self.history = [h for h in self.history if now - h[0] <= HISTORY_S]
                if t == "STATUSTEXT":
                    self.texts.append(msg.text)
                elif t == "PARAM_VALUE":
                    self.params[msg.param_id] = msg.param_value

    def get(self, msg_type):
        with self.lock:
            return self.latest.get(msg_type)

    def between(self, msg_type, start, end):
        """Messages of a type received between two times."""
        with self.lock:
            return [m for t0, t, m in self.history if t == msg_type and start <= t0 <= end]

    def armed(self):
        hb = self.get("HEARTBEAT")
        return hb is not None and bool(hb.base_mode & mavutil.mavlink.MAV_MODE_FLAG_SAFETY_ARMED)

    def param(self, name, timeout=5):
        with self.lock:
            self.params.pop(name, None)
        self.m.param_fetch_one(name)
        deadline = time.time() + timeout
        while time.time() < deadline:
            with self.lock:
                if name in self.params:
                    return self.params[name]
            time.sleep(0.05)
        return None

    def home(self, timeout=5):
        """ArduPilot's home as (lat, lon) in degrees, asked for once."""
        with self.lock:
            self.latest.pop("HOME_POSITION", None)
        self.m.mav.command_long_send(self.m.target_system, self.m.target_component,
                                     mavutil.mavlink.MAV_CMD_REQUEST_MESSAGE, 0,
                                     mavutil.mavlink.MAVLINK_MSG_ID_HOME_POSITION, 0, 0, 0, 0, 0, 0)
        deadline = time.time() + timeout
        while time.time() < deadline:
            h = self.get("HOME_POSITION")
            if h is not None:
                return h.latitude / 1e7, h.longitude / 1e7
            time.sleep(0.05)
        return None

    def close(self):
        self.running = False
        self.m.close()


class CrsfLink:
    """The receiver's side of the CRSF port: RC out, frames in."""

    # roll, pitch, throttle, yaw | arm, mode, rtl, gain knob
    def __init__(self):
        deadline = time.time() + 30
        while True:
            try:
                self.sock = socket.create_connection(("127.0.0.1", CRSF_PORT), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise
                time.sleep(0.5)
        self.sock.settimeout(0.05)
        self.channels = [1500, 1500, 988, 1500, 988, 988, 988, 1500]
        self.frames = []
        self.lock = threading.Lock()
        self.running = True
        self.buf = b""
        threading.Thread(target=self._send_rc, daemon=True).start()
        threading.Thread(target=self._receive, daemon=True).start()

    def send(self, ftype, payload):
        with self.lock:
            self.sock.sendall(frame(ftype, payload))

    def _send_rc(self):
        while self.running:
            try:
                with self.lock:
                    self.sock.sendall(rc_frame(self.channels))
            except OSError:
                return
            time.sleep(0.01)

    def _receive(self):
        while self.running:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk
            while len(self.buf) >= 2:
                length = self.buf[1]
                if self.buf[0] != SYNC and self.buf[0] != 0xEA or length < 2 or length > 62:
                    self.buf = self.buf[1:]
                    continue
                if len(self.buf) < length + 2:
                    break
                body = self.buf[2:1 + length]
                ok = crc8(body) == self.buf[1 + length]
                self.buf = self.buf[2 + length:]
                if ok:
                    with self.lock:
                        self.frames.append((time.time(), body[0], bytes(body[1:])))

    def take(self):
        """Every frame received since the last call: (time, type, payload)."""
        with self.lock:
            out, self.frames = self.frames, []
        return out

    def close(self):
        self.running = False
        self.sock.close()


class Radio:
    """The Lua core as a radio runs it, fed from a CRSF link."""

    def __init__(self, version="lua54"):
        import importlib
        self.rt = importlib.import_module("lupa." + version).LuaRuntime()
        read = lambda path: (ROOT / path).read_text(encoding="utf-8")  # noqa: E731
        self.core = self.rt.eval("""function(read)
            local cache = {}
            local function use(name)
              if cache[name] == nil then
                cache[name] = assert(load(read("src/core/" .. name .. ".lua"), "@" .. name))(use)
              end
              return cache[name]
            end
            return use
          end""")(read)
        self.vehicle = self.core("vehicle")
        self.crsf = self.core("crsf")
        self.devices = self.core("devices")
        self.home = self.core("home")
        self.state = self.vehicle.new()
        self.t0 = time.time()
        self.client = None
        self._feed = self.rt.eval("""function(crsf, home, client, s, ftype, payload, now)
            local d = {}
            for i = 1, #payload do d[i] = payload:byte(i) end
            if client and client:handle(ftype, d, now) then return end
            crsf.apply(s, ftype, d, now)
            home.update(s)
          end""")

    def attach(self, link):
        """Gives the device client a push function sending on `link`."""
        def push(ftype, payload):
            link.send(ftype, [payload[i] for i in range(1, len(payload) + 1)])
            return True
        self.client = self.devices.new(push)
        return self.client

    def call(self, method, *args):
        """Calls a device-client method; lupa does not pass self for us."""
        return self.client[method](self.client, *args)

    def now(self):
        return time.time() - self.t0

    def feed(self, frames):
        for _, ftype, payload in frames:
            self._feed(self.crsf, self.home, self.client, self.state, ftype, payload, self.now())

    def pump(self, link, seconds):
        """Runs the radio loop for `seconds`, as a script's wakeup would."""
        end = time.time() + seconds
        while time.time() < end:
            if self.client is not None:
                self.call("update", self.now())
            self.feed(link.take())
            time.sleep(0.02)


def fly(sitl, radio, record=None):
    """Arms on the switch, takes off in Manual, climbs and turns in FBWA."""
    ch = sitl.crsf.channels
    frames = []

    def wait(seconds):
        end = time.time() + seconds
        while time.time() < end:
            got = sitl.crsf.take()
            radio.feed(got)
            frames.extend(got)
            time.sleep(0.02)

    def alt():
        pos = sitl.mav.get("GLOBAL_POSITION_INT")
        return pos.relative_alt / 1000 if pos else 0

    # Disarmed on the ground, then armed on the switch; take off in Manual
    # and climb in FBWA from 10 m (held in Manual at full throttle the SITL
    # plane loops); turn right, turn left, then glide down.
    wait(8)
    ch[4] = 2012        # arm switch, throttle low
    wait(3)
    ch[2] = 2012        # full throttle in Manual
    end = time.time() + 20
    while time.time() < end and alt() < 10:
        wait(0.2)
    ch[5] = 1500        # FBWA, climb
    wait(15)
    ch[2] = 1700        # cruise
    ch[0] = 1800        # bank right
    wait(12)
    ch[0] = 1500
    wait(4)
    ch[0] = 1200        # bank left
    wait(12)
    ch[0] = 1500
    ch[2] = 988         # glide
    wait(15)
    if record:
        # The format core/replay.lua reads: "<seconds> <type> <payload hex>".
        with open(record, "w", encoding="utf-8", newline="\n") as f:
            t0 = frames[0][0] if frames else 0
            for t, ftype, payload in frames:
                f.write("%.3f %d %s\n" % (t - t0, ftype, payload.hex()))
    return frames


def record_menu(sitl, out):
    """Loads the gyro's whole menu, keeping its answers: the device info and
    every chunk of every entry, as "0 type hex" lines."""
    radio = Radio()
    client = radio.attach(sitl.crsf)
    kept = {}
    deadline = time.time() + 60
    loading = False
    radio.call("ping")
    while time.time() < deadline:
        radio.call("update", radio.now())
        frames = sitl.crsf.take()
        for _, ftype, payload in frames:
            if ftype == 0x29:
                kept[(ftype, 0, 0)] = payload
            elif ftype == 0x2B:
                kept[(ftype, payload[2], payload[3])] = payload
        radio.feed(frames)
        if client.devices[0xC8] is not None:
            if not loading:
                loading = True
                radio.call("load", 0xC8)
            loaded, count = radio.call("progress", 0xC8)
            if loaded == count:
                break
        time.sleep(0.02)
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        for (ftype, _, _), payload in sorted(kept.items()):
            f.write("0 %d %s\n" % (ftype, bytes(payload).hex()))
    return len(kept)


def main():
    run_in_wsl(__file__)
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="record a short flight's CRSF frames")
    rec.add_argument("out")
    rec.add_argument("--passthrough", action="store_true")
    men = sub.add_parser("menu", help="record the gyro's device menu")
    men.add_argument("out")
    args = ap.parse_args()
    if args.cmd == "menu":
        with Sitl() as sitl:
            time.sleep(8)
            n = record_menu(sitl, args.out)
        print("recorded %d frames to %s" % (n, args.out))
        return
    with Sitl(passthrough=args.passthrough) as sitl:
        frames = fly(sitl, Radio(), record=args.out)
    print("recorded %d frames to %s" % (len(frames), args.out))


if __name__ == "__main__":
    main()
