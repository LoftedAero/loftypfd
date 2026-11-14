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

T.case("RSSI reported positive is read as dBm below zero, from the stronger antenna", function()
  local s = vehicle.new()
  sensors.apply(s, reader({ ["1RSS"] = live(70), ["2RSS"] = live(52), ANT = live(1) }), 1)
  T.eq(s.link.rssi, -52, "second antenna, the stronger")
  T.eq(s.link.rssi1, -70, "first antenna")
  sensors.apply(s, reader({ ["1RSS"] = live(-64), ["2RSS"] = live(0) }), 2)
  T.eq(s.link.rssi, -64, "a receiver with one antenna")
  T.eq(s.link.rssi2, nil, "0 is no antenna")
end)

T.case("the downlink and the transmitter's power", function()
  local s = vehicle.new()
  sensors.apply(s, reader({ TPWR = live(250), TRSS = live(-71), TQly = live(100), TSNR = live(9) }), 1)
  T.eq(s.link.txPower, 250, "mW, as EdgeTX converts it")
  T.eq(s.link.downRssi, -71, "downlink RSSI")
  T.eq(s.link.downLq, 100, "downlink LQ")
  T.eq(s.link.downSnr, 9, "downlink SNR")
end)

T.case("no fix yet: 0, 0 is not a position", function()
  local s = vehicle.new()
  sensors.apply(s, reader({ GPS = live({ lat = 0, lon = 0 }), Sats = live(3) }), 1)
  T.eq(s.lat, nil, "no position")
  T.eq(s.sats, 3, "sats still read")
end)

-- A model's sensor list as EdgeTX's model.getSensor and getFieldInfo see
-- it: slots of {name, id, instance}, an empty name for an unused slot, and
-- sensor n's source id FIRST + 3n.
local FIRST = 300
local function model(list)
  local slots = {}
  for i, e in ipairs(list) do
    slots[i - 1] = { name = e[1], id = e[2], instance = e[3], type = 0, unit = 0, prec = 0 }
  end
  local function getSensor(slot)
    if slot < #list then
      return slots[slot]
    end
  end
  local function fieldInfo(name)
    for n = 0, #list - 1 do
      if slots[n].name == name then
        return { id = FIRST + 3 * n, name = name, unit = 0 }
      end
    end
  end
  return getSensor, fieldInfo
end

local function found(list)
  local f = sensors.finder(model(list))
  for t = 1, 20 do
    f:step(t * 0.05)
  end
  return f.ids
end

-- The list on a TX15 whose sensors were discovered on EdgeTX 2.11.
local TX15 = {
  { "1RSS", 0x14, 0 }, { "2RSS", 0x14, 1 }, { "RQly", 0x14, 2 }, { "RSNR", 0x14, 3 },
  { "ANT", 0x14, 4 }, { "RFMD", 0x14, 5 }, { "TPWR", 0x14, 6 }, { "TRSS", 0x14, 7 },
  { "TQly", 0x14, 8 }, { "TSNR", 0x14, 9 }, { "FM", 0x21, 0 }, { "GPS", 0x02, 0 },
  { "GSpd", 0x02, 2 }, { "Hdg", 0x02, 3 }, { "Alt", 0x02, 4 }, { "Sats", 0x02, 5 },
  { "Ptch", 0x1E, 0 }, { "Roll", 0x1E, 1 }, { "Yaw", 0x1E, 2 }, { "RxBt", 0x08, 0 },
  { "Curr", 0x08, 1 }, { "Capa", 0x08, 2 }, { "Bat%", 0x08, 3 }, { "VSpd", 0x07, 0 },
  { "Alt", 0x09, 0 },
}

T.case("2.11's two Alt sensors: the GPS one is GAlt, the baro one Alt", function()
  local ids = found(TX15)
  T.eq(ids.GAlt, FIRST + 3 * 14, "GPS altitude, slot 14")
  T.eq(ids.Alt, FIRST + 3 * 24, "baro altitude, slot 24, though a name finds slot 14")
  T.eq(ids.FM, FIRST + 3 * 10, "flight mode")
  T.eq(ids.RFMD, nil, "a sensor not read")
end)

T.case("a renamed sensor, an unused slot and an earlier field of the same name", function()
  local ids = found({
    { "", nil, nil }, { "Alt", 0x09, 0 }, { "Climb", 0x07, 0 }, { "Alt", 0x09, 0 },
  })
  T.eq(ids.Alt, FIRST + 3 * 1, "the first of two")
  T.eq(ids.VSpd, FIRST + 3 * 2, "found though renamed")

  -- A name that is also another field's finds that field, which has no unit;
  -- the next name gives the sensors' first id.
  local getSensor, fieldInfo = model({ { "thr", 0x09, 0 }, { "VSpd", 0x07, 0 } })
  local f = sensors.finder(getSensor, function(name)
    if name == "thr" then
      return { id = 5, name = "thr" }
    end
    return fieldInfo(name)
  end)
  f:step(0)
  T.eq(f.ids.Alt, FIRST, "the base from the second sensor")
end)

T.case("the list is read again, so a sensor discovered later is found", function()
  local list = { { "Ptch", 0x1E, 0 } }
  local getSensor, fieldInfo = model(list)
  local f = sensors.finder(getSensor, fieldInfo)
  f:step(0)
  T.eq(f.ids.RxBt, nil, "not yet")
  list[2] = { "RxBt", 0x08, 0 }
  getSensor, fieldInfo = model(list)
  f.getSensor, f.fieldInfo = getSensor, fieldInfo
  f:step(1)
  T.eq(f.ids.RxBt, nil, "waits between passes")
  f:step(3.1)
  T.eq(f.ids.RxBt, FIRST + 3, "found on the next pass")
end)

T.case("reading the list costs little a cycle", function()
  local list = {}
  for i = 1, 99 do
    list[i] = TX15[(i - 1) % #TX15 + 1]
  end
  local f = sensors.finder(model(list))
  local n = 0
  debug.sethook(function()
    n = n + 1
  end, "", 1)
  f:step(0)
  debug.sethook()
  T.ok(n < 1500, "one cycle took " .. n .. " instructions")
end)
