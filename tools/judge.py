"""How a decoded reading is judged against ArduPilot's MAVLink.

Shared by the SITL test (tests/sitl_test.py) and the hardware test
(tools/hwtest.py), so both hold the radio to the same rules.

Every reading a frame changes must lie on the path of MAVLink values from
BEFORE_S before its arrival to AFTER_S after. A frame can be sampled between
two MAVLink messages, and MAVLink can trail it: CRSF frames go out at once
while MAVLink is buffered and the heartbeat is 1 Hz. Comparing against the
newest MAVLink value instead measures latency, not decoding.
"""
import math

BEFORE_S = 1.5
AFTER_S = 1.2

ARMED_FLAG = 128  # MAV_MODE_FLAG_SAFETY_ARMED


def signed_angle(d):
    return (d + 180) % 360 - 180


def angle_diff(a, b):
    return abs(signed_angle(a - b))


def path_error(value, truth, angle):
    """How far `value` lies from the path through consecutive truth values.

    A frame is sampled at some moment between two MAVLink messages, so during
    a fast roll it can sit far from both and still be exactly right.
    """
    if angle:
        # Unwrap so a path across +-180 or 0/360 is one segment.
        base = truth[0]
        truth = [base + signed_angle(t - base) for t in truth]
        value = base + signed_angle(value - base)
    best = min(abs(value - t) for t in truth)
    for a, b in zip(truth, truth[1:]):
        if min(a, b) <= value <= max(a, b):
            return 0.0
    return best


def mode_of(m):
    """A heartbeat's mode name, as pymavlink spells it."""
    name = getattr(m, "mode_name", None)
    if name is None:
        from pymavlink import mavutil
        name = mavutil.mode_string_v10(m)
    return name


def truths():
    """reading: (message, value, tolerance, kind), kind "number", "angle"
    (wraps) or "exact"."""
    return {
        "roll": ("ATTITUDE", lambda m: math.degrees(m.roll), 1, "angle"),
        "pitch": ("ATTITUDE", lambda m: math.degrees(m.pitch), 1, "angle"),
        "yaw": ("ATTITUDE", lambda m: math.degrees(m.yaw) % 360, 1, "angle"),
        "lat": ("GLOBAL_POSITION_INT", lambda m: m.lat / 1e7, 2e-5, "number"),
        "lon": ("GLOBAL_POSITION_INT", lambda m: m.lon / 1e7, 2e-5, "number"),
        "alt": ("GLOBAL_POSITION_INT", lambda m: m.relative_alt / 1000, 1, "number"),
        "climb": ("VFR_HUD", lambda m: m.climb, 0.5, "number"),
        "volts": ("SYS_STATUS", lambda m: m.voltage_battery / 1000, 0.1, "number"),
        "mode": ("HEARTBEAT", mode_of, 0, "exact"),
        "armed": ("HEARTBEAT", lambda m: bool(m.base_mode & ARMED_FLAG), 0, "exact"),
        "sats": ("GPS_RAW_INT", lambda m: m.satellites_visible, 0, "exact"),
        # CRSF's GPS frame carries the receiver's speed, as GPS_RAW_INT does;
        # VFR_HUD's is the attitude estimator's and leads it in a turn.
        "groundspeed": ("GPS_RAW_INT", lambda m: m.vel / 100, 0.5, "number"),
    }


def readings(lua_state, vehicle):
    """The judged readings of a decoded state (a lupa table)."""
    s = lua_state
    battery = s["battery"][1] if s["battery"] else None
    return {
        "roll": s["roll"], "pitch": s["pitch"], "yaw": s["yaw"], "lat": s["lat"], "lon": s["lon"],
        "alt": s["alt"], "climb": s["climb"], "volts": battery["volts"] if battery else None,
        "mode": vehicle.modeName(s), "armed": s["armed"], "sats": s["sats"],
        "groundspeed": s["groundspeed"],
    }


def judge(pending, between, table=None, examples_max=12, before=None):
    """Judges each (name, value, arrival, label, capped) against the MAVLink
    messages `between(type, start, end)` returns around its arrival.

    Returns {name: [compared, wrong, worst]} and examples of what was wrong.
    `capped` marks satellites sent in passthrough's four bits. `before`
    widens the look-back for readings a slow link carries late, by name.
    """
    table = table or truths()
    before = before or {}
    stats = {name: [0, 0, 0.0] for name in table}
    examples = []
    for name, value, arrival, label, capped in pending:
        msg_type, get, tolerance, kind = table[name]
        if capped:
            get = lambda m: min(m.satellites_visible, 15)  # noqa: E731
        back = before.get(name, BEFORE_S)
        truth = [get(m) for m in between(msg_type, arrival - back, arrival + AFTER_S)]
        if not truth:
            continue
        if kind == "exact":
            norm = lambda v: v.upper() if isinstance(v, str) else v  # noqa: E731
            error = 0 if norm(value) in [norm(t) for t in truth] else 1
        else:
            error = path_error(value, truth, kind == "angle")
        st = stats[name]
        st[0] += 1
        if error > tolerance:
            st[1] += 1
            if len(examples) < examples_max:
                examples.append("       %s at %s: %r, MAVLink %s" % (
                    name, label, value, [round(t, 2) if isinstance(t, float) else t for t in truth]))
        st[2] = max(st[2], error)
    return stats, examples
