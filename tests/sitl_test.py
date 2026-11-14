"""The Lua core against ArduPilot SITL: telemetry and the gyro's device menu.

    .venv/Scripts/python tests/sitl_test.py

Needs the gyro SITL build in WSL (~/ardupilot-gyro/build/sitl/bin/arduplane,
built with --extra-hwdef=Tools/gyro/sitl-gyro.hwdef) and nothing else on
ports 5760 and 5765. Two runs, about two minutes each:

1. Plain CRSF, as the gyro's defaults send it. The device menu's top level
   loads, with how long telemetry stops meanwhile, and each folder as it
   opens; a selection and a number are written, checked through MAVLink and
   put back; a command runs and is canceled. Then a flight, with what the
   radio decodes compared against ArduPilot's own MAVLink.
2. Passthrough over CRSF (RC_OPTIONS bit 8), the same flight comparison.
"""
import pathlib
import sys
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent / "tools"))

import sitl as S  # noqa: E402
from judge import AFTER_S, angle_diff, judge, readings, truths  # noqa: E402

FC = 0xC8
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + ("  " + str(detail) if detail != "" else ""), flush=True)


def opened(sitl, radio, folder, limit=30):
    """Opens a folder and waits until its entries have loaded."""
    radio.call("open", FC, folder)
    end = time.time() + limit
    while time.time() < end:
        radio.pump(sitl.crsf, 0.2)
        done, total = radio.call("progress", FC, folder)
        if total > 0 and done == total:
            return True
    return False


def find(sitl, radio, folder_name, name):
    top = radio.call("children", FC, 0)
    for i in range(1, len(top) + 1):
        if top[i]["name"] == folder_name:
            opened(sitl, radio, top[i]["id"])
            kids = radio.call("children", FC, top[i]["id"])
            for k in range(1, len(kids) + 1):
                if kids[k]["name"] == name:
                    return kids[k]
    return None


def device_menu(sitl, radio):
    client = radio.attach(sitl.crsf)
    radio.call("ping")
    radio.pump(sitl.crsf, 3)
    dev = client.devices[FC]
    check("the flight controller answers a ping", dev is not None, dev and dev["name"])
    if dev is None:
        return
    # Opening the device reads entry 0 and the top level it lists. ArduPilot
    # stops its telemetry while menu reads come and for 5 s after the last
    # (AP_CRSF_Telem::adjust_packet_weight), so the stop is measured as the
    # longest wait for an attitude frame.
    radio.call("load", FC)
    started = last_attitude = time.time()
    longest = 0.0
    loaded_at = None
    while time.time() - started < 60:
        radio.call("update", radio.now())
        for f in sitl.crsf.take():
            if f[1] == 0x1E:
                longest = max(longest, f[0] - last_attitude)
                last_attitude = f[0]
            radio.feed([f])
        if loaded_at is None:
            loaded, total = radio.call("progress", FC, 0)
            if total > 0 and loaded == total:
                loaded_at = time.time()
        elif last_attitude > loaded_at:
            break
        time.sleep(0.02)
    loaded, total = radio.call("progress", FC, 0)
    root = dev["entries"][0]
    listed = [root["children"][i] for i in range(1, len(root["children"]) + 1)] if root else []
    check("entry 0 lists the top level", root is not None and root["name"] == "root" and len(listed) == 8, listed)
    check("the top level loads", loaded == total and total > 0,
          "%d of %d in %.1f s" % (loaded, total, (loaded_at or time.time()) - started))
    everything, count = radio.call("progress", FC)
    check("and nothing else", everything == total, "%d of %d entries read" % (everything, count))
    check("telemetry stops for less than 9 s", longest < 9, "attitude stopped for %.1f s" % longest)
    top = radio.call("children", FC, 0)
    names = [top[i]["name"] for i in range(1, len(top) + 1)]
    check("top level is the gyro's", names == ["Status", "1 Calibration", "2 Radio", "3 Flight modes",
                                               "4 Outputs", "5 Failsafe", "6 Tuning", "Tools"], names)

    link_loss = find(sitl, radio, "5 Failsafe", "Link loss")
    before = sitl.mav.param("FS_LONG_ACTN")
    radio.call("write", FC, link_loss["id"], 1)    # "RTL if GPS"
    radio.pump(sitl.crsf, 3)
    after = client.devices[FC]["entries"][link_loss["id"]]
    now_param = sitl.mav.param("FS_LONG_ACTN")
    check("a selection writes and reads back", after["value"] == 1 and now_param == 1,
          "entry %s, FS_LONG_ACTN %s" % (after["value"], now_param))
    radio.call("write", FC, link_loss["id"], 0 if before == 2 else 1)
    radio.pump(sitl.crsf, 3)

    rate = find(sitl, radio, "6 Tuning", "ACRO roll rate")
    before = sitl.mav.param("ACRO_ROLL_RATE")
    radio.call("write", FC, rate["id"], 250)
    radio.pump(sitl.crsf, 3)
    got = sitl.mav.param("ACRO_ROLL_RATE")
    check("a number writes", got == 250 and client.devices[FC]["entries"][rate["id"]]["value"] == 250, got)
    radio.call("write", FC, rate["id"], int(before))
    radio.pump(sitl.crsf, 3)

    cmd = find(sitl, radio, "3 Flight modes", "Check mode switch")
    radio.call("command", FC, cmd["id"], 1)
    radio.pump(sitl.crsf, 2)
    e = client.devices[FC]["entries"][cmd["id"]]
    check("a command opens with the device's text", e["status"] in (2, 3) and "MANUAL" in (e["info"] or ""),
          "status %s, %r" % (e["status"], e["info"]))
    radio.call("command", FC, cmd["id"], 5)
    radio.pump(sitl.crsf, 2)
    e = client.devices[FC]["entries"][cmd["id"]]
    check("a command cancels", e["status"] == 0, e["status"])
    browser(sitl, radio, client)
    radio.client = None


# The browser (core/menu.lua) driven as a pilot would: events in, the texts
# it draws out.
UI = """
local menu = ...
local B = {}
function B.canvas()
  local noop = function() end
  local c = { fill = noop, tri = noop, line = noop, texts = {} }
  function c.text(x, y, str) c.texts[#c.texts + 1] = { x = x, y = y, str = str } end
  function c.textWidth(str, size) return #str * size * 0.6 end
  return c
end
function B.screen(app)
  local c = B.canvas()
  app:paint(c, 480, 320)
  local out = {}
  for i, t in ipairs(c.texts) do out[i] = t.str end
  return table.concat(out, "|")
end
-- Taps the control on the row that reads `str`.
function B.tap(app, str)
  local c = B.canvas()
  app:paint(c, 480, 320)
  for _, t in ipairs(c.texts) do
    if t.str == str then
      for _, h in ipairs(app.hits) do
        if t.y >= h[2] and t.y < h[4] and (h.row or h.commit) then
          app:event("tap", (h[1] + h[3]) / 2, (h[2] + h[4]) / 2)
          return true
        end
      end
    end
  end
  return false
end
-- Taps the Learn button on the row that reads `str`.
function B.learn(app, str)
  local c = B.canvas()
  app:paint(c, 480, 320)
  for _, t in ipairs(c.texts) do
    if t.str == str then
      for _, h in ipairs(app.hits) do
        if t.y >= h[2] and t.y < h[4] and h.part == 2 then
          app:event("tap", (h[1] + h[3]) / 2, (h[2] + h[4]) / 2)
          return true
        end
      end
    end
  end
  return false
end
return B
"""


def browser(sitl, radio, client):
    menu = radio.core("menu")
    ui = radio.rt.execute(UI, menu)
    app = menu.new(client)

    def pump(seconds):
        end = time.time() + seconds
        while time.time() < end:
            app.update(app, radio.now())
            radio.feed(sitl.crsf.take())
            time.sleep(0.02)

    def event(name):
        app.event(app, name)
        pump(0.5)

    def tap(text):
        ok = ui.tap(app, text)
        pump(0.5)
        return ok

    pump(3)
    tap("Gyro")
    check("the browser opens the gyro", "5 Failsafe" in ui.screen(app).split("|"), ui.screen(app))

    tap("6 Tuning")
    rate = find(sitl, radio, "6 Tuning", "ACRO roll rate")
    before = sitl.mav.param("ACRO_ROLL_RATE")
    tap("ACRO roll rate")
    editing = app.edit is not None
    event("next")
    event("enter")
    pump(2)
    got = sitl.mav.param("ACRO_ROLL_RATE")
    shown = menu.valueText(client.devices[FC]["entries"][rate["id"]])
    check("a setting stepped in the browser reaches ArduPilot",
          editing and got is not None and before is not None and got > before and shown in ui.screen(app),
          "ACRO_ROLL_RATE %s -> %s, shows %s" % (before, got, shown))
    radio.call("write", FC, rate["id"], int(before))
    pump(2)

    event("back")
    title = ui.screen(app).split("|")
    check("Back goes up one level", "Gyro" in title and "5 Failsafe" in title, title[:3])

    tap("3 Flight modes")
    tap("Check mode switch")
    pump(1)
    text = ui.screen(app)
    check("a command's prompt shows in the browser's dialog", app.dialog is not None and "MANUAL" in text, text[-120:])
    event("back")
    pump(1)
    e = client.devices[FC]["entries"][find(sitl, radio, "3 Flight modes", "Check mode switch")["id"]]
    check("Back cancels the command", app.dialog is None and e["status"] == 0, e["status"])

    event("back")
    tap("2 Radio")
    pump(3)
    shown = ui.screen(app).split("|")
    check("each channel's Learn command shares its row",
          shown.count("Learn") == 5 and "Arm switch" in shown and "Learn sticks" in shown
          and not any(t.startswith("Learn ") and t != "Learn sticks" for t in shown), shown)
    ui.learn(app, "Arm switch")
    pump(1)
    text = ui.screen(app)
    check("its Learn button runs it", app.dialog is not None and "Learn arm switch" in text, text[-120:])
    event("back")
    pump(1)
    check("and Back cancels it", app.dialog is None, app.dialog)

    # Wing type sets channels 1-4 as it is written; the channel's folder,
    # read again on opening, shows the new function.
    event("back")
    tap("4 Outputs")
    pump(3)
    tap("Wing type")
    event("next")
    event("enter")
    pump(2)
    got = sitl.mav.param("SERVO1_FUNCTION")
    check("Wing type sets the outputs as it is written", got == 77 and "Flying wing" in ui.screen(app).split("|"), got)
    tap("Channel 1")
    pump(3)
    shown = ui.screen(app).split("|")
    check("the channel shows its new function", "Elevon L" in shown, shown)
    event("back")
    tap("Wing type")
    event("prev")
    event("enter")
    pump(2)
    check("and back to Normal", sitl.mav.param("SERVO1_FUNCTION") == 4, sitl.mav.param("SERVO1_FUNCTION"))


def flight(sitl, radio, passthrough):
    """Flies, checking every reading each frame changes against MAVLink."""
    longest_gap = 0.0
    last_arrival = None
    ch = sitl.crsf.channels
    checked = {}
    pending = []
    started = time.time()

    def alt():
        pos = sitl.mav.get("GLOBAL_POSITION_INT")
        return pos.relative_alt / 1000 if pos else 0

    # Arm on the switch, take off in Manual, climb in FBWA from 10 m (as the
    # gyro's autotune test does: held in Manual the plane loops), then bank.
    plan = [(5, None, None), (3, (4, 2012), None), (20, (2, 2012), lambda: alt() > 10),
            (15, (5, 1500), None), (6, (0, 1800), None)]
    for seconds, change, until in plan:
        if change:
            ch[change[0]] = change[1]
        end = time.time() + seconds
        while time.time() < end and not (until and until()):
            for f in sitl.crsf.take():
                arrival = f[0]
                if last_arrival is not None:
                    longest_gap = max(longest_gap, arrival - last_arrival)
                last_arrival = arrival
                radio.feed([f])
                for name, value in readings(radio.state, radio.vehicle).items():
                    if value is None or value == checked.get(name):
                        continue
                    checked[name] = value
                    capped = name == "sats" and passthrough and not radio.vehicle.recent(radio.state, "crsf.gps")
                    pending.append((name, value, arrival, "%.2f s (frame 0x%02X)" % (arrival - started, f[1]), capped))
            time.sleep(0.02)
    time.sleep(AFTER_S + 0.5)

    table = truths()
    stats, examples = judge(pending, sitl.mav.between, table)
    for name, (compared, wrong, worst) in stats.items():
        tolerance = table[name][2]
        check("%s matches MAVLink" % name, compared > 0 and wrong == 0,
              "%d updates, %d outside %s, worst %s" % (compared, wrong, tolerance, round(worst, 4)))
    for e in examples:
        print(e, flush=True)
    s = radio.state
    check("climbed", (s["alt"] or 0) > 20, s["alt"])
    home_check(sitl, radio, passthrough)
    print("     longest gap between frames: %.1f s" % longest_gap, flush=True)


def home_check(sitl, radio, passthrough):
    """The home distance and bearing against ArduPilot's home.

    Judged from the position the radio last decoded (checked against MAVLink
    above), not MAVLink's newest: the radio's state is seconds old by now, and
    the plane has flown on. Over plain CRSF the home is the radio's own
    (core/home.lua), from the GPS frame's position, so the tolerance allows
    the GPS against the estimate.
    """
    home = sitl.mav.home()
    s = radio.state
    if home is None or s["lat"] is None:
        check("ArduPilot reports its home", False)
        return
    dist, bearing = radio.home.vector(s["lat"], s["lon"], home[0], home[1])
    got = s["homeDist"]
    source = "aircraft's" if passthrough else "radio's"
    check("the %s home distance matches" % source,
          got is not None and abs(got - dist) <= max(10, dist * 0.05),
          "%s m, ArduPilot %.0f m" % (got and round(got), dist))
    gotb = s["homeBearing"]
    check("the %s home bearing matches" % source,
          gotb is not None and (dist < 50 or angle_diff(gotb, bearing) <= 5),
          "%s, ArduPilot %.0f" % (gotb and round(gotb), bearing))


def main():
    S.run_in_wsl(__file__)
    print("== plain CRSF", flush=True)
    with S.Sitl(passthrough=False) as sitl:
        radio = S.Radio()
        time.sleep(8)
        radio.feed(sitl.crsf.take())
        device_menu(sitl, radio)
        flight(sitl, radio, passthrough=False)
    print("== passthrough over CRSF", flush=True)
    with S.Sitl(passthrough=True) as sitl:
        radio = S.Radio()
        flight(sitl, radio, passthrough=True)
    failed = results.count(False)
    print("%d checks passed, %d failed" % (results.count(True), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
