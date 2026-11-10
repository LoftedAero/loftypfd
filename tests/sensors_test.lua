-- EdgeTX's sensors, in the units and shapes its getSourceValue returns.

local use, T = ...
local sensors = use("sensors")
local vehicle = use("vehicle")

-- A sensor table: name -> {value, current, fresh}; absent names never reported.
local function reader(t)
  return function(name)
    local e = t[name]
    if not e then
      return
    end
    return e[1], e[2], e[3]
  end
end

local function live(v)
  return { v, true, true }
end

T.case("a full set of plain CRSF sensors", function()
  local s = vehicle.new()
  local arrived = sensors.apply(s, reader({
    Ptch = live(0.175), Roll = live(-0.524), Yaw = live(-1.5708),
    GPS = live({ lat = -35.363261, lon = 149.16523 }), GSpd = live(90), Hdg = live(180), GAlt = live(584),
    Sats = live(10), RxBt = live(16.4), Curr = live(12.3), Capa = live(1234), ["Bat%"] = live(75),
    Alt = live(123.4), VSpd = live(2.5), FM = live("FBWA*"),
    ["1RSS"] = live(-55), ANT = live(0), RQly = live(98), RSNR = live(7),
  }), 4)
  T.ok(arrived, "arrived")
  T.eq(s.lastFrame, 4, "time")
  T.near(s.pitch, 10.03, 0.01, "pitch from radians")
  T.near(s.roll, -30.02, 0.01, "roll")
  T.near(s.yaw, 270, 0.01, "yaw wrapped")
  T.near(s.lat, -35.363261, 1e-7, "lat")
  T.near(s.groundspeed, 25, 1e-9, "km/h to m/s")
  T.eq(s.sats, 10, "sats")
  T.near(s.battery[1].volts, 16.4, 1e-9, "volts")
  T.eq(s.battery[1].used, 1234, "used")
  T.near(s.alt, 123.4, 1e-9, "alt")
  T.near(s.climb, 2.5, 1e-9, "climb")
  T.eq(vehicle.modeName(s), "FBWA", "mode")
  T.eq(s.armed, false, "the star says disarmed")
  T.eq(s.link.rssi, -55, "rssi")
  T.eq(s.link.lq, 98, "lq")
end)

T.case("stale sensors are held but do not count as arriving", function()
  local s = vehicle.new()
  local arrived = sensors.apply(s, reader({ Ptch = { 0.1, true, false }, Roll = { 0, true, false }, Yaw = { 0, true, false } }), 9)
  T.ok(not arrived, "not arrived")
  T.eq(s.lastFrame, nil, "no frame time")
  T.near(s.pitch, 5.73, 0.01, "value still applied while current")
  sensors.apply(s, reader({ RxBt = { 12, false, false } }), 10)
  T.eq(s.battery[1].volts, nil, "a timed-out sensor is not applied")
end)

T.case("RSSI reported positive is read as dBm below zero, from the active antenna", function()
  local s = vehicle.new()
  sensors.apply(s, reader({ ["1RSS"] = live(70), ["2RSS"] = live(52), ANT = live(1) }), 1)
  T.eq(s.link.rssi, -52, "second antenna")
end)

T.case("no fix yet: 0, 0 is not a position", function()
  local s = vehicle.new()
  sensors.apply(s, reader({ GPS = live({ lat = 0, lon = 0 }), Sats = live(3) }), 1)
  T.eq(s.lat, nil, "no position")
  T.eq(s.sats, 3, "sats still read")
end)
